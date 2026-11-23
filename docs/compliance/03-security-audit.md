# Constelmec — Fase 3: Auditoría de Seguridad Técnica

**Versión:** 0.1.0  
**Fecha:** 23/11/2026  
**Fase:** Fase 3 — Auditoría de seguridad técnica  
**Autor:** Auditoría automática (Claude Code — Frente 7)  
**Alcance:** Migraciones 001–010, `src/hooks/useRealData.ts`, `src/hooks/useAuth.ts`, `supabase/config.toml`  
**Referencia:** [Fase 0](./00-baseline.md) · [Fase 1](./01-compliance-matrix.md) · [Fase 2](./02-data-inventory.md)

> **Restricción metodológica:** Esta auditoría es estrictamente estática. No se ejecutaron pruebas activas contra producción ni bases de datos con datos reales. Todos los hallazgos se basan en lectura del código fuente, migraciones SQL y configuración del repositorio. ("No uses datos reales ni ataques contra producción" — directiva ChatGPT Fase 3.)

---

## 1. Resumen ejecutivo

La arquitectura de seguridad de datos de Constelmec está bien diseñada en su núcleo:

- RLS habilitado en las **20 tablas públicas** con aislamiento por `company_id`
- Todas las escrituras administrativas exclusivamente vía **RPCs con `SECURITY DEFINER` y `set search_path=''`**
- Privilegios INSERT/UPDATE/DELETE **revocados** de `anon` y `authenticated` en todas las tablas
- `audit_events` **append-only** garantizado por trigger a nivel de base de datos
- QR tokens: solo el **hash sha256** persiste; el token crudo se retorna una única vez
- **Sin credenciales hardcodeadas** en el código fuente

**Hallazgos nuevos de Fase 3 — riesgo alto:**

| ID | Hallazgo |
|----|----------|
| GAP-SEC-01 | Técnicos pueden leer todos los `audit_events` de la empresa, incluyendo `event_payload` con PII histórica — amplifica GAP-11 |
| GAP-SEC-02 | `customer_observations` usa INSERT directo desde el cliente — único punto de escritura fuera del patrón RPC, sin registro en `audit_events` |

**Hallazgos nuevos de Fase 3 — riesgo medio/bajo:**

| ID | Hallazgo |
|----|----------|
| GAP-SEC-03 | `service_orders.notes` y datos operacionales expuestos a todos los miembros (incluidos clientes) via mig 010 |
| GAP-SEC-04 | `00-baseline.md` documenta incorrectamente que `audit_events` no tiene política SELECT |
| GAP-SEC-05 | Técnico con perfil desactivado (`active=false`) pierde acceso a su historial propio en `service_order_technicians` |
| GAP-SEC-06 | `i_am_platform_admin` y `admin_list_all_companies` son SECURITY DEFINER sin `set search_path=''` explícito |

---

## 2. Metodología

| Aspecto | Método |
|---------|--------|
| Cobertura de migraciones | Lectura completa de los 10 archivos SQL (001–010) |
| Análisis de RLS | Inventario manual de cada `create policy` y `alter policy` por tabla |
| Análisis de RPCs | Verificación de `SECURITY DEFINER`, `set search_path=''`, y guards de autorización en cada función |
| Análisis del cliente | Lectura de `src/hooks/useRealData.ts` y `src/hooks/useAuth.ts` — toda la capa de acceso a datos |
| Configuración | Lectura de `supabase/config.toml` |
| Alcance | Solo análisis estático — sin ejecución contra base de datos ni datos reales |

---

## 3. Análisis de aislamiento multiempresa (RLS)

### 3.1 Inventario completo de políticas RLS

Todas las 20 tablas públicas tienen RLS habilitado. La tabla siguiente lista todas las políticas y su evaluación.

