-- Run against the development PG after 20261027190000. All fixtures and writes
-- roll back inside the nested block on both success and assertion failure.
DO $$
DECLARE v_subject text:='sl-three-a-'||gen_random_uuid()::text;
  v_other text:='sl-three-b-'||gen_random_uuid()::text;
  v_actor uuid; v_partner uuid; v_binding uuid; v_account uuid; v_empty uuid;
  v_input jsonb; v_result jsonb; v_saved jsonb; v_before jsonb; v_transaction text;
  v_first text; v_last text; v_error text;
BEGIN
  BEGIN
    v_actor:=public.sl_provision_user(v_subject,'Synthetic A')::uuid;
    v_partner:=public.sl_provision_user(v_other,'Synthetic B')::uuid;
    v_input:=jsonb_build_object('name','Three shares','account_type','cash','custodian','partner',
      'opening_state',jsonb_build_object('opening_date','2026-10-01','opening_balance_minor',30000,
        'opening_allocations','[{"fund_owner":"self","fund_type":"liquid","amount_minor":10000},
          {"fund_owner":"self","fund_type":"savings","amount_minor":10000},
          {"fund_owner":"partner","fund_type":"savings","amount_minor":10000}]'::jsonb));
    BEGIN
      PERFORM public.sl_create_account(v_subject,repeat('a',64),repeat('a',64),v_input);
      RAISE EXCEPTION 'unbound partner allocation was accepted';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
      IF v_error<>'sl_relationship_conflict' THEN RAISE; END IF;
    END;
    IF EXISTS(SELECT 1 FROM public.sl_accounts WHERE holder_user_id=v_actor) THEN
      RAISE EXCEPTION 'failed creation left an account'; END IF;
    INSERT INTO public.sl_bindings DEFAULT VALUES RETURNING id INTO v_binding;
    INSERT INTO public.sl_binding_members(user_id,binding_id) VALUES(v_actor,v_binding),(v_partner,v_binding);
    v_saved:=public.sl_create_account(v_subject,repeat('b',64),repeat('b',64),v_input);
    v_account:=(v_saved->>'id')::uuid;
    IF v_saved->>'custodian'<>'partner' OR jsonb_array_length(v_saved->'fund_shares')<>3 THEN
      RAISE EXCEPTION 'opening projection lost owner/custodian'; END IF;

    v_result:=public.sl_create_transaction(v_subject,repeat('c',64),repeat('c',64),
      jsonb_build_object('type','expense','account_id',v_account::text,'amount_minor',25000,
        'occurred_at','2026-10-20T12:00:00+08:00','category_code','other','merchant','','note',''));
    v_transaction:=v_result->'transaction'->>'id';
    IF (v_result->'account_changes'->0->>'balance_minor')::numeric<>5000 OR
      v_result->'notices'<>'[{"code":"OWN_SAVINGS_USED","amount_minor":10000},
        {"code":"PARTNER_SAVINGS_USED","amount_minor":5000}]'::jsonb OR
      EXISTS(SELECT 1 FROM public.sl_share_state(v_account) WHERE current_minor<>
        CASE WHEN fund_owner_id=v_partner THEN 5000 ELSE 0 END) THEN
      RAISE EXCEPTION 'three-share deduction order failed'; END IF;
    PERFORM public.sl_patch_transaction(v_subject,v_transaction,1,'{"amount_minor":13000}'::jsonb);
    IF EXISTS(SELECT 1 FROM public.sl_share_state(v_account) WHERE current_minor<>
      CASE WHEN fund_owner_id=v_partner THEN 10000 WHEN fund_type='savings' THEN 7000 ELSE 0 END) THEN
      RAISE EXCEPTION 'partner-first replenishment failed'; END IF;

    v_input:='{"from":{"fund_owner":"partner","fund_type":"savings"},
      "to":{"fund_owner":"self","fund_type":"savings"},"amount_minor":2000}'::jsonb;
    v_result:=public.sl_adjust_funds(v_subject,v_account::text,repeat('d',64),repeat('d',64),3,v_input);
    IF (v_result->>'balance_minor')::numeric<>17000 OR v_result->'opening_state'<>v_saved->'opening_state' OR
      EXISTS(SELECT 1 FROM public.sl_share_state(v_account) WHERE
        (fund_owner_id=v_partner AND (current_minor<>8000 OR baseline_minor<>8000)) OR
        (fund_owner_id=v_actor AND fund_type='savings' AND (current_minor<>9000 OR baseline_minor<>12000))) THEN
      RAISE EXCEPTION 'owner adjustment or savings baseline failed'; END IF;
    IF public.sl_adjust_funds(v_subject,v_account::text,repeat('d',64),repeat('d',64),3,v_input)<>v_result THEN
      RAISE EXCEPTION 'stale-version idempotent replay failed'; END IF;
    BEGIN
      PERFORM public.sl_adjust_funds(v_subject,v_account::text,repeat('d',64),repeat('e',64),4,v_input);
      RAISE EXCEPTION 'changed payload reused key';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
      IF v_error<>'sl_idempotency_conflict' THEN RAISE; END IF;
    END;
    v_before:=public.sl_get_account_visible(v_other,v_account::text);
    IF v_before->>'holder'<>'partner' OR (v_before->>'read_only')::boolean<>true OR
      NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_before->'fund_shares') s
        WHERE s->>'fund_owner'='self' AND s->>'fund_type'='savings' AND (s->>'amount_minor')::numeric=8000) THEN
      RAISE EXCEPTION 'viewer-relative ownership failed'; END IF;
    BEGIN
      PERFORM public.sl_adjust_funds(v_other,v_account::text,repeat('e',64),repeat('e',64),4,v_input);
      RAISE EXCEPTION 'partner gained account write access';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
      IF v_error<>'sl_account_not_found' THEN RAISE; END IF;
    END;
    BEGIN
      PERFORM public.sl_adjust_funds(v_subject,v_account::text,repeat('f',64),repeat('f',64),3,v_input);
      RAISE EXCEPTION 'stale version accepted';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
      IF v_error<>'sl_version_mismatch' THEN RAISE; END IF;
    END;
    v_result:=public.sl_patch_transaction(v_subject,v_transaction,2,'{"amount_minor":14000}'::jsonb);
    IF v_result->'notices'<>'[{"code":"OWN_SAVINGS_USED","amount_minor":1000}]'::jsonb THEN
      RAISE EXCEPTION 'expense increase bypassed own savings'; END IF;
    v_before:=public.sl_account_json(v_account);
    BEGIN
      PERFORM public.sl_create_transaction(v_subject,repeat('0',64),repeat('0',64),
        jsonb_build_object('type','expense','account_id',v_account::text,'amount_minor',16001,
          'occurred_at','2026-10-20T13:00:00+08:00','category_code','other','merchant','','note',''));
      RAISE EXCEPTION 'overdraft accepted';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
      IF v_error<>'sl_insufficient_funds' THEN RAISE; END IF;
    END;
    IF public.sl_account_json(v_account)<>v_before OR
      (SELECT count(*) FROM public.sl_transactions WHERE owner_id=v_actor)<>1 THEN
      RAISE EXCEPTION 'overdraft left a partial mutation'; END IF;
    PERFORM public.sl_delete_transaction(v_subject,v_transaction,3);
    IF EXISTS(SELECT 1 FROM public.sl_share_state(v_account) WHERE current_minor<>
      CASE WHEN fund_owner_id=v_partner THEN 8000 WHEN fund_type='savings' THEN 12000 ELSE 10000 END) THEN
      RAISE EXCEPTION 'delete reversed the wrong owner share'; END IF;

    -- An edited expense can own a positive replenishment in another share.
    -- Spending that replenishment later makes deleting the earlier expense unsafe.
    v_input:=jsonb_build_object('type','expense','account_id',v_account::text,'amount_minor',1000,
      'occurred_at','2026-10-20T14:00:00+08:00','category_code','other','merchant','','note','');
    v_first:=public.sl_create_transaction(v_subject,repeat('1',64),repeat('1',64),v_input)->'transaction'->>'id';
    PERFORM public.sl_create_transaction(v_subject,repeat('2',64),repeat('2',64),jsonb_set(v_input,'{amount_minor}','23000'::jsonb));
    PERFORM public.sl_patch_transaction(v_subject,v_first,1,'{"amount_minor":500}'::jsonb);
    v_last:=public.sl_create_transaction(v_subject,repeat('3',64),repeat('3',64),jsonb_set(v_input,'{amount_minor}','6500'::jsonb))->'transaction'->>'id';
    v_before:=public.sl_account_json(v_account);
    BEGIN
      PERFORM public.sl_delete_transaction(v_subject,v_first,2);
      RAISE EXCEPTION 'unsafe partner-share reversal accepted';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
      IF v_error<>'sl_unsafe_reversal' THEN RAISE; END IF;
    END;
    IF public.sl_account_json(v_account)<>v_before THEN RAISE EXCEPTION 'unsafe reversal changed funds'; END IF;
    v_input:=jsonb_build_object('name','Empty','account_type','cash','custodian','self','opening_state',
      jsonb_build_object('opening_date','2026-10-01','opening_balance_minor',0,
        'opening_allocations','[{"fund_owner":"self","fund_type":"liquid","amount_minor":0}]'::jsonb));
    v_empty:=(public.sl_create_account(v_subject,repeat('4',64),repeat('4',64),v_input)->>'id')::uuid;
    BEGIN
      PERFORM public.sl_patch_transaction(v_subject,v_last,1,jsonb_build_object('account_id',v_empty::text));
      RAISE EXCEPTION 'move to insufficient account accepted';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
      IF v_error<>'sl_insufficient_funds' THEN RAISE; END IF;
    END;
    IF public.sl_account_json(v_account)<>v_before OR
      (public.sl_account_json(v_empty)->>'balance_minor')::numeric<>0 THEN
      RAISE EXCEPTION 'failed account move was not atomic'; END IF;
    RAISE EXCEPTION USING ERRCODE='ZX001',MESSAGE='roll back successful synthetic fixtures';
  EXCEPTION WHEN SQLSTATE 'ZX001' THEN NULL;
  END;
  IF EXISTS(SELECT 1 FROM public.sl_users WHERE auth_subject IN(v_subject,v_other)) THEN
    RAISE EXCEPTION 'synthetic fixtures were not rolled back'; END IF;
END;
$$;
