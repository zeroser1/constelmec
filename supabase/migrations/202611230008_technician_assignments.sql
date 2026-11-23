-- Technician assignment infrastructure.
-- Extends the existing single-company technician model to support:
--   • Per-company enablement: which technicians are active for a given company
--   • Per-facility usual-assignment: a technician's habitual installation(s)
--   • Multi-technician orders: replace the single assigned_technician_id FK with a
--     many-to-many table that tracks lead vs support roles
--
-- Design decisions:
--   • technician_company_assignments and technician_facility_assignments are upsert-
--     toggled (no optimistic lock) because enable/disable is idempotent — the last
--     writer wins and no data is irreversibly lost. Optimistic lock would add UX friction
--     (timestamp round-trip) for a boolean flag that has no edit conflict semantics.
--   • service_order_technicians is insert/delete only — no update path.
--   • company_id is denormalized on both association tables for RLS efficiency.
--   • technician_profiles.company_id is kept for backward compat; new multi-company
--     linkage goes through technician_company_assignments.

-- ══════════════════════════════════════════════════════════════════════════════
-- 1. Enum
-- ══════════════════════════════════════════════════════════════════════════════

create type public.order_technician_role as enum ('lead', 'support');

-- ══════════════════════════════════════════════════════════════════════════════
-- 2. Tables
-- ══════════════════════════════════════════════════════════════════════════════

-- 2a. Technician enablement per company.
create table public.technician_company_assignments (
  id            uuid        primary key default gen_random_uuid(),
  technician_id uuid        not null references public.technician_profiles(id),
  company_id    uuid        not null references public.companies(id),
  active        boolean     not null default true,
  created_at    timestamptz not null default now(),
  unique(technician_id, company_id)
);

create index on public.technician_company_assignments(company_id);
create index on public.technician_company_assignments(company_id, active);

-- 2b. Technician usual-facility assignments.
create table public.technician_facility_assignments (
  id            uuid        primary key default gen_random_uuid(),
  technician_id uuid        not null references public.technician_profiles(id),
  facility_id   uuid        not null references public.facilities(id),
  company_id    uuid        not null references public.companies(id),
  active        boolean     not null default true,
  created_at    timestamptz not null default now(),
  unique(technician_id, facility_id)
);

create index on public.technician_facility_assignments(company_id);
create index on public.technician_facility_assignments(technician_id, company_id);

-- 2c. Multiple technicians per service order.
create table public.service_order_technicians (
  id               uuid                       primary key default gen_random_uuid(),
  service_order_id uuid                       not null references public.service_orders(id),
  technician_id    uuid                       not null references public.technician_profiles(id),
  company_id       uuid                       not null references public.companies(id),
  role             public.order_technician_role not null default 'support',
  assigned_at      timestamptz                not null default now(),
  unique(service_order_id, technician_id)
);

create index on public.service_order_technicians(service_order_id);
create index on public.service_order_technicians(company_id, technician_id);
-- Enforce the invariant at the DB level: at most one lead per order.
create unique index on public.service_order_technicians(service_order_id) where role = 'lead';

-- ══════════════════════════════════════════════════════════════════════════════
-- 3. Backfill — seed one company-assignment row per existing technician
-- ══════════════════════════════════════════════════════════════════════════════

insert into public.technician_company_assignments (technician_id, company_id, active)
select id, company_id, active
from public.technician_profiles
where company_id is not null
on conflict (technician_id, company_id) do nothing;

-- ══════════════════════════════════════════════════════════════════════════════
-- 4. RLS
-- ══════════════════════════════════════════════════════════════════════════════

alter table public.technician_company_assignments  enable row level security;
alter table public.technician_facility_assignments enable row level security;
alter table public.service_order_technicians       enable row level security;

create policy tech_company_assignments_read on public.technician_company_assignments
  for select to authenticated
  using(
    app_private.has_membership(company_id, array['admin']::public.member_role[])
    or app_private.is_platform_admin()
  );

create policy tech_facility_assignments_read on public.technician_facility_assignments
  for select to authenticated
  using(
    app_private.has_membership(company_id, array['admin']::public.member_role[])
    or app_private.is_platform_admin()
  );

create policy service_order_technicians_read on public.service_order_technicians
  for select to authenticated
  using(
    app_private.has_membership(company_id, array['admin']::public.member_role[])
    or app_private.is_platform_admin()
  );

revoke insert,update,delete on public.technician_company_assignments  from anon, authenticated;
revoke insert,update,delete on public.technician_facility_assignments from anon, authenticated;
revoke insert,update,delete on public.service_order_technicians       from anon, authenticated;

-- ══════════════════════════════════════════════════════════════════════════════
-- 5. Write RPCs
-- ══════════════════════════════════════════════════════════════════════════════

