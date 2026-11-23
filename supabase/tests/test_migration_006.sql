-- test_migration_006.sql
-- Run in Supabase SQL Editor AFTER applying migration 006.
-- Wraps everything in BEGIN...ROLLBACK — no persistent changes to the database.
-- Uses DO $$ ... $$ blocks with EXCEPTION handlers for expected-failure tests.
--
-- Expected output: a series of NOTICE lines "TEST Xa PASS: ..."
-- If any RAISE EXCEPTION propagates to the top level, the test fails.
--
-- Depends on migration 005 (platform_admins table, is_platform_admin, set_updated_at).

BEGIN;

-- ══════════════════════════════════════════════════════════════════
-- SETUP: synthetic platform admin + test company (all rolled back)
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
VALUES ('00000000-0000-0000-0000-000000000099', 'test_suite_006')
ON CONFLICT (user_id) DO NOTHING;

SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000099","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

-- Create test company via RPC from migration 005
DO $$
DECLARE v_id uuid;
BEGIN
  SELECT public.admin_create_company('_test_company_006') INTO v_id;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'SETUP FAIL: admin_create_company returned null';
  END IF;
  CREATE TEMP TABLE _t006 (company_id uuid, facility_id uuid, gate_id uuid) ON COMMIT DROP;
  INSERT INTO _t006 (company_id) VALUES (v_id);
  RAISE NOTICE 'SETUP: test company created %', v_id;
END;
$$;

RESET ROLE;
SET LOCAL "request.jwt.claims" = '';

-- ══════════════════════════════════════════════════════════════════
-- GROUP 1: EXECUTE permission — anon is blocked
-- ══════════════════════════════════════════════════════════════════

-- TEST 1a: anon cannot call admin_create_facility
DO $$
BEGIN
  SET LOCAL ROLE anon;
  PERFORM public.admin_create_facility(
    '00000000-0000-0000-0000-000000000001'::uuid, 'Planta Anon'
  );
  RAISE EXCEPTION 'TEST 1a FAIL: should have raised 42501';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'TEST 1a PASS: anon EXECUTE blocked (42501)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 1a FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 1b: anon cannot call admin_create_gate
DO $$
BEGIN
  SET LOCAL ROLE anon;
  PERFORM public.admin_create_gate(
    '00000000-0000-0000-0000-000000000001'::uuid,
    '00000000-0000-0000-0000-000000000001'::uuid,
    'P01', 'Portón principal'
  );
  RAISE EXCEPTION 'TEST 1b FAIL: should have raised 42501';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'TEST 1b PASS: anon EXECUTE blocked (42501)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 1b FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 1c: anon cannot call admin_issue_gate_qr
DO $$
BEGIN
  SET LOCAL ROLE anon;
  PERFORM public.admin_issue_gate_qr(
    '00000000-0000-0000-0000-000000000001'::uuid,
    '00000000-0000-0000-0000-000000000001'::uuid
  );
  RAISE EXCEPTION 'TEST 1c FAIL: should have raised 42501';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'TEST 1c PASS: anon EXECUTE blocked (42501)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 1c FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- ══════════════════════════════════════════════════════════════════
-- GROUP 2: Facility lifecycle (admin session)
-- ══════════════════════════════════════════════════════════════════

SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000099","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

-- TEST 2a: create facility — returns a UUID, audit event written
DO $$
DECLARE v_company_id uuid; v_facility_id uuid; v_count int;
BEGIN
  SELECT company_id INTO v_company_id FROM _t006 LIMIT 1;
  SELECT public.admin_create_facility(
    v_company_id, 'Planta Norte',
    'Ruta 9 km 42', 'Edificio principal', 'Juan García', '011-4444-5555'
  ) INTO v_facility_id;
  IF v_facility_id IS NULL THEN
    RAISE EXCEPTION 'TEST 2a FAIL: admin_create_facility returned null';
  END IF;
  UPDATE _t006 SET facility_id = v_facility_id;
  SELECT COUNT(*) INTO v_count
  FROM public.audit_events
  WHERE company_id = v_company_id AND event_type = 'facility_created';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'TEST 2a FAIL: no facility_created audit event';
  END IF;
  RAISE NOTICE 'TEST 2a PASS: facility created %, audit present', v_facility_id;
END;
$$;

-- TEST 2b: short name rejected (22023)
DO $$
DECLARE v_company_id uuid;
BEGIN
  SELECT company_id INTO v_company_id FROM _t006 LIMIT 1;
  PERFORM public.admin_create_facility(v_company_id, 'X');
  RAISE EXCEPTION 'TEST 2b FAIL: should have raised 22023';
