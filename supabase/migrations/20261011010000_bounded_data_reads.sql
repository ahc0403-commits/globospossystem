BEGIN;
-- Read contracts keep the old entry points and grants for deployed clients.
-- Indexes serve bounded index probes, not one remote request per item.
CREATE INDEX IF NOT EXISTS inventory_po_line_history_scope_idx
  ON public.inventory_purchase_order_lines(supplier_item_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS inventory_receipt_line_history_idx
  ON public.inventory_receipt_lines(purchase_order_line_id);

CREATE OR REPLACE FUNCTION public.get_inventory_supplier_history_batch(
  p_purchase_order_id uuid, p_supplier_item_ids uuid[]
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = public, auth, pg_catalog AS $$
DECLARE v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'INVENTORY_HISTORY_FORBIDDEN'; END IF;
  IF p_purchase_order_id IS NULL OR COALESCE(cardinality(p_supplier_item_ids),0) NOT BETWEEN 1 AND 100
    OR array_ndims(p_supplier_item_ids) <> 1 OR array_position(p_supplier_item_ids,NULL) IS NOT NULL
    OR cardinality(p_supplier_item_ids) <> (SELECT count(DISTINCT id) FROM unnest(p_supplier_item_ids) id)
  THEN RAISE EXCEPTION 'INVENTORY_HISTORY_QUERY_INVALID'; END IF;
  -- Invoker RLS applies both to the source order and every history/receipt row.
  IF NOT EXISTS (SELECT 1 FROM public.inventory_purchase_orders WHERE id=p_purchase_order_id)
    OR EXISTS (SELECT 1 FROM unnest(p_supplier_item_ids) requested(id) WHERE NOT EXISTS (
      SELECT 1 FROM public.inventory_purchase_order_lines l
      WHERE l.purchase_order_id=p_purchase_order_id AND l.supplier_item_id=requested.id
    )) THEN RAISE EXCEPTION 'INVENTORY_HISTORY_FORBIDDEN'; END IF;
  WITH selected AS MATERIALIZED (
    SELECT recent.* FROM unnest(p_supplier_item_ids) requested(id)
    CROSS JOIN LATERAL (
      SELECT l.* FROM public.inventory_purchase_order_lines l
      WHERE l.supplier_item_id=requested.id AND l.purchase_order_id<>p_purchase_order_id
      ORDER BY l.created_at DESC,l.id DESC LIMIT 3
    ) recent
  ), received AS MATERIALIZED (
    SELECT rl.purchase_order_line_id,
      sum(rl.received_quantity_base) AS received_quantity_base,
      sum(rl.accepted_quantity_base) AS accepted_quantity_base,
      sum(rl.rejected_quantity_base) AS rejected_quantity_base,
      (array_agg(r.status ORDER BY COALESCE(r.received_at,r.created_at) DESC,r.id DESC))[1] AS last_receipt_status,
      max(COALESCE(r.received_at,r.created_at)) AS last_receipt_at
    FROM selected l JOIN public.inventory_receipt_lines rl ON rl.purchase_order_line_id=l.id
    JOIN public.inventory_receipts r ON r.id=rl.receipt_id
    GROUP BY rl.purchase_order_line_id
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'supplier_item_id',l.supplier_item_id,'purchase_order_id',po.id,
    'purchase_order_no',po.purchase_order_no,'order_status',po.status,
    'ordered_at',po.created_at,'product_name',COALESCE(p.name,l.product_id::text,'-'),
    'ordered_quantity_base',l.ordered_quantity_base,'ordered_quantity_unit',l.ordered_quantity_unit,
    'order_unit',l.order_unit,'unit_price',l.unit_price,
    'received_quantity_base',COALESCE(r.received_quantity_base,0),
    'accepted_quantity_base',COALESCE(r.accepted_quantity_base,0),
    'rejected_quantity_base',COALESCE(r.rejected_quantity_base,0),
    'last_receipt_status',r.last_receipt_status,'last_receipt_at',r.last_receipt_at
  ) ORDER BY l.supplier_item_id,l.created_at DESC,l.id DESC),'[]') INTO v_result
  FROM selected l JOIN public.inventory_purchase_orders po ON po.id=l.purchase_order_id
  LEFT JOIN public.inventory_products p ON p.id=l.product_id
  LEFT JOIN received r ON r.purchase_order_line_id=l.id;
  RETURN jsonb_build_object('version',1,'rows',v_result);
