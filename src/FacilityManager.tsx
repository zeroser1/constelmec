import { useState } from 'react';
import { Building, ChevronRight, Copy, Plus, QrCode, Wrench, X } from 'lucide-react';
import type { Company } from './AdminControl';
import type { AdminGate, GateOperationalState, GateQR, RealFacility } from './lib/types';
import {
  useFacilities, useFacilityMutations,
  useAdminGates, useGateMutations, useQRMutations,
  type FacilityFormInput, type GateFormInput,
} from './hooks/useRealData';

// ── helpers ──────────────────────────────────────────────────────────────

function fmtDate(iso: string | null | undefined) {
  if (!iso) return '—';
  const d = new Date(iso);
  return `${String(d.getDate()).padStart(2,'0')}/${String(d.getMonth()+1).padStart(2,'0')}/${d.getFullYear()}`;
}

function activeQR(gate: AdminGate): GateQR | undefined {
  return gate.gate_qr_codes?.find(q => q.status === 'active');
}

const STATE_LABEL: Record<GateOperationalState, string> = {
  operational:       'Operativo',
  with_observations: 'Con observaciones',
  out_of_service:    'Fuera de servicio',
};
const STATE_COLOR: Record<GateOperationalState, string> = {
  operational:       '#0a7c42',
  with_observations: '#b65c00',
  out_of_service:    '#c41e32',
};

// ── input styles (shared) ─────────────────────────────────────────────────

const inp: React.CSSProperties = {
  border:'1px solid #dfe6ef', borderRadius:8, padding:'10px 12px', fontSize:14,
  fontFamily:'Arial,Helvetica,sans-serif', color:'#1b2838', background:'white',
  width:'100%', boxSizing:'border-box',
};

function Field({ label, children, required }: { label:string; children:React.ReactNode; required?:boolean }) {
  return (
    <label style={{ display:'flex', flexDirection:'column', gap:5, fontFamily:'Arial,Helvetica,sans-serif' }}>
      <span style={{ fontSize:11, fontWeight:800, color:'#728499', letterSpacing:'0.6px', textTransform:'uppercase' }}>
        {label}{required && <span style={{ color:'#c41e32', marginLeft:2 }}>*</span>}
      </span>
      {children}
    </label>
  );
}

// ── FacilityForm modal ────────────────────────────────────────────────────

type FacilityFormProps = {
  initial?: RealFacility;
  onSubmit: (data: FacilityFormInput) => Promise<void>;
  onClose: () => void;
};

const emptyFac: FacilityFormInput = { name:'', address:'', location_notes:'', contact_name:'', contact_phone:'' };

