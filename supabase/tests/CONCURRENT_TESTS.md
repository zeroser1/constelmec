# Concurrent test runbook — Constelmec

Manual procedure to verify race conditions that sequential tests cannot catch.
Requires a running Supabase local stack (`supabase start` + `supabase db reset`).
All sessions use the local DB on port 54322.

---

## Prerequisites

```bash
# Start local stack and apply all migrations
supabase start
supabase db reset

# Verify the stack is healthy
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -c "SELECT version();"
```

You need **two separate terminal windows** open simultaneously.
Each terminal runs `psql postgresql://postgres:postgres@127.0.0.1:54322/postgres`.

---

## Setup: insert the test fixture

Run this ONCE in either terminal before the concurrent tests (not inside a BEGIN block —
the fixture rows must persist across separate sessions).

```sql
-- Platform admin user
INSERT INTO auth.users (
  id, email, email_confirmed_at, created_at, updated_at,
  aud, role, raw_app_meta_data, raw_user_meta_data, encrypted_password
) VALUES (
  'cccc0000-0000-0000-0000-000000000001',
  '_conc_admin@constelmec.test',
  now(), now(), now(),
  'authenticated', 'authenticated',
  '{"provider":"email","providers":["email"]}', '{}', ''
) ON CONFLICT (id) DO NOTHING;

INSERT INTO app_private.platform_admins (user_id, granted_by)
VALUES ('cccc0000-0000-0000-0000-000000000001', 'concurrent_runbook')
ON CONFLICT (user_id) DO NOTHING;

-- Test company
INSERT INTO public.companies (id, name) VALUES
  ('cccc0000-0000-0000-0000-000000000010', '_ConcTestCo')
ON CONFLICT (id) DO NOTHING;

-- Three technicians in the test company
INSERT INTO public.technician_profiles (id, company_id, first_name, last_name, active) VALUES
  ('cccc0000-0000-0000-0000-000000000020', 'cccc0000-0000-0000-0000-000000000010', 'Lead', 'Alpha', true),
  ('cccc0000-0000-0000-0000-000000000021', 'cccc0000-0000-0000-0000-000000000010', 'Lead', 'Beta',  true),
  ('cccc0000-0000-0000-0000-000000000022', 'cccc0000-0000-0000-0000-000000000010', 'Support', 'Gamma', true)
ON CONFLICT (id) DO NOTHING;

-- Enable each tech for the test company
INSERT INTO public.technician_company_assignments (technician_id, company_id, active) VALUES
  ('cccc0000-0000-0000-0000-000000000020', 'cccc0000-0000-0000-0000-000000000010', true),
  ('cccc0000-0000-0000-0000-000000000021', 'cccc0000-0000-0000-0000-000000000010', true),
  ('cccc0000-0000-0000-0000-000000000022', 'cccc0000-0000-0000-0000-000000000010', true)
ON CONFLICT (technician_id, company_id) DO NOTHING;

-- A service order in the test company
INSERT INTO public.service_orders (
  id, company_id, service_type, status, scheduled_start, scheduled_end
) VALUES (
  'cccc0000-0000-0000-0000-000000000030',
  'cccc0000-0000-0000-0000-000000000010',
  'preventive', 'scheduled',
  now() + interval '1 day',
  now() + interval '1 day' + interval '2 hours'
) ON CONFLICT (id) DO NOTHING;
```

---

## Test A — Two simultaneous lead assignments on the same order

**Scenario:** Two admin sessions both try to assign a *lead* technician to the same order at
exactly the same time. The unique partial index `(service_order_id) WHERE role='lead' AND active`
(migration 009) must ensure exactly one succeeds and the other gets a P0001 error.

**Expected outcome:** One session commits, the other receives
`"this order already has an active lead technician; remove the existing lead first"`.

### Session 1 (Terminal A)

```sql
BEGIN;

-- Acquire the row lock on the technician_company_assignment row
-- (mimics what admin_assign_order_technician does internally)
SELECT id FROM public.technician_company_assignments
WHERE technician_id = 'cccc0000-0000-0000-0000-000000000020'
  AND company_id    = 'cccc0000-0000-0000-0000-000000000010'
  AND active
FOR UPDATE;

-- *** PAUSE HERE — do NOT commit yet. Switch to Session 2 and run its BEGIN + SELECT FOR UPDATE ***
```

### Session 2 (Terminal B)

```sql
BEGIN;

-- This will BLOCK waiting for Session 1 to release the lock
SELECT id FROM public.technician_company_assignments
WHERE technician_id = 'cccc0000-0000-0000-0000-000000000021'
  AND company_id    = 'cccc0000-0000-0000-0000-000000000010'
  AND active
FOR UPDATE;

-- Once Session 1 commits, Session 2 continues here.
-- *** PAUSE HERE after Session 1 runs its INSERT below ***
```

### Session 1 — insert lead assignment

```sql
INSERT INTO public.service_order_technicians
  (service_order_id, technician_id, company_id, role)
VALUES (
  'cccc0000-0000-0000-0000-000000000030',
  'cccc0000-0000-0000-0000-000000000020',
  'cccc0000-0000-0000-0000-000000000010',
  'lead'
);

COMMIT;
-- ✓ Should succeed. Switch back to Session 2 and run its INSERT.
```

### Session 2 — attempt second lead assignment (should fail)

```sql
INSERT INTO public.service_order_technicians
  (service_order_id, technician_id, company_id, role)
VALUES (
  'cccc0000-0000-0000-0000-000000000030',
  'cccc0000-0000-0000-0000-000000000021',
  'cccc0000-0000-0000-0000-000000000010',
  'lead'
);
-- Expected: ERROR on unique index violation (23505) — "duplicate key value violates
-- unique constraint" on (service_order_id) WHERE role='lead' AND active.
-- The RPC layer converts this to a P0001 "already has an active lead" message.

ROLLBACK;
```

