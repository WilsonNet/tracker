import { test, expect } from "../fixtures.ts";

const openRack = async (tauriPage: any) => {
  await tauriPage.goto("/");
  await tauriPage.waitForSelector(".track");
  await tauriPage.keyboard.press("x");
  await tauriPage.waitForSelector(".fx-rack");
};

test("x opens the rack on the selected track", async ({ tauriPage }) => {
  await openRack(tauriPage);
  await expect(tauriPage.locator(".fx-mod")).toHaveCount(3);
  await expect(tauriPage.locator(".fx-tab--active")).toHaveText("1");
  await expect(tauriPage.locator(".fx-mod__name").first()).toHaveText("EQ");
});

test("track FX button opens that track's chain", async ({ tauriPage }) => {
  await tauriPage.goto("/");
  await tauriPage.waitForSelector(".track");
  await tauriPage.locator('[aria-label="Open effects for track 3"]').click();
  await tauriPage.waitForSelector(".fx-rack");
  await expect(tauriPage.locator(".fx-tab--active")).toHaveText("3");
  await expect(tauriPage.locator(".fx-rack__channel")).toHaveText("TRACK 3");
});

test("compressor bypass toggles and updates the track badge", async ({ tauriPage }) => {
  await openRack(tauriPage);
  const comp = tauriPage.locator('.fx-mod[data-module="comp"]');
  const power = comp.locator(".fx-power");
  await expect(power).toHaveText("BYP");
  await power.click();
  await expect(power).toHaveText("ON");
  await expect(tauriPage.locator('[aria-label="Open effects for track 1"]')).toContainText("CMP");
  await power.click();
  await expect(power).toHaveText("BYP");
});

test("knob responds to arrow keys and double-click reset", async ({ tauriPage }) => {
  await openRack(tauriPage);
  const comp = tauriPage.locator('.fx-mod[data-module="comp"]');
  await comp.locator(".fx-power").click();
  const thr = comp.locator('[aria-label="Compressor threshold"]');
  await expect(thr).toHaveAttribute("aria-valuetext", "−18.0 dB");
  await thr.focus();
  await tauriPage.keyboard.press("ArrowDown");
  await tauriPage.keyboard.press("ArrowDown");
  await expect(thr).toHaveAttribute("aria-valuetext", "−19.0 dB");
  await thr.dblclick();
  await expect(thr).toHaveAttribute("aria-valuetext", "−18.0 dB");
});

test("tabs cycle with brackets and the master chain shows five modules", async ({ tauriPage }) => {
  await openRack(tauriPage);
  await tauriPage.keyboard.press("]");
  await expect(tauriPage.locator(".fx-tab--active")).toHaveText("2");
  await tauriPage.keyboard.press("[");
  await expect(tauriPage.locator(".fx-tab--active")).toHaveText("1");
  await tauriPage.locator(".fx-tab").nth(4).click();
  await expect(tauriPage.locator(".fx-mod")).toHaveCount(5);
  await expect(tauriPage.locator(".fx-mod__name").last()).toHaveText("LIMITER");
});

test("Escape closes the rack before touching the transport", async ({ tauriPage }) => {
  await openRack(tauriPage);
  await tauriPage.keyboard.press("Escape");
  await expect(tauriPage.locator(".fx-rack")).toHaveCount(0);
});

test("play renders the mix and drives live GR meters", async ({ tauriPage }) => {
  await openRack(tauriPage);
  await tauriPage.locator('.fx-mod[data-module="comp"] .fx-power').click();
  await tauriPage.locator('[aria-label="Play mix"]').click();
  await expect(tauriPage.locator(".fx-rack__status")).toHaveText("LIVE METERS");
  await expect(tauriPage.locator('.fx-mod[data-module="comp"] .gr-meter__value')).not.toHaveText("0.0 dB");
  await tauriPage.locator('[aria-label="Stop playback"]').click();
  await expect(tauriPage.locator(".fx-rack__status")).toContainText("PLAY MIX");
});

test("sends feed the shared buses and show on the strip", async ({ tauriPage }) => {
  await openRack(tauriPage);
  const rev = tauriPage.locator('[aria-label="Reverb send"]');
  await rev.focus();
  for (let i = 0; i < 5; i += 1) await tauriPage.keyboard.press("PageUp");
  await expect(tauriPage.locator('[aria-label="Open effects for track 1"]')).toContainText("REV");
});