EXCEPTION
  WHEN SQLSTATE '22023' THEN
    RAISE NOTICE 'TEST 2b PASS: single-char name rejected (22023)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 2b FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 2c: inactive company rejects new facility (P0002)
DO $$
DECLARE v_company_id uuid;
BEGIN
  SELECT company_id INTO v_company_id FROM _t006 LIMIT 1;
  PERFORM public.admin_set_company_active(v_company_id, false);
  PERFORM public.admin_create_facility(v_company_id, 'Planta en empresa inactiva');
  RAISE EXCEPTION 'TEST 2c FAIL: should have raised P0002';
EXCEPTION
  WHEN SQLSTATE 'P0002' THEN
    RAISE NOTICE 'TEST 2c PASS: inactive company rejected (P0002)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 2c FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- Reactivate company for remaining tests
DO $$
DECLARE v_company_id uuid;
BEGIN
  SELECT company_id INTO v_company_id FROM _t006 LIMIT 1;
  PERFORM public.admin_set_company_active(v_company_id, true);
END;
$$;

-- TEST 2d: update facility — optimistic lock enforced
DO $$
DECLARE v_company_id uuid; v_facility_id uuid; v_ts timestamptz;
BEGIN
  SELECT company_id, facility_id INTO v_company_id, v_facility_id FROM _t006 LIMIT 1;
  SELECT updated_at INTO v_ts FROM public.facilities WHERE id = v_facility_id;
  PERFORM public.admin_update_facility(
    v_facility_id, v_company_id, 'Planta Norte v2', 'Ruta 9 km 42 actualizado',
    null, null, null, v_ts
  );
  RAISE NOTICE 'TEST 2d PASS: facility updated with correct timestamp';
END;
$$;

-- TEST 2e: stale timestamp rejected (P0001)
DO $$
DECLARE v_company_id uuid; v_facility_id uuid;
BEGIN
  SELECT company_id, facility_id INTO v_company_id, v_facility_id FROM _t006 LIMIT 1;
  PERFORM public.admin_update_facility(
    v_facility_id, v_company_id, 'Nombre con ts viejo',
    null, null, null, null,
    '2000-01-01 00:00:00+00'::timestamptz
  );
  RAISE EXCEPTION 'TEST 2e FAIL: should have raised P0001';
EXCEPTION
  WHEN SQLSTATE 'P0001' THEN
    RAISE NOTICE 'TEST 2e PASS: stale timestamp rejected (P0001)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 2e FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- ══════════════════════════════════════════════════════════════════
-- GROUP 3: Gate lifecycle
-- ══════════════════════════════════════════════════════════════════

-- TEST 3a: create gate
DO $$
DECLARE v_company_id uuid; v_facility_id uuid; v_gate_id uuid; v_count int;
BEGIN
  SELECT company_id, facility_id INTO v_company_id, v_facility_id FROM _t006 LIMIT 1;
  SELECT public.admin_create_gate(
    v_company_id, v_facility_id,
    'P-01', 'Portón principal de acceso',
    'CAME BX-243', 'SN-9871234', 'Sector A, junto a garita'
  ) INTO v_gate_id;
  IF v_gate_id IS NULL THEN
    RAISE EXCEPTION 'TEST 3a FAIL: admin_create_gate returned null';
  END IF;
  UPDATE _t006 SET gate_id = v_gate_id;
  SELECT COUNT(*) INTO v_count
  FROM public.audit_events
  WHERE company_id = v_company_id AND gate_id = v_gate_id AND event_type = 'gate_created';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'TEST 3a FAIL: no gate_created audit event';
  END IF;
  RAISE NOTICE 'TEST 3a PASS: gate created %, audit present', v_gate_id;
END;
$$;

-- TEST 3b: empty code rejected (22023)
DO $$
DECLARE v_company_id uuid; v_facility_id uuid;
BEGIN
  SELECT company_id, facility_id INTO v_company_id, v_facility_id FROM _t006 LIMIT 1;
  PERFORM public.admin_create_gate(v_company_id, v_facility_id, '', 'Sin código');
  RAISE EXCEPTION 'TEST 3b FAIL: should have raised 22023';
EXCEPTION
  WHEN SQLSTATE '22023' THEN
    RAISE NOTICE 'TEST 3b PASS: empty code rejected (22023)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 3b FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 3c: inactive facility rejects new gate (P0002)
