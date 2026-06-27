interface TimecodeDisplayProps {
  seconds: number;
}

function fmt(v: number): string {
  return String(Math.floor(v)).padStart(2, "0");
}

export function TimecodeDisplay({ seconds }: TimecodeDisplayProps) {
  const h = seconds / 3600;
  const m = (seconds % 3600) / 60;
  const s = seconds % 60;
  const ms = Math.floor((seconds % 1) * 100);

  return (
    <div className="timecode">
      <span className="timecode__value">
        {fmt(h)}:{fmt(m)}:{fmt(s)}.{fmt(ms)}
      </span>
      <style>{`
        .timecode {
          font-family: var(--font-mono);
          font-size: var(--text-data);
          font-variant-numeric: tabular-nums;
          color: var(--ink);
          letter-spacing: 0;
          line-height: 1;
        }
        .timecode__value {
          background: var(--surface);
          padding: var(--space-1) var(--space-2);
          border-radius: var(--radius-sm);
        }
      `}</style>
    </div>
  );
}
