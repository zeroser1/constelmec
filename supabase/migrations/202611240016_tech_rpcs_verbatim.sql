-- Migration 016 — Verbatim documentation of 9 existing production RPCs
-- Source: pg_get_functiondef queried by ChatGPT 2026-11-23 from project xpguxfttlxqpdlbhsjud.
-- PostgreSQL 17. All 9 RPCs confirmed: authenticated=YES, anon=NO, SECURITY DEFINER=YES.
-- NO functional changes from production. DO NOT APPLY to production without ChatGPT approval.

-- ── 1. tech_start_pilot_order ─────────────────────────────────────────────
-- Idempotent: returns existing inspection_visit_id. FOR UPDATE prevents race.
CREATE OR REPLACE FUNCTION public.tech_start_pilot_order(p_order_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.service_orders%rowtype; v_visit uuid;
begin
select o.* into v from public.service_orders o join public.service_order_technicians a on a.service_order_id=o.id and a.active=true join public.technician_profiles t on t.id=a.technician_id and t.user_id=auth.uid() where o.id=p_order_id and o.status in ('scheduled','in_progress') and exists(select 1 from public.memberships m where m.user_id=auth.uid() and m.company_id=o.company_id and m.role='technician' and m.active) for update of o;
if not found then raise exception 'Orden no asignada o no disponible' using errcode='42501'; end if;
v_visit:=v.inspection_visit_id;
if v_visit is null then
insert into public.visits(company_id,gate_id,status,responsible_user_id,started_at) values(v.company_id,v.gate_id,'in_progress',auth.uid(),now()) returning id into v_visit;
update public.service_orders set inspection_visit_id=v_visit where id=v.id;
end if;
update public.service_orders set status='in_progress' where id=v.id and status='scheduled';
return v_visit;
end $function$;

-- ── 2. tech_live_heartbeat ────────────────────────────────────────────────
-- Idempotent: ON CONFLICT DO UPDATE on (visit_id).
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
 from public.visits v join public.service_orders o on o.inspection_visit_id=v.id
 where v.id=p_visit_id and o.id=p_order_id and v.responsible_user_id=auth.uid()
   and v.status::text='in_progress' and o.status='in_progress' and v.company_id=o.company_id;
 if v_company is null then raise exception 'Inspección no activa o sin autorización' using errcode='42501'; end if;
 insert into public.live_inspection_heartbeats(visit_id,order_id,company_id,user_id,last_seen_at)
 values(p_visit_id,p_order_id,v_company,auth.uid(),now())
 on conflict(visit_id) do update set last_seen_at=excluded.last_seen_at
 where public.live_inspection_heartbeats.user_id=auth.uid()
   and public.live_inspection_heartbeats.order_id=p_order_id;
end $function$;

-- ── 3. tech_save_pilot_control ────────────────────────────────────────────
-- NOT idempotent: server-generated idempotency_key on corrections path. See mig 017.
CREATE OR REPLACE FUNCTION public.tech_save_pilot_control(p_order_id uuid, p_visit_id uuid, p_key text, p_label text, p_result control_result, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_company uuid; v_id uuid; v_original public.inspection_controls%rowtype; v_note text; v_current public.control_result;
begin
 select o.company_id into v_company from public.service_orders o join public.service_order_technicians a on a.service_order_id=o.id and a.active join public.technician_profiles t on t.id=a.technician_id and t.user_id=auth.uid() join public.visits v on v.id=p_visit_id and v.company_id=o.company_id and v.gate_id=o.gate_id and v.responsible_user_id=auth.uid() and v.status='in_progress' where o.id=p_order_id and o.status='in_progress' and exists(select 1 from public.memberships m where m.user_id=auth.uid() and m.company_id=o.company_id and m.role='technician' and m.active);
 if v_company is null then raise exception 'Inspección no autorizada' using errcode='42501'; end if;
 if p_key is null or length(trim(p_key))=0 or length(p_key)>80 or p_label is null or length(trim(p_label))=0 or length(p_label)>200 or length(coalesce(p_note,''))>1000 then raise exception 'Control inválido'; end if;
 v_note:=nullif(trim(p_note),'');
 if p_result = 'fault'::public.control_result and length(coalesce(v_note, '')) < 10 then raise exception 'Describí la falla con al menos 10 caracteres'; end if;
 select * into v_original from public.inspection_controls where visit_id=p_visit_id and control_key=p_key;
 if found then
   select coalesce((select corrected_result from public.inspection_corrections where inspection_control_id=v_original.id order by created_at desc,id desc limit 1),v_original.result) into v_current;
   if v_current='fault' and p_result<>'fault' then raise exception 'Para cambiar una falla, explicá la corrección en el formulario'; end if;
   insert into public.inspection_corrections(company_id,inspection_control_id,actor_user_id,corrected_result,reason,idempotency_key)
   values(v_company,v_original.id,auth.uid(),p_result,coalesce(v_note,'Actualización del resultado durante inspección en curso'),gen_random_uuid());
   return v_original.id;
 end if;
 insert into public.inspection_controls(company_id,visit_id,control_key,control_label,result,note) values(v_company,p_visit_id,p_key,p_label,p_result,v_note) returning id into v_id;
 return v_id;
end $function$;

-- ── 4. tech_save_pilot_correction ────────────────────────────────────────
-- NOT idempotent: state-dependent, new key per call. See mig 017.
CREATE OR REPLACE FUNCTION public.tech_save_pilot_correction(p_order_id uuid, p_visit_id uuid, p_key text, p_result control_result, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_company uuid; v_control public.inspection_controls%rowtype; v_latest public.control_result;
begin
select o.company_id into v_company from public.service_orders o join public.service_order_technicians a on a.service_order_id=o.id and a.active join public.technician_profiles t on t.id=a.technician_id and t.user_id=auth.uid() join public.visits v on v.id=p_visit_id and v.company_id=o.company_id and v.gate_id=o.gate_id and v.responsible_user_id=auth.uid() and v.status='in_progress' where o.id=p_order_id and o.status='in_progress' and exists(select 1 from public.memberships m where m.user_id=auth.uid() and m.company_id=o.company_id and m.role='technician' and m.active);
if v_company is null then raise exception 'Inspección no autorizada' using errcode='42501'; end if;
select * into v_control from public.inspection_controls where visit_id=p_visit_id and control_key=p_key;
if not found then raise exception 'Control inexistente'; end if;
select coalesce((select corrected_result from public.inspection_corrections where inspection_control_id=v_control.id order by created_at desc,id desc limit 1),v_control.result) into v_latest;
if v_latest<>'fault' or p_result='fault' then raise exception 'Esta corrección requiere un cambio desde Falla'; end if;
if length(trim(coalesce(p_reason,'')))<10 or length(p_reason)>1000 or trim(p_reason)=trim(coalesce(v_control.note,'')) then raise exception 'Explicá qué hiciste para corregir la falla (mínimo 10 caracteres y distinto de la descripción original)'; end if;
insert into public.inspection_corrections(company_id,inspection_control_id,actor_user_id,corrected_result,reason,idempotency_key) values(v_company,v_control.id,auth.uid(),p_result,trim(p_reason),gen_random_uuid());
return v_control.id;
end $function$;

-- ── 5. tech_finish_pilot_order ────────────────────────────────────────────
-- NOT idempotent: requires in_progress. Retry after lost response fails. See mig 017.
CREATE OR REPLACE FUNCTION public.tech_finish_pilot_order(p_order_id uuid, p_visit_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_company uuid;
begin
 select o.company_id into v_company from public.service_orders o join public.service_order_technicians a on a.service_order_id=o.id and a.active join public.technician_profiles t on t.id=a.technician_id and t.user_id=auth.uid() join public.visits v on v.id=p_visit_id and v.company_id=o.company_id and v.gate_id=o.gate_id and v.responsible_user_id=auth.uid() and v.status='in_progress' where o.id=p_order_id and o.status='in_progress' and exists(select 1 from public.memberships m where m.user_id=auth.uid() and m.company_id=o.company_id and m.role='technician' and m.active);
 if v_company is null then raise exception 'Inspección no autorizada' using errcode='42501'; end if;
 if (select count(distinct control_key) from public.inspection_controls where visit_id=p_visit_id and control_key=any(array['structure','guides','motor','electrical','photocells','emergency','opening','closing'])) <> 8 then raise exception 'Completá los ocho controles antes de finalizar'; end if;
 update public.visits set status='closed',closed_at=now() where id=p_visit_id;
 update public.service_orders set status='completed',completed_at=now() where id=p_order_id;
end $function$;

-- ── 6. tech_get_pilot_progress ────────────────────────────────────────────
-- Read-only. Returns jsonb with visit_id + controls array.
CREATE OR REPLACE FUNCTION public.tech_get_pilot_progress(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_visit public.visits%rowtype; v_data jsonb;
begin
select v.* into v_visit from public.visits v join public.service_orders o on o.inspection_visit_id=v.id join public.service_order_technicians a on a.service_order_id=o.id and a.active join public.technician_profiles t on t.id=a.technician_id and t.user_id=auth.uid() where o.id=p_order_id and v.responsible_user_id=auth.uid() and v.status='in_progress' and exists(select 1 from public.memberships m where m.user_id=auth.uid() and m.company_id=o.company_id and m.role='technician' and m.active) limit 1;
if not found then return null; end if;
select jsonb_build_object('visit_id',v_visit.id,'controls',coalesce(jsonb_agg(jsonb_build_object('key',c.control_key,'result',coalesce((select ic.corrected_result::text from public.inspection_corrections ic where ic.inspection_control_id=c.id order by ic.created_at desc,ic.id desc limit 1),c.result::text),'note',c.note,'original_result',c.result::text)) filter(where c.id is not null),'[]'::jsonb)) into v_data from public.inspection_controls c where c.visit_id=v_visit.id;
return v_data;
end $function$;

-- ── 7. tech_create_spontaneous_order ─────────────────────────────────────
-- Idempotent: returns existing in_progress order if one exists for this tech+gate.
CREATE OR REPLACE FUNCTION public.tech_create_spontaneous_order(p_gate_id uuid, p_service_type text DEFAULT 'preventive'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_gate public.gates%rowtype; v_tech uuid; v_order uuid;
begin
 if auth.uid() is null then raise exception 'Autenticación requerida' using errcode='42501'; end if;
 select * into v_gate from public.gates where id=p_gate_id and active=true;
 if not found then raise exception 'Portón inexistente o inactivo'; end if;
 select t.id into v_tech from public.technician_profiles t join public.memberships m on m.user_id=t.user_id and m.company_id=t.company_id and m.role='technician' and m.active=true where t.user_id=auth.uid() and t.company_id=v_gate.company_id and t.active=true limit 1;
 if v_tech is null then raise exception 'Técnico sin acceso a este cliente' using errcode='42501'; end if;
 if p_service_type not in ('preventive','corrective','emergency') then raise exception 'Tipo de servicio inválido'; end if;
 select o.id into v_order from public.service_orders o join public.service_order_technicians a on a.service_order_id=o.id and a.technician_id=v_tech and a.active=true where o.gate_id=p_gate_id and o.status='in_progress' order by o.created_at desc limit 1;
 if v_order is not null then return v_order; end if;
 insert into public.service_orders(company_id,facility_id,gate_id,assigned_technician_id,service_type,status,scheduled_start,scheduled_end,notes) values(v_gate.company_id,v_gate.facility_id,p_gate_id,v_tech,p_service_type,'scheduled',now(),now()+interval '2 hours','Iniciada espontáneamente por técnico') returning id into v_order;
 insert into public.service_order_technicians(service_order_id,technician_id,company_id,role) values(v_order,v_tech,v_gate.company_id,'lead');
 return v_order;
end $function$;

-- ── 8. monitor_live_inspections ───────────────────────────────────────────
-- Read-only. Returns active inspections for admin+customer roles.
CREATE OR REPLACE FUNCTION public.monitor_live_inspections()
 RETURNS TABLE(visit_id uuid, order_id uuid, company_id uuid, company_name text, gate_id uuid, gate_code text, gate_description text, facility_name text, technician_name text, started_at timestamp with time zone, last_seen_at timestamp with time zone, controls_done bigint, controls_total integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select v.id, o.id, v.company_id, c.name::text, g.id, g.code::text,g.description::text,
        f.name::text,concat_ws(' ',tp.first_name,tp.last_name)::text,
        v.started_at,h.last_seen_at,count(distinct ic.control_key)::bigint,8
 from public.live_inspection_heartbeats h
 join public.visits v on v.id=h.visit_id and v.company_id=h.company_id
 join public.service_orders o on o.id=h.order_id and o.inspection_visit_id=v.id and o.company_id=v.company_id
 join public.gates g on g.id=v.gate_id and g.company_id=v.company_id
 join public.companies c on c.id=v.company_id
 left join public.facilities f on f.id=g.facility_id
 left join public.technician_profiles tp on tp.user_id=h.user_id and tp.company_id=v.company_id
 left join public.inspection_controls ic on ic.visit_id=v.id and ic.company_id=v.company_id
 where auth.uid() is not null and v.status::text='in_progress' and o.status='in_progress'
   and h.last_seen_at>now()-interval '5 minutes'
   and exists(select 1 from public.memberships m where m.user_id=auth.uid() and m.company_id=v.company_id and m.active and m.role::text in ('admin','customer'))
 group by v.id,o.id,v.company_id,c.name,g.id,g.code,g.description,f.name,tp.first_name,tp.last_name,v.started_at,h.last_seen_at
 order by h.last_seen_at desc
$function$;

-- ── 9. gate_inspection_history ────────────────────────────────────────────
-- Read-only. Returns jsonb with closed visits + controls + corrections for a gate.
CREATE OR REPLACE FUNCTION public.gate_inspection_history(p_gate_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_company uuid; v_history jsonb;
begin
select g.company_id into v_company from public.gates g where g.id=p_gate_id and exists(select 1 from public.memberships m where m.company_id=g.company_id and m.user_id=auth.uid() and m.active and m.role in ('technician','admin','customer'));
if v_company is null then raise exception 'Acceso no autorizado al portón' using errcode='42501'; end if;
select coalesce(jsonb_agg(jsonb_build_object(
'id',v.id,'order_id',o.id,'date',coalesce(v.closed_at,v.started_at,v.created_at),'status',v.status,
'technician',coalesce(nullif(concat_ws(' ',t.first_name,t.last_name),''),'Técnico'),
'controls',(select coalesce(jsonb_agg(jsonb_build_object(
'key',c.control_key,'label',c.control_label,'original_result',c.result::text,'original_note',c.note,
'result',coalesce(lastc.corrected_result::text,c.result::text),'note',c.note,
'corrections',(select coalesce(jsonb_agg(jsonb_build_object('result',ic.corrected_result::text,'reason',ic.reason,'date',ic.created_at) order by ic.created_at,ic.id),'[]'::jsonb) from public.inspection_corrections ic where ic.inspection_control_id=c.id)
) order by c.created_at,c.id),'[]'::jsonb) from public.inspection_controls c
left join lateral (select corrected_result from public.inspection_corrections ic where ic.inspection_control_id=c.id order by ic.created_at desc,ic.id desc limit 1) lastc on true
where c.visit_id=v.id)
) order by coalesce(v.closed_at,v.started_at,v.created_at) desc),'[]'::jsonb) into v_history
from public.visits v left join public.technician_profiles t on t.user_id=v.responsible_user_id and t.company_id=v.company_id
left join public.service_orders o on o.inspection_visit_id=v.id and o.company_id=v.company_id
where v.gate_id=p_gate_id and v.company_id=v_company and v.status='closed';
return v_history;
end $function$;

-- ── GRANT statements ──────────────────────────────────────────────────────
-- All 9 RPCs: authenticated=YES, anon=NO, SECURITY DEFINER=YES (confirmed).
-- Explicit GRANTs below — matches production permissions.
GRANT EXECUTE ON FUNCTION public.tech_start_pilot_order(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.tech_live_heartbeat(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.tech_save_pilot_control(uuid, uuid, text, text, control_result, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.tech_save_pilot_correction(uuid, uuid, text, control_result, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.tech_finish_pilot_order(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.tech_get_pilot_progress(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.tech_create_spontaneous_order(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.monitor_live_inspections() TO authenticated;
GRANT EXECUTE ON FUNCTION public.gate_inspection_history(uuid) TO authenticated;
