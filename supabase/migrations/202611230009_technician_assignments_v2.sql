-- Migration 009: Corrective revision to migration 008 (technician assignment infrastructure).
-- NOT safe to apply to production until 007, 008, and 009 are reviewed together.
--
-- Applies three architecture decisions reviewed by ChatGPT:
--
--   1. Soft-delete on service_order_technicians.
--      Physical DELETE was wrong for a maintenance system where re-assignment history matters.
--      Carlos is assigned → absent → replaced by Juan → returns: admin must be able to
--      re-assign Carlos without creating a new order. Full history preserved as inactive rows.
--
--   2. Cross-company enablement requires platform admin.
--      Migration 008 blocked all cross-company enablement (technician.company_id check).
--      Fix: allow active techs from other companies, but gate cross-company on is_platform_admin().
--      Company admins cannot discover or arbitrarily incorporate techs from other companies.
--
--   3. Status-aware cascade when disabling a technician.
--      in_progress orders → raise exception (admin must re-assign manually before disabling).
--      pending/scheduled/rescheduled orders → soft-remove the tech assignment automatically.
--      completed/cancelled orders → preserved unchanged.
--      No needs_reassignment flag: derive "needs reassignment" from orders with no active lead.

-- ══════════════════════════════════════════════════════════════════════════════
-- 1. Alter service_order_technicians — add soft-delete columns
-- ══════════════════════════════════════════════════════════════════════════════

alter table public.service_order_technicians
  add column active      boolean     not null default true,
  add column removed_at  timestamptz,
  add column removed_by  uuid references auth.users(id);

-- Mark all backfilled/existing rows as active (they already default to true; this is explicit).
update public.service_order_technicians set active = true;

-- Drop the global unique constraint that blocks re-assignment of the same tech.
alter table public.service_order_technicians
  drop constraint service_order_technicians_service_order_id_technician_id_key;

-- Drop the old partial unique index for 'lead' (created without active scope).
-- Use pg_indexes lookup to avoid hardcoding the auto-generated name.
do $$
declare
  v_idx text;
begin
  select indexname into v_idx
  from pg_indexes
  where tablename  = 'service_order_technicians'
    and schemaname = 'public'
    and indexdef   like '%UNIQUE%'
    and indexdef   like '%role = ''lead''%';
  if v_idx is not null then
    execute 'drop index if exists public.' || quote_ident(v_idx);
  end if;
end;
$$;

-- New partial unique indexes scoped to active assignments only.
-- Allows re-assignment: the previous inactive row is not counted.
create unique index on public.service_order_technicians(service_order_id, technician_id)
  where active = true;

-- At most one active lead per order (race-condition proof; RPC also gives a readable message).
create unique index on public.service_order_technicians(service_order_id)
  where role = 'lead' and active = true;

-- ══════════════════════════════════════════════════════════════════════════════
-- 2. Replace admin_set_technician_company
--    Three changes from migration 008:
--      a) Relaxed technician check: any active tech may be enabled for any company
--      b) Cross-company enablement gated on is_platform_admin()
--      c) Status-aware cascade on disable
-- ══════════════════════════════════════════════════════════════════════════════

create or replace function public.admin_set_technician_company(
  p_company_id    uuid,
  p_technician_id uuid,
  p_active        boolean
) returns void language plpgsql security definer set search_path=''
as $$
declare
  v_tech_company uuid;
