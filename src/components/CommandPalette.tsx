import { useState, useEffect, useRef } from "react";

interface CommandPaletteProps {
  open: boolean;
  onClose: () => void;
  onCommand: (cmd: string) => void;
}

const COMMANDS = [
  { key: "w", desc: "Save project" },
  { key: "q", desc: "Quit" },
  { key: "h", desc: "Show help" },
  { key: "bn", desc: "New bounce" },
  { key: "bu", desc: "Undo bounce" },
  { key: "rt", desc: "Toggle rhythm" },
  { key: "rm", desc: "Mute all" },
  { key: "rs", desc: "Solo toggle" },
];

export function CommandPalette({ open, onClose, onCommand }: CommandPaletteProps) {
  const [input, setInput] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (open) {
      setInput("");
      setTimeout(() => inputRef.current?.focus(), 50);
    }
  }, [open]);

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape" && open) {
        onClose();
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open, onClose]);

  function handleSubmit() {
    const trimmed = input.trim().toLowerCase();
    if (trimmed) {
      onCommand(trimmed);
    }
    onClose();
  }

  if (!open) return null;

  const filtered = COMMANDS.filter(
    (c) => !input || c.key.includes(input.toLowerCase()) || c.desc.toLowerCase().includes(input.toLowerCase()),
  );

  return (
    <div className="cmd-overlay" onClick={onClose} role="dialog" aria-modal="true" aria-label="Command palette">
      <div className="cmd-panel" onClick={(e) => e.stopPropagation()}>
        <div className="cmd-input-wrap">
          <span className="cmd-prompt">:</span>
          <input
            ref={inputRef}
            className="cmd-input"
            type="text"
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") handleSubmit();
              if (e.key === "Escape") onClose();
            }}
            placeholder="type a command..."
            aria-label="Command input"
          />
        </div>
        {filtered.length > 0 && (
          <div className="cmd-suggestions">
            {filtered.map((c) => (
              <button
                key={c.key}
                className="cmd-suggestion"
                onClick={() => { setInput(c.key); handleSubmit(); }}
              >
                <span className="cmd-suggestion__key">{c.key}</span>
                <span className="cmd-suggestion__desc">{c.desc}</span>
              </button>
            ))}
          </div>
        )}
      </div>
      <style>{`
        .cmd-overlay {
          position: fixed;
          inset: 0;
          background: rgba(0, 0, 0, 0.6);
          display: flex;
          align-items: flex-start;
          justify-content: center;
          padding-top: 15vh;
          z-index: var(--z-overlay);
        }
        .cmd-panel {
          background: var(--surface);
          border: 1px solid var(--border);
          border-radius: var(--radius-md);
          min-width: 360px;
          max-width: 480px;
          box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5);
        }
        .cmd-input-wrap {
          display: flex;
          align-items: center;
          gap: var(--space-2);
          padding: var(--space-3);
          border-bottom: 1px solid var(--border);
        }
        .cmd-prompt {
          font-size: var(--text-heading);
          font-weight: 700;
          color: var(--amber);
        }
        .cmd-input {
          flex: 1;
          font-size: var(--text-body);
          padding: var(--space-1) var(--space-2);
          background: var(--bg);
          border: 1px solid var(--border);
          border-radius: var(--radius-sm);
          color: var(--ink);
          font-family: var(--font-mono);
        }
        .cmd-input:focus { border-color: var(--amber); outline: none; }
        .cmd-suggestions {
          padding: var(--space-2);
          display: flex;
          flex-direction: column;
          gap: var(--space-1);
          max-height: 240px;
          overflow-y: auto;
        }
        .cmd-suggestion {
          display: flex;
          align-items: center;
          gap: var(--space-3);
          padding: var(--space-1) var(--space-2);
          border-radius: var(--radius-sm);
          font-size: var(--text-body);
          text-align: left;
          color: var(--ink-dim);
          transition: background var(--duration-fast) var(--ease-out);
        }
        .cmd-suggestion:hover, .cmd-suggestion:focus { background: var(--surface-hover); color: var(--ink); }
        .cmd-suggestion__key {
          font-weight: 700;
          color: var(--amber);
          font-size: var(--text-label);
          min-width: 24px;
        }
        .cmd-suggestion__desc { font-size: var(--text-body); }
      `}</style>
    </div>
  );
}
