-- test_migration_019_020.sql
-- Integration tests for migrations 019 (control_result enum) and 020 (inspection_repairs +
-- corrected_note + strict idempotency C1).
-- Wraps everything in BEGIN...ROLLBACK — no persistent changes.
--
-- Coverage:
--   A1 — same-state note correction accepted; empty/no-change correction rejected
--   B  — corrected_note persists; current_note reflects it; inspection_controls.note immutable
--   C1 — strict idempotency: same key+payload → return; same key+different payload → conflict
--   T  — transition matrix: fault→resolved, resolved→fault, pre-existing via control RPC → rejected
--   P  — partial-failure recovery: control committed, repair missing → repair inserted on retry
--
-- Requires migrations 001–020 applied.
-- Expected output: a series of NOTICE lines "TEST Xa PASS: ..."
--
-- ══════════════════════════════════════════════════════════════════════════════
-- FALSE POSITIVE / FALSE FAIL RISK REGISTER
-- ══════════════════════════════════════════════════════════════════════════════
--
-- ENV-1 (environment): Requires Supabase-compatible PostgreSQL with the
--   'authenticated' role and auth.uid() function.  Run only via:
--     supabase db execute --file supabase/tests/test_migration_019_020.sql
--   or in the Supabase Cloud SQL Editor with the postgres role.
--
-- ENV-2 (superuser for auth.users): INSERTs into auth.users require the
--   postgres role.  ON CONFLICT DO NOTHING guards against interrupted prior runs.
--
-- ENV-3 (migration dependency): All 20 migrations must be applied.  If migration
--   020 is not applied, all tests fail because inspection_repairs does not exist.
--   If migration 019 is not applied, enum values fault/critical/resolved/partial
--   do not exist and the tests fail at CAST time.
--
-- GUC-1 (request.jwt.claims lifetime): SET LOCAL sets the GUC for the duration
--   of the transaction.  After RESET ROLE at line ~P1-setup, the claims still
--   hold the technician's JWT for any RPC call that reads auth.uid() — this is
--   intentional for the P1 partial-failure test.
--
-- C1-1 (hardcoded idempotency keys): Tests use deterministic UUIDs in the
--   '00000000-0000-0000-00xx-000000000NNN' range.  Collision with real data is
--   astronomically unlikely inside a ROLLBACK, but the ROLLBACK makes it safe
--   regardless.
--
-- RACE-1 (two-session ON CONFLICT): The race-loser path for concurrent first-save
--   cannot be tested in a single ROLLBACK transaction.  See GROUP R documentation
--   below for the manual two-session procedure.
--
-- ERRCODE-1 (C1b/C1d/A1c/A1d): These tests catch '22023' via WHEN OTHERS and
--   inspect SQLERRM.  If a future RPC changes its error message wording, update
--   the LIKE patterns here — the error must still fire, but the message may differ.
-- ══════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── SETUP: auth users ─────────────────────────────────────────────────────────
-- U99 = platform admin, U98 = technician
INSERT INTO auth.users (
  id, email, email_confirmed_at, created_at, updated_at,
  aud, role, raw_app_meta_data, raw_user_meta_data, encrypted_password
) VALUES
  ('00000000-0000-0000-0000-000000000099',
   '_test_padmin_020@constelmec.test',
   now(), now(), now(), 'authenticated', 'authenticated',
   '{"provider":"email","providers":["email"]}', '{}', ''),
  ('00000000-0000-0000-0000-000000000098',
   '_test_tech_020@constelmec.test',
   now(), now(), now(), 'authenticated', 'authenticated',
   '{"provider":"email","providers":["email"]}', '{}', '')
ON CONFLICT (id) DO NOTHING;

INSERT INTO app_private.platform_admins (user_id, granted_by)
VALUES ('00000000-0000-0000-0000-000000000099', 'test_suite_020')
ON CONFLICT (user_id) DO NOTHING;

-- ── Admin creates company + facility + gate ────────────────────────────────────
SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000099","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

DO $$
DECLARE
  v_co   uuid;
  v_fac  uuid;
  v_gate uuid;
