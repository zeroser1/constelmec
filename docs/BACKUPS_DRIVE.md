# CONSTELMEC — backups cifrados Supabase → Google Drive

**Estado inicial: preparado, NO activado.** El cron empieza únicamente después de integrar el PR a la rama por defecto, configurar secretos y verificar un primer PASS manual. No sustituye la comprobación de un backup previo al release del PR #9.

## Destino y alcance

- Google Drive: CONSTELMEC_DATA/07_BACKUPS_SUPABASE
- Carpeta: https://drive.google.com/drive/folders/1KRTJuK_fcilZ72pAda4UQTAZ_L4xaDUQ
- Proyecto fijo: xpguxfttlxqpdlbhsjud (producción); el script rechaza otros SUPABASE_URL.
- Diario a las **06:00 UTC (03:00 Argentina)**, más ejecución manual en GitHub Actions. GitHub puede retrasar el cron.
- Roles, esquema y datos SQL mediante Supabase CLI v2; descarga de todos los buckets y objetos de Supabase Storage accesibles con la clave de servicio.
- ZIP AES-256 con contraseña fuerte; manifiesto con tamaños y SHA-256; comprobación local de ZIP y de tamaño/MD5 del archivo remoto en Drive.
- Los respaldos anteriores **no se eliminan automáticamente**. Definir retención después de medir volumen.

## Activación

En GitHub → zeroser1/constelmec → Settings → Secrets and variables → Actions, crear los siguientes **Repository secrets**:

| Secreto | Valor |
| --- | --- |
| SUPABASE_DB_URL | Connection string PostgreSQL de producción (Supabase → Connect) |
| SUPABASE_URL | https://xpguxfttlxqpdlbhsjud.supabase.co |
| SUPABASE_SERVICE_ROLE_KEY | Clave de servidor de producción; nunca usarla en el frontend |
| GDRIVE_CLIENT_ID | Client ID de una app OAuth de Google Cloud |
| GDRIVE_CLIENT_SECRET | Client secret de esa app OAuth |
| GDRIVE_REFRESH_TOKEN | Refresh token del propietario de Drive, acceso offline y scope https://www.googleapis.com/auth/drive |
| BACKUP_ENCRYPTION_PASSWORD | Contraseña aleatoria de 32+ caracteres, guardada también fuera de GitHub |

Para Google: habilitar Google Drive API, configurar pantalla de consentimiento OAuth y obtener un refresh token con el flujo OAuth legítimo. Una app en modo Testing puede generar tokens de corta duración; configurar el estado de publicación adecuado. Mantener la carpeta privada.

**Las credenciales del conector Google Drive de ChatGPT no se pueden reutilizar automáticamente desde GitHub Actions.** Nunca copiar tokens ni claves en un chat ni commitearlos.

Después del merge del PR, ejecutar Actions → CONSTELMEC encrypted Supabase backup to Drive → Run workflow. Comprobar PASS y que el ZIP aparezca en Drive. Descargar y descifrar con la contraseña guardada fuera de GitHub. Repetir tras rotar credenciales.

## Recuperación

1. Descargar el ZIP desde Drive y descifrarlo con 7-Zip u otra herramienta compatible con ZIP AES-256.
2. Revisar manifest.json y comprobar los SHA-256 de los archivos extraídos.
3. Crear un proyecto Supabase de recuperación aislado. Nunca restaurar directamente sobre producción sin ensayo y autorización.
4. Restaurar roles.sql, schema.sql y data.sql siguiendo la guía oficial y atendiendo a extensiones/configuración del proyecto.
5. Reimportar los archivos storage/<bucket>/<path> a los buckets respectivos conservando rutas y permisos.
6. Verificar auth.users, conteos de tablas, Storage, RLS, RPC, órdenes e historial. Proveedores OAuth, SMTP, Edge Functions, secretos y Vercel requieren respaldo/configuración aparte.

Referencia: https://supabase.com/docs/guides/self-hosting/restore-from-platform

## Límites

- SQL y Storage se capturan secuencialmente; no constituyen un snapshot atómico entre servicios. Coordinar ventana sin escrituras para un pre-release.
- Supabase CLI excluye esquemas internos administrados. No es una copia física de toda la plataforma.
- No incluye configuración externa de Vercel, secretos, SMTP, proveedores OAuth o repositorio GitHub.
- Verificar integridad **no es** ensayar una restauración. Hacer una restauración de prueba antes de depender de esto como único backup.
- Fallará ante secretos faltantes, URL de proyecto incorrecta, descarga fallida o inconsistencia de Drive. Supervisar las alertas de GitHub Actions.
