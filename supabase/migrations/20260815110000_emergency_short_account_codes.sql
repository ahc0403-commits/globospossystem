BEGIN;

-- Keep legacy station suffixes readable while supporting the shorter account
-- codes used by BunsikClub Binh Thanh and BunsikClub SAMPLE.
CREATE OR REPLACE FUNCTION public.sync_emergency_station_assignment_for_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_station text;
  v_floor text;
BEGIN
  IF NEW.fixed_account_code IS NULL OR NEW.restaurant_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.fixed_account_code ~ '_(tray1|tray)$' THEN
    v_station := 'tray';
  ELSIF NEW.fixed_account_code ~ '_(floor_1f|1f)$' THEN
    v_station := 'floor';
    v_floor := '1F';
  ELSIF NEW.fixed_account_code ~ '_(floor_2f|2f)$' THEN
    v_station := 'floor';
    v_floor := '2F';
  ELSIF NEW.fixed_account_code ~ '_(kit1|kit)$' THEN
    v_station := 'kitchen';
  ELSE
    RETURN NEW;
  END IF;

  INSERT INTO public.emergency_station_assignments (
    restaurant_id, user_id, station_type, floor_label, is_active
  ) VALUES (
    NEW.restaurant_id, NEW.id, v_station, v_floor, NEW.is_active
  )
  ON CONFLICT (restaurant_id, user_id) DO UPDATE SET
    station_type = EXCLUDED.station_type,
    floor_label = EXCLUDED.floor_label,
    is_active = EXCLUDED.is_active,
    updated_at = now();

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_emergency_station_assignment_for_user()
  FROM PUBLIC, anon, authenticated;

-- production-gate: self-verifying
DO $verify$
DECLARE
  v_function regprocedure :=
    to_regprocedure('public.sync_emergency_station_assignment_for_user()');
  v_definition text;
BEGIN
  IF v_function IS NULL THEN
    RAISE EXCEPTION 'EMERGENCY_STATION_ACCOUNT_SYNC_MISSING';
  END IF;

  v_definition := pg_get_functiondef(v_function);
  IF position('_(tray1|tray)$' IN v_definition) = 0
     OR position('_(floor_1f|1f)$' IN v_definition) = 0
     OR position('_(floor_2f|2f)$' IN v_definition) = 0
     OR position('_(kit1|kit)$' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'EMERGENCY_SHORT_ACCOUNT_CODE_SUPPORT_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid = 'public.users'::regclass
      AND trigger_row.tgfoid = v_function::oid
      AND NOT trigger_row.tgisinternal
  ) THEN
    RAISE EXCEPTION 'EMERGENCY_STATION_ACCOUNT_SYNC_TRIGGER_MISSING';
  END IF;

  IF has_function_privilege(
       'anon',
       'public.sync_emergency_station_assignment_for_user()',
       'EXECUTE'
     )
     OR has_function_privilege(
       'authenticated',
       'public.sync_emergency_station_assignment_for_user()',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'EMERGENCY_STATION_ACCOUNT_SYNC_EXECUTE_EXPOSED';
  END IF;
END;
$verify$;

COMMIT;