BEGIN
  SELECT public.admin_create_company('_test_co_020') INTO v_co;
  SELECT public.admin_create_facility(v_co, 'Planta 020') INTO v_fac;
  SELECT public.admin_create_gate(v_co, v_fac, 'P20-01', 'Gate 020') INTO v_gate;

  CREATE TEMP TABLE _t020 (
    co   uuid, fac uuid, gate uuid,
    tech_id uuid,
    ord_id  uuid,
    sot_id  uuid,
    vis_id  uuid
  ) ON COMMIT DROP;
  INSERT INTO _t020 (co, fac, gate) VALUES (v_co, v_fac, v_gate);
  RAISE NOTICE 'SETUP: co=%, gate=%', v_co, v_gate;
END;
$$;

RESET ROLE;

-- ── Superuser: technician profile + membership + order + visit + assignment ────
DO $$
DECLARE
  v_co   uuid; v_fac uuid; v_gate uuid;
  v_tech uuid; v_ord uuid; v_vis uuid; v_sot uuid;
BEGIN
  SELECT co, fac, gate INTO v_co, v_fac, v_gate FROM _t020 LIMIT 1;

  INSERT INTO public.technician_profiles (company_id, user_id, first_name, last_name, specialty, active)
  VALUES (v_co, '00000000-0000-0000-0000-000000000098', 'Tech', 'Test', 'Electrical', true)
  RETURNING id INTO v_tech;

  INSERT INTO public.memberships (company_id, user_id, role)
  VALUES (v_co, '00000000-0000-0000-0000-000000000098', 'technician')
  ON CONFLICT DO NOTHING;

  -- Also valid under migration 021, where the order assignment is history only.
  INSERT INTO public.technician_company_assignments (company_id, technician_id, active)
  VALUES (v_co, v_tech, true);

  -- Visit must exist before the service order references it
  INSERT INTO public.visits (company_id, gate_id, status, responsible_user_id, started_at)
  VALUES (v_co, v_gate, 'in_progress', '00000000-0000-0000-0000-000000000098', now())
  RETURNING id INTO v_vis;

  INSERT INTO public.service_orders (
    company_id, facility_id, gate_id, service_type, status,
    inspection_visit_id, scheduled_start, scheduled_end
  ) VALUES (
    v_co, v_fac, v_gate, 'preventive', 'in_progress',
    v_vis, now(), now() + interval '2 hours'
  ) RETURNING id INTO v_ord;

  INSERT INTO public.service_order_technicians (service_order_id, technician_id, company_id, role)
  VALUES (v_ord, v_tech, v_co, 'lead')
  RETURNING id INTO v_sot;

  UPDATE _t020 SET tech_id=v_tech, ord_id=v_ord, sot_id=v_sot, vis_id=v_vis;
  RAISE NOTICE 'SETUP: tech=%, ord=%, vis=%', v_tech, v_ord, v_vis;
END;
$$;

-- ── Switch to technician session ───────────────────────────────────────────────
SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000098","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

-- ══════════════════════════════════════════════════════════════════════════════
-- GROUP A: Same-state note correction (A1)
-- ══════════════════════════════════════════════════════════════════════════════

-- TEST A1a: First save as fault — control created with original note
DO $$
DECLARE v_ord uuid; v_vis uuid; v_id uuid;
BEGIN
  SELECT ord_id, vis_id INTO v_ord, v_vis FROM _t020 LIMIT 1;
  SELECT public.tech_save_pilot_control(
    v_ord, v_vis, 'ctrl_a', 'Motor y transmisión',
    'fault'::public.control_result,
    'Ruido extraño al abrir y cerrar el portón completo'
  ) INTO v_id;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'TEST A1a FAIL: null control id returned';
  END IF;
  RAISE NOTICE 'TEST A1a PASS: first save as fault, id=%', v_id;
END;
$$;

