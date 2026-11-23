-- test_migration_009.sql
-- Run in Supabase SQL Editor AFTER applying migrations 007 + 008 + 009.
-- Wraps everything in BEGIN...ROLLBACK — no persistent changes.
--
-- Expected output: a series of NOTICE lines "TEST Xa PASS: ..."
-- If any RAISE EXCEPTION propagates to the top level, the test fails.
--
-- Covers all 7 approval criteria from the migration 009 architecture review:
--   1. Re-assignment of same tech to same order works.
--   2. No two active duplicate assignments.
--   3. No two active lead technicians per order.
--   4. Full assignment history preserved after soft-remove.
--   5. Disabling a tech does not modify completed service assignments.
--   6. Cannot assign inactive techs or cross-company without authorization.
--   7. Tests cover re-assignment, concurrency invariant, and multi-company isolation.

BEGIN;

-- ══════════════════════════════════════════════════════════════════
-- SETUP: synthetic users (platform admin + company admin)
-- ══════════════════════════════════════════════════════════════════

INSERT INTO auth.users (
  id, email, email_confirmed_at, created_at, updated_at,
  aud, role, raw_app_meta_data, raw_user_meta_data, encrypted_password
) VALUES
  ('00000000-0000-0000-0000-000000000099',
   '_test_padmin_009@constelmec.test',
   now(), now(), now(), 'authenticated', 'authenticated',
   '{"provider":"email","providers":["email"]}', '{}', ''),
  ('00000000-0000-0000-0000-000000000098',
   '_test_cadmin_009@constelmec.test',
   now(), now(), now(), 'authenticated', 'authenticated',
   '{"provider":"email","providers":["email"]}', '{}', '')
ON CONFLICT (id) DO NOTHING;

INSERT INTO app_private.platform_admins (user_id, granted_by)
VALUES ('00000000-0000-0000-0000-000000000099', 'test_suite_009')
ON CONFLICT (user_id) DO NOTHING;

-- Platform admin creates companies, facilities, and gates.
SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000099","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

DO $$
DECLARE
  v_co_a   uuid; v_co_b   uuid;
  v_fac    uuid; v_gate   uuid;
BEGIN
  SELECT public.admin_create_company('_test_co_a_009') INTO v_co_a;
  SELECT public.admin_create_company('_test_co_b_009') INTO v_co_b;
  SELECT public.admin_create_facility(v_co_a, 'Planta A-009') INTO v_fac;
  SELECT public.admin_create_gate(v_co_a, v_fac, 'P-01', 'Gate A-009') INTO v_gate;
  CREATE TEMP TABLE _t009_ids (co_a uuid, co_b uuid, fac uuid, gate uuid) ON COMMIT DROP;
  INSERT INTO _t009_ids VALUES (v_co_a, v_co_b, v_fac, v_gate);
  RAISE NOTICE 'SETUP: co_a=%, co_b=%, fac=%, gate=%', v_co_a, v_co_b, v_fac, v_gate;
END;
$$;

-- Add company admin membership for the second user on co_a.
DO $$
DECLARE v_co_a uuid;
BEGIN
  SELECT co_a INTO v_co_a FROM _t009_ids LIMIT 1;
  INSERT INTO public.memberships (company_id, user_id, role)
  VALUES (v_co_a, '00000000-0000-0000-0000-000000000098', 'admin')
  ON CONFLICT DO NOTHING;
END;
$$;

RESET ROLE;

-- Direct INSERTs as superuser for tables with revoked DML.
DO $$
DECLARE
  v_co_a    uuid; v_co_b   uuid;
  v_fac     uuid; v_gate   uuid;
  v_tech_a  uuid; v_tech_b uuid;
  v_ord_sched uuid; v_ord_inprog uuid; v_ord_done uuid;
