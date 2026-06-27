interface KnobProps {
  value: number;
  onChange: (value: number) => void;
  label: string;
  ariaLabel: string;
}

export function Knob({ value, label, ariaLabel }: KnobProps) {
  const deg = Math.round(value * 270 - 135);
  return (
    <div className="knob" role="slider" aria-label={ariaLabel} aria-valuenow={Math.round(value * 100)} tabIndex={0}>
      <div className="knob__dial">
        <div className="knob__pointer" style={{ transform: `rotate(${deg}deg)` }} />
      </div>
      <span className="knob__label">{label}</span>
      <span className="knob__value">
        {value < 0.45 ? "L" : value > 0.55 ? "R" : "C"}
      </span>
      <style>{`
        .knob {
          display: flex;
          flex-direction: column;
          align-items: center;
          gap: 2px;
          cursor: ns-resize;
        }
        .knob:focus-visible { outline: 1px solid var(--amber); outline-offset: 2px; border-radius: var(--radius-sm); }
        .knob__dial {
          width: 24px;
          height: 24px;
          border-radius: 50%;
          background: var(--surface-raised);
          border: 1px solid var(--border);
          position: relative;
        }
        .knob__pointer {
          position: absolute;
          top: 2px;
          left: 50%;
          width: 2px;
          height: 8px;
          background: var(--ink-dim);
          border-radius: 1px;
          transform-origin: bottom center;
          transition: transform var(--duration-fast) var(--ease-out);
        }
        .knob__label {
          font-size: 0.5625rem;
          font-weight: 600;
          letter-spacing: 0.06em;
          color: var(--ink-dim);
          text-transform: uppercase;
        }
        .knob__value {
          font-size: 0.5625rem;
          color: var(--ink-muted);
          font-variant-numeric: tabular-nums;
        }
      `}</style>
    </div>
  );
}