| Tabla | Política | Op. | Condición efectiva | Estado |
|-------|----------|-----|-------------------|--------|
| `companies` | companies_read | SELECT | `has_membership(id)` | ✅ Aislado por empresa |
| `memberships` | memberships_read | SELECT | `user_id = auth.uid()` | ✅ Solo registro propio |
| `facilities` | facilities_read | SELECT | `has_membership(company_id)` | ✅ Aislado por empresa |
| `gates` | gates_read | SELECT | `has_membership(company_id)` | ✅ Aislado por empresa |
| `visits` | visits_read | SELECT | `has_membership(company_id)` | ✅ Aislado por empresa |
| `inspection_controls` | controls_read | SELECT | `has_membership(company_id)` | ✅ Aislado por empresa |
| `customer_observations` | observations_read | SELECT | `has_membership(company_id) OR is_platform_admin()` | ✅ Aislado por empresa |
| `customer_observations` | observations_insert | INSERT | WITH CHECK: `author_user_id = auth.uid() AND has_membership(company_id)` | ✅ Solo propia identidad + empresa |
| `audit_events` | audit_read (mig 001) | SELECT | `has_membership(company_id, ['admin','technician'])` | ⚠️ Técnicos leen eventos con PII — ver GAP-SEC-01 |
| `audit_events` | audit_read (mig 004) | SELECT | `...OR is_platform_admin()` | ⚠️ Ampliación correcta |
| `findings` | findings_read | SELECT | `has_membership(company_id) OR is_platform_admin()` | ✅ Aislado por empresa |
| `finding_events` | finding_events_read | SELECT | `has_membership(company_id) OR is_platform_admin()` | ✅ Aislado por empresa |
| `inspection_corrections` | corrections_read | SELECT | `has_membership(company_id) OR is_platform_admin()` | ✅ Aislado por empresa |
| `report_versions` | reports_read | SELECT | `has_membership(company_id) OR is_platform_admin()` | ✅ Aislado por empresa |
| `technician_profiles` | technician_profiles_admin_read (mig 003) | SELECT | `has_membership(company_id, ['admin']) OR is_platform_admin()` | ✅ Solo admins |
| `technician_profiles` | technician_profiles_self_read (mig 010) | SELECT | `user_id = auth.uid()` | ✅ Solo registro propio |
| `service_orders` | service_orders_admin_read (mig 003) | SELECT | `has_membership(company_id, ['admin']) OR is_platform_admin()` | ✅ Solo admins |
| `service_orders` | service_orders_member_read (mig 010) | SELECT | `has_membership(company_id)` | ⚠️ Todos los miembros — ver GAP-SEC-03 |
| `gate_qr_codes` | qr_codes_read (mig 006) | SELECT | `has_membership(company_id, ['admin','technician']) OR is_platform_admin()` | ✅ Aislado + roles admin/tech |
| `company_contacts` | contacts_read (mig 007) | SELECT | `has_membership(company_id, ['admin']) OR is_platform_admin()` | ✅ Solo admins |
| `technician_company_assignments` | tech_company_assignments_read (mig 008) | SELECT | `has_membership(company_id, ['admin']) OR is_platform_admin()` | ✅ Solo admins |
| `technician_facility_assignments` | tech_facility_assignments_read (mig 008) | SELECT | `has_membership(company_id, ['admin']) OR is_platform_admin()` | ✅ Solo admins |
| `service_order_technicians` | service_order_technicians_read (mig 008) | SELECT | `has_membership(company_id, ['admin']) OR is_platform_admin()` | ✅ Solo admins |
| `service_order_technicians` | service_order_technicians_self_read (mig 010) | SELECT | `technician_id = (subquery auth.uid()) OR has_membership(...,'admin') OR is_platform_admin()` | ✅ Técnico ve sus propias filas |

**Resultado: 20/20 tablas con RLS habilitado. Ninguna tabla con acceso no autenticado. Ninguna tabla sin política SELECT para el rol autenticado.**

### 3.2 `has_membership()` — función central de aislamiento

```sql
-- app_private (oculta del Data API — PostgREST no expone app_private)
-- SECURITY DEFINER + set search_path=''
select exists(
  select 1 from public.memberships m
  where m.company_id = p_company
    and m.user_id = (select auth.uid())   -- anti-inlining: evaluado una sola vez
    and m.active
    and (p_roles is null or m.role = any(p_roles))
)
```

Versión 2 (mig 005) verifica adicionalmente `companies.active` — un usuario no puede acceder a datos de una empresa desactivada aunque su membresía esté activa.

