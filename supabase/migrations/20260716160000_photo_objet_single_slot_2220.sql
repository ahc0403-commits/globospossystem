-- Replace the Photo Objet intraday collection schedule with one complete daily
-- collection at 22:20 HCM. Historical v1/v2 slots remain intact.

CREATE TABLE IF NOT EXISTS public.photo_slot_20260716160000_state (
  migration_id text PRIMARY KEY,
  cutover_date date NOT NULL,
  cutover_at timestamptz NOT NULL,
  prior_schedule_default text NOT NULL,
  prior_schedule_constraint_definition text NOT NULL,
  prior_slot_constraint_definition text NOT NULL,
  prior_ensure_function_definition text NOT NULL,
  prior_health_function_definition text NOT NULL,
  prior_enqueue_trigger_definition text,
  captured_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.photo_slot_20260716160000_policy_map (
  old_policy_id uuid PRIMARY KEY,
  new_policy_id uuid NOT NULL UNIQUE,
  store_id uuid NOT NULL,
  old_effective_to timestamptz,
  timezone text NOT NULL,
  grace_minutes integer NOT NULL,
  final_slot_grace_minutes integer NOT NULL,
  is_enabled boolean NOT NULL
);

CREATE TABLE IF NOT EXISTS public.photo_slot_20260716160000_expected_backup (
  id uuid PRIMARY KEY,
  store_id uuid NOT NULL,
  slot_date_hcm date NOT NULL,
  slot_time_hcm time NOT NULL,
  scheduled_at timestamptz NOT NULL,
  due_at timestamptz NOT NULL,
  monitoring_policy_id uuid NOT NULL,
  status text NOT NULL,
  successful_run_id uuid,
  attempt_count integer NOT NULL,
  last_failure_class text,
  alerted_failure_class text,
  alerted_at timestamptz,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);

ALTER TABLE public.photo_slot_20260716160000_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_slot_20260716160000_state FORCE ROW LEVEL SECURITY;
ALTER TABLE public.photo_slot_20260716160000_policy_map ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_slot_20260716160000_policy_map FORCE ROW LEVEL SECURITY;
ALTER TABLE public.photo_slot_20260716160000_expected_backup ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_slot_20260716160000_expected_backup FORCE ROW LEVEL SECURITY;

REVOKE ALL ON
  public.photo_slot_20260716160000_state,
  public.photo_slot_20260716160000_policy_map,
  public.photo_slot_20260716160000_expected_backup
FROM PUBLIC, anon, authenticated, service_role;

INSERT INTO public.photo_slot_20260716160000_state (
  migration_id,
  cutover_date,
  cutover_at,
  prior_schedule_default,
  prior_schedule_constraint_definition,
  prior_slot_constraint_definition,
  prior_ensure_function_definition,
  prior_health_function_definition,
  prior_enqueue_trigger_definition
)
SELECT
  '20260716160000',
  (cutover.cutover_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
  cutover.cutover_at,
  pg_get_expr(default_value.adbin, default_value.adrelid),
  schedule_constraint.definition,
  slot_constraint.definition,
  pg_get_functiondef(
    'public.photo_objet_ensure_expected_slots(date,date)'::regprocedure
  ),
  pg_get_functiondef(
    'public.photo_objet_expected_slot_health_at(timestamp with time zone,integer)'::regprocedure
  ),
  (
    SELECT pg_get_triggerdef(trigger.oid, true)
    FROM pg_trigger trigger
    WHERE trigger.tgrelid = 'public.photo_objet_sales_raw'::regclass
      AND trigger.tgname = 'trg_enqueue_photo_objet_meinvoice_job'
      AND NOT trigger.tgisinternal
  )
FROM (
  SELECT coalesce(
    nullif(current_setting('app.photo_objet_single_slot_cutover_at', true), '')::timestamptz,
    (
      nullif(current_setting('app.photo_objet_single_slot_cutover_date', true), '')::date::timestamp
      AT TIME ZONE 'Asia/Ho_Chi_Minh'
    ),
    now()
  ) AS cutover_at
) cutover
CROSS JOIN LATERAL (
  SELECT d.adbin, d.adrelid
  FROM pg_attribute a
  JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
  WHERE a.attrelid = 'public.photo_objet_monitoring_policies'::regclass
    AND a.attname = 'schedule_version'
    AND NOT a.attisdropped
) default_value
CROSS JOIN LATERAL (
  SELECT pg_get_constraintdef(c.oid, true) AS definition
  FROM pg_constraint c
  WHERE c.conrelid = 'public.photo_objet_monitoring_policies'::regclass
    AND c.conname = 'photo_objet_monitoring_policy_schedule_check'
) schedule_constraint
CROSS JOIN LATERAL (
  SELECT pg_get_constraintdef(c.oid, true) AS definition
  FROM pg_constraint c
  WHERE c.conrelid = 'public.photo_objet_expected_slots'::regclass
    AND c.conname = 'photo_objet_expected_slot_time_check'
) slot_constraint
ON CONFLICT (migration_id) DO NOTHING;

-- Photo collection is an immutable sales ledger only. MISA issuance remains
-- outside POS and is handled by the separate Windows portal automation.
DROP TRIGGER IF EXISTS trg_enqueue_photo_objet_meinvoice_job
  ON public.photo_objet_sales_raw;

DO $$
DECLARE
  v_cutover_at timestamptz;
  v_bad integer;
BEGIN
  SELECT cutover_at INTO STRICT v_cutover_at
  FROM public.photo_slot_20260716160000_state
  WHERE migration_id = '20260716160000';

  IF NOT EXISTS (
    SELECT 1 FROM public.photo_objet_monitoring_policies
    WHERE effective_to IS NULL
      AND schedule_version = 'hcm-eod-2220-v3'
  ) THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.photo_objet_monitoring_policies
      WHERE effective_to IS NULL
        AND schedule_version = 'hcm-two-hour-2230-v2'
    ) THEN
      RAISE EXCEPTION 'PHOTO_2220_OPEN_V2_POLICY_MISSING';
    END IF;

    SELECT count(*) INTO v_bad
    FROM public.photo_objet_monitoring_policies p
    JOIN public.restaurants r ON r.id = p.store_id
    WHERE p.effective_to IS NULL
      AND p.schedule_version = 'hcm-two-hour-2230-v2'
      AND (
        p.is_enabled IS DISTINCT FROM true
        OR r.is_active IS DISTINCT FROM true
        OR p.timezone <> 'Asia/Ho_Chi_Minh'
        OR p.final_slot_grace_minutes <> 90
      );
    IF v_bad <> 0 THEN
      RAISE EXCEPTION 'PHOTO_2220_POLICY_PREFLIGHT_FAILED: %', v_bad;
    END IF;

    SELECT count(*) INTO v_bad
    FROM public.photo_objet_expected_slots slot
    JOIN public.photo_objet_monitoring_policies p
      ON p.id = slot.monitoring_policy_id
    WHERE p.effective_to IS NULL
      AND p.schedule_version = 'hcm-two-hour-2230-v2'
      AND slot.scheduled_at >= v_cutover_at
      AND (
        slot.status <> 'expected'
        OR slot.attempt_count <> 0
        OR slot.successful_run_id IS NOT NULL
        OR slot.last_failure_class IS NOT NULL
        OR slot.alerted_failure_class IS NOT NULL
        OR slot.alerted_at IS NOT NULL
      );
    IF v_bad <> 0 THEN
      RAISE EXCEPTION 'PHOTO_2220_FUTURE_SLOT_ALREADY_USED: %', v_bad;
    END IF;
  END IF;
END $$;

INSERT INTO public.photo_slot_20260716160000_policy_map (
  old_policy_id,
  new_policy_id,
  store_id,
  old_effective_to,
  timezone,
  grace_minutes,
  final_slot_grace_minutes,
  is_enabled
)
SELECT
  p.id,
  gen_random_uuid(),
  p.store_id,
  p.effective_to,
  p.timezone,
  p.grace_minutes,
  p.final_slot_grace_minutes,
  p.is_enabled
FROM public.photo_objet_monitoring_policies p
WHERE p.effective_to IS NULL
  AND p.schedule_version = 'hcm-two-hour-2230-v2'
ON CONFLICT (old_policy_id) DO NOTHING;

INSERT INTO public.photo_slot_20260716160000_expected_backup
SELECT slot.*
FROM public.photo_objet_expected_slots slot
JOIN public.photo_slot_20260716160000_policy_map mapping
  ON mapping.old_policy_id = slot.monitoring_policy_id
JOIN public.photo_slot_20260716160000_state state
  ON state.migration_id = '20260716160000'
WHERE slot.scheduled_at >= state.cutover_at
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.photo_objet_monitoring_policies
  DROP CONSTRAINT IF EXISTS photo_objet_monitoring_policy_schedule_check;
ALTER TABLE public.photo_objet_monitoring_policies
  ADD CONSTRAINT photo_objet_monitoring_policy_schedule_check CHECK (
    schedule_version IN (
      'hcm-two-hour-v1',
      'hcm-two-hour-2230-v2',
      'hcm-eod-2220-v3'
    )
  );
ALTER TABLE public.photo_objet_monitoring_policies
  ALTER COLUMN schedule_version SET DEFAULT 'hcm-eod-2220-v3';

ALTER TABLE public.photo_objet_expected_slots
  DROP CONSTRAINT IF EXISTS photo_objet_expected_slot_time_check;
ALTER TABLE public.photo_objet_expected_slots
  ADD CONSTRAINT photo_objet_expected_slot_time_check CHECK (
    slot_time_hcm IN (
      TIME '10:00', TIME '12:00', TIME '14:00', TIME '16:00',
      TIME '18:00', TIME '20:00', TIME '22:20', TIME '22:30', TIME '23:00'
    )
  );

UPDATE public.photo_objet_monitoring_policies policy
SET effective_to = state.cutover_at
FROM public.photo_slot_20260716160000_policy_map mapping
CROSS JOIN public.photo_slot_20260716160000_state state
WHERE state.migration_id = '20260716160000'
  AND policy.id = mapping.old_policy_id
  AND policy.effective_to IS NULL;

INSERT INTO public.photo_objet_monitoring_policies (
  id, store_id, effective_from, effective_to, timezone, schedule_version,
  grace_minutes, final_slot_grace_minutes, is_enabled
)
SELECT
  mapping.new_policy_id,
  mapping.store_id,
  state.cutover_at,
  NULL,
  mapping.timezone,
  'hcm-eod-2220-v3',
  mapping.grace_minutes,
  mapping.final_slot_grace_minutes,
  mapping.is_enabled
FROM public.photo_slot_20260716160000_policy_map mapping
CROSS JOIN public.photo_slot_20260716160000_state state
WHERE state.migration_id = '20260716160000'
ON CONFLICT (id) DO NOTHING;

DELETE FROM public.photo_objet_expected_slots slot
USING public.photo_slot_20260716160000_policy_map mapping,
      public.photo_slot_20260716160000_state state
WHERE state.migration_id = '20260716160000'
  AND slot.monitoring_policy_id = mapping.old_policy_id
  AND slot.scheduled_at >= state.cutover_at;

CREATE OR REPLACE FUNCTION public.photo_objet_ensure_expected_slots(
  p_from_date date,
  p_to_date date
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_inserted integer;
BEGIN
  IF p_from_date IS NULL OR p_to_date IS NULL OR p_to_date < p_from_date THEN
    RAISE EXCEPTION 'PHOTO_EXPECTED_SLOT_DATE_RANGE_INVALID';
  END IF;
  IF p_to_date - p_from_date > 92 THEN
    RAISE EXCEPTION 'PHOTO_EXPECTED_SLOT_DATE_RANGE_TOO_LARGE';
  END IF;

  WITH target_dates AS (
    SELECT generate_series(p_from_date, p_to_date, interval '1 day')::date AS slot_date
  ),
  candidates AS (
    SELECT
      p.id AS policy_id,
      p.store_id,
      d.slot_date,
      st.slot_time,
      (d.slot_date + st.slot_time) AT TIME ZONE p.timezone AS scheduled_at,
      (d.slot_date + st.slot_time) AT TIME ZONE p.timezone
        + make_interval(mins => CASE
          WHEN st.slot_time IN (TIME '22:20', TIME '22:30', TIME '23:00')
            THEN p.final_slot_grace_minutes
          ELSE p.grace_minutes
        END) AS due_at
    FROM public.photo_objet_monitoring_policies p
    JOIN public.restaurants r ON r.id = p.store_id AND r.is_active = true
    CROSS JOIN target_dates d
    CROSS JOIN LATERAL unnest(
      CASE p.schedule_version
        WHEN 'hcm-two-hour-v1' THEN ARRAY[
          TIME '10:00', TIME '12:00', TIME '14:00', TIME '16:00',
          TIME '18:00', TIME '20:00', TIME '23:00'
        ]
        WHEN 'hcm-two-hour-2230-v2' THEN ARRAY[
          TIME '10:00', TIME '12:00', TIME '14:00', TIME '16:00',
          TIME '18:00', TIME '20:00', TIME '22:30'
        ]
        WHEN 'hcm-eod-2220-v3' THEN ARRAY[TIME '22:20']
        ELSE ARRAY[]::time[]
      END
    ) st(slot_time)
    WHERE p.is_enabled = true
      AND (d.slot_date + st.slot_time) AT TIME ZONE p.timezone >= p.effective_from
      AND (
        p.effective_to IS NULL
        OR (d.slot_date + st.slot_time) AT TIME ZONE p.timezone < p.effective_to
      )
  )
  INSERT INTO public.photo_objet_expected_slots (
    store_id, slot_date_hcm, slot_time_hcm, scheduled_at, due_at,
    monitoring_policy_id
  )
  SELECT store_id, slot_date, slot_time, scheduled_at, due_at, policy_id
  FROM candidates
  ON CONFLICT (store_id, slot_date_hcm, slot_time_hcm) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  RETURN v_inserted;
END;
$$;

CREATE OR REPLACE FUNCTION public.photo_objet_expected_slot_health_at(
  p_observed_at timestamptz DEFAULT now(),
  p_lookback_days integer DEFAULT 2
)
RETURNS TABLE (
  store_id uuid,
  target_date date,
  policy_expected_slots integer,
  materialized_slots integer,
  coverage_missing_slots integer,
  policy_store_active boolean,
  due_slots integer,
  collected_slots integer,
  collected_zero_slots integer,
  recovered_slots integer,
  missing_slots integer,
  failed_slots integer,
  failure_classes text[],
  latest_due_slot timestamptz,
  status text,
  is_healthy boolean
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH target_dates AS (
    SELECT generate_series(
      (p_observed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date - (p_lookback_days - 1),
      (p_observed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
      interval '1 day'
    )::date AS target_date
    UNION
    SELECT DISTINCT slot.slot_date_hcm
    FROM public.photo_objet_expected_slots slot
    WHERE slot.status IN ('missing', 'failed')
  ),
  policy_candidates AS (
    SELECT
      p.id AS policy_id,
      p.store_id,
      d.target_date,
      st.slot_time,
      r.is_active AS policy_store_active
    FROM public.photo_objet_monitoring_policies p
    JOIN public.restaurants r ON r.id = p.store_id
    CROSS JOIN target_dates d
    CROSS JOIN LATERAL unnest(
      CASE p.schedule_version
        WHEN 'hcm-two-hour-v1' THEN ARRAY[
          TIME '10:00', TIME '12:00', TIME '14:00', TIME '16:00',
          TIME '18:00', TIME '20:00', TIME '23:00'
        ]
        WHEN 'hcm-two-hour-2230-v2' THEN ARRAY[
          TIME '10:00', TIME '12:00', TIME '14:00', TIME '16:00',
          TIME '18:00', TIME '20:00', TIME '22:30'
        ]
        WHEN 'hcm-eod-2220-v3' THEN ARRAY[TIME '22:20']
        ELSE ARRAY[]::time[]
      END
    ) st(slot_time)
    WHERE (
        p.is_enabled = true
        OR EXISTS (
          SELECT 1
          FROM public.photo_objet_expected_slots unresolved
          WHERE unresolved.monitoring_policy_id = p.id
            AND unresolved.slot_date_hcm = d.target_date
            AND unresolved.status IN ('missing', 'failed')
        )
      )
      AND (d.target_date + st.slot_time) AT TIME ZONE p.timezone >= p.effective_from
      AND (
        p.effective_to IS NULL
        OR (d.target_date + st.slot_time) AT TIME ZONE p.timezone < p.effective_to
      )
  )
  SELECT
    c.store_id,
    c.target_date,
    count(*)::integer,
    count(s.id)::integer,
    (count(*) - count(s.id))::integer,
    bool_and(c.policy_store_active),
    count(s.id) FILTER (WHERE s.due_at <= p_observed_at)::integer,
    count(s.id) FILTER (
      WHERE s.due_at <= p_observed_at AND s.status = 'collected'
    )::integer,
    count(s.id) FILTER (
      WHERE s.due_at <= p_observed_at AND s.status = 'collected_zero'
    )::integer,
    count(s.id) FILTER (
      WHERE s.due_at <= p_observed_at AND s.status = 'recovered'
    )::integer,
    count(s.id) FILTER (
      WHERE s.due_at <= p_observed_at
        AND s.status IN ('expected', 'running', 'missing')
    )::integer,
    count(s.id) FILTER (
      WHERE s.due_at <= p_observed_at AND s.status = 'failed'
    )::integer,
    CASE
      WHEN count(s.id) <> count(*) OR bool_and(c.policy_store_active) IS DISTINCT FROM true
        THEN array_prepend(
          'AUDIT_INFRA_FAILED'::text,
          coalesce(array_agg(DISTINCT s.last_failure_class ORDER BY s.last_failure_class)
            FILTER (
              WHERE s.due_at <= p_observed_at
                AND s.status IN ('missing', 'failed')
                AND s.last_failure_class IS NOT NULL
            ), ARRAY[]::text[])
        )
      ELSE coalesce(array_agg(DISTINCT s.last_failure_class ORDER BY s.last_failure_class)
        FILTER (
          WHERE s.due_at <= p_observed_at
            AND s.status IN ('missing', 'failed')
            AND s.last_failure_class IS NOT NULL
        ), ARRAY[]::text[])
    END,
    max(s.scheduled_at) FILTER (WHERE s.due_at <= p_observed_at),
    CASE
      WHEN bool_and(c.policy_store_active) IS DISTINCT FROM true THEN 'audit_infra_failed'
      WHEN count(s.id) <> count(*) THEN 'audit_infra_failed'
      WHEN count(s.id) FILTER (WHERE s.due_at <= p_observed_at) = 0 THEN 'not_due'
      WHEN count(s.id) FILTER (
        WHERE s.due_at <= p_observed_at AND s.status = 'failed'
      ) > 0 THEN 'failed'
      WHEN count(s.id) FILTER (
        WHERE s.due_at <= p_observed_at
          AND s.status IN ('expected', 'running', 'missing')
      ) > 0 THEN 'missing'
      ELSE 'healthy'
    END,
    bool_and(c.policy_store_active)
      AND count(s.id) = count(*)
      AND count(s.id) FILTER (WHERE s.due_at <= p_observed_at) > 0
      AND count(s.id) FILTER (
        WHERE s.due_at <= p_observed_at
          AND s.status IN ('expected', 'running', 'missing', 'failed')
      ) = 0
  FROM policy_candidates c
  LEFT JOIN public.photo_objet_expected_slots s
    ON s.monitoring_policy_id = c.policy_id
   AND s.store_id = c.store_id
   AND s.slot_date_hcm = c.target_date
   AND s.slot_time_hcm = c.slot_time
  GROUP BY c.policy_id, c.store_id, c.target_date
$$;

DO $$
DECLARE
  v_from date;
  v_to date;
BEGIN
  SELECT
    state.cutover_date,
    greatest(
      state.cutover_date + 2,
      coalesce(max(backup.slot_date_hcm), state.cutover_date)
    )
  INTO STRICT v_from, v_to
  FROM public.photo_slot_20260716160000_state state
  LEFT JOIN public.photo_slot_20260716160000_expected_backup backup ON true
  WHERE state.migration_id = '20260716160000'
  GROUP BY state.cutover_date;

  PERFORM public.photo_objet_ensure_expected_slots(v_from, v_to);
END $$;

COMMENT ON FUNCTION public.photo_objet_ensure_expected_slots(date, date) IS
  'Materializes historical v1/v2 intervals and one 22:20 HCM slot for v3.';
COMMENT ON TABLE public.photo_slot_20260716160000_state IS
  'Owner-only rollback evidence for the Photo Objet single 22:20 transition.';
