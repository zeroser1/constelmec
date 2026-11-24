import {supabase} from './lib/supabase';
import TechnicianInspection from './TechnicianInspection';
import GateHistory from './GateHistory';
import {useEffect,useState} from 'react';
import {useQueryClient} from '@tanstack/react-query';
import {CalendarDays,Clock3,DoorOpen,HardHat,MapPin,ShieldAlert,Wrench} from 'lucide-react';
import {useMyAssignedOrders,useMyTechnicianProfile,useRealGates} from './hooks/useRealData';
import type {Membership} from './lib/types';
import type {TechAssignedOrder} from './lib/types';

type Props = {
  companyId: string;
  userId: string;
  membership: Membership;
};

type Section = 'orders' | 'gates';

const serviceTypeLabel: Record<string, string> = {
  preventive: 'Preventivo', corrective: 'Correctivo',
  installation: 'Instalación', emergency: 'Emergencia',
};
const statusLabel: Record<string, string> = {
  unassigned: 'Sin asignar', scheduled: 'Programado', in_progress: 'En curso',
  completed: 'Finalizado', rescheduled: 'Reprogramado', cancelled: 'Cancelado',
};
const roleLabel = (role: string) => role === 'lead' ? 'Principal' : 'Apoyo';

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

function OrderCard({item,onNavigate}: {item: TechAssignedOrder;onNavigate:()=>void}) {
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
        <span className={`tech-role-badge tech-role-badge--${item.role}`}>{roleLabel(item.role)}</span>
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
      {o.notes && <p className="tech-order-notes">{o.notes}</p>}
      {o.status !== 'completed' && o.status !== 'cancelled' && <button type="button" onClick={()=>setInspect(v=>!v)} style={{marginTop:12,padding:'12px 18px',borderRadius:9,background:'#c60020',color:'white',fontWeight:700,border:0}}>{inspect?'Ocultar chequeo':'Iniciar chequeo'}</button>}
      {o.status === 'completed' && <p className="tech-order-notes">Mantenimiento finalizado.</p>}
      {o.gate_id && <button type="button" onClick={()=>setShowHistory(v=>!v)} style={{marginTop:10,padding:12,borderRadius:9,border:'1px solid #cbd5e1',background:'white'}}>{showHistory?'Cerrar historial':'Ver historial del portón'}</button>}
      {showHistory && o.gate_id && <GateHistory gateId={o.gate_id} orderId={o.status==='completed'?o.id:undefined}/>}
      {inspect && <TechnicianInspection orderId={o.id} gateCode={o.gates?.code ?? 'Portón'} onVisitStarted={setActiveVisitId} onFinished={()=>setInspDone(true)} onDone={()=>{setInspect(false);onNavigate()}}/>}
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
      <p>Iniciá un mantenimiento desde la pestaña de portones; también aparecerán aquí los trabajos finalizados.</p>
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
            .map(item => <OrderCard key={item.id} item={item} onNavigate={onNavigate}/>)}
        </div>
      ))}
    </>
  );
}

