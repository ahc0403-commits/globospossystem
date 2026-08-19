DO $$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure(
    'public.admin_record_employee_attendance(uuid,uuid,text,timestamptz,text,text)'
  ) IS NULL THEN
    RAISE EXCEPTION 'PIN-protected manual attendance RPC is missing';
  END IF;

  SELECT pg_get_functiondef(
    'public.admin_record_employee_attendance(uuid,uuid,text,timestamptz,text,text)'::regprocedure
  ) INTO v_definition;

  IF position('ATTENDANCE_MANUAL_SEQUENCE_INVALID' IN v_definition) > 0
     OR position('v_previous_type' IN v_definition) > 0
     OR position('v_next_type' IN v_definition) > 0 THEN
    RAISE EXCEPTION 'manual attendance RPC still enforces event sequence';
  END IF;

  IF position('verify_discount_manager_pin_or_raise' IN v_definition) = 0
     OR position('ATTENDANCE_MANUAL_ENTRY_FORBIDDEN' IN v_definition) = 0
     OR position('ATTENDANCE_MANUAL_TIME_INVALID' IN v_definition) = 0
     OR position('ATTENDANCE_MANUAL_TIME_DUPLICATE' IN v_definition) = 0
     OR position('ATTENDANCE_MANUAL_REASON_REQUIRED' IN v_definition) = 0
     OR position('attendance_manual_entry' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'manual attendance safety checks or audit trail are missing';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.admin_record_employee_attendance(uuid,uuid,text,timestamptz,text,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'authenticated role cannot execute manual attendance RPC';
  END IF;
END
$$;

SELECT 'order-independent manual attendance verification passed' AS result;
