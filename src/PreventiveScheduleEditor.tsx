import { useMemo, useState } from 'react';
import { fetchArgentineHolidays, type Holiday } from './lib/argentineHolidays';
import { occurrenceWindow, type RecurrenceFrequency, type RecurrenceRule } from './lib/maintenanceRecurrence';

export type PreventiveScheduleDraft = {
  anchorDate: string;
  rule: RecurrenceRule;
};

/**
 * Configuration-only editor. Does not write orders or modify an existing series.
 * The parent must persist the draft through an authorized server operation.
 */
export default function PreventiveScheduleEditor({
  onChange,
  initial,
}: {
  onChange: (draft: PreventiveScheduleDraft) => void;
  initial?: PreventiveScheduleDraft;
}) {
  const [anchorDate, setAnchorDate] = useState(initial?.anchorDate ?? '');
  const [frequency, setFrequency] = useState<RecurrenceFrequency>(initial?.rule.everyMonths ?? 1);
  const [mode, setMode] = useState<RecurrenceRule['mode']>(initial?.rule.mode ?? 'fixed_day');
  const [day, setDay] = useState(initial?.rule.mode === 'fixed_day' ? initial.rule.dayOfMonth : 1);
  const [week, setWeek] = useState<1 | 2 | 3 | 4 | 5>(initial?.rule.mode === 'business_week' ? initial.rule.week : 2);
  const [holidays, setHolidays] = useState<Holiday[]>([]);
  const [excludedDates, setExcludedDates] = useState<string[]>([]);
  const [holidayYear, setHolidayYear] = useState(new Date().getFullYear());
  const [holidaySearch, setHolidaySearch] = useState('');
  const [holidayError, setHolidayError] = useState('');
  const [holidayLoading, setHolidayLoading] = useState(false);
  const [loadedYears, setLoadedYears] = useState<number[]>([]);

  async function refreshHolidays() {
    setHolidayLoading(true);
    setHolidayError('');
    try {
      const fetched = await fetchArgentineHolidays(holidayYear);
      setHolidays(previous => [...previous.filter(h => !h.date.startsWith(`${holidayYear}-`)), ...fetched]
        .sort((a, b) => a.date.localeCompare(b.date)));
      setLoadedYears(previous => [...new Set([...previous, holidayYear])]);
      setExcludedDates(previous => [...new Set([...previous, ...fetched.filter(h => h.global).map(h => h.date)])]);
    } catch (error) {
      setHolidayError(error instanceof Error ? error.message : 'No se pudo actualizar');
    } finally {
      setHolidayLoading(false);
    }
  }
  const filteredHolidays = holidays.filter(h =>
    h.date.startsWith(`${holidayYear}-`) &&
    `${h.date} ${h.localName}`.toLocaleLowerCase('es').includes(holidaySearch.toLocaleLowerCase('es'))
  );
  const rule: RecurrenceRule = mode === 'fixed_day'
    ? { mode, everyMonths: frequency, dayOfMonth: day }
    : { mode, everyMonths: frequency, week };

  const preview = useMemo(() => {
    if (!anchorDate) return { dates: [] as string[], error: '' };
    try {
      return {
        dates: [0, 1, 2].map(index => {
          const window = occurrenceWindow(anchorDate, rule, index, excludedDates);
          return window.start === window.end ? window.start : `${window.start} al ${window.end}`;
        }),
        error: '',
      };
    } catch (error) {
      return { dates: [] as string[], error: error instanceof Error ? error.message : 'Fecha inválida' };
    }
  }, [anchorDate, frequency, mode, day, week, excludedDates]);

  return (
    <section aria-label="Programación preventiva recurrente" style={{ display: 'grid', gap: 12 }}>
      <label>Fecha de referencia
        <input type="date" value={anchorDate} onChange={e => setAnchorDate(e.target.value)} />
      </label>
      <label>Frecuencia
        <select value={frequency} onChange={e => setFrequency(Number(e.target.value) as RecurrenceFrequency)}>
          <option value={1}>Mensual</option>
          <option value={2}>Cada 2 meses</option>
          <option value={3}>Cada 3 meses</option>
          <option value={6}>Cada 6 meses</option>
          <option value={12}>Anual</option>
        </select>
      </label>
      <label>Ventana de ejecución
        <select value={mode} onChange={e => setMode(e.target.value as RecurrenceRule['mode'])}>
          <option value="fixed_day">Día fijo del mes</option>
          <option value="business_week">Semana hábil del mes</option>
        </select>
      </label>
      {mode === 'fixed_day' ? (
        <label>Día del mes
          <input type="number" min={1} max={31} value={day} onChange={e => setDay(Number(e.target.value))} />
        </label>
      ) : (
        <label>Semana
          <select value={week} onChange={e => setWeek(Number(e.target.value) as 1 | 2 | 3 | 4 | 5)}>
            {[1, 2, 3, 4, 5].map(n => <option key={n} value={n}>{n}ª semana</option>)}
          </select>
        </label>
      )}
      <fieldset style={{ display: 'grid', gap: 8 }}>
        <legend>Feriados de Argentina</legend>
        <label>Año
          <input type="number" min={2000} max={2100} value={holidayYear}
            onChange={e => setHolidayYear(Number(e.target.value))} />
        </label>
        <button type="button" onClick={() => void refreshHolidays()} disabled={holidayLoading}>
          {holidayLoading ? 'Consultando…' : 'Buscar / actualizar feriados'}
        </button>
        <label>Buscar feriado por nombre o fecha
          <input type="search" value={holidaySearch} onChange={e => setHolidaySearch(e.target.value)}
            placeholder="Ej. 25 de mayo" />
        </label>
        {holidayError && <p role="alert">{holidayError}</p>}
        {loadedYears.includes(holidayYear) && (
          <p>{filteredHolidays.length} resultados. Desmarcá feriados que no correspondan a tu localidad.</p>
        )}
        <div style={{ maxHeight: 180, overflowY: 'auto' }}>
          {filteredHolidays.map(holiday => (
            <label key={holiday.date} style={{ display: 'block' }}>
              <input type="checkbox" checked={excludedDates.includes(holiday.date)}
                onChange={e => setExcludedDates(previous => e.target.checked
                  ? [...new Set([...previous, holiday.date])]
                  : previous.filter(date => date !== holiday.date))} />
              {' '}{holiday.date} — {holiday.localName}{holiday.global ? '' : ' (regional)'}
            </label>
          ))}
        </div>
        <small>Fuente: Nager.Date (servicio externo). Verificá feriados trasladables,
          días puente y feriados locales con el calendario oficial argentino.
          Los años no consultados no tienen exclusiones cargadas.</small>
      </fieldset>
      {preview.error && <p role="alert">{preview.error}</p>}
      {preview.dates.length > 0 && (
        <div aria-live="polite">
          <strong>Próximas tres ventanas (excluyendo feriados seleccionados)</strong>
          <ul>{preview.dates.map(date => <li key={date}>{date}</li>)}</ul>
        </div>
      )}
      <p>La fecha concreta de visita se confirma después. Este formulario no genera órdenes automáticamente.</p>
      <button type="button" disabled={!anchorDate || !!preview.error}
        onClick={() => onChange({ anchorDate, rule })}>
        Confirmar configuración
      </button>
    </section>
  );
}