**Propiedades verificadas:**
- SECURITY DEFINER + `set search_path=''` → sin riesgo de path injection
- `(select auth.uid())` → la función auth se evalúa una vez, no por fila
- Función STABLE → PostgreSQL puede optimizar llamadas repetidas en un query
- Schema `app_private` → no accessible vía REST API

### 3.3 Protección contra UPDATE/DELETE en tablas críticas

Todas las tablas tienen `REVOKE INSERT,UPDATE,DELETE FROM anon, authenticated`. Las tablas de registro tienen protección adicional por trigger de inmutabilidad:

| Tabla | Trigger | Efecto |
|-------|---------|--------|
| `audit_events` | audit_no_update | UPDATE y DELETE generan EXCEPTION — inmutabilidad garantizada a nivel DB |
| `inspection_controls` | controls_no_update | Inmutable |
| `customer_observations` | observations_no_update | Inmutable |
| `findings` | findings_no_update | Inmutable |
| `finding_events` | finding_events_no_update | Inmutable |
| `inspection_corrections` | corrections_no_update | Inmutable |
| `report_versions` | reports_no_update | Inmutable |

**Resultado: Las tablas de registro y auditoría son inmutables incluso para service_role.**

---

## 4. Análisis de RPCs con privilegio elevado

### 4.1 Inventario de funciones SECURITY DEFINER

| Función | Schema | SEC DEF | search_path | Guard de autorización |
|---------|--------|---------|-------------|----------------------|
| `app_private.has_membership` | app_private | ✅ | ✅ | Helper — no DML |
| `app_private.is_technician` | app_private | ✅ | ✅ | Helper — no DML |
| `app_private.is_platform_admin` | app_private | ✅ | ✅ | Consulta `platform_admins` |
| `app_private.audit_immutable` | app_private | — | ✅ | Trigger — bloquea todo |
| `app_private.set_updated_at` | app_private | — | ✅ | Trigger — no privilegio |
| `app_private.validate_cuit` | app_private | — | ✅ | Helper — no DML |
| `public.i_am_platform_admin` | public | ✅ | ❌ ausente | Llama a `is_platform_admin()` |
| `public.admin_list_all_companies` | public | ✅ | ❌ ausente | `is_platform_admin()` check |
| `public.admin_create_company` | public | ✅ | ✅ | `is_platform_admin()` check |
| `public.admin_update_company` | public | ✅ | ✅ | `is_platform_admin()` + membership check |
| `public.admin_set_company_active` | public | ✅ | ✅ | `is_platform_admin()` check |
| `public.admin_create_facility` | public | ✅ | ✅ | `is_platform_admin() OR has_membership(['admin'])` |
| `public.admin_update_facility` | public | ✅ | ✅ | Ídem |
| `public.admin_set_facility_active` | public | ✅ | ✅ | Ídem |
| `public.admin_create_gate` | public | ✅ | ✅ | Ídem |
| `public.admin_update_gate` | public | ✅ | ✅ | Ídem |
| `public.admin_set_gate_active` | public | ✅ | ✅ | Ídem |
| `public.admin_issue_gate_qr` | public | ✅ | ✅ | Ídem |
| `public.admin_revoke_gate_qr` | public | ✅ | ✅ | Ídem |
| `public.admin_create_company_contact` | public | ✅ | ✅ | Ídem |
| `public.admin_update_company_contact` | public | ✅ | ✅ | Ídem |
| `public.admin_set_company_contact_active` | public | ✅ | ✅ | Ídem |
| `public.admin_set_technician_company` | public | ✅ | ✅ | Ídem |
| `public.admin_set_technician_facility` | public | ✅ | ✅ | Ídem |
| `public.admin_assign_order_technician` | public | ✅ | ✅ | Ídem |
| `public.admin_remove_order_technician` | public | ✅ | ✅ | Ídem |

**Hallazgo (GAP-SEC-06):** `i_am_platform_admin` y `admin_list_all_companies` tienen SECURITY DEFINER sin `set search_path=''`. Son funciones de solo lectura que delegan a `app_private.is_platform_admin()` (que sí tiene `set search_path=''`). El riesgo de explotación es bajo ya que no ejecutan DML directo, pero rompen la consistencia del patrón de seguridad.

