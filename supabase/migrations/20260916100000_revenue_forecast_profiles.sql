BEGIN;

CREATE TABLE IF NOT EXISTS public.revenue_forecast_profile_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE RESTRICT,
  revision bigint NOT NULL CHECK (revision > 0),
  model_type text NOT NULL CHECK (model_type IN ('restaurant', 'photo')),
  schema_version integer NOT NULL DEFAULT 1 CHECK (schema_version = 1),
  settings jsonb NOT NULL CHECK (jsonb_typeof(settings) = 'object'),
  effective_from timestamptz NOT NULL DEFAULT now(),
  effective_to timestamptz,
  created_by uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT revenue_forecast_profile_revision_unique
    UNIQUE (restaurant_id, revision),
  CONSTRAINT revenue_forecast_profile_effective_range_check
    CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

CREATE UNIQUE INDEX IF NOT EXISTS revenue_forecast_profile_current_unique
  ON public.revenue_forecast_profile_versions (restaurant_id)
  WHERE effective_to IS NULL;

CREATE INDEX IF NOT EXISTS revenue_forecast_profile_lookup_idx
  ON public.revenue_forecast_profile_versions
  (restaurant_id, effective_from DESC);

ALTER TABLE public.revenue_forecast_profile_versions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS revenue_forecast_profile_accessible_read
  ON public.revenue_forecast_profile_versions;
CREATE POLICY revenue_forecast_profile_accessible_read
  ON public.revenue_forecast_profile_versions
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.users actor
      WHERE actor.auth_id = (SELECT auth.uid())
        AND actor.is_active = true
        AND actor.role IN ('brand_admin', 'photo_objet_master', 'super_admin')
        AND (
          actor.role = 'super_admin'
          OR EXISTS (
            SELECT 1
            FROM public.user_accessible_stores((SELECT auth.uid())) scope(store_id)
            WHERE scope.store_id = restaurant_id
          )
        )
    )
  );

REVOKE ALL ON public.revenue_forecast_profile_versions FROM anon, authenticated;
GRANT SELECT ON public.revenue_forecast_profile_versions TO authenticated;

