import {useEffect,useRef,useState} from 'react';
import {supabase} from './lib/supabase';
type Correction={result:string;reason:string;corrected_note:string|null;date:string};
type Repair={id:string;actor_user_id:string;problem_found:string;intervention:string;verification:string|null;remaining_work:string|null;created_at:string};
type Control={key:string;label:string;result:string;note:string|null;current_note:string|null;original_result:string;original_note:string|null;corrections:Correction[];repairs:Repair[]};
type Visit={id:string;order_id:string|null;date:string;status:string;technician:string;participants?:string[];controls:Control[]};
type PhotoItem={id:string;control_key:string;phase:string;signedUrl:string};
const names:Record<string,string>={ok:'Correcto',fault:'Falla',critical:'Crítica',not_applicable:'No aplica',unverifiable:'No verificable',resolved:'Resuelto',partial:'Parcial'};
const resultColor=(r:string)=>r==='fault'||r==='critical'?'#b91c1c':r==='partial'?'#c2410c':r==='resolved'?'#065f46':'#334155';
const fmt=(date:string)=>new Date(date).toLocaleString('es-AR',{timeZone:'America/Argentina/Buenos_Aires',day:'2-digit',month:'2-digit',year:'numeric',hour:'2-digit',minute:'2-digit',second:'2-digit'});
export default function GateHistory({gateId,orderId,companyId}:{gateId:string;orderId?:string;companyId?:string}){
 const [items,setItems]=useState<Visit[]>([]),[loading,setLoading]=useState(true),[error,setError]=useState(''),[open,setOpen]=useState<string|null>(null);
 const [visitPhotos,setVisitPhotos]=useState<Record<string,PhotoItem[]>>({});
 const [visitPhotoErr,setVisitPhotoErr]=useState<Record<string,string>>({});
 const loadedRef=useRef<Set<string>>(new Set());
 useEffect(()=>{let active=true;setLoading(true);void(async()=>{const {data,error}=await supabase!.rpc('gate_inspection_history',{p_gate_id:gateId});if(!active)return;const visits=(data||[]) as Visit[];setItems(visits);setError(error?.message||'');setOpen(orderId?visits.find(v=>v.order_id===orderId)?.id||null:null);setLoading(false)})();return()=>{active=false}},[gateId,orderId]);
 useEffect(()=>{
  if(!open||!companyId||loadedRef.current.has(open))return;
  loadedRef.current.add(open);
  void(async()=>{try{
   const{data}=await supabase!.rpc('get_visit_maintenance_photos',{p_company_id:companyId,p_visit_id:open});
   if(!data||!Array.isArray(data)){setVisitPhotoErr(pe=>({...pe,[open]:''}));setVisitPhotos(p=>({...p,[open]:[]}));return;}
   const result:PhotoItem[]=[];
   let failed=0;
   await Promise.all((data as Array<{id:string;control_key:string;phase:string;storage_path:string;bucket:string}>).map(async ph=>{
    const{data:u}=await supabase!.storage.from(ph.bucket||'maintenance-evidence').createSignedUrl(ph.storage_path,3600);
    if(!u?.signedUrl){failed++;return;}
    result.push({id:ph.id,control_key:ph.control_key,phase:ph.phase,signedUrl:u.signedUrl});
   }));
   setVisitPhotoErr(pe=>({...pe,[open]:failed>0?`${failed} foto(s) no pudieron cargarse.`:''}));
   setVisitPhotos(p=>({...p,[open]:result}));
  }catch(e){
   loadedRef.current.delete(open);
   setVisitPhotoErr(pe=>({...pe,[open]:(e as Error).message||'No se pudieron cargar las fotos.'}));
  }})();
 },[open,companyId]);
 const ordered=orderId?items.filter(v=>v.order_id===orderId):items;
 return <section style={{padding:'12px 0',minWidth:0,overflowWrap:'anywhere'}} aria-label="Historial del portón">
 <h3>{orderId?'Registro de esta orden':'Historial de mantenimientos'}</h3>
 {loading?<p>Cargando historial…</p>:error?<p role="alert">{error}</p>:ordered.length===0?<p>{orderId?'No se pudo vincular automáticamente esta orden con una visita histórica. Consultá el historial general del portón.':'Todavía no hay mantenimientos finalizados para este portón.'}</p>:ordered.map(v=>{
 const active=v.controls.filter(c=>c.result==='fault'||c.result==='critical'||c.result==='partial').length;
 const resolved_count=v.controls.filter(c=>c.result==='resolved').length;
 return <div key={v.id} style={{border:'1px solid #cbd5e1',borderRadius:12,padding:12,marginBottom:10,minWidth:0,maxWidth:'100%',boxSizing:'border-box'}}>
 <button type="button" onClick={()=>setOpen(open===v.id?null:v.id)} style={{width:'100%',textAlign:'left',background:'white',border:0,padding:8,color:'#14263e',fontSize:15,fontWeight:700,whiteSpace:'normal'}}>
 {fmt(v.date)} · {active?active+' problema(s) activo(s)':'Sin problemas activos'}{resolved_count?' · '+resolved_count+' resuelto(s)':''} · {open===v.id?'Ocultar':'Ver chequeo'}
 </button>
 <small>{v.participants?.length ? 'Responsable: ' : 'Técnico: '}{v.technician} · {v.controls.length} controles · Visita {v.id.slice(0,8)}{v.order_id?' · Orden '+v.order_id.slice(0,8):''}</small>
 {v.participants && v.participants.length>0 && <small>Participantes: {v.participants.join(', ')}</small>}
 {open===v.id&&<div style={{marginTop:12}}>{visitPhotoErr[v.id]&&<p style={{fontSize:11,color:'#b91c1c',margin:'0 0 8px'}}>{visitPhotoErr[v.id]}</p>}{v.controls.map(c=><div key={c.key} style={{borderTop:'1px solid #e2e8f0',padding:'10px 4px'}}>
 <strong>{c.label}</strong>
 <div style={{color:resultColor(c.result)}}>Estado actual: {names[c.result]||c.result}</div>
 {c.original_result!==c.result&&<div>Estado inicial: {names[c.original_result]||c.original_result}</div>}
 {c.current_note&&<p style={{whiteSpace:'pre-wrap',overflowWrap:'anywhere',wordBreak:'break-word',margin:'4px 0',color:'#14263e'}}>Observación vigente: {c.current_note}</p>}
 {c.original_note&&c.original_note!==c.current_note&&<p style={{whiteSpace:'pre-wrap',overflowWrap:'anywhere',wordBreak:'break-word',margin:'4px 0',color:'#64748b',fontSize:12}}>Observación original: {c.original_note}</p>}
 {c.corrections?.length>0&&<div style={{paddingLeft:10,borderLeft:'3px solid #94a3b8'}}><strong>Movimientos y observaciones</strong>{c.corrections.map((x,i)=>{const previous=i===0?c.original_result:c.corrections[i-1].result;return <div key={i} style={{margin:'6px 0'}}><p style={{whiteSpace:'pre-wrap',margin:0}}>{fmt(x.date)} · {previous===x.result?'Observación actualizada':(names[previous]||previous)+' → '+(names[x.result]||x.result)}: {x.reason}</p>{x.corrected_note&&<p style={{whiteSpace:'pre-wrap',margin:'2px 0 0 8px',fontSize:12,color:'#334155'}}>Observación: {x.corrected_note}</p>}</div>})}</div>}
 {c.repairs?.length>0&&<div style={{paddingLeft:10,borderLeft:'3px solid #065f46',marginTop:6}}><strong>Reparaciones ({c.repairs.length})</strong>{c.repairs.map(r=><div key={r.id} style={{marginTop:6,fontSize:13}}><div><strong>Problema:</strong> {r.problem_found}</div><div><strong>Intervención:</strong> {r.intervention}</div>{r.verification&&<div><strong>Verificación:</strong> {r.verification}</div>}{r.remaining_work&&<div><strong>Pendiente:</strong> {r.remaining_work}</div>}<div style={{color:'#64748b',fontSize:11}}>{fmt(r.created_at)}</div></div>)}</div>}
 {(visitPhotos[v.id]??[]).filter(ph=>ph.control_key===c.key).map(ph=><a key={ph.id} href={ph.signedUrl} target="_blank" rel="noopener noreferrer" style={{display:'inline-block',width:52,height:52,borderRadius:6,border:'1px solid #cbd5e1',overflow:'hidden',background:'#f1f5f9',verticalAlign:'middle',marginRight:4,marginTop:6}}><img src={ph.signedUrl} alt={ph.phase} style={{width:'100%',height:'100%',objectFit:'cover',display:'block'}}/></a>)}
 </div>)}</div>}
 </div>})}</section>;
}