import { useCallback, useEffect, useRef } from "react";

type KeyHandler = (key: string, mods: { ctrl: boolean; shift: boolean }) => void;

export function useVimKeyboard(handler: KeyHandler) {
  const handlerRef = useRef(handler);
  handlerRef.current = handler;

  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      if (
        e.target instanceof HTMLInputElement ||
        e.target instanceof HTMLTextAreaElement ||
        e.target instanceof HTMLSelectElement
      ) {
        return;
      }
      handlerRef.current(e.key, { ctrl: e.ctrlKey, shift: e.shiftKey });
      if (e.key === " " || e.key === ":" || e.key === "Escape") {
        e.preventDefault();
      }
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);
}

export function useTransport(
  onPlay: () => void,
  onStop: () => void,
  onRecord: () => void,
) {
  useVimKeyboard(
    useCallback(
      (key, mods) => {
        if (mods.ctrl) return;
        if (key === "Escape") {
          onStop();
        } else if (key === " ") {
          onPlay();
        } else if (key === "r" && !mods.shift) {
          onRecord();
        }
      },
      [onPlay, onStop, onRecord],
    ),
  );
}
