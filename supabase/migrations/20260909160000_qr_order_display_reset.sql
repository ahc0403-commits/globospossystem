-- Reset the customer-facing QR order list ten minutes after every item has
-- reached the floor. The printed table QR remains stable; only presentation
-- state is reset. Unpaid orders remain open and receive later additions, while
-- a fully paid order is already completed by process_payment and the next QR
-- submission creates a new order.

BEGIN;

-- production-gate: self-verifying

CREATE TABLE public.qr_order_display_states (
  order_id uuid PRIMARY KEY REFERENCES public.orders(id) ON DELETE CASCADE,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  table_id uuid NOT NULL REFERENCES public.tables(id) ON DELETE CASCADE,
  visible_from timestamptz NOT NULL,
  display_version bigint NOT NULL DEFAULT 0 CHECK (display_version >= 0),
  all_served_at timestamptz,
  reset_due_at timestamptz,
  reset_applied_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT qr_order_display_reset_due_pair CHECK (
    (all_served_at IS NULL AND reset_due_at IS NULL)
    OR (all_served_at IS NOT NULL AND reset_due_at = all_served_at + interval '10 minutes')
  )
);

CREATE INDEX qr_order_display_states_table
  ON public.qr_order_display_states (restaurant_id, table_id, updated_at DESC);

ALTER TABLE public.qr_order_display_states ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.qr_order_display_states FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.qr_order_display_states TO service_role;

