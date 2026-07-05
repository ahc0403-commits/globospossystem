-- MISA meInvoice dispatcher foundation.
-- Adds service-only token cache, dispatch audit events, and retry metadata.
-- This migration does not schedule or enable live MISA dispatch.

BEGIN;

ALTER TABLE public.meinvoice_tax_entity_config
  ADD COLUMN IF NOT EXISTS auth_base_url text
    NOT NULL DEFAULT 'https://api.meinvoice.vn/api/integration';

ALTER TABLE public.meinvoice_tax_entity_config
  ALTER COLUMN api_base_url
  SET DEFAULT 'https://api.meinvoice.vn/api/integration/invoice';

UPDATE public.meinvoice_tax_entity_config
SET api_base_url = 'https://api.meinvoice.vn/api/integration/invoice',
    auth_base_url = 'https://api.meinvoice.vn/api/integration',
    updated_at = now()
WHERE api_base_url IN (
    'https://app3.meinvoice.vn/api/integration',
    'https://api.meinvoice.vn/api/integration',
    'https://api.meinvoice.vn/api/v3'
  )
  OR auth_base_url IS NULL;

COMMENT ON COLUMN public.meinvoice_tax_entity_config.auth_base_url IS
  'MISA token API base URL. Official integration token path is /auth/token under /api/integration.';
COMMENT ON COLUMN public.meinvoice_tax_entity_config.api_base_url IS
  'MISA NEW invoice API base URL. Cash-register publish uses SignType=5 at /api/integration/invoice.';

INSERT INTO public.system_config (key, value, description)
VALUES
  (
    'meinvoice_dispatch_enabled',
    'false',
    'MISA meInvoice API dispatch gate. Keep false until MISA app_id/API activation, invoice series, and payment labels are confirmed.'
  ),
  (
    'meinvoice_dispatch_batch_size',
    '10',
    'Maximum meInvoice jobs processed by one dispatcher invocation.'
  ),
  (
    'meinvoice_token_refresh_skew_minutes',
    '60',
    'Refresh cached MISA token before expiry. Avoids calling /auth/token for every invoice.'
  )
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value,
    description = EXCLUDED.description,
    updated_at = now();

ALTER TABLE public.meinvoice_jobs
  ADD COLUMN IF NOT EXISTS dispatch_attempts int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_dispatch_at timestamptz,
  ADD COLUMN IF NOT EXISTS next_retry_at timestamptz,
  ADD COLUMN IF NOT EXISTS sent_at timestamptz;

CREATE TABLE IF NOT EXISTS public.meinvoice_token_cache (
  tax_entity_id uuid PRIMARY KEY REFERENCES public.tax_entity(id),
  current_token text NOT NULL,
  token_expires_at timestamptz NOT NULL,
  last_verified_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.meinvoice_token_cache IS
  'Service-only cache for MISA meInvoice tokens. No authenticated read policy is defined; Edge Functions use service_role only.';
COMMENT ON COLUMN public.meinvoice_token_cache.current_token IS
  'Bearer token returned by MISA /auth/token. Treat as secret runtime state.';
COMMENT ON COLUMN public.meinvoice_token_cache.token_expires_at IS
  'Expiry derived from JWT exp when present, otherwise a conservative 14-day fallback.';

ALTER TABLE public.meinvoice_token_cache ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.meinvoice_job_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid REFERENCES public.meinvoice_jobs(id) ON DELETE SET NULL,
  event_type text NOT NULL,
  description text,
  retry_count int,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  raw_request jsonb,
  raw_response jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.meinvoice_job_events
  ADD COLUMN IF NOT EXISTS metadata jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON TABLE public.meinvoice_job_events IS
  'Append-only audit trail for meInvoice dispatcher attempts. Store safe metadata summaries; do not persist raw invoice payloads or MISA responses.';

CREATE INDEX IF NOT EXISTS idx_meinvoice_job_events_job_created
  ON public.meinvoice_job_events (job_id, created_at DESC);

ALTER TABLE public.meinvoice_job_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "meinvoice_job_events_store_read"
  ON public.meinvoice_job_events;
CREATE POLICY "meinvoice_job_events_store_read"
  ON public.meinvoice_job_events
  FOR SELECT
  TO authenticated
  USING (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.meinvoice_jobs mj
      JOIN public.user_accessible_stores(auth.uid()) s(store_id)
        ON s.store_id = mj.store_id
      WHERE mj.id = meinvoice_job_events.job_id
    )
  );

COMMIT;
