-- Direct Order packing metadata; no changes to payment/VAT/inventory amounts.
-- production-gate: self-verifying
BEGIN;

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
    'direct_order_reference', r.reference_code)
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

-- Enrich only new jobs. Pending, in-flight and completed snapshots are retained;
-- the existing dedicated reprint creates a new job with the current count.
CREATE OR REPLACE FUNCTION public.direct_order_enrich_print_fulfillment()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public,pg_catalog AS $$
DECLARE v_context jsonb; v_reference text;
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
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_enrich_print_fulfillment()
  FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.direct_order_enrich_digital_receipt_packing()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public,pg_catalog AS $$
DECLARE v_context jsonb;
BEGIN
  -- A combined receipt is a group snapshot, not a single packing order.
  IF NEW.combined_payment_group_id IS NOT NULL THEN RETURN NEW; END IF;
  SELECT jsonb_build_object('diner_count',r.diner_count,
    'fulfillment_method',r.fulfillment_method,
    'direct_order_reference',r.reference_code)
  INTO v_context
  FROM public.direct_order_financials f
  JOIN public.direct_order_requests r
    ON r.id = f.request_id AND r.restaurant_id = f.restaurant_id
  WHERE f.order_id = NEW.order_id AND f.restaurant_id = NEW.restaurant_id;
  IF v_context IS NOT NULL THEN NEW.snapshot := NEW.snapshot || v_context; END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_enrich_digital_receipt_packing()
  FROM PUBLIC,anon,authenticated;
CREATE TRIGGER zz_direct_order_enrich_digital_receipt_packing
  BEFORE INSERT ON public.digital_receipts FOR EACH ROW
  EXECUTE FUNCTION public.direct_order_enrich_digital_receipt_packing();

DO $verify$
BEGIN
  IF has_function_privilege('anon','public.direct_order_receipt_packing_context(uuid,uuid)','EXECUTE')
    OR NOT has_function_privilege('authenticated','public.direct_order_receipt_packing_context(uuid,uuid)','EXECUTE')
    OR has_function_privilege('authenticated','public.direct_order_enrich_digital_receipt_packing()','EXECUTE')
    OR NOT EXISTS (SELECT 1 FROM pg_trigger
      WHERE tgrelid='public.digital_receipts'::regclass
        AND tgname='zz_direct_order_enrich_digital_receipt_packing' AND tgenabled='O')
    OR NOT EXISTS (SELECT 1 FROM pg_trigger
      WHERE tgrelid='public.print_jobs'::regclass
        AND tgname='zz_direct_order_enrich_print_fulfillment' AND tgenabled='O') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PACKING_CONTRACT_VERIFICATION_FAILED';
  END IF;
END;
$verify$;
COMMIT;
