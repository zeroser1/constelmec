# Constelmec — Fase 4A: Propuestas de Remediación de Seguridad

**Versión:** 1.2.0  
**Fecha:** 23/11/2026  
**Fase:** Fase 4A — Seguridad de datos  
**Autor:** Auditoría automática (Claude Code — Frente 7)  
**Referencia:** [Fase 3 — Auditoría de seguridad](./03-security-audit.md)

> **Restricción de despliegue:** Estas propuestas son documentación de diseño. Ninguna migración de esta fase debe aplicarse a producción hasta recibir aprobación explícita de ChatGPT. Producción permanece congelada.

---

## Resumen de GAPs a remediar

| GAP | Prioridad | Descripción |
|-----|-----------|-------------|
| GAP-SEC-01 | Alta | Técnicos leen `audit_events` con PII histórica en `event_payload` |
| GAP-SEC-02 | Media | `customer_observations` INSERT directo sin trazabilidad en `audit_events` |
| GAP-SEC-03 | Media | `service_orders.notes` visible a todos los miembros incluyendo clientes |
| GAP-SEC-06 | Baja | `i_am_platform_admin` y `admin_list_all_companies` sin `set search_path=''` |
| GAP-01 | Crítico | Storage sin bucket policy declarada (`report_versions.private_storage_path`) |

Orden de implementación recomendado: GAP-SEC-06 → GAP-SEC-01 → GAP-SEC-02 → GAP-SEC-03 → GAP-01.  
Justificación: menor al mayor impacto en RLS/permisos, con GAP-01 al final por depender de verificación remota.

---

## Propuesta 1 — GAP-SEC-06: `set search_path=''` en funciones de plataforma

**Archivo de migración:** `supabase/migrations/202611230011_fix_search_path.sql`

**Problema:** `i_am_platform_admin` y `admin_list_all_companies` tienen `SECURITY DEFINER` pero no `set search_path=''`. Una función SECURITY DEFINER que resuelve objetos de base de datos en un `search_path` no explícito puede ejecutar código malicioso si el schema público es manipulado.

**Cambio propuesto:**

```sql
-- Reemplazar ambas funciones con la misma lógica + search_path correcto

CREATE OR REPLACE FUNCTION public.i_am_platform_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''  -- AÑADIR
AS $$
  SELECT app_private.is_platform_admin();
$$;

CREATE OR REPLACE FUNCTION public.admin_list_all_companies()
RETURNS TABLE(id uuid, name text, tax_id text, active boolean, created_at timestamptz)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''  -- AÑADIR
AS $$
  SELECT c.id, c.name, c.tax_id, c.active, c.created_at
  FROM public.companies c
  WHERE app_private.is_platform_admin();
$$;

-- REVOKE/GRANT intactos (ya existen en mig_004 — no tocar)
```

**Tests de regresión:** Verificar que llamadas existentes a `i_am_platform_admin()` y `admin_list_all_companies()` siguen retornando los mismos resultados. No hay cambio funcional — solo corrección de `SET search_path`.

**Riesgo:** Muy bajo — cambio de un atributo de sesión en funciones de solo lectura que ya delegan a funciones con `search_path=''` correcto.

---

## Propuesta 2 — GAP-SEC-01: Restricción de `audit_events` para técnicos

**Archivo de migración:** `supabase/migrations/202611230012_audit_events_tech_filter.sql`

**Problema:** Técnicos pueden leer todos los `audit_events` de su empresa, incluyendo `event_payload` con campos `before`/`after` que contienen PII de contactos, perfiles y otros miembros. Amplifica GAP-11.

**Por qué filtrar por `event_type` no es suficiente:**

Filtrar el acceso del técnico a ciertos `event_type` no elimina el riesgo: eventos operacionales (ej. `order_updated`, `order_technician_assigned`) también pueden contener datos sensibles en `event_payload` si su payload incluye campos de la fila antes/después de la operación. El filtrado por tipo restringe el acceso pero no garantiza que lo que sí pasa sea inocuo.

