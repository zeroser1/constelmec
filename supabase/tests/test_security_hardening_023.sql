-- Non-destructive assertions for migration 023.
-- Run on DEV after applying 023. Raises an exception on any failed assertion.
DO $assert_security$
DECLARE
  v_rel oid;
  v_count integer;
BEGIN
  SELECT c.oid INTO v_rel FROM pg_class c
  JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relname='live_inspection_heartbeats';
  IF v_rel IS NULL THEN RAISE EXCEPTION 'Missing heartbeat table'; END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid=v_rel) THEN
    RAISE EXCEPTION 'Heartbeat RLS is disabled';
  END IF;
  IF has_table_privilege('anon',v_rel,'SELECT')
     OR has_table_privilege('anon',v_rel,'INSERT')
     OR has_table_privilege('authenticated',v_rel,'SELECT')
     OR has_table_privilege('authenticated',v_rel,'INSERT')
     OR has_table_privilege('authenticated',v_rel,'UPDATE')
     OR has_table_privilege('authenticated',v_rel,'DELETE') THEN
    RAISE EXCEPTION 'Unexpected direct heartbeat table privilege';
  END IF;
  SELECT count(*) INTO v_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND p.prosecdef
    AND p.proname IN (
      'confirm_observation_attachment','customer_create_observation',
      'get_gate_maintenance_photos','get_observation_attachments',
      'get_observation_conversation','get_visit_maintenance_photos',
      'request_observation_attachment_slot','tech_list_gate_observations',
      'tech_reply_to_observation','gate_inspection_history'
    )
    AND (has_function_privilege('anon',p.oid,'EXECUTE')
      OR NOT has_function_privilege('authenticated',p.oid,'EXECUTE'));
  IF v_count <> 0 THEN
    RAISE EXCEPTION '% security-definer RPC(s) have unsafe EXECUTE grants',v_count;
  END IF;
  RAISE NOTICE 'PASS: heartbeat RLS and restricted RPC grants';
END;
$assert_security$;
