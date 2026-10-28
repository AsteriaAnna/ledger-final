-- Maintenance of the currently supported manual-expense slice.
-- Every mutation runs in one PG transaction and holds the actor row before account locks.

CREATE OR REPLACE FUNCTION public.sl_account_json(p_account_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.sl_accounts%ROWTYPE; v_opening jsonb; v_shares jsonb; v_balance numeric;
BEGIN
  SELECT * INTO a FROM public.sl_accounts WHERE id=p_account_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_account_not_found'; END IF;
  SELECT COALESCE(sum(signed_amount_minor),0) INTO v_balance FROM public.sl_movements WHERE account_id=a.id;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('fund_owner','self','fund_type',fund_type,'amount_minor',amount_minor)
    ORDER BY CASE fund_type WHEN 'liquid' THEN 0 ELSE 1 END),'[]'::jsonb) INTO v_opening
  FROM (SELECT fund_type,sum(signed_amount_minor) AS amount_minor FROM public.sl_movements
    WHERE account_id=a.id AND reason='opening' GROUP BY fund_type) x;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'fund_owner','self','fund_type',s.fund_type,'amount_minor',s.current_minor,
    'savings_baseline_minor',CASE WHEN s.fund_type='savings' THEN s.opening_minor ELSE NULL END,
    'savings_gap_minor',CASE WHEN s.fund_type='savings' THEN greatest(s.opening_minor-s.current_minor,0) ELSE NULL END)
    ORDER BY CASE s.fund_type WHEN 'liquid' THEN 0 ELSE 1 END),'[]'::jsonb) INTO v_shares
  FROM (SELECT m.fund_type,sum(m.signed_amount_minor) AS current_minor,
    sum(m.signed_amount_minor) FILTER (WHERE m.reason='opening') AS opening_minor
    FROM public.sl_movements m WHERE m.account_id=a.id GROUP BY m.fund_type) s;
  RETURN jsonb_build_object('id',a.id::text,'name',a.name,'account_type',a.account_type,
    'holder','self','custodian',CASE WHEN a.custodian_user_id=a.holder_user_id THEN 'self' ELSE 'partner' END,
    'opening_state',jsonb_build_object('opening_date',a.opening_date::text,
      'opening_balance_minor',(SELECT COALESCE(sum(signed_amount_minor),0)
        FROM public.sl_movements WHERE account_id=a.id AND reason='opening'),
      'opening_allocations',v_opening),
    'balance_minor',v_balance,'fund_shares',v_shares,'version',a.version,'read_only',false);
END;
$$;

