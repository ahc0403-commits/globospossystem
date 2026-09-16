-- Store-controlled QR takeout availability.
--
-- Existing active stores are paused immediately for the current promotion and
-- automatically become effective again at 2026-09-20 00:00 Asia/Ho_Chi_Minh.
-- BM/admin users can subsequently enable, disable, or reschedule the control.
-- production-gate: self-verifying

BEGIN;

ALTER TABLE public.restaurants
  ADD COLUMN IF NOT EXISTS qr_takeout_enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS qr_takeout_resume_at timestamptz;

COMMENT ON COLUMN public.restaurants.qr_takeout_enabled IS
  'BM-controlled QR order-time takeout switch. False may be paired with qr_takeout_resume_at.';
COMMENT ON COLUMN public.restaurants.qr_takeout_resume_at IS
  'Optional instant when a disabled QR takeout switch becomes effective again.';

-- 2026-09-20 00:00 in Vietnam is 2026-09-19 17:00 UTC. The effective checks
-- below make a deployment after that instant a no-op from the customer view.
UPDATE public.restaurants
SET qr_takeout_enabled = false,
    qr_takeout_resume_at = timestamptz '2026-09-20 00:00:00+07'
WHERE is_active = true
  AND qr_takeout_enabled = true
  AND qr_takeout_resume_at IS NULL;