**Decisión de diseño:** Negar acceso al técnico a `audit_events` directamente. Ofrecer una RPC o vista con campos explícitamente permitidos y sin `event_payload`.

**Opciones:**

| Opción | Descripción | Ventajas | Desventajas |
|--------|-------------|----------|-------------|
| A — Negar acceso completo a técnicos en `audit_events` | Remover técnicos de la política `audit_read` | Elimina exposición de `event_payload` completamente | Si existe UI de técnico que muestra historial de auditoría, se rompe |
| B — RPC `tech_get_my_audit_events()` | Función SECURITY DEFINER que retorna (`event_type`, `recorded_at`, `actor_user_id`) SIN `event_payload` para el técnico autenticado | Superficie de datos explícita y controlada | Requiere actualizar `useRealData.ts` si el cliente consulta `audit_events` directamente |

**Decisión (ChatGPT 23/11/2026): solo la restricción. No agregar RPC.**

Razón: `tech_get_my_audit_events()` devuelve eventos de empresa completa, no solo del técnico autenticado. `actor_user_id` expone identificadores de otros usuarios. El portal técnico no tiene UI de historial de auditoría — no hay requerimiento operativo. Si surge uno en el futuro, la consulta debe limitarse a las órdenes asignadas al técnico, no a la empresa completa.

**Propuesta (implementación en mig 012):**

```sql
-- Reemplazar política audit_read: técnicos ya NO tienen acceso a audit_events
DROP POLICY IF EXISTS audit_read ON public.audit_events;

CREATE POLICY audit_read ON public.audit_events
  FOR SELECT TO authenticated
  USING (
    app_private.is_platform_admin()
    OR app_private.has_membership(company_id, ARRAY['admin']::public.member_role[])
    -- Técnicos: removidos. Acceso directo a audit_events denegado.
  );
```

**Tests requeridos:**
- Técnico A: `SELECT * FROM audit_events WHERE company_id = A` → 0 filas (política RLS)
- Técnico A: `SELECT * FROM audit_events WHERE event_type = 'order_created'` → 0 filas
- Admin A: `SELECT * FROM audit_events WHERE company_id = A` → filas completas incluyendo `event_payload`
- Platform admin: `SELECT * FROM audit_events` → filas de todas las empresas

**Riesgo:** Medio — cambio en RLS policy activa. Verificar que `useRealData.ts` no tiene queries directas a `audit_events` para el rol técnico (ninguna encontrada en el análisis estático — el técnico no tiene UI de auditoría actual). Si existe una, debe migrarse a la RPC.

---

## Propuesta 3 — GAP-SEC-02: Trigger de trazabilidad para `customer_observations`

**Archivo de migración:** `supabase/migrations/202611230013_observations_audit_trigger.sql`

**Problema:** El INSERT directo en `customer_observations` no genera un evento en `audit_events`. Si hay abuso o error, no hay trazabilidad de quién insertó qué observación ni cuándo.

**Cambio propuesto:** Trigger AFTER INSERT en `customer_observations` que inserta en `audit_events`.

```sql
CREATE OR REPLACE FUNCTION app_private.observations_audit_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.audit_events (
    company_id,
    actor_user_id,
    event_type,
    event_payload,
    idempotency_key
  ) VALUES (
    NEW.company_id,
    NEW.author_user_id,
    'observation_created',
    jsonb_build_object(
      'observation_id', NEW.id,
      'gate_id', NEW.gate_id
      -- Nota: no incluir NEW.body para no duplicar el contenido del texto libre en audit_events
    ),
    gen_random_uuid()
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER observations_audit
  AFTER INSERT ON public.customer_observations
  FOR EACH ROW
  EXECUTE FUNCTION app_private.observations_audit_trigger();
```

**Decisión de diseño:** El payload del evento de auditoría incluye `observation_id` y `gate_id` pero NO el contenido de `body`. Razón: `body` es texto libre que puede contener PII — almacenarlo en `audit_events.event_payload` amplificaría GAP-11 en lugar de reducirlo.