CREATE OR REPLACE FUNCTION public.get_revenue_forecast_profile(
  p_store_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'FORECAST_AUTH_REQUIRED';
  END IF;
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'FORECAST_STORE_REQUIRED';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.users actor
    WHERE actor.auth_id = auth.uid()
      AND actor.is_active = true
      AND actor.role IN ('brand_admin', 'photo_objet_master', 'super_admin')
  ) THEN
    RAISE EXCEPTION 'FORECAST_READ_FORBIDDEN';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.user_accessible_stores(auth.uid()) scope(store_id)
    WHERE scope.store_id = p_store_id
  ) AND NOT EXISTS (
    SELECT 1
    FROM public.users actor
    WHERE actor.auth_id = auth.uid()
      AND actor.is_active = true
      AND actor.role = 'super_admin'
  ) THEN
    RAISE EXCEPTION 'FORECAST_READ_FORBIDDEN';
  END IF;

  SELECT jsonb_build_object(
    'store_id', profile.restaurant_id,
    'revision', profile.revision,
    'model_type', profile.model_type,
    'schema_version', profile.schema_version,
    'settings', profile.settings,
    'effective_from', profile.effective_from
  )
  INTO v_result
  FROM public.revenue_forecast_profile_versions profile
  WHERE profile.restaurant_id = p_store_id
    AND profile.effective_to IS NULL
  ORDER BY profile.revision DESC
  LIMIT 1;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.save_revenue_forecast_profile(
  p_store_id uuid,
  p_expected_revision bigint,
  p_model_type text,
  p_settings jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_current_revision bigint;
  v_next_revision bigint;
  v_now timestamptz := clock_timestamp();
  v_floor jsonb;
  v_machine_capacity integer;
  v_store_brand_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'FORECAST_AUTH_REQUIRED';
  END IF;
  SELECT actor.*
  INTO v_actor
  FROM public.users actor
  WHERE actor.auth_id = auth.uid()
    AND actor.is_active = true
    AND actor.role IN (
      'brand_admin', 'photo_objet_master', 'super_admin'
    )
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FORECAST_PROFILE_WRITE_FORBIDDEN';
  END IF;
  IF v_actor.role <> 'super_admin' AND NOT EXISTS (
    SELECT 1
    FROM public.user_accessible_stores(auth.uid()) scope(store_id)
    WHERE scope.store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'FORECAST_PROFILE_WRITE_FORBIDDEN';
  END IF;
  IF p_expected_revision IS NULL OR p_expected_revision < 0 THEN
    RAISE EXCEPTION 'FORECAST_EXPECTED_REVISION_REQUIRED';
  END IF;
  IF p_model_type NOT IN ('restaurant', 'photo') THEN
    RAISE EXCEPTION 'FORECAST_MODEL_TYPE_INVALID';
  END IF;
  IF p_settings IS NULL OR jsonb_typeof(p_settings) <> 'object' THEN
    RAISE EXCEPTION 'FORECAST_SETTINGS_INVALID';
  END IF;
  IF NOT p_settings ? 'operating_weekdays'
    OR jsonb_typeof(p_settings->'operating_weekdays') <> 'array'
    OR jsonb_array_length(p_settings->'operating_weekdays') = 0
    OR EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_settings->'operating_weekdays') weekday(value)
      WHERE jsonb_typeof(weekday.value) <> 'number'
        OR weekday.value::text !~ '^[1-7]$'
    )
    OR (
      SELECT count(*)
      FROM jsonb_array_elements_text(p_settings->'operating_weekdays') weekday(value)
    ) <> (
      SELECT count(DISTINCT weekday.value)
      FROM jsonb_array_elements_text(p_settings->'operating_weekdays') weekday(value)
    ) THEN
    RAISE EXCEPTION 'FORECAST_OPERATING_WEEKDAYS_INVALID';
  END IF;

  SELECT store.brand_id
  INTO v_store_brand_id
  FROM public.restaurants store
  WHERE store.id = p_store_id
    AND store.is_active = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FORECAST_STORE_NOT_FOUND';
  END IF;
  IF (v_store_brand_id = '77000000-0000-0000-0000-000000000001'::uuid)
    <> (p_model_type = 'photo') THEN
    RAISE EXCEPTION 'FORECAST_MODEL_STORE_MISMATCH';
  END IF;

  IF p_model_type = 'restaurant' THEN
    IF NOT p_settings ?& ARRAY[
      'floors', 'seated_to_first_serve_minutes', 'dining_minutes',
      'payment_wait_minutes', 'cleanup_minutes', 'kitchen_units_per_hour',
      'checker_units_per_hour', 'operating_minutes_per_day',
      'average_ticket_vnd'
    ] OR jsonb_typeof(p_settings->'floors') <> 'array'
      OR jsonb_array_length(p_settings->'floors') = 0
      OR (p_settings->>'seated_to_first_serve_minutes')::numeric < 0
      OR (p_settings->>'dining_minutes')::numeric <= 0
      OR (p_settings->>'payment_wait_minutes')::numeric < 0
      OR (p_settings->>'cleanup_minutes')::numeric < 0
      OR (p_settings->>'kitchen_units_per_hour')::numeric <= 0
      OR (p_settings->>'checker_units_per_hour')::numeric <= 0
      OR (p_settings->>'operating_minutes_per_day')::integer <= 0
      OR (p_settings->>'operating_minutes_per_day')::integer > 1440
      OR (p_settings->>'average_ticket_vnd')::numeric <= 0 THEN
      RAISE EXCEPTION 'FORECAST_RESTAURANT_SETTINGS_INVALID';
    END IF;
    FOR v_floor IN
      SELECT value FROM jsonb_array_elements(p_settings->'floors')
    LOOP
      IF jsonb_typeof(v_floor) <> 'object'
        OR NOT v_floor ?& ARRAY['label', 'table_count', 'service_units_per_hour']
        OR btrim(v_floor->>'label') = ''
        OR (v_floor->>'table_count')::integer <= 0
        OR (v_floor->>'service_units_per_hour')::numeric <= 0 THEN
        RAISE EXCEPTION 'FORECAST_RESTAURANT_FLOOR_INVALID';
      END IF;
    END LOOP;
  ELSE
    IF NOT p_settings ?& ARRAY[
      'machine_count', 'operating_minutes_per_day',
      'free_service_sessions_per_day'
    ] OR (p_settings->>'machine_count')::integer <= 0
      OR (p_settings->>'operating_minutes_per_day')::integer <= 0
      OR (p_settings->>'operating_minutes_per_day')::integer > 1440
      OR (p_settings->>'free_service_sessions_per_day')::integer < 0 THEN
      RAISE EXCEPTION 'FORECAST_PHOTO_SETTINGS_INVALID';
    END IF;
    v_machine_capacity := (p_settings->>'machine_count')::integer
      * floor((p_settings->>'operating_minutes_per_day')::numeric / 8)::integer;
    IF (p_settings->>'free_service_sessions_per_day')::integer
      > v_machine_capacity THEN
      RAISE EXCEPTION 'FORECAST_PHOTO_SERVICE_EXCEEDS_CAPACITY';
    END IF;
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('revenue-forecast-profile:' || p_store_id::text, 0)
  );

  SELECT profile.revision
  INTO v_current_revision
  FROM public.revenue_forecast_profile_versions profile
  WHERE profile.restaurant_id = p_store_id
    AND profile.effective_to IS NULL
  FOR UPDATE;

  IF COALESCE(v_current_revision, 0) <> p_expected_revision THEN
    RAISE EXCEPTION 'FORECAST_PROFILE_CONFLICT';
  END IF;

  v_next_revision := COALESCE(v_current_revision, 0) + 1;
  UPDATE public.revenue_forecast_profile_versions
  SET effective_to = v_now
  WHERE restaurant_id = p_store_id
    AND effective_to IS NULL;

  INSERT INTO public.revenue_forecast_profile_versions (
    restaurant_id,
    revision,
    model_type,
    schema_version,
    settings,
    effective_from,
    created_by
  ) VALUES (
    p_store_id,
    v_next_revision,
    p_model_type,
    1,
    p_settings,
    v_now,
    v_actor.id
  );

  RETURN jsonb_build_object(
    'store_id', p_store_id,
    'revision', v_next_revision,
    'model_type', p_model_type,
    'schema_version', 1,
    'settings', p_settings,
    'effective_from', v_now
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_revenue_forecast_profile(uuid)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.save_revenue_forecast_profile(
  uuid, bigint, text, jsonb
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_revenue_forecast_profile(uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_revenue_forecast_profile(
  uuid, bigint, text, jsonb
) TO authenticated;

COMMIT;