BEGIN
  SELECT co_a, co_b, fac, gate INTO v_co_a, v_co_b, v_fac, v_gate FROM _t009_ids LIMIT 1;

  -- tech_a belongs to co_a (same-company path).
  INSERT INTO public.technician_profiles (company_id, first_name, last_name, active)
  VALUES (v_co_a, 'Carlos', 'García', true)
  RETURNING id INTO v_tech_a;

  -- tech_b belongs to co_b (cross-company path).
  INSERT INTO public.technician_profiles (company_id, first_name, last_name, active)
  VALUES (v_co_b, 'Mónica', 'Vidal', true)
  RETURNING id INTO v_tech_b;

  -- Scheduled order (pending — cascade should soft-remove tech).
  INSERT INTO public.service_orders (company_id, facility_id, gate_id, service_type, status,
                                     scheduled_start, scheduled_end)
  VALUES (v_co_a, v_fac, v_gate, 'preventive', 'scheduled',
          now() + interval '1 day', now() + interval '1 day 2 hours')
  RETURNING id INTO v_ord_sched;

  -- In-progress order (cascade should raise exception).
  INSERT INTO public.service_orders (company_id, facility_id, gate_id, service_type, status,
                                     scheduled_start, scheduled_end)
  VALUES (v_co_a, v_fac, v_gate, 'corrective', 'in_progress',
          now() - interval '1 hour', now() + interval '1 hour')
  RETURNING id INTO v_ord_inprog;

  -- Completed order (cascade should leave unchanged).
  INSERT INTO public.service_orders (company_id, facility_id, gate_id, service_type, status,
                                     scheduled_start, scheduled_end, completed_at)
  VALUES (v_co_a, v_fac, v_gate, 'preventive', 'completed',
          now() - interval '5 days', now() - interval '5 days' + interval '2 hours',
          now() - interval '5 days' + interval '2 hours')
  RETURNING id INTO v_ord_done;

  CREATE TEMP TABLE _t009 (
    co_a      uuid, co_b      uuid,
    fac       uuid, gate      uuid,
    tech_a    uuid, tech_b    uuid,
    ord_sched uuid, ord_inprog uuid, ord_done uuid
  ) ON COMMIT DROP;
  INSERT INTO _t009 VALUES (v_co_a, v_co_b, v_fac, v_gate, v_tech_a, v_tech_b,
                            v_ord_sched, v_ord_inprog, v_ord_done);
  RAISE NOTICE 'SETUP: tech_a=%, tech_b=%, ord_sched=%, ord_inprog=%, ord_done=%',
    v_tech_a, v_tech_b, v_ord_sched, v_ord_inprog, v_ord_done;
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
    '00000000-0000-0000-0000-000000000002'::uuid, true);
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
  PERFORM public.admin_assign_order_technician(
    '00000000-0000-0000-0000-000000000001'::uuid,
    '00000000-0000-0000-0000-000000000002'::uuid,
    '00000000-0000-0000-0000-000000000003'::uuid);
  RAISE EXCEPTION 'TEST 1b FAIL: should have raised 42501';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'TEST 1b PASS: anon EXECUTE blocked on assign_order_technician (42501)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 1b FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

DO $$
BEGIN
  SET LOCAL ROLE anon;
  PERFORM public.admin_remove_order_technician(
    '00000000-0000-0000-0000-000000000001'::uuid,
    '00000000-0000-0000-0000-000000000002'::uuid,
    '00000000-0000-0000-0000-000000000003'::uuid);
  RAISE EXCEPTION 'TEST 1c FAIL: should have raised 42501';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'TEST 1c PASS: anon EXECUTE blocked on remove_order_technician (42501)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 1c FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- ══════════════════════════════════════════════════════════════════
-- GROUP 2: Cross-company enablement isolation (Criterion 6 & 7)
-- ══════════════════════════════════════════════════════════════════

-- TEST 2a: Company admin cannot enable a tech from a different company.
SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000098","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_co_a uuid; v_tech_b uuid;
BEGIN
  SELECT co_a, tech_b INTO v_co_a, v_tech_b FROM _t009 LIMIT 1;
  PERFORM public.admin_set_technician_company(v_co_a, v_tech_b, true);
  RAISE EXCEPTION 'TEST 2a FAIL: company admin should not enable cross-company tech';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'TEST 2a PASS: company admin cross-company enable blocked (42501)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 2a FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

