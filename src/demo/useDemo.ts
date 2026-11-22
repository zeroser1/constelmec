import { useMemo, useState } from 'react';
import type { Control, GateState, Observation, Role, Visit } from '../lib/types';
import { initialGates, makeControls, today } from './constants';

// All interactive state + business logic for the demo workspace. Keeping it in
// one hook lets App.tsx stay a thin router and makes the visit state machine
// (closeVisit) unit-testable in isolation.
export function useDemo() {
  const [role, setRole] = useState<Role>('technician');
  const [gates, setGates] = useState(initialGates);
  const [selected, setSelected] = useState<string | null>(null);
  const [search, setSearch] = useState('');
  const [filter, setFilter] = useState('Todos');
  const [controls, setControls] = useState<Control[]>(makeControls);
  const [visitOpen, setVisitOpen] = useState(false);
  const [visits, setVisits] = useState<Visit[]>([]);
  const [observations, setObservations] = useState<Observation[]>([]);
  const [observationText, setObservationText] = useState('');
  const [message, setMessage] = useState('');
  const [mobileMenu, setMobileMenu] = useState(false);

  const gate = gates.find(g => g.id === selected);
  const filtered = useMemo(
    () => gates.filter(g =>
      (filter === 'Todos' || g.state === filter) &&
      (g.name + g.code + g.location).toLowerCase().includes(search.toLowerCase())),
    [gates, filter, search],
  );
  const counts = {
    total: gates.length,
    good: gates.filter(g => g.state === 'Operativo').length,
    warning: gates.filter(g => g.state === 'Con observaciones').length,
    danger: gates.filter(g => g.state === 'Fuera de servicio').length,
  };
  const completed = controls.filter(c => c.status !== 'Pendiente').length;

  const showMessage = (text: string) => setMessage(text);

  const chooseGate = (id: string) => {
    setSelected(id);
    setVisitOpen(false);
    setControls(makeControls());
    setMessage('');
    setMobileMenu(false);
  };

  const switchRole = (next: Role) => { setRole(next); setSelected(null); };

  const closeVisit = () => {
    if (!gate || !visitOpen || completed !== controls.length) return;
    const issues = controls.filter(c => c.status === 'Falla').length;
    const unverified = controls.filter(c => c.status === 'No verificable').length;
    // Invariant: a closed visit never auto-restores an out-of-service gate.
    const state: GateState = gate.state === 'Fuera de servicio'
      ? 'Fuera de servicio'
      : issues || unverified
        ? 'Con observaciones'
        : gate.state === 'Con observaciones' ? 'Con observaciones' : 'Operativo';
    setGates(prev => prev.map(g => g.id === gate.id ? { ...g, state, last: today(), observations: g.observations + issues } : g));
    setVisits(prev => [{ gateId: gate.id, completedAt: today(), issueCount: issues, technician: 'Técnico demo' }, ...prev]);
    setVisitOpen(false);
    showMessage('Visita de demostración cerrada. No se generó un registro real ni un informe PDF.');
  };

  const addObservation = () => {
    if (!gate || !observationText.trim()) return;
    setObservations(prev => [{ gateId: gate.id, text: observationText.trim(), author: 'Cliente demo', createdAt: today() }, ...prev]);
    setObservationText('');
    showMessage('Observación guardada solo en esta demostración. No crea una falla técnica.');
  };

  return {
    role, setRole, switchRole,
    gates, selected, setSelected, gate,
    search, setSearch, filter, setFilter, filtered, counts,
    controls, setControls, completed,
    visitOpen, setVisitOpen, visits,
    observations, observationText, setObservationText,
    message, showMessage, setMessage,
    mobileMenu, setMobileMenu,
    chooseGate, closeVisit, addObservation,
  };
}

export type DemoState = ReturnType<typeof useDemo>;
