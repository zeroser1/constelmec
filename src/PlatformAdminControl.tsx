import { LogOut, Shield } from 'lucide-react';
import AdminControl from './AdminControl';
import { usePlatformAdminData } from './hooks/useRealData';

export default function PlatformAdminControl({ userId, email, onLogout }: { userId: string; email: string; onLogout: () => void }) {
  const dataQ = usePlatformAdminData(userId);

  if (dataQ.isLoading) return <div className="real-shell"><div className="real-panel"><p>Cargando vista global...</p></div></div>;
  if (dataQ.error) return <div className="real-shell"><div className="real-panel"><p>Error: {dataQ.error instanceof Error ? dataQ.error.message : 'Error desconocido'}</p></div></div>;

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100dvh' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 16px', background: '#1a1a2e', color: '#a0a0c0', fontSize: 13, flexShrink: 0 }}>
        <Shield size={15} style={{ color: '#7c6df5' }} />
        <span style={{ color: '#e0e0ff', fontWeight: 600 }}>Administrador Global</span>
        <span style={{ opacity: 0.6 }}>{email}</span>
        <span style={{ opacity: 0.4, margin: '0 4px' }}>·</span>
        <span style={{ opacity: 0.7 }}>{dataQ.data?.companies.length ?? 0} empresas</span>
        <button
          onClick={onLogout}
          style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 6, background: 'none', border: '1px solid #333', color: '#a0a0c0', borderRadius: 6, padding: '4px 10px', cursor: 'pointer', fontSize: 12 }}
        >
          <LogOut size={13} /> Cerrar sesión
        </button>
      </div>
      <AdminControl
        companies={dataQ.data?.companies ?? []}
        orders={dataQ.data?.orders ?? []}
        technicians={dataQ.data?.technicians ?? []}
      />
    </div>
  );
}
