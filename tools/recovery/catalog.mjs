// Only application-owned objects. Platform Auth, storage and credentials are separate.
export const tables=['sl_users','sl_bindings','sl_binding_members','sl_invitations','sl_accounts',
  'sl_source_profiles','sl_source_mappings','sl_transactions','sl_effects','sl_movements','sl_fund_adjustments',
  'sl_import_batches','sl_source_records','sl_source_observations','sl_reconciliation_items','sl_requests','sl_monthly_budgets'];
export const schemaSql=`SELECT jsonb_build_object(
 'columns',(SELECT jsonb_agg(jsonb_build_array(table_name,column_name,udt_name,is_nullable,column_default) ORDER BY table_name,ordinal_position)
   FROM information_schema.columns WHERE table_schema='public' AND table_name LIKE 'sl_%'),
 'constraints',(SELECT jsonb_agg(jsonb_build_array(c.relname,k.conname,pg_get_constraintdef(k.oid)) ORDER BY c.relname,k.conname)
   FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname LIKE 'sl_%'),
 'indexes',(SELECT jsonb_agg(jsonb_build_array(tablename,indexname,indexdef) ORDER BY tablename,indexname) FROM pg_indexes WHERE schemaname='public' AND tablename LIKE 'sl_%'),
 'rls',(SELECT jsonb_agg(jsonb_build_array(c.relname,c.relrowsecurity,c.relforcerowsecurity) ORDER BY c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' AND c.relname LIKE 'sl_%'),
 'functions',(SELECT jsonb_agg(jsonb_build_array(p.proname,pg_get_function_identity_arguments(p.oid),md5(pg_get_functiondef(p.oid)),
   has_function_privilege('anon',p.oid,'EXECUTE'),has_function_privilege('authenticated',p.oid,'EXECUTE'),has_function_privilege('service_role',p.oid,'EXECUTE')) ORDER BY p.proname,pg_get_function_identity_arguments(p.oid))
   FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname LIKE 'sl_%'),
 'table_grants',(SELECT jsonb_agg(jsonb_build_array(grantee,table_name,privilege_type) ORDER BY grantee,table_name,privilege_type) FROM information_schema.table_privileges
   WHERE table_schema='public' AND table_name LIKE 'sl_%' AND grantee IN ('anon','authenticated','service_role','PUBLIC'))
) AS schema`;
export const rowsSql=table=>`SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),'[]'::jsonb)::text AS data FROM public.${table} t`;
