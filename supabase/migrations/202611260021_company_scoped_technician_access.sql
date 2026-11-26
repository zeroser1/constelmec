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
        and tp.company_id = p_company
        and tp.active = true
    );
$$;

revoke all on function app_private.tech_can_access_company(uuid) from public, anon;
grant execute on function app_private.tech_can_access_company(uuid) to authenticated;

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
      and p.proname like 'tech_%'
      and p.proname not in ('tech_create_spontaneous_order','tech_request_maintenance_photo_slot')
      and pg_get_functiondef(p.oid) ilike '%service_order_technicians%'
  loop
    old_definition := pg_get_functiondef(f.oid);
    new_definition := regexp_replace(
      old_definition, join_pattern,
      'join public.technician_profiles t on t.user_id = auth.uid() and t.company_id = o.company_id and t.active and app_private.tech_can_access_company(o.company_id)',
      'gi'
    );
    if new_definition = old_definition or new_definition ilike '%service_order_technicians%' then
      raise exception 'Migration 021 requires manual authorization review for RPC %', f.proname;
    end if;
    execute new_definition;
  end loop;

  -- A missing or unexpectedly rewritten RPC must not silently pass.
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'tech_start_pilot_order','tech_get_pilot_progress',
        'tech_save_pilot_control','tech_save_pilot_correction',
        'tech_finish_pilot_order','tech_live_heartbeat'
      )
      and pg_get_functiondef(p.oid) not ilike '%tech_can_access_company%'
  ) then
    raise exception 'Migration 021: one or more inspection RPCs lack company-scoped authorization';
  end if;
end
$migration$;

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
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if p_phase not in ('inspection','fault','correction') then raise exception 'Invalid photo phase'; end if;
  if p_mime_type not in ('image/jpeg','image/png','image/webp','image/heic','image/heif') then raise exception 'Invalid MIME type'; end if;
  if p_file_size_bytes is null or p_file_size_bytes < 1 or p_file_size_bytes > 10485760 then raise exception 'File size exceeds allowed limit'; end if;
  if nullif(btrim(p_original_filename),'') is null or length(p_original_filename)>255 then raise exception 'Invalid filename'; end if;

  select * into v_order from public.service_orders
  where id=p_order_id and company_id=p_company_id;
  if not found or v_order.status <> 'in_progress'
      or v_order.inspection_visit_id is distinct from p_visit_id then
    raise exception 'Order is not an active inspection';
  end if;
  select * into v_visit from public.visits
  where id=p_visit_id and company_id=p_company_id
    and gate_id=v_order.gate_id and status='in_progress';
  if not found then raise exception 'Visit not active or mismatched'; end if;
  if not app_private.tech_can_access_company(p_company_id) then
    raise exception 'Technician not enabled for company' using errcode='42501';
  end if;

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
