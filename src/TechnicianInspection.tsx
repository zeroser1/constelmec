import {useState} from 'react';
import {supabase} from './lib/supabase';

const checks = [
 ['structure','Integridad y estructura'],['guides','Guías y rodillos'],['motor','Motor y transmisión'],
 ['electrical','Tablero eléctrico'],['photocells','Fotocélulas'],['emergency','Parada de emergencia'],
 ['opening','Prueba de apertura'],['closing','Prueba de cierre']
] as const;
type Result='ok'|'fault'|'not_applicable'|'unverifiable';
export default function TechnicianInspection({orderId,gateCode,onDone}:{orderId:string;gateCode:string;onDone:()=>void}) {
 const [visitId,setVisitId]=useState<string|null>(null);
 const [results,setResults]=useState<Record<string,Result>>({});
 const [notes,setNotes]=useState<Record<string,string>>({});
 const [busy,setBusy]=useState(false);
 const [error,setError]=useState('');
 const [message,setMessage]=useState('');
 const [finished,setFinished]=useState(false);
 const start=async()=>{setBusy(true);setError('');try{const {data,error}=await supabase!.rpc('tech_start_pilot_order',{p_order_id:orderId});if(error)throw error;setVisitId(data as string)}catch(e){setError((e as Error).message)}finally{setBusy(false)}};
 const save=async(key:string,label:string,result:Result)=>{if(!visitId)return;setBusy(true);setError('');setMessage('');try{const {error}=await supabase!.rpc('tech_save_pilot_control',{p_order_id:orderId,p_visit_id:visitId,p_key:key,p_label:label,p_result:result,p_note:notes[key]||null});if(error)throw error;setResults(v=>({...v,[key]:result}));setMessage('Control guardado en Supabase')}catch(e){setError((e as Error).message)}finally{setBusy(false)}};
 const finish=async()=>{if(!visitId)return;setBusy(true);setError('');try{const {error}=await supabase!.rpc('tech_finish_pilot_order',{p_order_id:orderId,p_visit_id:visitId});if(error)throw error;setFinished(true);setMessage('Mantenimiento finalizado y guardado')}catch(e){setError((e as Error).message)}finally{setBusy(false)}};
 return <section style={{border:'1px solid #cbd5e1',borderRadius:16,padding:18,marginTop:12,background:'#fff'}}>
  <h3>Chequeo real · {gateCode}</h3>
  <p>Los resultados se guardan en Supabase y quedan asociados al portón.</p>
  {error&&<p role="alert" style={{color:'#b91c1c'}}>{error}</p>}
  {message&&<p role="status">{message}</p>}
  {!visitId?<button type="button" disabled={busy} onClick={start}>Iniciar mantenimiento</button>:finished?<button type="button" onClick={onDone}>Volver a mis órdenes</button>:<>
   {checks.map(([key,label])=><div key={key} style={{padding:'12px 0',borderBottom:'1px solid #e2e8f0'}}>
    <strong>{label}</strong>
    <div style={{display:'flex',gap:8,flexWrap:'wrap',marginTop:8}}>
     {([['ok','OK'],['fault','Falla'],['not_applicable','N/A'],['unverifiable','No verificable']] as [Result,string][]).map(([value,text])=><button key={value} type="button" disabled={busy} onClick={()=>save(key,label,value)} style={{padding:'8px 12px',borderRadius:8,border:'1px solid #94a3b8',background:results[key]===value?'#dbeafe':'#fff',color:'#14263e'}}>{text}</button>)}
    </div>
    <input aria-label={'Observaciones: '+label} placeholder="Observaciones (opcional, guardar al elegir resultado)" value={notes[key]||''} onChange={e=>setNotes(n=>({...n,[key]:e.target.value}))} style={{width:'100%',marginTop:8,padding:10}}/>
    {results[key]&&<small>Guardado: {results[key]}</small>}
   </div>)}
   <p>{Object.keys(results).length} de {checks.length} controles guardados</p>
   <button type="button" disabled={busy||Object.keys(results).length===0} onClick={finish}>Finalizar mantenimiento</button>
  </>}
 </section>;
}