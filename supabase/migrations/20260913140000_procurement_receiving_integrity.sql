-- P1: immutable commercial terms and line-level receiving completion.
-- Additive migration. Never recover historical terms from today's supplier master.
BEGIN;
ALTER TABLE public.inventory_purchase_order_lines
 ADD COLUMN order_unit_quantity_base_snapshot numeric(12,3),
 ADD COLUMN tax_rate_snapshot numeric(5,2),
 ADD COLUMN base_unit_snapshot text,
 ADD COLUMN cancelled_quantity_base numeric(12,3) NOT NULL DEFAULT 0,
 ADD CONSTRAINT inventory_line_cancelled_qty_valid CHECK (
   cancelled_quantity_base>=0 AND cancelled_quantity_base<=ordered_quantity_base);

UPDATE public.inventory_purchase_order_lines SET
 order_unit_quantity_base_snapshot=CASE
   WHEN recommendation_snapshot->>'order_unit_quantity_base' ~ '^[0-9]+(\.[0-9]+)?$'
     THEN (recommendation_snapshot->>'order_unit_quantity_base')::numeric
   WHEN ordered_quantity_unit>0 THEN ordered_quantity_base/ordered_quantity_unit END,
 tax_rate_snapshot=CASE
   WHEN recommendation_snapshot->>'tax_rate' ~ '^[0-9]+(\.[0-9]+)?$'
     THEN (recommendation_snapshot->>'tax_rate')::numeric
   -- Only exactly recoverable integer VAT rates are safe from historical amounts.
   WHEN supply_amount>0 AND round(tax_amount/supply_amount*100)=tax_amount/supply_amount*100
     THEN tax_amount/supply_amount*100 END;

CREATE OR REPLACE FUNCTION public.capture_inventory_order_line_terms()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE item public.inventory_supplier_items%rowtype; state text; product public.inventory_products%rowtype;
BEGIN
 SELECT status INTO state FROM public.inventory_purchase_orders WHERE id=NEW.purchase_order_id;
 IF TG_OP='UPDATE' AND COALESCE(current_setting('app.procurement_terms_repair',true),'')<>'true' AND state NOT IN ('draft','submitted','office_returned') AND (
   NEW.ordered_quantity_base IS DISTINCT FROM OLD.ordered_quantity_base
   OR NEW.ordered_quantity_unit IS DISTINCT FROM OLD.ordered_quantity_unit
   OR NEW.unit_price IS DISTINCT FROM OLD.unit_price
   OR NEW.tax_amount IS DISTINCT FROM OLD.tax_amount
   OR NEW.order_unit_quantity_base_snapshot IS DISTINCT FROM OLD.order_unit_quantity_base_snapshot
   OR NEW.tax_rate_snapshot IS DISTINCT FROM OLD.tax_rate_snapshot
   OR NEW.product_id IS DISTINCT FROM OLD.product_id
   OR NEW.base_unit_snapshot IS DISTINCT FROM OLD.base_unit_snapshot
   OR NEW.order_unit IS DISTINCT FROM OLD.order_unit
   OR NEW.supply_amount IS DISTINCT FROM OLD.supply_amount
   OR NEW.supplier_item_id IS DISTINCT FROM OLD.supplier_item_id
 ) THEN RAISE EXCEPTION 'INVENTORY_ORDER_TERMS_IMMUTABLE'; END IF;
 IF TG_OP='INSERT' OR state IN ('draft','submitted','office_returned') THEN
   SELECT * INTO item FROM public.inventory_supplier_items WHERE id=NEW.supplier_item_id;
   SELECT * INTO product FROM public.inventory_products WHERE id=NEW.product_id;
   NEW.order_unit_quantity_base_snapshot:=COALESCE(
     NULLIF(NEW.ordered_quantity_base,0)/NULLIF(NEW.ordered_quantity_unit,0),item.order_unit_quantity_base);
   NEW.tax_rate_snapshot:=COALESCE(CASE
     WHEN NEW.recommendation_snapshot->>'tax_rate' ~ '^[0-9]+(\.[0-9]+)?$'
       THEN (NEW.recommendation_snapshot->>'tax_rate')::numeric END,item.tax_rate);
   NEW.base_unit_snapshot:=product.base_unit;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER capture_inventory_order_line_terms