-- TEST A1b: Same-state fault→fault correction with updated note — must succeed
DO $$
DECLARE v_ord uuid; v_vis uuid; v_id uuid;
BEGIN
  SELECT ord_id, vis_id INTO v_ord, v_vis FROM _t020 LIMIT 1;
  SELECT public.tech_save_pilot_correction(
    v_ord, v_vis, 'ctrl_a',
    'fault'::public.control_result,
    'El técnico identificó el origen del ruido con más detalle',
    '00000000-0000-0000-00a1-000000000001'::uuid,
    'Correa desgastada en polea del motor derecho, desgaste sobre límite permitido'
  ) INTO v_id;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'TEST A1b FAIL: null control id returned';
  END IF;
  RAISE NOTICE 'TEST A1b PASS: same-state correction with updated note accepted, id=%', v_id;
END;
$$;

-- TEST A1c: No-change correction (same result, same current note, no repair) — must reject
DO $$
DECLARE v_ord uuid; v_vis uuid; v_id uuid;
BEGIN
  SELECT ord_id, vis_id INTO v_ord, v_vis FROM _t020 LIMIT 1;
  BEGIN
    SELECT public.tech_save_pilot_correction(
      v_ord, v_vis, 'ctrl_a',
      'fault'::public.control_result,
      'Mismo resultado, misma observación vigente, debe rechazarse esto',
      '00000000-0000-0000-00a1-000000000002'::uuid,
      'Correa desgastada en polea del motor derecho, desgaste sobre límite permitido'
    ) INTO v_id;
    RAISE EXCEPTION 'TEST A1c FAIL: expected rejection for no-change correction, got id=%', v_id;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%No hay cambios%' THEN
      RAISE NOTICE 'TEST A1c PASS: no-change correction correctly rejected (%)', SQLERRM;
    ELSE
      RAISE EXCEPTION 'TEST A1c FAIL: wrong error: %', SQLERRM;
    END IF;
  END;
END;
$$;

-- TEST A1d: Fault→fault correction with note below 10 chars — must reject
DO $$
DECLARE v_ord uuid; v_vis uuid; v_id uuid;
BEGIN
  SELECT ord_id, vis_id INTO v_ord, v_vis FROM _t020 LIMIT 1;
  BEGIN
    SELECT public.tech_save_pilot_correction(
      v_ord, v_vis, 'ctrl_a',
      'fault'::public.control_result,
      'Motivo válido con más de diez caracteres aquí completo',
      '00000000-0000-0000-00a1-000000000003'::uuid,
      'corta'
    ) INTO v_id;
    RAISE EXCEPTION 'TEST A1d FAIL: expected rejection for short note on fault, got id=%', v_id;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%10 caracteres%' OR SQLERRM LIKE '%falla%' THEN
      RAISE NOTICE 'TEST A1d PASS: short note on fault correctly rejected (%)', SQLERRM;
    ELSE
      RAISE EXCEPTION 'TEST A1d FAIL: wrong error: %', SQLERRM;
    END IF;
  END;
END;
$$;

-- ══════════════════════════════════════════════════════════════════════════════
-- GROUP B: Observation persistence
-- ══════════════════════════════════════════════════════════════════════════════

-- TEST B1: tech_get_pilot_progress returns current_note = corrected_note, note = original
DO $$
DECLARE
  v_ord uuid;
  v_data jsonb;
  v_ctrl jsonb;
  v_current_note text;
  v_original_note text;
BEGIN
  SELECT ord_id INTO v_ord FROM _t020 LIMIT 1;
  SELECT public.tech_get_pilot_progress(v_ord) INTO v_data;
  SELECT c INTO v_ctrl
  FROM jsonb_array_elements(v_data->'controls') c
  WHERE c->>'key' = 'ctrl_a';
  v_current_note  := v_ctrl->>'current_note';
  v_original_note := v_ctrl->>'note';
  IF v_current_note IS DISTINCT FROM
     'Correa desgastada en polea del motor derecho, desgaste sobre límite permitido' THEN
    RAISE EXCEPTION 'TEST B1 FAIL: current_note=% (expected corrected note)', v_current_note;
  END IF;
  IF v_original_note IS DISTINCT FROM 'Ruido extraño al abrir y cerrar el portón completo' THEN
    RAISE EXCEPTION 'TEST B1 FAIL: original note changed: % (must be immutable)', v_original_note;
  END IF;
  RAISE NOTICE 'TEST B1 PASS: current_note reflects corrected_note; original note immutable';
