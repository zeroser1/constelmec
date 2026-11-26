-- DEV only. Self-contained fixture with no real accounts or persistent changes.
begin;

create temp table company_auth_fixture (
  admin_id uuid default gen_random_uuid(),
  guilliman_id uuid default gen_random_uuid(),
  lion_id uuid default gen_random_uuid(),
  customer_id uuid default gen_random_uuid(),
  company_id uuid default gen_random_uuid(),
  other_company_id uuid default gen_random_uuid(),
  facility_id uuid default gen_random_uuid(),
  gate_id uuid default gen_random_uuid(),
  other_gate_id uuid default gen_random_uuid(),
  other_facility_id uuid default gen_random_uuid(),
  other_order_id uuid default gen_random_uuid(),
  lion_profile_id uuid default gen_random_uuid(),
  order_id uuid,
  visit_id uuid,
  observation_id uuid,
  pending_photo_id uuid
) on commit drop;
insert into company_auth_fixture default values;
grant select, update on company_auth_fixture to authenticated;

do $seed$
declare f company_auth_fixture%rowtype;
begin
  select * into f from company_auth_fixture;
  insert into auth.users(id,email,raw_app_meta_data,raw_user_meta_data)
  select id, id::text||'@constelmec.test', '{}', '{}'
  from unnest(array[f.admin_id,f.guilliman_id,f.lion_id,f.customer_id]) id;
  insert into public.companies (id,name) values (f.company_id,'QA Company'),(f.other_company_id,'QA Other Company');
  insert into public.memberships (company_id,user_id,role) values
    (f.company_id,f.admin_id,'admin'),(f.company_id,f.guilliman_id,'technician'),
    (f.company_id,f.lion_id,'technician'),(f.company_id,f.customer_id,'customer'),
    (f.other_company_id,f.lion_id,'technician');
  insert into public.facilities (id,company_id,name) values
    (f.facility_id,f.company_id,'QA Plant'),(f.other_facility_id,f.other_company_id,'QA Other Plant');
  insert into public.gates (id,company_id,facility_id,code,description) values
    (f.gate_id,f.company_id,f.facility_id,'QA-001','QA gate'),
    (f.other_gate_id,f.other_company_id,f.other_facility_id,'QA-002','QA other gate');
  insert into public.technician_profiles(id,user_id,company_id,first_name,last_name) values
    (gen_random_uuid(),f.guilliman_id,f.company_id,'Roboute','Guilliman'),
    (f.lion_profile_id,f.lion_id,f.company_id,'Lion','El Jonson');
  insert into public.technician_company_assignments(company_id,technician_id,active)
    select f.company_id,id,true from public.technician_profiles where user_id in (f.guilliman_id,f.lion_id);
  insert into public.service_orders(id,company_id,facility_id,gate_id,service_type,status,scheduled_start,scheduled_end)
  values(f.other_order_id,f.other_company_id,f.other_facility_id,f.other_gate_id,'preventive','scheduled',now(),now()+interval '1 hour');
end
$seed$;

set local role authenticated;
do $shared$
declare
  f company_auth_fixture%rowtype;
  slot jsonb;
  progress jsonb;
