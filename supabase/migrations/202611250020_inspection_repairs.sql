-- Migration 020: inspection_repairs table + updated RPCs for repair tracking.
--
-- Requires migration 019 (enum ADD VALUE) to be committed first.
-- PostgreSQL cannot reference new enum values in the same transaction they were added.
--
-- Changes:
--   NEW table:  public.inspection_repairs (immutable, company-isolated)
--   MODIFIED:   tech_save_pilot_control    — adds p_repair jsonb DEFAULT NULL
--   MODIFIED:   tech_save_pilot_correction — adds p_repair jsonb DEFAULT NULL
--   MODIFIED:   tech_get_pilot_progress    — repairs array per control
--   MODIFIED:   gate_inspection_history    — repairs per control + 6-category summary
--
-- Function replacement strategy:
--   Adding p_repair creates a NEW overload, not a replacement of the old signature.
--   We DROP the old 6-param control and 5-param correction functions explicitly,
--   then CREATE the new 7-param and 6-param versions. Callers that omit p_repair
--   are still served by the DEFAULT NULL, so no frontend changes are needed.
--
-- Do NOT apply to production without authorization.

-- ─── 1. Table: inspection_repairs ────────────────────────────────────────────

CREATE TABLE public.inspection_repairs (
  id                       uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id               uuid        NOT NULL REFERENCES public.companies(id),
  inspection_control_id    uuid        NOT NULL,
  inspection_correction_id uuid        REFERENCES public.inspection_corrections(id),
  -- NULL  → repair is part of the initial control save (first save as resolved/partial)
  -- NOT NULL → repair is linked to a subsequent correction record
  actor_user_id            uuid        NOT NULL REFERENCES auth.users(id),
  problem_found            text        NOT NULL CHECK(length(trim(problem_found)) BETWEEN 10 AND 2000),
  intervention             text        NOT NULL CHECK(length(trim(intervention))  BETWEEN 10 AND 2000),
  verification             text        CHECK(verification    IS NULL OR length(trim(verification))    BETWEEN 10 AND 2000),
  -- verification  required for 'resolved', optional for 'partial' (enforced in RPC)
  remaining_work           text        CHECK(remaining_work  IS NULL OR length(trim(remaining_work))  BETWEEN 10 AND 2000),
  -- remaining_work required for 'partial', must be NULL for 'resolved' (enforced in RPC)
  created_at               timestamptz NOT NULL DEFAULT now(),
  idempotency_key          uuid        NOT NULL,
  UNIQUE(company_id, idempotency_key),
  FOREIGN KEY(inspection_control_id, company_id) REFERENCES public.inspection_controls(id, company_id)
);
-- Index: fast lookup from gate_inspection_history and tech_get_pilot_progress
CREATE INDEX ON public.inspection_repairs(inspection_control_id);
CREATE INDEX ON public.inspection_repairs(company_id, created_at DESC);

-- ─── 2. Immutability + RLS + permissions ─────────────────────────────────────

CREATE TRIGGER repairs_no_update
  BEFORE UPDATE OR DELETE ON public.inspection_repairs
  FOR EACH ROW EXECUTE FUNCTION app_private.audit_immutable();

ALTER TABLE public.inspection_repairs ENABLE ROW LEVEL SECURITY;
CREATE POLICY repairs_read ON public.inspection_repairs
  FOR SELECT TO authenticated
  USING(app_private.has_membership(company_id));
REVOKE INSERT, UPDATE, DELETE ON public.inspection_repairs FROM anon, authenticated;

-- ─── 2.5 inspection_corrections: corrected_note (auditable observation) ───────
-- The observation ("nueva observación") is distinct from reason ("motivo").
-- inspection_controls.note stays immutable; the current observation is derived as
-- coalesce(latest corrected_note, control.note) by the read RPCs.
-- inspection_corrections is insert-only (corrections_no_update trigger, mig 002);
-- ADD COLUMN is DDL and safe. Existing rows get NULL and pass the CHECK.

ALTER TABLE public.inspection_corrections
  ADD COLUMN corrected_note text
  CHECK (corrected_note IS NULL OR length(trim(corrected_note)) BETWEEN 10 AND 1000);

