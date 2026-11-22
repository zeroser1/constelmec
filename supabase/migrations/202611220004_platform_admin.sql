-- Platform admin: global read-only access across all companies.
-- Follows the app_private SECURITY DEFINER pattern established in migration 001.
--
-- Security notes:
--   - app_private schema is NOT exposed in Supabase Data API (only 'public' is listed
--     under Project Settings > API > Exposed schemas). Clients cannot query it directly.
--   - INSERT/UPDATE/DELETE policies are NOT modified — write operations still require
--     has_membership with an admin role scoped to a specific company.
--   - No RPC, trigger, or endpoint exposes INSERT/UPDATE on platform_admins.
--     The only way to grant this role is via the Supabase SQL Editor (service role).
--
-- BOOTSTRAP (run MANUALLY in Supabase SQL Editor ONLY after both conditions are true):
--   (a) Account exists and email is confirmed
--   (b) This migration has been applied
--
-- Safer bootstrap — raises NO_DATA_FOUND (0 rows) or TOO_MANY_ROWS (>1 row):
--
-- do $$
-- declare target_user_id uuid;
-- begin
--   select id into strict target_user_id
--   from auth.users
--   where email = 'constelmec.gestion@gmail.com'
--     and email_confirmed_at is not null;
--   insert into app_private.platform_admins (user_id, granted_by)
--   values (target_user_id, 'bootstrap');
-- end;
-- $$;
--
-- Revocation (soft-delete, preserves audit trail):
--   UPDATE app_private.platform_admins SET active = false WHERE user_id = '<uuid>';

-- 1. Registry table (private schema — anon and authenticated have no access)
create table app_private.platform_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  granted_at timestamptz not null default now(),
  granted_by text not null,
  active     boolean not null default true
);
create index on app_private.platform_admins(user_id) where active;
revoke all on app_private.platform_admins from anon, authenticated;

-- 2. is_platform_admin() — SECURITY DEFINER, called from RLS policies and public RPCs.
--    Reads only the calling user's own row (WHERE user_id = auth.uid()).
--    Cannot return true for anyone other than the caller.
create or replace function app_private.is_platform_admin()
  returns boolean language sql stable security definer set search_path=''
as $$
  select exists(
    select 1 from app_private.platform_admins
    where user_id = (select auth.uid()) and active
  )
$$;
revoke all on function app_private.is_platform_admin() from public;
grant execute on function app_private.is_platform_admin() to authenticated;

-- 3. Public RPCs for the frontend.
--    Explicit REVOKE from public before GRANT to authenticated — defense in depth.

create or replace function public.i_am_platform_admin()
  returns boolean language sql stable security definer set search_path=''
as $$
  select app_private.is_platform_admin()
$$;
revoke execute on function public.i_am_platform_admin() from public;
grant execute on function public.i_am_platform_admin() to authenticated;

-- admin_list_all_companies(): explicit permission check — raises 42501 for non-admins
-- rather than returning an empty result set, so access attempts are always visible.
create or replace function public.admin_list_all_companies()
  returns setof public.companies language plpgsql stable security definer set search_path=''
as $$
begin
  if not app_private.is_platform_admin() then
    raise exception 'permission denied: global admin role required'
      using errcode = '42501';
  end if;
  return query
    select * from public.companies order by name;
end;
$$;
revoke execute on function public.admin_list_all_companies() from public;
grant execute on function public.admin_list_all_companies() to authenticated;

-- 4. Update all 14 RLS SELECT policies to also allow platform admins.
--    Uses ALTER POLICY (modifies USING expression in-place) — no drop+create window
--    where the table would have zero policies and deny all access.
--    Policy names verified against migrations 001-003.

alter policy companies_read on public.companies
  using(app_private.has_membership(id) or app_private.is_platform_admin());

alter policy memberships_read on public.memberships
  using(user_id = (select auth.uid()) or app_private.is_platform_admin());

alter policy facilities_read on public.facilities
  using(app_private.has_membership(company_id) or app_private.is_platform_admin());

alter policy gates_read on public.gates
  using(app_private.has_membership(company_id) or app_private.is_platform_admin());

alter policy visits_read on public.visits
  using(app_private.has_membership(company_id) or app_private.is_platform_admin());

alter policy controls_read on public.inspection_controls
  using(app_private.has_membership(company_id) or app_private.is_platform_admin());

alter policy observations_read on public.customer_observations
  using(app_private.has_membership(company_id) or app_private.is_platform_admin());

alter policy audit_read on public.audit_events
  using(app_private.has_membership(company_id, array['admin','technician']::public.member_role[]) or app_private.is_platform_admin());

alter policy findings_read on public.findings
  using(app_private.has_membership(company_id) or app_private.is_platform_admin());

alter policy finding_events_read on public.finding_events
  using(app_private.has_membership(company_id) or app_private.is_platform_admin());

alter policy corrections_read on public.inspection_corrections
  using(app_private.has_membership(company_id) or app_private.is_platform_admin());

alter policy reports_read on public.report_versions
  using(app_private.has_membership(company_id) or app_private.is_platform_admin());

alter policy technician_profiles_admin_read on public.technician_profiles
  using(app_private.has_membership(company_id, array['admin']::public.member_role[]) or app_private.is_platform_admin());

alter policy service_orders_admin_read on public.service_orders
  using(app_private.has_membership(company_id, array['admin']::public.member_role[]) or app_private.is_platform_admin());
