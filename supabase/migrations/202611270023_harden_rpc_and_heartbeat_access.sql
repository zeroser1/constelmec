-- Security hardening: block direct Data API access to heartbeat rows.
-- The app uses SECURITY DEFINER RPCs with explicit role/company checks.
ALTER TABLE public.live_inspection_heartbeats ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.live_inspection_heartbeats FROM PUBLIC, anon, authenticated;

-- These RPCs are intended for signed-in users only.
-- Postgres grants EXECUTE to PUBLIC by default; remove that implicit grant.
DO $revoke_anon$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS signature
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public'
      AND p.prosecdef
      AND p.proname IN (
        'confirm_observation_attachment',
        'customer_create_observation',
        'get_gate_maintenance_photos',
        'get_observation_attachments',
        'get_observation_conversation',
        'get_visit_maintenance_photos',
        'request_observation_attachment_slot',
        'tech_list_gate_observations',
        'tech_reply_to_observation',
        'gate_inspection_history'
      )
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', f.signature);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.signature);
  END LOOP;
END;
$revoke_anon$;