BEFORE INSERT OR UPDATE ON public.inventory_purchase_order_lines
FOR EACH ROW EXECUTE FUNCTION public.capture_inventory_order_line_terms();
REVOKE ALL ON FUNCTION public.capture_inventory_order_line_terms() FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.verify_inventory_receipt(
  p_receipt_id uuid,
  p_expected_version integer,
  p_idempotency_key text,
  p_lines jsonb DEFAULT '[]'::jsonb,
  p_verification_reason text DEFAULT NULL
) RETURNS public.inventory_purchase_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_receipt public.inventory_receipts%ROWTYPE;
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_line jsonb;
  v_receipt_line public.inventory_receipt_lines%ROWTYPE;
  v_order_line public.inventory_purchase_order_lines%ROWTYPE;
  v_accepted numeric(12,3);
  v_rejected numeric(12,3);
  v_price numeric(12,2);
  v_reason text;
  v_conversion numeric(12,3);
  v_unit_quantity numeric(12,3);
  v_tax_rate numeric(5,2);
  v_supply numeric(12,2) := 0;
  v_tax numeric(12,2) := 0;
  v_ordered_total numeric(12,3);
  v_accepted_before numeric(12,3);
  v_accepted_after numeric(12,3);
  v_previous public.inventory_receipt_confirmation_attempts%ROWTYPE;
  v_payload_hash text;
  v_attempt_key text := NULLIF(btrim(COALESCE(p_idempotency_key, '')), '');
