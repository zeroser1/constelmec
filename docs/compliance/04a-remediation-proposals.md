# Constelmec — Fase 4A: Propuestas de Remediación de Seguridad

**Versión:** 1.0.0  
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

**Opciones:**

| Opción | Descripción | Ventajas | Desventajas |
|--------|-------------|----------|-------------|
| A — Filtrar por `event_type` en RLS | Política RLS para técnicos limita a eventos operacionales (`order_*`, `qr_*`, `assignment_*`) | Simple, no cambia el schema | La lista de tipos debe mantenerse explícita; nuevos tipos de eventos podrían no incluirse |
| B — Crear vista `audit_events_tech_view` | Vista que enmascara `event_payload` y filtra por tipos permitidos para técnicos | No expone PII nunca, payload simplificado | Requiere actualizar las consultas del cliente si leen `audit_events` directamente |
| C — Enmascarar `event_payload` en RLS | Política con `CASE` que retorna `event_payload` sin campos `before`/`after` para técnicos | Mismo schema | Más complejo; PostgreSQL RLS no soporta transformaciones de columna — requiere vista |

**Recomendación: Opción A (corto plazo) + Opción B (largo plazo).**

**Propuesta Opción A (implementación en 011):**

```sql
-- Reemplazar la política audit_read para técnicos con una más restrictiva
-- Tipos de eventos OPERACIONALES (técnico no ve before/after de datos de contacto/empresa):
-- order_*, qr_*, gate_*, assignment_* → SÍ
-- company_*, contact_*, facility_*, technician_profile_* → NO para técnicos (contienen PII)

ALTER POLICY audit_read ON public.audit_events
  USING (
    app_private.is_platform_admin()
    OR (
      app_private.has_membership(company_id, ARRAY['admin']::public.member_role[])
    )
    OR (
      -- Técnicos: solo eventos operacionales propios o de órdenes asignadas
      app_private.has_membership(company_id, ARRAY['technician']::public.member_role[])
      AND event_type = ANY(ARRAY[
        'order_created', 'order_updated', 'order_completed',
        'gate_qr_issued', 'gate_qr_revoked',
        'order_technician_assigned', 'order_technician_removed',
        'technician_company_enabled', 'technician_company_disabled'
      ])
    )
  );
```

**Tests requeridos:**
- Técnico A no puede leer eventos de tipo `contact_created`, `contact_updated`, `company_created`
- Técnico A sí puede leer eventos de tipo `order_created`, `gate_qr_issued`
- Admin A puede leer todos los tipos de eventos de Empresa A
- Platform admin puede leer todos los tipos de todas las empresas

**Riesgo:** Medio — cambio en RLS policy activa. Si hay lógica del cliente que espera que el técnico vea todos los tipos, puede romperse. Requiere revisión de `useRealData.ts` para confirmar qué queries de `audit_events` hace el cliente para el rol técnico (ninguna encontrada en el análisis estático — el técnico no tiene UI de auditoría actual).

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

**Decisión de diseño:** El payload del evento de auditoría incluye `observation_id` y `gate_id` pero NO el contenido de `body`. Razón: `body` es texto libre que puede contener PII — almacenarlo en `audit_events.event_payload` amplificaría GAP-11 en lugar de reducirlo. La trazabilidad de quién insertó qué observación es suficiente con el `observation_id`.

**Tests requeridos:**
- INSERT en `customer_observations` → `audit_events` recibe fila con `event_type='observation_created'`
- Payload tiene `observation_id` y `gate_id` pero NO `body`
- Fallo en trigger no silencia el INSERT (trigger AFTER → no bloquea la escritura)
- El trigger no puede ser desactivado por `authenticated` (es SECURITY DEFINER en `app_private`)

**Riesgo:** Bajo — trigger AFTER no afecta el comportamiento del INSERT original. El único riesgo es un fallo en el trigger que podría lanzar una excepción y revertir el INSERT; para mitigar, se puede usar `EXECUTE PROCEDURE ... COST 100` en modo permisivo, o manejar excepciones dentro del trigger.

---

## Propuesta 4 — GAP-SEC-03: Restricción de `service_orders.notes` para clientes

**Archivo de migración:** `supabase/migrations/202611230014_service_orders_notes_access.sql`

**Problema:** La política `service_orders_member_read` (mig 010) expone `service_orders.*` a todos los miembros de la empresa — incluyendo clientes (`role='customer'`) — lo que incluye el campo `notes` con potencial información operacional sensible.

**Opciones:**

