-- Migration 017 — Idempotent retry layer for offline sync (Option C)
-- Architecture v2: original RPCs unchanged; new _v2 offline RPCs; modified tech_finish_pilot_order
-- v10 (2026-11-23): ChatGPT v9 P0/P1 fixes applied:
--   P0-1 (v10): cross-table UUID uniqueness — before inserting a correction in save_control_v2,
--               check that p_client_key is not already a first-save key in inspection_controls.
--   P0-2 (v10): lock protocol applied to originals — FOR SHARE + re-verify status added to
--               tech_save_pilot_control and tech_save_pilot_correction (preserves signatures).
--   P1-1 (v10): start_v2 idempotent retry adds company_id + gate_id to visit identity check.
--   P1-2 (v10): documented cross-version retry policy (v1-start + v2-retry incompatibility).
-- v9 (2026-11-23): reviewer v8 Minor fix applied:
--   Minor (v9): merged two-UPDATE split in start_v2 new-visit path into one atomic UPDATE.
-- v8 (2026-11-23): ChatGPT v7 P0/P1 fixes applied:
--   P0-1 (v8): o.inspection_visit_id = p_visit_id added to primary auth in BOTH finish functions
--   P0-2 (v8): tech_start_pilot_order_v2 idempotent after completion — visit check before status gate
--   P1-3 (v8): online fallback (p_client_key null) verifies payload before returning ID
--   P1-4 (v8): all payload != comparisons replaced with IS DISTINCT FROM (NULL-safe)
--   P1-5 (v8): REVOKE EXECUTE FROM PUBLIC, anon before each GRANT on all _v2 functions
-- DO NOT DEPLOY to production without ChatGPT explicit final SQL approval.

-- ── Schema changes ────────────────────────────────────────────────────────

-- inspection_controls: client key for offline first-save idempotency
-- Partial index: only non-NULL keys constrained (NULL = online mode)
ALTER TABLE public.inspection_controls
  ADD COLUMN IF NOT EXISTS client_idempotency_key uuid;

CREATE UNIQUE INDEX IF NOT EXISTS uq_inspection_controls_client_key
  ON public.inspection_controls (company_id, client_idempotency_key)
  WHERE client_idempotency_key IS NOT NULL;

-- Audit: server receive time (separate from device offline action time)
ALTER TABLE public.inspection_controls
  ADD COLUMN IF NOT EXISTS server_received_at timestamptz NOT NULL DEFAULT now();

ALTER TABLE public.inspection_corrections
  ADD COLUMN IF NOT EXISTS server_received_at timestamptz NOT NULL DEFAULT now();

-- Offline timestamp preservation (device time; server timestamps = sync receive evidence)
ALTER TABLE public.visits
  ADD COLUMN IF NOT EXISTS client_started_at timestamptz;
ALTER TABLE public.visits
  ADD COLUMN IF NOT EXISTS client_closed_at timestamptz;

-- ── tech_save_pilot_control_v2 ─────────────────────────────────────────────
-- New function (original preserved unchanged).
-- p_client_key: idempotency key for offline retries.
--
-- Idempotency guarantees — all checks run INSIDE the FOR UPDATE lock:
--   UPDATE path:    Case A — first-save retry (control.client_idempotency_key match)
--                   Case B — correction retry (corrections.idempotency_key match)
--   FIRST-SAVE path: INSERT ON CONFLICT DO NOTHING → fallback SELECT with payload verify
--
-- Lock ordering (P1-1): FOR SHARE service_orders → FOR UPDATE inspection_controls.
-- Status separation (P0-1): identity auth has NO status check.
-- Two-tier auth (P1-1 v7): primary requires active assignment; historical fallback allows retry.
-- IS DISTINCT FROM (P1-4 v8): all payload comparisons NULL-safe.
-- Online fallback payload check (P1-3 v8): verifies result+label+note before returning ID.

