# Constelmec Maintenance

Aplicación web progresiva (PWA) mobile-first para mantenimiento de portones industriales.

> **Estado: MVP de interfaz / demo técnica.** Aún no está listo para uso operativo con clientes. No hay autenticación, backend conectado, auditoría real ni persistencia de datos. Los datos de muestra y el cambio de roles son exclusivamente demostrativos.

## Ejecutar

Requiere Node.js 22.

```bash
npm install
npm run build
npm run dev
```

Abrí la URL local que muestra Vite. Para instalar como PWA, publicá en un dominio HTTPS compatible y abrí la opción de instalación del navegador.

## Estructura
- `src/`: panel técnico y portal cliente con flujos de demostración.
- `public/manifest.webmanifest`, `public/icon.svg`, `public/sw.js`: identidad PWA y caché de shell público.
- `supabase/migrations/`: migración SQL inicial **no aplicada**; requiere revisión de seguridad y pruebas.
- `docs/SECURITY.md`: límites de seguridad y requisitos antes de producción.
- `docs/ROADMAP.md`: avance y pendientes.
- `.github/workflows/ci.yml`: compilación y verificación de tipos en GitHub Actions.

## Reglas fundamentales
- Nunca guardar secretos en `VITE_*` o en GitHub.
- El código QR no concede acceso a información.
- El cliente no modifica inspecciones técnicas.
- El historial técnico será append-only y toda corrección estará atribuida a su autor.
- Cerrar una visita no levanta una condición fuera de servicio.
- No guardar ni cachear respuestas privadas en el service worker.

## Próximo hito
Conectar un proyecto Supabase con Auth, RLS probado, RPCs transaccionales de escritura y un entorno de hosting apto para uso comercial. Luego implementar offline, fotos privadas, informes y notificaciones.
