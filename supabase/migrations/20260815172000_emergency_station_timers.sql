BEGIN;

-- production-gate: self-verifying

-- Return the arrival and latest completion-event timestamps for the current
-- station. The client only treats station_completed_at as final when the
-- quantity ledger says the station is fully complete.
CREATE OR REPLACE FUNCTION public.get_emergency_station_timings()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_day_start timestamptz;
  v_timings jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_user
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;

  SELECT * INTO v_assignment
  FROM public.emergency_station_assignments
  WHERE user_id = v_user.id
    AND restaurant_id = v_user.restaurant_id
    AND is_active = true;
  IF NOT FOUND THEN RETURN '[]'::jsonb; END IF;

  v_day_start := (
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp
    AT TIME ZONE 'Asia/Ho_Chi_Minh'
  );

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'queue_id', queue.id,
        'station_started_at', CASE v_assignment.station_type
          WHEN 'kitchen' THEN queue.created_at
          WHEN 'tray' THEN station_events.previous_stage_at
          ELSE CASE
            WHEN EXISTS (
              SELECT 1
              FROM public.emergency_floor_direct_items direct
              WHERE direct.session_id = queue.session_id
                AND direct.order_id = queue.order_id
                AND direct.queue_id = queue.id
                AND direct.is_cancelled = false
            ) THEN queue.created_at
            ELSE station_events.previous_stage_at
          END
        END,
        'station_completed_at', station_events.completed_at
      )
      ORDER BY queue.queue_no
    ),
    '[]'::jsonb
  )
  INTO v_timings
  FROM public.emergency_order_queue queue
  JOIN public.emergency_fulfillment_sessions session
    ON session.id = queue.session_id
  LEFT JOIN LATERAL (
    SELECT
      min(event.created_at) FILTER (
        WHERE event.stage = CASE v_assignment.station_type
          WHEN 'tray' THEN 'kitchen_done'
          WHEN 'floor' THEN 'tray_dispatched'
          ELSE 'order_received'
        END
      ) AS previous_stage_at,
      max(event.created_at) FILTER (
        WHERE event.stage = CASE v_assignment.station_type
          WHEN 'kitchen' THEN 'kitchen_done'
          WHEN 'tray' THEN 'tray_dispatched'
          ELSE 'floor_served'
        END
      ) AS completed_at
    FROM public.emergency_fulfillment_events event
    WHERE event.restaurant_id = queue.restaurant_id
      AND event.session_id = queue.session_id
      AND event.order_id = queue.order_id
      AND event.delta > 0
      AND event.stage IN (
        'order_received', 'kitchen_done', 'tray_dispatched', 'floor_served'
      )
  ) station_events ON true
  WHERE queue.restaurant_id = v_assignment.restaurant_id
    AND (
      v_assignment.station_type <> 'floor'
      OR queue.floor_label = v_assignment.floor_label
    )
    AND (
      session.status = 'active'
      OR station_events.completed_at >= v_day_start
    );

  RETURN v_timings;
END;
$$;

REVOKE ALL ON FUNCTION public.get_emergency_station_timings()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_emergency_station_timings()
  TO authenticated;

DO $$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.get_emergency_station_timings()'::regprocedure
  )
  INTO v_definition;

  IF v_definition NOT LIKE '%station_started_at%'
     OR v_definition NOT LIKE '%station_completed_at%'
     OR v_definition NOT LIKE '%emergency_fulfillment_events%'
     OR v_definition NOT LIKE '%Asia/Ho_Chi_Minh%' THEN
    RAISE EXCEPTION 'EMERGENCY_STATION_TIMINGS_VERIFICATION_FAILED';
  END IF;

  IF NOT pg_catalog.has_function_privilege(
    'authenticated',
    'public.get_emergency_station_timings()',
    'EXECUTE'
  ) OR pg_catalog.has_function_privilege(
    'anon',
    'public.get_emergency_station_timings()',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'EMERGENCY_STATION_TIMINGS_GRANT_VERIFICATION_FAILED';
  END IF;
END;
$$;

COMMIT;