RESET ROLE;
SET LOCAL "request.jwt.claims" = '';

-- TEST 2b: Platform admin CAN enable a tech from a different company.
SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000099","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_co_a uuid; v_tech_b uuid; v_active boolean;
BEGIN
  SELECT co_a, tech_b INTO v_co_a, v_tech_b FROM _t009 LIMIT 1;
  PERFORM public.admin_set_technician_company(v_co_a, v_tech_b, true);
  SELECT active INTO v_active
  FROM public.technician_company_assignments
  WHERE company_id = v_co_a AND technician_id = v_tech_b;
  IF v_active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'TEST 2b FAIL: assignment not active after platform admin cross-company enable';
  END IF;
  RAISE NOTICE 'TEST 2b PASS: platform admin cross-company enable succeeded';
END;
$$;

-- Disable cross-company tech to avoid interfering with cascade tests.
DO $$
DECLARE v_co_a uuid; v_tech_b uuid;
BEGIN
  SELECT co_a, tech_b INTO v_co_a, v_tech_b FROM _t009 LIMIT 1;
  PERFORM public.admin_set_technician_company(v_co_a, v_tech_b, false);
END;
$$;

-- ══════════════════════════════════════════════════════════════════
-- GROUP 3: Company assignment lifecycle with status-aware cascade
-- ══════════════════════════════════════════════════════════════════

-- Enable tech_a for co_a (prerequisite for all subsequent tests).
DO $$
DECLARE v_co_a uuid; v_tech_a uuid;
BEGIN
  SELECT co_a, tech_a INTO v_co_a, v_tech_a FROM _t009 LIMIT 1;
  PERFORM public.admin_set_technician_company(v_co_a, v_tech_a, true);
  RAISE NOTICE 'SETUP 3: tech_a enabled for co_a';
END;
$$;

-- TEST 3a: Enable tech — assignment row active, audit event present.
DO $$
DECLARE v_co_a uuid; v_tech_a uuid; v_active boolean; v_count int;
BEGIN
  SELECT co_a, tech_a INTO v_co_a, v_tech_a FROM _t009 LIMIT 1;
  SELECT active INTO v_active
  FROM public.technician_company_assignments
  WHERE company_id = v_co_a AND technician_id = v_tech_a;
  IF NOT v_active THEN
    RAISE EXCEPTION 'TEST 3a FAIL: assignment not active after enable';
  END IF;
  SELECT COUNT(*) INTO v_count
  FROM public.audit_events
  WHERE company_id = v_co_a AND event_type = 'technician_company_enabled';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'TEST 3a FAIL: no technician_company_enabled audit event';
  END IF;
  RAISE NOTICE 'TEST 3a PASS: technician enabled, audit present';
END;
$$;

-- TEST 3b: Disable with no active orders — only facility cascade, no exception.
DO $$
DECLARE v_co_a uuid; v_fac uuid; v_tech_a uuid; v_active boolean; v_fac_count int;
BEGIN
  SELECT co_a, fac, tech_a INTO v_co_a, v_fac, v_tech_a FROM _t009 LIMIT 1;
  -- Assign a facility so we can verify it gets cleared.
  PERFORM public.admin_set_technician_facility(v_co_a, v_tech_a, v_fac, true);
  -- Disable (no active orders assigned yet).
  PERFORM public.admin_set_technician_company(v_co_a, v_tech_a, false);
  SELECT active INTO v_active
  FROM public.technician_company_assignments
  WHERE company_id = v_co_a AND technician_id = v_tech_a;
  IF v_active THEN
    RAISE EXCEPTION 'TEST 3b FAIL: company assignment still active after disable';
  END IF;
  SELECT COUNT(*) INTO v_fac_count
  FROM public.technician_facility_assignments
  WHERE company_id = v_co_a AND technician_id = v_tech_a AND active = true;
  IF v_fac_count > 0 THEN
    RAISE EXCEPTION 'TEST 3b FAIL: facility assignments not cleared on company disable';
  END IF;
  RAISE NOTICE 'TEST 3b PASS: disable with no orders cascades to facilities, no error';
  -- Re-enable for subsequent tests.
  PERFORM public.admin_set_technician_company(v_co_a, v_tech_a, true);
