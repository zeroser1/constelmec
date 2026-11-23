-- Migration 014: move service_orders.notes to a protected table.
--
-- Context (GAP-SEC-03, Media prioridad):
--   service_orders.notes is currently visible to all company members (admin,
--   technician, customer) via the service_orders_member_read policy from mig_010.
--   TechnicianPortal.tsx currently renders notes — this is a design gap.
--
-- Root cause of previous failed approach (view + dual policy):
--   Two permissive policies on the same table (admin-read + member-read) are
--   OR-combined by PostgreSQL.  Any policy that grants technician/customer access
--   to service_orders also grants access to ALL columns including notes.
--   A security_invoker view cannot hide notes from a technician that has a
--   permissive base-table policy.  Column-level filtering requires column-level
--   grants or a separate table.
--
-- Fix: separate table for internal notes.
--   1. Create service_order_internal_notes — admin + platform_admin read only.
--   2. Backfill existing notes from service_orders where notes IS NOT NULL.
--   3. Clear service_orders.notes (set to NULL) so the existing tech portal
--      query returns no note content.
--   4. Write access via admin_set_service_order_note() RPC only.
--
-- TypeScript changes required (separate deploy):
--   - Admin hooks: add query to service_order_internal_notes for the notes field
--   - Admin UI: render notes from service_order_internal_notes, not service_orders
--   - TechnicianPortal.tsx: remove {o.notes && ...} render (no longer populated)
--   - Admin: add admin_set_service_order_note() call when creating/editing orders
--
-- NOT safe to apply to production until ChatGPT gives explicit approval for the
-- full 011–015 set AND TypeScript hooks are updated.

-- ══════════════════════════════════════════════════════════════════════════════
-- 1. New table: service_order_internal_notes
-- ══════════════════════════════════════════════════════════════════════════════

create table public.service_order_internal_notes (
  id               uuid primary key default gen_random_uuid(),
  service_order_id uuid not null references public.service_orders(id),
  company_id       uuid not null references public.companies(id),
  content          text not null check(length(trim(content)) between 1 and 5000),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create index on public.service_order_internal_notes(service_order_id);
create index on public.service_order_internal_notes(company_id);

create trigger set_updated_at
  before update on public.service_order_internal_notes
  for each row
  execute function app_private.set_updated_at();

alter table public.service_order_internal_notes enable row level security;

revoke insert, update, delete on public.service_order_internal_notes from anon, authenticated;
grant select on public.service_order_internal_notes to authenticated;

-- ══════════════════════════════════════════════════════════════════════════════
-- 2. RLS: admin and platform_admin read only
-- ══════════════════════════════════════════════════════════════════════════════

create policy soin_admin_read
  on public.service_order_internal_notes
  for select
  to authenticated
  using (
    app_private.is_platform_admin()
    or app_private.has_membership(company_id, array['admin']::public.member_role[])
  );

-- ══════════════════════════════════════════════════════════════════════════════
-- 3. Unique constraint — must exist before the RPC that uses ON CONFLICT
-- ══════════════════════════════════════════════════════════════════════════════
-- One note per service order. Defined here (before the function) so the
-- constraint exists at function definition time, not just at call time.

alter table public.service_order_internal_notes
  add constraint soin_one_per_order unique(service_order_id);

-- ══════════════════════════════════════════════════════════════════════════════
-- 4. Write RPC: admin_set_service_order_note
-- ══════════════════════════════════════════════════════════════════════════════
-- Upserts (insert-or-update) the internal note for a service order.
-- Only one note row per service order is maintained (upsert by service_order_id).
-- Pass p_content = NULL or empty string to remove the note.

create or replace function public.admin_set_service_order_note(
  p_company_id      uuid,
  p_service_order_id uuid,
  p_content         text
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not (app_private.is_platform_admin()
          or app_private.has_membership(p_company_id, array['admin']::public.member_role[])) then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.service_orders
    where id = p_service_order_id and company_id = p_company_id
  ) then
    raise exception 'service order not found in company' using errcode = 'P0002';
  end if;

  if p_content is null or trim(p_content) = '' then
    -- Remove note
    delete from public.service_order_internal_notes
    where service_order_id = p_service_order_id and company_id = p_company_id;
  else
    insert into public.service_order_internal_notes (service_order_id, company_id, content)
    values (p_service_order_id, p_company_id, trim(p_content))
    on conflict (service_order_id) do update set content = excluded.content, company_id = excluded.company_id;
  end if;
end;
$$;

revoke execute on function public.admin_set_service_order_note(uuid, uuid, text) from public, anon;
grant  execute on function public.admin_set_service_order_note(uuid, uuid, text) to authenticated;

-- ══════════════════════════════════════════════════════════════════════════════
-- 5. Backfill existing notes from service_orders
-- ══════════════════════════════════════════════════════════════════════════════

insert into public.service_order_internal_notes (service_order_id, company_id, content)
select id, company_id, notes
from public.service_orders
where notes is not null and trim(notes) <> '';

-- ══════════════════════════════════════════════════════════════════════════════
-- 6. Clear notes column in service_orders
-- ══════════════════════════════════════════════════════════════════════════════
-- Column stays (nullable) but is empty.  Existing tech portal query (.select
-- '...notes,...') returns null for all rows — TechnicianPortal renders nothing.
-- Column can be dropped in a future migration once hooks are updated.

update public.service_orders set notes = null where notes is not null;

-- ══════════════════════════════════════════════════════════════════════════════
-- Required regression tests (run in staging, not production):
-- ══════════════════════════════════════════════════════════════════════════════
--   1. Admin A: SELECT * FROM service_order_internal_notes WHERE company_id = A
--      → rows with content (backfilled from service_orders.notes)
--   2. Tech A: SELECT * FROM service_order_internal_notes WHERE company_id = A
--      → 0 rows (admin-only policy)
--   3. Tech A: SELECT notes FROM service_orders WHERE company_id = A
--      → all rows with notes = NULL (column cleared)
--   4. Admin A calls admin_set_service_order_note(A, order_A_id, 'Note text')
--      → upserts a row in service_order_internal_notes
--   5. Admin B calls admin_set_service_order_note(A, order_A_id, 'Evil')
--      → 42501 (cross-company denied)
