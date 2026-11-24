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
 const [techFilter,setTechFilter]=useState('');
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
  refetchInterval:5000,
  staleTime:3000,
 });

 const liveByOrderId=new Map((liveQ.data??[]).map(r=>[r.order_id,r]));
 const now=Date.now();

 const withTech=techFilter
  ?orders.filter(o=>o.technician_profiles&&`${o.technician_profiles.first_name} ${o.technician_profiles.last_name}`===techFilter)
  :orders;

 const active=withTech.filter(o=>o.status==='in_progress');
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
  const d=o.status==='completed'?(o.completed_at??o.scheduled_start):o.scheduled_start;
  return dayKey(d)===selectedDate;
 });
 const uniqueGates=new Set(allToday.map(o=>o.gate_id??o.gates?.code??o.id)).size;

 const techNames=[...new Set(orders.filter(o=>o.technician_profiles).map(o=>`${o.technician_profiles!.first_name} ${o.technician_profiles!.last_name}`))].sort();

 const card={border:'1px solid #e2e8f0',borderRadius:12,padding:14,marginTop:10,background:'#fff'} as const;

 return(
  <div style={{color:'#14263e'}}>
   {/* Filters */}
   <div style={{display:'flex',gap:12,flexWrap:'wrap',marginBottom:14,alignItems:'flex-end'}}>
    <label style={{fontSize:13,fontWeight:600}}>
     Fecha
     <input type="date" value={selectedDate} onChange={e=>setSelectedDate(e.target.value)}
      style={{display:'block',padding:'6px 10px',border:'1px solid #d1dbe5',borderRadius:7,fontSize:14,marginTop:4}}/>
    </label>
    {techNames.length>0&&<label style={{fontSize:13,fontWeight:600}}>
     Técnico
     <select value={techFilter} onChange={e=>setTechFilter(e.target.value)}
      style={{display:'block',padding:'6px 10px',border:'1px solid #d1dbe5',borderRadius:7,fontSize:14,marginTop:4}}>
      <option value="">Todos</option>
      {techNames.map(n=><option key={n} value={n}>{n}</option>)}
     </select>
    </label>}
   </div>

   {/* Counters */}
   <div style={{display:'flex',gap:10,flexWrap:'wrap',marginBottom:16}}>
    {[
     {label:'Activos',value:active.length,color:'#1876d2'},
     {label:'Finalizados',value:completed.length,color:'#166534'},
     {label:'Pendientes',value:pending.length,color:'#92400e'},
     {label:'Portones únicos',value:uniqueGates,color:'#5b21b6'},
    ].map(({label,value,color})=>(
     <div key={label} style={{background:'#f8fafc',border:'1px solid #e2e8f0',borderRadius:10,padding:'10px 16px',textAlign:'center',minWidth:100}}>
      <div style={{fontSize:22,fontWeight:800,color}}>{value}</div>
      <div style={{fontSize:12,color:'#64748b'}}>{label}</div>
     </div>
    ))}
   </div>

   {/* Sub-tabs */}
   <div style={{display:'flex',gap:0,marginBottom:14,border:'1px solid #e2e8f0',borderRadius:9,overflow:'hidden',width:'fit-content'}}>
    {(['active','completed','pending'] as SubTab[]).map(tab=>{
     const labels:Record<SubTab,string>={active:`Activos (${active.length})`,completed:`Finalizados (${completed.length})`,pending:`Pendientes (${pending.length})`};
     return <button key={tab} onClick={()=>setSubTab(tab)}
      style={{padding:'9px 18px',border:'none',background:subTab===tab?'#1876d2':'#fff',color:subTab===tab?'#fff':'#14263e',fontWeight:subTab===tab?700:500,fontSize:13,cursor:'pointer'}}>
      {labels[tab]}
     </button>;
    })}
   </div>

   {/* Live error */}
   {liveQ.error&&<p role="alert" style={{color:'#b91c1c',display:'flex',gap:6,alignItems:'center',fontSize:13,marginBottom:10}}><ShieldAlert size={14}/>No se pudo obtener datos de seguimiento en vivo: {(liveQ.error as Error).message}</p>}

   {/* Gate history modal */}
   {historyGate&&<div style={{border:'1px solid #d8e2ee',borderRadius:12,padding:14,margin:'10px 0',background:'#f8fafc'}}>
    <div style={{display:'flex',justifyContent:'space-between',alignItems:'center',marginBottom:8}}>
     <strong>Historial del portón</strong>
     <button onClick={()=>setHistoryGate(null)} style={{border:'none',background:'none',cursor:'pointer',color:'#64748b',fontSize:16}}>✕</button>
    </div>
    <GateHistory gateId={historyGate.gateId} orderId={historyGate.orderId}/>
   </div>}

   {/* Activos */}
   {subTab==='active'&&<>
    {active.length===0&&<p style={{color:'#64748b',padding:'20px 0',textAlign:'center'}}>No hay mantenimientos activos en este momento.</p>}
    {active.map(o=>{
     const live=liveByOrderId.get(o.id);
     const isConnected=live?now-new Date(live.last_seen_at).getTime()<=60000:false;
     const done=live?Number(live.controls_done):0;
     const total=live?Number(live.controls_total):8;
     const techName=live?.technician_name||(o.technician_profiles?`${o.technician_profiles.first_name} ${o.technician_profiles.last_name}`:'Sin técnico');
     return <article key={o.id} style={{...card,borderLeft:`4px solid ${isConnected?'#166534':'#92400e'}`}}>
      <div style={{display:'flex',justifyContent:'space-between',gap:8,flexWrap:'wrap',alignItems:'center',marginBottom:6}}>
       <strong style={{fontSize:15}}><DoorOpen size={14} style={{verticalAlign:'middle',marginRight:4}}/>{o.gates?.code??'—'} · {o.gates?.description??'Portón'}</strong>
       <span style={{fontSize:13,fontWeight:700,color:isConnected?'#166534':'#92400e'}}>{isConnected?'● Conectado':'● Sin señal reciente'}</span>
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
        style={{height:7,background:'#e2e8f0',borderRadius:8,overflow:'hidden'}}>
        <div style={{height:'100%',width:Math.min(100,done/total*100)+'%',background:'#1876d2',transition:'width .3s'}}/>
       </div>
      </>}
      {o.gate_id&&<button onClick={()=>setHistoryGate({gateId:o.gate_id!,orderId:o.id})}
       style={{marginTop:10,padding:'8px 12px',border:'1px solid #d1dbe5',borderRadius:7,background:'#fff',fontSize:12,cursor:'pointer'}}>
       Ver historial del portón
      </button>}
     </article>;
    })}
   </>}

   {/* Finalizados */}
   {subTab==='completed'&&<>
    {completed.length===0&&<p style={{color:'#64748b',padding:'20px 0',textAlign:'center'}}>No hay mantenimientos finalizados para esta fecha.</p>}
    {completed.map(o=>(
     <article key={o.id} style={card}>
      <div style={{display:'flex',justifyContent:'space-between',gap:8,flexWrap:'wrap',alignItems:'center',marginBottom:6}}>
       <strong style={{fontSize:15}}><DoorOpen size={14} style={{verticalAlign:'middle',marginRight:4}}/>{o.gates?.code??'—'} · {o.gates?.description??'Portón'}</strong>
       <span className="adm-status completed">{statusLabel[o.status]??o.status}</span>
      </div>
      <div style={{fontSize:13,display:'flex',flexWrap:'wrap',gap:'4px 16px'}}>
       {o.technician_profiles&&<span><HardHat size={12} style={{verticalAlign:'middle'}}/> {o.technician_profiles.first_name} {o.technician_profiles.last_name}</span>}
       {o.facilities&&<span><MapPin size={12} style={{verticalAlign:'middle'}}/> {o.facilities.name}</span>}
       <span><CheckCircle2 size={12} style={{verticalAlign:'middle'}}/> {fmtDate(o.completed_at??o.scheduled_start)}</span>
       <span><Wrench size={12} style={{verticalAlign:'middle'}}/> {svcLabel[o.service_type]??o.service_type}</span>
      </div>
      {o.gate_id&&<button onClick={()=>setHistoryGate({gateId:o.gate_id!,orderId:o.id})}
       style={{marginTop:10,padding:'8px 12px',border:'1px solid #d1dbe5',borderRadius:7,background:'#fff',fontSize:12,cursor:'pointer'}}>
       Ver historial del portón
      </button>}
     </article>
    ))}
   </>}

   {/* Pendientes */}
   {subTab==='pending'&&<>
    {pending.length===0&&<p style={{color:'#64748b',padding:'20px 0',textAlign:'center'}}>No hay mantenimientos pendientes para esta fecha.</p>}
    {pending.map(o=>(
     <article key={o.id} style={card}>
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

   <p style={{fontSize:12,color:'#94a3b8',marginTop:16,display:'flex',alignItems:'center',gap:6}}>
    <Activity size={12}/>Datos en vivo actualizados cada 5 segundos · La señal del técnico se envía cada 15 segundos
   </p>
  </div>
 );
}
