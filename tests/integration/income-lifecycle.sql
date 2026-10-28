-- Current income/expense contract risks; all fixtures roll back on every exit.
DO $$
DECLARE v_subject text:='sl-income-a-'||gen_random_uuid()::text;
  v_other text:='sl-income-b-'||gen_random_uuid()::text;
  v_actor uuid; v_partner uuid; v_binding uuid; v_account uuid; v_target uuid; v_other_account uuid; v_replay uuid;
  v_input jsonb; v_result jsonb; v_created jsonb; v_before jsonb; v_fact jsonb; v_other_before jsonb;
  v_income text; v_flip text; v_historical text; v_order bigint; v_version bigint; v_error text;
BEGIN
  BEGIN
    v_actor:=public.sl_provision_user(v_subject,'Synthetic income A')::uuid;
    v_partner:=public.sl_provision_user(v_other,'Synthetic income B')::uuid;
    INSERT INTO public.sl_bindings DEFAULT VALUES RETURNING id INTO v_binding;
    INSERT INTO public.sl_binding_members(user_id,binding_id) VALUES(v_actor,v_binding),(v_partner,v_binding);
    v_input:='{"name":"Income account","account_type":"cash","custodian":"self","opening_state":{
      "opening_date":"2026-10-01","opening_balance_minor":10000,"opening_allocations":[
      {"fund_owner":"self","fund_type":"liquid","amount_minor":0},
      {"fund_owner":"self","fund_type":"savings","amount_minor":5000},
      {"fund_owner":"partner","fund_type":"savings","amount_minor":5000}]}}'::jsonb;
    v_account:=(public.sl_create_account(v_subject,repeat('a',64),repeat('a',64),v_input)->>'id')::uuid;
    v_input:='{"name":"Target account","account_type":"cash","custodian":"self","opening_state":{
      "opening_date":"2026-10-01","opening_balance_minor":2000,"opening_allocations":[
      {"fund_owner":"self","fund_type":"liquid","amount_minor":2000}]}}'::jsonb;
    v_target:=(public.sl_create_account(v_subject,repeat('b',64),repeat('b',64),v_input)->>'id')::uuid;
    v_other_account:=(public.sl_create_account(v_other,repeat('b',64),repeat('b',64),v_input)->>'id')::uuid;
    v_other_before:=public.sl_account_json(v_other_account);
    v_input:=jsonb_build_object('type','expense','account_id',v_account::text,'amount_minor',6000,
      'occurred_at','2026-10-10T12:00:00+08:00','category_code','other','merchant','','note','');
    PERFORM public.sl_create_transaction(v_subject,repeat('c',64),repeat('c',64),v_input);
    v_input:=jsonb_set(jsonb_set(v_input,'{type}','"income"'::jsonb),'{amount_minor}','10000'::jsonb);
    v_created:=public.sl_create_transaction(v_subject,repeat('d',64),repeat('d',64),v_input);
    v_income:=v_created->'transaction'->>'id';
    SELECT replay_order INTO v_order FROM public.sl_effects WHERE transaction_id=v_income::uuid;
    IF v_created->'transaction'->>'type'<>'income' OR v_created->'notices'<>'[]'::jsonb OR
      (v_created->'account_effects'->0->>'signed_amount_minor')::numeric<>10000 OR
      EXISTS(SELECT 1 FROM public.sl_share_state(v_account) WHERE current_minor<>
        CASE WHEN fund_type='liquid' THEN 10000 WHEN fund_owner_id=v_actor THEN 0 ELSE 4000 END) THEN
      RAISE EXCEPTION 'income did not credit only own liquid'; END IF;
    IF public.sl_create_transaction(v_subject,repeat('d',64),repeat('d',64),v_input)<>v_created THEN
      RAISE EXCEPTION 'income retry was not idempotent'; END IF;
    BEGIN
      PERFORM public.sl_create_transaction(v_subject,repeat('d',64),repeat('e',64),v_input);
      RAISE EXCEPTION 'income key collision accepted';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
      IF v_error<>'sl_idempotency_conflict' THEN RAISE; END IF;
    END;
    SELECT version INTO v_version FROM public.sl_accounts WHERE id=v_account;
    v_result:=public.sl_patch_transaction(v_subject,v_income,1,'{"note":"metadata only"}'::jsonb);
    IF v_result->'account_changes'<>'[]'::jsonb OR
      (SELECT version FROM public.sl_accounts WHERE id=v_account)<>v_version THEN
      RAISE EXCEPTION 'metadata-only edit changed account version/funds'; END IF;
    v_result:=public.sl_patch_transaction(v_subject,v_income,2,'{"amount_minor":12000}'::jsonb);
    IF (v_result->'account_effects'->0->>'signed_amount_minor')::numeric<>12000 OR
      (SELECT current_minor FROM public.sl_share_state(v_account) WHERE fund_owner_id=v_actor AND fund_type='liquid')<>12000 THEN
      RAISE EXCEPTION 'safe income amount edit failed'; END IF;
    IF (public.sl_patch_transaction(v_subject,v_income,3,'{"source_account_profile_id":null}'::jsonb)->'transaction'->>'version')::bigint<>3 THEN
      RAISE EXCEPTION 'null clear of absent source was not a no-op'; END IF;
    BEGIN
      PERFORM public.sl_patch_transaction(v_other,v_income,3,'{"amount_minor":1}'::jsonb);
      RAISE EXCEPTION 'partner edited income';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
      IF v_error<>'sl_transaction_not_found' THEN RAISE; END IF;
    END;
    v_result:=public.sl_patch_transaction(v_subject,v_income,3,jsonb_build_object('account_id',v_target::text));
    IF jsonb_array_length(v_result->'account_changes')<>2 OR
      (public.sl_account_json(v_target)->>'balance_minor')::numeric<>14000 OR
      (SELECT current_minor FROM public.sl_share_state(v_account) WHERE fund_owner_id=v_actor AND fund_type='liquid')<>0 OR
      (SELECT replay_order FROM public.sl_effects WHERE transaction_id=v_income::uuid)<>v_order THEN
      RAISE EXCEPTION 'income account move or stable order failed'; END IF;
    PERFORM public.sl_create_transaction(v_subject,repeat('e',64),repeat('e',64),
      jsonb_build_object('type','expense','account_id',v_target::text,'amount_minor',11000,
        'occurred_at','2026-10-12T12:00:00+08:00','category_code','other','merchant','','note',''));
    v_before:=public.sl_account_json(v_target);
    SELECT to_jsonb(tx) INTO v_fact FROM public.sl_transactions tx WHERE id=v_income::uuid;
    BEGIN
      PERFORM public.sl_delete_transaction(v_subject,v_income,4);
      RAISE EXCEPTION 'spent income could be deleted';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
      IF v_error<>'sl_unsafe_reversal' THEN RAISE; END IF;
    END;
    BEGIN
      PERFORM public.sl_patch_transaction(v_subject,v_income,4,'{"amount_minor":14000,"note":"must roll back"}'::jsonb);
      RAISE EXCEPTION 'spent income increase bypassed required reversal';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
      IF v_error<>'sl_unsafe_reversal' THEN RAISE; END IF;
    END;
    IF public.sl_account_json(v_target)<>v_before OR
      (SELECT to_jsonb(tx) FROM public.sl_transactions tx WHERE id=v_income::uuid)<>v_fact THEN
      RAISE EXCEPTION 'unsafe income edit/delete partially committed'; END IF;

    v_input:=jsonb_build_object('type','income','account_id',v_account::text,'amount_minor',2000,
      'occurred_at','2026-10-15T12:00:00+08:00','category_code','other','merchant','','note','');
    v_flip:=public.sl_create_transaction(v_subject,repeat('f',64),repeat('f',64),v_input)->'transaction'->>'id';
    v_result:=public.sl_patch_transaction(v_subject,v_flip,1,'{"type":"expense"}'::jsonb);
    IF v_result->'transaction'->>'id'<>v_flip OR v_result->'transaction'->>'type'<>'expense' OR
      (v_result->'account_effects'->0->>'signed_amount_minor')::numeric<>-2000 OR
      (public.sl_account_json(v_account)->>'balance_minor')::numeric<>2000 THEN
      RAISE EXCEPTION 'income to expense did not reverse then apply'; END IF;
    v_result:=public.sl_patch_transaction(v_subject,v_flip,2,'{"type":"income"}'::jsonb);
    IF v_result->'transaction'->>'type'<>'income' OR (public.sl_account_json(v_account)->>'balance_minor')::numeric<>6000 THEN
      RAISE EXCEPTION 'expense to income did not reverse then apply'; END IF;
    PERFORM public.sl_delete_transaction(v_subject,v_flip,3);
    IF (public.sl_account_json(v_account)->>'balance_minor')::numeric<>4000 THEN RAISE EXCEPTION 'safe income delete failed'; END IF;

    v_historical:=public.sl_create_transaction(v_subject,repeat('0',64),repeat('0',64),
      jsonb_set(jsonb_set(v_input,'{amount_minor}','1500'::jsonb),'{occurred_at}','"2026-09-20T12:00:00+08:00"'::jsonb))->'transaction'->>'id';
    IF EXISTS(SELECT 1 FROM public.sl_movements WHERE effect_id IN
      (SELECT id FROM public.sl_effects WHERE transaction_id=v_historical::uuid)) THEN RAISE EXCEPTION 'historical income changed funds'; END IF;
    PERFORM public.sl_patch_transaction(v_subject,v_historical,1,'{"occurred_at":"2026-10-20T12:00:00+08:00"}'::jsonb);
    IF (public.sl_account_json(v_account)->>'balance_minor')::numeric<>5500 THEN RAISE EXCEPTION 'income date did not activate effect'; END IF;
    PERFORM public.sl_patch_transaction(v_subject,v_historical,2,'{"occurred_at":"2026-09-20T12:00:00+08:00"}'::jsonb);
    v_result:=public.sl_delete_transaction(v_subject,v_historical,3);
    IF v_result->'account_changes'<>'[]'::jsonb OR (public.sl_account_json(v_account)->>'balance_minor')::numeric<>4000 THEN
      RAISE EXCEPTION 'historical income removal changed current funds'; END IF;

    v_input:='{"name":"Income replay","account_type":"cash","custodian":"self","opening_state":{
      "opening_date":"2026-10-01","opening_balance_minor":0,"opening_allocations":[
      {"fund_owner":"self","fund_type":"liquid","amount_minor":0}]}}'::jsonb;
    v_replay:=(public.sl_create_account(v_subject,repeat('1',64),repeat('1',64),v_input)->>'id')::uuid;
    v_input:=jsonb_build_object('type','income','account_id',v_replay::text,'amount_minor',5000,
      'occurred_at','2026-10-10T12:00:00+08:00','category_code','other','merchant','','note','');
    PERFORM public.sl_create_transaction(v_subject,repeat('2',64),repeat('2',64),v_input);
    PERFORM public.sl_create_transaction(v_subject,repeat('3',64),repeat('3',64),
      jsonb_set(jsonb_set(jsonb_set(v_input,'{type}','"expense"'::jsonb),'{amount_minor}','3000'::jsonb),
        '{occurred_at}','"2026-10-11T12:00:00+08:00"'::jsonb));
    PERFORM public.sl_adjust_funds(v_subject,v_replay::text,repeat('4',64),repeat('4',64),3,
      '{"from":{"fund_owner":"self","fund_type":"liquid"},"to":{"fund_owner":"self","fund_type":"savings"},"amount_minor":1000}'::jsonb);
    v_input:='{"opening_date":"2026-10-01","opening_balance_minor":1000,"opening_allocations":[
      {"fund_owner":"self","fund_type":"liquid","amount_minor":1000}]}'::jsonb;
    v_result:=public.sl_put_opening_state(v_subject,v_replay::text,4,v_input);
    IF (v_result->>'balance_minor')::numeric<>3000 OR EXISTS(SELECT 1 FROM public.sl_share_state(v_replay)
      WHERE current_minor<>CASE fund_type WHEN 'liquid' THEN 2000 ELSE 1000 END) THEN
      RAISE EXCEPTION 'opening replay omitted income'; END IF;
    v_before:=public.sl_account_json(v_replay);
    BEGIN
      PERFORM public.sl_put_opening_state(v_subject,v_replay::text,5,jsonb_set(v_input,'{opening_date}','"2026-10-11"'::jsonb));
      RAISE EXCEPTION 'replay ignored expense after excluded income';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
      IF v_error<>'sl_opening_recalculation_conflict' THEN RAISE; END IF;
    END;
    IF public.sl_account_json(v_replay)<>v_before THEN RAISE EXCEPTION 'failed income replay changed account'; END IF;
    PERFORM public.sl_put_opening_state(v_subject,v_replay::text,5,jsonb_set(v_input,'{opening_date}','"2026-10-12"'::jsonb));
    v_result:=public.sl_put_opening_state(v_subject,v_replay::text,6,v_input);
    IF (v_result->>'balance_minor')::numeric<>3000 THEN RAISE EXCEPTION 'income replay did not reactivate history'; END IF;
    v_before:=public.sl_account_json(v_replay);
    BEGIN
      PERFORM public.sl_create_transaction(v_subject,repeat('5',64),repeat('5',64),
        jsonb_build_object('type','income','account_id',v_replay::text,'amount_minor',9007199254740991,
          'occurred_at','2026-10-20T12:00:00+08:00','category_code','other','merchant','','note',''));
      RAISE EXCEPTION 'income exceeded safe account balance';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
      IF v_error<>'sl_insufficient_funds' THEN RAISE; END IF;
    END;
    IF public.sl_account_json(v_replay)<>v_before OR public.sl_account_json(v_other_account)<>v_other_before THEN
      RAISE EXCEPTION 'income overflow or another-user account changed'; END IF;
    RAISE EXCEPTION USING ERRCODE='ZX003',MESSAGE='roll back successful income fixtures';
  EXCEPTION WHEN SQLSTATE 'ZX003' THEN NULL;
  END;
  IF EXISTS(SELECT 1 FROM public.sl_users WHERE auth_subject IN(v_subject,v_other)) THEN
    RAISE EXCEPTION 'income fixtures were not rolled back'; END IF;
END;
$$;