### Verification

```sql
-- Should show exactly 1 active lead assignment
SELECT role, active, technician_id
FROM public.service_order_technicians
WHERE service_order_id = 'cccc0000-0000-0000-0000-000000000030'
  AND active = true;

-- Expected: 1 row with role='lead'
```

---

## Test B — Disable technician while assignment is being made

**Scenario:** Session 1 is mid-way through assigning a technician to an order.
Session 2 simultaneously tries to disable that technician for the company.
The row lock in `admin_set_technician_company` / `admin_assign_order_technician`
(both lock `technician_company_assignments`) must serialize the two operations.

**Expected outcome:**  
- If Session 1 commits first: Session 2 sees `active=true`, proceeds with cascade-disable,
  and soft-removes the new assignment (since the order is `scheduled`, not `in_progress`).  
- If Session 2 commits first: Session 1's `SELECT … FOR UPDATE` sees `active=false` and
  raises `"technician is not enabled for this company"`.

### Session 1 (Terminal A)

```sql
BEGIN;

-- Lock the company assignment row (same first step as admin_assign_order_technician)
SELECT id FROM public.technician_company_assignments
WHERE technician_id = 'cccc0000-0000-0000-0000-000000000022'
  AND company_id    = 'cccc0000-0000-0000-0000-000000000010'
  AND active
FOR UPDATE;

-- *** PAUSE — switch to Session 2 ***
```

### Session 2 (Terminal B)

```sql
BEGIN;

-- This will BLOCK on the same row Session 1 is holding
SELECT id FROM public.technician_company_assignments
WHERE technician_id = 'cccc0000-0000-0000-0000-000000000022'
  AND company_id    = 'cccc0000-0000-0000-0000-000000000010'
FOR UPDATE;

-- *** PAUSE — switch back to Session 1 to commit the assignment ***
```

### Session 1 — complete the assignment

```sql
INSERT INTO public.service_order_technicians
  (service_order_id, technician_id, company_id, role)
VALUES (
  'cccc0000-0000-0000-0000-000000000030',
  'cccc0000-0000-0000-0000-000000000022',
  'cccc0000-0000-0000-0000-000000000010',
  'support'
);

COMMIT;
-- ✓ Switch back to Session 2 — it unblocks now.
```

### Session 2 — disable the technician (cascade should soft-remove the assignment)

```sql
-- Session 2 is now unblocked and re-reads active=true
-- Proceed with the disable cascade:
UPDATE public.service_order_technicians sot
  SET active     = false,
      removed_at = now(),
      removed_by = 'cccc0000-0000-0000-0000-000000000001'
FROM public.service_orders so
WHERE sot.service_order_id = so.id
  AND sot.technician_id    = 'cccc0000-0000-0000-0000-000000000022'
  AND sot.company_id       = 'cccc0000-0000-0000-0000-000000000010'
  AND sot.active           = true
  AND so.status NOT IN ('in_progress', 'completed', 'cancelled');

UPDATE public.technician_company_assignments
  SET active = false
WHERE technician_id = 'cccc0000-0000-0000-0000-000000000022'
  AND company_id    = 'cccc0000-0000-0000-0000-000000000010';

COMMIT;
-- ✓ Should succeed.
```

### Verification

```sql
-- Assignment from Session 1 must now be soft-deleted
SELECT active, removed_at
FROM public.service_order_technicians
WHERE service_order_id = 'cccc0000-0000-0000-0000-000000000030'
  AND technician_id    = 'cccc0000-0000-0000-0000-000000000022';

-- Expected: active=false, removed_at IS NOT NULL

-- Tech must be disabled for the company
SELECT active
FROM public.technician_company_assignments
WHERE technician_id = 'cccc0000-0000-0000-0000-000000000022'
  AND company_id    = 'cccc0000-0000-0000-0000-000000000010';

-- Expected: active=false
```

---

## Teardown

After all concurrent tests, clean up the fixture data:

```sql
DELETE FROM public.service_order_technicians
  WHERE company_id = 'cccc0000-0000-0000-0000-000000000010';
DELETE FROM public.technician_company_assignments
  WHERE company_id = 'cccc0000-0000-0000-0000-000000000010';
DELETE FROM public.service_orders
  WHERE company_id = 'cccc0000-0000-0000-0000-000000000010';
DELETE FROM public.technician_profiles
  WHERE company_id = 'cccc0000-0000-0000-0000-000000000010';
DELETE FROM public.companies WHERE id = 'cccc0000-0000-0000-0000-000000000010';
DELETE FROM app_private.platform_admins
  WHERE user_id = 'cccc0000-0000-0000-0000-000000000001';
DELETE FROM auth.users WHERE id = 'cccc0000-0000-0000-0000-000000000001';
```

Or simply restart the local stack:

```bash
supabase stop --no-backup && supabase start && supabase db reset
```

---

## Notes

- These tests require **manual coordination** between two terminal windows.
  They cannot be fully automated in a single-session CI script.
- The concurrent safety net in migration 009 is the partial unique index on
  `(service_order_id) WHERE role='lead' AND active`. It fires even if the application
  guard in `admin_assign_order_technician` is bypassed.
- Test A validates the index. Test B validates the lock ordering that prevents deadlocks.
- Both tests assume the `scheduled` order status (not `in_progress`), so the cascade
  in Test B performs a soft-delete rather than raising an exception.
