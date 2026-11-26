import {supabase} from './lib/supabase';
import TechnicianInspection from './TechnicianInspection';
import GateHistory from './GateHistory';
import {useEffect,useMemo,useState} from 'react';
import {useQueryClient} from '@tanstack/react-query';
import {CalendarDays,Clock3,DoorOpen,HardHat,MapPin,MessageCircle,Send,ShieldAlert,Wrench} from 'lucide-react';
import {useMyAssignedOrders,useMyTechnicianProfile,useRealGates,useTechnicianCompanies} from './hooks/useRealData';
import type {Membership} from './lib/types';
import type {TechAssignedOrder} from './lib/types';

type Props = {
  companyId: string;
  userId: string;
  membership: Membership;
};

type Section = 'orders' | 'gates' | 'observations';

const serviceTypeLabel: Record<string, string> = {
  preventive: 'Preventivo', corrective: 'Correctivo',
  installation: 'Instalación', emergency: 'Emergencia',
};
const statusLabel: Record<string, string> = {
  unassigned: 'Sin asignar', scheduled: 'Programado', in_progress: 'En curso',
  completed: 'Finalizado', rescheduled: 'Reprogramado', cancelled: 'Cancelado',
};

function fmtTime(iso: string) {
  return new Date(iso).toLocaleTimeString('es-AR', {hour: '2-digit', minute: '2-digit'});
}
function fmtDayHeader(iso: string) {
  return new Date(iso).toLocaleDateString('es-AR', {weekday: 'long', day: 'numeric', month: 'long', year: 'numeric'});
}
function dayKey(iso: string) {
  const d = new Date(iso);
  return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
}

