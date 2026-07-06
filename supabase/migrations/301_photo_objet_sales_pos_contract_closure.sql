BEGIN;

DROP VIEW IF EXISTS public.v_photo_objet_daily_summary;

CREATE OR REPLACE VIEW public.v_photo_objet_daily_summary
WITH (security_invoker = true) AS
SELECT
  pos.store_id,
  r.name AS store_name,
  pos.sale_date,
  SUM(pos.gross_sales) AS total_gross_sales,
  SUM(pos.transaction_count) AS total_transactions,
  SUM(pos.service_amount) AS total_service_amount,
  COUNT(DISTINCT pos.device_name) AS active_machines,
  MAX(pos.pulled_at) AS last_pulled_at
FROM public.photo_objet_sales pos
JOIN public.restaurants r ON r.id = pos.store_id
GROUP BY pos.store_id, r.name, pos.sale_date;

COMMENT ON VIEW public.v_photo_objet_daily_summary IS
  'Photo Objet daily sales rollup joined to restaurants for POS Photo Ops workspace.';

ALTER TABLE public.photo_objet_sales ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "po_sales_master" ON public.photo_objet_sales;
DROP POLICY IF EXISTS "po_sales_store" ON public.photo_objet_sales;
DROP POLICY IF EXISTS "photo_objet_sales_select_scope" ON public.photo_objet_sales;

CREATE POLICY "photo_objet_sales_select_scope"
ON public.photo_objet_sales
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.user_accessible_stores(auth.uid()) s(store_id)
    WHERE s.store_id = photo_objet_sales.store_id
  )
  OR public.is_super_admin()
);

REVOKE ALL ON public.photo_objet_sales FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.photo_objet_sales TO authenticated;
GRANT ALL ON public.photo_objet_sales TO service_role;
GRANT SELECT ON public.v_photo_objet_daily_summary TO authenticated;
GRANT ALL ON public.v_photo_objet_daily_summary TO service_role;

COMMIT;
