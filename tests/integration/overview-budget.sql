-- Independent fixed-clock expectations, not a second copy of the implementation.
DO $$
DECLARE s text:='sl-overview-'||gen_random_uuid()::text; ps text:='sl-overview-partner-'||gen_random_uuid()::text;
  u uuid;p uuid;binding uuid;a uuid;b uuid;c uuid;r jsonb;input jsonb;overview jsonb;stats jsonb;budget jsonb;msg text;
  first_page jsonb;second_page jsonb;third_page jsonb;tx_id text;
BEGIN
  BEGIN
    u:=public.sl_provision_user(s,'Synthetic overview')::uuid;p:=public.sl_provision_user(ps,'Synthetic partner')::uuid;
    INSERT INTO public.sl_bindings DEFAULT VALUES RETURNING id INTO binding;
    INSERT INTO public.sl_binding_members(user_id,binding_id) VALUES(u,binding),(p,binding);
    a:=(public.sl_create_account(s,repeat('a',64),repeat('a',64),'{"name":"Overview A","account_type":"cash","custodian":"self","opening_state":{
      "opening_date":"2026-10-01","opening_balance_minor":15000,"opening_allocations":[{"fund_owner":"self","fund_type":"liquid","amount_minor":10000},
      {"fund_owner":"self","fund_type":"savings","amount_minor":2000},{"fund_owner":"partner","fund_type":"savings","amount_minor":3000}]}}'::jsonb)->>'id')::uuid;
    b:=(public.sl_create_account(ps,repeat('a',64),repeat('a',64),'{"name":"Overview B","account_type":"cash","custodian":"self","opening_state":{
      "opening_date":"2026-10-01","opening_balance_minor":15000,"opening_allocations":[{"fund_owner":"self","fund_type":"liquid","amount_minor":4000},
      {"fund_owner":"self","fund_type":"savings","amount_minor":5000},{"fund_owner":"partner","fund_type":"savings","amount_minor":6000}]}}'::jsonb)->>'id')::uuid;
    c:=(public.sl_create_account(s,repeat('b',64),repeat('b',64),'{"name":"Overview C","account_type":"cash","custodian":"self","opening_state":{
      "opening_date":"2026-10-01","opening_balance_minor":0,"opening_allocations":[{"fund_owner":"self","fund_type":"liquid","amount_minor":0}]}}'::jsonb)->>'id')::uuid;
    input:=jsonb_build_object('type','expense','account_id',a::text,'amount_minor',3000,'occurred_at','2026-09-10T12:00:00+08:00','category_code','food','merchant','literal%merchant','note','');
    PERFORM public.sl_create_transaction(s,repeat('c',64),repeat('c',64),input);
    PERFORM public.sl_post_transaction(s,repeat('d',64),repeat('d',64),input||'{"type":"refund","amount_minor":2000,"refund_kind":"merchant_refund","affects_spending":true}'::jsonb,true);
    PERFORM public.sl_create_transaction(s,repeat('e',64),repeat('e',64),input||'{"amount_minor":10000,"occurred_at":"2026-10-03T12:00:00+08:00"}'::jsonb);
    PERFORM public.sl_post_transaction(s,repeat('f',64),repeat('f',64),input||'{"type":"refund","amount_minor":12000,"occurred_at":"2026-10-08T12:00:00+08:00","refund_kind":"merchant_refund","affects_spending":true}'::jsonb,true);
    PERFORM public.sl_create_transaction(s,repeat('0',64),repeat('0',64),input||'{"type":"income","amount_minor":1000,"occurred_at":"2026-10-05T12:00:00+08:00"}'::jsonb);
    PERFORM public.sl_create_transaction(s,repeat('1',64),repeat('1',64),jsonb_build_object('type','transfer','from_account_id',a::text,'to_account_id',c::text,
      'amount_minor',500,'occurred_at','2026-10-09T12:00:00+08:00','category_code','other','merchant','','note',''));
    PERFORM public.sl_create_transaction(s,repeat('2',64),repeat('2',64),input||'{"amount_minor":300,"occurred_at":"2026-10-20T12:00:00+08:00"}'::jsonb);
    overview:=public.sl_overview_at(s,'2026-10','2026-10-15');stats:=overview->'personal_spending';
    IF overview->>'as_of_date'<>'2026-10-15' OR overview->'funds'<>'{"my_liquid_minor":12700,"my_savings_minor":8000,"partner_liquid_minor":4000,"partner_savings_minor":8000,"visible_total_minor":32700}'::jsonb OR
      stats<>'{"expense_minor":10000,"refund_offset_minor":12000,"month_spent_minor":-2000,"daily_average_minor":-133,"previous_month_daily_average_minor":33,"daily_change_minor":-167,"daily_change_rate":-5.0000,"projected_month_spending_minor":-4133}'::jsonb OR overview->'budget'<>'null'::jsonb THEN
      RAISE EXCEPTION 'fixed-clock overview mismatch: %',overview;END IF;
    budget:=public.sl_put_budget(s,'2026-10','{"budget_minor":5000,"expected_version":0}'::jsonb);
    IF (budget->>'version')::bigint<>1 OR public.sl_put_budget(s,'2026-10','{"budget_minor":5000,"expected_version":1}'::jsonb)<>budget THEN RAISE EXCEPTION 'budget no-op changed version';END IF;
    BEGIN PERFORM public.sl_put_budget(s,'2026-10','{"budget_minor":1,"expected_version":0}'::jsonb);RAISE EXCEPTION 'stale budget accepted';
    EXCEPTION WHEN raise_exception THEN GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT;IF msg<>'sl_resource_conflict' THEN RAISE;END IF;END;
    overview:=public.sl_overview_at(s,'2026-10','2026-10-15');
    IF overview->'budget'<>'{"budget_minor":5000,"spent_minor":-2000,"remaining_minor":7000,"over_budget_minor":0,"status":"within_budget"}'::jsonb THEN RAISE EXCEPTION 'negative spending budget was clamped';END IF;
    IF public.sl_get_budget(ps,'2026-10') IS NOT NULL THEN RAISE EXCEPTION 'partner budget leaked';END IF;
    PERFORM public.sl_put_budget(s,'2027-01','{"budget_minor":0,"expected_version":0}'::jsonb);
    BEGIN PERFORM public.sl_overview_at(s,'2026-11','2026-10-15');RAISE EXCEPTION 'future overview accepted';
    EXCEPTION WHEN raise_exception THEN GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT;IF msg<>'sl_invalid_input' THEN RAISE;END IF;END;
    overview:=public.sl_overview_at(s,'2026-09','2026-10-15');
    IF overview->>'as_of_date'<>'2026-09-30' OR (overview->'personal_spending'->>'projected_month_spending_minor')::numeric<>1000 OR
      overview->'personal_spending'->'daily_change_rate'<>'null'::jsonb THEN RAISE EXCEPTION 'historical projection or zero divisor wrong';END IF;
    -- Equal timestamps are disambiguated by UUID; pages are authorized before the cursor is applied.
    first_page:=public.sl_transactions_page(s,'mine',1,'{}'::jsonb);
    second_page:=public.sl_transactions_page(s,'mine',1,'{}'::jsonb,(first_page->'next'->>'time')::timestamptz,(first_page->'next'->>'id')::uuid);
    IF first_page->'data'->0->>'id'=second_page->'data'->0->>'id' THEN RAISE EXCEPTION 'transaction page repeated row';END IF;
    r:=public.sl_transactions_page(s,'mine',100,jsonb_build_object('account_id',c::text,'type','transfer'));
    IF jsonb_array_length(r->'data')<>1 THEN RAISE EXCEPTION 'transfer target account filter failed';END IF;
    r:=public.sl_transactions_page(s,'mine',100,'{"q":"%"}'::jsonb);
    IF jsonb_array_length(r->'data')<>6 THEN RAISE EXCEPTION 'literal substring filter treated percent as wildcard';END IF;
    r:=public.sl_transactions_page(s,'mine',100,jsonb_build_object('account_id',b::text));
    IF r->'data'<>'[]'::jsonb THEN RAISE EXCEPTION 'foreign account filter leaked rows';END IF;
    first_page:=public.sl_accounts_page(s,'mine',1);second_page:=public.sl_accounts_page(s,'mine',1,(first_page->'next'->>'time')::timestamptz,(first_page->'next'->>'id')::uuid);
    IF first_page->'data'->0->>'id'=second_page->'data'->0->>'id' OR second_page->'next'<>'null'::jsonb THEN RAISE EXCEPTION 'account pagination boundary wrong';END IF;
    r:=public.sl_transactions_page(ps,'partner',100,'{}'::jsonb);
    IF EXISTS(SELECT 1 FROM jsonb_array_elements(r->'data') x WHERE x->>'read_only'<>'true' OR x->'source_summaries'<>'[]'::jsonb) THEN RAISE EXCEPTION 'partner list became writable';END IF;
    RAISE EXCEPTION USING ERRCODE='ZX006',MESSAGE='roll back successful overview fixtures';
  EXCEPTION WHEN SQLSTATE 'ZX006' THEN NULL;END;
  IF EXISTS(SELECT 1 FROM public.sl_users WHERE auth_subject IN(s,ps)) THEN RAISE EXCEPTION 'overview fixtures remain';END IF;
END $$;
