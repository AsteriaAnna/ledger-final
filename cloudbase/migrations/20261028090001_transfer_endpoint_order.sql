-- A transfer is one event with one endpoint per account. Its two endpoints
-- share the original transaction order; ordering remains unique within each
-- account. Keep applied migration history unchanged.
ALTER TABLE public.sl_effects DROP CONSTRAINT sl_effects_replay_order_key;
DROP INDEX public.sl_effects_account_replay;
ALTER TABLE public.sl_effects ADD CONSTRAINT sl_effects_account_replay_key UNIQUE(account_id,replay_order);
