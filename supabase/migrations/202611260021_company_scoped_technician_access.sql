-- Migration 021: company-scoped technician authorization.
-- Apply AFTER migrations 019 and 020. This migration intentionally preserves
-- the latest RPC bodies from 020 and replaces ONLY their assignment gate.
-- Run in an isolated DEV project and validate before production rollout.

create or replace function app_private.tech_can_access_company(p_company uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select (select auth.uid()) is not null
    and app_private.has_membership(p_company, array['technician'::public.member_role])
    and exists (
      select 1
      from public.technician_profiles tp
      join public.technician_company_assignments tca
        on tca.technician_id = tp.id
       and tca.company_id = p_company
       and tca.active = true
      join public.companies c
        on c.id = p_company and c.active = true
      where tp.user_id = (select auth.uid())
        and tp.active = true
    );
$$;

revoke all on function app_private.tech_can_access_company(uuid) from public, anon;
grant execute on function app_private.tech_can_access_company(uuid) to authenticated;

-- List only the signed-in technician's authorized clients across memberships.
create or replace function public.tech_list_accessible_companies()
returns table(id uuid, name text)
language sql stable security definer set search_path = ''
as $$
  select c.id, c.name
  from public.memberships m
  join public.companies c on c.id=m.company_id
  where m.user_id=(select auth.uid()) and m.role='technician' and m.active
    and c.active and app_private.tech_can_access_company(c.id)
  order by c.name, c.id;
$$;
revoke execute on function public.tech_list_accessible_companies() from public, anon;
grant execute on function public.tech_list_accessible_companies() to authenticated;

-- Administrators can see authorized technicians whose profile belongs to another client.
create or replace function public.admin_list_enabled_company_technicians(p_company uuid)
returns table(id uuid, first_name text, last_name text)
language sql stable security definer set search_path = ''
as $$
  select t.id, t.first_name, t.last_name
  from public.technician_company_assignments a
  join public.technician_profiles t on t.id=a.technician_id and t.active
  join public.companies c on c.id=a.company_id and c.active
  join public.memberships m on m.company_id=c.id and m.user_id=t.user_id
    and m.active and m.role='technician'
  where a.company_id=p_company and a.active
    and (app_private.is_platform_admin() or app_private.has_membership(p_company,array['admin']::public.member_role[]))
  order by t.last_name,t.first_name,t.id;
$$;
revoke execute on function public.admin_list_enabled_company_technicians(uuid) from public, anon;
grant execute on function public.admin_list_enabled_company_technicians(uuid) to authenticated;

-- Access rule shared by company data reads, alongside the existing platform role.
create or replace function app_private.can_read_company_data(p_company uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select app_private.has_membership(p_company, array['admin','customer']::public.member_role[])
    or app_private.is_platform_admin()
    or app_private.tech_can_access_company(p_company);
$$;
revoke execute on function app_private.can_read_company_data(uuid) from public, anon;
grant execute on function app_private.can_read_company_data(uuid) to authenticated;

-- Gate-based reads, observations and attachments already call this helper.
-- Do not grant access based on historic service_order_technicians rows.
create or replace function app_private.tech_assigned_to_gate(p_company uuid, p_gate uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select app_private.tech_can_access_company(p_company)
     and exists (
       select 1 from public.gates g
       where g.id = p_gate and g.company_id = p_company
     );
$$;

-- Remove broad technician reads via membership alone. Admin/customer retain
-- existing company-level visibility. The admin-specific policy remains intact.
drop policy if exists service_orders_member_read on public.service_orders;
create policy service_orders_member_read on public.service_orders
for select to authenticated
using (
  app_private.has_membership(company_id, array['admin'::public.member_role,'customer'::public.member_role])
  or app_private.tech_can_access_company(company_id)
);

drop policy if exists gates_read on public.gates;
create policy gates_read on public.gates
for select to authenticated
using (
  app_private.has_membership(company_id, array['admin'::public.member_role,'customer'::public.member_role])
  or app_private.tech_can_access_company(company_id)
  or app_private.is_platform_admin()
);

drop policy if exists visits_read on public.visits;
create policy visits_read on public.visits
for select to authenticated
using (
  app_private.has_membership(company_id, array['admin'::public.member_role,'customer'::public.member_role])
  or app_private.tech_can_access_company(company_id)
  or app_private.is_platform_admin()
);

drop policy if exists controls_read on public.inspection_controls;
create policy controls_read on public.inspection_controls
for select to authenticated
using (
  app_private.has_membership(company_id, array['admin'::public.member_role,'customer'::public.member_role])
  or app_private.tech_can_access_company(company_id)
  or app_private.is_platform_admin()
);

drop policy if exists corrections_read on public.inspection_corrections;
create policy corrections_read on public.inspection_corrections
for select to authenticated
using (
  app_private.has_membership(company_id, array['admin'::public.member_role,'customer'::public.member_role])
  or app_private.tech_can_access_company(company_id)
  or app_private.is_platform_admin()
);

alter policy companies_read on public.companies
using (app_private.is_platform_admin() or (active and app_private.can_read_company_data(id)));
alter policy memberships_read on public.memberships
using (app_private.is_platform_admin() or (
  user_id = (select auth.uid()) and app_private.has_membership(company_id)
));

alter policy facilities_read on public.facilities
using (app_private.can_read_company_data(company_id));
-- Use write time after the order lock. Transaction start time can make a
-- later correction sort before the one it follows, including within one transaction.
alter table public.inspection_corrections alter column created_at set default clock_timestamp();

alter policy repairs_read on public.inspection_repairs
using (app_private.can_read_company_data(company_id));
alter policy findings_read on public.findings
using (app_private.can_read_company_data(company_id));
alter policy finding_events_read on public.finding_events
using (app_private.can_read_company_data(company_id));
alter policy reports_read on public.report_versions
using (app_private.can_read_company_data(company_id));

alter policy observations_read on public.customer_observations
using (app_private.can_read_company_data(company_id));
-- Observation writes go through the role-scoped RPCs, as on the deployed baseline.
drop policy if exists observations_insert on public.customer_observations;

alter policy service_order_technicians_self_read on public.service_order_technicians
using (
  app_private.has_membership(company_id, array['admin']::public.member_role[])
  or app_private.is_platform_admin()
  or (
    app_private.tech_can_access_company(company_id)
    and exists (select 1 from public.technician_profiles t
      where t.id=technician_id and t.user_id=(select auth.uid()) and t.active)
  )
);

-- Preserve the exact 019/020 inspection behavior (idempotency, corrections,
-- repairs and concurrency) while swapping the old order-assignment JOIN.
-- Fail CLOSED if any target function has an unfamiliar authorization shape.
do $migration$
declare
  f record;
  old_definition text;
  new_definition text;
  join_pattern text :=
    'join[[:space:]]+public[.]service_order_technicians[[:space:]]+a[[:space:]]+on[[:space:]]+a[.]service_order_id[[:space:]]*=[[:space:]]*o[.]id[[:space:]]+and[[:space:]]+a[.]active([[:space:]]*=[[:space:]]*true)?[[:space:]]+join[[:space:]]+public[.]technician_profiles[[:space:]]+t[[:space:]]+on[[:space:]]+t[.]id[[:space:]]*=[[:space:]]*a[.]technician_id[[:space:]]+and[[:space:]]+t[.]user_id[[:space:]]*=[[:space:]]*auth[.]uid[(][)]';
begin
  for f in
    select p.oid, p.proname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'tech_get_pilot_progress', 'tech_save_pilot_control',
        'tech_save_pilot_correction', 'tech_finish_pilot_order', 'tech_live_heartbeat',
        'tech_save_pilot_control_v2', 'tech_save_pilot_correction_v2', 'tech_finish_pilot_order_v2'
      )
      and pg_get_functiondef(p.oid) ilike '%service_order_technicians%'
  loop
    old_definition := pg_get_functiondef(f.oid);
    new_definition := regexp_replace(
      old_definition, join_pattern,
      'join public.companies access_company on access_company.id = o.company_id and app_private.tech_can_access_company(o.company_id)',
      'gi'
    );
    if f.proname = 'tech_get_pilot_progress' then
      new_definition := replace(new_definition, 'join public.service_orders o on o.inspection_visit_id=v.id',
        'join public.service_orders o on o.inspection_visit_id=v.id and o.company_id=v.company_id and o.gate_id=v.gate_id and o.status=''in_progress''');
    end if;
    if new_definition not ilike '%tech_can_access_company%'
      or new_definition ilike '%service_order_technicians%' then
      raise exception 'Migration 021 requires manual authorization review for RPC %', f.proname;
    end if;
    execute new_definition;
  end loop;

  if to_regprocedure('public.tech_start_pilot_order_v2(uuid,timestamptz)') is not null then
    old_definition := pg_get_functiondef('public.tech_start_pilot_order_v2(uuid,timestamptz)'::regprocedure);
    new_definition := regexp_replace(old_definition,
      'and exists[(]select 1 from public[.]memberships m[[:space:]]+where m[.]user_id=auth[.]uid[(][)] and m[.]company_id=o[.]company_id[[:space:]]+and m[.]role=''technician'' and m[.]active[)]',
      'and app_private.tech_can_access_company(o.company_id)', 'i');
    new_definition := regexp_replace(new_definition,
      'if not exists[(][[:space:]]+select 1 from public[.]service_order_technicians a[[:space:]]+join public[.]technician_profiles t on t[.]id=a[.]technician_id and t[.]user_id=auth[.]uid[(][)][[:space:]]+where a[.]service_order_id=v[.]id and a[.]active=true[[:space:]]+[)] then[[:space:]]+raise exception ''Inspección no autorizada'' using errcode=''42501'';[[:space:]]+end if;',
      '', 'i');
    if new_definition not ilike '%tech_can_access_company(o.company_id)%'
      or new_definition ilike '%service_order_technicians%' then
      raise exception 'Migration 021 requires manual authorization review for tech_start_pilot_order_v2';
    end if;
    execute new_definition;
  end if;

  -- Fail if a required signature is absent, including the expanded 020 signatures.
  if exists (
    select 1 from unnest(array[
      'public.tech_start_pilot_order(uuid)',
      'public.tech_get_pilot_progress(uuid)',
      'public.tech_save_pilot_control(uuid,uuid,text,text,public.control_result,text,jsonb)',
      'public.tech_save_pilot_correction(uuid,uuid,text,public.control_result,text,uuid,text,jsonb)',
      'public.tech_finish_pilot_order(uuid,uuid)',
      'public.tech_live_heartbeat(uuid,uuid)'
    ]) as signature
    where to_regprocedure(signature) is null
  ) then
    raise exception 'Migration 021 requires the 018 and 020 RPC signatures';
  end if;
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'tech_get_pilot_progress',
        'tech_save_pilot_control','tech_save_pilot_correction',
        'tech_finish_pilot_order','tech_live_heartbeat'
      )
      and pg_get_functiondef(p.oid) not ilike '%tech_can_access_company%'
  ) then
    raise exception 'Migration 021: one or more inspection RPCs lack company-scoped authorization';
  end if;
