import { useState } from 'react';
import { Building, Mail, MapPin, Phone, Plus, User, X } from 'lucide-react';
import type { Company } from './AdminControl';
import type { CompanyContact, ContactCategory, RealFacility } from './lib/types';
import {
  useCompanyContacts, useCompanyContactMutations, useFacilities,
  type ContactFormInput,
} from './hooks/useRealData';

// ── constants ─────────────────────────────────────────────────────────────

const CATEGORY_LABEL: Record<ContactCategory, string> = {
  commercial:     'Comercial',
  administrative: 'Administrativo',
  technical:      'Técnico',
  emergency:      'Emergencias',
  other:          'Otro',
};

const CATEGORY_COLOR: Record<ContactCategory, string> = {
  commercial:     '#0070c0',
  administrative: '#10263e',
  technical:      '#0a7c42',
  emergency:      '#c41e32',
  other:          '#8295a8',
};

// ── input styles ──────────────────────────────────────────────────────────

const inp: React.CSSProperties = {
  border: '1px solid #dfe6ef', borderRadius: 8, padding: '10px 12px', fontSize: 14,
  fontFamily: 'Arial,Helvetica,sans-serif', color: '#1b2838', background: 'white',
  width: '100%', boxSizing: 'border-box',
};

function Field({ label, children, required }: { label: string; children: React.ReactNode; required?: boolean }) {
  return (
    <label style={{ display: 'flex', flexDirection: 'column', gap: 5, fontFamily: 'Arial,Helvetica,sans-serif' }}>
      <span style={{ fontSize: 11, fontWeight: 800, color: '#728499', letterSpacing: '0.6px', textTransform: 'uppercase' }}>
        {label}{required && <span style={{ color: '#c41e32', marginLeft: 2 }}>*</span>}
      </span>
      {children}
    </label>
  );
}

function Btn({ onClick, disabled, color, children }: {
  onClick: () => void; disabled?: boolean; color: string; children: React.ReactNode;
}) {
  return (
    <button onClick={onClick} disabled={disabled}
      style={{ background: 'none', border: `1px solid ${color}`, borderRadius: 7, padding: '6px 12px', cursor: 'pointer', color, fontFamily: 'Arial,Helvetica,sans-serif', fontSize: 12, fontWeight: 600, opacity: disabled ? 0.6 : 1 }}>
      {children}
    </button>
  );
}

// ── ContactForm modal ─────────────────────────────────────────────────────

type ContactFormProps = {
  initial?: CompanyContact;
  facilities: RealFacility[];
  onSubmit: (data: ContactFormInput) => Promise<void>;
  onClose: () => void;
};

const emptyForm: ContactFormInput = {
  first_name: '', last_name: '', category: 'administrative',
  email: '', phone: '', notes: '', facility_id: null,
};

