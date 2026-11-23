-- test_migration_008.sql
-- Run in Supabase SQL Editor AFTER applying migrations 007 + 008.
-- Wraps everything in BEGIN...ROLLBACK — no persistent changes.
-- Uses DO $$ ... $$ blocks with EXCEPTION handlers for expected-failure tests.
--
-- Expected output: a series of NOTICE lines "TEST Xa PASS: ..."
-- If any RAISE EXCEPTION propagates to the top level, the test fails.
--
-- Depends on migrations 005 + 006 + 007 (platform_admins, facilities, is_platform_admin).

BEGIN;

-- ══════════════════════════════════════════════════════════════════
-- SETUP: synthetic platform admin + company + facility + technician + order
-- ══════════════════════════════════════════════════════════════════

INSERT INTO auth.users (
  id, email, email_confirmed_at, created_at, updated_at,
  aud, role, raw_app_meta_data, raw_user_meta_data, encrypted_password
) VALUES (
  '00000000-0000-0000-0000-000000000099',
  '_test_admin@constelmec.test',
  now(), now(), now(),
  'authenticated', 'authenticated',
  '{"provider":"email","providers":["email"]}', '{}', ''
) ON CONFLICT (id) DO NOTHING;

INSERT INTO app_private.platform_admins (user_id, granted_by)
VALUES ('00000000-0000-0000-0000-000000000099', 'test_suite_008')
ON CONFLICT (user_id) DO NOTHING;

SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000099","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

-- Create company, facility, gate via RPCs (write access via authenticated role + admin JWT)
DO $$
DECLARE
  v_company_id       uuid;
  v_other_company_id uuid;
  v_facility_id      uuid;
  v_gate_id          uuid;
BEGIN
  SELECT public.admin_create_company('_test_co_008') INTO v_company_id;
  SELECT public.admin_create_facility(v_company_id, 'Planta 008') INTO v_facility_id;
  SELECT public.admin_create_gate(v_company_id, v_facility_id, 'P-01', 'Test gate 008') INTO v_gate_id;
  SELECT public.admin_create_company('_test_other_co_008') INTO v_other_company_id;
  CREATE TEMP TABLE _t008_ids (
    company_id       uuid,
    other_company_id uuid,
    facility_id      uuid,
    gate_id          uuid
  ) ON COMMIT DROP;
  INSERT INTO _t008_ids VALUES (v_company_id, v_other_company_id, v_facility_id, v_gate_id);
  RAISE NOTICE 'SETUP (RPCs): company %, facility %, gate %', v_company_id, v_facility_id, v_gate_id;
END;
$$;

RESET ROLE;

-- Direct INSERTs as superuser (INSERT is revoked from authenticated on these tables)
DO $$
DECLARE
  v_company_id    uuid;
  v_facility_id   uuid;
  v_gate_id       uuid;
  v_technician_id uuid;
  v_order_id      uuid;
BEGIN
  SELECT company_id, facility_id, gate_id INTO v_company_id, v_facility_id, v_gate_id
  FROM _t008_ids LIMIT 1;

  INSERT INTO public.technician_profiles
    (company_id, first_name, last_name, active)
  VALUES (v_company_id, 'Luis', 'Rodríguez', true)
  RETURNING id INTO v_technician_id;

  INSERT INTO public.service_orders
    (company_id, facility_id, gate_id, service_type, status, scheduled_start, scheduled_end)
  VALUES (
    v_company_id, v_facility_id, v_gate_id,
    'preventive', 'scheduled',
    now() + interval '1 day', now() + interval '1 day 2 hours'
  )
  RETURNING id INTO v_order_id;

  CREATE TEMP TABLE _t008 (
    company_id       uuid,
    other_company_id uuid,
    facility_id      uuid,
    technician_id    uuid,
    order_id         uuid
  ) ON COMMIT DROP;
  INSERT INTO _t008
  SELECT i.company_id, i.other_company_id, i.facility_id, v_technician_id, v_order_id
  FROM _t008_ids i;
  RAISE NOTICE 'SETUP (direct): technician %, order %', v_technician_id, v_order_id;
END;
$$;

RESET ROLE;
SET LOCAL "request.jwt.claims" = '';

-- ══════════════════════════════════════════════════════════════════
-- GROUP 1: EXECUTE permission — anon is blocked
-- ══════════════════════════════════════════════════════════════════

DO $$
BEGIN
  SET LOCAL ROLE anon;
  PERFORM public.admin_set_technician_company(
    '00000000-0000-0000-0000-000000000001'::uuid,
    '00000000-0000-0000-0000-000000000002'::uuid,
    true
  );
  RAISE EXCEPTION 'TEST 1a FAIL: should have raised 42501';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'TEST 1a PASS: anon EXECUTE blocked on set_technician_company (42501)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 1a FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

