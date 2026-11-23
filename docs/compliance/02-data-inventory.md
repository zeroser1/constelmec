# Constelmec — Inventario de Datos Personales (Fase 2)

**Versión:** 0.2.0  
**Fecha:** 23/11/2026  
**Fase:** Fase 2 — Inventario de datos y flujos  
**Autor:** Auditoría automática (Claude Code — Frente 7)  
**Alcance:** Migraciones 001–010. Las migraciones están commiteadas pero NO aplicadas a producción.  
**Referencia:** [Fase 0 — Línea de base](./00-baseline.md) · GAP-01, GAP-02, GAP-05, GAP-11

---

## 1. Inventario campo a campo

### 1.1 `auth.users` — Gestionado por Supabase Auth (externo a migraciones)

| Campo | Tipo | Categoría | Finalidad | Retención | Compartido | Control de acceso | Riesgo |
|-------|------|-----------|-----------|-----------|------------|-------------------|--------|
| `id` | uuid | identity | Identificador único de usuario; FK en todas las tablas de la app | TBD (ver GAP-05) | none | Sólo service_role; la app recibe via JWT | Bajo |
| `email` | text | contact_info | Credencial de autenticación; identifica al usuario en el sistema | TBD (ver GAP-05) | none | Sólo service_role / `auth.uid()` vía RPC | Alto |
| `created_at` | timestamptz | behavioral | Timestamp de registro en la plataforma | TBD (ver GAP-05) | none | Sólo service_role | Bajo |
| `last_sign_in_at` | timestamptz | behavioral | Auditoría de último acceso | TBD (ver GAP-05) | none | Sólo service_role | Medio |
| `raw_user_meta_data` | jsonb | identity | Metadatos opcionales provistos en el sign-up | TBD (ver GAP-05) | none | Sólo service_role | Medio |

> **Nota:** `auth.users` es gestionado completamente por Supabase Auth. La aplicación no tiene control directo sobre la retención, encriptación en reposo, ni el ciclo de vida de estas filas. Ver sección 3.

---

### 1.2 `public.memberships`

| Campo | Tipo | Categoría | Finalidad | Retención | Compartido | Control de acceso | Riesgo |
|-------|------|-----------|-----------|-----------|------------|-------------------|--------|
| `user_id` | uuid | identity | Vincula un usuario autenticado a una empresa y rol | TBD (ver GAP-05) | none | Usuario ve sus propias filas (`user_id = auth.uid()`) | Medio |
| `role` | enum | behavioral | Define el nivel de acceso: admin / technician / customer | TBD (ver GAP-05) | none | Usuario ve sus propias filas | Bajo |
| `active` | boolean | behavioral | Indica si el acceso está habilitado | TBD (ver GAP-05) | none | Usuario ve sus propias filas | Bajo |
| `created_at` | timestamptz | behavioral | Fecha de asignación del acceso | TBD (ver GAP-05) | none | Usuario ve sus propias filas | Bajo |

---

### 1.3 `public.technician_profiles` — Mayor densidad PII

| Campo | Tipo | Categoría | Finalidad | Retención | Compartido | Control de acceso | Riesgo |
|-------|------|-----------|-----------|-----------|------------|-------------------|--------|
| `user_id` | uuid | identity | Vincula el perfil al usuario de auth; nullable (técnico sin cuenta app) | TBD (ver GAP-05) | none | Admin + platform_admin; técnico ve su propia fila (mig 010) | Medio |
| `first_name` | text | identity | Identificación del técnico para asignación de órdenes y trazabilidad | TBD (ver GAP-05) | none | Admin + platform_admin; técnico ve su propia fila | Alto |
| `last_name` | text | identity | Identificación del técnico para asignación de órdenes y trazabilidad | TBD (ver GAP-05) | none | Admin + platform_admin; técnico ve su propia fila | Alto |
| `work_phone` | text | contact_info | Contacto operacional para coordinación de visitas y emergencias | TBD (ver GAP-05) | none | Admin + platform_admin; técnico ve su propia fila | Medio |
| `work_email` | text | contact_info | Contacto alternativo; puede coincidir con email de auth | TBD (ver GAP-05) | none | Admin + platform_admin; técnico ve su propia fila | Medio |
| `specialty` | text | professional | Calificación técnica que determina asignación a tipos de trabajo | TBD (ver GAP-05) | none | Admin + platform_admin; técnico ve su propia fila | Bajo |
| `driving_authorized` | boolean | professional | Habilitación para conducir en tareas; dato de capacidad laboral | TBD (ver GAP-05) | none | Admin + platform_admin; técnico ve su propia fila | Medio |
| `license_expires_on` | date | professional | Vencimiento de licencia de conducir; impacta asignación de órdenes | TBD (ver GAP-05) | none | Admin + platform_admin; técnico ve su propia fila | **Alto** |
| `active` | boolean | behavioral | Estado de habilitación para recibir órdenes | TBD (ver GAP-05) | none | Admin + platform_admin; técnico ve su propia fila | Bajo |

