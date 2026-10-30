DO $$
DECLARE v_campaigns jsonb; v_targets jsonb; v_categories jsonb; payments jsonb;
BEGIN
 SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.id),'[]'::jsonb) INTO v_campaigns FROM public.store_promotions p;
 SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.promotion_id,t.menu_item_id),'[]'::jsonb) INTO v_targets
  FROM public.store_promotion_menu_items t;
 SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.id),'[]'::jsonb) INTO v_categories FROM public.menu_categories c;
 SELECT jsonb_agg(jsonb_build_object('signature',p.oid::regprocedure::text,
   'hash',encode(sha256(convert_to(pg_get_functiondef(p.oid),'UTF8')),'hex')) ORDER BY p.oid) INTO payments
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='process_payment';
 IF NOT EXISTS(SELECT 1 FROM pg_temp.pos_discount_release_baseline b
  WHERE b.campaigns=v_campaigns AND b.targets=v_targets AND b.categories=v_categories
   AND b.payment_definitions IS NOT DISTINCT FROM payments) THEN
  RAISE EXCEPTION 'MENU_DISCOUNT_EXISTING_CONFIGURATION_CHANGED';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relname='menu_discount_quantities' AND c.relrowsecurity)
  OR has_table_privilege('anon','public.menu_discount_quantities','SELECT')
  OR has_table_privilege('authenticated','public.menu_discount_quantities','UPDATE') THEN
  RAISE EXCEPTION 'MENU_DISCOUNT_PRIVILEGE_VERIFICATION_FAILED';
 END IF;
 RAISE NOTICE 'MENU_DISCOUNT_RELEASE_EXISTING_CAMPAIGNS_CATEGORIES_TARGETS_PAYMENT=PRESERVED';
END $$;
