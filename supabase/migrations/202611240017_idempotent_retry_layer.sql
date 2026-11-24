-- Migration 017 — Idempotent retry layer for offline sync (Option C)
-- Architecture v2: original RPCs unchanged; new _v2 offline RPCs; modified tech_finish_pilot_order
-- v7 (2026-11-23): ChatGPT v5 P0/P1 fixes + v6 P0/P1 fixes applied:
--   P0-1 (v5): fallback INSERT offline mode — raise 23505 when p_client_key provided but UUID not found
--   P0-2 (v5): o.inspection_visit_id = p_visit_id added to auth WHERE in both save _v2 RPCs
--   P0-3 (v5): IS DISTINCT FROM replaces <> for timestamp comparisons (NULL-safe)
--   P1-1 (v5): two-tier auth in save RPCs (historical fallback; active membership, no assignment)
--   P1-1 (v5): active membership required in finish idempotent retry EXISTS
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
--   Prevents deadlock with tech_finish_pilot_order (FOR UPDATE service_orders).
-- Status separation (P0-1): identity auth has NO status check.
--   New operations require in_progress; idempotent retries succeed after close.
-- Two-tier auth (P1-1 v7): primary requires active assignment; historical fallback allows retry
--   after assignment revocation (requires active company membership).

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
  -- Primary auth WITHOUT status (P0-1): active assignment + active membership.
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
  -- Blocks if finish holds FOR UPDATE on service_orders; prevents deadlock in reverse scenario.
  -- SHARE is compatible with concurrent _v2 saves.
  perform 1 from public.service_orders where id=p_order_id for share;

  -- FOR UPDATE by (visit_id, control_key): serializes all operations on this control row.
  -- All idempotency + status checks run INSIDE this lock.
  select * into v_original from public.inspection_controls
  where visit_id=p_visit_id and control_key=p_key
  for update;

  if found then
    if p_client_key is not null then
      -- Case A: idempotent retry of the first-save (key stored on control row)
      if v_original.client_idempotency_key = p_client_key then
        -- Full payload check (P0-2): result + label + note must all match
        if v_original.result != p_result
           or v_original.control_label != p_label
           or coalesce(v_original.note,'') != coalesce(v_note,'') then
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
        if v_ck_cid != v_original.id then
          raise exception 'Conflict: idempotency key bound to different control' using errcode='23505';
        end if;
        if v_ck_result != p_result then
          raise exception 'Conflict: idempotency key reused with different result' using errcode='23505';
        end if;
        -- Reason check: stored as coalesce(v_note, default) — must match same normalization
        if v_ck_reason != coalesce(v_note, 'Actualización del resultado durante inspección en curso') then
          raise exception 'Conflict: idempotency key reused with different reason' using errcode='23505';
        end if;
        if v_ck_actor != auth.uid() then
          raise exception 'Conflict: idempotency key reused by different actor' using errcode='42501';
        end if;
        return v_original.id; -- idempotent correction success
      end if;
    end if;

    -- New operation on existing control: require primary auth + in_progress (P0-1)
    -- Historical auth path is retries-only (P1-1 v7): gate new ops
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
  -- New operation: require primary auth + in_progress (P0-1)
  -- Historical auth is retries-only (P1-1 v7)
  if v_hist_auth then
    raise exception 'Inspección no autorizada' using errcode='42501';
  end if;
  if not exists(select 1 from public.visits where id=p_visit_id and status='in_progress') or
     not exists(select 1 from public.service_orders where id=p_order_id and status='in_progress') then
    raise exception 'Inspección no autorizada' using errcode='42501';
  end if;

  -- Concurrent first-saves both pass FOR UPDATE (row not found) → both reach INSERT.
  -- ON CONFLICT DO NOTHING (no target): one wins, one gets NULL from RETURNING.
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
        -- Control identity check (BUG-1 fix): key must be bound to THIS control, not another
        if v_fallback.visit_id != p_visit_id or v_fallback.control_key != p_key then
          raise exception 'Conflict: idempotency key bound to different control' using errcode='23505';
        end if;
        if v_fallback.result != p_result
           or v_fallback.control_label != p_label
           or coalesce(v_fallback.note,'') != coalesce(v_note,'') then
          raise exception 'Conflict: idempotency key reused with different payload' using errcode='23505';
        end if;
        return v_fallback.id;
      end if;
      -- P0-1 (v7): p_client_key provided but conflicting row stored with different UUID.
      -- Two concurrent offline saves with different keys → not an idempotent retry.
      raise exception 'Conflict: concurrent INSERT with different idempotency key' using errcode='23505';
    end if;
    -- Online mode (p_client_key null): find conflicting row by control identity
    select id into v_id from public.inspection_controls
    where visit_id=p_visit_id and control_key=p_key;
    if v_id is null then
      -- Concurrent INSERT not yet committed (not visible in this snapshot)
      raise exception 'Transient conflict: please retry' using errcode='40001';
    end if;
  end if;

  return v_id;
