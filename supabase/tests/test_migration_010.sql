-- test_migration_010.sql
-- Cross-company isolation negative tests for migration 010 (portal_rls.sql).
-- Wraps everything in BEGIN...ROLLBACK — no persistent changes.
--
-- Purpose: verify that a technician from company A cannot access data of company B,
-- even when providing known UUIDs for company B resources (direct queries + RPCs).
--
-- Addresses ChatGPT Fase 3 requirement:
--   "un técnico no pueda consultar órdenes de otra empresa ni acceder a datos
--    de una empresa a la que no esté autorizado, incluso si conoce los identificadores."
--
-- Requires migrations 001–010 applied.
-- Expected output: a series of NOTICE lines "TEST Xa PASS: ..."

BEGIN;

-- ══════════════════════════════════════════════════════════════════
-- SETUP: users
-- U99: platform admin (creates all data)
-- U97: attacker — technician in company A only
-- U96: victim admin — admin in company B only
-- ══════════════════════════════════════════════════════════════════

INSERT INTO auth.users (
  id, email, email_confirmed_at, created_at, updated_at,
  aud, role, raw_app_meta_data, raw_user_meta_data, encrypted_password
) VALUES
  ('00000000-0000-0000-0000-000000000099',
   '_test_padmin_010@constelmec.test',
   now(), now(), now(), 'authenticated', 'authenticated',
   '{"provider":"email","providers":["email"]}', '{}', ''),
  ('00000000-0000-0000-0000-000000000097',
   '_test_attacker_010@constelmec.test',
   now(), now(), now(), 'authenticated', 'authenticated',
   '{"provider":"email","providers":["email"]}', '{}', ''),
  ('00000000-0000-0000-0000-000000000096',
   '_test_victim_010@constelmec.test',
   now(), now(), now(), 'authenticated', 'authenticated',
   '{"provider":"email","providers":["email"]}', '{}', '')
ON CONFLICT (id) DO NOTHING;

INSERT INTO app_private.platform_admins (user_id, granted_by)
VALUES ('00000000-0000-0000-0000-000000000099', 'test_suite_010')
ON CONFLICT (user_id) DO NOTHING;

-- Platform admin creates companies + facilities + gates + orders
SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000099","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

DO $$
DECLARE
  v_co_a   uuid; v_co_b   uuid;
  v_fac_a  uuid; v_fac_b  uuid;
  v_gate_b uuid;
BEGIN
  SELECT public.admin_create_company('_test_co_a_010') INTO v_co_a;
  SELECT public.admin_create_company('_test_co_b_010') INTO v_co_b;
  SELECT public.admin_create_facility(v_co_a, 'Planta A-010') INTO v_fac_a;
  SELECT public.admin_create_facility(v_co_b, 'Planta B-010') INTO v_fac_b;
  SELECT public.admin_create_gate(v_co_b, v_fac_b, 'PB-01', 'Gate B-010') INTO v_gate_b;
  CREATE TEMP TABLE _t010 (
    co_a uuid, co_b uuid,
    fac_a uuid, fac_b uuid,
    gate_b uuid,
    tech_a_id uuid,  -- technician_profiles.id for attacker in co_a
    tech_b_id uuid,  -- technician_profiles.id for a co_b technician
    ord_b_id uuid,   -- service_orders.id in co_b
    sot_b_id uuid    -- service_order_technicians.id in co_b
  ) ON COMMIT DROP;
  INSERT INTO _t010 (co_a, co_b, fac_a, fac_b, gate_b)
  VALUES (v_co_a, v_co_b, v_fac_a, v_fac_b, v_gate_b);
  RAISE NOTICE 'SETUP: co_a=%, co_b=%', v_co_a, v_co_b;
END;
$$;

RESET ROLE;

-- Attacker membership: technician in company A only
DO $$
DECLARE v_co_a uuid;
BEGIN
  SELECT co_a INTO v_co_a FROM _t010 LIMIT 1;
  INSERT INTO public.memberships (company_id, user_id, role)
  VALUES (v_co_a, '00000000-0000-0000-0000-000000000097', 'technician')
  ON CONFLICT DO NOTHING;