END;
$$;

-- TEST 3c: Disable while tech is on an in-progress order → P0001 (Criterion 5 corollary).
DO $$
DECLARE v_co_a uuid; v_tech_a uuid; v_ord_inprog uuid;
BEGIN
  SELECT co_a, tech_a, ord_inprog INTO v_co_a, v_tech_a, v_ord_inprog FROM _t009 LIMIT 1;
  -- Assign tech to the in-progress order.
  PERFORM public.admin_assign_order_technician(
    v_co_a, v_ord_inprog, v_tech_a, 'lead'::public.order_technician_role);
  -- Now try to disable the company assignment.
  PERFORM public.admin_set_technician_company(v_co_a, v_tech_a, false);
  RAISE EXCEPTION 'TEST 3c FAIL: should have raised P0001 (in-progress order)';
EXCEPTION
  WHEN SQLSTATE 'P0001' THEN
    RAISE NOTICE 'TEST 3c PASS: disable blocked by in-progress order (P0001)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 3c FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- Clean up the in-progress assignment as superuser so tech can be used in test 3d.
-- (DML is revoked from authenticated; must RESET ROLE to run as superuser.)
RESET ROLE;
DO $$
DECLARE v_tech_a uuid; v_ord_inprog uuid;
BEGIN
  SELECT tech_a, ord_inprog INTO v_tech_a, v_ord_inprog FROM _t009 LIMIT 1;
  UPDATE public.service_order_technicians
    SET active = false, removed_at = now()
  WHERE service_order_id = v_ord_inprog AND technician_id = v_tech_a AND active = true;
END;
$$;
SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000099","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

-- TEST 3d: Disable with a scheduled order and a completed order.
--   Scheduled assignment → soft-removed automatically.
--   Completed assignment → preserved unchanged (Criterion 5).

-- Setup: insert completed order assignment as superuser
-- (INSERT/UPDATE are revoked from authenticated; must RESET ROLE before direct DML).
RESET ROLE;
DO $$
DECLARE v_co_a uuid; v_tech_a uuid; v_ord_done uuid;
BEGIN
  SELECT co_a, tech_a, ord_done INTO v_co_a, v_tech_a, v_ord_done FROM _t009 LIMIT 1;
  INSERT INTO public.service_order_technicians
    (service_order_id, technician_id, company_id, role, active)
  VALUES (v_ord_done, v_tech_a, v_co_a, 'lead', true);
END;
$$;
SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000099","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

DO $$
DECLARE
  v_co_a    uuid; v_tech_a  uuid;
  v_ord_sched uuid; v_ord_done uuid;
  v_sched_active boolean; v_done_active boolean;
BEGIN
  SELECT co_a, tech_a, ord_sched, ord_done
  INTO v_co_a, v_tech_a, v_ord_sched, v_ord_done FROM _t009 LIMIT 1;

  -- Assign tech to scheduled order.
  PERFORM public.admin_assign_order_technician(
    v_co_a, v_ord_sched, v_tech_a, 'lead'::public.order_technician_role);

  -- Disable tech.
  PERFORM public.admin_set_technician_company(v_co_a, v_tech_a, false);

  -- Scheduled assignment must be soft-removed.
  SELECT active INTO v_sched_active
  FROM public.service_order_technicians
  WHERE service_order_id = v_ord_sched AND technician_id = v_tech_a
  ORDER BY assigned_at DESC LIMIT 1;
  IF v_sched_active IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'TEST 3d FAIL: scheduled order assignment not soft-removed on tech disable';
  END IF;

  -- Completed assignment must be preserved (active = true).
  SELECT active INTO v_done_active
  FROM public.service_order_technicians
  WHERE service_order_id = v_ord_done AND technician_id = v_tech_a;
  IF v_done_active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'TEST 3d FAIL: completed order assignment should not be touched on tech disable';
  END IF;

  RAISE NOTICE 'TEST 3d PASS: scheduled soft-removed, completed preserved (Criterion 5)';
  -- Re-enable for subsequent tests.
  PERFORM public.admin_set_technician_company(v_co_a, v_tech_a, true);
