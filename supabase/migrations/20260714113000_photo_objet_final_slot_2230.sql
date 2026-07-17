-- Move only the final Photo Objet collection slot from 23:00 to 22:30 HCM.
-- Historical v1 expectations remain valid. The cutover starts at midnight on
-- the HCM date when this migration is applied, and Moers raw rows are never
-- mutated.

CREATE TABLE IF NOT EXISTS public.photo_slot_20260714113000_state (
  migration_id text PRIMARY KEY,
  cutover_date date NOT NULL,
  cutover_at timestamptz NOT NULL,
  prior_schedule_default text,
  prior_schedule_constraint_definition text NOT NULL,
  prior_slot_constraint_definition text NOT NULL,
  prior_ensure_function_definition text NOT NULL,
  prior_health_function_definition text NOT NULL,
  raw_row_count bigint NOT NULL,
  raw_fingerprint text NOT NULL,
  policy_map_row_count bigint,
  policy_map_fingerprint text,
  expected_backup_row_count bigint,
  expected_backup_fingerprint text,
  captured_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.photo_slot_20260714113000_state
  ADD COLUMN IF NOT EXISTS policy_map_row_count bigint,
  ADD COLUMN IF NOT EXISTS policy_map_fingerprint text,
  ADD COLUMN IF NOT EXISTS expected_backup_row_count bigint,
  ADD COLUMN IF NOT EXISTS expected_backup_fingerprint text;

CREATE TABLE IF NOT EXISTS public.photo_slot_20260714113000_policy_map (
  old_policy_id uuid PRIMARY KEY,
  new_policy_id uuid NOT NULL UNIQUE,
  store_id uuid NOT NULL,
  reuse_policy boolean NOT NULL,
  old_effective_from timestamptz NOT NULL,
  old_effective_to timestamptz,
  timezone text NOT NULL,
  grace_minutes integer NOT NULL,
  final_slot_grace_minutes integer NOT NULL,
  is_enabled boolean NOT NULL
);

CREATE TABLE IF NOT EXISTS public.photo_slot_20260714113000_expected_backup (
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

CREATE TABLE IF NOT EXISTS public.photo_slot_20260714113000_raw_identity_backup (
  id uuid PRIMARY KEY,
  store_id uuid NOT NULL,
  source_hash text NOT NULL
);

REVOKE ALL ON public.photo_slot_20260714113000_state
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON public.photo_slot_20260714113000_policy_map
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON public.photo_slot_20260714113000_expected_backup
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON public.photo_slot_20260714113000_raw_identity_backup
  FROM PUBLIC, anon, authenticated, service_role;

ALTER TABLE public.photo_slot_20260714113000_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_slot_20260714113000_policy_map ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_slot_20260714113000_expected_backup ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_slot_20260714113000_raw_identity_backup ENABLE ROW LEVEL SECURITY;

INSERT INTO public.photo_slot_20260714113000_state (
  migration_id,
  cutover_date,
  cutover_at,
  prior_schedule_default,
  prior_schedule_constraint_definition,
  prior_slot_constraint_definition,
  prior_ensure_function_definition,
  prior_health_function_definition,
  raw_row_count,
  raw_fingerprint
)
SELECT
  '20260714113000',
  cutover.cutover_date,
  cutover.cutover_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh',
  (
    SELECT pg_get_expr(d.adbin, d.adrelid)
    FROM pg_attribute a
    JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    WHERE a.attrelid = 'public.photo_objet_monitoring_policies'::regclass
      AND a.attname = 'schedule_version'
      AND NOT a.attisdropped
  ),
  (
    SELECT pg_get_constraintdef(c.oid, true)
    FROM pg_constraint c
    WHERE c.conrelid = 'public.photo_objet_monitoring_policies'::regclass
      AND c.conname = 'photo_objet_monitoring_policy_schedule_check'
  ),
  (
    SELECT pg_get_constraintdef(c.oid, true)
    FROM pg_constraint c
    WHERE c.conrelid = 'public.photo_objet_expected_slots'::regclass
      AND c.conname = 'photo_objet_expected_slot_time_check'
  ),
  pg_get_functiondef(
    'public.photo_objet_ensure_expected_slots(date,date)'::regprocedure
  ),
  pg_get_functiondef(
    'public.photo_objet_expected_slot_health_at(timestamp with time zone,integer)'::regprocedure
  ),
  raw_state.row_count,
  raw_state.fingerprint
FROM (
  SELECT coalesce(
    nullif(current_setting('app.photo_objet_final_slot_cutover_date', true), '')::date,
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
  ) AS cutover_date
) cutover
CROSS JOIN LATERAL (
  SELECT
    count(*)::bigint AS row_count,
    md5(coalesce(string_agg(
      raw.id::text || ':' || raw.store_id::text || ':' || raw.source_hash,
      '|' ORDER BY raw.id
    ), '')) AS fingerprint
  FROM public.photo_objet_sales_raw raw
) raw_state
ON CONFLICT (migration_id) DO NOTHING;

INSERT INTO public.photo_slot_20260714113000_raw_identity_backup (
  id, store_id, source_hash
)
SELECT raw.id, raw.store_id, raw.source_hash
FROM public.photo_objet_sales_raw raw
WHERE NOT EXISTS (
  SELECT 1 FROM public.photo_slot_20260714113000_raw_identity_backup
)
ON CONFLICT (id) DO NOTHING;

DO $$
DECLARE
  v_cutover_at timestamptz;
  v_bad integer;
BEGIN
  SELECT cutover_at INTO STRICT v_cutover_at
  FROM public.photo_slot_20260714113000_state
  WHERE migration_id = '20260714113000';

  IF NOT EXISTS (
    SELECT 1
    FROM public.photo_objet_monitoring_policies
    WHERE effective_to IS NULL
      AND schedule_version = 'hcm-two-hour-v1'
  ) AND NOT EXISTS (
    SELECT 1 FROM public.photo_slot_20260714113000_policy_map
  ) THEN
    RAISE EXCEPTION 'PHOTO_2230_OPEN_V1_POLICY_MISSING';
  END IF;

  SELECT count(*) INTO v_bad
  FROM public.photo_objet_monitoring_policies p
  JOIN public.restaurants r ON r.id = p.store_id
  WHERE p.effective_to IS NULL
    AND p.schedule_version = 'hcm-two-hour-v1'
    AND (
      p.effective_from > v_cutover_at
      OR p.is_enabled IS DISTINCT FROM true
      OR r.is_active IS DISTINCT FROM true
      OR p.timezone <> 'Asia/Ho_Chi_Minh'
      OR p.grace_minutes <> 90
      OR p.final_slot_grace_minutes <> 90
    );
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'PHOTO_2230_POLICY_PREFLIGHT_FAILED: %', v_bad;
  END IF;

  SELECT count(*) INTO v_bad
  FROM public.photo_objet_expected_slots slot
  JOIN public.photo_objet_monitoring_policies p
    ON p.id = slot.monitoring_policy_id
  WHERE p.effective_to IS NULL
    AND p.schedule_version = 'hcm-two-hour-v1'
    AND slot.slot_date_hcm >= (v_cutover_at AT TIME ZONE p.timezone)::date
    AND slot.slot_time_hcm = TIME '23:00'
    AND (
      slot.status <> 'expected'
      OR slot.attempt_count <> 0
      OR slot.successful_run_id IS NOT NULL
      OR slot.last_failure_class IS NOT NULL
      OR slot.alerted_failure_class IS NOT NULL
      OR slot.alerted_at IS NOT NULL
    );
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'PHOTO_2230_LEGACY_SLOT_ALREADY_USED: %', v_bad;
  END IF;
END $$;

INSERT INTO public.photo_slot_20260714113000_policy_map (
  old_policy_id,
  new_policy_id,
  store_id,
  reuse_policy,
  old_effective_from,
  old_effective_to,
  timezone,
  grace_minutes,
  final_slot_grace_minutes,
  is_enabled
)
SELECT
  p.id,
  CASE WHEN p.effective_from = state.cutover_at THEN p.id ELSE gen_random_uuid() END,
  p.store_id,
  p.effective_from = state.cutover_at,
  p.effective_from,
  p.effective_to,
  p.timezone,
  p.grace_minutes,
  p.final_slot_grace_minutes,
  p.is_enabled
FROM public.photo_objet_monitoring_policies p
CROSS JOIN public.photo_slot_20260714113000_state state
WHERE state.migration_id = '20260714113000'
  AND p.effective_to IS NULL
  AND p.schedule_version = 'hcm-two-hour-v1'
ON CONFLICT (old_policy_id) DO NOTHING;

INSERT INTO public.photo_slot_20260714113000_expected_backup (
  id, store_id, slot_date_hcm, slot_time_hcm, scheduled_at, due_at,
  monitoring_policy_id, status, successful_run_id, attempt_count,
  last_failure_class, alerted_failure_class, alerted_at, created_at, updated_at
)
SELECT
  slot.id, slot.store_id, slot.slot_date_hcm, slot.slot_time_hcm,
  slot.scheduled_at, slot.due_at, slot.monitoring_policy_id, slot.status,
  slot.successful_run_id, slot.attempt_count, slot.last_failure_class,
  slot.alerted_failure_class, slot.alerted_at, slot.created_at, slot.updated_at
FROM public.photo_objet_expected_slots slot
JOIN public.photo_slot_20260714113000_policy_map mapping
  ON mapping.old_policy_id = slot.monitoring_policy_id
CROSS JOIN public.photo_slot_20260714113000_state state
WHERE state.migration_id = '20260714113000'
  AND slot.slot_date_hcm >= state.cutover_date
  AND NOT EXISTS (
    SELECT 1 FROM public.photo_slot_20260714113000_expected_backup
  )
ON CONFLICT (id) DO NOTHING;

WITH policy_evidence AS (
  SELECT
    count(*)::bigint AS row_count,
    md5(coalesce(string_agg(
      to_jsonb(mapping)::text,
      '|' ORDER BY mapping.old_policy_id
    ), '')) AS fingerprint
  FROM public.photo_slot_20260714113000_policy_map mapping
), expected_evidence AS (
  SELECT
    count(*)::bigint AS row_count,
    md5(coalesce(string_agg(
      to_jsonb(backup)::text,
      '|' ORDER BY backup.id
    ), '')) AS fingerprint
  FROM public.photo_slot_20260714113000_expected_backup backup
)
UPDATE public.photo_slot_20260714113000_state state
SET policy_map_row_count = policy_evidence.row_count,
    policy_map_fingerprint = policy_evidence.fingerprint,
    expected_backup_row_count = expected_evidence.row_count,
    expected_backup_fingerprint = expected_evidence.fingerprint
FROM policy_evidence, expected_evidence
WHERE state.migration_id = '20260714113000'
  AND state.policy_map_row_count IS NULL
  AND state.policy_map_fingerprint IS NULL
  AND state.expected_backup_row_count IS NULL
  AND state.expected_backup_fingerprint IS NULL;

ALTER TABLE public.photo_objet_monitoring_policies
  DROP CONSTRAINT photo_objet_monitoring_policy_schedule_check;
ALTER TABLE public.photo_objet_monitoring_policies
  ADD CONSTRAINT photo_objet_monitoring_policy_schedule_check CHECK (
    schedule_version IN ('hcm-two-hour-v1', 'hcm-two-hour-2230-v2')
  );
ALTER TABLE public.photo_objet_monitoring_policies
  ALTER COLUMN schedule_version SET DEFAULT 'hcm-two-hour-2230-v2';

ALTER TABLE public.photo_objet_expected_slots
  DROP CONSTRAINT photo_objet_expected_slot_time_check;
ALTER TABLE public.photo_objet_expected_slots
  ADD CONSTRAINT photo_objet_expected_slot_time_check CHECK (
    slot_time_hcm IN (
      TIME '10:00', TIME '12:00', TIME '14:00', TIME '16:00',
      TIME '18:00', TIME '20:00', TIME '22:30', TIME '23:00'
    )
  );

UPDATE public.photo_objet_monitoring_policies policy
SET schedule_version = 'hcm-two-hour-2230-v2'
FROM public.photo_slot_20260714113000_policy_map mapping
WHERE mapping.reuse_policy = true
  AND policy.id = mapping.old_policy_id;

UPDATE public.photo_objet_monitoring_policies policy
SET effective_to = state.cutover_at
FROM public.photo_slot_20260714113000_policy_map mapping
CROSS JOIN public.photo_slot_20260714113000_state state
WHERE state.migration_id = '20260714113000'
  AND mapping.reuse_policy = false
  AND policy.id = mapping.old_policy_id;

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
  'hcm-two-hour-2230-v2',
  mapping.grace_minutes,
  mapping.final_slot_grace_minutes,
  mapping.is_enabled
FROM public.photo_slot_20260714113000_policy_map mapping
CROSS JOIN public.photo_slot_20260714113000_state state
WHERE state.migration_id = '20260714113000'
  AND mapping.reuse_policy = false
ON CONFLICT (id) DO NOTHING;

UPDATE public.photo_objet_expected_slots slot
SET monitoring_policy_id = mapping.new_policy_id
FROM public.photo_slot_20260714113000_policy_map mapping
CROSS JOIN public.photo_slot_20260714113000_state state
WHERE state.migration_id = '20260714113000'
  AND slot.monitoring_policy_id = mapping.old_policy_id
  AND slot.slot_date_hcm >= state.cutover_date
  AND slot.slot_time_hcm <> TIME '23:00';

DELETE FROM public.photo_objet_expected_slots slot
USING public.photo_slot_20260714113000_policy_map mapping,
      public.photo_slot_20260714113000_state state
WHERE state.migration_id = '20260714113000'
  AND slot.monitoring_policy_id IN (mapping.old_policy_id, mapping.new_policy_id)
  AND slot.slot_date_hcm >= state.cutover_date
  AND slot.slot_time_hcm = TIME '23:00';

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
          WHEN st.slot_time IN (TIME '22:30', TIME '23:00')
            THEN p.final_slot_grace_minutes
          ELSE p.grace_minutes
        END) AS due_at
    FROM public.photo_objet_monitoring_policies p
    JOIN public.restaurants r ON r.id = p.store_id AND r.is_active = true
    CROSS JOIN target_dates d
    CROSS JOIN LATERAL (
      VALUES
        (TIME '10:00'), (TIME '12:00'), (TIME '14:00'), (TIME '16:00'),
        (TIME '18:00'), (TIME '20:00'),
        (CASE p.schedule_version
          WHEN 'hcm-two-hour-v1' THEN TIME '23:00'
          WHEN 'hcm-two-hour-2230-v2' THEN TIME '22:30'
        END)
    ) st(slot_time)
    WHERE p.is_enabled = true
      AND st.slot_time IS NOT NULL
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
    CROSS JOIN LATERAL (
      VALUES
        (TIME '10:00'), (TIME '12:00'), (TIME '14:00'), (TIME '16:00'),
        (TIME '18:00'), (TIME '20:00'),
        (CASE p.schedule_version
          WHEN 'hcm-two-hour-v1' THEN TIME '23:00'
          WHEN 'hcm-two-hour-2230-v2' THEN TIME '22:30'
        END)
    ) st(slot_time)
    WHERE st.slot_time IS NOT NULL
      AND (
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
  SELECT state.cutover_date,
    greatest(
      state.cutover_date,
      coalesce(max(backup.slot_date_hcm), state.cutover_date)
    )
  INTO STRICT v_from, v_to
  FROM public.photo_slot_20260714113000_state state
  LEFT JOIN public.photo_slot_20260714113000_expected_backup backup ON true
  WHERE state.migration_id = '20260714113000'
  GROUP BY state.cutover_date;

  PERFORM public.photo_objet_ensure_expected_slots(v_from, v_to);
END $$;

COMMENT ON FUNCTION public.photo_objet_ensure_expected_slots(date, date) IS
  'Materializes effective-dated Photo Objet slots: v1 ends at 23:00; v2 ends at 22:30 HCM.';
COMMENT ON TABLE public.photo_slot_20260714113000_state IS
  'Owner-only rollback evidence for the Photo Objet 22:30 final-slot transition.';
