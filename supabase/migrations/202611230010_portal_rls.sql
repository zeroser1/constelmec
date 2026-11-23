-- Migration 010: member-level read access for tech and customer portals.
--
-- NOT safe to apply to production until ChatGPT reviews the complete set
-- (007, 008, 009, 010) and gives explicit approval.
--
-- Context:
--   Migration 003 added technician_profiles and service_orders with admin-only
--   SELECT policies.  The tech portal needs technicians to read their own profile
--   row and the orders they are assigned to.  The customer portal needs all
--   company members to read service orders so upcoming service dates are visible.
--
-- What this migration does:
--   1. Technicians can read their own technician_profiles row (user_id = auth.uid()).
--   2. All active company members can read service_orders for their company.
--      Existing admin-only policy remains unchanged — these are additive (OR'd).
--   3. Technicians can read their own rows in service_order_technicians.
--      The existing admin-only policy from migration 008 would otherwise return 0
--      rows silently, breaking the entire assigned-orders view in TechnicianPortal.
--
-- What this migration does NOT do:
--   - No schema changes.
--   - No RPC changes.
--   - No removal or modification of existing policies.

-- ══════════════════════════════════════════════════════════════════════════════
-- 1. Technician self-read on technician_profiles
-- ══════════════════════════════════════════════════════════════════════════════
-- Allows a technician to read their own profile row to find their profile ID,
-- specialty, and license details.  Does not expose other technicians' profiles.

create policy technician_profiles_self_read
  on public.technician_profiles
  for select
  to authenticated
  using (user_id = (select auth.uid()));

-- ══════════════════════════════════════════════════════════════════════════════
-- 2. Company member read on service_orders
-- ══════════════════════════════════════════════════════════════════════════════
-- The existing service_orders_admin_read policy (from migration 003) already
-- covers admins.  This policy extends visibility to all active members so that:
--   - Technicians can join their service_order_technicians rows to service_orders
--     to see the full order context (gate, facility, dates, status).
--   - Customers can see upcoming and past service orders for their company,
--     enabling "próximo servicio" in the customer portal.
--
-- Note: service_orders still has no INSERT/UPDATE/DELETE for non-admin roles
-- (revoked in migration 003).  This is a read-only expansion.

create policy service_orders_member_read
  on public.service_orders
  for select
  to authenticated
  using (app_private.has_membership(company_id));

-- ══════════════════════════════════════════════════════════════════════════════
-- 3. Technician self-read on service_order_technicians
-- ══════════════════════════════════════════════════════════════════════════════
-- Migration 008 added an admin-only SELECT policy on service_order_technicians.
-- Without this policy, technicians would receive 0 rows silently — breaking the
-- entire assigned-orders view in TechnicianPortal (useMyAssignedOrders).
-- This policy allows a technician to read only the rows assigned to their own
-- profile, identified via technician_profiles.user_id = auth.uid().
-- Admin and platform-admin access from the migration 008 policy is preserved
-- because Supabase ORs additive policies.

create policy service_order_technicians_self_read
  on public.service_order_technicians
  for select
  to authenticated
  using (
    technician_id = (
      select id from public.technician_profiles
      where user_id = (select auth.uid()) and active
      limit 1
    )
    or app_private.has_membership(company_id, array['admin']::public.member_role[])
    or app_private.is_platform_admin()
  );
