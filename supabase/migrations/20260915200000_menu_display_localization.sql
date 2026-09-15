-- Keep historical identities, amounts, permissions and pagination unchanged.
-- Return menu translations as data so already-open screens can switch locale.
BEGIN;

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
      jsonb_build_array(jsonb_build_object('name', COALESCE(NULLIF(al.details ->> 'label', ''), NULLIF(oi.display_name, ''), oi.label), 'name_ko', menu_item.name_ko, 'name_vi', menu_item.name_vi, 'name_en', menu_item.name_en, 'item_type', oi.item_type)) AS item_names,
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
    LEFT JOIN public.menu_items menu_item
      ON menu_item.id = COALESCE(oi.menu_item_id_snapshot, oi.menu_item_id)
      AND menu_item.restaurant_id = oi.restaurant_id
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
      jsonb_agg(jsonb_build_object('name', COALESCE(NULLIF(oi.display_name, ''), NULLIF(oi.label, ''), menu_item.name), 'name_ko', menu_item.name_ko, 'name_vi', menu_item.name_vi, 'name_en', menu_item.name_en, 'item_type', oi.item_type) ORDER BY oi.created_at, oi.id) AS item_names,
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
    LEFT JOIN public.menu_items menu_item
      ON menu_item.id = COALESCE(oi.menu_item_id_snapshot, oi.menu_item_id)
      AND menu_item.restaurant_id = oi.restaurant_id
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
      jsonb_build_array(jsonb_build_object('name', COALESCE(NULLIF(item.value ->> 'label', ''), NULLIF(current_item.display_name, ''), current_item.label), 'name_ko', menu_item.name_ko, 'name_vi', menu_item.name_vi, 'name_en', menu_item.name_en, 'item_type', current_item.item_type)) AS item_names,
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
    LEFT JOIN public.menu_items menu_item
      ON menu_item.id = COALESCE(current_item.menu_item_id_snapshot, current_item.menu_item_id)
      AND menu_item.restaurant_id = l.restaurant_id
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
      jsonb_build_array(jsonb_build_object('name', COALESCE(NULLIF(item.value ->> 'label', ''), NULLIF(current_item.display_name, ''), current_item.label), 'name_ko', menu_item.name_ko, 'name_vi', menu_item.name_vi, 'name_en', menu_item.name_en, 'item_type', current_item.item_type)) AS item_names,
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
    LEFT JOIN public.menu_items menu_item
      ON menu_item.id = COALESCE(current_item.menu_item_id_snapshot, current_item.menu_item_id)
      AND menu_item.restaurant_id = l.restaurant_id
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
        OR EXISTS (
          SELECT 1 FROM jsonb_array_elements(event.item_names) translated(item),
            jsonb_each_text(translated.item) name
          WHERE name.key IN ('name_ko', 'name_vi', 'name_en')
            AND lower(name.value) LIKE '%' || v_search || '%'
        )
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
          'name_ko', menu_item.name_ko,
          'name_vi', menu_item.name_vi,
          'name_en', menu_item.name_en,
          'item_type', order_item.item_type,
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
      ON menu_item.id = COALESCE(order_item.menu_item_id_snapshot, order_item.menu_item_id)
      AND menu_item.restaurant_id = order_item.restaurant_id
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

