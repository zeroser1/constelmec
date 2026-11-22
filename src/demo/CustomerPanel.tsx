import { Activity, Send } from 'lucide-react';
import type { DemoState } from './useDemo';

// Customer-side view inside the gate detail card: status + observation form.
export default function CustomerPanel({ demo }: { demo: DemoState }) {
  const { gate, observationText, setObservationText, addObservation } = demo;
  if (!gate) return null;
  return (
    <>
      <div className="callout customer"><Activity size={27} /><h3>Estado actual</h3><p>El equipo figura como <strong>{gate.state.toLowerCase()}</strong>. Los datos son de demostración y no se actualizan en tiempo real.</p></div>
      <label className="field-label" htmlFor="observation">Enviar observación</label>
      <textarea id="observation" className="observation-input" value={observationText} onChange={e => setObservationText(e.target.value)} placeholder="Describí qué observaste en este portón..." maxLength={1000} />
      <button className="btn primary" disabled={!observationText.trim()} onClick={addObservation}><Send size={17} /> Enviar observación</button>
      <p className="fineprint">Una observación del cliente no crea automáticamente una falla técnica ni una orden de trabajo.</p>
    </>
  );
}
