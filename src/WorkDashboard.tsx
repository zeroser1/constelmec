import {useState} from 'react';
import {useQuery} from '@tanstack/react-query';
import {Activity,CalendarDays,CheckCircle2,Clock3,DoorOpen,HardHat,MapPin,ShieldAlert,Wrench} from 'lucide-react';
import {supabase} from './lib/supabase';
import GateHistory from './GateHistory';
import type {ServiceOrder} from './AdminControl';

type LiveRow={
 visit_id:string;order_id:string;company_id:string;company_name:string;
 gate_id:string;gate_code:string;gate_description:string;facility_name:string|null;
 technician_name:string;started_at:string;last_seen_at:string;
 controls_done:number;controls_total:number;
};

function todayKey(){
 const d=new Date();
 return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
}
function dayKey(iso:string){
 const d=new Date(iso);
 return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
}
function fmt(iso:string){return new Date(iso).toLocaleTimeString('es-AR',{hour:'2-digit',minute:'2-digit'});}
function fmtDate(iso:string){return new Date(iso).toLocaleDateString('es-AR',{day:'2-digit',month:'2-digit',year:'numeric'});}

const svcLabel:Record<string,string>={preventive:'Preventivo',corrective:'Correctivo',installation:'Instalación',emergency:'Emergencia'};
const statusLabel:Record<string,string>={unassigned:'Sin asignar',scheduled:'Programado',in_progress:'En curso',completed:'Finalizado',rescheduled:'Reprogramado',cancelled:'Cancelado'};

type SubTab='active'|'completed'|'pending';

