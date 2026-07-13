-- Moers exports are an immutable append-only sales source. Existing source rows
-- may gain invoice-processing metadata, but their sales identity cannot change.

CREATE OR REPLACE FUNCTION public.enforce_photo_objet_raw_immutability()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF current_user NOT IN ('postgres', 'supabase_admin') THEN
      RAISE EXCEPTION 'PHOTO_OBJET_RAW_DELETE_FORBIDDEN';
    END IF;
    RETURN OLD;
  END IF;

  IF ROW(
    NEW.id,
    NEW.store_id,
    NEW.sale_date,
    NEW.device_name,
    NEW.device_id,
    NEW.sale_time_text,
    NEW.sold_at,
    NEW.amount,
    NEW.raw_type,
    NEW.payment_method,
    NEW.buyer_kind,
    NEW.raw_payload,
    NEW.source_hash,
    NEW.source_identity_version,
    NEW.occurrence_no,
    NEW.interval_start_at,
    NEW.interval_end_at,
    NEW.pull_run_id,
    NEW.first_seen_at,
    NEW.created_at
  ) IS DISTINCT FROM ROW(
    OLD.id,
    OLD.store_id,
    OLD.sale_date,
    OLD.device_name,
    OLD.device_id,
    OLD.sale_time_text,
    OLD.sold_at,
    OLD.amount,
    OLD.raw_type,
    OLD.payment_method,
    OLD.buyer_kind,
    OLD.raw_payload,
    OLD.source_hash,
    OLD.source_identity_version,
    OLD.occurrence_no,
    OLD.interval_start_at,
    OLD.interval_end_at,
    OLD.pull_run_id,
    OLD.first_seen_at,
    OLD.created_at
  ) THEN
    RAISE EXCEPTION 'PHOTO_OBJET_RAW_IDENTITY_IMMUTABLE';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_photo_objet_raw_immutability
  ON public.photo_objet_sales_raw;
CREATE TRIGGER trg_photo_objet_raw_immutability
BEFORE UPDATE OR DELETE ON public.photo_objet_sales_raw
FOR EACH ROW EXECUTE FUNCTION public.enforce_photo_objet_raw_immutability();

COMMENT ON FUNCTION public.enforce_photo_objet_raw_immutability() IS
  'Prevents service paths from changing or deleting immutable Moers sales identity fields.';

