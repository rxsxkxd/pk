// Case 1 (E2E.md 5.2): the SPA's main mode — issue with the ticket issue API (JSON), then the SPA's ticket
// screen shows the QR from the QR image API.

import { expect, test } from '@playwright/test';
import { join } from 'node:path';
import { API_URL, FIXTURES } from '../env.ts';

const CODE_RE = /^\d{14}-[0-9A-HJKMNP-TV-Z]{8}$/;

test('page mode: issue, move to the SPA ticket screen and show the QR', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'チケット発行' })).toBeVisible();

  await page.getByTestId('photo-input').setInputFiles(join(FIXTURES, 'photo.heic'));
  await expect(page.getByTestId('photo-info')).toContainText('photo.heic');

  const issued = page.waitForResponse((r) => r.url() === `${API_URL}/v1/tickets` && r.request().method() === 'POST');
  const qr = page.waitForResponse((r) => r.url().startsWith(`${API_URL}/v1/tickets/`) && r.url().includes('/qr?sig='));
  await page.getByTestId('issue-page').click();

  // The ticket issue API answers JSON (CORS lets the SPA read it).
  const issueRes = await issued;
  expect(issueRes.status()).toBe(201);
  expect(issueRes.headers()['access-control-allow-origin']).toBe(new URL(page.url()).origin);
  const ticket = (await issueRes.json()) as { ticketCode: string; sig: string };
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
