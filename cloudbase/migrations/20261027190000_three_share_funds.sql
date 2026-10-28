-- M2 funds helpers are the single runtime implementation of deduction/replenishment.
-- No public API or table layout changes. Existing movements retain their owners.

CREATE FUNCTION public.sl_share_owner(p_actor uuid,p_ref jsonb) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_partner uuid;
BEGIN
  IF coalesce(jsonb_typeof(p_ref),'null')<>'object' OR
    EXISTS (SELECT 1 FROM jsonb_object_keys(p_ref) AS k(name) WHERE name NOT IN ('fund_owner','fund_type')) THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  IF p_ref->>'fund_owner'='self' AND p_ref->>'fund_type' IN ('liquid','savings') THEN RETURN p_actor; END IF;
  IF p_ref->>'fund_owner'='partner' AND p_ref->>'fund_type'='savings' THEN
    v_partner:=public.sl_partner_id(p_actor);
    IF v_partner IS NULL THEN RAISE EXCEPTION 'sl_relationship_conflict'; END IF;
    RETURN v_partner;
  END IF;
  RAISE EXCEPTION 'sl_invalid_input';
END;
$$;

CREATE FUNCTION public.sl_share_state(p_account uuid)
RETURNS TABLE(fund_owner_id uuid,fund_type text,current_minor numeric,baseline_minor numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT m.fund_owner_id,m.fund_type,sum(m.signed_amount_minor),
    COALESCE(sum(m.signed_amount_minor) FILTER (WHERE m.reason IN ('opening','adjustment')),0)
  FROM public.sl_movements m WHERE m.account_id=p_account GROUP BY m.fund_owner_id,m.fund_type;
$$;

CREATE FUNCTION public.sl_assert_funds(p_account uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.sl_share_state(p_account)
    WHERE current_minor<0 OR current_minor>9007199254740991 OR
      (fund_type='savings' AND (baseline_minor<0 OR baseline_minor>9007199254740991))) OR
    (SELECT COALESCE(sum(current_minor),0) FROM public.sl_share_state(p_account))>9007199254740991 THEN
    RAISE EXCEPTION 'sl_insufficient_funds'; END IF;
END;
$$;

CREATE FUNCTION public.sl_record_expense_delta(p_account uuid,p_actor uuid,p_effect uuid,
  p_group uuid,p_time timestamptz,p_amount numeric,p_replenish boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_partner uuid:=public.sl_partner_id(p_actor); s record; v_current numeric;
  v_baseline numeric; v_limit numeric; v_take numeric; v_remaining numeric:=p_amount;
  v_notices jsonb:='[]'::jsonb;
BEGIN
  IF p_amount IS NULL OR p_amount<=0 OR p_amount<>trunc(p_amount) OR p_amount>9007199254740991 THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  FOR s IN SELECT * FROM (VALUES
    (p_actor,'liquid',CASE WHEN p_replenish THEN 3 ELSE 1 END),
    (p_actor,'savings',2),
    (v_partner,'savings',CASE WHEN p_replenish THEN 1 ELSE 3 END)) AS x(owner_id,kind,priority)
    ORDER BY priority LOOP
    CONTINUE WHEN s.owner_id IS NULL OR v_remaining=0;
    SELECT current_minor,baseline_minor INTO v_current,v_baseline FROM public.sl_share_state(p_account)
      WHERE fund_owner_id=s.owner_id AND fund_type=s.kind;
    v_current:=COALESCE(v_current,0); v_baseline:=COALESCE(v_baseline,0);
    v_limit:=CASE WHEN NOT p_replenish THEN v_current WHEN s.kind='liquid' THEN v_remaining
      ELSE greatest(v_baseline-v_current,0) END;
    v_take:=least(v_limit,v_remaining);
    IF v_take>0 THEN
      INSERT INTO public.sl_movements(account_id,fund_owner_id,fund_type,signed_amount_minor,
        reason,operation_group,effect_id,effective_at)
        VALUES(p_account,s.owner_id,s.kind,CASE WHEN p_replenish THEN v_take ELSE -v_take END,
          'transaction',p_group,p_effect,p_time);
      v_remaining:=v_remaining-v_take;
      IF NOT p_replenish AND s.kind='savings' THEN
        v_notices:=v_notices||jsonb_build_array(jsonb_build_object('code',
          CASE WHEN s.owner_id=p_actor THEN 'OWN_SAVINGS_USED' ELSE 'PARTNER_SAVINGS_USED' END,
          'amount_minor',v_take));
      END IF;
    END IF;
  END LOOP;
  IF v_remaining<>0 THEN RAISE EXCEPTION 'sl_insufficient_funds'; END IF;
  PERFORM public.sl_assert_funds(p_account);
  RETURN v_notices;
END;
$$;

CREATE FUNCTION public.sl_assert_effect_reversal(p_effect uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_account uuid;
BEGIN
  SELECT account_id INTO v_account FROM public.sl_effects WHERE id=p_effect;
  IF EXISTS (SELECT 1 FROM
    (SELECT fund_owner_id,fund_type,sum(signed_amount_minor) AS effect_minor
      FROM public.sl_movements WHERE effect_id=p_effect GROUP BY fund_owner_id,fund_type) e
    LEFT JOIN public.sl_share_state(v_account) s USING(fund_owner_id,fund_type)
    WHERE COALESCE(s.current_minor,0)-e.effect_minor<0) THEN
    RAISE EXCEPTION 'sl_unsafe_reversal'; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.sl_account_json(p_account_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.sl_accounts%ROWTYPE; v_opening jsonb; v_shares jsonb; v_balance numeric;
BEGIN
  SELECT * INTO a FROM public.sl_accounts WHERE id=p_account_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_account_not_found'; END IF;
  SELECT COALESCE(sum(current_minor),0) INTO v_balance FROM public.sl_share_state(a.id);
  SELECT COALESCE(jsonb_agg(jsonb_build_object('fund_owner',
    CASE WHEN fund_owner_id=a.holder_user_id THEN 'self' ELSE 'partner' END,
    'fund_type',fund_type,'amount_minor',amount_minor)
    ORDER BY CASE WHEN fund_owner_id=a.holder_user_id AND fund_type='liquid' THEN 1
      WHEN fund_owner_id=a.holder_user_id THEN 2 ELSE 3 END),'[]'::jsonb) INTO v_opening
    FROM (SELECT fund_owner_id,fund_type,sum(signed_amount_minor) AS amount_minor
      FROM public.sl_movements WHERE account_id=a.id AND reason='opening' GROUP BY fund_owner_id,fund_type) x;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('fund_owner',
    CASE WHEN fund_owner_id=a.holder_user_id THEN 'self' ELSE 'partner' END,
    'fund_type',fund_type,'amount_minor',current_minor,
    'savings_baseline_minor',CASE WHEN fund_type='savings' THEN baseline_minor ELSE NULL END,
    'savings_gap_minor',CASE WHEN fund_type='savings' THEN greatest(baseline_minor-current_minor,0) ELSE NULL END)
    ORDER BY CASE WHEN fund_owner_id=a.holder_user_id AND fund_type='liquid' THEN 1
      WHEN fund_owner_id=a.holder_user_id THEN 2 ELSE 3 END),'[]'::jsonb) INTO v_shares
    FROM public.sl_share_state(a.id);
  RETURN jsonb_build_object('id',a.id::text,'name',a.name,'account_type',a.account_type,
    'holder','self','custodian',CASE WHEN a.custodian_user_id=a.holder_user_id THEN 'self' ELSE 'partner' END,
    'opening_state',jsonb_build_object('opening_date',a.opening_date::text,
      'opening_balance_minor',(SELECT COALESCE(sum(signed_amount_minor),0) FROM public.sl_movements
        WHERE account_id=a.id AND reason='opening'),'opening_allocations',v_opening),
    'balance_minor',v_balance,'fund_shares',v_shares,'version',a.version,'read_only',false);
END;
$$;

CREATE OR REPLACE FUNCTION public.sl_create_account(p_actor_subject text,p_key_digest text,
  p_payload_hash text,p_input jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_account uuid; v_prior jsonb; v_prior_hash text; v_alloc jsonb;
  v_amount numeric; v_total numeric:=0; v_seen text[]:='{}'; v_share text; v_owner uuid;
  v_open_date date; v_balance numeric; v_result jsonb; v_custodian uuid;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  IF p_key_digest IS NULL OR p_payload_hash IS NULL OR p_key_digest !~ '^[0-9a-f]{64}$' OR
    p_payload_hash !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  SELECT response_body,payload_hash INTO v_prior,v_prior_hash FROM public.sl_requests
    WHERE actor_id=v_actor AND method='POST' AND path='/api/v1/accounts' AND key_digest=p_key_digest;
  IF FOUND THEN
    IF v_prior_hash<>p_payload_hash THEN RAISE EXCEPTION 'sl_idempotency_conflict'; END IF;
    RETURN v_prior;
  END IF;
  IF p_input->>'custodian' NOT IN ('self','partner') OR p_input->>'name' IS NULL OR
    p_input->>'account_type' NOT IN ('cash','bank_card','wechat_balance','alipay_balance','other') THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  v_custodian:=CASE WHEN p_input->>'custodian'='self' THEN v_actor ELSE public.sl_partner_id(v_actor) END;
  IF v_custodian IS NULL THEN RAISE EXCEPTION 'sl_relationship_conflict'; END IF;
  BEGIN
    v_open_date:=(p_input->'opening_state'->>'opening_date')::date;
    v_balance:=(p_input->'opening_state'->>'opening_balance_minor')::numeric;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'sl_invalid_input'; END;
  IF v_open_date IS NULL OR v_open_date>(now() AT TIME ZONE 'Asia/Shanghai')::date OR
    v_balance IS NULL OR v_balance<0 OR v_balance<>trunc(v_balance) OR v_balance>9007199254740991 OR
    coalesce(jsonb_typeof(p_input->'opening_state'->'opening_allocations'),'null')<>'array' THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  INSERT INTO public.sl_accounts(holder_user_id,custodian_user_id,name,account_type,opening_date)
    VALUES(v_actor,v_custodian,p_input->>'name',p_input->>'account_type',v_open_date) RETURNING id INTO v_account;
  FOR v_alloc IN SELECT value FROM jsonb_array_elements(p_input->'opening_state'->'opening_allocations') LOOP
    v_owner:=public.sl_share_owner(v_actor,v_alloc-'amount_minor');
    v_share:=(v_alloc->>'fund_owner')||':'||(v_alloc->>'fund_type');
    IF v_share=ANY(v_seen) THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
    BEGIN v_amount:=(v_alloc->>'amount_minor')::numeric;
    EXCEPTION WHEN others THEN RAISE EXCEPTION 'sl_invalid_input'; END;
    IF v_amount IS NULL OR v_amount<0 OR v_amount<>trunc(v_amount) OR v_amount>9007199254740991 THEN
      RAISE EXCEPTION 'sl_invalid_input'; END IF;
    v_seen:=array_append(v_seen,v_share); v_total:=v_total+v_amount;
    INSERT INTO public.sl_movements(account_id,fund_owner_id,fund_type,signed_amount_minor,reason,operation_group,effective_at)
      VALUES(v_account,v_owner,v_alloc->>'fund_type',v_amount,'opening',v_account,
        v_open_date::timestamp AT TIME ZONE 'Asia/Shanghai');
  END LOOP;
  IF cardinality(v_seen) NOT BETWEEN 1 AND 3 OR v_total<>v_balance THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  PERFORM public.sl_assert_funds(v_account);
  v_result:=public.sl_account_json(v_account);
  INSERT INTO public.sl_requests(actor_id,method,path,key_digest,payload_hash,response_body)
    VALUES(v_actor,'POST','/api/v1/accounts',p_key_digest,p_payload_hash,v_result);
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.sl_adjust_funds(p_actor_subject text,p_account_id text,
  p_key_digest text,p_payload_hash text,p_expected_version bigint,p_input jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; a public.sl_accounts%ROWTYPE; v_id uuid; v_path text;
  v_prior jsonb; v_prior_hash text; v_from uuid; v_to uuid; v_from_type text; v_to_type text;
  v_amount numeric; v_available numeric; v_group uuid; v_result jsonb;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  IF p_key_digest IS NULL OR p_payload_hash IS NULL OR p_key_digest !~ '^[0-9a-f]{64}$' OR
    p_payload_hash !~ '^[0-9a-f]{64}$' OR p_expected_version IS NULL OR p_expected_version<1 THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  BEGIN v_id:=p_account_id::uuid;
  EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_account_not_found'; END;
  v_path:='/api/v1/accounts/'||v_id::text||'/fund-adjustments';
  SELECT response_body,payload_hash INTO v_prior,v_prior_hash FROM public.sl_requests
    WHERE actor_id=v_actor AND method='POST' AND path=v_path AND key_digest=p_key_digest;
  IF FOUND THEN
    IF v_prior_hash<>p_payload_hash THEN RAISE EXCEPTION 'sl_idempotency_conflict'; END IF;
    RETURN v_prior;
  END IF;
  SELECT * INTO a FROM public.sl_accounts WHERE id=v_id AND holder_user_id=v_actor FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_account_not_found'; END IF;
  IF a.version<>p_expected_version THEN RAISE EXCEPTION 'sl_version_mismatch'; END IF;
  v_from:=public.sl_share_owner(v_actor,p_input->'from'); v_to:=public.sl_share_owner(v_actor,p_input->'to');
  v_from_type:=p_input->'from'->>'fund_type'; v_to_type:=p_input->'to'->>'fund_type';
  BEGIN v_amount:=(p_input->>'amount_minor')::numeric;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'sl_invalid_input'; END;
  IF (v_from=v_to AND v_from_type=v_to_type) OR v_amount IS NULL OR v_amount<=0 OR
    v_amount<>trunc(v_amount) OR v_amount>9007199254740991 THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  SELECT COALESCE(sum(current_minor),0) INTO v_available FROM public.sl_share_state(v_id)
    WHERE fund_owner_id=v_from AND fund_type=v_from_type;
  IF v_available<v_amount THEN RAISE EXCEPTION 'sl_insufficient_funds'; END IF;
  v_group:=gen_random_uuid();
  INSERT INTO public.sl_movements(account_id,fund_owner_id,fund_type,signed_amount_minor,reason,operation_group,effective_at)
    VALUES(v_id,v_from,v_from_type,-v_amount,'adjustment',v_group,now()),
          (v_id,v_to,v_to_type,v_amount,'adjustment',v_group,now());
  PERFORM public.sl_assert_funds(v_id);
  UPDATE public.sl_accounts SET version=version+1,funds_revision=funds_revision+1 WHERE id=v_id;
  v_result:=public.sl_account_json(v_id);
  INSERT INTO public.sl_requests(actor_id,method,path,key_digest,payload_hash,response_body)
    VALUES(v_actor,'POST',v_path,p_key_digest,p_payload_hash,v_result);
  RETURN v_result;
END;
$$;

-- Expense entry points follow below. Helpers are private even to service_role.

CREATE OR REPLACE FUNCTION public.sl_create_expense(p_actor_subject text, p_key_digest text, p_payload_hash text, p_input jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_account public.sl_accounts%ROWTYPE; v_transaction uuid; v_effect uuid;
  v_prior jsonb; v_prior_hash text; v_amount numeric; v_liquid numeric; v_savings numeric;
  v_use_liquid numeric; v_use_savings numeric; v_occurred timestamptz; v_applied boolean;
  v_mutation jsonb; v_account_json jsonb; v_notice jsonb:='[]'::jsonb; v_effect_json jsonb;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  IF p_key_digest !~ '^[0-9a-f]{64}$' OR p_payload_hash !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  SELECT response_body,payload_hash INTO v_prior,v_prior_hash FROM public.sl_requests
    WHERE actor_id=v_actor AND method='POST' AND path='/api/v1/transactions' AND key_digest=p_key_digest;
  IF FOUND THEN
    IF v_prior_hash<>p_payload_hash THEN RAISE EXCEPTION 'sl_idempotency_conflict'; END IF;
    RETURN v_prior;
  END IF;
  IF p_input->>'type'<>'expense' OR p_input->>'account_id' IS NULL OR
    p_input->>'category_code' NOT IN ('food','shopping','transport','education','health','entertainment','utilities','other') THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  BEGIN
    v_amount := (p_input->>'amount_minor')::numeric;
    v_occurred := (p_input->>'occurred_at')::timestamptz;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'sl_invalid_input'; END;
  IF v_amount IS NULL OR v_amount<=0 OR v_amount<>trunc(v_amount) OR v_amount>9007199254740991 OR v_occurred IS NULL OR v_occurred>now() THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  BEGIN
    SELECT * INTO v_account FROM public.sl_accounts WHERE id=(p_input->>'account_id')::uuid AND holder_user_id=v_actor FOR UPDATE;
  EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_account_not_found'; END;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_account_not_found'; END IF;
  v_applied := (v_occurred AT TIME ZONE 'Asia/Shanghai')::date >= v_account.opening_date;
  INSERT INTO public.sl_transactions(owner_id,type,accounting_semantics,amount_minor,occurred_at,category_code,merchant,note)
    VALUES(v_actor,'expense','ordinary',v_amount,v_occurred,p_input->>'category_code',p_input->>'merchant',p_input->>'note')
    RETURNING id INTO v_transaction;
  INSERT INTO public.sl_effects(transaction_id,account_id,role,signed_amount_minor,status)
    VALUES(v_transaction,v_account.id,'primary',-v_amount,CASE WHEN v_applied THEN 'applied' ELSE 'historical_only' END)
    RETURNING id INTO v_effect;
  IF v_applied THEN
    v_notice:=public.sl_record_expense_delta(v_account.id,v_actor,v_effect,v_transaction,v_occurred,v_amount,false);
    UPDATE public.sl_accounts SET version=version+1,funds_revision=funds_revision+1 WHERE id=v_account.id;
  END IF;
  v_effect_json:=jsonb_build_object('account_id',v_account.id::text,'role','primary',
    'status',CASE WHEN v_applied THEN 'applied' ELSE 'historical_only' END,'signed_amount_minor',-v_amount);
  v_account_json:=public.sl_account_json(v_account.id);
  v_mutation:=jsonb_build_object('transaction',public.sl_transaction_json(v_transaction),
    'account_effects',jsonb_build_array(v_effect_json),
    'account_changes',CASE WHEN v_applied THEN jsonb_build_array(jsonb_build_object('account_id',v_account.id::text,
      'balance_minor',v_account_json->'balance_minor','fund_shares',v_account_json->'fund_shares','version',v_account_json->'version')) ELSE '[]'::jsonb END,
    'affected_months',jsonb_build_array(to_char(v_occurred AT TIME ZONE 'Asia/Shanghai','YYYY-MM')),
    'notices',v_notice);
  INSERT INTO public.sl_requests(actor_id,method,path,key_digest,payload_hash,response_body)
    VALUES(v_actor,'POST','/api/v1/transactions',p_key_digest,p_payload_hash,v_mutation);
  RETURN v_mutation;
END;
$$;

CREATE OR REPLACE FUNCTION public.sl_patch_expense(p_actor_subject text,p_transaction_id text,
  p_expected_version bigint,p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_id uuid; t public.sl_transactions%ROWTYPE; e public.sl_effects%ROWTYPE;
  v_account uuid; v_new_account uuid; a public.sl_accounts%ROWTYPE;
  v_amount numeric; v_time timestamptz; v_category text; v_merchant text; v_note text;
  v_new_status text; v_liquid numeric; v_savings numeric; v_open_savings numeric;
  v_old_liquid numeric; v_old_savings numeric; v_delta numeric; v_take_liquid numeric;
  v_take_savings numeric; v_add_savings numeric; v_add_liquid numeric; v_new_liquid numeric;
  v_new_savings numeric; v_changes jsonb:='[]'::jsonb; v_months jsonb; v_notice jsonb:='[]'::jsonb;
  v_effect jsonb;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  IF p_expected_version IS NULL OR p_expected_version<1 OR coalesce(jsonb_typeof(p_patch),'null')<>'object' OR
    EXISTS (SELECT 1 FROM jsonb_object_keys(p_patch) AS keys(name) WHERE name NOT IN
      ('type','amount_minor','occurred_at','account_id','category_code','merchant','note')) OR
    (p_patch ? 'type' AND p_patch->>'type' IS DISTINCT FROM 'expense') THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  BEGIN v_id:=p_transaction_id::uuid;
  EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_transaction_not_found'; END;
  SELECT * INTO t FROM public.sl_transactions WHERE id=v_id AND owner_id=v_actor FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_transaction_not_found'; END IF;
  IF t.version<>p_expected_version THEN RAISE EXCEPTION 'sl_version_mismatch'; END IF;
  IF t.type<>'expense' OR t.accounting_semantics<>'ordinary' THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  SELECT * INTO e FROM public.sl_effects WHERE transaction_id=v_id AND role='primary' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  v_account:=e.account_id;
  BEGIN
    v_new_account:=CASE WHEN p_patch ? 'account_id' THEN (p_patch->>'account_id')::uuid ELSE v_account END;
    v_amount:=CASE WHEN p_patch ? 'amount_minor' THEN (p_patch->>'amount_minor')::numeric ELSE t.amount_minor END;
    v_time:=CASE WHEN p_patch ? 'occurred_at' THEN (p_patch->>'occurred_at')::timestamptz ELSE t.occurred_at END;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'sl_invalid_input'; END;
  v_category:=CASE WHEN p_patch ? 'category_code' THEN p_patch->>'category_code' ELSE t.category_code END;
  v_merchant:=CASE WHEN p_patch ? 'merchant' THEN p_patch->>'merchant' ELSE t.merchant END;
  v_note:=CASE WHEN p_patch ? 'note' THEN p_patch->>'note' ELSE t.note END;
  IF v_amount IS NULL OR v_amount<=0 OR v_amount<>trunc(v_amount) OR v_amount>9007199254740991 OR
    v_time IS NULL OR v_time>now() OR v_new_account IS NULL OR
    v_category IS NULL OR v_category NOT IN ('food','shopping','transport','education','health','entertainment','utilities','other') OR
    v_merchant IS NULL OR v_note IS NULL THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  -- Lock all affected accounts in a stable order. The actor lock serializes this user's writes.
  PERFORM id FROM public.sl_accounts WHERE id IN (v_account,v_new_account) ORDER BY id FOR UPDATE;
  SELECT * INTO a FROM public.sl_accounts WHERE id=v_new_account AND holder_user_id=v_actor;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_account_not_found'; END IF;
  v_new_status:=CASE WHEN (v_time AT TIME ZONE 'Asia/Shanghai')::date>=a.opening_date
    THEN 'applied' ELSE 'historical_only' END;
  v_effect:=jsonb_build_object('account_id',v_account::text,'role','primary',
    'status',e.status,'signed_amount_minor',e.signed_amount_minor);
  IF (v_amount,v_time,v_new_account,v_category,v_merchant,v_note) IS NOT DISTINCT FROM
     (t.amount_minor,t.occurred_at,v_account,t.category_code,t.merchant,t.note) THEN
    RETURN jsonb_build_object('transaction',public.sl_transaction_json(v_id),
      'account_effects',jsonb_build_array(v_effect),'account_changes','[]'::jsonb,
      'affected_months','[]'::jsonb,'notices','[]'::jsonb);
  END IF;
  IF v_account=v_new_account AND e.status=v_new_status THEN
    IF e.status='applied' AND v_amount<>t.amount_minor THEN
      v_delta:=v_amount-t.amount_minor;
      v_notice:=public.sl_record_expense_delta(v_account,v_actor,e.id,v_id,v_time,abs(v_delta),v_delta<0);
    END IF;
    IF e.status='applied' AND v_time<>t.occurred_at THEN
      UPDATE public.sl_movements SET effective_at=v_time WHERE effect_id=e.id;
    END IF;
  ELSE
    IF e.status='applied' THEN PERFORM public.sl_assert_effect_reversal(e.id); END IF;
    DELETE FROM public.sl_movements WHERE effect_id=e.id;
    IF v_new_status='applied' THEN
      v_notice:=public.sl_record_expense_delta(v_new_account,v_actor,e.id,v_id,v_time,v_amount,false);
    END IF;
  END IF;
  UPDATE public.sl_effects SET account_id=v_new_account,signed_amount_minor=-v_amount,status=v_new_status WHERE id=e.id;
  UPDATE public.sl_transactions SET amount_minor=v_amount,occurred_at=v_time,
    category_code=v_category,merchant=v_merchant,note=v_note,version=version+1 WHERE id=v_id;
  IF e.status='applied' OR v_new_status='applied' THEN
    UPDATE public.sl_accounts SET version=version+1,funds_revision=funds_revision+1
      WHERE id IN (CASE WHEN e.status='applied' THEN v_account END,
                   CASE WHEN v_new_status='applied' THEN v_new_account END);
    SELECT COALESCE(jsonb_agg(jsonb_build_object('account_id',x.id::text,
      'balance_minor',x.payload->'balance_minor','fund_shares',x.payload->'fund_shares',
      'version',x.payload->'version') ORDER BY x.id),'[]'::jsonb) INTO v_changes
      FROM (SELECT id,public.sl_account_json(id) AS payload FROM public.sl_accounts
        WHERE id IN (CASE WHEN e.status='applied' THEN v_account END,
                     CASE WHEN v_new_status='applied' THEN v_new_account END)) x;
  END IF;
  v_months:=CASE WHEN to_char(t.occurred_at AT TIME ZONE 'Asia/Shanghai','YYYY-MM')=
    to_char(v_time AT TIME ZONE 'Asia/Shanghai','YYYY-MM') THEN
      jsonb_build_array(to_char(v_time AT TIME ZONE 'Asia/Shanghai','YYYY-MM'))
    ELSE jsonb_build_array(to_char(t.occurred_at AT TIME ZONE 'Asia/Shanghai','YYYY-MM'),
      to_char(v_time AT TIME ZONE 'Asia/Shanghai','YYYY-MM')) END;
  RETURN jsonb_build_object('transaction',public.sl_transaction_json(v_id),
    'account_effects',jsonb_build_array(jsonb_build_object('account_id',v_new_account::text,
      'role','primary','status',v_new_status,'signed_amount_minor',-v_amount)),
    'account_changes',v_changes,'affected_months',v_months,'notices',v_notice);
END;
$$;

CREATE OR REPLACE FUNCTION public.sl_delete_expense(p_actor_subject text,p_transaction_id text,
  p_expected_version bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_id uuid; t public.sl_transactions%ROWTYPE; e public.sl_effects%ROWTYPE;
  v_liquid numeric; v_savings numeric; v_effect_liquid numeric; v_effect_savings numeric;
  v_account_json jsonb; v_changes jsonb:='[]'::jsonb;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  IF p_expected_version IS NULL OR p_expected_version<1 THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  BEGIN v_id:=p_transaction_id::uuid;
  EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_transaction_not_found'; END;
  SELECT * INTO t FROM public.sl_transactions WHERE id=v_id AND owner_id=v_actor FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_transaction_not_found'; END IF;
  IF t.version<>p_expected_version THEN RAISE EXCEPTION 'sl_version_mismatch'; END IF;
  IF t.type<>'expense' OR t.accounting_semantics<>'ordinary' THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  SELECT * INTO e FROM public.sl_effects WHERE transaction_id=v_id AND role='primary' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  PERFORM id FROM public.sl_accounts WHERE id=e.account_id FOR UPDATE;
  IF e.status='applied' THEN PERFORM public.sl_assert_effect_reversal(e.id); END IF;
  DELETE FROM public.sl_movements WHERE effect_id=e.id;
  DELETE FROM public.sl_effects WHERE id=e.id;
  DELETE FROM public.sl_transactions WHERE id=v_id;
  IF e.status='applied' THEN
    UPDATE public.sl_accounts SET version=version+1,funds_revision=funds_revision+1 WHERE id=e.account_id;
    v_account_json:=public.sl_account_json(e.account_id);
    v_changes:=jsonb_build_array(jsonb_build_object('account_id',e.account_id::text,
      'balance_minor',v_account_json->'balance_minor','fund_shares',v_account_json->'fund_shares',
      'version',v_account_json->'version'));
  END IF;
  RETURN jsonb_build_object('deleted_transaction_id',v_id::text,'account_changes',v_changes,
    'affected_months',jsonb_build_array(to_char(t.occurred_at AT TIME ZONE 'Asia/Shanghai','YYYY-MM')));
END;
$$;

REVOKE ALL ON FUNCTION public.sl_share_owner(uuid,jsonb),public.sl_share_state(uuid),
  public.sl_assert_funds(uuid),public.sl_record_expense_delta(uuid,uuid,uuid,uuid,timestamptz,numeric,boolean),
  public.sl_assert_effect_reversal(uuid) FROM PUBLIC,anon,authenticated,service_role;
