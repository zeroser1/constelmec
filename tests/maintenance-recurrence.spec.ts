import { test, expect } from '@playwright/test';
import { occurrenceWindow } from '../src/lib/maintenanceRecurrence';

test.describe('preventive recurrence windows', () => {
  test('monthly fixed day clamps February and does not drift', () => {
    const rule = { mode: 'fixed_day' as const, dayOfMonth: 31, everyMonths: 1 as const };
    expect(occurrenceWindow('2027-01-31', rule, 1)).toEqual({ start: '2027-02-28', end: '2027-02-28' });
    expect(occurrenceWindow('2027-01-31', rule, 2)).toEqual({ start: '2027-03-31', end: '2027-03-31' });
  });

  test('second business week excludes weekends and supplied holidays', () => {
    const rule = { mode: 'business_week' as const, week: 2 as const, everyMonths: 1 as const };
    expect(occurrenceWindow('2026-11-01', rule, 0)).toEqual({ start: '2026-11-09', end: '2026-11-13' });
    expect(occurrenceWindow('2026-11-01', rule, 0, ['2026-11-09', '2026-11-13']))
      .toEqual({ start: '2026-11-10', end: '2026-11-12' });
  });

  test('semiannual recurrence uses anchor month rather than previous occurrence', () => {
    const rule = { mode: 'fixed_day' as const, dayOfMonth: 15, everyMonths: 6 as const };
    expect(occurrenceWindow('2026-11-15', rule, 1)).toEqual({ start: '2027-05-15', end: '2027-05-15' });
  });

  test('invalid dates and negative occurrences fail closed', () => {
    const rule = { mode: 'fixed_day' as const, dayOfMonth: 10, everyMonths: 1 as const };
    expect(() => occurrenceWindow('2026-02-30', rule, 0)).toThrow();
    expect(() => occurrenceWindow('2026-01-01', rule, -1)).toThrow();
  });
});

test('partial first week is not counted as first business week', () => {
  const rule = { mode: 'business_week' as const, week: 1 as const, everyMonths: 1 as const };
  expect(occurrenceWindow('2026-11-01', rule, 0)).toEqual({ start: '2026-11-02', end: '2026-11-06' });
});
