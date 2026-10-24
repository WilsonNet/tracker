import { useState, useCallback, useEffect, useRef, useMemo } from "react";
import type { TransportState, VimMode, TrackData, BounceState, RhythmData, AudioDeviceInfo, LevelUpdate, MixRenderResult } from "./types/types.ts";
import { defaultTrack } from "./types/types.ts";
import { useVimKeyboard } from "./hooks/useVimKeyboard.ts";
import { TransportBar } from "./components/TransportBar.tsx";
import { TrackStrip } from "./components/TrackStrip.tsx";
import { BounceSection } from "./components/BounceSection.tsx";
import { RhythmSection } from "./components/RhythmSection.tsx";
import { VimStatusLine } from "./components/VimStatusLine.tsx";
import { CommandPalette } from "./components/CommandPalette.tsx";
import { FxRack, type FxMeterState, type FxTab } from "./components/FxRack.tsx";
import {
  defaultFxState,
  effectiveDelayMs,
  fmtDb,
  trackFxBadges,
  type FxState,
  type MixSettings,
} from "./lib/fx.ts";

function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

async function tauriInvoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  const { invoke } = await import("@tauri-apps/api/core");
  return invoke<T>(cmd, args);
}

async function tauriListen<T>(event: string, handler: (payload: T) => void): Promise<() => void> {
  const { listen } = await import("@tauri-apps/api/event");
  return listen<T>(event, (e) => handler(e.payload));
}

