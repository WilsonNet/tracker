import type { VimMode } from "../types/types.ts";

interface VimStatusLineProps {
  mode: VimMode;
  message?: string;
  recording?: boolean;
  captureActive?: boolean;
  armedTracks?: number;
}

export function VimStatusLine({ mode, message, recording, captureActive, armedTracks }: VimStatusLineProps) {
  const modeColors: Record<VimMode, string> = {
    normal: "var(--amber)",
    insert: "var(--ink)",
    command: "var(--teal)",
  };

  return (
    <div className="statusline">
      <div className="statusline__mode" style={{ background: modeColors[mode], color: mode === "insert" ? "var(--bg)" : "var(--ink)" }}>
        {mode === "command" ? ":" : mode.toUpperCase()}
      </div>
      <span className="statusline__message">{message ?? ""}</span>
      <div className="statusline__indicators">
        {captureActive && (
          <span className="statusline__ind statusline__ind--capture">
            ● CAP
          </span>
        )}
        {recording && (
          <span className="statusline__ind statusline__ind--recording">
            ● REC {armedTracks ?? 0}
          </span>
        )}
        <span className="statusline__hints">
          {mode === "normal" && "j/k: nav  J/K: vol  : command"}
          {mode === "insert" && "Esc: normal"}
          {mode === "command" && "Type command"}
        </span>
      </div>
      <style>{`
        .statusline {
          display: flex;
          align-items: center;
          gap: var(--space-2);
          padding: var(--space-1) var(--space-4);
          border-top: 1px solid var(--border);
          font-size: var(--text-caption);
          color: var(--ink-muted);
          background: var(--surface);
        }
        .statusline__mode {
          font-weight: 700;
          font-size: 0.625rem;
          letter-spacing: 0.08em;
          padding: 1px var(--space-2);
          border-radius: var(--radius-sm);
          line-height: 1.5;
        }
        .statusline__message {
          flex: 1;
          font-size: var(--text-caption);
          color: var(--ink-dim);
        }
        .statusline__indicators {
          display: flex;
          align-items: center;
          gap: var(--space-3);
        }
        .statusline__ind {
          font-family: var(--font-mono);
          font-size: 0.625rem;
          font-weight: 600;
          letter-spacing: 0.05em;
          padding: 1px var(--space-2);
          border-radius: var(--radius-sm);
          line-height: 1.6;
        }
        .statusline__ind--capture {
          color: var(--amber);
          background: var(--amber-bg);
        }
        .statusline__ind--recording {
          color: var(--ink);
          background: var(--red);
        }
        .statusline__hints {
          font-size: var(--text-caption);
          color: var(--ink-muted);
        }
        @media (max-width: 600px) {
          .statusline__hints { display: none; }
        }
      `}</style>
    </div>
  );
}
