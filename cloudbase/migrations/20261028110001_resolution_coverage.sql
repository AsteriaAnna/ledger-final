-- Recompute full-batch eligibility after explicit row decisions.
CREATE OR REPLACE FUNCTION public.sl_import_resolve(p_actor_subject text,p_batch text,p_key_digest text,p_payload_hash text,p_input jsonb) RETURNS jsonb
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
  END IF;
  PERFORM public.sl_process_import(p_actor_subject,v_id);
  v_result:=public.sl_import_json(p_actor_subject,v_id::text);
  INSERT INTO public.sl_requests(actor_id,method,path,key_digest,payload_hash,response_body) VALUES(v_actor,'POST','/api/v1/imports/'||v_id::text||'/resolutions',p_key_digest,p_payload_hash,v_result);
  RETURN v_result;
END $$;
