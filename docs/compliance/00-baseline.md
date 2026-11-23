# Constelmec — Inventario de Controles de Privacidad y Seguridad

**Versión:** 0.1.1  
**Fecha:** 23/11/2026  
**Fase:** Fase 0 — Línea de base  
**Autor:** Auditoría automática (Claude Code — Frente 7)  
**Alcance:** Migraciones 001–010, `src/lib/supabase.ts`, `supabase/config.toml`

---

## 1. Resumen ejecutivo

Constelmec es una PWA de gestión de mantenimiento industrial (Argentina) que procesa datos PII de técnicos y contactos de empresa, genera órdenes de servicio, registra historial de visitas, y emite tokens QR para acceso físico a portones. La base de datos opera sobre Supabase (PostgreSQL 17 + Auth + Storage).

La evaluación de los 10 archivos de migración y la configuración del cliente revela una **arquitectura de seguridad de base sólida** (RLS, RPCs SECURITY DEFINER, auditoría append-only, hash de tokens QR) con **brechas relevantes** en privacidad de datos, política de almacenamiento, y requisitos legales de Ley 25.326 / GDPR para operación comercial.

---

## 2. Inventario de controles implementados

### 2.1 Autenticación y gestión de sesiones

| Control | Archivo | Estado | Notas |
|---------|---------|--------|-------|
| Email/password auth vía Supabase Auth | `config.toml [auth]` | ✅ Implementado | JWT expira en 3600 s |
| Session persistence en localStorage | `src/lib/supabase.ts:14` | ✅ Implementado | Key: `constelmec:auth:v2` |
| Auto-refresh de tokens | `src/lib/supabase.ts:17` | ✅ Implementado | `autoRefreshToken: true` |
| Refresh token rotation | `config.toml:177` | ✅ Implementado | `enable_refresh_token_rotation = true` |
| Anonymous sign-ins deshabilitados | `config.toml:184` | ✅ Implementado | `enable_anonymous_sign_ins = false` |
| Email confirmation deshabilitada | `config.toml:234` | ⚠️ No verificado en prod | `enable_confirmations = false` en config local — estado del proyecto remoto no verificado |
| MFA deshabilitado | `config.toml:315–320` | ⚠️ No verificado en prod | `enroll_enabled = false` en config local — estado del proyecto remoto no verificado |
| Session timeout no configurado | `config.toml:289` | ⚠️ No verificado en prod | `[auth.sessions]` comentado en config local — estado del proyecto remoto no verificado |
| Contraseña mínima 6 caracteres | `config.toml:188` | ⚠️ Débil | Mínimo recomendado 8; sin `password_requirements` |

### 2.2 Autorización y control de acceso (RLS)

| Control | Migración | Estado | Notas |
|---------|-----------|--------|-------|
| RLS habilitado en todas las tablas públicas | 001–010 | ✅ Implementado | Verificado en cada `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` |
| Writes revocados de `anon, authenticated` por defecto | 001–010 | ✅ Implementado | Patrón consistente: `REVOKE INSERT,UPDATE,DELETE ... FROM anon, authenticated` |
| Todas las escrituras vía SECURITY DEFINER RPCs | 001–010 | ✅ Implementado | `set search_path=''` en todas las funciones |
| `app_private` fuera del Data API | `config.toml:14` | ✅ Implementado | `schemas = ["public", "graphql_public"]` — `app_private` inaccesible vía REST |
| `has_membership()` v2 comprueba empresa activa | `mig_005:app_private` | ✅ Implementado | Verifica `memberships.active AND companies.active` |
| `is_platform_admin()` en esquema privado | `mig_004:app_private` | ✅ Implementado | `app_private.platform_admins` fuera del Data API |
| Lectura de contactos: solo admins | `mig_007:52–57` | ✅ Implementado | — |
| Lectura de asignaciones: solo admins | `mig_008:89–108` | ✅ Implementado | `technician_company_assignments`, `technician_facility_assignments`, `service_order_technicians` |
| Auto-lectura de perfil técnico (mig 010) | `mig_010:31–35` | ✅ Implementado | `user_id = auth.uid()` — solo el propio perfil |
| Lectura de órdenes para miembros (mig 010) | `mig_010:50–54` | ✅ Implementado | `has_membership(company_id)` — sin restricción de rol |
| Auto-lectura de asignaciones de orden (mig 010) | `mig_010:67–79` | ✅ Implementado | Técnico ve sus propias filas en `service_order_technicians` |

