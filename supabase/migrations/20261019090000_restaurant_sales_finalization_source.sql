BEGIN;
-- production-gate: self-verifying
-- Reporting scope is independent of optional order-cutoff enforcement settings.
-- Only direct Restaurant stores contribute; Photo Objet and external stores do not.
CREATE OR REPLACE VIEW public.v_restaurant_sales_receipts
WITH (security_invoker=true) AS
SELECT p.restaurant_id AS store_id, p.id::text AS receipt_id,
  'pos_payment'::text AS receipt_source, o.sales_channel,
  coalesce(p.amount_portion,p.amount)::numeric(18,2) AS gross_sales,
  p.created_at AS sold_at,
  (p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS sale_date_hcm,
  date_trunc('hour',p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh') AS sale_hour_hcm
FROM public.payments p JOIN public.orders o ON o.id=p.order_id
JOIN public.restaurants r ON r.id=p.restaurant_id
WHERE p.is_revenue AND o.status='completed' AND r.store_type='direct'
  AND r.brand_id IS DISTINCT FROM '77000000-0000-0000-0000-000000000001'::uuid
UNION ALL
SELECT e.restaurant_id,e.id::text,'external_delivery',e.sales_channel,
  e.gross_amount::numeric(18,2),coalesce(e.completed_at,e.created_at),
  (coalesce(e.completed_at,e.created_at) AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
  date_trunc('hour',coalesce(e.completed_at,e.created_at) AT TIME ZONE 'Asia/Ho_Chi_Minh')
FROM public.external_sales e JOIN public.restaurants r ON r.id=e.restaurant_id
WHERE e.is_revenue AND e.order_status='completed' AND r.store_type='direct'
  AND r.brand_id IS DISTINCT FROM '77000000-0000-0000-0000-000000000001'::uuid;

-- One bounded set-based read for both scheduled close and audited recovery.
CREATE OR REPLACE FUNCTION public.restaurant_sales_totals_range(p_from date,p_to date)
RETURNS TABLE(business_date date,store_count integer,receipt_count integer,
  gross_sales numeric,post_cutoff_receipt_count integer,offending_stores jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_to<p_from OR p_to-p_from>30 THEN
    RAISE EXCEPTION 'RESTAURANT_SALES_RANGE_INVALID' USING ERRCODE='22023';
  END IF;
  RETURN QUERY
  WITH scope AS (
    SELECT count(*)::integer AS n FROM public.restaurants r
    WHERE r.store_type='direct'
      AND r.brand_id IS DISTINCT FROM '77000000-0000-0000-0000-000000000001'::uuid
  ), receipts AS MATERIALIZED (
    SELECT v.* FROM public.v_restaurant_sales_receipts v
    WHERE v.sold_at >= (p_from::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh')
      AND v.sold_at < ((p_to+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh')
  ), daily AS (
    SELECT v.sale_date_hcm AS day,count(*)::integer AS n,sum(v.gross_sales) AS amount
    FROM receipts v GROUP BY v.sale_date_hcm
  ), offenders AS (
    SELECT v.sale_date_hcm AS day,v.store_id,count(*)::integer AS n
    FROM receipts v WHERE (v.sold_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::time>=time '21:45'
    GROUP BY v.sale_date_hcm,v.store_id
  ), failures AS (
    SELECT o.day,sum(o.n)::integer AS n,
      jsonb_agg(jsonb_build_object('store_id',o.store_id,'receipt_count',o.n) ORDER BY o.store_id) AS stores
    FROM offenders o GROUP BY o.day
  )
  SELECT d::date,s.n,coalesce(t.n,0),coalesce(t.amount,0),coalesce(f.n,0),coalesce(f.stores,'[]'::jsonb)
  FROM generate_series(p_from::timestamp,p_to::timestamp,interval '1 day') d
  CROSS JOIN scope s LEFT JOIN daily t ON t.day=d::date LEFT JOIN failures f ON f.day=d::date;
END $$;
REVOKE ALL ON FUNCTION public.restaurant_sales_totals_range(date,date) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.restaurant_sales_totals_range(date,date) TO service_role;

CREATE OR REPLACE FUNCTION public.restaurant_finalize_daily_sales_at(p_business_date date,p_observed_at timestamptz)
RETURNS public.restaurant_daily_sales_finalizations
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_existing public.restaurant_daily_sales_finalizations%ROWTYPE;
  v_result public.restaurant_daily_sales_finalizations%ROWTYPE; t record;
BEGIN
  IF p_business_date IS NULL OR p_observed_at IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_FINALIZATION_INPUT_REQUIRED';
  END IF;
  IF (p_observed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date<>p_business_date THEN
    RAISE EXCEPTION 'RESTAURANT_FINALIZATION_DATE_INVALID';
  END IF;
  IF (p_observed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::time<time '22:20' THEN
    RAISE EXCEPTION 'RESTAURANT_FINALIZATION_TOO_EARLY';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('restaurant-daily-sales:'||p_business_date::text));
  SELECT * INTO v_existing FROM public.restaurant_daily_sales_finalizations f WHERE f.business_date=p_business_date;
  IF FOUND THEN
    IF v_existing.store_count=0 THEN RAISE EXCEPTION 'RESTAURANT_FINALIZATION_REPAIR_REQUIRED'; END IF;
    RETURN v_existing;
  END IF;
  SELECT * INTO t FROM public.restaurant_sales_totals_range(p_business_date,p_business_date);
  IF t.store_count=0 THEN RAISE EXCEPTION 'RESTAURANT_FINALIZATION_NO_STORES'; END IF;
  INSERT INTO public.restaurant_daily_sales_finalizations(
    business_date,status,store_count,receipt_count,gross_sales,post_cutoff_receipt_count,
    offending_stores,observed_at,finalized_at)
  VALUES(p_business_date,CASE WHEN t.post_cutoff_receipt_count>0 THEN 'data_integrity_failed' ELSE 'finalized' END,
    t.store_count,CASE WHEN t.post_cutoff_receipt_count=0 THEN t.receipt_count END,
    CASE WHEN t.post_cutoff_receipt_count=0 THEN t.gross_sales END,t.post_cutoff_receipt_count,
    t.offending_stores,p_observed_at,CASE WHEN t.post_cutoff_receipt_count=0 THEN p_observed_at END)
  RETURNING * INTO v_result;
  RETURN v_result;
END $$;
-- Preserve the existing no-application-write contract.
REVOKE ALL ON FUNCTION public.restaurant_finalize_daily_sales_at(date,timestamptz) FROM PUBLIC,anon,authenticated,service_role;

CREATE TABLE IF NOT EXISTS public.restaurant_sales_finalization_repairs(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), finalization_id uuid NOT NULL,
  business_date date NOT NULL, previous_record jsonb NOT NULL, corrected_record jsonb NOT NULL,
  reason text NOT NULL CHECK(length(btrim(reason))>=10),
  repaired_at timestamptz NOT NULL DEFAULT now(), repaired_by text NOT NULL DEFAULT session_user
);
ALTER TABLE public.restaurant_sales_finalization_repairs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.restaurant_sales_finalization_repairs FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.restaurant_sales_finalization_repairs TO service_role;
CREATE TRIGGER restaurant_sales_repairs_immutable BEFORE UPDATE OR DELETE ON public.restaurant_sales_finalization_repairs
FOR EACH ROW EXECUTE FUNCTION public.enforce_restaurant_finalization_immutable();
DO $$ BEGIN
  IF position('restaurant_cutoff_policies' IN pg_get_functiondef('public.restaurant_sales_totals_range(date,date)'::regprocedure))>0
    OR has_function_privilege('authenticated','public.restaurant_sales_totals_range(date,date)','execute') THEN
    RAISE EXCEPTION 'RESTAURANT_SALES_SOURCE_VERIFY_FAILED';
  END IF;
END $$;
COMMIT;
