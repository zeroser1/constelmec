import { useState } from 'react';
import { Building2, CalendarDays, MapPin } from 'lucide-react';
import AdminControl from './AdminControl';
import AppShell from './AppShell';
import CompanyManager from './CompanyManager';
import FacilityManager from './FacilityManager';
import { usePlatformAdminData } from './hooks/useRealData';

type Section = 'companies' | 'operations' | 'facilities';

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

  const companies   = dataQ.data?.companies   ?? [];
  const orders      = dataQ.data?.orders      ?? [];
  const technicians = dataQ.data?.technicians ?? [];

  const navItems = [
    { key: 'companies',  label: 'Empresas',      icon: Building2,   badge: companies.length > 0 ? companies.length : undefined },
    { key: 'operations', label: 'Operaciones',   icon: CalendarDays },
    { key: 'facilities', label: 'Instalaciones', icon: MapPin },
  ];

  return (
    <AppShell
      navItems={navItems}
      activeSection={section}
      onNavigate={k => setSection(k as Section)}
      brand="Admin Global"
      userEmail={email}
      onLogout={onLogout}
    >
      {section === 'companies' ? (
        <CompanyManager
          companies={companies}
          isLoading={dataQ.isLoading}
          error={dataQ.error}
        />
      ) : section === 'facilities' ? (
        <FacilityManager companies={companies} />
      ) : (
        <AdminControl
          companies={companies}
          orders={orders}
          technicians={technicians}
        />
      )}
    </AppShell>
  );
}
