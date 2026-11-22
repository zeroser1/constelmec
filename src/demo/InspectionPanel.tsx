import { CheckCircle2, Plus, Wrench } from 'lucide-react';
import type { ControlStatus } from '../lib/types';
import type { DemoState } from './useDemo';
import { makeControls } from './constants';

// Technician inspection checklist inside the gate detail card.
export default function InspectionPanel({ demo }: { demo: DemoState }) {
  const { visitOpen, setVisitOpen, setControls, controls, completed, closeVisit } = demo;

  if (!visitOpen) return (
    <div className="callout"><Wrench size={27} /><h3>Registrar mantenimiento</h3><p>Iniciá una visita de demostración para completar los controles del portón.</p><button className="btn primary" onClick={() => { setControls(makeControls()); setVisitOpen(true); }}><Plus size={17} /> Iniciar inspección</button></div>
  );

  const blockFinish = completed !== controls.length || controls.some(c => (c.status === 'Falla' || c.status === 'No verificable') && !c.note.trim());

  return (
    <>
      <div className="progress-text"><strong>Checklist de inspección</strong><span>{completed}/{controls.length} completados</span></div>
      <div className="progress"><span style={{ width: (completed / controls.length * 100) + '%' }} /></div>
      <div className="checks">{controls.map((c, i) => (
        <div className="check" key={c.id}>
          <div className="check-label"><span className="check-number">{String(i + 1).padStart(2, '0')}</span><strong>{c.label}</strong></div>
          <div className="check-options" role="group" aria-label={'Estado de ' + c.label}>{(['OK', 'Falla', 'N/A', 'No verificable'] as ControlStatus[]).map(status => (
            <button type="button" key={status} aria-pressed={c.status === status} className={'check-choice ' + (c.status === status ? 'chosen ' : '') + (status === 'OK' ? 'choice-ok' : status === 'Falla' ? 'choice-fail' : 'choice-neutral')} onClick={() => setControls(prev => prev.map(x => x.id === c.id ? { ...x, status } : x))}>{status}</button>
          ))}</div>
          {(c.status === 'Falla' || c.status === 'No verificable') && <textarea aria-label={'Nota de ' + c.label} placeholder="Describí el hallazgo..." value={c.note} onChange={e => setControls(prev => prev.map(x => x.id === c.id ? { ...x, note: e.target.value } : x))} />}
        </div>
      ))}</div>
      <div className="visit-actions"><button className="btn ghost" onClick={() => setVisitOpen(false)}>Cancelar</button><button className="btn primary" disabled={blockFinish} onClick={closeVisit}><CheckCircle2 size={17} /> Finalizar inspección</button></div>
      <p className="fineprint">El cierre de una visita no certifica que el portón sea seguro. El estado fuera de servicio no se levanta automáticamente.</p>
    </>
  );
}
