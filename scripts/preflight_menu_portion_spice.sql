DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='menu_items' AND column_name='portion_code') THEN
  RAISE EXCEPTION 'MENU_OPTIONS_ALREADY_PRESENT';
 END IF;
 IF to_regprocedure('public.admin_create_menu_item_with_invoice(uuid,uuid,text,text,text,text,numeric,integer,boolean,jsonb,text)') IS NULL
 OR to_regprocedure('public.direct_order_prepare_combo_items(uuid,jsonb)') IS NULL THEN RAISE EXCEPTION 'MENU_OPTION_PREREQUISITES_MISSING'; END IF;
END $$;
SELECT 'MENU_PORTION_SPICE_PREFLIGHT=PASS';
