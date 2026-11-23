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
 const [savedNotes,setSavedNotes]=useState<Record<string,string>>({});
 const start=async()=>{setBusy(true);setError('');try{const {data,error}=await supabase!.rpc('tech_start_pilot_order',{p_order_id:orderId});if(error)throw error;setVisitId(data as string)}catch(e){setError((e as Error).message)}finally{setBusy(false)}};
 const save=async(key:string,label:string,result:Result)=>{if(!visitId)return;setBusy(true);setError('');setMessage('');try{const {error}=await supabase!.rpc('tech_save_pilot_control',{p_order_id:orderId,p_visit_id:visitId,p_key:key,p_label:label,p_result:result,p_note:notes[key]||null});if(error)throw error;setResults(v=>({...v,[key]:result}));setSavedNotes(v=>({...v,[key]:notes[key]||''}));setMessage('Cambios guardados')}catch(e){setError((e as Error).message)}finally{setBusy(false)}};
 const finish=async()=>{if(!visitId)return;setBusy(true);setError('');try{const {error}=await supabase!.rpc('tech_finish_pilot_order',{p_order_id:orderId,p_visit_id:visitId});if(error)throw error;setFinished(true);setMessage('Mantenimiento finalizado y guardado')}catch(e){setError((e as Error).message)}finally{setBusy(false)}};
 return <section style={{border:'1px solid #cbd5e1',borderRadius:16,padding:18,marginTop:12,background:'#fff'}}>
  <h3>Inspección · {gateCode}</h3>
  <p>Registrá el estado de cada componente y sus observaciones.</p>
  {error&&<p role="alert" style={{color:'#b91c1c'}}>{error}</p>}
  {message&&<p role="status">{message}</p>}
  {!visitId?<button type="button" disabled={busy} onClick={start}>Iniciar mantenimiento</button>:finished?<button type="button" onClick={onDone}>Volver a mis órdenes</button>:<>
   {checks.map(([key,label])=><div key={key} style={{padding:'18px 0',borderBottom:'1px solid #e2e8f0'}}>
    <strong>{label}</strong>
    <div style={{display:'flex',gap:8,flexWrap:'wrap',marginTop:8}}>
     {([['ok','OK'],['fault','Falla'],['not_applicable','N/A'],['unverifiable','No verificable']] as [Result,string][]).map(([value,text])=><button key={value} type="button" disabled={busy} onClick={()=>save(key,label,value)} style={{padding:'10px 13px',borderRadius:10,border:results[key]===value?'2px solid currentColor':'1px solid #cbd5e1',background:results[key]===value?({ok:'#dcfce7',fault:'#fee2e2',not_applicable:'#e2e8f0',unverifiable:'#fef3c7'}[value]):'#fff',color:results[key]===value?({ok:'#166534',fault:'#b91c1c',not_applicable:'#334155',unverifiable:'#92400e'}[value]):'#14263e',fontWeight:results[key]===value?700:500}}>{text}</button>)}
    </div>
    <textarea aria-label={'Observaciones: '+label} placeholder="Observaciones del componente" value={notes[key]||''} onChange={e=>setNotes(n=>({...n,[key]:e.target.value}))} rows={2} style={{width:'100%',marginTop:10,padding:12,borderRadius:9,border:'1px solid #cbd5e1',fontFamily:'inherit',boxSizing:'border-box'}}/>
    {results[key] && notes[key]!==savedNotes[key] && <button type="button" disabled={busy} onClick={()=>save(key,label,results[key])}>Guardar observación</button>}
    {results[key]&&<small style={{display:'block',marginTop:8,color:'#64748b'}}>Estado guardado: {({ok:'Correcto',fault:'Falla',not_applicable:'No aplica',unverifiable:'No verificable'} as Record<Result,string>)[results[key]]}</small>}
   </div>)}
   <p>{Object.keys(results).length} de {checks.length} controles guardados</p>
   <button type="button" disabled={busy||Object.keys(results).length===0} onClick={finish}>Finalizar mantenimiento</button>
  </>}
 </section>;
}