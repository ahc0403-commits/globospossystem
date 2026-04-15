-- Phase 2 Step 7 — Add WeTax token cache columns to partner_credentials
-- Edge functions need to cache the WeTax JWT between invocations.
-- Token stored in DB (stateless Deno functions have no in-memory persistence).

ALTER TABLE public.partner_credentials
  ADD COLUMN current_token       text,
  ADD COLUMN token_expires_at    timestamptz;

COMMENT ON COLUMN public.partner_credentials.current_token IS
  'Cached WeTax JWT from WT00 login. Read by dispatcher before each API call. '
  'Refreshed when NULL or within 15 minutes of token_expires_at.';

COMMENT ON COLUMN public.partner_credentials.token_expires_at IS
  'Expiry timestamp of current_token. Proactive refresh triggers at '
  'token_expires_at - 15 minutes. Set from WT00 response expires_in.';;
