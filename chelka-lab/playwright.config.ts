import { defineConfig } from '@playwright/test';
export default defineConfig({
  testDir: './tests', fullyParallel: false, workers: 1, timeout: 30000,
  expect: { timeout: 6000 }, reporter: [['list'], ['html', { open: 'never', outputFolder: 'artifacts/report' }]],
  use: { baseURL: 'http://127.0.0.1:5187', channel: 'chrome', viewport: { width: 1440, height: 1100 }, screenshot: 'only-on-failure', trace: 'retain-on-failure' },
  outputDir: 'artifacts/test-results',
  webServer: { command: 'npm run dev', url: 'http://127.0.0.1:5187', reuseExistingServer: true, timeout: 20000 },
});
