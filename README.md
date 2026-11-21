# Constelmec Maintenance

MVP mobile-first para mantenimiento de portones industriales.

## Estado
**Prototipo funcional con datos ficticios.** No está conectado a Supabase, no tiene autenticación ni sincronización offline. No utilizar con clientes ni registrar información sensible hasta implementar y verificar RLS, auditoría, almacenamiento privado y controles de acceso.

## Desarrollo local
```bash
npm install
npm run dev
```

## Stack
React 19, TypeScript, Vite. Preparado para PWA, Supabase y flujos auditables en próximas etapas.

## Flujos de demostración
- Técnico: seleccionar portón, iniciar visita, completar controles, registrar observación y cerrar visita.
- Cliente: consultar estado e historial ficticio y enviar una observación de demostración.
- Datos en memoria: los cambios se reinician al recargar.

## Próximas etapas
1. Supabase Auth, modelo multiempresa y RLS con pruebas de aislamiento.
2. Eventos de auditoría append-only, visitas e inspecciones versionadas.
3. QR, fotos privadas, IndexedDB offline y sincronización idempotente.
4. Informes PDF versionados, notificaciones y archivo seguro.