type TechObs={id:string;gate_code:string;gate_desc:string;body:string;author_name:string;created_at:string;reply_count:number;unread_count:number};
type TechConvItem={item_type:string;item_id:string;author_role:string;body:string;created_at:string};
function ObservationsInbox({companyId}:{companyId:string}){
 const [items,setItems]=useState<TechObs[]|null>(null);
 const [loading,setLoading]=useState(true);
 const [err,setErr]=useState('');
 const [expanded,setExpanded]=useState<string|null>(null);
 const [conv,setConv]=useState<Record<string,TechConvItem[]>>({});
 const [convLoading,setConvLoading]=useState<string|null>(null);
 const [reply,setReply]=useState<Record<string,string>>({});
 const [sending,setSending]=useState<string|null>(null);
 const [sendErr,setSendErr]=useState<Record<string,string>>({});
 const fmtDt=(iso:string)=>new Date(iso).toLocaleDateString('es-AR',{day:'2-digit',month:'2-digit',year:'numeric'});
 const roleLabel=(r:string)=>r==='technician'?'Técnico':r==='admin'?'Admin':'Cliente';
 useEffect(()=>{
  setLoading(true);setErr('');
  void(async()=>{try{
   const{data,error}=await supabase!.rpc('tech_list_gate_observations',{p_company_id:companyId});
   if(error)throw new Error(error.message.includes('does not exist')||error.message.includes('no existe')?'Módulo de observaciones en preparación.':error.message);
   setItems((data??[]) as TechObs[]);
  }catch(e){setErr((e as Error).message);}finally{setLoading(false);}})();
 },[companyId]);
 const toggleConv=async(id:string)=>{
  if(expanded===id){setExpanded(null);return;}
  setExpanded(id);
  if(conv[id])return;
  setConvLoading(id);
  try{
   const{data,error}=await supabase!.rpc('get_observation_conversation',{p_company_id:companyId,p_observation_id:id});
   if(error)throw new Error(error.message);
   setConv(c=>({...c,[id]:(data??[]) as TechConvItem[]}));
  }catch{/* silent */}finally{setConvLoading(null);}
 };
 const sendReply=async(obsId:string)=>{
  const body=(reply[obsId]||'').trim();
  if(!body)return;
  setSending(obsId);setSendErr(e=>({...e,[obsId]:''}));
  try{
   const{error}=await supabase!.rpc('tech_reply_to_observation',{p_company_id:companyId,p_observation_id:obsId,p_body:body});
   if(error)throw new Error(error.message.includes('does not exist')||error.message.includes('no existe')?'Función de respuesta en preparación.':error.message);
   setReply(r=>({...r,[obsId]:''}));
   // reload conversation
   const{data:data2}=await supabase!.rpc('get_observation_conversation',{p_company_id:companyId,p_observation_id:obsId});
   if(data2)setConv(c=>({...c,[obsId]:data2 as TechConvItem[]}));
  }catch(e){setSendErr(se=>({...se,[obsId]:(e as Error).message}));}finally{setSending(null);}
 };
 if(loading)return <p className="cust-empty">Cargando observaciones…</p>;
 if(err)return <p className="cust-error"><ShieldAlert size={15}/>{err}</p>;
 if(items&&items.length===0)return <div className="tech-no-profile"><MessageCircle size={34}/><h2>Sin observaciones</h2><p>No hay observaciones pendientes de tus portones asignados.</p></div>;
 return <div style={{display:'flex',flexDirection:'column',gap:8,marginTop:8}}>
  {(items??[]).map(o=><div key={o.id} style={{border:'1px solid #d1dbe5',borderRadius:12,padding:'14px 16px',background:'#fff'}}>
   <div style={{display:'flex',alignItems:'flex-start',justifyContent:'space-between',gap:8,flexWrap:'wrap'}}>
    <div style={{flex:1}}>
     <strong style={{fontSize:13,color:'#14263e'}}>{o.gate_code}</strong>
     <span style={{fontSize:12,color:'#64748b',marginLeft:6}}>{o.gate_desc}</span>
     {o.unread_count>0&&<span style={{marginLeft:8,background:'#c60020',color:'white',borderRadius:10,fontSize:10,fontWeight:700,padding:'1px 6px'}}>{o.unread_count}</span>}
     <p style={{margin:'6px 0 0',fontSize:13,color:'#334155'}}>{o.body}</p>
     <p style={{margin:'4px 0 0',fontSize:11,color:'#94a3b8'}}>{o.author_name} · {fmtDt(o.created_at)} · {o.reply_count} {o.reply_count===1?'respuesta':'respuestas'}</p>
    </div>
    <button type="button" onClick={()=>void toggleConv(o.id)} style={{flexShrink:0,display:'inline-flex',alignItems:'center',gap:4,fontSize:12,color:'#1a5eb8',background:'#eff6ff',border:'1px solid #bfdbfe',borderRadius:7,padding:'6px 10px',cursor:'pointer'}}>
     <MessageCircle size={14}/>{expanded===o.id?'Ocultar':'Responder'}
    </button>
   </div>
   {expanded===o.id&&<div style={{marginTop:10,paddingTop:10,borderTop:'1px solid #e2e8f0'}}>
    {convLoading===o.id&&<p style={{fontSize:12,color:'#64748b'}}>Cargando hilo…</p>}
    {(conv[o.id]??[]).map(it=><div key={it.item_id} style={{marginBottom:8,fontSize:12,display:'flex',gap:6}}>
     <strong style={{flexShrink:0,color:it.author_role==='technician'?'#1d4ed8':it.author_role==='admin'?'#166534':'#64748b'}}>{roleLabel(it.author_role)}:</strong>
     <span style={{color:'#334155'}}>{it.body}</span>
    </div>)}
    <div style={{display:'flex',gap:8,marginTop:10,alignItems:'flex-start'}}>
     <textarea value={reply[o.id]||''} onChange={e=>setReply(r=>({...r,[o.id]:e.target.value}))} rows={2} maxLength={2000}
       placeholder="Escribí tu respuesta…" style={{flex:1,padding:10,borderRadius:8,border:'1px solid #cbd5e1',fontSize:13,fontFamily:'inherit',resize:'vertical'}}/>
     <button type="button" disabled={!reply[o.id]?.trim()||sending===o.id} onClick={()=>void sendReply(o.id)}
       style={{padding:'10px 14px',borderRadius:8,background:reply[o.id]?.trim()?'#1a5eb8':'#8295a8',color:'white',border:'none',fontWeight:700,cursor:reply[o.id]?.trim()?'pointer':'default',display:'flex',alignItems:'center',gap:4,fontSize:13}}>
      <Send size={14}/>{sending===o.id?'…':'Enviar'}
     </button>
    </div>
    {sendErr[o.id]&&<p style={{fontSize:12,color:'#b91c1c',marginTop:4}}>{sendErr[o.id]}</p>}
   </div>}
  </div>)}
 </div>;
}

