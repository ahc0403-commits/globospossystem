BEGIN;

CREATE TABLE IF NOT EXISTS public.sepay_alert_devices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  installation_id text NOT NULL,
  platform text NOT NULL,
  push_provider text NOT NULL,
  push_token text,
  label text,
  is_enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sepay_alert_devices_installation_id_check
    CHECK (char_length(btrim(installation_id)) BETWEEN 8 AND 128),
  CONSTRAINT sepay_alert_devices_platform_check
    CHECK (platform IN ('web', 'windows', 'macos', 'android', 'ios')),
  CONSTRAINT sepay_alert_devices_provider_check
    CHECK (push_provider IN ('fcm', 'apns', 'web_push', 'polling')),
  CONSTRAINT sepay_alert_devices_push_token_check
    CHECK (
      push_provider = 'polling'
      OR char_length(btrim(COALESCE(push_token, ''))) BETWEEN 16 AND 4096
    ),
  UNIQUE (restaurant_id, user_id, installation_id)
);

CREATE TABLE IF NOT EXISTS public.sepay_alert_deliveries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  transaction_id uuid NOT NULL
    REFERENCES public.sepay_transactions(id) ON DELETE CASCADE,
  device_id uuid NOT NULL
    REFERENCES public.sepay_alert_devices(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'queued',
  attempt_count integer NOT NULL DEFAULT 0,
  provider_message_id text,
  last_error text,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  accepted_at timestamptz,
  seen_at timestamptz,
  spoken_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sepay_alert_deliveries_status_check
    CHECK (status IN ('queued', 'processing', 'accepted', 'seen', 'spoken', 'failed')),
  CONSTRAINT sepay_alert_deliveries_attempt_count_check
    CHECK (attempt_count >= 0),
  UNIQUE (transaction_id, device_id)
);

CREATE INDEX IF NOT EXISTS sepay_alert_devices_store_enabled_idx
  ON public.sepay_alert_devices (restaurant_id, is_enabled);
CREATE INDEX IF NOT EXISTS sepay_alert_deliveries_dispatch_idx
  ON public.sepay_alert_deliveries (status, next_attempt_at, created_at)
  WHERE status IN ('queued', 'failed', 'processing');
CREATE INDEX IF NOT EXISTS sepay_alert_deliveries_device_created_idx
  ON public.sepay_alert_deliveries (device_id, created_at DESC);

ALTER TABLE public.sepay_alert_devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sepay_alert_deliveries ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.sepay_alert_devices FROM anon, authenticated;
REVOKE ALL ON public.sepay_alert_deliveries FROM anon, authenticated;
GRANT ALL ON public.sepay_alert_devices TO service_role;
GRANT ALL ON public.sepay_alert_deliveries TO service_role;

COMMENT ON TABLE public.sepay_alert_devices IS
  'Private per-user alert installations. Push tokens are server-only.';
COMMENT ON TABLE public.sepay_alert_deliveries IS
  'Per-transaction per-device SePay delivery, visibility, and speech ledger.';

