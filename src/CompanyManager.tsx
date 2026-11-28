import { useMemo, useState } from 'react';
import { Building2, ChevronRight, Mail, MapPin, PencilLine, Phone, Plus, PowerOff, Search, ToggleRight, User, X } from 'lucide-react';
import type { Company } from './AdminControl';
import type { CompanyFormInput } from './hooks/useRealData';
import { useAdminCompanyMutations } from './hooks/useRealData';
import CompanyForm from './CompanyForm';

type Props = {
  companies: Company[];
  isLoading?: boolean;
  error?: Error | null;
};

const fmtDate = (iso?: string | null) =>
  iso ? new Date(iso).toLocaleDateString('es-AR', { day: '2-digit', month: '2-digit', year: 'numeric' }) : '—';

export default function CompanyManager({ companies, isLoading, error }: Props) {
  const [query, setQuery] = useState('');
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [form, setForm] = useState<{ open: boolean; editing?: Company }>({ open: false });
  const [confirmDeactivate, setConfirmDeactivate] = useState<Company | null>(null);
  const [mutError, setMutError] = useState('');
  const { createCompany, updateCompany, setCompanyActive } = useAdminCompanyMutations();

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return companies;
    return companies.filter(c =>
      c.name.toLowerCase().includes(q) ||
      (c.legal_name?.toLowerCase().includes(q)) ||
      (c.tax_id?.toLowerCase().includes(q))
    );
  }, [companies, query]);

  // Keep selectedCompany in sync with fresh data after mutations
  const selectedCompany = useMemo(
    () => companies.find(c => c.id === selectedId) ?? null,
    [companies, selectedId]
  );

  const handleCreate = async (data: CompanyFormInput) => {
    setMutError('');
    await createCompany.mutateAsync(data);
  };

  const handleUpdate = async (data: CompanyFormInput) => {
    if (!form.editing) return;
    setMutError('');
    await updateCompany.mutateAsync({
      ...data,
      id: form.editing.id,
      expected_updated_at: form.editing.updated_at ?? null,
    });
  };

  const handleToggleActive = async (company: Company, active: boolean) => {
    setMutError('');
    try {
      await setCompanyActive.mutateAsync({ id: company.id, active });
    } catch (e) {
      setMutError(e instanceof Error ? e.message : 'Error al actualizar estado.');
    }
    setConfirmDeactivate(null);
  };

  const isMutating = createCompany.isPending || updateCompany.isPending || setCompanyActive.isPending;
  // Panel only shows when the selected company is visible in the current filtered results.
  // If the user types a search that excludes the selected company, the panel closes and
  // the full 6-column view is restored, avoiding the layout desync.
  const hasPanel = !!selectedCompany && filtered.some(c => c.id === selectedId);

  return (
    <div className="company-management" data-detail={hasPanel}>
      {/* Page heading */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap', marginBottom: 20 }}>
        <div>
          <small style={{ fontSize: 10, letterSpacing: '1.4px', color: 'var(--cm-muted)', fontWeight: 800 }}>EMPRESAS CLIENTES</small>
          <h1 className="company-management-title">Gestión de empresas</h1>
        </div>
        <button onClick={() => setForm({ open: true })} disabled={isMutating}
          style={{ display: 'flex', alignItems: 'center', gap: 8, background: 'var(--company-primary)', border: 0, borderRadius: 9, padding: '11px 18px', cursor: 'pointer', color: 'var(--company-on-primary)', fontWeight: 700, fontSize: 13 }}>
          <Plus size={16} /> Nueva empresa
        </button>
      </div>

      {/* Search */}
      <div style={{ position: 'relative', marginBottom: 18 }}>
        <Search size={16} style={{ position: 'absolute', left: 14, top: '50%', transform: 'translateY(-50%)', color: 'var(--cm-muted)', pointerEvents: 'none' }} />
        <input
          value={query} onChange={e => setQuery(e.target.value)}
          aria-label="Buscar empresas"
          placeholder="Buscar por nombre, razón social o CUIT…"
          style={{ width: '100%', boxSizing: 'border-box', border: '1px solid var(--cm-line)', borderRadius: 9, padding: '11px 14px 11px 42px', fontSize: 14, color: 'var(--cm-text)', background: 'var(--cm-surface)' }}
        />
      </div>

      {/* Error */}
      {(mutError || error) && (
        <p style={{ background: 'var(--company-error-surface)', border: '1px solid var(--cm-critical)', borderRadius: 8, padding: '10px 14px', color: 'var(--cm-critical)', fontSize: 13, marginBottom: 16 }}>
          {mutError || error?.message}
        </p>
      )}

      {/* Split layout: table + optional detail panel */}
      <div className="company-management-layout">
        {/* Table */}
        <div className="company-management-results">
          <div className="company-management-table">
            {isLoading ? (
              <p style={{ padding: '40px 24px', color: 'var(--cm-muted)', textAlign: 'center' }}>Cargando empresas…</p>
            ) : filtered.length === 0 ? (
              <div style={{ padding: '52px 24px', textAlign: 'center' }}>
                <Building2 size={36} style={{ color: 'var(--cm-muted)', marginBottom: 12 }} />
                <p style={{ color: 'var(--cm-muted)', margin: 0, fontSize: 14 }}>
                  {query ? 'Ninguna empresa coincide con la búsqueda.' : 'Todavía no hay empresas registradas. Creá la primera.'}
                </p>
              </div>
            ) : (
              <table style={{ width: '100%', borderCollapse: 'collapse' }}>
                <thead>
                  <tr style={{ background: 'var(--company-subtle)', borderBottom: '1px solid var(--cm-line)' }}>
                    {(hasPanel
                      ? ['Empresa', 'Estado', '']
                      : ['Nombre comercial', 'Razón social', 'CUIT', 'Contacto', 'Estado', '']
                    ).map((h, i) => (
                      <th key={i} style={{ padding: '11px 16px', textAlign: 'left', fontSize: 11, fontWeight: 800, color: 'var(--cm-muted)', letterSpacing: '0.6px', textTransform: 'uppercase', whiteSpace: 'nowrap' }}>{h}</th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {filtered.map((c, idx) => (
                    hasPanel
                      ? <CompanyRowCompact key={c.id} company={c} odd={idx % 2 === 1}
                          selected={c.id === selectedId}
                          onClick={() => setSelectedId(c.id === selectedId ? null : c.id)}
                        />
                      : <CompanyRow key={c.id} company={c} odd={idx % 2 === 1}
                          onEdit={() => setForm({ open: true, editing: c })}
                          onToggle={() => c.active !== false ? setConfirmDeactivate(c) : handleToggleActive(c, true)}
                          onSelect={() => setSelectedId(c.id)}
                          disabled={isMutating}
                        />
                  ))}
                </tbody>
              </table>
            )}
          </div>
          <p style={{ color: 'var(--cm-muted)', fontSize: 11, marginTop: 12 }}>
            {filtered.length} empresa{filtered.length !== 1 ? 's' : ''} · Panel de administrador global
          </p>
        </div>

        {/* Detail panel */}
        {hasPanel && selectedCompany && (
          <div className="company-management-detail">
            <CompanyDetail
              company={selectedCompany}
              onEdit={() => setForm({ open: true, editing: selectedCompany })}
              onToggle={() => selectedCompany.active !== false
                ? setConfirmDeactivate(selectedCompany)
                : handleToggleActive(selectedCompany, true)}
              onClose={() => setSelectedId(null)}
              disabled={isMutating}
            />
          </div>
        )}
      </div>

      {/* Deactivate confirmation */}
      {confirmDeactivate && (
        <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,.5)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 200, padding: 16 }}>
          <div style={{ background: 'var(--cm-surface)', borderRadius: 12, padding: '28px 28px 24px', maxWidth: 380, width: '100%', boxShadow: '0 20px 60px rgba(0,0,0,.3)' }}>
            <h3 style={{ margin: '0 0 10px', color: 'var(--cm-text)', fontFamily: 'Arial,Helvetica,sans-serif' }}>¿Desactivar empresa?</h3>
            <p style={{ margin: '0 0 20px', color: 'var(--cm-muted)', fontSize: 14, fontFamily: 'Arial,Helvetica,sans-serif' }}>
              <strong>{confirmDeactivate.name}</strong> quedará inactiva. Los usuarios perderán acceso operativo, pero su historial se conserva. Podés reactivarla en cualquier momento.
            </p>
            <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end' }}>
              <button onClick={() => setConfirmDeactivate(null)}
                style={{ background: 'none', border: '1px solid var(--cm-line)', borderRadius: 8, padding: '10px 16px', cursor: 'pointer', color: 'var(--cm-muted)', fontFamily: 'Arial,Helvetica,sans-serif', fontSize: 13 }}>
                Cancelar
              </button>
              <button onClick={() => handleToggleActive(confirmDeactivate, false)} disabled={setCompanyActive.isPending}
                style={{ background: '#b31632', border: 0, borderRadius: 8, padding: '10px 18px', cursor: 'pointer', color: '#fff', fontWeight: 700, fontFamily: 'Arial,Helvetica,sans-serif', fontSize: 13 }}>
                {setCompanyActive.isPending ? 'Desactivando…' : 'Desactivar'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Create / Edit form */}
      {form.open && (
        <CompanyForm
          initial={form.editing}
          onSubmit={form.editing ? handleUpdate : handleCreate}
          onClose={() => setForm({ open: false })}
        />
      )}
    </div>
  );
}

// ── Full table row (no panel open) ────────────────────────────────────────────

function CompanyRow({ company: c, odd, onEdit, onToggle, onSelect, disabled }: {
  company: Company; odd: boolean; onEdit: () => void; onToggle: () => void; onSelect: () => void; disabled: boolean;
}) {
  const inactive = c.active === false;
  return (
    <tr onClick={onSelect} style={{ background: odd ? 'var(--company-subtle)' : 'var(--cm-surface)', borderBottom: '1px solid var(--cm-line)', cursor: 'pointer' }}>
      <td style={{ padding: '13px 16px' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <span style={{ width: 8, height: 8, borderRadius: '50%', background: inactive ? 'var(--cm-muted)' : 'var(--cm-good)', flexShrink: 0 }} />
          <span style={{ fontWeight: 700, color: 'var(--cm-text)', fontSize: 14 }}>{c.name}</span>
        </div>
      </td>
      <td style={{ padding: '13px 16px', color: 'var(--cm-muted)', fontSize: 13 }}>{c.legal_name || <span style={{ color: 'var(--cm-muted)' }}>—</span>}</td>
      <td style={{ padding: '13px 16px', color: 'var(--cm-muted)', fontSize: 13, fontVariantNumeric: 'tabular-nums' }}>{c.tax_id || <span style={{ color: 'var(--cm-muted)' }}>—</span>}</td>
      <td style={{ padding: '13px 16px', color: 'var(--cm-muted)', fontSize: 13 }}>
        {c.contact_name ? (
          <div>
            <div>{c.contact_name}</div>
            {c.contact_phone && <div style={{ fontSize: 11, color: 'var(--cm-muted)' }}>{c.contact_phone}</div>}
          </div>
        ) : <span style={{ color: 'var(--cm-muted)' }}>—</span>}
      </td>
      <td style={{ padding: '13px 16px' }}>
        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, background: inactive ? 'var(--cm-raised)' : 'var(--company-success-surface)', color: inactive ? 'var(--cm-muted)' : 'var(--cm-good)', borderRadius: 14, padding: '4px 10px', fontSize: 11, fontWeight: 800 }}>
          {inactive ? <PowerOff size={11} /> : <ToggleRight size={11} />}
          {inactive ? 'Inactiva' : 'Activa'}
        </span>
      </td>
      <td style={{ padding: '13px 16px' }} onClick={e => e.stopPropagation()}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, justifyContent: 'flex-end' }}>
          <button onClick={onEdit} disabled={disabled} title="Editar empresa"
            style={{ background: 'none', border: '1px solid var(--cm-line)', borderRadius: 7, padding: '6px 8px', cursor: 'pointer', color: 'var(--cm-muted)', display: 'flex', alignItems: 'center', gap: 5, fontSize: 12 }}>
            <PencilLine size={13} /> Editar
          </button>
          <button onClick={onToggle} disabled={disabled} title={inactive ? 'Reactivar' : 'Desactivar'}
            style={{ background: 'none', border: '1px solid var(--cm-line)', borderRadius: 7, padding: '6px 8px', cursor: 'pointer', color: inactive ? 'var(--cm-good)' : 'var(--cm-critical)', display: 'flex', alignItems: 'center', gap: 5, fontSize: 12 }}>
            <ChevronRight size={13} /> {inactive ? 'Reactivar' : 'Desactivar'}
          </button>
        </div>
      </td>
    </tr>
  );
}

