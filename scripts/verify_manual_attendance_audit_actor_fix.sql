DO $$
DECLARE
  v_definition text;
  v_normalized text;
BEGIN
  IF to_regprocedure(
    'public.admin_record_employee_attendance(uuid,uuid,text,timestamptz,text,text)'
  ) IS NULL THEN
    RAISE EXCEPTION 'manual attendance RPC is missing';
  END IF;

  SELECT pg_get_functiondef(
    'public.admin_record_employee_attendance(uuid,uuid,text,timestamptz,text,text)'::regprocedure
  ) INTO v_definition;
  v_normalized := regexp_replace(v_definition, '[[:space:]]+', ' ', 'g');

  IF position(
    'VALUES ( auth.uid(), ''attendance_manual_entry''' IN v_normalized
  ) = 0 THEN
    RAISE EXCEPTION 'manual attendance audit actor is not the authenticated Auth user';
  END IF;
  IF position(
    'VALUES ( v_actor.id, ''attendance_manual_entry''' IN v_normalized
  ) > 0 THEN
    RAISE EXCEPTION 'manual attendance audit actor still uses the public user ID';
  END IF;
  IF position('ATTENDANCE_MANUAL_SEQUENCE_INVALID' IN v_definition) > 0 THEN
    RAISE EXCEPTION 'manual attendance RPC still enforces event sequence';
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT has_function_privilege(
    'authenticated',
    'public.admin_record_employee_attendance(uuid,uuid,text,timestamptz,text,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'authenticated cannot execute manual attendance RPC';
  END IF;
END;
$$;

SELECT 'manual attendance audit actor verification passed' AS result;
