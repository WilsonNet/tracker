import type { TrackData } from "../types/types.ts";
import { LevelMeter } from "./LevelMeter.tsx";
import { Knob } from "./Knob.tsx";
import type { TrackFxSettings } from "../lib/fx.ts";
import { trackFxBadges } from "../lib/fx.ts";

interface TrackStripProps {
  track: TrackData;
  index: number;
  selected: boolean;
  transportState: "stopped" | "playing" | "recording";
  channelCount: number;
  channelNames?: string[];
  meterLevel?: number;
  fx: TrackFxSettings;
  onArm: (id: number) => void;
  onSolo: (id: number) => void;
  onMute: (id: number) => void;
  onLevelChange: (id: number, level: number) => void;
  onPanChange: (id: number, pan: number) => void;
  onChannelChange: (id: number, channel: number) => void;
  onSelect: (id: number) => void;
  onOpenFx: (id: number) => void;
}

export function TrackStrip({
  track,
  index,
  selected,
  transportState,
  channelCount,
  channelNames,
  meterLevel,
  fx,
  onArm,
  onSolo,
  onMute,
  onLevelChange,
  onPanChange,
  onChannelChange,
  onSelect,
  onOpenFx,
}: TrackStripProps) {
  const isActive = !track.muted && (selected || track.armed || transportState !== "stopped" || meterLevel !== undefined);
  const isRecording = transportState === "recording" && track.armed;
  const badges = trackFxBadges(fx);
  const effectiveMeter = meterLevel !== undefined ? meterLevel : track.level * 0.9;
  const chCount = Math.max(channelCount, 1);

  return (
    <div
      className={`track ${selected ? "track--selected" : ""} ${track.armed ? "track--armed" : ""} ${isRecording ? "track--recording" : ""}`}
      onClick={() => onSelect(track.id)}
      role="region"
      aria-label={`Track ${index + 1}: ${track.name}`}
      tabIndex={0}
      onKeyDown={(e) => { if (e.key === "Enter") onSelect(track.id); }}
    >
      <div className="track__header">
        <span className="track__number">{String(index + 1).padStart(2, "0")}</span>
        <span className="track__name">{track.name}</span>
        <div className="track__input" onClick={(e) => e.stopPropagation()}>
          <span className="track__input-label">IN</span>
          <div className="track__input-pills" role="group" aria-label={`Input channel buttons track ${index + 1}`}>
            {Array.from({ length: Math.min(chCount, 4) }, (_, i) => {
              const chTitle = channelNames?.[i] ? `IN ${i + 1}: ${channelNames[i]}` : `Input ${i + 1}`;
              const active = track.inputChannel === i;
              return (
                <button
                  key={i}
                  type="button"
                  className={`track__in-pill ${active ? "track__in-pill--active" : ""}`}
                  onClick={() => onChannelChange(track.id, i)}
                  aria-pressed={active}
                  title={chTitle}
                >
                  {i + 1}
                </button>
              );
            })}
          </div>
          <select
            className={`track__input-select ${chCount <= 4 ? "track__input-select--compact" : ""}`}
            value={track.inputChannel}
            onChange={(e) => onChannelChange(track.id, Number(e.target.value))}
            aria-label={`Input channel track ${index + 1}`}
            title={channelNames?.[track.inputChannel] ?? `Input ${track.inputChannel + 1}`}
          >
            {Array.from({ length: chCount }, (_, i) => {
              const name = channelNames?.[i];
              return (
                <option key={i} value={i}>
                  {name && name !== `IN ${i + 1}` ? `${i + 1} · ${name}` : `${i + 1}`}
                </option>
              );
            })}
          </select>
        </div>
      </div>

      <button
        type="button"
        className={`track__fx ${badges.length > 0 ? "track__fx--active" : ""} ${selected ? "track__fx--selected" : ""}`}
        onClick={(e) => { e.stopPropagation(); onOpenFx(track.id); }}
        aria-label={`Open effects for track ${index + 1}`}
        title={`Effects · x opens the rack (${badges.join(" ") || "clean"})`}
      >
        <span className="track__fx-label">FX</span>
        <span className="track__fx-badges">{badges.join(" · ") || "CLEAN"}</span>
        <span className="track__fx-key">x</span>
      </button>

      <div className="track__controls">
        <div className="track__buttons">
          <button
            className={`ctrl-btn ctrl-btn--arm ${track.armed ? "ctrl-btn--on" : ""}`}
            onClick={(e) => { e.stopPropagation(); onArm(track.id); }}
            title={`Arm Track ${index + 1} (${index + 1})`}
            aria-pressed={track.armed}
            aria-label={`Arm track ${index + 1}`}
          >
            ARM
          </button>
          <button
            className={`ctrl-btn ctrl-btn--solo ${track.solo ? "ctrl-btn--on-solo" : ""}`}
            onClick={(e) => { e.stopPropagation(); onSolo(track.id); }}
            title={`Solo Track ${index + 1}`}
            aria-pressed={track.solo}
            aria-label={`Solo track ${index + 1}`}
          >
            SOLO
          </button>
          <button
            className={`ctrl-btn ctrl-btn--mute ${track.muted ? "ctrl-btn--on-mute" : ""}`}
            onClick={(e) => { e.stopPropagation(); onMute(track.id); }}
            title={`Mute Track ${index + 1}`}
            aria-pressed={track.muted}
            aria-label={`Mute track ${index + 1}`}
          >
            MUTE
          </button>
        </div>

        <div className="track__pan">
          <Knob
            value={track.pan}
            onChange={(v) => onPanChange(track.id, v)}
            label="PAN"
            ariaLabel={`Pan track ${index + 1}`}
            min={0}
            max={1}
            step={0.01}
            defaultValue={0.5}
            size="sm"
            format={(v) =>
              v < 0.49 ? `L${Math.round((0.5 - v) * 200)}` : v > 0.51 ? `R${Math.round((v - 0.5) * 200)}` : "C"
            }
          />
        </div>

        <div className="track__fader">
          <input
            type="range"
            min="0"
            max="1"
            step="0.01"
            value={track.level}
            onChange={(e) => onLevelChange(track.id, Number(e.target.value))}
            className="fader"
            aria-label={`Volume level track ${index + 1}`}
          />
          <span className="fader__value">
            {Math.round(levelToDb(track.level))}dB
          </span>
        </div>

        <div className="track__meter">
          <LevelMeter
            level={effectiveMeter}
            active={isActive}
            vertical
          />
        </div>
      </div>

      <style>{`
        .track {
          display: flex;
          flex-direction: column;
          gap: var(--space-2);
          padding: var(--space-3);
          background: var(--bg);
          border: 1px solid var(--border-subtle);
          border-radius: var(--radius-sm);
          cursor: pointer;
          transition: border-color var(--duration-fast) var(--ease-out),
                      background var(--duration-fast) var(--ease-out);
          min-width: 140px;
          flex: 1;
        }
        .track:hover {
          border-color: var(--border);
          background: var(--surface-hover);
        }
        .track--selected {
          border-color: var(--border-amber);
          background: var(--surface);
        }
        .track--armed {
          border-color: var(--amber-dim);
        }
        .track--recording {
          border-color: var(--red);
        }
        .track__header {
          display: flex;
          align-items: center;
          gap: var(--space-2);
        }
        .track__number {
          font-size: var(--text-label);
          font-weight: 600;
          color: var(--amber);
          letter-spacing: var(--tracking-label);
        }
        .track--recording .track__number {
          color: var(--red);
          animation: pulse-glow 1s ease-in-out infinite;
        }
        .track__name {
          font-size: var(--text-label);
          color: var(--ink);
          font-weight: 500;
        }
        .track__input {
          font-size: var(--text-caption);
          color: var(--ink-muted);
          margin-left: auto;
          display: flex;
          align-items: center;
          gap: 3px;
          letter-spacing: var(--tracking-label);
        }
        .track__input-label {
          font-size: 0.625rem;
          font-weight: 600;
          color: var(--ink-muted);
        }
        .track__input-pills {
          display: flex;
          align-items: center;
          gap: 2px;
        }
        .track__in-pill {
          font-family: var(--font-mono);
          font-size: 0.625rem;
          font-weight: 700;
          min-width: 18px;
          height: 18px;
          padding: 0 4px;
          border-radius: var(--radius-sm);
          border: 1px solid var(--border);
          background: var(--bg);
          color: var(--ink-muted);
          line-height: 1;
          transition: all var(--duration-fast) var(--ease-out);
        }
        .track__in-pill:hover {
          color: var(--ink);
          border-color: var(--amber-dim);
        }
        .track__in-pill--active {
          color: var(--ink);
          background: var(--amber);
          border-color: var(--amber);
        }
        .track__input-select {
          font-family: var(--font-mono);
          font-size: var(--text-caption);
          color: var(--amber);
          background-color: var(--bg);
          border: 1px solid var(--border);
          border-radius: var(--radius-sm);
          padding: 0 var(--space-4) 0 var(--space-1);
          appearance: none;
          -webkit-appearance: none;
          cursor: pointer;
          max-width: 72px;
          text-overflow: ellipsis;
          background-image:
            linear-gradient(45deg, transparent 50%, var(--amber-dim) 50%),
            linear-gradient(135deg, var(--amber-dim) 50%, transparent 50%);
          background-position: calc(100% - 9px) calc(50% + 1px), calc(100% - 5px) calc(50% + 1px);
          background-size: 4px 4px;
          background-repeat: no-repeat;
        }
        .track__input-select--compact {
          width: 14px;
          padding: 0;
          color: transparent;
          border-color: transparent;
          background-color: transparent;
          background-position: calc(50% - 2px) calc(50% + 1px), calc(50% + 2px) calc(50% + 1px);
        }
        .track__input-select:hover { border-color: var(--amber-dim); }
        .track__input-select:focus-visible { outline: 1px solid var(--amber); outline-offset: 1px; }
        .track__input-select option { background: var(--surface-raised); color: var(--ink); }
        .track__fx {
          display: flex;
          align-items: center;
          gap: var(--space-2);
          width: 100%;
          padding: 2px var(--space-1) 2px var(--space-2);
          font-family: var(--font-mono);
          font-size: 0.5625rem;
          letter-spacing: 0.06em;
          color: var(--ink-muted);
          border: 1px solid var(--border-subtle);
          border-radius: var(--radius-sm);
          text-align: left;
          transition: color var(--duration-fast) var(--ease-out),
                      border-color var(--duration-fast) var(--ease-out),
                      background var(--duration-fast) var(--ease-out);
        }
        .track__fx:hover { color: var(--ink-dim); border-color: var(--border); background: var(--surface-hover); }
        .track__fx--active { color: var(--ink-dim); border-color: var(--border); }
        .track__fx--selected { border-color: var(--border-amber); }
        .track__fx-label { font-weight: 700; color: var(--ink-muted); }
        .track__fx--active .track__fx-label { color: var(--amber); }
        .track__fx-badges { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .track__fx-key { font-size: 0.5rem; opacity: 0; transition: opacity var(--duration-fast); }
        .track__fx:hover .track__fx-key,
        .track__fx:focus-visible .track__fx-key { opacity: 1; }
        .track__controls {
          display: flex;
          align-items: flex-end;
          gap: var(--space-3);
        }
        .track__buttons {
          display: flex;
          flex-direction: column;
          gap: var(--space-1);
        }
        .ctrl-btn {
          font-family: var(--font-mono);
          font-size: 0.625rem;
          font-weight: 700;
          letter-spacing: 0.06em;
          padding: 2px var(--space-2);
          border-radius: var(--radius-sm);
          text-transform: uppercase;
          line-height: 1.6;
          transition: all var(--duration-fast) var(--ease-out);
          border: 1px solid transparent;
        }
        .ctrl-btn--arm { color: var(--red); }
        .ctrl-btn--arm:hover { background: var(--red-bg); border-color: var(--red); }
        .ctrl-btn--arm.ctrl-btn--on { background: var(--red); color: var(--ink); border-color: var(--red); }

        .ctrl-btn--solo { color: var(--teal); }
        .ctrl-btn--solo:hover { background: var(--teal-bg); border-color: var(--teal); }
        .ctrl-btn--solo.ctrl-btn--on-solo { background: var(--teal); color: var(--bg); border-color: var(--teal); }

        .ctrl-btn--mute { color: var(--ink-dim); }
        .ctrl-btn--mute:hover { background: var(--surface-raised); border-color: var(--ink-dim); }
        .ctrl-btn--mute.ctrl-btn--on-mute { background: var(--ink-muted); color: var(--bg); }

        .track__pan {
          display: flex;
          align-items: center;
          justify-content: center;
          padding: 0 var(--space-1);
        }
        .track__fader {
          display: flex;
          flex-direction: column;
          align-items: center;
          gap: var(--space-1);
        }
        .fader {
          writing-mode: vertical-lr;
          direction: rtl;
          width: 24px;
          height: 64px;
          -webkit-appearance: none;
          appearance: none;
          background: transparent;
          cursor: pointer;
        }
        .fader::-webkit-slider-runnable-track {
          width: 4px;
          height: 100%;
          background: var(--border);
          border-radius: 2px;
        }
        .fader::-webkit-slider-thumb {
          -webkit-appearance: none;
          width: 16px;
          height: 16px;
          border-radius: 2px;
          background: var(--amber);
          border: none;
          margin-left: -6px;
          margin-bottom: -6px;
        }
        .fader__value {
          font-size: var(--text-caption);
          color: var(--ink-muted);
          font-variant-numeric: tabular-nums;
        }
        .track__meter {
          display: flex;
          align-items: flex-end;
          height: 80px;
        }
        @media (max-width: 600px) {
          .track { min-width: 100%; }
          .track__controls { flex-wrap: wrap; }
        }
      `}</style>
    </div>
  );
}

function levelToDb(level: number): number {
  if (level <= 0) return -Infinity;
  return Math.max(-48, Math.round(20 * Math.log10(level)));
}
