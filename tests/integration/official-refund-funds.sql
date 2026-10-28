-- Tests the private M3 official-source capability and shared M2 plans. Public
-- callers cannot invoke sl_post_transaction or supply refund eligibility.
DO $$
DECLARE s text:='sl-refund-'||gen_random_uuid()::text; partner_s text:='sl-refund-partner-'||gen_random_uuid()::text;
  u uuid; partner uuid; binding uuid; a uuid; result jsonb; input jsonb; first_id text; second_id text;
  before_account jsonb; before_tx jsonb; msg text; current_version bigint; movement_ids uuid[];
BEGIN
  BEGIN
    u:=public.sl_provision_user(s,'Synthetic refund')::uuid;partner:=public.sl_provision_user(partner_s,'Synthetic partner')::uuid;
    INSERT INTO public.sl_bindings DEFAULT VALUES RETURNING id INTO binding;
    INSERT INTO public.sl_binding_members(user_id,binding_id) VALUES(u,binding),(partner,binding);
    a:=(public.sl_create_account(s,repeat('a',64),repeat('a',64),'{"name":"Refund fixture","account_type":"cash","custodian":"self","opening_state":{
      "opening_date":"2026-10-01","opening_balance_minor":6000,"opening_allocations":[
      {"fund_owner":"self","fund_type":"liquid","amount_minor":1000},{"fund_owner":"self","fund_type":"savings","amount_minor":2000},
      {"fund_owner":"partner","fund_type":"savings","amount_minor":3000}]}}'::jsonb)->>'id')::uuid;
    input:=jsonb_build_object('type','expense','account_id',a::text,'amount_minor',5000,'occurred_at','2026-10-10T12:00:00+08:00','category_code','other','merchant','','note','');
    PERFORM public.sl_create_transaction(s,repeat('b',64),repeat('b',64),input);
    input:=input||'{"type":"refund","amount_minor":1500,"refund_kind":"merchant_refund","affects_spending":true}'::jsonb;
    BEGIN
      PERFORM public.sl_post_transaction(s,repeat('c',64),repeat('c',64),input,false);RAISE EXCEPTION 'manual eligibility accepted';
    EXCEPTION WHEN raise_exception THEN GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT;IF msg<>'sl_invalid_input' THEN RAISE;END IF;END;
    first_id:=public.sl_post_transaction(s,repeat('c',64),repeat('c',64),input,true)->'transaction'->>'id';
    IF (SELECT current_minor FROM public.sl_share_state(a) WHERE fund_owner_id=partner AND fund_type='savings')<>2500 OR
      (SELECT current_minor FROM public.sl_share_state(a) WHERE fund_owner_id=u AND fund_type='savings')<>0 THEN RAISE EXCEPTION 'refund did not fill partner first';END IF;
    second_id:=public.sl_post_transaction(s,repeat('d',64),repeat('d',64),input||'{"amount_minor":2000,"refund_kind":"transfer_return","affects_spending":false,"occurred_at":"2026-10-11T12:00:00+08:00"}'::jsonb,true)->'transaction'->>'id';
    IF EXISTS(SELECT 1 FROM public.sl_share_state(a) WHERE baseline_minor<>CASE WHEN fund_owner_id=partner THEN 3000 WHEN fund_type='savings' THEN 2000 ELSE 1000 END) OR
      (SELECT current_minor FROM public.sl_share_state(a) WHERE fund_owner_id=partner AND fund_type='savings')<>3000 OR
      (SELECT current_minor FROM public.sl_share_state(a) WHERE fund_owner_id=u AND fund_type='savings')<>1500 THEN RAISE EXCEPTION 'refund baseline or second priority wrong';END IF;
    before_account:=public.sl_account_json(a);
    result:=public.sl_patch_transaction(s,first_id,1,'{"affects_spending":false}'::jsonb);
    IF public.sl_account_json(a)<>before_account OR result->'account_changes'<>'[]'::jsonb THEN RAISE EXCEPTION 'toggle moved funds';END IF;
    PERFORM public.sl_patch_transaction(s,first_id,2,'{"amount_minor":1000}'::jsonb);
    IF (SELECT current_minor FROM public.sl_share_state(a) WHERE fund_owner_id=partner AND fund_type='savings')<>2500 OR
      (SELECT current_minor FROM public.sl_share_state(a) WHERE fund_owner_id=u AND fund_type='savings')<>1500 THEN RAISE EXCEPTION 'refund edit did not safely reapply current gaps';END IF;
    SELECT array_agg(m.id ORDER BY m.id) INTO movement_ids FROM public.sl_movements m JOIN public.sl_effects e ON e.id=m.effect_id WHERE e.transaction_id=first_id::uuid;
    PERFORM public.sl_patch_transaction(s,first_id,3,'{"occurred_at":"2026-10-12T12:00:00+08:00"}'::jsonb);
    IF movement_ids<>(SELECT array_agg(m.id ORDER BY m.id) FROM public.sl_movements m JOIN public.sl_effects e ON e.id=m.effect_id WHERE e.transaction_id=first_id::uuid) THEN RAISE EXCEPTION 'date-only refund edit rebuilt plan';END IF;
    before_account:=public.sl_account_json(a);SELECT to_jsonb(t) INTO before_tx FROM public.sl_transactions t WHERE id=first_id::uuid;
    BEGIN PERFORM public.sl_patch_transaction(s,first_id,4,'{"type":"expense"}'::jsonb);RAISE EXCEPTION 'refund type changed';
    EXCEPTION WHEN raise_exception THEN GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT;IF msg<>'sl_invalid_input' THEN RAISE;END IF;END;
    IF public.sl_account_json(a)<>before_account OR (SELECT to_jsonb(t) FROM public.sl_transactions t WHERE id=first_id::uuid)<>before_tx THEN RAISE EXCEPTION 'invalid type edit changed original';END IF;
    SELECT version INTO current_version FROM public.sl_accounts WHERE id=a;
    result:=public.sl_put_opening_state(s,a::text,current_version,'{"opening_date":"2026-10-01","opening_balance_minor":7000,"opening_allocations":[
      {"fund_owner":"self","fund_type":"liquid","amount_minor":2000},{"fund_owner":"self","fund_type":"savings","amount_minor":2000},
      {"fund_owner":"partner","fund_type":"savings","amount_minor":3000}]}'::jsonb);
    IF (result->>'balance_minor')::numeric<>5000 THEN RAISE EXCEPTION 'opening replay omitted independent refunds';END IF;
    PERFORM public.sl_delete_transaction(s,first_id,4);
    IF EXISTS(SELECT 1 FROM public.sl_transactions WHERE id=first_id::uuid) OR NOT EXISTS(SELECT 1 FROM public.sl_transactions WHERE id=second_id::uuid) THEN RAISE EXCEPTION 'refund delete affected unrelated refund';END IF;
    RAISE EXCEPTION USING ERRCODE='ZX005',MESSAGE='roll back successful refund fixtures';
  EXCEPTION WHEN SQLSTATE 'ZX005' THEN NULL;END;
  IF EXISTS(SELECT 1 FROM public.sl_users WHERE auth_subject IN(s,partner_s)) THEN RAISE EXCEPTION 'refund fixtures remain';END IF;
END $$;
