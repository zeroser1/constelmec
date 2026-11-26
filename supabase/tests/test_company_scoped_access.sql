-- DEV ONLY. Apply migrations 019, 020 and 021 before running.
-- Read-only regression assertions. No production writes, no persistent changes.
begin;
do $test$
declare
  v_company uuid;
  v_lion uuid;
  v_guilliman uuid;
  v_order uuid;
  v_count integer;
  v_unauthorized_company uuid := gen_random_uuid();
begin
  select id into v_company from public.companies
    where name ilike '%ACME%' order by created_at limit 1;
  if v_company is null then
    raise exception 'BLOCKED: ACME test company not found';
  end if;

  select id into v_lion from auth.users where email='lion@constelmec.com';
  select id into v_guilliman from auth.users where email='guilliman@constelmec.com';
  if v_lion is null or v_guilliman is null then
    raise exception 'BLOCKED: test technicians missing';
  end if;

  select o.id into v_order
  from public.service_orders o
  join public.service_order_technicians sot on sot.service_order_id=o.id
  join public.technician_profiles tp on tp.id=sot.technician_id
  where o.company_id=v_company and tp.user_id=v_guilliman
    and sot.active=true and not exists (
      select 1 from public.service_order_technicians s2
      join public.technician_profiles t2 on t2.id=s2.technician_id
      where s2.service_order_id=o.id and s2.active=true
        and t2.user_id=v_lion
    )
  order by o.created_at desc limit 1;
  if v_order is null then
    raise exception 'BLOCKED: no Guilliman-only order available for the regression';
  end if;

  perform set_config('request.jwt.claim.sub',v_lion::text,true);
  if not app_private.tech_can_access_company(v_company) then
    raise exception 'FAIL: Lion with active company assignment denied';
  end if;
  if app_private.tech_can_access_company(v_unauthorized_company) then
    raise exception 'FAIL: Lion authorized for unrelated company';
  end if;

  perform set_config('request.jwt.claim.sub',v_guilliman::text,true);
  if not app_private.tech_can_access_company(v_company) then
    raise exception 'FAIL: Guilliman with active company assignment denied';
  end if;

  select count(*) into v_count
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname in ('tech_start_pilot_order','tech_get_pilot_progress',
      'tech_save_pilot_control','tech_save_pilot_correction',
      'tech_finish_pilot_order','tech_live_heartbeat')
    and pg_get_functiondef(p.oid) ilike '%tech_can_access_company%';
  if v_count <> 6 then
    raise exception 'FAIL: expected six company-scoped inspection RPCs, got %',v_count;
  end if;
  raise notice 'PASS (read-only): company assignment, cross-company denial, six RPC guards, and legacy order fixture';
end
$test$;
rollback;

-- Additional E2E steps requiring authenticated browser sessions:
-- 1. Lion sees a scheduled ACME order assigned only to Guilliman (PASS expected).
-- 2. Lion opens same in-progress visit; Guilliman sees shared saved controls.
-- 3. Both can save, correct, upload photos and heartbeat without per-order assignments.
-- 4. Revoking Lion's company assignment immediately blocks list, RPC and storage reads.
-- 5. An ACME technician cannot list or modify a different company's orders.
-- 6. A completed order cannot be reopened; duplicate retries remain idempotent.
-- 7. Admin schedules an order with no service_order_technicians rows.
-- 8. Verify participants are derived from actual visits/controls, not assignments.
