import {supabase} from './lib/supabase';
import TechnicianInspection from './TechnicianInspection';
import {useState} from 'react';
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

function OrderCard({item}: {item: TechAssignedOrder}) {
  const [inspect,setInspect]=useState(false);
  const o = item.service_orders;
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
      {inspect && <TechnicianInspection orderId={o.id} gateCode={o.gates?.code ?? 'Portón'} onDone={()=>{setInspect(false);window.location.reload()}}/>}
    </div>
  );
}

function OrdersSection({companyId, userId}: {companyId: string; userId: string}) {
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
  const active = orders.filter(o => o.service_orders && !['cancelled','completed'].includes(o.service_orders.status));

  if (active.length === 0) return (
    <div className="tech-no-profile">
      <CalendarDays size={34}/>
      <h2>Sin órdenes asignadas</h2>
      <p>Cuando un administrador te asigne un servicio, aparecerá aquí.</p>
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
            .map(item => <OrderCard key={item.id} item={item}/>)}
        </div>
      ))}
    </>
  );
}

function GatesSection({companyId}: {companyId: string}) {
  const [selected,setSelected]=useState<{id:string;code:string}|null>(null);
  const [busy,setBusy]=useState<string|null>(null);
  const [error,setError]=useState('');
  const startGate=async (gate:{id:string;code:string})=>{setBusy(gate.id);setError('');try{const {data,error}=await supabase!.rpc('tech_create_spontaneous_order',{p_gate_id:gate.id,p_service_type:'preventive'});if(error)throw error;setSelected({id:data as string,code:gate.code});}catch(e){setError((e as Error).message)}finally{setBusy(null)}};
  const gatesQ = useRealGates(companyId);
  const stateLabel: Record<string,string> = {operational:'Operativo',with_observations:'Con observaciones',out_of_service:'Fuera de servicio'};
  const stateClass: Record<string,string> = {operational:'operational',with_observations:'in_progress',out_of_service:'unassigned'};
  if (gatesQ.isLoading) return <p className="cust-empty">Cargando portones…</p>;
  const gates = gatesQ.data ?? [];
  if (gates.length === 0) return <p className="cust-empty">No hay portones registrados.</p>;
  return (
    <div className="tech-gates-list">
      <p>Seleccioná cualquier portón de tu empresa para comenzar un mantenimiento sin orden previa.</p>
      {error && <p role="alert" className="cust-error">{error}</p>}
      {selected && <TechnicianInspection key={selected.id} orderId={selected.id} gateCode={selected.code} onDone={()=>{setSelected(null);window.location.reload()}}/>}
      {gates.map(g => (
        <div key={g.id} className="tech-gate-row">
          <DoorOpen size={18}/>
          <div>
            <strong>{g.code} · {g.description}</strong>
            <span>{g.facilities?.name ?? 'Sin instalación'}</span>
          </div>
          <button type="button" disabled={!!busy} onClick={()=>startGate({id:g.id,code:g.code})} style={{padding:'10px 14px',borderRadius:9,background:'#c60020',color:'#fff',border:0,fontWeight:700}}>{busy===g.id?'Creando…':'Iniciar mantenimiento'}</button>
          <span className={`adm-status ${stateClass[g.operational_state] ?? ''}`}>
            {stateLabel[g.operational_state] ?? g.operational_state}
          </span>
        </div>
      ))}
    </div>
  );
}

export default function TechnicianPortal({companyId, userId, membership}: Props) {
  const [section, setSection] = useState<Section>('orders');
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
      {section === 'orders' && <OrdersSection companyId={companyId} userId={userId}/>}
      {section === 'gates' && <GatesSection companyId={companyId}/>}
    </div>
  );
}
