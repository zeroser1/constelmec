import {useQuery} from '@tanstack/react-query';
import {Activity,Clock3,HardHat,DoorOpen,ShieldAlert} from 'lucide-react';
import {supabase} from './lib/supabase';

type LiveRow={
 visit_id:string;order_id:string;company_id:string;company_name:string;
 gate_id:string;gate_code:string;gate_description:string;facility_name:string|null;
 technician_name:string;started_at:string;last_seen_at:string;
 controls_done:number;controls_total:number;
};
const stamp=(value:string)=>new Date(value).toLocaleTimeString('es-AR',{hour:'2-digit',minute:'2-digit'});
export default function LiveInspections({role,companyId}:{role:'admin'|'customer';companyId?:string}){
 const q=useQuery({
  queryKey:['live-inspections',role,companyId],
  queryFn:async()=>{
   const {data,error}=await supabase!.rpc('monitor_live_inspections');
   if(error)throw new Error(error.message);
   return (data??[]) as LiveRow[];
  },
  refetchInterval:5000,refetchIntervalInBackground:false,staleTime:3000,
 });
 const now=Date.now();
 const rows=(q.data??[]).filter(v=>!companyId||v.company_id===companyId);
 const active=rows.filter(v=>now-new Date(v.last_seen_at).getTime()<=60000);
 const interrupted=rows.filter(v=>now-new Date(v.last_seen_at).getTime()>60000);
 return <section aria-label="Seguimiento de mantenimientos en vivo" style={{border:'1px solid #d8e2ee',background:'#fff',borderRadius:16,padding:18,margin:'16px 0',color:'#14263e'}}>
  <div style={{display:'flex',justifyContent:'space-between',alignItems:'center',flexWrap:'wrap',gap:10,marginBottom:10}}>
   <div><h2 style={{margin:0,fontSize:20,display:'flex',alignItems:'center',gap:8}}><Activity size={20}/> Mantenimientos en vivo</h2>
    <p style={{margin:'5px 0',fontSize:13,color:'#64748b'}}>Actualización automática cada 5 segundos · actividad del técnico cada 15 segundos</p></div>
   <span role="status" style={{padding:'6px 10px',background:'#eff6ff',borderRadius:20,fontSize:13,fontWeight:700}}>{active.length} {active.length===1?'mantenimiento activo':'mantenimientos activos'}</span>
  </div>
  {q.isLoading&&<p>Consultando actividad…</p>}
  {q.error&&<p role="alert" style={{color:'#b91c1c',display:'flex',gap:6}}><ShieldAlert size={16}/> No se pudo consultar la actividad: {(q.error as Error).message}</p>}
  {!q.isLoading&&!q.error&&rows.length===0&&<p style={{color:'#64748b'}}>No hay mantenimientos con actividad reciente. Una orden programada o abierta no se considera activa hasta que el técnico esté trabajando en el checklist.</p>}
  {[...active,...interrupted].map(v=>{
   const live=now-new Date(v.last_seen_at).getTime()<=60000;
   const done=Number(v.controls_done)||0,total=Number(v.controls_total)||8;
   return <article key={v.visit_id} style={{border:'1px solid #e2e8f0',borderRadius:12,padding:14,marginTop:10,background:live?'#f8fffb':'#fffaf0'}}>
    <div style={{display:'flex',justifyContent:'space-between',gap:8,flexWrap:'wrap',alignItems:'center'}}>
     <strong style={{fontSize:16}}><DoorOpen size={15} style={{verticalAlign:'middle'}}/> {v.gate_code} · {v.gate_description}</strong>
     <span style={{color:live?'#166534':'#92400e',fontSize:13,fontWeight:700}}>{live?'● Trabajando ahora':'● Sin señal reciente'}</span>
    </div>
    {role==='admin'&&<p style={{fontSize:13,margin:'7px 0'}}>{v.company_name} · {v.facility_name??'Instalación'}</p>}
    {role==='customer'&&v.facility_name&&<p style={{fontSize:13,margin:'7px 0'}}>{v.facility_name}</p>}
    <p style={{fontSize:13,margin:'7px 0',display:'flex',alignItems:'center',gap:5}}><HardHat size={14}/>{v.technician_name||'Técnico asignado'}</p>
    <div style={{display:'flex',justifyContent:'space-between',fontSize:13,gap:8,flexWrap:'wrap'}}><span>{done} de {total} controles guardados</span><span><Clock3 size={13} style={{verticalAlign:'middle'}}/> Inicio {stamp(v.started_at)} · Última señal {stamp(v.last_seen_at)}</span></div>
    <div role="progressbar" aria-label={'Progreso de '+v.gate_code} aria-valuenow={done} aria-valuemin={0} aria-valuemax={total} style={{height:8,background:'#e2e8f0',borderRadius:10,overflow:'hidden',marginTop:8}}><div style={{height:'100%',width:Math.min(100,Math.max(0,done/total*100))+'%',background:'#1876d2',transition:'width .3s'}}/></div>
    {!live&&<p style={{fontSize:12,color:'#92400e',margin:'8px 0 0'}}>El mantenimiento no figura como finalizado, pero no se recibe actividad reciente. No implica que el técnico siga trabajando.</p>}
   </article>;
  })}
  <p style={{fontSize:12,color:'#64748b',margin:'12px 0 0'}}>El progreso refleja controles guardados, no movimientos físicos ni ubicación GPS. Si se interrumpe la conexión, la actividad deja de considerarse en vivo después de 60 segundos.</p>
 </section>;
}
