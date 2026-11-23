-- test_migration_007.sql
-- Run in Supabase SQL Editor AFTER applying migration 007.
-- Wraps everything in BEGIN...ROLLBACK — no persistent changes to the database.
-- Uses DO $$ ... $$ blocks with EXCEPTION handlers for expected-failure tests.
--
-- Expected output: a series of NOTICE lines "TEST Xa PASS: ..."
-- If any RAISE EXCEPTION propagates to the top level, the test fails.
--
-- Depends on migrations 005 + 006 (platform_admins, facilities, is_platform_admin, set_updated_at).

BEGIN;

-- ══════════════════════════════════════════════════════════════════
-- SETUP: synthetic platform admin + test company + test facility
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
VALUES ('00000000-0000-0000-0000-000000000099', 'test_suite_007')
ON CONFLICT (user_id) DO NOTHING;

SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000099","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

-- Create test company + facility, store IDs in temp table
DO $$
DECLARE v_company_id uuid; v_facility_id uuid; v_other_company_id uuid;
BEGIN
  SELECT public.admin_create_company('_test_company_007') INTO v_company_id;
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'SETUP FAIL: admin_create_company returned null';
  END IF;
  SELECT public.admin_create_facility(v_company_id, 'Planta Norte 007') INTO v_facility_id;
  IF v_facility_id IS NULL THEN
    RAISE EXCEPTION 'SETUP FAIL: admin_create_facility returned null';
  END IF;
  -- A second company for cross-company isolation tests
  SELECT public.admin_create_company('_test_other_company_007') INTO v_other_company_id;
  CREATE TEMP TABLE _t007 (
    company_id       uuid,
    facility_id      uuid,
    other_company_id uuid,
    contact_id       uuid
  ) ON COMMIT DROP;
  INSERT INTO _t007 (company_id, facility_id, other_company_id)
  VALUES (v_company_id, v_facility_id, v_other_company_id);
  RAISE NOTICE 'SETUP: company %, facility %, other_company %',
    v_company_id, v_facility_id, v_other_company_id;
END;
$$;

RESET ROLE;
SET LOCAL "request.jwt.claims" = '';

-- ══════════════════════════════════════════════════════════════════
-- GROUP 1: EXECUTE permission — anon is blocked
-- ══════════════════════════════════════════════════════════════════

-- TEST 1a: anon cannot call admin_create_company_contact
DO $$
BEGIN
  SET LOCAL ROLE anon;
  PERFORM public.admin_create_company_contact(
    '00000000-0000-0000-0000-000000000001'::uuid, 'Juan', 'Pérez'
  );
  RAISE EXCEPTION 'TEST 1a FAIL: should have raised 42501';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'TEST 1a PASS: anon EXECUTE blocked on create (42501)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 1a FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 1b: anon cannot call admin_update_company_contact
DO $$
BEGIN
  SET LOCAL ROLE anon;
  PERFORM public.admin_update_company_contact(
    '00000000-0000-0000-0000-000000000001'::uuid,
    '00000000-0000-0000-0000-000000000001'::uuid,
    'Juan', 'Pérez', 'administrative'::public.contact_category,
    null, null, null, null, now()
  );
  RAISE EXCEPTION 'TEST 1b FAIL: should have raised 42501';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'TEST 1b PASS: anon EXECUTE blocked on update (42501)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 1b FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 1c: anon cannot call admin_set_company_contact_active
DO $$
BEGIN
  SET LOCAL ROLE anon;
  PERFORM public.admin_set_company_contact_active(
    '00000000-0000-0000-0000-000000000001'::uuid,
    '00000000-0000-0000-0000-000000000001'::uuid,
    false, now()
  );
  RAISE EXCEPTION 'TEST 1c FAIL: should have raised 42501';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'TEST 1c PASS: anon EXECUTE blocked on set_active (42501)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 1c FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- ══════════════════════════════════════════════════════════════════
-- GROUP 2: Contact lifecycle (admin session)
-- ══════════════════════════════════════════════════════════════════

SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000099","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

