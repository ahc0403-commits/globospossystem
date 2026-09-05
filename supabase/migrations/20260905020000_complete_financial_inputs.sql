BEGIN;

-- Only the explicitly listed existing projections are available. Identifiers
-- and SQL fragments never come from the caller; all values use EXECUTE USING.
-- Invoker security preserves underlying table/view RLS and SELECT privileges.
CREATE OR REPLACE FUNCTION public.get_financial_input_page(
  p_source text,
  p_store_ids uuid[] DEFAULT NULL,
  p_from timestamptz DEFAULT NULL,
  p_to timestamptz DEFAULT NULL,
  p_from_date date DEFAULT NULL,
  p_to_date date DEFAULT NULL,
  p_cursor jsonb DEFAULT NULL,
  p_expected_revision text DEFAULT NULL,
  p_page_size integer DEFAULT 500
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_query text;
  v_order text;
  v_cursor text;
  v_after text;
  v_arity integer := 2;
  v_rows jsonb;
  v_has_more boolean;
  v_revision text;
  v_count bigint;
  v_context text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'FINANCIAL_INPUT_FORBIDDEN'; END IF;
  IF p_source IS NULL OR p_page_size IS NULL OR p_page_size NOT BETWEEN 1 AND 500
    OR (p_cursor IS NULL) <> (p_expected_revision IS NULL)
    OR (p_expected_revision IS NOT NULL AND p_expected_revision !~ '^[0-9a-f]{32}$') THEN
    RAISE EXCEPTION 'FINANCIAL_INPUT_QUERY_INVALID';
  END IF;

  IF p_source <> 'holidays' AND (
    COALESCE(cardinality(p_store_ids), 0) = 0
    OR EXISTS (
      SELECT 1 FROM unnest(p_store_ids) requested(id)
      WHERE requested.id IS NULL OR (NOT COALESCE(public.is_super_admin(), false) AND NOT EXISTS (
        SELECT 1 FROM public.user_accessible_stores(auth.uid()) allowed(id)
        WHERE allowed.id = requested.id
      ))
    )
  ) THEN RAISE EXCEPTION 'FINANCIAL_INPUT_FORBIDDEN'; END IF;

  IF p_source IN ('allowances', 'holidays', 'photoSales') AND (
    p_from_date IS NULL OR p_to_date IS NULL OR p_to_date < p_from_date
    OR NOT isfinite(p_from_date) OR NOT isfinite(p_to_date)
  ) THEN RAISE EXCEPTION 'FINANCIAL_INPUT_QUERY_INVALID'; END IF;
  IF p_source IN ('revenuePayments', 'servicePayments', 'externalSales',
                  'orders', 'cancelledItems', 'einvoiceJobs') AND (
    p_from IS NULL OR p_to IS NULL OR p_to <= p_from
    OR NOT isfinite(p_from) OR NOT isfinite(p_to)
  ) THEN RAISE EXCEPTION 'FINANCIAL_INPUT_QUERY_INVALID'; END IF;

  -- The derived table remains flattenable. Continuation predicates are added
  -- only for continuation pages, avoiding nullable OR predicates on index keys.
  CASE p_source
    WHEN 'staff' THEN
      v_query := 'SELECT id, store_id, employee_number, full_name, employment_role
        FROM public.store_employees WHERE store_id = ANY($1) AND is_active = true';
      v_order := 'q.id'; v_cursor := 'jsonb_build_array(q.id)';
      v_after := 'q.id > ($6->>0)::uuid'; v_arity := 1;
    WHEN 'allowances' THEN
      v_query := 'SELECT id, store_id, employee_id, work_date, is_split_shift,
        meal_allowance_amount, parking_allowance_amount
        FROM public.employee_daily_allowances WHERE store_id = ANY($1)
          AND work_date >= $4 AND work_date <= $5';
      v_order := 'q.work_date, q.id'; v_cursor := 'jsonb_build_array(q.work_date, q.id)';
      v_after := '(q.work_date, q.id) > (($6->>0)::date, ($6->>1)::uuid)';
    WHEN 'holidays' THEN
      v_query := 'SELECT holiday_date FROM public.vietnam_public_holidays
        WHERE is_active = true AND holiday_date >= $4 AND holiday_date <= $5';
      v_order := 'q.holiday_date'; v_cursor := 'jsonb_build_array(q.holiday_date)';
      v_after := 'q.holiday_date > ($6->>0)::date'; v_arity := 1;
    WHEN 'revenuePayments' THEN
      v_query := 'SELECT p.id, p.restaurant_id, p.order_id, p.amount, p.amount_portion,
        p.method, p.created_at, p.proof_required, p.proof_photo_url,
        CASE WHEN o.id IS NULL THEN NULL ELSE jsonb_build_object(''sales_channel'', o.sales_channel) END AS orders
        FROM public.payments p LEFT JOIN public.orders o ON o.id = p.order_id
        WHERE p.restaurant_id = ANY($1) AND p.is_revenue = true
          AND p.created_at >= $2 AND p.created_at < $3';
    WHEN 'servicePayments' THEN
      v_query := 'SELECT id, restaurant_id, amount, created_at FROM public.payments
        WHERE restaurant_id = ANY($1) AND is_revenue = false
          AND created_at >= $2 AND created_at < $3';
    WHEN 'externalSales' THEN
      v_query := 'SELECT id, restaurant_id, net_amount, completed_at FROM public.external_sales
        WHERE restaurant_id = ANY($1) AND is_revenue = true AND order_status = ''completed''
          AND completed_at >= $2 AND completed_at < $3';
      v_order := 'q.completed_at, q.id'; v_cursor := 'jsonb_build_array(q.completed_at, q.id)';
      v_after := '(q.completed_at, q.id) > (($6->>0)::timestamptz, ($6->>1)::uuid)';
    WHEN 'photoSales' THEN
      v_query := 'SELECT store_id, sale_date, total_gross_sales, total_transactions,
        total_service_amount FROM public.v_photo_objet_daily_summary
        WHERE store_id = ANY($1) AND sale_date >= $4 AND sale_date <= $5';
      v_order := 'q.sale_date, q.store_id'; v_cursor := 'jsonb_build_array(q.sale_date, q.store_id)';
      v_after := '(q.sale_date, q.store_id) > (($6->>0)::date, ($6->>1)::uuid)';
    WHEN 'orders' THEN
      v_query := 'SELECT id, restaurant_id, status, created_at FROM public.orders
        WHERE restaurant_id = ANY($1) AND created_at >= $2 AND created_at < $3';
    WHEN 'cancelledItems' THEN
      v_query := 'SELECT i.id, i.order_id, o.restaurant_id, o.created_at
        FROM public.order_items i JOIN public.orders o ON o.id = i.order_id
        WHERE i.status = ''cancelled'' AND o.restaurant_id = ANY($1)
          AND o.created_at >= $2 AND o.created_at < $3';
    WHEN 'einvoiceJobs' THEN
      v_query := 'SELECT id, store_id, order_id, status, error_message, manual_action_type,
        created_at FROM public.meinvoice_jobs
        WHERE store_id = ANY($1) AND created_at >= $2 AND created_at < $3';
    ELSE RAISE EXCEPTION 'FINANCIAL_INPUT_SOURCE_INVALID';
  END CASE;
  IF v_order IS NULL THEN
    v_order := 'q.created_at, q.id'; v_cursor := 'jsonb_build_array(q.created_at, q.id)';
    v_after := '(q.created_at, q.id) > (($6->>0)::timestamptz, ($6->>1)::uuid)';
  END IF;
  IF p_cursor IS NOT NULL THEN
    IF jsonb_typeof(p_cursor) <> 'array' THEN
      RAISE EXCEPTION 'FINANCIAL_INPUT_CURSOR_INVALID';
    END IF;
    IF jsonb_array_length(p_cursor) <> v_arity OR EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_cursor) element
      WHERE jsonb_typeof(element) <> 'string' OR element #>> '{}' = ''
    ) THEN RAISE EXCEPTION 'FINANCIAL_INPUT_CURSOR_INVALID'; END IF;
  END IF;

  EXECUTE format(
    'SELECT COALESCE(jsonb_agg(to_jsonb(page) ORDER BY %s), ''[]''::jsonb)
       FROM (SELECT q.*, %s AS _cursor FROM (%s) q %s ORDER BY %s LIMIT $7) page',
    replace(v_order, 'q.', 'page.'), v_cursor, v_query,
    CASE WHEN p_cursor IS NULL THEN '' ELSE 'WHERE ' || v_after END, v_order
  ) INTO v_rows
    USING p_store_ids, p_from, p_to, p_from_date, p_to_date, p_cursor, p_page_size + 1;
  v_has_more := jsonb_array_length(v_rows) > p_page_size;
  IF v_has_more THEN v_rows := v_rows - p_page_size; END IF;

  -- Validate each dataset across its pages, without rescanning it on every page.
  -- Hash only the projected input values (also works for the existing RLS view).
  -- This is not a transaction spanning separate datasets or the whole report.
  IF p_cursor IS NULL OR NOT v_has_more THEN
    v_context := jsonb_build_array(p_source, auth.uid(), p_store_ids,
      p_from, p_to, p_from_date, p_to_date)::text;
    EXECUTE format(
      'SELECT md5($8 || COALESCE(string_agg(md5(to_jsonb(q)::text), '''' ORDER BY %s), '''')), count(*)
         FROM (%s) q', v_order, v_query
    ) INTO v_revision, v_count
      USING p_store_ids, p_from, p_to, p_from_date, p_to_date, p_cursor, p_page_size, v_context;
    IF p_expected_revision IS NOT NULL AND p_expected_revision <> v_revision THEN
      RAISE EXCEPTION 'FINANCIAL_INPUT_CHANGED';
    END IF;
  ELSE
    v_revision := p_expected_revision;
  END IF;
  RETURN jsonb_build_object('rows', v_rows, 'has_more', v_has_more,
    'revision', v_revision, 'total_count', v_count);
END;
$$;

REVOKE ALL ON FUNCTION public.get_financial_input_page(
  text, uuid[], timestamptz, timestamptz, date, date, jsonb, text, integer
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_financial_input_page(
  text, uuid[], timestamptz, timestamptz, date, date, jsonb, text, integer
) TO authenticated;
COMMENT ON FUNCTION public.get_financial_input_page(
  text, uuid[], timestamptz, timestamptz, date, date, jsonb, text, integer
) IS 'Allowlisted financial read projections with existing RLS, bounded native keyset pages and first/final input validation. No financial arithmetic is changed.';
COMMIT;
