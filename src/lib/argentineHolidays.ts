/**
 * Public-holiday lookup for Argentina.
 * Nager.Date is a third-party public API. Its coverage of moved holidays,
 * bridge holidays and provincial/municipal observances is not guaranteed.
 * Callers must review results before treating dates as authoritative.
 */
export type Holiday = {
  date: string;
  localName: string;
  name: string;
  global: boolean;
  counties: string[] | null;
};

export async function fetchArgentineHolidays(year: number, signal?: AbortSignal): Promise<Holiday[]> {
  if (!Number.isInteger(year) || year < 2000 || year > 2100) throw new Error('Año fuera de rango');
  const response = await fetch(`https://date.nager.at/api/v3/PublicHolidays/${year}/AR`, {
    signal,
    headers: { Accept: 'application/json' },
  });
  if (!response.ok) throw new Error(`No se pudieron consultar los feriados (${response.status})`);
  const data: unknown = await response.json();
  if (!Array.isArray(data)) throw new Error('Respuesta de feriados inválida');
  const holidays: Holiday[] = [];
  for (const item of data) {
    if (!item || typeof item !== 'object') continue;
    const h = item as Record<string, unknown>;
    if (typeof h.date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(h.date) ||
      typeof h.localName !== 'string' || typeof h.name !== 'string') continue;
    if (!h.date.startsWith(`${year}-`)) continue;
    holidays.push({
      date: h.date,
      localName: h.localName,
      name: h.name,
      global: h.global === true,
      counties: Array.isArray(h.counties) ? h.counties.filter((x): x is string => typeof x === 'string') : null,
    });
  }
  if (!holidays.length) throw new Error('La fuente no devolvió feriados válidos');
  return holidays.sort((a, b) => a.date.localeCompare(b.date));
}
