SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';
-- Run in the same official atomic transaction as the migration and verifier.
-- Retain the existing campaign, target menu set and category identities/rates.
LOCK TABLE public.store_promotions,public.store_promotion_menu_items,public.menu_categories IN SHARE MODE;
DO $$ BEGIN
 IF to_regclass('public.menu_discount_quantities') IS NOT NULL OR EXISTS(
  SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='order_items'
   AND column_name='promotion_quantity_snapshot') THEN
  RAISE EXCEPTION 'MENU_DISCOUNT_PREDECESSOR_ALREADY_CHANGED';
 END IF;
END $$;
CREATE TEMP TABLE pos_discount_release_baseline ON COMMIT DROP AS
SELECT
 (SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.id),'[]'::jsonb) FROM public.store_promotions p) AS campaigns,
 (SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.promotion_id,t.menu_item_id),'[]'::jsonb)
  FROM public.store_promotion_menu_items t) AS targets,
 (SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.id),'[]'::jsonb) FROM public.menu_categories c) AS categories,
 (SELECT jsonb_agg(jsonb_build_object('signature',p.oid::regprocedure::text,
   'hash',encode(sha256(convert_to(pg_get_functiondef(p.oid),'UTF8')),'hex')) ORDER BY p.oid)
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='process_payment') AS payment_definitions;
