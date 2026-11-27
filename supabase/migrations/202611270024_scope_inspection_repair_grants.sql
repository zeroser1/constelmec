-- The platform's default grants may include table privileges outside RLS.
-- Repair reads use RLS, and writes go through the inspection RPCs.
REVOKE ALL PRIVILEGES ON TABLE public.inspection_repairs
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.inspection_repairs TO authenticated;

-- The repair comparison is private to the inspection RPCs.
ALTER FUNCTION app_private.repair_payload_matches(public.inspection_repairs, jsonb)
  SET search_path TO '';
REVOKE EXECUTE ON FUNCTION app_private.repair_payload_matches(public.inspection_repairs, jsonb)
  FROM PUBLIC, anon, authenticated;
