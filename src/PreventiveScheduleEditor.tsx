import { useMemo, useState } from 'react';
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
  const rule: RecurrenceRule = mode === 'fixed_day'
    ? { mode, everyMonths: frequency, dayOfMonth: day }
    : { mode, everyMonths: frequency, week };

  const preview = useMemo(() => {
    if (!anchorDate) return { dates: [] as string[], error: '' };
    try {
      return {
        dates: [0, 1, 2].map(index => {
          const window = occurrenceWindow(anchorDate, rule, index);
          return window.start === window.end ? window.start : `${window.start} al ${window.end}`;
        }),
        error: '',
      };
    } catch (error) {
      return { dates: [] as string[], error: error instanceof Error ? error.message : 'Fecha inválida' };
    }
  }, [anchorDate, frequency, mode, day, week]);

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
      {preview.error && <p role="alert">{preview.error}</p>}
      {preview.dates.length > 0 && (
        <div aria-live="polite">
          <strong>Próximas tres ventanas (sin feriados)</strong>
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
