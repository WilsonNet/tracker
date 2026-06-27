import type { TransportState, VimMode } from "../types/types.ts";
import { TimecodeDisplay } from "./TimecodeDisplay.tsx";

interface TransportBarProps {
  state: TransportState;
  mode: VimMode;
  bpm: number;
  position: number;
  onPlay: () => void;
  onStop: () => void;
  onRecord: () => void;
  onBpmChange: (bpm: number) => void;
  recordingTime?: number;
}

export function TransportBar({
  state,
  mode,
  bpm,
  position,
  onPlay,
  onStop,
  onRecord,
  onBpmChange,
  recordingTime,
}: TransportBarProps) {
  const isRecording = state === "recording";
  const isPlaying = state === "playing";

  return (
    <div className="transport">
      <div className="transport__inner">
        <div className="transport__section transport__section--modes">
          <span className={`mode-badge mode-badge--${mode}`}>
            {mode.toUpperCase()}
          </span>
        </div>

        <div className="transport__section transport__section--controls">
          <button
            className={`transport-btn transport-btn--record ${isRecording ? "transport-btn--active" : ""}`}
            onClick={onRecord}
            title="Record (R)"
            aria-label={isRecording ? "Stop recording" : "Record"}
          >
            <span className="transport-btn__icon">●</span>
            <span className="transport-btn__label">REC</span>
          </button>
          <button
            className={`transport-btn transport-btn--play ${isPlaying ? "transport-btn--active" : ""}`}
            onClick={onPlay}
            title="Play / Stop (Space)"
            aria-label={isPlaying ? "Pause" : "Play"}
          >
            <span className="transport-btn__icon">{isPlaying ? "■" : "▶"}</span>
            <span className="transport-btn__label">{isPlaying ? "STOP" : "PLAY"}</span>
          </button>
          <button
            className="transport-btn transport-btn--stop"
            onClick={onStop}
            title="Stop (Esc)"
            aria-label="Stop"
          >
            <span className="transport-btn__icon">⏹</span>
            <span className="transport-btn__label">STOP</span>
          </button>
        </div>

        <div className="transport__section transport__section--time">
          <TimecodeDisplay seconds={recordingTime ?? position} />
        </div>

        <div className="transport__section transport__section--bpm">
          <label className="bpm-label" htmlFor="bpm-input">BPM</label>
          <input
            id="bpm-input"
            className="bpm-input"
            type="number"
            min="20"
            max="300"
            value={bpm}
            onChange={(e) => onBpmChange(Number((e.target as HTMLInputElement).value))}
            aria-label="Tempo in BPM"
          />
        </div>
      </div>

      <style>{`
        .transport {
          background: var(--surface);
          border-bottom: 1px solid var(--border);
        }
        .transport__inner {
          display: flex;
          align-items: center;
          gap: var(--space-5);
          padding: var(--space-2) var(--space-4);
        }
        .transport__section {
          display: flex;
          align-items: center;
          gap: var(--space-2);
        }
        .transport__section--controls { gap: var(--space-1); }
        .transport__section--time { margin-left: auto; }
        .transport__section--bpm { margin-left: var(--space-4); }

        .mode-badge {
          font-size: var(--text-label);
          font-weight: 600;
          letter-spacing: var(--tracking-label);
          padding: var(--space-1) var(--space-2);
          border-radius: var(--radius-sm);
          line-height: 1;
        }
        .mode-badge--normal { color: var(--amber); background: var(--amber-bg); }
        .mode-badge--insert { color: var(--ink); background: var(--surface-raised); }
        .mode-badge--command { color: var(--teal); background: var(--teal-bg); }

        .transport-btn {
          display: flex;
          align-items: center;
          gap: var(--space-1);
          padding: var(--space-1) var(--space-3);
          border-radius: var(--radius-sm);
          font-size: var(--text-label);
          font-weight: 600;
          letter-spacing: var(--tracking-label);
          text-transform: uppercase;
          transition: background var(--duration-fast) var(--ease-out),
                      color var(--duration-fast) var(--ease-out);
        }
        .transport-btn__icon { font-size: 0.75rem; line-height: 1; }
        .transport-btn--record { color: var(--red); }
        .transport-btn--record:hover { background: var(--red-bg); }
        .transport-btn--record.transport-btn--active {
          background: var(--red);
          color: var(--ink);
          animation: pulse-glow 1s ease-in-out infinite;
        }
        .transport-btn--play { color: var(--amber); }
        .transport-btn--play:hover { background: var(--amber-bg); }
        .transport-btn--play.transport-btn--active {
          background: var(--amber);
          color: var(--bg);
        }
        .transport-btn--stop { color: var(--ink-dim); }
        .transport-btn--stop:hover {
          background: var(--surface-hover);
          color: var(--ink);
        }

        .bpm-label {
          font-size: var(--text-label);
          font-weight: 600;
          letter-spacing: var(--tracking-label);
          color: var(--ink-dim);
        }
        .bpm-input {
          width: 56px;
          font-size: var(--text-data);
          font-variant-numeric: tabular-nums;
          text-align: center;
          padding: var(--space-1);
          border-color: var(--border);
          background: var(--bg);
          color: var(--ink);
          border-radius: var(--radius-sm);
        }
        .bpm-input:focus { border-color: var(--amber); }

        @media (max-width: 600px) {
          .transport__inner { gap: var(--space-3); padding: var(--space-2); flex-wrap: wrap; }
          .transport__section--time { margin-left: 0; }
          .transport__section--bpm { margin-left: auto; }
        }
      `}</style>
    </div>
  );
}