// ── Compact row (panel open) ──────────────────────────────────────────────────

function CompanyRowCompact({ company: c, odd, selected, onClick }: {
  company: Company; odd: boolean; selected: boolean; onClick: () => void;
}) {
  const inactive = c.active === false;
  return (
    <tr onClick={onClick} style={{ background: selected ? 'var(--cm-raised)' : odd ? 'var(--company-subtle)' : 'var(--cm-surface)', borderBottom: '1px solid var(--cm-line)', cursor: 'pointer', outline: selected ? '2px solid var(--cm-focus)' : 'none' }}>
      <td style={{ padding: '12px 16px' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{ width: 7, height: 7, borderRadius: '50%', background: inactive ? 'var(--cm-muted)' : 'var(--cm-good)', flexShrink: 0 }} />
          <span style={{ fontWeight: selected ? 800 : 600, color: 'var(--cm-text)', fontSize: 13 }}>{c.name}</span>
        </div>
      </td>
      <td style={{ padding: '12px 16px' }}>
        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4, background: inactive ? 'var(--cm-raised)' : 'var(--company-success-surface)', color: inactive ? 'var(--cm-muted)' : 'var(--cm-good)', borderRadius: 12, padding: '3px 8px', fontSize: 10, fontWeight: 800 }}>
          {inactive ? 'Inactiva' : 'Activa'}
        </span>
      </td>
      <td style={{ padding: '12px 16px', textAlign: 'right' }}>
        <ChevronRight size={15} style={{ color: selected ? 'var(--cm-focus)' : 'var(--cm-muted)' }} />
      </td>
    </tr>
  );
}

