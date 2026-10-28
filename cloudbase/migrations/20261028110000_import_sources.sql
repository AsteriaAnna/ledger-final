-- M4 evidence and decisions remain separate from M3 facts and M2 movements.
CREATE TABLE public.sl_source_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), owner_id uuid NOT NULL REFERENCES public.sl_users,
  platform text NOT NULL CHECK(platform IN ('wechat','alipay')), label text NOT NULL CHECK(char_length(label) BETWEEN 1 AND 80),
  identity_hint text, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX sl_profiles_owner ON public.sl_source_profiles(owner_id,platform);
CREATE TABLE public.sl_source_mappings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), profile_id uuid NOT NULL REFERENCES public.sl_source_profiles,
  canonical_method_key text NOT NULL, account_id uuid NOT NULL REFERENCES public.sl_accounts,
  version bigint NOT NULL DEFAULT 1, UNIQUE(profile_id,canonical_method_key)
);
CREATE TABLE public.sl_import_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), owner_id uuid NOT NULL REFERENCES public.sl_users,
  platform text NOT NULL, profile_id uuid REFERENCES public.sl_source_profiles, profile_version bigint NOT NULL DEFAULT 0,
  file_hash text NOT NULL, identity_hint text, coverage jsonb NOT NULL, source_metadata jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX sl_batches_owner ON public.sl_import_batches(owner_id,created_at DESC,id);
CREATE TABLE public.sl_source_records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), profile_id uuid NOT NULL REFERENCES public.sl_source_profiles,
  official_transaction_id text NOT NULL, current_observation_id uuid, exported_at timestamptz,
  fact_hash text NOT NULL, accepted_hash text, decision jsonb, transaction_id uuid REFERENCES public.sl_transactions,
  version bigint NOT NULL DEFAULT 1, UNIQUE(profile_id,official_transaction_id)
);
CREATE INDEX sl_sources_transaction ON public.sl_source_records(transaction_id);
CREATE TABLE public.sl_source_observations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), batch_id uuid NOT NULL REFERENCES public.sl_import_batches,
  source_id uuid REFERENCES public.sl_source_records, row_number integer NOT NULL, official_transaction_id text NOT NULL,
  evidence jsonb NOT NULL, candidate jsonb NOT NULL, base_disposition text, base_reason text,
  fact_hash text NOT NULL, disposition text NOT NULL DEFAULT 'needs_review', phase text NOT NULL DEFAULT 'profile_resolution',
  reason_codes jsonb NOT NULL DEFAULT '[]', candidate_transaction_ids jsonb NOT NULL DEFAULT '[]',
  UNIQUE(batch_id,row_number)
);
CREATE INDEX sl_observations_source ON public.sl_source_observations(source_id,batch_id);
ALTER TABLE public.sl_source_records ADD CONSTRAINT sl_source_current_observation_fk
  FOREIGN KEY(current_observation_id) REFERENCES public.sl_source_observations;
CREATE TABLE public.sl_reconciliation_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), profile_id uuid NOT NULL REFERENCES public.sl_source_profiles,
  transaction_id uuid NOT NULL REFERENCES public.sl_transactions, first_batch_id uuid NOT NULL REFERENCES public.sl_import_batches,
  last_batch_id uuid NOT NULL REFERENCES public.sl_import_batches,
  status text NOT NULL DEFAULT 'pending_confirmation' CHECK(status IN ('pending_confirmation','kept_manual','matched_to_source')),
  version bigint NOT NULL DEFAULT 1, UNIQUE(profile_id,transaction_id)
);
ALTER TABLE public.sl_transactions ADD COLUMN source_account_profile_id uuid REFERENCES public.sl_source_profiles,
  ADD COLUMN refund_kind text, ADD COLUMN affects_spending boolean;
ALTER TABLE public.sl_transactions DROP CONSTRAINT sl_transactions_type_check;
ALTER TABLE public.sl_transactions ADD CONSTRAINT sl_transactions_type_check CHECK(type IN ('income','expense','transfer','refund'));
ALTER TABLE public.sl_transactions DROP CONSTRAINT sl_transactions_accounting_semantics_check;
ALTER TABLE public.sl_transactions ADD CONSTRAINT sl_transactions_accounting_semantics_check CHECK(
  (type IN ('income','expense') AND accounting_semantics='ordinary') OR
  (type='transfer' AND accounting_semantics='internal_transfer') OR (type='refund' AND accounting_semantics='refund_inflow'));
ALTER TABLE public.sl_transactions ADD CONSTRAINT sl_refund_fields CHECK(
  (type='refund' AND refund_kind IS NOT NULL AND refund_kind IN ('merchant_refund','transfer_return') AND affects_spending IS NOT NULL) OR
  (type<>'refund' AND refund_kind IS NULL AND affects_spending IS NULL));
DO $$ DECLARE n text; BEGIN
  FOREACH n IN ARRAY ARRAY['sl_source_profiles','sl_source_mappings','sl_import_batches','sl_source_records','sl_source_observations','sl_reconciliation_items'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',n);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,anon,authenticated,service_role',n);
  END LOOP;
END $$;

CREATE FUNCTION public.sl_profile_for_actor(p_subject text,p_profile text) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_id uuid; BEGIN
  IF p_profile IS NULL THEN RETURN NULL; END IF;
  BEGIN v_id:=p_profile::uuid; EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_invalid_input'; END;
  IF NOT EXISTS(SELECT 1 FROM public.sl_source_profiles p JOIN public.sl_users u ON u.id=p.owner_id
    WHERE p.id=v_id AND u.auth_subject=p_subject) THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.sl_apply_effect(p_type text,p_role text,p_account uuid,p_actor uuid,
  p_effect uuid,p_group uuid,p_time timestamptz,p_amount numeric) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_liquid numeric;