function FacilityForm({ initial, onSubmit, onClose }: FacilityFormProps) {
  const [form, setForm] = useState<FacilityFormInput>({
    name:           initial?.name           ?? '',
    address:        initial?.address        ?? '',
    location_notes: initial?.location_notes ?? '',
    contact_name:   initial?.contact_name   ?? '',
    contact_phone:  initial?.contact_phone  ?? '',
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const field = (k: keyof FacilityFormInput) => ({
    value: form[k],
    onChange: (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
      setForm(prev => ({ ...prev, [k]: e.target.value })),
  });

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (form.name.trim().length < 2) { setError('El nombre debe tener al menos 2 caracteres.'); return; }
    setBusy(true); setError('');
    try { await onSubmit(form); onClose(); }
    catch (err) {
      const msg = err instanceof Error ? err.message : '';
      setError(msg.includes('concurrent edit conflict')
        ? 'Esta instalación fue editada por otro usuario. Cerrá el formulario y volvé a abrirlo.'
        : msg || 'Error al guardar instalación.');
    } finally { setBusy(false); }
  };

  return (
    <div style={{ position:'fixed',inset:0,background:'rgba(0,0,0,.55)',display:'flex',alignItems:'center',justifyContent:'center',zIndex:200,padding:16 }}>
      <div style={{ background:'white',borderRadius:14,width:'100%',maxWidth:460,maxHeight:'90vh',display:'flex',flexDirection:'column',boxShadow:'0 20px 60px rgba(0,0,0,.3)' }}>
        <div style={{ display:'flex',alignItems:'center',justifyContent:'space-between',padding:'20px 24px 0',flexShrink:0 }}>
          <h2 style={{ margin:0,fontSize:19,fontWeight:800,color:'#10263e',fontFamily:'Arial,Helvetica,sans-serif' }}>
            {initial ? 'Editar instalación' : 'Nueva instalación'}
          </h2>
          <button onClick={onClose} disabled={busy} style={{ background:'none',border:0,cursor:'pointer',color:'#8295a8',padding:4,borderRadius:6 }}>
            <X size={20} />
          </button>
        </div>

        <form onSubmit={submit} style={{ overflow:'auto',padding:'20px 24px 24px',display:'flex',flexDirection:'column',gap:14 }}>
          <Field label="Nombre *" required>
            <input {...field('name')} placeholder="Planta Norte" style={inp} required minLength={2} />
          </Field>
          <Field label="Dirección">
            <input {...field('address')} placeholder="Ruta 9 km 42, Buenos Aires" style={inp} />
          </Field>
          <Field label="Notas de ubicación">
            <textarea {...field('location_notes')} placeholder="Edificio principal, acceso por portón lateral..." rows={2} style={{ ...inp, resize:'vertical', minHeight:60 }} />
          </Field>
          <div style={{ display:'grid',gridTemplateColumns:'1fr 1fr',gap:12 }}>
            <Field label="Contacto">
              <input {...field('contact_name')} placeholder="Juan García" style={inp} />
            </Field>
            <Field label="Teléfono">
              <input {...field('contact_phone')} placeholder="011-4444-5555" style={inp} />
            </Field>
          </div>

          {error && <p style={{ margin:0,color:'#c41e32',fontSize:13,fontFamily:'Arial,Helvetica,sans-serif' }}>{error}</p>}

          <div style={{ display:'flex',gap:10,justifyContent:'flex-end',paddingTop:4 }}>
            <button type="button" onClick={() => { setForm(emptyFac); setError(''); }} disabled={busy}
              style={{ background:'none',border:'1px solid #cdd5df',borderRadius:8,padding:'10px 16px',cursor:'pointer',color:'#526479',fontFamily:'Arial,Helvetica,sans-serif',fontSize:13 }}>
              Limpiar
            </button>
            <button type="button" onClick={onClose} disabled={busy}
              style={{ background:'none',border:'1px solid #cdd5df',borderRadius:8,padding:'10px 16px',cursor:'pointer',color:'#526479',fontFamily:'Arial,Helvetica,sans-serif',fontSize:13 }}>
              Cancelar
            </button>
            <button type="submit" disabled={busy}
              style={{ background:'#10263e',border:0,borderRadius:8,padding:'10px 20px',cursor:'pointer',color:'white',fontWeight:700,fontFamily:'Arial,Helvetica,sans-serif',fontSize:13,opacity:busy?0.7:1 }}>
              {busy ? 'Guardando...' : initial ? 'Guardar cambios' : 'Crear instalación'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

// ── GateForm modal ────────────────────────────────────────────────────────

type GateFormProps = {
  initial?: AdminGate;
  onSubmit: (data: GateFormInput) => Promise<void>;
  onClose: () => void;
};


function GateForm({ initial, onSubmit, onClose }: GateFormProps) {
  const [form, setForm] = useState<GateFormInput>({
    code:                 initial?.code                 ?? '',
    description:          initial?.description          ?? '',
    model:                initial?.model                ?? '',
    serial_number:        initial?.serial_number        ?? '',
    location_description: initial?.location_description ?? '',
    operational_state:    initial?.operational_state    ?? 'operational',
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const field = (k: keyof GateFormInput) => ({
    value: form[k],
    onChange: (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) =>
      setForm(prev => ({ ...prev, [k]: e.target.value })),
  });

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.code.trim()) { setError('El código es obligatorio.'); return; }
    if (form.description.trim().length < 2) { setError('La descripción debe tener al menos 2 caracteres.'); return; }
    setBusy(true); setError('');
    try { await onSubmit(form); onClose(); }
    catch (err) {
      const msg = err instanceof Error ? err.message : '';
      setError(msg.includes('concurrent edit conflict')
        ? 'Este portón fue editado por otro usuario. Cerrá el formulario y volvé a abrirlo.'
        : msg || 'Error al guardar portón.');
    } finally { setBusy(false); }
  };

  return (
    <div style={{ position:'fixed',inset:0,background:'rgba(0,0,0,.55)',display:'flex',alignItems:'center',justifyContent:'center',zIndex:200,padding:16 }}>
      <div style={{ background:'white',borderRadius:14,width:'100%',maxWidth:460,maxHeight:'90vh',display:'flex',flexDirection:'column',boxShadow:'0 20px 60px rgba(0,0,0,.3)' }}>
        <div style={{ display:'flex',alignItems:'center',justifyContent:'space-between',padding:'20px 24px 0',flexShrink:0 }}>
          <h2 style={{ margin:0,fontSize:19,fontWeight:800,color:'#10263e',fontFamily:'Arial,Helvetica,sans-serif' }}>
            {initial ? 'Editar portón' : 'Nuevo portón'}
          </h2>
          <button onClick={onClose} disabled={busy} style={{ background:'none',border:0,cursor:'pointer',color:'#8295a8',padding:4,borderRadius:6 }}>
            <X size={20} />
          </button>
        </div>

        <form onSubmit={submit} style={{ overflow:'auto',padding:'20px 24px 24px',display:'flex',flexDirection:'column',gap:14 }}>
          <div style={{ display:'grid',gridTemplateColumns:'1fr 2fr',gap:12 }}>
            <Field label="Código *" required>
              <input {...field('code')} placeholder="P-01" style={inp} required disabled={!!initial} />
            </Field>
            <Field label="Descripción *" required>
              <input {...field('description')} placeholder="Portón principal de acceso" style={inp} required minLength={2} />
            </Field>
          </div>
          <div style={{ display:'grid',gridTemplateColumns:'1fr 1fr',gap:12 }}>
            <Field label="Modelo">
              <input {...field('model')} placeholder="CAME BX-243" style={inp} />
            </Field>
            <Field label="Número de serie">
              <input {...field('serial_number')} placeholder="SN-9871234" style={inp} />
            </Field>
          </div>
          <Field label="Ubicación dentro de la instalación">
            <input {...field('location_description')} placeholder="Sector A, junto a garita" style={inp} />
          </Field>
          <Field label="Estado operativo">
            <select {...field('operational_state')} style={{ ...inp, cursor:'pointer' }}>
              <option value="operational">Operativo</option>
              <option value="with_observations">Con observaciones</option>
              <option value="out_of_service">Fuera de servicio</option>
            </select>
          </Field>

          {error && <p style={{ margin:0,color:'#c41e32',fontSize:13,fontFamily:'Arial,Helvetica,sans-serif' }}>{error}</p>}

          <div style={{ display:'flex',gap:10,justifyContent:'flex-end',paddingTop:4 }}>
            <button type="button" onClick={onClose} disabled={busy}
              style={{ background:'none',border:'1px solid #cdd5df',borderRadius:8,padding:'10px 16px',cursor:'pointer',color:'#526479',fontFamily:'Arial,Helvetica,sans-serif',fontSize:13 }}>
              Cancelar
            </button>
            <button type="submit" disabled={busy}
              style={{ background:'#10263e',border:0,borderRadius:8,padding:'10px 20px',cursor:'pointer',color:'white',fontWeight:700,fontFamily:'Arial,Helvetica,sans-serif',fontSize:13,opacity:busy?0.7:1 }}>
              {busy ? 'Guardando...' : initial ? 'Guardar cambios' : 'Crear portón'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

// ── QR token reveal modal ─────────────────────────────────────────────────

function QRTokenModal({ token, onClose }: { token: string; onClose: () => void }) {
  const [copied, setCopied] = useState(false);
  const copy = () => {
    navigator.clipboard.writeText(token).then(() => { setCopied(true); setTimeout(() => setCopied(false), 2000); });
  };
  return (
    <div style={{ position:'fixed',inset:0,background:'rgba(0,0,0,.65)',display:'flex',alignItems:'center',justifyContent:'center',zIndex:300,padding:16 }}>
      <div style={{ background:'white',borderRadius:14,width:'100%',maxWidth:440,boxShadow:'0 20px 60px rgba(0,0,0,.35)',padding:'28px 28px 24px',fontFamily:'Arial,Helvetica,sans-serif' }}>
        <div style={{ display:'flex',alignItems:'center',gap:10,marginBottom:12 }}>
          <QrCode size={22} style={{ color:'#0a7c42',flexShrink:0 }} />
          <h2 style={{ margin:0,fontSize:17,fontWeight:800,color:'#10263e' }}>Token QR emitido</h2>
        </div>
        <p style={{ margin:'0 0 8px',fontSize:13,color:'#c41e32',fontWeight:700 }}>
          Copiá este token ahora — no se mostrará de nuevo.
        </p>
        <div style={{ background:'#f0f4f9',borderRadius:8,padding:'12px 14px',marginBottom:16,wordBreak:'break-all',fontFamily:'monospace',fontSize:13,color:'#10263e',lineHeight:1.6 }}>
          {token}
        </div>
        <div style={{ display:'flex',gap:10,justifyContent:'flex-end' }}>
          <button onClick={copy}
            style={{ display:'flex',alignItems:'center',gap:6,background:'#10263e',border:0,borderRadius:8,padding:'10px 18px',cursor:'pointer',color:'white',fontWeight:700,fontSize:13 }}>
            <Copy size={14} /> {copied ? '¡Copiado!' : 'Copiar token'}
          </button>
          <button onClick={onClose}
            style={{ background:'none',border:'1px solid #cdd5df',borderRadius:8,padding:'10px 16px',cursor:'pointer',color:'#526479',fontSize:13 }}>
            Cerrar
          </button>
        </div>
      </div>
    </div>
  );
}

// ── Confirm modal (deactivate / reactivate) ───────────────────────────────

type ConfirmModal = {
  kind: 'facility' | 'gate';
  id: string;
  name: string;
  active: boolean;
};

function ConfirmDeactivateModal({
  confirm, onConfirm, onClose,
}: { confirm: ConfirmModal; onConfirm: () => Promise<void>; onClose: () => void }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const noun = confirm.kind === 'facility' ? 'instalación' : 'portón';
  const action = confirm.active ? 'desactivar' : 'reactivar';

  const run = async () => {
    setBusy(true); setError('');
    try { await onConfirm(); onClose(); }
    catch (err) { setError(err instanceof Error ? err.message : 'Error'); }
    finally { setBusy(false); }
  };

  return (
    <div style={{ position:'fixed',inset:0,background:'rgba(0,0,0,.55)',display:'flex',alignItems:'center',justifyContent:'center',zIndex:200,padding:16 }}>
      <div style={{ background:'white',borderRadius:14,width:'100%',maxWidth:400,boxShadow:'0 20px 60px rgba(0,0,0,.3)',padding:'28px 28px 24px',fontFamily:'Arial,Helvetica,sans-serif' }}>
        <h3 style={{ margin:'0 0 10px',fontSize:17,fontWeight:800,color:'#10263e',textTransform:'capitalize' }}>
          {action.charAt(0).toUpperCase() + action.slice(1)} {noun}
        </h3>
        <p style={{ margin:'0 0 20px',fontSize:14,color:'#4a5568',lineHeight:1.5 }}>
          ¿Confirmas {action} <strong>{confirm.name}</strong>?
          {confirm.active && confirm.kind === 'facility' && ' Esto también afecta a todos sus portones activos.'}
        </p>
        {error && <p style={{ margin:'0 0 12px',color:'#c41e32',fontSize:13 }}>{error}</p>}
        <div style={{ display:'flex',gap:10,justifyContent:'flex-end' }}>
          <button onClick={onClose} disabled={busy}
            style={{ background:'none',border:'1px solid #cdd5df',borderRadius:8,padding:'10px 16px',cursor:'pointer',color:'#526479',fontSize:13 }}>
            Cancelar
          </button>
          <button onClick={run} disabled={busy}
            style={{ background: confirm.active ? '#c41e32' : '#0a7c42',border:0,borderRadius:8,padding:'10px 20px',cursor:'pointer',color:'white',fontWeight:700,fontSize:13,opacity:busy?0.7:1 }}>
            {busy ? 'Procesando...' : confirm.active ? 'Desactivar' : 'Reactivar'}
          </button>
        </div>
      </div>
    </div>
  );
}

// ── GateCard ──────────────────────────────────────────────────────────────

type GateCardProps = {
  gate: AdminGate;
  companyId: string;
  facilityId: string;
  onEdit: (g: AdminGate) => void;
  onToggleActive: (g: AdminGate) => void;
};

function GateCard({ gate, companyId, facilityId, onEdit, onToggleActive }: GateCardProps) {
  const qr = activeQR(gate);
  const { issueQR, revokeQR } = useQRMutations(companyId, facilityId);
  const [issuedToken, setIssuedToken] = useState<string | null>(null);
  const [qrError, setQrError] = useState('');

  const handleIssue = async () => {
    setQrError('');
    try {
      const token = await issueQR.mutateAsync(gate.id);
      setIssuedToken(token);
    } catch (err) {
      setQrError(err instanceof Error ? err.message : 'Error al emitir QR.');
    }
  };

  const handleRevoke = async () => {
    if (!qr) return;
    setQrError('');
    try { await revokeQR.mutateAsync(qr.id); }
    catch (err) { setQrError(err instanceof Error ? err.message : 'Error al revocar QR.'); }
  };

  const state = gate.operational_state as GateOperationalState;

  return (
    <>
      {issuedToken && <QRTokenModal token={issuedToken} onClose={() => setIssuedToken(null)} />}
      <div style={{ background:'white',borderRadius:10,border:'1px solid #dfe6ef',padding:'14px 16px',display:'flex',flexDirection:'column',gap:10 }}>
        {/* Gate header */}
        <div style={{ display:'flex',alignItems:'center',gap:8,flexWrap:'wrap' }}>
          <span style={{ fontWeight:800,fontSize:14,color:'#10263e',fontFamily:'Arial,Helvetica,sans-serif' }}>{gate.code}</span>
          <span style={{ fontSize:13,color:'#526479',fontFamily:'Arial,Helvetica,sans-serif',flex:1 }}>{gate.description}</span>
          <span style={{ fontSize:11,fontWeight:700,color: STATE_COLOR[state] ?? '#526479',background:`${STATE_COLOR[state] ?? '#526479'}18`,borderRadius:12,padding:'3px 9px',fontFamily:'Arial,Helvetica,sans-serif' }}>
            {STATE_LABEL[state] ?? gate.operational_state}
          </span>
          {!gate.active && (
            <span style={{ fontSize:11,fontWeight:700,color:'#8295a8',background:'#f0f4f9',borderRadius:12,padding:'3px 9px',fontFamily:'Arial,Helvetica,sans-serif' }}>Inactivo</span>
          )}
        </div>

        {/* Meta */}
        {(gate.model || gate.serial_number || gate.location_description) && (
          <div style={{ display:'flex',gap:12,flexWrap:'wrap',fontSize:12,color:'#728499',fontFamily:'Arial,Helvetica,sans-serif' }}>
            {gate.model && <span>Modelo: <strong style={{ color:'#4a5568' }}>{gate.model}</strong></span>}
            {gate.serial_number && <span>S/N: <strong style={{ color:'#4a5568' }}>{gate.serial_number}</strong></span>}
            {gate.location_description && <span>Ubicación: <strong style={{ color:'#4a5568' }}>{gate.location_description}</strong></span>}
          </div>
        )}

        {/* QR section */}
        <div style={{ display:'flex',alignItems:'center',gap:8,flexWrap:'wrap',borderTop:'1px solid #f0f4f9',paddingTop:10 }}>
          <QrCode size={14} style={{ color: qr ? '#0a7c42' : '#8295a8',flexShrink:0 }} />
          {qr ? (
            <span style={{ fontSize:12,color:'#0a7c42',fontFamily:'Arial,Helvetica,sans-serif',flex:1 }}>
              QR activo · emitido {fmtDate(qr.issued_at)}
            </span>
          ) : (
            <span style={{ fontSize:12,color:'#8295a8',fontFamily:'Arial,Helvetica,sans-serif',flex:1 }}>Sin QR activo</span>
          )}

          {gate.active && (
            <>
              {qr && (
                <Btn onClick={handleRevoke} disabled={revokeQR.isPending} color="#c41e32">
                  Revocar QR
                </Btn>
              )}
              <Btn onClick={handleIssue} disabled={issueQR.isPending} color="#10263e">
                {issueQR.isPending ? 'Emitiendo...' : qr ? 'Reemitir QR' : 'Emitir QR'}
              </Btn>
            </>
          )}
        </div>

        {qrError && <p style={{ margin:0,color:'#c41e32',fontSize:12,fontFamily:'Arial,Helvetica,sans-serif' }}>{qrError}</p>}

        {/* Gate actions */}
        <div style={{ display:'flex',gap:8,flexWrap:'wrap',borderTop:'1px solid #f0f4f9',paddingTop:10 }}>
          <Btn onClick={() => onEdit(gate)} color="#10263e">Editar</Btn>
          <Btn onClick={() => onToggleActive(gate)} color={gate.active ? '#c41e32' : '#0a7c42'}>
            {gate.active ? 'Desactivar' : 'Reactivar'}
          </Btn>
        </div>
      </div>
    </>
  );
}

// ── Btn helper ────────────────────────────────────────────────────────────

function Btn({ onClick, disabled, color, children }: {
  onClick: () => void; disabled?: boolean; color: string; children: React.ReactNode;
}) {
  return (
    <button onClick={onClick} disabled={disabled}
      style={{ background:'none',border:`1px solid ${color}`,borderRadius:7,padding:'6px 12px',cursor:'pointer',color,fontFamily:'Arial,Helvetica,sans-serif',fontSize:12,fontWeight:600,opacity:disabled?0.6:1 }}>
      {children}
    </button>
  );
}

// ── FacilityDetail ────────────────────────────────────────────────────────

type FacilityDetailProps = {
  facility: RealFacility;
  companyId: string;
  onEdit: () => void;
  onToggleActive: () => void;
  onClose: () => void;
};

function FacilityDetail({ facility, companyId, onEdit, onToggleActive, onClose }: FacilityDetailProps) {
  const gatesQ = useAdminGates(facility.id, companyId);
  const { createGate, updateGate, setGateActive } = useGateMutations(companyId, facility.id);
  const [showGateForm, setShowGateForm] = useState(false);
  const [editingGate, setEditingGate] = useState<AdminGate | null>(null);
  const [confirmGate, setConfirmGate] = useState<ConfirmModal | null>(null);
  const [mutError, setMutError] = useState('');

  const handleGateToggle = (g: AdminGate) => {
    setConfirmGate({ kind:'gate', id:g.id, name:`${g.code} — ${g.description}`, active:g.active });
  };
  const doGateToggle = async () => {
    if (!confirmGate) return;
    await setGateActive.mutateAsync({ id: confirmGate.id, active: !confirmGate.active });
  };

  return (
    <>
      {(showGateForm || editingGate) && (
        <GateForm
          initial={editingGate ?? undefined}
          onClose={() => { setShowGateForm(false); setEditingGate(null); }}
          onSubmit={async (data) => {
            setMutError('');
            if (editingGate) {
              await updateGate.mutateAsync({ ...data, id: editingGate.id, expected_updated_at: editingGate.updated_at });
            } else {
              await createGate.mutateAsync(data);
            }
          }}
        />
      )}
      {confirmGate && (
        <ConfirmDeactivateModal
          confirm={confirmGate}
          onClose={() => setConfirmGate(null)}
          onConfirm={doGateToggle}
        />
      )}

      <div style={{ display:'flex',flexDirection:'column',height:'100%' }}>
        {/* Detail header */}
        <div style={{ padding:'20px 24px 0',flexShrink:0 }}>
          <div style={{ display:'flex',alignItems:'flex-start',gap:8,marginBottom:4 }}>
            <button onClick={onClose} style={{ background:'none',border:0,cursor:'pointer',color:'#8295a8',padding:'2px 0',marginTop:2 }}>
              <X size={16} />
            </button>
            <div style={{ flex:1 }}>
              <h2 style={{ margin:0,fontSize:18,fontWeight:800,color:'#10263e',fontFamily:'Arial,Helvetica,sans-serif' }}>{facility.name}</h2>
              <div style={{ display:'flex',alignItems:'center',gap:8,marginTop:6 }}>
                <span style={{ fontSize:12,fontWeight:700,color: facility.active ? '#0a7c42' : '#8295a8',background: facility.active ? '#e6f5ec' : '#f0f4f9',borderRadius:12,padding:'3px 9px',fontFamily:'Arial,Helvetica,sans-serif' }}>
                  {facility.active ? 'Activo' : 'Inactivo'}
                </span>
                <Btn onClick={onEdit} color="#10263e">Editar</Btn>
                <Btn onClick={onToggleActive} color={facility.active ? '#c41e32' : '#0a7c42'}>
                  {facility.active ? 'Desactivar' : 'Reactivar'}
                </Btn>
              </div>
            </div>
          </div>

          {/* Facility meta */}
          <div style={{ display:'flex',flexDirection:'column',gap:6,marginTop:12,marginBottom:16,fontSize:13,color:'#4a5568',fontFamily:'Arial,Helvetica,sans-serif' }}>
            {facility.address && (
              <div><span style={{ color:'#8295a8',fontWeight:600 }}>Dirección: </span>{facility.address}</div>
            )}
            {facility.location_notes && (
              <div><span style={{ color:'#8295a8',fontWeight:600 }}>Notas: </span>{facility.location_notes}</div>
            )}
            {(facility.contact_name || facility.contact_phone) && (
              <div>
                <span style={{ color:'#8295a8',fontWeight:600 }}>Contacto: </span>
                {[facility.contact_name, facility.contact_phone].filter(Boolean).join(' · ')}
              </div>
            )}
          </div>

          <div style={{ display:'flex',alignItems:'center',justifyContent:'space-between',borderTop:'1px solid #e8edf4',paddingTop:14,paddingBottom:14 }}>
            <span style={{ fontSize:13,fontWeight:700,color:'#10263e',fontFamily:'Arial,Helvetica,sans-serif',display:'flex',alignItems:'center',gap:6 }}>
              <Wrench size={14} /> Portones
            </span>
            {facility.active && (
              <button
                onClick={() => { setShowGateForm(true); setEditingGate(null); }}
                style={{ display:'flex',alignItems:'center',gap:6,background:'#10263e',border:0,borderRadius:8,padding:'8px 14px',cursor:'pointer',color:'white',fontWeight:700,fontFamily:'Arial,Helvetica,sans-serif',fontSize:12 }}>
                <Plus size={13} /> Nuevo portón
              </button>
            )}
          </div>
        </div>

        {/* Gates list */}
        <div style={{ flex:1,overflow:'auto',padding:'0 24px 24px' }}>
          {mutError && <p style={{ margin:'0 0 12px',color:'#c41e32',fontSize:13,fontFamily:'Arial,Helvetica,sans-serif' }}>{mutError}</p>}
          {gatesQ.isLoading && <p style={{ color:'#8295a8',fontFamily:'Arial,Helvetica,sans-serif',fontSize:13 }}>Cargando portones…</p>}
          {gatesQ.error && <p style={{ color:'#c41e32',fontFamily:'Arial,Helvetica,sans-serif',fontSize:13 }}>Error: {gatesQ.error.message}</p>}
          {gatesQ.data && gatesQ.data.length === 0 && (
            <p style={{ color:'#8295a8',fontFamily:'Arial,Helvetica,sans-serif',fontSize:13 }}>Sin portones registrados.</p>
          )}
          <div style={{ display:'flex',flexDirection:'column',gap:12 }}>
            {gatesQ.data?.map(g => (
              <GateCard
                key={g.id}
                gate={g}
                companyId={companyId}
                facilityId={facility.id}
                onEdit={gate => { setEditingGate(gate); setShowGateForm(false); }}
                onToggleActive={handleGateToggle}
              />
            ))}
          </div>
        </div>
      </div>
    </>
  );
}

// ── FacilityManager (main export) ─────────────────────────────────────────

type Props = { companies: Company[] };

export default function FacilityManager({ companies }: Props) {
  const [companyId, setCompanyId] = useState('');
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [showFacForm, setShowFacForm] = useState(false);
  const [editingFac, setEditingFac] = useState<RealFacility | null>(null);
  const [confirmFac, setConfirmFac] = useState<ConfirmModal | null>(null);
  const [search, setSearch] = useState('');
  const [mutError, setMutError] = useState('');

  const facilitiesQ = useFacilities(companyId || undefined);
  const { createFacility, updateFacility, setFacilityActive } = useFacilityMutations(companyId || undefined);

  const facilities = facilitiesQ.data ?? [];
  const filtered = facilities.filter(f => f.name.toLowerCase().includes(search.toLowerCase()));
  const selected = filtered.find(f => f.id === selectedId) ?? null;

  const doFacilityToggle = async () => {
    if (!confirmFac) return;
    await setFacilityActive.mutateAsync({ id: confirmFac.id, active: !confirmFac.active });
    if (confirmFac.active && confirmFac.id === selectedId) setSelectedId(null);
  };

  return (
    <>
      {/* Modals */}
      {(showFacForm || editingFac) && (
        <FacilityForm
          initial={editingFac ?? undefined}
          onClose={() => { setShowFacForm(false); setEditingFac(null); }}
          onSubmit={async (data) => {
            setMutError('');
            if (editingFac) {
              await updateFacility.mutateAsync({ ...data, id: editingFac.id, expected_updated_at: editingFac.updated_at });
            } else {
              await createFacility.mutateAsync(data);
            }
          }}
        />
      )}
      {confirmFac && (
        <ConfirmDeactivateModal
          confirm={confirmFac}
          onClose={() => setConfirmFac(null)}
          onConfirm={doFacilityToggle}
        />
      )}

      <div style={{ display:'flex', flexDirection:'column', height:'100%', background:'#f3f5f8', fontFamily:'Arial,Helvetica,sans-serif' }}>
        {/* Toolbar */}
        <div style={{ padding:'16px 20px 0', flexShrink:0 }}>
          <div style={{ display:'flex', alignItems:'center', gap:12, flexWrap:'wrap' }}>
            {/* Company selector */}
            <div style={{ display:'flex', alignItems:'center', gap:8 }}>
              <Building size={15} style={{ color:'#8295a8' }} />
              <select
                value={companyId}
                onChange={e => { setCompanyId(e.target.value); setSelectedId(null); setSearch(''); }}
                style={{ border:'1px solid #dfe6ef', borderRadius:8, padding:'8px 12px', fontSize:13, fontFamily:'Arial,Helvetica,sans-serif', color:'#10263e', background:'white', cursor:'pointer', minWidth:220 }}
              >
                <option value="">— Seleccioná una empresa —</option>
                {companies.map(c => (
                  <option key={c.id} value={c.id}>{c.name}</option>
                ))}
              </select>
            </div>

            {/* Search */}
            {companyId && (
              <input
                value={search}
                onChange={e => setSearch(e.target.value)}
                placeholder="Buscar instalación…"
                style={{ border:'1px solid #dfe6ef', borderRadius:8, padding:'8px 12px', fontSize:13, fontFamily:'Arial,Helvetica,sans-serif', color:'#10263e', background:'white', flex:1, minWidth:160 }}
              />
            )}

            {/* New facility */}
            {companyId && (
              <button
                onClick={() => { setShowFacForm(true); setEditingFac(null); }}
                style={{ display:'flex', alignItems:'center', gap:6, background:'#10263e', border:0, borderRadius:8, padding:'9px 16px', cursor:'pointer', color:'white', fontWeight:700, fontFamily:'Arial,Helvetica,sans-serif', fontSize:13, flexShrink:0 }}>
                <Plus size={14} /> Nueva instalación
              </button>
            )}
          </div>

          {mutError && <p style={{ margin:'8px 0 0',color:'#c41e32',fontSize:13 }}>{mutError}</p>}
        </div>

        {/* Body */}
        {!companyId ? (
          <div style={{ flex:1, display:'flex', alignItems:'center', justifyContent:'center' }}>
            <p style={{ color:'#8295a8', fontSize:14 }}>Seleccioná una empresa para ver sus instalaciones.</p>
          </div>
        ) : (
          <div style={{ flex:1, overflow:'hidden', display:'flex', margin:'16px 20px', gap:16 }}>
            {/* Facility list */}
            <div style={{ flex: selected ? '0 0 340px' : 1, overflow:'auto', background:'white', borderRadius:12, border:'1px solid #e0e6ef', display:'flex', flexDirection:'column' }}>
              {/* List header */}
              <div style={{ padding:'14px 16px', borderBottom:'1px solid #e8edf4', display:'flex', alignItems:'center', justifyContent:'space-between', flexShrink:0 }}>
                <span style={{ fontSize:13, fontWeight:700, color:'#10263e' }}>
                  Instalaciones {facilities.length > 0 && `(${facilities.length})`}
                </span>
              </div>

              {facilitiesQ.isLoading && <p style={{ padding:'16px', color:'#8295a8', fontSize:13 }}>Cargando…</p>}
              {facilitiesQ.error && <p style={{ padding:'16px', color:'#c41e32', fontSize:13 }}>Error: {facilitiesQ.error.message}</p>}
              {!facilitiesQ.isLoading && filtered.length === 0 && (
                <p style={{ padding:'16px', color:'#8295a8', fontSize:13 }}>
                  {search ? 'Sin resultados.' : 'Sin instalaciones. Creá la primera.'}
                </p>
              )}

              <div style={{ overflow:'auto', flex:1 }}>
                {filtered.map(f => (
                  <button
                    key={f.id}
                    onClick={() => setSelectedId(f.id === selectedId ? null : f.id)}
                    style={{
                      width:'100%', background: f.id === selectedId ? '#f0f4fc' : 'none',
                      border:'none', borderBottom:'1px solid #f0f4f9', padding:'14px 16px',
                      cursor:'pointer', display:'flex', alignItems:'center', gap:10, textAlign:'left',
                    }}
                  >
                    <div style={{ flex:1 }}>
                      <div style={{ display:'flex', alignItems:'center', gap:8 }}>
                        <span style={{ fontWeight:700, fontSize:14, color:'#10263e', fontFamily:'Arial,Helvetica,sans-serif' }}>{f.name}</span>
                        {!f.active && <span style={{ fontSize:11, color:'#8295a8', background:'#f0f4f9', borderRadius:10, padding:'2px 7px' }}>Inactiva</span>}
                      </div>
                      {f.address && <div style={{ fontSize:12, color:'#8295a8', marginTop:3, fontFamily:'Arial,Helvetica,sans-serif' }}>{f.address}</div>}
                    </div>
                    <ChevronRight size={15} style={{ color:'#8295a8', flexShrink:0 }} />
                  </button>
                ))}
              </div>
            </div>

            {/* Detail panel */}
            {selected && (
              <div style={{ flex:1, overflow:'hidden', background:'white', borderRadius:12, border:'1px solid #e0e6ef', display:'flex', flexDirection:'column' }}>
                <FacilityDetail
                  facility={selected}
                  companyId={companyId}
                  onEdit={() => { setEditingFac(selected); setShowFacForm(false); }}
                  onToggleActive={() => setConfirmFac({ kind:'facility', id:selected.id, name:selected.name, active:selected.active })}
                  onClose={() => setSelectedId(null)}
                />
              </div>
            )}
          </div>
        )}
      </div>
    </>
  );
}
