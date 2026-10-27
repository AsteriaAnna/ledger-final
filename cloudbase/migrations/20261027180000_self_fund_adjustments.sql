-- Current self-owned share slice of adjustFunds. Opening movements remain immutable.
-- Rollback needs a separate reviewed migration because adjustment rows are ledger facts.

ALTER TABLE public.sl_movements DROP CONSTRAINT sl_movements_reason_check;
ALTER TABLE public.sl_movements ADD CONSTRAINT sl_movements_reason_check
  CHECK (reason IN ('opening','transaction','adjustment'));

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
    'savings_baseline_minor',CASE WHEN s.fund_type='savings' THEN s.baseline_minor ELSE NULL END,
    'savings_gap_minor',CASE WHEN s.fund_type='savings' THEN greatest(s.baseline_minor-s.current_minor,0) ELSE NULL END)
    ORDER BY CASE s.fund_type WHEN 'liquid' THEN 0 ELSE 1 END),'[]'::jsonb) INTO v_shares
  FROM (SELECT m.fund_type,sum(m.signed_amount_minor) AS current_minor,
    sum(m.signed_amount_minor) FILTER (WHERE m.reason IN ('opening','adjustment')) AS baseline_minor
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

CREATE OR REPLACE FUNCTION public.sl_account_visible_json(p_account_id uuid,p_actor uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.sl_accounts%ROWTYPE; v_result jsonb; v_opening jsonb; v_shares jsonb;
BEGIN
  SELECT * INTO a FROM public.sl_accounts WHERE id=p_account_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_account_not_found'; END IF;
  IF a.holder_user_id<>p_actor AND public.sl_partner_id(p_actor) IS DISTINCT FROM a.holder_user_id THEN
    RAISE EXCEPTION 'sl_account_not_found'; END IF;
  v_result := public.sl_account_json(p_account_id);
  IF a.holder_user_id=p_actor THEN RETURN v_result; END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'fund_owner',CASE WHEN fund_owner_id=p_actor THEN 'self' ELSE 'partner' END,
    'fund_type',fund_type,'amount_minor',amount_minor)
    ORDER BY CASE fund_type WHEN 'liquid' THEN 0 ELSE 1 END, fund_owner_id),'[]'::jsonb)
    INTO v_opening FROM (SELECT fund_owner_id,fund_type,sum(signed_amount_minor) AS amount_minor
      FROM public.sl_movements WHERE account_id=p_account_id AND reason='opening'
      GROUP BY fund_owner_id,fund_type) x;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'fund_owner',CASE WHEN fund_owner_id=p_actor THEN 'self' ELSE 'partner' END,
    'fund_type',fund_type,'amount_minor',current_minor,
    'savings_baseline_minor',CASE WHEN fund_type='savings' THEN baseline_minor ELSE NULL END,
    'savings_gap_minor',CASE WHEN fund_type='savings' THEN greatest(baseline_minor-current_minor,0) ELSE NULL END)
    ORDER BY CASE fund_type WHEN 'liquid' THEN 0 ELSE 1 END, fund_owner_id),'[]'::jsonb)
    INTO v_shares FROM (SELECT fund_owner_id,fund_type,sum(signed_amount_minor) AS current_minor,
      sum(signed_amount_minor) FILTER (WHERE reason IN ('opening','adjustment')) AS baseline_minor
      FROM public.sl_movements WHERE account_id=p_account_id GROUP BY fund_owner_id,fund_type) x;
  v_result := jsonb_set(v_result,'{holder}','"partner"'::jsonb);
  v_result := jsonb_set(v_result,'{custodian}',
    to_jsonb(CASE WHEN a.custodian_user_id=p_actor THEN 'self' ELSE 'partner' END));
  v_result := jsonb_set(v_result,'{opening_state,opening_allocations}',v_opening);
  v_result := jsonb_set(v_result,'{fund_shares}',v_shares);
  RETURN jsonb_set(v_result,'{read_only}','true'::jsonb);
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
  SELECT COALESCE(sum(signed_amount_minor) FILTER (WHERE fund_type='liquid'),0),
    COALESCE(sum(signed_amount_minor) FILTER (WHERE fund_type='savings'),0)
    INTO v_old_liquid,v_old_savings FROM public.sl_movements WHERE effect_id=e.id;
  IF v_account=v_new_account AND e.status=v_new_status THEN
    IF e.status='applied' AND v_amount<>t.amount_minor THEN
      v_delta:=v_amount-t.amount_minor;
      SELECT COALESCE(sum(signed_amount_minor) FILTER (WHERE fund_type='liquid'),0),
        COALESCE(sum(signed_amount_minor) FILTER (WHERE fund_type='savings'),0),
        COALESCE(sum(signed_amount_minor) FILTER (WHERE fund_type='savings' AND reason IN ('opening','adjustment')),0)
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