### 2.3 Auditoría e inmutabilidad

| Control | Migración | Estado | Notas |
|---------|-----------|--------|-------|
| `audit_events` append-only vía trigger | `mig_001` | ✅ Implementado | `audit_immutable` trigger: UPDATE y DELETE lanzan excepción |
| Idempotency key en cada evento | 001–010 | ✅ Implementado | `gen_random_uuid()` como `idempotency_key` en todas las inserciones de auditoría |
| Cobertura de eventos — creación | 001–010 | ✅ Implementado | `*_created` para empresa, instalación, portón, contacto |
| Cobertura de eventos — ciclo de vida QR | `mig_006` | ✅ Implementado | `gate_qr_issued`, `gate_qr_revoked` |
| Cobertura de eventos — asignaciones | `mig_008/009` | ✅ Implementado | `order_technician_assigned`, `technician_company_enabled/disabled` |
| `audit_events` sin política SELECT pública | `mig_001` | ✅ Implementado | No hay política `for select` — solo `service_role` puede leer por defecto |

### 2.4 Tokens QR y seguridad de acceso físico

| Control | Migración | Estado | Notas |
|---------|-----------|--------|-------|
| Solo se almacena `sha256(token)` | `mig_006:503` | ✅ Implementado | `encode(extensions.digest(v_token::text, 'sha256'), 'hex')` |
| Token crudo retornado una única vez | `mig_006:510` | ✅ Implementado | `return v_token::text` — no persiste en DB |
| Revocación atómica del QR anterior en re-emisión | `mig_006:496–497` | ✅ Implementado | `UPDATE gate_qr_codes SET status = 'revoked'` antes del INSERT |
| `SELECT ... FOR UPDATE` serializa emisiones concurrentes | `mig_006:472–488` | ✅ Implementado | Lock en `gates` y `facilities` |
| Índice único parcial: un QR `active` por portón | `mig_006` | ✅ Implementado | `CREATE UNIQUE INDEX ... WHERE status = 'active'` |
| Revocación al desactivar portón | `mig_006:429–432` | ✅ Implementado | `admin_set_gate_active(false)` revoca QR activo |
| Validación de jerarquía activa (empresa → instalación → portón) | `mig_006:466–490` | ✅ Implementado | Falla si instalación o portón inactivos |

### 2.5 Integridad de datos y concurrencia

| Control | Migración | Estado | Notas |
|---------|-----------|--------|-------|
| Optimistic locking en contactos | `mig_007:210–221` | ✅ Implementado | `p_expected_updated_at` requerido |
| Optimistic locking en empresas | `mig_005` | ✅ Implementado | `expected_updated_at` en RPCs de empresa |
| Partial unique index — un lead activo por orden | `mig_009:62–63` | ✅ Implementado | `WHERE role = 'lead' AND active = true` |
| Soft-delete en `service_order_technicians` | `mig_009:26–29` | ✅ Implementado | `active`, `removed_at`, `removed_by` |
| Cascade al deshabilitar técnico (status-aware) | `mig_009:117–151` | ✅ Implementado | Bloquea si orden `in_progress`; soft-remove en pending/scheduled |
| Validación de CUIT (formato) | `mig_005` | ✅ Implementado | — |
| Validación de email en contactos | `mig_007:101–103` | ✅ Implementado | Regex básico en RPC |

### 2.6 Integraciones externas

| Servicio | Estado | Notas |
|----------|--------|-------|
| Email (SMTP) | ❌ No configurado | `[auth.email.smtp]` comentado; `enable_confirmations = false` |
| SMS | ❌ Deshabilitado | `[auth.sms] enabled = false`; Twilio configurado solo con env vars vacías |
| OAuth providers (Apple, GitHub, etc.) | ❌ Deshabilitados | Todos `enabled = false` |
| MFA | ❌ Deshabilitado | TOTP y phone `enroll_enabled = false` |
| Webhooks externos | ❌ No encontrados | Sin edge functions ni llamadas a APIs externas en el código fuente |
| Analytics / trackers | ❌ Ninguno | Solo Supabase Analytics interno (`backend = "postgres"`) |
| Terceros (Firebase, Auth0, Cognito) | ❌ Deshabilitados | Todos `enabled = false` |
| **Supabase (BaaS)** | ⚠️ No verificado | Proveedor de infraestructura — potencial transferencia internacional pendiente de análisis |
| **Vercel (hosting)** | ⚠️ No verificado | Plataforma de despliegue — potencial transferencia internacional pendiente de análisis |

