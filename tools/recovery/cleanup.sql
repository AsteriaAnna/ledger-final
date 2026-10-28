-- Exact synthetic subjects only; no TRUNCATE, schema deletion or Auth mutation.
DO $$ DECLARE ids uuid[];accounts uuid[];transactions uuid[];batches uuid[];profiles uuid[];bindings uuid[]; BEGIN
 SELECT array_agg(id) INTO ids FROM public.sl_users WHERE auth_subject IN('sl-recovery-20261028','sl-recovery-partner-20261028')
   AND display_name IN('Synthetic recovery','Synthetic recovery partner');
 IF coalesce(cardinality(ids),0)<>2 THEN RAISE EXCEPTION 'recovery_cleanup_scope_mismatch';END IF;
 SELECT array_agg(id) INTO accounts FROM public.sl_accounts WHERE holder_user_id=ANY(ids);
 SELECT array_agg(id) INTO transactions FROM public.sl_transactions WHERE owner_id=ANY(ids);
 SELECT array_agg(id) INTO batches FROM public.sl_import_batches WHERE owner_id=ANY(ids);
 SELECT array_agg(id) INTO profiles FROM public.sl_source_profiles WHERE owner_id=ANY(ids);
 SELECT array_agg(binding_id) INTO bindings FROM public.sl_binding_members WHERE user_id=ANY(ids);
 DELETE FROM public.sl_reconciliation_items WHERE profile_id=ANY(profiles);
 UPDATE public.sl_source_records SET current_observation_id=NULL WHERE profile_id=ANY(profiles);
 DELETE FROM public.sl_source_observations WHERE batch_id=ANY(batches);
 DELETE FROM public.sl_source_records WHERE profile_id=ANY(profiles);
 DELETE FROM public.sl_requests WHERE actor_id=ANY(ids);
 DELETE FROM public.sl_import_batches WHERE owner_id=ANY(ids);
 DELETE FROM public.sl_source_mappings WHERE profile_id=ANY(profiles);
 DELETE FROM public.sl_movements WHERE account_id=ANY(accounts);
 DELETE FROM public.sl_effects WHERE transaction_id=ANY(transactions);
 DELETE FROM public.sl_fund_adjustments WHERE account_id=ANY(accounts);
 DELETE FROM public.sl_transactions WHERE owner_id=ANY(ids);
 DELETE FROM public.sl_source_profiles WHERE owner_id=ANY(ids);
 DELETE FROM public.sl_accounts WHERE holder_user_id=ANY(ids);
 DELETE FROM public.sl_monthly_budgets WHERE owner_id=ANY(ids);
 DELETE FROM public.sl_invitations WHERE inviter_id=ANY(ids);
 DELETE FROM public.sl_binding_members WHERE user_id=ANY(ids);
 DELETE FROM public.sl_bindings WHERE id=ANY(bindings) AND NOT EXISTS(SELECT 1 FROM public.sl_binding_members m WHERE m.binding_id=sl_bindings.id);
 DELETE FROM public.sl_users WHERE id=ANY(ids);
END $$;