function ContactForm({ initial, facilities, onSubmit, onClose }: ContactFormProps) {
  const [form, setForm] = useState<ContactFormInput>({
    first_name:  initial?.first_name  ?? '',
    last_name:   initial?.last_name   ?? '',
    category:    initial?.category    ?? 'administrative',
    email:       initial?.email       ?? '',
    phone:       initial?.phone       ?? '',
    notes:       initial?.notes       ?? '',
    facility_id: initial?.facility_id ?? null,
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (form.first_name.trim().length < 2) { setError('El nombre debe tener al menos 2 caracteres.'); return; }
    if (form.last_name.trim().length < 2)  { setError('El apellido debe tener al menos 2 caracteres.'); return; }
    setBusy(true); setError('');
    try { await onSubmit(form); onClose(); }
    catch (err) {
      const msg = err instanceof Error ? err.message : '';
      setError(msg.includes('concurrent edit conflict')
        ? 'Este contacto fue editado por otro usuario. Cerrá el formulario y volvé a abrirlo.'
        : msg || 'Error al guardar contacto.');
    } finally { setBusy(false); }
  };

  return (
    <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,.55)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 200, padding: 16 }}>
      <div style={{ background: 'white', borderRadius: 14, width: '100%', maxWidth: 480, maxHeight: '90vh', display: 'flex', flexDirection: 'column', boxShadow: '0 20px 60px rgba(0,0,0,.3)' }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '20px 24px 0', flexShrink: 0 }}>
          <h2 style={{ margin: 0, fontSize: 19, fontWeight: 800, color: '#10263e', fontFamily: 'Arial,Helvetica,sans-serif' }}>
            {initial ? 'Editar contacto' : 'Nuevo contacto'}
          </h2>
          <button onClick={onClose} disabled={busy} style={{ background: 'none', border: 0, cursor: 'pointer', color: '#8295a8', padding: 4, borderRadius: 6 }}>
            <X size={20} />
          </button>
        </div>

        <form onSubmit={submit} style={{ overflow: 'auto', padding: '20px 24px 24px', display: 'flex', flexDirection: 'column', gap: 14 }}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
            <Field label="Nombre *" required>
              <input
                value={form.first_name}
                onChange={e => setForm(prev => ({ ...prev, first_name: e.target.value }))}
                placeholder="María" style={inp} required minLength={2}
              />
            </Field>
            <Field label="Apellido *" required>
              <input
                value={form.last_name}
                onChange={e => setForm(prev => ({ ...prev, last_name: e.target.value }))}
                placeholder="González" style={inp} required minLength={2}
              />
            </Field>
          </div>

          <Field label="Categoría">
            <select
              value={form.category}
              onChange={e => setForm(prev => ({ ...prev, category: e.target.value as ContactCategory }))}
              style={{ ...inp, cursor: 'pointer' }}
            >
              <option value="commercial">Comercial</option>
              <option value="administrative">Administrativo</option>
              <option value="technical">Técnico</option>
              <option value="emergency">Emergencias</option>
              <option value="other">Otro</option>
            </select>
          </Field>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
            <Field label="Email">
              <input
                value={form.email}
                onChange={e => setForm(prev => ({ ...prev, email: e.target.value }))}
                placeholder="maria@empresa.com" style={inp} type="email"
              />
            </Field>
            <Field label="Teléfono">
              <input
                value={form.phone}
                onChange={e => setForm(prev => ({ ...prev, phone: e.target.value }))}
                placeholder="+54-11-5555-1234" style={inp}
              />
            </Field>
          </div>

          {facilities.length > 0 && (
            <Field label="Instalación (opcional)">
              <select
                value={form.facility_id ?? ''}
                onChange={e => setForm(prev => ({ ...prev, facility_id: e.target.value || null }))}
                style={{ ...inp, cursor: 'pointer' }}
              >
                <option value="">— Empresa en general —</option>
                {facilities.filter(f => f.active).map(f => (
                  <option key={f.id} value={f.id}>{f.name}</option>
                ))}
                {/* Inactive facility linked to this contact — show as disabled so the
                    controlled value always matches a visible option and the user knows
                    the current state. Without this, the browser would show the first
                    active option while React retains the stale facility_id. */}
                {form.facility_id && !facilities.some(f => f.id === form.facility_id && f.active) &&
                  facilities.filter(f => f.id === form.facility_id).map(f => (
                    <option key={f.id} value={f.id} disabled>{f.name} (Inactiva)</option>
                  ))
                }
              </select>
              {form.facility_id && !facilities.some(f => f.id === form.facility_id && f.active) && (
                <span style={{ fontSize: 11, color: '#c41e32', fontFamily: 'Arial,Helvetica,sans-serif' }}>
                  Esta instalación está inactiva. Considerá cambiarla o desvincularla.
                </span>
              )}
            </Field>
          )}

          <Field label="Notas">
            <textarea
              value={form.notes}
              onChange={e => setForm(prev => ({ ...prev, notes: e.target.value }))}
              placeholder="Información adicional..."
              rows={2} style={{ ...inp, resize: 'vertical', minHeight: 60 }}
            />
          </Field>

          {error && <p style={{ margin: 0, color: '#c41e32', fontSize: 13, fontFamily: 'Arial,Helvetica,sans-serif' }}>{error}</p>}

          <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end', paddingTop: 4 }}>
            <button type="button" onClick={() => { setForm(emptyForm); setError(''); }} disabled={busy}
              style={{ background: 'none', border: '1px solid #cdd5df', borderRadius: 8, padding: '10px 16px', cursor: 'pointer', color: '#526479', fontFamily: 'Arial,Helvetica,sans-serif', fontSize: 13 }}>
              Limpiar
            </button>
            <button type="button" onClick={onClose} disabled={busy}
              style={{ background: 'none', border: '1px solid #cdd5df', borderRadius: 8, padding: '10px 16px', cursor: 'pointer', color: '#526479', fontFamily: 'Arial,Helvetica,sans-serif', fontSize: 13 }}>
              Cancelar
            </button>
            <button type="submit" disabled={busy}
              style={{ background: '#10263e', border: 0, borderRadius: 8, padding: '10px 20px', cursor: 'pointer', color: 'white', fontWeight: 700, fontFamily: 'Arial,Helvetica,sans-serif', fontSize: 13, opacity: busy ? 0.7 : 1 }}>
              {busy ? 'Guardando...' : initial ? 'Guardar cambios' : 'Crear contacto'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

// ── ConfirmContactModal ───────────────────────────────────────────────────

function ConfirmContactModal({
  contact, action, onConfirm, onClose,
}: { contact: CompanyContact; action: 'deactivate' | 'activate'; onConfirm: () => Promise<void>; onClose: () => void }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const run = async () => {
    setBusy(true); setError('');
    try { await onConfirm(); onClose(); }
    catch (err) { setError(err instanceof Error ? err.message : 'Error'); }
    finally { setBusy(false); }
  };

  return (
    <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,.55)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 200, padding: 16 }}>
      <div style={{ background: 'white', borderRadius: 14, width: '100%', maxWidth: 400, boxShadow: '0 20px 60px rgba(0,0,0,.3)', padding: '28px 28px 24px', fontFamily: 'Arial,Helvetica,sans-serif' }}>
        <h3 style={{ margin: '0 0 10px', fontSize: 17, fontWeight: 800, color: '#10263e' }}>
          {action === 'deactivate' ? 'Desactivar contacto' : 'Reactivar contacto'}
        </h3>
        <p style={{ margin: '0 0 20px', fontSize: 14, color: '#4a5568', lineHeight: 1.5 }}>
          ¿Confirmas {action === 'deactivate' ? 'desactivar' : 'reactivar'} a{' '}
          <strong>{contact.first_name} {contact.last_name}</strong>?
        </p>
        {error && <p style={{ margin: '0 0 12px', color: '#c41e32', fontSize: 13 }}>{error}</p>}
        <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end' }}>
          <button onClick={onClose} disabled={busy}
            style={{ background: 'none', border: '1px solid #cdd5df', borderRadius: 8, padding: '10px 16px', cursor: 'pointer', color: '#526479', fontSize: 13 }}>
            Cancelar
          </button>
          <button onClick={run} disabled={busy}
            style={{ background: action === 'deactivate' ? '#c41e32' : '#0a7c42', border: 0, borderRadius: 8, padding: '10px 20px', cursor: 'pointer', color: 'white', fontWeight: 700, fontSize: 13, opacity: busy ? 0.7 : 1 }}>
            {busy ? 'Procesando...' : action === 'deactivate' ? 'Desactivar' : 'Reactivar'}
          </button>
        </div>
      </div>
    </div>
  );
}