-- 5a. Enable or disable a technician for a company (upsert toggle).
create or replace function public.admin_set_technician_company(
  p_company_id    uuid,
  p_technician_id uuid,
  p_active        boolean
) returns void language plpgsql security definer set search_path=''
as $$
begin
  if not (app_private.is_platform_admin() or
          app_private.has_membership(p_company_id, array['admin']::public.member_role[])) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if not exists (select 1 from public.companies where id = p_company_id and active) then
    raise exception 'company not found or inactive' using errcode = 'P0002';
  end if;
  if not exists (
    select 1 from public.technician_profiles
    where id = p_technician_id and company_id = p_company_id
  ) then
    raise exception 'technician not found in this company' using errcode = 'P0002';
  end if;
  insert into public.technician_company_assignments (technician_id, company_id, active)
  values (p_technician_id, p_company_id, p_active)
  on conflict (technician_id, company_id) do update set active = excluded.active;
  -- When disabling, also deactivate all facility assignments for this company.
  if not p_active then
    update public.technician_facility_assignments
      set active = false
    where technician_id = p_technician_id and company_id = p_company_id;
  end if;
  insert into public.audit_events (company_id, actor_user_id, event_type, event_payload, idempotency_key)
  values (p_company_id, auth.uid(),
    case when p_active then 'technician_company_enabled' else 'technician_company_disabled' end,
    jsonb_build_object('technician_id', p_technician_id, 'company_id', p_company_id),
    gen_random_uuid());
end;
$$;
revoke execute on function public.admin_set_technician_company(uuid,uuid,boolean) from public;
revoke execute on function public.admin_set_technician_company(uuid,uuid,boolean) from anon;
grant  execute on function public.admin_set_technician_company(uuid,uuid,boolean) to authenticated;

-- 5b. Add or remove a technician's usual-facility assignment (upsert toggle).
create or replace function public.admin_set_technician_facility(
  p_company_id    uuid,
  p_technician_id uuid,
  p_facility_id   uuid,
  p_active        boolean
) returns void language plpgsql security definer set search_path=''
as $$
begin
  if not (app_private.is_platform_admin() or
          app_private.has_membership(p_company_id, array['admin']::public.member_role[])) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.technician_company_assignments
    where technician_id = p_technician_id and company_id = p_company_id and active
  ) then
    raise exception 'technician is not enabled for this company' using errcode = 'P0002';
  end if;
  if not exists (
    select 1 from public.facilities
    where id = p_facility_id and company_id = p_company_id and active
  ) then
    raise exception 'facility not found, inactive, or belongs to a different company'
      using errcode = 'P0002';
  end if;
  insert into public.technician_facility_assignments
    (technician_id, facility_id, company_id, active)
  values (p_technician_id, p_facility_id, p_company_id, p_active)
  on conflict (technician_id, facility_id) do update set active = excluded.active;
  insert into public.audit_events (company_id, actor_user_id, event_type, event_payload, idempotency_key)
  values (p_company_id, auth.uid(),
    case when p_active then 'technician_facility_assigned' else 'technician_facility_removed' end,
    jsonb_build_object(
      'technician_id', p_technician_id,
      'facility_id',   p_facility_id
    ),
    gen_random_uuid());
end;
$$;
revoke execute on function public.admin_set_technician_facility(uuid,uuid,uuid,boolean) from public;
revoke execute on function public.admin_set_technician_facility(uuid,uuid,uuid,boolean) from anon;
grant  execute on function public.admin_set_technician_facility(uuid,uuid,uuid,boolean) to authenticated;

-- 5c. Assign a technician to a service order (lead or support role).
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
  if not exists (
    select 1 from public.technician_company_assignments
    where technician_id = p_technician_id and company_id = p_company_id and active
  ) then
    raise exception 'technician is not enabled for this company' using errcode = 'P0002';
  end if;
  if not exists (
    select 1 from public.service_orders
    where id = p_order_id and company_id = p_company_id
  ) then
    raise exception 'service order not found in this company' using errcode = 'P0002';
  end if;
  -- Guard: reject duplicate assignment before the UNIQUE constraint fires with a raw 23505.
  if exists (
    select 1 from public.service_order_technicians
    where service_order_id = p_order_id and technician_id = p_technician_id
  ) then
    raise exception 'technician is already assigned to this order' using errcode = 'P0001';
  end if;
  -- Enforce at most one lead per order (backed by partial unique index — this check
  -- gives a user-readable message; the index prevents the race-condition bypass).
  if p_role = 'lead' and exists (
    select 1 from public.service_order_technicians
    where service_order_id = p_order_id and role = 'lead'
  ) then
    raise exception 'this order already has a lead technician; remove the existing lead first'
      using errcode = 'P0001';
  end if;
  insert into public.service_order_technicians
    (service_order_id, technician_id, company_id, role)
  values (p_order_id, p_technician_id, p_company_id, p_role)
  returning id into v_id;
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

-- 5d. Remove a technician from a service order.
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
  delete from public.service_order_technicians
    where service_order_id = p_order_id
      and technician_id    = p_technician_id
      and company_id       = p_company_id;
  if not found then
    raise exception 'technician assignment not found' using errcode = 'P0002';
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
