DO $$ BEGIN
  IF to_regprocedure('public.sync_active_order_promotion(uuid,uuid,timestamptz)') IS NULL
     OR to_regprocedure('public.refresh_store_order_promotions(uuid,timestamptz)') IS NULL
     OR to_regclass('public.order_discount_lines') IS NULL
     OR to_regclass('public.store_promotion_menu_items') IS NULL THEN
    RAISE EXCEPTION 'PROMOTION_SYNC_PREREQUISITE_MISSING';
  END IF;
END $$;
