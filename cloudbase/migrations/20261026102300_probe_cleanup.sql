-- Remove only the synthetic P1 probe objects after recording read-back results.
DROP FUNCTION public.sl_p1_probe_spend(text, bigint, text, boolean);
DROP TABLE public.sl_p1_probe_requests;
DROP TABLE public.sl_p1_probe_accounts;
