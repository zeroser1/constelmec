-- test_migration_005.sql
-- Run these in Supabase SQL Editor AFTER applying migration 005.
-- Each block is independent. Expected result is noted in the comment above each test.
-- ⚠ Uses SET LOCAL to impersonate roles — works only in Supabase SQL Editor (service role).

-- ═══════════════════════════════════════════════════════════════
-- SETUP: insert a test company (via service role, bypasses RLS)
-- ═══════════════════════════════════════════════════════════════
insert into public.companies (id, name, active)
values ('00000000-0000-0000-0000-000000000001', '_test_empresa', true)
on conflict (id) do update set name = '_test_empresa', active = true;

-- Also insert a membership for a hypothetical test user
-- Replace <test_user_uuid> with any user ID from auth.users
-- insert into public.memberships (company_id, user_id, role, active)
-- values ('00000000-0000-0000-0000-000000000001', '<test_user_uuid>', 'operator', true)
-- on conflict do nothing;


-- ═══════════════════════════════════════════════════════════════
-- GROUP 1: Negative permission tests (RPCs — anon + regular user)
-- ═══════════════════════════════════════════════════════════════

-- TEST 1a: anon cannot call admin_create_company
-- Expected: ERROR 42501 "permission denied"
set local role anon;
select public.admin_create_company('Empresa Test Anon');
reset role;

-- TEST 1b: anon cannot call admin_update_company
-- Expected: ERROR 42501
set local role anon;
select public.admin_update_company('00000000-0000-0000-0000-000000000001', 'Nuevo nombre');
reset role;

-- TEST 1c: anon cannot call admin_set_company_active
-- Expected: ERROR 42501
set local role anon;
select public.admin_set_company_active('00000000-0000-0000-0000-000000000001', false);
reset role;

-- TEST 1d: authenticated non-admin cannot call admin_create_company
-- Expected: ERROR 42501 "global admin role required"
-- (set local role authenticated only works with a real JWT — run via Supabase client
--  or use the Policies Tester in the Supabase dashboard with a non-admin user)


-- ═══════════════════════════════════════════════════════════════
-- GROUP 2: Indirect access tests — inactive company blocks RLS
-- ═══════════════════════════════════════════════════════════════

-- TEST 2a: deactivate the test company (requires platform_admin JWT or service role)
update public.companies set active = false
where id = '00000000-0000-0000-0000-000000000001';

-- TEST 2b: has_membership returns false for inactive company
-- Expected: false
select app_private.has_membership('00000000-0000-0000-0000-000000000001');
-- (runs as current service-role user, uid() = null → returns false for different reason;
--  use Supabase Policies Tester to test with a real member user JWT)

-- TEST 2c: companies_read RLS — non-admin cannot see inactive company
-- Expected: 0 rows when queried as non-admin user via Policies Tester
select id, name, active from public.companies
where id = '00000000-0000-0000-0000-000000000001';
-- (service role bypasses RLS — always returns the row; test via client with member JWT)

-- TEST 2d: memberships_read RLS — non-admin cannot see membership for inactive company
-- Expected: 0 rows when queried as the member user via Policies Tester
-- (requires test membership row from SETUP block; query as the member user via JWT)
-- select * from public.memberships where company_id = '00000000-0000-0000-0000-000000000001';


-- ═══════════════════════════════════════════════════════════════
-- GROUP 3: Validation tests (run as platform_admin user)
-- ═══════════════════════════════════════════════════════════════

-- TEST 3a: short name rejected
-- Expected: ERROR 22023 "at least 2 characters"
select public.admin_create_company('A');

-- TEST 3b: invalid CUIT rejected
-- Expected: ERROR 22023 "invalid CUIT"
select public.admin_create_company('Empresa Válida', null, '12345678901');

-- TEST 3c: valid CUIT accepted (20-05536168-2)
-- Expected: returns a UUID
select public.admin_create_company('Empresa Test CUIT OK', null, '20-05536168-2');

-- TEST 3d: invalid email rejected
-- Expected: ERROR 22023 "invalid email format"
select public.admin_create_company('Empresa Email Test', null, null, null, 'not-an-email');

-- TEST 3e: valid email accepted
-- Expected: returns a UUID
select public.admin_create_company('Empresa Email OK', null, null, null, 'contacto@empresa.com.ar');


-- ═══════════════════════════════════════════════════════════════
-- GROUP 4: Concurrency and null-guard tests
-- ═══════════════════════════════════════════════════════════════

-- TEST 4a: null p_expected_updated_at is explicitly rejected
-- Expected: ERROR 22023 "p_expected_updated_at is required"
select public.admin_update_company(
  '00000000-0000-0000-0000-000000000001',
  'Nombre con null timestamp',
  null, null, null, null, null, null, null,
  null  -- explicitly null — must be rejected
);

-- TEST 4b: update with wrong expected_updated_at is rejected
-- Expected: ERROR P0001 "concurrent edit conflict"
select public.admin_update_company(
  '00000000-0000-0000-0000-000000000001',
  'Nombre actualizado',
  null, null, null, null, null, null, null,
  '2000-01-01 00:00:00+00'  -- deliberately wrong timestamp
);

-- TEST 4c: update with correct expected_updated_at succeeds
-- Expected: no error
-- (get the real updated_at first: select updated_at from companies where id = '...')
-- select public.admin_update_company(
--   '00000000-0000-0000-0000-000000000001',
--   'Nombre actualizado',
--   null, null, null, null, null, null, null,
--   '<actual updated_at from the row>'
-- );


-- ═══════════════════════════════════════════════════════════════
-- GROUP 5: Audit trail check
-- ═══════════════════════════════════════════════════════════════

-- TEST 5a: after creating a company, audit_events has a company_created row
-- Expected: 1 row with event_type = 'company_created', payload contains all fields
select event_type, event_payload
from public.audit_events
where company_id = '00000000-0000-0000-0000-000000000001'
order by id desc limit 5;

-- TEST 5b: after updating, audit has before + after in payload
-- Expected: event_payload->>'before' and event_payload->>'after' both present
select event_type, event_payload->'before', event_payload->'after'
from public.audit_events
where event_type = 'company_updated'
order by id desc limit 1;


-- ═══════════════════════════════════════════════════════════════
-- CLEANUP
-- ═══════════════════════════════════════════════════════���═══════
-- delete from public.companies where id = '00000000-0000-0000-0000-000000000001';
-- (audit_events rows cannot be deleted — that is intentional)