BEGIN
  IF p_role='primary' THEN
    IF p_type='refund' THEN
      PERFORM public.sl_record_expense_delta(p_account,p_actor,p_effect,p_group,p_time,p_amount,true);
      RETURN '[]'::jsonb;
    END IF;
    RETURN public.sl_apply_ordinary_funds(p_type,p_account,p_actor,p_effect,p_group,p_time,p_amount);
  END IF;
  IF p_type<>'transfer' OR p_role NOT IN ('from','to') OR p_amount IS NULL OR
    p_amount<=0 OR p_amount<>trunc(p_amount) OR p_amount>9007199254740991 THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  IF p_role='to' THEN PERFORM public.sl_record_income(p_account,p_actor,p_effect,p_group,p_time,p_amount);
  ELSE
    SELECT COALESCE(sum(current_minor),0) INTO v_liquid FROM public.sl_share_state(p_account)
      WHERE fund_owner_id=p_actor AND fund_type='liquid';
    IF v_liquid<p_amount THEN RAISE EXCEPTION 'sl_insufficient_funds'; END IF;
    INSERT INTO public.sl_movements(account_id,fund_owner_id,fund_type,signed_amount_minor,reason,operation_group,effect_id,effective_at)
      VALUES(p_account,p_actor,'liquid',-p_amount,'transaction',p_group,p_effect,p_time);
    PERFORM public.sl_assert_funds(p_account);
  END IF;
  RETURN '[]'::jsonb;
END $$;

CREATE FUNCTION public.sl_source_summaries(p_tx uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('source_record_id',s.id::text,'platform',p.platform,
    'source_occurred_at',o.candidate->'source_occurred_at') ORDER BY s.id),'[]'::jsonb)
    FROM public.sl_source_records s JOIN public.sl_source_profiles p ON p.id=s.profile_id
    JOIN public.sl_source_observations o ON o.id=s.current_observation_id WHERE s.transaction_id=p_tx;
$$;

