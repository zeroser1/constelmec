import {useQuery} from '@tanstack/react-query';
import GateHistory from './GateHistory';
import {supabase} from './lib/supabase';
import {useEffect,useRef,useState} from 'react';
import {AlertTriangle,ArrowLeft,CheckCircle2,DoorOpen,FileText,HardHat,MessageCircle,Send,ShieldAlert,Wrench} from 'lucide-react';
import {useGateObservations,useObservationMutations,useRealGates,useVisits,useCompanyServiceOrders} from './hooks/useRealData';
import type {RealGate} from './lib/types';
import type {Membership} from './lib/types';

type ConvItem={item_type:string;item_id:string;author_role:string;body:string;created_at:string};
function ObsConversation({companyId,obsId,onClose}:{companyId:string;obsId:string;onClose:()=>void}){
 const [items,setItems]=useState<ConvItem[]|null>(null);
 const [loading,setLoading]=useState(true);
 const [err,setErr]=useState('');
 useEffect(()=>{
  setLoading(true);setErr('');
  void(async()=>{try{
   const{data,error}=await supabase!.rpc('get_observation_conversation',{p_company_id:companyId,p_observation_id:obsId});
   if(error)throw new Error(error.message.includes('does not exist')||error.message.includes('no existe')?'':error.message);
   setItems((data??[]) as ConvItem[]);
  }catch(e){const m=(e as Error).message;if(m)setErr(m);}finally{setLoading(false);}})();
 },[companyId,obsId]);
 const roleLabel=(r:string)=>r==='technician'?'Técnico':r==='admin'?'Admin':'Cliente';
 const fmt=(iso:string)=>new Date(iso).toLocaleDateString('es-AR',{day:'2-digit',month:'2-digit',year:'numeric',hour:'2-digit',minute:'2-digit'} as Intl.DateTimeFormatOptions);
 return <div style={{marginTop:8,paddingLeft:12,borderLeft:'2px solid #cbd5e1'}}>
  {loading&&<p style={{fontSize:12,color:'#64748b'}}>Cargando respuestas…</p>}
  {err&&<p style={{fontSize:12,color:'#b91c1c'}}>{err}</p>}
  {items&&items.length===0&&<p style={{fontSize:12,color:'#64748b'}}>Sin respuestas aún.</p>}
  {items&&items.map(it=><div key={it.item_id} style={{marginBottom:8,fontSize:12}}>
   <strong style={{color:it.author_role==='technician'?'#1d4ed8':it.author_role==='admin'?'#166534':'#64748b'}}>{roleLabel(it.author_role)}</strong>
   <span style={{color:'#94a3b8',marginLeft:6}}>{fmt(it.created_at)}</span>
   <p style={{margin:'4px 0 0',color:'#334155'}}>{it.body}</p>
  </div>)}
  <button type="button" onClick={onClose} style={{fontSize:11,color:'#64748b',background:'none',border:'none',cursor:'pointer',padding:'2px 0'}}>Cerrar</button>
 </div>;
}



type Props = {
  companyId: string;
  userId: string;
  membership: Membership;
};

const stateLabel: Record<string, string> = {
  operational: 'Operativo',
  with_observations: 'Con observaciones',
  observations: 'Con observaciones',
  out_of_service: 'Fuera de servicio',
};
const stateClass: Record<string, string> = {
  operational: 'operational',
  with_observations: 'in_progress',
  observations: 'in_progress',
  out_of_service: 'unassigned',
};
const serviceTypeLabel: Record<string, string> = {
  preventive: 'Preventivo', corrective: 'Correctivo',
  installation: 'Instalación', emergency: 'Emergencia',
};
const statusLabel: Record<string, string> = {
  unassigned: 'Sin asignar', scheduled: 'Programado', in_progress: 'En curso',
  completed: 'Finalizado', rescheduled: 'Reprogramado', cancelled: 'Cancelado',
};

function fmt(iso: string) {
  return new Date(iso).toLocaleDateString('es-AR', {day: '2-digit', month: '2-digit', year: 'numeric'});
}

