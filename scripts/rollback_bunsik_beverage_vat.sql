\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout='5s';
SELECT m.id FROM public.menu_items m JOIN public.bunsik_beverage_vat_20260929_backup b ON b.id=m.id FOR UPDATE OF m;
-- Future menu settings only. Never rewrite prior order/invoice snapshots.
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.bunsik_beverage_vat_20260929_backup b JOIN public.menu_items m ON m.id=b.id
 WHERE m.beverage_sugar_tax_class<>b.applied_class OR m.sugar_g_per_100ml IS NOT NULL
 OR m.tax_basis_note IS DISTINCT FROM 'Store owner confirmed sold SKU sugar band on 2026-09-29; exact label grams pending.') THEN
 RAISE EXCEPTION 'BUNSIK_BEVERAGE_ROLLBACK_WOULD_OVERWRITE_NEWER_EDIT'; END IF;
END $$;
UPDATE public.menu_items m SET beverage_sugar_tax_class=b.beverage_sugar_tax_class,
 sugar_g_per_100ml=b.sugar_g_per_100ml,tax_basis_note=b.tax_basis_note,updated_at=now()
FROM public.bunsik_beverage_vat_20260929_backup b WHERE m.id=b.id AND m.restaurant_id=b.restaurant_id;
COMMIT;