// ── Company detail panel ──────────────────────────────────────────────────────

function CompanyDetail({ company: c, onEdit, onToggle, onClose, disabled }: {
  company: Company; onEdit: () => void; onToggle: () => void; onClose: () => void; disabled: boolean;
}) {
  const inactive = c.active === false;

  return (
    <div style={{ background: 'var(--cm-surface)', border: '1px solid var(--cm-line)', borderRadius: 13, overflow: 'hidden', fontFamily: 'Arial,Helvetica,sans-serif' }}>
      {/* Panel header */}
      <div style={{ background: 'var(--company-subtle)', borderBottom: '1px solid var(--cm-line)', padding: '16px 20px', display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 12 }}>
        <div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 6 }}>
            <span style={{ width: 10, height: 10, borderRadius: '50%', background: inactive ? 'var(--cm-muted)' : 'var(--cm-good)', flexShrink: 0 }} />
            <h2 style={{ margin: 0, fontSize: 17, fontWeight: 800, color: 'var(--cm-text)' }}>{c.name}</h2>
          </div>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, background: inactive ? 'var(--cm-raised)' : 'var(--company-success-surface)', color: inactive ? 'var(--cm-muted)' : 'var(--cm-good)', borderRadius: 14, padding: '4px 10px', fontSize: 11, fontWeight: 800 }}>
            {inactive ? <PowerOff size={11} /> : <ToggleRight size={11} />}
            {inactive ? 'Empresa inactiva' : 'Empresa activa'}
          </span>
        </div>
        <button onClick={onClose} style={{ background: 'none', border: 0, cursor: 'pointer', color: 'var(--cm-muted)', padding: 4, borderRadius: 6, flexShrink: 0 }}>
          <X size={18} />
        </button>
      </div>

      {/* Fields */}
      <div style={{ padding: '20px', display: 'flex', flexDirection: 'column', gap: 16 }}>
        {/* Legal + tax */}
        <Section label="Datos legales">
          <Field label="Razón social" value={c.legal_name} />
          <Field label="CUIT" value={c.tax_id} mono />
        </Section>

        {/* Contact */}
        <Section label="Contacto">
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            {c.contact_name && (
              <Row icon={<User size={13} />}>{c.contact_name}</Row>
            )}
            {c.contact_phone && (
              <Row icon={<Phone size={13} />}>{c.contact_phone}</Row>
            )}
            {c.contact_email && (
              <Row icon={<Mail size={13} />}>{c.contact_email}</Row>
            )}
            {!c.contact_name && !c.contact_phone && !c.contact_email && (
              <span style={{ color: 'var(--cm-muted)', fontSize: 13 }}>Sin datos de contacto registrados.</span>
            )}
          </div>
        </Section>

        {/* Address */}
        {c.address && (
          <Section label="Dirección">
            <Row icon={<MapPin size={13} />}>{c.address}</Row>
          </Section>
        )}

        {/* Notes */}
        {c.notes && (
          <Section label="Observaciones internas">
            <p style={{ margin: 0, fontSize: 13, color: 'var(--cm-muted)', lineHeight: 1.5 }}>{c.notes}</p>
          </Section>
        )}

        {/* Timestamps */}
        <div style={{ borderTop: '1px solid var(--cm-line)', paddingTop: 14, display: 'flex', gap: 20, flexWrap: 'wrap' }}>
          <Timestamp label="Creada" value={c.created_at} />
          <Timestamp label="Última edición" value={c.updated_at} />
        </div>

        {/* Actions */}
        <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', paddingTop: 4 }}>
          <button onClick={onEdit} disabled={disabled}
            style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 7, background: 'var(--company-primary)', border: 0, borderRadius: 9, padding: '11px 16px', cursor: 'pointer', color: 'var(--company-on-primary)', fontWeight: 700, fontSize: 13 }}>
            <PencilLine size={14} /> Editar empresa
          </button>
          <button onClick={onToggle} disabled={disabled}
            style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 7, background: 'none', border: `1px solid ${inactive ? 'var(--cm-good)' : 'var(--cm-critical)'}`, borderRadius: 9, padding: '11px 16px', cursor: 'pointer', color: inactive ? 'var(--cm-good)' : 'var(--cm-critical)', fontWeight: 700, fontSize: 13 }}>
            {inactive ? <ToggleRight size={14} /> : <PowerOff size={14} />}
            {inactive ? 'Reactivar' : 'Desactivar'}
          </button>
        </div>
      </div>
    </div>
  );
}

