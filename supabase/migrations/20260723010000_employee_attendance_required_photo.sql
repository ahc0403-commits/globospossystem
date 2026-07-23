-- Require a captured photo for the employee-number attendance kiosk path.
-- The existing three-argument RPC remains available to older internal clients;
-- the kiosk uses this explicit photo-backed contract.

CREATE OR REPLACE FUNCTION public.record_employee_attendance_with_photo(
  p_store_id uuid,
  p_employee_number text,
  p_type text,
  p_photo_url text
) RETURNS public.attendance_logs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_photo_url text := NULLIF(btrim(COALESCE(p_photo_url, '')), '');
  v_log public.attendance_logs%ROWTYPE;
BEGIN
  IF v_photo_url IS NULL THEN
    RAISE EXCEPTION 'ATTENDANCE_PHOTO_REQUIRED';
  END IF;

  v_log := public.record_employee_attendance(
    p_store_id,
    p_employee_number,
    p_type
  );

  UPDATE public.attendance_logs
  SET
    photo_url = v_photo_url,
    photo_thumbnail_url = v_photo_url
  WHERE id = v_log.id
  RETURNING * INTO v_log;

  RETURN v_log;
END;
$$;

REVOKE ALL ON FUNCTION public.record_employee_attendance_with_photo(
  uuid,
  text,
  text,
  text
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.record_employee_attendance_with_photo(
  uuid,
  text,
  text,
  text
) TO authenticated;

COMMENT ON FUNCTION public.record_employee_attendance_with_photo(
  uuid,
  text,
  text,
  text
) IS 'Records employee-number attendance only after a kiosk photo has been uploaded.';
