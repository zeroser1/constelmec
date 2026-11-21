import { useEffect, useMemo, useState } from 'react';
import { ArrowLeft, Check, ChevronDown, ChevronRight, ClipboardCheck, CloudOff, DoorOpen, ImagePlus, MapPin, QrCode, ShieldAlert, X } from 'lucide-react';
import './qr-demo.css';

type Result = 'OK' | 'Falla' | 'N/A' | 'No verificable';
type Finding = { description: string; action: string; photoName?: string };
const groups = [
  ['Estructura e integridad', ['Integridad general del portón','Estado de lona / hoja','Guías laterales y fijaciones','Anclajes, soportes y tornillería','Sellos, burletes y terminaciones','Corrosión, deformaciones o golpes']],
  ['Movimiento y mecánica', ['Rodillos y rodamientos','Rieles y deslizamiento','Lubricación de componentes','Topes y amortiguadores','Cables, cadenas y poleas','Alineación y vibraciones']],
  ['Motor y accionamiento', ['Fijación del motor','Reductor y transmisión','Frenos y desbloqueo manual','Ruido y temperatura','Finales de carrera','Protecciones mecánicas']],
  ['PLC y tablero eléctrico', ['Estado del tablero','Cableado y borneras','Protecciones eléctricas','PLC y señales de control','Puesta a tierra','Contactores y relés','Identificación de circuitos']],
  ['Seguridad', ['Fotocélulas','Parada de emergencia','Bordes sensibles','Señalización de maniobra','Resguardos y enclavamientos','Prueba de detección de obstáculos']],
  ['Operación y cierre', ['Apertura completa','Cierre completo','Funcionamiento manual','Comandos de operación','Limpieza y entrega del área']]
] as const;
const all = groups.flatMap((group, gi) => group[1].map((label, ci) => ({ id: gi+'-'+ci, label, group:gi })));
const initial: Record<string,Result> = {'0-0':'OK','0-1':'OK','0-2':'Falla','0-3':'OK','0-4':'OK','0-5':'N/A'};
const STORAGE_KEY = 'constelmec:demo:p014:v1';
const validResults: Result[] = ['OK','Falla','N/A','No verificable'];
const defaultFindings: Record<string,Finding> = {'0-2':{description:'Desalineación en guía derecha. Se observa desgaste y juego excesivo.',action:'Pendiente de reparación'}};
function loadDraft(): {results:Record<string,Result>;findings:Record<string,Finding>} {
  const fallback = {results:initial,findings:defaultFindings};
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return fallback;
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object') return fallback;
    const data = parsed as {results?:unknown;findings?:unknown};
    if (!data.results || typeof data.results !== 'object' || !data.findings || typeof data.findings !== 'object') return fallback;
    const results: Record<string,Result> = {};
    const findings: Record<string,Finding> = {};
    for (const item of all) {
      const result = (data.results as Record<string,unknown>)[item.id];
      if (typeof result === 'string' && validResults.includes(result as Result)) results[item.id] = result as Result;
      const finding = (data.findings as Record<string,unknown>)[item.id];
      if (finding && typeof finding === 'object') {
        const entry = finding as Record<string,unknown>;
        if (typeof entry.description === 'string' && typeof entry.action === 'string')
          findings[item.id] = {description:entry.description.slice(0,500),action:entry.action.slice(0,100)};
      }
    }
    return {results,findings};
  } catch { return fallback; }
}
export default function QRDemo({onBack}:{onBack:()=>void}) {
 const [screen,setScreen]=useState<'gate'|'inspection'|'finding'|'summary'>('gate');
 const [savedDraft] = useState(loadDraft);
 const [results,setResults]=useState<Record<string,Result>>(savedDraft.results);
 const [findings,setFindings]=useState<Record<string,Finding>>(savedDraft.findings);
 const [savedAt,setSavedAt]=useState('');
 const [active,setActive]=useState(0);
 const [findingId,setFindingId]=useState('0-2');
 const [draft,setDraft]=useState<Finding>({description:'',action:'Pendiente de reparación'});
 const [photo,setPhoto]=useState<string|undefined>();
 useEffect(()=>{try {localStorage.setItem(STORAGE_KEY,JSON.stringify({results,findings}));setSavedAt('Borrador guardado en este dispositivo');} catch {setSavedAt('No se pudo guardar el borrador en este dispositivo');}},[results,findings]);
 const resetDraft=()=>{if (!window.confirm('¿Reiniciar la inspección de demostración? Se perderán los cambios guardados en este dispositivo.')) return;setResults(initial);setFindings(defaultFindings);setActive(0);setScreen('gate');};
 const done=Object.keys(results).length;
 const faults=Object.values(results).filter(v=>v==='Falla').length;
 const pending=all.length-done;
 const current=useMemo(()=>all.find(x=>x.id===findingId),[findingId]);
 const editFinding=(id:string)=>{setFindingId(id);setDraft(findings[id]||{description:'',action:'Pendiente de reparación'});setPhoto(undefined);setScreen('finding');};
 const updateResult=(id:string,result:Result)=>{setResults(prev=>({...prev,[id]:result}));if(result==='Falla')editFinding(id);};
 const saveFinding=()=>{if(!draft.description.trim())return;setFindings(prev=>({...prev,[findingId]:{...draft,photoName:photo||prev[findingId]?.photoName}}));setScreen('inspection');};
 return <div className="qr-demo">
 <header className="qr-header"><button aria-label="Volver" onClick={()=>screen==='gate'?onBack():screen==='finding'?setScreen('inspection'):screen==='summary'?setScreen('inspection'):setScreen('gate')}><ArrowLeft size={23}/></button><div className="qr-logo"><span className="qr-swoosh" aria-hidden="true"/> <span>CONSTELMEC</span></div><span className="qr-demo-tag">DEMO</span></header>
 <main className="qr-body">
 {screen==='gate'&&<><div className="qr-title"><span className="qr-eyebrow"><QrCode size={15}/> QR DE EJEMPLO · P-014</span><h1>Inspección de Portón</h1></div><div className="qr-offline"><CloudOff size={25}/><span>Modo demostración: el borrador se guarda en este dispositivo, sin sincronización con el servidor.</span></div><div className="qr-gate-visual"><img src="/gate-reference.jpg" alt="Portón industrial enrollable azul de referencia" /></div><div className="qr-gate-title"><div><h2>P-014</h2><p>Enrollable Rápido</p></div><span className="qr-active">Activo</span></div><p className="qr-location"><MapPin size={18}/> Planta Principal · Sector Logística</p><section className="qr-specs"><div><span>N.º de serie</span><strong>CM-2024-0014</strong></div><div><span>Modelo</span><strong>CR-3000</strong></div><div><span>PLC</span><strong>Siemens S7-1200</strong></div><div><span>Último service</span><strong>15/08/2026</strong></div></section><div className="qr-alert"><ShieldAlert size={21}/> {Math.max(2,faults)} fallas pendientes <ChevronRight size={19}/></div><button className="qr-primary" onClick={()=>setScreen('inspection')}>Iniciar inspección <ChevronRight size={19}/></button></>}
 {screen==='inspection'&&<><div className="qr-title"><h1>Inspección · P-014</h1><p>Enrollable Rápido</p></div><div className="qr-progress-title"><strong>{done} de {all.length} controles</strong><strong>{Math.round(done/all.length*100)}%</strong></div><p className="qr-save-status" role="status">{savedAt}</p><div className="qr-progress"><span style={{width:done/all.length*100+'%'}}/></div><div className="qr-groups">{groups.map(([name,items],gi)=>{const n=items.filter((_,ci)=>results[gi+'-'+ci]).length;return <section className="qr-group" key={name}><button className="qr-group-heading" onClick={()=>setActive(active===gi?-1:gi)}><ChevronDown className={active===gi?'':'qr-collapsed'} size={19}/><strong>{gi+1}. {name}</strong><span>{n}/{items.length}</span>{n===items.length&&<Check size={19} className="qr-complete"/>}</button>{active===gi&&<div className="qr-group-items">{items.map((label,ci)=>{const id=gi+'-'+ci;return <div className="qr-control" key={id}><div className="qr-control-title"><strong>{label}</strong>{results[id]==='Falla'&&<button className="qr-edit" onClick={()=>editFinding(id)}>Detalle <ChevronRight size={14}/></button>}</div><div className="qr-choices">{(['OK','Falla','N/A'] as Result[]).map(value=><button key={value} className={'qr-choice '+(results[id]===value?'is-'+(value==='OK'?'ok':value==='Falla'?'fault':'na'):'')} aria-pressed={results[id]===value} onClick={()=>updateResult(id,value)}>{value==='OK'?'✓ ':value==='Falla'?'× ':''}{value}</button>)}</div><button className="qr-unverifiable" aria-pressed={results[id]==='No verificable'} onClick={()=>updateResult(id,'No verificable')}>{results[id]==='No verificable'?'✓ No verificable':'No verificable / sin acceso'}</button></div>})}</div>}</section>})}</div><button className="qr-primary" disabled={pending>0 || Object.entries(results).some(([id,r])=>r==='Falla'&&!findings[id]?.description.trim())} onClick={()=>setScreen('summary')}>Finalizar inspección</button><p className="qr-hint">{pending? 'Completá los '+pending+' controles pendientes para habilitar el cierre.':'Revisá los resultados antes de finalizar.'}</p><button className="qr-reset" onClick={resetDraft}>Reiniciar demo</button></>}
 {screen==='finding'&&<><div className="qr-title"><h1>Falla detectada</h1><p>{current?.label}</p></div><div className="qr-fault-pill"><X size={19}/> Falla</div><label className="qr-field">Descripción de la falla *</label><textarea className="qr-textarea" maxLength={500} value={draft.description} onChange={e=>setDraft({...draft,description:e.target.value})} placeholder="Describí el problema encontrado..."/><div className="qr-count">{draft.description.length} / 500</div><label className="qr-field">Evidencia fotográfica</label><label className="qr-upload"><ImagePlus size={26}/><span>{photo||draft.photoName||'Agregar foto (solo demo)'}</span><input type="file" accept="image/*" capture="environment" onChange={e=>setPhoto(e.target.files?.[0]?.name)} /></label><label className="qr-field">Acción / Estado</label><div className="qr-actions">{['Pendiente de reparación','Reparado durante la visita','Requiere repuesto','Fuera de servicio por seguridad'].map(action=><button key={action} className={draft.action===action?'selected':''} onClick={()=>setDraft({...draft,action})}><span className="qr-radio"/>{action}</button>)}</div><button className="qr-primary" disabled={!draft.description.trim()} onClick={saveFinding}>Guardar falla</button><p className="qr-hint">La descripción se guarda localmente; la fotografía seleccionada no se conserva ni se sube.</p></>}
 {screen==='summary'&&<><div className="qr-title"><h1>Resumen de inspección</h1><p>Portón P-014 · Enrollable Rápido</p></div><section className="qr-specs"><div><span>Controles realizados</span><strong>{done}/{all.length}</strong></div><div><span>Correctos</span><strong>{Object.values(results).filter(x=>x==='OK').length}</strong></div><div><span>Fallas detectadas</span><strong>{faults}</strong></div><div><span>No verificables</span><strong>{Object.values(results).filter(x=>x==='No verificable').length}</strong></div></section><div className="qr-alert"><ShieldAlert size={21}/> Informe de demostración: no es una certificación técnica.</div><button className="qr-primary" onClick={()=>setScreen('gate')}>Volver al portón</button></>}
 </main><nav className="qr-bottom"><button onClick={onBack}><DoorOpen size={22}/>Inicio</button><button className="selected" onClick={()=>setScreen('gate')}><QrCode size={22}/>Escanear</button><button onClick={()=>setScreen('inspection')}><ClipboardCheck size={22}/>Servicios</button><button onClick={onBack}><span className="qr-profile-icon">T</span>Perfil</button></nav>
 </div>;
}