| Opción | Descripción | Ventajas | Desventajas |
|--------|-------------|----------|-------------|
| A — Crear política separada por rol | Reemplazar `service_orders_member_read` con dos políticas: admins ven todo; técnicos y clientes ven columnas limitadas | No requiere schema changes | PostgreSQL RLS no soporta column-level filtering en policies — requiere vista |
| B — Crear vista `service_orders_client_view` | Vista sin `notes` para miembros que no son admin | Limpia, explícita | El cliente (TypeScript) debe consultar la vista en lugar de la tabla base |
| C — Mover `notes` a tabla separada `service_order_notes` | Solo admins leen `service_order_notes` | Separación limpia de privilegios | Breaking change — requiere actualización de queries en `useRealData.ts` |

**Recomendación: Opción A con ajuste de policy + documentar como KNOWN_LIMITATION hasta que se implemente la vista.**

**Acción inmediata (Opción A simplificada):**

PostgreSQL RLS no filtra columnas individuales. La solución a corto plazo es documentar que el campo `notes` es visible a todos los miembros — y que hasta que se implemente una vista o se migre `notes` a tabla separada, el contenido de `notes` no debe contener datos sensibles de clientes. Esta restricción debe aplicarse en la UI (mostrar `notes` solo en el panel de admin) y documentarse como deuda técnica.

**Propuesta de migración (Opción B — para sprint siguiente):**

```sql
-- Vista que excluye `notes` para acceso de técnicos y clientes
-- (admins siguen consultando la tabla base vía RPC o directo con policy de admin)

CREATE VIEW public.service_orders_member_view AS
  SELECT
    id, company_id, facility_id, gate_id, service_type, status,
    scheduled_start, scheduled_end, completed_at, next_service_at,
    created_at, updated_at
    -- Sin: notes (visible solo a admin)
  FROM public.service_orders;

-- RLS en la vista heredada de la tabla base (PostgreSQL aplica RLS a la tabla, no a la vista)
-- La consulta del cliente debe ser ajustada a: supabase.from('service_orders_member_view').select(...)
```

**Riesgo:** Alto si se implementa como breaking change — requiere actualización de `useRealData.ts`. Recomendado como Fase 4B, no urgente para el sprint actual.

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

```sql
-- Declarar bucket privado en config.toml (Supabase local):
-- [storage.buckets.reports]
-- public = false

-- Política de acceso: solo admin de empresa puede leer su propio report
-- (en Supabase Cloud, las políticas de Storage se crean vía dashboard o CLI)

-- SQL equivalente (Supabase Storage usa schema `storage`):
INSERT INTO storage.buckets (id, name, public)
VALUES ('reports', 'reports', false)
ON CONFLICT (id) DO UPDATE SET public = false;

-- Política de lectura: solo miembros con rol admin pueden descargar archivos de su empresa
-- La convención de path debe incluir el company_id:
-- ej: reports/{company_id}/{report_id}/{filename}
-- La política verifica que el {company_id} en el path pertenezca al usuario

CREATE POLICY "reports_read_admin_only"
ON storage.objects FOR SELECT
TO authenticated
USING (
  bucket_id = 'reports'
  AND app_private.has_membership(
    (storage.foldername(name))[1]::uuid,  -- primer segmento del path = company_id
    ARRAY['admin']::public.member_role[]
  )
);

CREATE POLICY "reports_insert_service_role"
ON storage.objects FOR INSERT
TO service_role
WITH CHECK (bucket_id = 'reports');
```

**Nota de nomenclatura:** La convención `{company_id}/{report_id}/...` en los paths de Storage no está establecida en el código actual. Debe acordarse con el equipo antes de implementar la política, ya que `private_storage_path` en `report_versions` no sigue este patrón todavía.

**Riesgo:** Crítico si el bucket existe y es público en producción. Bajo si el bucket no existe aún.

---

## Plan de implementación

| Migración | GAP | Prioridad | Dependencias | Estado |
|-----------|-----|-----------|-------------|--------|
| `011_fix_search_path.sql` | GAP-SEC-06 | Baja | Ninguna | Propuesta — no creada |
| `012_audit_events_tech_filter.sql` | GAP-SEC-01 | Alta | mig_001 + mig_004 | Propuesta — no creada |
| `013_observations_audit_trigger.sql` | GAP-SEC-02 | Media | mig_010 | Propuesta — no creada |
| `014_service_orders_notes_access.sql` | GAP-SEC-03 | Media | mig_010 | Propuesta — Fase 4B recomendado |
| `015_storage_bucket_policy.sql` | GAP-01 | Crítico | Verificación remota primero | Propuesta — bloqueada por verificación |

> **Producción permanece congelada.** Ninguna migración se aplica al proyecto remoto hasta aprobación explícita de ChatGPT tras revisión del set completo 011–015.

---

*Documento generado automáticamente a partir del estado del repositorio. No contiene datos de producción ni credenciales.*