CREATE OR REPLACE FUNCTION public.upsert_sepay_alert_device(
  p_store_id uuid,
  p_installation_id text,
  p_platform text,
  p_push_provider text,
  p_push_token text DEFAULT NULL,
  p_label text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_device_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) accessible(store_id)
       WHERE accessible.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_DENIED';
  END IF;

  IF char_length(btrim(COALESCE(p_installation_id, ''))) NOT BETWEEN 8 AND 128
     OR p_platform NOT IN ('web', 'windows', 'macos', 'android', 'ios')
     OR p_push_provider NOT IN ('fcm', 'apns', 'web_push', 'polling')
     OR (
       p_push_provider <> 'polling'
       AND char_length(btrim(COALESCE(p_push_token, ''))) NOT BETWEEN 16 AND 4096
     ) THEN
    RAISE EXCEPTION 'SEPAY_ALERT_DEVICE_INVALID';
  END IF;

  INSERT INTO public.sepay_alert_devices (
    restaurant_id,
    user_id,
    installation_id,
    platform,
    push_provider,
    push_token,
    label,
    is_enabled,
    updated_at,
    last_seen_at
  ) VALUES (
    p_store_id,
    auth.uid(),
    btrim(p_installation_id),
    p_platform,
    p_push_provider,
    NULLIF(btrim(COALESCE(p_push_token, '')), ''),
    NULLIF(btrim(COALESCE(p_label, '')), ''),
    true,
    now(),
    now()
  )
  ON CONFLICT (restaurant_id, user_id, installation_id) DO UPDATE
  SET platform = EXCLUDED.platform,
      push_provider = CASE
        WHEN sepay_alert_devices.push_provider = 'fcm'
          AND EXCLUDED.push_provider = 'polling'
        THEN sepay_alert_devices.push_provider
        ELSE EXCLUDED.push_provider
      END,
      push_token = CASE
        WHEN sepay_alert_devices.push_provider = 'fcm'
          AND EXCLUDED.push_provider = 'polling'
        THEN sepay_alert_devices.push_token
        ELSE EXCLUDED.push_token
      END,
      label = EXCLUDED.label,
      is_enabled = true,
      updated_at = now(),
      last_seen_at = now()
  RETURNING id INTO v_device_id;

  RETURN v_device_id;
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_sepay_alert_device(
  uuid, text, text, text, text, text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_sepay_alert_device(
  uuid, text, text, text, text, text
) TO authenticated;

CREATE OR REPLACE FUNCTION public.ack_sepay_alert_delivery(
  p_transaction_id uuid,
  p_installation_id text,
  p_status text
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_updated integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;
  IF p_status NOT IN ('seen', 'spoken') THEN
    RAISE EXCEPTION 'SEPAY_ALERT_ACK_INVALID';
  END IF;

  UPDATE public.sepay_alert_deliveries delivery
  SET status = CASE
        WHEN delivery.status = 'spoken' THEN 'spoken'
        ELSE p_status
      END,
      seen_at = COALESCE(delivery.seen_at, now()),
      spoken_at = CASE
        WHEN p_status = 'spoken' THEN COALESCE(delivery.spoken_at, now())
        ELSE delivery.spoken_at
      END,
      updated_at = now()
  FROM public.sepay_alert_devices device
  WHERE delivery.transaction_id = p_transaction_id
    AND delivery.device_id = device.id
    AND device.user_id = auth.uid()
    AND device.installation_id = btrim(p_installation_id);

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated > 0;
END;
$$;

REVOKE ALL ON FUNCTION public.ack_sepay_alert_delivery(uuid, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ack_sepay_alert_delivery(uuid, text, text)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.enqueue_sepay_alert_deliveries()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.restaurant_id IS NULL
     OR NEW.transfer_type <> 'in'
     OR NEW.resolution_status <> 'matched' THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.sepay_alert_deliveries (
    restaurant_id,
    transaction_id,
    device_id
  )
  SELECT NEW.restaurant_id, NEW.id, device.id
  FROM public.sepay_alert_devices device
  WHERE device.restaurant_id = NEW.restaurant_id
    AND device.is_enabled = true
  ON CONFLICT (transaction_id, device_id) DO NOTHING;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_sepay_alert_deliveries()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS sepay_alert_delivery_enqueue_trigger
  ON public.sepay_transactions;
CREATE TRIGGER sepay_alert_delivery_enqueue_trigger
AFTER INSERT ON public.sepay_transactions
FOR EACH ROW
EXECUTE FUNCTION public.enqueue_sepay_alert_deliveries();

CREATE OR REPLACE FUNCTION public.claim_sepay_alert_deliveries(
  p_limit integer DEFAULT 100
) RETURNS TABLE (
  delivery_id uuid,
  transaction_id uuid,
  restaurant_id uuid,
  device_id uuid,
  platform text,
  push_provider text,
  push_token text,
  amount bigint,
  payment_code text,
  received_at timestamptz,
  attempt_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH candidates AS (
    SELECT delivery.id
    FROM public.sepay_alert_deliveries delivery
    JOIN public.sepay_alert_devices device ON device.id = delivery.device_id
    WHERE (
        (delivery.status IN ('queued', 'failed')
          AND delivery.next_attempt_at <= now())
        OR (
          delivery.status = 'processing'
          AND delivery.updated_at <= now() - interval '5 minutes'
        )
      )
      AND delivery.attempt_count < 10
      AND device.is_enabled = true
      AND device.push_provider = 'fcm'
      AND device.push_token IS NOT NULL
    ORDER BY delivery.created_at ASC
    FOR UPDATE OF delivery SKIP LOCKED
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500)
  ), claimed AS (
    UPDATE public.sepay_alert_deliveries delivery
    SET status = 'processing',
        attempt_count = delivery.attempt_count + 1,
        updated_at = now()
    FROM candidates
    WHERE delivery.id = candidates.id
    RETURNING delivery.*
  )
  SELECT
    claimed.id,
    claimed.transaction_id,
    claimed.restaurant_id,
    claimed.device_id,
    device.platform,
    device.push_provider,
    device.push_token,
    txn.transfer_amount,
    txn.payment_code,
    txn.received_at,
    claimed.attempt_count
  FROM claimed
  JOIN public.sepay_alert_devices device ON device.id = claimed.device_id
  JOIN public.sepay_transactions txn ON txn.id = claimed.transaction_id
  ORDER BY claimed.created_at ASC;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_sepay_alert_deliveries(integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_sepay_alert_deliveries(integer)
  TO service_role;

CREATE OR REPLACE FUNCTION public.complete_sepay_alert_delivery(
  p_delivery_id uuid,
  p_accepted boolean,
  p_provider_message_id text DEFAULT NULL,
  p_error text DEFAULT NULL,
  p_retry_after_seconds integer DEFAULT 30
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.sepay_alert_deliveries
  SET status = CASE WHEN p_accepted THEN 'accepted' ELSE 'failed' END,
      provider_message_id = NULLIF(btrim(COALESCE(p_provider_message_id, '')), ''),
      last_error = CASE
        WHEN p_accepted THEN NULL
        ELSE left(COALESCE(p_error, 'PUSH_FAILED'), 500)
      END,
      next_attempt_at = CASE
        WHEN p_accepted THEN next_attempt_at
        ELSE now() + make_interval(
          secs => LEAST(GREATEST(COALESCE(p_retry_after_seconds, 30), 5), 3600)
        )
      END,
      accepted_at = CASE WHEN p_accepted THEN now() ELSE accepted_at END,
      updated_at = now()
  WHERE id = p_delivery_id
    AND status = 'processing';
END;
$$;

REVOKE ALL ON FUNCTION public.complete_sepay_alert_delivery(
  uuid, boolean, text, text, integer
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.complete_sepay_alert_delivery(
  uuid, boolean, text, text, integer
) TO service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
     AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    PERFORM cron.unschedule(jobid)
    FROM cron.job
    WHERE jobname = 'sepay-alert-dispatcher-every-minute';

    PERFORM cron.schedule(
      'sepay-alert-dispatcher-every-minute',
      '* * * * *',
      $job$
      SELECT net.http_post(
        url := 'https://ynriuoomotxuwhuxxmhj.supabase.co/functions/v1/sepay-alert-dispatcher',
        headers := jsonb_build_object(
          'Authorization', 'Bearer ' || (
            SELECT decrypted_secret
            FROM vault.decrypted_secrets
            WHERE name = 'cron_secret'
            LIMIT 1
          ),
          'Content-Type', 'application/json'
        ),
        body := '{}'::jsonb
      )
      $job$
    );
  END IF;
EXCEPTION
  WHEN invalid_schema_name OR undefined_function OR insufficient_privilege THEN
    RAISE NOTICE 'pg_cron/pg_net unavailable; skipped SePay dispatcher schedule.';
END
$$;

COMMIT;