END;
$$;

-- Victim admin membership: admin in company B
DO $$
DECLARE v_co_b uuid;
BEGIN
  SELECT co_b INTO v_co_b FROM _t010 LIMIT 1;
  INSERT INTO public.memberships (company_id, user_id, role)
  VALUES (v_co_b, '00000000-0000-0000-0000-000000000096', 'admin')
  ON CONFLICT DO NOTHING;
END;
$$;

-- Superuser: insert technician profiles + service order + assignment in co_a and co_b
DO $$
DECLARE
  v_co_a uuid; v_co_b uuid; v_fac_b uuid; v_gate_b uuid;
  v_tech_a uuid; v_tech_b uuid; v_ord_b uuid; v_sot_b uuid;
BEGIN
  SELECT co_a, co_b, fac_b, gate_b INTO v_co_a, v_co_b, v_fac_b, v_gate_b FROM _t010 LIMIT 1;

  -- Attacker's technician profile in co_a
  INSERT INTO public.technician_profiles (company_id, user_id, first_name, last_name, specialty, active)
  VALUES (v_co_a, '00000000-0000-0000-0000-000000000097', 'Attacker', 'Tech', 'Electrical', true)
  RETURNING id INTO v_tech_a;

  -- Victim technician profile in co_b (no auth.users link — standalone profile)
  INSERT INTO public.technician_profiles (company_id, first_name, last_name, specialty, active)
  VALUES (v_co_b, 'Victim', 'Tech', 'Plumbing', true)
  RETURNING id INTO v_tech_b;

  -- Service order in co_b
  INSERT INTO public.service_orders (
    company_id, facility_id, gate_id, service_type, status, scheduled_start, scheduled_end
  ) VALUES (
    v_co_b, v_fac_b, v_gate_b, 'preventive', 'scheduled',
    now() + interval '1 day', now() + interval '1 day 2 hours'
  ) RETURNING id INTO v_ord_b;

  -- Assign victim tech to the co_b order
  INSERT INTO public.service_order_technicians (service_order_id, technician_id, company_id, role)
  VALUES (v_ord_b, v_tech_b, v_co_b, 'lead')
  RETURNING id INTO v_sot_b;

  UPDATE _t010 SET tech_a_id = v_tech_a, tech_b_id = v_tech_b, ord_b_id = v_ord_b, sot_b_id = v_sot_b;
  RAISE NOTICE 'SETUP: tech_a=%, tech_b=%, ord_b=%, sot_b=%', v_tech_a, v_tech_b, v_ord_b, v_sot_b;
END;
$$;

-- ══════════════════════════════════════════════════════════════════
-- Switch to attacker session
-- ══════════════════════════════════════════════════════════════════

SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000097","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

-- ══════════════════════════════════════════════════════════════════
-- GROUP 1: Direct table queries — attacker tries to read co_b data
-- ══════════════════════════════════════════════════════════════════

-- TEST 1a: Attacker cannot read service_orders of co_b (direct query with known company_id)
DO $$
DECLARE v_co_b uuid; v_count int;
BEGIN
  SELECT co_b INTO v_co_b FROM _t010 LIMIT 1;
  SELECT COUNT(*) INTO v_count
  FROM public.service_orders
  WHERE company_id = v_co_b;
  IF v_count > 0 THEN
    RAISE EXCEPTION 'TEST 1a FAIL: attacker read % service_orders rows from co_b (expected 0)', v_count;
  END IF;
  RAISE NOTICE 'TEST 1a PASS: attacker reads 0 service_orders rows from co_b (direct query blocked by RLS)';
END;
$$;

-- TEST 1b: Attacker cannot read co_b service_order by known UUID
DO $$
DECLARE v_ord_b uuid; v_count int;
BEGIN
  SELECT ord_b_id INTO v_ord_b FROM _t010 LIMIT 1;
  SELECT COUNT(*) INTO v_count
  FROM public.service_orders
  WHERE id = v_ord_b;
  IF v_count > 0 THEN
    RAISE EXCEPTION 'TEST 1b FAIL: attacker read service_order by known UUID from co_b (expected 0)';
  END IF;
  RAISE NOTICE 'TEST 1b PASS: attacker reads 0 rows querying co_b service_order by known UUID';
