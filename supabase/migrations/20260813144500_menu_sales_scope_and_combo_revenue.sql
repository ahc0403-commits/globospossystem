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

  WITH paid_orders AS MATERIALIZED (
    SELECT
      order_row.id AS order_id,
      order_row.sales_channel,
      max(payment.created_at) AS paid_at
    FROM public.orders order_row
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
      COALESCE((
        SELECT hour_row.hour
        FROM menu_hours hour_row
        WHERE hour_row.menu_key = total.menu_key
        ORDER BY hour_row.sold_quantity DESC, hour_row.hour
        LIMIT 1
      ), 0)::integer AS peak_hour
    FROM menu_totals total
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
        'hour', series.hour,
        'sold_quantity', COALESCE(hourly.sold_quantity, 0),
        'menu_sales_amount', COALESCE(hourly.menu_sales_amount, 0)
      ) ORDER BY menu.rank, series.hour)
      FROM ranked_menus menu
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

REVOKE ALL ON FUNCTION public.get_store_menu_sales_analytics(
  uuid, timestamptz, timestamptz, text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_store_menu_sales_analytics(
  uuid, timestamptz, timestamptz, text
) TO authenticated, service_role;

COMMENT ON FUNCTION public.get_store_menu_sales_analytics(
  uuid, timestamptz, timestamptz, text
) IS
  'Returns store-scoped POS menu analytics for all, regular-only, or combo-only menu sales, with combo revenue and immutable snapshot identity.';
