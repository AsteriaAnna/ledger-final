-- Risk-focused lifecycle suite. The enclosing subtransaction rolls back on
-- both success and failure, including effects, versions and idempotency rows.
DO $$
DECLARE s text:='sl-transfer-'||gen_random_uuid()::text; other_s text:='sl-transfer-other-'||gen_random_uuid()::text;
  u uuid; other_u uuid; binding uuid; a uuid; b uuid; c uuid; other_a uuid; capped uuid;
  input jsonb; result jsonb; created jsonb; before_a jsonb; before_b jsonb; facts jsonb;
  tx text; spent text; msg text; v bigint; original_order bigint; movement_ids uuid[];
BEGIN
  BEGIN
    u:=public.sl_provision_user(s,'Synthetic transfer')::uuid;
    other_u:=public.sl_provision_user(other_s,'Synthetic partner')::uuid;
    INSERT INTO public.sl_bindings DEFAULT VALUES RETURNING id INTO binding;
    INSERT INTO public.sl_binding_members(user_id,binding_id) VALUES(u,binding),(other_u,binding);
    input:='{"name":"Source","account_type":"cash","custodian":"self","opening_state":{
      "opening_date":"2026-10-01","opening_balance_minor":20000,"opening_allocations":[
      {"fund_owner":"self","fund_type":"liquid","amount_minor":10000},
      {"fund_owner":"self","fund_type":"savings","amount_minor":5000},
      {"fund_owner":"partner","fund_type":"savings","amount_minor":5000}]}}'::jsonb;
    a:=(public.sl_create_account(s,repeat('a',64),repeat('a',64),input)->>'id')::uuid;
    input:='{"name":"Destination","account_type":"cash","custodian":"self","opening_state":{
      "opening_date":"2026-10-20","opening_balance_minor":1000,"opening_allocations":[
      {"fund_owner":"self","fund_type":"liquid","amount_minor":1000}]}}'::jsonb;
    b:=(public.sl_create_account(s,repeat('b',64),repeat('b',64),input)->>'id')::uuid;
    c:=(public.sl_create_account(s,repeat('c',64),repeat('c',64),input)->>'id')::uuid;
    other_a:=(public.sl_create_account(other_s,repeat('a',64),repeat('a',64),input)->>'id')::uuid;
    before_a:=public.sl_account_json(a); before_b:=public.sl_account_json(b);
    input:=jsonb_build_object('type','transfer','from_account_id',a::text,'to_account_id',b::text,
      'amount_minor',11000,'occurred_at','2026-10-25T12:00:00+08:00','category_code','other','merchant','','note','');
    BEGIN
      PERFORM public.sl_create_transaction(s,repeat('d',64),repeat('d',64),input);
      RAISE EXCEPTION 'transfer silently used savings';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT; IF msg<>'sl_insufficient_funds' THEN RAISE; END IF;
    END;
    IF public.sl_account_json(a)<>before_a OR public.sl_account_json(b)<>before_b OR
      EXISTS(SELECT 1 FROM public.sl_transactions WHERE owner_id=u) OR
      EXISTS(SELECT 1 FROM public.sl_requests WHERE actor_id=u AND path='/api/v1/transactions') THEN
      RAISE EXCEPTION 'failed transfer partially committed'; END IF;
    input:=jsonb_set(input,'{amount_minor}','2000'::jsonb);
    created:=public.sl_create_transaction(s,repeat('d',64),repeat('d',64),input); tx:=created->'transaction'->>'id';
    SELECT min(replay_order) INTO original_order FROM public.sl_effects WHERE transaction_id=tx::uuid;
    IF created->'transaction'->>'accounting_semantics'<>'internal_transfer' OR created->'transaction' ? 'account_id' OR
      jsonb_array_length(created->'account_effects')<>2 OR jsonb_array_length(created->'account_changes')<>2 OR
      (public.sl_account_json(a)->>'balance_minor')::numeric<>18000 OR (public.sl_account_json(b)->>'balance_minor')::numeric<>3000 OR
      EXISTS(SELECT 1 FROM public.sl_movements m JOIN public.sl_effects e ON e.id=m.effect_id
        WHERE e.transaction_id=tx::uuid AND (m.fund_owner_id<>u OR m.fund_type<>'liquid')) OR
      (SELECT sum(signed_amount_minor) FROM public.sl_effects WHERE transaction_id=tx::uuid)<>0 THEN
      RAISE EXCEPTION 'transfer violated owner, amount or response shape'; END IF;
    IF public.sl_create_transaction(s,repeat('d',64),repeat('d',64),input)<>created THEN RAISE EXCEPTION 'retry duplicated transfer'; END IF;
    result:=public.sl_get_transaction_visible(other_s,tx);
    IF result->>'read_only'<>'true' OR result->'source_summaries'<>'[]'::jsonb THEN RAISE EXCEPTION 'partner projection failed'; END IF;
    BEGIN
      PERFORM public.sl_patch_transaction(other_s,tx,1,'{"amount_minor":1}'::jsonb);
      RAISE EXCEPTION 'partner changed transfer';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT; IF msg<>'sl_transaction_not_found' THEN RAISE; END IF;
    END;
    BEGIN
      PERFORM public.sl_create_transaction(s,repeat('e',64),repeat('e',64),jsonb_set(input,'{to_account_id}',to_jsonb(other_a::text)));
      RAISE EXCEPTION 'transfer wrote partner account';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT; IF msg<>'sl_account_not_found' THEN RAISE; END IF;
    END;
    before_a:=public.sl_account_json(a); before_b:=public.sl_account_json(b);
    SELECT array_agg(m.id ORDER BY m.id) INTO movement_ids FROM public.sl_movements m
      JOIN public.sl_effects e ON e.id=m.effect_id WHERE e.transaction_id=tx::uuid;
    result:=public.sl_patch_transaction(s,tx,1,'{"note":"metadata"}'::jsonb);
    IF result->'account_changes'<>'[]'::jsonb OR public.sl_account_json(a)<>before_a OR public.sl_account_json(b)<>before_b THEN
      RAISE EXCEPTION 'metadata changed funds/version'; END IF;
    result:=public.sl_patch_transaction(s,tx,2,'{}'::jsonb);
    IF (result->'transaction'->>'version')::bigint<>2 THEN RAISE EXCEPTION 'no-op changed version'; END IF;
    BEGIN
      PERFORM public.sl_patch_transaction(s,tx,1,'{}'::jsonb); RAISE EXCEPTION 'stale no-op accepted';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT; IF msg<>'sl_version_mismatch' THEN RAISE; END IF;
    END;
    result:=public.sl_patch_transaction(s,tx,2,'{"occurred_at":"2026-10-24T12:00:00+08:00"}'::jsonb);
    IF result->'account_changes'<>'[]'::jsonb OR movement_ids<>(SELECT array_agg(m.id ORDER BY m.id)
      FROM public.sl_movements m JOIN public.sl_effects e ON e.id=m.effect_id WHERE e.transaction_id=tx::uuid) THEN
      RAISE EXCEPTION 'date-only edit rebuilt unchanged plans'; END IF;
    -- Only destination crosses its boundary; source plan and version stay intact.
    before_a:=public.sl_account_json(a);
    result:=public.sl_patch_transaction(s,tx,3,'{"occurred_at":"2026-10-15T12:00:00+08:00"}'::jsonb);
    IF public.sl_account_json(a)<>before_a OR jsonb_array_length(result->'account_changes')<>1 OR
      (public.sl_account_json(b)->>'balance_minor')::numeric<>1000 OR
      (SELECT status FROM public.sl_effects WHERE transaction_id=tx::uuid AND role='to')<>'historical_only' THEN
      RAISE EXCEPTION 'date crossing changed wrong endpoint'; END IF;
    -- Change both endpoints to historical, then only destination applied, then both.
    PERFORM public.sl_patch_transaction(s,tx,4,'{"occurred_at":"2026-09-20T12:00:00+08:00"}'::jsonb);
    IF EXISTS(SELECT 1 FROM public.sl_effects WHERE transaction_id=tx::uuid AND status='applied') THEN RAISE EXCEPTION 'both historical not preserved'; END IF;
    PERFORM public.sl_patch_transaction(s,tx,5,jsonb_build_object('from_account_id',b::text,'to_account_id',a::text,
      'occurred_at','2026-10-15T12:00:00+08:00'));
    IF (SELECT status FROM public.sl_effects WHERE transaction_id=tx::uuid AND role='from')<>'historical_only' OR
      (public.sl_account_json(a)->>'balance_minor')::numeric<>22000 THEN RAISE EXCEPTION 'independent source boundary failed'; END IF;
    PERFORM public.sl_patch_transaction(s,tx,6,jsonb_build_object('from_account_id',a::text,'to_account_id',b::text,
      'occurred_at','2026-10-25T12:00:00+08:00','amount_minor',3000));
    IF (SELECT min(replay_order) FROM public.sl_effects WHERE transaction_id=tx::uuid)<>original_order THEN RAISE EXCEPTION 'edit lost original order'; END IF;
    -- Received liquid is spent: reversal must reject the whole transfer, even an increase.
    spent:=public.sl_create_transaction(s,repeat('f',64),repeat('f',64),jsonb_build_object('type','expense','account_id',b::text,
      'amount_minor',3500,'occurred_at','2026-10-26T12:00:00+08:00','category_code','other','merchant','','note',''))->'transaction'->>'id';
    before_a:=public.sl_account_json(a); before_b:=public.sl_account_json(b);
    SELECT to_jsonb(t) INTO facts FROM public.sl_transactions t WHERE id=tx::uuid;
    BEGIN
      PERFORM public.sl_delete_transaction(s,tx,7); RAISE EXCEPTION 'spent transfer deleted';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT; IF msg<>'sl_unsafe_reversal' THEN RAISE; END IF;
    END;
    BEGIN
      PERFORM public.sl_patch_transaction(s,tx,7,'{"amount_minor":4000,"note":"must roll back"}'::jsonb);
      RAISE EXCEPTION 'spent transfer increase bypassed reversal';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT; IF msg<>'sl_unsafe_reversal' THEN RAISE; END IF;
    END;
    IF public.sl_account_json(a)<>before_a OR public.sl_account_json(b)<>before_b OR
      (SELECT to_jsonb(t) FROM public.sl_transactions t WHERE id=tx::uuid)<>facts THEN RAISE EXCEPTION 'unsafe reversal partially committed'; END IF;
    PERFORM public.sl_delete_transaction(s,spent,1);
    -- Change transfer -> ordinary -> transfer; no old endpoint effects may remain.
    PERFORM public.sl_patch_transaction(s,tx,7,jsonb_build_object('type','expense','account_id',a::text,'amount_minor',1000));
    IF (SELECT count(*) FROM public.sl_effects WHERE transaction_id=tx::uuid)<>1 THEN RAISE EXCEPTION 'type change left stale endpoints'; END IF;
    PERFORM public.sl_patch_transaction(s,tx,8,jsonb_build_object('type','transfer','from_account_id',a::text,'to_account_id',c::text));
    before_b:=public.sl_account_json(c);
    -- Rebuilding source opening changes only that source endpoint, not c or facts.
    SELECT version INTO v FROM public.sl_accounts WHERE id=a;
    SELECT to_jsonb(t) INTO facts FROM public.sl_transactions t WHERE id=tx::uuid;
    result:=public.sl_put_opening_state(s,a::text,v,'{"opening_date":"2026-10-26","opening_balance_minor":20000,
      "opening_allocations":[{"fund_owner":"self","fund_type":"liquid","amount_minor":10000},
      {"fund_owner":"self","fund_type":"savings","amount_minor":5000},
      {"fund_owner":"partner","fund_type":"savings","amount_minor":5000}]}'::jsonb);
    IF (result->>'balance_minor')::numeric<>20000 OR public.sl_account_json(c)<>before_b OR
      (SELECT to_jsonb(t) FROM public.sl_transactions t WHERE id=tx::uuid)<>facts THEN RAISE EXCEPTION 'opening replay changed opposite endpoint or fact'; END IF;
    SELECT version INTO v FROM public.sl_accounts WHERE id=a;
    PERFORM public.sl_put_opening_state(s,a::text,v,jsonb_set(result->'opening_state','{opening_date}','"2026-10-01"'::jsonb));
    IF (public.sl_account_json(a)->>'balance_minor')::numeric<>19000 OR public.sl_account_json(c)<>before_b THEN RAISE EXCEPTION 'transfer replay activation failed'; END IF;
    before_a:=public.sl_account_json(a);
    SELECT version INTO v FROM public.sl_accounts WHERE id=a;
    BEGIN
      PERFORM public.sl_put_opening_state(s,a::text,v,'{"opening_date":"2026-10-01","opening_balance_minor":20000,
        "opening_allocations":[{"fund_owner":"self","fund_type":"savings","amount_minor":20000}]}'::jsonb);
      RAISE EXCEPTION 'transfer replay silently consumed savings';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT; IF msg<>'sl_opening_recalculation_conflict' THEN RAISE; END IF;
    END;
    IF public.sl_account_json(a)<>before_a OR public.sl_account_json(c)<>before_b THEN RAISE EXCEPTION 'failed replay changed endpoints'; END IF;
    PERFORM public.sl_delete_transaction(s,tx,9);
    IF (public.sl_account_json(a)->>'balance_minor')::numeric<>20000 OR (public.sl_account_json(c)->>'balance_minor')::numeric<>1000 THEN
      RAISE EXCEPTION 'safe transfer delete did not restore both endpoints'; END IF;
    -- Destination overflow occurs after source processing; neither endpoint nor
    -- the failed idempotency key may remain changed.
    capped:=(public.sl_create_account(s,repeat('9',64),repeat('9',64),'{"name":"Capped","account_type":"cash","custodian":"self",
      "opening_state":{"opening_date":"2026-10-01","opening_balance_minor":9007199254740991,"opening_allocations":[
      {"fund_owner":"self","fund_type":"liquid","amount_minor":9007199254740991}]}}'::jsonb)->>'id')::uuid;
    before_a:=public.sl_account_json(a); before_b:=public.sl_account_json(capped);
    BEGIN
      PERFORM public.sl_create_transaction(s,repeat('8',64),repeat('8',64),jsonb_build_object('type','transfer',
        'from_account_id',a::text,'to_account_id',capped::text,'amount_minor',1,'occurred_at','2026-10-25T12:00:00+08:00',
        'category_code','other','merchant','','note',''));
      RAISE EXCEPTION 'destination overflow accepted';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT; IF msg<>'sl_insufficient_funds' THEN RAISE; END IF;
    END;
    IF public.sl_account_json(a)<>before_a OR public.sl_account_json(capped)<>before_b OR
      EXISTS(SELECT 1 FROM public.sl_requests WHERE actor_id=u AND path='/api/v1/transactions' AND key_digest=repeat('8',64)) THEN
      RAISE EXCEPTION 'destination failure left half a transfer'; END IF;
    RAISE EXCEPTION USING ERRCODE='ZX004',MESSAGE='roll back successful transfer fixtures';
  EXCEPTION WHEN SQLSTATE 'ZX004' THEN NULL;
  END;
  IF EXISTS(SELECT 1 FROM public.sl_users WHERE auth_subject IN(s,other_s)) THEN RAISE EXCEPTION 'transfer fixtures remain'; END IF;
END;
$$;