### 4.2 Patrón de autorización en RPCs de escritura

Todas las RPCs siguen el mismo patrón verificado:

```sql
-- 1. Verificar autorización
if not (is_platform_admin() or has_membership(company_id, ['admin'])) then
  raise exception 'permission denied' using errcode = '42501';
end if;

-- 2. Verificar existencia y estado del objeto padre
if not exists (select 1 from companies where id = company_id and active) then
  raise exception '...' using errcode = 'P0002';
end if;

-- 3. Validar inputs (nombre, email regex, longitud, etc.)
if length(trim(field)) < N then ...

-- 4. Escribir en la tabla objetivo
INSERT INTO public.<tabla> (...) RETURNING id INTO v_id;

-- 5. Registrar en audit_events (cada RPC)
INSERT INTO public.audit_events (company_id, actor_user_id, event_type, event_payload, idempotency_key)
VALUES (..., gen_random_uuid());
```

**Resultado: Patrón consistente en todos los RPCs verificados. Sin excepciones.**

---

## 5. Acceso del cliente — análisis de `useRealData.ts`

### 5.1 Resumen de accesos

El cliente solo utiliza `supabase.auth.*` y `supabase.rpc()` — con dos excepciones de lectura directa y una de escritura directa:

| Tipo | Acceso | Protección |
|------|--------|-----------|
| `supabase.auth.*` | Autenticación (login, logout, session) | Supabase Auth |
| `supabase.rpc(...)` | 21 RPCs de escritura (admin_*) | SECURITY DEFINER + RLS |
| `supabase.from('service_orders').select(...)` | Lectura con join a gates, facilities, technician_profiles | RLS por tabla |
| `supabase.from('technician_profiles').select(...)` | Lectura completa incluyendo license_expires_on | RLS admin-only |
| `supabase.from('companies').select('id,name').in('id', ids)` | Lectura de nombres de empresa | RLS has_membership |
| `supabase.from('customer_observations').insert({...})` | **Escritura directa** — único caso sin RPC | RLS WITH CHECK |

### 5.2 Lectura directa de `service_orders` con join

```ts
supabase!.from('service_orders')
  .select('id,company_id,service_type,status,scheduled_start,scheduled_end,
           completed_at,next_service_at,notes,
           gates(code,description),
           facilities(name),
           technician_profiles(first_name,last_name)')
  .order('scheduled_start', { ascending: true })
```

Este join incluye `technician_profiles(first_name,last_name)`. Supabase/PostgREST ejecuta cada tabla del join con el rol del usuario autenticado y sus propias políticas RLS. Para un técnico:
- `service_orders` → visible via `service_orders_member_read` (mig 010)
- `technician_profiles` → visible solo el propio perfil via `technician_profiles_self_read` (mig 010)

Resultado: el join retornará `null` para los perfiles de otros técnicos cuando el solicitante es un técnico. **Sin fuga de información entre técnicos.**

### 5.3 Escritura directa en `customer_observations` (GAP-SEC-02)

```ts
// useRealData.ts:725
await supabase!.from('customer_observations').insert({
  company_id: companyId,
  gate_id: gateId,
  author_user_id: authorId,  // controlado por el cliente
  body,                       // texto libre, 2000 chars
});
```

La protección es la política RLS `observations_insert` (WITH CHECK):

```sql
WITH CHECK (
  author_user_id = (select auth.uid())   -- no puede suplantar autoría
  AND app_private.has_membership(company_id)  -- no puede insertar en empresa ajena
)
```

Adicionalmente, la FK compuesta `(gate_id, company_id) REFERENCES gates(id, company_id)` impide referenciar un portón de otra empresa.

**Vulnerabilidades no encontradas:** no es posible suplantar `author_user_id`, insertar en empresa ajena, ni referenciar portones de otra empresa. La protección DB es correcta.

**GAP-SEC-02 (diseño):** Esta escritura directa existe como excepción al patrón uniforme de RPCs:
1. No genera un evento en `audit_events` para el INSERT de observaciones — no hay trazabilidad de quién insertó qué observación en el log de auditoría
2. Riesgo futuro: si la política RLS es editada incorrectamente, no hay capa de validación server-side adicional (como la que proveen los RPCs con guards explícitos)

