DO $assert_repair_grants$
BEGIN
  IF has_table_privilege('anon', 'public.inspection_repairs', 'SELECT')
     OR has_table_privilege('anon', 'public.inspection_repairs', 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
     OR NOT has_table_privilege('authenticated', 'public.inspection_repairs', 'SELECT')
     OR has_table_privilege('authenticated', 'public.inspection_repairs', 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER') THEN
    RAISE EXCEPTION 'Unexpected direct inspection repair table privilege';
  END IF;

  IF has_function_privilege('anon', 'app_private.repair_payload_matches(public.inspection_repairs, jsonb)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'app_private.repair_payload_matches(public.inspection_repairs, jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Unexpected direct repair comparison privilege';
  END IF;
END;
$assert_repair_grants$;
