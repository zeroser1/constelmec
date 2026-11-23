-- Migration 015: service order creation RPCs.
--
-- Context (V1 circuit — authorized by ChatGPT 23/11/2026):
--   Admin panel needs a "Nueva orden" flow. No RPC exists for programmatic
--   creation of service_orders from the admin portal. Orders were seeded
--   manually or not at all.
--
-- Two RPCs:
--
--   1. admin_create_service_order
--      Creates a new service order in 'unassigned' status.
--      Does NOT accept notes — mig_014 routes notes through
--      admin_set_service_order_note separately.
--      Accepts p_idempotency_key: on network-timeout retry, the unique constraint
--      on audit_events(company_id, idempotency_key) causes a 23505 that rolls back
--      the whole transaction — the client can detect this and treat it as "order
--      already created" without creating a duplicate.
--      Returns the new order id (uuid).
--
--   2. admin_schedule_service_order
--      Transitions status 'unassigned' → 'scheduled'.
--      Called by the hook after at least one technician is successfully
--      assigned via admin_assign_order_technician().
--      Guards at the DB level: at least one active row in service_order_technicians
--      must exist before the transition is allowed.
--      Idempotent for 'scheduled' (no-op).
--      Raises for any other status (in_progress, completed, rescheduled, cancelled).
--
-- Hook orchestration contract:
--   1. Generate a stable idempotency_key (uuid) in client state before first call.
--   2. Call admin_create_service_order(... p_idempotency_key) → order_id.
--      On 23505 (unique_violation): first call committed — query recent orders to recover id.
--   3. For each selected tech: call admin_assign_order_technician().
--   4. If at least one assignment succeeded: call admin_schedule_service_order().
--   5. Partial failure: surface which techs were assigned and which failed;
--      do NOT create a second order — the order already exists.
--
-- NOT safe to apply to production until ChatGPT gives explicit approval for the
-- full 011–015 set.

-- ══════════════════════════════════════════════════════════════════════════════
-- 1. admin_create_service_order
-- ══════════════════════════════════════════════════════════════════════════════

create or replace function public.admin_create_service_order(
  p_company_id      uuid,
  p_facility_id     uuid,
  p_gate_id         uuid,
  p_service_type    text,
  p_scheduled_start timestamptz,
  p_scheduled_end   timestamptz,
  p_idempotency_key uuid
)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if not (app_private.is_platform_admin()
          or app_private.has_membership(p_company_id, array['admin']::public.member_role[])) then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  if p_idempotency_key is null then
    raise exception 'p_idempotency_key must not be null' using errcode = '22004';
  end if;

  -- Belt-and-suspenders: table CHECK also enforces this, but explicit guard gives a readable message.
  if p_scheduled_end <= p_scheduled_start then
    raise exception 'scheduled_end must be after scheduled_start' using errcode = '22023';
  end if;

  -- The service_orders FK only validates (gate_id, company_id); we also validate
  -- that the gate belongs to the specified facility within the company.
  if not exists (
    select 1 from public.gates
    where id          = p_gate_id
      and company_id  = p_company_id
      and facility_id = p_facility_id
  ) then
    raise exception 'gate not found in specified facility for this company' using errcode = 'P0002';
  end if;

  insert into public.service_orders (
    company_id,
    facility_id,
    gate_id,
    assigned_technician_id,
    service_type,
    status,
    scheduled_start,
    scheduled_end
  ) values (
    p_company_id,
    p_facility_id,
    p_gate_id,
    null,         -- service_order_technicians is the source of truth; this column stays null
    p_service_type,
    'unassigned', -- transitions to 'scheduled' after first tech assignment via admin_schedule_service_order
    p_scheduled_start,
    p_scheduled_end
  )
  returning id into v_id;

  -- Caller-supplied idempotency_key: the unique constraint on audit_events(company_id, idempotency_key)
  -- will raise 23505 on a duplicate call, rolling back the service_orders INSERT above too.
  insert into public.audit_events (
    company_id, gate_id, actor_user_id, event_type, event_payload, idempotency_key
  ) values (
    p_company_id,
    p_gate_id,
    auth.uid(),
    'order_created',
    jsonb_build_object(
      'order_id',        v_id,
      'facility_id',     p_facility_id,
      'gate_id',         p_gate_id,
      'service_type',    p_service_type,
      'scheduled_start', p_scheduled_start,
      'scheduled_end',   p_scheduled_end
    ),
    p_idempotency_key
  );

  return v_id;
