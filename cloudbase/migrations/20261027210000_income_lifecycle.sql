-- Extend the current ordinary transaction lifecycle without parallel income RPCs.
ALTER TABLE public.sl_transactions DROP CONSTRAINT sl_transactions_type_check;
ALTER TABLE public.sl_transactions ADD CONSTRAINT sl_transactions_type_check CHECK(type IN ('income','expense'));
ALTER FUNCTION public.sl_create_expense(text,text,text,jsonb) RENAME TO sl_create_transaction;
ALTER FUNCTION public.sl_patch_expense(text,text,bigint,jsonb) RENAME TO sl_patch_transaction;
ALTER FUNCTION public.sl_delete_expense(text,text,bigint) RENAME TO sl_delete_transaction;

CREATE FUNCTION public.sl_record_income(p_account uuid,p_actor uuid,p_effect uuid,
  p_group uuid,p_time timestamptz,p_amount numeric) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p_amount IS NULL OR p_amount<=0 OR p_amount<>trunc(p_amount) OR p_amount>9007199254740991 THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  INSERT INTO public.sl_movements(account_id,fund_owner_id,fund_type,signed_amount_minor,
    reason,operation_group,effect_id,effective_at)
    VALUES(p_account,p_actor,'liquid',p_amount,'transaction',p_group,p_effect,p_time);
  PERFORM public.sl_assert_funds(p_account);
END;
$$;

CREATE FUNCTION public.sl_apply_ordinary_funds(p_type text,p_account uuid,p_actor uuid,p_effect uuid,
  p_group uuid,p_time timestamptz,p_amount numeric) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p_type='expense' THEN
    RETURN public.sl_record_expense_delta(p_account,p_actor,p_effect,p_group,p_time,p_amount,false);
  ELSIF p_type='income' THEN
    PERFORM public.sl_record_income(p_account,p_actor,p_effect,p_group,p_time,p_amount);
    RETURN '[]'::jsonb;
  END IF;
  RAISE EXCEPTION 'sl_invalid_input';
END;
$$;

CREATE FUNCTION public.sl_reverse_effect(p_effect uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_account uuid;
BEGIN
  SELECT account_id INTO v_account FROM public.sl_effects WHERE id=p_effect;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  PERFORM public.sl_assert_effect_reversal(p_effect);
  DELETE FROM public.sl_movements WHERE effect_id=p_effect;
  PERFORM public.sl_assert_funds(v_account);
END;
$$;

CREATE FUNCTION public.sl_account_changes(p_accounts uuid[]) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('account_id',x.id::text,
    'balance_minor',x.payload->'balance_minor','fund_shares',x.payload->'fund_shares','version',x.payload->'version')
    ORDER BY x.id),'[]'::jsonb)
  FROM (SELECT a.id,public.sl_account_json(a.id) AS payload FROM public.sl_accounts a WHERE a.id=ANY(p_accounts)) x;
$$;