function OrderCard({item,companyId,onNavigate}: {item: TechAssignedOrder;companyId:string;onNavigate:()=>void}) {
  const [inspect,setInspect]=useState(false);
  const [showHistory,setShowHistory]=useState(false);
  const [activeVisitId,setActiveVisitId]=useState<string|null>(null);
  const [inspDone,setInspDone]=useState(false);
  const o = item.service_orders;

  // Heartbeat lives here — survives TechnicianInspection being hidden/shown
  useEffect(()=>{
    if(!activeVisitId||inspDone||!o?.id)return;
    let live=true;
    const beat=async()=>{const{error}=await supabase!.rpc('tech_live_heartbeat',{p_order_id:o.id,p_visit_id:activeVisitId});if(error&&live)console.warn('Heartbeat failed:',error.message);};
    void beat();
    const timer=window.setInterval(()=>{void beat();},30000);
    return()=>{live=false;window.clearInterval(timer);};
  },[activeVisitId,inspDone,o?.id]);
  if (!o) return null;
  return (
    <div className={`tech-order-card tech-order-card--${o.status}`}>
      <div className="tech-order-top">
        <span className={'adm-status ' + o.status}>{statusLabel[o.status] ?? o.status}</span>
      </div>
      <div className="tech-order-type">
        <Wrench size={14}/>{serviceTypeLabel[o.service_type] ?? o.service_type}
      </div>
      <div className="tech-order-meta">
        <span><Clock3 size={13}/>{fmtTime(o.scheduled_start)} – {fmtTime(o.scheduled_end)}</span>
        {o.facilities && <span><MapPin size={13}/>{o.facilities.name}</span>}
        {o.gates && <span><DoorOpen size={13}/>{o.gates.code} · {o.gates.description}</span>}
      </div>
      <p className="tech-order-identifier">Orden #{o.id.slice(0,8)}</p>
      {o.notes && <p className="tech-order-notes">{o.notes}</p>}
      {o.status !== 'completed' && o.status !== 'cancelled' && <button type="button" onClick={()=>setInspect(v=>!v)} style={{marginTop:12,padding:'12px 18px',borderRadius:9,background:'#c60020',color:'white',fontWeight:700,border:0}}>{inspect?'Ocultar chequeo':'Iniciar chequeo'}</button>}
      {o.status === 'completed' && <p className="tech-order-notes">Mantenimiento finalizado.</p>}
      {o.gate_id && <button type="button" onClick={()=>setShowHistory(v=>!v)} style={{marginTop:10,padding:12,borderRadius:9,border:'1px solid #cbd5e1',background:'white'}}>{showHistory?'Cerrar historial':'Ver historial del portón'}</button>}
      {showHistory && o.gate_id && <GateHistory gateId={o.gate_id} orderId={o.status==='completed'?o.id:undefined}/>}
      {inspect && <TechnicianInspection orderId={o.id} gateCode={o.gates?.code ?? 'Portón'} companyId={companyId} onVisitStarted={setActiveVisitId} onFinished={()=>setInspDone(true)} onDone={()=>{setInspect(false);onNavigate()}}/>}
    </div>
  );
}

function OrdersSection({companyId, userId,onNavigate}: {companyId: string; userId: string;onNavigate:()=>void}) {
  const profileQ = useMyTechnicianProfile(userId, companyId);
  const ordersQ  = useMyAssignedOrders(companyId, profileQ.data?.id);

  if (profileQ.isLoading || ordersQ.isLoading) {
    return <p className="cust-empty">Cargando órdenes…</p>;
  }

  if (profileQ.error) return (
    <p className="cust-error"><ShieldAlert size={15}/>{(profileQ.error as Error).message}</p>
  );
  if (ordersQ.error) return (
    <p className="cust-error"><ShieldAlert size={15}/>{(ordersQ.error as Error).message}</p>
  );

  if (!profileQ.data) return (
    <div className="tech-no-profile">
      <HardHat size={34}/>
      <h2>Sin perfil técnico</h2>
      <p>Tu usuario no tiene un perfil de técnico asociado. Contactá al administrador de tu empresa.</p>
    </div>
  );

  const orders = ordersQ.data ?? [];
  const active = orders.filter(o => o.service_orders && o.service_orders.status !== 'cancelled');

  if (active.length === 0) return (
    <div className="tech-no-profile">
      <CalendarDays size={34}/>
      <h2>Sin mantenimientos registrados</h2>
      <p>Las órdenes programadas para esta empresa aparecerán aquí, junto con los trabajos finalizados.</p>
    </div>
  );

  // Group active orders by day
  const byDay: Record<string, TechAssignedOrder[]> = {};
  for (const item of active) {
    if (!item.service_orders) continue;
    const key = dayKey(item.service_orders.scheduled_start);
    if (!byDay[key]) byDay[key] = [];
    byDay[key].push(item);
  }
  const days = Object.keys(byDay).sort();

  return (
    <>
      <p className="tech-profile-name">
        <HardHat size={16}/>{profileQ.data.first_name} {profileQ.data.last_name}
        {profileQ.data.specialty ? ` · ${profileQ.data.specialty}` : ''}
      </p>
      {days.map(day => (
        <div key={day} className="tech-day-group">
          <div className="tech-day-header">{fmtDayHeader(day + 'T12:00:00')}</div>
          {byDay[day]
            .sort((a, b) =>
              (a.service_orders?.scheduled_start ?? '').localeCompare(b.service_orders?.scheduled_start ?? ''))
            .map(item => <OrderCard key={item.id} item={item} companyId={companyId} onNavigate={onNavigate}/>)}
        </div>
      ))}
    </>
  );
}