---

## 3. Inventario de datos PII

### 3.1 Tablas con datos personales

| Tabla | Columnas PII | Categoría | Acceso actual |
|-------|-------------|-----------|---------------|
| `auth.users` (Supabase) | email, created_at | Identidad | Gestionado por Supabase Auth |
| `memberships` | user_id (FK) | Vínculo identidad-empresa | Admin + plataforma |
| `technician_profiles` | first_name, last_name, work_phone, work_email, specialty, driving_authorized, license_expires_on | PII sensible (datos laborales + licencia) | Admin + plataforma; técnico ve su propia fila (mig 010) |
| `company_contacts` | first_name, last_name, email, phone, notes | Datos de contacto | Solo admin |
| `service_order_technicians` | technician_id, removed_by | Vínculo persona-orden | Admin; técnico ve sus propias filas (mig 010) |
| `audit_events` | actor_user_id, event_payload | Trazabilidad de acciones | Solo service_role |

### 3.2 Datos sensibles operacionales (no PII directo)

| Tabla | Dato sensitivo | Riesgo |
|-------|---------------|--------|
| `gate_qr_codes` | token_hash | Bajo — solo hash, raw token no persiste |
| `findings` | Hallazgos de inspección | Medio — información operacional del cliente |
| `report_versions` | `private_storage_path` | **Alto** — ruta a archivos en Storage, sin bucket policy definida |
| `customer_observations` | body (texto libre) | Medio — puede contener datos sensibles del cliente |

---

## 4. Brechas identificadas

### 4.1 Brechas Críticas (bloquean operación comercial)

| ID | Brecha | Tablas / Archivos afectados | Riesgo |
|----|--------|---------------------------|--------|
| GAP-01 | **Storage bucket — riesgo no verificado** — `report_versions.private_storage_path` referencia archivos pero no existe ninguna `[storage.buckets.*]` configurada en config local. La ausencia de política declarada no prueba acceso irrestricto; pendiente verificar existencia del bucket, configuración real y políticas efectivas en el proyecto remoto. | `config.toml:120–132`, `mig_002:report_versions` | Crítico |
| GAP-02 | **Sin mecanismo de consentimiento/información** — no existe flujo de aceptación de Términos, Política de Privacidad, ni información de tratamiento al momento de registro. Distinguir: (a) tratamiento de datos, (b) aceptación contractual, (c) consentimiento específico. No todo tratamiento requiere consentimiento expreso — evaluar bases legales alternativas (Art. 5 y excepciones). | Toda la app | Crítico |
| GAP-03 | **Sin documentos legales** — no existen `politica_privacidad.md`, `terminos_uso.md`, ni textos en la UI. | docs/ | Crítico |

### 4.2 Brechas Altas (deben resolverse antes del lanzamiento)

| ID | Brecha | Archivo | Riesgo |
|----|--------|---------|--------|
| GAP-04 | **Email verification deshabilitado** — usuarios pueden iniciar sesión sin confirmar su email. | `config.toml:234` | Alto |
| GAP-05 | **Sin retención ni eliminación de datos** — no existe flujo de baja de usuario, derecho al olvido (Art. 6 Ley 25.326), ni política de retención de `audit_events`. | DB | Alto |
| GAP-06 | **MFA no disponible** — sistema procesa acceso físico (QR) y datos laborales sensibles; sin segundo factor de autenticación. | `config.toml:315–320` | Alto |
| GAP-07 | **Session timeout no configurado** — sesiones sin `timebox` ni `inactivity_timeout` persisten indefinidamente hasta expiración del refresh token. | `config.toml:289` | Alto |

### 4.3 Brechas Medias (mejoras recomendadas)

| ID | Brecha | Archivo | Riesgo |
|----|--------|---------|--------|
| GAP-08 | **Contraseña mínima débil** — 6 caracteres sin requisitos de complejidad. | `config.toml:188` | Medio |
| GAP-09 | **Network restrictions deshabilitadas** — DB acepta conexiones de cualquier IP. | `config.toml:79–84` | Medio |
| GAP-10 | **Sin política de exportación de datos** — no existe endpoint para que un usuario descargue sus propios datos (derecho de acceso, Art. 14 Ley 25.326). | — | Medio |
| GAP-11 | **`audit_events.event_payload` puede contener PII** — e.g., `before/after` en `contact_updated` incluye email y teléfono. No hay enmascaramiento. | `mig_007:236–257` | Medio |

