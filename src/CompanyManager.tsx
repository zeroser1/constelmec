import { useMemo, useState } from 'react';
import { Building2, ChevronRight, PencilLine, Plus, PowerOff, Search, ToggleRight } from 'lucide-react';
import type { Company } from './AdminControl';
import type { CompanyFormInput } from './hooks/useRealData';
import { useAdminCompanyMutations } from './hooks/useRealData';
import CompanyForm from './CompanyForm';

type Props = {
  companies: Company[];
  isLoading?: boolean;
  error?: Error | null;
};

export default function CompanyManager({ companies, isLoading, error }: Props) {
  const [query, setQuery] = useState('');
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

  const handleCreate = async (data: CompanyFormInput) => {
    setMutError('');
    await createCompany.mutateAsync(data);
  };

  const handleUpdate = async (data: CompanyFormInput) => {
    if (!form.editing) return;
    setMutError('');
    await updateCompany.mutateAsync({ ...data, id: form.editing.id });
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

  return (
    <div style={{ padding:'28px',maxWidth:1100,margin:'0 auto',fontFamily:'Arial,Helvetica,sans-serif' }}>
      {/* Page heading */}
      <div style={{ display:'flex',alignItems:'center',justifyContent:'space-between',gap:12,flexWrap:'wrap',marginBottom:20 }}>
        <div>
          <small style={{ fontSize:10,letterSpacing:'1.4px',color:'#728499',fontWeight:800 }}>EMPRESAS CLIENTES</small>
          <h1 style={{ fontSize:26,margin:'6px 0 0',color:'#10263e' }}>Gestión de empresas</h1>
        </div>
        <button onClick={() => setForm({ open: true })} disabled={isMutating}
          style={{ display:'flex',alignItems:'center',gap:8,background:'#10263e',border:0,borderRadius:9,padding:'11px 18px',cursor:'pointer',color:'white',fontWeight:700,fontSize:13 }}>
          <Plus size={16} /> Nueva empresa
        </button>
      </div>

      {/* Search */}
      <div style={{ position:'relative',marginBottom:18 }}>
        <Search size={16} style={{ position:'absolute',left:14,top:'50%',transform:'translateY(-50%)',color:'#8295a8',pointerEvents:'none' }} />
        <input
          value={query} onChange={e => setQuery(e.target.value)}
          placeholder="Buscar por nombre, razón social o CUIT…"
          style={{ width:'100%',boxSizing:'border-box',border:'1px solid #dfe6ef',borderRadius:9,padding:'11px 14px 11px 42px',fontSize:14,color:'#1b2838',background:'white' }}
        />
      </div>

      {/* Error */}
      {(mutError || error) && (
        <p style={{ background:'#fce6e9',border:'1px solid #f5c6cb',borderRadius:8,padding:'10px 14px',color:'#c41e32',fontSize:13,marginBottom:16 }}>
          {mutError || error?.message}
        </p>
      )}

      {/* Table */}
      <div style={{ background:'white',border:'1px solid #e0e6ed',borderRadius:13,overflow:'hidden' }}>
        {isLoading ? (
          <p style={{ padding:'40px 24px',color:'#728499',textAlign:'center' }}>Cargando empresas…</p>
        ) : filtered.length === 0 ? (
          <div style={{ padding:'52px 24px',textAlign:'center' }}>
            <Building2 size={36} style={{ color:'#b0beca',marginBottom:12 }} />
            <p style={{ color:'#728499',margin:0,fontSize:14 }}>
              {query ? 'Ninguna empresa coincide con la búsqueda.' : 'Todavía no hay empresas registradas. Creá la primera.'}
            </p>
          </div>
        ) : (
          <table style={{ width:'100%',borderCollapse:'collapse' }}>
            <thead>
              <tr style={{ background:'#f7f9fb',borderBottom:'1px solid #e0e6ed' }}>
                {['Nombre comercial','Razón social','CUIT','Contacto','Estado',''].map((h,i) => (
                  <th key={i} style={{ padding:'11px 16px',textAlign:'left',fontSize:11,fontWeight:800,color:'#728499',letterSpacing:'0.6px',textTransform:'uppercase',whiteSpace:'nowrap' }}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {filtered.map((c, idx) => (
                <CompanyRow key={c.id} company={c} odd={idx % 2 === 1}
                  onEdit={() => setForm({ open: true, editing: c })}
                  onToggle={() => c.active !== false ? setConfirmDeactivate(c) : handleToggleActive(c, true)}
                  disabled={isMutating}
                />
              ))}
            </tbody>
          </table>
        )}
      </div>

      <p style={{ color:'#8295a8',fontSize:11,marginTop:12 }}>
        {filtered.length} empresa{filtered.length !== 1 ? 's' : ''} · Panel de administrador global
      </p>

      {/* Deactivate confirmation */}
      {confirmDeactivate && (
        <div style={{ position:'fixed',inset:0,background:'rgba(0,0,0,.5)',display:'flex',alignItems:'center',justifyContent:'center',zIndex:200,padding:16 }}>
          <div style={{ background:'white',borderRadius:12,padding:'28px 28px 24px',maxWidth:380,width:'100%',boxShadow:'0 20px 60px rgba(0,0,0,.3)' }}>
            <h3 style={{ margin:'0 0 10px',color:'#10263e',fontFamily:'Arial,Helvetica,sans-serif' }}>¿Desactivar empresa?</h3>
            <p style={{ margin:'0 0 20px',color:'#526479',fontSize:14,fontFamily:'Arial,Helvetica,sans-serif' }}>
              <strong>{confirmDeactivate.name}</strong> quedará inactiva. Los usuarios perderán acceso operativo, pero su historial se conserva. Podés reactivarla en cualquier momento.
            </p>
            <div style={{ display:'flex',gap:10,justifyContent:'flex-end' }}>
              <button onClick={() => setConfirmDeactivate(null)}
                style={{ background:'none',border:'1px solid #cdd5df',borderRadius:8,padding:'10px 16px',cursor:'pointer',color:'#526479',fontFamily:'Arial,Helvetica,sans-serif',fontSize:13 }}>
                Cancelar
              </button>
              <button onClick={() => handleToggleActive(confirmDeactivate, false)} disabled={setCompanyActive.isPending}
                style={{ background:'#c41e32',border:0,borderRadius:8,padding:'10px 18px',cursor:'pointer',color:'white',fontWeight:700,fontFamily:'Arial,Helvetica,sans-serif',fontSize:13 }}>
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

function CompanyRow({ company: c, odd, onEdit, onToggle, disabled }: {
  company: Company; odd: boolean; onEdit: () => void; onToggle: () => void; disabled: boolean;
}) {
  const inactive = c.active === false;
  const rowBg = odd ? '#fafbfd' : 'white';

  return (
    <tr style={{ background:rowBg,borderBottom:'1px solid #edf0f4',opacity:inactive ? 0.65 : 1 }}>
      <td style={{ padding:'13px 16px' }}>
        <div style={{ display:'flex',alignItems:'center',gap:10 }}>
          <span style={{ width:8,height:8,borderRadius:'50%',background:inactive ? '#b0beca' : '#1dab5e',flexShrink:0 }} />
          <span style={{ fontWeight:700,color:'#10263e',fontSize:14 }}>{c.name}</span>
        </div>
      </td>
      <td style={{ padding:'13px 16px',color:'#526479',fontSize:13 }}>{c.legal_name || <span style={{ color:'#b0beca' }}>—</span>}</td>
      <td style={{ padding:'13px 16px',color:'#526479',fontSize:13,fontVariantNumeric:'tabular-nums' }}>{c.tax_id || <span style={{ color:'#b0beca' }}>—</span>}</td>
      <td style={{ padding:'13px 16px',color:'#526479',fontSize:13 }}>
        {c.contact_name ? (
          <div>
            <div>{c.contact_name}</div>
            {c.contact_phone && <div style={{ fontSize:11,color:'#8295a8' }}>{c.contact_phone}</div>}
          </div>
        ) : <span style={{ color:'#b0beca' }}>—</span>}
      </td>
      <td style={{ padding:'13px 16px' }}>
        <span style={{ display:'inline-flex',alignItems:'center',gap:5,background:inactive ? '#f1f3f5' : '#e4f4e8',color:inactive ? '#728499' : '#187a3d',borderRadius:14,padding:'4px 10px',fontSize:11,fontWeight:800 }}>
          {inactive ? <PowerOff size={11}/> : <ToggleRight size={11}/>}
          {inactive ? 'Inactiva' : 'Activa'}
        </span>
      </td>
      <td style={{ padding:'13px 16px' }}>
        <div style={{ display:'flex',alignItems:'center',gap:6,justifyContent:'flex-end' }}>
          <button onClick={onEdit} disabled={disabled} title="Editar empresa"
            style={{ background:'none',border:'1px solid #dfe6ef',borderRadius:7,padding:'6px 8px',cursor:'pointer',color:'#526479',display:'flex',alignItems:'center',gap:5,fontSize:12 }}>
            <PencilLine size={13}/> Editar
          </button>
          <button onClick={onToggle} disabled={disabled} title={inactive ? 'Reactivar' : 'Desactivar'}
            style={{ background:'none',border:'1px solid #dfe6ef',borderRadius:7,padding:'6px 8px',cursor:'pointer',color:inactive ? '#187a3d' : '#c41e32',display:'flex',alignItems:'center',gap:5,fontSize:12 }}>
            <ChevronRight size={13}/> {inactive ? 'Reactivar' : 'Desactivar'}
          </button>
        </div>
      </td>
    </tr>
  );
}
