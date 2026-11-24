-- Migration 018: Multi-tech collaboration — remove write-lock from inspection RPCs
--
-- Problem: ALL write RPCs filter v.responsible_user_id = auth.uid(), restricting
-- all writes to the technician who first called tech_start_pilot_order. Any second
-- technician assigned via service_order_technicians gets "Inspección no autorizada".
--
-- Fix: replace responsible_user_id=auth.uid() with service_order_technicians
-- membership check — the same pattern already used correctly in tech_start_pilot_order.
--
-- Schema change: live_inspection_heartbeats.UNIQUE(visit_id) → UNIQUE(visit_id,user_id)
-- so each assigned technician maintains their own heartbeat row on the shared visit.
--
-- Does NOT modify:
--   tech_start_pilot_order  — already uses SOT membership correctly; visit creation keeps responsible_user_id to track starter
--   gate_inspection_history — responsible_user_id as "inspector who started" is intentional; no collaboration concern
--   tech_create_spontaneous_order — single-tech spontaneous flow, out of scope for multi-tech
--   migration 017 _v2 functions  — DRAFT, not applied to production; 017 must incorporate
--                                   these same changes when finalized before production apply
--
-- Apply BEFORE migration 017 (idempotency DRAFT). After applying: any technician
-- listed in service_order_technicians can independently heartbeat, save controls /
-- corrections, and close the shared inspection visit.

-- ─── 1. Schema: live_inspection_heartbeats — per-tech heartbeat rows ──────────

-- Drop the single-visit unique. Query pg_constraint by column expression so the DO block
-- works regardless of what Supabase auto-named it. Fails fast if something unexpected exists.
DO $$
DECLARE _cname text;
BEGIN
  SELECT c.conname INTO _cname
  FROM pg_constraint c
  JOIN pg_class t ON t.oid=c.conrelid
  JOIN pg_namespace n ON n.oid=t.relnamespace
  WHERE n.nspname='public' AND t.relname='live_inspection_heartbeats'
    AND c.contype='u' AND array_length(c.conkey,1)=1
    AND EXISTS(
      SELECT 1 FROM pg_attribute a
      WHERE a.attrelid=c.conrelid AND a.attnum=c.conkey[1] AND a.attname='visit_id'
    );
  IF _cname IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.live_inspection_heartbeats DROP CONSTRAINT %I', _cname);
  END IF;
END $$;

-- Per-tech composite unique: one heartbeat row per (visit, tech).
ALTER TABLE public.live_inspection_heartbeats
  ADD CONSTRAINT IF NOT EXISTS live_inspection_heartbeats_visit_id_user_id_key
    UNIQUE (visit_id, user_id);

-- ─── 2. tech_live_heartbeat — auth via SOT membership ────────────────────────
-- Was: WHERE v.responsible_user_id=auth.uid() (no SOT check at all in 016)
-- Now: JOIN service_order_technicians + technician_profiles; heartbeat per (visit,user)