END $$;
REVOKE ALL ON FUNCTION public.get_inventory_supplier_history_batch(uuid,uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_supplier_history_batch(uuid,uuid[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_store_menu_sales_analytics(
  p_store_id uuid,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_menu_scope text
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_result jsonb;
  v_menu_scope text := lower(btrim(p_menu_scope));
BEGIN
  IF p_store_id IS NULL
     OR p_start_at IS NULL
     OR p_end_at IS NULL
     OR p_menu_scope IS NULL
     OR v_menu_scope NOT IN ('all', 'regular', 'combo')
     OR p_start_at >= p_end_at
     OR p_end_at > p_start_at + interval '366 days' THEN
    RAISE EXCEPTION 'MENU_SALES_ANALYTICS_RANGE_INVALID';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  WITH candidate_orders AS MATERIALIZED (
    SELECT DISTINCT payment.order_id
    FROM public.payments payment
    WHERE payment.restaurant_id = p_store_id AND payment.is_revenue = true
      AND payment.created_at >= p_start_at AND payment.created_at < p_end_at
  ), paid_orders AS MATERIALIZED (
    SELECT
      order_row.id AS order_id,
      order_row.sales_channel,
      max(payment.created_at) AS paid_at
    FROM candidate_orders candidate
    JOIN public.orders order_row ON order_row.id = candidate.order_id
    JOIN public.payments payment
      ON payment.order_id = order_row.id
     AND payment.restaurant_id = order_row.restaurant_id
     AND payment.is_revenue = true
    WHERE order_row.restaurant_id = p_store_id
      AND order_row.status = 'completed'
    GROUP BY order_row.id, order_row.sales_channel
    HAVING max(payment.created_at) >= p_start_at
       AND max(payment.created_at) < p_end_at
  ),
  menu_lines AS MATERIALIZED (
    SELECT
      paid.order_id,
      paid.sales_channel,
      paid.paid_at,
      item.created_at AS line_created_at,
      CASE
        WHEN COALESCE(item.menu_item_id_snapshot, item.menu_item_id) IS NOT NULL
          THEN COALESCE(
            item.menu_item_id_snapshot,
            item.menu_item_id
          )::text
        ELSE 'name:' || md5(lower(btrim(COALESCE(
          NULLIF(item.display_name, ''),
          NULLIF(item.label, ''),
          'Unnamed menu'
        ))))
      END AS menu_key,
      CASE
        WHEN COALESCE(item.menu_item_id_snapshot, item.menu_item_id) IS NULL
          THEN 'name_fallback'
        ELSE 'stable_id'
      END AS identity_quality,
      COALESCE(
        NULLIF(btrim(item.display_name), ''),
        NULLIF(btrim(item.label), ''),
        'Unnamed menu'
      ) AS display_name,
      jsonb_array_length(
        COALESCE(item.combo_components, '[]'::jsonb)
      ) > 0 AS is_combo,
      item.quantity::bigint AS sold_quantity,
      COALESCE(item.paying_amount_inc_tax, 0)::numeric AS menu_sales_amount
    FROM paid_orders paid
    JOIN public.order_items item
      ON item.order_id = paid.order_id
     AND item.restaurant_id = p_store_id
    WHERE item.item_type = 'menu_item'
      AND item.status <> 'cancelled'
      AND COALESCE(item.is_service_item, false) = false
      AND CASE v_menu_scope
        WHEN 'regular' THEN jsonb_array_length(
          COALESCE(item.combo_components, '[]'::jsonb)
        ) = 0
        WHEN 'combo' THEN jsonb_array_length(
          COALESCE(item.combo_components, '[]'::jsonb)
        ) > 0
        ELSE true
      END
  ),
  menu_hours AS MATERIALIZED (
    SELECT
      line.menu_key,
      extract(hour FROM (
        line.paid_at AT TIME ZONE 'Asia/Ho_Chi_Minh'
      ))::integer AS hour,
      sum(line.sold_quantity)::bigint AS sold_quantity,
      sum(line.menu_sales_amount)::numeric AS menu_sales_amount,
      count(DISTINCT line.order_id)::integer AS order_count
    FROM menu_lines line
    GROUP BY line.menu_key, hour
  ),
  menu_totals AS MATERIALIZED (
    SELECT
      line.menu_key,
      (array_agg(
        line.display_name
        ORDER BY line.paid_at DESC, line.line_created_at DESC, line.order_id
      ))[1] AS display_name,
      min(line.identity_quality) AS identity_quality,
      count(DISTINCT lower(btrim(line.display_name))) > 1
        AS name_changed_in_period,
      bool_or(line.is_combo) AS is_combo,
      sum(line.sold_quantity)::bigint AS sold_quantity,
      count(DISTINCT line.order_id)::integer AS order_count,
      sum(line.menu_sales_amount)::numeric AS menu_sales_amount,
      sum(line.sold_quantity) FILTER (
        WHERE line.sales_channel = 'dine_in'
      )::bigint AS dine_in_quantity,
      sum(line.sold_quantity) FILTER (
        WHERE line.sales_channel = 'takeaway'
      )::bigint AS takeaway_quantity,
      sum(line.sold_quantity) FILTER (
        WHERE line.sales_channel = 'delivery'
      )::bigint AS delivery_quantity
    FROM menu_lines line
    GROUP BY line.menu_key
  ),
  overall AS MATERIALIZED (
    SELECT
      count(DISTINCT line.order_id)::integer AS order_count,
      COALESCE(sum(line.sold_quantity), 0)::bigint AS sold_quantity,
      COALESCE(sum(line.sold_quantity) FILTER (
        WHERE line.is_combo
      ), 0)::bigint AS combo_sold_quantity,
      COALESCE(sum(line.menu_sales_amount), 0)::numeric
        AS menu_sales_amount,
      COALESCE(sum(line.menu_sales_amount) FILTER (
        WHERE line.is_combo
      ), 0)::numeric AS combo_menu_sales_amount,
      count(DISTINCT line.menu_key)::integer AS sold_menu_count,
      count(DISTINCT line.menu_key) FILTER (
        WHERE line.is_combo
      )::integer AS combo_sold_menu_count
    FROM menu_lines line
  ),
  ranked_menus AS MATERIALIZED (
    SELECT
      row_number() OVER (
        ORDER BY total.sold_quantity DESC,
          total.menu_sales_amount DESC,
          lower(total.display_name),
          total.menu_key
      )::integer AS rank,
      total.*,
      COALESCE(peak.hour, 0)::integer AS peak_hour
    FROM menu_totals total
    LEFT JOIN (
      SELECT DISTINCT ON (menu_key) menu_key, hour
      FROM menu_hours ORDER BY menu_key, sold_quantity DESC, hour
    ) peak ON peak.menu_key = total.menu_key
  ),
  hourly_totals AS MATERIALIZED (
    SELECT
      series.hour::integer AS hour,
      COALESCE(sum(line.sold_quantity), 0)::bigint AS sold_quantity,
      COALESCE(sum(line.menu_sales_amount), 0)::numeric
        AS menu_sales_amount,
      count(DISTINCT line.order_id)::integer AS order_count
    FROM generate_series(0, 23) AS series(hour)
    LEFT JOIN menu_lines line
      ON extract(hour FROM (
        line.paid_at AT TIME ZONE 'Asia/Ho_Chi_Minh'
      ))::integer = series.hour
    GROUP BY series.hour
  ),
  adjustments AS MATERIALIZED (
    SELECT
      count(*)::integer AS adjustment_count,
      COALESCE(sum(adjustment.amount), 0)::numeric AS adjustment_amount
    FROM public.payment_adjustments adjustment
    WHERE adjustment.restaurant_id = p_store_id
      AND adjustment.created_at >= p_start_at
      AND adjustment.created_at < p_end_at
  )
  SELECT jsonb_build_object(
    'summary', jsonb_build_object(
      'order_count', overall.order_count,
      'sold_quantity', overall.sold_quantity,
      'sold_menu_count', overall.sold_menu_count,
      'combo_sold_quantity', overall.combo_sold_quantity,
      'combo_sold_menu_count', overall.combo_sold_menu_count,
      'menu_sales_amount', overall.menu_sales_amount,
      'combo_menu_sales_amount', overall.combo_menu_sales_amount,
      'unallocated_adjustment_count', adjustments.adjustment_count,
      'unallocated_adjustment_amount', adjustments.adjustment_amount
    ),
    'menu_rows', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'rank', menu.rank,
        'menu_key', menu.menu_key,
        'display_name', menu.display_name,
        'name_ko', menu_item.name_ko,
        'name_vi', menu_item.name_vi,
        'name_en', menu_item.name_en,
        'identity_quality', menu.identity_quality,
        'name_changed_in_period', menu.name_changed_in_period,
        'is_combo', menu.is_combo,
        'sold_quantity', menu.sold_quantity,
        'order_count', menu.order_count,
        'menu_sales_amount', menu.menu_sales_amount,
        'quantity_share', CASE
          WHEN overall.sold_quantity = 0 THEN 0
          ELSE round(
            menu.sold_quantity::numeric / overall.sold_quantity * 100,
            2
          )
        END,
        'revenue_share', CASE
          WHEN overall.menu_sales_amount = 0 THEN 0
          ELSE round(
            menu.menu_sales_amount / overall.menu_sales_amount * 100,
            2
          )
        END,
        'peak_hour', menu.peak_hour,
        'dine_in_quantity', COALESCE(menu.dine_in_quantity, 0),
        'takeaway_quantity', COALESCE(menu.takeaway_quantity, 0),
        'delivery_quantity', COALESCE(menu.delivery_quantity, 0)
      ) ORDER BY menu.rank)
      FROM ranked_menus menu
      LEFT JOIN public.menu_items menu_item
        ON menu.menu_key = menu_item.id::text
        AND menu_item.restaurant_id = p_store_id
    ), '[]'::jsonb),
    'hour_rows', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'hour', hourly.hour,
        'sold_quantity', hourly.sold_quantity,
        'menu_sales_amount', hourly.menu_sales_amount,
        'order_count', hourly.order_count
      ) ORDER BY hourly.hour)
      FROM hourly_totals hourly
    ), '[]'::jsonb),
    'top_menu_hour_rows', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'rank', menu.rank,
        'menu_key', menu.menu_key,
        'display_name', menu.display_name,
        'name_ko', menu_item.name_ko,
        'name_vi', menu_item.name_vi,
        'name_en', menu_item.name_en,
        'hour', series.hour,
        'sold_quantity', COALESCE(hourly.sold_quantity, 0),
        'menu_sales_amount', COALESCE(hourly.menu_sales_amount, 0)
      ) ORDER BY menu.rank, series.hour)
      FROM ranked_menus menu
      LEFT JOIN public.menu_items menu_item
        ON menu.menu_key = menu_item.id::text
        AND menu_item.restaurant_id = p_store_id
      CROSS JOIN generate_series(0, 23) AS series(hour)
      LEFT JOIN menu_hours hourly
        ON hourly.menu_key = menu.menu_key
       AND hourly.hour = series.hour
      WHERE menu.rank <= 5
    ), '[]'::jsonb),
    'scope', jsonb_build_object(
      'aggregation_version', 3,
      'timezone', 'Asia/Ho_Chi_Minh',
      'payment_time_basis', 'last_revenue_payment',
      'menu_scope', v_menu_scope,
      'include_combos', v_menu_scope <> 'regular',
      'combo_identity_basis', 'order_item_combo_components_snapshot',
      'included_sources', jsonb_build_array('pos_orders'),
      'excluded_sources', jsonb_build_array(
        'external_sales',
        'photo_objet_sales'
      ),
      'adjustment_allocation', 'unallocated'
    )
  )
  INTO v_result
  FROM overall
  CROSS JOIN adjustments;

  RETURN v_result;
