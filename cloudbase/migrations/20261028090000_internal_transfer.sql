-- Internal transfers extend the same lifecycle. All entry points lock the actor
-- then every affected account in UUID order; helpers remain owner-only.
ALTER TABLE public.sl_transactions DROP CONSTRAINT sl_transactions_type_check;
ALTER TABLE public.sl_transactions ADD CONSTRAINT sl_transactions_type_check CHECK(type IN ('income','expense','transfer'));
ALTER TABLE public.sl_transactions DROP CONSTRAINT sl_transactions_accounting_semantics_check;
ALTER TABLE public.sl_transactions ADD CONSTRAINT sl_transactions_accounting_semantics_check CHECK(
  (type IN ('income','expense') AND accounting_semantics='ordinary') OR
  (type='transfer' AND accounting_semantics='internal_transfer'));
ALTER TABLE public.sl_effects DROP CONSTRAINT sl_effects_role_check;
ALTER TABLE public.sl_effects ADD CONSTRAINT sl_effects_role_check CHECK(role IN ('primary','from','to'));

CREATE FUNCTION public.sl_apply_effect(p_type text,p_role text,p_account uuid,p_actor uuid,
  p_effect uuid,p_group uuid,p_time timestamptz,p_amount numeric) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_liquid numeric;
BEGIN
  IF p_role='primary' AND p_type IN ('income','expense') THEN
    RETURN public.sl_apply_ordinary_funds(p_type,p_account,p_actor,p_effect,p_group,p_time,p_amount);
  END IF;
  IF p_type<>'transfer' OR p_role NOT IN ('from','to') OR p_amount IS NULL OR
    p_amount<=0 OR p_amount<>trunc(p_amount) OR p_amount>9007199254740991 THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  IF p_role='to' THEN
    PERFORM public.sl_record_income(p_account,p_actor,p_effect,p_group,p_time,p_amount);
  ELSE
    SELECT COALESCE(sum(current_minor),0) INTO v_liquid FROM public.sl_share_state(p_account)
      WHERE fund_owner_id=p_actor AND fund_type='liquid';
    IF v_liquid<p_amount THEN RAISE EXCEPTION 'sl_insufficient_funds'; END IF;
    INSERT INTO public.sl_movements(account_id,fund_owner_id,fund_type,signed_amount_minor,
      reason,operation_group,effect_id,effective_at)
      VALUES(p_account,p_actor,'liquid',-p_amount,'transaction',p_group,p_effect,p_time);
    PERFORM public.sl_assert_funds(p_account);
  END IF;
  RETURN '[]'::jsonb;
END;
$$;

CREATE FUNCTION public.sl_effects_json(p_tx uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('account_id',account_id::text,'role',role,
    'status',status,'signed_amount_minor',signed_amount_minor) ORDER BY role),'[]'::jsonb)
    FROM public.sl_effects WHERE transaction_id=p_tx;
$$;

