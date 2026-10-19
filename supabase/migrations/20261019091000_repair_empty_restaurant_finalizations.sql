-- production-gate: self-verifying
-- Bounded recovery; original values remain immutable in the repair audit.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';
SELECT set_config('analytics.repair_from', '2026-10-05', true),
       set_config('analytics.repair_to', '2026-10-18', true),
       set_config('analytics.repair_reason', 'Repair empty Restaurant reporting scope, 2026-10-19', true);
DO $$ BEGIN
  IF length(btrim(current_setting('analytics.repair_reason')))<10 THEN
    RAISE EXCEPTION 'Repair reason required';
  END IF;
  IF current_setting('analytics.repair_to')::date >= (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date THEN
    RAISE EXCEPTION 'Only completed historical business days may be repaired';
  END IF;
END $$;
LOCK TABLE public.restaurant_daily_sales_finalizations IN ACCESS EXCLUSIVE MODE;
CREATE TEMP TABLE analytics_repairs ON COMMIT DROP AS
SELECT f.id,to_jsonb(f) AS previous_record,t.*
FROM public.restaurant_daily_sales_finalizations f
JOIN public.restaurant_sales_totals_range(current_setting('analytics.repair_from')::date,
  current_setting('analytics.repair_to')::date) t USING(business_date)
WHERE f.store_count=0 AND f.status='finalized' AND f.gross_sales=0 AND f.receipt_count=0;
DO $$ BEGIN
  IF EXISTS(SELECT 1 FROM analytics_repairs WHERE store_count=0) THEN
    RAISE EXCEPTION 'Cannot repair without eligible Restaurant stores';
  END IF;
END $$;
-- Exclusive lock prevents any concurrent application operation during the
-- brief trigger suspension. Any failure rolls the suspension and data back.
ALTER TABLE public.restaurant_daily_sales_finalizations DISABLE TRIGGER trg_restaurant_finalization_immutable;
WITH corrected AS (
  UPDATE public.restaurant_daily_sales_finalizations f SET
    status=CASE WHEN r.post_cutoff_receipt_count>0 THEN 'data_integrity_failed' ELSE 'finalized' END,
    store_count=r.store_count,receipt_count=CASE WHEN r.post_cutoff_receipt_count=0 THEN r.receipt_count END,
    gross_sales=CASE WHEN r.post_cutoff_receipt_count=0 THEN r.gross_sales END,
    post_cutoff_receipt_count=r.post_cutoff_receipt_count,offending_stores=r.offending_stores,
    finalized_at=CASE WHEN r.post_cutoff_receipt_count=0 THEN now() END
  FROM analytics_repairs r WHERE f.id=r.id RETURNING f.*
)
INSERT INTO public.restaurant_sales_finalization_repairs(finalization_id,business_date,previous_record,corrected_record,reason)
SELECT c.id,c.business_date,r.previous_record,to_jsonb(c),current_setting('analytics.repair_reason')
FROM corrected c JOIN analytics_repairs r ON r.id=c.id;
ALTER TABLE public.restaurant_daily_sales_finalizations ENABLE TRIGGER trg_restaurant_finalization_immutable;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM public.restaurant_daily_sales_finalizations
    WHERE business_date between date '2026-10-05' and date '2026-10-18'
      AND status='finalized' AND store_count=0)
    OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='public.restaurant_daily_sales_finalizations'::regclass
      AND tgname='trg_restaurant_finalization_immutable' AND tgenabled='O') THEN
    RAISE EXCEPTION 'RESTAURANT_SALES_REPAIR_VERIFY_FAILED';
  END IF;
END $$;
COMMIT;