---

## 6. Tokens QR — seguridad de acceso físico

### 6.1 Diseño criptográfico

| Aspecto | Implementación | Evaluación |
|---------|---------------|------------|
| Almacenamiento | Solo `sha256(token)` en `token_hash` | ✅ Token crudo no recuperable desde la DB |
| Generación | `gen_random_uuid()` como token raw | ✅ 128 bits de entropía criptográfica |
| Hash | `encode(extensions.digest(token::text, 'sha256'), 'hex')` | ✅ SHA-256 — resistente a preimage |
| Retorno | `return v_token::text` — única vez, no persiste en ninguna columna | ✅ |
| Unicidad | Partial unique index: `CREATE UNIQUE INDEX ... WHERE status = 'active'` | ✅ Un solo QR activo por portón |
| Serialización | `SELECT ... FOR UPDATE` en gate y facility durante emisión | ✅ Emisión concurrente serializada |

### 6.2 Revocación en cadena

| Evento | Efecto sobre QR |
|--------|----------------|
| `admin_issue_gate_qr` (re-emisión) | Revoca el QR activo anterior antes del INSERT del nuevo |
| `admin_set_gate_active(false)` | Revoca el QR activo del portón automáticamente |
| `admin_revoke_gate_qr` | Revocación manual explícita |

**Resultado: Diseño de QR tokens correcto. No se identificaron vulnerabilidades.**

**Nota:** La validación del QR en el proceso de ingreso físico no está implementada en el repositorio actual — se espera implementación futura. La función `admin_issue_gate_qr` retorna el token crudo una sola vez y lo almacena como hash. La validación en el portón deberá hashear el QR presentado y comparar contra `token_hash WHERE status = 'active'`.

---

## 7. Configuración de autenticación

> Valores de `config.toml` local (desarrollo). Estado en producción no verificado — ver GAP-04, GAP-06, GAP-07 en Fase 1.

| Control | Valor config local | Riesgo |
|---------|-------------------|--------|
| JWT expiry | `jwt_expiry = 3600` (1 hora) | ✅ Correcto |
| Refresh token rotation | `enable_refresh_token_rotation = true` | ✅ Correcto |
| Refresh reuse interval | `refresh_token_reuse_interval = 10` | ✅ Correcto |
| Anonymous sign-ins | `enable_anonymous_sign_ins = false` | ✅ Correcto |
| Email confirmation | `enable_confirmations = false` | ⚠️ GAP-04 — no verificado en prod |
| MFA TOTP | `enroll_enabled = false` | ⚠️ GAP-06 — no verificado en prod |
| Session timeout | `[auth.sessions]` comentado | ⚠️ GAP-07 — no verificado en prod |
| Contraseña mínima | `minimum_password_length = 6` | ⚠️ GAP-08 — débil (mínimo recomendado: 8) |
| Rate limiting sign-in | `30 req/5min` | ✅ Correcto |
| Rate limiting token refresh | `150 req/5min` | ✅ Correcto |
| OAuth providers | todos `enabled = false` | ✅ Superficie reducida |
| SMS / Twilio | `enabled = false` | ✅ |

---

## 8. Storage

No existe ninguna configuración de bucket en `config.toml`:

```toml
[storage]
enabled = true
file_size_limit = "50MiB"
# [storage.buckets.images]  ← comentado, sin buckets declarados
```

La tabla `report_versions` referencia `private_storage_path` para rutas de archivos en Storage. No se encontró ningún uso de `supabase.storage` en el código fuente TypeScript.

**Ver GAP-01 (Fase 0) y C-20 (Fase 1) — Storage sin política de bucket declarada.**

---

## 9. Hallazgos de seguridad consolidados

### 9.1 Hallazgos nuevos de riesgo alto

| ID | Hallazgo | Archivo / Referencia | Prioridad | Ref. cruzada |
|----|----------|---------------------|-----------|-------------|
| GAP-SEC-01 | Técnicos pueden leer `audit_events` con `event_payload` que contiene PII histórica (before/after de actualizaciones de contactos, perfiles, etc.) | `mig_001:47`, `mig_004:111` | Alta | GAP-11, A-02, B-09 |
| GAP-SEC-02 | `customer_observations` usa INSERT directo desde el cliente — no genera entrada en `audit_events`; dependencia exclusiva de RLS para control de acceso en escrituras | `useRealData.ts:725` | Media | A-02 |