CREATE OR REPLACE FUNCTION public.qr_order_is_fully_floor_served(
  p_order_id uuid
) RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
BEGIN
  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id;

  IF NOT FOUND OR v_order.status NOT IN ('pending', 'confirmed', 'serving') THEN
    RETURN false;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.order_items item
    WHERE item.order_id = p_order_id
      AND item.status <> 'cancelled'
      AND item.item_type = 'menu_item'
      AND COALESCE(item.is_service_item, false) = false
  ) THEN
    RETURN false;
  END IF;

  IF v_order.fulfillment_mode_snapshot <> 'paperless' THEN
    RETURN NOT EXISTS (
      SELECT 1
      FROM public.order_items item
      WHERE item.order_id = p_order_id
        AND item.status <> 'cancelled'
        AND item.item_type = 'menu_item'
        AND COALESCE(item.is_service_item, false) = false
        AND item.status <> 'served'
    );
  END IF;

  -- Every commercial item must be represented in the active paperless ledger.
  -- A missing ledger row is treated as incomplete rather than silently served.
  IF EXISTS (
    SELECT 1
    FROM public.order_items item
    WHERE item.order_id = p_order_id
      AND item.status <> 'cancelled'
      AND item.item_type = 'menu_item'
      AND COALESCE(item.is_service_item, false) = false
      AND NOT EXISTS (
        SELECT 1
        FROM public.emergency_fulfillment_items standard
        JOIN public.emergency_fulfillment_sessions session
          ON session.id = standard.session_id AND session.status = 'active'
        WHERE standard.order_item_id = item.id
          AND standard.order_id = p_order_id
          AND standard.is_cancelled = false
        UNION ALL
        SELECT 1
        FROM public.emergency_floor_direct_items direct
        JOIN public.emergency_fulfillment_sessions session
          ON session.id = direct.session_id AND session.status = 'active'
        WHERE direct.order_item_id = item.id
          AND direct.order_id = p_order_id
          AND direct.is_cancelled = false
      )
  ) THEN
    RETURN false;
  END IF;

  RETURN NOT EXISTS (
    SELECT 1
    FROM public.emergency_fulfillment_items item
    JOIN public.emergency_fulfillment_sessions session
      ON session.id = item.session_id AND session.status = 'active'
    WHERE item.order_id = p_order_id
      AND item.is_cancelled = false
      AND (item.needs_review OR item.floor_served_quantity < item.ordered_quantity)
    UNION ALL
    SELECT 1
    FROM public.emergency_floor_direct_items item
    JOIN public.emergency_fulfillment_sessions session
      ON session.id = item.session_id AND session.status = 'active'
    WHERE item.order_id = p_order_id
      AND item.is_cancelled = false
      AND (item.needs_review OR item.floor_served_quantity < item.ordered_quantity)
    UNION ALL
    SELECT 1
    FROM public.emergency_combo_component_items item
    JOIN public.emergency_fulfillment_sessions session
      ON session.id = item.session_id AND session.status = 'active'
    WHERE item.order_id = p_order_id
      AND item.is_cancelled = false
      AND (item.needs_review OR item.floor_served_quantity < item.ordered_quantity)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.qr_refresh_order_display_state(
  p_order_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_fully_served boolean;
  v_observed_at timestamptz := clock_timestamp();
BEGIN
  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id;
  IF NOT FOUND OR v_order.table_id IS NULL OR v_order.sales_channel <> 'dine_in' THEN
    RETURN;
  END IF;

  INSERT INTO public.qr_order_display_states (
    order_id, restaurant_id, table_id, visible_from
  )
  VALUES (
    v_order.id,
    v_order.restaurant_id,
    v_order.table_id,
    v_order.created_at
  )
  ON CONFLICT (order_id) DO NOTHING;

  v_fully_served := public.qr_order_is_fully_floor_served(p_order_id);

  IF v_fully_served THEN
    UPDATE public.qr_order_display_states state
    SET all_served_at = COALESCE(state.all_served_at, v_observed_at),
        reset_due_at = COALESCE(
          state.reset_due_at,
          v_observed_at + interval '10 minutes'
        ),
        updated_at = v_observed_at
    WHERE state.order_id = p_order_id;
  ELSE
    UPDATE public.qr_order_display_states state
    SET all_served_at = NULL,
        reset_due_at = NULL,
        updated_at = v_observed_at
    WHERE state.order_id = p_order_id
      AND (state.all_served_at IS NOT NULL OR state.reset_due_at IS NOT NULL);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.qr_apply_due_order_display_reset(
  p_order_id uuid
) RETURNS public.qr_order_display_states
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $$
DECLARE
  v_state public.qr_order_display_states%ROWTYPE;
  v_observed_at timestamptz := clock_timestamp();
BEGIN
  PERFORM public.qr_refresh_order_display_state(p_order_id);

  UPDATE public.qr_order_display_states state
  SET visible_from = GREATEST(state.visible_from, state.reset_due_at),
      display_version = state.display_version + 1,
      reset_applied_at = state.reset_due_at,
      updated_at = v_observed_at
  WHERE state.order_id = p_order_id
    AND state.reset_due_at IS NOT NULL
    AND state.reset_due_at <= v_observed_at
    AND (
      state.reset_applied_at IS NULL
      OR state.reset_applied_at < state.reset_due_at
    )
  RETURNING * INTO v_state;

  IF FOUND THEN RETURN v_state; END IF;

  SELECT * INTO v_state
  FROM public.qr_order_display_states
  WHERE order_id = p_order_id;
  RETURN v_state;
END;
$$;

CREATE OR REPLACE FUNCTION public.qr_refresh_display_from_order_item()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM public.qr_refresh_order_display_state(OLD.order_id);
    RETURN OLD;
  END IF;
  PERFORM public.qr_refresh_order_display_state(NEW.order_id);
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.qr_refresh_display_from_fulfillment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM public.qr_refresh_order_display_state(OLD.order_id);
    RETURN OLD;
  END IF;
  PERFORM public.qr_refresh_order_display_state(NEW.order_id);
  RETURN NEW;
END;
$$;

CREATE TRIGGER qr_order_items_refresh_display
AFTER INSERT OR DELETE OR UPDATE OF status, quantity, item_type, is_service_item
ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.qr_refresh_display_from_order_item();

CREATE TRIGGER qr_standard_fulfillment_refresh_display
AFTER INSERT OR DELETE OR UPDATE OF
  ordered_quantity, floor_served_quantity, is_cancelled, needs_review
ON public.emergency_fulfillment_items
FOR EACH ROW EXECUTE FUNCTION public.qr_refresh_display_from_fulfillment();

CREATE TRIGGER qr_floor_direct_refresh_display
AFTER INSERT OR DELETE OR UPDATE OF
  ordered_quantity, floor_served_quantity, is_cancelled, needs_review
ON public.emergency_floor_direct_items
FOR EACH ROW EXECUTE FUNCTION public.qr_refresh_display_from_fulfillment();

CREATE TRIGGER qr_combo_component_refresh_display
AFTER INSERT OR DELETE OR UPDATE OF
  ordered_quantity, floor_served_quantity, is_cancelled, needs_review
ON public.emergency_combo_component_items
FOR EACH ROW EXECUTE FUNCTION public.qr_refresh_display_from_fulfillment();

-- Preserve the current takeout/progress response and filter its customer list
-- with the server-owned display boundary.
ALTER FUNCTION public.qr_get_active_order(text)
  RENAME TO qr_get_active_order_pre_display_reset;

CREATE OR REPLACE FUNCTION public.qr_get_active_order(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $$
DECLARE
  v_payload jsonb;
  v_token text := NULLIF(btrim(COALESCE(p_token, '')), '');
  v_table record;
  v_order public.orders%ROWTYPE;
  v_state public.qr_order_display_states%ROWTYPE;
  v_items jsonb := '[]'::jsonb;
  v_last_closed_order_id uuid;
BEGIN
  v_payload := public.qr_get_active_order_pre_display_reset(p_token);

  SELECT qr.restaurant_id, qr.table_id INTO v_table
  FROM public.table_qr_tokens qr
  WHERE qr.token = v_token AND qr.is_active = true;

  IF COALESCE((v_payload->>'active')::boolean, false) = false THEN
    SELECT order_row.id INTO v_last_closed_order_id
    FROM public.orders order_row
    WHERE order_row.restaurant_id = v_table.restaurant_id
      AND order_row.table_id = v_table.table_id
      AND order_row.status IN ('completed', 'cancelled')
    ORDER BY order_row.updated_at DESC, order_row.created_at DESC
    LIMIT 1;

    RETURN v_payload || jsonb_build_object(
      'order_id', NULL,
      'last_closed_order_id', v_last_closed_order_id,
      'display_version', 0,
      'display_reset_at', NULL,
      'reset_due_at', NULL
    );
  END IF;

  SELECT * INTO v_order
  FROM public.orders order_row
  WHERE order_row.restaurant_id = v_table.restaurant_id
    AND order_row.table_id = v_table.table_id
    AND order_row.status IN ('pending', 'confirmed', 'serving')
  ORDER BY order_row.created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'active', false,
      'order_id', NULL,
      'last_closed_order_id', NULL,
      'order_code', '',
      'status', '',
      'fulfillment_mode', 'pos_print',
      'items', '[]'::jsonb,
      'leftover_packaging_status', NULL,
      'display_version', 0,
      'display_reset_at', NULL,
      'reset_due_at', NULL
    );
  END IF;

  v_state := public.qr_apply_due_order_display_reset(v_order.id);

  WITH source_items AS (
    SELECT source.raw, source.ord
    FROM jsonb_array_elements(COALESCE(v_payload->'items', '[]'::jsonb))
      WITH ORDINALITY source(raw, ord)
  ), ordered_items AS (
    SELECT item.created_at,
      row_number() OVER (ORDER BY item.created_at, item.id) AS ord
    FROM public.order_items item
    WHERE item.order_id = v_order.id
      AND item.restaurant_id = v_table.restaurant_id
      AND item.status <> 'cancelled'
      AND item.item_type = 'menu_item'
      AND COALESCE(item.is_service_item, false) = false
  )
  SELECT COALESCE(jsonb_agg(source.raw ORDER BY source.ord), '[]'::jsonb)
  INTO v_items
  FROM source_items source
  JOIN ordered_items item ON item.ord = source.ord
  WHERE item.created_at >= v_state.visible_from;

  RETURN jsonb_set(v_payload, '{items}', v_items, true)
    || jsonb_build_object(
      'order_id', v_order.id::text,
      'last_closed_order_id', NULL,
      'display_version', v_state.display_version,
      'display_reset_at', v_state.reset_applied_at,
      'reset_due_at', v_state.reset_due_at
    );
END;
$$;

-- The legacy core rejected any payment row, including a legitimate partial
-- payment. Payment completion changes the order status to completed, so an
-- open order can safely receive additions after preserving prior payments.
DO $patch_partial_payment$
DECLARE
  v_rpc regprocedure :=
    'public.qr_place_order_pre_takeout_core(text,jsonb,uuid)'::regprocedure;
  v_definition text;
  v_old text := $old$    IF EXISTS (
      SELECT 1
      FROM public.payments p
      WHERE p.order_id = v_live_order.id
    ) THEN
      RAISE EXCEPTION 'QR_ORDER_PAYMENT_IN_PROGRESS';
    END IF;$old$;
  v_new text := $new$    -- Partial payments remain attached to this open order. A fully paid
    -- order is completed by process_payment and is not selected above.$new$;
BEGIN
  SELECT pg_get_functiondef(v_rpc::oid) INTO v_definition;
  IF position(v_old IN v_definition) = 0 THEN
    RAISE EXCEPTION 'QR_DISPLAY_RESET_PATCH_FAILED: payment guard not found';
  END IF;
  EXECUTE replace(v_definition, v_old, v_new);
END;
$patch_partial_payment$;

-- New clients submit the order context that was visible when the cart was
-- prepared. A stale request cannot silently attach itself to the next table
-- order during a peak-time handover.
CREATE OR REPLACE FUNCTION public.qr_place_order(
  p_token text,
  p_items jsonb,
  p_client_order_id uuid,
  p_validate_combo_choices boolean,
  p_expected_order_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_token text := NULLIF(btrim(COALESCE(p_token, '')), '');
  v_table record;
  v_current_order_id uuid;
  v_existing public.qr_order_batches%ROWTYPE;
  v_result jsonb;
BEGIN
  SELECT qr.restaurant_id, qr.table_id INTO v_table
  FROM public.table_qr_tokens qr
  JOIN public.tables table_row
    ON table_row.id = qr.table_id
   AND table_row.restaurant_id = qr.restaurant_id
  JOIN public.restaurants restaurant
    ON restaurant.id = qr.restaurant_id AND restaurant.is_active = true
  WHERE qr.token = v_token AND qr.is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'QR_TOKEN_INVALID'; END IF;

  SELECT * INTO v_existing
  FROM public.qr_order_batches batch
  WHERE batch.client_order_id = p_client_order_id
    AND batch.restaurant_id = v_table.restaurant_id
    AND batch.table_id = v_table.table_id;
  IF FOUND THEN RETURN v_existing.result_snapshot; END IF;

  -- Payment locks the order before releasing its table. Match that order for
  -- an existing check so a payment completion and a QR addition cannot form
  -- an order/table lock cycle. If no active order exists, lock the table and
  -- recheck before allowing the delegated function to create one.
  SELECT order_row.id INTO v_current_order_id
  FROM public.orders order_row
  WHERE order_row.table_id = v_table.table_id
    AND order_row.restaurant_id = v_table.restaurant_id
    AND order_row.status IN ('pending', 'confirmed', 'serving')
  ORDER BY order_row.created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF v_current_order_id IS NULL THEN
    PERFORM 1
    FROM public.tables table_row
    WHERE table_row.id = v_table.table_id
      AND table_row.restaurant_id = v_table.restaurant_id
    FOR UPDATE;

    SELECT order_row.id INTO v_current_order_id
    FROM public.orders order_row
    WHERE order_row.table_id = v_table.table_id
      AND order_row.restaurant_id = v_table.restaurant_id
      AND order_row.status IN ('pending', 'confirmed', 'serving')
    ORDER BY order_row.created_at DESC
    LIMIT 1
    FOR UPDATE;
  ELSE
    PERFORM 1
    FROM public.tables table_row
    WHERE table_row.id = v_table.table_id
      AND table_row.restaurant_id = v_table.restaurant_id
    FOR UPDATE;
  END IF;

  IF v_current_order_id IS DISTINCT FROM p_expected_order_id THEN
    RAISE EXCEPTION 'QR_ORDER_CONTEXT_CHANGED';
  END IF;

  IF v_current_order_id IS NOT NULL THEN
    PERFORM public.qr_apply_due_order_display_reset(v_current_order_id);
  END IF;

  v_result := public.qr_place_order(
    p_token,
    p_items,
    p_client_order_id,
    p_validate_combo_choices
  );

  PERFORM public.qr_refresh_order_display_state((v_result->>'order_id')::uuid);
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.qr_order_is_fully_floor_served(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.qr_refresh_order_display_state(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.qr_apply_due_order_display_reset(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.qr_refresh_display_from_order_item()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.qr_refresh_display_from_fulfillment()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.qr_get_active_order_pre_display_reset(text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.qr_get_active_order(text) FROM PUBLIC;
-- Require customer clients to send the order context they actually saw.
-- The previous public overloads remain available only to trusted server-side
-- callers so cached clients cannot bypass the stale-order guard.
REVOKE ALL ON FUNCTION public.qr_place_order(text, jsonb, uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.qr_place_order(text, jsonb, uuid, boolean)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.qr_place_order(text, jsonb, uuid, boolean, uuid)
  FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.qr_get_active_order(text)
  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.qr_place_order(text, jsonb, uuid),
  public.qr_place_order(text, jsonb, uuid, boolean)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.qr_place_order(
  text, jsonb, uuid, boolean, uuid
) TO anon, authenticated, service_role;

DO $verify$
DECLARE
  v_core_definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.qr_place_order_pre_takeout_core(text,jsonb,uuid)'::regprocedure
  ) INTO v_core_definition;

  IF to_regclass('public.qr_order_display_states') IS NULL
     OR to_regprocedure('public.qr_get_active_order(text)') IS NULL
     OR to_regprocedure(
       'public.qr_place_order(text,jsonb,uuid,boolean,uuid)'
     ) IS NULL
     OR position('QR_ORDER_PAYMENT_IN_PROGRESS' IN v_core_definition) > 0
     OR has_table_privilege('anon', 'public.qr_order_display_states', 'select')
     OR NOT has_function_privilege(
       'anon',
       'public.qr_get_active_order(text)',
       'execute'
     )
     OR NOT has_function_privilege(
       'anon',
       'public.qr_place_order(text,jsonb,uuid,boolean,uuid)',
       'execute'
     )
     OR has_function_privilege(
       'anon',
       'public.qr_place_order(text,jsonb,uuid)',
       'execute'
     )
     OR has_function_privilege(
       'anon',
       'public.qr_place_order(text,jsonb,uuid,boolean)',
       'execute'
     ) THEN
    RAISE EXCEPTION 'QR_ORDER_DISPLAY_RESET_VERIFICATION_FAILED';
  END IF;
END;
$verify$;

COMMIT;
