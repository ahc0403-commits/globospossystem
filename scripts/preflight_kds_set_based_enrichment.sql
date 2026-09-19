DO $preflight$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure(
       'public.emergency_enrich_start_ready_orders(jsonb)'
     ) IS NULL
     OR to_regclass('public.emergency_order_queue') IS NULL
     OR to_regclass('public.emergency_fulfillment_items') IS NULL
     OR to_regclass('public.emergency_combo_component_items') IS NULL
     OR to_regclass('public.emergency_floor_direct_items') IS NULL
     OR to_regclass('public.emergency_floor_ready_lots') IS NULL THEN
    RAISE EXCEPTION 'KDS_SET_ENRICHMENT_PREREQUISITES_MISSING';
  END IF;
  IF to_regprocedure(
       'public.emergency_enrich_start_ready_orders_pre_500_scale(jsonb)'
     ) IS NOT NULL THEN
    RAISE EXCEPTION 'KDS_SET_ENRICHMENT_BACKUP_ALREADY_EXISTS';
  END IF;
  SELECT pg_get_functiondef(
    'public.emergency_enrich_start_ready_orders(jsonb)'::regprocedure
  ) INTO v_definition;
  IF position('emergency_floor_ready_lots' IN v_definition) = 0
     OR position('workflow_version' IN v_definition) = 0
     OR position('excused_quantity' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'KDS_SET_ENRICHMENT_UNEXPECTED_PREDECESSOR';
  END IF;
END;
$preflight$;