> **Nota de riesgo:** `license_expires_on` es dato profesional sensible bajo Art. 7 Ley 25.326. Combinado con `first_name`/`last_name`, constituye un registro de capacidad laboral vinculado a una persona identificada.

---

### 1.4 `public.company_contacts`

| Campo | Tipo | Categoría | Finalidad | Retención | Compartido | Control de acceso | Riesgo |
|-------|------|-----------|-----------|-----------|------------|-------------------|--------|
| `first_name` | text | identity | Nombre del contacto operacional de la empresa cliente | TBD (ver GAP-05) | none | Solo admin + platform_admin | Alto |
| `last_name` | text | identity | Nombre del contacto operacional de la empresa cliente | TBD (ver GAP-05) | none | Solo admin + platform_admin | Alto |
| `category` | enum | professional | Rol funcional del contacto (commercial/administrative/technical/emergency/other) | TBD (ver GAP-05) | none | Solo admin + platform_admin | Bajo |
| `email` | text | contact_info | Email de contacto; puede ser personal o corporativo | TBD (ver GAP-05) | none | Solo admin + platform_admin | Alto |
| `phone` | text | contact_info | Teléfono de contacto; puede ser personal o laboral | TBD (ver GAP-05) | none | Solo admin + platform_admin | Medio |
| `notes` | text | contact_info | Campo de texto libre; puede contener datos sensibles no estructurados | TBD (ver GAP-05) | none | Solo admin + platform_admin | **Alto** |

---

### 1.5 `public.companies` — Datos de empresa (con campos potencialmente personales)

| Campo | Tipo | Categoría | Finalidad | Retención | Compartido | Control de acceso | Riesgo |
|-------|------|-----------|-----------|-----------|------------|-------------------|--------|
| `contact_name` | text | identity | Nombre del representante de la empresa; puede ser persona física | TBD (ver GAP-05) | none | Todos los miembros de la empresa | Medio |
| `contact_email` | text | contact_info | Email del representante; puede ser personal | TBD (ver GAP-05) | none | Todos los miembros de la empresa | Medio |
| `contact_phone` | text | contact_info | Teléfono del representante; puede ser personal | TBD (ver GAP-05) | none | Todos los miembros de la empresa | Bajo |
| `tax_id` (CUIT) | text | identity | CUIT/CUIL de la empresa; si es unipersonal, identifica a una persona física | TBD (ver GAP-05) | none | Todos los miembros de la empresa | **Alto** |
| `address` | text | contact_info | Domicilio fiscal; puede coincidir con domicilio personal si es unipersonal | TBD (ver GAP-05) | none | Todos los miembros de la empresa | Medio |

---

### 1.6 `public.service_order_technicians`

| Campo | Tipo | Categoría | Finalidad | Retención | Compartido | Control de acceso | Riesgo |
|-------|------|-----------|-----------|-----------|------------|-------------------|--------|
| `technician_id` | uuid | identity | FK a perfil de técnico asignado; vincula persona a orden de trabajo | TBD (ver GAP-05) | none | Admin + platform_admin; técnico ve sus propias filas (mig 010) | Medio |
| `role` | enum | behavioral | Rol en la orden (lead/support); refleja responsabilidad laboral | TBD (ver GAP-05) | none | Admin + platform_admin; técnico ve sus propias filas | Bajo |
| `assigned_at` | timestamptz | behavioral | Timestamp de asignación; trazabilidad de responsabilidad | TBD (ver GAP-05) | none | Admin + platform_admin; técnico ve sus propias filas | Bajo |
| `removed_at` | timestamptz | behavioral | Timestamp de remoción suave; historia de asignaciones | TBD (ver GAP-05) | none | Admin + platform_admin; técnico ve sus propias filas | Bajo |
| `removed_by` | uuid | behavioral | FK al usuario que removió al técnico; auditoría de gestión de personal | TBD (ver GAP-05) | none | Admin + platform_admin | Medio |
| `active` | boolean | behavioral | Estado de asignación; permite historial completo de reasignaciones | TBD (ver GAP-05) | none | Admin + platform_admin; técnico ve sus propias filas | Bajo |