DO $$
BEGIN
  SET LOCAL ROLE anon;
  PERFORM public.admin_set_technician_facility(
    '00000000-0000-0000-0000-000000000001'::uuid,
    '00000000-0000-0000-0000-000000000002'::uuid,
    '00000000-0000-0000-0000-000000000003'::uuid,
    true
  );
  RAISE EXCEPTION 'TEST 1b FAIL: should have raised 42501';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'TEST 1b PASS: anon EXECUTE blocked on set_technician_facility (42501)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 1b FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

DO $$
BEGIN
  SET LOCAL ROLE anon;
  PERFORM public.admin_assign_order_technician(
    '00000000-0000-0000-0000-000000000001'::uuid,
    '00000000-0000-0000-0000-000000000002'::uuid,
    '00000000-0000-0000-0000-000000000003'::uuid
  );
  RAISE EXCEPTION 'TEST 1c FAIL: should have raised 42501';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'TEST 1c PASS: anon EXECUTE blocked on assign_order_technician (42501)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 1c FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

DO $$
BEGIN
  SET LOCAL ROLE anon;
  PERFORM public.admin_remove_order_technician(
    '00000000-0000-0000-0000-000000000001'::uuid,
    '00000000-0000-0000-0000-000000000002'::uuid,
    '00000000-0000-0000-0000-000000000003'::uuid
  );
  RAISE EXCEPTION 'TEST 1d FAIL: should have raised 42501';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'TEST 1d PASS: anon EXECUTE blocked on remove_order_technician (42501)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 1d FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- ══════════════════════════════════════════════════════════════════
-- GROUP 2: Company assignment lifecycle
-- ══════════════════════════════════════════════════════════════════

SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000099","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

-- TEST 2a: enable technician for company — row created, audit event
DO $$
DECLARE v_company_id uuid; v_technician_id uuid; v_count int; v_active boolean;
BEGIN
  SELECT company_id, technician_id INTO v_company_id, v_technician_id FROM _t008 LIMIT 1;
  PERFORM public.admin_set_technician_company(v_company_id, v_technician_id, true);
  SELECT active INTO v_active
  FROM public.technician_company_assignments
  WHERE technician_id = v_technician_id AND company_id = v_company_id;
  IF NOT v_active THEN
    RAISE EXCEPTION 'TEST 2a FAIL: assignment not active after enable';
  END IF;
  SELECT COUNT(*) INTO v_count
  FROM public.audit_events
  WHERE company_id = v_company_id AND event_type = 'technician_company_enabled';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'TEST 2a FAIL: no technician_company_enabled audit event';
  END IF;
  RAISE NOTICE 'TEST 2a PASS: technician enabled for company, audit present';
END;
$$;

-- TEST 2b: disable technician — row updated, facility assignments also deactivated
DO $$
DECLARE v_company_id uuid; v_facility_id uuid; v_technician_id uuid;
        v_active boolean; v_count int;
BEGIN
  SELECT company_id, facility_id, technician_id
  INTO v_company_id, v_facility_id, v_technician_id FROM _t008 LIMIT 1;
  -- First assign a facility so we can verify cascade-disable
  PERFORM public.admin_set_technician_facility(v_company_id, v_technician_id, v_facility_id, true);
  -- Now disable company assignment
  PERFORM public.admin_set_technician_company(v_company_id, v_technician_id, false);
  -- Company assignment is inactive
  SELECT active INTO v_active
  FROM public.technician_company_assignments
  WHERE technician_id = v_technician_id AND company_id = v_company_id;
  IF v_active THEN
    RAISE EXCEPTION 'TEST 2b FAIL: company assignment still active after disable';
  END IF;
  -- Facility assignment also deactivated
  SELECT COUNT(*) INTO v_count
  FROM public.technician_facility_assignments
  WHERE technician_id = v_technician_id AND company_id = v_company_id AND active = true;
  IF v_count > 0 THEN
    RAISE EXCEPTION 'TEST 2b FAIL: facility assignments not deactivated when company disabled';
  END IF;
  RAISE NOTICE 'TEST 2b PASS: company disable cascades to facility assignments';
END;
$$;

-- Re-enable technician for subsequent tests
DO $$
DECLARE v_company_id uuid; v_technician_id uuid;
BEGIN
  SELECT company_id, technician_id INTO v_company_id, v_technician_id FROM _t008 LIMIT 1;
  PERFORM public.admin_set_technician_company(v_company_id, v_technician_id, true);
END;
$$;

-- ══════════════════════════════════════════════════════════════════
-- GROUP 3: Facility assignment
-- ══════════════════════════════════════════════════════════════════