end
$migration$;

create or replace function public.tech_start_pilot_order(p_order_id uuid)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  target public.service_orders%rowtype;
  visit uuid;
begin
  select o.* into target from public.service_orders o
  where o.id=p_order_id and o.status in ('scheduled','in_progress')
    and app_private.tech_assigned_to_gate(o.company_id,o.gate_id)
  for update of o;
  if not found then
    raise exception 'Orden no autorizada o no disponible' using errcode='42501';
  end if;

  visit := target.inspection_visit_id;
  if visit is null then
    insert into public.visits(company_id,gate_id,status,responsible_user_id,started_at)
    values(target.company_id,target.gate_id,'in_progress',auth.uid(),now())
    returning id into visit;
  elsif not exists (
    select 1 from public.visits v where v.id=visit and v.company_id=target.company_id
      and v.gate_id=target.gate_id and v.status='in_progress'
  ) then
    raise exception 'La visita vinculada no está activa o no corresponde a la orden' using errcode='42501';
  end if;
  update public.service_orders set status='in_progress', inspection_visit_id=visit
  where id=target.id and (status<>'in_progress' or inspection_visit_id is null);
  return visit;
end;
$$;

-- Administrators may schedule without picking a technician per order.
create or replace function public.admin_schedule_service_order(p_company_id uuid, p_order_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_status text;
begin
  if not (app_private.is_platform_admin()
      or app_private.has_membership(p_company_id, array['admin']::public.member_role[])) then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  select status into v_status from public.service_orders
  where id = p_order_id and company_id = p_company_id for update;
  if not found then
    raise exception 'service order not found in this company' using errcode = 'P0002';
  end if;
  if v_status = 'scheduled' then return; end if;
  if v_status <> 'unassigned' then
    raise exception 'cannot schedule a % order; only unassigned orders can transition to scheduled',
      v_status using errcode = 'P0001';
  end if;

  update public.service_orders set status = 'scheduled'
  where id = p_order_id and company_id = p_company_id;

  insert into public.audit_events
    (company_id, actor_user_id, event_type, event_payload, idempotency_key)
  values (p_company_id, auth.uid(), 'order_scheduled',
          jsonb_build_object('order_id',p_order_id,'assignment_model','company'),
          gen_random_uuid());
end;
$$;

-- A spontaneous order is now available to all active technicians of its company.
-- Serialize per gate to prevent duplicate spontaneous orders under concurrency.
create or replace function public.tech_create_spontaneous_order(
  p_gate_id uuid, p_service_type text default 'preventive'
)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_gate public.gates%rowtype; v_order uuid;
begin
  if auth.uid() is null then
    raise exception 'Autenticación requerida' using errcode='42501';
  end if;
  select * into v_gate from public.gates where id=p_gate_id and active=true;
  if not found then raise exception 'Portón inexistente o inactivo'; end if;
  if not app_private.tech_can_access_company(v_gate.company_id) then
    raise exception 'Técnico sin acceso a este cliente' using errcode='42501';
  end if;
  if p_service_type not in ('preventive','corrective','emergency') then
    raise exception 'Tipo de servicio inválido';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_gate_id::text, 0));
  select o.id into v_order
    from public.service_orders o
    where o.company_id=v_gate.company_id and o.gate_id=p_gate_id
      and (o.status='in_progress'
        or (o.status='scheduled' and o.scheduled_start::date=current_date))
    order by case when o.status='in_progress' then 0 else 1 end,
             o.created_at desc limit 1;
  if v_order is not null then return v_order; end if;

  insert into public.service_orders
    (company_id,facility_id,gate_id,assigned_technician_id,service_type,
     status,scheduled_start,scheduled_end,notes)
  values
    (v_gate.company_id,v_gate.facility_id,p_gate_id,null,p_service_type,
     'scheduled',now(),now()+interval '2 hours',
     'Iniciada espontáneamente por técnico')
  returning id into v_order;
  return v_order;
