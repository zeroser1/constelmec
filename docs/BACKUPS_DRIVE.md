# CONSTELMEC — backups cifrados Supabase → Google Drive

**Estado: PR en borrador, solo ejecución manual, no se ha realizado un backup real.** La programación automática está deshabilitada hasta verificar una restauración. No habilitar release PR #9 sin copia recuperable validada.

## Página pública para OAuth (GitHub Pages)

- Página principal: `https://zeroser1.github.io/constelmec/`
- Política de privacidad: `https://zeroser1.github.io/constelmec/privacy.html`
- Archivos: `backup-site/index.html` y `backup-site/privacy.html`.
- Workflow: `.github/workflows/backup-pages.yml` publica **solamente** `backup-site/`.
- **Para activar:** después del merge, ir a GitHub → Settings → Pages → Build and deployment → Source **GitHub Actions**; ejecutar `Publish CONSTELMEC Backup OAuth info` si no se ejecuta automáticamente. Comprobar que ambas URL cargan antes de usarlas en Google OAuth.
- En Google Auth Platform → Información de marca: colocar las URL públicas de inicio y privacidad. Para dominios autorizados/verificación, seguir lo que Google solicite; puede requerir verificación de propiedad. No inventar URL ni asumir que publicar elimina los requisitos de verificación.

## Permisos mínimos de Google Drive

**Solicitar solamente** `https://www.googleapis.com/auth/drive.file`, NO `https://www.googleapis.com/auth/drive`. El permiso `drive.file` permite administrar archivos/carpetas creados por la aplicación o autorizados explícitamente para ella.

**Importante:** el folder `CONSTELMEC_DATA/07_BACKUPS_SUPABASE` creado anteriormente con otro cliente OAuth **no es automáticamente accesible** con `drive.file`. Para respetar el permiso mínimo, la primera ejecución crea una carpeta nueva llamada `CONSTELMEC_BACKUPS_AUTOMATICOS` en Mi unidad. El administrador puede mover manualmente esa carpeta dentro de `CONSTELMEC_DATA/07_BACKUPS_SUPABASE`. La carpeta creada por la aplicación conserva el acceso de `drive.file`; no reemplazarla ni borrarla sin adaptar la configuración. Se identifica con `appProperties.constelmec_backup=production`.

**OAuth externo en Testing:** refresh tokens para scopes Drive suelen expirar a los 7 días. Antes de depender del cron diario, pasar a producción cuando Google lo permita; pueden existir avisos o requisitos de verificación. No solicitar secretos en un chat.

## Obtener token OAuth en tu propia PC (una sola vez)

**Precondición:** Google Auth Platform → Público indica **En producción**, y en Acceso a los datos quedó solo el permiso `drive.file`. El estado de publicación no garantiza que Google haya completado verificaciones que eventualmente exija.

1. En Google Auth Platform → Clientes, descargá el JSON del cliente OAuth **Aplicación de escritorio** y guardalo en una carpeta privada de tu computadora (por ejemplo, Descargas). Nunca lo agregues al repositorio.
2. Descargá la rama de este PR en tu PC, o al menos `scripts/authorize_drive.py` y `scripts/authorize-requirements.txt`.
3. Instalá Python 3.12+ en Windows. En PowerShell, dentro del directorio del repositorio:

   `py -m pip install -r scripts/authorize-requirements.txt`

4. Ejecutá (reemplazá la ruta por la ubicación real del JSON):

   `py scripts/authorize_drive.py "$env:USERPROFILE\Downloads\client_secret.json"`

5. Se abrirá Google en el navegador. Elegí la cuenta autorizada de CONSTELMEC y aprobá el permiso `drive.file`. Si Google advierte que la app no está verificada, revisá que sea el proyecto que vos creaste; no ignores bloqueos de seguridad ni compartas credenciales.
6. El script mostrará **GDRIVE_CLIENT_ID**, **GDRIVE_CLIENT_SECRET** y **GDRIVE_REFRESH_TOKEN**. Copiá cada valor **directamente** a GitHub → Settings → Secrets and variables → Actions → New repository secret. **No pegues los valores en ChatGPT, tickets, mensajes ni archivos versionados.**
7. Cerrá la terminal. Borrá de Descargas cualquier copia innecesaria del JSON y no guardes capturas del token. Si el token se expone, revocalo y generá otro.

