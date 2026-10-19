-- Direct order receipt presentation only; retain financial and issued snapshots.
-- production-gate: self-verifying
BEGIN;

-- Resolve the existing receipt lines in one batch before removing the fee line,
-- so a fee between two menus cannot shift names or notes onto the wrong menu.
CREATE FUNCTION public.direct_order_receipt_content(
  p_store_id uuid, p_order_id uuid, p_items jsonb
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_catalog AS $$
  WITH context AS (
    SELECT f.delivery_fee_item_id, r.fulfillment_method,
      NULLIF(btrim(r.customer_note), '') AS note
    FROM public.direct_order_financials f
    JOIN public.direct_order_requests r
      ON r.id = f.request_id AND r.restaurant_id = f.restaurant_id
    WHERE f.order_id = p_order_id AND f.restaurant_id = p_store_id
  ), ordered_item AS (
    SELECT i.id, i.notes,
      row_number() OVER (ORDER BY i.created_at, i.id) AS ord
    FROM public.order_items i
    WHERE i.order_id = p_order_id AND i.restaurant_id = p_store_id
      AND i.status <> 'cancelled'
  ), receipt_item AS (
    SELECT raw.value, raw.ordinality
    FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb))
      WITH ORDINALITY AS raw(value, ordinality)
  ), resolved_item AS (
    SELECT raw.value, raw.ordinality,
      COALESCE(by_id.id, by_position.id) AS id,
      COALESCE(by_id.notes, by_position.notes) AS notes
    FROM receipt_item raw
    LEFT JOIN ordered_item by_id ON by_id.id::text = raw.value->>'item_id'
    LEFT JOIN ordered_item by_position ON by_position.ord = raw.ordinality
      AND COALESCE(raw.value->>'item_id', '') = ''
  )
  SELECT jsonb_build_object('order_notes', context.note, 'items', COALESCE(
    jsonb_agg(i.value || jsonb_build_object(
      'item_id', COALESCE(i.id::text, i.value->>'item_id'),
      'notes', COALESCE(NULLIF(btrim(i.notes), ''), i.value->>'notes'),
      'label', CASE WHEN i.id = context.delivery_fee_item_id
        THEN 'Phí giao hàng' ELSE i.value->>'label' END
    ) ORDER BY i.ordinality) FILTER (
      WHERE i.ordinality IS NOT NULL
        AND NOT COALESCE(i.id = context.delivery_fee_item_id
          AND context.fulfillment_method = 'pickup', false)
    ), '[]'::jsonb))
  FROM context
  LEFT JOIN resolved_item i ON true
  GROUP BY context.note, context.delivery_fee_item_id, context.fulfillment_method;
$$;
REVOKE ALL ON FUNCTION public.direct_order_receipt_content(uuid,uuid,jsonb)
  FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.direct_order_receipt_packing_context(
  p_store_id uuid, p_order_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, auth, pg_catalog AS $$
DECLARE v_result jsonb;
BEGIN
  PERFORM public.direct_order_require_actor(p_store_id,
    ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
  IF NOT EXISTS (SELECT 1 FROM public.orders
    WHERE id = p_order_id AND restaurant_id = p_store_id) THEN
    RAISE EXCEPTION 'RECEIPT_ORDER_NOT_FOUND';
  END IF;
  SELECT jsonb_build_object('diner_count', r.diner_count,
    'fulfillment_method', r.fulfillment_method,
    'direct_order_reference', r.reference_code,
    'order_notes', NULLIF(btrim(r.customer_note), ''),
    'delivery_fee_item_id', f.delivery_fee_item_id)
  INTO v_result
  FROM public.direct_order_financials f
  JOIN public.direct_order_requests r
    ON r.id = f.request_id AND r.restaurant_id = f.restaurant_id
  WHERE f.order_id = p_order_id AND f.restaurant_id = p_store_id;
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_receipt_packing_context(uuid,uuid)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_receipt_packing_context(uuid,uuid)
  TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.direct_order_enrich_print_fulfillment()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public,pg_catalog AS $$
DECLARE v_context jsonb; v_reference text; v_content jsonb;
BEGIN
  SELECT public.direct_order_fulfillment_context(f.request_id), r.reference_code
  INTO v_context, v_reference
  FROM public.direct_order_financials f
  JOIN public.direct_order_requests r
    ON r.id = f.request_id AND r.restaurant_id = f.restaurant_id
  WHERE f.order_id = NEW.order_id AND f.restaurant_id = NEW.restaurant_id;
  IF v_context IS NOT NULL THEN
    NEW.payload := NEW.payload || jsonb_build_object(
      'diner_count',v_context->'diner_count',
      'fulfillment_method',v_context->'method',
      'direct_order_reference',v_reference,
      'refunded_total',v_context->'refunded_total');
    IF NEW.copy_type = 'receipt' AND NEW.combined_payment_group_id IS NULL THEN
      v_content := public.direct_order_receipt_content(
        NEW.restaurant_id, NEW.order_id, NEW.payload->'items');
      IF v_content IS NOT NULL THEN NEW.payload := NEW.payload || v_content; END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_enrich_print_fulfillment()
  FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.direct_order_enrich_digital_receipt_packing()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public,pg_catalog AS $$
DECLARE v_context jsonb; v_content jsonb;
BEGIN
  IF NEW.combined_payment_group_id IS NOT NULL THEN RETURN NEW; END IF;
  SELECT jsonb_build_object('diner_count',r.diner_count,
    'fulfillment_method',r.fulfillment_method,
    'direct_order_reference',r.reference_code)
  INTO v_context
  FROM public.direct_order_financials f
  JOIN public.direct_order_requests r
    ON r.id = f.request_id AND r.restaurant_id = f.restaurant_id
  WHERE f.order_id = NEW.order_id AND f.restaurant_id = NEW.restaurant_id;
  IF v_context IS NOT NULL THEN
    v_content := public.direct_order_receipt_content(
      NEW.restaurant_id, NEW.order_id, NEW.snapshot->'items');
    NEW.snapshot := NEW.snapshot || v_context || v_content;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_enrich_digital_receipt_packing()
  FROM PUBLIC,anon,authenticated;

DO $verify$
BEGIN
  IF has_function_privilege('anon','public.direct_order_receipt_content(uuid,uuid,jsonb)','EXECUTE')
    OR has_function_privilege('authenticated','public.direct_order_receipt_content(uuid,uuid,jsonb)','EXECUTE')
    OR has_function_privilege('anon','public.direct_order_receipt_packing_context(uuid,uuid)','EXECUTE')
    OR NOT has_function_privilege('authenticated','public.direct_order_receipt_packing_context(uuid,uuid)','EXECUTE')
    OR NOT EXISTS (SELECT 1 FROM pg_trigger
      WHERE tgrelid='public.print_jobs'::regclass
        AND tgname='zz_direct_order_enrich_print_fulfillment' AND tgenabled='O')
    OR NOT EXISTS (SELECT 1 FROM pg_trigger
      WHERE tgrelid='public.digital_receipts'::regclass
        AND tgname='zz_direct_order_enrich_digital_receipt_packing' AND tgenabled='O') THEN
    RAISE EXCEPTION 'RECEIPT_REQUESTS_VERIFICATION_FAILED';
  END IF;
END;
$verify$;
COMMIT;
