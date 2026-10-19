DO $verify$
DECLARE
  v_definition text;
  v_probe jsonb;
BEGIN
  IF to_regprocedure(
       'public.emergency_enrich_start_ready_orders(jsonb)'
     ) IS NULL
     OR to_regprocedure(
       'public.emergency_enrich_start_ready_orders_pre_500_scale(jsonb)'
     ) IS NULL THEN
    RAISE EXCEPTION 'KDS_SET_ENRICHMENT_OBJECTS_MISSING';
  END IF;
  SELECT pg_get_functiondef(
    'public.emergency_enrich_start_ready_orders(jsonb)'::regprocedure
  ) INTO v_definition;
  IF position('WITH ORDINALITY' IN v_definition) = 0
     OR position('pending_source_ready' IN v_definition) = 0
     OR position('FOR v_order IN' IN v_definition) > 0
     OR position('FOR v_item IN' IN v_definition) > 0 THEN
    RAISE EXCEPTION 'KDS_SET_ENRICHMENT_DEFINITION_INVALID';
  END IF;
  IF has_function_privilege(
       'authenticated',
       'public.emergency_enrich_start_ready_orders(jsonb)',
       'EXECUTE'
     ) OR has_function_privilege(
       'anon',
       'public.emergency_enrich_start_ready_orders(jsonb)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'KDS_SET_ENRICHMENT_PRIVILEGES_INVALID';
  END IF;
  SELECT public.emergency_enrich_start_ready_orders(NULL::jsonb)
  INTO v_probe;
  IF v_probe <> '[]'::jsonb THEN
    RAISE EXCEPTION 'KDS_SET_ENRICHMENT_NULL_INPUT_INVALID';
  END IF;
END;
$verify$;