BEGIN
  IF v_attempt_key IS NULL THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_IDEMPOTENCY_KEY_REQUIRED'; END IF;
  SELECT * INTO v_receipt FROM public.inventory_receipts
  WHERE id = p_receipt_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_NOT_FOUND'; END IF;
  SELECT * INTO v_order FROM public.inventory_purchase_orders
  WHERE id = v_receipt.purchase_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND'; END IF;
  SELECT * INTO v_receipt FROM public.inventory_receipts
  WHERE id = p_receipt_id FOR UPDATE;
  IF NOT public.can_verify_inventory_receipt(v_receipt.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_VERIFY_FORBIDDEN';
  END IF;
  IF v_receipt.received_by IS NOT DISTINCT FROM auth.uid() OR EXISTS (
    SELECT 1 FROM public.inventory_receipt_submission_attempts a
    WHERE a.receipt_id=v_receipt.id AND a.actor_id=auth.uid()) THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_MAKER_CHECKER_REQUIRED';
  END IF;
  v_payload_hash := encode(extensions.digest(convert_to(jsonb_build_object(
    'receipt_id',p_receipt_id,'lines',COALESCE(p_lines,'[]'::jsonb),
    'reason',NULLIF(btrim(p_verification_reason),'')
  )::text,'UTF8'),'sha256'),'hex');
  SELECT * INTO v_previous FROM public.inventory_receipt_confirmation_attempts
    WHERE purchase_order_id=v_order.id AND attempt_key=v_attempt_key;
  IF FOUND THEN
    IF v_previous.receipt_id IS DISTINCT FROM p_receipt_id
       OR v_previous.actor_id IS DISTINCT FROM auth.uid()
       OR v_previous.metadata->>'payload_hash' IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_RETRY_MISMATCH';
    END IF;
    RETURN v_order;
  END IF;
  IF v_receipt.status = 'confirmed' THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_ALREADY_CONFIRMED';
  END IF;
  IF v_receipt.status <> 'draft' THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_NOT_VERIFIABLE'; END IF;
  IF v_receipt.row_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_STALE_VERSION'; END IF;
  PERFORM public.validate_inventory_receipt_attachment(
    v_receipt.restaurant_id, v_receipt.id, v_receipt.statement_storage_path, v_receipt.inspector_name);
  IF v_receipt.submitted_at IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_SUBMISSION_REQUIRED';
  END IF;

  SELECT COALESCE(sum(ordered_quantity_base), 0) INTO v_ordered_total
  FROM public.inventory_purchase_order_lines WHERE purchase_order_id = v_order.id;
  SELECT COALESCE(sum(irl.accepted_quantity_base), 0) INTO v_accepted_before
  FROM public.inventory_receipt_lines irl
  JOIN public.inventory_receipts ir ON ir.id = irl.receipt_id
  WHERE ir.purchase_order_id = v_order.id AND ir.status = 'confirmed';

  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array'
     AND jsonb_array_length(p_lines) > 0 THEN
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
      SELECT * INTO v_receipt_line FROM public.inventory_receipt_lines
      WHERE receipt_id = v_receipt.id
        AND purchase_order_line_id = NULLIF(
          v_line->>'purchase_order_line_id', ''
        )::uuid FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_LINE_NOT_FOUND'; END IF;
      SELECT * INTO v_order_line FROM public.inventory_purchase_order_lines
      WHERE id = v_receipt_line.purchase_order_line_id;
      v_accepted := COALESCE(
        NULLIF(v_line->>'accepted_quantity_base', '')::numeric,
        v_receipt_line.accepted_quantity_base
      );
      v_rejected := COALESCE(
        NULLIF(v_line->>'rejected_quantity_base', '')::numeric,
        v_receipt_line.rejected_quantity_base
      );
      v_price := COALESCE(
        NULLIF(v_line->>'actual_unit_price', '')::numeric,
        v_receipt_line.actual_unit_price, v_order_line.unit_price
      );
      v_reason := COALESCE(
        NULLIF(btrim(COALESCE(v_line->>'discrepancy_reason', '')), ''),
        v_receipt_line.discrepancy_reason
      );
      IF v_accepted < 0 OR v_rejected < 0 OR v_price < 0
         OR v_accepted::text IN ('NaN','Infinity','-Infinity')
         OR v_rejected::text IN ('NaN','Infinity','-Infinity')
         OR v_price::text IN ('NaN','Infinity','-Infinity') THEN
        RAISE EXCEPTION 'INVENTORY_RECEIPT_FINAL_VALUE_INVALID';
      END IF;
      IF (v_accepted IS DISTINCT FROM v_receipt_line.accepted_quantity_base
          OR v_price IS DISTINCT FROM v_order_line.unit_price)
         AND v_reason IS NULL THEN
        RAISE EXCEPTION 'INVENTORY_RECEIPT_DISCREPANCY_REASON_REQUIRED';
      END IF;
      UPDATE public.inventory_receipt_lines SET
        received_quantity_base = v_accepted + v_rejected,
        accepted_quantity_base = v_accepted,
        rejected_quantity_base = v_rejected,
        actual_unit_price = v_price,
        discrepancy_reason = v_reason,
        updated_at = now()
      WHERE id = v_receipt_line.id;
    END LOOP;
  END IF;

  v_receipt.total_supply_amount := 0;
  v_receipt.tax_amount := 0;
  FOR v_receipt_line IN
    SELECT * FROM public.inventory_receipt_lines
    WHERE receipt_id = v_receipt.id FOR UPDATE
  LOOP
    SELECT * INTO v_order_line FROM public.inventory_purchase_order_lines
    WHERE id = v_receipt_line.purchase_order_line_id;
    v_conversion := v_order_line.order_unit_quantity_base_snapshot;
    v_tax_rate := v_order_line.tax_rate_snapshot;
    IF v_conversion IS NULL OR v_conversion <= 0 OR v_tax_rate IS NULL THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_ORDER_TERMS_REVIEW_REQUIRED';
    END IF;
    v_unit_quantity := v_receipt_line.accepted_quantity_base / v_conversion;
    UPDATE public.inventory_receipt_lines SET
      actual_unit_price = COALESCE(actual_unit_price, v_order_line.unit_price),
      final_supply_amount = round(v_unit_quantity *
        COALESCE(actual_unit_price, v_order_line.unit_price), 2),
      final_tax_amount = round(v_unit_quantity *
        COALESCE(actual_unit_price, v_order_line.unit_price) * v_tax_rate / 100, 2),
      updated_at = now()
    WHERE id = v_receipt_line.id
    RETURNING final_supply_amount, final_tax_amount INTO v_supply, v_tax;
    v_receipt.total_supply_amount := v_receipt.total_supply_amount + v_supply;
    v_receipt.tax_amount := v_receipt.tax_amount + v_tax;
  END LOOP;

  IF EXISTS (
    SELECT 1 FROM public.inventory_receipt_lines rl
    LEFT JOIN public.inventory_purchase_order_lines ol ON ol.id=rl.purchase_order_line_id
    LEFT JOIN public.inventory_products pr ON pr.id=rl.product_id
    LEFT JOIN public.inventory_items it ON it.id=pr.inventory_item_id
    WHERE rl.receipt_id=v_receipt.id AND rl.accepted_quantity_base>0
      AND (ol.id IS NULL OR ol.purchase_order_id<>v_order.id
        OR ol.product_id<>rl.product_id OR pr.restaurant_id<>v_order.restaurant_id
        OR it.id IS NULL OR it.restaurant_id<>v_order.restaurant_id)
  ) THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_STOCK_MAPPING_REQUIRED'; END IF;

  UPDATE public.inventory_items ii SET
    current_stock = COALESCE(ii.current_stock, 0) + received.accepted_quantity_base,
    quantity = COALESCE(ii.quantity, 0) + received.accepted_quantity_base,
    updated_at = now()
  FROM (
    SELECT ip.inventory_item_id,
      sum(irl.accepted_quantity_base) accepted_quantity_base
    FROM public.inventory_receipt_lines irl
    JOIN public.inventory_products ip ON ip.id = irl.product_id
    WHERE irl.receipt_id = v_receipt.id AND ip.inventory_item_id IS NOT NULL
    GROUP BY ip.inventory_item_id
  ) received
  WHERE ii.id = received.inventory_item_id
    AND ii.restaurant_id = v_order.restaurant_id;

  INSERT INTO public.inventory_transactions(
    restaurant_id, ingredient_id, transaction_type, quantity_g,
    reference_type, reference_id, note, created_by
  )
  SELECT v_order.restaurant_id, ip.inventory_item_id, 'restock',
    sum(irl.accepted_quantity_base), 'inventory_purchase_receipt', v_receipt.id,
    'Verified supplier statement ' || COALESCE(v_receipt.statement_number, v_receipt.id::text), auth.uid()
  FROM public.inventory_receipt_lines irl
  JOIN public.inventory_products ip ON ip.id = irl.product_id
  WHERE irl.receipt_id = v_receipt.id AND ip.inventory_item_id IS NOT NULL
    AND irl.accepted_quantity_base > 0
  GROUP BY ip.inventory_item_id;

  UPDATE public.inventory_receipts SET
    status = 'confirmed', verified_by = auth.uid(), verified_at = now(),
    total_supply_amount = v_receipt.total_supply_amount,
    tax_amount = v_receipt.tax_amount,
    total_amount = v_receipt.total_supply_amount + v_receipt.tax_amount,
    verification_reason = NULLIF(btrim(COALESCE(p_verification_reason, '')), ''),
    row_version = row_version + 1, updated_at = now()
  WHERE id = v_receipt.id RETURNING * INTO v_receipt;

  SELECT COALESCE(sum(irl.accepted_quantity_base), 0) INTO v_accepted_after
  FROM public.inventory_receipt_lines irl
  JOIN public.inventory_receipts ir ON ir.id = irl.receipt_id
  WHERE ir.purchase_order_id = v_order.id AND ir.status = 'confirmed';

  UPDATE public.inventory_purchase_orders SET
    status = CASE WHEN NOT EXISTS (
      SELECT 1 FROM public.inventory_purchase_order_lines pol
      WHERE pol.purchase_order_id=v_order.id
        AND pol.ordered_quantity_base-pol.cancelled_quantity_base > COALESCE((
          SELECT sum(rl.accepted_quantity_base) FROM public.inventory_receipt_lines rl
          JOIN public.inventory_receipts r ON r.id=rl.receipt_id
          WHERE rl.purchase_order_line_id=pol.id AND r.status='confirmed'
        ),0)
    ) THEN 'received' ELSE 'partially_received' END,
    row_version = row_version + 1, updated_at = now()
  WHERE id = v_order.id RETURNING * INTO v_order;

  INSERT INTO public.inventory_receipt_confirmation_attempts(
    purchase_order_id, receipt_id, restaurant_id, actor_id, attempt_key,
    attempt_status, requested_line_count, accepted_total_quantity_base,
    rejected_total_quantity_base, remaining_quantity_before_base,
    remaining_quantity_after_base, metadata
  ) SELECT
    v_order.id, v_receipt.id, v_order.restaurant_id, auth.uid(), v_attempt_key,
    'succeeded', count(*)::integer,
    COALESCE(sum(accepted_quantity_base), 0),
    COALESCE(sum(rejected_quantity_base), 0),
    GREATEST(v_ordered_total - v_accepted_before, 0),
    GREATEST(v_ordered_total - v_accepted_after, 0),
    jsonb_build_object(
      'payload_hash',v_payload_hash,'maker_checker', true, 'statement_number', v_receipt.statement_number,
      'order_status_after', v_order.status,
      'total_amount', v_receipt.total_amount
    )
  FROM public.inventory_receipt_lines WHERE receipt_id = v_receipt.id;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'inventory_receipt_verified', 'inventory_purchase_order',
    v_order.id, jsonb_build_object(
      'receipt_id', v_receipt.id,
      'statement_number', v_receipt.statement_number,
      'total_amount', v_receipt.total_amount,
      'order_status_after', v_order.status
    )
  );
  RETURN v_order;
END;
$$;
CREATE OR REPLACE FUNCTION public.get_inventory_actual_purchase_prices(p_store_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
BEGIN
 IF NOT (public.can_access_inventory_purchase_store(p_store_id) OR public.can_verify_inventory_receipt(p_store_id)) THEN
   RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN'; END IF;
 RETURN COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM (
   SELECT DISTINCT ON (rl.product_id,r.supplier_id)
     rl.product_id,r.supplier_id,rl.actual_unit_price,ol.order_unit,
     ol.order_unit_quantity_base_snapshot,ol.tax_rate_snapshot,
     r.id AS receipt_id,r.verified_at
   FROM public.inventory_receipt_lines rl
   JOIN public.inventory_receipts r ON r.id=rl.receipt_id
   JOIN public.inventory_purchase_order_lines ol ON ol.id=rl.purchase_order_line_id
   WHERE r.restaurant_id=p_store_id AND r.status='confirmed' AND rl.accepted_quantity_base>0
   ORDER BY rl.product_id,r.supplier_id,r.verified_at DESC,r.id DESC
 ) x),'[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.get_inventory_actual_purchase_prices(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_actual_purchase_prices(uuid) TO authenticated,service_role;
COMMIT;
