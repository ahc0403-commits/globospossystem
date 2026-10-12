SET fixture.super_admin='true';
SET request.jwt.claim.sub='00000000-0000-0000-0000-000000000001';
ALTER TABLE public.daily_closings ADD COLUMN payments_total numeric DEFAULT 0,
 ADD COLUMN payments_cash numeric DEFAULT 0, ADD COLUMN expected_cash_amount numeric DEFAULT 0;
CREATE UNIQUE INDEX fixture_closing_store_day ON daily_closings(restaurant_id,closing_date);
CREATE TABLE direct_order_driver_cash_movements(id uuid DEFAULT gen_random_uuid(),restaurant_id uuid,kind text,method text,amount numeric,occurred_at timestamptz);
CREATE TABLE direct_order_refund_records(id uuid DEFAULT gen_random_uuid(),restaurant_id uuid,amount numeric,recorded_at timestamptz);
CREATE TABLE direct_order_refund_evidence(refund_id uuid,method text);
CREATE FUNCTION require_pos_admin_actor_for_store(uuid,text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 IF auth.uid() IS NULL OR (NOT is_super_admin() AND $1<>COALESCE(NULLIF(current_setting('fixture.allowed_store',true),'')::uuid,'20000000-0000-0000-0000-000000000001'::uuid)) THEN RAISE EXCEPTION '%',$2; END IF;
END $$;
CREATE FUNCTION get_daily_closing_days(p_store_id uuid,p_limit integer DEFAULT 30)
RETURNS TABLE(closing_date date,close_source text,payments_cash numeric,counted_cash_amount numeric,opening_cash_amount numeric,cash_variance numeric,
 direct_order_cash_refunds numeric,delivery_cash_paid numeric,delivery_cash_recovered numeric,ledger_payments_cash numeric)
LANGUAGE plpgsql AS $$
DECLARE v_limit int:=LEAST(GREATEST(COALESCE(p_limit,30),1),90);
BEGIN
  PERFORM public.require_pos_admin_actor_for_store(p_store_id,'DAILY_CLOSINGS_FORBIDDEN');
 RETURN QUERY WITH business_days AS(SELECT ((now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date - day_offset)::date business_date
 FROM generate_series(0,v_limit-1) days(day_offset))
 SELECT day.business_date,d.close_source,COALESCE(d.payments_cash,p.cash,0),d.counted_cash_amount,d.opening_cash_amount,d.cash_variance,
 d.direct_order_cash_refunds,d.delivery_cash_paid,d.delivery_cash_recovered,COALESCE(p.cash,0)
 FROM business_days day LEFT JOIN daily_closings d ON d.restaurant_id=p_store_id AND d.closing_date=day.business_date
 LEFT JOIN(SELECT (created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS day,sum(COALESCE(amount_portion,amount)) cash
 FROM payments WHERE restaurant_id=p_store_id AND is_revenue AND method='CASH'
 AND created_at>=((now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date-v_limit+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'
 GROUP BY 1) p ON p.day=day.business_date;
END $$;
CREATE FUNCTION get_daily_closing_cash_before_reconciliation(p_store_id uuid,p_closing_date date)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE amount numeric;
BEGIN
 PERFORM require_pos_admin_actor_for_store(p_store_id,'DAILY_CLOSING_FORBIDDEN');
 SELECT COALESCE(sum(COALESCE(p.amount_portion,p.amount)),0) INTO amount FROM payments p
 WHERE p.restaurant_id=p_store_id AND p.is_revenue AND p.method='CASH'
 AND p.created_at>=p_closing_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'
 AND p.created_at<(p_closing_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
 RETURN jsonb_build_object('closing_date',p_closing_date,'opening_cash_amount',5000000,'payments_cash',amount,'expected_cash_amount',5000000+amount);
END $$;
CREATE FUNCTION create_daily_closing_before_reconciliation(p_store_id uuid,p_notes text,p_cash_denominations jsonb,p_opening_cash_amount numeric,p_closing_date date)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE counted numeric;cash numeric;total numeric;
BEGIN
 PERFORM require_pos_admin_actor_for_store(p_store_id,'DAILY_CLOSING_FORBIDDEN');
 IF EXISTS(SELECT 1 FROM daily_closings WHERE restaurant_id=p_store_id AND closing_date=p_closing_date AND close_source='manual') THEN RAISE EXCEPTION 'DAILY_CLOSING_ALREADY_EXISTS'; END IF;
 SELECT COALESCE(sum(key::numeric*value::numeric),0) INTO counted FROM jsonb_each_text(p_cash_denominations);
 SELECT COALESCE(sum(COALESCE(p.amount_portion,p.amount)) FILTER(WHERE method='CASH'),0),COALESCE(sum(COALESCE(p.amount_portion,p.amount)),0)
 INTO cash,total FROM payments p WHERE p.restaurant_id=p_store_id AND p.is_revenue
 AND p.created_at>=p_closing_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh' AND p.created_at<(p_closing_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
 INSERT INTO daily_closings(restaurant_id,closing_date,close_source,counted_cash_amount,opening_cash_amount,payments_cash,payments_total,expected_cash_amount,cash_variance)
 VALUES(p_store_id,p_closing_date,'manual',counted,p_opening_cash_amount,cash,total,p_opening_cash_amount+cash,counted-p_opening_cash_amount-cash)
 ON CONFLICT(restaurant_id,closing_date) DO UPDATE SET close_source='manual',counted_cash_amount=EXCLUDED.counted_cash_amount,
 opening_cash_amount=EXCLUDED.opening_cash_amount,payments_cash=EXCLUDED.payments_cash,payments_total=EXCLUDED.payments_total;
 RETURN jsonb_build_object('closing_date',p_closing_date,'counted_cash_amount',counted);
END $$;