CREATE OR REPLACE FUNCTION public.sl_create_transaction(p_actor_subject text,p_key_digest text,p_payload_hash text,p_input jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF p_input->>'type' NOT IN ('income','expense','transfer') THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  PERFORM public.sl_profile_for_actor(p_actor_subject,p_input->>'source_account_profile_id');
  RETURN public.sl_post_transaction(p_actor_subject,p_key_digest,p_payload_hash,p_input,false);
END $$;

CREATE OR REPLACE FUNCTION public.sl_patch_transaction(p_actor_subject text,p_transaction_id text,p_expected_version bigint,p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF p_patch ? 'source_account_profile_id' THEN PERFORM public.sl_profile_for_actor(p_actor_subject,p_patch->>'source_account_profile_id'); END IF;
  RETURN public.sl_patch_transaction_core(p_actor_subject,p_transaction_id,p_expected_version,p_patch);
END $$;

ALTER FUNCTION public.sl_delete_transaction(text,text,bigint) RENAME TO sl_delete_transaction_core;
CREATE FUNCTION public.sl_delete_transaction(p_actor_subject text,p_transaction_id text,p_expected_version bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_id uuid; v_owner uuid; BEGIN
  BEGIN v_id:=p_transaction_id::uuid; EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_transaction_not_found'; END;
  SELECT id INTO v_owner FROM public.sl_users WHERE auth_subject=p_actor_subject FOR UPDATE;
  IF NOT EXISTS(SELECT 1 FROM public.sl_transactions WHERE id=v_id AND owner_id=v_owner) THEN RAISE EXCEPTION 'sl_transaction_not_found'; END IF;
  UPDATE public.sl_source_records SET transaction_id=NULL,version=version+1 WHERE transaction_id=v_id;
  DELETE FROM public.sl_reconciliation_items WHERE transaction_id=v_id;
  RETURN public.sl_delete_transaction_core(p_actor_subject,p_transaction_id,p_expected_version);
END $$;

CREATE FUNCTION public.sl_mapping_json(p_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
  SELECT jsonb_build_object('id',id::text,'source_account_profile_id',profile_id::text,
    'canonical_method_key',canonical_method_key,'account_id',account_id::text,'version',version)
    FROM public.sl_source_mappings WHERE id=p_id;
$$;

CREATE FUNCTION public.sl_list_mappings(p_actor_subject text,p_profile text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_id uuid; v_result jsonb; BEGIN
  v_id:=public.sl_profile_for_actor(p_actor_subject,p_profile);
  IF v_id IS NULL THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  SELECT COALESCE(jsonb_agg(public.sl_mapping_json(id) ORDER BY canonical_method_key),'[]'::jsonb) INTO v_result
    FROM public.sl_source_mappings WHERE profile_id=v_id;
  RETURN v_result;
END $$;

CREATE FUNCTION public.sl_put_mapping(p_actor_subject text,p_input jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_actor uuid; v_profile uuid; v_account uuid; v_key text; m public.sl_source_mappings%ROWTYPE; v_version bigint;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  v_profile:=public.sl_profile_for_actor(p_actor_subject,p_input->>'source_account_profile_id');
  BEGIN v_account:=(p_input->>'account_id')::uuid; v_version:=(p_input->>'expected_version')::bigint;
  EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_invalid_input'; END;
  v_key:=p_input->>'canonical_method_key';
  IF v_profile IS NULL OR v_key IS NULL OR length(v_key)=0 OR v_version IS NULL OR v_version<0 THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.sl_accounts WHERE id=v_account AND holder_user_id=v_actor) THEN RAISE EXCEPTION 'sl_account_not_found'; END IF;
  -- Wallet mapping cannot attach one actual wallet to another source account.
  IF v_key IN ('微信零钱','支付宝余额') AND EXISTS(SELECT 1 FROM public.sl_source_mappings
    WHERE canonical_method_key=v_key AND account_id=v_account AND profile_id<>v_profile) THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  SELECT * INTO m FROM public.sl_source_mappings WHERE profile_id=v_profile AND canonical_method_key=v_key FOR UPDATE;
  IF FOUND THEN
    IF v_version<>m.version THEN RAISE EXCEPTION 'sl_resource_conflict'; END IF;
    IF m.account_id=v_account THEN RETURN public.sl_mapping_json(m.id); END IF;
    UPDATE public.sl_source_mappings SET account_id=v_account,version=version+1 WHERE id=m.id;
  ELSE
    IF v_version<>0 THEN RAISE EXCEPTION 'sl_resource_conflict'; END IF;
    INSERT INTO public.sl_source_mappings(profile_id,canonical_method_key,account_id) VALUES(v_profile,v_key,v_account) RETURNING * INTO m;
  END IF;
  RETURN public.sl_mapping_json(m.id);
END $$;

CREATE FUNCTION public.sl_attach_sources(p_batch uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE b public.sl_import_batches%ROWTYPE; o public.sl_source_observations%ROWTYPE; s public.sl_source_records%ROWTYPE; v_export timestamptz;
BEGIN
  SELECT * INTO b FROM public.sl_import_batches WHERE id=p_batch;
  IF b.profile_id IS NULL THEN RETURN; END IF;
  v_export:=(b.coverage->>'exported_at')::timestamptz;
  FOR o IN SELECT * FROM public.sl_source_observations WHERE batch_id=p_batch AND source_id IS NULL ORDER BY row_number LOOP
    IF o.official_transaction_id='' OR o.base_disposition='failed' THEN CONTINUE; END IF;
    SELECT * INTO s FROM public.sl_source_records WHERE profile_id=b.profile_id AND official_transaction_id=o.official_transaction_id FOR UPDATE;
    IF NOT FOUND THEN
      INSERT INTO public.sl_source_records(profile_id,official_transaction_id,current_observation_id,exported_at,fact_hash,accepted_hash)
        VALUES(b.profile_id,o.official_transaction_id,o.id,v_export,o.fact_hash,o.fact_hash) RETURNING * INTO s;
    ELSIF COALESCE(v_export,'-infinity'::timestamptz)>COALESCE(s.exported_at,'-infinity'::timestamptz) THEN
      UPDATE public.sl_source_records SET current_observation_id=o.id,exported_at=v_export,fact_hash=o.fact_hash,
        accepted_hash=CASE WHEN transaction_id IS NULL THEN o.fact_hash ELSE accepted_hash END,
        decision=CASE WHEN fact_hash<>o.fact_hash THEN NULL ELSE decision END,
        version=version+CASE WHEN fact_hash<>o.fact_hash THEN 1 ELSE 0 END WHERE id=s.id;
    END IF;
    UPDATE public.sl_source_observations SET source_id=s.id WHERE id=o.id;
  END LOOP;
END $$;

CREATE FUNCTION public.sl_process_import_row(p_subject text,p_observation uuid,p_force_new boolean DEFAULT false) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE o public.sl_source_observations%ROWTYPE; current_o public.sl_source_observations%ROWTYPE;
  s public.sl_source_records%ROWTYPE; b public.sl_import_batches%ROWTYPE; v_actor uuid; c jsonb; v_candidates jsonb;
  v_reason text; v_disposition text; v_phase text; v_result jsonb; v_tx uuid; v_input jsonb; v_error text;
BEGIN
  SELECT * INTO o FROM public.sl_source_observations WHERE id=p_observation FOR UPDATE;
  SELECT * INTO b FROM public.sl_import_batches WHERE id=o.batch_id;
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_subject;
  IF b.owner_id IS DISTINCT FROM v_actor THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  c:=o.candidate; v_candidates:='[]'::jsonb; v_phase:='normalization'; v_disposition:='needs_review';
  IF b.profile_id IS NULL THEN
    v_reason:='SOURCE_PROFILE_REQUIRED';v_phase:='profile_resolution';
    IF o.base_disposition IN ('failed','unsupported','ineffective') THEN v_disposition:=o.base_disposition;v_reason:=o.base_reason; END IF;
  ELSIF o.source_id IS NULL THEN v_disposition:='failed';v_reason:=COALESCE(o.base_reason,'INVALID_SOURCE_FIELDS');
  ELSE
    SELECT * INTO s FROM public.sl_source_records WHERE id=o.source_id FOR UPDATE;
    SELECT * INTO current_o FROM public.sl_source_observations WHERE id=s.current_observation_id;
    c:=current_o.candidate;
    IF s.current_observation_id<>o.id AND COALESCE((b.coverage->>'exported_at')::timestamptz,'-infinity'::timestamptz)=COALESCE(s.exported_at,'-infinity'::timestamptz) AND o.fact_hash<>s.fact_hash THEN
      v_reason:='SAME_EXPORT_CONFLICT';
    ELSIF s.transaction_id IS NOT NULL THEN
      IF s.accepted_hash IS DISTINCT FROM s.fact_hash THEN v_reason:='SOURCE_CHANGED';
      ELSE v_disposition:=CASE WHEN o.disposition IN ('created','linked_existing') THEN o.disposition ELSE 'duplicate_existing' END;v_phase:='posted'; END IF;
    ELSIF current_o.base_disposition IN ('failed','unsupported','ineffective') THEN
      v_disposition:=current_o.base_disposition;v_reason:=current_o.base_reason;
    ELSE
      v_reason:=current_o.base_reason;
      IF s.decision IS NOT NULL AND current_o.base_reason='TRANSFER_ROLE_REQUIRED' THEN
        c:=c||s.decision;v_reason:=NULL;
        c:=jsonb_set(c,'{accounting_semantics}',to_jsonb(CASE WHEN c->>'type'='transfer' THEN 'internal_transfer' ELSE 'ordinary' END));
      END IF;
      IF v_reason IS NULL THEN
        v_phase:='account_resolution';
        IF c->>'type'='transfer' THEN
          IF s.decision IS NULL THEN
            c:=jsonb_set(c,'{from_account_id}',COALESCE((SELECT to_jsonb(account_id::text) FROM public.sl_source_mappings WHERE profile_id=b.profile_id AND canonical_method_key=c->>'from_canonical_method_key'),'null'::jsonb));
            c:=jsonb_set(c,'{to_account_id}',COALESCE((SELECT to_jsonb(account_id::text) FROM public.sl_source_mappings WHERE profile_id=b.profile_id AND canonical_method_key=c->>'to_canonical_method_key'),'null'::jsonb));
          END IF;
          IF c->>'from_account_id' IS NULL OR c->>'to_account_id' IS NULL THEN v_reason:='ACCOUNT_MAPPING_REQUIRED'; END IF;
        ELSE
          IF s.decision IS NULL THEN c:=jsonb_set(c,'{account_id}',COALESCE((SELECT to_jsonb(account_id::text) FROM public.sl_source_mappings WHERE profile_id=b.profile_id AND canonical_method_key=c->>'canonical_method_key'),'null'::jsonb)); END IF;
          IF c->>'account_id' IS NULL THEN v_reason:='ACCOUNT_MAPPING_REQUIRED'; END IF;
        END IF;
      END IF;
      IF v_reason IS NULL THEN
        v_phase:='transaction_resolution';
        SELECT COALESCE(jsonb_agg(t.id::text ORDER BY t.id),'[]'::jsonb) INTO v_candidates FROM public.sl_transactions t
          WHERE t.owner_id=v_actor AND t.type=c->>'type' AND t.amount_minor=(c->>'amount_minor')::numeric AND
            (t.occurred_at AT TIME ZONE 'Asia/Shanghai')::date=((c->>'occurred_at')::timestamptz AT TIME ZONE 'Asia/Shanghai')::date AND
            (t.type<>'refund' OR t.refund_kind=c->>'refund_kind') AND
            ((t.type<>'transfer' AND EXISTS(SELECT 1 FROM public.sl_effects WHERE transaction_id=t.id AND account_id=(c->>'account_id')::uuid AND role='primary')) OR
             (t.type='transfer' AND EXISTS(SELECT 1 FROM public.sl_effects WHERE transaction_id=t.id AND account_id=(c->>'from_account_id')::uuid AND role='from') AND
               EXISTS(SELECT 1 FROM public.sl_effects WHERE transaction_id=t.id AND account_id=(c->>'to_account_id')::uuid AND role='to')));
        IF jsonb_array_length(v_candidates)>0 AND NOT p_force_new THEN v_reason:='SAME_EVENT_CONFIRMATION_REQUIRED';
        ELSE
          v_input:=jsonb_build_object('type',c->'type','amount_minor',c->'amount_minor','occurred_at',c->'occurred_at',
            'category_code',c->'category_code','merchant',c->'merchant','note',c->'note','source_account_profile_id',b.profile_id::text);
          IF c->>'type'='transfer' THEN v_input:=v_input||jsonb_build_object('from_account_id',c->'from_account_id','to_account_id',c->'to_account_id');
          ELSE v_input:=v_input||jsonb_build_object('account_id',c->'account_id'); END IF;
          IF c->>'type'='refund' THEN v_input:=v_input||jsonb_build_object('refund_kind',c->'refund_kind','affects_spending',c->'affects_spending'); END IF;
          BEGIN
            v_result:=public.sl_post_transaction(p_subject,repeat(md5('source:'||s.id::text||':'||s.version::text),2),repeat(md5(v_input::text),2),v_input,true);
            v_tx:=(v_result->'transaction'->>'id')::uuid;
            UPDATE public.sl_source_records SET transaction_id=v_tx,accepted_hash=fact_hash,version=version+1 WHERE id=s.id;
            v_disposition:='created';v_phase:='posted';
          EXCEPTION WHEN others THEN
            GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
            v_disposition:='failed';v_reason:=CASE WHEN v_error IN ('sl_insufficient_funds','sl_unsafe_reversal') THEN 'FUNDS_ALLOCATION_NOT_POSSIBLE' ELSE 'POSTING_FAILED' END;
          END;
        END IF;
      END IF;
    END IF;
  END IF;
  UPDATE public.sl_source_observations SET candidate=c,disposition=v_disposition,phase=v_phase,
    reason_codes=CASE WHEN v_reason IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(v_reason) END,
    candidate_transaction_ids=v_candidates WHERE id=o.id;
END $$;

CREATE FUNCTION public.sl_process_import(p_subject text,p_batch uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE b public.sl_import_batches%ROWTYPE; r record; v_eligible boolean; v_blockers jsonb;
BEGIN
  SELECT * INTO b FROM public.sl_import_batches WHERE id=p_batch;
  PERFORM public.sl_attach_sources(p_batch);
  FOR r IN SELECT id FROM public.sl_source_observations WHERE batch_id=p_batch
    ORDER BY (candidate->>'occurred_at')::timestamptz NULLS LAST,official_transaction_id,row_number LOOP
    PERFORM public.sl_process_import_row(p_subject,r.id);
  END LOOP;
  v_eligible:=(b.coverage->>'structural_complete')::boolean AND b.profile_id IS NOT NULL AND
    NOT EXISTS(SELECT 1 FROM public.sl_source_observations WHERE batch_id=p_batch AND disposition IN ('unsupported','needs_review','failed'));
  v_blockers:=CASE WHEN v_eligible THEN '[]'::jsonb ELSE
    COALESCE((SELECT jsonb_agg(DISTINCT code) FROM public.sl_source_observations o CROSS JOIN LATERAL jsonb_array_elements_text(o.reason_codes) code
      WHERE o.batch_id=p_batch AND o.disposition IN ('unsupported','needs_review','failed')),'[]'::jsonb)||
    CASE WHEN NOT (b.coverage->>'structural_complete')::boolean THEN '["INCOMPLETE_COVERAGE"]'::jsonb ELSE '[]'::jsonb END END;
  UPDATE public.sl_import_batches SET coverage=coverage||jsonb_build_object('reconciliation_eligible',v_eligible,'blockers',v_blockers) WHERE id=p_batch;
  IF v_eligible THEN
    INSERT INTO public.sl_reconciliation_items(profile_id,transaction_id,first_batch_id,last_batch_id)
      SELECT b.profile_id,t.id,p_batch,p_batch FROM public.sl_transactions t WHERE t.owner_id=b.owner_id
      AND t.occurred_at>=(b.coverage->>'effective_from')::timestamptz AND t.occurred_at<=(b.coverage->>'effective_to')::timestamptz
      AND NOT EXISTS(SELECT 1 FROM public.sl_source_records WHERE transaction_id=t.id)
      AND (t.source_account_profile_id=b.profile_id OR (t.source_account_profile_id IS NULL AND EXISTS(
        SELECT 1 FROM public.sl_effects e JOIN public.sl_source_mappings m ON m.account_id=e.account_id
        WHERE e.transaction_id=t.id AND m.profile_id=b.profile_id AND m.canonical_method_key IN ('微信零钱','支付宝余额'))))
      ON CONFLICT(profile_id,transaction_id) DO UPDATE SET last_batch_id=excluded.last_batch_id;
  END IF;
  UPDATE public.sl_reconciliation_items i SET status='matched_to_source',version=version+1
    WHERE i.profile_id=b.profile_id AND i.status<>'matched_to_source' AND EXISTS(SELECT 1 FROM public.sl_source_records s WHERE s.transaction_id=i.transaction_id);
END $$;

CREATE FUNCTION public.sl_import_json(p_subject text,p_batch text,p_limit integer DEFAULT 50,p_rows integer DEFAULT 0,p_reconciliation integer DEFAULT 0) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_actor uuid; v_id uuid; b public.sl_import_batches%ROWTYPE; v_rows jsonb; v_items jsonb; v_summary jsonb;
  v_profiles jsonb; v_profile jsonb; v_row_count integer; v_item_count integer;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_subject;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  BEGIN v_id:=p_batch::uuid; EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_account_not_found'; END;
  SELECT * INTO b FROM public.sl_import_batches WHERE id=v_id AND owner_id=v_actor;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_account_not_found'; END IF;
  IF p_limit NOT BETWEEN 1 AND 200 OR p_rows<0 OR p_reconciliation<0 THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  SELECT jsonb_build_object('id',id::text,'platform',platform,'label',label) INTO v_profile FROM public.sl_source_profiles WHERE id=b.profile_id;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id::text,'platform',platform,'label',label) ORDER BY created_at,id),'[]'::jsonb) INTO v_profiles
    FROM public.sl_source_profiles WHERE owner_id=v_actor AND platform=b.platform;
  SELECT count(*) INTO v_row_count FROM public.sl_source_observations WHERE batch_id=v_id;
  SELECT count(*) INTO v_item_count FROM public.sl_reconciliation_items WHERE first_batch_id=v_id OR last_batch_id=v_id;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('observation_id',o.id::text,'row_number',o.row_number,
    'source_record_id',o.source_id::text,'source_version',s.version,'phase',o.phase,'disposition',o.disposition,
    'reason_codes',o.reason_codes,'evidence',o.evidence,'candidate',o.candidate,'transaction_id',s.transaction_id::text,
    'candidate_transaction_ids',o.candidate_transaction_ids,'allowed_actions',
      CASE WHEN b.profile_id IS NULL THEN '["select_source_profile"]'::jsonb
      WHEN o.reason_codes ? 'TRANSFER_ROLE_REQUIRED' THEN '["set_transfer_role"]'::jsonb
      WHEN o.reason_codes ? 'SOURCE_CHANGED' OR o.reason_codes ? 'SAME_EXPORT_CONFLICT' THEN '["accept_source_change"]'::jsonb
      WHEN o.reason_codes ? 'SAME_EVENT_CONFIRMATION_REQUIRED' THEN '["create_transaction","link_existing_transaction"]'::jsonb
      WHEN o.disposition IN ('needs_review','failed') OR (o.phase='posted' AND s.transaction_id IS NULL) THEN '["resume"]'::jsonb ELSE '[]'::jsonb END
    ) ORDER BY o.row_number),'[]'::jsonb) INTO v_rows
    FROM (SELECT * FROM public.sl_source_observations WHERE batch_id=v_id ORDER BY row_number OFFSET p_rows LIMIT p_limit) o
    LEFT JOIN public.sl_source_records s ON s.id=o.source_id;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id::text,'transaction_id',transaction_id::text,
    'source_account_profile_id',profile_id::text,'status',status,'version',version,'reason_code','NO_SOURCE_MATCH_WITHIN_COVERAGE') ORDER BY id),'[]'::jsonb) INTO v_items
    FROM (SELECT * FROM public.sl_reconciliation_items WHERE first_batch_id=v_id OR last_batch_id=v_id ORDER BY id OFFSET p_reconciliation LIMIT p_limit) i;
  SELECT jsonb_build_object('read_rows',count(*),'created',count(*) FILTER(WHERE disposition='created'),
    'linked_existing',count(*) FILTER(WHERE disposition='linked_existing'),'duplicate_existing',count(*) FILTER(WHERE disposition='duplicate_existing'),
    'unsupported',count(*) FILTER(WHERE disposition='unsupported'),'ineffective',count(*) FILTER(WHERE disposition='ineffective'),
    'needs_review',count(*) FILTER(WHERE disposition='needs_review'),'failed',count(*) FILTER(WHERE disposition='failed'),
    'manual_transactions_not_found',v_item_count,'reconciliation_items_rechecked',
      (SELECT count(*) FROM public.sl_reconciliation_items WHERE last_batch_id=v_id AND first_batch_id<>v_id)) INTO v_summary
    FROM public.sl_source_observations WHERE batch_id=v_id;
  RETURN jsonb_build_object('data',jsonb_build_object('batch_id',b.id::text,'platform',b.platform,
    'status',CASE WHEN (v_summary->>'needs_review')::integer>0 OR (v_summary->>'failed')::integer>0 THEN 'needs_review' ELSE 'completed' END,
    'source_account_profile',v_profile,'profile_version',b.profile_version,'profile_candidates',v_profiles,
    'summary',v_summary,'coverage',b.coverage,'rows',v_rows,'reconciliation_items',v_items,'source_metadata',b.source_metadata),
    'page',jsonb_build_object('rows_next_cursor',CASE WHEN p_rows+p_limit<v_row_count THEN (p_rows+p_limit)::text END,
      'reconciliation_next_cursor',CASE WHEN p_reconciliation+p_limit<v_item_count THEN (p_reconciliation+p_limit)::text END));
