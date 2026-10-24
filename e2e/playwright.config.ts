import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  timeout: 60000,
  expect: { timeout: 10000 },
  fullyParallel: false,
  retries: process.env.CI ? 1 : 0,
  workers: 1,
  reporter: [['html', { outputFolder: '../.playwright-report' }], ['list']],
  use: {
    baseURL: 'http://localhost:1420',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },
  projects: [
    {
      name: 'browser-only',
      testIgnore: /(desktop|live-record)\.spec\.ts/,
      use: {
        ...devices['Desktop Chrome'],
        mode: 'browser' as const,
      },
    },
    {
      name: 'tauri',
      testMatch: /(desktop|live-record)\.spec\.ts/,
      use: {
        mode: 'tauri' as const,
      },
    },
  ],
});