END;
$$;

-- ══════════════════════════════════════════════════════════════════
-- GROUP 4: Order assignment — soft-delete, re-assignment, history
-- ══════════════════════════════════════════════════════════════════

-- TEST 4a: Assign tech as lead → returns UUID, role correct, audit event (Criterion 1 baseline).
DO $$
DECLARE v_co_a uuid; v_tech_a uuid; v_ord_sched uuid;
        v_assign_id uuid; v_role text; v_count int;
BEGIN
  SELECT co_a, tech_a, ord_sched INTO v_co_a, v_tech_a, v_ord_sched FROM _t009 LIMIT 1;
  SELECT public.admin_assign_order_technician(
    v_co_a, v_ord_sched, v_tech_a, 'lead'::public.order_technician_role
  ) INTO v_assign_id;
  IF v_assign_id IS NULL THEN
    RAISE EXCEPTION 'TEST 4a FAIL: assign returned null';
  END IF;
  SELECT role INTO v_role FROM public.service_order_technicians WHERE id = v_assign_id;
  IF v_role <> 'lead' THEN
    RAISE EXCEPTION 'TEST 4a FAIL: expected role=lead, got %', v_role;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.audit_events
  WHERE company_id = v_co_a AND event_type = 'order_technician_assigned';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'TEST 4a FAIL: no order_technician_assigned audit event';
  END IF;
  RAISE NOTICE 'TEST 4a PASS: lead assigned %, audit present', v_assign_id;
END;
$$;

-- TEST 4b: Duplicate active assignment rejected (Criterion 2).
DO $$
DECLARE v_co_a uuid; v_tech_a uuid; v_ord_sched uuid;
BEGIN
  SELECT co_a, tech_a, ord_sched INTO v_co_a, v_tech_a, v_ord_sched FROM _t009 LIMIT 1;
  PERFORM public.admin_assign_order_technician(
    v_co_a, v_ord_sched, v_tech_a, 'support'::public.order_technician_role);
  RAISE EXCEPTION 'TEST 4b FAIL: should have raised P0001 (duplicate active)';
EXCEPTION
  WHEN SQLSTATE 'P0001' THEN
    RAISE NOTICE 'TEST 4b PASS: duplicate active assignment rejected (Criterion 2)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 4b FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 4c: Second active lead rejected (Criterion 3).
-- Setup: create second technician as superuser (INSERT revoked from authenticated).
RESET ROLE;
DO $$
DECLARE v_co_a uuid; v_tech2_id uuid;
BEGIN
  SELECT co_a INTO v_co_a FROM _t009 LIMIT 1;
  INSERT INTO public.technician_profiles (company_id, first_name, last_name, active)
  VALUES (v_co_a, 'Ana', 'Roldán', true) RETURNING id INTO v_tech2_id;
  CREATE TEMP TABLE _t009_tech2 (id uuid) ON COMMIT DROP;
  INSERT INTO _t009_tech2 VALUES (v_tech2_id);
END;
$$;
SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000099","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_co_a uuid; v_ord_sched uuid; v_tech2_id uuid;
BEGIN
  SELECT co_a, ord_sched INTO v_co_a, v_ord_sched FROM _t009 LIMIT 1;
  SELECT id INTO v_tech2_id FROM _t009_tech2 LIMIT 1;
  PERFORM public.admin_set_technician_company(v_co_a, v_tech2_id, true);
  PERFORM public.admin_assign_order_technician(
    v_co_a, v_ord_sched, v_tech2_id, 'lead'::public.order_technician_role);
  RAISE EXCEPTION 'TEST 4c FAIL: should have raised P0001 (duplicate lead)';
EXCEPTION
  WHEN SQLSTATE 'P0001' THEN
    RAISE NOTICE 'TEST 4c PASS: second active lead rejected (Criterion 3)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 4c FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 4d: Soft-remove — row still exists as inactive (Criterion 4), audit event present.
