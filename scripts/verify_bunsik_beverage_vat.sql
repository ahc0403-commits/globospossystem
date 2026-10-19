\set ON_ERROR_STOP on
DO $$ BEGIN
 IF (SELECT count(*) FROM public.bunsik_beverage_vat_20260929_backup)<>10 OR EXISTS(
 SELECT 1 FROM public.bunsik_beverage_vat_20260929_backup b LEFT JOIN public.menu_items m ON m.id=b.id
 WHERE m.id IS NULL OR m.restaurant_id<>b.restaurant_id OR m.price<>b.price OR m.vat_category<>b.vat_category
 OR m.beverage_sugar_tax_class<>b.applied_class OR m.effective_vat_rate<>CASE WHEN b.applied_class='gt_5' THEN 10 ELSE 8 END
 ) THEN RAISE EXCEPTION 'BUNSIK_BEVERAGE_VERIFY_FAILED'; END IF;
END $$;
SELECT m.restaurant_id,m.name_en,m.effective_vat_rate FROM public.menu_items m
JOIN public.bunsik_beverage_vat_20260929_backup b ON b.id=m.id ORDER BY m.restaurant_id,m.name_en;