// ── ContactCard ───────────────────────────────────────────────────────────

type ContactCardProps = {
  contact: CompanyContact;
  facilityName: string | null;
  onEdit: (c: CompanyContact) => void;
  onToggleActive: (c: CompanyContact) => void;
};

function ContactCard({ contact, facilityName, onEdit, onToggleActive }: ContactCardProps) {
  const cat = contact.category;
  return (
    <div style={{ background: 'white', borderRadius: 10, border: '1px solid #dfe6ef', padding: '14px 16px', display: 'flex', flexDirection: 'column', gap: 10 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
        <User size={15} style={{ color: '#8295a8', flexShrink: 0 }} />
        <span style={{ fontWeight: 800, fontSize: 14, color: '#10263e', fontFamily: 'Arial,Helvetica,sans-serif', flex: 1 }}>
          {contact.first_name} {contact.last_name}
        </span>
        <span style={{ fontSize: 11, fontWeight: 700, color: CATEGORY_COLOR[cat], background: `${CATEGORY_COLOR[cat]}18`, borderRadius: 12, padding: '3px 9px', fontFamily: 'Arial,Helvetica,sans-serif' }}>
          {CATEGORY_LABEL[cat]}
        </span>
        {!contact.active && (
          <span style={{ fontSize: 11, fontWeight: 700, color: '#8295a8', background: '#f0f4f9', borderRadius: 12, padding: '3px 9px', fontFamily: 'Arial,Helvetica,sans-serif' }}>Inactivo</span>
        )}
      </div>

      {(contact.email || contact.phone || facilityName) && (
        <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', fontSize: 12, color: '#728499', fontFamily: 'Arial,Helvetica,sans-serif', alignItems: 'center' }}>
          {contact.email && (
            <span style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
              <Mail size={11} /> <strong style={{ color: '#4a5568' }}>{contact.email}</strong>
            </span>
          )}
          {contact.phone && (
            <span style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
              <Phone size={11} /> <strong style={{ color: '#4a5568' }}>{contact.phone}</strong>
            </span>
          )}
          {facilityName && (
            <span style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
              <MapPin size={11} /> <strong style={{ color: '#4a5568' }}>{facilityName}</strong>
            </span>
          )}
        </div>
      )}

      {contact.notes && (
        <p style={{ margin: 0, fontSize: 12, color: '#728499', fontFamily: 'Arial,Helvetica,sans-serif', lineHeight: 1.4 }}>
          {contact.notes}
        </p>
      )}

      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', borderTop: '1px solid #f0f4f9', paddingTop: 10 }}>
        <Btn onClick={() => onEdit(contact)} color="#10263e">Editar</Btn>
        <Btn onClick={() => onToggleActive(contact)} color={contact.active ? '#c41e32' : '#0a7c42'}>
          {contact.active ? 'Desactivar' : 'Reactivar'}
        </Btn>
      </div>
    </div>
  );
}

// ── ContactManager (main export) ──────────────────────────────────────────

type Props = { companies: Company[] };

export default function ContactManager({ companies }: Props) {
  const [companyId, setCompanyId] = useState('');
  const [search, setSearch] = useState('');
  const [categoryFilter, setCategoryFilter] = useState<ContactCategory | 'all'>('all');
  const [showForm, setShowForm] = useState(false);
  const [editingContact, setEditingContact] = useState<CompanyContact | null>(null);
  const [confirmOp, setConfirmOp] = useState<{ contact: CompanyContact; action: 'deactivate' | 'activate' } | null>(null);

  const contactsQ = useCompanyContacts(companyId || undefined);
  const facilitiesQ = useFacilities(companyId || undefined);
  const { createContact, updateContact, setContactActive } = useCompanyContactMutations(companyId || undefined);

  const contacts = contactsQ.data ?? [];
  const facilities = facilitiesQ.data ?? [];
  const facilityMap = Object.fromEntries(facilities.map(f => [f.id, f.name]));

  const filtered = contacts.filter(c => {
    if (categoryFilter !== 'all' && c.category !== categoryFilter) return false;
    const q = search.toLowerCase();
    return !q || `${c.first_name} ${c.last_name} ${c.email ?? ''}`.toLowerCase().includes(q);
  });

  const doToggleActive = async () => {
    if (!confirmOp) return;
    const { contact, action } = confirmOp;
    const ts = contact.updated_at ?? contact.created_at;
    if (!ts) throw new Error('No se pudo obtener la marca de tiempo del contacto.');
    await setContactActive.mutateAsync({
      id: contact.id,
      active: action === 'activate',
      expected_updated_at: ts,
    });
  };

  return (
    <>
      {(showForm || editingContact) && (
        <ContactForm
          initial={editingContact ?? undefined}
          facilities={facilities}
          onClose={() => { setShowForm(false); setEditingContact(null); }}
          onSubmit={async (data) => {
            if (editingContact) {
              await updateContact.mutateAsync({
                ...data,
                id: editingContact.id,
                expected_updated_at: editingContact.updated_at,
              });
            } else {
              await createContact.mutateAsync(data);
            }
          }}
        />
      )}
      {confirmOp && (
        <ConfirmContactModal
          contact={confirmOp.contact}
          action={confirmOp.action}
          onClose={() => setConfirmOp(null)}
          onConfirm={doToggleActive}
        />
      )}

      <div style={{ display: 'flex', flexDirection: 'column', height: '100%', background: '#f3f5f8', fontFamily: 'Arial,Helvetica,sans-serif' }}>
        {/* Toolbar */}
        <div style={{ padding: '16px 20px 0', flexShrink: 0 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <Building size={15} style={{ color: '#8295a8' }} />
              <select
                value={companyId}
                onChange={e => { setCompanyId(e.target.value); setSearch(''); setCategoryFilter('all'); }}
                style={{ border: '1px solid #dfe6ef', borderRadius: 8, padding: '8px 12px', fontSize: 13, fontFamily: 'Arial,Helvetica,sans-serif', color: '#10263e', background: 'white', cursor: 'pointer', minWidth: 220 }}
              >
                <option value="">— Seleccioná una empresa —</option>
                {companies.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}
              </select>
            </div>

            {companyId && (
              <>
                <input
                  value={search}
                  onChange={e => setSearch(e.target.value)}
                  placeholder="Buscar contacto…"
                  style={{ border: '1px solid #dfe6ef', borderRadius: 8, padding: '8px 12px', fontSize: 13, fontFamily: 'Arial,Helvetica,sans-serif', color: '#10263e', background: 'white', flex: 1, minWidth: 160 }}
                />
                <select
                  value={categoryFilter}
                  onChange={e => setCategoryFilter(e.target.value as ContactCategory | 'all')}
                  style={{ border: '1px solid #dfe6ef', borderRadius: 8, padding: '8px 12px', fontSize: 13, fontFamily: 'Arial,Helvetica,sans-serif', color: '#10263e', background: 'white', cursor: 'pointer' }}
                >
                  <option value="all">Todas las categorías</option>
                  <option value="commercial">Comercial</option>
                  <option value="administrative">Administrativo</option>
                  <option value="technical">Técnico</option>
                  <option value="emergency">Emergencias</option>
                  <option value="other">Otro</option>
                </select>
                <button
                  onClick={() => { setShowForm(true); setEditingContact(null); }}
                  style={{ display: 'flex', alignItems: 'center', gap: 6, background: '#10263e', border: 0, borderRadius: 8, padding: '9px 16px', cursor: 'pointer', color: 'white', fontWeight: 700, fontFamily: 'Arial,Helvetica,sans-serif', fontSize: 13, flexShrink: 0 }}>
                  <Plus size={14} /> Nuevo contacto
                </button>
              </>
            )}
          </div>
        </div>

        {/* Body */}
        {!companyId ? (
          <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            <p style={{ color: '#8295a8', fontSize: 14 }}>Seleccioná una empresa para ver sus contactos.</p>
          </div>
        ) : (
          <div style={{ flex: 1, overflow: 'auto', margin: '16px 20px' }}>
            <div style={{ background: 'white', borderRadius: 12, border: '1px solid #e0e6ef' }}>
              <div style={{ padding: '14px 16px', borderBottom: '1px solid #e8edf4' }}>
                <span style={{ fontSize: 13, fontWeight: 700, color: '#10263e' }}>
                  Contactos {contacts.length > 0 && `(${contacts.length})`}
                </span>
              </div>

              {contactsQ.isLoading && <p style={{ padding: 16, color: '#8295a8', fontSize: 13 }}>Cargando…</p>}
              {contactsQ.error && <p style={{ padding: 16, color: '#c41e32', fontSize: 13 }}>Error: {contactsQ.error.message}</p>}
              {!contactsQ.isLoading && filtered.length === 0 && (
                <p style={{ padding: 16, color: '#8295a8', fontSize: 13 }}>
                  {search || categoryFilter !== 'all' ? 'Sin resultados.' : 'Sin contactos. Creá el primero.'}
                </p>
              )}

              {filtered.length > 0 && (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 12, padding: 16 }}>
                  {filtered.map(c => (
                    <ContactCard
                      key={c.id}
                      contact={c}
                      facilityName={c.facility_id ? (facilityMap[c.facility_id] ?? null) : null}
                      onEdit={contact => { setEditingContact(contact); setShowForm(false); }}
                      onToggleActive={contact => setConfirmOp({ contact, action: contact.active ? 'deactivate' : 'activate' })}
                    />
                  ))}
                </div>
              )}
            </div>
          </div>
        )}
      </div>
    </>
  );
}