END;
$$;

-- TEST B2: Second correction updates current_note to the latest corrected_note
DO $$
DECLARE
  v_ord uuid; v_vis uuid;
  v_data jsonb;
  v_current_note text;
BEGIN
  SELECT ord_id, vis_id INTO v_ord, v_vis FROM _t020 LIMIT 1;
  PERFORM public.tech_save_pilot_correction(
    v_ord, v_vis, 'ctrl_a',
    'fault'::public.control_result,
    'Diagnóstico refinado con medición exacta del desgaste en taller',
    '00000000-0000-0000-00b2-000000000001'::uuid,
    'Correa desgastada en polea del motor derecho, desgaste de tres milímetros sobre el límite permitido'
  );
  SELECT public.tech_get_pilot_progress(v_ord) INTO v_data;
  SELECT c->>'current_note' INTO v_current_note
  FROM jsonb_array_elements(v_data->'controls') c
  WHERE c->>'key' = 'ctrl_a';
  IF v_current_note IS DISTINCT FROM
     'Correa desgastada en polea del motor derecho, desgaste de tres milímetros sobre el límite permitido' THEN
    RAISE EXCEPTION 'TEST B2 FAIL: current_note not updated to latest correction: %', v_current_note;
  END IF;
  RAISE NOTICE 'TEST B2 PASS: current_note reflects the latest corrected_note after two corrections';
END;
$$;

-- ══════════════════════════════════════════════════════════════════════════════
-- GROUP C: Strict idempotency (C1) — corrections
-- ══════════════════════════════════════════════════════════════════════════════

-- Setup: a fresh control for C1 correction tests
DO $$
DECLARE v_ord uuid; v_vis uuid; v_id uuid;
BEGIN
  SELECT ord_id, vis_id INTO v_ord, v_vis FROM _t020 LIMIT 1;
  SELECT public.tech_save_pilot_control(
    v_ord, v_vis, 'ctrl_c', 'Sistema eléctrico',
    'fault'::public.control_result,
    'Falla eléctrica en panel de control principal del portón trasero'
  ) INTO v_id;
  RAISE NOTICE 'SETUP C: ctrl_c created as fault, id=%', v_id;
END;
$$;

-- TEST C1a: Same idempotency_key + same payload → returns same id, one correction row
DO $$
DECLARE
  v_ord  uuid; v_vis uuid;
  v_id1  uuid; v_id2 uuid;
  v_key  uuid := '00000000-0000-0000-00c1-000000000001'::uuid;
  v_count int;
BEGIN
  SELECT ord_id, vis_id INTO v_ord, v_vis FROM _t020 LIMIT 1;
  SELECT public.tech_save_pilot_correction(
    v_ord, v_vis, 'ctrl_c',
    'fault'::public.control_result,
    'Primer motivo de corrección válido y detallado para test idempotencia',
    v_key,
    'Interruptor principal quemado en posición tres del panel de distribución'
  ) INTO v_id1;
  -- Identical retry with same idempotency key
  SELECT public.tech_save_pilot_correction(
    v_ord, v_vis, 'ctrl_c',
    'fault'::public.control_result,
    'Primer motivo de corrección válido y detallado para test idempotencia',
    v_key,
    'Interruptor principal quemado en posición tres del panel de distribución'
  ) INTO v_id2;
  IF v_id1 IS DISTINCT FROM v_id2 THEN
    RAISE EXCEPTION 'TEST C1a FAIL: different ids on retry: % vs %', v_id1, v_id2;
  END IF;
  SELECT count(*) INTO v_count
  FROM public.inspection_corrections cx
  JOIN public.inspection_controls ic ON ic.id=cx.inspection_control_id
  WHERE ic.control_key='ctrl_c' AND cx.idempotency_key=v_key;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'TEST C1a FAIL: expected 1 correction row, found %', v_count;
  END IF;
  RAISE NOTICE 'TEST C1a PASS: idempotent retry returns same id, no duplicate correction row';
END;
$$;

