-- Platform admin: global read access across all companies.
-- Follows the app_private SECURITY DEFINER pattern established in migration 001.
--
-- BOOTSTRAP (run once after constelmec.gestion@gmail.com confirms their account):
--   INSERT INTO app_private.platform_admins (user_id, granted_by)
--   SELECT id, 'bootstrap' FROM auth.users WHERE email = 'constelmec.gestion@gmail.com';
--
-- Revocation:
--   UPDATE app_private.platform_admins SET active = false WHERE user_id = '<uuid>';

-- 1. Registry table (private schema — clients cannot read or write)
create table app_private.platform_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  granted_at timestamptz not null default now(),
  granted_by text not null,
  active     boolean not null default true
);
create index on app_private.platform_admins(user_id) where active;
revoke all on app_private.platform_admins from anon, authenticated;

-- 2. is_platform_admin() — SECURITY DEFINER, called from RLS policies and public RPCs
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

-- 3. Public RPCs for the frontend
create or replace function public.i_am_platform_admin()
  returns boolean language sql stable security definer set search_path=''
as $$
  select app_private.is_platform_admin()
$$;
grant execute on function public.i_am_platform_admin() to authenticated;

create or replace function public.admin_list_all_companies()
  returns setof public.companies language sql stable security definer set search_path=''
as $$
  select * from public.companies
  where app_private.is_platform_admin()
  order by name
$$;
grant execute on function public.admin_list_all_companies() to authenticated;

-- 4. Update all RLS SELECT policies to also allow platform admins.
--    Uses ALTER POLICY (modifies USING expression in-place) — no drop+create window
--    where the table would have zero policies and deny all access.

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
