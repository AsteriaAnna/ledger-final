-- P1 synthetic probe only. No personal or production data.
CREATE TABLE public.sl_p1_probe_accounts (
  id text PRIMARY KEY,
  balance_cents bigint NOT NULL CHECK (balance_cents >= 0),
  revision bigint NOT NULL DEFAULT 0
);

CREATE TABLE public.sl_p1_probe_requests (
  request_key text PRIMARY KEY,
  account_id text NOT NULL REFERENCES public.sl_p1_probe_accounts(id),
  amount_cents bigint NOT NULL CHECK (amount_cents > 0),
  balance_after_cents bigint NOT NULL
);

CREATE FUNCTION public.sl_p1_probe_spend(
  p_account_id text,
  p_amount_cents bigint,
  p_request_key text,
  p_inject_failure boolean DEFAULT false
) RETURNS bigint
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_balance bigint;
  v_request public.sl_p1_probe_requests%ROWTYPE;
BEGIN
  IF p_amount_cents <= 0 OR p_request_key IS NULL OR p_request_key = '' THEN
    RAISE EXCEPTION 'invalid_probe_input';
  END IF;

  SELECT balance_cents INTO v_balance
  FROM public.sl_p1_probe_accounts
  WHERE id = p_account_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'probe_account_missing'; END IF;

  SELECT * INTO v_request
  FROM public.sl_p1_probe_requests
  WHERE request_key = p_request_key;
  IF FOUND THEN
    IF v_request.account_id <> p_account_id OR v_request.amount_cents <> p_amount_cents THEN
      RAISE EXCEPTION 'probe_idempotency_conflict';
    END IF;
    RETURN v_request.balance_after_cents;
  END IF;

  IF v_balance < p_amount_cents THEN RAISE EXCEPTION 'probe_insufficient_funds'; END IF;
  v_balance := v_balance - p_amount_cents;

  UPDATE public.sl_p1_probe_accounts
  SET balance_cents = v_balance, revision = revision + 1
  WHERE id = p_account_id;
  INSERT INTO public.sl_p1_probe_requests(request_key, account_id, amount_cents, balance_after_cents)
  VALUES (p_request_key, p_account_id, p_amount_cents, v_balance);

  IF p_inject_failure THEN RAISE EXCEPTION 'probe_injected_failure'; END IF;
  RETURN v_balance;
END;
$$;

REVOKE ALL ON public.sl_p1_probe_accounts FROM PUBLIC;
REVOKE ALL ON public.sl_p1_probe_requests FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sl_p1_probe_spend(text, bigint, text, boolean) FROM PUBLIC;

-- Cleanup after recording results: apply a NEW migration that drops only these three probe objects.
