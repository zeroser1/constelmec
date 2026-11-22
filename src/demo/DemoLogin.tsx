import { ArrowRight, Building2, HardHat, ShieldAlert } from 'lucide-react';
import type { Role } from '../lib/types';

type Props = {
  loginRole: Role;
  setLoginRole: (r: Role) => void;
  onEnter: () => void;
};

// The demo (passwordless) login screen shown when a demo session is not active.
export default function DemoLogin({ loginRole, setLoginRole, onEnter }: Props) {
  return (
    <div className="login-screen">
      <div className="login-brand"><span className="login-symbol" aria-hidden="true" /><span>CONSTELMEC</span></div>
      <main className="login-panel">
        <div className="login-kicker">PLATAFORMA DE MANTENIMIENTO</div>
        <h1>Bienvenido</h1>
        <p>Accedé al espacio de mantenimiento de portones industriales.</p>
        <div className="login-role-switch" aria-label="Elegir perfil">
          <button className={loginRole === 'technician' ? 'active' : ''} onClick={() => setLoginRole('technician')}><HardHat size={19} /> Técnico</button>
          <button className={loginRole === 'customer' ? 'active' : ''} onClick={() => setLoginRole('customer')}><Building2 size={19} /> Cliente</button>
        </div>
        <div className="login-demo-notice"><ShieldAlert size={19} /><span>Vista de demostración. El acceso real ya utiliza Supabase; esta vista usa datos ficticios.</span></div>
        <button className="login-enter" onClick={onEnter}>Explorar demo de {loginRole === 'technician' ? 'técnico' : 'cliente'} <ArrowRight size={20} /></button>
        <p className="login-fineprint">Este explorador no requiere contraseña y no guarda datos en el servidor.</p>
      </main>
      <div className="login-footer">CONSTELMEC · MAINTENANCE</div>
    </div>
  );
}