export default function WorkDashboard({orders,companyId}:{orders:ServiceOrder[];companyId:string|undefined}){
 const [selectedDate,setSelectedDate]=useState(todayKey());
 const [techFilter,setTechFilter]=useState(''); // stores assigned_technician_id
 const [subTab,setSubTab]=useState<SubTab>('active');
 const [historyGate,setHistoryGate]=useState<{gateId:string;orderId?:string}|null>(null);

 const liveQ=useQuery({
  queryKey:['live-inspections','admin',companyId],
  queryFn:async()=>{
   const{data,error}=await supabase!.rpc('monitor_live_inspections');
   if(error)throw new Error(error.message);
   return(data??[]) as LiveRow[];
  },
  enabled:!!supabase,
  refetchInterval:30000,
  refetchIntervalInBackground:false,
  staleTime:3000,
 });

 const liveByOrderId=new Map((liveQ.data??[]).map(r=>[r.order_id,r]));
 const now=Date.now();

 const withTech=techFilter
  ?orders.filter(o=>o.assigned_technician_id===techFilter)
  :orders;

 const isToday=selectedDate===todayKey();
 // Active: on today's view include overdue in_progress orders (scheduled yesterday, still running);
 // on a past-date view include only orders scheduled on that specific day.
 const active=withTech.filter(o=>o.status==='in_progress'&&(isToday||dayKey(o.scheduled_start)===selectedDate));
 const completed=withTech.filter(o=>{
  if(o.status!=='completed')return false;
  return dayKey(o.completed_at??o.scheduled_start)===selectedDate;
 });
 const pending=withTech.filter(o=>{
  if(!['scheduled','unassigned'].includes(o.status))return false;
  return dayKey(o.scheduled_start)===selectedDate;
 });

 const allToday=withTech.filter(o=>{
  if(o.status==='cancelled')return false;
  if(o.status==='in_progress')return isToday||dayKey(o.scheduled_start)===selectedDate;
  const d=o.status==='completed'?(o.completed_at??o.scheduled_start):o.scheduled_start;
  return dayKey(d)===selectedDate;
 });
 const uniqueGates=new Set(allToday.map(o=>o.gate_id??o.gates?.code??o.id)).size;

 const techMap=new Map<string,string>();
 for(const o of orders){if(o.assigned_technician_id&&o.technician_profiles)techMap.set(o.assigned_technician_id,`${o.technician_profiles.first_name} ${o.technician_profiles.last_name}`);}
 const techEntries=[...techMap.entries()].sort((a,b)=>a[1].localeCompare(b[1]));

 return(
  <div className="work-dashboard">
   {/* Filters */}
   <div className="work-filters">
    <label>
     Fecha
     <input type="date" value={selectedDate} onChange={e=>setSelectedDate(e.target.value)}/>
    </label>
    {techEntries.length>0&&<label>
     Técnico
     <select value={techFilter} onChange={e=>setTechFilter(e.target.value)}>
      <option value="">Todos</option>
      {techEntries.map(([id,name])=><option key={id} value={id}>{name}</option>)}
     </select>
    </label>}
   </div>

   {/* Counters */}
   <dl className="work-metrics">
    {[
     {label:'Activos',value:active.length,tone:'active'},
     {label:'Finalizados',value:completed.length,tone:'completed'},
     {label:'Pendientes',value:pending.length,tone:'pending'},
     {label:'Portones únicos',value:uniqueGates,tone:'neutral'},
    ].map(({label,value,tone})=>(
     <div key={tone} className="work-metric" data-tone={tone}>
      <dt>{label}</dt>
      <dd>{value}</dd>
     </div>
    ))}
   </dl>

   {/* Sub-tabs */}
   <div className="work-segments" role="group" aria-label="Estado del mantenimiento">
    {(['active','completed','pending'] as SubTab[]).map(tab=>{
     const labels:Record<SubTab,string>={active:`Activos (${active.length})`,completed:`Finalizados (${completed.length})`,pending:`Pendientes (${pending.length})`};
     return <button key={tab} aria-pressed={subTab===tab} onClick={()=>setSubTab(tab)}>
      {labels[tab]}
     </button>;
    })}
   </div>

   {/* Live error */}
   {liveQ.error&&<p role="alert" className="work-alert"><ShieldAlert size={14}/>No se pudo obtener datos de seguimiento en vivo: {(liveQ.error as Error).message}</p>}

   {/* Gate history modal */}
   {historyGate&&<div className="work-card work-history">
    <div style={{display:'flex',justifyContent:'space-between',alignItems:'center',marginBottom:8}}>
     <strong>Historial del portón</strong>
     <button className="work-action" onClick={()=>setHistoryGate(null)} aria-label="Cerrar historial">✕</button>
    </div>
    <GateHistory gateId={historyGate.gateId} orderId={historyGate.orderId}/>
   </div>}

   {/* Activos */}
   {subTab==='active'&&<>
    {active.length===0&&<p className="work-empty">No hay mantenimientos activos en este momento.</p>}
    {active.map(o=>{
     const live=liveByOrderId.get(o.id);
     const isConnected=live?now-new Date(live.last_seen_at).getTime()<=60000:false;
     const done=live?Number(live.controls_done):0;
     const total=live?Number(live.controls_total):8;
     const techName=live?.technician_name||(o.technician_profiles?`${o.technician_profiles.first_name} ${o.technician_profiles.last_name}`:'Sin técnico');
     return <article key={o.id} className="work-card" data-connection={isConnected?'connected':'delayed'}>
      <div style={{display:'flex',justifyContent:'space-between',gap:8,flexWrap:'wrap',alignItems:'center',marginBottom:6}}>
       <strong style={{fontSize:15}}><DoorOpen size={14} style={{verticalAlign:'middle',marginRight:4}}/>{o.gates?.code??'—'} · {o.gates?.description??'Portón'}</strong>
       <span className="work-connection">{isConnected?'● Conectado':'● Sin señal reciente'}</span>
      </div>
      <div style={{fontSize:13,display:'flex',flexWrap:'wrap',gap:'4px 16px',marginBottom:6}}>
       <span><HardHat size={12} style={{verticalAlign:'middle'}}/> {techName}</span>
       {o.facilities&&<span><MapPin size={12} style={{verticalAlign:'middle'}}/> {o.facilities.name}</span>}
       {live&&<span><Clock3 size={12} style={{verticalAlign:'middle'}}/> Inicio {fmt(live.started_at)} · Última señal {fmt(live.last_seen_at)}</span>}
       <span><Wrench size={12} style={{verticalAlign:'middle'}}/> {svcLabel[o.service_type]??o.service_type}</span>
      </div>
      {live&&<>
       <div style={{fontSize:13,marginBottom:4}}>{done} de {total} controles guardados</div>
       <div role="progressbar" aria-valuenow={done} aria-valuemin={0} aria-valuemax={total}
        className="work-progress">
        <div style={{width:Math.min(100,done/total*100)+'%'}}/>
       </div>
      </>}
      {o.gate_id&&<button onClick={()=>setHistoryGate({gateId:o.gate_id!,orderId:o.id})}
       className="work-action work-card-action">
       Ver historial del portón
      </button>}
     </article>;
    })}
   </>}

   {/* Finalizados */}
   {subTab==='completed'&&<>
    {completed.length===0&&<p className="work-empty">No hay mantenimientos finalizados para esta fecha.</p>}
    {completed.map(o=>(
     <article key={o.id} className="work-card">
      <div style={{display:'flex',justifyContent:'space-between',gap:8,flexWrap:'wrap',alignItems:'center',marginBottom:6}}>
       <strong style={{fontSize:15}}><DoorOpen size={14} style={{verticalAlign:'middle',marginRight:4}}/>{o.gates?.code??'—'} · {o.gates?.description??'Portón'}</strong>
       <span className="adm-status completed">{statusLabel[o.status]??o.status}</span>
      </div>
      <div style={{fontSize:13,display:'flex',flexWrap:'wrap',gap:'4px 16px'}}>
       {o.technician_profiles&&<span><HardHat size={12} style={{verticalAlign:'middle'}}/> {o.technician_profiles.first_name} {o.technician_profiles.last_name}</span>}
       {o.facilities&&<span><MapPin size={12} style={{verticalAlign:'middle'}}/> {o.facilities.name}</span>}
       <span><CheckCircle2 size={12} style={{verticalAlign:'middle'}}/> Finalizado {fmtDate(o.completed_at??o.scheduled_start)}{o.completed_at?` a las ${fmt(o.completed_at)}`:''}</span>
       <span><Wrench size={12} style={{verticalAlign:'middle'}}/> {svcLabel[o.service_type]??o.service_type}</span>
      </div>
      {o.gate_id&&<button onClick={()=>setHistoryGate({gateId:o.gate_id!,orderId:o.id})}
       className="work-action work-card-action">
       Ver historial del portón
      </button>}
     </article>
    ))}
   </>}

   {/* Pendientes */}
   {subTab==='pending'&&<>
    {pending.length===0&&<p className="work-empty">No hay mantenimientos pendientes para esta fecha.</p>}
    {pending.map(o=>(
     <article key={o.id} className="work-card">
      <div style={{display:'flex',justifyContent:'space-between',gap:8,flexWrap:'wrap',alignItems:'center',marginBottom:6}}>
       <strong style={{fontSize:15}}><DoorOpen size={14} style={{verticalAlign:'middle',marginRight:4}}/>{o.gates?.code??'—'} · {o.gates?.description??'Portón'}</strong>
       <span className={'adm-status '+o.status}>{statusLabel[o.status]??o.status}</span>
      </div>
      <div style={{fontSize:13,display:'flex',flexWrap:'wrap',gap:'4px 16px'}}>
       {o.technician_profiles&&<span><HardHat size={12} style={{verticalAlign:'middle'}}/> {o.technician_profiles.first_name} {o.technician_profiles.last_name}</span>}
       {o.facilities&&<span><MapPin size={12} style={{verticalAlign:'middle'}}/> {o.facilities.name}</span>}
       <span><CalendarDays size={12} style={{verticalAlign:'middle'}}/> {fmt(o.scheduled_start)} – {fmt(o.scheduled_end)}</span>
       <span><Wrench size={12} style={{verticalAlign:'middle'}}/> {svcLabel[o.service_type]??o.service_type}</span>
      </div>
     </article>
    ))}
   </>}

   <p className="work-note">
    <Activity size={12}/>Datos en vivo actualizados cada 30 segundos · La señal del técnico se envía cada 30 segundos
   </p>
  </div>
 );
}
