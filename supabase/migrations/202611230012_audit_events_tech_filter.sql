-- Migration 012: restrict audit_events access for technicians.
--
-- Context (GAP-SEC-01, Alta prioridad):
--   The existing audit_read policy (from mig_001) allows technicians to read
--   all audit_events for their company, including event_payload which contains
--   before/after snapshots with PII (contact names, emails, technician data, etc.)
--   Filtering by event_type is insufficient: operational events (order_updated,
--   order_technician_assigned) can also carry PII in event_payload if the trigger
--   that generated them included full row snapshots.
--
-- Fix:
--   Replace audit_read policy: remove technician access entirely.
--   Only admins and platform admins can query audit_events directly.
--
--   No RPC is added.  The technician portal does not currently display audit
--   history.  If a future operational requirement emerges, the RPC should be
--   scoped to the technician's own assigned orders (not company-wide) and must
--   not expose actor_user_id of other users.
--
-- NOT safe to apply to production until ChatGPT gives explicit approval for the
-- full 011–015 set.

-- ══════════════════════════════════════════════════════════════════════════════
-- 1. Replace audit_read policy: remove technician access
-- ══════════════════════════════════════════════════════════════════════════════
-- Drop existing policy and recreate with admins and platform_admins only.
-- Technicians are explicitly excluded; they had access via the mig_001 policy
-- which included 'technician' in the has_membership() call.

drop policy if exists audit_read on public.audit_events;

create policy audit_read
  on public.audit_events
  for select
  to authenticated
  using (
    app_private.is_platform_admin()
    or app_private.has_membership(company_id, array['admin']::public.member_role[])
    -- Technicians: removed.  Direct audit_events access denied.
  );

-- ══════════════════════════════════════════════════════════════════════════════
-- Required regression tests (run in staging, not production):
-- ══════════════════════════════════════════════════════════════════════════════
--   1. Tech A: SELECT * FROM audit_events WHERE company_id = A → 0 rows (RLS)
--   2. Tech A: SELECT * FROM audit_events WHERE event_type = 'order_created' → 0 rows
--   3. Admin A: SELECT * FROM audit_events WHERE company_id = A → full rows with payload
--   4. Platform admin: SELECT * FROM audit_events → rows from all companies
