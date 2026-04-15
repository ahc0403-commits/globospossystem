-- ============================================================
-- POS Attendance Event Capture + Log Visibility contract closure
-- 2026-04-09
-- Bounded scope:
-- - staff directory read for attendance capture
-- - attendance log visibility read
-- - attendance event recording
-- - server-owned validation and minimal audit trace
-- Out of scope:
-- - payroll configuration/export
-- - fingerprint enrollment/identify redesign
-- - hardware/device orchestration changes
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_attendance_staff_directory(
  p_restaurant_id UUID
) RETURNS TABLE (
  user_id UUID,
  full_name TEXT,
  role TEXT
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ATTENDANCE_STAFF_DIRECTORY_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'ATTENDANCE_STAFF_DIRECTORY_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    u.id AS user_id,
    u.full_name,
    u.role
  FROM public.users u
  WHERE u.restaurant_id = p_restaurant_id
    AND u.is_active = TRUE
    AND u.role IN ('admin', 'waiter', 'kitchen', 'cashier')
  ORDER BY lower(u.full_name), u.created_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
CREATE OR REPLACE FUNCTION public.get_attendance_log_view(
  p_restaurant_id UUID,
  p_from TIMESTAMPTZ,
  p_to TIMESTAMPTZ,
  p_user_id UUID DEFAULT NULL
) RETURNS TABLE (
  attendance_log_id UUID,
  restaurant_id UUID,
  user_id UUID,
  user_full_name TEXT,
  user_role TEXT,
  attendance_type TEXT,
  photo_url TEXT,
  photo_thumbnail_url TEXT,
  logged_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_VIEW_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_VIEW_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_RANGE_REQUIRED';
  END IF;

  IF p_from > p_to THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_RANGE_INVALID';
  END IF;

  IF p_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = p_user_id
      AND u.restaurant_id = p_restaurant_id
      AND u.is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_USER_NOT_FOUND';
  END IF;

  RETURN QUERY
  SELECT
    al.id AS attendance_log_id,
    al.restaurant_id,
    al.user_id,
    u.full_name AS user_full_name,
    u.role AS user_role,
    al.type AS attendance_type,
    al.photo_url,
    al.photo_thumbnail_url,
    al.logged_at,
    al.created_at
  FROM public.attendance_logs al
  JOIN public.users u
    ON u.id = al.user_id
   AND u.restaurant_id = al.restaurant_id
  WHERE al.restaurant_id = p_restaurant_id
    AND al.logged_at >= p_from
    AND al.logged_at <= p_to
    AND (p_user_id IS NULL OR al.user_id = p_user_id)
  ORDER BY al.logged_at DESC, al.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
CREATE OR REPLACE FUNCTION public.record_attendance_event(
  p_restaurant_id UUID,
  p_user_id UUID,
  p_type TEXT,
  p_photo_url TEXT DEFAULT NULL,
  p_photo_thumbnail_url TEXT DEFAULT NULL
) RETURNS TABLE (
  attendance_log_id UUID,
  restaurant_id UUID,
  user_id UUID,
  attendance_type TEXT,
  photo_url TEXT,
  photo_thumbnail_url TEXT,
  logged_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_target_user public.users%ROWTYPE;
  v_log public.attendance_logs%ROWTYPE;
  v_photo_url TEXT := NULLIF(btrim(COALESCE(p_photo_url, '')), '');
  v_photo_thumbnail_url TEXT := NULLIF(btrim(COALESCE(p_photo_thumbnail_url, '')), '');
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ATTENDANCE_EVENT_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'ATTENDANCE_EVENT_FORBIDDEN';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'ATTENDANCE_EVENT_USER_REQUIRED';
  END IF;

  IF p_type IS NULL OR p_type NOT IN ('clock_in', 'clock_out') THEN
    RAISE EXCEPTION 'ATTENDANCE_EVENT_TYPE_INVALID';
  END IF;

  SELECT u.*
  INTO v_target_user
  FROM public.users u
  WHERE u.id = p_user_id
    AND u.restaurant_id = p_restaurant_id
    AND u.is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ATTENDANCE_EVENT_USER_NOT_FOUND';
  END IF;

  INSERT INTO public.attendance_logs (
    restaurant_id,
    user_id,
    type,
    photo_url,
    photo_thumbnail_url,
    logged_at
  )
  VALUES (
    p_restaurant_id,
    p_user_id,
    p_type,
    v_photo_url,
    COALESCE(v_photo_thumbnail_url, v_photo_url),
    now()
  )
  RETURNING * INTO v_log;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'attendance_event_recorded',
    'attendance_logs',
    v_log.id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'user_id', p_user_id,
      'attendance_type', p_type,
      'logged_at', v_log.logged_at,
      'photo_url', v_log.photo_url,
      'photo_thumbnail_url', v_log.photo_thumbnail_url
    )
  );

  RETURN QUERY
  SELECT
    v_log.id AS attendance_log_id,
    v_log.restaurant_id,
    v_log.user_id,
    v_log.type AS attendance_type,
    v_log.photo_url,
    v_log.photo_thumbnail_url,
    v_log.logged_at,
    v_log.created_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