DO $$
DECLARE v_co_a uuid; v_tech_a uuid; v_ord_sched uuid;
        v_active boolean; v_removed_at timestamptz; v_count int;
BEGIN
  SELECT co_a, tech_a, ord_sched INTO v_co_a, v_tech_a, v_ord_sched FROM _t009 LIMIT 1;
  PERFORM public.admin_remove_order_technician(v_co_a, v_ord_sched, v_tech_a);
  -- Row must still exist (soft-delete, not physical delete).
  SELECT active, removed_at INTO v_active, v_removed_at
  FROM public.service_order_technicians
  WHERE service_order_id = v_ord_sched AND technician_id = v_tech_a
  ORDER BY assigned_at DESC LIMIT 1;
  IF v_active IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'TEST 4d FAIL: row was physically deleted or still active after soft-remove';
  END IF;
  IF v_removed_at IS NULL THEN
    RAISE EXCEPTION 'TEST 4d FAIL: removed_at not set after soft-remove';
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.audit_events
  WHERE company_id = v_co_a AND event_type = 'order_technician_removed';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'TEST 4d FAIL: no order_technician_removed audit event';
  END IF;
  RAISE NOTICE 'TEST 4d PASS: soft-remove sets active=false, removed_at set, audit present (Criterion 4)';
END;
$$;

-- TEST 4e: Re-assignment after soft-remove succeeds (Criterion 1 — the key scenario).
DO $$
DECLARE v_co_a uuid; v_tech_a uuid; v_ord_sched uuid;
        v_new_id uuid; v_active_count int; v_total_count int;
BEGIN
  SELECT co_a, tech_a, ord_sched INTO v_co_a, v_tech_a, v_ord_sched FROM _t009 LIMIT 1;
  -- Assign same tech again after soft-remove.
  SELECT public.admin_assign_order_technician(
    v_co_a, v_ord_sched, v_tech_a, 'lead'::public.order_technician_role
  ) INTO v_new_id;
  IF v_new_id IS NULL THEN
    RAISE EXCEPTION 'TEST 4e FAIL: re-assignment returned null';
  END IF;
  -- Exactly one active assignment.
  SELECT COUNT(*) INTO v_active_count
  FROM public.service_order_technicians
  WHERE service_order_id = v_ord_sched AND technician_id = v_tech_a AND active = true;
  IF v_active_count <> 1 THEN
    RAISE EXCEPTION 'TEST 4e FAIL: expected 1 active assignment, got %', v_active_count;
  END IF;
  RAISE NOTICE 'TEST 4e PASS: re-assignment after soft-remove succeeded (Criterion 1)';
END;
$$;

-- TEST 4f: History preserved — multiple rows exist (old inactive + new active) (Criterion 4).
DO $$
DECLARE v_ord_sched uuid; v_tech_a uuid; v_total_count int;
BEGIN
  SELECT ord_sched, tech_a INTO v_ord_sched, v_tech_a FROM _t009 LIMIT 1;
  SELECT COUNT(*) INTO v_total_count
  FROM public.service_order_technicians
  WHERE service_order_id = v_ord_sched AND technician_id = v_tech_a;
  IF v_total_count < 2 THEN
    RAISE EXCEPTION 'TEST 4f FAIL: expected ≥2 history rows, got % (old inactive + new active)',
      v_total_count;
  END IF;
  RAISE NOTICE 'TEST 4f PASS: % rows in history (Criterion 4)', v_total_count;
END;
$$;

-- TEST 4g: Remove already-removed (no active row) → P0002.
DO $$
DECLARE v_co_a uuid; v_tech_a uuid; v_ord_sched uuid;
BEGIN
  SELECT co_a, tech_a, ord_sched INTO v_co_a, v_tech_a, v_ord_sched FROM _t009 LIMIT 1;
  -- Remove the current active assignment first.
  PERFORM public.admin_remove_order_technician(v_co_a, v_ord_sched, v_tech_a);
  -- Remove again — should fail.
  PERFORM public.admin_remove_order_technician(v_co_a, v_ord_sched, v_tech_a);
  RAISE EXCEPTION 'TEST 4g FAIL: should have raised P0002 (no active assignment)';