---

## 5. Mapa normativo — Argentina (Ley 25.326)

| Artículo | Requisito | Estado actual |
|----------|-----------|---------------|
| Art. 4 — Calidad del dato | Datos exactos y actualizados | ⚠️ Parcial — no hay flujo de corrección/actualización de datos por el titular |
| Art. 5 — Consentimiento | Consentimiento previo, informado y libre | ❌ Falta flujo de aceptación — verificar excepciones legales aplicables (relación contractual, interés legítimo) |
| Art. 6 — Deber de información | Informar finalidad, destinatarios y posibilidad de acceso/rectificación al momento de recolección | ❌ No implementado — no hay mecanismo de información en el momento de recolección |
| Art. 7 — Datos sensibles | Protección reforzada de datos laborales | ⚠️ Parcial — `technician_profiles` sin controles adicionales explícitos |
| Art. 9 — Deber de secreto | Confidencialidad en el tratamiento | ✅ Parcial — RLS + SECURITY DEFINER limitan acceso; sin política documentada de confidencialidad |
| Art. 11 — Cesión de datos | Prohibición de ceder datos sin consentimiento informado | ✅ No hay cesiones activas — sin integraciones que compartan datos con terceros |
| Art. 12 — Transferencia internacional | Restricciones si datos salen del país | ⚠️ No verificado — Supabase y Vercel son proveedores con infraestructura potencialmente fuera de Argentina |
| Art. 14 — Derecho de acceso | Titular puede solicitar sus datos | ❌ No implementado |
| Art. 16 — Derecho de rectificación y supresión | Titular puede corregir o solicitar baja definitiva | ❌ No implementado (aplica a rectificación y supresión) |

---

## 6. Próximas fases recomendadas

| Fase | Contenido | Prioridad |
|------|-----------|-----------|
| **Fase 1** | Análisis normativo detallado — mapear cada tabla/columna contra Ley 25.326 y GDPR-lite | Alta |
| **Fase 2** | Inventario de flujos de datos — diagrama origen→destino para cada categoría PII | Alta |
| **Fase 3** | Auditoría de seguridad técnica — penetration test de RLS (service_role bypass, indirect inference, timing attacks en has_membership) | Alta |
| **Fase 4** | Implementación de controles faltantes — bucket policy (GAP-01), session timeout (GAP-07), MFA (GAP-06), email verification (GAP-04) | Alta |
| **Fase 5** | Redacción de documentos legales — Política de Privacidad, Términos de Uso, Política de Cookies (si aplica) | Alta |
| **Fase 6** | Flujo de aceptación en-app — modal de consentimiento en primer login, versioning de aceptación, derecho de baja | Alta |
| **Fase 7** | Release readiness — checklist final antes de operación comercial | Alta |

---

## 7. Decisiones resueltas (ChatGPT — 23/11/2026)

| GAP | Decisión |
|-----|----------|
| GAP-01 — Storage | Bucket privado. Acceso solo a usuarios autenticados y autorizados por empresa/orden/rol. `service_role` reservado al backend. |
| GAP-02 — Consentimiento | Identidad de usuario única. Aceptación y contexto jurídico separados por empresa. Distinguir: (a) tratamiento de datos, (b) información de privacidad, (c) aceptación contractual. |
| GAP-04 — Email | Invitación administrada para usuarios corporativos. Verificación de identidad y correo antes de habilitar acceso. |
| GAP-05 — Retención | No fijar años arbitrariamente. Proponer matriz por categoría de datos, finalidad y obligación de conservación. |
| GAP-06 — MFA | Obligatorio para administradores. Recomendado y opcional inicialmente para técnicos/clientes, sujeto a evaluación de riesgos. |
| GAP-07 — Sesiones | Expiración por inactividad + reautenticación para operaciones sensibles. Valores concretos a definir tras evaluar experiencia operativa de técnicos en campo. |

*Decisiones de diseño para avanzar — no autorizaciones de despliegue en producción.*

---

*Documento generado automáticamente a partir del estado del repositorio. No contiene datos de producción ni credenciales.*
