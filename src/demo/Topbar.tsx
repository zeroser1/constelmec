import { Building2, HardHat, Menu } from 'lucide-react';
import type { DemoState } from './useDemo';

// Top bar: mobile menu trigger, breadcrumbs, exit, and the role toggle.
export default function Topbar({ demo, onExit }: { demo: DemoState; onExit: () => void }) {
  const { gate, role, switchRole, setMobileMenu } = demo;
  return (
    <header className="topbar">
      <button className="mobile-menu icon-btn" aria-label="Abrir menú" onClick={() => setMobileMenu(true)}><Menu size={21} /></button>
      <div className="breadcrumbs">Constelmec <span>/</span> {gate ? gate.code : 'Panel general'}</div>
      <div className="top-actions">
        <button className="logout-demo" onClick={onExit} aria-label="Volver al acceso">Salir</button>
        <span className="demo-pill">● Demo interactiva</span>
        <div className="role-toggle" aria-label="Cambiar vista">
          <button className={role === 'technician' ? 'selected' : ''} onClick={() => switchRole('technician')}><HardHat size={15} /> Técnico</button>
          <button className={role === 'customer' ? 'selected' : ''} onClick={() => switchRole('customer')}><Building2 size={15} /> Cliente</button>
        </div>
      </div>
    </header>
  );
}
