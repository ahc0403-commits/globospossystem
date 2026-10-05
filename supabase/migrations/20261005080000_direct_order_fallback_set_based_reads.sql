-- Kitchen packing reads must not call the financial/detail helper per ticket.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';

CREATE OR REPLACE FUNCTION public.direct_delivery_ticket_list_v3(
  p_store_id uuid,
  p_statuses text[] DEFAULT NULL,
  p_limit integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_day_start timestamptz;
  v_day_end timestamptz;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['kitchen', 'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_LIMIT_INVALID';
  END IF;
  v_day_start := (
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp
    AT TIME ZONE 'Asia/Ho_Chi_Minh'
  );
  v_day_end := v_day_start + interval '1 day';

  RETURN (
    WITH ticket_page AS MATERIALIZED (
      SELECT ticket.id, ticket.request_id, ticket.status, ticket.pickup_code,
             ticket.version, ticket.created_at, ticket.updated_at
      FROM public.direct_delivery_fulfillment_tickets ticket
      WHERE ticket.restaurant_id = p_store_id
        AND NOT EXISTS (SELECT 1 FROM public.direct_order_financials f
          JOIN public.emergency_order_queue q ON q.order_id = f.order_id
          JOIN public.direct_order_requests r ON r.id = f.request_id
          WHERE f.request_id = ticket.request_id AND r.fulfillment_type = 'pickup')
        AND ticket.created_at >= v_day_start
        AND ticket.created_at < v_day_end
        AND (p_statuses IS NULL OR ticket.status = ANY(p_statuses))
      ORDER BY ticket.created_at, ticket.id
      LIMIT p_limit
    ), ticket_items AS (
      SELECT item.ticket_id, jsonb_agg(jsonb_build_object(
        'id', item.id,
        'name_ko', item.display_name_ko,
        'name_vi', item.display_name_vi,
        'name_en', item.display_name_en,
        'quantity', item.quantity,
        'note', item.item_note
      ) ORDER BY item.sort_order, item.id) AS items
      FROM ticket_page page
      JOIN public.direct_delivery_fulfillment_ticket_items item
        ON item.ticket_id = page.id AND item.restaurant_id = p_store_id
      GROUP BY item.ticket_id
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', page.id,
      'request_id', page.request_id,
      'status', page.status,
      'pickup_code', page.pickup_code,
      'version', page.version,
      'created_at', page.created_at,
      'updated_at', page.updated_at,
      'items', COALESCE(item_group.items, '[]'::jsonb),
      'delivery', jsonb_build_object(
        'diner_count', request_row.diner_count,
        'method', request_row.fulfillment_method,
        'version', request_row.fulfillment_version
      )
    ) ORDER BY page.created_at, page.id), '[]'::jsonb)
    FROM ticket_page page
    JOIN public.direct_order_requests request_row
      ON request_row.id = page.request_id AND request_row.restaurant_id = p_store_id
    LEFT JOIN ticket_items item_group ON item_group.ticket_id = page.id
  );
END;
$$;

COMMENT ON FUNCTION public.direct_delivery_ticket_list_v3(uuid,text[],integer) IS
  'Current Vietnam business-day kitchen tickets, bounded to 200; set-based items and packing-only delivery {diner_count,method,version}. Financial/provider context belongs to authorized single-request detail.';
REVOKE ALL ON FUNCTION public.direct_delivery_ticket_list_v3(uuid,text[],integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_delivery_ticket_list_v3(uuid,text[],integer)
  TO authenticated, service_role;

DO $verify$
BEGIN
  IF strpos(pg_get_functiondef('public.direct_delivery_ticket_list_v3(uuid,text[],integer)'::regprocedure),
            'direct_order_fulfillment_context') > 0
    OR has_function_privilege('anon','public.direct_delivery_ticket_list_v3(uuid,text[],integer)','EXECUTE')
    OR NOT has_function_privilege('authenticated','public.direct_delivery_ticket_list_v3(uuid,text[],integer)','EXECUTE')
  THEN RAISE EXCEPTION 'DIRECT_ORDER_FALLBACK_VERIFICATION_FAILED'; END IF;
END;
$verify$;
COMMIT;