CREATE FUNCTION public.sl_patch_account(p_actor_subject text,p_account_id text,
  p_expected_version bigint,p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_account public.sl_accounts%ROWTYPE; v_id uuid;
  v_name text; v_type text; v_custodian text; v_custodian_id uuid;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  IF p_expected_version IS NULL OR p_expected_version<1 OR coalesce(jsonb_typeof(p_patch),'null')<>'object' OR
    EXISTS (SELECT 1 FROM jsonb_object_keys(p_patch) AS keys(name)
      WHERE name NOT IN ('name','account_type','custodian')) THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  BEGIN v_id:=p_account_id::uuid;
  EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_account_not_found'; END;
  SELECT * INTO v_account FROM public.sl_accounts WHERE id=v_id AND holder_user_id=v_actor FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_account_not_found'; END IF;
  IF v_account.version<>p_expected_version THEN RAISE EXCEPTION 'sl_version_mismatch'; END IF;
  v_name:=CASE WHEN p_patch ? 'name' THEN btrim(p_patch->>'name') ELSE v_account.name END;
  v_type:=CASE WHEN p_patch ? 'account_type' THEN p_patch->>'account_type' ELSE v_account.account_type END;
  v_custodian:=CASE WHEN p_patch ? 'custodian' THEN p_patch->>'custodian'
    WHEN v_account.custodian_user_id=v_actor THEN 'self' ELSE 'partner' END;
  IF v_name IS NULL OR char_length(v_name) NOT BETWEEN 1 AND 80 OR v_type IS NULL OR
    v_type NOT IN ('cash','bank_card','wechat_balance','alipay_balance','other') OR
    v_custodian IS NULL OR v_custodian NOT IN ('self','partner') THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  v_custodian_id:=CASE WHEN v_custodian='self' THEN v_actor ELSE public.sl_partner_id(v_actor) END;
  IF v_custodian_id IS NULL THEN RAISE EXCEPTION 'sl_relationship_conflict'; END IF;
  IF (v_name,v_type,v_custodian_id) IS DISTINCT FROM
     (v_account.name,v_account.account_type,v_account.custodian_user_id) THEN
    UPDATE public.sl_accounts SET name=v_name,account_type=v_type,custodian_user_id=v_custodian_id,
      version=version+1 WHERE id=v_id;
  END IF;
  RETURN public.sl_account_json(v_id);
END;
$$;

CREATE FUNCTION public.sl_patch_expense(p_actor_subject text,p_transaction_id text,
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
  SELECT COALESCE(sum(signed_amount_minor) FILTER (WHERE fund_type='liquid'),0),
    COALESCE(sum(signed_amount_minor) FILTER (WHERE fund_type='savings'),0)
    INTO v_old_liquid,v_old_savings FROM public.sl_movements WHERE effect_id=e.id;
  IF v_account=v_new_account AND e.status=v_new_status THEN
    IF e.status='applied' AND v_amount<>t.amount_minor THEN
      v_delta:=v_amount-t.amount_minor;
      SELECT COALESCE(sum(signed_amount_minor) FILTER (WHERE fund_type='liquid'),0),
        COALESCE(sum(signed_amount_minor) FILTER (WHERE fund_type='savings'),0),
        COALESCE(sum(signed_amount_minor) FILTER (WHERE fund_type='savings' AND reason='opening'),0)
        INTO v_liquid,v_savings,v_open_savings FROM public.sl_movements WHERE account_id=v_account AND fund_owner_id=v_actor;
      IF v_delta>0 THEN
        IF v_delta>v_liquid+v_savings THEN RAISE EXCEPTION 'sl_insufficient_funds'; END IF;
        v_take_liquid:=least(v_liquid,v_delta); v_take_savings:=v_delta-v_take_liquid;
        v_new_liquid:=v_old_liquid-v_take_liquid; v_new_savings:=v_old_savings-v_take_savings;
        IF v_take_savings>0 THEN v_notice:=jsonb_build_array(
          jsonb_build_object('code','OWN_SAVINGS_USED','amount_minor',v_take_savings)); END IF;
      ELSE
        v_add_savings:=least(greatest(v_open_savings-v_savings,0),-v_delta);
        v_add_liquid:=-v_delta-v_add_savings;
        v_new_liquid:=v_old_liquid+v_add_liquid; v_new_savings:=v_old_savings+v_add_savings;
      END IF;
      DELETE FROM public.sl_movements WHERE effect_id=e.id;
      IF v_new_liquid<>0 THEN
        INSERT INTO public.sl_movements(account_id,fund_owner_id,fund_type,signed_amount_minor,
          reason,operation_group,effect_id,effective_at)
        VALUES(v_account,v_actor,'liquid',v_new_liquid,'transaction',v_id,e.id,v_time);
      END IF;
      IF v_new_savings<>0 THEN
        INSERT INTO public.sl_movements(account_id,fund_owner_id,fund_type,signed_amount_minor,
          reason,operation_group,effect_id,effective_at)
        VALUES(v_account,v_actor,'savings',v_new_savings,'transaction',v_id,e.id,v_time);
      END IF;
    ELSIF e.status='applied' AND v_time<>t.occurred_at THEN
      UPDATE public.sl_movements SET effective_at=v_time WHERE effect_id=e.id;
    END IF;
  ELSE
    IF e.status='applied' THEN
      SELECT COALESCE(sum(signed_amount_minor) FILTER (WHERE fund_type='liquid'),0),
        COALESCE(sum(signed_amount_minor) FILTER (WHERE fund_type='savings'),0)
        INTO v_liquid,v_savings FROM public.sl_movements WHERE account_id=v_account AND fund_owner_id=v_actor;
      IF v_liquid-v_old_liquid<0 OR v_savings-v_old_savings<0 THEN RAISE EXCEPTION 'sl_unsafe_reversal'; END IF;
    END IF;
    DELETE FROM public.sl_movements WHERE effect_id=e.id;
    IF v_new_status='applied' THEN
      SELECT COALESCE(sum(signed_amount_minor) FILTER (WHERE fund_type='liquid'),0),
        COALESCE(sum(signed_amount_minor) FILTER (WHERE fund_type='savings'),0)
        INTO v_liquid,v_savings FROM public.sl_movements WHERE account_id=v_new_account AND fund_owner_id=v_actor;
      IF v_amount>v_liquid+v_savings THEN RAISE EXCEPTION 'sl_insufficient_funds'; END IF;
      v_take_liquid:=least(v_liquid,v_amount); v_take_savings:=v_amount-v_take_liquid;
      IF v_take_liquid>0 THEN
        INSERT INTO public.sl_movements(account_id,fund_owner_id,fund_type,signed_amount_minor,
          reason,operation_group,effect_id,effective_at)
        VALUES(v_new_account,v_actor,'liquid',-v_take_liquid,'transaction',v_id,e.id,v_time);
      END IF;
      IF v_take_savings>0 THEN
        INSERT INTO public.sl_movements(account_id,fund_owner_id,fund_type,signed_amount_minor,
          reason,operation_group,effect_id,effective_at)
        VALUES(v_new_account,v_actor,'savings',-v_take_savings,'transaction',v_id,e.id,v_time);
        v_notice:=jsonb_build_array(jsonb_build_object('code','OWN_SAVINGS_USED','amount_minor',v_take_savings));
      END IF;
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

CREATE FUNCTION public.sl_delete_expense(p_actor_subject text,p_transaction_id text,
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
  IF e.status='applied' THEN
    SELECT COALESCE(sum(signed_amount_minor) FILTER (WHERE fund_type='liquid'),0),
      COALESCE(sum(signed_amount_minor) FILTER (WHERE fund_type='savings'),0)
      INTO v_liquid,v_savings FROM public.sl_movements WHERE account_id=e.account_id AND fund_owner_id=v_actor;
    SELECT COALESCE(sum(signed_amount_minor) FILTER (WHERE fund_type='liquid'),0),
      COALESCE(sum(signed_amount_minor) FILTER (WHERE fund_type='savings'),0)
      INTO v_effect_liquid,v_effect_savings FROM public.sl_movements WHERE effect_id=e.id;
    IF v_liquid-v_effect_liquid<0 OR v_savings-v_effect_savings<0 THEN RAISE EXCEPTION 'sl_unsafe_reversal'; END IF;
  END IF;
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

REVOKE ALL ON FUNCTION public.sl_patch_account(text,text,bigint,jsonb),
  public.sl_patch_expense(text,text,bigint,jsonb),public.sl_delete_expense(text,text,bigint)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.sl_patch_account(text,text,bigint,jsonb),
  public.sl_patch_expense(text,text,bigint,jsonb),public.sl_delete_expense(text,text,bigint)
  TO service_role;