-- TEST 3a: assign facility — row created, audit event
DO $$
DECLARE v_company_id uuid; v_facility_id uuid; v_technician_id uuid;
        v_active boolean; v_count int;
BEGIN
  SELECT company_id, facility_id, technician_id
  INTO v_company_id, v_facility_id, v_technician_id FROM _t008 LIMIT 1;
  PERFORM public.admin_set_technician_facility(v_company_id, v_technician_id, v_facility_id, true);
  SELECT active INTO v_active
  FROM public.technician_facility_assignments
  WHERE technician_id = v_technician_id AND facility_id = v_facility_id;
  IF NOT v_active THEN
    RAISE EXCEPTION 'TEST 3a FAIL: facility assignment not active';
  END IF;
  SELECT COUNT(*) INTO v_count
  FROM public.audit_events
  WHERE company_id = v_company_id AND event_type = 'technician_facility_assigned';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'TEST 3a FAIL: no technician_facility_assigned audit event';
  END IF;
  RAISE NOTICE 'TEST 3a PASS: facility assignment created, audit present';
END;
$$;

-- TEST 3b: facility from another company rejected (P0002)
DO $$
DECLARE v_company_id uuid; v_other_company_id uuid; v_technician_id uuid; v_other_facility_id uuid;
BEGIN
  SELECT company_id, other_company_id, technician_id
  INTO v_company_id, v_other_company_id, v_technician_id FROM _t008 LIMIT 1;
  SELECT public.admin_create_facility(v_other_company_id, 'Other facility 008') INTO v_other_facility_id;
  PERFORM public.admin_set_technician_facility(v_company_id, v_technician_id, v_other_facility_id, true);
  RAISE EXCEPTION 'TEST 3b FAIL: should have raised P0002';
EXCEPTION
  WHEN SQLSTATE 'P0002' THEN
    RAISE NOTICE 'TEST 3b PASS: cross-company facility rejected (P0002)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 3b FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 3c: disabled technician cannot get facility assigned (P0002)
DO $$
DECLARE v_company_id uuid; v_facility_id uuid; v_technician_id uuid;
BEGIN
  SELECT company_id, facility_id, technician_id
  INTO v_company_id, v_facility_id, v_technician_id FROM _t008 LIMIT 1;
  -- Disable first
  PERFORM public.admin_set_technician_company(v_company_id, v_technician_id, false);
  PERFORM public.admin_set_technician_facility(v_company_id, v_technician_id, v_facility_id, true);
  RAISE EXCEPTION 'TEST 3c FAIL: should have raised P0002';
EXCEPTION
  WHEN SQLSTATE 'P0002' THEN
    RAISE NOTICE 'TEST 3c PASS: disabled technician rejects facility assignment (P0002)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 3c FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- Re-enable technician
DO $$
DECLARE v_company_id uuid; v_technician_id uuid;
BEGIN
  SELECT company_id, technician_id INTO v_company_id, v_technician_id FROM _t008 LIMIT 1;
  PERFORM public.admin_set_technician_company(v_company_id, v_technician_id, true);
END;
$$;

-- ══════════════════════════════════════════════════════════════════
-- GROUP 4: Order technician assignment
-- ══════════════════════════════════════════════════════════════════

-- TEST 4a: assign technician as lead — returns UUID, audit event, one lead only
DO $$
DECLARE v_company_id uuid; v_technician_id uuid; v_order_id uuid;
        v_assignment_id uuid; v_count int; v_role text;
BEGIN
  SELECT company_id, technician_id, order_id
  INTO v_company_id, v_technician_id, v_order_id FROM _t008 LIMIT 1;
  IF v_order_id IS NULL THEN
    RAISE NOTICE 'TEST 4a SKIP: no service order available (no gates in test db)';
    RETURN;
  END IF;
  SELECT public.admin_assign_order_technician(
    v_company_id, v_order_id, v_technician_id, 'lead'::public.order_technician_role
  ) INTO v_assignment_id;
  IF v_assignment_id IS NULL THEN
    RAISE EXCEPTION 'TEST 4a FAIL: assign returned null';
  END IF;
  SELECT role INTO v_role FROM public.service_order_technicians WHERE id = v_assignment_id;
  IF v_role <> 'lead' THEN
    RAISE EXCEPTION 'TEST 4a FAIL: expected role=lead, got %', v_role;
  END IF;
  SELECT COUNT(*) INTO v_count
  FROM public.audit_events
  WHERE company_id = v_company_id AND event_type = 'order_technician_assigned';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'TEST 4a FAIL: no order_technician_assigned audit event';
  END IF;
  RAISE NOTICE 'TEST 4a PASS: lead assigned %, audit present', v_assignment_id;
END;
$$;