DO $$
DECLARE v_company_id uuid; v_facility_id uuid;
BEGIN
  SELECT company_id, facility_id INTO v_company_id, v_facility_id FROM _t006 LIMIT 1;
  PERFORM public.admin_set_facility_active(v_facility_id, v_company_id, false);
  PERFORM public.admin_create_gate(v_company_id, v_facility_id, 'P-99', 'No debe crearse');
  RAISE EXCEPTION 'TEST 3c FAIL: should have raised P0002';
EXCEPTION
  WHEN SQLSTATE 'P0002' THEN
    RAISE NOTICE 'TEST 3c PASS: inactive facility rejected (P0002)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 3c FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- Reactivate facility
DO $$
DECLARE v_company_id uuid; v_facility_id uuid;
BEGIN
  SELECT company_id, facility_id INTO v_company_id, v_facility_id FROM _t006 LIMIT 1;
  PERFORM public.admin_set_facility_active(v_facility_id, v_company_id, true);
END;
$$;

-- TEST 3d: update gate with correct timestamp
DO $$
DECLARE v_company_id uuid; v_gate_id uuid; v_ts timestamptz;
BEGIN
  SELECT company_id, gate_id INTO v_company_id, v_gate_id FROM _t006 LIMIT 1;
  SELECT updated_at INTO v_ts FROM public.gates WHERE id = v_gate_id;
  PERFORM public.admin_update_gate(
    v_gate_id, v_company_id,
    'Portón principal de acceso (actualizado)',
    'CAME BX-244', null, 'Sector A, garita renovada',
    'operational'::public.gate_operational_state, v_ts
  );
  RAISE NOTICE 'TEST 3d PASS: gate updated with correct timestamp';
END;
$$;

-- ══════════════════════════════════════════════════════════════════
-- GROUP 4: QR lifecycle
-- ══════════════════════════════════════════════════════════════════

-- TEST 4a: issue QR — returns a non-null token, hash stored in DB
DO $$
DECLARE v_company_id uuid; v_gate_id uuid; v_token text;
        v_expected_hash text; v_stored_hash text; v_status text;
BEGIN
  SELECT company_id, gate_id INTO v_company_id, v_gate_id FROM _t006 LIMIT 1;
  SELECT public.admin_issue_gate_qr(v_gate_id, v_company_id) INTO v_token;
  IF v_token IS NULL THEN
    RAISE EXCEPTION 'TEST 4a FAIL: admin_issue_gate_qr returned null';
  END IF;
  v_expected_hash := encode(extensions.digest(v_token, 'sha256'), 'hex');
  SELECT token_hash, status INTO v_stored_hash, v_status
  FROM public.gate_qr_codes
  WHERE gate_id = v_gate_id AND status = 'active';
  IF v_stored_hash IS NULL THEN
    RAISE EXCEPTION 'TEST 4a FAIL: no active QR row found in gate_qr_codes';
  END IF;
  IF v_stored_hash <> v_expected_hash THEN
    RAISE EXCEPTION 'TEST 4a FAIL: stored hash % does not match expected %',
      v_stored_hash, v_expected_hash;
  END IF;
  RAISE NOTICE 'TEST 4a PASS: QR issued, hash verified';
END;
$$;

-- TEST 4b: re-issuing QR revokes the previous one and issues a new one
DO $$
DECLARE v_company_id uuid; v_gate_id uuid;
        v_token1 text; v_token2 text;
        v_active_count int; v_revoked_count int;
BEGIN
  SELECT company_id, gate_id INTO v_company_id, v_gate_id FROM _t006 LIMIT 1;
  -- Issue second QR (first is already active from TEST 4a)
  SELECT public.admin_issue_gate_qr(v_gate_id, v_company_id) INTO v_token2;
  -- Should now be exactly 1 active QR
  SELECT COUNT(*) INTO v_active_count
  FROM public.gate_qr_codes WHERE gate_id = v_gate_id AND status = 'active';
  IF v_active_count <> 1 THEN
    RAISE EXCEPTION 'TEST 4b FAIL: expected 1 active QR, found %', v_active_count;
  END IF;
  -- And at least 1 revoked QR (the first one)
  SELECT COUNT(*) INTO v_revoked_count
  FROM public.gate_qr_codes WHERE gate_id = v_gate_id AND status = 'revoked';
  IF v_revoked_count < 1 THEN
    RAISE EXCEPTION 'TEST 4b FAIL: expected at least 1 revoked QR, found 0';
  END IF;
  RAISE NOTICE 'TEST 4b PASS: re-issue revokes previous QR (% active, % revoked)',
    v_active_count, v_revoked_count;
