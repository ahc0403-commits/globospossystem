DO $assert_rollback$
DECLARE
  v_actual_objects integer;
BEGIN
  IF to_regclass('public.tax_entity_brands') IS NOT NULL
     OR to_regclass('public.hierarchy_20260711090000_backup_state') IS NOT NULL
     OR to_regclass('public.hierarchy_20260711090000_photo_backup') IS NOT NULL
     OR to_regclass('public.hierarchy_20260711090000_history_backup') IS NOT NULL
     OR to_regclass('public.hierarchy_20260711090000_object_backup') IS NOT NULL
     OR to_regclass('public.v_office_eligible_stores') IS NOT NULL THEN
    RAISE EXCEPTION 'LOCAL_SMOKE_ROLLBACK_ARTIFACT_REMAINS';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'tax_entity'
      AND column_name = 'onboarding_status'
  ) OR to_regprocedure('public.admin_create_restaurant_v2(text,text,text,uuid,uuid,text,numeric,uuid)') IS NOT NULL
     OR to_regprocedure('public.admin_update_restaurant_v2(uuid,text,text,text,uuid,uuid,text,numeric,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'LOCAL_SMOKE_ROLLBACK_NEW_OBJECT_REMAINS';
  END IF;

  IF EXISTS (
    (TABLE test_expected.tax_entity EXCEPT TABLE public.tax_entity)
    UNION ALL (TABLE public.tax_entity EXCEPT TABLE test_expected.tax_entity)
  ) OR EXISTS (
    (TABLE test_expected.brands EXCEPT TABLE public.brands)
    UNION ALL (TABLE public.brands EXCEPT TABLE test_expected.brands)
  ) OR EXISTS (
    (TABLE test_expected.restaurants EXCEPT TABLE public.restaurants)
    UNION ALL (TABLE public.restaurants EXCEPT TABLE test_expected.restaurants)
  ) OR EXISTS (
    (TABLE test_expected.history EXCEPT TABLE public.store_tax_entity_history)
    UNION ALL (TABLE public.store_tax_entity_history EXCEPT TABLE test_expected.history)
  ) THEN
    RAISE EXCEPTION 'LOCAL_SMOKE_ROLLBACK_STATE_MISMATCH';
  END IF;

  SELECT count(*) INTO v_actual_objects
  FROM (
    SELECT p.oid::regprocedure::text AS object_identity,
           'function'::text AS object_kind,
           pg_get_functiondef(p.oid) AS definition
    FROM pg_proc p
    WHERE p.oid IN (
      to_regprocedure('public.admin_create_restaurant(text,text,text,text,numeric,uuid,text,uuid)'),
      to_regprocedure('public.admin_update_restaurant(uuid,text,text,text,text,numeric,uuid,text)'),
      to_regprocedure('public.sync_restaurant_store_type_from_tax_entity()'),
      to_regprocedure('public.sync_stores_after_tax_entity_owner_change()'),
      to_regprocedure('public.guard_pending_tax_entity_meinvoice_activation()')
    )
    UNION ALL
    SELECT format('%I.%I:%I', n.nspname, c.relname, t.tgname),
           'trigger',
           pg_get_triggerdef(t.oid, true)
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE NOT t.tgisinternal
      AND t.tgname IN (
        'trg_sync_restaurant_store_type_from_tax_entity',
        'trg_sync_stores_after_tax_entity_owner_change',
        'trg_guard_pending_tax_entity_meinvoice_activation'
      )
  ) actual
  FULL JOIN test_expected.object_definitions expected
    USING (object_identity, object_kind, definition)
  WHERE actual.object_identity IS NULL OR expected.object_identity IS NULL;

  IF v_actual_objects <> 0 THEN
    RAISE EXCEPTION 'LOCAL_SMOKE_ROLLBACK_OBJECT_DEFINITION_MISMATCH';
  END IF;
END;
$assert_rollback$;