CREATE FUNCTION public.sl_adjust_funds(p_actor_subject text,p_account_id text,
  p_key_digest text,p_payload_hash text,p_expected_version bigint,p_input jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_account public.sl_accounts%ROWTYPE; v_id uuid;
  v_path text; v_prior jsonb; v_prior_hash text; v_from text; v_to text;
  v_amount numeric; v_available numeric; v_group uuid; v_result jsonb;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  IF p_key_digest !~ '^[0-9a-f]{64}$' OR p_payload_hash !~ '^[0-9a-f]{64}$' OR
    p_expected_version IS NULL OR p_expected_version<1 THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  BEGIN v_id:=p_account_id::uuid;
  EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_account_not_found'; END;
  v_path:='/api/v1/accounts/'||v_id::text||'/fund-adjustments';
  SELECT response_body,payload_hash INTO v_prior,v_prior_hash FROM public.sl_requests
    WHERE actor_id=v_actor AND method='POST' AND path=v_path AND key_digest=p_key_digest;
  IF FOUND THEN
    IF v_prior_hash<>p_payload_hash THEN RAISE EXCEPTION 'sl_idempotency_conflict'; END IF;
    RETURN v_prior;
  END IF;
  SELECT * INTO v_account FROM public.sl_accounts WHERE id=v_id AND holder_user_id=v_actor FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_account_not_found'; END IF;
  IF v_account.version<>p_expected_version THEN RAISE EXCEPTION 'sl_version_mismatch'; END IF;
  IF coalesce(jsonb_typeof(p_input),'null')<>'object' OR
    p_input->'from'->>'fund_owner' IS DISTINCT FROM 'self' OR
    p_input->'to'->>'fund_owner' IS DISTINCT FROM 'self' THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  v_from:=p_input->'from'->>'fund_type'; v_to:=p_input->'to'->>'fund_type';
  BEGIN v_amount:=(p_input->>'amount_minor')::numeric;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'sl_invalid_input'; END;
  IF v_from IS NULL OR v_to IS NULL OR v_from NOT IN ('liquid','savings') OR
    v_to NOT IN ('liquid','savings') OR v_from=v_to OR v_amount IS NULL OR
    v_amount<=0 OR v_amount<>trunc(v_amount) OR v_amount>9007199254740991 THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  SELECT COALESCE(sum(signed_amount_minor),0) INTO v_available FROM public.sl_movements
    WHERE account_id=v_id AND fund_owner_id=v_actor AND fund_type=v_from;
  IF v_available<v_amount THEN RAISE EXCEPTION 'sl_insufficient_funds'; END IF;
  v_group:=gen_random_uuid();
  INSERT INTO public.sl_movements(account_id,fund_owner_id,fund_type,signed_amount_minor,
    reason,operation_group,effective_at) VALUES
    (v_id,v_actor,v_from,-v_amount,'adjustment',v_group,now()),
    (v_id,v_actor,v_to,v_amount,'adjustment',v_group,now());
  UPDATE public.sl_accounts SET version=version+1,funds_revision=funds_revision+1 WHERE id=v_id;
  v_result:=public.sl_account_json(v_id);
  INSERT INTO public.sl_requests(actor_id,method,path,key_digest,payload_hash,response_body)
    VALUES(v_actor,'POST',v_path,p_key_digest,p_payload_hash,v_result);
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.sl_adjust_funds(text,text,text,text,bigint,jsonb)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.sl_adjust_funds(text,text,text,text,bigint,jsonb) TO service_role;
