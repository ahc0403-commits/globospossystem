DO $verify$
DECLARE
  v_complete_definition text;
  v_revert_definition text;
BEGIN
  IF to_regclass('public.emergency_fulfillment_actions') IS NULL THEN
    RAISE EXCEPTION 'EMERGENCY_KDS_ACTION_TABLE_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'emergency_fulfillment_events'
      AND column_name = 'action_id'
  ) THEN
    RAISE EXCEPTION 'EMERGENCY_KDS_EVENT_ACTION_LINK_MISSING';
  END IF;

  IF to_regprocedure(
       'public.emergency_complete_order_stage(uuid,uuid)'
     ) IS NULL
     OR to_regprocedure(
       'public.emergency_revert_order_action(uuid,uuid,uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'EMERGENCY_KDS_ORDER_ACTION_RPCS_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.emergency_complete_order_stage(uuid,uuid)'::regprocedure
  ) INTO v_complete_definition;
  SELECT pg_get_functiondef(
    'public.emergency_revert_order_action(uuid,uuid,uuid)'::regprocedure
  ) INTO v_revert_definition;

  IF position('FOR UPDATE OF queue' IN v_complete_definition) = 0
     OR position('ON CONFLICT (action_id) DO NOTHING' IN v_complete_definition) = 0
     OR position('tray_received_quantity = kitchen_done_quantity'
       IN v_complete_definition) = 0
     OR position('tray_dispatched_quantity = kitchen_done_quantity'
       IN v_complete_definition) = 0 THEN
    RAISE EXCEPTION 'EMERGENCY_KDS_COMPLETE_ATOMICITY_CONTRACT_MISSING';
  END IF;

  IF position('EMERGENCY_REVERT_DOWNSTREAM_PROGRESS'
       IN v_revert_definition) = 0
     OR position('original_action_id' IN v_revert_definition) = 0 THEN
    RAISE EXCEPTION 'EMERGENCY_KDS_REVERT_GUARD_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'emergency_fulfillment_actions'
      AND policyname = 'emergency_actions_store_read'
  ) THEN
    RAISE EXCEPTION 'EMERGENCY_KDS_ACTION_RLS_MISSING';
  END IF;
END;
$verify$;
