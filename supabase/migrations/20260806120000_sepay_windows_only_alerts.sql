BEGIN;

UPDATE public.sepay_alert_devices
SET is_enabled = false,
    updated_at = now()
WHERE platform <> 'windows'
   OR push_provider <> 'polling';

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
     OR p_platform <> 'windows'
     OR p_push_provider <> 'polling'
     OR NULLIF(btrim(COALESCE(p_push_token, '')), '') IS NOT NULL THEN
    RAISE EXCEPTION 'SEPAY_WINDOWS_ALERT_DEVICE_REQUIRED';
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
    'windows',
    'polling',
    NULL,
    NULLIF(btrim(COALESCE(p_label, '')), ''),
    true,
    now(),
    now()
  )
  ON CONFLICT (restaurant_id, user_id, installation_id) DO UPDATE
  SET platform = 'windows',
      push_provider = 'polling',
      push_token = NULL,
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
    AND device.platform = 'windows'
    AND device.push_provider = 'polling'
  ON CONFLICT (transaction_id, device_id) DO NOTHING;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_sepay_alert_deliveries()
  FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF to_regclass('cron.job') IS NOT NULL THEN
    PERFORM cron.unschedule(jobid)
    FROM cron.job
    WHERE jobname = 'sepay-alert-dispatcher-every-minute';
  END IF;
EXCEPTION
  WHEN invalid_schema_name OR undefined_function OR insufficient_privilege THEN
    RAISE NOTICE 'pg_cron unavailable; no SePay push dispatcher to remove.';
END
$$;

COMMIT;
