// Case 1 (E2E.md 5.2): the SPA's main mode — grant with the ticket grant API (JSON), then the SPA's ticket
// screen shows the QR from the QR image API.

import { expect, test } from '@playwright/test';
import { join } from 'node:path';
import { API_URL, FIXTURES } from '../env.ts';

// {YYYYMMDDHHmmss}{UUIDv4, 32 lowercase hex}{fixed suffix: TICKET_CODE_SUFFIX of compose.e2e.yaml}
const CODE_RE = /^\d{14}[0-9a-f]{32}E2E$/;

test('page mode: grant, move to the SPA ticket screen and show the QR', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'チケット発行' })).toBeVisible();

  await page.getByTestId('image-input').setInputFiles(join(FIXTURES, 'photo.heic'));
  await expect(page.getByTestId('image-info')).toContainText('photo.heic');

  const granted = page.waitForResponse((r) => r.url() === `${API_URL}/v1/tickets` && r.request().method() === 'POST');
  const qr = page.waitForResponse((r) => r.url().startsWith(`${API_URL}/v1/tickets/`) && r.url().includes('/qr?sig='));
  await page.getByTestId('grant-page').click();

  // The ticket grant API answers JSON (CORS lets the SPA read it).
  const grantRes = await granted;
  expect(grantRes.status()).toBe(201);
  expect(grantRes.headers()['access-control-allow-origin']).toBe(new URL(page.url()).origin);
  const ticket = (await grantRes.json()) as { ticketCode: string; sig: string };
  expect(ticket.ticketCode).toMatch(CODE_RE);

  // The SPA moves to its ticket screen, drawn from the URL only.
  await expect(page).toHaveURL(new RegExp(`#/tickets/${ticket.ticketCode}\\?sig=${ticket.sig}$`));
  await expect(page.getByTestId('ticket-code')).toHaveText(ticket.ticketCode);

  // The QR comes from the QR image API as a PNG and is displayed.
  const qrRes = await qr;
  expect(qrRes.status()).toBe(200);
  expect(qrRes.headers()['content-type']).toBe('image/png');
  const img = page.getByAltText('チケットQRコード');
  await expect(img).toBeVisible();
  await expect.poll(() => img.evaluate((el: HTMLImageElement) => el.complete && el.naturalWidth)).toBeGreaterThan(0);
});