CREATE OR REPLACE FUNCTION public.photo_objet_collection_health_at(
  p_observed_at timestamptz DEFAULT now()
)
RETURNS TABLE (
  store_id uuid,
  target_date date,
  expected_slots integer,
  due_slots integer,
  successful_slots integer,
  failed_slots integer,
  missing_slots integer,
  missing_slot_times text[],
  failed_slot_times text[],
  latest_successful_slot timestamptz,
  next_expected_slot timestamptz,
  last_finished_at timestamptz,
  observed_at timestamptz,
  status text,
  is_healthy boolean
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $health$
WITH runtime AS (
  SELECT
    p_observed_at AS observed_at,
    (p_observed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS hcm_today,
    '2026-07-13 09:00:00+07'::timestamptz AS audit_start_at
),
dates AS (
  SELECT generate_series(
    runtime.hcm_today - 92,
    runtime.hcm_today,
    interval '1 day'
  )::date AS target_date
  FROM runtime
),
slot_times(slot_time_hcm) AS (
  VALUES
    ('09:00'::time), ('10:00'::time), ('11:00'::time),
    ('12:00'::time), ('13:00'::time), ('14:00'::time),
    ('15:00'::time), ('16:00'::time), ('17:00'::time),
    ('18:00'::time), ('19:00'::time), ('20:00'::time),
    ('21:00'::time), ('22:00'::time), ('22:30'::time)
),
scheduled_slots_base AS (
  SELECT
    dates.target_date,
    slot_times.slot_time_hcm,
    (dates.target_date + slot_times.slot_time_hcm)
      AT TIME ZONE 'Asia/Ho_Chi_Minh' AS scheduled_at
  FROM dates
  CROSS JOIN slot_times
  CROSS JOIN runtime
  WHERE (dates.target_date + slot_times.slot_time_hcm)
      AT TIME ZONE 'Asia/Ho_Chi_Minh' >= runtime.audit_start_at
),
scheduled_slots AS (
  SELECT
    target_date,
    slot_time_hcm,
    scheduled_at,
    coalesce(
      lead(scheduled_at) OVER (
        PARTITION BY target_date
        ORDER BY slot_time_hcm
      ),
      scheduled_at + interval '90 minutes'
    ) + interval '15 minutes' AS due_at
  FROM scheduled_slots_base
),
scheduled_runs AS (
  SELECT
    store_id,
    slot_date_hcm AS target_date,
    slot_time_hcm,
    bool_or(status = 'success') AS succeeded,
    bool_or(status = 'failed') AS failed,
    max(finished_at) FILTER (WHERE status = 'success') AS finished_at
  FROM public.photo_objet_sales_pull_runs
  WHERE run_source = 'scheduled'
    AND slot_date_hcm IS NOT NULL
    AND slot_time_hcm IS NOT NULL
  GROUP BY store_id, slot_date_hcm, slot_time_hcm
),
store_slots AS (
  SELECT
    restaurants.id AS store_id,
    scheduled_slots.target_date,
    scheduled_slots.slot_time_hcm,
    scheduled_slots.scheduled_at,
    scheduled_slots.due_at,
    runtime.observed_at,
    coalesce(scheduled_runs.succeeded, false) AS succeeded,
    coalesce(scheduled_runs.failed, false) AS failed,
    scheduled_runs.finished_at
  FROM public.restaurants
  CROSS JOIN scheduled_slots
  CROSS JOIN runtime
  LEFT JOIN scheduled_runs
    ON scheduled_runs.store_id = restaurants.id
   AND scheduled_runs.target_date = scheduled_slots.target_date
   AND scheduled_runs.slot_time_hcm = scheduled_slots.slot_time_hcm
  WHERE restaurants.is_active = true
    AND restaurants.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
),
aggregated AS (
  SELECT
    store_id,
    target_date,
    count(*)::integer AS expected_slots,
    count(*) FILTER (
      WHERE due_at <= observed_at
    )::integer AS due_slots,
    count(*) FILTER (
      WHERE due_at <= observed_at
        AND succeeded
    )::integer AS successful_slots,
    count(*) FILTER (
      WHERE due_at <= observed_at
        AND failed
        AND NOT succeeded
    )::integer AS failed_slots,
    count(*) FILTER (
      WHERE due_at <= observed_at
        AND NOT succeeded
    )::integer AS missing_slots,
    coalesce(
      array_agg(to_char(slot_time_hcm, 'HH24:MI') ORDER BY slot_time_hcm)
        FILTER (
          WHERE due_at <= observed_at
            AND NOT succeeded
        ),
      ARRAY[]::text[]
    ) AS missing_slot_times,
    coalesce(
      array_agg(to_char(slot_time_hcm, 'HH24:MI') ORDER BY slot_time_hcm)
        FILTER (
          WHERE due_at <= observed_at
            AND failed
            AND NOT succeeded
        ),
      ARRAY[]::text[]
    ) AS failed_slot_times,
    max(scheduled_at) FILTER (WHERE succeeded) AS latest_successful_slot,
    min(scheduled_at) FILTER (
      WHERE due_at > observed_at
    ) AS next_expected_slot,
    max(finished_at) FILTER (WHERE succeeded) AS last_finished_at,
    max(observed_at) AS observed_at
  FROM store_slots
  GROUP BY store_id, target_date
)
SELECT
  store_id,
  target_date,
  expected_slots,
  due_slots,
  successful_slots,
  failed_slots,
  missing_slots,
  missing_slot_times,
  failed_slot_times,
  latest_successful_slot,
  next_expected_slot,
  last_finished_at,
  observed_at,
  CASE
    WHEN due_slots = 0 THEN 'not_due'
    WHEN failed_slots > 0 THEN 'failed'
    WHEN missing_slots > 0 THEN 'missing'
    ELSE 'healthy'
  END AS status,
  due_slots > 0 AND missing_slots = 0 AND failed_slots = 0 AS is_healthy
FROM aggregated
$health$;

REVOKE ALL ON FUNCTION public.photo_objet_collection_health_at(timestamptz)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.photo_objet_collection_health_at(timestamptz)
  TO authenticated, service_role;

CREATE OR REPLACE VIEW public.v_photo_objet_collection_health
WITH (security_invoker = true)
AS
SELECT *
FROM public.photo_objet_collection_health_at(now());

COMMENT ON VIEW public.v_photo_objet_collection_health IS
  'Exact-slot Photo Objet health due 15 minutes after the next schedule, tolerating delayed GitHub starts.';

GRANT SELECT ON public.v_photo_objet_collection_health TO authenticated;
GRANT SELECT ON public.v_photo_objet_collection_health TO service_role;