CREATE OR REPLACE FUNCTION public.get_qr_takeout_availability(
  p_store_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_store public.restaurants%ROWTYPE;
  v_effective boolean;
BEGIN
  PERFORM public.require_pos_admin_actor_for_store(
    p_store_id,
    'QR_TAKEOUT_SETTING_FORBIDDEN'
  );

  SELECT * INTO v_store
  FROM public.restaurants restaurant
  WHERE restaurant.id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RESTAURANT_NOT_FOUND';
  END IF;

  v_effective := v_store.qr_takeout_enabled
    OR (
      v_store.qr_takeout_resume_at IS NOT NULL
      AND now() >= v_store.qr_takeout_resume_at
    );

  RETURN jsonb_build_object(
    'store_id', v_store.id,
    'configured_enabled', v_store.qr_takeout_enabled,
    'effective_enabled', v_effective,
    'resume_at', v_store.qr_takeout_resume_at,
    'server_now', now()
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.set_qr_takeout_availability(
  p_store_id uuid,
  p_enabled boolean,
  p_resume_at timestamptz DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_store public.restaurants%ROWTYPE;
  v_previous_enabled boolean;
  v_previous_resume_at timestamptz;
  v_effective boolean;
BEGIN
  PERFORM public.require_pos_admin_actor_for_store(
    p_store_id,
    'QR_TAKEOUT_SETTING_FORBIDDEN'
  );

  IF p_enabled IS NULL THEN
    RAISE EXCEPTION 'QR_TAKEOUT_SETTING_INVALID';
  END IF;
  IF p_enabled AND p_resume_at IS NOT NULL THEN
    RAISE EXCEPTION 'QR_TAKEOUT_RESUME_REQUIRES_DISABLED';
  END IF;
  IF NOT p_enabled AND p_resume_at IS NOT NULL AND p_resume_at <= now() THEN
    RAISE EXCEPTION 'QR_TAKEOUT_RESUME_MUST_BE_FUTURE';
  END IF;

  SELECT * INTO v_store
  FROM public.restaurants restaurant
  WHERE restaurant.id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RESTAURANT_NOT_FOUND';
  END IF;

  v_previous_enabled := v_store.qr_takeout_enabled;
  v_previous_resume_at := v_store.qr_takeout_resume_at;

  IF v_previous_enabled IS DISTINCT FROM p_enabled
     OR v_previous_resume_at IS DISTINCT FROM p_resume_at THEN
    UPDATE public.restaurants
    SET qr_takeout_enabled = p_enabled,
        qr_takeout_resume_at = p_resume_at
    WHERE id = p_store_id
    RETURNING * INTO v_store;

    INSERT INTO public.audit_logs (
      actor_id,
      action,
      entity_type,
      entity_id,
      details
    ) VALUES (
      auth.uid(),
      'qr_takeout_availability_changed',
      'restaurants',
      p_store_id,
      jsonb_build_object(
        'store_id', p_store_id,
        'previous_enabled', v_previous_enabled,
        'previous_resume_at', v_previous_resume_at,
        'enabled', p_enabled,
        'resume_at', p_resume_at
      )
    );

    -- The generic restaurants trigger emits the authenticated settings event.
    -- This additional payload-free menu invalidation reaches anonymous QR tabs.
    INSERT INTO public.pos_live_events (
      restaurant_id,
      domain,
      source_table,
      event_type
    ) VALUES (
      p_store_id,
      'menu',
      'restaurants',
      'UPDATE'
    );
  END IF;

  v_effective := v_store.qr_takeout_enabled
    OR (
      v_store.qr_takeout_resume_at IS NOT NULL
      AND now() >= v_store.qr_takeout_resume_at
    );

  RETURN jsonb_build_object(
    'store_id', v_store.id,
    'configured_enabled', v_store.qr_takeout_enabled,
    'effective_enabled', v_effective,
    'resume_at', v_store.qr_takeout_resume_at,
    'server_now', now()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_qr_takeout_availability(uuid)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_qr_takeout_availability(uuid, boolean, timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_qr_takeout_availability(uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_qr_takeout_availability(uuid, boolean, timestamptz)
  TO authenticated, service_role;

-- Preserve the latest menu implementation and append only the new public flag.
ALTER FUNCTION public.qr_get_menu(text)
  RENAME TO qr_get_menu_pre_takeout_availability;

REVOKE ALL ON FUNCTION public.qr_get_menu_pre_takeout_availability(text)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.qr_get_menu(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_payload jsonb;
  v_store public.restaurants%ROWTYPE;
  v_effective boolean;
BEGIN
  v_payload := public.qr_get_menu_pre_takeout_availability(p_token);

  SELECT * INTO v_store
  FROM public.restaurants restaurant
  WHERE restaurant.id = NULLIF(v_payload->>'store_id', '')::uuid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QR_TOKEN_INVALID';
  END IF;

  v_effective := v_store.qr_takeout_enabled
    OR (
      v_store.qr_takeout_resume_at IS NOT NULL
      AND now() >= v_store.qr_takeout_resume_at
    );

  RETURN v_payload || jsonb_build_object('takeout_enabled', v_effective);
END;
$$;

REVOKE ALL ON FUNCTION public.qr_get_menu(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qr_get_menu(text)
  TO anon, authenticated, service_role;

-- Guard the only customer-executable order overload. Trusted legacy overloads
-- remain service-role-only under the preceding QR display-reset migration.
ALTER FUNCTION public.qr_place_order(text, jsonb, uuid, boolean, uuid)
  RENAME TO qr_place_order_pre_takeout_availability;

REVOKE ALL ON FUNCTION public.qr_place_order_pre_takeout_availability(
  text, jsonb, uuid, boolean, uuid
) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.qr_place_order(
  p_token text,
  p_items jsonb,
  p_client_order_id uuid,
  p_validate_combo_choices boolean,
  p_expected_order_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_takeout_requested boolean := false;
  v_takeout_enabled boolean;
BEGIN
  IF jsonb_typeof(p_items) = 'array' THEN
    SELECT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_items) line(raw)
      WHERE line.raw->'is_takeout' = 'true'::jsonb
    ) INTO v_takeout_requested;
  END IF;

  IF v_takeout_requested THEN
    SELECT (
      restaurant.qr_takeout_enabled
      OR (
        restaurant.qr_takeout_resume_at IS NOT NULL
        AND now() >= restaurant.qr_takeout_resume_at
      )
    )
    INTO v_takeout_enabled
    FROM public.table_qr_tokens qr
    JOIN public.tables table_row
      ON table_row.id = qr.table_id
     AND table_row.restaurant_id = qr.restaurant_id
    JOIN public.restaurants restaurant
      ON restaurant.id = qr.restaurant_id
     AND restaurant.is_active = true
    WHERE qr.token = NULLIF(btrim(COALESCE(p_token, '')), '')
      AND qr.is_active = true;

    IF FOUND AND NOT COALESCE(v_takeout_enabled, false) THEN
      RAISE EXCEPTION 'QR_TAKEOUT_UNAVAILABLE';
    END IF;
  END IF;

  RETURN public.qr_place_order_pre_takeout_availability(
    p_token,
    p_items,
    p_client_order_id,
    p_validate_combo_choices,
    p_expected_order_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.qr_place_order(
  text, jsonb, uuid, boolean, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qr_place_order(
  text, jsonb, uuid, boolean, uuid
) TO anon, authenticated, service_role;

-- Wake already-open QR menus immediately when this migration pauses stores.
INSERT INTO public.pos_live_events (
  restaurant_id,
  domain,
  source_table,
  event_type
)
SELECT restaurant.id, 'menu', 'restaurants', 'UPDATE'
FROM public.restaurants restaurant
WHERE restaurant.is_active = true;

DO $verify$
DECLARE
  v_menu_definition text;
  v_order_definition text;
BEGIN
  SELECT pg_get_functiondef('public.qr_get_menu(text)'::regprocedure)
  INTO v_menu_definition;
  SELECT pg_get_functiondef(
    'public.qr_place_order(text,jsonb,uuid,boolean,uuid)'::regprocedure
  ) INTO v_order_definition;

  IF NOT EXISTS (
       SELECT 1
       FROM information_schema.columns
       WHERE table_schema = 'public'
         AND table_name = 'restaurants'
         AND column_name = 'qr_takeout_enabled'
         AND is_nullable = 'NO'
     )
     OR NOT EXISTS (
       SELECT 1
       FROM information_schema.columns
       WHERE table_schema = 'public'
         AND table_name = 'restaurants'
         AND column_name = 'qr_takeout_resume_at'
     )
     OR position('takeout_enabled' IN v_menu_definition) = 0
     OR position('QR_TAKEOUT_UNAVAILABLE' IN v_order_definition) = 0
     OR NOT has_function_privilege(
       'anon',
       'public.qr_get_menu(text)',
       'execute'
     )
     OR NOT has_function_privilege(
       'anon',
       'public.qr_place_order(text,jsonb,uuid,boolean,uuid)',
       'execute'
     )
     OR has_function_privilege(
       'anon',
       'public.qr_get_menu_pre_takeout_availability(text)',
       'execute'
     )
     OR has_function_privilege(
       'anon',
       'public.qr_place_order_pre_takeout_availability(text,jsonb,uuid,boolean,uuid)',
       'execute'
     ) THEN
    RAISE EXCEPTION 'QR_TAKEOUT_AVAILABILITY_VERIFICATION_FAILED';
  END IF;
END;
$verify$;

COMMIT;
