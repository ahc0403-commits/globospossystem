BEGIN;

-- Group staff meals by order and expose a BM-only original-order drilldown.

CREATE INDEX IF NOT EXISTS audit_logs_bm_menu_exception_idx
  ON public.audit_logs(action, created_at DESC)
  WHERE action IN ('mark_order_item_service', 'unmark_order_item_service');

CREATE INDEX IF NOT EXISTS orders_bm_staff_meal_history_idx
  ON public.orders(restaurant_id, created_at DESC)
  WHERE order_purpose = 'staff_meal';

DROP FUNCTION IF EXISTS public.get_bm_menu_exception_history(
  uuid, timestamptz, timestamptz, text, boolean, text, integer, integer
);

CREATE OR REPLACE FUNCTION public.get_bm_menu_exception_history(
  p_store_id uuid DEFAULT NULL,
  p_start_at timestamptz DEFAULT NULL,
  p_end_at timestamptz DEFAULT NULL,
  p_history_type text DEFAULT 'all',
  p_include_reversals boolean DEFAULT true,
  p_search text DEFAULT NULL,
  p_snapshot_at timestamptz DEFAULT NULL,
  p_page integer DEFAULT 0,
  p_page_size integer DEFAULT 50
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_page integer := GREATEST(COALESCE(p_page, 0), 0);
  v_page_size integer := LEAST(GREATEST(COALESCE(p_page_size, 50), 1), 100);
  v_search text := NULLIF(lower(btrim(COALESCE(p_search, ''))), '');
  v_snapshot_at timestamptz := COALESCE(p_snapshot_at, statement_timestamp());
  v_result jsonb;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role <> 'brand_admin' THEN
    RAISE EXCEPTION 'BM_MENU_HISTORY_FORBIDDEN';
  END IF;

  IF p_start_at IS NULL OR p_end_at IS NULL OR p_start_at >= p_end_at THEN
    RAISE EXCEPTION 'BM_MENU_HISTORY_RANGE_INVALID';
  END IF;

  IF p_history_type NOT IN ('all', 'service', 'cancellation', 'staff_meal') THEN
    RAISE EXCEPTION 'BM_MENU_HISTORY_TYPE_INVALID';
  END IF;

  IF length(COALESCE(p_search, '')) > 100 THEN
    RAISE EXCEPTION 'BM_MENU_HISTORY_SEARCH_TOO_LONG';
  END IF;

  IF p_store_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) allowed(store_id)
       WHERE allowed.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'BM_MENU_HISTORY_FORBIDDEN';
  END IF;

  WITH service_source AS MATERIALIZED (
    SELECT
      'service'::text AS source_kind,
      CASE al.action
        WHEN 'mark_order_item_service' THEN 'service_marked'
        ELSE 'service_unmarked'
      END::text AS event_type,
      al.id AS event_id,
      al.entity_id::text AS line_key,
      al.created_at AS event_at,
      CASE
        WHEN COALESCE(al.details ->> 'store_id', '') ~
          '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        THEN (al.details ->> 'store_id')::uuid
        ELSE oi.restaurant_id
      END AS store_id,
      restaurant.name AS store_name,
      COALESCE(
        CASE
          WHEN COALESCE(al.details ->> 'order_id', '') ~
            '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
          THEN (al.details ->> 'order_id')::uuid
        END,
        oi.order_id
      ) AS order_id,
      order_row.created_at AS order_created_at,
      table_row.table_number,
      COALESCE(
        NULLIF(al.details ->> 'label', ''),
        NULLIF(oi.display_name, ''),
        NULLIF(oi.label, ''),
        'Unknown item'
      ) AS item_name,
      CASE
        WHEN COALESCE(al.details ->> 'quantity', '') ~ '^[-+]?[0-9]+([.][0-9]+)?$'
        THEN (al.details ->> 'quantity')::numeric
        ELSE oi.quantity::numeric
      END AS quantity,
      CASE
        WHEN COALESCE(al.details ->> 'unit_price', '') ~ '^[-+]?[0-9]+([.][0-9]+)?$'
        THEN (al.details ->> 'unit_price')::numeric
        ELSE oi.unit_price::numeric
      END AS unit_price,
      CASE
        WHEN COALESCE(al.details ->> 'quantity', '') ~ '^[-+]?[0-9]+([.][0-9]+)?$'
         AND COALESCE(al.details ->> 'unit_price', '') ~ '^[-+]?[0-9]+([.][0-9]+)?$'
        THEN (al.details ->> 'quantity')::numeric
             * (al.details ->> 'unit_price')::numeric
        WHEN oi.id IS NOT NULL THEN oi.quantity::numeric * oi.unit_price::numeric
      END AS reference_amount,
      NULL::numeric AS cancelled_amount,
      true AS is_service_item,
      al.actor_id,
      COALESCE(NULLIF(actor.full_name, ''), 'Unknown actor') AS actor_name,
      NULLIF(al.details ->> 'reason', '') AS reason,
      CASE
        WHEN oi.id IS NULL THEN 'unknown'
        WHEN oi.status = 'cancelled' THEN 'cancelled'
        WHEN COALESCE(oi.is_service_item, false) THEN 'service'
        ELSE 'charged'
      END::text AS current_state,
      NULL::uuid AS original_event_id,
      (
        NULLIF(al.details ->> 'label', '') IS NULL
        OR NULLIF(al.details ->> 'quantity', '') IS NULL
        OR NULLIF(al.details ->> 'unit_price', '') IS NULL
      ) AS data_incomplete
    FROM public.audit_logs al
    LEFT JOIN public.order_items oi ON oi.id = al.entity_id
    LEFT JOIN public.orders order_row ON order_row.id = COALESCE(
      CASE
        WHEN COALESCE(al.details ->> 'order_id', '') ~
          '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        THEN (al.details ->> 'order_id')::uuid
      END,
      oi.order_id
    )
    LEFT JOIN public.tables table_row ON table_row.id = order_row.table_id
    LEFT JOIN public.restaurants restaurant ON restaurant.id = CASE
      WHEN COALESCE(al.details ->> 'store_id', '') ~
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
      THEN (al.details ->> 'store_id')::uuid
      ELSE oi.restaurant_id
    END
    LEFT JOIN public.users actor ON actor.auth_id = al.actor_id
    WHERE al.action IN (
      'mark_order_item_service', 'unmark_order_item_service'
    )
      AND al.created_at >= p_start_at
      AND al.created_at < p_end_at
      AND al.created_at <= v_snapshot_at
  ),
  staff_meal_source AS MATERIALIZED (
    SELECT
      'staff_meal'::text AS source_kind,
      'staff_meal_created'::text AS event_type,
      order_row.id AS event_id,
      order_row.id::text AS line_key,
      order_row.created_at AS event_at,
      order_row.restaurant_id AS store_id,
      restaurant.name AS store_name,
      order_row.id AS order_id,
      order_row.created_at AS order_created_at,
      table_row.table_number,
      string_agg(
        COALESCE(
          NULLIF(oi.display_name, ''),
          NULLIF(oi.label, ''),
          NULLIF(menu_item.name, ''),
          'Unknown item'
        ),
        ', ' ORDER BY oi.created_at, oi.id
      ) AS item_name,
      sum(oi.quantity)::numeric AS quantity,
      NULL::numeric AS unit_price,
      sum(oi.quantity::numeric * oi.unit_price::numeric)::numeric
        AS reference_amount,
      NULL::numeric AS cancelled_amount,
      false AS is_service_item,
      order_row.created_by AS actor_id,
      COALESCE(NULLIF(actor.full_name, ''), 'Unknown actor') AS actor_name,
      NULLIF(order_row.notes, '') AS reason,
      ('staff_meal_' || order_row.status)::text AS current_state,
      NULL::uuid AS original_event_id,
      bool_or(
        COALESCE(
          NULLIF(oi.display_name, ''),
          NULLIF(oi.label, ''),
          NULLIF(menu_item.name, '')
        ) IS NULL
      ) AS data_incomplete
    FROM public.orders order_row
    JOIN public.order_items oi ON oi.order_id = order_row.id
    LEFT JOIN public.menu_items menu_item ON menu_item.id = oi.menu_item_id
    LEFT JOIN public.tables table_row ON table_row.id = order_row.table_id
    LEFT JOIN public.restaurants restaurant
      ON restaurant.id = order_row.restaurant_id
    LEFT JOIN public.users actor ON actor.auth_id = order_row.created_by
    WHERE order_row.order_purpose = 'staff_meal'
      AND oi.item_type <> 'service_charge'
      AND order_row.created_at >= p_start_at
      AND order_row.created_at < p_end_at
      AND order_row.created_at <= v_snapshot_at
    GROUP BY
      order_row.id,
      order_row.created_at,
      order_row.restaurant_id,
      order_row.created_by,
      order_row.notes,
      order_row.status,
      restaurant.name,
      table_row.table_number,
      actor.full_name
  ),
  cancellation_source AS MATERIALIZED (
    SELECT
      'cancellation'::text AS source_kind,
      CASE l.cancellation_scope
        WHEN 'order' THEN 'order_cancelled'
        ELSE 'item_cancelled'
      END::text AS event_type,
      l.id AS event_id,
      COALESCE(item.value ->> 'order_item_id', item.ordinality::text) AS line_key,
      l.created_at AS event_at,
      l.restaurant_id AS store_id,
      restaurant.name AS store_name,
      l.order_id,
      order_row.created_at AS order_created_at,
      table_row.table_number,
      COALESCE(
        NULLIF(item.value ->> 'label', ''),
        NULLIF(current_item.display_name, ''),
        NULLIF(current_item.label, ''),
        'Unknown item'
      ) AS item_name,
      CASE
        WHEN COALESCE(item.value ->> 'quantity', '') ~ '^[-+]?[0-9]+([.][0-9]+)?$'
        THEN (item.value ->> 'quantity')::numeric
      END AS quantity,
      CASE
        WHEN COALESCE(item.value ->> 'unit_price', '') ~ '^[-+]?[0-9]+([.][0-9]+)?$'
        THEN (item.value ->> 'unit_price')::numeric
      END AS unit_price,
      CASE
        WHEN COALESCE(item.value ->> 'quantity', '') ~ '^[-+]?[0-9]+([.][0-9]+)?$'
         AND COALESCE(item.value ->> 'unit_price', '') ~ '^[-+]?[0-9]+([.][0-9]+)?$'
        THEN (item.value ->> 'quantity')::numeric
             * (item.value ->> 'unit_price')::numeric
      END AS reference_amount,
      CASE
        WHEN lower(COALESCE(item.value ->> 'is_service_item', 'false')) = 'true'
        THEN 0
        WHEN COALESCE(item.value ->> 'paying_amount_inc_tax', '') ~ '^[-+]?[0-9]+([.][0-9]+)?$'
             AND (item.value ->> 'paying_amount_inc_tax')::numeric > 0
        THEN (item.value ->> 'paying_amount_inc_tax')::numeric
        WHEN COALESCE(item.value ->> 'quantity', '') ~ '^[-+]?[0-9]+([.][0-9]+)?$'
         AND COALESCE(item.value ->> 'unit_price', '') ~ '^[-+]?[0-9]+([.][0-9]+)?$'
        THEN (item.value ->> 'quantity')::numeric
             * (item.value ->> 'unit_price')::numeric
      END AS cancelled_amount,
      lower(COALESCE(item.value ->> 'is_service_item', 'false')) = 'true'
        AS is_service_item,
      l.created_by AS actor_id,
      COALESCE(NULLIF(actor.full_name, ''), 'Unknown actor') AS actor_name,
      NULL::text AS reason,
      CASE
        WHEN reversal.id IS NOT NULL THEN 'restored'
        WHEN current_item.status = 'cancelled' THEN 'cancelled'
        ELSE 'changed'
      END::text AS current_state,
      NULL::uuid AS original_event_id,
      (
        NULLIF(item.value ->> 'label', '') IS NULL
        OR NULLIF(item.value ->> 'quantity', '') IS NULL
        OR NULLIF(item.value ->> 'unit_price', '') IS NULL
      ) AS data_incomplete
    FROM public.order_cancellation_ledger l
    CROSS JOIN LATERAL jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(l.item_snapshot) = 'array' THEN l.item_snapshot
        ELSE '[]'::jsonb
      END
    ) WITH ORDINALITY AS item(value, ordinality)
    LEFT JOIN public.order_cancellation_reversals reversal
      ON reversal.cancellation_ledger_id = l.id
    LEFT JOIN public.order_items current_item ON current_item.id = CASE
      WHEN COALESCE(item.value ->> 'order_item_id', '') ~
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
      THEN (item.value ->> 'order_item_id')::uuid
    END
    LEFT JOIN public.orders order_row ON order_row.id = l.order_id
    LEFT JOIN public.tables table_row ON table_row.id = order_row.table_id
    LEFT JOIN public.restaurants restaurant ON restaurant.id = l.restaurant_id
    LEFT JOIN public.users actor ON actor.auth_id = l.created_by
    WHERE COALESCE(item.value ->> 'item_type', 'menu_item') <> 'service_charge'
      AND l.created_at >= p_start_at
      AND l.created_at < p_end_at
      AND l.created_at <= v_snapshot_at
  ),
  restoration_source AS MATERIALIZED (
    SELECT
      'cancellation'::text AS source_kind,
      CASE l.cancellation_scope
        WHEN 'order' THEN 'order_restored'
        ELSE 'item_restored'
      END::text AS event_type,
      reversal.id AS event_id,
      COALESCE(item.value ->> 'order_item_id', item.ordinality::text) AS line_key,
      reversal.restored_at AS event_at,
      l.restaurant_id AS store_id,
      restaurant.name AS store_name,
      l.order_id,
      order_row.created_at AS order_created_at,
      table_row.table_number,
      COALESCE(
        NULLIF(item.value ->> 'label', ''),
        NULLIF(current_item.display_name, ''),
        NULLIF(current_item.label, ''),
        'Unknown item'
      ) AS item_name,
      CASE
        WHEN COALESCE(item.value ->> 'quantity', '') ~ '^[-+]?[0-9]+([.][0-9]+)?$'
        THEN (item.value ->> 'quantity')::numeric
      END AS quantity,
      CASE
        WHEN COALESCE(item.value ->> 'unit_price', '') ~ '^[-+]?[0-9]+([.][0-9]+)?$'
        THEN (item.value ->> 'unit_price')::numeric
      END AS unit_price,
      CASE
        WHEN COALESCE(item.value ->> 'quantity', '') ~ '^[-+]?[0-9]+([.][0-9]+)?$'
         AND COALESCE(item.value ->> 'unit_price', '') ~ '^[-+]?[0-9]+([.][0-9]+)?$'
        THEN (item.value ->> 'quantity')::numeric
             * (item.value ->> 'unit_price')::numeric
      END AS reference_amount,
      NULL::numeric AS cancelled_amount,
      lower(COALESCE(item.value ->> 'is_service_item', 'false')) = 'true'
        AS is_service_item,
      reversal.restored_by AS actor_id,
      COALESCE(NULLIF(actor.full_name, ''), 'Unknown actor') AS actor_name,
      NULL::text AS reason,
      CASE
        WHEN current_item.status = 'cancelled' THEN 'cancelled_again'
        WHEN current_item.id IS NULL THEN 'unknown'
        ELSE 'restored'
      END::text AS current_state,
      l.id AS original_event_id,
      (
        NULLIF(item.value ->> 'label', '') IS NULL
        OR NULLIF(item.value ->> 'quantity', '') IS NULL
        OR NULLIF(item.value ->> 'unit_price', '') IS NULL
      ) AS data_incomplete
    FROM public.order_cancellation_reversals reversal
    JOIN public.order_cancellation_ledger l
      ON l.id = reversal.cancellation_ledger_id
    CROSS JOIN LATERAL jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(l.item_snapshot) = 'array' THEN l.item_snapshot
        ELSE '[]'::jsonb
      END
    ) WITH ORDINALITY AS item(value, ordinality)
    LEFT JOIN public.order_items current_item ON current_item.id = CASE
      WHEN COALESCE(item.value ->> 'order_item_id', '') ~
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
      THEN (item.value ->> 'order_item_id')::uuid
    END
    LEFT JOIN public.orders order_row ON order_row.id = l.order_id
    LEFT JOIN public.tables table_row ON table_row.id = order_row.table_id
    LEFT JOIN public.restaurants restaurant ON restaurant.id = l.restaurant_id
    LEFT JOIN public.users actor ON actor.auth_id = reversal.restored_by
    WHERE COALESCE(item.value ->> 'item_type', 'menu_item') <> 'service_charge'
      AND reversal.restored_at >= p_start_at
      AND reversal.restored_at < p_end_at
      AND reversal.restored_at <= v_snapshot_at
  ),
  all_events AS MATERIALIZED (
    SELECT * FROM service_source
    UNION ALL
    SELECT * FROM staff_meal_source
    UNION ALL
    SELECT * FROM cancellation_source
    UNION ALL
    SELECT * FROM restoration_source
  ),
  enriched_events AS MATERIALIZED (
    SELECT
      event.*,
      CASE
        WHEN event.order_id IS NULL THEN NULL
        ELSE lpad(
          (
            ('x' || substr(md5(event.order_id::text), 9, 8))::bit(32)::bigint
            % 100000
          )::text,
          5,
          '0'
        )
      END AS order_number
    FROM all_events event
  ),
  filtered AS MATERIALIZED (
    SELECT event.*
    FROM enriched_events event
    WHERE event.event_at >= p_start_at
      AND event.event_at < p_end_at
      AND (
        p_store_id IS NULL
        OR event.store_id = p_store_id
      )
      AND EXISTS (
        SELECT 1
        FROM public.user_accessible_stores(auth.uid()) allowed(store_id)
        WHERE allowed.store_id = event.store_id
      )
      AND (
        p_history_type = 'all'
        OR event.source_kind = p_history_type
      )
      AND (
        COALESCE(p_include_reversals, true)
        OR event.event_type NOT IN (
          'service_unmarked', 'order_restored', 'item_restored'
        )
      )
      AND (
        v_search IS NULL
        OR lower(event.item_name) LIKE '%' || v_search || '%'
        OR lower(COALESCE(event.actor_name, '')) LIKE '%' || v_search || '%'
        OR event.order_id::text LIKE '%' || v_search || '%'
        OR event.order_number LIKE '%' || v_search || '%'
        OR lower(COALESCE(event.table_number, '')) LIKE '%' || v_search || '%'
      )
  ),
  page_rows AS (
    SELECT filtered.*
    FROM filtered
    ORDER BY event_at DESC, source_kind, event_id DESC, line_key
    OFFSET v_page * v_page_size
    LIMIT v_page_size
  ),
  summary AS (
    SELECT
      count(*)::integer AS total_rows,
      count(DISTINCT event_id) FILTER (
        WHERE event_type = 'service_marked'
      )::integer AS service_event_count,
      COALESCE(sum(quantity) FILTER (
        WHERE event_type = 'service_marked'
      ), 0)::numeric AS service_quantity,
      COALESCE(sum(reference_amount) FILTER (
        WHERE event_type = 'service_marked'
      ), 0)::numeric AS service_reference_amount,
      count(DISTINCT event_id) FILTER (
        WHERE event_type IN ('order_cancelled', 'item_cancelled')
      )::integer AS cancellation_event_count,
      COALESCE(sum(quantity) FILTER (
        WHERE event_type IN ('order_cancelled', 'item_cancelled')
      ), 0)::numeric AS cancelled_quantity,
      COALESCE(sum(cancelled_amount) FILTER (
        WHERE event_type IN ('order_cancelled', 'item_cancelled')
      ), 0)::numeric AS cancelled_amount,
      count(DISTINCT event_id) FILTER (
        WHERE event_type = 'staff_meal_created'
      )::integer AS staff_meal_event_count,
      COALESCE(sum(quantity) FILTER (
        WHERE event_type = 'staff_meal_created'
      ), 0)::numeric AS staff_meal_quantity,
      COALESCE(sum(reference_amount) FILTER (
        WHERE event_type = 'staff_meal_created'
      ), 0)::numeric AS staff_meal_reference_amount,
      count(DISTINCT event_id) FILTER (
        WHERE event_type IN (
          'service_unmarked', 'order_restored', 'item_restored'
        )
      )::integer AS reversal_event_count
    FROM filtered
  )
  SELECT jsonb_build_object(
    'items', COALESCE(
      (SELECT jsonb_agg(to_jsonb(page_rows) ORDER BY
        event_at DESC, source_kind, event_id DESC, line_key)
       FROM page_rows),
      '[]'::jsonb
    ),
    'summary', to_jsonb(summary),
    'page', v_page,
    'page_size', v_page_size,
    'has_more', summary.total_rows > ((v_page + 1) * v_page_size),
    'fetched_at', v_snapshot_at
  )
  INTO v_result
  FROM summary;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_bm_menu_exception_history(
  uuid, timestamptz, timestamptz, text, boolean, text, timestamptz,
  integer, integer
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_bm_menu_exception_history(
  uuid, timestamptz, timestamptz, text, boolean, text, timestamptz,
  integer, integer
) TO authenticated, service_role;

COMMENT ON FUNCTION public.get_bm_menu_exception_history(
  uuid, timestamptz, timestamptz, text, boolean, text, timestamptz,
  integer, integer
) IS
  'BM-only paged service-item and cancellation events plus order-grouped staff meals for accessible stores.';

DROP FUNCTION IF EXISTS public.get_bm_order_history_detail(uuid);

CREATE OR REPLACE FUNCTION public.get_bm_order_history_detail(
  p_order_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_result jsonb;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role <> 'brand_admin' THEN
    RAISE EXCEPTION 'BM_MENU_HISTORY_FORBIDDEN';
  END IF;

  SELECT jsonb_build_object(
    'order_id', order_row.id,
    'order_number', lpad(
      (
        ('x' || substr(md5(order_row.id::text), 9, 8))::bit(32)::bigint
        % 100000
      )::text,
      5,
      '0'
    ),
    'created_at', order_row.created_at,
    'store_id', order_row.restaurant_id,
    'store_name', restaurant.name,
    'table_number', table_row.table_number,
    'status', order_row.status,
    'order_purpose', order_row.order_purpose,
    'sales_channel', order_row.sales_channel,
    'created_by_name', COALESCE(NULLIF(creator.full_name, ''), 'Unknown actor'),
    'notes', NULLIF(order_row.notes, ''),
    'item_count', COALESCE(item_summary.item_count, 0),
    'total_quantity', COALESCE(item_summary.total_quantity, 0),
    'reference_amount', COALESCE(item_summary.reference_amount, 0),
    'items', COALESCE(item_summary.items, '[]'::jsonb)
  )
  INTO v_result
  FROM public.orders order_row
  JOIN public.restaurants restaurant
    ON restaurant.id = order_row.restaurant_id
  LEFT JOIN public.tables table_row ON table_row.id = order_row.table_id
  LEFT JOIN public.users creator ON creator.auth_id = order_row.created_by
  LEFT JOIN LATERAL (
    SELECT
      count(*)::integer AS item_count,
      COALESCE(sum(order_item.quantity), 0)::numeric AS total_quantity,
      COALESCE(
        sum(order_item.quantity::numeric * order_item.unit_price::numeric),
        0
      )::numeric AS reference_amount,
      jsonb_agg(
        jsonb_build_object(
          'id', order_item.id,
          'name', COALESCE(
            NULLIF(order_item.display_name, ''),
            NULLIF(order_item.label, ''),
            NULLIF(menu_item.name, ''),
            'Unknown item'
          ),
          'quantity', order_item.quantity,
          'unit_price', order_item.unit_price,
          'reference_amount',
            order_item.quantity::numeric * order_item.unit_price::numeric,
          'status', order_item.status,
          'is_service_item', COALESCE(order_item.is_service_item, false)
        )
        ORDER BY order_item.created_at, order_item.id
      ) AS items
    FROM public.order_items order_item
    LEFT JOIN public.menu_items menu_item
      ON menu_item.id = order_item.menu_item_id
    WHERE order_item.order_id = order_row.id
      AND order_item.item_type <> 'service_charge'
  ) item_summary ON true
  WHERE order_row.id = p_order_id
    AND EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) allowed(store_id)
      WHERE allowed.store_id = order_row.restaurant_id
    );

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'BM_ORDER_HISTORY_NOT_FOUND';
  END IF;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_bm_order_history_detail(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_bm_order_history_detail(uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.get_bm_order_history_detail(uuid) IS
  'BM-only original POS order detail for an accessible service, cancellation, or staff-meal history row.';

COMMIT;