**Corrección de diseño — trigger AFTER INSERT y atomicidad:**

Un trigger AFTER INSERT que lanza una excepción **revierte la transacción completa**, incluyendo el INSERT original. La frase anterior "trigger AFTER → no bloquea la escritura" era incorrecta.

La decisión es explícita: **auditoría obligatoria y atómica**. Si el trigger falla, el INSERT también falla. Esta es la semántica correcta para un sistema de trazabilidad — una observación sin registro de auditoría es indeseable. No se implementa manejo de excepciones en el trigger para "ignorar" fallos de auditoría.

Consecuencia para pruebas: si `audit_events` está llena, bloqueada o su trigger `audit_immutable` produce un conflicto, el INSERT en `customer_observations` también fallará. Esto es aceptable y esperado.

**Tests requeridos:**
- INSERT en `customer_observations` → `audit_events` recibe fila con `event_type='observation_created'`
- Payload tiene `observation_id` y `gate_id` pero NO `body`
- Si el INSERT de auditoría falla (simulando constraint violation) → el INSERT de observación también se revierte
- El trigger no puede ser desactivado por `authenticated` (es SECURITY DEFINER en `app_private`)

**Riesgo:** Bajo — trigger AFTER con atomicidad explícita. El riesgo de regresión es que si `audit_events` tiene algún constraint que falle inesperadamente (ej. `idempotency_key` duplicado con `gen_random_uuid()` — probabilidad prácticamente nula), el INSERT de observación también fallará. Monitorear en staging.

---

## Propuesta 4 — GAP-SEC-03: Restricción de `service_orders.notes` para clientes

**Archivo de migración:** `supabase/migrations/202611230014_service_orders_notes_access.sql`

**Problema:** La política `service_orders_member_read` (mig 010) expone `service_orders.*` a todos los miembros de la empresa — incluyendo técnicos y clientes — lo que incluye el campo `notes` con información operacional interna sensible.

**Por qué el enfoque de vista + doble política falló (decisión ChatGPT 23/11/2026):**

La propuesta anterior (vista `service_orders_member_view` + política separada en tabla base para técnicos) tiene una falla fundamental: PostgreSQL combina políticas permisivas con OR. Si existe una política permisiva para técnicos en `service_orders`, los técnicos pueden consultar la tabla base directamente y leer `notes`, ignorando la vista completamente. `security_invoker=true` no ayuda — solo aplica las políticas existentes del usuario sobre la tabla base; si esas políticas permiten el acceso, el acceso ocurre.

La solución correcta requiere separación a nivel de schema: notas internas en una tabla con RLS admin-only.

**Decisión: Opción C — tabla separada `service_order_internal_notes`.**

**Propuesta correcta (mig 014):**

```sql
-- 1. Nueva tabla: solo admins y platform_admin pueden leer
CREATE TABLE public.service_order_internal_notes (
  id               uuid primary key default gen_random_uuid(),
  service_order_id uuid not null references public.service_orders(id),
  company_id       uuid not null references public.companies(id),
  content          text not null check(length(trim(content)) between 1 and 5000),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  UNIQUE(service_order_id)  -- una nota por orden
);

ALTER TABLE public.service_order_internal_notes ENABLE ROW LEVEL SECURITY;
REVOKE INSERT, UPDATE, DELETE ON public.service_order_internal_notes FROM anon, authenticated;
GRANT SELECT ON public.service_order_internal_notes TO authenticated;

CREATE POLICY soin_admin_read ON public.service_order_internal_notes
  FOR SELECT TO authenticated
  USING (
    app_private.is_platform_admin()
    OR app_private.has_membership(company_id, ARRAY['admin']::public.member_role[])
  );

-- 2. RPC de escritura para administradores
CREATE OR REPLACE FUNCTION public.admin_set_service_order_note(
  p_company_id uuid, p_service_order_id uuid, p_content text
) RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT (app_private.is_platform_admin()
          OR app_private.has_membership(p_company_id, ARRAY['admin']::public.member_role[])) THEN
    RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
  END IF;
  -- upsert o delete según p_content
END;
$$;

-- 3. Backfill desde service_orders.notes
INSERT INTO public.service_order_internal_notes (service_order_id, company_id, content)
SELECT id, company_id, notes FROM public.service_orders
WHERE notes IS NOT NULL AND trim(notes) <> '';

-- 4. Limpiar service_orders.notes
UPDATE public.service_orders SET notes = NULL WHERE notes IS NOT NULL;
```

