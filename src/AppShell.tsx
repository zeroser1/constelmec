import { useState } from 'react';
import type { ComponentType, ReactNode } from 'react';
import { ChevronLeft, ChevronRight, LogOut, Menu } from 'lucide-react';
import ThemeSwitch from './ThemeSwitch';
import logo from './assets/logo.png';
import './AppShell.css';

export type NavItem = {
  key: string;
  label: string;
  icon: ComponentType<{ size?: number }>;
  badge?: number;
};

type Props = {
  navItems: NavItem[];
  activeSection: string;
  onNavigate: (key: string) => void;
  brand?: string;
  userEmail: string;
  onLogout: () => void;
  children: ReactNode;
};

export default function AppShell({
  navItems,
  activeSection,
  onNavigate,
  brand = 'CONSTELMEC',
  userEmail,
  onLogout,
  children,
}: Props) {
  const [collapsed, setCollapsed] = useState(false);
  const [mobileOpen, setMobileOpen] = useState(false);

  const closeMobile = () => setMobileOpen(false);

  return (
    <div className="appshell-root">
      {/* Mobile topbar strip */}
      <button
        className="appshell-hamburger"
        onClick={() => setMobileOpen(true)}
        aria-label="Abrir menú"
      >
        <Menu size={20} />
        {brand}
      </button>

      {/* Mobile backdrop overlay */}
      {mobileOpen && (
        <div className="appshell-overlay" onClick={closeMobile} aria-hidden />
      )}

      {/* Sidebar */}
      <aside
        className={[
          'appshell-sidebar',
          collapsed ? 'collapsed' : '',
          mobileOpen ? 'mobile-open' : '',
        ].filter(Boolean).join(' ')}
      >
        {/* Brand */}
        <div className="appshell-brand">
          <img src={logo} alt="Constelmec" className="appshell-brand-logo" />
          <div className="appshell-brand-text">
            <div className="appshell-brand-name">{brand}</div>
            <div className="appshell-brand-sub">{userEmail}</div>
          </div>
        </div>

        {/* Nav items */}
        <nav className="appshell-nav" aria-label="Navegación principal">
          {navItems.map(({ key, label, icon: Icon, badge }) => (
            <button
              key={key}
              className={['appshell-nav-btn', activeSection === key ? 'active' : ''].filter(Boolean).join(' ')}
              onClick={() => { onNavigate(key); closeMobile(); }}
            >
              <span className="appshell-nav-btn-icon"><Icon size={18} /></span>
              <span className="appshell-nav-btn-label">{label}</span>
              {badge !== undefined && (
                <span className="appshell-nav-badge">{badge}</span>
              )}
            </button>
          ))}
        </nav>

        {/* Footer: theme toggle + logout */}
        <div className="appshell-footer">
          <ThemeSwitch />
          <button className="appshell-logout-btn" onClick={onLogout}>
            <LogOut size={16} />
            <span className="appshell-logout-label">Cerrar sesión</span>
          </button>
        </div>

        {/* Desktop collapse toggle */}
        <button
          className="appshell-collapse-btn"
          onClick={() => setCollapsed(c => !c)}
          aria-label={collapsed ? 'Expandir menú' : 'Colapsar menú'}
        >
          {collapsed ? <ChevronRight size={16} /> : <ChevronLeft size={16} />}
          <span className="appshell-collapse-label">{collapsed ? '' : 'Colapsar'}</span>
        </button>
      </aside>

      {/* Main content */}
      <main className="appshell-content">
        {children}
      </main>
    </div>
  );
}
