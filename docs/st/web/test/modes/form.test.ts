// フォーム送信方式（src/modes/form/）: fetch を使わない普通のフォーム。
import { describe, expect, test } from 'vitest';
import { grantFormAction } from '../../src/modes/form/api.ts';
import { routes } from '../../src/modes/form/index.ts';
import { API, config, mountAt } from '../helpers.ts';

test('the form posts to the ticket grant API', () => {
  expect(grantFormAction(API)).toBe(`${API}/v1/tickets`);
  expect(grantFormAction('')).toBe('/v1/tickets');
});

describe('grant screen', () => {
  test('a plain multipart form to the ticket grant API; no other mode on the screen', async () => {
    const { wrapper } = await mountAt(routes, '/');
    const form = wrapper.get('[data-testid="post-form"]');
    expect(form.attributes('action')).toBe(`${API}/v1/tickets`);
    expect(form.attributes('method')).toBe('post');
    expect(form.attributes('enctype')).toBe('multipart/form-data');
    const input = form.get('input[type="file"]');
    expect(input.attributes('name')).toBe('image');
    expect(input.attributes('required')).toBeDefined();
    expect(wrapper.find('[data-testid="grant-page"]').exists()).toBe(false);
    expect(wrapper.find('[data-testid="grant-inline"]').exists()).toBe(false);
  });

  test('same origin (unified layout): the action is a relative URL', async () => {
    const { wrapper } = await mountAt(routes, '/', { ...config(), apiBaseUrl: '' });
    expect(wrapper.get('[data-testid="post-form"]').attributes('action')).toBe('/v1/tickets');
  });
});
