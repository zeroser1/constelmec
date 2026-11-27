import { useState } from 'react';
import { Building, CheckCircle, HardHat, XCircle } from 'lucide-react';
import type { Company, Technician } from './AdminControl';
import {
  useFacilities,
  useTechnicianCompanyAssignments,
  useEnabledCompanyTechnicians,
  useTechnicianFacilityAssignments,
  useTechnicianMutations,
  useTechnicianProfiles,
  type TechnicianCompanyAssignment,
  type TechnicianFacilityAssignment,
} from './hooks/useRealData';

type Tab = 'ficha' | 'empresa' | 'instalaciones';

type Props = { companies: Company[]; platformAdmin?: boolean };

export default function TechnicianManager({ companies, platformAdmin = false }: Props) {
  const [companyId, setCompanyId]       = useState('');
  const [selectedTech, setSelectedTech] = useState<Technician | null>(null);
  const [tab, setTab]                   = useState<Tab>('ficha');
  const [companyError, setCompanyError] = useState('');
  const [facilityError, setFacilityError] = useState('');

  const techsQ              = useTechnicianProfiles(companyId || undefined, platformAdmin);
  const facilitiesQ         = useFacilities(companyId || undefined);
  const companyAssignmentsQ = useTechnicianCompanyAssignments(companyId || undefined);
  const enabledQ = useEnabledCompanyTechnicians(companyId || undefined);
  const facilityAssignmentsQ = useTechnicianFacilityAssignments(
    companyId || undefined,
    selectedTech?.id,
  );
  const { setCompanyActive, setFacilityActive } = useTechnicianMutations();

  const techs: Technician[]                             = techsQ.data ?? [];
  const facilities                                      = facilitiesQ.data ?? [];
  const companyAssignments: TechnicianCompanyAssignment[] = companyAssignmentsQ.data ?? [];
  const facilityAssignments: TechnicianFacilityAssignment[] = facilityAssignmentsQ.data ?? [];

  const enabledNames = new Map((enabledQ.data ?? []).map(tech => [tech.id, `${tech.first_name} ${tech.last_name}`]));
  const companyAssignmentMap = Object.fromEntries(companyAssignments.map(a => [a.technician_id, a]));
  const facilityAssignmentMap = Object.fromEntries(facilityAssignments.map(a => [a.facility_id, a]));

  const selectedAssignment = selectedTech ? (companyAssignmentMap[selectedTech.id] ?? null) : null;
  const isEnabled = selectedAssignment?.active ?? false;

  const handleSelectTech = (tech: Technician) => {
    setSelectedTech(tech);
    setTab('ficha');
    setCompanyError('');
    setFacilityError('');
  };

  const handleCompanyChange = (newId: string) => {
    setCompanyId(newId);
    setSelectedTech(null);
    setCompanyError('');
    setFacilityError('');
  };

  const toggleCompany = async () => {
    if (!companyId || !selectedTech) return;
    setCompanyError('');
    try {
      await setCompanyActive.mutateAsync({ active: !isEnabled, cId: companyId, tId: selectedTech.id });
    } catch (err) {
      setCompanyError(err instanceof Error ? err.message : 'Error al actualizar');
    }
  };

  const toggleFacility = async (facilityId: string, currentActive: boolean) => {
    if (!companyId || !selectedTech) return;
    setFacilityError('');
    try {
      await setFacilityActive.mutateAsync({ facilityId, active: !currentActive, cId: companyId, tId: selectedTech.id });
    } catch (err) {
      setFacilityError(err instanceof Error ? err.message : 'Error al actualizar');
    }
  };

  // ── Render: left panel technician item ───────────────────────────────────

  const renderTechItem = (tech: Technician) => {
    const a = companyAssignmentMap[tech.id];
    const enabled = a?.active ?? false;
    const sel = selectedTech?.id === tech.id;
    return (
      <div
        key={tech.id}
        onClick={() => handleSelectTech(tech)}
        style={{
          padding: '10px 14px', borderRadius: 8, cursor: 'pointer', userSelect: 'none',
          background: sel ? '#10263e' : 'white',
          border: `1px solid ${sel ? '#10263e' : '#e0e6ef'}`,
          display: 'flex', flexDirection: 'column', gap: 4,
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
          <HardHat size={13} style={{ color: sel ? '#8aafd4' : '#8295a8', flexShrink: 0 }} />
          <span style={{ fontWeight: 800, fontSize: 13, color: sel ? 'white' : '#10263e', fontFamily: 'Arial,Helvetica,sans-serif' }}>
            {tech.last_name}, {tech.first_name}
          </span>
        </div>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', paddingLeft: 19 }}>
          {tech.specialty && (
            <span style={{ fontSize: 11, color: sel ? '#8aafd4' : '#728499', fontFamily: 'Arial,Helvetica,sans-serif' }}>
              {tech.specialty}
            </span>
          )}
          {!tech.active && (
            <span style={{ fontSize: 11, fontWeight: 700, color: '#8295a8', background: '#8295a818', borderRadius: 12, padding: '2px 8px', fontFamily: 'Arial,Helvetica,sans-serif' }}>
              Inactivo
            </span>
          )}
          <span style={{ fontSize: 11, fontWeight: 700, color: enabled ? '#0a7c42' : '#c41e32', background: enabled ? '#0a7c4218' : '#c41e3218', borderRadius: 12, padding: '2px 8px', fontFamily: 'Arial,Helvetica,sans-serif' }}>
            {enabled ? 'Habilitado' : 'Sin habilitar'}
          </span>
        </div>
      </div>
    );
  };

  // ── Render: Ficha tab (read-only) ─────────────────────────────────────────

  const renderFichaTab = () => {
    if (!selectedTech) return null;
    const t = selectedTech;
    const rows: [string, string][] = [
      ['Nombre completo', `${t.first_name} ${t.last_name}`],
      ['Especialidad', t.specialty ?? '—'],
      ['Teléfono laboral', t.work_phone ?? '—'],
      ['Email laboral', t.work_email ?? '—'],
      ['Autorización para conducir', t.driving_authorized ? 'Autorizado' : 'No autorizado'],
      ['Vencimiento de licencia', t.license_expires_on ?? '—'],
      ['Estado del perfil', t.active ? 'Activo' : 'Inactivo'],
    ];
    return (
      <div style={{ display: 'flex', flexDirection: 'column' }}>
        {rows.map(([label, value]) => (
          <div
            key={label}
            style={{ display: 'grid', gridTemplateColumns: '180px 1fr', gap: 12, padding: '10px 16px', borderBottom: '1px solid #f0f4f9' }}
          >
            <span style={{ fontSize: 12, fontWeight: 700, color: '#728499', textTransform: 'uppercase', letterSpacing: '0.4px', fontFamily: 'Arial,Helvetica,sans-serif', paddingTop: 1 }}>
              {label}
            </span>
            <span style={{ fontSize: 13, color: '#10263e', fontFamily: 'Arial,Helvetica,sans-serif' }}>
              {value}
            </span>
          </div>
        ))}
        <p style={{ padding: '10px 16px', margin: 0, fontSize: 11, color: '#8295a8', fontFamily: 'Arial,Helvetica,sans-serif', fontStyle: 'italic' }}>
          Los datos de la ficha son de solo lectura. Para modificarlos, contactá al administrador de plataforma.
        </p>
      </div>
    );
  };

  // ── Render: Empresa tab ───────────────────────────────────────────────────

  const renderEmpresaTab = () => {
    if (companyAssignmentsQ.isLoading) return <p style={{ padding: 16, color: '#8295a8', fontSize: 13, fontFamily: 'Arial,Helvetica,sans-serif' }}>Cargando…</p>;
    if (companyAssignmentsQ.error) return <p style={{ padding: 16, color: '#c41e32', fontSize: 13, fontFamily: 'Arial,Helvetica,sans-serif' }}>Error: {companyAssignmentsQ.error.message}</p>;
    const busy = setCompanyActive.isPending;
    return (
      <div style={{ padding: '20px 16px', display: 'flex', flexDirection: 'column', gap: 16 }}>
        <div style={{
          display: 'flex', alignItems: 'center', gap: 12, padding: '14px 16px',
          background: isEnabled ? '#f0faf4' : '#fff4f4',
          borderRadius: 10, border: `1px solid ${isEnabled ? '#c3e6cb' : '#f5c6cb'}`,
        }}>
          {isEnabled
            ? <CheckCircle size={20} style={{ color: '#0a7c42', flexShrink: 0 }} />
            : <XCircle    size={20} style={{ color: '#c41e32', flexShrink: 0 }} />
          }
          <div>
            <p style={{ margin: 0, fontSize: 14, fontWeight: 800, color: isEnabled ? '#0a7c42' : '#c41e32', fontFamily: 'Arial,Helvetica,sans-serif' }}>
              {isEnabled ? 'Técnico habilitado para esta empresa' : 'Técnico no habilitado para esta empresa'}
            </p>
            <p style={{ margin: '2px 0 0', fontSize: 12, color: '#728499', fontFamily: 'Arial,Helvetica,sans-serif' }}>
              {isEnabled
                ? 'Puede trabajar en las órdenes habilitadas de esta empresa con una membresía de técnico activa.'
                : 'No puede consultar ni operar órdenes de esta empresa hasta que esté habilitado.'}
            </p>
          </div>
        </div>

        {companyError && (
          <p style={{ margin: 0, color: '#c41e32', fontSize: 13, fontFamily: 'Arial,Helvetica,sans-serif' }}>
            {companyError}
          </p>
        )}

        <button
          onClick={toggleCompany}
          disabled={busy}
          style={{
            alignSelf: 'flex-start', background: isEnabled ? '#c41e32' : '#0a7c42',
            border: 0, borderRadius: 8, padding: '10px 20px', cursor: 'pointer',
            color: 'white', fontWeight: 700, fontFamily: 'Arial,Helvetica,sans-serif', fontSize: 13,
            opacity: busy ? 0.7 : 1,
          }}
        >
          {busy ? 'Procesando…' : isEnabled ? 'Deshabilitar para esta empresa' : 'Habilitar para esta empresa'}
        </button>
      </div>
    );
  };

  // ── Render: Instalaciones tab ─────────────────────────────────────────────

  const renderInstalacionesTab = () => {
    const busy = setFacilityActive.isPending;
    if (facilityAssignmentsQ.isLoading) {
      return <p style={{ padding: 16, color: '#8295a8', fontSize: 13, fontFamily: 'Arial,Helvetica,sans-serif' }}>Cargando…</p>;
    }
    if (facilityAssignmentsQ.error) {
      return <p style={{ padding: 16, color: '#c41e32', fontSize: 13, fontFamily: 'Arial,Helvetica,sans-serif' }}>Error: {facilityAssignmentsQ.error.message}</p>;
    }
    const activeFacilities = facilities.filter(f => f.active);
    if (activeFacilities.length === 0) {
      return <p style={{ padding: 16, color: '#8295a8', fontSize: 13, fontFamily: 'Arial,Helvetica,sans-serif' }}>Esta empresa no tiene instalaciones activas.</p>;
    }
    return (
      <div style={{ display: 'flex', flexDirection: 'column' }}>
        {!isEnabled && (
          <div style={{ margin: '12px 16px 4px', padding: '10px 14px', background: '#fff9e6', border: '1px solid #f5d6a0', borderRadius: 8 }}>
            <p style={{ margin: 0, fontSize: 12, color: '#a07000', fontFamily: 'Arial,Helvetica,sans-serif' }}>
              Habilitá al técnico para esta empresa antes de asignarle instalaciones.
            </p>
          </div>
        )}
        {facilityError && (
          <p style={{ padding: '8px 16px', margin: 0, color: '#c41e32', fontSize: 13, fontFamily: 'Arial,Helvetica,sans-serif' }}>
            {facilityError}
          </p>
        )}
        {activeFacilities.map(facility => {
          const a = facilityAssignmentMap[facility.id];
          const facEnabled = a?.active ?? false;
          return (
            <div
              key={facility.id}
              style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '10px 16px', borderBottom: '1px solid #f0f4f9', gap: 12 }}
            >
              <span style={{ fontSize: 13, color: '#10263e', fontFamily: 'Arial,Helvetica,sans-serif' }}>
                {facility.name}
              </span>
              <button
                onClick={() => toggleFacility(facility.id, facEnabled)}
                disabled={busy || !isEnabled}
                style={{
                  background: 'none',
                  border: `1px solid ${facEnabled ? '#c41e32' : '#0a7c42'}`,
                  borderRadius: 7, padding: '5px 12px',
                  cursor: !isEnabled || busy ? 'not-allowed' : 'pointer',
                  color: facEnabled ? '#c41e32' : '#0a7c42',
                  fontWeight: 600, fontFamily: 'Arial,Helvetica,sans-serif', fontSize: 12,
                  opacity: !isEnabled || busy ? 0.5 : 1,
                }}
              >
                {facEnabled ? 'Desasignar' : 'Asignar'}
              </button>
            </div>
          );
        })}
      </div>
    );
  };

  // ── Main render ───────────────────────────────────────────────────────────

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', background: '#f3f5f8', fontFamily: 'Arial,Helvetica,sans-serif' }}>
      {/* Toolbar */}
      <div style={{ padding: '16px 20px 0', flexShrink: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <Building size={15} style={{ color: '#8295a8' }} />
          <select
            value={companyId}
            onChange={e => handleCompanyChange(e.target.value)}
            style={{ border: '1px solid #dfe6ef', borderRadius: 8, padding: '8px 12px', fontSize: 13, fontFamily: 'Arial,Helvetica,sans-serif', color: '#10263e', background: 'white', cursor: 'pointer', minWidth: 220 }}
          >
            <option value="">— Seleccioná una empresa —</option>
            {companies.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </div>
      </div>

      {!companyId ? (
        <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <p style={{ color: '#8295a8', fontSize: 14 }}>Seleccioná una empresa para ver sus técnicos.</p>
        </div>
      ) : (
        <div style={{ flex: 1, overflow: 'hidden', display: 'flex', gap: 16, margin: '16px 20px' }}>

          {/* Left panel — technician list */}
          <div style={{ width: 260, flexShrink: 0, background: 'white', borderRadius: 12, border: '1px solid #e0e6ef', display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
            <div style={{ padding: '12px 14px', borderBottom: '1px solid #e8edf4', flexShrink: 0 }}>
              <span style={{ fontSize: 13, fontWeight: 700, color: '#10263e' }}>
                Técnicos {techs.length > 0 && `(${techs.length})`}
              </span>
            </div>
            <div style={{ overflow: 'auto', flex: 1, padding: 10, display: 'flex', flexDirection: 'column', gap: 8 }}>
              {techsQ.isLoading && <p style={{ color: '#8295a8', fontSize: 13, padding: 4 }}>Cargando…</p>}
              {techsQ.error    && <p style={{ color: '#c41e32', fontSize: 13, padding: 4 }}>Error: {techsQ.error.message}</p>}
              {!techsQ.isLoading && techs.length === 0 && (
                <p style={{ color: '#8295a8', fontSize: 13, padding: 4 }}>Sin técnicos en esta empresa.</p>
              )}
              {techs.map(renderTechItem)}
              {enabledQ.isError && <p role="alert">No se pudo consultar la lista de técnicos habilitados.</p>}
              {enabledNames.size > 0 && <div>
                <strong>Habilitados para la empresa</strong>
                <ul>{Array.from(enabledNames, ([id, name]) => <li key={id}>{name}</li>)}</ul>
              </div>}
            </div>
          </div>

          {/* Right panel — detail */}
          <div style={{ flex: 1, background: 'white', borderRadius: 12, border: '1px solid #e0e6ef', display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
            {!selectedTech ? (
              <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                <p style={{ color: '#8295a8', fontSize: 14 }}>Seleccioná un técnico para ver su detalle.</p>
              </div>
            ) : (
              <>
                {/* Tech header */}
                <div style={{ padding: '16px', borderBottom: '1px solid #e8edf4', display: 'flex', alignItems: 'center', gap: 10, flexShrink: 0 }}>
                  <HardHat size={18} style={{ color: '#8295a8' }} />
                  <div>
                    <p style={{ margin: 0, fontSize: 15, fontWeight: 800, color: '#10263e', fontFamily: 'Arial,Helvetica,sans-serif' }}>
                      {selectedTech.first_name} {selectedTech.last_name}
                    </p>
                    {selectedTech.specialty && (
                      <p style={{ margin: 0, fontSize: 12, color: '#728499', fontFamily: 'Arial,Helvetica,sans-serif' }}>
                        {selectedTech.specialty}
                      </p>
                    )}
                  </div>
                </div>

                {/* Tab navigation */}
                <div style={{ display: 'flex', borderBottom: '1px solid #e8edf4', flexShrink: 0 }}>
                  {(['ficha', 'empresa', 'instalaciones'] as Tab[]).map(t => (
                    <button
                      key={t}
                      onClick={() => setTab(t)}
                      style={{
                        background: 'none', border: 0,
                        borderBottom: `2px solid ${tab === t ? '#10263e' : 'transparent'}`,
                        padding: '10px 16px', cursor: 'pointer',
                        fontSize: 13, fontWeight: tab === t ? 800 : 500,
                        color: tab === t ? '#10263e' : '#728499',
                        fontFamily: 'Arial,Helvetica,sans-serif',
                      }}
                    >
                      {t === 'ficha' ? 'Ficha' : t === 'empresa' ? 'Empresa' : 'Instalaciones'}
                    </button>
                  ))}
                </div>

                {/* Tab content */}
                <div style={{ flex: 1, overflow: 'auto' }}>
                  {tab === 'ficha'          && renderFichaTab()}
                  {tab === 'empresa'        && renderEmpresaTab()}
                  {tab === 'instalaciones'  && renderInstalacionesTab()}
                </div>
              </>
            )}
          </div>

        </div>
      )}
    </div>
  );
}
