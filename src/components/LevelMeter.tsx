interface LevelMeterProps {
  level: number;
  peak?: number;
  active: boolean;
  vertical?: boolean;
  label?: string;
}

const SEGMENTS = 16;
const WARN_AT = 0.8;
const CLIP_AT = 0.95;

export function LevelMeter({ level, peak, active, vertical, label }: LevelMeterProps) {
  const filled = Math.round(level * SEGMENTS);
  const showPeak = peak !== undefined && level >= peak;
  const isClipping = level >= CLIP_AT;

  const barDirection = vertical ? "column" : "row";

  return (
    <div
      className={`meter ${vertical ? "meter--vertical" : "meter--horizontal"} ${
        active ? "meter--active" : ""
      } ${isClipping ? "meter--clip" : ""}`}
    >
      {label && <span className="meter__label">{label}</span>}
      <div className="meter__track" style={{ flexDirection: barDirection }}>
        {Array.from({ length: SEGMENTS }, (_, i) => {
          const ratio = (i + 1) / SEGMENTS;
          let cls = "meter__seg";
          if (i < filled) {
            cls += ratio > CLIP_AT ? " meter__seg--clip" : ratio > WARN_AT ? " meter__seg--warn" : " meter__seg--lit";
          }
          if (showPeak && i === filled) {
            cls += " meter__seg--peak";
          }
          return <div key={i} className={cls} />;
        })}
      </div>
      <style>{`
        .meter {
          display: flex;
          align-items: center;
          gap: var(--space-1);
          min-height: ${vertical ? "80px" : "8px"};
          min-width: ${vertical ? "8px" : "80px"};
        }
        .meter--vertical {
          flex-direction: column;
          width: 8px;
        }
        .meter--horizontal {
          flex-direction: row;
          height: 8px;
        }
        .meter__label {
          font-size: var(--text-caption);
          color: var(--ink-muted);
          width: 2.5em;
          text-align: right;
        }
        .meter__track {
          display: flex;
          flex: 1;
          gap: 1px;
          background: var(--surface);
          border-radius: var(--radius-sm);
          overflow: hidden;
          height: ${vertical ? "100%" : "100%"};
          width: ${vertical ? "100%" : "100%"};
        }
        .meter__seg {
          flex: 1;
          background: var(--border);
          transition: background var(--duration-fast) var(--ease-out);
        }
        .meter--active .meter__seg--lit {
          background: var(--amber);
        }
        .meter--active .meter__seg--warn {
          background: var(--amber-bright);
        }
        .meter--active .meter__seg--clip {
          background: var(--red);
        }
        .meter--clip .meter__seg--peak {
          background: var(--red-bright);
          box-shadow: 0 0 4px var(--red);
        }
        @media (prefers-reduced-motion: reduce) {
          .meter__seg { transition: none; }
        }
      `}</style>
    </div>
  );
}
