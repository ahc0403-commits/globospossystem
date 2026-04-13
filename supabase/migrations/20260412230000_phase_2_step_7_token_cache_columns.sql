-- Phase 2 Step 7 — Add WeTax token cache columns to partner_credentials
-- Applied via Supabase MCP. Token cached in DB for stateless Deno edge functions.

ALTER TABLE public.partner_credentials
  ADD COLUMN current_token    text,
  ADD COLUMN token_expires_at timestamptz;

COMMENT ON COLUMN public.partner_credentials.current_token IS
  'Cached WeTax JWT from WT00 login. Refreshed when NULL or within 15 min of expiry.';
COMMENT ON COLUMN public.partner_credentials.token_expires_at IS
  'Expiry of current_token. Proactive refresh at token_expires_at - 15 minutes.';