EXCEPTION
  WHEN SQLSTATE 'P0002' THEN
    RAISE NOTICE 'TEST 4g PASS: second remove of same tech rejected (P0002)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 4g FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 4h: Inactive tech cannot be assigned (Criterion 6).
-- Setup: create un-enabled technician as superuser (INSERT revoked from authenticated).
RESET ROLE;
DO $$
DECLARE v_co_a uuid; v_invisible_id uuid;
BEGIN
  SELECT co_a INTO v_co_a FROM _t009 LIMIT 1;
  INSERT INTO public.technician_profiles (company_id, first_name, last_name, active)
  VALUES (v_co_a, 'Pedro', 'Invisible', true) RETURNING id INTO v_invisible_id;
  CREATE TEMP TABLE _t009_invisible (id uuid) ON COMMIT DROP;
  INSERT INTO _t009_invisible VALUES (v_invisible_id);
END;
$$;
SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000099","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_co_a uuid; v_ord_sched uuid; v_inactive_tech uuid;
BEGIN
  SELECT co_a, ord_sched INTO v_co_a, v_ord_sched FROM _t009 LIMIT 1;
  SELECT id INTO v_inactive_tech FROM _t009_invisible LIMIT 1;
  -- Do NOT call admin_set_technician_company → tech has no company assignment.
  PERFORM public.admin_assign_order_technician(
    v_co_a, v_ord_sched, v_inactive_tech, 'support'::public.order_technician_role);
  RAISE EXCEPTION 'TEST 4h FAIL: should have raised P0002 (tech not enabled)';
EXCEPTION
  WHEN SQLSTATE 'P0002' THEN
    RAISE NOTICE 'TEST 4h PASS: not-enabled tech assignment rejected (Criterion 6)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 4h FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

RESET ROLE;

-- ══════════════════════════════════════════════════════════════════
-- GROUP 5: Status guards — no assign/remove on completed or cancelled
-- (product decision from ChatGPT review, 2026-11-23)
-- ══════════════════════════════════════════════════════════════════

-- Setup: create a cancelled order as superuser.
DO $$
DECLARE v_co_a uuid; v_fac uuid; v_gate uuid; v_ord_cancelled uuid;
BEGIN
  SELECT co_a, fac, gate INTO v_co_a, v_fac, v_gate FROM _t009 LIMIT 1;
  INSERT INTO public.service_orders (company_id, facility_id, gate_id, service_type, status,
                                     scheduled_start, scheduled_end)
  VALUES (v_co_a, v_fac, v_gate, 'corrective', 'cancelled',
          now() - interval '3 days', now() - interval '3 days' + interval '2 hours')
  RETURNING id INTO v_ord_cancelled;
  CREATE TEMP TABLE _t009_cancelled (id uuid) ON COMMIT DROP;
  INSERT INTO _t009_cancelled VALUES (v_ord_cancelled);
END;
$$;
SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000099","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

-- TEST 5a: Cannot assign to a completed order → P0001.
-- tech2 is enabled for co_a (from test 4c setup); ord_done is completed.
DO $$
DECLARE v_co_a uuid; v_ord_done uuid; v_tech2_id uuid;
BEGIN
  SELECT co_a, ord_done INTO v_co_a, v_ord_done FROM _t009 LIMIT 1;
  SELECT id INTO v_tech2_id FROM _t009_tech2 LIMIT 1;
  PERFORM public.admin_assign_order_technician(
    v_co_a, v_ord_done, v_tech2_id, 'support'::public.order_technician_role);
  RAISE EXCEPTION 'TEST 5a FAIL: should have raised P0001 (completed order)';
EXCEPTION
  WHEN SQLSTATE 'P0001' THEN
    RAISE NOTICE 'TEST 5a PASS: assign to completed order rejected (P0001)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 5a FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 5b: Cannot assign to a cancelled order → P0001.