begin
  -- Auth guard: must be platform admin OR an admin of the target company.
  if not (app_private.is_platform_admin() or
          app_private.has_membership(p_company_id, array['admin']::public.member_role[])) then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  -- Target company must be active.
  if not exists (select 1 from public.companies where id = p_company_id and active) then
    raise exception 'company not found or inactive' using errcode = 'P0002';
  end if;

  -- Technician must exist and be active in the system (home company no longer required to match).
  select company_id into v_tech_company
  from public.technician_profiles
  where id = p_technician_id and active;

  if not found then
    raise exception 'technician not found or inactive' using errcode = 'P0002';
  end if;

  -- Cross-company enablement requires platform admin.
  -- NULL IS NULL check required: if tech has no home company, treat as cross-company.
  if (v_tech_company is null or v_tech_company <> p_company_id) and not app_private.is_platform_admin() then
    raise exception 'cross-company technician enablement requires platform administrator access'
      using errcode = '42501';
  end if;

  -- Lock the assignment row early (if it exists) to serialize with concurrent assigns.
  -- admin_assign_order_technician also takes this lock; whichever wins commits first,
  -- the loser then re-reads the updated active flag.
  perform id from public.technician_company_assignments
  where technician_id = p_technician_id and company_id = p_company_id
  for update;

  -- Disabling: status-aware cascade.
  if not p_active then
    -- Block if any active assignment is on an in-progress order.
    if exists (
      select 1
      from public.service_order_technicians sot
      join public.service_orders so on so.id = sot.service_order_id
      where sot.technician_id = p_technician_id
        and sot.company_id    = p_company_id
        and sot.active        = true
        and so.status         = 'in_progress'
    ) then
      raise exception
        'cannot disable a technician who is assigned to an in-progress service order'
        using errcode = 'P0001';
    end if;

    -- Soft-remove assignments on pending/scheduled/rescheduled orders.
    -- completed and cancelled orders are left untouched to preserve historical accuracy.
    update public.service_order_technicians sot
      set active     = false,
          removed_at = now(),
          removed_by = auth.uid()
    from public.service_orders so
    where sot.service_order_id = so.id
      and sot.technician_id    = p_technician_id
      and sot.company_id       = p_company_id
      and sot.active           = true
      and so.status not in ('in_progress', 'completed', 'cancelled');

    -- Deactivate all facility assignments for this company.
    update public.technician_facility_assignments
      set active = false
    where technician_id = p_technician_id
      and company_id    = p_company_id;
  end if;

  -- Upsert the company assignment row.
  insert into public.technician_company_assignments (technician_id, company_id, active)
  values (p_technician_id, p_company_id, p_active)
  on conflict (technician_id, company_id) do update set active = excluded.active;

  insert into public.audit_events (company_id, actor_user_id, event_type, event_payload, idempotency_key)
  values (p_company_id, auth.uid(),
    case when p_active then 'technician_company_enabled' else 'technician_company_disabled' end,
    jsonb_build_object(
      'technician_id', p_technician_id,
      'company_id',    p_company_id,
      'cross_company', (v_tech_company is null or v_tech_company <> p_company_id)
    ),
    gen_random_uuid());
end;
$$;
revoke execute on function public.admin_set_technician_company(uuid,uuid,boolean) from public;
revoke execute on function public.admin_set_technician_company(uuid,uuid,boolean) from anon;
grant  execute on function public.admin_set_technician_company(uuid,uuid,boolean) to authenticated;

-- ══════════════════════════════════════════════════════════════════════════════
-- 3. Replace admin_assign_order_technician
--    Two changes from migration 008:
--      a) Duplicate-assignment check scoped to active = true (re-assignment allowed)
--      b) Lead-conflict check scoped to active = true (previous lead can be replaced)
-- ══════════════════════════════════════════════════════════════════════════════

create or replace function public.admin_assign_order_technician(
  p_company_id    uuid,
  p_order_id      uuid,
  p_technician_id uuid,
  p_role          public.order_technician_role default 'support'
) returns uuid language plpgsql security definer set search_path=''
as $$
declare
  v_id uuid;
