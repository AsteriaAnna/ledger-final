-- M1 relationship and reciprocal read-only projections for the first two-user slice.
CREATE TABLE public.sl_bindings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.sl_binding_members (
  user_id uuid PRIMARY KEY REFERENCES public.sl_users(id),
  binding_id uuid NOT NULL REFERENCES public.sl_bindings(id),
  UNIQUE(binding_id,user_id)
);
CREATE INDEX sl_binding_members_binding ON public.sl_binding_members(binding_id);

CREATE TABLE public.sl_invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  inviter_id uuid NOT NULL REFERENCES public.sl_users(id),
  token_hash text NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz NOT NULL,
  consumed_by uuid REFERENCES public.sl_users(id),
  consumed_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((consumed_by IS NULL) = (consumed_at IS NULL))
);
CREATE UNIQUE INDEX sl_invitations_one_active ON public.sl_invitations(inviter_id)
  WHERE consumed_at IS NULL AND revoked_at IS NULL;

ALTER TABLE public.sl_bindings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sl_binding_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sl_invitations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sl_bindings, public.sl_binding_members, public.sl_invitations FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.sl_bindings, public.sl_binding_members, public.sl_invitations TO service_role;

CREATE FUNCTION public.sl_partner_id(p_actor uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT other.user_id FROM public.sl_binding_members own
  JOIN public.sl_binding_members other ON other.binding_id=own.binding_id AND other.user_id<>own.user_id
  WHERE own.user_id=p_actor;
$$;

CREATE FUNCTION public.sl_relationship_json(p_actor uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_partner uuid; v_name text;
BEGIN
  v_partner := public.sl_partner_id(p_actor);
  IF v_partner IS NULL THEN
    RETURN jsonb_build_object('status','unbound','partner',NULL,'permissions',
      jsonb_build_object('partner_accounts','none','partner_transactions','none'));
  END IF;
  SELECT display_name INTO v_name FROM public.sl_users WHERE id=v_partner;
  RETURN jsonb_build_object('status','bound','partner',
    jsonb_build_object('id',v_partner::text,'display_name',v_name),'permissions',
    jsonb_build_object('partner_accounts','read_only','partner_transactions','read_only'));
END;
$$;

CREATE FUNCTION public.sl_get_relationship(p_actor_subject text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  RETURN public.sl_relationship_json(v_actor);
END;
$$;

CREATE FUNCTION public.sl_create_invitation(p_actor_subject text, p_key_digest text,
  p_payload_hash text, p_token_hash text, p_token text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_prior jsonb; v_prior_hash text; v_expiry timestamptz; v_result jsonb;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  IF coalesce(p_key_digest,'') !~ '^[0-9a-f]{64}$' OR
     coalesce(p_payload_hash,'') !~ '^[0-9a-f]{64}$' OR
     coalesce(p_token_hash,'') !~ '^[0-9a-f]{64}$' OR
     coalesce(p_token,'') !~ '^[A-Za-z0-9_-]{43}$' THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  SELECT response_body,payload_hash INTO v_prior,v_prior_hash FROM public.sl_requests
    WHERE actor_id=v_actor AND method='POST' AND path='/api/v1/relationship/invitations'
      AND key_digest=p_key_digest AND expires_at>now();
  IF FOUND THEN
    IF v_prior_hash<>p_payload_hash THEN RAISE EXCEPTION 'sl_idempotency_conflict'; END IF;
    RETURN v_prior;
  END IF;
  IF public.sl_partner_id(v_actor) IS NOT NULL THEN RAISE EXCEPTION 'sl_relationship_conflict'; END IF;
  UPDATE public.sl_invitations SET revoked_at=now()
    WHERE inviter_id=v_actor AND consumed_at IS NULL AND revoked_at IS NULL;
  v_expiry := now() + interval '10 minutes';
  INSERT INTO public.sl_invitations(inviter_id,token_hash,expires_at)
    VALUES(v_actor,p_token_hash,v_expiry);
  v_result := jsonb_build_object('binding_token',p_token,'expires_at',
    to_char(v_expiry AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  INSERT INTO public.sl_requests(actor_id,method,path,key_digest,payload_hash,response_body)
    VALUES(v_actor,'POST','/api/v1/relationship/invitations',p_key_digest,p_payload_hash,v_result);
  RETURN v_result;
END;
$$;

CREATE FUNCTION public.sl_bind_relationship(p_actor_subject text, p_key_digest text,
  p_payload_hash text, p_token_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_inviter uuid; v_inv public.sl_invitations%ROWTYPE;
  v_prior jsonb; v_prior_hash text; v_binding uuid; v_result jsonb;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  IF coalesce(p_key_digest,'') !~ '^[0-9a-f]{64}$' OR
     coalesce(p_payload_hash,'') !~ '^[0-9a-f]{64}$' OR
     coalesce(p_token_hash,'') !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  SELECT response_body,payload_hash INTO v_prior,v_prior_hash FROM public.sl_requests
    WHERE actor_id=v_actor AND method='POST' AND path='/api/v1/relationship/binding'
      AND key_digest=p_key_digest AND expires_at>now();
  IF FOUND THEN
    IF v_prior_hash<>p_payload_hash THEN RAISE EXCEPTION 'sl_idempotency_conflict'; END IF;
    RETURN v_prior;
  END IF;
  SELECT inviter_id INTO v_inviter FROM public.sl_invitations WHERE token_hash=p_token_hash;
  IF NOT FOUND OR v_inviter=v_actor THEN RAISE EXCEPTION 'sl_binding_invitation_invalid'; END IF;
  -- Both identities are locked in the same order, including simultaneous crossed invitations.
  PERFORM id FROM public.sl_users WHERE id IN (v_actor,v_inviter) ORDER BY id FOR UPDATE;
  SELECT response_body,payload_hash INTO v_prior,v_prior_hash FROM public.sl_requests
    WHERE actor_id=v_actor AND method='POST' AND path='/api/v1/relationship/binding'
      AND key_digest=p_key_digest AND expires_at>now();
  IF FOUND THEN
    IF v_prior_hash<>p_payload_hash THEN RAISE EXCEPTION 'sl_idempotency_conflict'; END IF;
    RETURN v_prior;
  END IF;
  SELECT * INTO v_inv FROM public.sl_invitations WHERE token_hash=p_token_hash FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_binding_invitation_invalid'; END IF;
  IF v_inv.consumed_by=v_actor AND public.sl_partner_id(v_actor)=v_inviter THEN
    v_result := public.sl_relationship_json(v_actor);
  ELSE
    IF public.sl_partner_id(v_actor) IS NOT NULL OR public.sl_partner_id(v_inviter) IS NOT NULL THEN
      RAISE EXCEPTION 'sl_relationship_conflict'; END IF;
    IF v_inv.revoked_at IS NOT NULL OR v_inv.consumed_at IS NOT NULL OR v_inv.expires_at<=now() THEN
      RAISE EXCEPTION 'sl_binding_invitation_invalid'; END IF;
    INSERT INTO public.sl_bindings DEFAULT VALUES RETURNING id INTO v_binding;
    INSERT INTO public.sl_binding_members(user_id,binding_id) VALUES(v_actor,v_binding),(v_inviter,v_binding);
    UPDATE public.sl_invitations SET consumed_by=v_actor,consumed_at=now() WHERE id=v_inv.id;
    UPDATE public.sl_invitations SET revoked_at=now()
      WHERE inviter_id IN (v_actor,v_inviter) AND id<>v_inv.id AND consumed_at IS NULL AND revoked_at IS NULL;
    v_result := public.sl_relationship_json(v_actor);
  END IF;
  INSERT INTO public.sl_requests(actor_id,method,path,key_digest,payload_hash,response_body)
    VALUES(v_actor,'POST','/api/v1/relationship/binding',p_key_digest,p_payload_hash,v_result);
  RETURN v_result;
END;
$$;

CREATE FUNCTION public.sl_account_visible_json(p_account_id uuid,p_actor uuid) RETURNS jsonb
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
    'savings_baseline_minor',CASE WHEN fund_type='savings' THEN opening_minor ELSE NULL END,
    'savings_gap_minor',CASE WHEN fund_type='savings' THEN greatest(opening_minor-current_minor,0) ELSE NULL END)
    ORDER BY CASE fund_type WHEN 'liquid' THEN 0 ELSE 1 END, fund_owner_id),'[]'::jsonb)
    INTO v_shares FROM (SELECT fund_owner_id,fund_type,sum(signed_amount_minor) AS current_minor,
      sum(signed_amount_minor) FILTER (WHERE reason='opening') AS opening_minor
      FROM public.sl_movements WHERE account_id=p_account_id GROUP BY fund_owner_id,fund_type) x;
  v_result := jsonb_set(v_result,'{holder}','"partner"'::jsonb);
  v_result := jsonb_set(v_result,'{custodian}',
    to_jsonb(CASE WHEN a.custodian_user_id=p_actor THEN 'self' ELSE 'partner' END));
  v_result := jsonb_set(v_result,'{opening_state,opening_allocations}',v_opening);
  v_result := jsonb_set(v_result,'{fund_shares}',v_shares);
  RETURN jsonb_set(v_result,'{read_only}','true'::jsonb);
END;
$$;

CREATE FUNCTION public.sl_get_account_visible(p_actor_subject text,p_account_id text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_account uuid;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  BEGIN v_account:=p_account_id::uuid;
  EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_account_not_found'; END;
  RETURN public.sl_account_visible_json(v_account,v_actor);
END;
$$;

CREATE FUNCTION public.sl_list_accounts_visible(p_actor_subject text,p_view text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_owner uuid; v_result jsonb;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  IF p_view='mine' THEN v_owner:=v_actor;
  ELSIF p_view='partner' THEN
    v_owner:=public.sl_partner_id(v_actor);
    IF v_owner IS NULL THEN RAISE EXCEPTION 'sl_partner_unavailable'; END IF;
  ELSE RAISE EXCEPTION 'sl_invalid_input'; END IF;
  SELECT COALESCE(jsonb_agg(public.sl_account_visible_json(id,v_actor)
    ORDER BY created_at DESC,id DESC),'[]'::jsonb) INTO v_result
    FROM (SELECT id,created_at FROM public.sl_accounts WHERE holder_user_id=v_owner
      ORDER BY created_at DESC,id DESC LIMIT 50) a;
  RETURN v_result;
END;
$$;

CREATE FUNCTION public.sl_transaction_visible_json(p_transaction_id uuid,p_actor uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_owner uuid; v_result jsonb;
BEGIN
  SELECT owner_id INTO v_owner FROM public.sl_transactions WHERE id=p_transaction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_transaction_not_found'; END IF;
  IF v_owner<>p_actor AND public.sl_partner_id(p_actor) IS DISTINCT FROM v_owner THEN
    RAISE EXCEPTION 'sl_transaction_not_found'; END IF;
  v_result:=public.sl_transaction_json(p_transaction_id);
  IF v_owner=p_actor THEN RETURN v_result; END IF;
  v_result:=jsonb_set(v_result,'{source_account_profile_id}','null'::jsonb);
  v_result:=jsonb_set(v_result,'{source_summaries}','[]'::jsonb);
  RETURN jsonb_set(v_result,'{read_only}','true'::jsonb);
END;
$$;

CREATE FUNCTION public.sl_get_transaction_visible(p_actor_subject text,p_transaction_id text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_transaction uuid;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  BEGIN v_transaction:=p_transaction_id::uuid;
  EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_transaction_not_found'; END;
  RETURN public.sl_transaction_visible_json(v_transaction,v_actor);
END;
$$;

CREATE FUNCTION public.sl_list_transactions_visible(p_actor_subject text,p_view text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_owner uuid; v_result jsonb;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  IF p_view='mine' THEN v_owner:=v_actor;
  ELSIF p_view='partner' THEN
    v_owner:=public.sl_partner_id(v_actor);
    IF v_owner IS NULL THEN RAISE EXCEPTION 'sl_partner_unavailable'; END IF;
  ELSE RAISE EXCEPTION 'sl_invalid_input'; END IF;
  SELECT COALESCE(jsonb_agg(public.sl_transaction_visible_json(id,v_actor)
    ORDER BY occurred_at DESC,id DESC),'[]'::jsonb) INTO v_result
    FROM (SELECT id,occurred_at FROM public.sl_transactions WHERE owner_id=v_owner
      ORDER BY occurred_at DESC,id DESC LIMIT 50) t;
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.sl_partner_id(uuid),public.sl_relationship_json(uuid),
  public.sl_get_relationship(text),public.sl_create_invitation(text,text,text,text,text),
  public.sl_bind_relationship(text,text,text,text),public.sl_account_visible_json(uuid,uuid),
  public.sl_get_account_visible(text,text),public.sl_list_accounts_visible(text,text),
  public.sl_transaction_visible_json(uuid,uuid),public.sl_get_transaction_visible(text,text),
  public.sl_list_transactions_visible(text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sl_partner_id(uuid),public.sl_relationship_json(uuid),
  public.sl_get_relationship(text),public.sl_create_invitation(text,text,text,text,text),
  public.sl_bind_relationship(text,text,text,text),public.sl_account_visible_json(uuid,uuid),
  public.sl_get_account_visible(text,text),public.sl_list_accounts_visible(text,text),
  public.sl_transaction_visible_json(uuid,uuid),public.sl_get_transaction_visible(text,text),
  public.sl_list_transactions_visible(text,text) TO service_role;