END;
$$;

-- TEST 1c: Attacker cannot read service_order_technicians assignments of co_b
DO $$
DECLARE v_sot_b uuid; v_count int;
BEGIN
  SELECT sot_b_id INTO v_sot_b FROM _t010 LIMIT 1;
  SELECT COUNT(*) INTO v_count
  FROM public.service_order_technicians
  WHERE id = v_sot_b;
  IF v_count > 0 THEN
    RAISE EXCEPTION 'TEST 1c FAIL: attacker read service_order_technicians row from co_b by UUID (expected 0)';
  END IF;
  RAISE NOTICE 'TEST 1c PASS: attacker reads 0 rows from co_b service_order_technicians by known UUID';
END;
$$;

-- TEST 1d: Attacker cannot read technician_profiles of co_b (even with known UUID)
DO $$
DECLARE v_tech_b uuid; v_count int;
BEGIN
  SELECT tech_b_id INTO v_tech_b FROM _t010 LIMIT 1;
  SELECT COUNT(*) INTO v_count
  FROM public.technician_profiles
  WHERE id = v_tech_b;
  IF v_count > 0 THEN
    RAISE EXCEPTION 'TEST 1d FAIL: attacker read technician_profile from co_b by UUID (expected 0)';
  END IF;
  RAISE NOTICE 'TEST 1d PASS: attacker reads 0 rows from co_b technician_profiles by known UUID';
END;
$$;

-- TEST 1e: Attacker cannot read company_contacts of co_b
DO $$
DECLARE v_co_b uuid; v_count int;
BEGIN
  SELECT co_b INTO v_co_b FROM _t010 LIMIT 1;
  SELECT COUNT(*) INTO v_count
  FROM public.company_contacts
  WHERE company_id = v_co_b;
  IF v_count > 0 THEN
    RAISE EXCEPTION 'TEST 1e FAIL: attacker read %  company_contacts rows from co_b (expected 0)', v_count;
  END IF;
  RAISE NOTICE 'TEST 1e PASS: attacker reads 0 company_contacts from co_b';
END;
$$;

-- TEST 1f: Attacker cannot read the companies row of co_b (not a member of co_b)
DO $$
DECLARE v_co_b uuid; v_count int;
BEGIN
  SELECT co_b INTO v_co_b FROM _t010 LIMIT 1;
  SELECT COUNT(*) INTO v_count
  FROM public.companies
  WHERE id = v_co_b;
  IF v_count > 0 THEN
    RAISE EXCEPTION 'TEST 1f FAIL: attacker read co_b from public.companies (expected 0)';
  END IF;
  RAISE NOTICE 'TEST 1f PASS: attacker reads 0 rows from public.companies for co_b';
END;
$$;

-- ══════════════════════════════════════════════════════════════════
-- GROUP 2: RPC calls — attacker tries to mutate co_b data
-- ══════════════════════════════════════════════════════════════════

-- TEST 2a: Attacker cannot create a contact in co_b via admin RPC (42501)
DO $$
DECLARE v_co_b uuid;
BEGIN
  SELECT co_b INTO v_co_b FROM _t010 LIMIT 1;
  PERFORM public.admin_create_company_contact(v_co_b, 'Evil', 'Insert');
  RAISE EXCEPTION 'TEST 2a FAIL: RPC should have raised 42501' USING ERRCODE = 'XX000';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'TEST 2a PASS: admin_create_company_contact for co_b rejected (42501)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 2a FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 2b: Attacker cannot create a facility in co_b via admin RPC (42501)
