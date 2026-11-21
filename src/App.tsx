import { useMemo, useState } from 'react';
import { Activity, ArrowLeft, ArrowRight, Building2, CheckCircle2, ChevronDown, ClipboardCheck, Clock3, DoorOpen, FileText, HardHat, History, LayoutDashboard, Menu, Plus, QrCode, Search, ShieldAlert, Wrench, X, AlertTriangle, Send } from 'lucide-react';

type Role = 'technician' | 'customer';
type GateState = 'Operativo' | 'Con observaciones' | 'Fuera de servicio';
type ControlStatus = 'Pendiente' | 'OK' | 'Falla' | 'N/A' | 'No verificable';
type Gate = { id: string; name: string; code: string; location: string; model: string; state: GateState; last: string; next: string; observations: number };
type Control = { id: string; label: string; status: ControlStatus; note: string };
type Visit = { gateId: string; completedAt: string; issueCount: number; technician: string };
type Observation = { gateId: string; text: string; author: string; createdAt: string };
const initialGates: Gate[] = [
  { id: 'g1', name: 'Portón principal', code: 'CM-001', location: 'Planta Norte · Acceso A', model: 'Corredizo industrial', state: 'Operativo', last: '12 nov 2026', next: '12 feb 2027', observations: 0 },
  { id: 'g2', name: 'Portón de carga', code: 'CM-002', location: 'Planta Norte · Depósito', model: 'Seccional motorizado', state: 'Con observaciones', last: '05 nov 2026', next: '05 feb 2027', observations: 2 },
  { id: 'g3', name: 'Portón lateral', code: 'CM-003', location: 'Planta Sur · Acceso B', model: 'Levadizo industrial', state: 'Fuera de servicio', last: '29 oct 2026', next: 'Pendiente', observations: 1 },
  { id: 'g4', name: 'Portón estacionamiento', code: 'CM-004', location: 'Planta Sur · Parking', model: 'Corredizo automático', state: 'Operativo', last: '08 nov 2026', next: '08 feb 2027', observations: 0 }
];
const controlLabels = ['Estado general y estructura', 'Motor y transmisión', 'Sensores y dispositivos de seguridad', 'Guías, rodillos y herrajes', 'Sistema eléctrico y comandos', 'Prueba de apertura y cierre'];
const makeControls = (): Control[] => controlLabels.map((label, index) => ({ id: String(index), label, status: 'Pendiente', note: '' }));
const badgeClass = (state: GateState) => state === 'Operativo' ? 'good' : state === 'Con observaciones' ? 'warn' : 'danger';
const today = () => new Intl.DateTimeFormat('es-AR', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date());

