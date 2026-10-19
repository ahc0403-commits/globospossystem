DO $assert$
DECLARE
  v_actual jsonb;
  v_expected jsonb;
BEGIN
  SELECT expected,
         public.emergency_enrich_start_ready_orders(input)
  INTO v_expected, v_actual
  FROM public.kds_enrichment_expected;
  IF v_actual IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'KDS_SET_ENRICHMENT_PARITY_FAILED expected=% actual=%',
      v_expected, v_actual;
  END IF;
  IF public.emergency_enrich_start_ready_orders(NULL::jsonb) <> '[]'::jsonb
     OR public.emergency_enrich_start_ready_orders('{}'::jsonb) <> '[]'::jsonb
     OR public.emergency_enrich_start_ready_orders('[]'::jsonb) <> '[]'::jsonb THEN
    RAISE EXCEPTION 'KDS_SET_ENRICHMENT_EMPTY_INPUT_FAILED';
  END IF;
END;
$assert$;
