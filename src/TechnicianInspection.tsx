import {useEffect,useRef,useState} from 'react';
import {useQueryClient} from '@tanstack/react-query';
import {supabase} from './lib/supabase';
import MaintenancePhoto from './components/MaintenancePhoto';
import type {TechAssignedOrder} from './lib/types';

type PhotoState={id:string;path:string;bucket?:string;phase:string;status:'uploading'|'confirmed'|'failed'};
type PhotoSlot={photo_id:string;storage_path:string;bucket:string};

const checks = [
 ['structure','Integridad y estructura'],['guides','Guías y rodillos'],['motor','Motor y transmisión'],
 ['electrical','Tablero eléctrico'],['photocells','Fotocélulas'],['emergency','Parada de emergencia'],
 ['opening','Prueba de apertura'],['closing','Prueba de cierre']
] as const;
type Result='ok'|'fault'|'critical'|'not_applicable'|'unverifiable'|'resolved'|'partial';
type RepairFields={problem_found:string;intervention:string;verification:string;remaining_work:string};
export default function TechnicianInspection({orderId,gateCode,companyId,onDone,autoStart=false,onVisitStarted,onFinished}:{orderId:string;gateCode:string;companyId?:string;onDone:()=>void;autoStart?:boolean;onVisitStarted?:(visitId:string)=>void;onFinished?:()=>void}) {
 const queryClient=useQueryClient();
 const autoStartAttempted=useRef(false);
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
 const [correctedNote,setCorrectedNote]=useState('');
 const [correctionIdempotencyKey,setCorrectionIdempotencyKey]=useState<string|null>(null);
 const [photos,setPhotos]=useState<Record<string,PhotoState[]>>({});
 const [photoErr,setPhotoErr]=useState<Record<string,string>>({});
 const [repair,setRepair]=useState<{mode:'control'|'correction';key:string;label:string;result:Result}|null>(null);
 const [repairFields,setRepairFields]=useState<RepairFields>({problem_found:'',intervention:'',verification:'',remaining_work:''});
 const [repairReason,setRepairReason]=useState('');
 const [repairKey,setRepairKey]=useState<string|null>(null);
 const draftKey=`constelmec:inspection-draft:${orderId}`;
 const isRepair=(r:Result)=>r==='resolved'||r==='partial';
 const isFaultLike=(r:Result)=>r==='fault'||r==='critical';
 const openRepairModal=(mode:'control'|'correction',key:string,label:string,result:Result)=>{
  setRepair({mode,key,label,result});
  setRepairFields({problem_found:'',intervention:'',verification:'',remaining_work:''});
  setRepairReason('');setRepairKey(crypto.randomUUID());if(mode==='correction')setCorrectionIdempotencyKey(crypto.randomUUID());setError('');
 };
 // Load photos when visitId becomes known (backend may not exist yet — degrades silently)
 useEffect(()=>{
  if(!visitId||!companyId)return;
  void(async()=>{try{
   const{data}=await supabase!.rpc('get_visit_maintenance_photos',{p_company_id:companyId,p_visit_id:visitId});
   if(!data||!Array.isArray(data))return;
   const grouped:Record<string,PhotoState[]>={};
   for (const p of data as Array<{id:string;control_key:string;phase:string;storage_path:string;bucket:string}>) {
    (grouped[p.control_key] ??= []).push({id:p.id,path:p.storage_path,bucket:p.bucket,phase:p.phase,status:'confirmed'});
   }
   setPhotos(grouped);
  }catch{/* backend not ready */}})();
 },[visitId,companyId]);
 const uploadPhoto=async(key:string,phase:string,file:File)=>{
  if(!visitId||!companyId){setPhotoErr(e=>({...e,[key]:'Iniciá la inspección antes de subir fotos.'}));return;}
  if(file.size>10*1024*1024){setPhotoErr(e=>({...e,[key]:'El archivo supera los 10 MB. Usá una foto más pequeña.'}));return;}
  const allowed=['image/jpeg','image/png','image/webp','image/heic','image/heif'];
  if(!allowed.includes(file.type)){setPhotoErr(e=>({...e,[key]:`Formato no permitido (${file.type||'desconocido'}). Usá JPEG, PNG o WEBP.`}));return;}
  setPhotoErr(e=>({...e,[key]:''}));
  const tempId='tmp-'+Math.random().toString(36).slice(2);
  setPhotos(p=>({...p,[key]:[...(p[key]??[]),{id:tempId,path:'',phase,status:'uploading'}]}));
  try{
   // Step 1: get secure upload path from RPC
   const{data:slot,error:slotErr}=await supabase!.rpc('tech_request_maintenance_photo_slot',{
    p_company_id:companyId,p_order_id:orderId,p_visit_id:visitId,p_control_key:key,p_phase:phase,
    p_mime_type:file.type,p_file_size_bytes:file.size,p_original_filename:file.name
   });
   if(slotErr)throw new Error(slotErr.message.includes('does not exist')||slotErr.message.includes('no existe')?'Función de fotos aún no disponible':slotErr.message);
   if(!slot)throw new Error('Función de fotos aún no disponible');
   const{photo_id,storage_path,bucket}=slot as PhotoSlot;
   // Step 2: upload to storage
   const{error:upErr}=await supabase!.storage.from(bucket).upload(storage_path,file,{upsert:false});
   if(upErr)throw new Error(upErr.message);
   // Step 3: confirm
   const{error:confErr}=await supabase!.rpc('tech_confirm_maintenance_photo',{p_photo_id:photo_id});
   if(confErr)throw new Error(confErr.message);
   setPhotos(p=>({...p,[key]:(p[key]??[]).map(ph=>ph.id===tempId?{id:photo_id,path:storage_path,phase,status:'confirmed',bucket}:ph)}));
  }catch(e){
   setPhotos(p=>({...p,[key]:(p[key]??[]).filter(ph=>ph.id!==tempId)}));
   setPhotoErr(pe=>({...pe,[key]:(e as Error).message}));
  }
 };
 useEffect(()=>{try{const raw=sessionStorage.getItem(draftKey);if(raw){const saved=JSON.parse(raw) as Record<string,string>;setNotes(n=>({...n,...saved}));}}catch{/* unavailable storage */}},[draftKey]);
 useEffect(()=>{let alive=true;void (async()=>{const {data,error}=await supabase!.rpc('tech_get_pilot_progress',{p_order_id:orderId});if(!alive)return;if(error){setError(error.message)}else if(data?.visit_id){setVisitId(data.visit_id);onVisitStarted?.(data.visit_id);const r:Record<string,Result>={};const n:Record<string,string>={};for(const c of data.controls||[]){r[c.key]=c.result;n[c.key]=c.current_note||c.note||''}setResults(r);setNotes({...n,...(()=>{try{return JSON.parse(sessionStorage.getItem(draftKey)||'{}')}catch{return {}}})()});setSavedNotes(n)}setLoading(false)})();return()=>{alive=false}},[orderId]);

 const start=async()=>{setBusy(true);setError('');try{const {data,error}=await supabase!.rpc('tech_start_pilot_order',{p_order_id:orderId});if(error)throw error;const vid=data as string;setVisitId(vid);onVisitStarted?.(vid);}catch(e){setError((e as Error).message)}finally{setBusy(false)}};
 useEffect(()=>{if(autoStart&&!loading&&!visitId&&!autoStartAttempted.current){autoStartAttempted.current=true;void start();}},[autoStart,loading,visitId]);
 const save=async(key:string,label:string,result:Result)=>{
  if(!visitId)return;
  if((notes[key]||'').length>1000){setError(`La observación de ${label} supera los 1000 caracteres. Acortala en ${(notes[key]||'').length-1000} ${(notes[key]||'').length-1000===1?'carácter':'caracteres'}.`);document.getElementById(`note-${key}`)?.focus();return;}
  if(isFaultLike(result)&&(notes[key]||'').trim().length<10){setNotes(n=>({...n,[key]:n[key]||''}));setError(`Describí la falla de ${label} con al menos 10 caracteres.`);document.getElementById(`note-${key}`)?.focus();return;}
  if(results[key]&&notes[key]?.trim()&&notes[key].trim().length<10){setError(`Escribí al menos 10 caracteres en la observación de ${label} para registrar el cambio.`);document.getElementById(`note-${key}`)?.focus();return;}
  // Pre-existing control: ALL changes (incl. same-state note edits) go through the auditable correction path
  if(results[key]){
   if(isRepair(result)){openRepairModal('correction',key,label,result);return;}
   if(result===results[key]&&(notes[key]||'')===(savedNotes[key]||''))return;setCorrection({key,label,result});setReason('');setCorrectedNote(notes[key]||'');setCorrectionIdempotencyKey(crypto.randomUUID());setError('');return;
  }
  // First save with repair result: needs repair data
  if(!results[key]&&isRepair(result)){openRepairModal('control',key,label,result);return;}
  // Direct save via tech_save_pilot_control
  setBusy(true);setError('');setMessage('');
  try{const {error}=await supabase!.rpc('tech_save_pilot_control',{p_order_id:orderId,p_visit_id:visitId,p_key:key,p_label:label,p_result:result,p_note:notes[key]||null});if(error)throw error;setResults(v=>({...v,[key]:result}));setNotes(v=>({...v,[key]:notes[key]||''}));setSavedNotes(v=>({...v,[key]:notes[key]||''}));setMessage('Cambios guardados')}
  catch(e){const msg=(e as Error).message;setError(msg.includes('Control inválido')?'La observación supera el límite permitido de 1000 caracteres. Revisá el texto antes de guardar.':msg.includes('inspection_corrections_reason_check')?'La explicación del cambio es demasiado corta. Escribí al menos 10 caracteres.':msg)}
  finally{setBusy(false)};
 };
 const saveCorrection=async()=>{
  if(!visitId||!correction)return;
  if(reason.trim().length<10){setError('Explicá el motivo del cambio (mínimo 10 caracteres).');return;}
  if(isFaultLike(correction.result)&&correctedNote.trim().length<10){setError('La nueva observación de una falla/crítica requiere al menos 10 caracteres.');return;}
  setBusy(true);setError('');
  try{const {error}=await supabase!.rpc('tech_save_pilot_correction',{p_order_id:orderId,p_visit_id:visitId,p_key:correction.key,p_result:correction.result,p_reason:reason.trim(),p_idempotency_key:correctionIdempotencyKey,p_corrected_note:correctedNote.trim()||null});if(error)throw error;const savedNote=correctedNote.trim();setResults(v=>({...v,[correction.key]:correction.result}));setNotes(v=>({...v,[correction.key]:savedNote}));setSavedNotes(v=>({...v,[correction.key]:savedNote}));setCorrection(null);setReason('');setCorrectedNote('');setCorrectionIdempotencyKey(null);setMessage('Corrección registrada con su motivo')}
  catch(e){setError((e as Error).message)}finally{setBusy(false)};
 };
 const saveRepair=async()=>{
  if(!repair||!visitId||!repairKey)return;
  if(repairFields.problem_found.trim().length<10){setError('Problema encontrado: mínimo 10 caracteres.');return;}
  if(repairFields.intervention.trim().length<10){setError('Intervención realizada: mínimo 10 caracteres.');return;}
  if(repair.result==='resolved'&&repairFields.verification.trim().length<10){setError('Verificación obligatoria (mínimo 10 caracteres).');return;}
  if(repair.result==='partial'&&repairFields.verification.trim().length>0&&repairFields.verification.trim().length<10){setError('La verificación debe tener al menos 10 caracteres si se completa.');return;}
  if(repair.result==='partial'&&repairFields.remaining_work.trim().length<10){setError('Trabajo pendiente: mínimo 10 caracteres.');return;}
  if(repair.mode==='correction'&&repairReason.trim().length<10){setError('Motivo de corrección: mínimo 10 caracteres.');return;}
  const p_repair:Record<string,string>={problem_found:repairFields.problem_found.trim(),intervention:repairFields.intervention.trim(),idempotency_key:repairKey};
  if(repairFields.verification.trim())p_repair['verification']=repairFields.verification.trim();
  if(repairFields.remaining_work.trim())p_repair['remaining_work']=repairFields.remaining_work.trim();
  setBusy(true);setError('');
  try{
   let err;
   if(repair.mode==='control'){({error:err}=await supabase!.rpc('tech_save_pilot_control',{p_order_id:orderId,p_visit_id:visitId,p_key:repair.key,p_label:repair.label,p_result:repair.result,p_note:notes[repair.key]||null,p_repair}));}
   else{({error:err}=await supabase!.rpc('tech_save_pilot_correction',{p_order_id:orderId,p_visit_id:visitId,p_key:repair.key,p_result:repair.result,p_reason:repairReason.trim(),p_idempotency_key:correctionIdempotencyKey,p_corrected_note:(notes[repair.key]||'').trim()||null,p_repair}));}
   if(err)throw err;
   setResults(v=>({...v,[repair.key]:repair.result}));setNotes(v=>({...v,[repair.key]:(notes[repair.key]||'').trim()}));setSavedNotes(v=>({...v,[repair.key]:(notes[repair.key]||'').trim()}));
   setRepair(null);setMessage('Reparación registrada');
  }catch(e){setError((e as Error).message)}finally{setBusy(false)};
 };
 const missing=checks.filter(([key])=>!results[key]);
 const unsaved=checks.filter(([key])=>results[key] && (notes[key]||'') !== (savedNotes[key]||''));
 const invalidFaults=checks.filter(([key])=>isFaultLike(results[key])&&!savedNotes[key]?.trim());
 const finish=async()=>{if(!visitId)return;if(missing.length||unsaved.length||invalidFaults.length){setShowMissing(true);setError(missing.length?`Faltan ${missing.length} controles por completar.`:'Hay observaciones sin guardar.');const first=missing[0]?.[0]??invalidFaults[0]?.[0]??unsaved[0]?.[0];document.getElementById(`inspection-${first}`)?.scrollIntoView({behavior:'smooth',block:'center'});document.getElementById(`inspection-${first}`)?.focus({preventScroll:true});return;}setShowMissing(false);setBusy(true);setError('');try{const {error}=await supabase!.rpc('tech_finish_pilot_order',{p_order_id:orderId,p_visit_id:visitId});if(error)throw error;await queryClient.cancelQueries({queryKey:['my-assigned-orders']});queryClient.setQueriesData<TechAssignedOrder[]>({queryKey:['my-assigned-orders']},old=>old?.map(item=>item.service_orders?.id===orderId?{...item,service_orders:{...item.service_orders,status:'completed'}}:item));setFinished(true);onFinished?.();void queryClient.invalidateQueries({queryKey:['my-assigned-orders']});try{sessionStorage.removeItem(draftKey)}catch{/* unavailable storage */}setMessage('Mantenimiento finalizado y guardado')}catch(e){setError((e as Error).message)}finally{setBusy(false)}};
 const bgFor=(v:Result)=>({ok:'#dcfce7',fault:'#fee2e2',critical:'#fecdd3',not_applicable:'#e2e8f0',unverifiable:'#fef3c7',resolved:'#d1fae5',partial:'#ffedd5'}[v]);
 const colorFor=(v:Result)=>({ok:'#166534',fault:'#b91c1c',critical:'#9f1239',not_applicable:'#334155',unverifiable:'#92400e',resolved:'#065f46',partial:'#c2410c'}[v]);
 const labelFor=(v:Result)=>({ok:'Correcto',fault:'Falla',critical:'Crítica',not_applicable:'No aplica',unverifiable:'No verificable',resolved:'Resuelto',partial:'Parcial'}[v]);
 const buttons:Array<[Result,string]>=[['ok','OK'],['fault','Falla'],['critical','Crítica'],['not_applicable','No aplica'],['unverifiable','No verif.'],['resolved','Resuelto'],['partial','Parcial']];
 const taSty={width:'100%',boxSizing:'border-box' as const,padding:10};
 return <section style={{border:'1px solid #cbd5e1',borderRadius:16,padding:18,marginTop:12,background:'#fff'}}>
  <h3>Inspección · {gateCode}</h3>
  <p>Registrá el estado de cada componente y sus observaciones.</p>
  {error&&<p role="alert" style={{color:'#b91c1c'}}>{error}</p>}
  {message&&<p role="status">{message}</p>}
  {loading?<p>Cargando inspección guardada…</p>:!visitId?<button type="button" disabled={busy} onClick={start}>Iniciar mantenimiento</button>:finished?<button type="button" onClick={onDone}>Volver a mis órdenes</button>:<>
   {repair&&<div role="dialog" aria-label="Registrar reparación" style={{border:'2px solid #065f46',padding:16,borderRadius:12,marginBottom:14,background:'#f0fdf4'}}>
    <strong>{repair.mode==='correction'?'Corregir y registrar reparación':'Registrar reparación'} — {repair.label}</strong>
    {repair.mode==='correction'&&<><p style={{marginTop:12}}>Motivo de la corrección *</p><textarea value={repairReason} onChange={e=>setRepairReason(e.target.value)} placeholder="Explicá qué hiciste (mínimo 10 caracteres)" maxLength={1000} rows={2} style={taSty}/></>}
    <p style={{marginTop:12}}>Problema encontrado *</p>
    <textarea value={repairFields.problem_found} onChange={e=>setRepairFields(f=>({...f,problem_found:e.target.value}))} placeholder="Mínimo 10 caracteres" maxLength={2000} rows={2} style={taSty}/>
    <p style={{marginTop:8}}>Intervención realizada *</p>
    <textarea value={repairFields.intervention} onChange={e=>setRepairFields(f=>({...f,intervention:e.target.value}))} placeholder="Mínimo 10 caracteres" maxLength={2000} rows={2} style={taSty}/>
    <p style={{marginTop:8}}>Verificación{repair.result==='resolved'?' *':' (opcional)'}</p>
    <textarea value={repairFields.verification} onChange={e=>setRepairFields(f=>({...f,verification:e.target.value}))} placeholder={repair.result==='resolved'?'Mínimo 10 caracteres':'Opcional — mínimo 10 si se completa'} maxLength={2000} rows={2} style={taSty}/>
    {repair.result==='partial'&&<><p style={{marginTop:8}}>Trabajo pendiente *</p><textarea value={repairFields.remaining_work} onChange={e=>setRepairFields(f=>({...f,remaining_work:e.target.value}))} placeholder="Mínimo 10 caracteres" maxLength={2000} rows={2} style={taSty}/></>}
    <div style={{marginTop:12}}>
     <button type="button" disabled={busy} onClick={saveRepair}>Guardar como {repair.result==='resolved'?'Resuelto':'Parcial'}</button>
     {' '}<button type="button" disabled={busy} onClick={()=>setRepair(null)}>Cancelar</button>
    </div>
   </div>}
   {correction&&<div role="dialog" aria-label="Justificar corrección" style={{border:'2px solid #c60020',padding:16,borderRadius:12,marginBottom:14,background:'#fff7f7'}}><strong>Corregir — {correction.label}</strong><p>Estado actual: {labelFor(results[correction.key])} → {labelFor(correction.result)}</p><p style={{marginTop:12}}>Nueva observación{isFaultLike(correction.result)?' *':' (opcional)'}</p><textarea aria-label="Nueva observación" value={correctedNote} onChange={e=>setCorrectedNote(e.target.value)} placeholder={isFaultLike(correction.result)?'Describí la falla (mínimo 10 caracteres)':'Actualizá la observación (opcional)'} maxLength={1000} rows={2} style={{width:'100%',boxSizing:'border-box',padding:10}}/><p style={{marginTop:12}}>Motivo de la corrección *</p><textarea aria-label="Motivo de corrección" value={reason} onChange={e=>setReason(e.target.value)} placeholder="Ej.: Se ajustó el rodillo y se verificó el funcionamiento" maxLength={1000} rows={3} style={{width:'100%',boxSizing:'border-box',padding:10}}/><p>Escribí al menos 10 caracteres.</p><button type="button" disabled={busy} onClick={saveCorrection}>Guardar corrección</button> <button type="button" disabled={busy} onClick={()=>setCorrection(null)}>Cancelar</button></div>}
   {checks.map(([key,label])=><div key={key} id={`inspection-${key}`} tabIndex={-1} style={{padding:'18px 0',borderBottom:'1px solid #e2e8f0',borderLeft:showMissing&&!results[key]?'4px solid #b91c1c':'4px solid transparent',paddingLeft:10,scrollMarginTop:24}}>
    <strong>{label}</strong>
    <div style={{display:'flex',gap:8,flexWrap:'wrap',marginTop:8}}>
     {buttons.map(([value,text])=><button key={value} type="button" disabled={busy||!!correction||!!repair} onClick={()=>save(key,label,value)} style={{padding:'10px 13px',borderRadius:10,border:results[key]===value?'2px solid currentColor':'1px solid #cbd5e1',background:results[key]===value?(bgFor(value)||'#fff'):'#fff',color:results[key]===value?(colorFor(value)||'#14263e'):'#14263e',fontWeight:results[key]===value?700:500}}>{text}</button>)}
    </div>
    {(isFaultLike(results[key])||!results[key])&&<p style={{fontSize:13,color:isFaultLike(results[key])?'#b91c1c':'#64748b'}}>{results[key]==='fault'?'Obligatorio: explicá qué problema encontraste.':results[key]==='critical'?'Crítico: describí el problema con al menos 10 caracteres.':'Podés agregar una observación.'}</p>}
    <textarea id={`note-${key}`} aria-label={'Observaciones: '+label} placeholder="Observaciones del componente" value={notes[key]||''} onChange={e=>{setMessage('');setNotes(n=>{const next={...n,[key]:e.target.value};try{sessionStorage.setItem(draftKey,JSON.stringify(next))}catch{/* unavailable storage */}return next})}} rows={2} maxLength={1000} style={{width:'100%',marginTop:10,padding:12,borderRadius:9,border:'1px solid #cbd5e1',fontFamily:'inherit',boxSizing:'border-box'}}/>
    <small style={{display:'block',color:'#64748b'}}>{(notes[key]||'').length}/1000 caracteres. {isFaultLike(results[key])?'La falla requiere al menos 10 caracteres.':''}</small>
    {(notes[key]||'').length>1000&&<small role="alert" style={{display:'block',color:'#b91c1c'}}>Acortá la observación en {(notes[key]||'').length-1000} {(notes[key]||'').length-1000===1?'carácter':'caracteres'} antes de guardar.</small>}
    {results[key] && (notes[key]||'')!==(savedNotes[key]||'') && <button type="button" disabled={busy||!!correction||!!repair} onClick={()=>save(key,label,results[key])}>Guardar observación</button>}
    {results[key]&&<small style={{display:'block',marginTop:8,color:'#64748b'}}>Estado guardado: {labelFor(results[key])}</small>}
    {visitId&&<div style={{display:'flex',flexWrap:'wrap',gap:8,marginTop:8,alignItems:'center'}}>
     <label style={{display:'inline-flex',alignItems:'center',gap:5,padding:'7px 11px',borderRadius:8,border:'1px solid #cbd5e1',cursor:busy||finished?'default':'pointer',fontSize:12,color:'#334155',background:'#f8fafc',opacity:busy||finished?0.5:1}}>
      📷 Foto
      <input type="file" accept="image/jpeg,image/png,image/webp,image/heic,image/heif" style={{display:'none'}} disabled={busy||finished}
       onChange={e=>{const f=e.target.files?.[0];if(f){void uploadPhoto(key,isFaultLike(results[key])?'fault':'inspection',f);}e.target.value='';}}/>
     </label>
     {photoErr[key]&&<small style={{color:'#b91c1c',fontSize:11}}>{photoErr[key]}</small>}
     {(photos[key]??[]).map(ph=><span key={ph.id} style={{display:'inline-block',width:52,height:52,borderRadius:6,border:'1px solid #cbd5e1',overflow:'hidden',background:'#f1f5f9',verticalAlign:'middle'}}>
      {ph.status==='uploading'?<span style={{display:'flex',width:'100%',height:'100%',alignItems:'center',justifyContent:'center',fontSize:11,color:'#64748b'}}>↑</span>
       :ph.status==='confirmed'?<MaintenancePhoto bucket={ph.bucket||'maintenance-evidence'} path={ph.path} phase={ph.phase}/>
       :null}
     </span>)}
    </div>}
   </div>)}
   <p>{Object.keys(results).length} de {checks.length} controles guardados.</p>
   {showMissing && (missing.length>0||unsaved.length>0||invalidFaults.length>0) && <div role="alert" style={{background:'#fff7ed',border:'1px solid #fdba74',padding:12,borderRadius:10,marginBottom:12}}><strong>Antes de finalizar:</strong>{missing.length>0&&<p>Completá {missing.length} {missing.length===1?'control pendiente':'controles pendientes'}: {missing.map(([,label])=>label).join(', ')}.</p>}{invalidFaults.length>0&&<p>Describí las fallas de: {invalidFaults.map(([,label])=>label).join(', ')}.</p>}{unsaved.length>0&&<p>Guardá las observaciones de: {unsaved.map(([,label])=>label).join(', ')}.</p>}</div>}
   <button type="button" disabled={busy||!!correction||!!repair} onClick={finish}>Finalizar mantenimiento</button>
  </>}
 </section>;
}
