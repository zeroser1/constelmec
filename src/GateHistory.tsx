import {useEffect,useState} from 'react';
import {supabase} from './lib/supabase';
type Control={key:string;label:string;result:string;note:string};
type Visit={id:string;date:string;status:string;technician:string;controls:Control[]};
const names:Record<string,string>={ok:'Correcto',fault:'Falla',not_applicable:'No aplica',unverifiable:'No verificable'};
export default function GateHistory({gateId}:{gateId:string}){
 const [items,setItems]=useState<Visit[]>([]),[loading,setLoading]=useState(true),[error,setError]=useState(''),[open,setOpen]=useState<string|null>(null);
 useEffect(()=>{let active=true;setLoading(true);void (async()=>{const {data,error}=await supabase!.rpc('gate_inspection_history',{p_gate_id:gateId});if(!active)return;setItems((data||[]) as Visit[]);setError(error?.message||'');setLoading(false)})();return()=>{active=false}},[gateId]);
 return <section style={{padding:'12px 0'}} aria-label="Historial del portón">
 <h3>Historial de mantenimientos</h3>
 {loading?<p>Cargando historial…</p>:error?<p role="alert">{error}</p>:items.length===0?<p>Todavía no hay mantenimientos finalizados para este portón.</p>:items.map(v=>{const faults=v.controls.filter(c=>c.result==='fault');return <div key={v.id} style={{border:'1px solid #cbd5e1',borderRadius:12,padding:12,marginBottom:10}}>
 <button type="button" onClick={()=>setOpen(open===v.id?null:v.id)} style={{width:'100%',textAlign:'left',background:'white',border:0,padding:8,color:'#14263e',fontSize:15,fontWeight:700}}>
 {new Date(v.date).toLocaleDateString('es-AR')} · {faults.length?faults.length+' falla(s)':'Sin fallas'} · {open===v.id?'Ocultar':'Ver chequeo'}
 </button>
 <small>Técnico: {v.technician} · {v.controls.length} controles</small>
 {open===v.id&&<div style={{marginTop:12}}>{v.controls.map(c=><div key={c.key} style={{borderTop:'1px solid #e2e8f0',padding:'10px 4px'}}><strong>{c.label}</strong><div style={{color:c.result==='fault'?'#b91c1c':'#334155'}}>{names[c.result]||c.result}</div>{c.note&&<p style={{whiteSpace:'pre-wrap',margin:'4px 0'}}>{c.note}</p>}</div>)}</div>}
 </div>})}</section>
}