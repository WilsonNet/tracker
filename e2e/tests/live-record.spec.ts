import { execSync } from "node:child_process";
import { test, expect } from "../fixtures.ts";
import { createDriver, waitFor, waitForText } from "../js-driver.ts";

/**
 * Live hardware check against the real app: select the Scarlett's 2-channel
 * hardware node, record input 2 (guitar) for ~3 s, then inspect the WAV.
 *
 * Run:
 *   TAURI_LIVE=1 npm run test:e2e:tauri -- tests/live-record.spec.ts
 * (app running with --features e2e-testing; any window state — the driver
 * drives the React DOM directly, not native pointer coordinates)
 */
test.skip(
  process.env.TAURI_LIVE !== "1",
  "Live capture test — needs the desktop app with hardware input 2",
);

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

test("records input 2 of the Scarlett to track 1", async ({ tauriPage }) => {
  const ui = createDriver(tauriPage);
  await tauriPage.goto("/");
  await waitFor(tauriPage, ".track");
  await sleep(500); // let React finish the first paint after goto

  await ui.click('[aria-label="Audio input and devices"]');
  await waitFor(tauriPage, ".sidebar--open");

  const device = await ui.setSelect(
    'select[aria-label="Select audio input device"]',
    "Focusrite Scarlett 2i2 2nd Gen 0",
  );
  expect(device).toContain("2nd Gen 0");

  await ui.click('[aria-label="Start capture"]');
  const sidebar = await waitForText(tauriPage, ".app__sidebar", "LIVE LEVELS");
  console.log("live levels:", sidebar.replace(/\s+/g, " ").trim());

  await ui.setSelect('select[aria-label="Input channel track 1"]', "1");
  await ui.click('[aria-label="Arm track 1"]');
  expect(await ui.attr('[aria-label="Arm track 1"]', "aria-pressed")).toBe("true");

  await ui.click('[aria-label="Record"]');
  expect(await ui.attr('[aria-label="Stop recording"]', "aria-label")).toBe(
    "Stop recording",
  );
  await sleep(3000);
  await ui.click('[aria-label="Stop recording"]');
  await sleep(1000);

  const seconds = Number(
    execSync("soxi -D /tmp/tracker_recordings/track_1.wav").toString().trim(),
  );
  console.log("recorded seconds:", seconds);
  expect(seconds).toBeGreaterThan(2.5);

  const stats = execSync(
    "sox /tmp/tracker_recordings/track_1.wav -n stat 2>&1",
  ).toString();
  console.log(stats);
});
