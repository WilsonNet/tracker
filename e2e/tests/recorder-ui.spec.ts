import { test, expect } from "../fixtures.ts";

test("app loads with correct title", async ({ tauriPage }) => {
  await tauriPage.goto("/");
  await tauriPage.waitForSelector(".app");
  const title = await tauriPage.title();
  expect(title).toContain("Tracker");
});

test("transport controls render", async ({ tauriPage }) => {
  await tauriPage.goto("/");
  await tauriPage.waitForSelector(".transport-btn");
  await expect(tauriPage.locator(".transport-btn--play")).toBeVisible();
});

test("4 track strips render", async ({ tauriPage }) => {
  await tauriPage.goto("/");
  await tauriPage.waitForSelector(".track");
  expect(await tauriPage.locator(".track").count()).toBe(4);
});

test("arm button toggles aria-pressed", async ({ tauriPage }) => {
  await tauriPage.goto("/");
  await tauriPage.waitForSelector(".track");
  const armBtn = tauriPage.locator('[aria-label="Arm track 1"]');
  await armBtn.click();
  await new Promise((r) => setTimeout(r, 300));
  await expect(armBtn).toHaveAttribute("aria-pressed", "true");
});

test("solo button toggles", async ({ tauriPage }) => {
  await tauriPage.goto("/");
  await tauriPage.waitForSelector(".track");
  const btn = tauriPage.locator('[aria-label="Solo track 1"]');
  await btn.click();
  await new Promise((r) => setTimeout(r, 200));
  await expect(btn).toHaveAttribute("aria-pressed", "true");
});

test("mute button toggles", async ({ tauriPage }) => {
  await tauriPage.goto("/");
  await tauriPage.waitForSelector(".track");
  const btn = tauriPage.locator('[aria-label="Mute track 1"]');
  await btn.click();
  await new Promise((r) => setTimeout(r, 200));
  await expect(btn).toHaveAttribute("aria-pressed", "true");
});

test("record button toggles active class", async ({ tauriPage }) => {
  await tauriPage.goto("/");
  await tauriPage.waitForSelector(".transport-btn");
  const btn = tauriPage.locator(".transport-btn--record");
  await btn.click();
  await new Promise((r) => setTimeout(r, 200));
  await expect(btn).toHaveClass(/transport-btn--active/);
});

test("keyboard Space toggles play", async ({ tauriPage }) => {
  await tauriPage.goto("/");
  await tauriPage.waitForSelector(".transport-btn");
  await tauriPage.keyboard.press(" ");
  await new Promise((r) => setTimeout(r, 200));
  expect(await tauriPage.locator(".transport-btn--active").count()).toBeGreaterThanOrEqual(1);
});

test("keyboard 1 arms track 1", async ({ tauriPage }) => {
  await tauriPage.goto("/");
  await tauriPage.waitForSelector(".track");
  await tauriPage.keyboard.press("1");
  await new Promise((r) => setTimeout(r, 200));
  await expect(tauriPage.locator('[aria-label="Arm track 1"]')).toHaveAttribute("aria-pressed", "true");
});

test("command palette opens with colon key", async ({ tauriPage }) => {
  await tauriPage.goto("/");
  await tauriPage.waitForSelector(".transport");
  await tauriPage.keyboard.press(":");
  await new Promise((r) => setTimeout(r, 500));
  await expect(tauriPage.locator(".cmd-overlay")).toBeVisible();
});

test("sidebar collapsed handle is visible at right edge", async ({ tauriPage }) => {
  await tauriPage.goto("/");
  await tauriPage.waitForSelector(".app__sidebar");
  const w = await tauriPage.evaluate(() =>
    document.querySelector(".app__sidebar")!.getBoundingClientRect().width
  );
  expect(w).toBeGreaterThanOrEqual(6);
  expect(w).toBeLessThanOrEqual(10);
});

