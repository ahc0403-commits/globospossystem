DO $$
DECLARE
  v_signature text;
BEGIN
  FOREACH v_signature IN ARRAY ARRAY[
    'public.emergency_record_floor_direct_progress(uuid,integer,uuid)',
    'public.emergency_complete_route_order_stage(uuid,uuid)',
    'public.emergency_revert_route_order_action(uuid,uuid,uuid)'
  ] LOOP
    IF to_regprocedure(v_signature) IS NULL
       OR NOT has_function_privilege('authenticated', v_signature, 'EXECUTE') THEN
      RAISE EXCEPTION 'FLOOR_DIRECT_ACTION_MISSING_OR_FORBIDDEN: %', v_signature;
    END IF;
  END LOOP;

  IF position(
    'FOR UPDATE' IN pg_get_functiondef(
      'public.emergency_record_floor_direct_progress(uuid,integer,uuid)'::regprocedure
    )
  ) = 0 OR position(
    'deduplicated' IN pg_get_functiondef(
      'public.emergency_record_floor_direct_progress(uuid,integer,uuid)'::regprocedure
    )
  ) = 0 THEN
    RAISE EXCEPTION 'FLOOR_DIRECT_ACTION_IDEMPOTENCY_MISSING';
  END IF;
END;
$$;
