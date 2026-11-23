import {useEffect,useState} from 'react';
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
 const [loading,setLoading]=useState(true);
 const [showMissing,setShowMissing]=useState(false);
 const [correction,setCorrection]=useState<{key:string;label:string;result:Result}|null>(null);
 const [reason,setReason]=useState('');
 const draftKey=`constelmec:inspection-draft:${orderId}`;
 useEffect(()=>{try{const raw=sessionStorage.getItem(draftKey);if(raw){const saved=JSON.parse(raw) as Record<string,string>;setNotes(n=>({...n,...saved}));}}catch{/* unavailable storage */}},[draftKey]);
 useEffect(()=>{let alive=true;void (async()=>{const {data,error}=await supabase!.rpc('tech_get_pilot_progress',{p_order_id:orderId});if(!alive)return;if(error){setError(error.message)}else if(data?.visit_id){setVisitId(data.visit_id);const r:Record<string,Result>={};const n:Record<string,string>={};for(const c of data.controls||[]){r[c.key]=c.result;n[c.key]=c.note||''}setResults(r);setNotes({...n,...(()=>{try{return JSON.parse(sessionStorage.getItem(draftKey)||'{}')}catch{return {}}})()});setSavedNotes(n)}setLoading(false)})();return()=>{alive=false}},[orderId]);

 const start=async()=>{setBusy(true);setError('');try{const {data,error}=await supabase!.rpc('tech_start_pilot_order',{p_order_id:orderId});if(error)throw error;setVisitId(data as string)}catch(e){setError((e as Error).message)}finally{setBusy(false)}};
 const save=async(key:string,label:string,result:Result)=>{if(!visitId)return;if(results[key]==='fault'&&result!=='fault'){setCorrection({key,label,result});setReason('');setError('');return;}if(result==='fault'&&(notes[key]||'').trim().length<10){setNotes(n=>({...n,[key]:n[key]||''}));setError(`Describí la falla de ${label} con al menos 10 caracteres.`);document.getElementById(`note-${key}`)?.focus();return;}if(results[key]&&notes[key]?.trim()&&notes[key].trim().length<10){setError(`Escribí al menos 10 caracteres en la observación de ${label} para registrar el cambio.`);document.getElementById(`note-${key}`)?.focus();return;}setBusy(true);setError('');setMessage('');try{const {error}=await supabase!.rpc('tech_save_pilot_control',{p_order_id:orderId,p_visit_id:visitId,p_key:key,p_label:label,p_result:result,p_note:notes[key]||null});if(error)throw error;setResults(v=>({...v,[key]:result}));setSavedNotes(v=>({...v,[key]:notes[key]||''}));setMessage('Cambios guardados')}catch(e){const msg=(e as Error).message;setError(msg.includes('inspection_corrections_reason_check')?'La explicación del cambio es demasiado corta. Escribí al menos 10 caracteres.':msg)}finally{setBusy(false)}};
 const saveCorrection=async()=>{if(!visitId||!correction)return;if(reason.trim().length<10||reason.trim()===notes[correction.key]?.trim()){setError('Explicá qué hiciste para corregir la falla (mínimo 10 caracteres, diferente de la descripción de la falla).');return;}setBusy(true);setError('');try{const {error}=await supabase!.rpc('tech_save_pilot_correction',{p_order_id:orderId,p_visit_id:visitId,p_key:correction.key,p_result:correction.result,p_reason:reason.trim()});if(error)throw error;setResults(v=>({...v,[correction.key]:correction.result}));setCorrection(null);setReason('');setMessage('Corrección registrada con su motivo')}catch(e){setError((e as Error).message)}finally{setBusy(false)}};
 const missing=checks.filter(([key])=>!results[key]);
 const unsaved=checks.filter(([key])=>results[key] && (notes[key]||'') !== (savedNotes[key]||''));
 const invalidFaults=checks.filter(([key])=>results[key]==='fault'&&!savedNotes[key]?.trim());
 const finish=async()=>{if(!visitId)return;if(missing.length||unsaved.length||invalidFaults.length){setShowMissing(true);setError(missing.length?`Faltan ${missing.length} controles por completar.`:'Hay observaciones sin guardar.');const first=missing[0]?.[0]??invalidFaults[0]?.[0]??unsaved[0]?.[0];document.getElementById(`inspection-${first}`)?.scrollIntoView({behavior:'smooth',block:'center'});document.getElementById(`inspection-${first}`)?.focus({preventScroll:true});return;}setShowMissing(false);setBusy(true);setError('');try{const {error}=await supabase!.rpc('tech_finish_pilot_order',{p_order_id:orderId,p_visit_id:visitId});if(error)throw error;setFinished(true);try{sessionStorage.removeItem(draftKey)}catch{/* unavailable storage */}setMessage('Mantenimiento finalizado y guardado')}catch(e){setError((e as Error).message)}finally{setBusy(false)}};
 return <section style={{border:'1px solid #cbd5e1',borderRadius:16,padding:18,marginTop:12,background:'#fff'}}>
  <h3>Inspección · {gateCode}</h3>
  <p>Registrá el estado de cada componente y sus observaciones.</p>
  {error&&<p role="alert" style={{color:'#b91c1c'}}>{error}</p>}
  {message&&<p role="status">{message}</p>}
  {loading?<p>Cargando inspección guardada…</p>:!visitId?<button type="button" disabled={busy} onClick={start}>Iniciar mantenimiento</button>:finished?<button type="button" onClick={onDone}>Volver a mis órdenes</button>:<>
   {correction&&<div role="dialog" aria-label="Justificar corrección" style={{border:'2px solid #c60020',padding:16,borderRadius:12,marginBottom:14,background:'#fff7f7'}}><strong>¿Qué hiciste para corregir la falla de {correction.label}?</strong><p>Descripción original: {notes[correction.key]}</p><textarea aria-label="Motivo de corrección" value={reason} onChange={e=>setReason(e.target.value)} placeholder="Ej.: Se ajustó el rodillo y se verificó el funcionamiento" maxLength={1000} rows={3} style={{width:'100%',boxSizing:'border-box',padding:10}}/><p>Escribí al menos 10 caracteres. La descripción de la falla se conservará.</p><button type="button" disabled={busy} onClick={saveCorrection}>Guardar corrección</button> <button type="button" disabled={busy} onClick={()=>setCorrection(null)}>Cancelar</button></div>}
   {checks.map(([key,label])=><div key={key} id={`inspection-${key}`} tabIndex={-1} style={{padding:'18px 0',borderBottom:'1px solid #e2e8f0',borderLeft:showMissing&&!results[key]?'4px solid #b91c1c':'4px solid transparent',paddingLeft:10,scrollMarginTop:24}}>
    <strong>{label}</strong>
    <div style={{display:'flex',gap:8,flexWrap:'wrap',marginTop:8}}>
     {([['ok','OK'],['fault','Falla'],['not_applicable','No aplica'],['unverifiable','No verificable']] as [Result,string][]).map(([value,text])=><button key={value} type="button" disabled={busy} onClick={()=>save(key,label,value)} style={{padding:'10px 13px',borderRadius:10,border:results[key]===value?'2px solid currentColor':'1px solid #cbd5e1',background:results[key]===value?({ok:'#dcfce7',fault:'#fee2e2',not_applicable:'#e2e8f0',unverifiable:'#fef3c7'}[value]):'#fff',color:results[key]===value?({ok:'#166534',fault:'#b91c1c',not_applicable:'#334155',unverifiable:'#92400e'}[value]):'#14263e',fontWeight:results[key]===value?700:500}}>{text}</button>)}
    </div>
    {(results[key]==='fault'||!results[key])&&<p style={{fontSize:13,color:results[key]==='fault'?'#b91c1c':'#64748b'}}>{results[key]==='fault'?'Obligatorio: explicá qué problema encontraste.':'Podés agregar una observación.'}</p>}
    <textarea id={`note-${key}`} aria-label={'Observaciones: '+label} placeholder="Observaciones del componente" value={notes[key]||''} onChange={e=>setNotes(n=>{const next={...n,[key]:e.target.value};try{sessionStorage.setItem(draftKey,JSON.stringify(next))}catch{/* unavailable storage */}return next})} rows={2} maxLength={1000} style={{width:'100%',marginTop:10,padding:12,borderRadius:9,border:'1px solid #cbd5e1',fontFamily:'inherit',boxSizing:'border-box'}}/>
    <small style={{display:'block',color:'#64748b'}}>{(notes[key]||'').length}/1000 caracteres. {results[key]==='fault'?'La falla requiere al menos 10 caracteres.':''}</small>
    {results[key] && notes[key]!==savedNotes[key] && <button type="button" disabled={busy} onClick={()=>save(key,label,results[key])}>Guardar observación</button>}
    {results[key]&&<small style={{display:'block',marginTop:8,color:'#64748b'}}>Estado guardado: {({ok:'Correcto',fault:'Falla',not_applicable:'No aplica',unverifiable:'No verificable'} as Record<Result,string>)[results[key]]}</small>}
   </div>)}
   <p>{Object.keys(results).length} de {checks.length} controles guardados.</p>
   {showMissing && (missing.length>0||unsaved.length>0||invalidFaults.length>0) && <div role="alert" style={{background:'#fff7ed',border:'1px solid #fdba74',padding:12,borderRadius:10,marginBottom:12}}><strong>Antes de finalizar:</strong>{missing.length>0&&<p>Completá {missing.length} {missing.length===1?'control pendiente':'controles pendientes'}: {missing.map(([,label])=>label).join(', ')}.</p>}{invalidFaults.length>0&&<p>Describí las fallas de: {invalidFaults.map(([,label])=>label).join(', ')}.</p>}{unsaved.length>0&&<p>Guardá las observaciones de: {unsaved.map(([,label])=>label).join(', ')}.</p>}</div>}
   <button type="button" disabled={busy||!!correction} onClick={finish}>Finalizar mantenimiento</button>
  </>}
 </section>;
}