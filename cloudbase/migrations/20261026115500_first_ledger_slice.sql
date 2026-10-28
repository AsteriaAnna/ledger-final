-- First runnable ledger slice. All money is integer cents; balance is derived from movements.
CREATE TABLE public.sl_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_subject text NOT NULL UNIQUE,
  display_name text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.sl_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  holder_user_id uuid NOT NULL REFERENCES public.sl_users(id),
  custodian_user_id uuid NOT NULL REFERENCES public.sl_users(id),
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 80),
  account_type text NOT NULL CHECK (account_type IN ('cash','bank_card','wechat_balance','alipay_balance','other')),
  opening_date date NOT NULL,
  version bigint NOT NULL DEFAULT 1 CHECK (version >= 1),
  funds_revision bigint NOT NULL DEFAULT 1 CHECK (funds_revision >= 1),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX sl_accounts_holder_order ON public.sl_accounts(holder_user_id, created_at DESC, id DESC);

CREATE TABLE public.sl_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES public.sl_users(id),
  type text NOT NULL CHECK (type = 'expense'),
  accounting_semantics text NOT NULL CHECK (accounting_semantics = 'ordinary'),
  amount_minor numeric(20,0) NOT NULL CHECK (amount_minor > 0),
  occurred_at timestamptz NOT NULL,
  category_code text NOT NULL CHECK (category_code IN ('food','shopping','transport','education','health','entertainment','utilities','other')),
  merchant text NOT NULL DEFAULT '',
  note text NOT NULL DEFAULT '',
  version bigint NOT NULL DEFAULT 1 CHECK (version >= 1),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX sl_transactions_owner_order ON public.sl_transactions(owner_id, occurred_at DESC, id DESC);

CREATE TABLE public.sl_effects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id uuid NOT NULL REFERENCES public.sl_transactions(id),
  account_id uuid NOT NULL REFERENCES public.sl_accounts(id),
  role text NOT NULL CHECK (role = 'primary'),
  signed_amount_minor numeric(20,0) NOT NULL CHECK (signed_amount_minor <> 0),
  status text NOT NULL CHECK (status IN ('applied','historical_only')),
  UNIQUE(transaction_id,role),
  UNIQUE(transaction_id,account_id)
);

CREATE TABLE public.sl_movements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.sl_accounts(id),
  fund_owner_id uuid NOT NULL REFERENCES public.sl_users(id),
  fund_type text NOT NULL CHECK (fund_type IN ('liquid','savings')),
  signed_amount_minor numeric(20,0) NOT NULL,
  reason text NOT NULL CHECK (reason IN ('opening','transaction')),
  operation_group uuid NOT NULL,
  effect_id uuid REFERENCES public.sl_effects(id),
  effective_at timestamptz NOT NULL,
  CHECK ((reason = 'transaction') = (effect_id IS NOT NULL))
);
CREATE INDEX sl_movements_account_share ON public.sl_movements(account_id, fund_owner_id, fund_type);
CREATE INDEX sl_movements_effect ON public.sl_movements(effect_id);

CREATE TABLE public.sl_requests (
  actor_id uuid NOT NULL REFERENCES public.sl_users(id),
  method text NOT NULL,
  path text NOT NULL,
  key_digest text NOT NULL,
  payload_hash text NOT NULL,
  response_body jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT now() + interval '24 hours',
  PRIMARY KEY(actor_id, method, path, key_digest)
);

ALTER TABLE public.sl_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sl_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sl_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sl_effects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sl_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sl_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sl_users, public.sl_accounts, public.sl_transactions, public.sl_effects, public.sl_movements, public.sl_requests FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.sl_users, public.sl_accounts, public.sl_transactions, public.sl_effects, public.sl_movements, public.sl_requests TO service_role;