-- TEST C1b: Same idempotency_key + different corrected_note → conflict error
DO $$
DECLARE
  v_ord uuid; v_vis uuid; v_id uuid;
  v_key uuid := '00000000-0000-0000-00c1-000000000002'::uuid;
BEGIN
  SELECT ord_id, vis_id INTO v_ord, v_vis FROM _t020 LIMIT 1;
  SELECT public.tech_save_pilot_correction(
    v_ord, v_vis, 'ctrl_c',
    'fault'::public.control_result,
    'Segundo motivo de corrección completamente válido y verificado',
    v_key,
    'Cable rojo desconectado en bornera número cuatro del tablero eléctrico'
  ) INTO v_id;
  BEGIN
    SELECT public.tech_save_pilot_correction(
      v_ord, v_vis, 'ctrl_c',
      'fault'::public.control_result,
      'Segundo motivo de corrección completamente válido y verificado',
      v_key,
      'Cable azul desconectado en bornera número cinco del tablero eléctrico'
    ) INTO v_id;
    RAISE EXCEPTION 'TEST C1b FAIL: expected conflict for different payload with same key';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%duplicada%' OR SQLERRM LIKE '%distintos%' THEN
      RAISE NOTICE 'TEST C1b PASS: same key different payload correctly rejected (%)', SQLERRM;
    ELSE
      RAISE EXCEPTION 'TEST C1b FAIL: wrong error: %', SQLERRM;
    END IF;
  END;
END;
$$;

-- ══════════════════════════════════════════════════════════════════════════════
-- GROUP C2: Strict idempotency (C1) — first-save with repair
-- ══════════════════════════════════════════════════════════════════════════════

-- TEST C2a: Same repair idempotency_key + same payload → one repair row
DO $$
DECLARE
  v_ord  uuid; v_vis uuid;
  v_id1  uuid; v_id2 uuid;
  v_rkey uuid := '00000000-0000-0000-00c2-000000000001'::uuid;
  v_count int;
BEGIN
  SELECT ord_id, vis_id INTO v_ord, v_vis FROM _t020 LIMIT 1;
  SELECT public.tech_save_pilot_control(
    v_ord, v_vis, 'ctrl_c2a', 'Sensor de presencia',
    'resolved'::public.control_result,
    NULL,
    jsonb_build_object(
      'idempotency_key', v_rkey,
      'problem_found',   'Sensor de presencia desalineado en carril superior izquierdo',
      'intervention',    'Realineación del sensor con ajuste de tornillos de fijación lateral',
      'verification',    'Sensor detecta vehículo correctamente en diez pruebas de paso consecutivas'
    )
  ) INTO v_id1;
  -- Identical retry
  SELECT public.tech_save_pilot_control(
    v_ord, v_vis, 'ctrl_c2a', 'Sensor de presencia',
    'resolved'::public.control_result,
    NULL,
    jsonb_build_object(
      'idempotency_key', v_rkey,
      'problem_found',   'Sensor de presencia desalineado en carril superior izquierdo',
      'intervention',    'Realineación del sensor con ajuste de tornillos de fijación lateral',
      'verification',    'Sensor detecta vehículo correctamente en diez pruebas de paso consecutivas'
    )
  ) INTO v_id2;
  IF v_id1 IS DISTINCT FROM v_id2 THEN
    RAISE EXCEPTION 'TEST C2a FAIL: different ids on retry: % vs %', v_id1, v_id2;
  END IF;
  SELECT count(*) INTO v_count FROM public.inspection_repairs WHERE idempotency_key=v_rkey;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'TEST C2a FAIL: expected 1 repair row, found %', v_count;
  END IF;
  RAISE NOTICE 'TEST C2a PASS: first-save repair idempotency works, one repair row';
END;
$$;

-- TEST C2b: Same repair key + different problem_found → conflict error
DO $$
DECLARE
  v_ord uuid; v_vis uuid; v_id uuid;
  v_rkey uuid := '00000000-0000-0000-00c2-000000000002'::uuid;
