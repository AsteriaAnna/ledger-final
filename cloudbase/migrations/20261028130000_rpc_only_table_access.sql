-- CloudBase may grant new public tables to service_role by default. The API
-- only calls guarded SECURITY DEFINER entry points; it never needs table CRUD.
DO $$ DECLARE object record; BEGIN
  FOR object IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relkind IN ('r','S') AND c.relname LIKE 'sl\_%' ESCAPE '\' LOOP
    EXECUTE format('REVOKE ALL ON %s public.%I FROM PUBLIC,anon,authenticated,service_role',
      CASE WHEN (SELECT relkind FROM pg_class WHERE oid=format('public.%I',object.relname)::regclass)='S' THEN 'SEQUENCE' ELSE 'TABLE' END,object.relname);
  END LOOP;
END $$;
