import { useState } from 'react';
import { CheckCircle2, X } from 'lucide-react';
import type { Role } from './lib/types';
import QRDemo from './QRDemo';
import RealAccess from './RealAccess';
import { useDemo } from './demo/useDemo';
import DemoLogin from './demo/DemoLogin';
import Sidebar from './demo/Sidebar';
import Topbar from './demo/Topbar';
import Dashboard from './demo/Dashboard';
import GateDetail from './demo/GateDetail';

export default function App() {
  const demo = useDemo();
  const [demoSession, setDemoSession] = useState(false);
  const [realAccess, setRealAccess] = useState(true);
  const [qrDemo, setQrDemo] = useState(false);
  const [loginRole, setLoginRole] = useState<Role>('technician');
  const { gate, message, setMessage, setRole, setSelected, setVisitOpen, mobileMenu, setMobileMenu } = demo;

  if (realAccess) return <RealAccess onDemo={() => { setRole('technician'); setDemoSession(true); setRealAccess(false); setSelected(null); }} />;

  if (!demoSession) return <DemoLogin loginRole={loginRole} setLoginRole={setLoginRole} onEnter={() => { setRole(loginRole); setDemoSession(true); setSelected(null); }} />;

  if (qrDemo) return <QRDemo onBack={() => setQrDemo(false)} />;

  return (
    <div className="app">
      <Sidebar demo={demo} />
      {mobileMenu && <button className="scrim" aria-label="Cerrar menú" onClick={() => setMobileMenu(false)} />}
      <main className="main">
        <Topbar demo={demo} onExit={() => { setDemoSession(false); setSelected(null); setVisitOpen(false); }} />
        <div className="content">
          {message && <div className="toast" role="status"><CheckCircle2 size={18} />{message}<button aria-label="Cerrar aviso" onClick={() => setMessage('')}><X size={17} /></button></div>}
          {!gate ? <Dashboard demo={demo} onScanQR={() => setQrDemo(true)} /> : <GateDetail demo={demo} />}
          <footer>CONSTELMEC MAINTENANCE <span>·</span> PROTOTIPO v0.1 <span>·</span> Datos ficticios, sin conexión al servidor</footer>
        </div>
      </main>
    </div>
  );
}
