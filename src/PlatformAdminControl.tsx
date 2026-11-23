import { useState } from 'react';
import { Building2, CalendarDays, LogOut, Shield } from 'lucide-react';
import AdminControl from './AdminControl';
import CompanyManager from './CompanyManager';
import { usePlatformAdminData } from './hooks/useRealData';

type Section = 'companies' | 'operations';

export default function PlatformAdminControl({
  userId,
  email,
  onLogout,
}: {
  userId: string;
  email: string;
  onLogout: () => void;
}) {
  const dataQ = usePlatformAdminData(userId, true);
  const [section, setSection] = useState<Section>('companies');

  if (dataQ.isLoading) {
    return <div className="real-shell"><div className="real-panel"><p>Cargando vista global…</p></div></div>;
  }
  if (dataQ.error) {
    return (
      <div className="real-shell">
        <div className="real-panel">
          <p>Error: {dataQ.error?.message ?? 'Error desconocido'}</p>
        </div>
      </div>
    );
  }

  const companies  = dataQ.data?.companies  ?? [];
  const orders     = dataQ.data?.orders     ?? [];
  const technicians = dataQ.data?.technicians ?? [];

  return (
    <div style={{ display:'flex', flexDirection:'column', height:'100dvh', background:'#f3f5f8', fontFamily:'Arial,Helvetica,sans-serif' }}>
      {/* Top bar: identity + nav + logout */}
      <div style={{ background:'#10263e', color:'white', flexShrink:0, display:'flex', alignItems:'center', gap:12, padding:'0 20px', flexWrap:'wrap' }}>
        {/* Brand identity */}
        <div style={{ display:'flex', alignItems:'center', gap:8, padding:'12px 0', flex:1, minWidth:200 }}>
          <Shield size={16} style={{ color:'#7c6df5' }} />
          <span style={{ fontWeight:800, fontSize:14, color:'#e0e0ff' }}>Administrador Global</span>
          <span style={{ color:'#8090b0', fontSize:12, marginLeft:4 }}>{email}</span>
        </div>

        {/* Section tabs */}
        <div style={{ display:'flex', gap:4 }}>
          <NavTab
            label="Empresas"
            icon={<Building2 size={15} />}
            active={section === 'companies'}
            count={companies.length}
            onClick={() => setSection('companies')}
          />
          <NavTab
            label="Operaciones"
            icon={<CalendarDays size={15} />}
            active={section === 'operations'}
            onClick={() => setSection('operations')}
          />
        </div>

        {/* Logout */}
        <button
          onClick={onLogout}
          style={{ display:'flex', alignItems:'center', gap:6, background:'none', border:'1px solid #2d3f5a', color:'#8090b0', borderRadius:7, padding:'6px 12px', cursor:'pointer', fontSize:12, marginLeft:'auto' }}
        >
          <LogOut size={13} /> Cerrar sesión
        </button>
      </div>

      {/* Section content */}
      <div style={{ flex:1, overflow:'auto' }}>
        {section === 'companies' ? (
          <CompanyManager
            companies={companies}
            isLoading={dataQ.isLoading}
            error={dataQ.error}
          />
        ) : (
          <AdminControl
            companies={companies}
            orders={orders}
            technicians={technicians}
          />
        )}
      </div>
    </div>
  );
}

function NavTab({
  label, icon, active, count, onClick,
}: {
  label: string; icon: React.ReactNode; active: boolean; count?: number; onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      style={{
        display:'flex', alignItems:'center', gap:6,
        background: active ? 'rgba(255,255,255,.12)' : 'none',
        border: active ? '1px solid rgba(255,255,255,.18)' : '1px solid transparent',
        borderRadius:7, padding:'8px 14px', cursor:'pointer',
        color: active ? '#fff' : '#8090b0',
        fontSize:13, fontWeight: active ? 700 : 400,
        fontFamily:'Arial,Helvetica,sans-serif',
      }}
    >
      {icon} {label}
      {count !== undefined && (
        <span style={{ background:'rgba(255,255,255,.18)', borderRadius:10, padding:'1px 6px', fontSize:11, marginLeft:2 }}>
          {count}
        </span>
      )}
    </button>
  );
}