**TypeScript changes required (separate deploy):**
- Admin hooks: añadir query a `service_order_internal_notes` para el campo notes
- Admin UI: renderizar notes desde `service_order_internal_notes`, no desde `service_orders`
- `TechnicianPortal.tsx`: remover `{o.notes && <p>...</p>}` — el campo queda NULL
- Admin: usar `admin_set_service_order_note()` al crear/editar órdenes

**Tests requeridos:**
- Admin A: `SELECT * FROM service_order_internal_notes WHERE company_id = A` → filas con contenido (backfill de service_orders.notes)
- Tech A: `SELECT * FROM service_order_internal_notes WHERE company_id = A` → 0 filas (RLS admin-only)
- Tech A: `SELECT notes FROM service_orders WHERE company_id = A` → todas las filas con `notes = NULL`
- Admin A: llama `admin_set_service_order_note(A, order_A_id, 'Texto')` → upsert correcto
- Admin B: llama `admin_set_service_order_note(A, order_A_id, 'Evil')` → 42501

**Riesgo:** Medio — el campo `service_orders.notes` queda NULL en producción tras el backfill. Los hooks TypeScript que leen notas del admin deben actualizarse en un deploy posterior. El portal técnico queda sin impacto visual (campo ya no devuelve contenido).

---

## Propuesta 5 — GAP-01: Storage con bucket privado

**Archivo de migración:** `supabase/migrations/202611230015_storage_bucket_policy.sql`

**Problema:** `report_versions.private_storage_path` referencia archivos en Supabase Storage pero no existe ninguna configuración de bucket en `config.toml`. El riesgo real depende de si el bucket existe en el proyecto remoto y si tiene acceso público — no verificado.

**Verificación requerida antes de implementar:**

1. Acceder al Supabase dashboard del proyecto remoto
2. Comprobar si existe un bucket (ej. `reports`) bajo Storage
3. Verificar si es público o privado
4. Si existe y es público → requiere corrección urgente
5. Si no existe → `private_storage_path` apunta a rutas inválidas (riesgo de dato inválido, no de acceso)

**Propuesta de bucket policy (para cuando se verifique el entorno remoto):**

**Tres preguntas que deben responderse antes de implementar:**

1. **¿Quién crea los archivos?** Si solo `service_role` puede hacer uploads (desde una Edge Function o backend), el path es server-controlled. Si `authenticated` puede hacer uploads, el usuario puede elegir el path — lo que invalida cualquier política que extraiga `company_id` del path.

2. **¿Qué paths puede elegir el uploader?** La política `reports_read_admin_only` extrae `company_id` del primer segmento del path. Si el uploader (aunque sea service_role) puede elegir arbitrariamente el path, puede crear `{company_id_de_B}/{...}` y habilitar acceso cruzado. La convención de path debe ser server-enforced, no solo asumida por la política de lectura.

3. **¿Existen políticas permisivas adicionales?** Supabase crea políticas de Storage por defecto en algunos casos. Una política restrictiva no neutraliza otras políticas permisivas — PostgreSQL aplica `OR` entre políticas del mismo tipo.

**Verificación correcta de políticas (corrección ChatGPT 23/11/2026):**

Para inspeccionar las políticas RLS de `storage.objects` usar `pg_policies`, no `storage.policies`:

```sql
-- Ver todas las políticas RLS sobre storage.objects
SELECT schemaname, tablename, policyname, cmd, roles, qual, with_check
FROM pg_policies
WHERE schemaname = 'storage' AND tablename = 'objects';
```