function Section({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <p style={{ margin: '0 0 8px', fontSize: 10, fontWeight: 800, color: 'var(--cm-muted)', letterSpacing: '0.8px', textTransform: 'uppercase' }}>{label}</p>
      {children}
    </div>
  );
}

function Field({ label, value, mono }: { label: string; value?: string | null; mono?: boolean }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, fontSize: 13, padding: '5px 0', borderBottom: '1px solid var(--cm-line)' }}>
      <span style={{ color: 'var(--cm-muted)', flexShrink: 0 }}>{label}</span>
      <span style={{ color: value ? 'var(--cm-text)' : 'var(--cm-muted)', fontFamily: mono ? 'monospace' : undefined, textAlign: 'right' }}>
        {value || '—'}
      </span>
    </div>
  );
}

function Row({ icon, children }: { icon: React.ReactNode; children: React.ReactNode }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, color: 'var(--cm-muted)' }}>
      <span style={{ color: 'var(--cm-muted)', flexShrink: 0 }}>{icon}</span>
      {children}
    </div>
  );
}

function Timestamp({ label, value }: { label: string; value?: string | null }) {
  return (
    <div>
      <p style={{ margin: '0 0 2px', fontSize: 10, fontWeight: 800, color: 'var(--cm-muted)', letterSpacing: '0.6px', textTransform: 'uppercase' }}>{label}</p>
      <p style={{ margin: 0, fontSize: 12, color: 'var(--cm-muted)' }}>{fmtDate(value)}</p>
    </div>
  );
}