end $function$;

GRANT EXECUTE ON FUNCTION public.tech_save_pilot_control_v2(uuid, uuid, text, text, public.control_result, text, uuid) TO authenticated;

-- ── tech_save_pilot_correction_v2 ─────────────────────────────────────────
-- New function (original preserved unchanged).
-- p_client_key: used as inspection_corrections.idempotency_key (leverages existing constraint).
-- Idempotency check BEFORE state check: confirmed correction recognized even if state changed.
--
-- Lock ordering (P1-1): FOR SHARE service_orders → FOR UPDATE inspection_controls.
-- Status separation (P0-1): identity auth has NO status check; in_progress only for new ops.
-- Control identity (P0-3): pre-lock + post-lock check verifies correction belongs to p_key control.
-- Full payload check (P0-2): result + reason (normalized) + actor must match on retry.
-- Two-tier auth (P1-1 v7): same as control_v2.

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
  -- Primary auth WITHOUT status (P0-1): active assignment + active membership.
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
  -- Full payload check (P0-2 + P0-3): result + reason + actor + control identity.
  -- Returns EARLY if correction confirmed — no locks needed for already-committed data.
  if p_client_key is not null then
    select ic.corrected_result, ic.inspection_control_id, ic.actor_user_id, ic.reason
    into v_ck_result, v_ck_control_id, v_ck_actor, v_ck_reason
    from public.inspection_corrections ic
    where ic.company_id=v_company and ic.idempotency_key=p_client_key;
    if found then
      -- Control identity check (P0-3): correction must belong to this (visit_id, control_key)
      if not exists(select 1 from public.inspection_controls
                    where id=v_ck_control_id and visit_id=p_visit_id and control_key=p_key) then
        raise exception 'Conflict: idempotency key bound to different control' using errcode='23505';
      end if;
      if v_ck_result != p_result then
        raise exception 'Conflict: idempotency key reused with different result' using errcode='23505';
      end if;
      -- Reason check normalized (trim both sides)
      if trim(coalesce(v_ck_reason,'')) != trim(coalesce(p_reason,'')) then
        raise exception 'Conflict: idempotency key reused with different reason' using errcode='23505';
      end if;
      if v_ck_actor != auth.uid() then
        raise exception 'Conflict: idempotency key reused by different actor' using errcode='42501';
      end if;
      return v_ck_control_id; -- authoritative FK: correct even if p_key differs on retry
    end if;
  end if;

  -- FOR SHARE on service_orders (P1-1): consistent lock ordering order → control.
  perform 1 from public.service_orders where id=p_order_id for share;

  -- FOR UPDATE on inspection_controls (serializes concurrent correction calls)
  select * into v_control from public.inspection_controls
  where visit_id=p_visit_id and control_key=p_key
  for update;
  if not found then raise exception 'Control inexistente'; end if;

  -- ── Post-lock idempotency re-check (handles concurrent calls) ─────────────
  -- Concurrent call: passed pre-lock check, now inside lock — re-check with fresh snapshot.
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
      if v_ck_result != p_result then
        raise exception 'Conflict: idempotency key reused with different result' using errcode='23505';
      end if;
      if trim(coalesce(v_ck_reason,'')) != trim(coalesce(p_reason,'')) then
        raise exception 'Conflict: idempotency key reused with different reason' using errcode='23505';
      end if;
      if v_ck_actor != auth.uid() then
        raise exception 'Conflict: idempotency key reused by different actor' using errcode='42501';
      end if;
      return v_ck_control_id;
    end if;
  end if;

  -- New operation: require primary auth + in_progress (P0-1)
  -- Historical auth is retries-only (P1-1 v7)
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

