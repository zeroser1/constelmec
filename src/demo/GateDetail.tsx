import { ArrowLeft, ClipboardCheck, DoorOpen, FileText, History } from 'lucide-react';
import type { DemoState } from './useDemo';
import { badgeClass } from './constants';
import InspectionPanel from './InspectionPanel';
import CustomerPanel from './CustomerPanel';

// Full gate detail: header, equipment info, role-specific action panel, history.
export default function GateDetail({ demo }: { demo: DemoState }) {
  const { gate, setSelected, role, visits, observations } = demo;
  if (!gate) return null;
  const gateVisits = visits.filter(v => v.gateId === gate.id);
  const gateObs = observations.filter(o => o.gateId === gate.id);
  return (
    <>
      <button className="back" onClick={() => setSelected(null)}><ArrowLeft size={17} /> Volver a portones</button>
      <div className="detail-head"><div><div className="eyebrow">FICHA DEL EQUIPO · {gate.code}</div><h1>{gate.name}</h1><p>{gate.location}</p></div><span className={'status large ' + badgeClass(gate.state)}><span className="status-dot" />{gate.state}</span></div>
      <div className="detail-grid">
        <section className="panel detail-card"><div className="mini-heading"><DoorOpen size={20} /><h3>Información del equipo</h3></div><div className="placeholder-photo"><DoorOpen size={43} /><span>Fotografía de referencia pendiente</span></div><div className="data-row"><span>Código</span><strong>{gate.code}</strong></div><div className="data-row"><span>Tipo</span><strong>{gate.model}</strong></div><div className="data-row"><span>Último mantenimiento</span><strong>{gate.last}</strong></div><div className="data-row"><span>Próximo mantenimiento</span><strong>{gate.next}</strong></div></section>
        <section className="panel detail-card"><div className="mini-heading"><ClipboardCheck size={20} /><h3>{role === 'technician' ? 'Inspección técnica' : 'Seguimiento del equipo'}</h3></div>{role === 'technician' ? <InspectionPanel demo={demo} /> : <CustomerPanel demo={demo} />}</section>
      </div>
      <section className="panel history-panel"><div className="mini-heading"><History size={19} /><h3>Historial y observaciones</h3></div>{gateVisits.map((v, i) => <div className="history-item" key={'v' + i}><ClipboardCheck size={18} /><div><strong>Mantenimiento de demostración finalizado</strong><p>{v.completedAt} · {v.technician} · {v.issueCount} fallas marcadas</p></div></div>)}{gateObs.map((o, i) => <div className="history-item" key={'o' + i}><FileText size={18} /><div><strong>Observación de {o.author}</strong><p>{o.text} · {o.createdAt}</p></div></div>)}{!gateVisits.length && !gateObs.length && <div className="empty compact">Todavía no hay registros creados en esta sesión de demostración.</div>}</section>
    </>
  );
}