begin
  select * into f from company_auth_fixture;
  perform set_config('request.jwt.claim.sub',f.admin_id::text,true);
  f.order_id := public.admin_create_service_order(f.company_id,f.facility_id,f.gate_id,'preventive',now(),now()+interval '1 hour',gen_random_uuid());
  perform public.admin_schedule_service_order(f.company_id,f.order_id);
  assert (select count(*)=0 from public.service_order_technicians where service_order_id=f.order_id);
  assert (select count(*)=2 from public.admin_list_enabled_company_technicians(f.company_id));
  perform set_config('request.jwt.claim.sub',f.customer_id::text,true);
  f.observation_id := public.customer_create_observation(f.company_id,f.gate_id,'[QA] Observación de prueba',gen_random_uuid());

  perform set_config('request.jwt.claim.sub',f.guilliman_id::text,true);
  f.visit_id := public.tech_start_pilot_order(f.order_id);
  perform public.tech_save_pilot_control(f.order_id,f.visit_id,'structure','Estructura','ok','Nota original de Guilliman');
  perform public.tech_live_heartbeat(f.order_id,f.visit_id);
  slot := public.tech_request_maintenance_photo_slot(f.company_id,f.order_id,f.visit_id,'structure','inspection','image/png',20,'structure.png');
  insert into storage.objects(bucket_id,name,metadata) values('maintenance-evidence',slot->>'storage_path','{"size":20}');
  perform public.tech_confirm_maintenance_photo((slot->>'photo_id')::uuid);

  perform set_config('request.jwt.claim.sub',f.lion_id::text,true);
  assert (select count(*)=1 from public.tech_list_accessible_companies() where id=f.company_id);
  assert (select count(*)=1 from public.service_orders where id=f.order_id);
  assert (select count(*)=0 from public.service_orders where id=f.other_order_id);
  assert (select count(*)=0 from public.gates where id=f.other_gate_id);
  assert public.tech_get_pilot_progress(f.other_order_id) is null;
  begin
    perform public.tech_start_pilot_order(f.other_order_id);
    raise exception 'Cross-company start unexpectedly allowed';
  exception when insufficient_privilege then null;
  end;
  assert public.tech_start_pilot_order(f.order_id)=f.visit_id;
  perform public.tech_reply_to_observation(f.company_id,f.observation_id,'[QA] Recepción confirmada');
  assert (select count(*)=2 from public.get_observation_conversation(f.company_id,f.observation_id));
  progress := public.tech_get_pilot_progress(f.order_id);
  assert progress->'controls'->0->>'note'='Nota original de Guilliman';
  perform public.tech_save_pilot_control(f.order_id,f.visit_id,'guides','Guías','ok','Nota original de Lion');
  perform public.tech_live_heartbeat(f.order_id,f.visit_id);
  slot := public.tech_request_maintenance_photo_slot(f.company_id,f.order_id,f.visit_id,'guides','inspection','image/png',20,'guides.png');
  insert into storage.objects(bucket_id,name,metadata) values('maintenance-evidence',slot->>'storage_path','{"size":20}');
  perform public.tech_confirm_maintenance_photo((slot->>'photo_id')::uuid);
  assert (select count(*)=2 from public.maintenance_photos where visit_id=f.visit_id);
  assert jsonb_array_length(public.tech_get_pilot_progress(f.order_id)->'controls')=2;
  slot := public.tech_request_maintenance_photo_slot(f.company_id,f.order_id,f.visit_id,'guides','inspection','image/png',20,'pending.png');
  f.pending_photo_id := (slot->>'photo_id')::uuid;
  perform set_config('qa.photo_path',slot->>'storage_path',true);
  update company_auth_fixture set order_id=f.order_id,visit_id=f.visit_id,observation_id=f.observation_id,pending_photo_id=f.pending_photo_id;
end
$shared$;

do $revocation$
declare f company_auth_fixture%rowtype;
begin
  select * into f from company_auth_fixture;
  perform set_config('request.jwt.claim.sub',f.admin_id::text,true);
  perform public.admin_set_technician_company(f.company_id,f.lion_profile_id,false);

  perform set_config('request.jwt.claim.sub',f.lion_id::text,true);
  assert (select count(*)=0 from public.tech_list_accessible_companies());
  assert (select count(*)=0 from public.service_orders where id=f.order_id);
  assert (select count(*)=0 from public.inspection_controls where visit_id=f.visit_id);
  assert (select count(*)=0 from public.maintenance_photos where visit_id=f.visit_id);
  assert not app_private.can_upload_maintenance_photo(current_setting('qa.photo_path'));
  assert public.tech_get_pilot_progress(f.order_id) is null;
  assert (select count(*)=0 from public.customer_observations where id=f.observation_id);
  assert (select count(*)=0 from public.get_observation_conversation(f.company_id,f.observation_id));
  begin
    perform public.gate_inspection_history(f.gate_id);
    raise exception 'Revoked history unexpectedly allowed';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.tech_confirm_maintenance_photo(f.pending_photo_id);
    raise exception 'Revoked photo confirmation unexpectedly allowed';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.tech_save_pilot_control(f.order_id,f.visit_id,'motor','Motor','ok');
    raise exception 'Revoked write unexpectedly allowed';
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claim.sub',f.admin_id::text,true);
  perform public.admin_set_technician_company(f.company_id,f.lion_profile_id,true);
  perform set_config('request.jwt.claim.sub',f.lion_id::text,true);
  assert jsonb_array_length(public.tech_get_pilot_progress(f.order_id)->'controls')=2;
end
$revocation$;

do $closed$
declare
  f company_auth_fixture%rowtype;
  key text;
  history jsonb;
begin
  select * into f from company_auth_fixture;
  perform set_config('request.jwt.claim.sub',f.lion_id::text,true);
  foreach key in array array['motor','electrical','photocells','emergency','opening','closing'] loop
    perform public.tech_save_pilot_control(f.order_id,f.visit_id,key,key,'ok');
  end loop;
  perform public.tech_finish_pilot_order(f.order_id,f.visit_id);
  begin
    perform public.tech_save_pilot_control(f.order_id,f.visit_id,'motor','Motor','ok');
    raise exception 'Closed write unexpectedly allowed';
  exception when insufficient_privilege then null;
  end;
  assert (select count(*)=8 from public.inspection_controls where visit_id=f.visit_id);
  perform set_config('request.jwt.claim.sub',f.customer_id::text,true);
  assert (select count(*)=2 from public.get_observation_conversation(f.company_id,f.observation_id));
  history := public.gate_inspection_history(f.gate_id);
  assert jsonb_array_length(history)=1;
  assert history->0->'participants' ? 'Roboute Guilliman';
  assert history->0->'participants' ? 'Lion El Jonson';
end
$closed$;
rollback;
