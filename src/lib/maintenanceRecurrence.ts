/**
 * Preventive-maintenance scheduling helpers.
 * All dates are calendar dates in the company's local timezone (YYYY-MM-DD).
 * No automatic service orders are created by this module.
 */
export type RecurrenceFrequency = 1 | 2 | 3 | 6 | 12;
export type RecurrenceRule =
  | { mode: 'fixed_day'; dayOfMonth: number; everyMonths: RecurrenceFrequency }
  | { mode: 'business_week'; week: 1 | 2 | 3 | 4 | 5; everyMonths: RecurrenceFrequency };

export type DateWindow = { start: string; end: string };

function parseDate(value: string): Date {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new Error('Fecha inválida');
  const date = new Date(value + 'T12:00:00Z');
  if (Number.isNaN(date.getTime()) || date.toISOString().slice(0, 10) !== value) {
    throw new Error('Fecha inválida');
  }
  return date;
}

function formatDate(date: Date): string {
  return date.toISOString().slice(0, 10);
}

function isBusinessDay(date: Date, holidays: ReadonlySet<string>): boolean {
  const weekday = date.getUTCDay();
  return weekday !== 0 && weekday !== 6 && !holidays.has(formatDate(date));
}

function calendarMonth(anchor: Date, offset: number): { year: number; month: number } {
  const date = new Date(Date.UTC(anchor.getUTCFullYear(), anchor.getUTCMonth() + offset, 1, 12));
  return { year: date.getUTCFullYear(), month: date.getUTCMonth() };
}

/**
 * Generate a single occurrence window. The anchor month is occurrence zero;
 * callers must persist occurrence identity (rule id + month) to prevent duplicates.
 * Business weeks are Monday-Sunday calendar weeks containing business days.
 * Public holidays can be supplied by the caller; they are not guessed.
 */
export function occurrenceWindow(
  anchorDate: string,
  rule: RecurrenceRule,
  occurrence: number,
  holidayDates: readonly string[] = [],
): DateWindow {
  if (!Number.isSafeInteger(occurrence) || occurrence < 0) throw new Error('Ocurrencia inválida');
  if (![1, 2, 3, 6, 12].includes(rule.everyMonths)) throw new Error('Frecuencia inválida');
  const anchor = parseDate(anchorDate);
  const { year, month } = calendarMonth(anchor, occurrence * rule.everyMonths);
  const lastDay = new Date(Date.UTC(year, month + 1, 0, 12)).getUTCDate();
  if (rule.mode === 'fixed_day') {
    if (!Number.isInteger(rule.dayOfMonth) || rule.dayOfMonth < 1 || rule.dayOfMonth > 31) {
      throw new Error('Día inválido');
    }
    const date = formatDate(new Date(Date.UTC(year, month, Math.min(rule.dayOfMonth, lastDay), 12)));
    return { start: date, end: date };
  }
  if (!Number.isInteger(rule.week) || rule.week < 1 || rule.week > 5) throw new Error('Semana inválida');
  const holidays = new Set(holidayDates);
  // Calendar weeks start on Monday. The first week intersects the first day of the month.
  const first = new Date(Date.UTC(year, month, 1, 12));
  const firstMonday = 1 - ((first.getUTCDay() + 6) % 7);
  const weekStart = firstMonday + (rule.week - 1) * 7;
  const available: string[] = [];
  for (let day = Math.max(1, weekStart); day <= Math.min(lastDay, weekStart + 6); day++) {
    const date = new Date(Date.UTC(year, month, day, 12));
    if (isBusinessDay(date, holidays)) available.push(formatDate(date));
  }
  if (!available.length) throw new Error('La semana solicitada no tiene días hábiles');
  return { start: available[0], end: available[available.length - 1] };
}