end;
$$;

revoke execute on function public.admin_create_service_order(uuid, uuid, uuid, text, timestamptz, timestamptz, uuid) from public;
revoke execute on function public.admin_create_service_order(uuid, uuid, uuid, text, timestamptz, timestamptz, uuid) from anon;
grant  execute on function public.admin_create_service_order(uuid, uuid, uuid, text, timestamptz, timestamptz, uuid) to authenticated;

-- ══════════════════════════════════════════════════════════════════════════════
-- 2. admin_schedule_service_order
-- ══════════════════════════════════════════════════════════════════════════════
-- Transitions a service order from 'unassigned' to 'scheduled'.
-- Called by the client hook after at least one technician assignment succeeds.
-- DB-level guard: at least one active service_order_technicians row must exist.
-- Idempotent: 'scheduled' → no-op (no audit event).
-- Raises for all other statuses.

create or replace function public.admin_schedule_service_order(
  p_company_id uuid,
  p_order_id   uuid
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_status text;
begin
  if not (app_private.is_platform_admin()
          or app_private.has_membership(p_company_id, array['admin']::public.member_role[])) then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  select status into v_status
  from public.service_orders
  where id = p_order_id and company_id = p_company_id
  for update;

  if not found then
    raise exception 'service order not found in this company' using errcode = 'P0002';
  end if;

  if v_status = 'scheduled' then
    -- Idempotent: hook may call this twice on retry; silently succeed.
    return;
  end if;

  if v_status <> 'unassigned' then
    raise exception 'cannot schedule a % order; only unassigned orders can transition to scheduled',
      v_status
      using errcode = 'P0001';
  end if;

  -- DB-level guard: a scheduled order must have at least one active technician.
  -- assigned_technician_id is a dead column; service_order_technicians is the source of truth.
  if not exists (
    select 1 from public.service_order_technicians
    where service_order_id = p_order_id
      and company_id       = p_company_id
      and active           = true
  ) then
    raise exception 'cannot schedule an order with no assigned technicians' using errcode = 'P0001';
  end if;

  update public.service_orders
  set status = 'scheduled'
  where id = p_order_id and company_id = p_company_id;

  insert into public.audit_events (
    company_id, actor_user_id, event_type, event_payload, idempotency_key
  ) values (
    p_company_id,
    auth.uid(),
    'order_scheduled',
    jsonb_build_object('order_id', p_order_id),
    gen_random_uuid()
  );
end;
$$;

revoke execute on function public.admin_schedule_service_order(uuid, uuid) from public;
revoke execute on function public.admin_schedule_service_order(uuid, uuid) from anon;
grant  execute on function public.admin_schedule_service_order(uuid, uuid) to authenticated;

-- ══════════════════════════════════════════════════════════════════════════════
-- Required regression tests (run in staging, not production):
-- ══════════════════════════════════════════════════════════════════════════════
--   1. Tech A calls admin_create_service_order(A, fac_A, gate_A, 'preventive', ..., key) → 42501
--   2. Admin A calls admin_create_service_order(A, fac_A, gate_A, 'preventive', ..., key) → uuid
--      service_orders row: status='unassigned', assigned_technician_id=NULL
--      audit_events row: event_type='order_created', gate_id=gate_A, idempotency_key=key
--   3. Admin A calls admin_create_service_order(A, fac_A, gate_A, ..., same_key) again → 23505
--      (unique violation on audit_events; service_orders INSERT also rolled back)
--   4. Admin A calls admin_create_service_order(A, fac_A, gate_other_company, ...) → P0002
--      (gate not in facility for this company)
--   5. Admin A calls admin_create_service_order(A, fac_A, gate_A, ...) with end <= start → 22023
--   6. Admin A calls admin_schedule_service_order(A, new_order_id) → P0001
--      (order is 'unassigned' but no tech assigned yet — DB guard fires)
--   7. Admin A: assign tech via admin_assign_order_technician() → uuid
--      Then: admin_schedule_service_order(A, new_order_id) → void
--      service_orders.status = 'scheduled'
--   8. Second call to admin_schedule_service_order(A, new_order_id) → void (idempotent)
--   9. Admin B calls admin_schedule_service_order(A, new_order_id) → 42501 (cross-company)