begin
  if not (app_private.is_platform_admin() or
          app_private.has_membership(p_company_id, array['admin']::public.member_role[])) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  -- Lock the company assignment row to prevent concurrent disable-assign races.
  -- Serializes with admin_set_technician_company: whichever function acquires the lock first
  -- commits before the other sees the updated active flag.
  perform id from public.technician_company_assignments
  where technician_id = p_technician_id and company_id = p_company_id and active
  for update;
  if not found then
    raise exception 'technician is not enabled for this company' using errcode = 'P0002';
  end if;
  if not exists (
    select 1 from public.service_orders
    where id = p_order_id and company_id = p_company_id
  ) then
    raise exception 'service order not found in this company' using errcode = 'P0002';
  end if;
  if not exists (
    select 1 from public.technician_profiles
    where id = p_technician_id and active
  ) then
    raise exception 'technician profile is not active' using errcode = 'P0002';
  end if;
  -- Guard: reject duplicate active assignment; ON CONFLICT below is the concurrent safety net.
  if exists (
    select 1 from public.service_order_technicians
    where service_order_id = p_order_id
      and technician_id    = p_technician_id
      and active           = true
  ) then
    raise exception 'technician is already actively assigned to this order'
      using errcode = 'P0001';
  end if;
  -- At most one active lead per order.
  if p_role = 'lead' and exists (
    select 1 from public.service_order_technicians
    where service_order_id = p_order_id
      and role             = 'lead'
      and active           = true
  ) then
    raise exception
      'this order already has an active lead technician; remove the existing lead first'
      using errcode = 'P0001';
  end if;
  -- ON CONFLICT ... DO NOTHING is the concurrent safety net: if two transactions slip through
  -- the application guard simultaneously, one gets NULL back (not a raw 23505).
  insert into public.service_order_technicians
    (service_order_id, technician_id, company_id, role)
  values (p_order_id, p_technician_id, p_company_id, p_role)
  on conflict (service_order_id, technician_id) where active = true do nothing
  returning id into v_id;
  if v_id is null then
    raise exception 'technician is already actively assigned to this order'
      using errcode = 'P0001';
  end if;
  insert into public.audit_events (company_id, actor_user_id, event_type, event_payload, idempotency_key)
  values (p_company_id, auth.uid(), 'order_technician_assigned',
    jsonb_build_object(
      'assignment_id',  v_id,
      'order_id',       p_order_id,
      'technician_id',  p_technician_id,
      'role',           p_role::text
    ),
    gen_random_uuid());
  return v_id;
end;
$$;
revoke execute on function public.admin_assign_order_technician(uuid,uuid,uuid,public.order_technician_role) from public;
revoke execute on function public.admin_assign_order_technician(uuid,uuid,uuid,public.order_technician_role) from anon;
grant  execute on function public.admin_assign_order_technician(uuid,uuid,uuid,public.order_technician_role) to authenticated;

-- ══════════════════════════════════════════════════════════════════════════════
-- 4. Replace admin_remove_order_technician — now a soft-delete.
--    Physical DELETE replaced with active=false + timestamps.
--    Re-assignment of the same tech is allowed after soft-delete.
-- ══════════════════════════════════════════════════════════════════════════════

create or replace function public.admin_remove_order_technician(
  p_company_id    uuid,
  p_order_id      uuid,
  p_technician_id uuid
) returns void language plpgsql security definer set search_path=''
as $$
begin
  if not (app_private.is_platform_admin() or
          app_private.has_membership(p_company_id, array['admin']::public.member_role[])) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  update public.service_order_technicians
    set active     = false,
        removed_at = now(),
        removed_by = auth.uid()
  where service_order_id = p_order_id
    and technician_id    = p_technician_id
    and company_id       = p_company_id
    and active           = true;
  if not found then
    raise exception 'active technician assignment not found' using errcode = 'P0002';
  end if;
  insert into public.audit_events (company_id, actor_user_id, event_type, event_payload, idempotency_key)
  values (p_company_id, auth.uid(), 'order_technician_removed',
    jsonb_build_object(
      'order_id',      p_order_id,
      'technician_id', p_technician_id
    ),
    gen_random_uuid());
end;
$$;
revoke execute on function public.admin_remove_order_technician(uuid,uuid,uuid) from public;
revoke execute on function public.admin_remove_order_technician(uuid,uuid,uuid) from anon;
grant  execute on function public.admin_remove_order_technician(uuid,uuid,uuid) to authenticated;