BEGIN
  SELECT ord_id, vis_id INTO v_ord, v_vis FROM _t020 LIMIT 1;
  SELECT public.tech_save_pilot_control(
    v_ord, v_vis, 'ctrl_c2b', 'Sistema hidráulico',
    'resolved'::public.control_result,
    NULL,
    jsonb_build_object(
      'idempotency_key', v_rkey,
      'problem_found',   'Fuga de aceite en cilindro principal del brazo operador',
      'intervention',    'Reemplazo de sellos hidráulicos en cilindro principal del brazo',
      'verification',    'Sin fuga tras ciclo completo de diez aperturas y cierres consecutivas'
    )
  ) INTO v_id;
  BEGIN
    SELECT public.tech_save_pilot_control(
      v_ord, v_vis, 'ctrl_c2b', 'Sistema hidráulico',
      'resolved'::public.control_result,
      NULL,
      jsonb_build_object(
        'idempotency_key', v_rkey,
        'problem_found',   'Fuga de aceite en cilindro secundario del brazo operador',
        'intervention',    'Reemplazo de sellos hidráulicos en cilindro principal del brazo',
        'verification',    'Sin fuga tras ciclo completo de diez aperturas y cierres consecutivas'
      )
    ) INTO v_id;
    RAISE EXCEPTION 'TEST C2b FAIL: expected conflict for different repair payload with same key';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%duplicada%' OR SQLERRM LIKE '%distintos%' THEN
      RAISE NOTICE 'TEST C2b PASS: repair key collision with different payload rejected (%)', SQLERRM;
    ELSE
      RAISE EXCEPTION 'TEST C2b FAIL: wrong error: %', SQLERRM;
    END IF;
  END;
END;
$$;

-- ══════════════════════════════════════════════════════════════════════════════
-- GROUP T: Transition matrix
-- ══════════════════════════════════════════════════════════════════════════════

-- Setup: control for transitions (fault initial)
DO $$
DECLARE v_ord uuid; v_vis uuid; v_id uuid;
BEGIN
  SELECT ord_id, vis_id INTO v_ord, v_vis FROM _t020 LIMIT 1;
  SELECT public.tech_save_pilot_control(
    v_ord, v_vis, 'ctrl_t', 'Mecanismo de cierre',
    'fault'::public.control_result,
    'Mecanismo de cierre no llega al tope final con fuerza suficiente'
  ) INTO v_id;
  RAISE NOTICE 'SETUP T: ctrl_t created as fault, id=%', v_id;
END;
$$;

-- TEST T1: fault → resolved with repair (via correction RPC)
DO $$
DECLARE v_ord uuid; v_vis uuid; v_id uuid;
BEGIN
  SELECT ord_id, vis_id INTO v_ord, v_vis FROM _t020 LIMIT 1;
  SELECT public.tech_save_pilot_correction(
    v_ord, v_vis, 'ctrl_t',
    'resolved'::public.control_result,
    'Reparación completa del mecanismo de cierre verificada con éxito total',
    '00000000-0000-0000-01a1-000000000001'::uuid,
    NULL,
    jsonb_build_object(
      'idempotency_key', '00000000-0000-0000-01a1-000000000002'::uuid,
      'problem_found',   'Resorte de retorno del mecanismo de cierre roto por fatiga de material',
      'intervention',    'Reemplazo de resorte de retorno y lubricación de guías del mecanismo',
      'verification',    'Cierre completo al tope con fuerza normal en diez ciclos consecutivos'
    )
  ) INTO v_id;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'TEST T1 FAIL: null id returned';
  END IF;
  RAISE NOTICE 'TEST T1 PASS: fault→resolved via correction accepted, id=%', v_id;
END;
$$;

-- TEST T2: resolved → fault (via correction RPC, no repair, with updated note)
DO $$
DECLARE v_ord uuid; v_vis uuid; v_id uuid;
BEGIN
  SELECT ord_id, vis_id INTO v_ord, v_vis FROM _t020 LIMIT 1;
  SELECT public.tech_save_pilot_correction(
    v_ord, v_vis, 'ctrl_t',
    'fault'::public.control_result,
    'Reparación previa resultó insuficiente bajo carga real de tráfico pesado',
    '00000000-0000-0000-01a2-000000000001'::uuid,
    'Falla reaparece bajo carga de tráfico pesado con ciclos frecuentes de operación real'
  ) INTO v_id;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'TEST T2 FAIL: null id returned';
  END IF;
  RAISE NOTICE 'TEST T2 PASS: resolved→fault via correction accepted, id=%', v_id;