export default function App() {
  const [transport, setTransport] = useState<TransportState>("stopped");
  const [mode, setMode] = useState<VimMode>("normal");
  const [bpm, setBpm] = useState(120);
  const [position] = useState(0);
  const [tracks, setTracks] = useState<TrackData[]>([
    defaultTrack(0),
    defaultTrack(1),
    defaultTrack(2),
    defaultTrack(3),
  ]);
  const [selectedTrack, setSelectedTrack] = useState(0);
  const [bounce, setBounce] = useState<BounceState>({ canUndo: false, inProgress: false });
  const [rhythm, setRhythm] = useState<RhythmData>({
    enabled: false,
    pattern: "Rock",
    tempo: 120,
    patternName: "Rock",
  });
  const [cmdOpen, setCmdOpen] = useState(false);
  const [statusMsg, setStatusMsg] = useState("");
  const [devices, setDevices] = useState<AudioDeviceInfo[]>([]);
  const [selectedDevice, setSelectedDevice] = useState("");
  const [captureActive, setCaptureActive] = useState(false);
  const [levels, setLevels] = useState<LevelUpdate | null>(null);
  const [tauriMode, setTauriMode] = useState(false);
  const [playbackActive, setPlaybackActive] = useState(false);
  const [recordingTime, setRecordingTime] = useState(0);
  const recStartRef = useRef(0);
  const [fx, setFx] = useState<FxState>(() => defaultFxState(4));
  const [fxOpen, setFxOpen] = useState(false);
  const [fxTab, setFxTab] = useState<FxTab>(0);
  const [renderInfo, setRenderInfo] = useState<MixRenderResult | null>(null);
  const [playhead, setPlayhead] = useState(0);

  const channelCount = tauriMode
    ? devices.find((d) => d.name === selectedDevice)?.input_channels ?? 2
    : 2;

  const mixSettings: MixSettings = useMemo(() => {
    const anySolo = tracks.some((t) => t.solo);
    return {
      tracks: fx.tracks.map((trackFx, i) => {
        const track = tracks[i];
        return {
          eq: trackFx.eq,
          comp: trackFx.comp,
          sendReverb: trackFx.sendReverb,
          sendDelay: trackFx.sendDelay,
          level: track?.level ?? 0.8,
          pan: (track?.pan ?? 0.5) * 2 - 1,
          muted: !track || track.muted || (anySolo && !track.solo),
        };
      }),
      masterComp: fx.masterComp,
      reverb: fx.reverb,
      delay: { ...fx.delay, timeMs: effectiveDelayMs(fx.delay, bpm) },
      width: fx.width,
      limiter: fx.limiter,
    };
  }, [bpm, fx, tracks]);

  const meters: FxMeterState = useMemo(() => {
    if (!renderInfo) {
      return {
        playing: false,
        trackGr: [0, 0, 0, 0],
        trackPeakGr: [0, 0, 0, 0],
        masterGr: 0,
        masterPeakGr: 0,
        limiterGr: 0,
        limiterPeakGr: 0,
        peakDb: -96,
      };
    }
    const live = playbackActive;
    const at = (timeline: number[] | undefined, fallback: number) => {
      if (!live || !timeline || timeline.length === 0) return fallback;
      return timeline[Math.min(playhead, timeline.length - 1)] ?? fallback;
    };
    return {
      playing: live,
      trackGr: renderInfo.trackGrTimeline.map((timeline, i) => at(timeline, renderInfo.trackGr[i] ?? 0)),
      trackPeakGr: renderInfo.trackGr,
      masterGr: at(renderInfo.masterGrTimeline, renderInfo.masterGr),
      masterPeakGr: renderInfo.masterGr,
      limiterGr: at(renderInfo.limiterGrTimeline, renderInfo.limiterGr),
      limiterPeakGr: renderInfo.limiterGr,
      peakDb: renderInfo.peakDb,
    };
  }, [playbackActive, playhead, renderInfo]);

  useEffect(() => {
    setTauriMode(isTauri());
  }, []);

  useEffect(() => {
    if (!tauriMode) return;
    tauriInvoke<AudioDeviceInfo[]>("list_audio_devices")
      .then((d) => {
        setDevices(d);
        const def = d.find((dd) => dd.is_default);
        if (def && !selectedDevice) setSelectedDevice(def.name);
      })
      .catch(() => {});
  }, [tauriMode]);

  useEffect(() => {
    if (!tauriMode) return;
    const unlisten = tauriListen<LevelUpdate>("level-update", (payload) => {
      setLevels(payload);
    });
    return () => { unlisten.then((u) => u()); };
  }, [tauriMode]);

  useEffect(() => {
    if (!tauriMode) return;
    const unlisten = tauriListen<boolean>("playback-ended", () => setPlaybackActive(false));
    return () => { unlisten.then((u) => u()); };
  }, [tauriMode]);

  // Drive the FX GR meters from the render's timeline while audio plays.
  useEffect(() => {
    if (!playbackActive || !renderInfo) return;
    const started = performance.now();
    const points = Math.max(1, renderInfo.limiterGrTimeline.length);
    setPlayhead(0);
    const id = setInterval(() => {
      const elapsed = (performance.now() - started) / 1000;
      setPlayhead(Math.max(0, Math.min(points - 1, Math.floor(elapsed * 20))));
      if (elapsed > renderInfo.durationSec + 0.4) setPlaybackActive(false);
    }, 50);
    return () => clearInterval(id);
  }, [playbackActive, renderInfo]);

  // Demo meter animation for browser/Vite mode
  useEffect(() => {
    if (tauriMode || !captureActive) return;
    const interval = setInterval(() => {
      const now = Date.now() / 1000;
      const a = Math.max(0, Math.sin(now * 4) * 0.5 + 0.5) * 0.85 + 0.05;
      const b = Math.max(0, Math.sin(now * 3 + 1) * 0.4 + 0.5) * 0.7 + 0.05;
      setLevels({
        input_peaks: [linearToDb(a), linearToDb(b)],
        input_rms: [linearToDb(a * 0.7), linearToDb(b * 0.6)],
        recording: transport === "recording",
        armed_tracks: tracks.map((t) => t.armed),
        metrics: { underruns: 0, overruns: 0, callback_interval_ms: 50 },
      });
    }, 50);
    return () => clearInterval(interval);
  }, [tauriMode, captureActive, transport, tracks]);

  // Recording timer
  useEffect(() => {
    if (transport === "recording") {
      recStartRef.current = Date.now();
      const t = setInterval(() => {
        setRecordingTime((Date.now() - recStartRef.current) / 1000);
      }, 250);
      return () => clearInterval(t);
    }
    setRecordingTime(0);
  }, [transport]);

  // Clamp per-track input channel when the selected device has fewer channels
  useEffect(() => {
    if (!tauriMode || !selectedDevice) return;
    setTracks((ts) =>
      ts.map((t) =>
        t.inputChannel >= channelCount ? { ...t, inputChannel: channelCount - 1 } : t,
      ),
    );
  }, [channelCount, tauriMode, selectedDevice]);

  const showMsg = useCallback((msg: string) => {
    setStatusMsg(msg);
    setTimeout(() => setStatusMsg(""), 3000);
  }, []);

  function toggleCapture() {
    if (captureActive) {
      if (tauriMode) tauriInvoke("stop_capture").catch(() => {});
      setCaptureActive(false);
      setLevels(null);
      showMsg("Capture stopped");
    } else {
      if (tauriMode && !selectedDevice) { showMsg("No device selected"); return; }
      if (tauriMode) {
        tauriInvoke("start_capture", { deviceName: selectedDevice })
          .then(() => setCaptureActive(true))
          .catch((e: string) => showMsg(`Capture failed: ${e}`));
      } else {
        setCaptureActive(true);
        showMsg("Demo mode — simulated levels");
      }
    }
  }

  useVimKeyboard(
    useCallback(
      (key, mods) => {
        if (cmdOpen) return;
        if (key === ":") { setCmdOpen(true); return; }
        if (key === "Escape") {
          if (fxOpen) { setFxOpen(false); return; }
          setMode("normal");
          setTransport("stopped");
          return;
        }
        if (key === "x" && !mods.shift) {
          setFxOpen((open) => !open);
          return;
        }
        if (key === "[" || key === "]") {
          const order: FxTab[] = [0, 1, 2, 3, "master"];
          setFxOpen(true);
          setFxTab((current) => {
            const index = Math.max(0, order.indexOf(current));
            const next = (index + (key === "]" ? 1 : order.length - 1)) % order.length;
            return order[next];
          });
          return;
        }
        if (key === " ") {
          setTransport((s) => (s === "playing" ? "stopped" : "playing"));
          showMsg(transport === "playing" ? "Stopped" : "Playing");
          return;
        }
        if (key === "r" && !mods.shift) {
          const next = transport === "recording" ? "stopped" : "recording";
          setTransport(next);
          if (tauriMode) {
            if (next === "recording") {
              tauriInvoke("start_recording").catch((e: string) => showMsg(`Record: ${e}`));
            } else {
              tauriInvoke("stop_recording").catch(() => {});
            }
          }
          showMsg(next === "recording" ? "Recording" : "Stopped");
          return;
        }
        if (key === "j" && !mods.shift) {
          setSelectedTrack((s) => Math.min(s + 1, tracks.length - 1));
          return;
        }
        if (key === "k" && !mods.shift) {
          setSelectedTrack((s) => Math.max(s - 1, 0));
          return;
        }
        if (key === "J" || (key === "j" && mods.shift)) {
          setTracks((ts) =>
            ts.map((t, i) =>
              i === selectedTrack ? { ...t, level: Math.min(1, t.level + 0.05) } : t,
            ),
          );
          return;
        }
        if (key === "K" || (key === "k" && mods.shift)) {
          setTracks((ts) =>
            ts.map((t, i) =>
              i === selectedTrack ? { ...t, level: Math.max(0, t.level - 0.05) } : t,
            ),
          );
          return;
        }
        const num = Number(key);
        if (num >= 1 && num <= 4) {
          setTracks((ts) =>
            ts.map((t) => (t.id === num - 1 ? { ...t, armed: !t.armed } : t)),
          );
          showMsg(`Track ${num} ${tracks[num - 1]?.armed ? "disarmed" : "armed"}`);
          return;
        }
      },
      [cmdOpen, selectedTrack, tracks, transport, showMsg, fxOpen],
    ),
  );

  function handleArm(id: number) {
    setTracks((ts) => {
      const updated = ts.map((t) => (t.id === id ? { ...t, armed: !t.armed } : t));
      if (tauriMode) {
        const track = updated.find((t) => t.id === id);
        tauriInvoke("arm_track", {
          id,
          armed: track?.armed ?? false,
          channel: track?.inputChannel ?? 0,
        }).catch(() => {});
      }
      return updated;
    });
  }
  function handleChannel(id: number, channel: number) {
    setTracks((ts) => {
      const updated = ts.map((t) => (t.id === id ? { ...t, inputChannel: channel } : t));
      if (tauriMode) {
        const track = updated.find((t) => t.id === id);
        tauriInvoke("arm_track", {
          id,
          armed: track?.armed ?? false,
          channel,
        }).catch(() => {});
      }
      return updated;
    });
  }
  function handleSolo(id: number) {
    setTracks((ts) => ts.map((t) => (t.id === id ? { ...t, solo: !t.solo } : t)));
  }
  function handleMute(id: number) {
    setTracks((ts) => ts.map((t) => (t.id === id ? { ...t, muted: !t.muted } : t)));
  }
  function handleLevel(id: number, level: number) {
    setTracks((ts) => ts.map((t) => (t.id === id ? { ...t, level } : t)));
  }
  function handlePan(id: number, pan: number) {
    setTracks((ts) => ts.map((t) => (t.id === id ? { ...t, pan } : t)));
  }

  function handleBounce() {
    setBounce({ canUndo: true, inProgress: true });
    if (tauriMode) {
      tauriInvoke<MixRenderResult>("bounce_tracks", { settings: mixSettings })
        .then((result) => {
          setRenderInfo(result);
          showMsg(`Bounce · peak ${fmtDb(result.peakDb)} · ${result.durationSec.toFixed(1)}s`);
        })
        .catch((e: string) => showMsg(`Bounce failed: ${e}`));
    } else {
      setRenderInfo(demoRender(mixSettings));
      showMsg("Bounce (demo — no audio written)");
    }
    setTimeout(() => setBounce((b) => ({ ...b, inProgress: false })), 1500);
  }
  function handleUndo() {
    setBounce({ canUndo: false, inProgress: false });
    showMsg("Bounce undone");
  }
  function handlePlayback() {
    if (tauriMode) {
      tauriInvoke<MixRenderResult>("preview_mix", { settings: mixSettings })
        .then((result) => {
          setRenderInfo(result);
          setPlayhead(0);
          setPlaybackActive(true);
          showMsg(`Playing mix · peak ${fmtDb(result.peakDb)}`);
        })
        .catch((e: string) => showMsg(`Playback: ${e}`));
    } else {
      setRenderInfo(demoRender(mixSettings));
      setPlayhead(0);
      setPlaybackActive(true);
      showMsg("Playback (demo — no audio)");
    }
  }
  function handleStopPlayback() {
    if (tauriMode) tauriInvoke("stop_playback").catch(() => {});
    setPlaybackActive(false);
  }
  function handleCommand(cmd: string) {
    if (cmd === "w") showMsg("Project saved");
    else if (cmd === "bn") handleBounce();
    else if (cmd === "bu") handleUndo();
    else if (cmd === "rt") setRhythm((r) => ({ ...r, enabled: !r.enabled }));
    else if (cmd === "rm") {
      setTracks((ts) => ts.map((t) => ({ ...t, muted: true })));
      showMsg("All tracks muted");
    } else if (cmd === "rs") {
      setTracks((ts) =>
        ts.map((t) => (t.solo ? { ...t, solo: false } : { ...t, solo: true, armed: false })),
      );
      showMsg("Solo toggled");
    } else if (cmd === "h") showMsg("Help: j/k nav, J/K vol, 1-4 arm, Space play, R rec, x fx rack");
    else showMsg(`Unknown: ${cmd}`);
  }



  return (
    <div className="app">
      <div className="app__main">
        <TransportBar
          state={transport}
          mode={mode}
          bpm={bpm}
          position={position}
          recordingTime={transport === "recording" ? recordingTime : undefined}
          onPlay={() => { setTransport((s) => (s === "playing" ? "stopped" : "playing")); showMsg(transport === "playing" ? "Stopped" : "Playing"); }}
          onStop={() => { setTransport("stopped"); showMsg("Stopped"); }}
          onRecord={() => {
            const next = transport === "recording" ? "stopped" : "recording";
            setTransport(next);
            if (tauriMode) {
              if (next === "recording") {
                tauriInvoke("start_recording").catch((e: string) => showMsg(`Record: ${e}`));
              } else {
                tauriInvoke("stop_recording").catch(() => {});
              }
            }
            showMsg(next === "recording" ? "Recording" : "Stopped");
          }}
          onBpmChange={setBpm}
        />

        <div className="app__tracks">
          {tracks.map((track, i) => {
            const showLive = captureActive && levels;
            let meterLevel = track.level;
            if (showLive) {
              const raw = levels!.input_peaks[track.inputChannel] ?? -96;
              meterLevel = Math.max(dbToLinear(raw), 0);
            }
            const liveTrack = { ...track, level: meterLevel };
            return (
              <TrackStrip
                key={track.id}
                track={liveTrack}
                index={i}
                selected={selectedTrack === i}
                transportState={transport}
                channelCount={channelCount}
                fx={fx.tracks[i]}
                onArm={handleArm}
                onSolo={handleSolo}
                onMute={handleMute}
                onLevelChange={handleLevel}
                onPanChange={handlePan}
                onChannelChange={handleChannel}
                onSelect={setSelectedTrack}
                onOpenFx={(id) => {
                  setSelectedTrack(id);
                  setFxTab(id);
                  setFxOpen(true);
                }}
              />
            );
          })}
        </div>

        <FxRack
          open={fxOpen}
          tab={fxTab}
          state={fx}
          tracks={tracks}
          bpm={bpm}
          meters={meters}
          onTabChange={setFxTab}
          onChange={setFx}
          onClose={() => setFxOpen(false)}
        />

        <BounceSection
          canUndo={bounce.canUndo}
          inProgress={bounce.inProgress}
          playing={playbackActive}
          onBounce={handleBounce}
          onUndo={handleUndo}
          onPlay={handlePlayback}
          onStopPlayback={handleStopPlayback}
        />
      </div>

      <aside className="app__sidebar">
        <div className="sidebar__section">
          <span className="sidebar__title">AUDIO INPUT</span>
          <div className="sidebar__item">
            <select
              className="sidebar__select"
              value={selectedDevice}
              onChange={(e) => setSelectedDevice(e.target.value)}
              disabled={captureActive || !tauriMode}
              aria-label="Select audio input device"
            >
              <option value="">{tauriMode ? "Select..." : "Browser mode"}</option>
              {devices.map((d) => (
                <option key={d.id} value={d.name}>
                  {d.name}{d.is_default ? " *" : ""} ({d.input_channels}ch)
                </option>
              ))}
            </select>
          </div>
          <button
            className={`sidebar__btn ${captureActive ? "sidebar__btn--active" : ""}`}
            onClick={toggleCapture}
            disabled={tauriMode && !captureActive && !selectedDevice}
            aria-label={captureActive ? "Stop capture" : "Start capture"}
          >
            {captureActive ? "■ STOP" : "● CAPTURE"}
          </button>
          {captureActive && levels && (
            <div className="sidebar__section">
              <span className="sidebar__title">LIVE LEVELS</span>
              {levels.input_peaks.map((peak, i) => (
                <div className="sidebar__item" key={i}>
                  <span className="sidebar__label">IN {i + 1}</span>
                  <span className={`sidebar__value sidebar__value--mono ${peak > -3 ? "sidebar__value--warn" : ""}`}>
                    {peak.toFixed(1)} dB
                  </span>
                </div>
              ))}
            </div>
          )}
        </div>

        {(captureActive || transport === "recording") && (
          <div className="sidebar__section">
            <span className="sidebar__title">RECORDING</span>
            <div className="sidebar__item">
              <span className="sidebar__label">Time</span>
              <span className="sidebar__value">
                {transport === "recording" ? fmtTime(recordingTime) : "—"}
              </span>
            </div>
            <div className="sidebar__item">
              <span className="sidebar__label">Output</span>
              <span className="sidebar__value">{"/tmp/tracker_recordings/"}</span>
            </div>
            <div className="sidebar__item">
              <span className="sidebar__label">Armed</span>
              <span className="sidebar__value">
                {tracks.filter((t) => t.armed).map((t) => t.id + 1).join(", ") || "none"}
              </span>
            </div>
          </div>
        )}

        {levels && (levels.metrics.underruns > 0 || levels.metrics.overruns > 0) && (
          <div className="sidebar__section">
            <span className="sidebar__title">PERF</span>
            <div className="sidebar__item">
              <span className="sidebar__label">Xruns</span>
              <span className="sidebar__value sidebar__value--warn">
                {levels.metrics.underruns}u · {levels.metrics.overruns}o
              </span>
            </div>
          </div>
        )}

        <div className="sidebar__section">
          <span className="sidebar__title">SESSION</span>
          <div className="sidebar__item">
            <span className="sidebar__label">Format</span>
            <span className="sidebar__value">WAV 48k 32-bit</span>
          </div>
          <div className="sidebar__item">
            <span className="sidebar__label">Armed tracks</span>
            <span className="sidebar__value">{tracks.filter((t) => t.armed).length}/4</span>
          </div>
        </div>

        <div className="sidebar__section">
          <span className="sidebar__title">FX</span>
          <button
            className={`sidebar__btn ${fxOpen ? "sidebar__btn--active" : ""}`}
            onClick={() => setFxOpen((open) => !open)}
            aria-pressed={fxOpen}
          >
            {fxOpen ? "■ CLOSE RACK" : "▤ OPEN RACK · x"}
          </button>
          <div className="sidebar__item">
            <span className="sidebar__label">Track {selectedTrack + 1}</span>
            <span className="sidebar__value">
              {trackFxBadges(fx.tracks[selectedTrack]).join(" · ") || "clean"}
            </span>
          </div>
          <div className="sidebar__item">
            <span className="sidebar__label">Master</span>
            <span className="sidebar__value">
              {fx.limiter.enabled ? "LIM" : "—"}
              {fx.reverb.enabled ? " · REV" : ""}
              {fx.delay.enabled ? " · DLY" : ""}
              {fx.width.enabled ? " · WIDTH" : ""}
            </span>
          </div>
          {renderInfo ? (
            <div className="sidebar__item">
              <span className="sidebar__label">Last render</span>
              <span className="sidebar__value sidebar__value--mono">
                {fmtDb(renderInfo.peakDb)} peak
              </span>
            </div>
          ) : null}
        </div>
      </aside>

      <footer className="app__footer">
        <VimStatusLine
          mode={mode}
          message={statusMsg}
          recording={transport === "recording"}
          captureActive={captureActive}
          armedTracks={tracks.filter(t => t.armed).length}
        />
        <RhythmSection
          enabled={rhythm.enabled}
          pattern={rhythm.pattern}
          tempo={rhythm.tempo}
          onToggle={() => setRhythm((r) => ({ ...r, enabled: !r.enabled }))}
          onPatternChange={(p) => setRhythm((r) => ({ ...r, pattern: p, patternName: p }))}
          onTempoChange={(t) => setRhythm((r) => ({ ...r, tempo: t }))}
        />
      </footer>

      <CommandPalette
        open={cmdOpen}
        onClose={() => setCmdOpen(false)}
        onCommand={handleCommand}
      />

      <style>{`
        .app {
          display: flex;
          flex-direction: column;
          height: 100vh;
          width: 100vw;
          overflow: hidden;
          background: var(--bg);
        }
        .app__main {
          flex: 1;
          display: flex;
          flex-direction: column;
          overflow: hidden;
        }
        .app__tracks {
          display: flex;
          gap: var(--space-2);
          padding: var(--space-3);
          flex: 1;
          overflow-x: auto;
          overflow-y: hidden;
        }
        .app__sidebar {
          position: absolute;
          right: 0;
          top: 0;
          bottom: 0;
          width: 8px;
          background: var(--surface);
          border-left: 1px solid var(--border);
          padding: 0;
          display: flex;
          flex-direction: column;
          gap: var(--space-5);
          overflow: hidden;
          transition: width var(--duration-normal) var(--ease-out), padding var(--duration-normal) var(--ease-out);
          z-index: 10;
        }
        /* Keep the collapsed rail clean: content only paints once it is open. */
        .app__sidebar > * {
          opacity: 0;
          transition: opacity var(--duration-fast) var(--ease-out) 60ms;
        }
        .app__sidebar:hover > *,
        .app__sidebar:focus-within > *,
        .app__sidebar.sidebar--open > * {
          opacity: 1;
        }
        .app__sidebar:hover,
        .app__sidebar:focus-within,
        .app__sidebar.sidebar--open {
          width: 220px;
          padding: var(--space-3);
          overflow-y: auto;
        }
        /* Visible grip indicator at the right edge */
        .app__sidebar::after {
          content: '';
          position: absolute;
          left: 2px;
          top: 50%;
          width: 3px;
          height: 40px;
          background: var(--border);
          border-radius: 2px;
          transform: translateY(-50%);
          opacity: 0.6;
          pointer-events: none;
        }
        .app__sidebar:hover::after,
        .app__sidebar:focus-within::after {
          opacity: 0;
        }
        .sidebar__title {
          font-size: var(--text-label);
          font-weight: 700;
          letter-spacing: var(--tracking-label);
          color: var(--amber);
          margin-bottom: var(--space-2);
          display: block;
        }
        .sidebar__item {
          display: flex;
          flex-direction: column;
          gap: 2px;
          padding: var(--space-1) 0;
        }
        .sidebar__label { font-size: var(--text-caption); color: var(--ink-muted); }
        .sidebar__value { font-size: var(--text-label); color: var(--ink-dim); }
        .sidebar__value--warn { color: var(--amber); }
        .sidebar__value--mono { font-family: var(--font-mono); font-variant-numeric: tabular-nums; }
        .sidebar__select {
          font-family: var(--font-mono);
          font-size: var(--text-caption);
          padding: var(--space-1) var(--space-5) var(--space-1) var(--space-1);
          background-color: var(--bg);
          background-image:
            linear-gradient(45deg, transparent 50%, var(--amber) 50%),
            linear-gradient(135deg, var(--amber) 50%, transparent 50%);
          background-position: calc(100% - 11px) calc(50% + 1px), calc(100% - 7px) calc(50% + 1px);
          background-size: 4px 4px;
          background-repeat: no-repeat;
          border: 1px solid var(--border);
          border-radius: var(--radius-sm);
          color: var(--ink);
          width: 100%;
          appearance: none;
          -webkit-appearance: none;
          cursor: pointer;
          text-overflow: ellipsis;
        }
        .sidebar__select:hover:not(:disabled) { border-color: var(--amber-dim); }
        .sidebar__select:focus-visible { outline: 1px solid var(--amber); outline-offset: 1px; }
        .sidebar__select option { background: var(--surface-raised); color: var(--ink); }
        .sidebar__select:disabled { opacity: 0.5; cursor: default; }
        .sidebar__btn {
          font-family: var(--font-mono);
          font-size: var(--text-label);
          font-weight: 600;
          letter-spacing: var(--tracking-label);
          padding: var(--space-1) var(--space-3);
          border: 1px solid var(--amber);
          border-radius: var(--radius-sm);
          color: var(--amber);
          background: transparent;
          width: 100%;
          margin-top: var(--space-1);
          transition: all var(--duration-fast) var(--ease-out);
        }
        .sidebar__btn:hover:not(:disabled) { background: var(--amber-bg); }
        .sidebar__btn:disabled { opacity: 0.4; border-color: var(--border); color: var(--ink-muted); cursor: default; }
        .sidebar__btn--active { background: var(--red); border-color: var(--red); color: var(--ink); animation: pulse-glow 1s ease-in-out infinite; }
        .app__footer {
          border-top: 1px solid var(--border);
          display: flex;
          flex-direction: column;
        }
        @media (max-width: 600px) {
          .app__tracks { flex-direction: column; overflow-y: auto; overflow-x: hidden; }
          .app__sidebar { display: none; }
        }
      `}</style>
    </div>
  );
}

