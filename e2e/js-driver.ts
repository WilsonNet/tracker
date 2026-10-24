/**
 * DOM driver for the Tauri webview.
 *
 * Why this exists: @srsholmes/tauri-playwright injects *native* pointer events
 * at viewport coordinates. Those only land when the window is composited and
 * unobstructed at the expected screen position — they fail for a window on a
 * hidden special workspace, a floating window, or a window behind another one.
 * The app itself is plain React, so dispatching DOM events from inside the
 * webview drives it reliably regardless of window state.
 *
 * Usage (tauri test project):
 *   import { createDriver, waitFor } from "../js-driver.ts";
 *   const ui = createDriver(tauriPage);
 *   await ui.click('[aria-label="Audio input and devices"]');
 *   await ui.setSelect('select[aria-label="Select audio input device"]', "Scarlett");
 *   await waitFor(tauriPage, ".sidebar--open");
 *
 * Everything is synchronous inside one `evaluate` call. Do not schedule work
 * with page timers — use Node-side waits (`waitFor`).
 */

export interface TauriPageLike {
  evaluate(script: string): Promise<any>;
}

const selector = (value: string) => JSON.stringify(value);

export function createDriver(page: TauriPageLike) {
  const run = (code: string) => page.evaluate(`(function(){ ${code} })()`);

  return {
    /** Click by dispatching the full pointer/mouse sequence React expects. */
    click: (sel: string) =>
      run(`
        var el = document.querySelector(${selector(sel)});
        if (!el) return 'missing';
        var r = el.getBoundingClientRect();
        var opts = {
          bubbles: true, cancelable: true, composed: true,
          clientX: r.left + r.width / 2,
          clientY: r.top + r.height / 2,
          button: 0, buttons: 1
        };
        el.dispatchEvent(new PointerEvent('pointerdown', opts));
        el.dispatchEvent(new MouseEvent('mousedown', opts));
        el.dispatchEvent(new PointerEvent('pointerup', { ...opts, buttons: 0 }));
        el.dispatchEvent(new MouseEvent('mouseup', { ...opts, buttons: 0 }));
        el.dispatchEvent(new MouseEvent('click', { ...opts, buttons: 0 }));
        return 'ok';
      `),

    /** Set a controlled <select> and fire the React change event. */
    setSelect: (sel: string, value: string) =>
      run(`
        var el = document.querySelector(${selector(sel)});
        if (!el) return 'missing';
        var set = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value').set;
        set.call(el, ${JSON.stringify(value)});
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return el.value;
      `),

    /** Set a controlled <input> (BPM etc.). */
    setInput: (sel: string, value: string) =>
      run(`
        var el = document.querySelector(${selector(sel)});
        if (!el) return 'missing';
        var set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        set.call(el, ${JSON.stringify(value)});
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return el.value;
      `),

    /** Focus an element and dispatch a keydown/keyup (knobs, midi-style controls). */
    press: (sel: string, key: string, init: Record<string, unknown> = {}) =>
      run(`
        var el = document.querySelector(${selector(sel)});
        if (!el) return 'missing';
        el.focus();
        var opts = { key: ${JSON.stringify(key)}, bubbles: true, cancelable: true, ...${JSON.stringify(init)} };
        el.dispatchEvent(new KeyboardEvent('keydown', opts));
        el.dispatchEvent(new KeyboardEvent('keyup', opts));
        return 'ok';
      `),

    /** Dispatch a window-level key binding (x, i, 1-4, ...). */
    hotkey: (key: string, init: Record<string, unknown> = {}) =>
      run(`
        var opts = { key: ${JSON.stringify(key)}, bubbles: true, cancelable: true, ...${JSON.stringify(init)} };
        window.dispatchEvent(new KeyboardEvent('keydown', opts));
        window.dispatchEvent(new KeyboardEvent('keyup', opts));
        return 'ok';
      `),

    text: (sel: string) =>
      run(`
        var el = document.querySelector(${selector(sel)});
        return el ? el.textContent : null;
      `),

    attr: (sel: string, name: string) =>
      run(`
        var el = document.querySelector(${selector(sel)});
        return el ? el.getAttribute(${JSON.stringify(name)}) : null;
      `),

    classOf: (sel: string) =>
      run(`
        var el = document.querySelector(${selector(sel)});
        return el ? el.className : null;
      `),

    exists: (sel: string) =>
      run(`return !!document.querySelector(${selector(sel)});`),

    count: (sel: string) =>
      run(`return document.querySelectorAll(${selector(sel)}).length;`),
  };
}

/** Node-side polling: page timers can be frozen in a background webview. */
export async function waitFor(
  page: TauriPageLike,
  sel: string,
  timeoutMs = 10_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = await page.evaluate(
      `!!document.querySelector(${JSON.stringify(sel)})`,
    );
    if (found) return;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`timed out waiting for ${sel}`);
}

/** Wait until an element's text contains `needle`. */
export async function waitForText(
  page: TauriPageLike,
  sel: string,
  needle: string,
  timeoutMs = 15_000,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let last = "";
  while (Date.now() < deadline) {
    last = await page.evaluate(
      `(document.querySelector(${JSON.stringify(sel)}) || {}).textContent || ""`,
    );
    if (last.includes(needle)) return last;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(
    `timed out waiting for "${needle}" in ${sel} (last: ${JSON.stringify(last)})`,
  );
}