GRANT EXECUTE ON FUNCTION public.tech_save_pilot_correction_v2(uuid, uuid, text, public.control_result, text, uuid) TO authenticated;

-- ── tech_start_pilot_order_v2 ──────────────────────────────────────────────
-- New function (original preserved). Adds p_client_started_at for offline timestamp.
-- Validation: reject future timestamps only (1 min tolerance for clock skew).
-- No hard past limit: technician may work offline >24h in legitimate scenarios.
-- started_at = server receive time; client_started_at = device offline action time.
-- Idempotency (P1-ts fix): on retry, compares p_client_started_at vs stored value.
-- P0-3 (v7): IS DISTINCT FROM — raises even when one side is NULL (NULL mismatch = conflict).

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

  -- Auth + state check with FOR UPDATE (identical to v1)
  select o.* into v from public.service_orders o
  join public.service_order_technicians a on a.service_order_id=o.id and a.active=true
  join public.technician_profiles t on t.id=a.technician_id and t.user_id=auth.uid()
  where o.id=p_order_id and o.status in ('scheduled','in_progress')
    and exists(select 1 from public.memberships m
               where m.user_id=auth.uid() and m.company_id=o.company_id
                 and m.role='technician' and m.active)
  for update of o;
  if not found then
    raise exception 'Orden no asignada o no disponible' using errcode='42501';
  end if;

  v_visit := v.inspection_visit_id;
  if v_visit is null then
    -- New visit: started_at = server receive time; client_started_at = device offline action time
    insert into public.visits(company_id, gate_id, status, responsible_user_id, started_at, client_started_at)
    values(v.company_id, v.gate_id, 'in_progress', auth.uid(), now(), p_client_started_at)
    returning id into v_visit;
    update public.service_orders set inspection_visit_id=v_visit where id=v.id;
  else
    -- Idempotent retry: compare p_client_started_at vs stored value.
    -- IS DISTINCT FROM (P0-3 v7): treats NULL mismatch as a conflict.
    select vis.client_started_at into v_stored_ts from public.visits vis where vis.id=v_visit;
    if p_client_started_at IS DISTINCT FROM v_stored_ts then
      raise exception 'Conflict: client_started_at differs from recorded value' using errcode='23505';
    end if;
  end if;
  update public.service_orders set status='in_progress' where id=v.id and status='scheduled';
  return v_visit;
end $function$;

GRANT EXECUTE ON FUNCTION public.tech_start_pilot_order_v2(uuid, timestamptz) TO authenticated;

-- ── tech_finish_pilot_order (modified in place, no signature change) ───────
-- Original contract preserved. Changes: FOR UPDATE + idempotent retry (ChatGPT confirmed OK).
-- tech_finish_pilot_order_v2 (below) is the offline-safe version with p_client_closed_at.
-- P1-1 (v7): idempotent retry requires active membership (not just responsible_user_id).

