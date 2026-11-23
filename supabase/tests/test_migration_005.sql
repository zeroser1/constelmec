-- test_migration_005.sql
-- Run in Supabase SQL Editor AFTER applying migration 005.
-- Wraps everything in BEGIN...ROLLBACK — no persistent changes to the database.
-- Uses DO $$ ... $$ blocks with EXCEPTION handlers for expected-failure tests.
--
-- What can be tested from SQL Editor (service role):
--   GROUP 1  — EXECUTE permission revoked for anon
--   GROUP 2  — RLS on deactivated company (data layer)
--   GROUP 3  — Validation logic inside RPCs (via simulated admin session)
--   GROUP 4  — Null guard and optimistic lock rejection
--   GROUP 5  — Audit trail written correctly
--
-- What requires Supabase Policies Tester with real JWTs:
--   • Verify authenticated non-admin gets 42501 from admin_* RPCs
--   • Verify RLS blocks SELECT on memberships/facilities/gates for inactive company
--     when queried as the member user (service role bypasses RLS)
--
-- Expected output: a series of NOTICE lines "TEST Xa PASS: ..."
-- If any RAISE EXCEPTION propagates to the top level, the test fails.

BEGIN;

-- ══════════════════════════════════════════════════════════════════
-- SETUP: synthetic platform admin + test company (all rolled back)
-- ══════════════════════════════════════════════════════════════════