---

### 1.7 `public.audit_events` — ⚠️ Contiene PII indirecta en payload

| Campo | Tipo | Categoría | Finalidad | Retención | Compartido | Control de acceso | Riesgo |
|-------|------|-----------|-----------|-----------|------------|-------------------|--------|
| `actor_user_id` | uuid | identity | Vincula cada evento a quien lo ejecutó; trazabilidad de acciones | TBD (ver GAP-05) | none | Admin + technician (vía RLS); sólo service_role puede escribir | Medio |
| `event_type` | text | behavioral | Tipo de evento (created/updated/assigned/etc.) | TBD (ver GAP-05) | none | Admin + technician | Bajo |
| `event_payload` | jsonb | mixed | **Contiene campos `before`/`after` que pueden incluir PII** (ej. email, phone de contacto actualizado — ver GAP-11) | TBD (ver GAP-05) | none | Admin + technician | **Alto** |
| `recorded_at` | timestamptz | behavioral | Timestamp del evento; append-only | TBD (ver GAP-05) | none | Admin + technician | Bajo |

> **GAP-11:** `event_payload` puede contener en sus campos `before`/`after` datos personales completos de los registros modificados (email, teléfono, nombre de contacto). Sin enmascaramiento. Riesgo: cualquier admin o técnico con acceso a audit_events puede extraer historial de datos PII que ya no están visibles en la tabla principal.

---

### 1.8 `public.customer_observations`

| Campo | Tipo | Categoría | Finalidad | Retención | Compartido | Control de acceso | Riesgo |
|-------|------|-----------|-----------|-----------|------------|-------------------|--------|
| `author_user_id` | uuid | identity | FK al usuario que escribió la observación; atribuye autoría | TBD (ver GAP-05) | none | Todos los miembros de la empresa (has_membership sin restricción de rol) | Bajo |
| `body` | text | behavioral | Texto libre de la observación del cliente; puede contener datos personales no estructurados | TBD (ver GAP-05) | none | Todos los miembros de la empresa | **Alto** |
| `created_at` | timestamptz | behavioral | Timestamp inmutable (trigger no-update) | TBD (ver GAP-05) | none | Todos los miembros de la empresa | Bajo |

---

## 2. Flujos de datos por categoría PII

> **Proveedor externo de infraestructura:** Supabase Inc. (BaaS + Auth + Storage) y Vercel Inc. (hosting/edge) procesan todos los datos como encargados de tratamiento. Ambos requieren DPA — ver GAP-DI-05 y verificación de Art. 12 Ley 25.326 en `01-compliance-matrix.md`.

| Categoría PII | Origen (quién crea) | Almacenamiento | Proveedor del dato | Finalidad | Permisos de acceso | Destino externo | Conservación |
|---------------|--------------------|-----------------|--------------------|-----------|-------------------|----------------|-------------|
| **identity** — nombres, email de auth | Usuario en sign-up (email); admin en RPCs (nombre/apellido técnico y contacto) | `auth.users`, `technician_profiles`, `company_contacts`, `companies` | Usuario (sign-up); administrador de empresa | Autenticación; identificación del técnico para asignación de órdenes; contacto operacional del cliente | Supabase Auth (email); admin + platform_admin (perfiles/contactos); técnico (propio perfil vía mig 010) | Supabase Inc. (infraestructura) · Vercel Inc. (hosting) — **sin cesión a terceros** | TBD — ver GAP-DI-02 y GAP-05 |
| **contact_info** — email operacional, teléfono, dirección | Admin vía RPCs: `admin_create_company_contact`, `admin_update_company`, `admin_create_technician_profile` | `company_contacts`, `technician_profiles`, `companies` | Administrador de empresa | Contacto operacional para coordinación de visitas; domicilio fiscal del cliente | Solo admin + platform_admin | Supabase Inc. · Vercel Inc. — **sin cesión** | TBD |
| **professional** — especialidad, licencia de conducir, habilitación laboral | Admin vía RPCs (`admin_create_technician_profile`) | `technician_profiles`, `service_order_technicians` | Administrador de empresa | Determinar capacidad del técnico para tipos de trabajo; historial de asignaciones laborales | Admin + platform_admin; técnico (propio perfil) | Supabase Inc. · Vercel Inc. — **sin cesión** | TBD — datos laborales sensibles (Art. 7 Ley 25.326) |
| **behavioral** — asignaciones, visitas, observaciones, auditoría | App vía triggers + RPCs (audit log inmutable) | `audit_events`, `service_order_technicians`, `customer_observations` (inventariados en Sección 1) | Sistema (triggers); usuarios autenticados (observaciones) | Trazabilidad de operaciones; historial de órdenes; rendición de cuentas contractual | Admin + technician (audit_events); todos los miembros de la empresa (observations) | Supabase Inc. · Vercel Inc. — **sin cesión** | TBD — `audit_events` inmutable por diseño; conflicto con derecho de supresión (ver GAP-05) |
| **technical** — tokens QR, rutas de Storage | Sistema vía RPC `admin_issue_gate_qr`; motor de reportes | `gate_qr_codes` (solo hash sha256, raw token no persiste), `report_versions` (storage_path) | Sistema | Control de acceso físico a portones; gestión de versiones de informes | Admin (paths); service_role (validación QR) | Supabase Inc. (Storage) · Vercel Inc. — **sin cesión** | TBD — QR revocado en re-emisión; storage_path sin bucket policy (ver GAP-01) |