end;
$$;

-- Photo slot: preserve validation and visit checks, replace only authorization.
create or replace function public.tech_request_maintenance_photo_slot(
  p_company_id uuid, p_order_id uuid, p_visit_id uuid,
  p_control_key text, p_phase text, p_mime_type text,
  p_file_size_bytes bigint, p_original_filename text
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_order public.service_orders%rowtype;
  v_visit public.visits%rowtype;
  v_id uuid := gen_random_uuid();
  v_ext text;
  v_path text;
begin
  if not app_private.tech_can_access_company(p_company_id) then
    raise exception 'Technician not enabled for company' using errcode='42501';
  end if;
  if p_phase not in ('inspection','fault','correction') then raise exception 'Invalid photo phase'; end if;
  if p_mime_type not in ('image/jpeg','image/png','image/webp','image/heic','image/heif') then raise exception 'Invalid MIME type'; end if;
  if p_file_size_bytes is null or p_file_size_bytes < 1 or p_file_size_bytes > 10485760 then raise exception 'File size exceeds allowed limit'; end if;
  if nullif(btrim(p_original_filename),'') is null or length(p_original_filename)>255 then raise exception 'Invalid filename'; end if;

  select * into v_order from public.service_orders
  where id=p_order_id and company_id=p_company_id for update;
  if not found or v_order.status <> 'in_progress'
      or v_order.inspection_visit_id is distinct from p_visit_id then
    raise exception 'Order is not an active inspection';
  end if;
  select * into v_visit from public.visits
  where id=p_visit_id and company_id=p_company_id
    and gate_id=v_order.gate_id and status='in_progress';
  if not found then raise exception 'Visit not active or mismatched'; end if;
  v_ext := case p_mime_type
    when 'image/jpeg' then 'jpg'
    when 'image/png' then 'png'
    when 'image/webp' then 'webp'
    when 'image/heic' then 'heic' else 'heif' end;
  v_path := p_company_id::text||'/'||v_order.gate_id::text||'/'||
            p_order_id::text||'/'||p_visit_id::text||'/'||v_id::text||'.'||v_ext;
  insert into public.maintenance_photos
    (id,company_id,gate_id,service_order_id,visit_id,control_key,phase,
     storage_path,mime_type,original_filename,file_size_bytes,uploaded_by)
  values
    (v_id,p_company_id,v_order.gate_id,p_order_id,p_visit_id,
     nullif(btrim(p_control_key),''),p_phase,v_path,p_mime_type,
     p_original_filename,p_file_size_bytes,auth.uid());
  return jsonb_build_object('photo_id',v_id,'storage_path',v_path,'bucket','maintenance-evidence');
end;
$$;

-- Prevent a revoked technician from confirming a previously reserved photo.
create or replace function public.tech_confirm_maintenance_photo(p_photo_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare p public.maintenance_photos%rowtype; obj storage.objects%rowtype;
begin
  select * into p from public.maintenance_photos
  where id=p_photo_id and uploaded_by=auth.uid() for update;
  if not found then raise exception 'Photo reservation not found'; end if;
  if not app_private.tech_can_access_company(p.company_id) then
    raise exception 'Technician no longer enabled for company' using errcode='42501';
  end if;
  if p.upload_status='confirmed' then return; end if;
  perform 1 from public.service_orders o
    join public.visits v on v.id=p.visit_id and v.company_id=p.company_id
      and v.gate_id=p.gate_id
    where o.id=p.service_order_id and o.inspection_visit_id=v.id
      and o.company_id=p.company_id and o.gate_id=p.gate_id
      and o.status='in_progress' and v.status='in_progress'
    for update of o;
  if not found then raise exception 'Inspection closed'; end if;
  select * into obj from storage.objects
  where bucket_id='maintenance-evidence' and name=p.storage_path;
  if not found then raise exception 'File not uploaded'; end if;
  if coalesce((obj.metadata->>'size')::bigint,-1) <> p.file_size_bytes then
    raise exception 'Uploaded file size mismatch';
  end if;
  update public.maintenance_photos
    set upload_status='confirmed',storage_confirmed_at=now()
    where id=p_photo_id;
end;
$$;

-- Initial control writes have no actor column; keep actor evidence in the immutable audit trail.
create or replace function app_private.audit_company_inspection_control()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is not null then
    insert into public.audit_events (company_id,visit_id,actor_user_id,event_type,event_payload,idempotency_key)
    values (new.company_id,new.visit_id,auth.uid(),'inspection_control_saved',
      jsonb_build_object('control_id',new.id),gen_random_uuid());
  end if;
  return new;
end;
$$;
revoke all on function app_private.audit_company_inspection_control() from public, anon, authenticated;
create trigger audit_company_inspection_control
after insert on public.inspection_controls
for each row execute function app_private.audit_company_inspection_control();

create or replace function app_private.audit_company_inspection_close()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is not null then
    insert into public.audit_events (company_id,visit_id,actor_user_id,event_type,idempotency_key)
    values (new.company_id,new.id,auth.uid(),'inspection_closed',gen_random_uuid());
  end if;
  return new;
end;
$$;
revoke all on function app_private.audit_company_inspection_close() from public, anon, authenticated;
create trigger audit_company_inspection_close
after update of status on public.visits
for each row when (old.status is distinct from new.status and new.status='closed')
execute function app_private.audit_company_inspection_close();

-- Names shown in reports come only from recorded work on this visit.
create or replace function app_private.inspection_participants(p_visit uuid,p_company uuid,p_starter uuid)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(profile.name order by profile.name),'[]'::jsonb)
  from (
    select p_starter as user_id
    union select a.actor_user_id from public.audit_events a
      where a.visit_id=p_visit and a.company_id=p_company and a.event_type in ('inspection_control_saved','inspection_closed')
    union select r.actor_user_id from public.inspection_corrections r join public.inspection_controls c
      on c.id=r.inspection_control_id and c.company_id=r.company_id
      where c.visit_id=p_visit and c.company_id=p_company
    union select r.actor_user_id from public.inspection_repairs r join public.inspection_controls c
      on c.id=r.inspection_control_id and c.company_id=r.company_id
      where c.visit_id=p_visit and c.company_id=p_company
    union select p.uploaded_by from public.maintenance_photos p
      where p.visit_id=p_visit and p.company_id=p_company and p.upload_status='confirmed'
  ) people
  join lateral (
    select nullif(trim(concat_ws(' ',t.first_name,t.last_name)),'') as name
    from public.technician_profiles t where t.user_id=people.user_id
    order by (t.company_id=p_company) desc nulls last,t.id limit 1
  ) profile on profile.name is not null;
$$;
revoke all on function app_private.inspection_participants(uuid,uuid,uuid) from public, anon, authenticated;

-- Gate history is SECURITY DEFINER; tighten its own authorization without
-- changing the latest 020 report body (repairs/corrected notes included).
do $history$
declare
  old_definition text;
  new_definition text;
begin
  old_definition := pg_get_functiondef('public.gate_inspection_history(uuid)'::regprocedure);
  new_definition := replace(
    old_definition,
    'and m.role in (''technician'',''admin'',''customer'')',
    'and (m.role in (''admin'',''customer'') or (m.role = ''technician'' and app_private.tech_can_access_company(g.company_id)))'
  );
  if old_definition = new_definition or strpos(new_definition,'''technician'',') = 0 then
    raise exception 'Migration 021: gate_inspection_history authorization requires manual review';
  end if;
  new_definition := replace(new_definition,
    'left join public.technician_profiles t on t.user_id=v.responsible_user_id and t.company_id=v.company_id',
    'left join lateral (select p.first_name,p.last_name from public.technician_profiles p where p.user_id=v.responsible_user_id order by (p.company_id=v.company_id) desc nulls last,p.id limit 1) t on true');
  new_definition := replace(new_definition, '''technician'',',
    '''participants'', app_private.inspection_participants(v.id,v.company_id,v.responsible_user_id), ''technician'',');
  execute new_definition;
end
$history$;

-- Company revocation is the source of truth. Do not block deactivation merely
-- because an obsolete order-assignment row is in progress. Preserve order
-- assignments as historical data, without treating them as participants.
create or replace function public.admin_set_technician_company(
  p_company_id uuid, p_technician_id uuid, p_active boolean
)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_tech_company uuid;
begin
  if not (app_private.is_platform_admin()
      or app_private.has_membership(p_company_id, array['admin']::public.member_role[])) then
    raise exception 'permission denied' using errcode='42501';
  end if;
  if not exists (select 1 from public.companies where id=p_company_id and active) then
    raise exception 'company not found or inactive' using errcode='P0002';
  end if;
  select company_id into v_tech_company from public.technician_profiles
  where id=p_technician_id and active;
  if not found then raise exception 'technician not found or inactive' using errcode='P0002'; end if;
  if (v_tech_company is null or v_tech_company <> p_company_id)
      and not app_private.is_platform_admin() then
    raise exception 'cross-company technician enablement requires platform administrator access'
      using errcode='42501';
  end if;

  perform id from public.technician_company_assignments
    where technician_id=p_technician_id and company_id=p_company_id
    for update;

  if not p_active then
    update public.technician_facility_assignments
      set active=false
    where technician_id=p_technician_id and company_id=p_company_id;
  end if;

  insert into public.technician_company_assignments
    (technician_id,company_id,active)
  values (p_technician_id,p_company_id,p_active)
  on conflict (technician_id,company_id)
  do update set active=excluded.active;

  insert into public.audit_events
    (company_id,actor_user_id,event_type,event_payload,idempotency_key)
  values (p_company_id,auth.uid(),
    case when p_active then 'technician_company_enabled'
         else 'technician_company_disabled' end,
    jsonb_build_object('technician_id',p_technician_id,'company_id',p_company_id,
      'cross_company',(v_tech_company is null or v_tech_company <> p_company_id)),
    gen_random_uuid());
end;
$$;

-- Recheck the assignment when an existing reservation is used or confirmed.
CREATE OR REPLACE FUNCTION app_private.can_upload_maintenance_photo(p_path text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select exists(
 select 1 from public.maintenance_photos p
 join public.service_orders so on so.id=p.service_order_id and so.company_id=p.company_id and so.gate_id=p.gate_id
 join public.visits v on v.id=p.visit_id and v.id=so.inspection_visit_id and v.company_id=p.company_id and v.gate_id=p.gate_id
 where p.storage_path=p_path and p.uploaded_by=(select auth.uid()) and p.upload_status='pending'
 and so.status='in_progress' and v.status='in_progress'
 and app_private.tech_can_access_company(p.company_id)
 )
$function$;

CREATE OR REPLACE FUNCTION app_private.can_upload_observation_attachment(p_path text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select exists(select 1 from public.observation_attachments a
 where a.storage_path=p_path and a.uploaded_by=(select auth.uid()) and a.upload_status='pending'
 and app_private.can_read_company_data(a.company_id))
$function$;

CREATE OR REPLACE FUNCTION public.confirm_observation_attachment(p_att_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a public.observation_attachments%rowtype; obj storage.objects%rowtype;
begin
 select * into a from public.observation_attachments where id=p_att_id and uploaded_by=auth.uid() for update;
 if not found then raise exception 'Attachment reservation not found';end if;
 if not app_private.can_read_company_data(a.company_id) then raise exception 'Access denied' using errcode='42501';end if;
 if a.upload_status='confirmed' then return;end if;
 select * into obj from storage.objects where bucket_id='observation-files' and name=a.storage_path;
 if not found then raise exception 'Attachment file not uploaded';end if;
 if coalesce((obj.metadata->>'size')::bigint,-1)<>a.file_size_bytes then raise exception 'File size mismatch';end if;
 update public.observation_attachments set upload_status='confirmed',storage_confirmed_at=now() where id=p_att_id;
end $function$;

CREATE OR REPLACE FUNCTION public.request_observation_attachment_slot(p_company_id uuid, p_observation_id uuid, p_reply_id uuid, p_mime_type text, p_file_size_bytes bigint, p_original_filename text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.customer_observations%rowtype; r public.observation_replies%rowtype;
 v_id uuid:=gen_random_uuid(); v_path text; v_ext text; v_gate uuid;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if (p_observation_id is null)=(p_reply_id is null) then raise exception 'Choose exactly one attachment parent';end if;
 if p_mime_type not in ('image/jpeg','image/png','image/webp','image/heic','image/heif') then raise exception 'Invalid MIME type';end if;
 if p_file_size_bytes is null or p_file_size_bytes<1 or p_file_size_bytes>10485760 then raise exception 'Invalid file size';end if;
 if nullif(btrim(p_original_filename),'') is null or length(p_original_filename)>255 then raise exception 'Invalid filename';end if;
 if p_reply_id is not null then
   select * into r from public.observation_replies where id=p_reply_id and company_id=p_company_id;
   if not found then raise exception 'Reply not found';end if;
   select * into o from public.customer_observations where id=r.observation_id and company_id=p_company_id;
   if not found then raise exception 'Observation not found';end if;
   if r.author_user_id<>auth.uid() then raise exception 'Only reply author may attach';end if;
 else
   select * into o from public.customer_observations where id=p_observation_id and company_id=p_company_id;
   if not found then raise exception 'Observation not found';end if;
   if o.author_user_id<>auth.uid() then raise exception 'Only observation author may attach';end if;
 end if;
 if not app_private.can_read_company_data(p_company_id) then raise exception 'Access denied';end if;
 v_gate:=o.gate_id;
 v_ext:=case p_mime_type when 'image/jpeg' then 'jpg' when 'image/png' then 'png' when 'image/webp' then 'webp' when 'image/heic' then 'heic' else 'heif' end;
 v_path:=p_company_id::text||'/'||v_gate::text||'/'||o.id::text||'/'||v_id::text||'.'||v_ext;
 insert into public.observation_attachments(id,company_id,gate_id,observation_id,reply_id,storage_path,mime_type,original_filename,file_size_bytes,uploaded_by)
 values(v_id,p_company_id,v_gate,p_observation_id,p_reply_id,v_path,p_mime_type,p_original_filename,p_file_size_bytes,auth.uid());
 return jsonb_build_object('attachment_id',v_id,'storage_path',v_path,'bucket','observation-files');
end $function$;

revoke execute on function public.tech_start_pilot_order(uuid) from public, anon;
grant execute on function public.tech_start_pilot_order(uuid) to authenticated;
revoke execute on function public.tech_create_spontaneous_order(uuid,text) from public, anon;
grant execute on function public.tech_create_spontaneous_order(uuid,text) to authenticated;
revoke execute on function public.tech_request_maintenance_photo_slot(uuid,uuid,uuid,text,text,text,bigint,text) from public, anon;
grant execute on function public.tech_request_maintenance_photo_slot(uuid,uuid,uuid,text,text,text,bigint,text) to authenticated;
revoke execute on function public.tech_confirm_maintenance_photo(uuid) from public, anon;
grant execute on function public.tech_confirm_maintenance_photo(uuid) to authenticated;
