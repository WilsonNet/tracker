import { DRUM_PATTERNS } from "../types/types.ts";

interface RhythmSectionProps {
  enabled: boolean;
  pattern: string;
  tempo: number;
  onToggle: () => void;
  onPatternChange: (pattern: string) => void;
  onTempoChange: (tempo: number) => void;
}

export function RhythmSection({
  enabled,
  pattern,
  tempo,
  onToggle,
  onPatternChange,
  onTempoChange,
}: RhythmSectionProps) {
  return (
    <div className="rhythm">
      <button
        className={`rhythm__toggle ${enabled ? "rhythm__toggle--on" : ""}`}
        onClick={onToggle}
        aria-pressed={enabled}
        aria-label="Toggle rhythm section"
      >
        RHYTHM
        <span className="rhythm__ind">{enabled ? "ON" : "OFF"}</span>
      </button>

      {enabled && (
        <>
          <select
            className="rhythm__select"
            value={DRUM_PATTERNS.includes(pattern as any) ? pattern : DRUM_PATTERNS[0]}
            onChange={(e) => onPatternChange(e.target.value)}
            aria-label="Drum pattern"
          >
            {DRUM_PATTERNS.map((p) => (
              <option key={p} value={p}>{p}</option>
            ))}
          </select>
          <div className="rhythm__tempo">
            <label className="rhythm__tempo-label" htmlFor="rhythm-tempo">BPM</label>
            <input
              id="rhythm-tempo"
              className="rhythm__tempo-inp"
              type="number"
              min="20"
              max="300"
              value={tempo}
              onChange={(e) => onTempoChange(Number(e.target.value))}
              aria-label="Rhythm tempo"
            />
          </div>
        </>
      )}

      <style>{`
        .rhythm {
          display: flex;
          align-items: center;
          gap: var(--space-3);
          padding: var(--space-2) var(--space-4);
          border-top: 1px solid var(--border);
        }
        .rhythm__toggle {
          display: flex;
          align-items: center;
          gap: var(--space-2);
          font-family: var(--font-mono);
          font-size: var(--text-label);
          font-weight: 600;
          letter-spacing: var(--tracking-label);
          padding: var(--space-1) var(--space-3);
          border-radius: var(--radius-sm);
          color: var(--ink-dim);
          border: 1px solid var(--border);
          transition: all var(--duration-fast) var(--ease-out);
        }
        .rhythm__toggle:hover { background: var(--surface-hover); }
        .rhythm__toggle--on { color: var(--amber); border-color: var(--border-amber); background: var(--amber-bg); }
        .rhythm__ind { font-size: var(--text-caption); font-weight: 400; }
        .rhythm__select {
          font-family: var(--font-mono);
          font-size: var(--text-label);
          padding: var(--space-1) var(--space-2);
          border-radius: var(--radius-sm);
          background: var(--surface);
          border: 1px solid var(--border);
          color: var(--ink);
        }
        .rhythm__select:focus { border-color: var(--amber); }
        .rhythm__tempo { display: flex; align-items: center; gap: var(--space-1); }
        .rhythm__tempo-label { font-size: var(--text-caption); color: var(--ink-dim); }
        .rhythm__tempo-inp {
          width: 48px;
          font-size: var(--text-data);
          text-align: center;
          padding: var(--space-1);
          font-variant-numeric: tabular-nums;
        }
      `}</style>
    </div>
  );
}