DO $$
DECLARE v_co_a uuid; v_tech_a uuid; v_ord_cancelled uuid;
BEGIN
  SELECT co_a, tech_a INTO v_co_a, v_tech_a FROM _t009 LIMIT 1;
  SELECT id INTO v_ord_cancelled FROM _t009_cancelled LIMIT 1;
  PERFORM public.admin_assign_order_technician(
    v_co_a, v_ord_cancelled, v_tech_a, 'lead'::public.order_technician_role);
  RAISE EXCEPTION 'TEST 5b FAIL: should have raised P0001 (cancelled order)';
EXCEPTION
  WHEN SQLSTATE 'P0001' THEN
    RAISE NOTICE 'TEST 5b PASS: assign to cancelled order rejected (P0001)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 5b FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 5c: Cannot remove from a completed order → P0001.
-- tech_a is active in ord_done (assigned in test 3d, never removed since).
DO $$
DECLARE v_co_a uuid; v_tech_a uuid; v_ord_done uuid;
BEGIN
  SELECT co_a, tech_a, ord_done INTO v_co_a, v_tech_a, v_ord_done FROM _t009 LIMIT 1;
  PERFORM public.admin_remove_order_technician(v_co_a, v_ord_done, v_tech_a);
  RAISE EXCEPTION 'TEST 5c FAIL: should have raised P0001 (completed order)';
EXCEPTION
  WHEN SQLSTATE 'P0001' THEN
    RAISE NOTICE 'TEST 5c PASS: remove from completed order rejected (P0001)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 5c FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

-- TEST 5d: Cannot remove from a cancelled order → P0001.
-- Setup: insert tech_a into the cancelled order as superuser (bypassing RPC guard).
RESET ROLE;
DO $$
DECLARE v_co_a uuid; v_tech_a uuid; v_ord_cancelled uuid;
BEGIN
  SELECT co_a, tech_a INTO v_co_a, v_tech_a FROM _t009 LIMIT 1;
  SELECT id INTO v_ord_cancelled FROM _t009_cancelled LIMIT 1;
  INSERT INTO public.service_order_technicians (service_order_id, technician_id, company_id, role, active)
  VALUES (v_ord_cancelled, v_tech_a, v_co_a, 'lead', true);
END;
$$;
SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000099","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_co_a uuid; v_tech_a uuid; v_ord_cancelled uuid;
BEGIN
  SELECT co_a, tech_a INTO v_co_a, v_tech_a FROM _t009 LIMIT 1;
  SELECT id INTO v_ord_cancelled FROM _t009_cancelled LIMIT 1;
  PERFORM public.admin_remove_order_technician(v_co_a, v_ord_cancelled, v_tech_a);
  RAISE EXCEPTION 'TEST 5d FAIL: should have raised P0001 (cancelled order)';
EXCEPTION
  WHEN SQLSTATE 'P0001' THEN
    RAISE NOTICE 'TEST 5d PASS: remove from cancelled order rejected (P0001)';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'TEST 5d FAIL: unexpected % — %', SQLSTATE, SQLERRM;
END;
$$;

RESET ROLE;

-- ══════════════════════════════════════════════════════════════════
-- ROLLBACK: all test data discarded — no persistent changes
-- ══════════════════════════════════════════════════════════════════
ROLLBACK;

-- ══════════════════════════════════════════════════════════════════
-- MANUAL TESTS (require real user JWTs, run in Supabase Policies Tester)
-- ══════════════════════════════════════════════════════════════════
-- M-1. Admin of company A queries service_order_technicians of company B
--      → Expected: 0 rows (RLS isolates by company_id).
-- M-2. Technician role queries technician_company_assignments
--      → Expected: 0 rows (RLS allows only 'admin' role).
-- M-3. Admin of company A tries admin_set_technician_company for tech from company B
--      → Expected: 42501 (cross-company requires platform admin).
-- M-4. Platform admin enables tech from company B for company A, then company A admin
--      tries to disable it → Expected: succeeds (admin can manage the cross-company
--      assignment once it's been created by platform admin).
-- M-5. Concurrency: two sessions simultaneously assign the same tech as lead
--      to the same order. The partial unique index must let one through and
--      reject the other with 23505 (or P0001 if one hits the guard first).