test("sidebar expands on open class and shows capture button", async ({ tauriPage }) => {
  await tauriPage.goto("/");
  await tauriPage.waitForSelector(".app__sidebar");
  await tauriPage.evaluate(() =>
    document.querySelector(".app__sidebar")!.classList.add("sidebar--open")
  );
  await new Promise((r) => setTimeout(r, 350));
  const w = await tauriPage.evaluate(() =>
    document.querySelector(".app__sidebar")!.getBoundingClientRect().width
  );
  expect(w).toBeGreaterThan(200);
  const txt = await tauriPage.evaluate(() => document.querySelector(".sidebar__btn")?.textContent ?? "");
  expect(txt).toContain("CAPTURE");
});

test("I/O button and i shortcut open the device panel", async ({ tauriPage }) => {
  await tauriPage.goto("/");
  await tauriPage.waitForSelector(".track");
  await tauriPage.locator('[aria-label="Audio input and devices"]').click();
  await new Promise((r) => setTimeout(r, 350));
  await expect(tauriPage.locator('[aria-label="Select audio input device"]')).toBeVisible();
  const openWidth = await tauriPage.evaluate(() =>
    document.querySelector(".app__sidebar")!.getBoundingClientRect().width
  );
  expect(openWidth).toBeGreaterThan(200);
  // The panel starts below the transport, never covering the I/O toggle.
  const belowTransport = await tauriPage.evaluate(() => {
    const side = document.querySelector(".app__sidebar")!.getBoundingClientRect();
    const bar = document.querySelector(".transport")!.getBoundingClientRect();
    return side.top >= bar.bottom - 1;
  });
  expect(belowTransport).toBe(true);
  await tauriPage.keyboard.press("i");
  await new Promise((r) => setTimeout(r, 350));
  const closedWidth = await tauriPage.evaluate(() =>
    document.querySelector(".app__sidebar")!.getBoundingClientRect().width
  );
  expect(closedWidth).toBeLessThan(20);
});

test("capture activates demo meter segments", async ({ tauriPage }) => {
  await tauriPage.goto("/");
  await new Promise((r) => setTimeout(r, 500));
  await tauriPage.evaluate(() => {
    document.querySelector(".app__sidebar")!.classList.add("sidebar--open");
    setTimeout(() => {
      (document.querySelector(".sidebar__btn") as HTMLButtonElement)?.click();
    }, 100);
  });
  await new Promise((r) => setTimeout(r, 800));
  expect(
    await tauriPage.evaluate(() => document.querySelectorAll(".meter__seg--lit").length)
  ).toBeGreaterThan(0);
});

test("bounce section has bounce and play buttons", async ({ tauriPage }) => {
  await tauriPage.goto("/");
  await tauriPage.waitForSelector(".bounce");
  await expect(tauriPage.locator(".bounce__btn--do")).toBeVisible();
  await expect(tauriPage.locator(".bounce__btn--play")).toBeVisible();
});

test("Vim status line is visible", async ({ tauriPage }) => {
  await tauriPage.goto("/");
  await tauriPage.waitForSelector(".statusline");
  await expect(tauriPage.locator(".statusline")).toBeVisible();
});

test("BPM input shows default value 120", async ({ tauriPage }) => {
  await tauriPage.goto("/");
  await tauriPage.waitForSelector(".bpm-input");
  expect(await tauriPage.locator(".bpm-input").inputValue()).toBe("120");
});

test("4 vertical level meters are present", async ({ tauriPage }) => {
  await tauriPage.goto("/");
  await tauriPage.waitForSelector(".meter");
  expect(
    await tauriPage.evaluate(() => document.querySelectorAll(".meter--vertical").length)
  ).toBe(4);
});

test("NORMAL mode badge is shown", async ({ tauriPage }) => {
  await tauriPage.goto("/");
  await tauriPage.waitForSelector(".mode-badge");
  await expect(tauriPage.locator(".mode-badge--normal")).toBeVisible();
});