-- TEST 4b: second lead rejected (P0001) if order has one
DO $$
DECLARE v_company_id uuid; v_technician_id uuid; v_order_id uuid;
        v_technician2_id uuid;
BEGIN
  SELECT company_id, order_id INTO v_company_id, v_order_id FROM _t008 LIMIT 1;
  IF v_order_id IS NULL THEN
    RAISE NOTICE 'TEST 4b SKIP: no service order available';
    RETURN;
  END IF;
  -- Only run if 4a already assigned a lead
  IF NOT EXISTS (
    SELECT 1 FROM public.service_order_technicians
    WHERE service_order_id = v_order_id AND role = 'lead'
  ) THEN
    RAISE NOTICE 'TEST 4b SKIP: 4a did not run, no lead to conflict with';
    RETURN;
  END IF;
  -- Create a second technician for this test
  INSERT INTO public.technician_profiles (company_id, first_name, last_name)
  SELECT v_company_id, 'Ana', 'Martínez'
  RETURNING id INTO v_technician2_id;
  PERFORM public.admin_set_technician_company(v_company_id, v_technician2_id, true);
  PERFORM public.admin_assign_order_technician(
    v_company_id, v_order_id, v_technician2_id, 'lead'::public.order_technician_role
  );
  RAISE EXCEPTION 'TEST 4b FAIL: should have raised P0001 (duplicate lead)' USING ERRCODE = 'XX000';
EXCEPTION
  WHEN SQLSTATE 'P0001' THEN
    RAISE NOTICE 'TEST 4b PASS: second lead rejected (P0001)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 4b FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 4c: remove assignment — row deleted, audit event
DO $$
DECLARE v_company_id uuid; v_technician_id uuid; v_order_id uuid; v_count int;
BEGIN
  SELECT company_id, technician_id, order_id
  INTO v_company_id, v_technician_id, v_order_id FROM _t008 LIMIT 1;
  IF v_order_id IS NULL THEN
    RAISE NOTICE 'TEST 4c SKIP: no service order available';
    RETURN;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.service_order_technicians
    WHERE service_order_id = v_order_id AND technician_id = v_technician_id
  ) THEN
    RAISE NOTICE 'TEST 4c SKIP: 4a did not run, nothing to remove';
    RETURN;
  END IF;
  PERFORM public.admin_remove_order_technician(v_company_id, v_order_id, v_technician_id);
  IF EXISTS (
    SELECT 1 FROM public.service_order_technicians
    WHERE service_order_id = v_order_id AND technician_id = v_technician_id
  ) THEN
    RAISE EXCEPTION 'TEST 4c FAIL: assignment row still exists after remove';
  END IF;
  SELECT COUNT(*) INTO v_count
  FROM public.audit_events
  WHERE company_id = v_company_id AND event_type = 'order_technician_removed';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'TEST 4c FAIL: no order_technician_removed audit event';
  END IF;
  RAISE NOTICE 'TEST 4c PASS: assignment removed, audit present';
END;
$$;

-- TEST 4d: remove non-existent assignment (P0002)
DO $$
DECLARE v_company_id uuid; v_order_id uuid;
BEGIN
  SELECT company_id, order_id INTO v_company_id, v_order_id FROM _t008 LIMIT 1;
  IF v_order_id IS NULL THEN
    RAISE NOTICE 'TEST 4d SKIP: no service order available';
    RETURN;
  END IF;
  PERFORM public.admin_remove_order_technician(
    v_company_id, v_order_id, '00000000-0000-0000-0000-000000000099'::uuid
  );
  RAISE EXCEPTION 'TEST 4d FAIL: should have raised P0002';
EXCEPTION
  WHEN SQLSTATE 'P0002' THEN
    RAISE NOTICE 'TEST 4d PASS: non-existent assignment rejected (P0002)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 4d FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

RESET ROLE;

-- ══════════════════════════════════════════════════════════════════
-- ROLLBACK: all test data discarded — no persistent changes
-- ══════════════════════════════════════════════════════════════════
ROLLBACK;

-- ══════════════════════════════════════════════════════════════════
-- MANUAL TESTS (Policies Tester — require real user JWTs)
-- ══════════════════════════════════════════════════════════════════
-- A. Company admin calls admin_set_technician_company for another company's technician
--    → Expected: P0002 (technician not found in this company)
--
-- B. Technician role queries technician_company_assignments for their own company
--    → Expected: 0 rows (RLS allows only 'admin' role in this migration)
--
-- C. Admin of company A queries technician_facility_assignments of company B
--    → Expected: 0 rows (RLS isolates by company_id)
--
-- D. Admin assigns a disabled technician to an order
--    → Expected: P0002 (technician not enabled for company)