---

## 3. Supabase Auth — Tratamiento especial

- **Qué gestiona Supabase:** tabla `auth.users` (email, `encrypted_password`, `email_confirmed_at`, `last_sign_in_at`, tokens de sesión, `raw_user_meta_data`).
- **Fuera del control directo de la app:** esquema, retención, encriptación en reposo, logs de sesión — todos son responsabilidad de Supabase Inc.
- **Implicancia para Ley 25.326:** Constelmec actúa como responsable del tratamiento; Supabase Inc. actúa como encargado del tratamiento. Se requiere cláusula DPA (Data Processing Agreement) con Supabase antes de operación comercial. No hay evidencia de DPA en el repositorio.
- **GAP-04 cross-ref:** `enable_confirmations = false` en `config.toml:234` — usuarios pueden autenticarse con email no verificado. Supabase emite JWT para cualquier email registrado sin validar que el titular controla ese correo.
- **Región de datos:** configurable en Supabase dashboard; no determinada desde el repositorio. Si la región es fuera de Argentina, Art. 12 Ley 25.326 requiere habilitación previa de AAIP para transferencia internacional.

---

## 4. Brechas específicas de inventario de datos

| ID | Brecha | Tablas afectadas | Normativa | Riesgo |
|----|--------|-----------------|-----------|--------|
| **GAP-DI-01** | **Sin base legal documentada por campo** — ningún campo tiene registrada la base legal de tratamiento (consentimiento, contrato, interés legítimo). Requisito AAIP para registro de bases de datos. | Todas | Art. 3 y 5 Ley 25.326 | Crítico |
| **GAP-DI-02** | **Sin política de retención** — no existe un plazo de retención definido para ninguna tabla. `audit_events` y registros de visitas pueden acumularse indefinidamente. | Todas (esp. `audit_events`, `visits`, `technician_profiles`) | Art. 4 inc. 7, Art. 6 Ley 25.326 | Alto |
| **GAP-DI-03** | **`event_payload` sin enmascaramiento de PII** — los campos `before`/`after` en audit_events contienen snapshots completos de filas que incluyen email, teléfono y nombre. Cualquier admin con acceso puede extraer PII histórica. | `audit_events` | Art. 9 Ley 25.326 (medidas de seguridad) | Alto |
| **GAP-DI-04** | **`company_contacts.notes` y `customer_observations.body` sin validación de contenido sensible** — campos de texto libre pueden capturar PII no estructurada (DNI, datos médicos, domicilio personal) sin clasificación ni protección adicional. | `company_contacts`, `customer_observations` | Art. 7 Ley 25.326 (datos sensibles) | Medio |
| **GAP-DI-05** | **Sin DPA con Supabase Inc.** — tratamiento de datos PII delegado a proveedor sin contrato de encargado de tratamiento documentado. | `auth.users` + toda la DB | Art. 8 Ley 25.326 / Art. 28 GDPR-equivalent | Crítico |

---

*Documento generado automáticamente a partir del estado del repositorio. No contiene datos de producción ni credenciales.*
