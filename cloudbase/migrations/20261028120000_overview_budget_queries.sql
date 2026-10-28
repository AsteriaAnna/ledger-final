CREATE TABLE public.sl_monthly_budgets (
  owner_id uuid NOT NULL REFERENCES public.sl_users,month date NOT NULL CHECK(extract(day FROM month)=1),
  budget_minor numeric(20,0) NOT NULL CHECK(budget_minor BETWEEN 0 AND 9007199254740991),
  version bigint NOT NULL DEFAULT 1,PRIMARY KEY(owner_id,month)
);
ALTER TABLE public.sl_monthly_budgets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sl_monthly_budgets FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.sl_month(p_month text) RETURNS date
LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
BEGIN
  IF p_month IS NULL OR p_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' OR substring(p_month,1,4)='0000' THEN RAISE EXCEPTION 'sl_invalid_input';END IF;
  RETURN (p_month||'-01')::date;
END $$;
CREATE FUNCTION public.sl_get_budget(p_actor_subject text,p_month text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_date date;v_result jsonb;BEGIN
  v_date:=public.sl_month(p_month);
  SELECT jsonb_build_object('month',p_month,'budget_minor',b.budget_minor,'version',b.version) INTO v_result
    FROM public.sl_monthly_budgets b JOIN public.sl_users u ON u.id=b.owner_id WHERE u.auth_subject=p_actor_subject AND b.month=v_date;
  RETURN v_result;
END $$;
CREATE FUNCTION public.sl_put_budget(p_actor_subject text,p_month text,p_input jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;d date;n numeric;v bigint;b public.sl_monthly_budgets%ROWTYPE;BEGIN
  SELECT id INTO u FROM public.sl_users WHERE auth_subject=p_actor_subject FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned';END IF;
  d:=public.sl_month(p_month);n:=(p_input->>'budget_minor')::numeric;v:=(p_input->>'expected_version')::bigint;
  IF n IS NULL OR n<0 OR n>9007199254740991 OR n<>trunc(n) OR v IS NULL OR v<0 THEN RAISE EXCEPTION 'sl_invalid_input';END IF;
  SELECT * INTO b FROM public.sl_monthly_budgets WHERE owner_id=u AND month=d FOR UPDATE;
  IF FOUND THEN
    IF b.version<>v THEN RAISE EXCEPTION 'sl_resource_conflict';END IF;
    IF b.budget_minor<>n THEN UPDATE public.sl_monthly_budgets SET budget_minor=n,version=version+1 WHERE owner_id=u AND month=d;END IF;
  ELSE
    IF v<>0 THEN RAISE EXCEPTION 'sl_resource_conflict';END IF;
    INSERT INTO public.sl_monthly_budgets(owner_id,month,budget_minor) VALUES(u,d,n);
  END IF;
  RETURN public.sl_get_budget(p_actor_subject,p_month);
END $$;

CREATE FUNCTION public.sl_overview_at(p_actor_subject text,p_month text,p_today date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;partner uuid;d date;last_day date;previous_date date;as_of date;days numeric;month_days numeric;previous_days numeric;
  my_liquid numeric;my_savings numeric;partner_liquid numeric;partner_savings numeric;total numeric;
  expense numeric;offset_refund numeric;spent numeric;previous_spent numeric;daily numeric;previous_daily numeric;projected numeric;
  budget numeric;budget_view jsonb;
BEGIN
  d:=public.sl_month(p_month);
  IF d>date_trunc('month',p_today)::date THEN RAISE EXCEPTION 'sl_invalid_input';END IF;
  last_day:=(d+interval '1 month - 1 day')::date;as_of:=least(last_day,p_today);
  previous_date:=(d-interval '1 month')::date;month_days:=extract(day FROM last_day);
  days:=as_of-d+1;previous_days:=d-previous_date;
  SELECT id INTO u FROM public.sl_users WHERE auth_subject=p_actor_subject;
  partner:=public.sl_partner_id(u);
  SELECT COALESCE(sum(m.signed_amount_minor) FILTER(WHERE m.fund_owner_id=u AND m.fund_type='liquid'),0),
    COALESCE(sum(m.signed_amount_minor) FILTER(WHERE m.fund_owner_id=u AND m.fund_type='savings'),0),
    COALESCE(sum(m.signed_amount_minor) FILTER(WHERE m.fund_owner_id=partner AND m.fund_type='liquid'),0),
    COALESCE(sum(m.signed_amount_minor) FILTER(WHERE m.fund_owner_id=partner AND m.fund_type='savings'),0)
    INTO my_liquid,my_savings,partner_liquid,partner_savings FROM public.sl_movements m JOIN public.sl_accounts a ON a.id=m.account_id
    WHERE a.holder_user_id=u OR a.holder_user_id=partner;
  total:=my_liquid+my_savings+partner_liquid+partner_savings;
  SELECT COALESCE(sum(amount_minor) FILTER(WHERE type='expense'),0),
    COALESCE(sum(amount_minor) FILTER(WHERE type='refund' AND affects_spending),0) INTO expense,offset_refund
    FROM public.sl_transactions WHERE owner_id=u AND occurred_at >= d::timestamp AT TIME ZONE 'Asia/Shanghai' AND occurred_at < (as_of+1)::timestamp AT TIME ZONE 'Asia/Shanghai';
  spent:=expense-offset_refund;
  SELECT COALESCE(sum(CASE WHEN type='expense' THEN amount_minor WHEN type='refund' AND affects_spending THEN -amount_minor ELSE 0 END),0)
    INTO previous_spent FROM public.sl_transactions WHERE owner_id=u AND occurred_at>=previous_date::timestamp AT TIME ZONE 'Asia/Shanghai'
    AND occurred_at<d::timestamp AT TIME ZONE 'Asia/Shanghai';
  daily:=spent/days;previous_daily:=previous_spent/previous_days;
  projected:=CASE WHEN as_of=p_today AND d=date_trunc('month',p_today)::date THEN round(daily*month_days) ELSE spent END;
  SELECT budget_minor INTO budget FROM public.sl_monthly_budgets WHERE owner_id=u AND month=d;
  IF budget IS NOT NULL THEN budget_view:=jsonb_build_object('budget_minor',budget,'spent_minor',spent,
    'remaining_minor',greatest(budget-spent,0),'over_budget_minor',greatest(spent-budget,0),
    'status',CASE WHEN spent>budget THEN 'over_budget' ELSE 'within_budget' END);END IF;
  -- Never round an unsafe aggregate into a different number at the JSON boundary.
  IF total>9007199254740991 OR abs(expense)>9007199254740991 OR abs(offset_refund)>9007199254740991 OR
    abs(spent)>9007199254740991 OR abs(previous_spent)>9007199254740991 OR abs(projected)>9007199254740991 OR
    (budget IS NOT NULL AND budget-spent>9007199254740991) THEN RAISE EXCEPTION 'sl_invalid_input';END IF;
  RETURN jsonb_build_object('month',p_month,'as_of_date',as_of::text,'relationship_status',CASE WHEN partner IS NULL THEN 'unbound' ELSE 'bound' END,
    'funds',jsonb_build_object('my_liquid_minor',my_liquid,'my_savings_minor',my_savings,
      'partner_liquid_minor',CASE WHEN partner IS NOT NULL THEN partner_liquid END,
      'partner_savings_minor',CASE WHEN partner IS NOT NULL THEN partner_savings END,'visible_total_minor',total),
    'personal_spending',jsonb_build_object('expense_minor',expense,'refund_offset_minor',offset_refund,'month_spent_minor',spent,
      'daily_average_minor',round(daily),'previous_month_daily_average_minor',round(previous_daily),
      'daily_change_minor',round(daily-previous_daily),'daily_change_rate',CASE WHEN previous_daily<>0 THEN round((daily-previous_daily)/previous_daily,4) END,
      'projected_month_spending_minor',projected),'budget',budget_view);
END $$;
CREATE FUNCTION public.sl_get_overview(p_actor_subject text,p_month text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
  SELECT public.sl_overview_at(p_actor_subject,p_month,(now() AT TIME ZONE 'Asia/Shanghai')::date);
$$;

CREATE FUNCTION public.sl_accounts_page(p_actor_subject text,p_view text,p_limit integer,p_after_time timestamptz DEFAULT NULL,p_after_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;v_owner uuid;items jsonb;next_item jsonb;BEGIN
  SELECT id INTO u FROM public.sl_users WHERE auth_subject=p_actor_subject;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned';END IF;
  IF p_limit NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'sl_invalid_input';END IF;
  IF p_view='mine' THEN v_owner:=u;ELSIF p_view='partner' THEN v_owner:=public.sl_partner_id(u);
    IF v_owner IS NULL THEN RAISE EXCEPTION 'sl_partner_unavailable';END IF;
  ELSE RAISE EXCEPTION 'sl_invalid_input';END IF;
  WITH page AS(SELECT id,created_at FROM public.sl_accounts WHERE holder_user_id=v_owner AND
    (p_after_time IS NULL OR (created_at,id)<(p_after_time,p_after_id)) ORDER BY created_at DESC,id DESC LIMIT p_limit+1),
    visible AS(SELECT * FROM page ORDER BY created_at DESC,id DESC LIMIT p_limit)
    SELECT COALESCE((SELECT jsonb_agg(public.sl_account_visible_json(id,u) ORDER BY created_at DESC,id DESC) FROM visible),'[]'::jsonb),
      CASE WHEN (SELECT count(*) FROM page)>p_limit THEN (SELECT jsonb_build_object('time',created_at,'id',id::text) FROM visible ORDER BY created_at,id LIMIT 1) END
      INTO items,next_item;
  RETURN jsonb_build_object('data',items,'next',next_item);
END $$;

CREATE FUNCTION public.sl_transactions_page(p_actor_subject text,p_view text,p_limit integer,p_filters jsonb,
  p_after_time timestamptz DEFAULT NULL,p_after_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;v_owner uuid;items jsonb;next_item jsonb;BEGIN
  SELECT id INTO u FROM public.sl_users WHERE auth_subject=p_actor_subject;
  IF NOT FOUND THEN RAISE EXCEPTION 'sl_user_not_provisioned';END IF;
  IF p_limit NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'sl_invalid_input';END IF;
  IF p_view='mine' THEN v_owner:=u;ELSIF p_view='partner' THEN v_owner:=public.sl_partner_id(u);
    IF v_owner IS NULL THEN RAISE EXCEPTION 'sl_partner_unavailable';END IF;
  ELSE RAISE EXCEPTION 'sl_invalid_input';END IF;
  WITH page AS(SELECT t.id,t.occurred_at FROM public.sl_transactions t WHERE t.owner_id=v_owner
    AND (p_after_time IS NULL OR (t.occurred_at,t.id)<(p_after_time,p_after_id))
    AND (p_filters->>'from' IS NULL OR t.occurred_at>=((p_filters->>'from')::date)::timestamp AT TIME ZONE 'Asia/Shanghai')
    AND (p_filters->>'to' IS NULL OR t.occurred_at<((p_filters->>'to')::date+1)::timestamp AT TIME ZONE 'Asia/Shanghai')
    AND (p_filters->>'type' IS NULL OR t.type=p_filters->>'type')
    AND (p_filters->>'category_code' IS NULL OR t.category_code=p_filters->>'category_code')
    AND (p_filters->>'q' IS NULL OR strpos(lower(t.merchant||' '||t.note),lower(p_filters->>'q'))>0)
    AND (p_filters->>'account_id' IS NULL OR EXISTS(SELECT 1 FROM public.sl_effects e WHERE e.transaction_id=t.id AND e.account_id::text=p_filters->>'account_id'))
    ORDER BY t.occurred_at DESC,t.id DESC LIMIT p_limit+1),
    visible AS(SELECT * FROM page ORDER BY occurred_at DESC,id DESC LIMIT p_limit)
    SELECT COALESCE((SELECT jsonb_agg(public.sl_transaction_visible_json(id,u) ORDER BY occurred_at DESC,id DESC) FROM visible),'[]'::jsonb),
      CASE WHEN (SELECT count(*) FROM page)>p_limit THEN (SELECT jsonb_build_object('time',occurred_at,'id',id::text) FROM visible ORDER BY occurred_at,id LIMIT 1) END
      INTO items,next_item;
  RETURN jsonb_build_object('data',items,'next',next_item);
END $$;
REVOKE ALL ON FUNCTION public.sl_month(text),public.sl_get_budget(text,text),public.sl_put_budget(text,text,jsonb),
  public.sl_overview_at(text,text,date),public.sl_get_overview(text,text),public.sl_accounts_page(text,text,integer,timestamptz,uuid),
  public.sl_transactions_page(text,text,integer,jsonb,timestamptz,uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.sl_get_budget(text,text),public.sl_put_budget(text,text,jsonb),public.sl_get_overview(text,text),
  public.sl_accounts_page(text,text,integer,timestamptz,uuid),public.sl_transactions_page(text,text,integer,jsonb,timestamptz,uuid) TO service_role;