type CustomerLiveJob={gate_id:string;technician_name:string;last_seen_at:string};
function useCustomerLiveJobs(companyId:string){
 return useQuery({queryKey:['customer-live-jobs',companyId],queryFn:async()=>{
  const {data,error}=await supabase!.rpc('monitor_live_inspections');
  if(error)throw new Error(error.message);
  return (data??[]) as CustomerLiveJob[];
 },refetchInterval:30000,refetchIntervalInBackground:false,staleTime:3000});
}
function CustomerWorkStatus({job,isLoading,isError}:{job:CustomerLiveJob|undefined;isLoading:boolean;isError:boolean}){
 if(isLoading)return <span role="status" style={{display:'inline-flex',alignItems:'center',gap:6,fontSize:13,color:'#64748b',padding:'7px 10px'}}>Verificando actividad…</span>;
 if(isError)return <span role="status" style={{display:'inline-flex',alignItems:'center',gap:6,fontSize:13,color:'#92400e',background:'#fef3c7',padding:'7px 10px',borderRadius:8}}>No se pudo verificar la actividad en tiempo real.</span>;
 if(!job)return null;
 const active=Date.now()-new Date(job.last_seen_at).getTime()<=60000;
 return <span role="status" style={{display:'inline-flex',alignItems:'center',gap:6,flexWrap:'wrap',fontSize:13,fontWeight:700,color:active?'#166534':'#92400e',background:active?'#dcfce7':'#fef3c7',padding:'7px 10px',borderRadius:8}}>
  {active?'● Mantenimiento en curso · Técnico trabajando':'● Mantenimiento en curso · Sin actividad reciente'}
  {job.technician_name&&<span style={{fontWeight:500}}> · {job.technician_name}</span>}
 </span>;
}
function GateDetailPanel({gate, companyId, userId}: {gate: RealGate; companyId: string; userId: string}) {
  const visitsQ    = useVisits(companyId);
  const obsQ       = useGateObservations(companyId, gate.id);
  const ordersQ    = useCompanyServiceOrders(companyId);
  const {addObservation} = useObservationMutations(companyId);
  const [body, setBody] = useState('');
  const [sent, setSent]  = useState(false);
  const [expandedOrderId, setExpandedOrderId] = useState<string | null>(null);
  const [expandedObsId, setExpandedObsId] = useState<string | null>(null);

  const gateObs    = (obsQ.data ?? []);
  const gateOrders = (ordersQ.data ?? []).filter(o => o.gates?.code === gate.code);
  const upcoming   = gateOrders.filter(o => !['cancelled','completed'].includes(o.status))
    .sort((a, b) => a.scheduled_start.localeCompare(b.scheduled_start));
  const past       = gateOrders.filter(o => o.status === 'completed')
    .sort((a, b) => b.scheduled_start.localeCompare(a.scheduled_start));

  const submittingRef = useRef(false);

  const submit = () => {
    if (!body.trim() || submittingRef.current) return;
    submittingRef.current = true;
    addObservation.mutate({gateId: gate.id, body: body.trim(), authorId: userId}, {
      onSuccess: () => { setBody(''); setSent(true); setTimeout(() => setSent(false), 3000); },
      onSettled: () => { submittingRef.current = false; },
    });
  };

  return (
    <div className="cust-detail">
      {/* Upcoming */}
      <div className="cust-section-head"><Wrench size={16}/>Próximos servicios</div>
      {upcoming.length === 0 ? (
        <p className="cust-empty">No hay servicios programados.</p>
      ) : upcoming.slice(0, 3).map(o => (
        <div key={o.id} className="cust-order-row">
          <span className={'adm-status ' + o.status}>{statusLabel[o.status] ?? o.status}</span>
          <span className="cust-order-type">{serviceTypeLabel[o.service_type] ?? o.service_type}</span>
          <span className="cust-order-date">{fmt(o.scheduled_start)}</span>
        </div>
      ))}

      {/* Visit history — show completed service orders only; visits are always linked to orders */}
      <div className="cust-section-head"><CheckCircle2 size={16}/>Historial de visitas</div>
      {visitsQ.isLoading && <p className="cust-empty">Cargando…</p>}
      {!visitsQ.isLoading && past.length === 0 && (
        <p className="cust-empty">Sin visitas registradas.</p>
      )}
      {ordersQ.isError && <p role="alert" className="cust-error">No se pudo cargar el historial de órdenes.</p>}
      {past.map(o => (
        <div key={o.id} className="cust-history-entry">
          <button type="button" className="cust-history-row cust-history-button"
            aria-expanded={expandedOrderId === o.id}
            onClick={() => setExpandedOrderId(prev => prev === o.id ? null : o.id)}>
            <CheckCircle2 size={14} className="cust-icon-ok"/>
            <span className="cust-history-description">
              <strong>{serviceTypeLabel[o.service_type] ?? o.service_type}</strong>
              <span>{fmt(o.completed_at ?? o.scheduled_start)}{o.technician_profiles ? ` · ${o.technician_profiles.first_name} ${o.technician_profiles.last_name}` : ''}</span>
            </span>
            <span className="cust-history-action">{expandedOrderId === o.id ? 'Ocultar informe' : 'Ver informe'}</span>
          </button>
          {expandedOrderId === o.id && <GateHistory gateId={gate.id} orderId={o.id}/>}
        </div>
      ))}

      {/* Observations */}
      {gateObs.length > 0 && <>
        <div className="cust-section-head"><FileText size={16}/>Observaciones anteriores</div>
        {gateObs.map(o => (
          <div key={o.id} className="cust-obs-row" style={{flexDirection:'column',alignItems:'flex-start',gap:4}}>
            <div style={{display:'flex',gap:8,alignItems:'flex-start',width:'100%'}}>
              <FileText size={13} style={{flexShrink:0,marginTop:2}}/>
              <div style={{flex:1}}><span className="cust-obs-body">{o.body}</span><span className="cust-obs-date">{fmt(o.created_at)}</span></div>
              <button type="button" onClick={()=>setExpandedObsId(expandedObsId===o.id?null:o.id)}
                style={{flexShrink:0,display:'inline-flex',alignItems:'center',gap:4,fontSize:11,color:'#1d4ed8',background:'none',border:'none',cursor:'pointer',padding:'2px 4px'}}>
                <MessageCircle size={13}/>{expandedObsId===o.id?'Ocultar':'Ver respuestas'}
              </button>
            </div>
            {expandedObsId===o.id&&<ObsConversation companyId={companyId} obsId={o.id} onClose={()=>setExpandedObsId(null)}/>}
          </div>
        ))}
      </>}

      {/* Report observation */}
      <div className="cust-section-head"><AlertTriangle size={16}/>Reportar observación</div>
      <textarea
        className="cust-textarea"
        placeholder="Describí lo que observaste en este portón…"
        maxLength={2000}
        value={body}
        onChange={e => setBody(e.target.value)}
      />
      {sent && <p className="cust-sent"><CheckCircle2 size={14}/>Observación enviada.</p>}
      <button
        className="cust-send-btn"
        disabled={!body.trim() || addObservation.isPending}
        onClick={submit}
      >
        <Send size={15}/>{addObservation.isPending ? 'Enviando…' : 'Enviar observación'}
      </button>
      <p className="cust-footnote">Una observación no crea automáticamente una orden de trabajo.</p>
    </div>
  );
}

