import { test, expect } from "../fixtures.ts";

/**
 * Real Tauri app + real Rust audio engine.
 *
 * Run manually:
 *   1. `npm run tauri -- dev --features e2e-testing`
 *      (temporarily add `"playwright:default"` to src-tauri/capabilities/default.json)
 *   2. Make the window visible: SUPER+SHIFT+X
 *   3. `TRACKER_VISIBLE=1 npm run test:e2e:tauri`
 *
 * Skipped by default: the app window opens on a hidden Hyprland special
 * workspace, and the socket bridge cannot inject clicks into a hidden window.
 */
test.skip(
  process.env.TRACKER_VISIBLE !== "1",
  "Desktop E2E needs a visible window: SUPER+SHIFT+X, then TRACKER_VISIBLE=1 npm run test:e2e:tauri",
);

test("real engine: FX chain renders, previews and bounces", async ({ tauriPage }) => {
  await tauriPage.goto("/");
  await tauriPage.waitForSelector(".track");

  await tauriPage.locator('[aria-label="Open effects for track 1"]').click();
  await tauriPage.waitForSelector(".fx-rack");
  await tauriPage.locator('.fx-mod[data-module="comp"] .fx-power').click();

  await tauriPage.locator(".fx-tab").nth(4).click();
  await tauriPage.locator('.fx-mod[data-module="reverb"] .fx-power').click();
  await tauriPage.locator('.fx-mod[data-module="delay"] .fx-power').click();
  await tauriPage.locator('.fx-mod[data-module="width"] .fx-power').click();

  await tauriPage.locator('[aria-label="Play mix"]').click();
  await expect(tauriPage.locator(".fx-rack__status")).toHaveText("LIVE METERS", { timeout: 30_000 });

  const limiter = tauriPage.locator('.fx-mod[data-module="limiter"]');
  await expect(limiter).toContainText("PEAK");
  await expect(limiter).not.toContainText("−96.0 dB");

  await tauriPage.locator('[aria-label="Bounce tracks"]').click();
  await expect(tauriPage.locator(".bounce__status")).toHaveText("Bounce ready", { timeout: 30_000 });
  await expect(tauriPage.locator(".statusline__message")).toContainText("Bounce");

  await tauriPage.locator('[aria-label="Stop playback"]').click();
});
