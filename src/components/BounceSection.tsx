interface BounceSectionProps {
  canUndo: boolean;
  inProgress: boolean;
  playing: boolean;
  onBounce: () => void;
  onUndo: () => void;
  onPlay: () => void;
  onStopPlayback: () => void;
}

export function BounceSection({
  canUndo, inProgress, playing,
  onBounce, onUndo, onPlay, onStopPlayback,
}: BounceSectionProps) {
  return (
    <div className="bounce">
      <span className="bounce__title">BOUNCE</span>
      <button
        className="bounce__btn bounce__btn--do"
        onClick={onBounce}
        disabled={inProgress}
        aria-label="Bounce tracks"
      >
        {inProgress ? "···" : "BOUNCE"}
      </button>
      <button
        className="bounce__btn bounce__btn--undo"
        onClick={onUndo}
        disabled={!canUndo || inProgress}
        aria-label="Undo last bounce"
      >
        UNDO
      </button>
      <button
        className={`bounce__btn bounce__btn--play ${playing ? "bounce__btn--active" : ""}`}
        onClick={playing ? onStopPlayback : onPlay}
        aria-label={playing ? "Stop playback" : "Play mix"}
      >
        {playing ? "■ STOP" : "▶ PLAY"}
      </button>
      <span className="bounce__status">
        {inProgress ? "Bouncing..." : playing ? "Playing" : canUndo ? "Bounce ready" : "Ready"}
      </span>
      <style>{`
        .bounce {
          display: flex;
          align-items: center;
          gap: var(--space-2);
          padding: var(--space-2) var(--space-4);
          border-top: 1px solid var(--border);
        }
        .bounce__title {
          font-size: var(--text-label);
          font-weight: 700;
          letter-spacing: var(--tracking-label);
          color: var(--ink-dim);
        }
        .bounce__btn {
          font-family: var(--font-mono);
          font-size: var(--text-label);
          font-weight: 600;
          letter-spacing: var(--tracking-label);
          padding: var(--space-1) var(--space-3);
          border-radius: var(--radius-sm);
          transition: all var(--duration-fast) var(--ease-out);
        }
        .bounce__btn:disabled { opacity: 0.4; cursor: default; }
        .bounce__btn--do { color: var(--amber); border: 1px solid var(--border-amber); }
        .bounce__btn--do:hover:not(:disabled) { background: var(--amber-bg); }
        .bounce__btn--undo { color: var(--ink-dim); border: 1px solid var(--border); }
        .bounce__btn--undo:hover:not(:disabled) { background: var(--surface-hover); }
        .bounce__btn--play { color: var(--teal); border: 1px solid var(--teal); }
        .bounce__btn--play:hover:not(:disabled) { background: var(--teal-bg); }
        .bounce__btn--active { background: var(--teal); color: var(--bg); }
        .bounce__status {
          font-size: var(--text-caption);
          color: var(--ink-muted);
          margin-left: auto;
        }
      `}</style>
    </div>
  );
}
