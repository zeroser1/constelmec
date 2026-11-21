import { useEffect, useState } from 'react';
import { ArrowRight, Building2, HardHat, LogOut, ShieldAlert } from 'lucide-react';
import './real-access.css';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string | undefined;
type Session = {access_token:string;refresh_token:string;expires_at?:number;user:{id:string;email?:string}};
type Membership = {company_id:string;role:'admin'|'technician'|'customer';companies:{name:string}|null};
type Gate = {id:string;code:string;description:string;model:string|null;serial_number:string|null;operational_state:string;facilities:{name:string}|null};
const store='constelmec:auth:v1';
const headers=(token?:string)=>({'apikey':key||'','Content-Type':'application/json',...(token?{'Authorization':'Bearer '+token}:{})});
async function authRequest(path:string,body:object) {
 const response=await fetch(url+'/auth/v1/'+path,{method:'POST',headers:headers(),body:JSON.stringify(body)});
 const data=await response.json();if(!response.ok)throw new Error(data.msg||data.error_description||data.message||'No se pudo autenticar');return data;
}
async function api(path:string,token:string) {
 const response=await fetch(url+'/rest/v1/'+path,{headers:headers(token)});
 const data=await response.json();if(!response.ok)throw new Error(data.message||'Error al consultar Supabase');return data;
}
export default function RealAccess({onDemo}:{onDemo:()=>void}) {
 const [session,setSession]=useState<Session|null>(null);
 const [email,setEmail]=useState('');const [password,setPassword]=useState('');
 const [signup,setSignup]=useState(false);const [busy,setBusy]=useState(false);const [message,setMessage]=useState('');
 const [membership,setMembership]=useState<Membership|null>(null);
 const [gates,setGates]=useState<Gate[]>([]);
 const [loading,setLoading]=useState(true);
 useEffect(()=>{try{const raw=localStorage.getItem(store);if(raw){const parsed=JSON.parse(raw) as Session;if(parsed.access_token&&parsed.refresh_token)setSession(parsed);}}catch{localStorage.removeItem(store)}setLoading(false);},[]);
 useEffect(()=>{if(!session)return;let cancelled=false;
 const load=async()=>{try{
  let current=session;
  if(current.expires_at && current.expires_at<Date.now()/1000+60){
   const refreshed=await authRequest('token?grant_type=refresh_token',{refresh_token:current.refresh_token}) as Session & {expires_in:number};
   current={...refreshed,expires_at:Math.floor(Date.now()/1000)+refreshed.expires_in};
   if(cancelled)return;localStorage.setItem(store,JSON.stringify(current));setSession(current);
  }
  const rows=await api('memberships?select=company_id,role,companies(name)&active=eq.true&limit=1',current.access_token) as Membership[];
  if(cancelled)return;
  setMembership(rows[0]||null);
  if(rows[0])setGates(await api('gates?select=id,code,description,model,serial_number,operational_state,facilities(name)&company_id=eq.'+encodeURIComponent(rows[0].company_id)+'&order=code.asc',current.access_token) as Gate[]);
  setMessage('');
 }catch(error){if(!cancelled)setMessage(error instanceof Error?error.message:'Error de conexión');}};
 void load();return()=>{cancelled=true};},[session?.access_token]);
 const submit=async(e:React.FormEvent)=>{e.preventDefault();setBusy(true);setMessage('');try{
  if(signup){await authRequest('signup',{email,password});setMessage('Cuenta solicitada. Revisá tu correo para confirmar el registro. Un administrador debe asignarte una empresa.');setSignup(false);}
  else{const result=await authRequest('token?grant_type=password',{email,password}) as Session & {expires_in:number};const next={...result,expires_at:Math.floor(Date.now()/1000)+result.expires_in};localStorage.setItem(store,JSON.stringify(next));setSession(next);}
 }catch(error){setMessage(error instanceof Error?error.message:'No se pudo ingresar');}finally{setBusy(false)}};
 const logout=()=>{if(session)void authRequest('logout',{}).catch(()=>undefined);localStorage.removeItem(store);setSession(null);setMembership(null);setGates([]);setMessage('');};
 if(!url||!key)return <div className="real-shell"><div className="real-panel"><h1>Conexión pendiente</h1><p>Faltan variables de entorno públicas de Supabase en este despliegue.</p><button onClick={onDemo}>Abrir demostración</button></div></div>;
 if(loading)return <div className="real-shell">Cargando...</div>;
 return <div className="real-shell"><header className="real-header"><strong>CONSTELMEC</strong><span>MAINTENANCE</span></header>
 {!session?<main className="real-panel"><div className="real-eyebrow">ACCESO SEGURO</div><h1>{signup?'Crear cuenta':'Bienvenido'}</h1><p>Ingresá con tu cuenta de mantenimiento.</p>
 <form onSubmit={submit}><label>Correo electrónico<input type="email" autoComplete="email" required value={email} onChange={e=>setEmail(e.target.value)}/></label><label>Contraseña<input type="password" minLength={6} autoComplete={signup?'new-password':'current-password'} required value={password} onChange={e=>setPassword(e.target.value)}/></label><button className="real-primary" disabled={busy}>{busy?'Procesando...':signup?'Registrarme':'Iniciar sesión'} <ArrowRight size={18}/></button></form>
 {message&&<p className="real-message" role="status">{message}</p>}
 <button className="real-link" onClick={()=>{setSignup(!signup);setMessage('')}}>{signup?'Ya tengo cuenta':'Crear una cuenta'}</button>
 <div className="real-demo"><ShieldAlert size={18}/><span>¿Querés recorrer la app sin una cuenta?</span></div><button className="real-outline" onClick={onDemo}>Explorar demostración</button>
 </main>:<main className="real-panel real-wide"><div className="real-top"><div><div className="real-eyebrow">SESIÓN AUTENTICADA</div><h1>Hola, {session.user.email?.split('@')[0]}</h1></div><button className="real-link" onClick={logout}><LogOut size={17}/> Salir</button></div>
 {message&&<p className="real-message" role="alert">{message}</p>}
 {!membership?<div className="real-empty"><ShieldAlert size={30}/><h2>Cuenta pendiente de asignación</h2><p>Tu acceso está autenticado, pero todavía no pertenecés a una empresa. Un administrador debe asignarte un perfil para consultar los portones.</p></div>:<><div className="real-company"><Building2 size={23}/><div><strong>{membership.companies?.name||'Empresa'}</strong><span>{membership.role==='technician'?'Técnico':membership.role==='customer'?'Cliente':'Administrador'}</span></div></div><h2>Portones registrados ({gates.length})</h2>{gates.length?gates.map(g=><article className="real-gate" key={g.id}><HardHat size={21}/><div><strong>{g.code} · {g.description}</strong><p>{g.facilities?.name||'Sin instalación'} · {g.model||'Sin modelo'}</p><small>Estado: {g.operational_state} · Serie: {g.serial_number||'—'}</small></div></article>):<p className="real-empty">Todavía no hay portones registrados para esta empresa.</p>}<p className="real-note">Vista de datos reales de solo lectura. La edición de inspecciones se habilitará con operaciones transaccionales y permisos verificados.</p></>}
 <button className="real-outline" onClick={onDemo}>Abrir simulador de inspección</button></main>}
 <footer className="real-footer">CONSTELMEC · MAINTENANCE</footer></div>;
}