**No ejecutar `DELETE FROM storage.policies`** — no es una tabla de catálogo de políticas RLS de PostgreSQL.

**Sobre políticas dirigidas a `service_role`:**

Las políticas RLS con `TO service_role` no reemplazan los controles de autorización del servidor. `service_role` tiene `BYPASSRLS = true` en Supabase — sus queries ignoran todas las políticas RLS. Las políticas de Storage con `TO service_role` son ignoradas por el motor de Storage, que usa credenciales de service_role directamente. La validación de empresa, reporte y path debe hacerse **en el código servidor** (Edge Function o backend), no delegarse a políticas RLS de Storage.

**Propuesta de implementación segura (mig 015):**

```sql
-- 1. Bucket privado (config.toml para local; dashboard para producción)
-- [storage.buckets.reports]
-- public = false

INSERT INTO storage.buckets (id, name, public)
VALUES ('reports', 'reports', false)
ON CONFLICT (id) DO UPDATE SET public = false;

-- 2. Verificar políticas existentes antes de aplicar (no borrar sin confirmar):
-- SELECT schemaname, tablename, policyname, cmd, roles
-- FROM pg_policies
-- WHERE schemaname = 'storage' AND tablename = 'objects';

-- 3. INSERT solo desde service_role (backend server, Edge Function)
CREATE POLICY "reports_insert_service_role"
ON storage.objects FOR INSERT
TO service_role
WITH CHECK (bucket_id = 'reports');
-- Nota: esta política aplica al rol 'service_role' solo cuando BYPASSRLS = false,
-- que nunca es el caso en Supabase Cloud. El control real está en el backend.

-- 4. SELECT: solo admins pueden leer archivos de su empresa
-- PREREQUISITO: la convención de path es {company_id}/{report_id}/{filename}
CREATE POLICY "reports_read_admin_only"
ON storage.objects FOR SELECT
TO authenticated
USING (
  bucket_id = 'reports'
  AND app_private.has_membership(
    (storage.foldername(name))[1]::uuid,
    ARRAY['admin']::public.member_role[]
  )
);
```

**Verificación requerida antes de aplicar:**
1. `SELECT * FROM storage.policies WHERE bucket_id = 'reports'` — confirmar que no existen políticas permisivas previas
2. Confirmar que el código de generación de reportes usa service_role para el upload
3. Confirmar o implementar la convención de path `{company_id}/{report_id}/...` en el código de reportes
4. Confirmar que `private_storage_path` en `report_versions` sigue la misma convención

**Nota de nomenclatura:** La convención de path no está establecida en el código actual. `private_storage_path` en `report_versions` puede usar un formato diferente. Debe acordarse antes de implementar la política de lectura.

**Riesgo:** Crítico si el bucket existe y es público en producción. Bajo si el bucket no existe aún.

---

## Plan de implementación

| Migración | GAP | Prioridad | Dependencias | Estado |
|-----------|-----|-----------|-------------|--------|
| `011_fix_search_path.sql` | GAP-SEC-06 | Baja | Ninguna | **Creada** — no-op defensiva (funciones ya tenían `search_path=''`) |
| `012_audit_events_tech_filter.sql` | GAP-SEC-01 | Alta | mig_001 + mig_004 | **Creada** — solo restricción RLS, sin RPC |
| `013_observations_audit_trigger.sql` | GAP-SEC-02 | Media | mig_010 | **Creada** — trigger AFTER INSERT atómico |
| `014_service_orders_notes_access.sql` | GAP-SEC-03 | Media | mig_010 | **Creada** — tabla separada `service_order_internal_notes` |
| `015_storage_bucket_policy.sql` | GAP-01 | Crítico | Verificación remota primero | Propuesta — pendiente crear archivo

> **Producción permanece congelada.** Ninguna migración se aplica al proyecto remoto hasta aprobación explícita de ChatGPT tras revisión del set completo 011–015.

---

*Documento generado automáticamente a partir del estado del repositorio. No contiene datos de producción ni credenciales.*
