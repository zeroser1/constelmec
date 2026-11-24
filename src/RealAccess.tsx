import { useState } from 'react';
import { ArrowRight, DoorOpen, Eye, EyeOff, HardHat, LogOut, ShieldAlert } from 'lucide-react';
import './real-access.css';
import logo from './assets/logo.png';
import './portal.css';
import AdminControl from './AdminControl';
import AppShell from './AppShell';
import PlatformAdminControl from './PlatformAdminControl';
import CustomerPortal from './CustomerPortal';
import TechnicianPortal from './TechnicianPortal';
import { supabaseConfigured } from './lib/supabase';
import { useAuth, signIn, signUp, signOut, requestPasswordReset, updatePassword } from './hooks/useAuth';
import { useMembership, useAdminData, usePlatformAdmin } from './hooks/useRealData';

export default function RealAccess({ onDemo }: { onDemo: () => void }) {
  const { session, loading, passwordRecovery, setPasswordRecovery } = useAuth();
  const [forgotMode, setForgotMode] = useState(false);
  const [confirmPassword, setConfirmPassword] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [signupMode, setSignupMode] = useState(false);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('');
  const [adminDemo, setAdminDemo] = useState(false);

  const platformAdminQ = usePlatformAdmin(session?.user.id);
  const membershipQ = useMembership(session?.user.id);
  const membership = membershipQ.data ?? null;
  const adminQ = useAdminData(membership?.role === 'admin', session?.user.id);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true); setMessage('');
    try {
      if (passwordRecovery) {
        if (password.length < 8) throw new Error('La contraseña debe tener al menos 8 caracteres.');
        if (password !== confirmPassword) throw new Error('Las contraseñas no coinciden.');
        if (!session) throw new Error('El enlace no es válido o expiró. Solicitá uno nuevo.');
        await updatePassword(password);
        await signOut();
        setPasswordRecovery(false);
        setPassword(''); setConfirmPassword('');
        window.history.replaceState(null, '', window.location.pathname);
        setMessage('Contraseña actualizada. Ya podés iniciar sesión.');
      } else if (forgotMode) {
        await requestPasswordReset(email);
        setMessage('Si el correo está registrado, recibirás un enlace para restablecer tu contraseña. Revisá también spam.');
      } else if (signupMode) {
        await signUp(email, password);
        setMessage('Cuenta solicitada. Revisá tu correo para confirmar el registro. Un administrador debe asignarte una empresa.');
        setSignupMode(false);
      } else {
        await signIn(email, password);
      }
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'No se pudo ingresar');
    } finally {
      setBusy(false);
    }
  };

  const logout = async () => { await signOut(); setMessage(''); };

  const dataError = platformAdminQ.error || membershipQ.error || adminQ.error;
  const errorMessage = message || (dataError instanceof Error ? dataError.message : '');

  if (adminDemo && !passwordRecovery) return <><AdminControl demoMode companies={[]} orders={[]} technicians={[]} /><button className="adm-exit-demo" onClick={() => setAdminDemo(false)}>Salir de demo administrador</button></>;

  if (!passwordRecovery && session && platformAdminQ.data === true) return <PlatformAdminControl userId={session.user.id} email={session.user.email ?? ''} onLogout={logout} />;

  if (!passwordRecovery && session && membership?.role === 'admin') return <AdminControl companies={adminQ.data?.companies ?? []} orders={adminQ.data?.orders ?? []} technicians={adminQ.data?.technicians ?? []} email={session.user.email ?? ''} onLogout={logout} />;

  if (!passwordRecovery && session && membership?.role === 'technician') return <AppShell navItems={[{key:'technician',label:'Portal técnico',icon:HardHat}]} activeSection="technician" onNavigate={()=>{}} brand="Portal técnico" userEmail={session.user.email ?? ''} onLogout={logout}><TechnicianPortal companyId={membership.company_id} userId={session.user.id} membership={membership} /></AppShell>;

  if (!passwordRecovery && session && membership?.role === 'customer') return <AppShell navItems={[{key:'gates',label:'Mis portones',icon:DoorOpen}]} activeSection="gates" onNavigate={()=>{}} brand="Portal cliente" userEmail={session.user.email ?? ''} onLogout={logout}><CustomerPortal companyId={membership.company_id} userId={session.user.id} membership={membership} /></AppShell>;

  if (!supabaseConfigured) return <div className="real-shell"><div className="real-panel"><h1>Conexión pendiente</h1><p>Faltan variables de entorno públicas de Supabase en este despliegue.</p><button onClick={onDemo}>Abrir demostración</button></div></div>;

  if (loading || (!passwordRecovery && session && (platformAdminQ.isLoading || membershipQ.isLoading))) return <div className="real-shell">Cargando...</div>;

  return <div className="real-shell"><header className="real-header"><div className="real-brand"><img src={logo} alt="" className="real-brand-logo" /><div className="real-brand-wordmark"><strong>CONSTELMEC</strong><span>MAINTENANCE</span></div></div></header>
  {(!session || passwordRecovery) ? <main className="real-panel"><div className="real-eyebrow">ACCESO SEGURO</div><h1>{passwordRecovery ? 'Nueva contraseña' : forgotMode ? 'Recuperar contraseña' : signupMode ? 'Crear cuenta' : 'Bienvenido'}</h1><p>{passwordRecovery ? 'Elegí una contraseña nueva para tu cuenta.' : forgotMode ? 'Te enviaremos un enlace para recuperar el acceso.' : 'Ingresá con tu cuenta de mantenimiento.'}</p>
  <form onSubmit={submit}>{!passwordRecovery && <label>Correo electrónico<input type="email" autoComplete="email" required value={email} onChange={e => setEmail(e.target.value)} /></label>}{!forgotMode && <label>{passwordRecovery ? "Nueva contraseña" : "Contraseña"}<div style={{ position: 'relative' }}><input type={showPassword ? 'text' : 'password'} minLength={passwordRecovery ? 8 : 6} autoComplete={passwordRecovery || signupMode ? 'new-password' : 'current-password'} required value={password} onChange={e => setPassword(e.target.value)} style={{ paddingRight: 52 }} /><button type="button" aria-label={showPassword ? 'Ocultar contraseña' : 'Mostrar contraseña'} aria-pressed={showPassword} title={showPassword ? 'Ocultar contraseña' : 'Mostrar contraseña'} onClick={() => setShowPassword(v => !v)} style={{ position: 'absolute', right: 10, top: '50%', transform: 'translateY(-50%)', display: 'flex', alignItems: 'center', justifyContent: 'center', width: 36, height: 36, border: 0, background: 'transparent', color: '#475569', cursor: 'pointer', padding: 0 }}>{showPassword ? <EyeOff size={21} /> : <Eye size={21} />}</button></div></label>}{passwordRecovery && <label>Confirmar contraseña<input type="password" minLength={8} autoComplete="new-password" required value={confirmPassword} onChange={e => setConfirmPassword(e.target.value)} /></label>}<button className="real-primary" disabled={busy}>{busy ? 'Procesando...' : passwordRecovery ? 'Guardar contraseña' : forgotMode ? 'Enviar enlace' : signupMode ? 'Registrarme' : 'Iniciar sesión'} <ArrowRight size={18} /></button></form>
  {errorMessage && <p className="real-message" role="status">{errorMessage}</p>}
  {!passwordRecovery && <><button className="real-link" onClick={() => { setForgotMode(false); setSignupMode(!signupMode); setMessage(''); }}>{signupMode ? 'Ya tengo cuenta' : 'Crear una cuenta'}</button><button className="real-link" style={{marginLeft:12}} onClick={() => { setForgotMode(!forgotMode); setSignupMode(false); setMessage(''); }}>{forgotMode ? 'Volver al inicio' : '¿Olvidaste tu contraseña?'}</button></>}
  {!passwordRecovery && !forgotMode && <><div className="real-demo"><ShieldAlert size={18} /><span>¿Querés recorrer la app sin una cuenta?</span></div><button className="real-outline" onClick={onDemo}>Explorar demostración del técnico</button><button className="real-outline" style={{ marginTop: 10 }} onClick={() => setAdminDemo(true)}>Explorar centro de control (administrador)</button></>}
  </main> : <main className="real-panel real-wide"><div className="real-top"><div><div className="real-eyebrow">SESIÓN AUTENTICADA</div><h1>Hola, {session.user.email?.split('@')[0]}</h1></div><button className="real-link" onClick={logout}><LogOut size={17} /> Salir</button></div>
  {errorMessage && <p className="real-message" role="alert">{errorMessage}</p>}
  {!membership ? <div className="real-empty"><ShieldAlert size={30} /><h2>Cuenta pendiente de asignación</h2><p>Tu acceso está autenticado, pero todavía no pertenecés a una empresa. Un administrador debe asignarte un perfil para consultar los portones.</p></div> : <div className="real-empty"><ShieldAlert size={30}/><h2>Redirigiendo…</h2></div>}
  <button className="real-outline" onClick={onDemo}>Abrir simulador de inspección</button></main>}
  <footer className="real-footer">CONSTELMEC · MAINTENANCE</footer></div>;
}
