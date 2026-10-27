-- All synthetic rows roll back on success and failure. Run after the replay migration.
DO $$
DECLARE v_subject text:='sl-opening-a-'||gen_random_uuid()::text;
  v_other text:='sl-opening-b-'||gen_random_uuid()::text;
  v_actor uuid; v_partner uuid; v_binding uuid; v_account uuid; v_other_account uuid;
  v_tie uuid; v_partner_account uuid; v_adjustment uuid; v_transaction text;
  v_input jsonb; v_result jsonb; v_before jsonb; v_after jsonb; v_fact jsonb;
  v_other_before jsonb; v_instruction jsonb; v_order bigint; v_error text;
BEGIN
  BEGIN
    v_actor:=public.sl_provision_user(v_subject,'Synthetic opening A')::uuid;
    v_partner:=public.sl_provision_user(v_other,'Synthetic opening B')::uuid;
    v_input:='{"name":"Opening replay","account_type":"cash","custodian":"self",
      "opening_state":{"opening_date":"2026-10-01","opening_balance_minor":100000,
      "opening_allocations":[{"fund_owner":"self","fund_type":"liquid","amount_minor":50000},
      {"fund_owner":"self","fund_type":"savings","amount_minor":50000}]}}'::jsonb;
    v_account:=(public.sl_create_account(v_subject,repeat('a',64),repeat('a',64),v_input)->>'id')::uuid;
    v_other_account:=(public.sl_create_account(v_other,repeat('a',64),repeat('a',64),v_input)->>'id')::uuid;
    v_other_before:=jsonb_build_object('account',public.sl_account_json(v_other_account),
      'rows',(SELECT jsonb_agg(to_jsonb(m) ORDER BY m.id) FROM public.sl_movements m WHERE account_id=v_other_account));
    PERFORM public.sl_adjust_funds(v_subject,v_account::text,repeat('b',64),repeat('b',64),1,
      '{"from":{"fund_owner":"self","fund_type":"savings"},
        "to":{"fund_owner":"self","fund_type":"liquid"},"amount_minor":10000}'::jsonb);
    SELECT id INTO v_adjustment FROM public.sl_fund_adjustments WHERE account_id=v_account;
    IF v_adjustment IS NULL THEN RAISE EXCEPTION 'adjustment instruction was not saved'; END IF;
    -- Historical fixture date only; production instructions have no update endpoint.
    UPDATE public.sl_fund_adjustments SET occurred_at='2026-10-20T12:00:00+08:00' WHERE id=v_adjustment;
    UPDATE public.sl_movements SET effective_at='2026-10-20T12:00:00+08:00' WHERE operation_group=v_adjustment;
    SELECT to_jsonb(d) INTO v_instruction FROM public.sl_fund_adjustments d WHERE id=v_adjustment;
    v_result:=public.sl_create_expense(v_subject,repeat('c',64),repeat('c',64),
      jsonb_build_object('type','expense','account_id',v_account::text,'amount_minor',20000,
        'occurred_at','2026-10-21T12:00:00+08:00','category_code','other','merchant','','note',''));
    v_transaction:=v_result->'transaction'->>'id';
    SELECT to_jsonb(t) INTO v_fact FROM public.sl_transactions t WHERE id=v_transaction::uuid;
    SELECT replay_order INTO v_order FROM public.sl_effects WHERE transaction_id=v_transaction::uuid;
    v_input:='{"opening_date":"2026-10-01","opening_balance_minor":120000,
      "opening_allocations":[{"fund_owner":"self","fund_type":"liquid","amount_minor":70000},
        {"fund_owner":"self","fund_type":"savings","amount_minor":50000}]}'::jsonb;
    v_result:=public.sl_put_opening_state(v_subject,v_account::text,3,v_input);
    IF (v_result->>'version')::bigint<>4 OR (v_result->>'balance_minor')::numeric<>100000 OR
      EXISTS(SELECT 1 FROM public.sl_share_state(v_account) WHERE current_minor<>
        CASE fund_type WHEN 'liquid' THEN 60000 ELSE 40000 END) THEN
      RAISE EXCEPTION 'V19 opening replay result differs'; END IF;
    IF (SELECT to_jsonb(t) FROM public.sl_transactions t WHERE id=v_transaction::uuid)<>v_fact OR
      (SELECT replay_order FROM public.sl_effects WHERE transaction_id=v_transaction::uuid)<>v_order OR
      (SELECT to_jsonb(d) FROM public.sl_fund_adjustments d WHERE id=v_adjustment)<>v_instruction THEN
      RAISE EXCEPTION 'replay changed transaction facts/instruction/order'; END IF;
    v_before:=jsonb_build_object('account',(SELECT to_jsonb(a) FROM public.sl_accounts a WHERE id=v_account),
      'movements',(SELECT jsonb_agg(to_jsonb(m) ORDER BY m.id) FROM public.sl_movements m WHERE account_id=v_account),
      'effects',(SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id) FROM public.sl_effects e WHERE account_id=v_account));
    v_input:=jsonb_set(v_input,'{opening_allocations}',
      '[{"fund_owner":"self","fund_type":"savings","amount_minor":50000},
        {"fund_owner":"self","fund_type":"liquid","amount_minor":70000}]'::jsonb);
    v_result:=public.sl_put_opening_state(v_subject,v_account::text,4,v_input);
    IF (v_result->>'version')::bigint<>4 THEN RAISE EXCEPTION 'semantic no-op changed version'; END IF;
    BEGIN
      PERFORM public.sl_put_opening_state(v_subject,v_account::text,3,v_input);
      RAISE EXCEPTION 'stale version bypassed by no-op';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
      IF v_error<>'sl_version_mismatch' THEN RAISE; END IF;
    END;
    BEGIN
      PERFORM public.sl_put_opening_state(v_subject,v_account::text,4,
        '{"opening_date":"2026-10-01","opening_balance_minor":100000,
          "opening_allocations":[{"fund_owner":"self","fund_type":"liquid","amount_minor":100000}]}'::jsonb);
      RAISE EXCEPTION 'unsafe intermediate allocation was accepted';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
      IF v_error<>'sl_opening_recalculation_conflict' THEN RAISE; END IF;
    END;
    v_after:=jsonb_build_object('account',(SELECT to_jsonb(a) FROM public.sl_accounts a WHERE id=v_account),
      'movements',(SELECT jsonb_agg(to_jsonb(m) ORDER BY m.id) FROM public.sl_movements m WHERE account_id=v_account),
      'effects',(SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id) FROM public.sl_effects e WHERE account_id=v_account));
    IF v_before<>v_after THEN RAISE EXCEPTION 'no-op or failed replay changed stored rows'; END IF;
    v_result:=public.sl_put_opening_state(v_subject,v_account::text,4,
      jsonb_set(v_input,'{opening_date}','"2026-10-22"'::jsonb));
    IF (v_result->>'balance_minor')::numeric<>120000 OR
      (SELECT status FROM public.sl_effects WHERE transaction_id=v_transaction::uuid)<>'historical_only' OR
      EXISTS(SELECT 1 FROM public.sl_movements WHERE account_id=v_account AND reason<>'opening') OR
      (SELECT to_jsonb(d) FROM public.sl_fund_adjustments d WHERE id=v_adjustment)<>v_instruction THEN
      RAISE EXCEPTION 'late opening failed to retain inactive instruction/history'; END IF;
    v_result:=public.sl_put_opening_state(v_subject,v_account::text,5,v_input);
    IF (v_result->>'balance_minor')::numeric<>100000 OR
      (SELECT status FROM public.sl_effects WHERE transaction_id=v_transaction::uuid)<>'applied' THEN
      RAISE EXCEPTION 'earlier opening did not reactivate original events'; END IF;
    PERFORM public.sl_patch_expense(v_subject,v_transaction,1,'{"amount_minor":18000}'::jsonb);
    IF (SELECT replay_order FROM public.sl_effects WHERE transaction_id=v_transaction::uuid)<>v_order THEN
      RAISE EXCEPTION 'ordinary edit reassigned replay order'; END IF;
    SELECT to_jsonb(t) INTO v_fact FROM public.sl_transactions t WHERE id=v_transaction::uuid;
    v_result:=public.sl_put_opening_state(v_subject,v_account::text,7,
      '{"opening_date":"2026-10-01","opening_balance_minor":130000,
        "opening_allocations":[{"fund_owner":"self","fund_type":"liquid","amount_minor":80000},
        {"fund_owner":"self","fund_type":"savings","amount_minor":50000}]}'::jsonb);
    IF (v_result->>'balance_minor')::numeric<>112000 OR
      (SELECT to_jsonb(t) FROM public.sl_transactions t WHERE id=v_transaction::uuid)<>v_fact OR
      EXISTS(SELECT 1 FROM public.sl_share_state(v_account) WHERE current_minor<>
        CASE fund_type WHEN 'liquid' THEN 72000 ELSE 40000 END) THEN
      RAISE EXCEPTION 'replay did not use current edited transaction facts'; END IF;

    -- Equal event times must retain first-execution order across event kinds.
    v_input:='{"name":"Tie replay","account_type":"cash","custodian":"self",
      "opening_state":{"opening_date":"2026-10-01","opening_balance_minor":20000,
      "opening_allocations":[{"fund_owner":"self","fund_type":"savings","amount_minor":20000}]}}'::jsonb;
    v_tie:=(public.sl_create_account(v_subject,repeat('d',64),repeat('d',64),v_input)->>'id')::uuid;
    PERFORM public.sl_adjust_funds(v_subject,v_tie::text,repeat('e',64),repeat('e',64),1,
      '{"from":{"fund_owner":"self","fund_type":"savings"},
        "to":{"fund_owner":"self","fund_type":"liquid"},"amount_minor":10000}'::jsonb);
    PERFORM public.sl_create_expense(v_subject,repeat('f',64),repeat('f',64),
      jsonb_build_object('type','expense','account_id',v_tie::text,'amount_minor',10000,
        'occurred_at',to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'category_code','other','merchant','','note',''));
    v_result:=public.sl_put_opening_state(v_subject,v_tie::text,3,
      '{"opening_date":"2026-10-01","opening_balance_minor":30000,
        "opening_allocations":[{"fund_owner":"self","fund_type":"savings","amount_minor":30000}]}'::jsonb);
    IF EXISTS(SELECT 1 FROM public.sl_share_state(v_tie) WHERE current_minor<>
      CASE fund_type WHEN 'liquid' THEN 0 ELSE 20000 END) THEN
      RAISE EXCEPTION 'equal-time event order changed'; END IF;

    INSERT INTO public.sl_bindings DEFAULT VALUES RETURNING id INTO v_binding;
    INSERT INTO public.sl_binding_members(user_id,binding_id) VALUES(v_actor,v_binding),(v_partner,v_binding);
    v_input:='{"name":"Partner replay","account_type":"cash","custodian":"self",
      "opening_state":{"opening_date":"2026-10-01","opening_balance_minor":10000,
      "opening_allocations":[{"fund_owner":"partner","fund_type":"savings","amount_minor":10000}]}}'::jsonb;
    v_partner_account:=(public.sl_create_account(v_subject,repeat('0',64),repeat('0',64),v_input)->>'id')::uuid;
    PERFORM public.sl_adjust_funds(v_subject,v_partner_account::text,repeat('1',64),repeat('1',64),1,
      '{"from":{"fund_owner":"partner","fund_type":"savings"},
        "to":{"fund_owner":"self","fund_type":"liquid"},"amount_minor":2000}'::jsonb);
    PERFORM public.sl_create_expense(v_subject,repeat('2',64),repeat('2',64),
      jsonb_build_object('type','expense','account_id',v_partner_account::text,'amount_minor',2500,
        'occurred_at',to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'category_code','other','merchant','','note',''));
    v_input:='{"opening_date":"2026-10-01","opening_balance_minor":12000,
      "opening_allocations":[{"fund_owner":"partner","fund_type":"savings","amount_minor":12000}]}'::jsonb;
    v_result:=public.sl_put_opening_state(v_subject,v_partner_account::text,3,v_input);
    IF (v_result->>'balance_minor')::numeric<>9500 OR NOT EXISTS(
      SELECT 1 FROM public.sl_share_state(v_partner_account) WHERE fund_owner_id=v_partner
        AND current_minor=9500 AND baseline_minor=10000) THEN
      RAISE EXCEPTION 'partner-owned instruction or baseline lost during replay'; END IF;
    BEGIN
      PERFORM public.sl_put_opening_state(v_other,v_partner_account::text,4,v_input);
      RAISE EXCEPTION 'partner gained opening write access';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
      IF v_error<>'sl_account_not_found' THEN RAISE; END IF;
    END;
    IF jsonb_build_object('account',public.sl_account_json(v_other_account),
      'rows',(SELECT jsonb_agg(to_jsonb(m) ORDER BY m.id) FROM public.sl_movements m WHERE account_id=v_other_account))<>v_other_before THEN
      RAISE EXCEPTION 'opening correction changed another account'; END IF;
    RAISE EXCEPTION USING ERRCODE='ZX002',MESSAGE='roll back successful opening fixtures';
  EXCEPTION WHEN SQLSTATE 'ZX002' THEN NULL;
  END;
  IF EXISTS(SELECT 1 FROM public.sl_users WHERE auth_subject IN(v_subject,v_other)) THEN
    RAISE EXCEPTION 'opening fixtures were not rolled back'; END IF;
END;
$$;
