import { expect, test } from '@playwright/test';

test('shows the response received through the front-end proxy', async ({ page }) => {
  await page.goto('/');

  await expect(page.getByRole('heading', { name: 'Docker Compose Playwright' })).toBeVisible();
  await expect(page.locator('#api-message')).toHaveText('Go API container is running.');
});