END;
$$;

-- TEST T3: attempt to modify pre-existing control via tech_save_pilot_control → rejected
DO $$
DECLARE v_ord uuid; v_vis uuid; v_id uuid;
BEGIN
  SELECT ord_id, vis_id INTO v_ord, v_vis FROM _t020 LIMIT 1;
  BEGIN
    SELECT public.tech_save_pilot_control(
      v_ord, v_vis, 'ctrl_t', 'Mecanismo de cierre',
      'ok'::public.control_result,
      NULL
    ) INTO v_id;
    RAISE EXCEPTION 'TEST T3 FAIL: expected rejection for modifying pre-existing via control RPC, got %', v_id;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%corrección%' OR SQLERRM LIKE '%ya guardado%' THEN
      RAISE NOTICE 'TEST T3 PASS: pre-existing control modification via control RPC rejected (%)', SQLERRM;
    ELSE
      RAISE EXCEPTION 'TEST T3 FAIL: wrong error: %', SQLERRM;
    END IF;
  END;
END;
$$;

-- TEST T4: Idempotent double-submit of original first save (same result + note) → accepted
DO $$
DECLARE v_ord uuid; v_vis uuid; v_id uuid;
BEGIN
  SELECT ord_id, vis_id INTO v_ord, v_vis FROM _t020 LIMIT 1;
  SELECT public.tech_save_pilot_control(
    v_ord, v_vis, 'ctrl_a', 'Motor y transmisión',
    'fault'::public.control_result,
    'Ruido extraño al abrir y cerrar el portón completo'
  ) INTO v_id;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'TEST T4 FAIL: null id returned on idempotent retry';
  END IF;
  RAISE NOTICE 'TEST T4 PASS: idempotent double-submit of first save accepted, id=%', v_id;
END;
$$;

-- ══════════════════════════════════════════════════════════════════════════════
-- GROUP P: Partial-failure recovery
-- (control committed, repair insert failed on prior attempt)
-- ══════════════════════════════════════════════════════════════════════════════

-- TEST P1: Control exists but repair row is missing → RPC inserts the missing repair
-- Simulate partial failure by inserting the control directly (superuser), then calling
-- the control RPC as the technician — the recovery leg should insert the repair.

RESET ROLE;

DO $$
DECLARE
  v_co   uuid; v_vis uuid;
BEGIN
  SELECT co, vis_id INTO v_co, v_vis FROM _t020 LIMIT 1;
  -- Simulate a committed control row with no corresponding repair (partial failure)
  INSERT INTO public.inspection_controls (company_id, visit_id, control_key, control_label, result, note)
  VALUES (v_co, v_vis, 'ctrl_p1', 'Sensor de acceso principal',
          'resolved'::public.control_result, NULL);
END;
$$;

-- Restore technician session
SET LOCAL "request.jwt.claims" = '{"sub":"00000000-0000-0000-0000-000000000098","aud":"authenticated"}';
SET LOCAL "request.jwt.aud" = 'authenticated';
SET LOCAL ROLE authenticated;

DO $$
DECLARE
  v_ord  uuid; v_vis uuid;
  v_rkey uuid := '00000000-0000-0000-01b1-000000000001'::uuid;
  v_count int;
BEGIN
  SELECT ord_id, vis_id INTO v_ord, v_vis FROM _t020 LIMIT 1;
  -- RPC finds pre-existing control + repair key not found → partial-failure recovery
  PERFORM public.tech_save_pilot_control(
    v_ord, v_vis, 'ctrl_p1', 'Sensor de acceso principal',
    'resolved'::public.control_result,
    NULL,
    jsonb_build_object(
      'idempotency_key', v_rkey,
      'problem_found',   'Sensor de acceso principal sin respuesta a credencial activa del vehículo',
      'intervention',    'Reemplazo del módulo de lectura y actualización del firmware de acceso',
      'verification',    'Acceso verificado con cinco credenciales distintas sin fallo alguno registrado'
    )
  );
  SELECT count(*) INTO v_count FROM public.inspection_repairs WHERE idempotency_key=v_rkey;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'TEST P1 FAIL: expected 1 repair row after recovery, found %', v_count;
  END IF;
  RAISE NOTICE 'TEST P1 PASS: partial-failure recovery inserts missing repair row (count=%)', v_count;
