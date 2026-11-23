import { useState } from 'react';
import { X } from 'lucide-react';
import type { Company } from './AdminControl';
import type { CompanyFormInput } from './hooks/useRealData';

// CUIT/CUIL check-digit validation (Argentine tax ID, 11 digits).
// Mirrors the server-side app_private.validate_cuit() SQL function.
function validateCuit(raw: string): boolean {
  const digits = raw.replace(/[-\s]/g, '');
  if (!/^\d{11}$/.test(digits)) return false;
  const factors = [5, 4, 3, 2, 7, 6, 5, 4, 3, 2];
  const total = factors.reduce((sum, f, i) => sum + Number(digits[i]) * f, 0);
  const rem = total % 11;
  if (rem === 1) return false;
  return Number(digits[10]) === (rem === 0 ? 0 : 11 - rem);
}

type Props = {
  initial?: Company;
  onSubmit: (data: CompanyFormInput) => Promise<void>;
  onClose: () => void;
};

const empty: CompanyFormInput = {
  name: '', legal_name: '', tax_id: '', contact_name: '',
  contact_email: '', contact_phone: '', address: '', notes: '',
};

export default function CompanyForm({ initial, onSubmit, onClose }: Props) {
  const [form, setForm] = useState<CompanyFormInput>({
    name:          initial?.name          ?? '',
    legal_name:    initial?.legal_name    ?? '',
    tax_id:        initial?.tax_id        ?? '',
    contact_name:  initial?.contact_name  ?? '',
    contact_email: initial?.contact_email ?? '',
    contact_phone: initial?.contact_phone ?? '',
    address:       initial?.address       ?? '',
    notes:         initial?.notes         ?? '',
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const field = (key: keyof CompanyFormInput) => ({
    value: form[key],
    onChange: (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
      setForm(prev => ({ ...prev, [key]: e.target.value })),
  });

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (form.name.trim().length < 2) { setError('El nombre comercial debe tener al menos 2 caracteres.'); return; }
    const rawCuit = form.tax_id.replace(/[-\s]/g, '');
    if (rawCuit.length > 0 && !validateCuit(form.tax_id)) {
      setError('CUIT inválido. Verificá los 11 dígitos y el dígito verificador.');
      return;
    }
    setBusy(true); setError('');
    try {
      await onSubmit(form);
      onClose();
    } catch (err) {
      const msg = err instanceof Error ? err.message : '';
      if (msg.includes('concurrent edit conflict')) {
        setError('Esta empresa fue editada por otro usuario. Cerrá este formulario y volvé a abrirlo para ver los cambios recientes.');
      } else {
        setError(msg || 'Error al guardar empresa.');
      }
    } finally {
      setBusy(false);
    }
  };

  const isEdit = !!initial;

  return (
    <div style={{ position:'fixed',inset:0,background:'rgba(0,0,0,.55)',display:'flex',alignItems:'center',justifyContent:'center',zIndex:200,padding:'16px' }}>
      <div style={{ background:'white',borderRadius:14,width:'100%',maxWidth:480,maxHeight:'90vh',display:'flex',flexDirection:'column',boxShadow:'0 20px 60px rgba(0,0,0,.3)' }}>
        {/* Header */}
        <div style={{ display:'flex',alignItems:'center',justifyContent:'space-between',padding:'20px 24px 0',flexShrink:0 }}>
          <h2 style={{ margin:0,fontSize:19,fontWeight:800,color:'#10263e',fontFamily:'Arial,Helvetica,sans-serif' }}>
            {isEdit ? 'Editar empresa' : 'Nueva empresa'}
          </h2>
          <button onClick={onClose} disabled={busy}
            style={{ background:'none',border:0,cursor:'pointer',color:'#8295a8',display:'flex',alignItems:'center',padding:4,borderRadius:6 }}>
            <X size={20} />
          </button>
        </div>

        {/* Form */}
        <form onSubmit={submit} style={{ overflow:'auto',padding:'20px 24px 24px',display:'flex',flexDirection:'column',gap:14 }}>
          <Field label="Nombre comercial *" required>
            <input {...field('name')} placeholder="Acme S.R.L." style={inp} required minLength={2} />
          </Field>
          <Field label="Razón social">
            <input {...field('legal_name')} placeholder="ACME SOCIEDAD DE RESPONSABILIDAD LIMITADA" style={inp} />
          </Field>
          <Field label="CUIT">
            <input {...field('tax_id')} placeholder="20-05536168-2" style={inp} />
          </Field>
          <div style={{ display:'grid',gridTemplateColumns:'1fr 1fr',gap:12 }}>
            <Field label="Contacto">
              <input {...field('contact_name')} placeholder="Juan Pérez" style={inp} />
            </Field>
            <Field label="Teléfono">
              <input {...field('contact_phone')} placeholder="+54 11 1234-5678" style={inp} />
            </Field>
          </div>
          <Field label="Correo electrónico">
            <input {...field('contact_email')} type="email" placeholder="contacto@empresa.com.ar" style={inp} />
          </Field>
          <Field label="Dirección">
            <input {...field('address')} placeholder="Av. San Martín 1234, Buenos Aires" style={inp} />
          </Field>
          <Field label="Observaciones internas">
            <textarea {...field('notes')} placeholder="Notas para el equipo..." rows={3}
              style={{ ...inp, resize:'vertical', minHeight:70 }} />
          </Field>

          {error && <p style={{ margin:0,color:'#c41e32',fontSize:13,fontFamily:'Arial,Helvetica,sans-serif' }}>{error}</p>}

          <div style={{ display:'flex',gap:10,justifyContent:'flex-end',paddingTop:4,flexShrink:0 }}>
            <button type="button" onClick={() => { setForm(empty); setError(''); }} disabled={busy}
              style={{ background:'none',border:'1px solid #cdd5df',borderRadius:8,padding:'10px 16px',cursor:'pointer',color:'#526479',fontFamily:'Arial,Helvetica,sans-serif',fontSize:13 }}>
              Limpiar
            </button>
            <button type="button" onClick={onClose} disabled={busy}
              style={{ background:'none',border:'1px solid #cdd5df',borderRadius:8,padding:'10px 16px',cursor:'pointer',color:'#526479',fontFamily:'Arial,Helvetica,sans-serif',fontSize:13 }}>
              Cancelar
            </button>
            <button type="submit" disabled={busy}
              style={{ background:'#10263e',border:0,borderRadius:8,padding:'10px 20px',cursor:'pointer',color:'white',fontWeight:700,fontFamily:'Arial,Helvetica,sans-serif',fontSize:13,opacity:busy?0.7:1 }}>
              {busy ? 'Guardando...' : isEdit ? 'Guardar cambios' : 'Crear empresa'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

function Field({ label, children, required }: { label: string; children: React.ReactNode; required?: boolean }) {
  return (
    <label style={{ display:'flex',flexDirection:'column',gap:5,fontFamily:'Arial,Helvetica,sans-serif' }}>
      <span style={{ fontSize:11,fontWeight:800,color:'#728499',letterSpacing:'0.6px',textTransform:'uppercase' }}>
        {label}{required && <span style={{ color:'#c41e32',marginLeft:2 }}>*</span>}
      </span>
      {children}
    </label>
  );
}

const inp: React.CSSProperties = {
  border:'1px solid #dfe6ef',borderRadius:8,padding:'10px 12px',fontSize:14,
  fontFamily:'Arial,Helvetica,sans-serif',color:'#1b2838',background:'white',width:'100%',boxSizing:'border-box',
};