-- TEST 2a: create company-wide contact — returns UUID, audit event present
DO $$
DECLARE v_company_id uuid; v_contact_id uuid; v_count int;
BEGIN
  SELECT company_id INTO v_company_id FROM _t007 LIMIT 1;
  SELECT public.admin_create_company_contact(
    v_company_id, 'María', 'González',
    'commercial'::public.contact_category,
    'maria@empresa.com', '+54-11-5555-1234', 'Contacto principal de ventas'
  ) INTO v_contact_id;
  IF v_contact_id IS NULL THEN
    RAISE EXCEPTION 'TEST 2a FAIL: admin_create_company_contact returned null';
  END IF;
  UPDATE _t007 SET contact_id = v_contact_id;
  SELECT COUNT(*) INTO v_count
  FROM public.audit_events
  WHERE company_id = v_company_id AND event_type = 'contact_created';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'TEST 2a FAIL: no contact_created audit event';
  END IF;
  RAISE NOTICE 'TEST 2a PASS: contact created %, audit present', v_contact_id;
END;
$$;

-- TEST 2b: create facility-linked contact — facility must belong to same company
DO $$
DECLARE v_company_id uuid; v_facility_id uuid; v_contact_id uuid;
BEGIN
  SELECT company_id, facility_id INTO v_company_id, v_facility_id FROM _t007 LIMIT 1;
  SELECT public.admin_create_company_contact(
    v_company_id, 'Carlos', 'Rodríguez',
    'technical'::public.contact_category,
    null, null, null, v_facility_id
  ) INTO v_contact_id;
  IF v_contact_id IS NULL THEN
    RAISE EXCEPTION 'TEST 2b FAIL: facility-linked contact returned null';
  END IF;
  -- Verify facility_id stored correctly
  IF NOT EXISTS (
    SELECT 1 FROM public.company_contacts
    WHERE id = v_contact_id AND facility_id = v_facility_id
  ) THEN
    RAISE EXCEPTION 'TEST 2b FAIL: facility_id not stored on contact';
  END IF;
  RAISE NOTICE 'TEST 2b PASS: facility-linked contact created %', v_contact_id;
END;
$$;

-- TEST 2c: update contact with correct timestamp — succeeds
DO $$
DECLARE v_company_id uuid; v_contact_id uuid; v_ts timestamptz;
BEGIN
  SELECT company_id, contact_id INTO v_company_id, v_contact_id FROM _t007 LIMIT 1;
  SELECT updated_at INTO v_ts FROM public.company_contacts WHERE id = v_contact_id;
  PERFORM public.admin_update_company_contact(
    v_contact_id, v_company_id,
    'María', 'González Actualizada',
    'commercial'::public.contact_category,
    'maria.nueva@empresa.com', null, 'Notas actualizadas',
    null, v_ts
  );
  RAISE NOTICE 'TEST 2c PASS: contact updated with correct timestamp';
END;
$$;

-- TEST 2d: empty email string clears the field ('' → NULL via nullif)
DO $$
DECLARE v_company_id uuid; v_contact_id uuid; v_ts timestamptz; v_stored_email text;
BEGIN
  SELECT company_id, contact_id INTO v_company_id, v_contact_id FROM _t007 LIMIT 1;
  SELECT updated_at INTO v_ts FROM public.company_contacts WHERE id = v_contact_id;
  PERFORM public.admin_update_company_contact(
    v_contact_id, v_company_id,
    'María', 'González Actualizada',
    'commercial'::public.contact_category,
    '', null, null,
    null, v_ts
  );
  SELECT email INTO v_stored_email FROM public.company_contacts WHERE id = v_contact_id;
  IF v_stored_email IS NOT NULL THEN
    RAISE EXCEPTION 'TEST 2d FAIL: empty email should store NULL, got %', v_stored_email;
  END IF;
  RAISE NOTICE 'TEST 2d PASS: empty email string stored as NULL';
END;
$$;

-- TEST 2e: set_active deactivates with correct timestamp — succeeds
DO $$
DECLARE v_company_id uuid; v_contact_id uuid; v_ts timestamptz; v_active boolean;
BEGIN
  SELECT company_id, contact_id INTO v_company_id, v_contact_id FROM _t007 LIMIT 1;
  SELECT updated_at INTO v_ts FROM public.company_contacts WHERE id = v_contact_id;
  PERFORM public.admin_set_company_contact_active(v_contact_id, v_company_id, false, v_ts);
  SELECT active INTO v_active FROM public.company_contacts WHERE id = v_contact_id;
  IF v_active THEN
    RAISE EXCEPTION 'TEST 2e FAIL: contact still active after deactivation';
  END IF;
  RAISE NOTICE 'TEST 2e PASS: contact deactivated, audit event written';
