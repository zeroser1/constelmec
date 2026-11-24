import WorkDashboard from './WorkDashboard';
import {useEffect,useMemo,useState} from 'react';import AppShell from './AppShell';
import {AlertTriangle,Building2,CalendarDays,ChevronDown,ChevronLeft,ChevronRight,Clock3,HardHat,LayoutDashboard,MapPin,MessageSquare,Plus,Users,Wrench,X} from 'lucide-react';
import {supabase} from './lib/supabase';
import {useOrderTechnicians,useOrderTechnicianMutations,useTechnicianProfiles,useFacilities,useAdminGates,useCreateServiceOrder} from './hooks/useRealData';
import type {CreateServiceOrderResult} from './hooks/useRealData';
import type {OrderTechnicianRole} from './lib/types';
import './admin.css';
import ContactManager from './ContactManager';
import TechnicianManager from './TechnicianManager';
export type ServiceOrder={id:string;company_id:string;gate_id?:string;assigned_technician_id?:string;service_type:string;status:string;scheduled_start:string;scheduled_end:string;completed_at:string|null;next_service_at:string|null;notes:string|null;gates:{code:string;description:string}|null;facilities:{name:string}|null;technician_profiles:{first_name:string;last_name:string}|null};
export type Technician={id:string;company_id:string;first_name:string;last_name:string;work_phone:string|null;work_email:string|null;specialty:string|null;driving_authorized:boolean;license_expires_on:string|null;active:boolean};
export type Company={
  id:string;
  name:string;
  legal_name?:string|null;
  tax_id?:string|null;
  contact_name?:string|null;
  contact_email?:string|null;
  contact_phone?:string|null;
  address?:string|null;
  active?:boolean;
  notes?:string|null;
  updated_at?:string|null;
  created_at?:string;
};
const dayKey=(date:Date)=>[date.getFullYear(),String(date.getMonth()+1).padStart(2,'0'),String(date.getDate()).padStart(2,'0')].join('-');
const dateTime=(value:string)=>new Date(value).toLocaleString('es-AR',{dateStyle:'short',timeStyle:'short'});
const serviceType:Record<string,string>={preventive:'Preventivo',corrective:'Correctivo',installation:'Instalación',emergency:'Emergencia'};
const statusLabel:Record<string,string>={unassigned:'Sin asignar',scheduled:'Programado',in_progress:'En curso',completed:'Finalizado',rescheduled:'Reprogramado',cancelled:'Cancelado'};
const sampleCompanies:Company[]=[{id:'a',name:'Logística del Sur'},{id:'b',name:'Industrias Norte'},{id:'c',name:'Frigorífico Central'}];
function samples():{orders:ServiceOrder[];techs:Technician[]}{
 const base=new Date();base.setHours(9,0,0,0);
 const techs:Technician[]=[['t1','a','Martín','González'],['t2','b','Lucas','Fernández'],['t3','c','Diego','Romero']].map(([id,company_id,first_name,last_name],i)=>({id,company_id,first_name,last_name,work_phone:null,work_email:null,specialty:['Mecánica','Electricidad / PLC','Automatización'][i],driving_authorized:i!==2,license_expires_on:null,active:true}));
 const offsets=[0,0,1,2,3,4,-2];
 const orders=offsets.map((offset,i)=>{const d=new Date(base);d.setDate(d.getDate()+offset);d.setHours(i%2?13:9,0);const end=new Date(d);end.setHours(d.getHours()+2);const t=techs[i%3];return {id:'demo'+i,company_id:t.company_id,assigned_technician_id:t.id,service_type:i===2?'corrective':'preventive',status:i===6?'scheduled':i===1?'in_progress':i===5?'completed':'scheduled',scheduled_start:d.toISOString(),scheduled_end:end.toISOString(),completed_at:i===5?end.toISOString():null,next_service_at:null,notes:null,gates:{code:'P-'+String(14+i).padStart(3,'0'),description:'Portón industrial'},facilities:{name:['Planta principal','Sector logística','Depósito'][i%3]},technician_profiles:{first_name:t.first_name,last_name:t.last_name}} satisfies ServiceOrder});
 return {orders,techs};
}
const demo=samples();
function OrderTechPanel({order,demoMode,allTechs}:{order:ServiceOrder;demoMode:boolean;allTechs:Technician[]}){
  const {data:techs=[],isLoading}=useOrderTechnicians(demoMode?undefined:order.company_id,demoMode?undefined:order.id);
  const {assignTechnician,removeTechnician}=useOrderTechnicianMutations();
  const techProfiles=useTechnicianProfiles(demoMode?undefined:order.company_id);
  const [addOpen,setAddOpen]=useState(false);
  const [selTech,setSelTech]=useState('');
  const [selRole,setSelRole]=useState<OrderTechnicianRole>('support');
  const isClosed=order.status==='completed'||order.status==='cancelled';
  const demoList=order.technician_profiles?[{id:'demo',service_order_id:order.id,technician_id:'',company_id:order.company_id,role:'lead' as OrderTechnicianRole,assigned_at:'',active:true,technician_profiles:{first_name:order.technician_profiles.first_name,last_name:order.technician_profiles.last_name,specialty:null as string|null}}]:[];
  const display=demoMode?demoList:techs;
  const available=(demoMode?allTechs.filter(t=>t.company_id===order.company_id):techProfiles.data??[]).filter(t=>t.active);
  return <div className="adm-tech-panel">
    {isLoading&&<span className="adm-empty">Cargando…</span>}
    {!isLoading&&display.length===0&&<span className="adm-empty">Sin técnicos asignados.</span>}
    {display.map(t=><div key={t.id} className="adm-tech-row">
      <span className={`adm-role adm-role--${t.role}`}>{t.role==='lead'?'Principal':'Apoyo'}</span>
      <span className="adm-tech-name">{t.technician_profiles?.first_name} {t.technician_profiles?.last_name}</span>
      {!demoMode&&!isClosed&&<button className="adm-tech-remove" title="Quitar" onClick={()=>removeTechnician.mutate({companyId:order.company_id,orderId:order.id,technicianId:t.technician_id})}>×</button>}
    </div>)}
    {!demoMode&&!isClosed&&!addOpen&&<button className="adm-tech-add" onClick={()=>{setAddOpen(true);setSelTech('');setSelRole('support');}}>+ Asignar técnico</button>}
    {addOpen&&<div className="adm-tech-form">
      <select value={selTech} onChange={e=>setSelTech(e.target.value)}>
        <option value="">Técnico…</option>
        {available.map(t=><option key={t.id} value={t.id}>{t.first_name} {t.last_name}</option>)}
      </select>
      <select value={selRole} onChange={e=>setSelRole(e.target.value as OrderTechnicianRole)}>
        <option value="support">Apoyo</option>
        <option value="lead">Principal</option>
      </select>
      <button disabled={!selTech||assignTechnician.isPending} onClick={()=>{if(!selTech)return;assignTechnician.mutate({companyId:order.company_id,orderId:order.id,technicianId:selTech,role:selRole},{onSuccess:()=>setAddOpen(false)});}}>Asignar</button>
      <button onClick={()=>setAddOpen(false)}>Cancelar</button>
    </div>}
  </div>;
}
function NewOrderModal({companies,technicians,defaultCompanyId,defaultDate,onClose}:{companies:Company[];technicians:Technician[];defaultCompanyId:string;defaultDate:string;onClose:()=>void}){
  const {createOrder}=useCreateServiceOrder();
  const [cId,setCId]=useState(defaultCompanyId!=='all'?defaultCompanyId:(companies[0]?.id??''));
  const [facId,setFacId]=useState('');const [gateId,setGateId]=useState('');const [svcType,setSvcType]=useState('');
  const [startDt,setStartDt]=useState(defaultDate+'T09:00');const [endDt,setEndDt]=useState(defaultDate+'T11:00');
  const [techSel,setTechSel]=useState<Record<string,OrderTechnicianRole>>({});
  const [result,setResult]=useState<CreateServiceOrderResult|null>(null);const [err,setErr]=useState('');
  const facilitiesQ=useFacilities(cId||undefined);const gatesQ=useAdminGates(facId||undefined,cId||undefined);
  const activeFacs=(facilitiesQ.data??[]).filter(f=>f.active);const activeGates=(gatesQ.data??[]).filter(g=>g.active);
  const availTechs=technicians.filter(t=>t.company_id===cId&&t.active);
  const changeCo=(id:string)=>{setCId(id);setFacId('');setGateId('');setTechSel({});};
  const changeFac=(id:string)=>{setFacId(id);setGateId('');};
  const toggleTech=(id:string)=>setTechSel(p=>{if(id in p){const{[id]:_,...r}=p;return r;}return{...p,[id]:'support' as OrderTechnicianRole};});
  const canSub=!createOrder.isPending&&!!cId&&!!facId&&!!gateId&&!!svcType&&!!startDt&&!!endDt;
  const submit=async()=>{setErr('');setResult(null);const techs=Object.entries(techSel).map(([technicianId,role])=>({technicianId,role}));try{const r=await createOrder.mutateAsync({companyId:cId,facilityId:facId,gateId,serviceType:svcType,scheduledStart:new Date(startDt).toISOString(),scheduledEnd:new Date(endDt).toISOString(),technicians:techs});setResult(r);}catch(e:unknown){setErr(e instanceof Error?e.message:'Error al crear la orden');}};
  const bd={position:'fixed',inset:0,background:'rgba(0,0,0,.55)',display:'flex',alignItems:'center',justifyContent:'center',zIndex:200,padding:16} as const;
  const box={background:'white',borderRadius:14,width:'100%',maxWidth:520,maxHeight:'90vh',overflow:'auto',boxShadow:'0 20px 60px rgba(0,0,0,.3)',fontFamily:'Arial,Helvetica,sans-serif',padding:'24px 24px 28px'} as const;
  const sel={width:'100%',padding:'8px 10px',border:'1px solid #d1dbe5',borderRadius:8,fontSize:14,marginTop:4,display:'block'} as const;
  const lbl={display:'block',fontSize:13,fontWeight:600,color:'#10263e',marginBottom:12} as const;
  if(result)return(
    <div style={bd} onClick={onClose}><div style={box} onClick={e=>e.stopPropagation()}>
      <h2 style={{margin:'0 0 16px',fontSize:19,fontWeight:800,color:'#10263e'}}>Orden creada</h2>
      <p style={{fontSize:13,color:'#4a5e6d',wordBreak:'break-all',marginBottom:6}}>ID: {result.orderId}</p>
      <p style={{fontSize:14,color:result.scheduled?'#1a7a3f':'#b05000',margin:'0 0 12px'}}>{result.scheduled?'✓ Programada con técnicos asignados.':result.assignedTechs.length>0?'Creada, pero no se pudo programar (ver errores abajo).':'Creada sin técnicos (sin asignar).'}</p>
      {result.failedTechs.length>0&&<div style={{background:'#fff3cd',border:'1px solid #f0c040',borderRadius:8,padding:'10px 14px',marginBottom:12,fontSize:13}}><strong>Asignaciones fallidas:</strong><ul style={{margin:'6px 0 0',paddingLeft:18}}>{result.failedTechs.map(f=><li key={f.technicianId}>{f.technicianId==='__schedule__'?'Cambio de estado':f.technicianId.slice(0,8)+'…'}: {f.error}</li>)}</ul></div>}
      <button onClick={onClose} style={{padding:'9px 20px',background:'#1a5eb8',color:'white',border:'none',borderRadius:8,fontWeight:700,cursor:'pointer',fontSize:14}}>Cerrar</button>
    </div></div>
  );
  return(
    <div style={bd} onClick={onClose}><div style={box} onClick={e=>e.stopPropagation()}>
      <div style={{display:'flex',alignItems:'center',justifyContent:'space-between',marginBottom:20}}>
        <h2 style={{margin:0,fontSize:19,fontWeight:800,color:'#10263e'}}>Nueva orden de servicio</h2>
        <button onClick={onClose} style={{background:'none',border:0,cursor:'pointer',color:'#8295a8',padding:4}}><X size={20}/></button>
      </div>
      <label style={lbl}>Empresa<select style={sel} value={cId} onChange={e=>changeCo(e.target.value)}><option value="">Seleccionar…</option>{companies.map(c=><option key={c.id} value={c.id}>{c.name}</option>)}</select></label>
      <label style={lbl}>Instalación<select style={sel} value={facId} onChange={e=>changeFac(e.target.value)} disabled={!cId||facilitiesQ.isLoading}><option value="">Seleccionar…</option>{activeFacs.map(f=><option key={f.id} value={f.id}>{f.name}</option>)}</select></label>
      <label style={lbl}>Portón<select style={sel} value={gateId} onChange={e=>setGateId(e.target.value)} disabled={!facId||gatesQ.isLoading}><option value="">Seleccionar…</option>{activeGates.map(g=><option key={g.id} value={g.id}>{g.code} — {g.description}</option>)}</select></label>
      <label style={lbl}>Tipo de servicio<select style={sel} value={svcType} onChange={e=>setSvcType(e.target.value)}><option value="">Seleccionar…</option><option value="preventive">Preventivo</option><option value="corrective">Correctivo</option><option value="installation">Instalación</option><option value="emergency">Emergencia</option></select></label>
      <div style={{display:'grid',gridTemplateColumns:'1fr 1fr',gap:12,marginBottom:12}}>
        <label style={lbl}>Inicio<input type="datetime-local" style={sel} value={startDt} onChange={e=>setStartDt(e.target.value)}/></label>
        <label style={lbl}>Fin<input type="datetime-local" style={sel} value={endDt} onChange={e=>setEndDt(e.target.value)}/></label>
      </div>
      {availTechs.length>0&&<fieldset style={{border:'1px solid #d1dbe5',borderRadius:8,padding:'10px 14px',marginBottom:12}}>
        <legend style={{fontSize:13,fontWeight:600,color:'#4a5e6d',padding:'0 6px'}}>Técnicos (opcional)</legend>
        {availTechs.map(t=><div key={t.id} style={{display:'flex',alignItems:'center',gap:8,padding:'4px 0'}}>
          <input type="checkbox" id={'tech-'+t.id} checked={t.id in techSel} onChange={()=>toggleTech(t.id)} style={{cursor:'pointer'}}/>
          <label htmlFor={'tech-'+t.id} style={{fontSize:14,color:'#10263e',cursor:'pointer',flex:1}}>{t.first_name} {t.last_name}{t.specialty?<span style={{fontSize:12,color:'#8295a8',marginLeft:6}}>({t.specialty})</span>:null}</label>
          {t.id in techSel&&<select value={techSel[t.id]} onChange={e=>setTechSel(p=>({...p,[t.id]:e.target.value as OrderTechnicianRole}))} style={{padding:'4px 8px',border:'1px solid #d1dbe5',borderRadius:6,fontSize:13}}><option value="support">Apoyo</option><option value="lead">Principal</option></select>}
        </div>)}
      </fieldset>}
      {err&&<p style={{color:'#c0392b',fontSize:13,margin:'0 0 12px'}}>{err}</p>}
      <div style={{display:'flex',gap:10,justifyContent:'flex-end'}}>
        <button onClick={onClose} style={{padding:'9px 20px',background:'white',border:'1px solid #d1dbe5',borderRadius:8,cursor:'pointer',fontSize:14,color:'#4a5e6d'}}>Cancelar</button>
        <button onClick={submit} disabled={!canSub} style={{padding:'9px 20px',background:canSub?'#1a5eb8':'#8295a8',color:'white',border:'none',borderRadius:8,fontWeight:700,cursor:canSub?'pointer':'not-allowed',fontSize:14}}>{createOrder.isPending?'Creando…':'Crear orden'}</button>
      </div>
    </div></div>
  );
}
type AdminObs={id:string;gate_code:string;gate_desc:string;body:string;author_name:string;created_at:string;reply_count:number;latest_activity_at:string};
type AdminConvItem={item_type:string;item_id:string;author_role:string;body:string;created_at:string};
function AdminObservationsSection({companyId}:{companyId:string|undefined}){
 const [items,setItems]=useState<AdminObs[]|null>(null);
 const [loading,setLoading]=useState(false);
 const [err,setErr]=useState('');
 const [expanded,setExpanded]=useState<string|null>(null);
 const [conv,setConv]=useState<Record<string,AdminConvItem[]>>({});
 const [convLoading,setConvLoading]=useState<string|null>(null);
 const fmtDt=(iso:string)=>new Date(iso).toLocaleDateString('es-AR',{day:'2-digit',month:'2-digit',year:'numeric'});
 useEffect(()=>{
  if(!companyId)return;
  setLoading(true);setErr('');
  void(async()=>{try{
   const{data,error}=await supabase!.rpc('admin_list_all_observations',{p_company_id:companyId});
   if(error)throw new Error(error.message.includes('does not exist')||error.message.includes('no existe')?'Módulo de observaciones en preparación.':error.message);
   setItems((data??[]) as AdminObs[]);
  }catch(e){setErr((e as Error).message);}finally{setLoading(false);}})();
 },[companyId]);
 const toggleConv=async(id:string)=>{
  if(expanded===id){setExpanded(null);return;}
  setExpanded(id);
  if(conv[id]||!companyId)return;
  setConvLoading(id);
  try{
   const{data,error}=await supabase!.rpc('get_observation_conversation',{p_company_id:companyId,p_observation_id:id});
   if(error)throw new Error(error.message);
   setConv(c=>({...c,[id]:(data??[]) as AdminConvItem[]}));
  }catch{/* silent */}finally{setConvLoading(null);}
 };
 const roleLabel=(r:string)=>r==='technician'?'Técnico':r==='admin'?'Admin':'Cliente';
 if(!companyId)return <p className="adm-empty">Seleccioná una empresa para ver observaciones.</p>;
 if(loading)return <p className="adm-empty">Cargando observaciones…</p>;
 if(err)return <p style={{color:'#b91c1c',fontSize:13}}>{err}</p>;
 if(items&&items.length===0)return <p className="adm-empty">No hay observaciones registradas para esta empresa.</p>;
 return <div style={{display:'flex',flexDirection:'column',gap:8,marginTop:8}}>
  {(items??[]).map(o=><div key={o.id} style={{border:'1px solid #d1dbe5',borderRadius:10,padding:'12px 14px',background:'#fff'}}>
   <div style={{display:'flex',alignItems:'flex-start',justifyContent:'space-between',gap:8,flexWrap:'wrap'}}>
    <div style={{flex:1}}>
     <strong style={{fontSize:13,color:'#10263e'}}>{o.gate_code}</strong>
     <span style={{fontSize:12,color:'#64748b',marginLeft:6}}>{o.gate_desc}</span>
     <p style={{margin:'4px 0 0',fontSize:13,color:'#334155'}}>{o.body}</p>
     <p style={{margin:'4px 0 0',fontSize:11,color:'#94a3b8'}}>{o.author_name} · {fmtDt(o.created_at)} · {o.reply_count} {o.reply_count===1?'respuesta':'respuestas'}</p>
    </div>
    <button type="button" onClick={()=>void toggleConv(o.id)} style={{flexShrink:0,display:'inline-flex',alignItems:'center',gap:4,fontSize:12,color:'#1a5eb8',background:'#eff6ff',border:'1px solid #bfdbfe',borderRadius:7,padding:'6px 10px',cursor:'pointer'}}>
     <MessageSquare size={14}/>{expanded===o.id?'Ocultar':'Ver hilo'}
    </button>
   </div>
   {expanded===o.id&&<div style={{marginTop:10,paddingTop:10,borderTop:'1px solid #e2e8f0'}}>
    {convLoading===o.id&&<p style={{fontSize:12,color:'#64748b'}}>Cargando…</p>}
    {(conv[o.id]??[]).map(it=><div key={it.item_id} style={{marginBottom:8,fontSize:12}}>
     <strong style={{color:it.author_role==='technician'?'#1d4ed8':it.author_role==='admin'?'#166534':'#64748b'}}>{roleLabel(it.author_role)}</strong>
     <p style={{margin:'2px 0 0',color:'#334155'}}>{it.body}</p>
    </div>)}
   </div>}
  </div>)}
 </div>;
}
export default function AdminControl({companies,orders,technicians=[],demoMode=false,email,onLogout,embedded=false}:{companies:Company[];orders:ServiceOrder[];technicians?:Technician[];demoMode?:boolean;email?:string;onLogout?:()=>void;embedded?:boolean}){
 const [company,setCompany]=useState('all');const [section,setSection]=useState<'overview'|'calendar'|'contacts'|'technicians'|'live'|'observations'>('overview');const [selected,setSelected]=useState(dayKey(new Date()));const [month,setMonth]=useState(()=>new Date(new Date().getFullYear(),new Date().getMonth(),1));const [expandedOrder,setExpandedOrder]=useState<string|null>(null);const [newOrderOpen,setNewOrderOpen]=useState(false);
 const allCompanies=demoMode?sampleCompanies:companies;const allOrders=demoMode?demo.orders:orders;
 const filtered=useMemo(()=>allOrders.filter(o=>company==='all'||o.company_id===company),[allOrders,company]);

 const today=dayKey(new Date());const todayOrders=filtered.filter(o=>dayKey(new Date(o.scheduled_start))===today&&o.status!=='cancelled');
 const upcoming=filtered.filter(o=>dayKey(new Date(o.scheduled_start))>=today&&!['cancelled','completed'].includes(o.status)).sort((a,b)=>a.scheduled_start.localeCompare(b.scheduled_start));
 const overdue=filtered.filter(o=>dayKey(new Date(o.scheduled_start))<today&&!['cancelled','completed'].includes(o.status));
 const chosen=filtered.filter(o=>dayKey(new Date(o.scheduled_start))===selected);
 const daysInMonth=new Date(month.getFullYear(),month.getMonth()+1,0).getDate();const start=(new Date(month.getFullYear(),month.getMonth(),1).getDay()+6)%7;
 const companyName=(id:string)=>allCompanies.find(c=>c.id===id)?.name||'Empresa';
 const cards=[{label:'Servicios hoy',value:todayOrders.length,icon:CalendarDays},{label:'En curso',value:filtered.filter(o=>o.status==='in_progress').length,icon:Wrench},{label:'Próximos 7 días',value:upcoming.filter(o=>(new Date(o.scheduled_start).getTime()-Date.now())<7*86400000).length,icon:Clock3},{label:'Vencidos',value:overdue.length,icon:AlertTriangle}];
 const orderCard=(o:ServiceOrder)=>{const exp=expandedOrder===o.id;return <article className={'adm-order'+(exp?' adm-order--expanded':'')} key={o.id}><div className="adm-order-top"><strong>{companyName(o.company_id)}</strong><span className={'adm-status '+o.status}>{statusLabel[o.status]||o.status}</span></div><p><Clock3 size={14}/> {dateTime(o.scheduled_start)} · {serviceType[o.service_type]||o.service_type}</p><p><MapPin size={14}/> {o.facilities?.name||'Instalación'} · {o.gates?.code||'Portón'}</p><button className="adm-order-tech-toggle" onClick={()=>setExpandedOrder(exp?null:o.id)}><HardHat size={14}/>{exp?'Ocultar técnicos':(o.technician_profiles?o.technician_profiles.first_name+' '+o.technician_profiles.last_name:'Sin técnico · Ver asignaciones')}<ChevronDown size={12} style={{transform:exp?'rotate(180deg)':'none'}}/></button>{exp&&<OrderTechPanel order={o} demoMode={demoMode} allTechs={technicians}/>}</article>;};
 const useShell=!demoMode&&!!onLogout;const shellNavItems=[{key:'live',label:'Trabajos',icon:Wrench},{key:'overview',label:'Resumen',icon:LayoutDashboard},{key:'calendar',label:'Calendario',icon:CalendarDays},{key:'observations',label:'Observaciones',icon:MessageSquare},{key:'contacts',label:'Contactos',icon:Users},{key:'technicians',label:'Técnicos',icon:HardHat}];const _shell=<div className={"adm-shell"+(useShell||embedded?" adm-shell--embedded":"")}><header className="adm-header"><div className="adm-brand"><span className="adm-brand-mark" aria-hidden="true"/>CONSTELMEC</div><span className="adm-subtitle">CENTRO DE CONTROL</span></header><div className="adm-layout"><nav className="adm-nav" aria-label="Administración">{[{key:'live',label:'Trabajos',icon:Wrench},{key:'overview',label:'Resumen',icon:LayoutDashboard},{key:'calendar',label:'Calendario',icon:CalendarDays},{key:'observations',label:'Observaciones',icon:MessageSquare},{key:'contacts',label:'Contactos',icon:Users},{key:'technicians',label:'Técnicos',icon:HardHat}].map(({key,label,icon:Icon})=><button key={key} className={section===key?'active':''} onClick={()=>setSection(key as typeof section)}><Icon size={19}/>{label}</button>)}</nav><main className="adm-main"><div className="adm-heading"><div><small>OPERACIONES / {section==='overview'?'RESUMEN':section==='calendar'?'CALENDARIO':section==='contacts'?'CONTACTOS':section==='live'?'TRABAJOS':section==='observations'?'OBSERVACIONES':'TÉCNICOS'}</small><h1>{section==='overview'?'Centro de control':section==='calendar'?'Agenda de servicios':section==='contacts'?'Contactos':section==='live'?'Trabajos en curso':section==='observations'?'Observaciones de clientes':'Equipo técnico'}</h1></div>{demoMode&&<span className="adm-demo">DATOS DE DEMOSTRACIÓN</span>}</div>{(section==='overview'||section==='calendar'||section==='live')&&<label className="adm-company"><Building2 size={18}/><span>Empresa</span><select value={company} onChange={e=>setCompany(e.target.value)}><option value="all">Todas las empresas</option>{allCompanies.map(c=><option key={c.id} value={c.id}>{c.name}</option>)}</select></label>}
 {section==='live'&&!demoMode&&<WorkDashboard orders={filtered} companyId={company==='all'?undefined:company}/>}
 {section==='live'&&demoMode&&<p>El seguimiento en vivo solo está disponible con sesiones reales.</p>}
 {section==='overview'&&<><div className="adm-metrics">{cards.map(({label,value,icon:Icon},i)=><div className="adm-metric" key={label}><div><span>{label}</span><Icon size={19} color={i===3?'#d3273d':'#8193a6'}/></div><strong>{value}</strong></div>)}</div><div className="adm-columns"><section className="adm-card"><div className="adm-card-title"><h2>Servicios de hoy</h2><button onClick={()=>{setSection('calendar');setSelected(today)}}>Ver agenda</button></div>{todayOrders.length?todayOrders.map(orderCard):<p className="adm-empty">No hay servicios programados para hoy.</p>}</section><section className="adm-card"><div className="adm-card-title"><h2>Próximos servicios</h2><span>{upcoming.length} pendientes</span></div>{upcoming.length?upcoming.slice(0,5).map(orderCard):<p className="adm-empty">No hay próximos servicios pendientes.</p>}</section></div>{overdue.length>0&&<section className="adm-card adm-warning"><h2><AlertTriangle size={19}/> Servicios vencidos</h2>{overdue.map(orderCard)}</section>}</>}
 {section==='calendar'&&<div className="adm-columns"><section className="adm-card"><div className="adm-calendar-title"><button aria-label="Mes anterior" onClick={()=>setMonth(new Date(month.getFullYear(),month.getMonth()-1,1))}><ChevronLeft/></button><h2>{month.toLocaleDateString('es-AR',{month:'long',year:'numeric'})}</h2><button aria-label="Mes siguiente" onClick={()=>setMonth(new Date(month.getFullYear(),month.getMonth()+1,1))}><ChevronRight/></button></div><div className="adm-calendar">{['L','M','M','J','V','S','D'].map((d,i)=><span className="adm-weekday" key={i}>{d}</span>)}{Array.from({length:start},(_,i)=><span key={'pad'+i}/>)}{Array.from({length:daysInMonth},(_,i)=>{const day=dayKey(new Date(month.getFullYear(),month.getMonth(),i+1));const has=filtered.some(o=>dayKey(new Date(o.scheduled_start))===day);return <button key={day} className={[selected===day?'selected':'',day===today?'today':''].join(' ')} onClick={()=>setSelected(day)} aria-label={day}>{i+1}{has&&<i/>}</button>})}</div></section><section className="adm-card"><div style={{display:'flex',alignItems:'center',justifyContent:'space-between',marginBottom:4,flexWrap:'wrap',gap:8}}><h2 style={{margin:0}}>{new Date(selected+'T12:00:00').toLocaleDateString('es-AR',{weekday:'long',day:'numeric',month:'long'})}</h2>{!demoMode&&<button onClick={()=>setNewOrderOpen(true)} style={{display:'flex',alignItems:'center',gap:5,padding:'6px 12px',background:'#1a5eb8',color:'white',border:'none',borderRadius:7,fontSize:13,fontWeight:700,cursor:'pointer'}}><Plus size={14}/>Nueva orden</button>}</div>{chosen.length?chosen.map(orderCard):<p className="adm-empty">No hay servicios para esta fecha.</p>}</section></div>}
 {section==='contacts'&&<ContactManager companies={allCompanies}/>}
 {section==='technicians'&&<TechnicianManager companies={allCompanies}/>}
 {section==='observations'&&<AdminObservationsSection companyId={company==='all'?undefined:company}/>}
 {newOrderOpen&&!demoMode&&<NewOrderModal companies={allCompanies} technicians={technicians} defaultCompanyId={company} defaultDate={selected} onClose={()=>setNewOrderOpen(false)}/>}<p className="adm-footnote">{demoMode?'Información ficticia: las acciones no modifican Supabase.':'Datos reales de Supabase.'}</p></main></div></div>;return useShell?<AppShell navItems={shellNavItems} activeSection={section} onNavigate={k=>setSection(k as typeof section)} brand="Centro de Control" userEmail={email??''} onLogout={onLogout!}>{_shell}</AppShell>:_shell;
}
