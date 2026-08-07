\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_due_definition text;
  v_complete_definition text;
BEGIN
  IF to_regprocedure(
    'public.photo_objet_due_recovery_slots(timestamp with time zone,date,integer)'
  ) IS NULL OR to_regprocedure(
    'public.photo_objet_complete_recovery_slot(uuid,date,time without time zone,uuid,boolean)'
  ) IS NULL THEN
    RAISE EXCEPTION 'PHOTO_RECOVERY_FUNCTION_MISSING';
  END IF;

  SELECT lower(pg_get_functiondef(
    'public.photo_objet_due_recovery_slots(timestamp with time zone,date,integer)'::regprocedure
  )) INTO v_due_definition;
  SELECT lower(pg_get_functiondef(
    'public.photo_objet_complete_recovery_slot(uuid,date,time without time zone,uuid,boolean)'::regprocedure
  )) INTO v_complete_definition;

  IF v_due_definition NOT LIKE '%slot.slot_date_hcm = p_slot_date_hcm%'
     OR v_due_definition NOT LIKE '%hcm-eod-2200-v4%'
     OR v_due_definition NOT LIKE '%slot.status in (''missing'', ''failed'')%' THEN
    RAISE EXCEPTION 'PHOTO_RECOVERY_QUEUE_CONTRACT_INVALID';
  END IF;
  IF v_complete_definition NOT LIKE '%run.run_source = ''scheduled''%'
     OR v_complete_definition NOT LIKE '%run.interval_start_at = v_interval_start%'
     OR v_complete_definition NOT LIKE '%run.interval_end_at = v_interval_end%'
     OR v_complete_definition NOT LIKE '%else ''recovered''%' THEN
    RAISE EXCEPTION 'PHOTO_RECOVERY_COMPLETION_CONTRACT_INVALID';
  END IF;

  IF has_function_privilege(
       'anon',
       'public.photo_objet_due_recovery_slots(timestamp with time zone,date,integer)',
       'EXECUTE'
     ) OR has_function_privilege(
       'authenticated',
       'public.photo_objet_complete_recovery_slot(uuid,date,time without time zone,uuid,boolean)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'PHOTO_RECOVERY_FUNCTION_PRIVILEGE_TOO_BROAD';
  END IF;
  IF NOT has_function_privilege(
       'service_role',
       'public.photo_objet_due_recovery_slots(timestamp with time zone,date,integer)',
       'EXECUTE'
     ) OR NOT has_function_privilege(
       'service_role',
       'public.photo_objet_complete_recovery_slot(uuid,date,time without time zone,uuid,boolean)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'PHOTO_RECOVERY_SERVICE_ROLE_PRIVILEGE_MISSING';
  END IF;
END
$verify$;

SELECT 'Photo Objet automatic slot recovery verification passed' AS result;