function GatesSection({companyId, userId, onNavigate}: {companyId: string; userId: string; onNavigate:()=>void}) {
  const queryClient=useQueryClient();
  const [selected,setSelected]=useState<{id:string;code:string;gateId?:string}|null>(null);
  const [pendingGate,setPendingGate]=useState<{id:string;code:string}|null>(null);
  const [historyGate,setHistoryGate]=useState<string|null>(null);
  const [busy,setBusy]=useState<string|null>(null);
  const [error,setError]=useState('');
  const [activeVisitId,setActiveVisitId]=useState<string|null>(null);
  const [inspDone,setInspDone]=useState(false);

  // Heartbeat for spontaneous orders — survives section nav hiding the checklist
  useEffect(()=>{
    if(!activeVisitId||inspDone||!selected?.id)return;
    let live=true;
    const beat=async()=>{const{error}=await supabase!.rpc('tech_live_heartbeat',{p_order_id:selected.id,p_visit_id:activeVisitId});if(error&&live)console.warn('Heartbeat failed:',error.message);};
    void beat();
    const timer=window.setInterval(()=>{void beat();},30000);
    return()=>{live=false;window.clearInterval(timer);};
  },[activeVisitId,inspDone,selected?.id]);
  const startGate=async (gate:{id:string;code:string})=>{setBusy(gate.id);setError('');try{const {data,error}=await supabase!.rpc('tech_create_spontaneous_order',{p_gate_id:gate.id,p_service_type:'preventive'});if(error)throw error;await queryClient.invalidateQueries({queryKey:['my-assigned-orders']});setSelected({id:data as string,code:gate.code,gateId:gate.id});setPendingGate(null);}catch(e){setError((e as Error).message)}finally{setBusy(null)}};
  const gatesQ = useRealGates(companyId);
  const profileQ = useMyTechnicianProfile(userId, companyId);
  const ordersQ  = useMyAssignedOrders(companyId, profileQ.data?.id);
  // Map gateId → orderId for active in_progress orders (used to show "Continuar" button)
  const activeGateOrders = useMemo(()=>{
    const m = new Map<string,string>();
    for (const item of ordersQ.data ?? []) {
      if (item.service_orders?.status==='in_progress' && item.service_orders.gate_id)
        m.set(item.service_orders.gate_id, item.service_orders.id);
    }
    return m;
  },[ordersQ.data]);
  const stateLabel: Record<string,string> = {operational:'Operativo',with_observations:'Con observaciones',observations:'Con observaciones',out_of_service:'Fuera de servicio'};
  const stateClass: Record<string,string> = {operational:'operational',with_observations:'in_progress',out_of_service:'unassigned'};
  if (gatesQ.isLoading || profileQ.isLoading || ordersQ.isLoading) return <p className="cust-empty">Cargando portones…</p>;
  const gates = gatesQ.data ?? [];
  if (gates.length === 0) return <p className="cust-empty">No hay portones registrados.</p>;
  return (
    <div className="tech-gates-list">
      <p>Seleccioná un portón de tu empresa para continuar un trabajo en curso o iniciar un mantenimiento espontáneo.</p>
      {error && <p role="alert" className="cust-error">{error}</p>}
      {!selected && pendingGate && <div role="dialog" aria-label="Confirmar portón" style={{padding:16,border:'2px solid #c60020',borderRadius:12,marginBottom:14,background:'#fff'}}><strong>¿Vas a revisar el portón {pendingGate.code}?</strong><p>La orden se creará solamente cuando confirmes.</p><button type="button" disabled={!!busy} onClick={()=>startGate(pendingGate)}>Sí, comenzar</button> <button type="button" disabled={!!busy} onClick={()=>setPendingGate(null)}>Cambiar portón</button></div>}
      {selected && <TechnicianInspection autoStart key={selected.id} orderId={selected.id} gateCode={selected.code} companyId={companyId} onVisitStarted={setActiveVisitId} onFinished={()=>setInspDone(true)} onDone={()=>{setSelected(null);setActiveVisitId(null);setInspDone(false);onNavigate()}}/>}
      {!selected && gates.map(g => (
        <div key={g.id} className="tech-gate-row tech-gate-row--action" style={{display:'flex',flexWrap:'wrap',gap:10,alignItems:'center'}}>
          <DoorOpen size={18}/>
          <div>
            <strong>{g.code} · {g.description}</strong>
            <span>{g.facilities?.name ?? 'Sin instalación'}</span>
          </div>
          <button type="button" onClick={()=>setHistoryGate(historyGate===g.id?null:g.id)} style={{padding:'10px 12px',borderRadius:9,border:'1px solid #cbd5e1',background:'#fff',color:'#14263e',fontWeight:700,flexShrink:0}}>{historyGate===g.id?'Cerrar historial':'Ver historial'}</button>
          <button className="tech-gate-start" style={{position:'static',flexShrink:0}} type="button" disabled={!!busy} onClick={()=>{const activeId=activeGateOrders.get(g.id);if(activeId){setSelected({id:activeId,code:g.code,gateId:g.id});}else{setPendingGate({id:g.id,code:g.code});}}}>{busy===g.id?'Cargando…':activeGateOrders.has(g.id)?'Continuar inspección':'Iniciar mantenimiento'}</button>
          {historyGate===g.id&&<div style={{width:'100%',flexBasis:'100%'}}><GateHistory gateId={g.id}/></div>}
          <span className={`adm-status ${stateClass[g.operational_state] ?? ''}`}>
            {stateLabel[g.operational_state] ?? g.operational_state}
          </span>
        </div>
      ))}
    </div>
  );
}