END;
$$;
CREATE OR REPLACE FUNCTION public.get_inventory_cost_analysis(
  p_store_id UUID,
  p_from DATE DEFAULT CURRENT_DATE - 6,
  p_to DATE DEFAULT CURRENT_DATE
) RETURNS TABLE (
  product_id UUID,
  product_name TEXT,
  category TEXT,
  consumed_quantity_base NUMERIC(12,3),
  consumed_amount NUMERIC(12,2),
  avg_unit_cost NUMERIC(12,4),
  preferred_unit_cost NUMERIC(12,4),
  cost_status TEXT
) AS $$
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_COST_ANALYSIS_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to THEN
    RAISE EXCEPTION 'INVENTORY_COST_ANALYSIS_DATE_RANGE_INVALID';
  END IF;

  RETURN QUERY
  WITH scoped_products AS MATERIALIZED (
    SELECT ip.* FROM public.inventory_products ip
    WHERE ip.restaurant_id = p_store_id AND ip.is_active = true
  ), consumption AS (
    SELECT
      idc.product_id,
      SUM(idc.consumed_quantity_base)::NUMERIC(12,3) AS consumed_quantity_base,
      SUM(idc.consumed_amount)::NUMERIC(12,2) AS consumed_amount
    FROM public.inventory_daily_consumption idc
    WHERE idc.restaurant_id = p_store_id
      AND idc.consumption_date BETWEEN p_from AND p_to
    GROUP BY idc.product_id
  ),
  supplier_cost AS (
    SELECT DISTINCT ON (isi.product_id)
      isi.product_id,
      ROUND(
        isi.unit_price / NULLIF(isi.order_unit_quantity_base, 0),
        4
      ) AS preferred_unit_cost
    FROM public.inventory_supplier_items isi
    JOIN scoped_products scoped ON scoped.id = isi.product_id
    WHERE isi.is_active = TRUE
      AND isi.order_unit_quantity_base > 0
    ORDER BY isi.product_id, isi.is_preferred DESC, isi.updated_at DESC
  )
  SELECT
    ip.id AS product_id,
    ip.name AS product_name,
    COALESCE(ip.category, '-') AS category,
    COALESCE(c.consumed_quantity_base, 0)::NUMERIC(12,3),
    COALESCE(c.consumed_amount, 0)::NUMERIC(12,2),
    CASE
      WHEN COALESCE(c.consumed_quantity_base, 0) <= 0 THEN 0
      ELSE ROUND(c.consumed_amount / c.consumed_quantity_base, 4)
    END AS avg_unit_cost,
    COALESCE(sc.preferred_unit_cost, 0)::NUMERIC(12,4),
    CASE
      WHEN COALESCE(c.consumed_amount, 0) = 0 THEN 'stable'
      WHEN sc.preferred_unit_cost IS NULL THEN 'missing_supplier_cost'
      WHEN c.consumed_amount / NULLIF(c.consumed_quantity_base, 0) > sc.preferred_unit_cost * 1.1 THEN 'warning'
      ELSE 'normal'
    END AS cost_status
  FROM scoped_products ip
  LEFT JOIN consumption c
    ON c.product_id = ip.id
  LEFT JOIN supplier_cost sc
    ON sc.product_id = ip.id
  WHERE ip.restaurant_id = p_store_id
    AND ip.is_active = TRUE
  ORDER BY COALESCE(c.consumed_amount, 0) DESC, lower(ip.name);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
COMMIT;