DO $$
DECLARE v_co_b uuid;
BEGIN
  SELECT co_b INTO v_co_b FROM _t010 LIMIT 1;
  PERFORM public.admin_create_facility(v_co_b, 'Evil Facility');
  RAISE EXCEPTION 'TEST 2b FAIL: RPC should have raised 42501' USING ERRCODE = 'XX000';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'TEST 2b PASS: admin_create_facility for co_b rejected (42501)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 2b FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 2c: Attacker cannot assign technician to co_b order via admin RPC (42501)
DO $$
DECLARE v_co_b uuid; v_tech_a uuid; v_ord_b uuid;
BEGIN
  SELECT co_b, tech_a_id, ord_b_id INTO v_co_b, v_tech_a, v_ord_b FROM _t010 LIMIT 1;
  PERFORM public.admin_assign_order_technician(v_co_b, v_ord_b, v_tech_a, 'support'::public.order_technician_role);
  RAISE EXCEPTION 'TEST 2c FAIL: RPC should have raised 42501' USING ERRCODE = 'XX000';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'TEST 2c PASS: admin_assign_order_technician for co_b rejected (42501)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 2c FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 2d: Attacker cannot issue a QR token for a co_b gate via admin RPC (42501)
DO $$
DECLARE v_co_b uuid; v_gate_b uuid;
BEGIN
  SELECT co_b, gate_b INTO v_co_b, v_gate_b FROM _t010 LIMIT 1;
  PERFORM public.admin_issue_gate_qr(v_co_b, v_gate_b);
  RAISE EXCEPTION 'TEST 2d FAIL: RPC should have raised 42501' USING ERRCODE = 'XX000';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'TEST 2d PASS: admin_issue_gate_qr for co_b rejected (42501)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 2d FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- ══════════════════════════════════════════════════════════════════
-- GROUP 3: Positive baseline — attacker CAN read their own co_a data
-- (self-read policies working as intended)
-- ══════════════════════════════════════════════════════════════════

-- TEST 3a: Attacker can read their own technician_profile row (self-read policy)
DO $$
DECLARE v_tech_a uuid; v_count int;
BEGIN
  SELECT tech_a_id INTO v_tech_a FROM _t010 LIMIT 1;
  SELECT COUNT(*) INTO v_count
  FROM public.technician_profiles
  WHERE id = v_tech_a;
  IF v_count = 0 THEN
    RAISE EXCEPTION 'TEST 3a FAIL: attacker cannot read own technician_profile (expected 1 row)';
  END IF;
  RAISE NOTICE 'TEST 3a PASS: attacker reads 1 row from their own technician_profile (self-read working)';
END;
$$;

-- TEST 3b: Attacker can read co_a company row (is a member of co_a)
DO $$
DECLARE v_co_a uuid; v_count int;
BEGIN
  SELECT co_a INTO v_co_a FROM _t010 LIMIT 1;
  SELECT COUNT(*) INTO v_count
  FROM public.companies
  WHERE id = v_co_a;
  IF v_count = 0 THEN
    RAISE EXCEPTION 'TEST 3b FAIL: attacker cannot read co_a company row (expected 1)';
  END IF;
  RAISE NOTICE 'TEST 3b PASS: attacker reads co_a company row (member access working)';
END;
$$;

RESET ROLE;

-- ══════════════════════════════════════════════════════════════════
-- ROLLBACK: all test data discarded — no persistent changes
-- ══════════════════════════════════════════════════════════════════
ROLLBACK;

-- ══════════════════════════════════════════════════════════════════
-- MANUAL TESTS (require real user JWTs in Supabase SQL Editor)
-- ══════════════════════════════════════════════════════════════════
-- A. Technician from co_a queries service_orders with company_id = co_b_uuid
--    → Expected: 0 rows
-- B. Technician from co_a queries service_order_technicians with known sot_b UUID
--    → Expected: 0 rows
-- C. Technician from co_a calls admin_create_company_contact(co_b_uuid, ...)
--    → Expected: 42501 permission denied
-- D. Admin from co_a calls admin_assign_order_technician(co_b_uuid, ...)
--    → Expected: 42501 permission denied
-- E. Customer from co_a queries customer_observations with company_id = co_b
--    → Expected: 0 rows
