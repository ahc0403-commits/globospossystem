-- meInvoice adapter migration to the MISA Developer Portal OpenAPI.
-- Docs: https://developer.misa.vn/products-openapi/MEINVOICE
--
-- 1. Base URL defaults move from the legacy api.meinvoice.vn integration
--    API to the portal gateway. No config rows exist yet (verified on prod
--    2026-07-11), so only column defaults and comments change.
-- 2. app_id now stores the portal ClientID (issued per registered app on
--    developer.misa.vn). ClientSecret is an Edge Function env secret
--    (MISA_MEINVOICE_CLIENT_SECRET_<TAX_CODE>) and never lands in this table.
-- 3. Dispatch claim columns used by the deployed dispatcher are added
--    idempotently — they were applied to prod directly and were missing
--    from repo migrations (repo/local parity fix).

ALTER TABLE public.meinvoice_tax_entity_config
  ALTER COLUMN auth_base_url
    SET DEFAULT 'https://developer.misa.vn/apis/itg/meinvoice/invoice';

ALTER TABLE public.meinvoice_tax_entity_config
  ALTER COLUMN api_base_url
    SET DEFAULT 'https://developer.misa.vn/apis/itg/meinvoice/invoice';

COMMENT ON COLUMN public.meinvoice_tax_entity_config.auth_base_url IS
  'MISA Developer Portal base URL for POST {base}/token (ClientID + ClientSecret headers; taxcode/username/password body).';

COMMENT ON COLUMN public.meinvoice_tax_entity_config.api_base_url IS
  'MISA Developer Portal base URL for /publishing, /templates, /status, /Download (Bearer token + ClientID header).';

COMMENT ON COLUMN public.meinvoice_tax_entity_config.app_id IS
  'MISA Developer Portal ClientID for this legal entity. Non-secret; the paired ClientSecret lives only in Edge Function env as MISA_MEINVOICE_CLIENT_SECRET_<TAX_CODE>.';

ALTER TABLE public.meinvoice_jobs
  ADD COLUMN IF NOT EXISTS dispatch_claim_id uuid,
  ADD COLUMN IF NOT EXISTS dispatch_claimed_at timestamptz;

COMMENT ON COLUMN public.meinvoice_jobs.dispatch_claim_id IS
  'Dispatcher claim token: prevents two concurrent runs publishing the same job; stale claims (>15min) are reclaimable.';