END;
$$;

-- TEST 4c: explicit revoke clears the active QR
DO $$
DECLARE v_company_id uuid; v_gate_id uuid; v_qr_id uuid; v_active_count int;
BEGIN
  SELECT company_id, gate_id INTO v_company_id, v_gate_id FROM _t006 LIMIT 1;
  SELECT id INTO v_qr_id FROM public.gate_qr_codes
    WHERE gate_id = v_gate_id AND status = 'active' LIMIT 1;
  PERFORM public.admin_revoke_gate_qr(v_qr_id, v_company_id);
  SELECT COUNT(*) INTO v_active_count
  FROM public.gate_qr_codes WHERE gate_id = v_gate_id AND status = 'active';
  IF v_active_count <> 0 THEN
    RAISE EXCEPTION 'TEST 4c FAIL: expected 0 active QRs after revoke, found %', v_active_count;
  END IF;
  RAISE NOTICE 'TEST 4c PASS: explicit revoke cleared active QR';
END;
$$;

-- TEST 4d: deactivating a gate revokes its active QR
DO $$
DECLARE v_company_id uuid; v_gate_id uuid; v_active_count int;
BEGIN
  SELECT company_id, gate_id INTO v_company_id, v_gate_id FROM _t006 LIMIT 1;
  -- Issue a fresh QR first
  PERFORM public.admin_issue_gate_qr(v_gate_id, v_company_id);
  -- Deactivate the gate
  PERFORM public.admin_set_gate_active(v_gate_id, v_company_id, false);
  -- Active QR should be gone
  SELECT COUNT(*) INTO v_active_count
  FROM public.gate_qr_codes WHERE gate_id = v_gate_id AND status = 'active';
  IF v_active_count <> 0 THEN
    RAISE EXCEPTION 'TEST 4d FAIL: expected 0 active QRs after gate deactivation, found %',
      v_active_count;
  END IF;
  RAISE NOTICE 'TEST 4d PASS: gate deactivation revoked active QR';
END;
$$;

-- TEST 4e: cannot issue QR for an inactive gate (P0002)
DO $$
DECLARE v_company_id uuid; v_gate_id uuid;
BEGIN
  SELECT company_id, gate_id INTO v_company_id, v_gate_id FROM _t006 LIMIT 1;
  -- gate is inactive from TEST 4d
  PERFORM public.admin_issue_gate_qr(v_gate_id, v_company_id);
  RAISE EXCEPTION 'TEST 4e FAIL: should have raised P0002';
EXCEPTION
  WHEN SQLSTATE 'P0002' THEN
    RAISE NOTICE 'TEST 4e PASS: inactive gate rejects QR issuance (P0002)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 4e FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 4f: inactive facility blocks QR issuance (new hierarchy check)
DO $$
DECLARE v_company_id uuid; v_facility_id uuid; v_gate_id uuid;
BEGIN
  SELECT company_id, facility_id, gate_id INTO v_company_id, v_facility_id, v_gate_id FROM _t006 LIMIT 1;
  -- Reactivate gate (deactivated in TEST 4d) so facility check is reached
  PERFORM public.admin_set_gate_active(v_gate_id, v_company_id, true);
  -- Deactivate the facility — gate is active but facility is not
  PERFORM public.admin_set_facility_active(v_facility_id, v_company_id, false);
  -- Attempt QR issuance — should fail because facility is inactive
  PERFORM public.admin_issue_gate_qr(v_gate_id, v_company_id);
  RAISE EXCEPTION 'TEST 4f FAIL: should have raised P0002 for inactive facility';
EXCEPTION
  WHEN SQLSTATE 'P0002' THEN
    RAISE NOTICE 'TEST 4f PASS: inactive facility blocks QR issuance (P0002)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 4f FAIL: unexpected % — %', SQLSTATE, SQLERRM;
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
-- A. Company admin (not platform admin) calls admin_create_facility
--    → Expected: succeeds for their own company, 42501 for another company
--
-- B. Technician role calls admin_create_facility
--    → Expected: 42501 (write requires 'admin' role)
--
-- C. Technician queries gate_qr_codes for their own company
--    → Expected: returns rows (qr_codes_read policy allows admin + technician)
--
-- D. Customer role queries gate_qr_codes
--    → Expected: 0 rows (not in has_membership filter)
--
-- E. Member of company A queries facilities of company B
--    → Expected: 0 rows (RLS isolates by company_id)
