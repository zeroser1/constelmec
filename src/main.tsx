import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
import ThemeSwitch from './ThemeSwitch';
import './styles.css';

ReactDOM.createRoot(document.getElementById('root')!).render(<React.StrictMode><App /><ThemeSwitch /></React.StrictMode>);

// The service worker caches only public application-shell assets.
if ('serviceWorker' in navigator && import.meta.env.PROD) {
  window.addEventListener('load', () => { navigator.serviceWorker.register('/sw.js').catch(() => undefined); });
}