export default function App() {
  const [role, setRole] = useState<Role>('technician');
  const [gates, setGates] = useState(initialGates);
  const [selected, setSelected] = useState<string | null>(null);
  const [search, setSearch] = useState('');
  const [filter, setFilter] = useState('Todos');
  const [controls, setControls] = useState<Control[]>(makeControls);
  const [visitOpen, setVisitOpen] = useState(false);
  const [visits, setVisits] = useState<Visit[]>([]);
  const [observations, setObservations] = useState<Observation[]>([]);
  const [observationText, setObservationText] = useState('');
  const [message, setMessage] = useState('');
  const [mobileMenu, setMobileMenu] = useState(false);
  const gate = gates.find(g => g.id === selected);
  const filtered = useMemo(() => gates.filter(g => (filter === 'Todos' || g.state === filter) && (g.name + g.code + g.location).toLowerCase().includes(search.toLowerCase())), [gates, filter, search]);
  const counts = { total: gates.length, good: gates.filter(g => g.state === 'Operativo').length, warning: gates.filter(g => g.state === 'Con observaciones').length, danger: gates.filter(g => g.state === 'Fuera de servicio').length };
  const completed = controls.filter(c => c.status !== 'Pendiente').length;
  const showMessage = (text: string) => { setMessage(text); };
  const chooseGate = (id: string) => { setSelected(id); setVisitOpen(false); setControls(makeControls()); setMessage(''); setMobileMenu(false); };
  const closeVisit = () => {
    if (!gate || !visitOpen || completed !== controls.length) return;
    const issues = controls.filter(c => c.status === 'Falla').length;
    const unverified = controls.filter(c => c.status === 'No verificable').length;
    const state: GateState = gate.state === 'Fuera de servicio' ? 'Fuera de servicio' : issues || unverified ? 'Con observaciones' : gate.state === 'Con observaciones' ? 'Con observaciones' : 'Operativo';
    setGates(prev => prev.map(g => g.id === gate.id ? { ...g, state, last: today(), observations: g.observations + issues } : g));
    setVisits(prev => [{ gateId: gate.id, completedAt: today(), issueCount: issues, technician: 'Técnico demo' }, ...prev]);
    setVisitOpen(false);
    showMessage('Visita de demostración cerrada. No se generó un registro real ni un informe PDF.');
  };
  const addObservation = () => {
    if (!gate || !observationText.trim()) return;
    setObservations(prev => [{ gateId: gate.id, text: observationText.trim(), author: 'Cliente demo', createdAt: today() }, ...prev]);
    setObservationText('');
    showMessage('Observación guardada solo en esta demostración. No crea una falla técnica.');
  };
  return <div className="app">
    <aside className={mobileMenu ? 'sidebar open' : 'sidebar'}>
      <div className="brand"><div className="brand-icon"><DoorOpen size={25}/></div><div><strong>CONSTELMEC</strong><small>MAINTENANCE</small></div></div>
      <div className="workspace"><div className="workspace-logo"><Building2 size={19}/></div><div><strong>Empresa de ejemplo</strong><small>Entorno de demostración</small></div><ChevronDown size={16}/></div>
      <div className="nav-label">ESPACIO DE TRABAJO</div>
      <button className={!selected ? 'nav active' : 'nav'} onClick={() => { setSelected(null); setMobileMenu(false); }}><LayoutDashboard size={19}/> Panel general</button>
      <button className={selected ? 'nav active' : 'nav'} onClick={() => { chooseGate(gates[0].id); }}><DoorOpen size={19}/> Portones <span className="nav-count">{gates.length}</span></button>
      <button className="nav" onClick={() => showMessage('El historial real estará disponible al conectar Supabase y la auditoría.') }><History size={19}/> Historial</button>
      <button className="nav" onClick={() => showMessage('Los informes PDF se incorporarán en una próxima etapa.') }><FileText size={19}/> Informes</button>
      <div className="sidebar-bottom"><div className="demo-label"><span className="live-dot"/> DEMO · SIN DATOS REALES</div><div className="profile"><div className="avatar">{role === 'technician' ? 'TC' : 'CL'}</div><div><strong>{role === 'technician' ? 'Técnico demo' : 'Cliente demo'}</strong><small>{role === 'technician' ? 'Personal técnico' : 'Portal de cliente'}</small></div></div></div>
    </aside>
    {mobileMenu && <button className="scrim" aria-label="Cerrar menú" onClick={() => setMobileMenu(false)}/>}
    <main className="main">
      <header className="topbar"><button className="mobile-menu icon-btn" aria-label="Abrir menú" onClick={() => setMobileMenu(true)}><Menu size={21}/></button><div className="breadcrumbs">Constelmec <span>/</span> {gate ? gate.code : 'Panel general'}</div><div className="top-actions"><span className="demo-pill">● Demo interactiva</span><div className="role-toggle" aria-label="Cambiar vista"><button className={role === 'technician' ? 'selected' : ''} onClick={() => { setRole('technician'); setSelected(null); }}><HardHat size={15}/> Técnico</button><button className={role === 'customer' ? 'selected' : ''} onClick={() => { setRole('customer'); setSelected(null); }}><Building2 size={15}/> Cliente</button></div></div></header>
      <div className="content">
        {message && <div className="toast" role="status"><CheckCircle2 size={18}/>{message}<button aria-label="Cerrar aviso" onClick={() => setMessage('')}><X size={17}/></button></div>}
        {!gate ? <>
          <div className="page-head"><div><div className="eyebrow"><span className="live-dot"/> VISTA {role === 'technician' ? 'TÉCNICA' : 'DEL CLIENTE'}</div><h1>{role === 'technician' ? 'Control de mantenimiento' : 'Mis instalaciones'}</h1><p>{role === 'technician' ? 'Estado de los equipos, intervenciones y próximos mantenimientos.' : 'Consultá el estado de tus portones y registrá observaciones.'}</p></div><button className="btn primary" onClick={() => showMessage('El escaneo QR se habilitará con autenticación y control de acceso por empresa.')}><QrCode size={18}/> Escanear QR</button></div>
          <div className="stats"><div className="stat"><div className="stat-icon blue"><DoorOpen size={20}/></div><span>Portones registrados</span><strong>{counts.total}</strong><small>Equipos en instalaciones</small></div><div className="stat"><div className="stat-icon green"><CheckCircle2 size={20}/></div><span>Operativos</span><strong>{counts.good}</strong><small>Sin alertas activas</small></div><div className="stat"><div className="stat-icon amber"><AlertTriangle size={20}/></div><span>Con observaciones</span><strong>{counts.warning}</strong><small>Requieren seguimiento</small></div><div className="stat"><div className="stat-icon red"><ShieldAlert size={20}/></div><span>Fuera de servicio</span><strong>{counts.danger}</strong><small>Requieren intervención</small></div></div>
          <section className="panel"><div className="panel-head"><div><h2>Portones de la instalación</h2><p>Seleccioná un equipo para consultar su ficha y mantenimiento.</p></div><span className="count-pill">{filtered.length} equipos</span></div><div className="tools"><div className="search"><Search size={18}/><input aria-label="Buscar portones" value={search} onChange={e => setSearch(e.target.value)} placeholder="Buscar por nombre, código o sector..."/></div><div className="filters">{['Todos','Operativo','Con observaciones','Fuera de servicio'].map(f => <button key={f} className={filter === f ? 'filter active' : 'filter'} onClick={() => setFilter(f)}>{f}</button>)}</div></div>
          <div className="gate-list">{filtered.map(g => <button className="gate-row" key={g.id} onClick={() => chooseGate(g.id)}><div className="gate-symbol"><DoorOpen size={22}/></div><div className="gate-info"><strong>{g.name}</strong><span>{g.code} <b>·</b> {g.location}</span></div><div className="gate-date"><span>Último mantenimiento</span><strong>{g.last}</strong></div><span className={'status '+badgeClass(g.state)}><span className="status-dot"/>{g.state}</span><ArrowRight size={19} className="row-arrow"/></button>)}{filtered.length === 0 && <div className="empty">No se encontraron portones con esos filtros.</div>}</div></section>
          <div className="bottom-grid"><section className="panel small-panel"><div className="mini-heading"><Clock3 size={19}/><h3>Próximos mantenimientos</h3></div>{gates.slice(0,3).map(g => <button className="mini-row" key={g.id} onClick={() => chooseGate(g.id)}><span>{g.name}<small>{g.location}</small></span><strong>{g.next}</strong></button>)}</section><section className="panel small-panel"><div className="mini-heading"><Activity size={19}/><h3>Actividad reciente</h3></div><div className="activity"><span className="activity-dot"/><div><strong>{visits.length ? 'Visita cerrada en esta sesión' : 'Bienvenido a Constelmec Maintenance'}</strong><p>{visits.length ? visits[0].completedAt : 'Este entorno usa datos ficticios para probar el flujo.'}</p></div></div><div className="activity"><span className="activity-dot muted"/><div><strong>Registro de auditoría</strong><p>Se habilitará con el backend seguro.</p></div></div></section></div>
        </> : <>
          <button className="back" onClick={() => setSelected(null)}><ArrowLeft size={17}/> Volver a portones</button>
          <div className="detail-head"><div><div className="eyebrow">FICHA DEL EQUIPO · {gate.code}</div><h1>{gate.name}</h1><p>{gate.location}</p></div><span className={'status large '+badgeClass(gate.state)}><span className="status-dot"/>{gate.state}</span></div>
          <div className="detail-grid"><section className="panel detail-card"><div className="mini-heading"><DoorOpen size={20}/><h3>Información del equipo</h3></div><div className="placeholder-photo"><DoorOpen size={43}/><span>Fotografía de referencia pendiente</span></div><div className="data-row"><span>Código</span><strong>{gate.code}</strong></div><div className="data-row"><span>Tipo</span><strong>{gate.model}</strong></div><div className="data-row"><span>Último mantenimiento</span><strong>{gate.last}</strong></div><div className="data-row"><span>Próximo mantenimiento</span><strong>{gate.next}</strong></div></section>
          <section className="panel detail-card"><div className="mini-heading"><ClipboardCheck size={20}/><h3>{role === 'technician' ? 'Inspección técnica' : 'Seguimiento del equipo'}</h3></div>{role === 'technician' ? !visitOpen ? <div className="callout"><Wrench size={27}/><h3>Registrar mantenimiento</h3><p>Iniciá una visita de demostración para completar los controles del portón.</p><button className="btn primary" onClick={() => { setControls(makeControls()); setVisitOpen(true); }}><Plus size={17}/> Iniciar visita</button></div> : <><div className="progress-text"><strong>Checklist de inspección</strong><span>{completed}/{controls.length} completados</span></div><div className="progress"><span style={{width: (completed/controls.length*100)+'%'}}/></div><div className="checks">{controls.map(c => <div className="check" key={c.id}><strong>{c.label}</strong><select aria-label={'Estado de '+c.label} value={c.status} onChange={e => setControls(prev => prev.map(x => x.id === c.id ? {...x, status: e.target.value as ControlStatus} : x))}>{['Pendiente','OK','Falla','N/A','No verificable'].map(s => <option key={s}>{s}</option>)}</select>{(c.status === 'Falla' || c.status === 'No verificable') && <textarea aria-label={'Nota de '+c.label} placeholder="Describí el hallazgo..." value={c.note} onChange={e => setControls(prev => prev.map(x => x.id === c.id ? {...x, note: e.target.value} : x))}/>}</div>)}</div><div className="visit-actions"><button className="btn ghost" onClick={() => setVisitOpen(false)}>Cancelar</button><button className="btn primary" disabled={completed !== controls.length || controls.some(c => (c.status === 'Falla' || c.status === 'No verificable') && !c.note.trim())} onClick={closeVisit}><CheckCircle2 size={17}/> Cerrar visita</button></div><p className="fineprint">El cierre de una visita no certifica que el portón sea seguro. El estado fuera de servicio no se levanta automáticamente.</p></> : <><div className="callout customer"><Activity size={27}/><h3>Estado actual</h3><p>El equipo figura como <strong>{gate.state.toLowerCase()}</strong>. Los datos son de demostración y no se actualizan en tiempo real.</p></div><label className="field-label" htmlFor="observation">Enviar observación</label><textarea id="observation" className="observation-input" value={observationText} onChange={e => setObservationText(e.target.value)} placeholder="Describí qué observaste en este portón..." maxLength={1000}/><button className="btn primary" disabled={!observationText.trim()} onClick={addObservation}><Send size={17}/> Enviar observación</button><p className="fineprint">Una observación del cliente no crea automáticamente una falla técnica ni una orden de trabajo.</p></>}</section></div>
          <section className="panel history-panel"><div className="mini-heading"><History size={19}/><h3>Historial y observaciones</h3></div>{visits.filter(v => v.gateId === gate.id).map((v,i) => <div className="history-item" key={'v'+i}><ClipboardCheck size={18}/><div><strong>Mantenimiento de demostración finalizado</strong><p>{v.completedAt} · {v.technician} · {v.issueCount} fallas marcadas</p></div></div>)}{observations.filter(o => o.gateId === gate.id).map((o,i) => <div className="history-item" key={'o'+i}><FileText size={18}/><div><strong>Observación de {o.author}</strong><p>{o.text} · {o.createdAt}</p></div></div>)}{!visits.some(v => v.gateId === gate.id) && !observations.some(o => o.gateId === gate.id) && <div className="empty compact">Todavía no hay registros creados en esta sesión de demostración.</div>}</section>
        </>}
        <footer>CONSTELMEC MAINTENANCE <span>·</span> PROTOTIPO v0.1 <span>·</span> Datos ficticios, sin conexión al servidor</footer>
      </div>
    </main>
  </div>;
}
