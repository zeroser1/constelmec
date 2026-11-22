import type { Control, Gate, GateState } from '../lib/types';

export const initialGates: Gate[] = [
  { id: 'g1', name: 'Portón principal', code: 'CM-001', location: 'Planta Norte · Acceso A', model: 'Corredizo industrial', state: 'Operativo', last: '12 nov 2026', next: '12 feb 2027', observations: 0 },
  { id: 'g2', name: 'Portón de carga', code: 'CM-002', location: 'Planta Norte · Depósito', model: 'Seccional motorizado', state: 'Con observaciones', last: '05 nov 2026', next: '05 feb 2027', observations: 2 },
  { id: 'g3', name: 'Portón lateral', code: 'CM-003', location: 'Planta Sur · Acceso B', model: 'Levadizo industrial', state: 'Fuera de servicio', last: '29 oct 2026', next: 'Pendiente', observations: 1 },
  { id: 'g4', name: 'Portón estacionamiento', code: 'CM-004', location: 'Planta Sur · Parking', model: 'Corredizo automático', state: 'Operativo', last: '08 nov 2026', next: '08 feb 2027', observations: 0 },
];

export const controlLabels = [
  'Estado general y estructura',
  'Motor y transmisión',
  'Sensores y dispositivos de seguridad',
  'Guías, rodillos y herrajes',
  'Sistema eléctrico y comandos',
  'Prueba de apertura y cierre',
];

export const makeControls = (): Control[] =>
  controlLabels.map((label, index) => ({ id: String(index), label, status: 'Pendiente', note: '' }));

export const badgeClass = (state: GateState) =>
  state === 'Operativo' ? 'good' : state === 'Con observaciones' ? 'warn' : 'danger';

export const today = () =>
  new Intl.DateTimeFormat('es-AR', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date());

export const filterOptions = ['Todos', 'Operativo', 'Con observaciones', 'Fuera de servicio'] as const;
