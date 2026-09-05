BEGIN;
-- Same financial definitions as the complete-input report, aggregated within
-- one statement snapshot. Only actionable exceptions retain transaction IDs.
CREATE OR REPLACE FUNCTION public.get_store_report_summary(
  p_store_id uuid, p_from_date date, p_to_date date
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = public, auth, pg_catalog AS $$
DECLARE v_from timestamptz; v_to timestamptz; v_result jsonb;
BEGIN
  IF auth.uid() IS NULL OR p_store_id IS NULL OR (
    NOT COALESCE(public.is_super_admin(), false) AND NOT EXISTS (
      SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(id) WHERE s.id = p_store_id
    )) THEN RAISE EXCEPTION 'STORE_REPORT_FORBIDDEN'; END IF;
  IF p_from_date IS NULL OR p_to_date IS NULL OR p_to_date < p_from_date
    OR NOT isfinite(p_from_date) OR NOT isfinite(p_to_date) THEN
    RAISE EXCEPTION 'STORE_REPORT_QUERY_INVALID';
  END IF;
  v_from := p_from_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_to := (p_to_date + 1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  WITH p AS MATERIALIZED (
    SELECT p.id, p.order_id, coalesce(p.amount,0) AS received,
      coalesce(p.amount_portion,p.amount,0) AS sales, p.created_at,
      (p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS day,
      extract(hour FROM p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::int AS hour,
      coalesce(lower(o.sales_channel::text),'') = 'delivery' AS delivery,
      coalesce('order:' || p.order_id::text, 'payment:' || p.id::text) AS tx,
      CASE lower(btrim(coalesce(p.method::text,'')))
        WHEN 'card' THEN 'CREDITCARD' WHEN 'credit_card' THEN 'CREDITCARD'
        WHEN 'pay' THEN 'OTHER' WHEN 'epay' THEN 'OTHER' WHEN 'e_pay' THEN 'OTHER'
        ELSE upper(btrim(coalesce(p.method::text,''))) END AS method,
      coalesce(p.proof_required,false) AS proof_required,
      btrim(coalesce(p.proof_photo_url,'')) <> '' AS proof_present
    FROM public.payments p LEFT JOIN public.orders o ON o.id = p.order_id
    WHERE p.restaurant_id = p_store_id AND p.is_revenue = true
      AND p.created_at >= v_from AND p.created_at < v_to
  ), e AS MATERIALIZED (
    SELECT coalesce(net_amount,0) AS sales,
      (completed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS day,
      extract(hour FROM completed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::int AS hour
    FROM public.external_sales WHERE restaurant_id = p_store_id AND is_revenue = true
      AND order_status = 'completed' AND completed_at >= v_from AND completed_at < v_to
  ), f AS MATERIALIZED (
    SELECT sale_date AS day,
      greatest(coalesce(total_gross_sales,0)-coalesce(total_service_amount,0),0) AS sales,
      coalesce(total_service_amount,0) AS service, coalesce(total_transactions,0) AS teams
    FROM public.v_photo_objet_daily_summary WHERE store_id = p_store_id
      AND sale_date >= p_from_date AND sale_date <= p_to_date
  ), day_contributions AS (
    SELECT day, coalesce(sum(sales) FILTER (WHERE NOT delivery),0) AS dine_in,
      coalesce(sum(sales) FILTER (WHERE delivery),0) AS delivery,
      count(DISTINCT tx) FILTER (WHERE NOT delivery) AS teams,
      coalesce(sum(received) FILTER (WHERE method='CASH'),0) AS cash,
      coalesce(sum(received) FILTER (WHERE method IN ('CREDITCARD','ATM')),0) AS card,
      coalesce(sum(received) FILTER (WHERE method='BANKTRANSFER'),0) AS bank,
      coalesce(sum(received) FILTER (WHERE method NOT IN ('CASH','CREDITCARD','ATM','BANKTRANSFER')),0) AS pay,
      sum(received-sales) AS variance FROM p GROUP BY day
    UNION ALL SELECT day,0,sum(sales),0,0,0,0,0,0 FROM e GROUP BY day
    UNION ALL SELECT day,sales,0,teams,0,0,0,0,0 FROM f
  ), daily AS (
    SELECT day, sum(dine_in) AS dine_in, sum(delivery) AS delivery, sum(teams) AS teams,
      sum(cash) AS cash, sum(card) AS card, sum(bank) AS bank, sum(pay) AS pay,
      sum(variance) AS variance FROM day_contributions GROUP BY day
  ), hourly AS (
    SELECT hour,sum(sales) AS amount FROM (
      SELECT hour,sales FROM p UNION ALL SELECT hour,sales FROM e
    ) h GROUP BY hour
  ), methods AS (
    SELECT coalesce(nullif(method,''),'UNKNOWN') AS method,
      count(DISTINCT tx) AS count,sum(received) AS amount,
      CASE WHEN count(*) FILTER (WHERE proof_required)=0 THEN 100::numeric ELSE
        100.0 * count(*) FILTER (WHERE proof_required AND proof_present)
          / count(*) FILTER (WHERE proof_required) END AS proof_pct
    FROM p GROUP BY coalesce(nullif(method,''),'UNKNOWN')
  ), order_counts AS (
    SELECT count(*) AS total,
      count(*) FILTER (WHERE lower(status::text)='completed') AS completed,
      count(*) FILTER (WHERE lower(status::text)='cancelled') AS cancelled,
      count(*) FILTER (WHERE coalesce(lower(status::text),'') NOT IN ('completed','cancelled')) AS open
    FROM public.orders WHERE restaurant_id=p_store_id AND created_at>=v_from AND created_at<v_to
  ), latest_payment AS (
    SELECT DISTINCT ON (order_id) order_id,id FROM p WHERE order_id IS NOT NULL
    ORDER BY order_id,created_at DESC,id DESC
  ), jobs AS MATERIALIZED (
    SELECT j.id,j.order_id,lp.id AS payment_id,j.status,j.created_at,
      coalesce(nullif(btrim(j.error_message),''),btrim(j.manual_action_type),'') AS detail
    FROM public.meinvoice_jobs j LEFT JOIN latest_payment lp ON lp.order_id=j.order_id
    WHERE j.store_id=p_store_id AND j.created_at>=v_from AND j.created_at<v_to
      AND j.status IN ('failed','manual_action_required')
  ), stats AS (
    SELECT coalesce(sum(dine_in),0) AS dine_in,coalesce(sum(delivery),0) AS delivery,
      coalesce(sum(cash),0) AS cash,coalesce(sum(card),0) AS card,
      coalesce(sum(bank),0) AS bank,coalesce(sum(pay),0) AS pay,
      coalesce(sum(variance),0) AS variance FROM daily
  ), supplemental AS (
    SELECT (SELECT count(*) FROM e) + coalesce((SELECT sum(teams) FROM f),0) AS count
  )
  SELECT jsonb_build_object('version',1,'store_id',p_store_id,'from_date',p_from_date,'to_date',p_to_date,
    'dine_in',s.dine_in,'delivery',s.delivery,
    'service',coalesce((SELECT sum(amount) FROM public.payments
      WHERE restaurant_id=p_store_id AND is_revenue=false AND created_at>=v_from AND created_at<v_to),0)
      + coalesce((SELECT sum(service) FROM f),0),
    'cancelled_amount',public.get_store_sales_cancellation_total(p_store_id,v_from,v_to-interval '1 microsecond'),
    'total_orders',o.total+extra.count,'completed_orders',o.completed+extra.count,
    'paid_orders',(SELECT count(DISTINCT tx) FROM p)+extra.count,
    'open_orders',o.open,'cancelled_orders',o.cancelled,
    'cancelled_items',(SELECT count(*) FROM public.order_items i JOIN public.orders ord ON ord.id=i.order_id
      WHERE i.status='cancelled' AND ord.restaurant_id=p_store_id AND ord.created_at>=v_from AND ord.created_at<v_to),
    'cash',s.cash,'card',s.card,'bank',s.bank,'pay',s.pay,'variance',s.variance,
    'missing_proof_count',(SELECT count(*) FROM p WHERE proof_required AND NOT proof_present),
    'failed_einvoice_count',(SELECT count(*) FROM jobs),
    'proof_pct',(SELECT CASE WHEN count(*) FILTER (WHERE proof_required)=0 THEN 100::numeric ELSE
      100.0 * count(*) FILTER (WHERE proof_required AND proof_present) / count(*) FILTER (WHERE proof_required) END FROM p),
    'daily',coalesce((SELECT jsonb_agg(jsonb_build_object('date',day,'dine_in',dine_in,'delivery',delivery,
      'teams',teams,'cash',cash,'card',card,'bank',bank,'pay',pay,'variance',variance) ORDER BY day) FROM daily),'[]'::jsonb),
    'hourly',coalesce((SELECT jsonb_agg(jsonb_build_object('hour',hour,'amount',amount) ORDER BY hour) FROM hourly),'[]'::jsonb),
    'methods',coalesce((SELECT jsonb_agg(jsonb_build_object('method',method,'count',count,'amount',amount,
      'proof_pct',proof_pct) ORDER BY method) FROM methods),'[]'::jsonb),
    'missing_proof',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'order_id',order_id,'amount',received,
      'method',method,'created_at',created_at) ORDER BY created_at,id) FROM p WHERE proof_required AND NOT proof_present),'[]'::jsonb),
    'einvoice_issues',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'order_id',order_id,'payment_id',payment_id,
      'status',status,'detail',detail,'created_at',created_at) ORDER BY created_at,id) FROM jobs),'[]'::jsonb)
  ) INTO v_result FROM stats s CROSS JOIN order_counts o CROSS JOIN supplemental extra;
  RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION public.get_store_report_summary(uuid,date,date) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.get_store_report_summary(uuid,date,date) TO authenticated;
COMMIT;
