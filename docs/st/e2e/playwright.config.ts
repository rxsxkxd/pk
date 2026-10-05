import { defineConfig, devices } from '@playwright/test';
import { WEB_URL } from './env.ts';

export default defineConfig({
  testDir: 'tests',
  globalSetup: './global-setup.ts',
  // The Lambda RIE handles one invocation at a time (E2E.md 2.3).
  workers: 1,
  fullyParallel: false,
  retries: 0,
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    ...devices['Pixel 7'],
    baseURL: WEB_URL,
    trace: 'retain-on-failure',
  },
});