CREATE FUNCTION public.sl_account_json(p_account_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE a public.sl_accounts%ROWTYPE; v_opening jsonb; v_shares jsonb; v_balance numeric;
BEGIN
  SELECT * INTO a FROM public.sl_accounts WHERE id = p_account_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_account_not_found'; END IF;
  SELECT COALESCE(sum(signed_amount_minor),0) INTO v_balance FROM public.sl_movements WHERE account_id = a.id;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('fund_owner','self','fund_type',fund_type,'amount_minor',amount_minor)
    ORDER BY CASE fund_type WHEN 'liquid' THEN 0 ELSE 1 END), '[]'::jsonb) INTO v_opening
  FROM (SELECT fund_type, sum(signed_amount_minor) AS amount_minor FROM public.sl_movements
    WHERE account_id=a.id AND reason='opening' GROUP BY fund_type) x;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'fund_owner','self','fund_type',s.fund_type,'amount_minor',s.current_minor,
    'savings_baseline_minor',CASE WHEN s.fund_type='savings' THEN s.opening_minor ELSE NULL END,
    'savings_gap_minor',CASE WHEN s.fund_type='savings' THEN greatest(s.opening_minor-s.current_minor,0) ELSE NULL END)
    ORDER BY CASE s.fund_type WHEN 'liquid' THEN 0 ELSE 1 END), '[]'::jsonb) INTO v_shares
  FROM (SELECT m.fund_type, sum(m.signed_amount_minor) AS current_minor,
    sum(m.signed_amount_minor) FILTER (WHERE m.reason='opening') AS opening_minor
    FROM public.sl_movements m WHERE m.account_id=a.id GROUP BY m.fund_type) s;
  RETURN jsonb_build_object('id',a.id::text,'name',a.name,'account_type',a.account_type,
    'holder','self','custodian','self','opening_state',jsonb_build_object(
      'opening_date',a.opening_date::text,'opening_balance_minor',
      (SELECT COALESCE(sum(signed_amount_minor),0) FROM public.sl_movements WHERE account_id=a.id AND reason='opening'),
      'opening_allocations',v_opening),
    'balance_minor',v_balance,'fund_shares',v_shares,'version',a.version,'read_only',false);
END;
$$;