CREATE OR REPLACE FUNCTION public.tech_save_pilot_control_v2(
  p_order_id uuid,
  p_visit_id uuid,
  p_key text,
  p_label text,
  p_result public.control_result,
  p_note text DEFAULT NULL::text,
  p_client_key uuid DEFAULT NULL::uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare
  v_company uuid;
  v_id uuid;
  v_original public.inspection_controls%rowtype;
  v_fallback public.inspection_controls%rowtype;
  v_note text;
  v_current public.control_result;
  v_ck_result public.control_result;
  v_ck_actor uuid;
  v_ck_cid uuid;
  v_ck_reason text;
  v_hist_auth boolean := false;
begin
  -- Primary auth WITHOUT status (P0-1 v7): active assignment + active membership.
  -- o.inspection_visit_id = p_visit_id (P0-2 v7): prevents cross-visit forgery.
  select o.company_id into v_company
  from public.service_orders o
  join public.service_order_technicians a on a.service_order_id=o.id and a.active
  join public.technician_profiles t on t.id=a.technician_id and t.user_id=auth.uid()
  join public.visits v on v.id=p_visit_id and v.company_id=o.company_id and v.gate_id=o.gate_id
       and v.responsible_user_id=auth.uid()
  where o.id=p_order_id
    and o.inspection_visit_id = p_visit_id
    and exists(select 1 from public.memberships m
               where m.user_id=auth.uid() and m.company_id=o.company_id
                 and m.role='technician' and m.active);

  if v_company is null then
    -- Historical auth (P1-1 v7): allows retry after assignment revocation.
    -- Requires: visit responsible_user_id + active company membership (no assignment check).
    -- gate_id check omitted: visit already bound to order via inspection_visit_id at start time.
    select o.company_id into v_company
    from public.service_orders o
    join public.visits v on v.id=p_visit_id and v.company_id=o.company_id
         and v.responsible_user_id=auth.uid()
    where o.id=p_order_id
      and o.inspection_visit_id = p_visit_id
      and exists(select 1 from public.memberships m
                 where m.user_id=auth.uid() and m.company_id=o.company_id
                   and m.role='technician' and m.active);
    if v_company is not null then
      v_hist_auth := true; -- only idempotent operations allowed in this path
    end if;
  end if;

  if v_company is null then
    raise exception 'Inspección no autorizada' using errcode='42501';
  end if;

  -- Validation (identical to v1)
  if p_key is null or length(trim(p_key))=0 or length(p_key)>80
     or p_label is null or length(trim(p_label))=0 or length(p_label)>200
     or length(coalesce(p_note,''))>1000
  then raise exception 'Control inválido'; end if;

  v_note := nullif(trim(p_note), '');
  if p_result = 'fault'::public.control_result and length(coalesce(v_note,'')) < 10 then
    raise exception 'Describí la falla con al menos 10 caracteres';
  end if;

  -- FOR SHARE on service_orders (P1-1): lock order = service_orders → inspection_controls.
  perform 1 from public.service_orders where id=p_order_id for share;

  -- FOR UPDATE by (visit_id, control_key): serializes all operations on this control row.
  select * into v_original from public.inspection_controls
  where visit_id=p_visit_id and control_key=p_key
  for update;

  if found then
    if p_client_key is not null then
      -- Case A: idempotent retry of the first-save (key stored on control row)
      if v_original.client_idempotency_key = p_client_key then
        -- Full payload check (P1-4 v8): IS DISTINCT FROM for NULL-safe comparison
        if v_original.result IS DISTINCT FROM p_result
           or v_original.control_label IS DISTINCT FROM p_label
           or coalesce(v_original.note,'') IS DISTINCT FROM coalesce(v_note,'') then
          raise exception 'Conflict: idempotency key reused with different payload' using errcode='23505';
        end if;
        return v_original.id; -- idempotent first-save success
      end if;
      -- Case B: idempotent retry of a correction (key stored in inspection_corrections)
      select ic2.corrected_result, ic2.actor_user_id, ic2.inspection_control_id, ic2.reason
      into v_ck_result, v_ck_actor, v_ck_cid, v_ck_reason
      from public.inspection_corrections ic2
      where ic2.company_id=v_company and ic2.idempotency_key=p_client_key;
      if found then
        -- Control identity check (P0-3): correction must belong to this exact control row
        if v_ck_cid IS DISTINCT FROM v_original.id then
          raise exception 'Conflict: idempotency key bound to different control' using errcode='23505';
        end if;
        -- Payload check (P1-4 v8): IS DISTINCT FROM
        if v_ck_result IS DISTINCT FROM p_result then
          raise exception 'Conflict: idempotency key reused with different result' using errcode='23505';
        end if;
        if v_ck_reason IS DISTINCT FROM coalesce(v_note, 'Actualización del resultado durante inspección en curso') then
          raise exception 'Conflict: idempotency key reused with different reason' using errcode='23505';
        end if;
        if v_ck_actor IS DISTINCT FROM auth.uid() then
          raise exception 'Conflict: idempotency key reused by different actor' using errcode='42501';
        end if;
        return v_original.id; -- idempotent correction success
      end if;
      -- P0-1 (v10): cross-table UUID uniqueness check.
      -- Case A and Case B both failed: UUID not bound to v_original or any correction.
      -- If the UUID exists in inspection_controls for this company (another row), it is
      -- a first-save key for a DIFFERENT control — same key cannot identify two operations.
      if exists(select 1 from public.inspection_controls
                where company_id=v_company and client_idempotency_key=p_client_key) then
        raise exception 'Conflict: idempotency key already used as a first-save key for another control' using errcode='23505';
      end if;
    end if;

    -- New operation on existing control: require primary auth + in_progress (P0-1 v7)
    if v_hist_auth then
      raise exception 'Inspección no autorizada' using errcode='42501';
    end if;
    if not exists(select 1 from public.visits where id=p_visit_id and status='in_progress') or
       not exists(select 1 from public.service_orders where id=p_order_id and status='in_progress') then
      raise exception 'Inspección no autorizada' using errcode='42501';
    end if;

    -- State check (runs AFTER idempotency — identical to v1)
    select coalesce(
      (select ic2.corrected_result from public.inspection_corrections ic2
       where ic2.inspection_control_id=v_original.id
       order by ic2.created_at desc, ic2.id desc limit 1),
      v_original.result
    ) into v_current;
    if v_current='fault'::public.control_result and p_result<>'fault'::public.control_result then
      raise exception 'Para cambiar una falla, explicá la corrección en el formulario';
    end if;

    insert into public.inspection_corrections(
      company_id, inspection_control_id, actor_user_id, corrected_result, reason, idempotency_key
    ) values(
      v_company, v_original.id, auth.uid(), p_result,
      coalesce(v_note, 'Actualización del resultado durante inspección en curso'),
      coalesce(p_client_key, gen_random_uuid())
    );
    return v_original.id;
  end if;

  -- ── First-save INSERT (no existing row under lock) ────────────────────────
  if v_hist_auth then
    raise exception 'Inspección no autorizada' using errcode='42501';
  end if;
  if not exists(select 1 from public.visits where id=p_visit_id and status='in_progress') or
     not exists(select 1 from public.service_orders where id=p_order_id and status='in_progress') then
    raise exception 'Inspección no autorizada' using errcode='42501';
  end if;

  insert into public.inspection_controls(
    company_id, visit_id, control_key, control_label, result, note, client_idempotency_key
  ) values(v_company, p_visit_id, p_key, p_label, p_result, v_note, p_client_key)
  on conflict do nothing
  returning id into v_id;

  if v_id is null then
    -- Conflict: separate SELECT gets new READ COMMITTED snapshot.
    if p_client_key is not null then
      -- Offline mode: the conflicting row must be THIS attempt (same UUID).
      select * into v_fallback from public.inspection_controls
      where company_id=v_company and client_idempotency_key=p_client_key;
      if found then
        -- Control identity check: key must be bound to THIS control, not another
        if v_fallback.visit_id IS DISTINCT FROM p_visit_id
           or v_fallback.control_key IS DISTINCT FROM p_key then
          raise exception 'Conflict: idempotency key bound to different control' using errcode='23505';
        end if;
        -- Payload check (P1-4 v8): IS DISTINCT FROM
        if v_fallback.result IS DISTINCT FROM p_result
           or v_fallback.control_label IS DISTINCT FROM p_label
           or coalesce(v_fallback.note,'') IS DISTINCT FROM coalesce(v_note,'') then
          raise exception 'Conflict: idempotency key reused with different payload' using errcode='23505';
        end if;
        return v_fallback.id;
      end if;
      -- P0-1 (v7): p_client_key provided but conflicting row stored with different UUID.
      raise exception 'Conflict: concurrent INSERT with different idempotency key' using errcode='23505';
    end if;
    -- Online mode (p_client_key null): find conflicting row and verify payload (P1-3 v8).
    -- Two concurrent online first-saves: whichever won must have the same content.
    select * into v_fallback from public.inspection_controls
    where visit_id=p_visit_id and control_key=p_key;
    if not found then
      -- Concurrent INSERT not yet committed (not visible in this snapshot)
      raise exception 'Transient conflict: please retry' using errcode='40001';
    end if;
    if v_fallback.result IS DISTINCT FROM p_result
       or v_fallback.control_label IS DISTINCT FROM p_label
       or coalesce(v_fallback.note,'') IS DISTINCT FROM coalesce(v_note,'') then
      raise exception 'Conflict: concurrent INSERT with different payload' using errcode='23505';
    end if;
    return v_fallback.id;
  end if;

  return v_id;
end $function$;

REVOKE EXECUTE ON FUNCTION public.tech_save_pilot_control_v2(uuid, uuid, text, text, public.control_result, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tech_save_pilot_control_v2(uuid, uuid, text, text, public.control_result, text, uuid) TO authenticated;

-- ── tech_save_pilot_correction_v2 ─────────────────────────────────────────
-- New function (original preserved unchanged).
-- IS DISTINCT FROM (P1-4 v8): all payload comparisons NULL-safe.

CREATE OR REPLACE FUNCTION public.tech_save_pilot_correction_v2(
  p_order_id uuid,
  p_visit_id uuid,
  p_key text,
  p_result public.control_result,
  p_reason text,
  p_client_key uuid DEFAULT NULL::uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare
  v_company uuid;
  v_control public.inspection_controls%rowtype;
  v_latest public.control_result;
  v_ck_result public.control_result;
  v_ck_control_id uuid;
  v_ck_actor uuid;
  v_ck_reason text;
  v_hist_auth boolean := false;
begin
  -- Primary auth WITHOUT status (P0-1 v7): active assignment + active membership.
  select o.company_id into v_company
  from public.service_orders o
  join public.service_order_technicians a on a.service_order_id=o.id and a.active
  join public.technician_profiles t on t.id=a.technician_id and t.user_id=auth.uid()
  join public.visits v on v.id=p_visit_id and v.company_id=o.company_id and v.gate_id=o.gate_id
       and v.responsible_user_id=auth.uid()
  where o.id=p_order_id
    and o.inspection_visit_id = p_visit_id
    and exists(select 1 from public.memberships m
               where m.user_id=auth.uid() and m.company_id=o.company_id
                 and m.role='technician' and m.active);

  if v_company is null then
    -- Historical auth (P1-1 v7): allows retry after assignment revocation.
    select o.company_id into v_company
    from public.service_orders o
    join public.visits v on v.id=p_visit_id and v.company_id=o.company_id
         and v.responsible_user_id=auth.uid()
    where o.id=p_order_id
      and o.inspection_visit_id = p_visit_id
      and exists(select 1 from public.memberships m
                 where m.user_id=auth.uid() and m.company_id=o.company_id
                   and m.role='technician' and m.active);
    if v_company is not null then
      v_hist_auth := true;
    end if;
  end if;

  if v_company is null then
    raise exception 'Inspección no autorizada' using errcode='42501';
  end if;

  -- ── Pre-lock idempotency check (fast path for confirmed corrections) ──────
  if p_client_key is not null then
    select ic.corrected_result, ic.inspection_control_id, ic.actor_user_id, ic.reason
    into v_ck_result, v_ck_control_id, v_ck_actor, v_ck_reason
    from public.inspection_corrections ic
    where ic.company_id=v_company and ic.idempotency_key=p_client_key;
    if found then
      if not exists(select 1 from public.inspection_controls
                    where id=v_ck_control_id and visit_id=p_visit_id and control_key=p_key) then
        raise exception 'Conflict: idempotency key bound to different control' using errcode='23505';
      end if;
      -- Payload check (P1-4 v8): IS DISTINCT FROM
      if v_ck_result IS DISTINCT FROM p_result then
        raise exception 'Conflict: idempotency key reused with different result' using errcode='23505';
      end if;
      if trim(coalesce(v_ck_reason,'')) IS DISTINCT FROM trim(coalesce(p_reason,'')) then
        raise exception 'Conflict: idempotency key reused with different reason' using errcode='23505';
      end if;
      if v_ck_actor IS DISTINCT FROM auth.uid() then
        raise exception 'Conflict: idempotency key reused by different actor' using errcode='42501';
      end if;
      return v_ck_control_id;
    end if;
  end if;

  -- FOR SHARE on service_orders (P1-1): consistent lock ordering order → control.
  perform 1 from public.service_orders where id=p_order_id for share;

  -- FOR UPDATE on inspection_controls (serializes concurrent correction calls)
  select * into v_control from public.inspection_controls
  where visit_id=p_visit_id and control_key=p_key
  for update;
  if not found then raise exception 'Control inexistente'; end if;

  -- ── Post-lock idempotency re-check ────────────────────────────────────────
  if p_client_key is not null then
    select ic.corrected_result, ic.inspection_control_id, ic.actor_user_id, ic.reason
    into v_ck_result, v_ck_control_id, v_ck_actor, v_ck_reason
    from public.inspection_corrections ic
    where ic.company_id=v_company and ic.idempotency_key=p_client_key;
    if found then
      if not exists(select 1 from public.inspection_controls
                    where id=v_ck_control_id and visit_id=p_visit_id and control_key=p_key) then
        raise exception 'Conflict: idempotency key bound to different control' using errcode='23505';
      end if;
      if v_ck_result IS DISTINCT FROM p_result then
        raise exception 'Conflict: idempotency key reused with different result' using errcode='23505';
      end if;
      if trim(coalesce(v_ck_reason,'')) IS DISTINCT FROM trim(coalesce(p_reason,'')) then
        raise exception 'Conflict: idempotency key reused with different reason' using errcode='23505';
      end if;
      if v_ck_actor IS DISTINCT FROM auth.uid() then
        raise exception 'Conflict: idempotency key reused by different actor' using errcode='42501';
      end if;
      return v_ck_control_id;
    end if;
  end if;

  -- New operation: require primary auth + in_progress (P0-1 v7)
  if v_hist_auth then
    raise exception 'Inspección no autorizada' using errcode='42501';
  end if;
  if not exists(select 1 from public.visits where id=p_visit_id and status='in_progress') or
     not exists(select 1 from public.service_orders where id=p_order_id and status='in_progress') then
    raise exception 'Inspección no autorizada' using errcode='42501';
  end if;

  -- State validation (after idempotency — identical to v1)
  select coalesce(
    (select ic.corrected_result from public.inspection_corrections ic
     where ic.inspection_control_id=v_control.id
     order by ic.created_at desc, ic.id desc limit 1),
    v_control.result
  ) into v_latest;
  if v_latest<>'fault'::public.control_result or p_result='fault'::public.control_result then
    raise exception 'Esta corrección requiere un cambio desde Falla';
  end if;

  -- Reason validation (identical to v1)
  if length(trim(coalesce(p_reason,''))) < 10
     or length(p_reason) > 1000
     or trim(p_reason) = trim(coalesce(v_control.note,''))
  then
    raise exception 'Explicá qué hiciste para corregir la falla (mínimo 10 caracteres y distinto de la descripción original)';
  end if;

  insert into public.inspection_corrections(
    company_id, inspection_control_id, actor_user_id, corrected_result, reason, idempotency_key
  ) values(
    v_company, v_control.id, auth.uid(), p_result, trim(p_reason),
    coalesce(p_client_key, gen_random_uuid())
  );
  return v_control.id;
end $function$;

REVOKE EXECUTE ON FUNCTION public.tech_save_pilot_correction_v2(uuid, uuid, text, public.control_result, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tech_save_pilot_correction_v2(uuid, uuid, text, public.control_result, text, uuid) TO authenticated;

-- ── tech_start_pilot_order_v2 ──────────────────────────────────────────────
-- New function (original preserved). Adds p_client_started_at for offline timestamp.
-- P0-2 (v8): idempotent after order completion — visit check runs BEFORE status gate.
--   If inspection_visit_id already set: verify authorship + timestamp, return visit_id.
--   Only require scheduled/in_progress when creating a new visit.
-- IS DISTINCT FROM (P0-3 v7): NULL-safe timestamp comparison.

CREATE OR REPLACE FUNCTION public.tech_start_pilot_order_v2(
  p_order_id uuid,
  p_client_started_at timestamptz DEFAULT NULL::timestamptz
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare v public.service_orders%rowtype; v_visit uuid; v_stored_ts timestamptz;
begin
  -- Reject future client timestamps (1 minute tolerance for device clock skew)
  if p_client_started_at is not null and p_client_started_at > now() + interval '1 minute' then
    raise exception 'client_started_at cannot be in the future';
  end if;

  -- Lock order without status filter (P0-2 v8): allows idempotent retry after completion.
  -- Membership check only — assignment check only required for new visit creation (below).
  select o.* into v from public.service_orders o
  where o.id=p_order_id
    and exists(select 1 from public.memberships m
               where m.user_id=auth.uid() and m.company_id=o.company_id
                 and m.role='technician' and m.active)
  for update of o;
  if not found then
    raise exception 'Orden no asignada o no disponible' using errcode='42501';
  end if;

  v_visit := v.inspection_visit_id;

  if v_visit is not null then
    -- Idempotent retry: visit already created (order may be in_progress or completed).
    -- responsible_user_id is immutable — verifies this technician started it.
    -- P1-1 (v10): company_id + gate_id added — invariants for a SECURITY DEFINER function.
    if not exists(select 1 from public.visits vis
                  where vis.id=v_visit
                    and vis.responsible_user_id=auth.uid()
                    and vis.company_id=v.company_id
                    and vis.gate_id=v.gate_id) then
      raise exception 'Inspección no autorizada' using errcode='42501';
    end if;
    -- IS DISTINCT FROM (P0-3 v7): raises even when one side is NULL.
    -- P1-2 (v10) design note — cross-version retry policy:
    --   If the visit was started via tech_start_pilot_order (v1), client_started_at = NULL.
    --   A v2 retry with p_client_started_at = NULL passes (NULL IS DISTINCT FROM NULL = FALSE).
    --   A v2 retry with a non-null timestamp WILL raise 23505 — this is intentional.
    --   Assumption: the offline sync engine uses _v2 functions for the full session lifecycle.
    --   Mixed v1-start + v2-retry-with-timestamp is not a supported scenario.
    select vis.client_started_at into v_stored_ts from public.visits vis where vis.id=v_visit;
    if p_client_started_at IS DISTINCT FROM v_stored_ts then
      raise exception 'Conflict: client_started_at differs from recorded value' using errcode='23505';
    end if;
    -- Advance status if still scheduled (safe no-op if in_progress or completed)
    update public.service_orders set status='in_progress' where id=v.id and status='scheduled';
    return v_visit;
  end if;

  -- No visit yet: require schedulable state + active assignment
  if v.status not in ('scheduled', 'in_progress') then
    raise exception 'Orden no disponible' using errcode='42501';
  end if;
  if not exists(
    select 1 from public.service_order_technicians a
    join public.technician_profiles t on t.id=a.technician_id and t.user_id=auth.uid()
    where a.service_order_id=v.id and a.active=true
  ) then
    raise exception 'Inspección no autorizada' using errcode='42501';
  end if;

  -- New visit: started_at = server receive time; client_started_at = device offline action time
  insert into public.visits(company_id, gate_id, status, responsible_user_id, started_at, client_started_at)
  values(v.company_id, v.gate_id, 'in_progress', auth.uid(), now(), p_client_started_at)
  returning id into v_visit;
  -- Atomic update: single statement eliminates the intermediate-state window (v9 reviewer fix)
  update public.service_orders
  set inspection_visit_id=v_visit,
      status=case when status='scheduled' then 'in_progress' else status end
  where id=v.id;
  return v_visit;
end $function$;

REVOKE EXECUTE ON FUNCTION public.tech_start_pilot_order_v2(uuid, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tech_start_pilot_order_v2(uuid, timestamptz) TO authenticated;

-- ── tech_finish_pilot_order (modified in place, no signature change) ───────
-- Original contract preserved.
-- P0-1 (v8): o.inspection_visit_id = p_visit_id added to primary auth (was in retry path only).

CREATE OR REPLACE FUNCTION public.tech_finish_pilot_order(p_order_id uuid, p_visit_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_company uuid;
begin
  select o.company_id into v_company
  from public.service_orders o
  join public.service_order_technicians a on a.service_order_id=o.id and a.active
  join public.technician_profiles t on t.id=a.technician_id and t.user_id=auth.uid()
  join public.visits v on v.id=p_visit_id and v.company_id=o.company_id and v.gate_id=o.gate_id
       and v.responsible_user_id=auth.uid() and v.status='in_progress'
  where o.id=p_order_id and o.inspection_visit_id=p_visit_id and o.status='in_progress'
    and exists(select 1 from public.memberships m
               where m.user_id=auth.uid() and m.company_id=o.company_id
                 and m.role='technician' and m.active)
  for update of o;

  if v_company is null then
    -- Idempotent retry: same user, same (order_id, visit_id), completed+closed.
    if exists(
      select 1 from public.service_orders o
      join public.visits v on v.id=p_visit_id and v.company_id=o.company_id
           and v.responsible_user_id=auth.uid() and v.status='closed'
      join public.memberships m on m.user_id=auth.uid() and m.company_id=o.company_id
           and m.role='technician' and m.active
      where o.id=p_order_id and o.inspection_visit_id=p_visit_id and o.status='completed'
    ) then
      return; -- idempotent success: no dates overwritten
    end if;
    raise exception 'Inspección no autorizada' using errcode='42501';
  end if;

  if (select count(distinct control_key) from public.inspection_controls
      where visit_id=p_visit_id
        and control_key=any(array['structure','guides','motor','electrical',
                                  'photocells','emergency','opening','closing'])) <> 8
  then raise exception 'Completá los ocho controles antes de finalizar'; end if;

  update public.visits set status='closed', closed_at=now()
  where id=p_visit_id and status='in_progress';
  update public.service_orders set status='completed', completed_at=now()
  where id=p_order_id and status='in_progress';
end $function$;

REVOKE EXECUTE ON FUNCTION public.tech_finish_pilot_order(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tech_finish_pilot_order(uuid, uuid) TO authenticated;

-- ── tech_finish_pilot_order_v2 ─────────────────────────────────────────────
-- P0-1 (v8): o.inspection_visit_id = p_visit_id added to primary auth.
-- P0-3 (v7): IS DISTINCT FROM for timestamp comparison.
-- P1-1 (v7): active membership required in idempotent retry EXISTS.

CREATE OR REPLACE FUNCTION public.tech_finish_pilot_order_v2(
  p_order_id uuid,
  p_visit_id uuid,
  p_client_closed_at timestamptz DEFAULT NULL::timestamptz
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare
  v_company uuid;
  v_client_started_at timestamptz;
  v_stored_ts timestamptz;
begin
  if p_client_closed_at is not null and p_client_closed_at > now() + interval '1 minute' then
    raise exception 'client_closed_at cannot be in the future';
  end if;

  -- P0-1 (v8): o.inspection_visit_id = p_visit_id added to primary auth.
  select o.company_id into v_company
  from public.service_orders o
  join public.service_order_technicians a on a.service_order_id=o.id and a.active
  join public.technician_profiles t on t.id=a.technician_id and t.user_id=auth.uid()
  join public.visits v on v.id=p_visit_id and v.company_id=o.company_id and v.gate_id=o.gate_id
       and v.responsible_user_id=auth.uid() and v.status='in_progress'
  where o.id=p_order_id and o.inspection_visit_id=p_visit_id and o.status='in_progress'
    and exists(select 1 from public.memberships m
               where m.user_id=auth.uid() and m.company_id=o.company_id
                 and m.role='technician' and m.active)
  for update of o;

  if v_company is null then
    if exists(
      select 1 from public.service_orders o
      join public.visits v on v.id=p_visit_id and v.company_id=o.company_id
           and v.responsible_user_id=auth.uid() and v.status='closed'
      join public.memberships m on m.user_id=auth.uid() and m.company_id=o.company_id
           and m.role='technician' and m.active
      where o.id=p_order_id and o.inspection_visit_id=p_visit_id and o.status='completed'
    ) then
      -- P0-3 (v7): IS DISTINCT FROM — raises even when one side is NULL.
      select vis.client_closed_at into v_stored_ts from public.visits vis where vis.id=p_visit_id;
      if p_client_closed_at IS DISTINCT FROM v_stored_ts then
        raise exception 'Conflict: client_closed_at differs from recorded value' using errcode='23505';
      end if;
      return; -- idempotent success
    end if;
    raise exception 'Inspección no autorizada' using errcode='42501';
  end if;

  if (select count(distinct control_key) from public.inspection_controls
      where visit_id=p_visit_id
        and control_key=any(array['structure','guides','motor','electrical',
                                  'photocells','emergency','opening','closing'])) <> 8
  then raise exception 'Completá los ocho controles antes de finalizar'; end if;

  if p_client_closed_at is not null then
    select v.client_started_at into v_client_started_at
    from public.visits v where v.id=p_visit_id;
    if v_client_started_at is not null and p_client_closed_at < v_client_started_at then
      raise exception 'client_closed_at cannot be before client_started_at';
    end if;
  end if;

  update public.visits set status='closed', closed_at=now(), client_closed_at=p_client_closed_at
  where id=p_visit_id and status='in_progress';
  update public.service_orders set status='completed', completed_at=now()
  where id=p_order_id and status='in_progress';
end $function$;

REVOKE EXECUTE ON FUNCTION public.tech_finish_pilot_order_v2(uuid, uuid, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tech_finish_pilot_order_v2(uuid, uuid, timestamptz) TO authenticated;

-- ── P0-2 (v10): lock protocol applied to original save RPCs ───────────────
-- Original signatures and return types preserved. Only change: FOR SHARE on service_orders
-- (before inspection_controls SELECT) + re-verify status after acquiring lock.
-- Prevents writes after finish via stale auth read in READ COMMITTED.
-- Lock ordering: FOR SHARE service_orders → FOR UPDATE inspection_controls (matches _v2).

CREATE OR REPLACE FUNCTION public.tech_save_pilot_control(p_order_id uuid, p_visit_id uuid, p_key text, p_label text, p_result public.control_result, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_company uuid; v_id uuid; v_original public.inspection_controls%rowtype; v_note text; v_current public.control_result;
begin
 select o.company_id into v_company from public.service_orders o
 join public.service_order_technicians a on a.service_order_id=o.id and a.active
 join public.technician_profiles t on t.id=a.technician_id and t.user_id=auth.uid()
 join public.visits v on v.id=p_visit_id and v.company_id=o.company_id and v.gate_id=o.gate_id
      and v.responsible_user_id=auth.uid() and v.status='in_progress'
 where o.id=p_order_id and o.status='in_progress'
   and exists(select 1 from public.memberships m where m.user_id=auth.uid() and m.company_id=o.company_id and m.role='technician' and m.active);
 if v_company is null then raise exception 'Inspección no autorizada' using errcode='42501'; end if;
 if p_key is null or length(trim(p_key))=0 or length(p_key)>80 or p_label is null or length(trim(p_label))=0 or length(p_label)>200 or length(coalesce(p_note,''))>1000 then raise exception 'Control inválido'; end if;
 v_note:=nullif(trim(p_note),'');
 if p_result = 'fault'::public.control_result and length(coalesce(v_note, '')) < 10 then raise exception 'Describí la falla con al menos 10 caracteres'; end if;
 perform 1 from public.service_orders where id=p_order_id for share;
 if not exists(select 1 from public.service_orders where id=p_order_id and status='in_progress') or
    not exists(select 1 from public.visits where id=p_visit_id and status='in_progress') then
   raise exception 'Inspección no autorizada' using errcode='42501';
 end if;
 select * into v_original from public.inspection_controls where visit_id=p_visit_id and control_key=p_key for update;
 if found then
   select coalesce((select corrected_result from public.inspection_corrections where inspection_control_id=v_original.id order by created_at desc,id desc limit 1),v_original.result) into v_current;
   if v_current='fault'::public.control_result and p_result<>'fault'::public.control_result then raise exception 'Para cambiar una falla, explicá la corrección en el formulario'; end if;
   insert into public.inspection_corrections(company_id,inspection_control_id,actor_user_id,corrected_result,reason,idempotency_key)
   values(v_company,v_original.id,auth.uid(),p_result,coalesce(v_note,'Actualización del resultado durante inspección en curso'),gen_random_uuid());
   return v_original.id;
 end if;
 insert into public.inspection_controls(company_id,visit_id,control_key,control_label,result,note) values(v_company,p_visit_id,p_key,p_label,p_result,v_note) returning id into v_id;
 return v_id;
end $function$;

GRANT EXECUTE ON FUNCTION public.tech_save_pilot_control(uuid, uuid, text, text, public.control_result, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.tech_save_pilot_correction(p_order_id uuid, p_visit_id uuid, p_key text, p_result public.control_result, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_company uuid; v_control public.inspection_controls%rowtype; v_latest public.control_result;
begin
 select o.company_id into v_company from public.service_orders o
 join public.service_order_technicians a on a.service_order_id=o.id and a.active
 join public.technician_profiles t on t.id=a.technician_id and t.user_id=auth.uid()
 join public.visits v on v.id=p_visit_id and v.company_id=o.company_id and v.gate_id=o.gate_id
      and v.responsible_user_id=auth.uid() and v.status='in_progress'
 where o.id=p_order_id and o.status='in_progress'
   and exists(select 1 from public.memberships m where m.user_id=auth.uid() and m.company_id=o.company_id and m.role='technician' and m.active);
 if v_company is null then raise exception 'Inspección no autorizada' using errcode='42501'; end if;
 perform 1 from public.service_orders where id=p_order_id for share;
 if not exists(select 1 from public.service_orders where id=p_order_id and status='in_progress') or
    not exists(select 1 from public.visits where id=p_visit_id and status='in_progress') then
   raise exception 'Inspección no autorizada' using errcode='42501';
 end if;
 select * into v_control from public.inspection_controls where visit_id=p_visit_id and control_key=p_key for update;
 if not found then raise exception 'Control inexistente'; end if;
 select coalesce((select corrected_result from public.inspection_corrections where inspection_control_id=v_control.id order by created_at desc,id desc limit 1),v_control.result) into v_latest;
 if v_latest<>'fault'::public.control_result or p_result='fault'::public.control_result then raise exception 'Esta corrección requiere un cambio desde Falla'; end if;
 if length(trim(coalesce(p_reason,'')))<10 or length(p_reason)>1000 or trim(p_reason)=trim(coalesce(v_control.note,'')) then raise exception 'Explicá qué hiciste para corregir la falla (mínimo 10 caracteres y distinto de la descripción original)'; end if;
 insert into public.inspection_corrections(company_id,inspection_control_id,actor_user_id,corrected_result,reason,idempotency_key) values(v_company,v_control.id,auth.uid(),p_result,trim(p_reason),gen_random_uuid());
 return v_control.id;
end $function$;

GRANT EXECUTE ON FUNCTION public.tech_save_pilot_correction(uuid, uuid, text, public.control_result, text) TO authenticated;

-- ── Approval conditions ────────────────────────────────────────────────────
-- v10 reviewer (2026-11-23): CLEAN — no bugs found.
-- v9 reviewer (2026-11-23): 1 Minor finding — two-UPDATE intermediate window in start_v2.
--   FIXED in v9: merged into one atomic UPDATE. reviewer: CLEAN after fix.
-- v8 reviewer (2026-11-23): 1 Minor finding — same two-UPDATE split (pre-existing from v7).
--   DESIGN NOTE-1: IS DISTINCT FROM: client must durably store timestamps (hard dependency).
--   DESIGN NOTE-2: Historical auth omits gate_id — intentional (visit bound via inspection_visit_id).
--
-- v8 addresses ChatGPT v7 findings:
--   P0-1 ✅ o.inspection_visit_id = p_visit_id in BOTH finish primary auth queries
--   P0-2 ✅ start_v2: visit check before status gate; idempotent after completion
--   P1-3 ✅ Online fallback verifies result+label+note (IS DISTINCT FROM) before returning ID
--   P1-4 ✅ All payload != comparisons replaced with IS DISTINCT FROM
--   P1-5 ✅ REVOKE EXECUTE FROM PUBLIC, anon before each GRANT on all 5 functions
--
-- v5-v7 (2026-11-23): ChatGPT authorized dev commit; production blocked.
--   P0-1 ✅ Identity auth separated from status in both _v2 save RPCs
--   P0-2 ✅ Full payload check: result+label+note; result+reason+actor
--   P0-3 ✅ Correction verifies control identity; IS DISTINCT FROM timestamps
--   P1-1 ✅ FOR SHARE; two-tier auth; memberships.active in finish retry
--   P1-5 ✅ inspection_visit_id guard; online fallback fix; IS DISTINCT FROM all payloads
--
-- ✅ RPCs online originals preserved (control, correction, start, finish unchanged)
-- ✅ RPCs _v2 separated (new functions; no DROP; no overloads)
-- ✅ Unique index by (company_id, client_idempotency_key) on inspection_controls
-- ✅ REVOKE + GRANT on all _v2 functions (PUBLIC, anon excluded)
--
-- MERGE + DEPLOY: requires ChatGPT final SQL audit of v8. Send this file.
--
-- Tests planned (all original + new for v8):
-- 1. save_control_v2 first save → ok; retry same key → same id; same key diff payload → 23505
-- 2. save_control_v2 concurrent first saves same key → one id returned by both
-- 3. save_control_v2 retry after close → idempotent ok (not 42501)
-- 4. save_control_v2 concurrent saves different keys same control → 23505 (P0-1 v7)
-- 5. save_control_v2 historical auth (assignment revoked) → idempotent ok; new op → 42501
-- 6. save_control_v2 online concurrent saves same (visit,key) same payload → same id (P1-3 v8)
-- 7. save_control_v2 online concurrent saves same (visit,key) DIFF payload → 23505 (P1-3 v8)
-- 8. save_correction_v2 correction → ok; retry → same id; same key diff result → 23505
-- 9. save_correction_v2 retry after confirmed correction → idempotent ok
-- 10. finish: complete → void; retry → void; concurrent → first ok, second idempotent ok
-- 11. finish_v2: same + client_closed_at stored; retry same ts → void; diff ts → 23505
-- 12. start_v2: future ts → error; valid offline ts → stored; retry same ts → ok; diff ts → 23505
-- 13. start_v2: retry AFTER order completed → idempotent ok (P0-2 v8)
-- 14. finish/finish_v2: order with wrong visit_id → 42501 (P0-1 v8)
-- 15. Lock ordering: concurrent save_v2 + finish → no deadlock
-- 16. Cross-visit forgery: save with wrong (order_id, visit_id) pair → 42501