END;
$$;

-- TEST P2: Idempotent retry of P1 recovery call → still one repair row
DO $$
DECLARE
  v_ord  uuid; v_vis uuid;
  v_rkey uuid := '00000000-0000-0000-01b1-000000000001'::uuid;
  v_count int;
BEGIN
  SELECT ord_id, vis_id INTO v_ord, v_vis FROM _t020 LIMIT 1;
  PERFORM public.tech_save_pilot_control(
    v_ord, v_vis, 'ctrl_p1', 'Sensor de acceso principal',
    'resolved'::public.control_result,
    NULL,
    jsonb_build_object(
      'idempotency_key', v_rkey,
      'problem_found',   'Sensor de acceso principal sin respuesta a credencial activa del vehículo',
      'intervention',    'Reemplazo del módulo de lectura y actualización del firmware de acceso',
      'verification',    'Acceso verificado con cinco credenciales distintas sin fallo alguno registrado'
    )
  );
  SELECT count(*) INTO v_count FROM public.inspection_repairs WHERE idempotency_key=v_rkey;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'TEST P2 FAIL: expected 1 repair row after double recovery, found %', v_count;
  END IF;
  RAISE NOTICE 'TEST P2 PASS: idempotent recovery retry leaves one repair row (count=%)', v_count;
END;
$$;

-- ══════════════════════════════════════════════════════════════════════════════
-- RISK REGISTER: Race-loser concurrency (GROUP R — two-session procedure)
-- ══════════════════════════════════════════════════════════════════════════════
-- The ON CONFLICT DO NOTHING race-loser path in both RPCs cannot be exercised
-- deterministically in a single-session ROLLBACK because:
--   - Both sessions must hold their transactions open simultaneously
--   - Session A's INSERT on inspection_controls must commit before Session B's
--     ON CONFLICT fires, but a ROLLBACK would undo both inserts simultaneously
--
-- Manual procedure to verify (psql or two Supabase SQL Editor tabs):
--
-- PREREQUISITE: apply migration 020 to a dev project. Set up:
--   - auth.users: U_ADMIN (99), U_TECH (98) — same UUIDs as above
--   - company + facility + gate + order + visit + tech profile + SOT
--   - Record the order_id and visit_id from the setup
--
-- SESSION A (run first, do NOT commit yet):
--   BEGIN;
--   INSERT INTO inspection_controls (company_id, visit_id, control_key, control_label, result)
--   VALUES (<co>, <vis_id>, 'ctrl_race', 'Race test', 'resolved');
--   -- DO NOT COMMIT — keep this transaction open
--
-- SESSION B (run while A is open — will block on FOR UPDATE):
--   BEGIN;
--   SET LOCAL "request.jwt.claims" = '{"sub":"<U_TECH>","aud":"authenticated"}';
--   SET LOCAL ROLE authenticated;
--   SELECT tech_save_pilot_control(
--     <ord_id>, <vis_id>, 'ctrl_race', 'Race test', 'resolved', NULL,
--     '{"idempotency_key":"<uuid>","problem_found":"...", ...}'::jsonb
--   );
--   -- Session B blocks waiting for Session A's lock on service_orders
--
-- SESSION A (now commit):
--   COMMIT;
--
-- -- Session B unblocks, finds ctrl_race pre-existing, hits the race-loser path
-- -- with the repair key → ON CONFLICT DO NOTHING → returns existing control id
--
-- Expected result:
--   Session B returns the existing control id (not null)
--   SELECT count(*) FROM inspection_repairs WHERE idempotency_key='<uuid>' → 1
-- ══════════════════════════════════════════════════════════════════════════════

ROLLBACK;
