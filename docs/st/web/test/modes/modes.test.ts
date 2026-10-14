// The grant modes whose folder is present (only the built mode's folder is needed; web/DESIGN.md 4.1). page, the
// default, is always present.
import { describe, expect, test } from 'vitest';
import { GRANT_MODES } from '../../src/modes/types.ts';
import { MODE_FOLDERS, MODES } from '../helpers.ts';

test('page (the default mode) is present', () => {
  expect(MODES.map((m) => m.mode)).toContain('page');
});

describe.each(Object.entries(MODE_FOLDERS))('%s', (path, entry) => {
  test('names itself after its folder, is one of GRANT_MODES and has a grant screen at /', () => {
    expect(path).toBe(`../src/modes/${entry.mode}/index.ts`);
    expect(GRANT_MODES).toContain(entry.mode);
    expect(entry.routes.map((r) => r.path)).toContain('/');
  });
});