CREATE OR REPLACE FUNCTION public.tech_finish_pilot_order(p_order_id uuid, p_visit_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_company uuid;
begin
  -- FOR UPDATE OF o: serializes concurrent finish calls.
  -- READ COMMITTED: second concurrent call re-fetches after first commits;
  -- sees status='completed' → WHERE o.status='in_progress' false → NOT FOUND → idempotency branch.
  select o.company_id into v_company
  from public.service_orders o
  join public.service_order_technicians a on a.service_order_id=o.id and a.active
  join public.technician_profiles t on t.id=a.technician_id and t.user_id=auth.uid()
  join public.visits v on v.id=p_visit_id and v.company_id=o.company_id and v.gate_id=o.gate_id
       and v.responsible_user_id=auth.uid() and v.status='in_progress'
  where o.id=p_order_id and o.status='in_progress'
    and exists(select 1 from public.memberships m
               where m.user_id=auth.uid() and m.company_id=o.company_id
                 and m.role='technician' and m.active)
  for update of o;

  if v_company is null then
    -- Idempotent retry: same user, same (order_id, visit_id), completed+closed.
    -- P1-1 (v7): active membership required even for idempotent retry.
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

  -- Status guards on UPDATE: safe no-op if second concurrent call raced past FOR UPDATE.
  update public.visits set status='closed', closed_at=now()
  where id=p_visit_id and status='in_progress';
  update public.service_orders set status='completed', completed_at=now()
  where id=p_order_id and status='in_progress';
end $function$;

GRANT EXECUTE ON FUNCTION public.tech_finish_pilot_order(uuid, uuid) TO authenticated;

-- ── tech_finish_pilot_order_v2 ─────────────────────────────────────────────
-- New function for offline sync engine. Adds p_client_closed_at timestamptz.
-- client_closed_at registered only on FIRST confirmation (not overwritten on retry).
-- closed_at and completed_at stay as server timestamps (sync receive evidence).
-- Duration in reports: client_closed_at - client_started_at (both on visits).
-- Validates: client_closed_at not future (1 min tolerance); >= client_started_at if both set.
-- P0-3 (v7): IS DISTINCT FROM for timestamp comparison (NULL-safe).
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
  -- Reject future client timestamps (1 min tolerance)
  if p_client_closed_at is not null and p_client_closed_at > now() + interval '1 minute' then
    raise exception 'client_closed_at cannot be in the future';
  end if;

  -- Primary auth + state check with FOR UPDATE (serializes concurrent finish calls)
  select o.company_id into v_company
  from public.service_orders o
  join public.service_order_technicians a on a.service_order_id=o.id and a.active
  join public.technician_profiles t on t.id=a.technician_id and t.user_id=auth.uid()
  join public.visits v on v.id=p_visit_id and v.company_id=o.company_id and v.gate_id=o.gate_id
       and v.responsible_user_id=auth.uid() and v.status='in_progress'
  where o.id=p_order_id and o.status='in_progress'
    and exists(select 1 from public.memberships m
               where m.user_id=auth.uid() and m.company_id=o.company_id
                 and m.role='technician' and m.active)
  for update of o;

  if v_company is null then
    -- Idempotent retry check.
    -- P1-1 (v7): active membership required even for idempotent retry.
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

  -- 8-control check (identical to v1)
  if (select count(distinct control_key) from public.inspection_controls
      where visit_id=p_visit_id
        and control_key=any(array['structure','guides','motor','electrical',
                                  'photocells','emergency','opening','closing'])) <> 8
  then raise exception 'Completá los ocho controles antes de finalizar'; end if;

  -- Validate duration: client_closed_at must be >= client_started_at (if both are set)
  if p_client_closed_at is not null then
    select v.client_started_at into v_client_started_at
    from public.visits v where v.id=p_visit_id;
    if v_client_started_at is not null and p_client_closed_at < v_client_started_at then
      raise exception 'client_closed_at cannot be before client_started_at';
    end if;
  end if;

  -- closed_at = server receive time; client_closed_at = device offline action time
  update public.visits set status='closed', closed_at=now(), client_closed_at=p_client_closed_at
  where id=p_visit_id and status='in_progress';
  update public.service_orders set status='completed', completed_at=now()
  where id=p_order_id and status='in_progress';
end $function$;

GRANT EXECUTE ON FUNCTION public.tech_finish_pilot_order_v2(uuid, uuid, timestamptz) TO authenticated;

-- ── Approval conditions ────────────────────────────────────────────────────
-- v7 reviewer (2026-11-23): CLEAN — no confirmed bugs.
--   DESIGN NOTE-1: IS DISTINCT FROM in start_v2/finish_v2: a client that sends a timestamp
--     on first call and cannot recover it on retry will receive 23505 (trapped).
--     Client apps MUST durably store p_client_started_at / p_client_closed_at alongside
--     the pending operation (same local DB) — this is a hard correctness dependency.
--   DESIGN NOTE-2: Historical auth omits gate_id JOIN vs primary auth — intentional.
--     Visit is bound to order via inspection_visit_id at start time; gate_id re-check redundant.
--
-- v5 (2026-11-23): ChatGPT authorized dev commit; production blocked.
--   P0-1 ✅ Identity auth separated from status in both _v2 save RPCs
--   P0-2 ✅ Full payload check: result+label+note (control); result+reason+actor (correction)
--   P0-3 ✅ Correction idempotency verifies control identity (visit_id + control_key)
--   P1-1 ✅ Consistent lock ordering: FOR SHARE service_orders → FOR UPDATE inspection_controls
--   P1-ts ✅ client_started_at / client_closed_at compared on idempotent retry (→ 23505 on mismatch)
--
-- v7 (2026-11-23): Addresses ChatGPT v5 P0/P1 audit findings:
--   P0-1 ✅ Fallback INSERT offline mode: p_client_key provided + UUID not found → raise 23505
--            (no longer falls through to (visit_id, control_key) lookup in offline path)
--   P0-2 ✅ o.inspection_visit_id = p_visit_id added to WHERE in both save _v2 RPCs
--   P0-3 ✅ IS DISTINCT FROM replaces <> in start_v2 and finish_v2 timestamp comparisons
--   P1-1 ✅ Two-tier auth in save RPCs: historical fallback (responsible_user_id + active membership)
--            sets v_hist_auth=true; new ops gated (raise 42501) in both INSERT and UPDATE paths
--   P1-1 ✅ Active membership JOIN added to idempotent retry EXISTS in finish (v1 + v2)
--   P1-2 ⚠  FOR SHARE does not cover concurrent v1 + v2 RPCs — flag for staging test
--
-- ✅ RPCs online originals preserved (control, correction, start, finish unchanged)
-- ✅ RPCs _v2 separated (new functions; no DROP; no overloads)
-- ✅ Unique index by (company_id, client_idempotency_key) on inspection_controls
-- ✅ Initial INSERT retry without duplication (ON CONFLICT DO NOTHING + sep SELECT)
-- ✅ Two simultaneous requests same key (ON CONFLICT DO NOTHING handles both constraints)
-- ✅ Concurrent finish without overwriting timestamps (FOR UPDATE + status guards)
-- ✅ Authorization by company and technician (same as v1 + historical auth on retry)
-- ✅ Timestamps offline (client_started_at via v2 start; client_closed_at via v2 finish)
-- ✅ 24h limit removed (only future timestamps rejected with 1 min tolerance)
--
-- MERGE + DEPLOY: requires ChatGPT final SQL audit of v7. Send this file.
--
-- Tests planned:
-- 1. tech_save_pilot_control_v2 first save → ok; retry same key → same id; same key diff payload → 23505
-- 2. tech_save_pilot_control_v2 concurrent first saves same key → one id returned by both
-- 3. tech_save_pilot_control_v2 retry after close (visit closed) → idempotent ok (not 42501)
-- 4. tech_save_pilot_control_v2 concurrent saves different keys same control → 23505 (P0-1 v7)
-- 5. tech_save_pilot_control_v2 historical auth (assignment revoked) → idempotent ok; new op → 42501
-- 6. tech_save_pilot_correction_v2 correction → ok; retry → same id; same key diff result → 23505
-- 7. tech_save_pilot_correction_v2 retry after confirmed correction (non-fault state) → idempotent ok
-- 8. tech_save_pilot_correction_v2 retry after close → idempotent ok
-- 9. tech_finish_pilot_order: complete → void; retry → void; concurrent → first ok, second idempotent ok
-- 10. tech_finish_pilot_order_v2: same + client_closed_at stored; retry same ts → void; diff ts → 23505
-- 11. tech_start_pilot_order_v2: future ts → error; valid offline ts → stored; retry same ts → ok; diff ts → 23505
-- 12. Lock ordering: concurrent save_v2 + finish → no deadlock; new save after finish fails; retry succeeds
-- 13. Cross-visit forgery: save with wrong (order_id, visit_id) pair → 42501 (P0-2 v7)
