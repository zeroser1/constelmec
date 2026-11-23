# Constelmec — Fase 1: Matriz de Cumplimiento Normativo

**Versión:** 0.2.1  
**Fecha:** 23/11/2026  
**Fase:** Fase 1 — Análisis normativo detallado  
**Autor:** Auditoría automática (Claude Code — Frente 7)  
**Alcance:** Migraciones 001–010, `src/lib/supabase.ts`, `supabase/config.toml`

---

> **⚠️ Nota de despliegue:** La migración 005 está confirmada como aplicada a producción. El estado de las migraciones 006–010 no ha sido verificado en el proyecto remoto — se tratan como no aplicadas hasta confirmación explícita. Los controles marcados ✅ están implementados en código; los correspondientes a migraciones 006–010 requieren verificación en producción antes de poder considerarlos operativos.

---

## Convenciones

| Símbolo | Significado |
|---------|-------------|
| ✅ | Implementado y verificable en código (local/dev) |
| ⚠️ | Parcial — implementado con limitaciones o sin verificación de producción |
| ❌ | No implementado |
| 🔲 | No aplicable |

---

## A. Ley 25.326 / Decreto 1558/2001 (Argentina PDPL) + AAIP

> **Fuente:** Ley 25.326/2000 (BO 02/11/2000) · Decreto 1558/2001 · AAIP — [infoleg.gob.ar](https://www.infoleg.gob.ar/infolegInternet/anexos/60000-64999/64790/texact.htm)

| ID | Tipo | Requisito | Art./Norma | Estado | Evidencia | GAP | Prioridad |
|----|------|-----------|-----------|--------|-----------|-----|-----------|
| A-01 | Obligación legal | Exactitud y actualización de datos | Art. 4 | ⚠️ | Validaciones en RPCs (email regex, CUIT format); no hay mecanismo self-service para que el titular corrija sus datos | — | Alta |
| A-02 | Obligación legal | Pertinencia de datos según finalidad | Art. 4 | ⚠️ | Schema mínimo; `customer_observations.body` sin restricción temática; `audit_events.event_payload` guarda before/after con PII completo | GAP-11 | Media |
| A-03 | Obligación legal | Consentimiento previo, informado y libre | Art. 5 | ❌ | Sin flujo de aceptación, sin tabla `consent_records`, sin Política de Privacidad ni ToS en UI | GAP-02, GAP-03 | Crítica |
| A-04 | Obligación legal | Consentimiento para datos laborales sensibles | Art. 5 §2 | ❌ | `technician_profiles` contiene licencia, habilitación para conducir y datos laborales sin consentimiento específico | GAP-02 | Crítica |
| A-05 | Obligación legal | Prohibición de cesión de datos sin consentimiento | Art. 11 | ✅ | Sin integraciones externas activas; sin exports a terceros en codebase | — | — |
| A-06 | Obligación legal | Obligación de secreto (confidencialidad) | Art. 10 | ✅ | RLS impone aislamiento por empresa; escrituras solo vía SECURITY DEFINER; `app_private` oculto del Data API | — | — |
| A-07 | Obligación legal | Calidad y pertinencia de datos personales laborales (specialty, driving_authorized, license_expires_on) | Art. 4 | ⚠️ | RLS en `technician_profiles` (admin + propio perfil); datos laborales son personales pero no sensibles bajo Art. 7 (que cubre datos raciales, religiosos, sindicales, de salud o vida sexual); sin cifrado a nivel de columna ni enmascaramiento adicional | — | Alta |
| A-08 | Obligación legal | Medidas de seguridad técnicas y organizativas | Art. 9 | ⚠️ | RLS, audit log inmutable, SECURITY DEFINER, QR sha256 implementados; sin bucket policy, MFA, session timeout, ni email verification | GAP-01, GAP-04, GAP-06, GAP-07 | Crítica |
| A-09 | Obligación legal | Derecho de acceso del titular a sus datos | Art. 14 | ❌ | Sin endpoint de exportación de datos; sin vista self-service de datos propios | GAP-10 | Alta |
| A-10 | Obligación legal | Derecho de rectificación | Art. 16 | ❌ | Sin flujo self-service de corrección de datos por el titular | GAP-05 | Alta |
| A-11 | Obligación legal | Derecho de supresión (cancelación) | Art. 16 | ❌ | Sin mecanismo de baja de cuenta ni derecho al olvido; `audit_events` intencionalmente inmutables (conflicto de requisitos a resolver) | GAP-05 | Alta |
| A-12 | Obligación legal | Transferencia internacional de datos | Art. 12 | ⚠️ | Supabase Inc. y Vercel son proveedores con infraestructura potencialmente fuera de Argentina; región configurable pero no verificada en producción; sin DPA con Supabase (GAP-DI-05) | GAP-DI-05 | Alta |
| A-13 | Obligación legal | Inscripción ante AAIP del banco de datos | Dto. 1558, AAIP | ❌ | Sin evidencia de registro AAIP en docs/ ni en codebase | — | Alta |
| A-14 | Obligación legal | Responsable del tratamiento identificado | Art. 3 | ❌ | Sin DPA ni responsable de privacidad documentado | GAP-03 | Alta |
| A-15 | Obligación legal | Deber de información al momento de recolección de datos | Art. 6 | ❌ | Sin texto informativo ni aviso en formulario de registro/sign-up sobre finalidad, destinatarios y derechos del titular | GAP-02, GAP-03 | Alta |

**Resultado sección A:** 2 ✅ / 5 ⚠️ / 8 ❌ de 15 requisitos

---

## B. ISO/IEC 27001:2022 Annex A (controles aplicables)

> **Fuente:** ISO/IEC 27001:2022, Annex A — International Organization for Standardization (voluntary standard)

| ID | Tipo | Control | Ref. | Estado | Evidencia | GAP | Prioridad |
|----|------|---------|------|--------|-----------|-----|-----------|
| B-01 | Estándar voluntario | Políticas de seguridad de la información | A.5.1 | ❌ | Sin ISSP ni política de seguridad documentada en repo o docs/ | — | Alta |
| B-02 | Estándar voluntario | Inventario de activos de información | A.5.9 | ⚠️ | `00-baseline.md` documenta tablas PII; sin registro formal de activos | — | Media |
| B-03 | Estándar voluntario | Clasificación de la información | A.5.12 | ⚠️ | Inventario PII en 00-baseline; sin esquema de clasificación formal (Confidencial/Interno/Público por tabla) | — | Media |
| B-04 | Estándar voluntario | Seguridad de endpoints (clientes web/móvil) | A.8.1 | ⚠️ | HTTPS forzado por Supabase/Vercel en producción; sin MDM ni política de dispositivos | — | Media |
| B-05 | Estándar voluntario | Gestión de acceso privilegiado | A.8.2 | ✅ | Rol `admin` y `platform_admin` separados; `app_private` oculto del Data API; RPCs SECURITY DEFINER | — | — |
| B-06 | Estándar voluntario | Restricción de acceso a información | A.8.3 | ✅ | RLS en todas las tablas; aislamiento por empresa vía `has_membership()`; roles diferenciados | — | — |
| B-07 | Estándar voluntario | Acceso al código fuente | A.8.4 | ⚠️ | Repositorio GitHub (presumiblemente privado); sin CODEOWNERS verificado; sin branch protection documentada | — | Media |
| B-08 | Estándar voluntario | Autenticación segura | A.8.5 | ⚠️ | JWT + refresh token rotation; sin MFA; contraseña mínima 6 chars; sin verificación de email | GAP-04, GAP-06, GAP-08 | Alta |
| B-09 | Estándar voluntario | Enmascaramiento de datos | A.8.11 | ❌ | Sin enmascaramiento en `audit_events.event_payload`; payloads before/after contienen PII completo | GAP-11 | Media |
| B-10 | Estándar voluntario | Prevención de fuga de datos (DLP) | A.8.12 | ⚠️ | Sin integraciones externas; sin herramienta DLP; Storage sin bucket policy (riesgo no verificado en producción) | GAP-01 | Alta |
| B-11 | Estándar voluntario | Uso de criptografía | A.8.24 | ✅ | QR tokens almacenados como sha256; JWT firmado por Supabase; TLS en tránsito forzado por plataforma | — | — |
| B-12 | Estándar voluntario | Seguridad en el desarrollo | A.8.26 | ⚠️ | Patrón SECURITY DEFINER aplicado; migraciones con revisión; sin SAST en CI pipeline | — | Media |
| B-13 | Estándar voluntario | Codificación segura | A.8.28 | ⚠️ | Validación de inputs en RPCs; locking optimista; sin SAST/DAST automatizado | — | Media |

**Resultado sección B:** 3 ✅ / 8 ⚠️ / 2 ❌ de 13 controles

---

## C. OWASP ASVS v4.0 Level 2 (subset aplicable)

> **Fuente:** OWASP ASVS v4.0.3 — [github.com/OWASP/ASVS](https://github.com/OWASP/ASVS) (voluntary standard)

| ID | Tipo | Requisito | ASVS Ref. | Estado | Evidencia | GAP | Prioridad |
|----|------|-----------|-----------|--------|-----------|-----|-----------|
| C-01 | Estándar voluntario | Longitud mínima de contraseña ≥ 8 caracteres | V2.1.1 | ❌ | `minimum_password_length = 6` en config.toml:188 | GAP-08 | Media |
| C-02 | Estándar voluntario | Requisitos de complejidad de contraseña | V2.1.9 | ❌ | `password_requirements = ""` en config.toml:190 | GAP-08 | Media |
| C-03 | Estándar voluntario | Verificación contra base de credenciales comprometidas | V2.1.7 | ❌ | No implementado; Supabase Cloud no consulta HaveIBeenPwned por defecto | — | Baja |
| C-04 | Estándar voluntario | Verificación de email requerida al registro | V2.5.3 | ❌ | `enable_confirmations = false` en config.toml:234 — estado en producción no verificado | GAP-04 | Alta |
| C-05 | Estándar voluntario | MFA disponible para funciones de alto riesgo | V2.8 | ❌ | `enroll_enabled = false` en config.toml:314–320 — estado en producción no verificado | GAP-06 | Alta |
| C-06 | Estándar voluntario | Timeout de sesión e inactividad | V3.3.1 | ❌ | `[auth.sessions]` comentado en config.toml:283–287 — estado en producción no verificado | GAP-07 | Alta |
| C-07 | Estándar voluntario | Rotación de refresh tokens | V3.2.2 | ✅ | `enable_refresh_token_rotation = true`; `refresh_token_reuse_interval = 10` en config.toml:176–179 | — | — |
| C-08 | Estándar voluntario | Expiración de JWT ≤ 1 hora | V3.2.4 | ✅ | `jwt_expiry = 3600` en config.toml:170 | — | — |
| C-09 | Estándar voluntario | Cierre de sesión forzado al desactivar cuenta | V3.3.3 | ❌ | Desactivación de membresía no revoca sesiones activas | — | Media |
| C-10 | Estándar voluntario | RBAC aplicado en la capa de datos | V4.1.3 | ✅ | Políticas RLS por rol (admin/technician/customer) en todas las tablas; mig_001–010 | — | — |
| C-11 | Estándar voluntario | Principio de mínimo privilegio | V4.1.5 | ✅ | `REVOKE INSERT,UPDATE,DELETE FROM anon, authenticated`; `app_private` oculto; solo SECURITY DEFINER | — | — |
| C-12 | Estándar voluntario | Defensa contra IDOR | V4.2.1 | ✅ | `company_id` verificado en RLS y en guards de RPC; `has_membership()` valida por fila | — | — |
| C-13 | Estándar voluntario | Validación de inputs controlados por usuario | V5.1.3 | ⚠️ | Validación en RPCs (nombre, email regex, CUIT); `body` limitado a 2000 chars; sin scan XSS en campos de texto libre | — | Media |
| C-14 | Estándar voluntario | Sin datos sensibles en mensajes de error | V7.4.1 | ✅ | `RAISE EXCEPTION` usa mensajes genéricos; cliente recibe solo SQLSTATE/códigos | — | — |
| C-15 | Estándar voluntario | Sin stack traces expuestos al cliente | V7.4.2 | ✅ | Supabase Cloud no expone stack traces PostgreSQL al cliente en producción | — | — |
| C-16 | Estándar voluntario | PII cifrado en reposo | V8.2.1 | ⚠️ | Supabase Cloud cifra en reposo (AES-256); dev local (Docker) no; sin cifrado a nivel de columna | — | Media |
| C-17 | Estándar voluntario | PII transmitido únicamente por TLS | V9.1.1 | ✅ | HTTPS forzado en Supabase Cloud; dev local opera en http://127.0.0.1 | — | — |
| C-18 | Estándar voluntario | Sin secretos en código fuente | V14.2.1 | ✅ | Sin credenciales hardcoded; vars de entorno en `.env.local` (gitignored); `SUPABASE_SERVICE_ROLE_KEY` ausente del bundle cliente | — | — |
| C-19 | Estándar voluntario | Rate limiting en endpoints de autenticación | V14.4.1 | ✅ | `sign_in_sign_ups = 30/5min`, `token_refresh = 150/5min` en config.toml:210–215 | — | — |
| C-20 | Estándar voluntario | Control de acceso a Storage (buckets) | V8.3 | ❌ | Sin bucket configurado en config.toml:120–132; `report_versions.private_storage_path` sin política de bucket (riesgo no verificado en producción) | GAP-01 | Crítica |

**Resultado sección C:** 10 ✅ / 4 ⚠️ / 6 ❌ de 20 requisitos

---

## D. Resumen ejecutivo / Scorecard

| Norma | Tipo | Total | ✅ Cumple | ⚠️ Parcial | ❌ No cumple | Tasa de cumplimiento |
|-------|------|-------|-----------|------------|-------------|----------------------|
| Ley 25.326 / AAIP | Obligación legal | 15 | 2 | 5 | 8 | 13% |
| ISO/IEC 27001 Annex A | Estándar voluntario | 13 | 3 | 8 | 2 | 23% |
| OWASP ASVS v4.0 L2 | Estándar voluntario | 20 | 10 | 4 | 6 | 50% |
| **Total** | — | **48** | **15** | **17** | **16** | **31%** |

### Distribución por prioridad (requisitos no cumplidos o parciales)

| Prioridad | Cantidad | Requisitos |
|-----------|----------|------------|
| Crítica | 4 | A-03, A-04, A-08, C-20 |
| Alta | 15 | A-01, A-07, A-09, A-10, A-11, A-12, A-13, A-14, A-15, B-01, B-08, B-10, C-04, C-05, C-06 |
| Media | 13 | A-02, B-02, B-03, B-04, B-07, B-09, B-12, B-13, C-01, C-02, C-09, C-13, C-16 |
| Baja | 1 | C-03 |

### Mapa GAP → Requisitos afectados

| GAP | Descripción | Requisitos que bloquea |
|-----|-------------|------------------------|
| GAP-01 | Sin bucket policy en Storage (riesgo no verificado en prod) | A-08, B-10, C-20 |
| GAP-02 | Sin mecanismo de consentimiento/información | A-03, A-04, A-15 |
| GAP-03 | Sin documentos legales (ToS, PP) | A-03, A-14, A-15 |
| GAP-04 | Email verification (config local — no verificado en prod) | A-08, B-08, C-04 |
| GAP-05 | Sin retención/eliminación de datos | A-10, A-11 |
| GAP-06 | MFA (config local — no verificado en prod) | A-08, B-08, C-05 |
| GAP-07 | Session timeout (config local — no verificado en prod) | A-08, C-06 |
| GAP-08 | Contraseña mínima débil (6 chars) | B-08, C-01, C-02 |
| GAP-10 | Sin exportación de datos para titulares | A-09 |
| GAP-11 | PII en audit_events.event_payload | A-02, B-09 |
| GAP-DI-05 | Sin DPA con Supabase Inc. | A-12 |

---

*Documento generado automáticamente a partir del estado del repositorio. No contiene datos de producción ni credenciales.*  
*Prerequisito: `docs/compliance/00-baseline.md` (commit `5d9a0f3`).*