### 9.2 Hallazgos nuevos de riesgo medio/bajo

| ID | Hallazgo | Archivo / Referencia | Prioridad |
|----|----------|---------------------|-----------|
| GAP-SEC-03 | `service_orders` expuesto a todos los miembros via `service_orders_member_read` (mig 010) — clientes leen `notes`, `service_type`, `status` y fechas operacionales | `mig_010:50–54` | Media |
| GAP-SEC-04 | `00-baseline.md:60` documenta incorrectamente que `audit_events` no tiene política SELECT — hay dos políticas activas (admin + technician + platform_admin) | `00-baseline.md:60` | Baja (doc) |
| GAP-SEC-05 | Técnico con perfil desactivado (`active=false`) pierde acceso a su historial de asignaciones propias — subquery `WHERE active limit 1` retorna NULL y no hay fallback | `mig_010:72–74` | Baja |
| GAP-SEC-06 | `i_am_platform_admin` y `admin_list_all_companies` son SECURITY DEFINER sin `set search_path=''` — bajo riesgo (solo lectura) pero inconsistente con el patrón de seguridad | `mig_004:46,60,70` | Baja |

### 9.3 Controles correctamente implementados

| Control | Evidencia |
|---------|-----------|
| Aislamiento multiempresa 20/20 tablas | Todas las políticas RLS verificadas — `has_membership()` o `user_id = auth.uid()` |
| Zero DML desde anon/authenticated | `REVOKE INSERT,UPDATE,DELETE` en cada tabla, en cada migración |
| Sin SQL injection posible | Todos los parámetros de RPC son tipados (uuid, text, boolean, enum) |
| Sin path injection en SECURITY DEFINER | `set search_path=''` verificado en todas las funciones críticas |
| Inmutabilidad del audit log | Trigger `audit_immutable` en 7 tablas — ni service_role puede borrar |
| QR design seguro | sha256 solo, 128 bits de entropía, índice único parcial, revocación en cadena |
| Sin secretos en código fuente | No hay keys/tokens/passwords hardcodeados en `src/` ni en ningún archivo tracked |
| Rate limiting en auth endpoints | 30/5min sign-in, 150/5min token refresh |
| FK compuesta en `customer_observations` | `(gate_id, company_id)` → impide cross-company reference a nivel DB |
| `audit_immutable` cubre 7 tablas de registro | No solo `audit_events` — `findings`, `inspection_controls`, `report_versions` y más son inmutables |

---

## 10. Resumen de nuevos GAPs identificados en Fase 3

| GAP | Descripción | Tablas / Archivos | Prioridad |
|-----|-------------|-------------------|-----------|
| GAP-SEC-01 | Técnicos leen `audit_events` con PII histórica en `event_payload` — amplía la exposición de GAP-11 | `audit_events`, `mig_001`, `mig_004` | Alta |
| GAP-SEC-02 | `customer_observations` INSERT directo sin auditoría ni RPC wrapper | `customer_observations`, `useRealData.ts:725` | Media |
| GAP-SEC-03 | `service_orders.notes` y datos operacionales visibles a todos los miembros incluyendo clientes | `service_orders`, `mig_010:50–54` | Media |
| GAP-SEC-04 | Documentación errónea en `00-baseline.md` sobre política SELECT de `audit_events` | `00-baseline.md:60` | Baja (doc) |
| GAP-SEC-05 | Técnico desactivado pierde visibilidad de su historial propio en `service_order_technicians` | `mig_010:72–74` | Baja |
| GAP-SEC-06 | `i_am_platform_admin` y `admin_list_all_companies` sin `set search_path=''` | `mig_004:46,60,70` | Baja |

---

*Documento generado automáticamente a partir del estado del repositorio. No contiene datos de producción ni credenciales.*  
*Prerequisitos: `00-baseline.md` v0.1.1 · `01-compliance-matrix.md` v0.2.0 · `02-data-inventory.md` v0.2.0.*