-- Canonical repair-payload comparison for strict idempotency (C1).
-- Stored fields are already trimmed / nullif-empty on insert, so the incoming
-- jsonb is normalized the same way before comparison.
CREATE OR REPLACE FUNCTION app_private.repair_payload_matches(r public.inspection_repairs, p jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT r.problem_found  IS NOT DISTINCT FROM trim(p->>'problem_found')
     AND r.intervention   IS NOT DISTINCT FROM trim(p->>'intervention')
     AND r.verification   IS NOT DISTINCT FROM nullif(trim(coalesce(p->>'verification','')), '')
     AND r.remaining_work IS NOT DISTINCT FROM nullif(trim(coalesce(p->>'remaining_work','')), '');
$$;

-- ─── 3. Drop old function signatures ─────────────────────────────────────────
-- PostgreSQL: CREATE OR REPLACE with a different param list creates a NEW function.
-- Drop the old signatures so there is no ambiguous overload.

DROP FUNCTION IF EXISTS public.tech_save_pilot_control(uuid, uuid, text, text, public.control_result, text);
DROP FUNCTION IF EXISTS public.tech_save_pilot_correction(uuid, uuid, text, public.control_result, text);

-- ─── 4. tech_save_pilot_control v2 ───────────────────────────────────────────
-- Adds p_repair jsonb DEFAULT NULL.
-- Existing callers that omit p_repair continue to work unchanged.
--
-- Repair semantics:
--   resolved: problem_found + intervention + verification required (≥10 chars each)
--   partial:  problem_found + intervention + remaining_work required; verification optional
--   fault/critical: note ≥10 required; p_repair must be NULL
--
-- Transition guards (force correction form):
--   fault/critical → ok/not_applicable/unverifiable/critical/fault: use correction form
--   resolved/partial → fault/critical: use correction form
--   fault/critical → resolved/partial: allowed here if p_repair provided

CREATE OR REPLACE FUNCTION public.tech_save_pilot_control(
  p_order_id uuid,
  p_visit_id uuid,
  p_key      text,
  p_label    text,
  p_result   public.control_result,
  p_note     text    DEFAULT NULL,
  p_repair   jsonb   DEFAULT NULL
) RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_company    uuid;
  v_id         uuid;
  v_original   public.inspection_controls%rowtype;
  v_note       text;
  v_current    public.control_result;
  v_rep        public.inspection_repairs%rowtype;
  v_repair_key uuid;
begin
  -- Auth + SOT membership + visit/order active + row-level lock (consistent lock order)
  select o.company_id into v_company
  from public.service_orders o
  join public.service_order_technicians a on a.service_order_id=o.id and a.active
  join public.technician_profiles t on t.id=a.technician_id and t.user_id=auth.uid()
  join public.visits v on v.id=p_visit_id and v.company_id=o.company_id and v.gate_id=o.gate_id
                       and v.status='in_progress'
  where o.id=p_order_id
    and o.inspection_visit_id=p_visit_id
    and o.status='in_progress'
    and exists(select 1 from public.memberships m
               where m.user_id=auth.uid() and m.company_id=o.company_id
                 and m.role='technician' and m.active)
  for update of o;
  if v_company is null then raise exception 'Inspección no autorizada' using errcode='42501'; end if;

  -- Basic input validation
  if p_key is null or length(trim(p_key))=0 or length(p_key)>80
     or p_label is null or length(trim(p_label))=0 or length(p_label)>200
     or length(coalesce(p_note,''))>1000
  then raise exception 'Control inválido'; end if;
  v_note := nullif(trim(p_note), '');

  -- Note required for fault and critical
  if p_result in ('fault'::public.control_result, 'critical'::public.control_result)
     and length(coalesce(v_note,'')) < 10
  then raise exception 'Describí la falla con al menos 10 caracteres'; end if;

  -- Repair validation and idempotency key extraction
  if p_result in ('resolved'::public.control_result, 'partial'::public.control_result) then
    if p_repair is null then
      raise exception 'Se requiere registro de reparación para este resultado' using errcode='22023';
    end if;
    v_repair_key := (p_repair->>'idempotency_key')::uuid;
    if v_repair_key is null then
      raise exception 'idempotency_key requerido en p_repair' using errcode='22023';
    end if;
    if length(trim(coalesce(p_repair->>'problem_found',''))) < 10 then
      raise exception 'problem_found obligatorio (mín 10 caracteres)' using errcode='22023';
    end if;
    if length(trim(coalesce(p_repair->>'intervention',''))) < 10 then
      raise exception 'intervention obligatorio (mín 10 caracteres)' using errcode='22023';
    end if;
    if p_result = 'resolved'::public.control_result
       and length(trim(coalesce(p_repair->>'verification',''))) < 10 then
      raise exception 'verification obligatorio para resultado resuelto (mín 10 caracteres)' using errcode='22023';
    end if;
    if p_result = 'partial'::public.control_result
       and length(trim(coalesce(p_repair->>'verification',''))) > 0
       and length(trim(coalesce(p_repair->>'verification',''))) < 10 then
      raise exception 'verification debe tener al menos 10 caracteres si se proporciona' using errcode='22023';
    end if;
    if p_result = 'partial'::public.control_result
       and length(trim(coalesce(p_repair->>'remaining_work',''))) < 10 then
      raise exception 'remaining_work obligatorio para resultado parcial (mín 10 caracteres)' using errcode='22023';
    end if;
  end if;

  select * into v_original from public.inspection_controls
  where visit_id=p_visit_id and control_key=p_key;

  if not found then
    -- ── First save path ──────────────────────────────────────────────────────
    -- Idempotency (C1): if the repair key is already committed, the prior attempt
    -- succeeded. Same key must carry the same payload, otherwise it is a conflict.
    if v_repair_key is not null then
      select * into v_rep from public.inspection_repairs
      where company_id=v_company and idempotency_key=v_repair_key limit 1;
      if found then
        if not app_private.repair_payload_matches(v_rep, p_repair) then
          raise exception 'Operación duplicada con datos distintos (idempotency_key reutilizada)' using errcode='22023';
        end if;
        return v_rep.inspection_control_id;
      end if;
    end if;

    insert into public.inspection_controls(company_id, visit_id, control_key, control_label, result, note)
    values(v_company, p_visit_id, p_key, p_label, p_result, v_note)
    on conflict(visit_id, control_key) do nothing
    returning id into v_id;

    if v_id is not null then
      -- We won the race: insert repair if applicable (correction_id NULL = initial save)
      if v_repair_key is not null then
        insert into public.inspection_repairs(
          company_id, inspection_control_id, inspection_correction_id, actor_user_id,
          problem_found, intervention, verification, remaining_work, idempotency_key
        ) values(
          v_company, v_id, null, auth.uid(),
          trim(p_repair->>'problem_found'),
          trim(p_repair->>'intervention'),
          nullif(trim(coalesce(p_repair->>'verification','')), ''),
          nullif(trim(coalesce(p_repair->>'remaining_work','')), ''),
          v_repair_key
        );
      end if;
      return v_id;
    end if;

    -- Race lost: re-fetch and check for conflict or idempotency
    select * into v_original from public.inspection_controls
    where visit_id=p_visit_id and control_key=p_key;
    if not found then
      raise exception 'Error interno de concurrencia — reintentá la operación' using errcode='40001';
    end if;
    if v_original.result is distinct from p_result or v_original.note is distinct from v_note then
      raise exception 'Control guardado por otro técnico con resultado o nota diferente — recargá e intentá nuevamente' using errcode='40001';
    end if;
    -- Race loser but same data: insert our repair too (control is owned by the race winner)
    if v_repair_key is not null then
      insert into public.inspection_repairs(
        company_id, inspection_control_id, inspection_correction_id, actor_user_id,
        problem_found, intervention, verification, remaining_work, idempotency_key
      ) values(
        v_company, v_original.id, null, auth.uid(),
        trim(p_repair->>'problem_found'),
        trim(p_repair->>'intervention'),
        nullif(trim(coalesce(p_repair->>'verification','')), ''),
        nullif(trim(coalesce(p_repair->>'remaining_work','')), ''),
        v_repair_key
      )
      on conflict(company_id, idempotency_key) do nothing;
    end if;
    return v_original.id;
  end if;

  -- ── Pre-existing control path (defensive) ─────────────────────────────────
  -- The frontend routes every post-first-save change to tech_save_pilot_correction.
  -- This path only tolerates an idempotent retry of the original first save;
  -- any real change must go through the auditable correction flow.
  select coalesce(
    (select corrected_result from public.inspection_corrections
     where inspection_control_id=v_original.id
     order by created_at desc, id desc limit 1),
    v_original.result
  ) into v_current;

  -- Idempotent retry of a first save that carried a repair
  if v_repair_key is not null then
    select * into v_rep from public.inspection_repairs
    where company_id=v_company and idempotency_key=v_repair_key limit 1;
    if found then
      if not app_private.repair_payload_matches(v_rep, p_repair) then
        raise exception 'Operación duplicada con datos distintos (idempotency_key reutilizada)' using errcode='22023';
      end if;
      return v_original.id;
    else
      -- Partial-failure recovery: control committed but repair insert failed on a prior attempt.
      -- Insert the missing repair now; ON CONFLICT DO NOTHING makes this safe if another
      -- concurrent retry also reaches here.
      insert into public.inspection_repairs(
        company_id, inspection_control_id, inspection_correction_id, actor_user_id,
        problem_found, intervention, verification, remaining_work, idempotency_key
      ) values(
        v_company, v_original.id, null, auth.uid(),
        trim(p_repair->>'problem_found'),
        trim(p_repair->>'intervention'),
        nullif(trim(coalesce(p_repair->>'verification','')), ''),
        nullif(trim(coalesce(p_repair->>'remaining_work','')), ''),
        v_repair_key
      )
      on conflict(company_id, idempotency_key) do nothing;
      return v_original.id;
    end if;
  end if;

  -- Idempotent double-submit of a first save (same result, same note, no repair)
  if v_repair_key is null
     and p_result = v_current
     and v_note is not distinct from v_original.note then
    return v_original.id;
  end if;

  -- Any real modification of an already-saved control must be an auditable correction
  raise exception 'Para modificar un control ya guardado, usá el formulario de corrección' using errcode='22023';
end $function$;

-- ─── 5. tech_save_pilot_correction v2 ────────────────────────────────────────
-- New params: p_idempotency_key (required, strict idempotency C1),
--             p_corrected_note (nueva observación, distinct from p_reason = motivo).
-- Accepts same-result corrections when the observation changes (A1); rejects empty
-- (no-change) corrections and duplicate keys carrying a different payload.

CREATE OR REPLACE FUNCTION public.tech_save_pilot_correction(
  p_order_id uuid,
  p_visit_id uuid,
  p_key      text,
  p_result   public.control_result,
  p_reason   text,
  p_idempotency_key uuid,
  p_corrected_note  text  DEFAULT NULL,
  p_repair          jsonb DEFAULT NULL
) RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_company        uuid;
  v_control        public.inspection_controls%rowtype;
  v_latest         public.control_result;
  v_cur_note       text;
  v_corrected_note text;
  v_existing       public.inspection_corrections%rowtype;
  v_rep            public.inspection_repairs%rowtype;
  v_corr_id        uuid;
  v_repair_key     uuid;
begin
  -- Auth + SOT membership + visit/order active + row-level lock
  select o.company_id into v_company
  from public.service_orders o
  join public.service_order_technicians a on a.service_order_id=o.id and a.active
  join public.technician_profiles t on t.id=a.technician_id and t.user_id=auth.uid()
  join public.visits v on v.id=p_visit_id and v.company_id=o.company_id and v.gate_id=o.gate_id
                       and v.status='in_progress'
  where o.id=p_order_id
    and o.inspection_visit_id=p_visit_id
    and o.status='in_progress'
    and exists(select 1 from public.memberships m
               where m.user_id=auth.uid() and m.company_id=o.company_id
                 and m.role='technician' and m.active)
  for update of o;
  if v_company is null then raise exception 'Inspección no autorizada' using errcode='42501'; end if;

  if p_idempotency_key is null then
    raise exception 'idempotency_key requerido' using errcode='22023';
  end if;

  select * into v_control from public.inspection_controls
  where visit_id=p_visit_id and control_key=p_key;
  if not found then raise exception 'Control inexistente'; end if;

  -- Effective result + current observation (latest non-null corrected_note, else original)
  select coalesce(
    (select corrected_result from public.inspection_corrections
     where inspection_control_id=v_control.id
     order by created_at desc, id desc limit 1),
    v_control.result
  ) into v_latest;
  select coalesce(
    (select corrected_note from public.inspection_corrections
     where inspection_control_id=v_control.id and corrected_note is not null
     order by created_at desc, id desc limit 1),
    v_control.note
  ) into v_cur_note;

  v_corrected_note := nullif(trim(coalesce(p_corrected_note,'')), '');

  -- Idempotency (C1): a correction with this key must carry the same payload
  select * into v_existing from public.inspection_corrections
  where company_id=v_company and idempotency_key=p_idempotency_key limit 1;
  if found then
    if v_existing.corrected_result is distinct from p_result
       or v_existing.corrected_note  is distinct from v_corrected_note
       or v_existing.reason          is distinct from trim(coalesce(p_reason,'')) then
      raise exception 'Operación duplicada con datos distintos (idempotency_key reutilizada)' using errcode='22023';
    end if;
    if p_repair is not null then
      select * into v_rep from public.inspection_repairs
      where company_id=v_company and inspection_correction_id=v_existing.id limit 1;
      if found then
        if not app_private.repair_payload_matches(v_rep, p_repair) then
          raise exception 'Operación duplicada con datos distintos (idempotency_key reutilizada)' using errcode='22023';
        end if;
      else
        -- Partial-failure recovery: correction committed but repair insert failed on a prior attempt.
        insert into public.inspection_repairs(
          company_id, inspection_control_id, inspection_correction_id, actor_user_id,
          problem_found, intervention, verification, remaining_work, idempotency_key
        ) values(
          v_company, v_control.id, v_existing.id, auth.uid(),
          trim(p_repair->>'problem_found'),
          trim(p_repair->>'intervention'),
          nullif(trim(coalesce(p_repair->>'verification','')), ''),
          nullif(trim(coalesce(p_repair->>'remaining_work','')), ''),
          (p_repair->>'idempotency_key')::uuid
        )
        on conflict(company_id, idempotency_key) do nothing;
      end if;
    end if;
    return v_control.id;
  end if;

  -- No empty correction: must change result or observation, or carry a repair
  if p_result = v_latest
     and v_corrected_note is not distinct from v_cur_note
     and p_repair is null then
    raise exception 'No hay cambios para registrar' using errcode='22023';
  end if;

  -- Repair validation for resolved/partial
  if p_result in ('resolved'::public.control_result, 'partial'::public.control_result) then
    if p_repair is null then
      raise exception 'Se requiere registro de reparación para este resultado' using errcode='22023';
    end if;
    v_repair_key := (p_repair->>'idempotency_key')::uuid;
    if v_repair_key is null then
      raise exception 'idempotency_key requerido en p_repair' using errcode='22023';
    end if;
    if length(trim(coalesce(p_repair->>'problem_found',''))) < 10 then
      raise exception 'problem_found obligatorio (mín 10 caracteres)' using errcode='22023';
    end if;
    if length(trim(coalesce(p_repair->>'intervention',''))) < 10 then
      raise exception 'intervention obligatorio (mín 10 caracteres)' using errcode='22023';
    end if;
    if p_result = 'resolved'::public.control_result
       and length(trim(coalesce(p_repair->>'verification',''))) < 10 then
      raise exception 'verification obligatorio para resultado resuelto (mín 10 caracteres)' using errcode='22023';
    end if;
    if p_result = 'partial'::public.control_result
       and length(trim(coalesce(p_repair->>'verification',''))) > 0
       and length(trim(coalesce(p_repair->>'verification',''))) < 10 then
      raise exception 'verification debe tener al menos 10 caracteres si se proporciona' using errcode='22023';
    end if;
    if p_result = 'partial'::public.control_result
       and length(trim(coalesce(p_repair->>'remaining_work',''))) < 10 then
      raise exception 'remaining_work obligatorio para resultado parcial (mín 10 caracteres)' using errcode='22023';
    end if;
  end if;

  -- Observation (corrected_note) validation
  if p_result in ('fault'::public.control_result, 'critical'::public.control_result) then
    if v_corrected_note is null or length(v_corrected_note) < 10 then
      raise exception 'Describí la falla con al menos 10 caracteres' using errcode='22023';
    end if;
  elsif v_corrected_note is not null and length(v_corrected_note) < 10 then
    raise exception 'La observación debe tener al menos 10 caracteres' using errcode='22023';
  end if;
  if v_corrected_note is not null and length(v_corrected_note) > 1000 then
    raise exception 'La observación supera los 1000 caracteres' using errcode='22023';
  end if;

  -- Reason (motivo) validation
  if length(trim(coalesce(p_reason,''))) < 10 or length(trim(coalesce(p_reason,''))) > 1000 then
    raise exception 'Explicá el motivo de la corrección (mínimo 10 caracteres)' using errcode='22023';
  end if;

  -- Insert correction (reason = motivo, corrected_note = nueva observación)
  insert into public.inspection_corrections(
    company_id, inspection_control_id, actor_user_id, corrected_result, reason, corrected_note, idempotency_key
  ) values(
    v_company, v_control.id, auth.uid(), p_result, trim(p_reason), v_corrected_note, p_idempotency_key
  ) returning id into v_corr_id;

  -- Insert repair if applicable
  if v_repair_key is not null then
    insert into public.inspection_repairs(
      company_id, inspection_control_id, inspection_correction_id, actor_user_id,
      problem_found, intervention, verification, remaining_work, idempotency_key
    ) values(
      v_company, v_control.id, v_corr_id, auth.uid(),
      trim(p_repair->>'problem_found'),
      trim(p_repair->>'intervention'),
      nullif(trim(coalesce(p_repair->>'verification','')), ''),
      nullif(trim(coalesce(p_repair->>'remaining_work','')), ''),
      v_repair_key
    );
  end if;

  return v_control.id;
end $function$;

-- ─── 6. tech_get_pilot_progress v2 ───────────────────────────────────────────
-- Adds 'repairs' array to each control in the response.

CREATE OR REPLACE FUNCTION public.tech_get_pilot_progress(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_visit public.visits%rowtype; v_data jsonb;
begin
 select v.* into v_visit
 from public.visits v
 join public.service_orders o on o.inspection_visit_id=v.id
 join public.service_order_technicians a on a.service_order_id=o.id and a.active
 join public.technician_profiles t on t.id=a.technician_id and t.user_id=auth.uid()
 where o.id=p_order_id
   and v.status='in_progress'
   and exists(select 1 from public.memberships m where m.user_id=auth.uid() and m.company_id=o.company_id and m.role='technician' and m.active)
 limit 1;
 if not found then return null; end if;
 select jsonb_build_object(
   'visit_id', v_visit.id,
   'controls', coalesce(jsonb_agg(jsonb_build_object(
     'key',            c.control_key,
     'result',         coalesce((select ic.corrected_result::text from public.inspection_corrections ic where ic.inspection_control_id=c.id order by ic.created_at desc,ic.id desc limit 1),c.result::text),
     'note',           c.note,
     'current_note',   coalesce((select ic.corrected_note from public.inspection_corrections ic where ic.inspection_control_id=c.id and ic.corrected_note is not null order by ic.created_at desc,ic.id desc limit 1),c.note),
     'original_result',c.result::text,
     'repairs',        (select coalesce(jsonb_agg(jsonb_build_object(
                          'id',             r.id,
                          'actor_user_id',  r.actor_user_id,
                          'problem_found',  r.problem_found,
                          'intervention',   r.intervention,
                          'verification',   r.verification,
                          'remaining_work', r.remaining_work,
                          'created_at',     r.created_at
                        ) order by r.created_at,r.id),'[]'::jsonb)
                        from public.inspection_repairs r where r.inspection_control_id=c.id)
   )) filter(where c.id is not null),'[]'::jsonb)
 ) into v_data
 from public.inspection_controls c where c.visit_id=v_visit.id;
 return v_data;
end $function$;

-- ─── 7. gate_inspection_history v2 ───────────────────────────────────────────
-- Adds 'repairs' array to each control.
-- Adds 'summary' object per visit with 6-category indicator counts.
-- Summary subquery uses a derived table (not a JOIN) to avoid row multiplication.

CREATE OR REPLACE FUNCTION public.gate_inspection_history(p_gate_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_company uuid; v_history jsonb;
begin
 select g.company_id into v_company from public.gates g
 where g.id=p_gate_id
   and exists(select 1 from public.memberships m where m.company_id=g.company_id and m.user_id=auth.uid() and m.active and m.role in ('technician','admin','customer'));
 if v_company is null then raise exception 'Acceso no autorizado al portón' using errcode='42501'; end if;
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',         v.id,
   'order_id',   o.id,
   'date',       coalesce(v.closed_at,v.started_at,v.created_at),
   'status',     v.status,
   'technician', coalesce(nullif(concat_ws(' ',t.first_name,t.last_name),''),'Técnico'),
   'summary',    (
     -- Derived table avoids JOIN row multiplication; uses same corrected-result logic
     select jsonb_build_object(
       'ok',                           count(*) filter (where eff = 'ok'::public.control_result),
       'resolved',                     count(*) filter (where eff = 'resolved'::public.control_result),
       'partial',                      count(*) filter (where eff = 'partial'::public.control_result),
       'fault',                        count(*) filter (where eff = 'fault'::public.control_result),
       'critical',                     count(*) filter (where eff = 'critical'::public.control_result),
       'not_applicable_or_unverifiable',count(*) filter (where eff in ('not_applicable'::public.control_result,'unverifiable'::public.control_result))
     )
     from (
       select coalesce(
         (select ic2.corrected_result from public.inspection_corrections ic2
          where ic2.inspection_control_id=c2.id order by ic2.created_at desc,ic2.id desc limit 1),
         c2.result
       ) as eff
       from public.inspection_controls c2 where c2.visit_id=v.id
     ) eff_rows
   ),
   'controls',   (
     select coalesce(jsonb_agg(jsonb_build_object(
       'key',            c.control_key,
       'label',          c.control_label,
       'original_result',c.result::text,
       'original_note',  c.note,
       'result',         coalesce(lastc.corrected_result::text,c.result::text),
       'note',           c.note,
       'current_note',   coalesce((select ic.corrected_note from public.inspection_corrections ic where ic.inspection_control_id=c.id and ic.corrected_note is not null order by ic.created_at desc,ic.id desc limit 1),c.note),
       'corrections',    (select coalesce(jsonb_agg(jsonb_build_object('result',ic.corrected_result::text,'reason',ic.reason,'corrected_note',ic.corrected_note,'date',ic.created_at) order by ic.created_at,ic.id),'[]'::jsonb) from public.inspection_corrections ic where ic.inspection_control_id=c.id),
       'repairs',        (select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'actor_user_id',r.actor_user_id,'problem_found',r.problem_found,'intervention',r.intervention,'verification',r.verification,'remaining_work',r.remaining_work,'created_at',r.created_at) order by r.created_at,r.id),'[]'::jsonb) from public.inspection_repairs r where r.inspection_control_id=c.id)
     ) order by c.created_at,c.id),'[]'::jsonb)
     from public.inspection_controls c
     left join lateral (
       select corrected_result from public.inspection_corrections ic
       where ic.inspection_control_id=c.id order by ic.created_at desc,ic.id desc limit 1
     ) lastc on true
     where c.visit_id=v.id
   )
 ) order by coalesce(v.closed_at,v.started_at,v.created_at) desc),'[]'::jsonb) into v_history
 from public.visits v
 left join public.technician_profiles t on t.user_id=v.responsible_user_id and t.company_id=v.company_id
 left join public.service_orders o on o.inspection_visit_id=v.id and o.company_id=v.company_id
 where v.gate_id=p_gate_id and v.company_id=v_company and v.status='closed';
 return v_history;
end $function$;

-- ─── 8. Permissions ──────────────────────────────────────────────────────────

REVOKE EXECUTE ON FUNCTION public.tech_save_pilot_control(uuid, uuid, text, text, public.control_result, text, jsonb) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.tech_save_pilot_control(uuid, uuid, text, text, public.control_result, text, jsonb) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.tech_save_pilot_correction(uuid, uuid, text, public.control_result, text, uuid, text, jsonb) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.tech_save_pilot_correction(uuid, uuid, text, public.control_result, text, uuid, text, jsonb) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.tech_get_pilot_progress(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.tech_get_pilot_progress(uuid) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.gate_inspection_history(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.gate_inspection_history(uuid) TO authenticated;
