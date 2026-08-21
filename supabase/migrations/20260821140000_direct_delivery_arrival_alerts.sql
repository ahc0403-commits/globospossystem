-- Payload-free direct-order arrival signal and cashier-only catch-up cursor.
-- This is isolated from every existing POS/SePay/kitchen alert object.

BEGIN;

CREATE OR REPLACE FUNCTION public.direct_order_arrival_alerts_after(
  p_store_id uuid,
  p_after_created_at timestamptz DEFAULT NULL,
  p_after_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_cursor_created_at timestamptz;
  v_cursor_id uuid;
  v_items jsonb := '[]'::jsonb;
  v_has_more boolean := false;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier']
  );
  IF p_limit NOT BETWEEN 1 AND 100
     OR ((p_after_created_at IS NULL) <> (p_after_id IS NULL)) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_LIMIT_INVALID';
  END IF;

  IF p_after_created_at IS NULL THEN
    SELECT request_row.created_at, request_row.id
    INTO v_cursor_created_at, v_cursor_id
    FROM public.direct_order_requests request_row
    WHERE request_row.restaurant_id=p_store_id
    ORDER BY request_row.created_at DESC, request_row.id DESC
    LIMIT 1;

    IF v_cursor_created_at IS NULL THEN
      v_cursor_created_at := now();
      v_cursor_id := '00000000-0000-0000-0000-000000000000'::uuid;
    END IF;
  ELSE
    WITH page AS (
      SELECT request_row.id, request_row.created_at, request_row.state
      FROM public.direct_order_requests request_row
      WHERE request_row.restaurant_id=p_store_id
        AND (request_row.created_at, request_row.id)
          > (p_after_created_at, p_after_id)
      ORDER BY request_row.created_at, request_row.id
      LIMIT p_limit + 1
    ), bounded AS (
      SELECT * FROM page
      ORDER BY created_at, id
      LIMIT p_limit
    )
    SELECT
      COALESCE(jsonb_agg(jsonb_build_object(
        'request_id', bounded.id,
        'created_at', bounded.created_at,
        'state', bounded.state
      ) ORDER BY bounded.created_at, bounded.id), '[]'::jsonb),
      EXISTS (SELECT 1 FROM page OFFSET p_limit),
      COALESCE((SELECT created_at FROM bounded
                ORDER BY created_at DESC, id DESC LIMIT 1), p_after_created_at),
      COALESCE((SELECT id FROM bounded
                ORDER BY created_at DESC, id DESC LIMIT 1), p_after_id)
    INTO v_items, v_has_more, v_cursor_created_at, v_cursor_id
    FROM bounded;
  END IF;

  RETURN jsonb_build_object(
    'items', v_items,
    'pending_count', (
      SELECT count(*)
      FROM public.direct_order_requests request_row
      WHERE request_row.restaurant_id=p_store_id
        AND request_row.state='awaiting_quote'
    ),
    'next_cursor', jsonb_build_object(
      'created_at', v_cursor_created_at,
      'request_id', v_cursor_id
    ),
    'has_more', v_has_more
  );
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_arrival_alerts_after(
  uuid, timestamptz, uuid, integer
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_arrival_alerts_after(
  uuid, timestamptz, uuid, integer
) TO authenticated, service_role;

DROP TRIGGER IF EXISTS direct_order_arrival_live_event
  ON public.direct_order_requests;
CREATE TRIGGER direct_order_arrival_live_event
AFTER INSERT ON public.direct_order_requests
FOR EACH ROW
EXECUTE FUNCTION public.emit_pos_live_event('direct_orders');

COMMIT;
