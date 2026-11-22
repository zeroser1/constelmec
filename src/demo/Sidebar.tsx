import { Building2, ChevronDown, DoorOpen, FileText, History, LayoutDashboard } from 'lucide-react';
import type { DemoState } from './useDemo';

// Left navigation for the demo workspace.
export default function Sidebar({ demo }: { demo: DemoState }) {
  const { role, selected, gates, chooseGate, setSelected, setMobileMenu, showMessage, mobileMenu } = demo;
  return (
    <aside className={mobileMenu ? 'sidebar open' : 'sidebar'}>
      <div className="brand"><div className="brand-icon"><span className="brand-mark" aria-hidden="true" /></div><div><strong>CONSTELMEC</strong><small>MAINTENANCE</small></div></div>
      <div className="workspace"><div className="workspace-logo"><Building2 size={19} /></div><div><strong>Empresa de ejemplo</strong><small>Entorno de demostración</small></div><ChevronDown size={16} /></div>
      <div className="nav-label">ESPACIO DE TRABAJO</div>
      <button className={!selected ? 'nav active' : 'nav'} onClick={() => { setSelected(null); setMobileMenu(false); }}><LayoutDashboard size={19} /> Panel general</button>
      <button className={selected ? 'nav active' : 'nav'} onClick={() => chooseGate(gates[0].id)}><DoorOpen size={19} /> Portones <span className="nav-count">{gates.length}</span></button>
      <button className="nav" onClick={() => showMessage('El historial real estará disponible al conectar Supabase y la auditoría.')}><History size={19} /> Historial</button>
      <button className="nav" onClick={() => showMessage('Los informes PDF se incorporarán en una próxima etapa.')}><FileText size={19} /> Informes</button>
      <div className="sidebar-bottom"><div className="demo-label"><span className="live-dot" /> DEMO · SIN DATOS REALES</div><div className="profile"><div className="avatar">{role === 'technician' ? 'TC' : 'CL'}</div><div><strong>{role === 'technician' ? 'Técnico demo' : 'Cliente demo'}</strong><small>{role === 'technician' ? 'Personal técnico' : 'Portal de cliente'}</small></div></div></div>
    </aside>
  );
}