export default function CustomerPortal({companyId, userId, membership}: Props) {
  const gatesQ = useRealGates(companyId);
  const liveQ = useCustomerLiveJobs(companyId);
  const activeForGate=(id:string)=>(liveQ.data??[]).find(j=>j.gate_id===id);
  const [selectedGate, setSelectedGate] = useState<RealGate | null>(null);

  const companyName = membership.companies?.name ?? 'Empresa';

  if (gatesQ.isLoading) return (
    <div className="cust-shell">
      <div className="cust-company"><DoorOpen size={20}/><span>{companyName}</span></div>
      <p className="cust-empty">Cargando portones…</p>
    </div>
  );

  if (gatesQ.error) return (
    <div className="cust-shell">
      <p className="cust-error"><ShieldAlert size={16}/>{(gatesQ.error as Error).message}</p>
    </div>
  );

  const gates = gatesQ.data ?? [];

  if (selectedGate) return (
    <div className="cust-shell">
      <div className="cust-company"><DoorOpen size={20}/><span>{companyName}</span></div>
      <button className="cust-back" onClick={() => setSelectedGate(null)}>
        <ArrowLeft size={16}/> Volver a portones
      </button>
      <div className="cust-gate-head">
        <div>
          <div className="cust-gate-code">{selectedGate.code}</div>
          <h2 className="cust-gate-name">{selectedGate.description}</h2>
          <p className="cust-gate-loc">{selectedGate.facilities?.name ?? 'Sin instalación'}{selectedGate.model ? ` · ${selectedGate.model}` : ''}</p>
        </div>
        <span className={`adm-status ${stateClass[selectedGate.operational_state] ?? ''}`}>
          {stateLabel[selectedGate.operational_state] ?? selectedGate.operational_state}
        </span>
      </div>
      <CustomerWorkStatus job={activeForGate(selectedGate.id)} isLoading={liveQ.isLoading} isError={!!liveQ.error}/>
      <GateDetailPanel gate={selectedGate} companyId={companyId} userId={userId}/>
    </div>
  );

  return (
    <div className="cust-shell">
      <div className="cust-company"><DoorOpen size={20}/><span>{companyName}</span></div>
      <h1 className="cust-title">Mis portones</h1>
      {gates.length === 0 ? (
        <p className="cust-empty">No hay portones registrados para esta empresa.</p>
      ) : gates.map(g => (
        <button key={g.id} className="cust-gate-card" onClick={() => setSelectedGate(g)}>
          <div className="cust-gate-icon"><HardHat size={20}/></div>
          <div className="cust-gate-info">
            <strong>{g.code} · {g.description}</strong>
            <span>{g.facilities?.name ?? 'Sin instalación'}{g.model ? ` · ${g.model}` : ''}</span>
            <CustomerWorkStatus job={activeForGate(g.id)} isLoading={false} isError={false}/>
          </div>
          <span className={`adm-status ${stateClass[g.operational_state] ?? ''}`}>
            {stateLabel[g.operational_state] ?? g.operational_state}
          </span>
        </button>
      ))}
      <p className="cust-footnote">Para reportar una falla urgente, contactá directamente a tu administrador.</p>
    </div>
  );
}
