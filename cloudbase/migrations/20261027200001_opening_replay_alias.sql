-- Disambiguate the transaction table alias from the PL/pgSQL row variable.
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
        IF t.owner_id<>v_actor OR t.type<>'expense' OR t.accounting_semantics<>'ordinary' OR
          e.role<>'primary' OR e.signed_amount_minor<>-t.amount_minor THEN
          RAISE EXCEPTION 'sl_opening_recalculation_conflict'; END IF;
        PERFORM public.sl_record_expense_delta(v_id,v_actor,e.id,t.id,r.event_time,t.amount_minor,false);
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
