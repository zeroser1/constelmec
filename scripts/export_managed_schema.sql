BEGIN READ ONLY;
SET LOCAL search_path = pg_catalog;

SELECT format(
    'CREATE POLICY %I ON %I.%I AS %s FOR %s TO %s%s%s;',
    p.policyname, p.schemaname, p.tablename, p.permissive, p.cmd,
    (SELECT string_agg(
        CASE WHEN entry.role_name = 'public' THEN 'PUBLIC'
             ELSE quote_ident(entry.role_name) END, ', ' ORDER BY entry.position
    ) FROM unnest(p.roles) WITH ORDINALITY AS entry(role_name, position)),
    CASE WHEN p.qual IS NOT NULL THEN ' USING (' || p.qual || ')' ELSE '' END,
    CASE WHEN p.with_check IS NOT NULL THEN ' WITH CHECK (' || p.with_check || ')' ELSE '' END
)
FROM pg_policies p
WHERE p.schemaname IN ('auth', 'storage', 'realtime')
ORDER BY p.schemaname, p.tablename, p.policyname;

SELECT pg_get_triggerdef(t.oid, false) || ';' ||
    CASE t.tgenabled
        WHEN 'D' THEN format(E'\nALTER TABLE %I.%I DISABLE TRIGGER %I;', n.nspname, c.relname, t.tgname)
        WHEN 'R' THEN format(E'\nALTER TABLE %I.%I ENABLE REPLICA TRIGGER %I;', n.nspname, c.relname, t.tgname)
        WHEN 'A' THEN format(E'\nALTER TABLE %I.%I ENABLE ALWAYS TRIGGER %I;', n.nspname, c.relname, t.tgname)
        ELSE ''
    END
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_proc p ON p.oid = t.tgfoid
JOIN pg_namespace f ON f.oid = p.pronamespace
WHERE NOT t.tgisinternal
  AND n.nspname IN ('auth', 'storage', 'realtime')
  AND f.nspname IN ('public', 'app_private')
ORDER BY n.nspname, c.relname, t.tgname;

COMMIT;