END;
$$;

-- ══════════════════════════════════════════════════════════════════
-- GROUP 3: Validation rejects
-- ══════════════════════════════════════════════════════════════════

-- TEST 3a: first_name too short (22023)
DO $$
DECLARE v_company_id uuid;
BEGIN
  SELECT company_id INTO v_company_id FROM _t007 LIMIT 1;
  PERFORM public.admin_create_company_contact(v_company_id, 'X', 'Apellido');
  RAISE EXCEPTION 'TEST 3a FAIL: should have raised 22023';
EXCEPTION
  WHEN SQLSTATE '22023' THEN
    RAISE NOTICE 'TEST 3a PASS: single-char first_name rejected (22023)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 3a FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 3b: last_name too short (22023)
DO $$
DECLARE v_company_id uuid;
BEGIN
  SELECT company_id INTO v_company_id FROM _t007 LIMIT 1;
  PERFORM public.admin_create_company_contact(v_company_id, 'Nombre', 'Z');
  RAISE EXCEPTION 'TEST 3b FAIL: should have raised 22023';
EXCEPTION
  WHEN SQLSTATE '22023' THEN
    RAISE NOTICE 'TEST 3b PASS: single-char last_name rejected (22023)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 3b FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 3c: invalid email format (22023)
DO $$
DECLARE v_company_id uuid;
BEGIN
  SELECT company_id INTO v_company_id FROM _t007 LIMIT 1;
  PERFORM public.admin_create_company_contact(
    v_company_id, 'Juan', 'García', 'technical'::public.contact_category, 'not-an-email'
  );
  RAISE EXCEPTION 'TEST 3c FAIL: should have raised 22023';
EXCEPTION
  WHEN SQLSTATE '22023' THEN
    RAISE NOTICE 'TEST 3c PASS: invalid email format rejected (22023)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 3c FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 3d: phone too long (22023)
DO $$
DECLARE v_company_id uuid;
BEGIN
  SELECT company_id INTO v_company_id FROM _t007 LIMIT 1;
  PERFORM public.admin_create_company_contact(
    v_company_id, 'Juan', 'García', 'technical'::public.contact_category,
    null, repeat('1', 31)
  );
  RAISE EXCEPTION 'TEST 3d FAIL: should have raised 22023';
EXCEPTION
  WHEN SQLSTATE '22023' THEN
    RAISE NOTICE 'TEST 3d PASS: phone > 30 chars rejected (22023)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 3d FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 3e: notes too long (22023)
DO $$
DECLARE v_company_id uuid;
BEGIN
  SELECT company_id INTO v_company_id FROM _t007 LIMIT 1;
  PERFORM public.admin_create_company_contact(
    v_company_id, 'Juan', 'García', 'technical'::public.contact_category,
    null, null, repeat('x', 1001)
  );
  RAISE EXCEPTION 'TEST 3e FAIL: should have raised 22023';
EXCEPTION
  WHEN SQLSTATE '22023' THEN
    RAISE NOTICE 'TEST 3e PASS: notes > 1000 chars rejected (22023)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 3e FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 3f: facility from a different company (P0002)
DO $$
DECLARE v_company_id uuid; v_other_company_id uuid; v_other_facility_id uuid;
BEGIN
  SELECT company_id, other_company_id INTO v_company_id, v_other_company_id FROM _t007 LIMIT 1;
  -- Create a facility under other_company
  SELECT public.admin_create_facility(v_other_company_id, 'Planta Otra Empresa') INTO v_other_facility_id;
  -- Try to link it to v_company_id's contact — must fail
  PERFORM public.admin_create_company_contact(
    v_company_id, 'Ana', 'Martínez', 'administrative'::public.contact_category,
    null, null, null, v_other_facility_id
  );
  RAISE EXCEPTION 'TEST 3f FAIL: should have raised P0002';
EXCEPTION
  WHEN SQLSTATE 'P0002' THEN
    RAISE NOTICE 'TEST 3f PASS: cross-company facility rejected (P0002)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 3f FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 3g: inactive company rejects new contact (P0002)