Si Python no está instalado, instalalo desde [python.org](https://www.python.org/downloads/) y verificá `py --version`.

**Importante:** esta autorización no ejecuta el backup; aún deben configurarse los otros secretos, revisar el PR, ejecutar la primera copia manual y ensayar restauración.

## Configuración de GitHub Actions

Crear 7 **Repository secrets** en `zeroser1/constelmec → Settings → Secrets and variables → Actions`:

| Secreto | Descripción |
| --- | --- |
| `SUPABASE_DB_URL` | Connection string PostgreSQL del proyecto de producción (Supabase → Connect) |
| `SUPABASE_URL` | `https://xpguxfttlxqpdlbhsjud.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | Clave privada del servidor de Supabase producción |
| `GDRIVE_CLIENT_ID` | Client ID de Google OAuth Desktop |
| `GDRIVE_CLIENT_SECRET` | Client secret de Google OAuth Desktop |
| `GDRIVE_REFRESH_TOKEN` | Refresh token de la cuenta autorizada con scope **drive.file** y `access_type=offline` |
| `BACKUP_ENCRYPTION_PASSWORD` | Contraseña aleatoria de 32+ caracteres guardada también fuera de GitHub |

No publicar tokens, claves, passwords, dumps ni archivos JSON de OAuth. La autorización del conector Drive de ChatGPT no se comparte con GitHub Actions.

## Ejecución y verificación

- **Fase de validación:** solo ejecución manual `workflow_dispatch`; sin `schedule` ni cron activo. Una vez verificada una restauración aislada, se podrá proponer otro cambio para habilitar el cron diario **06:00 UTC / 03:00 Buenos Aires**.
- Dump Supabase CLI v2: `roles.sql`, `schema.sql`, `data.sql`.
- Descarga de todos los objetos Storage accesibles; compresión y cifrado ZIP AES-256.
- Manifiesto con SHA-256, test de ZIP local, subida resumable y verificación remota por tamaño y MD5.
- **No se eliminan backups antiguos automáticamente**; evaluar retención tras medir consumo.
- Luego de integrar el PR, ejecutar manualmente el workflow y confirmar `PASS` en Actions y archivo ZIP en Drive.
- Descargar el ZIP y hacer **restauración de prueba en un proyecto aislado**. El checksum no demuestra por sí solo que una restauración funcione.

## Recuperación

1. Descargar el ZIP, descifrar con 7-Zip o herramienta compatible con AES ZIP.
2. Comprobar `manifest.json` y hashes SHA-256.
3. Restaurar SQL a un proyecto de recuperación aislado siguiendo [guía Supabase](https://supabase.com/docs/guides/self-hosting/restore-from-platform).
4. Restaurar manualmente objetos `storage/<bucket>/<path>`, conservando rutas y políticas.
5. Validar usuarios, datos, RLS, órdenes, inspecciones y fotos. Configuración de Auth, secretos, Edge Functions, Vercel y SMTP se respaldan por separado.

## Límites y seguridad

- SQL y Storage se capturan secuencialmente, **no** como snapshot atómico. Para un release crítico, detener escrituras durante la copia o usar un snapshot oficial.
- Supabase CLI excluye ciertos esquemas internos gestionados; no equivale a una imagen completa del proyecto.
- El scope `drive.file` no da acceso automático a carpetas creadas por otra aplicación.
- Google OAuth en Testing puede hacer caducar tokens; verificar publicación antes de habilitar cron.
- Los backups pueden contener información sensible. Nunca guardar el archivo ZIP en un repositorio público ni publicar su contraseña.