function GatesSection({companyId,onNavigate}: {companyId: string;onNavigate:()=>void}) {
  const queryClient=useQueryClient();
  const [selected,setSelected]=useState<{id:string;code:string}|null>(null);
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
  const startGate=async (gate:{id:string;code:string})=>{setBusy(gate.id);setError('');try{const {data,error}=await supabase!.rpc('tech_create_spontaneous_order',{p_gate_id:gate.id,p_service_type:'preventive'});if(error)throw error;await queryClient.invalidateQueries({queryKey:['my-assigned-orders']});setSelected({id:data as string,code:gate.code});setPendingGate(null);}catch(e){setError((e as Error).message)}finally{setBusy(null)}};
  const gatesQ = useRealGates(companyId);
  const stateLabel: Record<string,string> = {operational:'Operativo',with_observations:'Con observaciones',observations:'Con observaciones',out_of_service:'Fuera de servicio'};
  const stateClass: Record<string,string> = {operational:'operational',with_observations:'in_progress',out_of_service:'unassigned'};
  if (gatesQ.isLoading) return <p className="cust-empty">Cargando portones…</p>;
  const gates = gatesQ.data ?? [];
  if (gates.length === 0) return <p className="cust-empty">No hay portones registrados.</p>;
  return (
    <div className="tech-gates-list">
      <p>Seleccioná cualquier portón de tu empresa para comenzar un mantenimiento sin orden previa.</p>
      {error && <p role="alert" className="cust-error">{error}</p>}
      {!selected && pendingGate && <div role="dialog" aria-label="Confirmar portón" style={{padding:16,border:'2px solid #c60020',borderRadius:12,marginBottom:14,background:'#fff'}}><strong>¿Vas a revisar el portón {pendingGate.code}?</strong><p>La orden se creará solamente cuando confirmes.</p><button type="button" disabled={!!busy} onClick={()=>startGate(pendingGate)}>Sí, comenzar</button> <button type="button" disabled={!!busy} onClick={()=>setPendingGate(null)}>Cambiar portón</button></div>}
      {selected && <TechnicianInspection autoStart key={selected.id} orderId={selected.id} gateCode={selected.code} onVisitStarted={setActiveVisitId} onFinished={()=>setInspDone(true)} onDone={()=>{setSelected(null);setActiveVisitId(null);setInspDone(false);onNavigate()}}/>}
      {!selected && gates.map(g => (
        <div key={g.id} className="tech-gate-row tech-gate-row--action" style={{display:'flex',flexWrap:'wrap',gap:10,alignItems:'center'}}>
          <DoorOpen size={18}/>
          <div>
            <strong>{g.code} · {g.description}</strong>
            <span>{g.facilities?.name ?? 'Sin instalación'}</span>
          </div>
          <button type="button" onClick={()=>setHistoryGate(historyGate===g.id?null:g.id)} style={{padding:'10px 12px',borderRadius:9,border:'1px solid #cbd5e1',background:'#fff',color:'#14263e',fontWeight:700,flexShrink:0}}>{historyGate===g.id?'Cerrar historial':'Ver historial'}</button>
          <button className="tech-gate-start" style={{position:'static',flexShrink:0}} type="button" disabled={!!busy} onClick={()=>setPendingGate({id:g.id,code:g.code})}>{busy===g.id?'Creando…':'Iniciar mantenimiento'}</button>
          {historyGate===g.id&&<div style={{width:'100%',flexBasis:'100%'}}><GateHistory gateId={g.id}/></div>}
          <span className={`adm-status ${stateClass[g.operational_state] ?? ''}`}>
            {stateLabel[g.operational_state] ?? g.operational_state}
          </span>
        </div>
      ))}
    </div>
  );
}

export default function TechnicianPortal({companyId, userId, membership}: Props) {
  const [section, setSection] = useState<Section>('gates');
  const queryClient=useQueryClient();
  const navigateOrders=async()=>{await queryClient.invalidateQueries({queryKey:['my-assigned-orders']});setSection('orders');};
  const companyName = membership.companies?.name ?? 'Empresa';

  const navItems: {key: Section; label: string; icon: React.ComponentType<{size:number}>}[] = [
    {key: 'orders', label: 'Mis órdenes', icon: CalendarDays},
    {key: 'gates',  label: 'Iniciar mantenimiento',    icon: DoorOpen},
  ];

  return (
    <div className="cust-shell">
      <div className="cust-company"><HardHat size={20}/><span>{companyName} · Técnico</span></div>
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
      {section === 'orders' && <OrdersSection companyId={companyId} userId={userId} onNavigate={()=>{void navigateOrders()}}/>}
      {section === 'gates' && <GatesSection companyId={companyId} onNavigate={()=>{void navigateOrders()}}/>}
    </div>
  );
}