END $$;

CREATE FUNCTION public.sl_import_upload(p_actor_subject text,p_key_digest text,p_payload_hash text,p_input jsonb,p_profile text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_actor uuid; v_profile uuid; v_batch uuid; prior public.sl_requests%ROWTYPE; v_result jsonb;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  SELECT * INTO prior FROM public.sl_requests WHERE actor_id=v_actor AND method='POST' AND path='/api/v1/imports' AND key_digest=p_key_digest;
  IF FOUND THEN IF prior.payload_hash<>p_payload_hash THEN RAISE EXCEPTION 'sl_idempotency_conflict'; END IF; RETURN prior.response_body; END IF;
  IF p_input->>'platform' NOT IN ('wechat','alipay') OR jsonb_array_length(p_input->'rows')>10000 THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  v_profile:=public.sl_profile_for_actor(p_actor_subject,p_profile);
  IF v_profile IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.sl_source_profiles WHERE id=v_profile AND platform=p_input->>'platform' AND
    (identity_hint IS NULL OR p_input->>'identity_hint' IS NULL OR identity_hint=p_input->>'identity_hint')) THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  IF v_profile IS NULL AND p_input->>'platform'='alipay' AND p_input->>'identity_hint' IS NOT NULL THEN
    SELECT id INTO v_profile FROM public.sl_source_profiles WHERE owner_id=v_actor AND platform='alipay' AND identity_hint=p_input->>'identity_hint';
  END IF;
  INSERT INTO public.sl_import_batches(owner_id,platform,profile_id,profile_version,file_hash,identity_hint,coverage,source_metadata)
    VALUES(v_actor,p_input->>'platform',v_profile,CASE WHEN v_profile IS NULL THEN 0 ELSE 1 END,p_input->>'file_hash',
      p_input->>'identity_hint',p_input->'coverage',p_input->'source_metadata') RETURNING id INTO v_batch;
  INSERT INTO public.sl_source_observations(batch_id,row_number,official_transaction_id,evidence,candidate,base_disposition,base_reason,fact_hash)
    SELECT v_batch,(x->>'row_number')::integer,x->>'official_transaction_id',x->'evidence',x->'candidate',x->>'base_disposition',x->>'base_reason',x->>'fact_hash'
      FROM jsonb_array_elements(p_input->'rows') x;
  PERFORM public.sl_process_import(p_actor_subject,v_batch);
  v_result:=public.sl_import_json(p_actor_subject,v_batch::text);
  INSERT INTO public.sl_requests(actor_id,method,path,key_digest,payload_hash,response_body) VALUES(v_actor,'POST','/api/v1/imports',p_key_digest,p_payload_hash,v_result);
  RETURN v_result;
