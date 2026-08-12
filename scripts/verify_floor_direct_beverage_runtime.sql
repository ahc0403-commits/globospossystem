DO $$
BEGIN
  IF to_regprocedure(
    'public.emergency_upsert_floor_direct_line(uuid,uuid,uuid,uuid,uuid,text,text,uuid,text,text,text,integer,boolean)'
  ) IS NULL OR position(
    'emergency_floor_direct_items' IN pg_get_functiondef(
      'public.emergency_sync_order_item()'::regprocedure
    )
  ) = 0 THEN
    RAISE EXCEPTION 'FLOOR_DIRECT_RUNTIME_FUNCTIONS_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.order_items'::regclass
      AND tgname = 'emergency_sync_order_item_trigger'
      AND NOT tgisinternal
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'emergency_floor_direct_items'
  ) THEN
    RAISE EXCEPTION 'FLOOR_DIRECT_RUNTIME_WIRING_MISSING';
  END IF;
END;
$$;
