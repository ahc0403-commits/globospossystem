BEGIN;
CREATE OR REPLACE FUNCTION public.get_payroll_employee_attendance_page(
  p_store_id uuid,
  p_employee_id uuid,
  p_from timestamptz,
  p_to timestamptz,
  p_page_size integer DEFAULT 500,
  p_after_logged_at timestamptz DEFAULT NULL,
  p_after_id uuid DEFAULT NULL,
  p_expected_revision text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_rows jsonb;
  v_has_more boolean;
  v_revision text;
  v_total_count bigint;
BEGIN
  SELECT actor.* INTO v_actor
  FROM public.users actor
  WHERE actor.auth_id = auth.uid() AND actor.is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role IS NULL OR v_actor.role NOT IN (
    'admin', 'store_admin', 'brand_admin', 'super_admin',
    'photo_objet_master', 'photo_objet_store_admin',
    'photo_objet_store_operator'
  ) THEN
    RAISE EXCEPTION 'ATTENDANCE_VIEW_FORBIDDEN';
  END IF;

  IF p_employee_id IS NULL OR p_store_id IS NULL OR p_from IS NULL OR p_to IS NULL
     OR p_to <= p_from OR NOT isfinite(p_from) OR NOT isfinite(p_to)
     OR p_page_size IS NULL OR p_page_size NOT BETWEEN 1 AND 500
     OR (p_after_logged_at IS NULL) <> (p_after_id IS NULL)
     OR (p_after_id IS NULL) <> (p_expected_revision IS NULL)
     OR (p_after_logged_at IS NOT NULL AND
         (p_after_logged_at < p_from OR p_after_logged_at >= p_to))
     OR (p_expected_revision IS NOT NULL AND
         p_expected_revision !~ '^[0-9a-f]{32}$') THEN
    RAISE EXCEPTION 'ATTENDANCE_QUERY_INVALID';
  END IF;

  IF v_actor.role <> 'super_admin' AND NOT EXISTS (
    SELECT 1 FROM public.user_accessible_stores(auth.uid()) scope(store_id)
    WHERE scope.store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'ATTENDANCE_VIEW_FORBIDDEN';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(page) ORDER BY page.logged_at, page.id), '[]')
  INTO v_rows
  FROM (
    SELECT log.id, log.restaurant_id, log.user_id, log.employee_id,
      log.type, log.logged_at,
      COALESCE(NULLIF(btrim(employee.full_name), ''),
               NULLIF(btrim(legacy_user.full_name), ''),
               NULLIF(btrim(employee.employee_number), ''), '-') AS person_name,
      COALESCE(NULLIF(btrim(employee.employment_role), ''),
               NULLIF(btrim(legacy_user.role), ''), 'staff') AS person_role,
      employee.employee_number
    FROM public.attendance_logs log
    LEFT JOIN public.store_employees employee ON employee.id = log.employee_id
    LEFT JOIN public.users legacy_user ON legacy_user.id = log.user_id
    WHERE log.restaurant_id = p_store_id
      AND log.logged_at >= p_from AND log.logged_at < p_to
      AND (log.employee_id = p_employee_id OR (log.employee_id IS NULL AND log.user_id = p_employee_id))
      AND (p_after_id IS NULL OR
           (log.logged_at, log.id) > (p_after_logged_at, p_after_id))
    ORDER BY log.logged_at, log.id
    LIMIT p_page_size + 1
  ) page;

  v_has_more := jsonb_array_length(v_rows) > p_page_size;
  IF v_has_more THEN v_rows := v_rows - p_page_size; END IF;

  -- Compare the complete input only on the first and final pages: two scans,
  -- not one per page. xmin also detects edits that restore an earlier value.
  -- This is an optimistic read check, not a persistent exported MVCC snapshot.
  -- A change fails the entire calculation instead of returning a partial wage.
  IF p_after_id IS NULL OR NOT v_has_more THEN
    SELECT md5(p_store_id::text || ':' || p_employee_id::text || ':' || extract(epoch FROM p_from)::text ||
               ':' || extract(epoch FROM p_to)::text || ':' ||
               COALESCE(string_agg(
                 format('%s:%s:%s:%s', log.id, log.xmin::text,
                        employee.xmin::text, legacy_user.xmin::text),
                 ',' ORDER BY log.id), '')), count(*)
    INTO v_revision, v_total_count
    FROM public.attendance_logs log
    LEFT JOIN public.store_employees employee ON employee.id = log.employee_id
    LEFT JOIN public.users legacy_user ON legacy_user.id = log.user_id
    WHERE log.restaurant_id = p_store_id
      AND log.logged_at >= p_from AND log.logged_at < p_to
      AND (log.employee_id = p_employee_id OR (log.employee_id IS NULL AND log.user_id = p_employee_id));

    IF p_expected_revision IS NOT NULL AND v_revision <> p_expected_revision THEN
      RAISE EXCEPTION 'PAYROLL_ATTENDANCE_CHANGED';
    END IF;
  ELSE
    v_revision := p_expected_revision;
  END IF;

  RETURN jsonb_build_object('rows', v_rows, 'has_more', v_has_more,
                            'revision', v_revision, 'total_count', v_total_count);