function dbToLinear(db: number): number {
  return Math.pow(10, db / 20);
}
function linearToDb(lin: number): number {
  return lin <= 0 ? -96 : Math.max(-96, 20 * Math.log10(lin));
}
function fmtTime(s: number): string {
  const m = Math.floor(s / 60);
  const sec = Math.floor(s % 60);
  const ms = Math.floor((s % 1) * 100);
  return `${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")}.${String(ms).padStart(2, "0")}`;
}

/**
 * Browser-mode stand-in for the Rust render: plausible meters so the rack is
 * fully testable without an audio device. Never used in the desktop app.
 */
function demoRender(mix: MixSettings): MixRenderResult {
  const durationSec = 14;
  const points = Math.floor(durationSec * 20);
  const trackPeak = mix.tracks.map((track, i) =>
    track.comp.enabled ? -(2 + ((i * 1.7) % 4)) : 0,
  );
  const trackGrTimeline = mix.tracks.map((track, i) => {
    const depth = trackPeak[i];
    return Array.from({ length: points }, (_, p) => {
      if (!track.comp.enabled || depth === 0) return 0;
      const envelope = 0.25 + 0.75 * Math.abs(Math.sin((p / 20) * 0.9 + i * 0.8));
      return depth * envelope;
    });
  });
  const masterGr = mix.masterComp.enabled ? -2.4 : 0;
  const limiterGr = mix.limiter.enabled ? -1.2 : 0;
  const masterGrTimeline = Array.from({ length: points }, (_, p) =>
    masterGr === 0 ? 0 : masterGr * (0.3 + 0.7 * Math.abs(Math.sin((p / 20) * 1.1))),
  );
  const limiterGrTimeline = Array.from({ length: points }, (_, p) =>
    limiterGr === 0 ? 0 : limiterGr * (0.2 + 0.8 * Math.abs(Math.sin((p / 20) * 1.3 + 0.4))),
  );
  return {
    path: null,
    frames: durationSec * 48_000,
    durationSec,
    peakDb: mix.limiter.ceilingDb,
    trackGr: trackPeak,
    masterGr,
    limiterGr,
    trackGrTimeline,
    masterGrTimeline,
    limiterGrTimeline,
  };
}