DO $$
DECLARE v_company_id uuid;
BEGIN
  SELECT company_id INTO v_company_id FROM _t007 LIMIT 1;
  PERFORM public.admin_set_company_active(v_company_id, false);
  PERFORM public.admin_create_company_contact(v_company_id, 'Ana', 'Martínez');
  RAISE EXCEPTION 'TEST 3g FAIL: should have raised P0002';
EXCEPTION
  WHEN SQLSTATE 'P0002' THEN
    RAISE NOTICE 'TEST 3g PASS: inactive company rejects new contact (P0002)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 3g FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- Reactivate company for remaining tests
DO $$
DECLARE v_company_id uuid;
BEGIN
  SELECT company_id INTO v_company_id FROM _t007 LIMIT 1;
  PERFORM public.admin_set_company_active(v_company_id, true);
END;
$$;

-- ══════════════════════════════════════════════════════════════════
-- GROUP 4: Optimistic lock
-- ══════════════════════════════════════════════════════════════════

-- TEST 4a: update with stale timestamp (P0001)
DO $$
DECLARE v_company_id uuid; v_contact_id uuid;
BEGIN
  SELECT company_id, contact_id INTO v_company_id, v_contact_id FROM _t007 LIMIT 1;
  PERFORM public.admin_update_company_contact(
    v_contact_id, v_company_id,
    'María', 'González',
    'commercial'::public.contact_category,
    null, null, null, null,
    '2000-01-01 00:00:00+00'::timestamptz
  );
  RAISE EXCEPTION 'TEST 4a FAIL: should have raised P0001';
EXCEPTION
  WHEN SQLSTATE 'P0001' THEN
    RAISE NOTICE 'TEST 4a PASS: stale timestamp rejected on update (P0001)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 4a FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 4b: set_active with stale timestamp (P0001)
DO $$
DECLARE v_company_id uuid; v_contact_id uuid;
BEGIN
  SELECT company_id, contact_id INTO v_company_id, v_contact_id FROM _t007 LIMIT 1;
  PERFORM public.admin_set_company_contact_active(
    v_contact_id, v_company_id, true,
    '2000-01-01 00:00:00+00'::timestamptz
  );
  RAISE EXCEPTION 'TEST 4b FAIL: should have raised P0001';
EXCEPTION
  WHEN SQLSTATE 'P0001' THEN
    RAISE NOTICE 'TEST 4b PASS: stale timestamp rejected on set_active (P0001)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 4b FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 4c: set_active reactivates with correct timestamp — audit event written
DO $$
DECLARE v_company_id uuid; v_contact_id uuid; v_ts timestamptz; v_count int; v_active boolean;
BEGIN
  SELECT company_id, contact_id INTO v_company_id, v_contact_id FROM _t007 LIMIT 1;
  SELECT updated_at INTO v_ts FROM public.company_contacts WHERE id = v_contact_id;
  PERFORM public.admin_set_company_contact_active(v_contact_id, v_company_id, true, v_ts);
  SELECT active INTO v_active FROM public.company_contacts WHERE id = v_contact_id;
  IF NOT v_active THEN
    RAISE EXCEPTION 'TEST 4c FAIL: contact not active after reactivation';
  END IF;
  SELECT COUNT(*) INTO v_count
  FROM public.audit_events
  WHERE company_id = v_company_id AND event_type = 'contact_activated';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'TEST 4c FAIL: no contact_activated audit event';
  END IF;
  RAISE NOTICE 'TEST 4c PASS: reactivation succeeds, audit event present';
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
-- A. Company admin calls admin_create_company_contact for their own company
--    → Expected: succeeds, contact created
--
-- B. Company admin calls admin_create_company_contact for a DIFFERENT company
--    → Expected: 42501 (has_membership check on p_company_id fails)
--
-- C. Technician role queries company_contacts for their own company
--    → Expected: 0 rows (RLS allows only 'admin' role; technicians cannot read contacts)
--
-- D. Member of company A queries contacts of company B
--    → Expected: 0 rows (RLS isolates by company_id)
--
-- E. Admin passes facility_id from another company
--    → Expected: P0002 (cross-company facility check)
