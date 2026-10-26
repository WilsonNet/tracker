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
  const [ioOpen, setIoOpen] = useState(false);
  const [renderInfo, setRenderInfo] = useState<MixRenderResult | null>(null);
  const [playhead, setPlayhead] = useState(0);

  const currentDevice = useMemo(
    () => devices.find((d) => d.name === selectedDevice),
    [devices, selectedDevice],
  );

  const channelCount = tauriMode
    ? currentDevice?.input_channels ?? 2
    : 2;

  const channelNames = useMemo(() => {
    if (tauriMode && currentDevice?.channel_names?.length) {
      return currentDevice.channel_names;
    }
    return Array.from({ length: channelCount }, (_, i) => `IN ${i + 1}`);
  }, [tauriMode, currentDevice, channelCount]);

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

  const refreshDevices = useCallback(() => {
    if (!tauriMode) return;
    tauriInvoke<AudioDeviceInfo[]>("list_audio_devices")
      .then((d) => {
        setDevices(d);
        setSelectedDevice((prev) => {
          if (prev && d.some((dd) => dd.name === prev)) return prev;
          const def = d.find((dd) => dd.is_default) ?? d[0];
          return def ? def.name : "";
        });
      })
      .catch(() => {});
  }, [tauriMode]);

  useEffect(() => {
    refreshDevices();
  }, [refreshDevices]);

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

  // Clamp per-track input channel when the selected device has fewer channels, and sync with Rust
  useEffect(() => {
    if (!tauriMode || !selectedDevice) return;
    setTracks((ts) =>
      ts.map((t) => {
        const clamped = t.inputChannel >= channelCount ? Math.max(0, channelCount - 1) : t.inputChannel;
        if (clamped !== t.inputChannel) {
          tauriInvoke("arm_track", { id: t.id, armed: t.armed, channel: clamped }).catch(() => {});
          return { ...t, inputChannel: clamped };
        }
        return t;
      }),
    );
  }, [channelCount, tauriMode, selectedDevice]);

  const showMsg = useCallback((msg: string) => {
    setStatusMsg(msg);
    setTimeout(() => setStatusMsg(""), 3000);
  }, []);

  const ensureCapture = useCallback(
    async (deviceOverride?: string): Promise<boolean> => {
      const targetDevice = deviceOverride ?? selectedDevice;
      if (!tauriMode) {
        if (!captureActive) setCaptureActive(true);
        return true;
      }
      if (captureActive && !deviceOverride) return true;
      const dev = targetDevice || devices.find((d) => d.is_default)?.name || devices[0]?.name || "";
      if (!dev) {
        showMsg("No audio input device available");
        return false;
      }
      if (dev !== selectedDevice) setSelectedDevice(dev);
      try {
        await tauriInvoke("start_capture", { deviceName: dev });
        setCaptureActive(true);
        return true;
      } catch (e) {
        showMsg(`Capture failed: ${String(e)}`);
        return false;
      }
    },
    [tauriMode, captureActive, selectedDevice, devices, showMsg],
  );

  function handleSelectDevice(nextDevice: string) {
    setSelectedDevice(nextDevice);
    if (!nextDevice) return;
    if (captureActive && tauriMode) {
      tauriInvoke("start_capture", { deviceName: nextDevice })
        .then(() => {
          setCaptureActive(true);
          showMsg(`Input switched: ${nextDevice}`);
        })
        .catch((e: string) => showMsg(`Input switch failed: ${e}`));
    }
  }

  function toggleCapture() {
    if (captureActive) {
      if (tauriMode) tauriInvoke("stop_capture").catch(() => {});
      setCaptureActive(false);
      setLevels(null);
      showMsg("Monitor stopped");
    } else {
      if (tauriMode && !selectedDevice) { showMsg("No device selected"); return; }
      ensureCapture().then((ok) => {
        if (ok) showMsg(tauriMode ? `Monitoring ${selectedDevice}` : "Demo mode — simulated levels");
      });
    }
  }

  const toggleRecording = useCallback(async () => {
    if (transport === "recording") {
      setTransport("stopped");
      if (tauriMode) {
        await tauriInvoke("stop_recording").catch(() => {});
      }
      showMsg("Recording stopped · saved to disk");
      return;
    }

    // Auto-arm selected track if no tracks are armed
    let currentTracks = tracks;
    if (!currentTracks.some((t) => t.armed)) {
      const targetId = selectedTrack;
      currentTracks = currentTracks.map((t) =>
        t.id === targetId ? { ...t, armed: true } : t,
      );
      setTracks(currentTracks);
      if (tauriMode) {
        const tr = currentTracks.find((t) => t.id === targetId);
        await tauriInvoke("arm_track", {
          id: targetId,
          armed: true,
          channel: tr?.inputChannel ?? 0,
        }).catch(() => {});
      }
    } else if (tauriMode) {
      // Ensure backend has latest arm states & channels synced
      for (const tr of currentTracks) {
        await tauriInvoke("arm_track", {
          id: tr.id,
          armed: tr.armed,
          channel: tr.inputChannel,
        }).catch(() => {});
      }
    }

    // Auto-start capture if not already running
    const capOk = await ensureCapture();
    if (!capOk) return;

    setTransport("recording");
    if (tauriMode) {
      try {
        await tauriInvoke("start_recording");
        const armedList = currentTracks
          .filter((t) => t.armed)
          .map((t) => `T${t.id + 1}(IN${t.inputChannel + 1})`)
          .join(", ");
        showMsg(`Recording ${armedList}`);
      } catch (e) {
        showMsg(`Record failed: ${String(e)}`);
        setTransport("stopped");
      }
    } else {
      showMsg("Recording");
    }
  }, [transport, tauriMode, tracks, selectedTrack, ensureCapture, showMsg]);

  useVimKeyboard(
    useCallback(
      (key, mods) => {
        if (cmdOpen) return;
        if (key === ":") { setCmdOpen(true); return; }
        if (key === "Escape") {
          if (fxOpen) { setFxOpen(false); return; }
          if (ioOpen) { setIoOpen(false); return; }
          if (transport === "recording" && tauriMode) {
            tauriInvoke("stop_recording").catch(() => {});
          }
          setMode("normal");
          setTransport("stopped");
          return;
        }
        if (key === "x" && !mods.shift) {
          setFxOpen((open) => !open);
          return;
        }
        if (key === "i" && !mods.shift) {
          setIoOpen((open) => !open);
          return;
        }
        if (key === "c" && !mods.shift) {
          toggleCapture();
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
          toggleRecording();
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
          handleArm(num - 1);
          showMsg(`Track ${num} ${tracks[num - 1]?.armed ? "disarmed" : "armed"}`);
          return;
        }
      },
      [cmdOpen, selectedTrack, tracks, transport, showMsg, fxOpen, ioOpen, tauriMode, toggleRecording],
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
    } else if (cmd === "h") showMsg("Help: j/k nav, J/K vol, 1-4 arm, Space play, R rec, x fx rack, i input");
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
          onStop={() => {
            if (transport === "recording" && tauriMode) {
              tauriInvoke("stop_recording").catch(() => {});
            }
            setTransport("stopped");
            showMsg("Stopped");
          }}
          onRecord={toggleRecording}
          onBpmChange={setBpm}
          ioOpen={ioOpen}
          onToggleIo={() => setIoOpen((open) => !open)}
          activeDeviceName={selectedDevice || (tauriMode ? "No Input" : "Demo Input")}
          captureActive={captureActive}
          onToggleCapture={toggleCapture}
        />
        <div className="app__workspace">
          <div className="app__tracks">
            {tracks.map((track, i) => {
              const showLive = captureActive && levels;
              let liveMeter: number | undefined;
              if (showLive) {
                const raw = levels!.input_peaks[track.inputChannel] ?? -96;
                liveMeter = Math.max(dbToLinear(raw), 0);
              }
              return (
                <TrackStrip
                  key={track.id}
                  track={track}
                  index={i}
                  selected={selectedTrack === i}
                  transportState={transport}
                  channelCount={channelCount}
                  channelNames={channelNames}
                  meterLevel={liveMeter}
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
          <aside className={`app__sidebar ${ioOpen ? "sidebar--open" : ""}`}>
            {ioOpen ? (
              <div className="sidebar__top">
                <span className="sidebar__title">I/O</span>
                <button
                  type="button"
                  className="sidebar__close"
                  onClick={() => setIoOpen(false)}
                  aria-label="Close input panel"
                  title="Close (i)"
                >
                  ✕
                </button>
              </div>
            ) : null}
            <div className="sidebar__section">
              <div className="sidebar__head-row">
                <span className="sidebar__title">AUDIO INPUT</span>
                {tauriMode ? (
                  <button
                    type="button"
                    className="sidebar__refresh"
                    onClick={refreshDevices}
                    title="Refresh audio devices"
                    aria-label="Refresh audio devices"
                  >
                    ↻
                  </button>
                ) : null}
              </div>
              <div className="sidebar__item">
                <select
                  className="sidebar__select"
                  value={selectedDevice}
                  onChange={(e) => handleSelectDevice(e.target.value)}
                  disabled={!tauriMode}
                  aria-label="Select audio input device"
                >
                  <option value="">{tauriMode ? "Select..." : "Browser mode (2ch)"}</option>
                  {devices.map((d) => (
                    <option key={d.id} value={d.name}>
                      {d.name}{d.is_default ? " ★" : ""} ({d.input_channels}ch)
                    </option>
                  ))}
                </select>
              </div>
              {currentDevice?.backend ? (
                <div className="sidebar__meta">
                  <span>{currentDevice.backend}</span>
                  <span>{channelCount} IN</span>
                </div>
              ) : null}
              <button
                className={`sidebar__btn ${captureActive ? "sidebar__btn--active" : ""}`}
                onClick={toggleCapture}
                disabled={tauriMode && !captureActive && !selectedDevice}
                aria-label={captureActive ? "Stop capture" : "Start capture"}
              >
                {captureActive ? "■ STOP MONITOR" : "● CAPTURE / MONITOR"}
              </button>
            </div>

            <div className="sidebar__section">
              <span className="sidebar__title">INPUT ROUTING MATRIX</span>
              <div className="io-matrix" role="group" aria-label="Track input routing matrix">
                <div className="io-matrix__head">
                  <span className="io-matrix__col-trk">TRK</span>
                  <div className="io-matrix__cols">
                    {Array.from({ length: Math.max(channelCount, 1) }, (_, chIdx) => (
                      <span
                        key={chIdx}
                        className="io-matrix__col-in"
                        title={channelNames[chIdx] ?? `IN ${chIdx + 1}`}
                      >
                        IN {chIdx + 1}
                      </span>
                    ))}
                  </div>
                  <span className="io-matrix__col-arm">ARM</span>
                </div>
                {tracks.map((tr) => (
                  <div key={tr.id} className={`io-matrix__row ${tr.armed ? "io-matrix__row--armed" : ""}`}>
                    <span className="io-matrix__trk">T{tr.id + 1}</span>
                    <div className="io-matrix__cells">
                      {Array.from({ length: Math.max(channelCount, 1) }, (_, chIdx) => {
                        const routed = tr.inputChannel === chIdx;
                        return (
                          <button
                            key={chIdx}
                            type="button"
                            className={`io-matrix__cell ${routed ? "io-matrix__cell--active" : ""}`}
                            onClick={() => handleChannel(tr.id, chIdx)}
                            aria-pressed={routed}
                            aria-label={`Route Track ${tr.id + 1} to Input ${chIdx + 1}`}
                            title={`Route Track ${tr.id + 1} ← ${channelNames[chIdx] ?? `IN ${chIdx + 1}`}`}
                          >
                            {routed ? "●" : "·"}
                          </button>
                        );
                      })}
                    </div>
                    <button
                      type="button"
                      className={`io-matrix__arm ${tr.armed ? "io-matrix__arm--on" : ""}`}
                      onClick={() => handleArm(tr.id)}
                      aria-pressed={tr.armed}
                      aria-label={`Matrix arm track ${tr.id + 1}`}
                      title={`Arm Track ${tr.id + 1}`}
                    >
                      {tr.armed ? "REC" : "ARM"}
                    </button>
                  </div>
                ))}
              </div>
            </div>

            {captureActive && levels && (
              <div className="sidebar__section">
                <span className="sidebar__title">LIVE LEVELS</span>
                <div className="io-levels">
                  {levels.input_peaks.map((peak, i) => {
                    const pct = Math.max(0, Math.min(100, ((peak + 60) / 60) * 100));
                    const label = channelNames[i] && channelNames[i] !== `IN ${i + 1}`
                      ? `IN ${i + 1} · ${channelNames[i]}`
                      : `IN ${i + 1}`;
                    return (
                      <div className="io-levels__row" key={i}>
                        <div className="io-levels__top">
                          <span className="sidebar__label" title={label}>{label}</span>
                          <span className={`sidebar__value sidebar__value--mono ${peak > -3 ? "sidebar__value--warn" : ""}`}>
                            {peak <= -90 ? "−∞" : `${peak.toFixed(1)}`} dB
                          </span>
                        </div>
                        <div className="io-levels__bar">
                          <div
                            className={`io-levels__fill ${peak > -3 ? "io-levels__fill--clip" : ""}`}
                            style={{ width: `${pct}%` }}
                          />
                        </div>
                      </div>
                    );
                  })}
                </div>
              </div>
            )}

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
        </div>
      </div>

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
          min-height: 0;
        }
        .app__workspace {
          position: relative;
          flex: 1;
          display: flex;
          flex-direction: column;
          min-height: 0;
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
          width: 268px;
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
        .sidebar__head-row {
          display: flex;
          align-items: center;
          justify-content: space-between;
          margin-bottom: var(--space-2);
        }
        .sidebar__head-row .sidebar__title {
          margin-bottom: 0;
        }
        .sidebar__refresh {
          font-family: var(--font-mono);
          font-size: var(--text-label);
          color: var(--ink-muted);
          padding: 1px 5px;
          border: 1px solid var(--border);
          border-radius: var(--radius-sm);
          line-height: 1.2;
        }
        .sidebar__refresh:hover {
          color: var(--amber);
          border-color: var(--amber-dim);
          background: var(--surface-raised);
        }
        .sidebar__meta {
          display: flex;
          align-items: center;
          justify-content: space-between;
          font-size: 0.625rem;
          color: var(--ink-muted);
          letter-spacing: 0.04em;
          padding: 2px 0 var(--space-1);
        }
        .io-matrix {
          display: flex;
          flex-direction: column;
          gap: 3px;
          background: var(--bg);
          border: 1px solid var(--border-subtle);
          border-radius: var(--radius-sm);
          padding: var(--space-2);
        }
        .io-matrix__head {
          display: flex;
          align-items: center;
          gap: var(--space-1);
          font-size: 0.5625rem;
          font-weight: 700;
          letter-spacing: 0.06em;
          color: var(--ink-muted);
          padding-bottom: 3px;
          border-bottom: 1px solid var(--border-subtle);
        }
        .io-matrix__col-trk {
          width: 24px;
        }
        .io-matrix__cols {
          display: flex;
          flex: 1;
          gap: 3px;
        }
        .io-matrix__col-in {
          flex: 1;
          text-align: center;
          overflow: hidden;
          text-overflow: ellipsis;
          white-space: nowrap;
        }
        .io-matrix__col-arm {
          width: 34px;
          text-align: right;
        }
        .io-matrix__row {
          display: flex;
          align-items: center;
          gap: var(--space-1);
          padding: 2px 0;
        }
        .io-matrix__trk {
          width: 24px;
          font-size: var(--text-caption);
          font-weight: 600;
          color: var(--ink-dim);
        }
        .io-matrix__row--armed .io-matrix__trk {
          color: var(--red);
        }
        .io-matrix__cells {
          display: flex;
          flex: 1;
          gap: 3px;
        }
        .io-matrix__cell {
          flex: 1;
          height: 20px;
          font-family: var(--font-mono);
          font-size: var(--text-caption);
          font-weight: 700;
          color: var(--ink-muted);
          background: var(--surface);
          border: 1px solid var(--border);
          border-radius: var(--radius-sm);
          transition: all var(--duration-fast) var(--ease-out);
        }
        .io-matrix__cell:hover {
          color: var(--ink);
          border-color: var(--amber-dim);
        }
        .io-matrix__cell--active {
          color: var(--ink);
          background: var(--amber);
          border-color: var(--amber);
        }
        .io-matrix__arm {
          width: 34px;
          height: 20px;
          font-family: var(--font-mono);
          font-size: 0.5625rem;
          font-weight: 700;
          letter-spacing: 0.04em;
          color: var(--red);
          border: 1px solid var(--border);
          border-radius: var(--radius-sm);
          background: transparent;
          transition: all var(--duration-fast) var(--ease-out);
        }
        .io-matrix__arm:hover {
          border-color: var(--red);
          background: var(--red-bg);
        }
        .io-matrix__arm--on {
          color: var(--ink);
          background: var(--red);
          border-color: var(--red);
        }
        .io-levels {
          display: flex;
          flex-direction: column;
          gap: 6px;
        }
        .io-levels__row {
          display: flex;
          flex-direction: column;
          gap: 2px;
        }
        .io-levels__top {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: var(--space-1);
        }
        .io-levels__top .sidebar__label {
          overflow: hidden;
          text-overflow: ellipsis;
          white-space: nowrap;
        }
        .io-levels__bar {
          height: 4px;
          background: var(--bg);
          border-radius: 1px;
          overflow: hidden;
          border: 1px solid var(--border-subtle);
        }
        .io-levels__fill {
          height: 100%;
          background: var(--amber);
          transition: width 60ms linear;
        }
        .io-levels__fill--clip {
          background: var(--red);
        }
        .sidebar__title {
          font-size: var(--text-label);
          font-weight: 700;
          letter-spacing: var(--tracking-label);
          color: var(--amber);
          margin-bottom: var(--space-2);
          display: block;
        }
        .sidebar__top {
          display: flex;
          align-items: center;
          justify-content: space-between;
        }
        .sidebar__top .sidebar__title { margin-bottom: 0; }
        .sidebar__close {
          color: var(--ink-muted);
          font-size: var(--text-caption);
          line-height: 1;
          padding: 2px 3px;
          border-radius: var(--radius-sm);
        }
        .sidebar__close:hover { color: var(--ink); background: var(--surface-raised); }
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