export default function TechnicianPortal({companyId: homeCompanyId, userId}: Props) {
  const [section, setSection] = useState<Section>('gates');
  const queryClient=useQueryClient();
  const navigateOrders=async()=>{await queryClient.invalidateQueries({queryKey:['my-assigned-orders']});setSection('orders');};
  const companiesQ = useTechnicianCompanies(userId);
  const [selectedCompanyId, setSelectedCompanyId] = useState(homeCompanyId);
  const companies = companiesQ.data ?? [];
  const activeCompany = companies.find(company => company.id === selectedCompanyId) ?? companies[0];

  if (companiesQ.isPending) return <p>Cargando empresas habilitadas…</p>;
  if (companiesQ.isError) return <p role="alert">No se pudieron verificar tus empresas habilitadas.</p>;
  if (!activeCompany) return <p role="status">No tenés empresas habilitadas.</p>;
  const { id: companyId, name: companyName } = activeCompany;

  const navItems: {key: Section; label: string; icon: React.ComponentType<{size:number}>}[] = [
    {key: 'orders', label: 'Mis órdenes', icon: CalendarDays},
    {key: 'gates',  label: 'Iniciar mantenimiento', icon: DoorOpen},
    {key: 'observations', label: 'Observaciones', icon: MessageCircle},
  ];

  return (
    <div className="cust-shell">
      <div className="cust-company">
        <HardHat size={20}/>
        {companies.length > 1
          ? <select aria-label="Empresa" value={companyId} onChange={event => setSelectedCompanyId(event.target.value)}>
              {companies.map(company => <option key={company.id} value={company.id}>{company.name}</option>)}
            </select>
          : <span>{companyName} · Técnico</span>}
      </div>
      <div className="tech-nav">
        {navItems.map(({key, label, icon: Icon}) => (
          <button
            key={key}
            className={`tech-nav-btn${section === key ? ' active' : ''}`}
            onClick={() => setSection(key)}
          >
            <Icon size={16}/>{label}
          </button>
        ))}
      </div>
      {section === 'orders' && <OrdersSection key={companyId} companyId={companyId} userId={userId} onNavigate={()=>{void navigateOrders()}}/>}
      {section === 'gates' && <GatesSection key={companyId} companyId={companyId} userId={userId} onNavigate={()=>{void navigateOrders()}}/>}
      {section === 'observations' && <ObservationsInbox key={companyId} companyId={companyId}/>}
    </div>
  );
}