END $$;

CREATE FUNCTION public.sl_import_resolve(p_actor_subject text,p_batch text,p_key_digest text,p_payload_hash text,p_input jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_actor uuid; v_id uuid; b public.sl_import_batches%ROWTYPE; o public.sl_source_observations%ROWTYPE; s public.sl_source_records%ROWTYPE;
  prior public.sl_requests%ROWTYPE; v_action text; v_result jsonb; v_profile uuid; v_tx uuid; v_decision jsonb; v_known uuid; v_account uuid;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  BEGIN v_id:=p_batch::uuid; EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_account_not_found'; END;
  SELECT * INTO b FROM public.sl_import_batches WHERE id=v_id AND owner_id=v_actor FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_account_not_found'; END IF;
  SELECT * INTO prior FROM public.sl_requests WHERE actor_id=v_actor AND method='POST' AND path='/api/v1/imports/'||v_id::text||'/resolutions' AND key_digest=p_key_digest;
  IF FOUND THEN IF prior.payload_hash<>p_payload_hash THEN RAISE EXCEPTION 'sl_idempotency_conflict'; END IF; RETURN prior.response_body; END IF;
  v_action:=p_input->>'action';
  IF v_action='select_source_profile' THEN
    IF (p_input->>'profile_version')::bigint<>b.profile_version THEN RAISE EXCEPTION 'sl_resource_conflict'; END IF;
    IF b.profile_id IS NOT NULL THEN RAISE EXCEPTION 'sl_resource_conflict'; END IF;
    IF p_input ? 'profile_id' THEN
      v_profile:=public.sl_profile_for_actor(p_actor_subject,p_input->>'profile_id');
      IF NOT EXISTS(SELECT 1 FROM public.sl_source_profiles WHERE id=v_profile AND platform=b.platform AND
        (identity_hint IS NULL OR b.identity_hint IS NULL OR identity_hint=b.identity_hint)) THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
    ELSE
      IF b.identity_hint IS NOT NULL AND EXISTS(SELECT 1 FROM public.sl_source_profiles WHERE owner_id=v_actor AND platform=b.platform AND identity_hint=b.identity_hint) THEN RAISE EXCEPTION 'sl_resource_conflict'; END IF;
      INSERT INTO public.sl_source_profiles(owner_id,platform,label,identity_hint) VALUES(v_actor,b.platform,p_input->>'create_label',b.identity_hint) RETURNING id INTO v_profile;
    END IF;
    UPDATE public.sl_import_batches SET profile_id=v_profile,profile_version=profile_version+1 WHERE id=v_id;
  ELSIF v_action='resume' THEN NULL;
  ELSE
    BEGIN SELECT * INTO o FROM public.sl_source_observations WHERE id=(p_input->>'observation_id')::uuid AND batch_id=v_id FOR UPDATE;
    EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_invalid_input'; END;
    IF o.id IS NULL OR o.source_id IS NULL THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
    SELECT * INTO s FROM public.sl_source_records WHERE id=o.source_id FOR UPDATE;
    IF s.version<>(p_input->>'expected_source_version')::bigint THEN RAISE EXCEPTION 'sl_resource_conflict'; END IF;
    IF COALESCE((b.coverage->>'exported_at')::timestamptz,'-infinity'::timestamptz)<COALESCE(s.exported_at,'-infinity'::timestamptz) THEN RAISE EXCEPTION 'sl_resource_conflict'; END IF;
    IF v_action='accept_source_change' THEN
      IF NOT (o.reason_codes ? 'SOURCE_CHANGED' OR o.reason_codes ? 'SAME_EXPORT_CONFLICT') THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
      UPDATE public.sl_source_records SET current_observation_id=o.id,exported_at=(b.coverage->>'exported_at')::timestamptz,
        fact_hash=o.fact_hash,accepted_hash=o.fact_hash,version=version+1,decision=NULL WHERE id=s.id;
    ELSIF v_action='set_transfer_role' THEN
      IF o.base_reason<>'TRANSFER_ROLE_REQUIRED' OR o.base_disposition IS DISTINCT FROM 'needs_review' OR s.transaction_id IS NOT NULL OR
        p_input->>'type' NOT IN ('income','expense','transfer') THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
      IF p_input->>'type'<>'transfer' AND p_input->>'type' IS DISTINCT FROM (CASE WHEN o.evidence->>'source_direction'='收入' THEN 'income' WHEN o.evidence->>'source_direction'='支出' THEN 'expense' END) THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
      v_decision:=p_input-'action'-'observation_id'-'expected_source_version';
      FOR v_account IN SELECT (value #>> '{}')::uuid FROM jsonb_each(v_decision) WHERE key IN ('account_id','from_account_id','to_account_id') LOOP
        IF NOT EXISTS(SELECT 1 FROM public.sl_accounts WHERE id=v_account AND holder_user_id=v_actor) THEN RAISE EXCEPTION 'sl_account_not_found'; END IF;
      END LOOP;
      IF p_input->>'type'='transfer' AND p_input->>'from_account_id'=p_input->>'to_account_id' THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
      IF o.candidate->>'canonical_method_key' IS NOT NULL THEN
        SELECT account_id INTO v_known FROM public.sl_source_mappings WHERE profile_id=b.profile_id AND canonical_method_key=o.candidate->>'canonical_method_key';
        IF v_known IS NULL OR v_known::text IS DISTINCT FROM (CASE WHEN p_input->>'type'='transfer' THEN
          CASE WHEN o.evidence->>'source_direction'='收入' THEN p_input->>'to_account_id' ELSE p_input->>'from_account_id' END ELSE p_input->>'account_id' END) THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
      END IF;
      UPDATE public.sl_source_records SET decision=v_decision,version=version+1 WHERE id=s.id;
    ELSIF v_action IN ('create_transaction','link_existing_transaction') THEN
      IF o.disposition<>'needs_review' OR NOT o.reason_codes ? 'SAME_EVENT_CONFIRMATION_REQUIRED' OR s.transaction_id IS NOT NULL THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
      IF v_action='create_transaction' THEN PERFORM public.sl_process_import_row(p_actor_subject,o.id,true);
      ELSE
        v_tx:=(p_input->>'transaction_id')::uuid;
        IF NOT o.candidate_transaction_ids ? v_tx::text OR NOT EXISTS(SELECT 1 FROM public.sl_transactions WHERE id=v_tx AND owner_id=v_actor) THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
        UPDATE public.sl_source_records SET transaction_id=v_tx,accepted_hash=fact_hash,version=version+1 WHERE id=s.id;
        UPDATE public.sl_source_observations SET disposition='linked_existing',phase='posted',reason_codes='[]' WHERE id=o.id;
      END IF;
    ELSE RAISE EXCEPTION 'sl_invalid_input'; END IF;
  END IF;
  -- Explicit link/create should keep their operation outcome in this response.
  IF v_action IN ('link_existing_transaction','create_transaction') THEN
    UPDATE public.sl_reconciliation_items SET status='matched_to_source',version=version+1 WHERE transaction_id IN(SELECT transaction_id FROM public.sl_source_records WHERE id=o.source_id) AND status<>'matched_to_source';
  ELSE PERFORM public.sl_process_import(p_actor_subject,v_id); END IF;
  v_result:=public.sl_import_json(p_actor_subject,v_id::text);
  INSERT INTO public.sl_requests(actor_id,method,path,key_digest,payload_hash,response_body) VALUES(v_actor,'POST','/api/v1/imports/'||v_id::text||'/resolutions',p_key_digest,p_payload_hash,v_result);
  RETURN v_result;
END $$;

CREATE FUNCTION public.sl_review_reconciliation(p_actor_subject text,p_batch text,p_key_digest text,p_payload_hash text,p_input jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_actor uuid; v_id uuid; item public.sl_reconciliation_items%ROWTYPE; prior public.sl_requests%ROWTYPE;
  v_result jsonb; v_delete jsonb; v_tx_version bigint;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  BEGIN v_id:=p_batch::uuid; EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'sl_account_not_found'; END;
  IF NOT EXISTS(SELECT 1 FROM public.sl_import_batches WHERE id=v_id AND owner_id=v_actor) THEN RAISE EXCEPTION 'sl_account_not_found'; END IF;
  SELECT * INTO prior FROM public.sl_requests WHERE actor_id=v_actor AND method='POST' AND path='/api/v1/imports/'||v_id::text||'/reconciliation-reviews' AND key_digest=p_key_digest;
  IF FOUND THEN IF prior.payload_hash<>p_payload_hash THEN RAISE EXCEPTION 'sl_idempotency_conflict'; END IF; RETURN prior.response_body; END IF;
  SELECT * INTO item FROM public.sl_reconciliation_items WHERE id=(p_input->>'reconciliation_item_id')::uuid AND (first_batch_id=v_id OR last_batch_id=v_id) FOR UPDATE;
  IF NOT FOUND OR NOT EXISTS(SELECT 1 FROM public.sl_source_profiles WHERE id=item.profile_id AND owner_id=v_actor) THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  IF item.version<>(p_input->>'expected_version')::bigint THEN RAISE EXCEPTION 'sl_resource_conflict'; END IF;
  IF item.status='matched_to_source' OR EXISTS(SELECT 1 FROM public.sl_source_records WHERE transaction_id=item.transaction_id) THEN RAISE EXCEPTION 'sl_resource_conflict'; END IF;
  IF p_input->>'action'='keep_manual' THEN
    IF item.status<>'kept_manual' THEN UPDATE public.sl_reconciliation_items SET status='kept_manual',version=version+1 WHERE id=item.id RETURNING * INTO item; END IF;
    v_result:=jsonb_build_object('reconciliation_item_id',item.id::text,'status','kept_manual','transaction_id',item.transaction_id::text,'account_changes','[]'::jsonb,'affected_months','[]'::jsonb,'version',item.version);
  ELSIF p_input->>'action'='delete_manual_transaction' THEN
    SELECT version INTO v_tx_version FROM public.sl_transactions WHERE id=item.transaction_id AND owner_id=v_actor;
    IF NOT FOUND THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
    v_delete:=public.sl_delete_transaction(p_actor_subject,item.transaction_id::text,v_tx_version);
    v_result:=jsonb_build_object('reconciliation_item_id',item.id::text,'status','deleted','transaction_id',item.transaction_id::text,
      'account_changes',v_delete->'account_changes','affected_months',v_delete->'affected_months','version',NULL);
  ELSE RAISE EXCEPTION 'sl_invalid_input'; END IF;
  INSERT INTO public.sl_requests(actor_id,method,path,key_digest,payload_hash,response_body) VALUES(v_actor,'POST','/api/v1/imports/'||v_id::text||'/reconciliation-reviews',p_key_digest,p_payload_hash,v_result);
  RETURN v_result;
END $$;


CREATE OR REPLACE FUNCTION public.sl_install_effects(p_tx uuid,p_actor uuid,p_type text,p_primary uuid,
  p_from uuid,p_to uuid,p_amount numeric,p_time timestamptz,p_order bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r record; v_id uuid; v_status text; v_order bigint;
  v_notices jsonb:='[]'::jsonb;
BEGIN
  v_order:=COALESCE(p_order,nextval('public.sl_replay_order_seq'::regclass));
  FOR r IN SELECT 'primary'::text AS role,p_primary AS account_id,
      CASE WHEN p_type IN ('income','refund') THEN p_amount ELSE -p_amount END AS signed WHERE p_type<>'transfer'
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
    'source_account_profile_id',v_tx.source_account_profile_id::text,'source_summaries',public.sl_source_summaries(v_tx.id),'version',v_tx.version,'read_only',false);
  IF v_tx.type='refund' THEN v_result:=v_result||jsonb_build_object('refund_kind',v_tx.refund_kind,'affects_spending',v_tx.affects_spending); END IF;
  IF v_tx.type='transfer' THEN
    RETURN v_result||jsonb_build_object('from_account_id',v_from::text,'to_account_id',v_to::text);
  END IF;
  RETURN v_result||jsonb_build_object('account_id',v_primary::text);
END;
$$;

CREATE FUNCTION public.sl_post_transaction(p_actor_subject text,p_key_digest text,
  p_payload_hash text,p_input jsonb,p_official boolean) RETURNS jsonb
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
  IF v_type IS NULL OR v_type NOT IN ('income','expense','transfer','refund') OR (v_type='refund' AND NOT p_official) OR
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
  IF v_type='refund' THEN
    IF p_input->>'refund_kind' NOT IN ('merchant_refund','transfer_return') OR p_input->>'refund_kind' IS NULL OR
      jsonb_typeof(p_input->'affects_spending') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  ELSIF p_input ? 'refund_kind' OR p_input ? 'affects_spending' THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  INSERT INTO public.sl_transactions(owner_id,type,accounting_semantics,amount_minor,occurred_at,category_code,merchant,note,
    source_account_profile_id,refund_kind,affects_spending)
    VALUES(v_actor,v_type,CASE WHEN v_type='transfer' THEN 'internal_transfer' WHEN v_type='refund' THEN 'refund_inflow' ELSE 'ordinary' END,
      v_amount,v_time,p_input->>'category_code',p_input->>'merchant',p_input->>'note',
      (p_input->>'source_account_profile_id')::uuid,p_input->>'refund_kind',(p_input->>'affects_spending')::boolean) RETURNING id INTO v_tx;
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

CREATE FUNCTION public.sl_patch_transaction_core(p_actor_subject text,p_transaction_id text,
  p_expected_version bigint,p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_id uuid; v_tx public.sl_transactions%ROWTYPE; e public.sl_effects%ROWTYPE;
  v_primary uuid; v_from uuid; v_to uuid; v_old_primary uuid; v_old_from uuid; v_old_to uuid;
  v_profile uuid; v_affects boolean; v_type text; v_amount numeric; v_time timestamptz; v_category text; v_merchant text; v_note text;
  v_accounts uuid[]; v_changed uuid[]:=ARRAY[]::uuid[]; v_order bigint; v_status text;
  v_rebuild boolean; v_notices jsonb:='[]'::jsonb; v_months jsonb;
BEGIN
  SELECT id INTO v_actor FROM public.sl_users WHERE auth_subject=p_actor_subject FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned'; END IF;
  IF p_expected_version IS NULL OR p_expected_version<1 OR coalesce(jsonb_typeof(p_patch),'null')<>'object' OR
    EXISTS(SELECT 1 FROM jsonb_object_keys(p_patch) AS k(name) WHERE name NOT IN
      ('type','amount_minor','occurred_at','account_id','from_account_id','to_account_id','category_code','merchant','note','source_account_profile_id','affects_spending')) THEN
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
  IF v_type IS NULL OR v_type NOT IN ('income','expense','transfer','refund') OR ((v_tx.type='refund')<>(v_type='refund')) THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
  BEGIN
    v_profile:=CASE WHEN p_patch ? 'source_account_profile_id' THEN (p_patch->>'source_account_profile_id')::uuid ELSE v_tx.source_account_profile_id END;
    IF p_patch ? 'affects_spending' AND (v_tx.type<>'refund' OR jsonb_typeof(p_patch->'affects_spending') IS DISTINCT FROM 'boolean') THEN RAISE EXCEPTION 'sl_invalid_input'; END IF;
    v_affects:=CASE WHEN p_patch ? 'affects_spending' THEN (p_patch->>'affects_spending')::boolean ELSE v_tx.affects_spending END;
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
  IF (v_type,v_amount,v_time,v_primary,v_from,v_to,v_category,v_merchant,v_note,v_profile,v_affects) IS NOT DISTINCT FROM
    (v_tx.type,v_tx.amount_minor,v_tx.occurred_at,v_old_primary,v_old_from,v_old_to,v_tx.category_code,v_tx.merchant,v_tx.note,v_tx.source_account_profile_id,v_tx.affects_spending) THEN
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
        signed_amount_minor=CASE WHEN v_type IN ('income','refund') OR e.role='to' THEN v_amount ELSE -v_amount END WHERE id=e.id;
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
    accounting_semantics=CASE WHEN v_type='transfer' THEN 'internal_transfer' WHEN v_type='refund' THEN 'refund_inflow' ELSE 'ordinary' END,
    amount_minor=v_amount,occurred_at=v_time,category_code=v_category,merchant=v_merchant,note=v_note,source_account_profile_id=v_profile,affects_spending=v_affects,version=version+1 WHERE id=v_id;
  UPDATE public.sl_accounts SET version=version+1,funds_revision=funds_revision+1 WHERE id=ANY(v_changed);
  SELECT jsonb_agg(x ORDER BY x) INTO v_months FROM (SELECT DISTINCT
    to_char(x AT TIME ZONE 'Asia/Shanghai','YYYY-MM') AS x FROM unnest(ARRAY[v_tx.occurred_at,v_time]) x) m;
  RETURN jsonb_build_object('transaction',public.sl_transaction_json(v_id),'account_effects',public.sl_effects_json(v_id),
    'account_changes',public.sl_account_changes(v_changed),'affected_months',v_months,'notices',v_notices);
END;
$$;

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
        IF t.owner_id<>v_actor OR t.type NOT IN ('income','expense','transfer','refund') OR
          (t.type='transfer' AND (t.accounting_semantics<>'internal_transfer' OR e.role NOT IN ('from','to'))) OR
          (t.type IN ('income','expense') AND (t.accounting_semantics<>'ordinary' OR e.role<>'primary')) OR
          (t.type='refund' AND (t.accounting_semantics<>'refund_inflow' OR e.role<>'primary')) OR
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

-- Service credentials can invoke application entry points, never private plans
-- or privileged official-source creation directly.
DO $$ DECLARE f record; BEGIN
  FOR f IN SELECT p.oid::regprocedure AS signature,p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname LIKE 'sl_%' LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated,service_role',f.signature);
    IF f.proname=ANY(ARRAY['sl_provision_user','sl_get_relationship','sl_create_invitation','sl_bind_relationship',
      'sl_get_account_visible','sl_list_accounts_visible','sl_create_account','sl_patch_account','sl_put_opening_state','sl_adjust_funds',
      'sl_list_transactions_visible','sl_get_transaction_visible','sl_create_transaction','sl_patch_transaction','sl_delete_transaction',
      'sl_import_upload','sl_import_json','sl_import_resolve','sl_list_mappings','sl_put_mapping','sl_review_reconciliation']) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role',f.signature);
    END IF;
  END LOOP;
END $$;
