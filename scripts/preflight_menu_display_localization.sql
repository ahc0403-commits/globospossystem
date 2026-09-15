DO $$
DECLARE name text;
BEGIN
  FOREACH name IN ARRAY ARRAY['name_ko','name_vi','name_en'] LOOP
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='menu_items' AND column_name=name) THEN
      RAISE EXCEPTION 'Missing menu translation field: %', name;
    END IF;
  END LOOP;
  IF to_regprocedure('public.get_bm_order_history_detail(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Apply the BM order drilldown migration before menu localization';
  END IF;
  IF to_regprocedure(
    'public.get_paperless_operations_report(uuid,timestamp with time zone,timestamp with time zone)'
  ) IS NULL OR to_regprocedure(
    'public.get_paperless_operations_insights_report(uuid,timestamp with time zone,timestamp with time zone)'
  ) IS NULL THEN
    RAISE EXCEPTION 'Apply the paperless operations migrations before menu localization';
  END IF;
END $$;
