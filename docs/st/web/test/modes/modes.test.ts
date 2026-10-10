// Every grant mode chosen by GRANT_MODE (vite.config.ts) exists and has a grant screen at '/'.
import { describe, expect, test } from 'vitest';
import { GRANT_MODES } from '../../src/modes/types.ts';

describe.each(GRANT_MODES)('grant mode %s', (mode) => {
  test('src/modes/<mode>/index.ts names itself and has a grant screen at /', async () => {
    const entry = await import(`../../src/modes/${mode}/index.ts`);
    expect(entry.mode).toBe(mode);
    expect(entry.routes.map((r: { path: string }) => r.path)).toContain('/');
  });
});