CREATE OR REPLACE FUNCTION public.tech_live_heartbeat(p_order_id uuid, p_visit_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_company uuid;
begin
 if auth.uid() is null then raise exception 'No autenticado' using errcode='42501'; end if;
 select v.company_id into v_company
 from public.visits v
 join public.service_orders o on o.inspection_visit_id=v.id and o.id=p_order_id
 join public.service_order_technicians a on a.service_order_id=o.id and a.active=true
 join public.technician_profiles t on t.id=a.technician_id and t.user_id=auth.uid()
 where v.id=p_visit_id
   and v.status::text='in_progress' and o.status='in_progress'
   and v.company_id=o.company_id
   and exists(select 1 from public.memberships m where m.user_id=auth.uid() and m.company_id=o.company_id and m.role='technician' and m.active);
 if v_company is null then raise exception 'Inspección no activa o sin autorización' using errcode='42501'; end if;
 insert into public.live_inspection_heartbeats(visit_id,order_id,company_id,user_id,last_seen_at)
 values(p_visit_id,p_order_id,v_company,auth.uid(),now())
 on conflict(visit_id,user_id) do update set last_seen_at=excluded.last_seen_at;
end $function$;

-- ─── 3. tech_finish_pilot_order — any assigned tech can close ────────────────
-- Was: v.responsible_user_id=auth.uid() in visits JOIN (016 line 61)
-- Now: removed; SOT join already validates assignment

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
                      and v.status='in_progress'
 where o.id=p_order_id
   and o.inspection_visit_id=p_visit_id
   and o.status='in_progress'
   and exists(select 1 from public.memberships m where m.user_id=auth.uid() and m.company_id=o.company_id and m.role='technician' and m.active);
 if v_company is null then raise exception 'Inspección no autorizada' using errcode='42501'; end if;
 if (select count(distinct control_key) from public.inspection_controls
     where visit_id=p_visit_id
       and control_key=any(array['structure','guides','motor','electrical','photocells','emergency','opening','closing'])
 ) <> 8 then raise exception 'Completá los ocho controles antes de finalizar'; end if;
 update public.visits        set status='closed',    closed_at=now()    where id=p_visit_id    and status='in_progress';
 update public.service_orders set status='completed', completed_at=now() where id=p_order_id    and status='in_progress';
end $function$;

-- ─── 4. tech_save_pilot_control — any assigned tech can save controls ─────────
-- Was: v.responsible_user_id=auth.uid() in visits JOIN (016 line 78)
-- Now: removed; existing SOT join already validates assignment

CREATE OR REPLACE FUNCTION public.tech_save_pilot_control(p_order_id uuid, p_visit_id uuid, p_key text, p_label text, p_result control_result, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_company uuid; v_id uuid; v_original public.inspection_controls%rowtype; v_note text; v_current public.control_result;
begin
 select o.company_id into v_company
 from public.service_orders o
 join public.service_order_technicians a on a.service_order_id=o.id and a.active
 join public.technician_profiles t on t.id=a.technician_id and t.user_id=auth.uid()
 join public.visits v on v.id=p_visit_id and v.company_id=o.company_id and v.gate_id=o.gate_id
                      and v.status='in_progress'
 where o.id=p_order_id
   and o.inspection_visit_id=p_visit_id
   and o.status='in_progress'
   and exists(select 1 from public.memberships m where m.user_id=auth.uid() and m.company_id=o.company_id and m.role='technician' and m.active);
 if v_company is null then raise exception 'Inspección no autorizada' using errcode='42501'; end if;
 if p_key is null or length(trim(p_key))=0 or length(p_key)>80 or p_label is null or length(trim(p_label))=0 or length(p_label)>200 or length(coalesce(p_note,''))>1000 then raise exception 'Control inválido'; end if;
 v_note:=nullif(trim(p_note),'');
 if p_result = 'fault'::public.control_result and length(coalesce(v_note, '')) < 10 then raise exception 'Describí la falla con al menos 10 caracteres'; end if;
 select * into v_original from public.inspection_controls where visit_id=p_visit_id and control_key=p_key;
 if not found then
   -- First save: atomic INSERT; ON CONFLICT guards the race where two techs save the same
   -- control_key simultaneously and both reach this branch (removed write-lock makes this reachable).
   insert into public.inspection_controls(company_id,visit_id,control_key,control_label,result,note)
   values(v_company,p_visit_id,p_key,p_label,p_result,v_note)
   on conflict(visit_id,control_key) do nothing
   returning id into v_id;
   if v_id is not null then return v_id; end if;
   -- Concurrent first-insert won the race; re-fetch and fall through to correction path.
   select * into v_original from public.inspection_controls where visit_id=p_visit_id and control_key=p_key;
   if not found then raise exception 'Error interno de concurrencia — reintentá la operación' using errcode='40001'; end if;
 end if;
 -- existing control (pre-existing or concurrent-race winner): validate and insert correction
 select coalesce((select corrected_result from public.inspection_corrections where inspection_control_id=v_original.id order by created_at desc,id desc limit 1),v_original.result) into v_current;
 if v_current='fault' and p_result<>'fault' then raise exception 'Para cambiar una falla, explicá la corrección en el formulario'; end if;
 insert into public.inspection_corrections(company_id,inspection_control_id,actor_user_id,corrected_result,reason,idempotency_key)
 values(v_company,v_original.id,auth.uid(),p_result,coalesce(v_note,'Actualización del resultado durante inspección en curso'),gen_random_uuid());
 return v_original.id;
end $function$;

-- ─── 5. tech_save_pilot_correction — any assigned tech can save corrections ───
-- Was: v.responsible_user_id=auth.uid() in visits JOIN (016 line 105)
-- Now: removed; existing SOT join already validates assignment

CREATE OR REPLACE FUNCTION public.tech_save_pilot_correction(p_order_id uuid, p_visit_id uuid, p_key text, p_result control_result, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_company uuid; v_control public.inspection_controls%rowtype; v_latest public.control_result;
begin
 select o.company_id into v_company
 from public.service_orders o
 join public.service_order_technicians a on a.service_order_id=o.id and a.active
 join public.technician_profiles t on t.id=a.technician_id and t.user_id=auth.uid()
 join public.visits v on v.id=p_visit_id and v.company_id=o.company_id and v.gate_id=o.gate_id
                      and v.status='in_progress'
 where o.id=p_order_id
   and o.inspection_visit_id=p_visit_id
   and o.status='in_progress'
   and exists(select 1 from public.memberships m where m.user_id=auth.uid() and m.company_id=o.company_id and m.role='technician' and m.active);
 if v_company is null then raise exception 'Inspección no autorizada' using errcode='42501'; end if;
 select * into v_control from public.inspection_controls where visit_id=p_visit_id and control_key=p_key;
 if not found then raise exception 'Control inexistente'; end if;
 select coalesce((select corrected_result from public.inspection_corrections where inspection_control_id=v_control.id order by created_at desc,id desc limit 1),v_control.result) into v_latest;
 if v_latest<>'fault' or p_result='fault' then raise exception 'Esta corrección requiere un cambio desde Falla'; end if;
 if length(trim(coalesce(p_reason,'')))<10 or length(p_reason)>1000 or trim(p_reason)=trim(coalesce(v_control.note,'')) then raise exception 'Explicá qué hiciste para corregir la falla (mínimo 10 caracteres y distinto de la descripción original)'; end if;
 insert into public.inspection_corrections(company_id,inspection_control_id,actor_user_id,corrected_result,reason,idempotency_key)
 values(v_company,v_control.id,auth.uid(),p_result,trim(p_reason),gen_random_uuid());
 return v_control.id;
end $function$;

-- ─── 6. tech_get_pilot_progress — any assigned tech can read progress ─────────
-- Was: v.responsible_user_id=auth.uid() in WHERE (016 line 126)
-- Now: removed; existing SOT join already validates assignment

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
   'visit_id',v_visit.id,
   'controls',coalesce(jsonb_agg(jsonb_build_object(
     'key',c.control_key,
     'result',coalesce((select ic.corrected_result::text from public.inspection_corrections ic where ic.inspection_control_id=c.id order by ic.created_at desc,ic.id desc limit 1),c.result::text),
     'note',c.note,
     'original_result',c.result::text
   )) filter(where c.id is not null),'[]'::jsonb)
 ) into v_data
 from public.inspection_controls c where c.visit_id=v_visit.id;
 return v_data;
end $function$;

-- ─── 7. monitor_live_inspections — handle multiple heartbeats per visit ───────
-- Uses DISTINCT ON (visit_id ORDER BY last_seen_at DESC) to show the most recently
-- active tech per visit. Controls count is unaffected (aggregated across all techs).

CREATE OR REPLACE FUNCTION public.monitor_live_inspections()
 RETURNS TABLE(visit_id uuid, order_id uuid, company_id uuid, company_name text, gate_id uuid, gate_code text, gate_description text, facility_name text, technician_name text, started_at timestamp with time zone, last_seen_at timestamp with time zone, controls_done bigint, controls_total integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select v.id, o.id, v.company_id, c.name::text, g.id, g.code::text, g.description::text,
        f.name::text, concat_ws(' ',tp.first_name,tp.last_name)::text,
        v.started_at, h.last_seen_at, count(distinct ic.control_key)::bigint, 8
 from (
   select distinct on (visit_id) visit_id, order_id, company_id, user_id, last_seen_at
   from public.live_inspection_heartbeats
   where last_seen_at > now() - interval '5 minutes'
   order by visit_id, last_seen_at desc
 ) h
 join public.visits v on v.id=h.visit_id and v.company_id=h.company_id
 join public.service_orders o on o.id=h.order_id and o.inspection_visit_id=v.id and o.company_id=v.company_id
 join public.gates g on g.id=v.gate_id and g.company_id=v.company_id
 join public.companies c on c.id=v.company_id
 left join public.facilities f on f.id=g.facility_id
 left join public.technician_profiles tp on tp.user_id=h.user_id and tp.company_id=v.company_id
 left join public.inspection_controls ic on ic.visit_id=v.id and ic.company_id=v.company_id
 where auth.uid() is not null
   and v.status::text='in_progress' and o.status='in_progress'
   and exists(select 1 from public.memberships m where m.user_id=auth.uid() and m.company_id=v.company_id and m.active and m.role::text in ('admin','customer'))
 group by v.id,o.id,v.company_id,c.name,g.id,g.code,g.description,f.name,tp.first_name,tp.last_name,v.started_at,h.last_seen_at
 order by h.last_seen_at desc
$function$;

-- ─── Permissions ─────────────────────────────────────────────────────────────

REVOKE EXECUTE ON FUNCTION public.tech_live_heartbeat(uuid, uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.tech_live_heartbeat(uuid, uuid) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.tech_finish_pilot_order(uuid, uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.tech_finish_pilot_order(uuid, uuid) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.tech_save_pilot_control(uuid, uuid, text, text, control_result, text) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.tech_save_pilot_control(uuid, uuid, text, text, control_result, text) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.tech_save_pilot_correction(uuid, uuid, text, control_result, text) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.tech_save_pilot_correction(uuid, uuid, text, control_result, text) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.tech_get_pilot_progress(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.tech_get_pilot_progress(uuid) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.monitor_live_inspections() FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.monitor_live_inspections() TO authenticated;