-- Simulate a platform admin JWT by inserting a synthetic user.
-- Service role has access to auth schema.
INSERT INTO auth.users (
  id, email, email_confirmed_at, created_at, updated_at,
  aud, role,
  raw_app_meta_data, raw_user_meta_data, encrypted_password
)
VALUES (
  '00000000-0000-0000-0000-000000000099',
  '_test_admin@constelmec.test',
  now(), now(), now(),
  'authenticated', 'authenticated',
  '{"provider":"email","providers":["email"]}', '{}',
  ''
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO app_private.platform_admins (user_id, granted_by)
VALUES ('00000000-0000-0000-0000-000000000099', 'test_suite')
ON CONFLICT (user_id) DO NOTHING;

-- Synthetic operator member (non-admin) for RLS isolation tests in GROUP 2
INSERT INTO auth.users (
  id, email, email_confirmed_at, created_at, updated_at,
  aud, role, raw_app_meta_data, raw_user_meta_data, encrypted_password
)
VALUES (
  '00000000-0000-0000-0000-000000000098',
  '_test_operator@constelmec.test',
  now(), now(), now(),
  'authenticated', 'authenticated',
  '{"provider":"email","providers":["email"]}', '{}', ''
)
ON CONFLICT (id) DO NOTHING;

-- Make auth.uid() return the synthetic admin UUID for the rest of this transaction.
SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000099","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

-- Create test company via RPC (exercises the full create path including audit).
DO $$
DECLARE v_id uuid;
BEGIN
  SELECT public.admin_create_company(
    '_test_empresa',
    '_Test Empresa S.R.L.',
    null, null, null, null, null, null
  ) INTO v_id;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'SETUP FAIL: admin_create_company returned null';
  END IF;
  RAISE NOTICE 'SETUP: test company created %', v_id;
  -- Store id for subsequent tests via a temp table
  CREATE TEMP TABLE _test_ids (company_id uuid) ON COMMIT DROP;
  INSERT INTO _test_ids VALUES (v_id);
END;
$$;

RESET ROLE;
SET LOCAL "request.jwt.claims" = '';

-- SETUP (service role): insert an operator membership for the inactive-company RLS test
DO $$
DECLARE v_id uuid;
BEGIN
  SELECT company_id INTO v_id FROM _test_ids LIMIT 1;
  INSERT INTO public.memberships (company_id, user_id, role, active)
  VALUES (v_id, '00000000-0000-0000-0000-000000000098'::uuid, 'technician', true)
  ON CONFLICT (user_id, company_id) DO NOTHING;
  RAISE NOTICE 'SETUP: operator member inserted for RLS test';
END;
$$;

-- ══════════════════════════════════════════════════════════════════
-- GROUP 1: EXECUTE permission — anon is blocked before any logic runs
-- ══════════════════════════════════════════════════════════════════

-- TEST 1a: anon cannot call admin_create_company
DO $$
BEGIN
  SET LOCAL ROLE anon;
  PERFORM public.admin_create_company('Anon Test');
  RAISE EXCEPTION 'TEST 1a FAIL: should have raised 42501';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'TEST 1a PASS: anon EXECUTE blocked (42501)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 1a FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 1b: anon cannot call admin_update_company
DO $$
BEGIN
  SET LOCAL ROLE anon;
  PERFORM public.admin_update_company(
    '00000000-0000-0000-0000-000000000001'::uuid, 'X',
    null, null, null, null, null, null, null,
    now()
  );
  RAISE EXCEPTION 'TEST 1b FAIL: should have raised 42501';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'TEST 1b PASS: anon EXECUTE blocked (42501)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 1b FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 1c: anon cannot call admin_set_company_active
DO $$
BEGIN
  SET LOCAL ROLE anon;
  PERFORM public.admin_set_company_active('00000000-0000-0000-0000-000000000001'::uuid, false);
  RAISE EXCEPTION 'TEST 1c FAIL: should have raised 42501';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'TEST 1c PASS: anon EXECUTE blocked (42501)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 1c FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 1d: authenticated non-admin (technician member) cannot call admin_create_company
-- Uses the synthetic non-admin JWT set outside the DO block so SET LOCAL is not subject
-- to the implicit SAVEPOINT rollback inside the exception handler.
SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000098","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

DO $$
BEGIN
  PERFORM public.admin_create_company('Non-admin Test');
  RAISE EXCEPTION 'TEST 1d FAIL: should have raised 42501' USING ERRCODE = 'XX000';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'TEST 1d PASS: non-admin authenticated user blocked (42501)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 1d FAIL: unexpected % — %', SQLSTATE, SQLERRM
      USING ERRCODE = 'XX000';
END;
$$;

RESET ROLE;
SET LOCAL "request.jwt.claims" = '';

-- ══════════════════════════════════════════════════════════════════
-- GROUP 2: Deactivated company blocks RLS
-- ══════════════════════════════════════════════════════════════════
-- TEST 2a:    data-layer check (service role, direct UPDATE)
-- TEST 2b-pre: positive — member sees their row while company is ACTIVE
-- TEST 2b:    has_membership returns false when uid = null
-- TEST 2b+:   RLS enforced for a real authenticated member after deactivation

-- TEST 2b-pre: member can read their own membership while company is ACTIVE.
-- Set JWT outside the DO block so it is not affected by any implicit SAVEPOINT.
SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000098","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_id uuid; v_count int;
BEGIN
  SELECT company_id INTO v_id FROM _test_ids LIMIT 1;
  SELECT COUNT(*) INTO v_count FROM public.memberships WHERE company_id = v_id;
  IF v_count = 0 THEN
    RAISE EXCEPTION 'TEST 2b-pre FAIL: member sees 0 membership rows for ACTIVE company'
      USING ERRCODE = 'XX000';
  END IF;
  RAISE NOTICE 'TEST 2b-pre PASS: member sees % membership row(s) for active company', v_count;
END;
$$;

RESET ROLE;
SET LOCAL "request.jwt.claims" = '';

-- Deactivate the test company
DO $$
DECLARE v_id uuid;
BEGIN
  SELECT company_id INTO v_id FROM _test_ids LIMIT 1;
  -- Use service role (no JWT) for direct update
  UPDATE public.companies SET active = false WHERE id = v_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'TEST 2a FAIL: company not found'; END IF;
  RAISE NOTICE 'TEST 2a PASS: company deactivated (active = false)';
END;
$$;

-- TEST 2b: has_membership returns false for a user on an inactive company
-- (uid() = null in service role context, so this tests the null-uid path;
--  use Policies Tester to verify with an actual member user)
DO $$
DECLARE v_id uuid; v_result boolean;
BEGIN
  SELECT company_id INTO v_id FROM _test_ids LIMIT 1;
  SELECT app_private.has_membership(v_id) INTO v_result;
  IF v_result = false THEN
    RAISE NOTICE 'TEST 2b PASS: has_membership returns false (uid=null, inactive company)';
  ELSE
    RAISE EXCEPTION 'TEST 2b FAIL: has_membership should return false, got %', v_result;
  END IF;
END;
$$;

-- TEST 2b+: RLS blocks an authenticated member from accessing inactive company data.
-- Uses a real non-admin JWT (uid = 00000000-0000-0000-0000-000000000098, operator member).
SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000098","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_id uuid; v_count int;
BEGIN
  SELECT company_id INTO v_id FROM _test_ids LIMIT 1;
  -- memberships_read policy: user_id = auth.uid() AND EXISTS(active company)
  -- → 0 rows when company is inactive
  SELECT COUNT(*) INTO v_count FROM public.memberships WHERE company_id = v_id;
  IF v_count > 0 THEN
    RAISE EXCEPTION 'TEST 2b+ FAIL: member sees % membership rows for inactive company', v_count
      USING ERRCODE = 'XX000';
  END IF;
  RAISE NOTICE 'TEST 2b+ PASS: memberships_read RLS blocks member on inactive company';
  -- companies_read policy: (active AND has_membership(id))
  -- → 0 rows when company is inactive
  SELECT COUNT(*) INTO v_count FROM public.companies WHERE id = v_id;
  IF v_count > 0 THEN
    RAISE EXCEPTION 'TEST 2b+(ii) FAIL: member sees % company rows for inactive company', v_count
      USING ERRCODE = 'XX000';
  END IF;
  RAISE NOTICE 'TEST 2b+(ii) PASS: companies_read RLS blocks member on inactive company';
END;
$$;

RESET ROLE;
SET LOCAL "request.jwt.claims" = '';

-- Reactivate for subsequent groups
DO $$
DECLARE v_id uuid;
BEGIN
  SELECT company_id INTO v_id FROM _test_ids LIMIT 1;
  UPDATE public.companies SET active = true WHERE id = v_id;
  RAISE NOTICE 'SETUP: company reactivated for groups 3-5';
END;
$$;

-- ══════════════════════════════════════════════════════════════════
-- GROUP 3: Validation — name, legal_name, CUIT, email (admin session)
-- ══════════════════════════════════════════════════════════════════

SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000099","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

-- TEST 3a: short name rejected
DO $$
BEGIN
  PERFORM public.admin_create_company('A');
  RAISE EXCEPTION 'TEST 3a FAIL: should have raised 22023';
EXCEPTION
  WHEN SQLSTATE '22023' THEN
    RAISE NOTICE 'TEST 3a PASS: single-char name rejected (22023)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 3a FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 3b: legal_name too short (1 char) rejected
DO $$
BEGIN
  PERFORM public.admin_create_company('Empresa OK', 'X');
  RAISE EXCEPTION 'TEST 3b FAIL: should have raised 22023';
EXCEPTION
  WHEN SQLSTATE '22023' THEN
    RAISE NOTICE 'TEST 3b PASS: single-char legal_name rejected (22023)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 3b FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 3c: invalid CUIT rejected
DO $$
BEGIN
  PERFORM public.admin_create_company('Empresa OK', null, '12345678901');
  RAISE EXCEPTION 'TEST 3c FAIL: should have raised 22023';
EXCEPTION
  WHEN SQLSTATE '22023' THEN
    RAISE NOTICE 'TEST 3c PASS: invalid CUIT rejected (22023)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 3c FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 3d: valid CUIT accepted (20-05536168-2)
DO $$
DECLARE v_id uuid;
BEGIN
  SELECT public.admin_create_company('Empresa CUIT OK', null, '20-05536168-2') INTO v_id;
  IF v_id IS NULL THEN RAISE EXCEPTION 'TEST 3d FAIL: got null'; END IF;
  RAISE NOTICE 'TEST 3d PASS: valid CUIT accepted, new id = %', v_id;
END;
$$;

-- TEST 3e: invalid email rejected
DO $$
BEGIN
  PERFORM public.admin_create_company('Empresa Email Test', null, null, null, 'not-an-email');
  RAISE EXCEPTION 'TEST 3e FAIL: should have raised 22023';
EXCEPTION
  WHEN SQLSTATE '22023' THEN
    RAISE NOTICE 'TEST 3e PASS: invalid email rejected (22023)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 3e FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 3f: valid email accepted
DO $$
DECLARE v_id uuid;
BEGIN
  SELECT public.admin_create_company('Empresa Email OK', null, null, null, 'contacto@empresa.com.ar') INTO v_id;
  IF v_id IS NULL THEN RAISE EXCEPTION 'TEST 3f FAIL: got null'; END IF;
  RAISE NOTICE 'TEST 3f PASS: valid email accepted, new id = %', v_id;
END;
$$;

-- ══════════════════════════════════════════════════════════════════
-- GROUP 4: Concurrency — null guard and timestamp conflict rejection
-- ══════════════════════════════════════════════════════════════════

-- TEST 4a: null p_expected_updated_at explicitly rejected (22023)
DO $$
DECLARE v_id uuid;
BEGIN
  SELECT company_id INTO v_id FROM _test_ids LIMIT 1;
  PERFORM public.admin_update_company(v_id, 'Nombre con null', null, null, null, null, null, null, null, null);
  RAISE EXCEPTION 'TEST 4a FAIL: should have raised 22023';
EXCEPTION
  WHEN SQLSTATE '22023' THEN
    RAISE NOTICE 'TEST 4a PASS: null p_expected_updated_at rejected (22023)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 4a FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 4b: stale timestamp rejected (P0001)
DO $$
DECLARE v_id uuid;
BEGIN
  SELECT company_id INTO v_id FROM _test_ids LIMIT 1;
  PERFORM public.admin_update_company(
    v_id, 'Nombre actualizado',
    null, null, null, null, null, null, null,
    '2000-01-01 00:00:00+00'::timestamptz
  );
  RAISE EXCEPTION 'TEST 4b FAIL: should have raised P0001' USING ERRCODE = 'XX000';
EXCEPTION
  WHEN SQLSTATE 'P0001' THEN
    RAISE NOTICE 'TEST 4b PASS: stale timestamp rejected (P0001 — concurrent edit conflict)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 4b FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 4c: correct timestamp accepted — two successive updates
DO $$
DECLARE v_id uuid; v_ts timestamptz;
BEGIN
  SELECT company_id INTO v_id FROM _test_ids LIMIT 1;
  SELECT updated_at INTO v_ts FROM public.companies WHERE id = v_id;
  -- First update
  PERFORM public.admin_update_company(v_id, 'Nombre v1', null, null, null, null, null, null, null, v_ts);
  RAISE NOTICE 'TEST 4c PASS (first update): timestamp % accepted', v_ts;
  -- Second update — must use the NEW updated_at after trigger fires
  SELECT updated_at INTO v_ts FROM public.companies WHERE id = v_id;
  PERFORM public.admin_update_company(v_id, 'Nombre v2', null, null, null, null, null, null, null, v_ts);
  RAISE NOTICE 'TEST 4c PASS (second update): timestamp % accepted', v_ts;
END;
$$;

-- TEST 4d: stale timestamp after first update is rejected
DO $$
DECLARE v_id uuid; v_ts_before timestamptz; v_ts_after timestamptz;
BEGIN
  SELECT company_id INTO v_id FROM _test_ids LIMIT 1;
  SELECT updated_at INTO v_ts_before FROM public.companies WHERE id = v_id;
  -- Update 1 — advances updated_at
  PERFORM public.admin_update_company(v_id, 'Nombre A', null, null, null, null, null, null, null, v_ts_before);
  -- Update 2 — uses the stale timestamp from before update 1
  PERFORM public.admin_update_company(v_id, 'Nombre B', null, null, null, null, null, null, null, v_ts_before);
  RAISE EXCEPTION 'TEST 4d FAIL: second update with stale ts should have been rejected' USING ERRCODE = 'XX000';
EXCEPTION
  WHEN SQLSTATE 'P0001' THEN
    RAISE NOTICE 'TEST 4d PASS: stale ts rejected after concurrent edit (P0001)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 4d FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- ══════════════════════════════════════════════════════════════════
-- GROUP 5: Audit trail written correctly
-- ══════════════════════════════════════════════════════════════════

-- TEST 5a: company_created event exists with all fields
DO $$
DECLARE v_id uuid; v_count int; v_payload jsonb;
BEGIN
  SELECT company_id INTO v_id FROM _test_ids LIMIT 1;
  SELECT COUNT(*) INTO v_count
  FROM public.audit_events
  WHERE company_id = v_id AND event_type = 'company_created';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'TEST 5a FAIL: no company_created event found';
  END IF;
  SELECT event_payload INTO v_payload
  FROM public.audit_events
  WHERE company_id = v_id AND event_type = 'company_created'
  ORDER BY recorded_at DESC, id DESC LIMIT 1;
  IF v_payload->>'name' IS NULL THEN
    RAISE EXCEPTION 'TEST 5a FAIL: audit payload missing name field';
  END IF;
  RAISE NOTICE 'TEST 5a PASS: company_created event found, name = %', v_payload->>'name';
END;
$$;

-- TEST 5b: company_updated event has before + after
DO $$
DECLARE v_id uuid; v_count int; v_payload jsonb;
BEGIN
  SELECT company_id INTO v_id FROM _test_ids LIMIT 1;
  SELECT COUNT(*) INTO v_count
  FROM public.audit_events
  WHERE company_id = v_id AND event_type = 'company_updated';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'TEST 5b FAIL: no company_updated event found';
  END IF;
  SELECT event_payload INTO v_payload
  FROM public.audit_events
  WHERE company_id = v_id AND event_type = 'company_updated'
  ORDER BY recorded_at DESC, id DESC LIMIT 1;
  IF v_payload->'before' IS NULL OR v_payload->'after' IS NULL THEN
    RAISE EXCEPTION 'TEST 5b FAIL: payload missing before or after: %', v_payload;
  END IF;
  RAISE NOTICE 'TEST 5b PASS: company_updated with before/after audit present';
END;
$$;

-- TEST 5c: audit_events are immutable (trigger blocks all updates)
-- RESET ROLE first: authenticated has UPDATE revoked on audit_events (migration_001),
-- so Postgres would raise 42501 before the trigger fires. Service_role retains
-- the privilege and BEFORE triggers still fire — this correctly tests audit_immutable().
RESET ROLE;

DO $$
DECLARE v_id uuid;
BEGIN
  SELECT company_id INTO v_id FROM _test_ids LIMIT 1;
  UPDATE public.audit_events SET event_type = 'tampered'
  WHERE company_id = v_id;
  RAISE EXCEPTION 'TEST 5c FAIL: update on audit_events should have been blocked' USING ERRCODE = 'XX000';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE '%Audit events are append-only%' THEN
      RAISE NOTICE 'TEST 5c PASS: audit_events blocked update (%)', SQLSTATE;
    ELSE
      RAISE EXCEPTION 'TEST 5c FAIL: got unexpected error % — %', SQLSTATE, SQLERRM
        USING ERRCODE = 'XX000';
    END IF;
END;
$$;

RESET ROLE;

-- ══════════════════════════════════════════════════════════════════
-- ROLLBACK: all test data is discarded — no persistent changes
-- ══════════════════════════════════════════════════════════════════
ROLLBACK;

-- ══════════════════════════════════════════════════════════════════
-- MANUAL TESTS (Policies Tester — require real user JWTs)
-- ══════════════════════════════════════════════════════════════════
-- Run these in Supabase Dashboard > Authentication > Policies Tester.
--
-- A. Authenticated non-admin calls admin_create_company
--    → Expected: 42501 "global admin role required"
--
-- B. Member user of an ACTIVE company queries memberships
--    → Expected: returns their own row
--
-- C. Same member user after company is deactivated queries memberships
--    → Expected: 0 rows (memberships_read policy blocks access)
--
-- D. Same member user queries facilities after deactivation
--    → Expected: 0 rows (has_membership now checks active)
--
-- E. Same member user queries gates after deactivation
--    → Expected: 0 rows