CREATE OR REPLACE FUNCTION public.sl_transaction_json(p_transaction_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_tx public.sl_transactions%ROWTYPE; v_result jsonb; v_primary uuid; v_from uuid; v_to uuid;
BEGIN
  SELECT * INTO v_tx FROM public.sl_transactions WHERE id=p_transaction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_transaction_not_found'; END IF;
  SELECT account_id INTO v_primary FROM public.sl_effects WHERE transaction_id=v_tx.id AND role='primary';
  SELECT account_id INTO v_from FROM public.sl_effects WHERE transaction_id=v_tx.id AND role='from';
  SELECT account_id INTO v_to FROM public.sl_effects WHERE transaction_id=v_tx.id AND role='to';
  v_result:=jsonb_build_object('id',v_tx.id::text,'type',v_tx.type,'accounting_semantics',v_tx.accounting_semantics,
    'amount_minor',v_tx.amount_minor,'occurred_at',
    to_char(v_tx.occurred_at AT TIME ZONE 'Asia/Shanghai','YYYY-MM-DD"T"HH24:MI:SS')||'+08:00',
    'category_code',v_tx.category_code,'merchant',v_tx.merchant,'note',v_tx.note,
    'source_account_profile_id',NULL,'source_summaries','[]'::jsonb,'version',v_tx.version,'read_only',false);
  IF v_tx.type='transfer' THEN
    RETURN v_result||jsonb_build_object('from_account_id',v_from::text,'to_account_id',v_to::text);
  END IF;
  RETURN v_result||jsonb_build_object('account_id',v_primary::text);
END;
$$;

-- Create one or two effects, using the transaction's original order on rebuild.
-- Caller already holds every account lock and has validated ownership.
CREATE FUNCTION public.sl_install_effects(p_tx uuid,p_actor uuid,p_type text,p_primary uuid,
  p_from uuid,p_to uuid,p_amount numeric,p_time timestamptz,p_order bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r record; v_id uuid; v_status text; v_order bigint;
  v_notices jsonb:='[]'::jsonb;
BEGIN
  v_order:=COALESCE(p_order,nextval('public.sl_replay_order_seq'::regclass));
  FOR r IN SELECT 'primary'::text AS role,p_primary AS account_id,
      CASE WHEN p_type='income' THEN p_amount ELSE -p_amount END AS signed WHERE p_type<>'transfer'
    UNION ALL SELECT 'from',p_from,-p_amount WHERE p_type='transfer'
    UNION ALL SELECT 'to',p_to,p_amount WHERE p_type='transfer'
  LOOP
    SELECT CASE WHEN (p_time AT TIME ZONE 'Asia/Shanghai')::date>=opening_date THEN 'applied'
      ELSE 'historical_only' END INTO v_status FROM public.sl_accounts WHERE id=r.account_id;
    INSERT INTO public.sl_effects(transaction_id,account_id,role,signed_amount_minor,status,replay_order)
      VALUES(p_tx,r.account_id,r.role,r.signed,v_status,v_order) RETURNING id INTO v_id;
    IF v_status='applied' THEN
      v_notices:=v_notices||public.sl_apply_effect(p_type,r.role,r.account_id,p_actor,v_id,p_tx,p_time,p_amount);
    END IF;
  END LOOP;
  RETURN v_notices;
END;
$$;

CREATE OR REPLACE FUNCTION public.sl_create_transaction(p_actor_subject text,p_key_digest text,
  p_payload_hash text,p_input jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_tx uuid; v_primary uuid; v_from uuid; v_to uuid; v_accounts uuid[];
  v_prior jsonb; v_hash text; v_type text; v_amount numeric; v_time timestamptz;
  v_notices jsonb; v_changed uuid[]; v_result jsonb;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  IF coalesce(p_key_digest,'') !~ '^[0-9a-f]{64}$' OR coalesce(p_payload_hash,'') !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  SELECT response_body,payload_hash INTO v_prior,v_hash FROM public.sl_requests
    WHERE actor_id=v_actor AND method='POST' AND path='/api/v1/transactions' AND key_digest=p_key_digest;
  IF FOUND THEN
    IF v_hash<>p_payload_hash THEN RAISE EXCEPTION 'sl_idempotency_conflict'; END IF;
    RETURN v_prior;
  END IF;
  v_type:=p_input->>'type';
  IF v_type IS NULL OR v_type NOT IN ('income','expense','transfer') OR
    p_input->>'category_code' IS NULL OR p_input->>'category_code' NOT IN
    ('food','shopping','transport','education','health','entertainment','utilities','other') THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  BEGIN
    v_amount:=(p_input->>'amount_minor')::numeric; v_time:=(p_input->>'occurred_at')::timestamptz;
    IF v_type='transfer' THEN
      IF p_input ? 'account_id' THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
      v_from:=(p_input->>'from_account_id')::uuid; v_to:=(p_input->>'to_account_id')::uuid;
      IF v_from IS NULL OR v_to IS NULL OR v_from=v_to THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
      v_accounts:=ARRAY[v_from,v_to];
    ELSE
      IF p_input ? 'from_account_id' OR p_input ? 'to_account_id' THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
      v_primary:=(p_input->>'account_id')::uuid;
      IF v_primary IS NULL THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
      v_accounts:=ARRAY[v_primary];
    END IF;
  EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_invalid_input'; END;
  IF v_amount IS NULL OR v_amount<=0 OR v_amount<>trunc(v_amount) OR v_amount>9007199254740991 OR
    v_time IS NULL OR v_time>now() OR p_input->>'merchant' IS NULL OR p_input->>'note' IS NULL THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  PERFORM id FROM public.sl_accounts WHERE id=ANY(v_accounts) ORDER BY id FOR UPDATE;
  IF (SELECT count(*) FROM public.sl_accounts WHERE id=ANY(v_accounts) AND holder_user_id=v_actor)<>cardinality(v_accounts) THEN
    RAISE EXCEPTION 'sl_account_not_found'; END IF;
  INSERT INTO public.sl_transactions(owner_id,type,accounting_semantics,amount_minor,occurred_at,category_code,merchant,note)
    VALUES(v_actor,v_type,CASE WHEN v_type='transfer' THEN 'internal_transfer' ELSE 'ordinary' END,
      v_amount,v_time,p_input->>'category_code',p_input->>'merchant',p_input->>'note') RETURNING id INTO v_tx;
  v_notices:=public.sl_install_effects(v_tx,v_actor,v_type,v_primary,v_from,v_to,v_amount,v_time,NULL);
  SELECT ARRAY(SELECT account_id FROM public.sl_effects WHERE transaction_id=v_tx AND status='applied') INTO v_changed;
  UPDATE public.sl_accounts SET version=version+1,funds_revision=funds_revision+1 WHERE id=ANY(v_changed);
  v_result:=jsonb_build_object('transaction',public.sl_transaction_json(v_tx),'account_effects',public.sl_effects_json(v_tx),
    'account_changes',public.sl_account_changes(v_changed),'affected_months',
    jsonb_build_array(to_char(v_time AT TIME ZONE 'Asia/Shanghai','YYYY-MM')),'notices',v_notices);
  INSERT INTO public.sl_requests(actor_id,method,path,key_digest,payload_hash,response_body)
    VALUES(v_actor,'POST','/api/v1/transactions',p_key_digest,p_payload_hash,v_result);
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.sl_patch_transaction(p_actor_subject text,p_transaction_id text,
  p_expected_version bigint,p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_id uuid; v_tx public.sl_transactions%ROWTYPE; e public.sl_effects%ROWTYPE;
  v_primary uuid; v_from uuid; v_to uuid; v_old_primary uuid; v_old_from uuid; v_old_to uuid;
  v_type text; v_amount numeric; v_time timestamptz; v_category text; v_merchant text; v_note text;
  v_accounts uuid[]; v_changed uuid[]:=ARRAY[]::uuid[]; v_order bigint; v_status text;
  v_rebuild boolean; v_notices jsonb:='[]'::jsonb; v_months jsonb;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  IF p_expected_version IS NULL OR p_expected_version<1 OR coalesce(jsonb_typeof(p_patch),'null')<>'object' OR
    EXISTS(SELECT 1 FROM jsonb_object_keys(p_patch) AS k(name) WHERE name NOT IN
      ('type','amount_minor','occurred_at','account_id','from_account_id','to_account_id','category_code','merchant','note','source_account_profile_id')) OR
    (p_patch ? 'source_account_profile_id' AND p_patch->'source_account_profile_id'<>'null'::jsonb) THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  BEGIN v_id:=p_transaction_id::uuid;
  EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_transaction_not_found'; END;
  SELECT * INTO v_tx FROM public.sl_transactions WHERE id=v_id AND owner_id=v_actor FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_transaction_not_found'; END IF;
  IF v_tx.version<>p_expected_version THEN RAISE EXCEPTION 'sl_version_mismatch'; END IF;
  PERFORM id FROM public.sl_effects WHERE transaction_id=v_id ORDER BY id FOR UPDATE;
  SELECT account_id INTO v_old_primary FROM public.sl_effects WHERE transaction_id=v_id AND role='primary';
  SELECT account_id INTO v_old_from FROM public.sl_effects WHERE transaction_id=v_id AND role='from';
  SELECT account_id INTO v_old_to FROM public.sl_effects WHERE transaction_id=v_id AND role='to';
  SELECT min(replay_order) INTO v_order FROM public.sl_effects WHERE transaction_id=v_id;
  v_type:=CASE WHEN p_patch ? 'type' THEN p_patch->>'type' ELSE v_tx.type END;
  IF v_type IS NULL OR v_type NOT IN ('income','expense','transfer') THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  BEGIN
    v_amount:=CASE WHEN p_patch ? 'amount_minor' THEN (p_patch->>'amount_minor')::numeric ELSE v_tx.amount_minor END;
    v_time:=CASE WHEN p_patch ? 'occurred_at' THEN (p_patch->>'occurred_at')::timestamptz ELSE v_tx.occurred_at END;
    IF v_type='transfer' THEN
      IF p_patch ? 'account_id' THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
      v_from:=CASE WHEN p_patch ? 'from_account_id' THEN (p_patch->>'from_account_id')::uuid ELSE v_old_from END;
      v_to:=CASE WHEN p_patch ? 'to_account_id' THEN (p_patch->>'to_account_id')::uuid ELSE v_old_to END;
      IF v_from IS NULL OR v_to IS NULL OR v_from=v_to THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
    ELSE
      IF p_patch ? 'from_account_id' OR p_patch ? 'to_account_id' THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
      v_primary:=CASE WHEN p_patch ? 'account_id' THEN (p_patch->>'account_id')::uuid ELSE v_old_primary END;
      IF v_primary IS NULL THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
    END IF;
  EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_invalid_input'; END;
  v_category:=CASE WHEN p_patch ? 'category_code' THEN p_patch->>'category_code' ELSE v_tx.category_code END;
  v_merchant:=CASE WHEN p_patch ? 'merchant' THEN p_patch->>'merchant' ELSE v_tx.merchant END;
  v_note:=CASE WHEN p_patch ? 'note' THEN p_patch->>'note' ELSE v_tx.note END;
  IF v_amount IS NULL OR v_amount<=0 OR v_amount<>trunc(v_amount) OR v_amount>9007199254740991 OR
    v_time IS NULL OR v_time>now() OR v_category IS NULL OR v_category NOT IN
    ('food','shopping','transport','education','health','entertainment','utilities','other') OR
    v_merchant IS NULL OR v_note IS NULL THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  SELECT ARRAY(SELECT DISTINCT x FROM unnest(ARRAY[v_primary,v_from,v_to,v_old_primary,v_old_from,v_old_to]) x WHERE x IS NOT NULL) INTO v_accounts;
  PERFORM id FROM public.sl_accounts WHERE id=ANY(v_accounts) ORDER BY id FOR UPDATE;
  IF (SELECT count(*) FROM public.sl_accounts WHERE id=ANY(v_accounts) AND holder_user_id=v_actor)<>cardinality(v_accounts) THEN
    RAISE EXCEPTION 'sl_account_not_found'; END IF;
  IF (v_type,v_amount,v_time,v_primary,v_from,v_to,v_category,v_merchant,v_note) IS NOT DISTINCT FROM
    (v_tx.type,v_tx.amount_minor,v_tx.occurred_at,v_old_primary,v_old_from,v_old_to,v_tx.category_code,v_tx.merchant,v_tx.note) THEN
    RETURN jsonb_build_object('transaction',public.sl_transaction_json(v_id),'account_effects',public.sl_effects_json(v_id),
      'account_changes','[]'::jsonb,'affected_months','[]'::jsonb,'notices','[]'::jsonb);
  END IF;
  v_rebuild:=(v_type,v_primary,v_from,v_to) IS DISTINCT FROM (v_tx.type,v_old_primary,v_old_from,v_old_to) OR
    (v_amount<>v_tx.amount_minor AND v_type<>'expense');
  -- Date-only changes process only the endpoint crossing its own opening date.
  -- Ordinary expense amount edits retain their original delta/replenishment rule.
  IF NOT v_rebuild THEN
    FOR e IN SELECT * FROM public.sl_effects WHERE transaction_id=v_id ORDER BY role LOOP
      SELECT CASE WHEN (v_time AT TIME ZONE 'Asia/Shanghai')::date>=opening_date THEN 'applied'
        ELSE 'historical_only' END INTO v_status FROM public.sl_accounts WHERE id=e.account_id;
      IF e.status<>v_status THEN
        IF e.status='applied' THEN PERFORM public.sl_reverse_effect(e.id); END IF;
        IF v_status='applied' THEN
          v_notices:=v_notices||public.sl_apply_effect(v_type,e.role,e.account_id,v_actor,e.id,v_id,v_time,v_amount);
        END IF;
        v_changed:=array_append(v_changed,e.account_id);
      ELSIF v_status='applied' THEN
        IF v_type='expense' AND v_amount<>v_tx.amount_minor THEN
          v_notices:=v_notices||public.sl_record_expense_delta(e.account_id,v_actor,e.id,v_id,v_time,
            abs(v_amount-v_tx.amount_minor),v_amount<v_tx.amount_minor);
          v_changed:=array_append(v_changed,e.account_id);
        END IF;
        IF v_time<>v_tx.occurred_at THEN UPDATE public.sl_movements SET effective_at=v_time WHERE effect_id=e.id; END IF;
      END IF;
      UPDATE public.sl_effects SET status=v_status,
        signed_amount_minor=CASE WHEN v_type='income' OR e.role='to' THEN v_amount ELSE -v_amount END WHERE id=e.id;
    END LOOP;
  ELSE
    -- Reverse all old applied endpoints before applying any replacement.
    FOR e IN SELECT * FROM public.sl_effects WHERE transaction_id=v_id ORDER BY role LOOP
      IF e.status='applied' THEN
        PERFORM public.sl_reverse_effect(e.id); v_changed:=array_append(v_changed,e.account_id);
      END IF;
    END LOOP;
    DELETE FROM public.sl_movements WHERE effect_id IN(SELECT id FROM public.sl_effects WHERE transaction_id=v_id);
    DELETE FROM public.sl_effects WHERE transaction_id=v_id;
    v_notices:=public.sl_install_effects(v_id,v_actor,v_type,v_primary,v_from,v_to,v_amount,v_time,v_order);
    SELECT v_changed||ARRAY(SELECT account_id FROM public.sl_effects WHERE transaction_id=v_id AND status='applied') INTO v_changed;
  END IF;
  UPDATE public.sl_transactions SET type=v_type,
    accounting_semantics=CASE WHEN v_type='transfer' THEN 'internal_transfer' ELSE 'ordinary' END,
    amount_minor=v_amount,occurred_at=v_time,category_code=v_category,merchant=v_merchant,note=v_note,version=version+1 WHERE id=v_id;
  UPDATE public.sl_accounts SET version=version+1,funds_revision=funds_revision+1 WHERE id=ANY(v_changed);
  SELECT jsonb_agg(x ORDER BY x) INTO v_months FROM (SELECT DISTINCT
    to_char(x AT TIME ZONE 'Asia/Shanghai','YYYY-MM') AS x FROM unnest(ARRAY[v_tx.occurred_at,v_time]) x) m;
  RETURN jsonb_build_object('transaction',public.sl_transaction_json(v_id),'account_effects',public.sl_effects_json(v_id),
    'account_changes',public.sl_account_changes(v_changed),'affected_months',v_months,'notices',v_notices);
END;
$$;

CREATE OR REPLACE FUNCTION public.sl_delete_transaction(p_actor_subject text,p_transaction_id text,
  p_expected_version bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_id uuid; v_tx public.sl_transactions%ROWTYPE; e public.sl_effects%ROWTYPE;
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
  PERFORM a.id FROM public.sl_accounts a WHERE a.id IN
    (SELECT account_id FROM public.sl_effects WHERE transaction_id=v_id) ORDER BY a.id FOR UPDATE;
  IF EXISTS(SELECT 1 FROM public.sl_effects x JOIN public.sl_accounts a ON a.id=x.account_id
    WHERE x.transaction_id=v_id AND a.holder_user_id<>v_actor) THEN RAISE EXCEPTION 'sl_account_not_found'; END IF;
  FOR e IN SELECT * FROM public.sl_effects WHERE transaction_id=v_id ORDER BY role LOOP
    IF e.status='applied' THEN
      PERFORM public.sl_reverse_effect(e.id); v_changed:=array_append(v_changed,e.account_id);
    END IF;
  END LOOP;
  DELETE FROM public.sl_movements WHERE effect_id IN(SELECT id FROM public.sl_effects WHERE transaction_id=v_id);
  DELETE FROM public.sl_effects WHERE transaction_id=v_id;
  DELETE FROM public.sl_transactions WHERE id=v_id;
  UPDATE public.sl_accounts SET version=version+1,funds_revision=funds_revision+1 WHERE id=ANY(v_changed);
  RETURN jsonb_build_object('deleted_transaction_id',v_id::text,'account_changes',public.sl_account_changes(v_changed),
    'affected_months',jsonb_build_array(to_char(v_tx.occurred_at AT TIME ZONE 'Asia/Shanghai','YYYY-MM')));
END;
$$;

REVOKE ALL ON FUNCTION public.sl_apply_effect(text,text,uuid,uuid,uuid,uuid,timestamptz,numeric),
  public.sl_effects_json(uuid),public.sl_install_effects(uuid,uuid,text,uuid,uuid,uuid,numeric,timestamptz,bigint)
  FROM PUBLIC,anon,authenticated,service_role;

-- Rebuild only this account endpoint; the other transfer endpoint is unchanged.
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
        IF t.owner_id<>v_actor OR t.type NOT IN ('income','expense','transfer') OR
          (t.type='transfer' AND (t.accounting_semantics<>'internal_transfer' OR e.role NOT IN ('from','to'))) OR
          (t.type<>'transfer' AND (t.accounting_semantics<>'ordinary' OR e.role<>'primary')) OR
          e.signed_amount_minor<>(CASE WHEN t.type='expense' OR e.role='from' THEN -t.amount_minor ELSE t.amount_minor END) THEN
          RAISE EXCEPTION 'sl_opening_recalculation_conflict'; END IF;
        PERFORM public.sl_apply_effect(t.type,e.role,v_id,v_actor,e.id,t.id,r.event_time,t.amount_minor);
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