CREATE FUNCTION public.sl_transaction_json(p_transaction_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE t public.sl_transactions%ROWTYPE; v_account_id uuid;
BEGIN
  SELECT * INTO t FROM public.sl_transactions WHERE id=p_transaction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_transaction_not_found'; END IF;
  SELECT account_id INTO v_account_id FROM public.sl_effects WHERE transaction_id=t.id;
  RETURN jsonb_build_object('id',t.id::text,'type','expense','accounting_semantics','ordinary',
    'amount_minor',t.amount_minor,'occurred_at',to_char(t.occurred_at AT TIME ZONE 'Asia/Shanghai','YYYY-MM-DD"T"HH24:MI:SS')||'+08:00',
    'category_code',t.category_code,'merchant',t.merchant,'note',t.note,
    'source_account_profile_id',NULL,'source_summaries','[]'::jsonb,
    'version',t.version,'read_only',false,'account_id',v_account_id::text);
END;
$$;

CREATE FUNCTION public.sl_provision_user(p_auth_subject text, p_display_name text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid;
BEGIN
  IF p_auth_subject IS NULL OR p_auth_subject='' OR p_display_name IS NULL OR p_display_name='' THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  INSERT INTO public.sl_users(auth_subject, display_name) VALUES (p_auth_subject, p_display_name)
    ON CONFLICT(auth_subject) DO UPDATE SET display_name=EXCLUDED.display_name RETURNING id INTO v_id;
  RETURN v_id::text;
END;
$$;

CREATE FUNCTION public.sl_get_account(p_actor_subject text, p_account_id text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_account uuid;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  BEGIN v_account := p_account_id::uuid; EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_account_not_found'; END;
  IF NOT EXISTS (SELECT 1 FROM public.sl_accounts WHERE id=v_account AND holder_user_id=v_actor) THEN
    RAISE EXCEPTION 'sl_account_not_found'; END IF;
  RETURN public.sl_account_json(v_account);
END;
$$;

CREATE FUNCTION public.sl_list_accounts(p_actor_subject text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_result jsonb;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  SELECT COALESCE(jsonb_agg(public.sl_account_json(id) ORDER BY created_at DESC,id DESC),'[]'::jsonb)
    INTO v_result FROM (SELECT id,created_at FROM public.sl_accounts WHERE holder_user_id=v_actor ORDER BY created_at DESC,id DESC LIMIT 50) a;
  RETURN v_result;
END;
$$;

CREATE FUNCTION public.sl_get_transaction(p_actor_subject text, p_transaction_id text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_transaction uuid;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  BEGIN v_transaction := p_transaction_id::uuid; EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_transaction_not_found'; END;
  IF NOT EXISTS (SELECT 1 FROM public.sl_transactions WHERE id=v_transaction AND owner_id=v_actor) THEN
    RAISE EXCEPTION 'sl_transaction_not_found'; END IF;
  RETURN public.sl_transaction_json(v_transaction);
END;
$$;

CREATE FUNCTION public.sl_list_transactions(p_actor_subject text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_result jsonb;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  SELECT COALESCE(jsonb_agg(public.sl_transaction_json(id) ORDER BY occurred_at DESC,id DESC),'[]'::jsonb)
    INTO v_result FROM (SELECT id,occurred_at FROM public.sl_transactions WHERE owner_id=v_actor ORDER BY occurred_at DESC,id DESC LIMIT 50) t;
  RETURN v_result;
END;
$$;

CREATE FUNCTION public.sl_create_account(p_actor_subject text, p_key_digest text, p_payload_hash text, p_input jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_account uuid; v_row jsonb; v_prior_hash text; v_alloc jsonb; v_total numeric:=0; v_seen text[]:='{}';
  v_amount numeric; v_type text; v_open_date date; v_balance numeric; v_response jsonb;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  IF p_key_digest !~ '^[0-9a-f]{64}$' OR p_payload_hash !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  SELECT response_body,payload_hash INTO v_row,v_prior_hash FROM public.sl_requests
    WHERE actor_id=v_actor AND method='POST' AND path='/api/v1/accounts' AND key_digest=p_key_digest;
  IF FOUND THEN
    IF v_prior_hash <> p_payload_hash THEN RAISE EXCEPTION 'sl_idempotency_conflict'; END IF;
    RETURN v_row;
  END IF;
  IF p_input->>'custodian' <> 'self' OR p_input->>'name' IS NULL OR p_input->>'account_type' NOT IN
    ('cash','bank_card','wechat_balance','alipay_balance','other') THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  BEGIN
    v_open_date := (p_input->'opening_state'->>'opening_date')::date;
    v_balance := (p_input->'opening_state'->>'opening_balance_minor')::numeric;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'sl_invalid_input'; END;
  IF v_open_date > (now() AT TIME ZONE 'Asia/Shanghai')::date OR v_balance < 0 OR v_balance <> trunc(v_balance) THEN
    RAISE EXCEPTION 'sl_invalid_input'; END IF;
  INSERT INTO public.sl_accounts(holder_user_id,custodian_user_id,name,account_type,opening_date)
    VALUES(v_actor,v_actor,p_input->>'name',p_input->>'account_type',v_open_date) RETURNING id INTO v_account;
  v_seen := '{}';
  FOR v_alloc IN SELECT value FROM jsonb_array_elements(p_input->'opening_state'->'opening_allocations') LOOP
    v_type := v_alloc->>'fund_type';
    IF v_alloc->>'fund_owner' <> 'self' OR v_type NOT IN ('liquid','savings') OR v_type=ANY(v_seen) THEN
      RAISE EXCEPTION 'sl_invalid_input'; END IF;
    BEGIN v_amount := (v_alloc->>'amount_minor')::numeric;
    EXCEPTION WHEN others THEN RAISE EXCEPTION 'sl_invalid_input'; END;
    IF v_amount < 0 OR v_amount <> trunc(v_amount) THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
    v_seen := array_append(v_seen,v_type); v_total := v_total+v_amount;
    INSERT INTO public.sl_movements(account_id,fund_owner_id,fund_type,signed_amount_minor,reason,operation_group,effective_at)
      VALUES(v_account,v_actor,v_type,v_amount,'opening',v_account,v_open_date::timestamp AT TIME ZONE 'Asia/Shanghai');
  END LOOP;
  IF cardinality(v_seen)<1 OR v_total<>v_balance THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  v_response := public.sl_account_json(v_account);
  INSERT INTO public.sl_requests(actor_id,method,path,key_digest,payload_hash,response_body)
    VALUES(v_actor,'POST','/api/v1/accounts',p_key_digest,p_payload_hash,v_response);
  RETURN v_response;
END;
$$;

CREATE FUNCTION public.sl_create_expense(p_actor_subject text, p_key_digest text, p_payload_hash text, p_input jsonb) RETURNS jsonb
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
  IF v_amount<=0 OR v_amount<>trunc(v_amount) OR v_occurred>now() THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  BEGIN
    SELECT * INTO v_account FROM public.sl_accounts WHERE id=(p_input->>'account_id')::uuid AND holder_user_id=v_actor FOR UPDATE;
  EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_account_not_found'; END;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_account_not_found'; END IF;
  v_applied := (v_occurred AT TIME ZONE 'Asia/Shanghai')::date >= v_account.opening_date;
  IF v_applied THEN
    SELECT COALESCE(sum(signed_amount_minor),0) INTO v_liquid FROM public.sl_movements
      WHERE account_id=v_account.id AND fund_owner_id=v_actor AND fund_type='liquid';
    SELECT COALESCE(sum(signed_amount_minor),0) INTO v_savings FROM public.sl_movements
      WHERE account_id=v_account.id AND fund_owner_id=v_actor AND fund_type='savings';
    IF v_amount>v_liquid+v_savings THEN RAISE EXCEPTION 'sl_insufficient_funds'; END IF;
    v_use_liquid:=least(v_liquid,v_amount); v_use_savings:=v_amount-v_use_liquid;
  END IF;
  INSERT INTO public.sl_transactions(owner_id,type,accounting_semantics,amount_minor,occurred_at,category_code,merchant,note)
    VALUES(v_actor,'expense','ordinary',v_amount,v_occurred,p_input->>'category_code',p_input->>'merchant',p_input->>'note')
    RETURNING id INTO v_transaction;
  INSERT INTO public.sl_effects(transaction_id,account_id,role,signed_amount_minor,status)
    VALUES(v_transaction,v_account.id,'primary',-v_amount,CASE WHEN v_applied THEN 'applied' ELSE 'historical_only' END)
    RETURNING id INTO v_effect;
  IF v_applied THEN
    IF v_use_liquid>0 THEN
      INSERT INTO public.sl_movements(account_id,fund_owner_id,fund_type,signed_amount_minor,reason,operation_group,effect_id,effective_at)
        VALUES(v_account.id,v_actor,'liquid',-v_use_liquid,'transaction',v_transaction,v_effect,v_occurred);
    END IF;
    IF v_use_savings>0 THEN
      INSERT INTO public.sl_movements(account_id,fund_owner_id,fund_type,signed_amount_minor,reason,operation_group,effect_id,effective_at)
        VALUES(v_account.id,v_actor,'savings',-v_use_savings,'transaction',v_transaction,v_effect,v_occurred);
      v_notice:=jsonb_build_array(jsonb_build_object('code','OWN_SAVINGS_USED','amount_minor',v_use_savings));
    END IF;
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

REVOKE ALL ON FUNCTION public.sl_account_json(uuid), public.sl_transaction_json(uuid),
  public.sl_provision_user(text,text), public.sl_get_account(text,text), public.sl_list_accounts(text),
  public.sl_get_transaction(text,text), public.sl_list_transactions(text),
  public.sl_create_account(text,text,text,jsonb), public.sl_create_expense(text,text,text,jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sl_account_json(uuid), public.sl_transaction_json(uuid),
  public.sl_provision_user(text,text), public.sl_get_account(text,text), public.sl_list_accounts(text),
  public.sl_get_transaction(text,text), public.sl_list_transactions(text),
  public.sl_create_account(text,text,text,jsonb), public.sl_create_expense(text,text,text,jsonb)
  TO service_role;
