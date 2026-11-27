-- Restore platform administrator access to inspection history after company-scoped technician authorization.
-- Source: DEV QA PR9 verified function definition (migration restore_platform_admin_inspection_history_022).
-- Idempotent CREATE OR REPLACE; authorization still checked within the function.
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
   and (app_private.is_platform_admin() or exists(select 1 from public.memberships m where m.company_id=g.company_id and m.user_id=auth.uid() and m.active and (m.role in ('admin','customer') or (m.role = 'technician' and app_private.tech_can_access_company(g.company_id)))));
 if v_company is null then raise exception 'Acceso no autorizado al portón' using errcode='42501'; end if;
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',         v.id,
   'order_id',   o.id,
   'date',       coalesce(v.closed_at,v.started_at,v.created_at),
   'status',     v.status,
   'participants', app_private.inspection_participants(v.id,v.company_id,v.responsible_user_id), 'technician', coalesce(nullif(concat_ws(' ',t.first_name,t.last_name),''),'Técnico'),
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
 left join lateral (select p.first_name,p.last_name from public.technician_profiles p where p.user_id=v.responsible_user_id order by (p.company_id=v.company_id) desc nulls last,p.id limit 1) t on true
 left join public.service_orders o on o.inspection_visit_id=v.id and o.company_id=v.company_id
 where v.gate_id=p_gate_id and v.company_id=v_company and v.status='closed';
 return v_history;
end $function$
;

REVOKE ALL ON FUNCTION public.gate_inspection_history(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gate_inspection_history(uuid) TO authenticated;
