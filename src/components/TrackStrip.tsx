import type { TrackData } from "../types/types.ts";
import { LevelMeter } from "./LevelMeter.tsx";
import { Knob } from "./Knob.tsx";

interface TrackStripProps {
  track: TrackData;
  index: number;
  selected: boolean;
  transportState: "stopped" | "playing" | "recording";
  onArm: (id: number) => void;
  onSolo: (id: number) => void;
  onMute: (id: number) => void;
  onLevelChange: (id: number, level: number) => void;
  onPanChange: (id: number, pan: number) => void;
  onSelect: (id: number) => void;
}

export function TrackStrip({
  track,
  index,
  selected,
  transportState,
  onArm,
  onSolo,
  onMute,
  onLevelChange,
  onPanChange,
  onSelect,
}: TrackStripProps) {
  const isActive = !track.muted && (selected || track.armed || transportState !== "stopped");
  const isRecording = transportState === "recording" && track.armed;

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
        <span className="track__input">{track.input === "Off" ? "—" : `IN ${track.input}`}</span>
      </div>

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
            level={track.level * 0.9}
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
        }
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