CREATE OR REPLACE FUNCTION public.sl_transaction_json(p_transaction_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_tx public.sl_transactions%ROWTYPE; v_account uuid;
BEGIN
  SELECT * INTO v_tx FROM public.sl_transactions WHERE id=p_transaction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_transaction_not_found'; END IF;
  SELECT account_id INTO v_account FROM public.sl_effects WHERE transaction_id=v_tx.id;
  RETURN jsonb_build_object('id',v_tx.id::text,'type',v_tx.type,'accounting_semantics',v_tx.accounting_semantics,
    'amount_minor',v_tx.amount_minor,'occurred_at',
      to_char(v_tx.occurred_at AT TIME ZONE 'Asia/Shanghai','YYYY-MM-DD"T"HH24:MI:SS')||'+08:00',
    'category_code',v_tx.category_code,'merchant',v_tx.merchant,'note',v_tx.note,
    'source_account_profile_id',NULL,'source_summaries','[]'::jsonb,
    'version',v_tx.version,'read_only',false,'account_id',v_account::text);
END;
$$;

CREATE OR REPLACE FUNCTION public.sl_create_transaction(p_actor_subject text,p_key_digest text,
  p_payload_hash text,p_input jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_account public.sl_accounts%ROWTYPE; v_transaction uuid; v_effect uuid;
  v_prior jsonb; v_prior_hash text; v_kind text; v_amount numeric; v_time timestamptz;
  v_applied boolean; v_signed numeric; v_notices jsonb:='[]'::jsonb; v_result jsonb;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  IF coalesce(p_key_digest,'') !~ '^[0-9a-f]{64}$' OR coalesce(p_payload_hash,'') !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  SELECT response_body,payload_hash INTO v_prior,v_prior_hash FROM public.sl_requests
    WHERE actor_id=v_actor AND method='POST' AND path='/api/v1/transactions' AND key_digest=p_key_digest;
  IF FOUND THEN
    IF v_prior_hash<>p_payload_hash THEN RAISE EXCEPTION 'sl_idempotency_conflict'; END IF;
    RETURN v_prior;
  END IF;
  v_kind:=p_input->>'type';
  IF v_kind IS NULL OR v_kind NOT IN ('income','expense') OR p_input->>'account_id' IS NULL OR
    p_input->>'category_code' IS NULL OR p_input->>'category_code' NOT IN
      ('food','shopping','transport','education','health','entertainment','utilities','other') THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  BEGIN
    v_amount:=(p_input->>'amount_minor')::numeric; v_time:=(p_input->>'occurred_at')::timestamptz;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'sl_invalid_input'; END;
  IF v_amount IS NULL OR v_amount<=0 OR v_amount<>trunc(v_amount) OR v_amount>9007199254740991 OR
    v_time IS NULL OR v_time>now() OR p_input->>'merchant' IS NULL OR p_input->>'note' IS NULL THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  BEGIN
    SELECT * INTO v_account FROM public.sl_accounts WHERE id=(p_input->>'account_id')::uuid AND holder_user_id=v_actor FOR UPDATE;
  EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_account_not_found'; END;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_account_not_found'; END IF;
  v_applied:=(v_time AT TIME ZONE 'Asia/Shanghai')::date>=v_account.opening_date;
  v_signed:=CASE WHEN v_kind='income' THEN v_amount ELSE -v_amount END;
  INSERT INTO public.sl_transactions(owner_id,type,accounting_semantics,amount_minor,occurred_at,category_code,merchant,note)
    VALUES(v_actor,v_kind,'ordinary',v_amount,v_time,p_input->>'category_code',p_input->>'merchant',p_input->>'note')
    RETURNING id INTO v_transaction;
  INSERT INTO public.sl_effects(transaction_id,account_id,role,signed_amount_minor,status)
    VALUES(v_transaction,v_account.id,'primary',v_signed,CASE WHEN v_applied THEN 'applied' ELSE 'historical_only' END)
    RETURNING id INTO v_effect;
  IF v_applied THEN
    v_notices:=public.sl_apply_ordinary_funds(v_kind,v_account.id,v_actor,v_effect,v_transaction,v_time,v_amount);
    UPDATE public.sl_accounts SET version=version+1,funds_revision=funds_revision+1 WHERE id=v_account.id;
  END IF;
  v_result:=jsonb_build_object('transaction',public.sl_transaction_json(v_transaction),
    'account_effects',jsonb_build_array(jsonb_build_object('account_id',v_account.id::text,'role','primary',
      'status',CASE WHEN v_applied THEN 'applied' ELSE 'historical_only' END,'signed_amount_minor',v_signed)),
    'account_changes',public.sl_account_changes(CASE WHEN v_applied THEN ARRAY[v_account.id] ELSE ARRAY[]::uuid[] END),
    'affected_months',jsonb_build_array(to_char(v_time AT TIME ZONE 'Asia/Shanghai','YYYY-MM')),'notices',v_notices);
  INSERT INTO public.sl_requests(actor_id,method,path,key_digest,payload_hash,response_body)
    VALUES(v_actor,'POST','/api/v1/transactions',p_key_digest,p_payload_hash,v_result);
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.sl_patch_transaction(p_actor_subject text,p_transaction_id text,
  p_expected_version bigint,p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_id uuid; v_tx public.sl_transactions%ROWTYPE; v_effect public.sl_effects%ROWTYPE;
  v_old_account uuid; v_new_account uuid; v_target public.sl_accounts%ROWTYPE; v_kind text;
  v_amount numeric; v_time timestamptz; v_category text; v_merchant text; v_note text; v_status text;
  v_signed numeric; v_delta numeric; v_funds_changed boolean:=false; v_changed uuid[]:=ARRAY[]::uuid[];
  v_notices jsonb:='[]'::jsonb; v_months jsonb;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  IF p_expected_version IS NULL OR p_expected_version<1 OR coalesce(jsonb_typeof(p_patch),'null')<>'object' OR
    EXISTS(SELECT 1 FROM jsonb_object_keys(p_patch) AS k(name) WHERE name NOT IN
      ('type','amount_minor','occurred_at','account_id','category_code','merchant','note','source_account_profile_id')) OR
    (p_patch ? 'source_account_profile_id' AND p_patch->'source_account_profile_id'<>'null'::jsonb) THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  BEGIN v_id:=p_transaction_id::uuid;
  EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_transaction_not_found'; END;
  SELECT * INTO v_tx FROM public.sl_transactions WHERE id=v_id AND owner_id=v_actor FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_transaction_not_found'; END IF;
  IF v_tx.version<>p_expected_version THEN RAISE EXCEPTION 'sl_version_mismatch'; END IF;
  IF v_tx.type NOT IN ('income','expense') OR v_tx.accounting_semantics<>'ordinary' THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  SELECT * INTO v_effect FROM public.sl_effects WHERE transaction_id=v_id AND role='primary' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  v_old_account:=v_effect.account_id;
  BEGIN
    v_new_account:=CASE WHEN p_patch ? 'account_id' THEN (p_patch->>'account_id')::uuid ELSE v_old_account END;
    v_amount:=CASE WHEN p_patch ? 'amount_minor' THEN (p_patch->>'amount_minor')::numeric ELSE v_tx.amount_minor END;
    v_time:=CASE WHEN p_patch ? 'occurred_at' THEN (p_patch->>'occurred_at')::timestamptz ELSE v_tx.occurred_at END;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'sl_invalid_input'; END;
  v_kind:=CASE WHEN p_patch ? 'type' THEN p_patch->>'type' ELSE v_tx.type END;
  v_category:=CASE WHEN p_patch ? 'category_code' THEN p_patch->>'category_code' ELSE v_tx.category_code END;
  v_merchant:=CASE WHEN p_patch ? 'merchant' THEN p_patch->>'merchant' ELSE v_tx.merchant END;
  v_note:=CASE WHEN p_patch ? 'note' THEN p_patch->>'note' ELSE v_tx.note END;
  IF v_kind IS NULL OR v_kind NOT IN ('income','expense') OR v_amount IS NULL OR v_amount<=0 OR
    v_amount<>trunc(v_amount) OR v_amount>9007199254740991 OR v_time IS NULL OR v_time>now() OR
    v_new_account IS NULL OR v_category IS NULL OR v_category NOT IN
      ('food','shopping','transport','education','health','entertainment','utilities','other') OR
    v_merchant IS NULL OR v_note IS NULL THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  PERFORM id FROM public.sl_accounts WHERE id IN(v_old_account,v_new_account) ORDER BY id FOR UPDATE;
  SELECT * INTO v_target FROM public.sl_accounts WHERE id=v_new_account AND holder_user_id=v_actor;
  IF NOT FOUND OR NOT EXISTS(SELECT 1 FROM public.sl_accounts WHERE id=v_old_account AND holder_user_id=v_actor) THEN
    RAISE EXCEPTION 'sl_account_not_found'; END IF;
  v_status:=CASE WHEN (v_time AT TIME ZONE 'Asia/Shanghai')::date>=v_target.opening_date THEN 'applied' ELSE 'historical_only' END;
  v_signed:=CASE WHEN v_kind='income' THEN v_amount ELSE -v_amount END;
  IF (v_kind,v_amount,v_time,v_new_account,v_category,v_merchant,v_note) IS NOT DISTINCT FROM
    (v_tx.type,v_tx.amount_minor,v_tx.occurred_at,v_old_account,v_tx.category_code,v_tx.merchant,v_tx.note) THEN
    RETURN jsonb_build_object('transaction',public.sl_transaction_json(v_id),
      'account_effects',jsonb_build_array(jsonb_build_object('account_id',v_old_account::text,'role','primary',
        'status',v_effect.status,'signed_amount_minor',v_effect.signed_amount_minor)),
      'account_changes','[]'::jsonb,'affected_months','[]'::jsonb,'notices','[]'::jsonb);
  END IF;
  IF v_old_account=v_new_account AND v_effect.status=v_status AND v_tx.type=v_kind THEN
    IF v_status='applied' THEN
      IF v_amount<>v_tx.amount_minor THEN
        IF v_kind='expense' THEN
          v_delta:=v_amount-v_tx.amount_minor;
          v_notices:=public.sl_record_expense_delta(v_old_account,v_actor,v_effect.id,v_id,v_time,abs(v_delta),v_delta<0);
        ELSE
          PERFORM public.sl_reverse_effect(v_effect.id);
          v_notices:=public.sl_apply_ordinary_funds(v_kind,v_new_account,v_actor,v_effect.id,v_id,v_time,v_amount);
        END IF;
        v_funds_changed:=true;
      END IF;
      IF v_time<>v_tx.occurred_at THEN UPDATE public.sl_movements SET effective_at=v_time WHERE effect_id=v_effect.id; END IF;
    END IF;
  ELSE
    IF v_effect.status='applied' THEN PERFORM public.sl_reverse_effect(v_effect.id); v_funds_changed:=true;
    ELSE DELETE FROM public.sl_movements WHERE effect_id=v_effect.id; END IF;
    IF v_status='applied' THEN
      v_notices:=public.sl_apply_ordinary_funds(v_kind,v_new_account,v_actor,v_effect.id,v_id,v_time,v_amount);
      v_funds_changed:=true;
    END IF;
  END IF;
  UPDATE public.sl_effects SET account_id=v_new_account,signed_amount_minor=v_signed,status=v_status WHERE id=v_effect.id;
  UPDATE public.sl_transactions SET type=v_kind,amount_minor=v_amount,occurred_at=v_time,
    category_code=v_category,merchant=v_merchant,note=v_note,version=version+1 WHERE id=v_id;
  IF v_funds_changed THEN
    SELECT ARRAY(SELECT DISTINCT x.account_id FROM unnest(ARRAY[
      CASE WHEN v_effect.status='applied' THEN v_old_account END,
      CASE WHEN v_status='applied' THEN v_new_account END]) AS x(account_id) WHERE x.account_id IS NOT NULL) INTO v_changed;
    UPDATE public.sl_accounts SET version=version+1,funds_revision=funds_revision+1 WHERE id=ANY(v_changed);
  END IF;
  v_months:=CASE WHEN to_char(v_tx.occurred_at AT TIME ZONE 'Asia/Shanghai','YYYY-MM')=
    to_char(v_time AT TIME ZONE 'Asia/Shanghai','YYYY-MM') THEN
      jsonb_build_array(to_char(v_time AT TIME ZONE 'Asia/Shanghai','YYYY-MM'))
    ELSE jsonb_build_array(to_char(v_tx.occurred_at AT TIME ZONE 'Asia/Shanghai','YYYY-MM'),
      to_char(v_time AT TIME ZONE 'Asia/Shanghai','YYYY-MM')) END;
  RETURN jsonb_build_object('transaction',public.sl_transaction_json(v_id),
    'account_effects',jsonb_build_array(jsonb_build_object('account_id',v_new_account::text,'role','primary',
      'status',v_status,'signed_amount_minor',v_signed)),
    'account_changes',public.sl_account_changes(v_changed),'affected_months',v_months,'notices',v_notices);
END;
$$;

CREATE OR REPLACE FUNCTION public.sl_delete_transaction(p_actor_subject text,p_transaction_id text,
  p_expected_version bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_id uuid; v_tx public.sl_transactions%ROWTYPE; v_effect public.sl_effects%ROWTYPE;
  v_changed uuid[]:=ARRAY[]::uuid[];
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  IF p_expected_version IS NULL OR p_expected_version<1 THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  BEGIN v_id:=p_transaction_id::uuid;
  EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_transaction_not_found'; END;
  SELECT * INTO v_tx FROM public.sl_transactions WHERE id=v_id AND owner_id=v_actor FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_transaction_not_found'; END IF;
  IF v_tx.version<>p_expected_version THEN RAISE EXCEPTION 'sl_version_mismatch'; END IF;
  IF v_tx.type NOT IN ('income','expense') OR v_tx.accounting_semantics<>'ordinary' THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  SELECT * INTO v_effect FROM public.sl_effects WHERE transaction_id=v_id AND role='primary' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  PERFORM id FROM public.sl_accounts WHERE id=v_effect.account_id AND holder_user_id=v_actor FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_account_not_found'; END IF;
  IF v_effect.status='applied' THEN
    PERFORM public.sl_reverse_effect(v_effect.id);
    v_changed:=ARRAY[v_effect.account_id];
    UPDATE public.sl_accounts SET version=version+1,funds_revision=funds_revision+1 WHERE id=v_effect.account_id;
  ELSE DELETE FROM public.sl_movements WHERE effect_id=v_effect.id; END IF;
  DELETE FROM public.sl_effects WHERE id=v_effect.id;
  DELETE FROM public.sl_transactions WHERE id=v_id;
  RETURN jsonb_build_object('deleted_transaction_id',v_id::text,'account_changes',public.sl_account_changes(v_changed),
    'affected_months',jsonb_build_array(to_char(v_tx.occurred_at AT TIME ZONE 'Asia/Shanghai','YYYY-MM')));
END;
$$;

REVOKE ALL ON FUNCTION public.sl_record_income(uuid,uuid,uuid,uuid,timestamptz,numeric),
  public.sl_apply_ordinary_funds(text,uuid,uuid,uuid,uuid,timestamptz,numeric),
  public.sl_reverse_effect(uuid),public.sl_account_changes(uuid[]) FROM PUBLIC,anon,authenticated,service_role;
-- Renamed lifecycle entry points retain the existing backend-only ACLs.

-- Replay now uses the same ordinary income/expense dispatcher.
CREATE OR REPLACE FUNCTION public.sl_put_opening_state(p_actor_subject text,p_account_id text,
  p_expected_version bigint,p_input jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_id uuid; a public.sl_accounts%ROWTYPE; v_date date;
  v_balance numeric; v_total numeric:=0; v_alloc jsonb; v_owner uuid; v_amount numeric;
  v_seen text[]:='{}'; v_key text; v_new_liquid numeric:=0; v_new_savings numeric:=0;
  v_new_partner numeric:=0; v_old_liquid numeric; v_old_savings numeric; v_old_partner numeric;
  v_before jsonb; r record; e public.sl_effects%ROWTYPE; t public.sl_transactions%ROWTYPE;
  d public.sl_fund_adjustments%ROWTYPE; v_available numeric; v_error text;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  IF p_expected_version IS NULL OR p_expected_version<1 THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  BEGIN v_id:=p_account_id::uuid;
  EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_account_not_found'; END;
  SELECT * INTO a FROM public.sl_accounts WHERE id=v_id AND holder_user_id=v_actor FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_account_not_found'; END IF;
  IF a.version<>p_expected_version THEN RAISE EXCEPTION 'sl_version_mismatch'; END IF;
  IF coalesce(jsonb_typeof(p_input),'null')<>'object' OR
    EXISTS(SELECT 1 FROM jsonb_object_keys(p_input) AS k(name)
      WHERE name NOT IN ('opening_date','opening_balance_minor','opening_allocations')) OR
    coalesce(jsonb_typeof(p_input->'opening_allocations'),'null')<>'array' THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  BEGIN
    v_date:=(p_input->>'opening_date')::date;
    v_balance:=(p_input->>'opening_balance_minor')::numeric;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'sl_invalid_input'; END;
  IF v_date IS NULL OR v_date>(now() AT TIME ZONE 'Asia/Shanghai')::date OR
    v_balance IS NULL OR v_balance<0 OR v_balance<>trunc(v_balance) OR v_balance>9007199254740991 THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  FOR v_alloc IN SELECT value FROM jsonb_array_elements(p_input->'opening_allocations') LOOP
    v_owner:=public.sl_share_owner(v_actor,v_alloc-'amount_minor');
    v_key:=v_owner::text||':'||(v_alloc->>'fund_type');
    IF v_key=ANY(v_seen) THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
    BEGIN v_amount:=(v_alloc->>'amount_minor')::numeric;
    EXCEPTION WHEN others THEN RAISE EXCEPTION 'sl_invalid_input'; END;
    IF v_amount IS NULL OR v_amount<0 OR v_amount<>trunc(v_amount) OR v_amount>9007199254740991 THEN
      RAISE EXCEPTION 'sl_invalid_input'; END IF;
    v_seen:=array_append(v_seen,v_key); v_total:=v_total+v_amount;
    IF v_owner<>v_actor THEN v_new_partner:=v_amount;
    ELSIF v_alloc->>'fund_type'='liquid' THEN v_new_liquid:=v_amount;
    ELSE v_new_savings:=v_amount; END IF;
  END LOOP;
  IF cardinality(v_seen) NOT BETWEEN 1 AND 3 OR v_total<>v_balance THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  SELECT COALESCE(sum(signed_amount_minor) FILTER(WHERE fund_owner_id=v_actor AND fund_type='liquid'),0),
    COALESCE(sum(signed_amount_minor) FILTER(WHERE fund_owner_id=v_actor AND fund_type='savings'),0),
    COALESCE(sum(signed_amount_minor) FILTER(WHERE fund_owner_id<>v_actor AND fund_type='savings'),0)
    INTO v_old_liquid,v_old_savings,v_old_partner FROM public.sl_movements WHERE account_id=v_id AND reason='opening';
  v_before:=public.sl_account_json(v_id);
  -- Allocation ordering and an omitted zero share are not meaningful changes.
  IF a.opening_date=v_date AND (v_old_liquid,v_old_savings,v_old_partner)=
    (v_new_liquid,v_new_savings,v_new_partner) AND
    (v_before->'opening_state'->>'opening_balance_minor')::numeric=v_balance THEN RETURN v_before; END IF;

  BEGIN
    DELETE FROM public.sl_movements WHERE account_id=v_id;
    UPDATE public.sl_accounts SET opening_date=v_date WHERE id=v_id;
    FOR v_alloc IN SELECT value FROM jsonb_array_elements(p_input->'opening_allocations') LOOP
      v_owner:=public.sl_share_owner(v_actor,v_alloc-'amount_minor');
      INSERT INTO public.sl_movements(account_id,fund_owner_id,fund_type,signed_amount_minor,
        reason,operation_group,effective_at)
        VALUES(v_id,v_owner,v_alloc->>'fund_type',(v_alloc->>'amount_minor')::numeric,'opening',v_id,
          v_date::timestamp AT TIME ZONE 'Asia/Shanghai');
    END LOOP;
    PERFORM public.sl_assert_funds(v_id);
    FOR r IN
      SELECT 'transaction'::text AS kind,x.id AS event_id,tx.occurred_at AS event_time,x.replay_order
        FROM public.sl_effects x JOIN public.sl_transactions tx ON tx.id=x.transaction_id WHERE x.account_id=v_id
      UNION ALL
      SELECT 'adjustment',x.id,x.occurred_at,x.replay_order FROM public.sl_fund_adjustments x WHERE x.account_id=v_id
      ORDER BY event_time,replay_order
    LOOP
      IF r.kind='transaction' THEN
        SELECT * INTO e FROM public.sl_effects WHERE id=r.event_id;
        IF (r.event_time AT TIME ZONE 'Asia/Shanghai')::date<v_date THEN
          UPDATE public.sl_effects SET status='historical_only' WHERE id=e.id;
          CONTINUE;
        END IF;
        SELECT * INTO t FROM public.sl_transactions WHERE id=e.transaction_id;
        IF t.owner_id<>v_actor OR t.type NOT IN ('income','expense') OR t.accounting_semantics<>'ordinary' OR
          e.role<>'primary' OR e.signed_amount_minor<>(CASE WHEN t.type='income' THEN t.amount_minor ELSE -t.amount_minor END) THEN
          RAISE EXCEPTION 'sl_opening_recalculation_conflict'; END IF;
        PERFORM public.sl_apply_ordinary_funds(t.type,v_id,v_actor,e.id,t.id,r.event_time,t.amount_minor);
        UPDATE public.sl_effects SET status='applied' WHERE id=e.id;
      ELSE
        IF (r.event_time AT TIME ZONE 'Asia/Shanghai')::date<v_date THEN CONTINUE; END IF;
        SELECT * INTO d FROM public.sl_fund_adjustments WHERE id=r.event_id;
        IF (d.from_owner_id<>v_actor AND
              (d.from_owner_id IS DISTINCT FROM public.sl_partner_id(v_actor) OR d.from_type<>'savings')) OR
           (d.to_owner_id<>v_actor AND
              (d.to_owner_id IS DISTINCT FROM public.sl_partner_id(v_actor) OR d.to_type<>'savings')) THEN
          RAISE EXCEPTION 'sl_opening_recalculation_conflict'; END IF;
        SELECT COALESCE(sum(current_minor),0) INTO v_available FROM public.sl_share_state(v_id)
          WHERE fund_owner_id=d.from_owner_id AND fund_type=d.from_type;
        IF v_available<d.amount_minor THEN RAISE EXCEPTION 'sl_insufficient_funds'; END IF;
        INSERT INTO public.sl_movements(account_id,fund_owner_id,fund_type,signed_amount_minor,
          reason,operation_group,effective_at) VALUES
          (v_id,d.from_owner_id,d.from_type,-d.amount_minor,'adjustment',d.id,d.occurred_at),
          (v_id,d.to_owner_id,d.to_type,d.amount_minor,'adjustment',d.id,d.occurred_at);
        PERFORM public.sl_assert_funds(v_id);
      END IF;
    END LOOP;
    UPDATE public.sl_accounts SET version=version+1,funds_revision=funds_revision+1 WHERE id=v_id;
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
    IF v_error IN ('sl_insufficient_funds','sl_unsafe_reversal','sl_invalid_input') THEN
      RAISE EXCEPTION 'sl_opening_recalculation_conflict'; END IF;
    RAISE;
  END;
  RETURN public.sl_account_json(v_id);
END;
$$;