END;
$$;
REVOKE ALL ON FUNCTION public.get_payroll_employee_attendance_page(uuid,uuid,timestamptz,timestamptz,integer,timestamptz,uuid,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.get_payroll_employee_attendance_page(uuid,uuid,timestamptz,timestamptz,integer,timestamptz,uuid,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.get_employee_financial_input_page(
  p_source text,
  p_employee_id uuid,
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
  IF p_employee_id IS NULL OR p_source NOT IN ('staff','allowances') THEN RAISE EXCEPTION 'FINANCIAL_INPUT_QUERY_INVALID'; END IF;
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
        FROM public.store_employees WHERE store_id = ANY($1) AND is_active = true AND id = $9';
      v_order := 'q.id'; v_cursor := 'jsonb_build_array(q.id)';
      v_after := 'q.id > ($6->>0)::uuid'; v_arity := 1;
    WHEN 'allowances' THEN
      v_query := 'SELECT id, store_id, employee_id, work_date, is_split_shift,
        meal_allowance_amount, parking_allowance_amount
        FROM public.employee_daily_allowances WHERE store_id = ANY($1)
          AND work_date >= $4 AND work_date <= $5 AND employee_id = $9';
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
    USING p_store_ids, p_from, p_to, p_from_date, p_to_date, p_cursor, p_page_size + 1, NULL, p_employee_id;
  v_has_more := jsonb_array_length(v_rows) > p_page_size;
  IF v_has_more THEN v_rows := v_rows - p_page_size; END IF;

  -- Validate each dataset across its pages, without rescanning it on every page.
  -- Hash only the projected input values (also works for the existing RLS view).
  -- This is not a transaction spanning separate datasets or the whole report.
  IF p_cursor IS NULL OR NOT v_has_more THEN
    v_context := jsonb_build_array(p_source, auth.uid(), p_store_ids,
      p_from, p_to, p_from_date, p_to_date, p_employee_id)::text;
    EXECUTE format(
      'SELECT md5($8 || COALESCE(string_agg(md5(to_jsonb(q)::text), '''' ORDER BY %s), '''')), count(*)
         FROM (%s) q', v_order, v_query
    ) INTO v_revision, v_count
      USING p_store_ids, p_from, p_to, p_from_date, p_to_date, p_cursor, p_page_size, v_context, p_employee_id;
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
REVOKE ALL ON FUNCTION public.get_employee_financial_input_page(text,uuid,uuid[],timestamptz,timestamptz,date,date,jsonb,text,integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.get_employee_financial_input_page(text,uuid,uuid[],timestamptz,timestamptz,date,date,jsonb,text,integer) TO authenticated;
COMMIT;