CREATE OR REPLACE FUNCTION public.get_receipt_ledger(
  p_business_date date,
  p_store_id uuid DEFAULT NULL,
  p_query text DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_business_date date := p_business_date;
  v_start timestamptz :=
    v_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_end timestamptz :=
    (v_business_date + 1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
  v_query text := NULLIF(btrim(COALESCE(p_query, '')), '');
  v_status text := NULLIF(lower(btrim(COALESCE(p_status, ''))), '');
  v_result jsonb;
BEGIN
  IF v_business_date IS NULL THEN
    RAISE EXCEPTION 'RECEIPT_LEDGER_BUSINESS_DATE_REQUIRED';
  END IF;

  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) THEN
    RAISE EXCEPTION 'RECEIPT_LEDGER_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin' AND p_store_id IS NULL THEN
    RAISE EXCEPTION 'RECEIPT_LEDGER_STORE_REQUIRED';
  END IF;

  IF p_store_id IS NOT NULL
     AND v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) scope(store_id)
       WHERE scope.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'RECEIPT_LEDGER_FORBIDDEN';
  END IF;

  WITH scoped_payments AS (
    SELECT
      payment.id,
      payment.order_id,
      payment.restaurant_id AS store_id,
      payment.combined_payment_group_id,
      CASE
        WHEN payment.combined_payment_group_id IS NULL
          THEN 'order:' || payment.order_id::text
        ELSE 'combined:' || payment.combined_payment_group_id::text
      END AS ledger_key,
      COALESCE(payment.amount_portion, payment.amount) AS amount,
      payment.method,
      COALESCE(payment_group.completed_at, payment.created_at) AS sold_at,
      COALESCE(
        NULLIF(user_row.fixed_account_code, ''),
        NULLIF(user_row.full_name, ''),
        'CASHIER'
      ) AS cashier_name
    FROM public.payments payment
    LEFT JOIN public.combined_payment_groups payment_group
      ON payment_group.id = payment.combined_payment_group_id
    LEFT JOIN public.users user_row
      ON user_row.auth_id = payment.processed_by
    WHERE payment.is_revenue = true
      AND COALESCE(payment_group.completed_at, payment.created_at) >= v_start
      AND COALESCE(payment_group.completed_at, payment.created_at) < v_end
      AND (p_store_id IS NULL OR payment.restaurant_id = p_store_id)
      AND (
        v_actor.role = 'super_admin'
        OR EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) scope(store_id)
          WHERE scope.store_id = payment.restaurant_id
        )
      )
  ),
  payment_adjustment_totals AS (
    SELECT
      payment.ledger_key,
      ROUND(COALESCE(sum(adjustment.amount), 0), 2) AS adjusted_amount
    FROM public.payment_adjustments adjustment
    JOIN scoped_payments payment ON payment.id = adjustment.payment_id
    GROUP BY payment.ledger_key
  ),
  pos_payment_groups AS (
    SELECT
      payment.ledger_key,
      payment.combined_payment_group_id,
      payment.store_id,
      max(payment.sold_at) AS sold_at,
      (array_agg(DISTINCT payment.order_id ORDER BY payment.order_id))[1]
        AS primary_order_id,
      array_agg(DISTINCT payment.order_id ORDER BY payment.order_id)
        AS order_ids,
      ROUND(sum(payment.amount), 2) AS gross_amount,
      (array_agg(
        payment.cashier_name
        ORDER BY payment.sold_at DESC, payment.id DESC
      ))[1] AS cashier_name
    FROM scoped_payments payment
    GROUP BY
      payment.ledger_key,
      payment.combined_payment_group_id,
      payment.store_id
  ),
  pos_payment_methods AS (
    SELECT
      payment.ledger_key,
      payment.method,
      ROUND(sum(payment.amount), 2) AS amount
    FROM scoped_payments payment
    GROUP BY payment.ledger_key, payment.method
  ),
  pos_payment_summaries AS (
    SELECT
      payment.ledger_key,
      jsonb_agg(jsonb_build_object(
        'method', payment.method,
        'amount', payment.amount
      ) ORDER BY payment.method) AS payments
    FROM pos_payment_methods payment
    GROUP BY payment.ledger_key
  ),
  pos_allocations AS (
    SELECT
      payment.ledger_key,
      payment.order_id,
      COALESCE(table_row.table_number, 'TAKEAWAY') AS table_number,
      ROUND(sum(payment.amount), 2) AS amount
    FROM scoped_payments payment
    JOIN public.orders order_row ON order_row.id = payment.order_id
    LEFT JOIN public.tables table_row ON table_row.id = order_row.table_id
    GROUP BY
      payment.ledger_key,
      payment.order_id,
      COALESCE(table_row.table_number, 'TAKEAWAY')
  ),
  pos_allocation_summaries AS (
    SELECT
      allocation.ledger_key,
      string_agg(
        allocation.table_number,
        ', ' ORDER BY allocation.table_number, allocation.order_id
      ) AS table_number,
      jsonb_agg(jsonb_build_object(
        'order_id', allocation.order_id,
        'table_number', allocation.table_number,
        'amount', allocation.amount
      ) ORDER BY allocation.table_number, allocation.order_id) AS allocations
    FROM pos_allocations allocation
    GROUP BY allocation.ledger_key
  ),
  pos_order_keys AS (
    SELECT DISTINCT
      payment.ledger_key,
      payment.combined_payment_group_id,
      payment.order_id,
      payment.store_id
    FROM scoped_payments payment
  ),
  pos_order_items AS (
    SELECT
      order_key.ledger_key,
      jsonb_agg(jsonb_build_object(
        'order_id', item.order_id,
        'table_number', COALESCE(table_row.table_number, 'TAKEAWAY'),
        'name', CASE
          WHEN order_key.combined_payment_group_id IS NULL THEN COALESCE(
            NULLIF(item.display_name, ''), NULLIF(item.label, ''), 'Item'
          )
          ELSE '[' || COALESCE(table_row.table_number, 'TAKEAWAY') || '] ' ||
            COALESCE(
              NULLIF(item.display_name, ''), NULLIF(item.label, ''), 'Item'
            )
        END,
        'name_ko', CASE WHEN NULLIF(btrim(menu_item.name_ko), '') IS NOT NULL THEN
          CASE WHEN order_key.combined_payment_group_id IS NULL THEN ''
            ELSE '[' || COALESCE(table_row.table_number, 'TAKEAWAY') || '] ' END
          || menu_item.name_ko END,
        'name_vi', CASE WHEN NULLIF(btrim(menu_item.name_vi), '') IS NOT NULL THEN
          CASE WHEN order_key.combined_payment_group_id IS NULL THEN ''
            ELSE '[' || COALESCE(table_row.table_number, 'TAKEAWAY') || '] ' END
          || menu_item.name_vi END,
        'name_en', CASE WHEN NULLIF(btrim(menu_item.name_en), '') IS NOT NULL THEN
          CASE WHEN order_key.combined_payment_group_id IS NULL THEN ''
            ELSE '[' || COALESCE(table_row.table_number, 'TAKEAWAY') || '] ' END
          || menu_item.name_en END,
        'quantity', item.quantity,
        'unit_price', item.unit_price
      ) ORDER BY
        COALESCE(table_row.table_number, 'TAKEAWAY'),
        item.created_at,
        item.id
      ) AS items
    FROM pos_order_keys order_key
    JOIN public.orders order_row ON order_row.id = order_key.order_id
    LEFT JOIN public.tables table_row ON table_row.id = order_row.table_id
    JOIN public.order_items item ON item.order_id = order_key.order_id
    LEFT JOIN public.menu_items menu_item
      ON menu_item.id = COALESCE(item.menu_item_id_snapshot, item.menu_item_id)
      AND menu_item.restaurant_id = item.restaurant_id
    WHERE item.status <> 'cancelled'
    GROUP BY order_key.ledger_key
  ),
  all_receipts AS (
    SELECT
      COALESCE(
        receipt.id::text,
        COALESCE(
          payment_group.combined_payment_group_id,
          payment_group.primary_order_id
        )::text
      ) AS receipt_id,
      COALESCE(
        receipt.receipt_number,
        CASE
          WHEN payment_group.combined_payment_group_id IS NOT NULL THEN
            'BC-' || to_char(
              payment_group.sold_at AT TIME ZONE 'Asia/Ho_Chi_Minh',
              'YYYYMMDD'
            ) || '-' || lpad(((
              ('x' || substr(md5(
                payment_group.combined_payment_group_id::text
              ), 1, 8))::bit(32)::bigint % 1000000
            )::text), 6, '0')
          ELSE 'POS-' || upper(substr(replace(
            payment_group.primary_order_id::text, '-', ''
          ), 1, 10))
        END
      ) AS receipt_number,
      CASE
        WHEN payment_group.combined_payment_group_id IS NULL
          THEN payment_group.primary_order_id
        ELSE NULL::uuid
      END AS order_id,
      payment_group.combined_payment_group_id,
      to_jsonb(payment_group.order_ids) AS order_ids,
      payment_group.store_id,
      restaurant.name AS store_name,
      payment_group.sold_at,
      allocation.table_number,
      CASE
        WHEN payment_group.combined_payment_group_id IS NULL
          THEN primary_order.sales_channel
        ELSE 'combined'
      END AS sales_channel,
      payment_group.cashier_name,
      payment_summary.payments,
      allocation.allocations,
      COALESCE(order_items.items, '[]'::jsonb) AS items,
      payment_group.gross_amount,
      LEAST(
        payment_group.gross_amount,
        COALESCE(adjustment.adjusted_amount, 0)
      ) AS adjusted_amount,
      GREATEST(
        payment_group.gross_amount - COALESCE(adjustment.adjusted_amount, 0),
        0
      ) AS net_amount,
      CASE
        WHEN COALESCE(adjustment.adjusted_amount, 0) >=
             payment_group.gross_amount THEN 'refunded'
        WHEN COALESCE(adjustment.adjusted_amount, 0) > 0
          THEN 'partially_refunded'
        ELSE 'paid'
      END AS receipt_status,
      'pos'::text AS receipt_source,
      CASE
        WHEN payment_group.combined_payment_group_id IS NULL
          THEN 'single'
        ELSE 'combined'
      END AS receipt_scope,
      true AS printable,
      receipt.id IS NOT NULL AS digital_receipt_ready,
      CASE
        WHEN payment_group.combined_payment_group_id IS NOT NULL THEN
          COALESCE(
            NULLIF(receipt.snapshot->>'received_amount', '')::numeric,
            payment_group.gross_amount
          )
        ELSE payment_group.gross_amount
      END AS received_amount
    FROM pos_payment_groups payment_group
    JOIN public.orders primary_order
      ON primary_order.id = payment_group.primary_order_id
    JOIN public.restaurants restaurant
      ON restaurant.id = payment_group.store_id
    JOIN pos_payment_summaries payment_summary
      ON payment_summary.ledger_key = payment_group.ledger_key
    JOIN pos_allocation_summaries allocation
      ON allocation.ledger_key = payment_group.ledger_key
    LEFT JOIN public.digital_receipts receipt ON (
      payment_group.combined_payment_group_id IS NOT NULL
      AND receipt.combined_payment_group_id =
        payment_group.combined_payment_group_id
      AND receipt.order_id IS NULL
    ) OR (
      payment_group.combined_payment_group_id IS NULL
      AND receipt.order_id = payment_group.primary_order_id
    )
    LEFT JOIN payment_adjustment_totals adjustment
      ON adjustment.ledger_key = payment_group.ledger_key
    LEFT JOIN pos_order_items order_items
      ON order_items.ledger_key = payment_group.ledger_key

    UNION ALL

    SELECT
      external.id::text,
      COALESCE(NULLIF(external.external_order_id, ''), external.id::text),
      NULL::uuid,
      NULL::uuid,
      '[]'::jsonb,
      external.restaurant_id,
      restaurant.name,
      COALESCE(external.completed_at, external.created_at),
      '-'::text,
      external.sales_channel,
      external.source_system,
      jsonb_build_array(jsonb_build_object(
        'method', external.source_system,
        'amount', external.net_amount
      )),
      '[]'::jsonb,
      '[]'::jsonb,
      external.gross_amount,
      GREATEST(external.gross_amount - external.net_amount, 0),
      external.net_amount,
      CASE external.order_status
        WHEN 'completed' THEN 'paid'
        WHEN 'partially_refunded' THEN 'partially_refunded'
        ELSE 'refunded'
      END,
      'external'::text,
      'external'::text,
      false,
      false,
      external.gross_amount
    FROM public.external_sales external
    JOIN public.restaurants restaurant
      ON restaurant.id = external.restaurant_id
    WHERE external.is_revenue = true
      AND COALESCE(external.completed_at, external.created_at) >= v_start
      AND COALESCE(external.completed_at, external.created_at) < v_end
      AND (p_store_id IS NULL OR external.restaurant_id = p_store_id)
      AND (
        v_actor.role = 'super_admin'
        OR EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) scope(store_id)
          WHERE scope.store_id = external.restaurant_id
        )
      )
  ),
  filtered_receipts AS (
    SELECT *
    FROM all_receipts receipt
    WHERE (v_status IS NULL OR receipt.receipt_status = v_status)
      AND (
        v_query IS NULL
        OR receipt.receipt_number ILIKE '%' || v_query || '%'
        OR receipt.store_name ILIKE '%' || v_query || '%'
        OR receipt.table_number ILIKE '%' || v_query || '%'
        OR COALESCE(receipt.order_id::text, '') ILIKE '%' || v_query || '%'
        OR COALESCE(receipt.combined_payment_group_id::text, '')
          ILIKE '%' || v_query || '%'
        OR receipt.order_ids::text ILIKE '%' || v_query || '%'
        OR receipt.allocations::text ILIKE '%' || v_query || '%'
      )
  ),
  page AS (
    SELECT *
    FROM filtered_receipts
    ORDER BY sold_at DESC, receipt_id DESC
    LIMIT v_limit OFFSET v_offset
  ),
  summary AS (
    SELECT
      count(*)::integer AS receipt_count,
      ROUND(COALESCE(sum(gross_amount), 0), 2) AS gross_amount,
      ROUND(COALESCE(sum(adjusted_amount), 0), 2) AS adjusted_amount,
      ROUND(COALESCE(sum(net_amount), 0), 2) AS net_amount
    FROM all_receipts
  )
  SELECT jsonb_build_object(
    'business_date', v_business_date,
    'generated_at', statement_timestamp(),
    'summary', jsonb_build_object(
      'receipt_count', summary.receipt_count,
      'gross_amount', summary.gross_amount,
      'adjusted_amount', summary.adjusted_amount,
      'net_amount', summary.net_amount
    ),
    'receipts', COALESCE(
      (SELECT jsonb_agg(to_jsonb(page)) FROM page),
      '[]'::jsonb
    ),
    'has_more',
      (SELECT count(*) FROM filtered_receipts) > v_offset + v_limit
  ) INTO v_result
  FROM summary;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_receipt_ledger(
  date, uuid, text, text, integer, integer
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_receipt_ledger(
  date, uuid, text, text, integer, integer
) TO authenticated, service_role;

COMMENT ON FUNCTION public.get_receipt_ledger(
  date, uuid, text, text, integer, integer
) IS 'Role-scoped receipt ledger with one row per combined tender and order allocations in its detail.';

DO $$
DECLARE
  v_function regprocedure :=
    'public.get_receipt_ledger(date,uuid,text,text,integer,integer)'::regprocedure;
  v_definition text;
BEGIN
  SELECT pg_get_functiondef(procedure_row.oid)
  INTO v_definition
  FROM pg_catalog.pg_proc procedure_row
  WHERE procedure_row.oid = v_function;

  IF pg_catalog.has_function_privilege('anon', v_function, 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', v_function, 'EXECUTE'
     )
     OR position('combined_payment_group_id' IN v_definition) = 0
     OR position('pos_allocation_summaries AS' IN v_definition) = 0
     OR position('receipt_scope' IN v_definition) = 0
     OR position('payment_group.primary_order_id' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'COMBINED_PAYMENT_LEDGER_GROUPING_VERIFY_FAILED';
  END IF;
END;
$$;


COMMIT;
