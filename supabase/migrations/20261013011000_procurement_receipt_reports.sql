BEGIN;
-- production-gate: self-verifying

CREATE TABLE public.procurement_receipt_reports (
 receipt_id uuid PRIMARY KEY REFERENCES public.inventory_receipts(id),
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
 purchase_order_id uuid NOT NULL REFERENCES public.inventory_purchase_orders(id),
 kind text NOT NULL CHECK(kind IN ('complete','discrepancy')),
 data jsonb NOT NULL, source_hash text NOT NULL,
 storage_path text, file_hash text, byte_size integer,
 sent_at timestamptz, sent_actor jsonb, channel text, delivery_reference text,
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.procurement_receipt_reports ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.procurement_receipt_reports FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.procurement_receipt_reports TO service_role;
CREATE INDEX procurement_receipt_reports_order ON public.procurement_receipt_reports(purchase_order_id,created_at,receipt_id);

-- Inspection validation joins product metadata once for the complete receipt.
CREATE FUNCTION public.procurement_validate_inspection_batch(p_store_id uuid,p_lines jsonb)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE rows jsonb;
BEGIN
 SELECT jsonb_agg(x||jsonb_build_object('storage_type',p.storage_type)) INTO rows
 FROM jsonb_array_elements(p_lines) x
 JOIN public.inventory_purchase_order_lines ol ON ol.id=(x->>'purchase_order_line_id')::uuid
 JOIN public.inventory_products p ON p.id=ol.product_id AND p.restaurant_id=p_store_id;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(rows) x WHERE jsonb_typeof(x->'inspection') IS DISTINCT FROM 'object') THEN RAISE EXCEPTION 'PROCUREMENT_INSPECTION_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(rows) x WHERE x->'inspection'->>'issue_type' IS NULL OR x->'inspection'->>'issue_type' NOT IN ('none','shortage','excess','wrong_item','damaged','specification','quality','expiry','temperature')) THEN RAISE EXCEPTION 'PROCUREMENT_ISSUE_TYPE_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(rows) x WHERE COALESCE((x->>'accepted_quantity_base')::numeric,(x->>'received_quantity_base')::numeric-COALESCE((x->>'rejected_quantity_base')::numeric,0))>0 AND
  (NOT COALESCE((x->'inspection'->>'spec_ok')::boolean,false) OR NOT COALESCE((x->'inspection'->>'quality_ok')::boolean,false) OR NOT COALESCE((x->'inspection'->>'packaging_ok')::boolean,false))) THEN RAISE EXCEPTION 'PROCUREMENT_FAILED_INSPECTION_CANNOT_ACCEPT'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(rows) x WHERE COALESCE((x->>'accepted_quantity_base')::numeric,(x->>'received_quantity_base')::numeric-COALESCE((x->>'rejected_quantity_base')::numeric,0))>0 AND
  NOT COALESCE((x->'inspection'->>'expiry_not_applicable')::boolean,false) AND (NULLIF(x->'inspection'->>'expiry_date','') IS NULL OR (x->'inspection'->>'expiry_date')::date<(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date)) THEN RAISE EXCEPTION 'PROCUREMENT_EXPIRY_REVIEW_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(rows) x WHERE COALESCE((x->>'accepted_quantity_base')::numeric,(x->>'received_quantity_base')::numeric-COALESCE((x->>'rejected_quantity_base')::numeric,0))>0 AND
  lower(COALESCE(x->>'storage_type',''))~'(cold|chill|frozen|freez|refriger|냉장|냉동)' AND
  (NULLIF(x->'inspection'->>'temperature_c','') IS NULL OR (x->'inspection'->>'temperature_c')::numeric::text IN ('NaN','Infinity','-Infinity') OR (x->'inspection'->>'temperature_c')::numeric NOT BETWEEN -100 AND 100 OR NOT COALESCE((x->'inspection'->>'temperature_ok')::boolean,false))) THEN RAISE EXCEPTION 'PROCUREMENT_TEMPERATURE_REVIEW_REQUIRED'; END IF;
END $$;
REVOKE ALL ON FUNCTION public.procurement_validate_inspection_batch(uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.procurement_create_receipt_report(p_receipt_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE report jsonb;complete boolean;
BEGIN
 WITH current_receipt AS MATERIALIZED(SELECT * FROM public.inventory_receipts WHERE id=p_receipt_id AND status='confirmed'),
 totals AS(SELECT l.purchase_order_line_id,sum(l.accepted_quantity_base) accepted
  FROM public.inventory_receipt_lines l JOIN public.inventory_receipts r ON r.id=l.receipt_id
  JOIN current_receipt cr ON cr.purchase_order_id=r.purchase_order_id WHERE r.status='confirmed' GROUP BY l.purchase_order_line_id),
 lines AS(SELECT ol.id,COALESCE(ol.recommendation_snapshot->>'product_code',p.product_code) product_code,
  COALESCE(ol.recommendation_snapshot->>'product_name',p.name) product_name,ol.order_unit unit,
  ol.ordered_quantity_unit ordered_quantity,
  (COALESCE(t.accepted,0)-COALESCE(rl.accepted_quantity_base,0))/ol.order_unit_quantity_base_snapshot previous_quantity,
  COALESCE(rl.received_quantity_base,0)/ol.order_unit_quantity_base_snapshot received_quantity,
  COALESCE(rl.accepted_quantity_base,0)/ol.order_unit_quantity_base_snapshot accepted_quantity,
  COALESCE(rl.rejected_quantity_base,0)/ol.order_unit_quantity_base_snapshot rejected_quantity,
  COALESCE(t.accepted,0)/ol.order_unit_quantity_base_snapshot cumulative_quantity,
  greatest(ol.ordered_quantity_base-COALESCE(t.accepted,0),0)/ol.order_unit_quantity_base_snapshot shortage_quantity,
  greatest(COALESCE(rl.received_quantity_base,0)-COALESCE(rl.expected_quantity_base_snapshot,ol.ordered_quantity_base),0)/ol.order_unit_quantity_base_snapshot excess_quantity,
  ol.transferred_quantity_base/ol.order_unit_quantity_base_snapshot transferred_quantity,
  COALESCE(rl.discrepancy_reason,'') reason,COALESCE((ol.recommendation_snapshot->>'line_position')::integer,0) position,
  ol.ordered_quantity_base=COALESCE(t.accepted,0) AND COALESCE(rl.rejected_quantity_base,0)=0 AND COALESCE(rl.inspection->>'issue_type','none')='none'
   AND COALESCE(rl.received_quantity_base,0)<=COALESCE(rl.expected_quantity_base_snapshot,ol.ordered_quantity_base) exact
  FROM current_receipt cr JOIN public.inventory_purchase_order_lines ol ON ol.purchase_order_id=cr.purchase_order_id
  JOIN public.inventory_products p ON p.id=ol.product_id LEFT JOIN totals t ON t.purchase_order_line_id=ol.id
  LEFT JOIN public.inventory_receipt_lines rl ON rl.receipt_id=cr.id AND rl.purchase_order_line_id=ol.id)
 SELECT jsonb_build_object('receipt_id',cr.id,'purchase_order_id',po.id,'purchase_order_no',po.purchase_order_no,
  'store_name',s.name,'supplier_name',v.supplier_name,'supplier_id',po.supplier_id,
  'received_at',cr.received_at,'confirmed_at',cr.verified_at,'inspector_name',cr.inspector_name,
  'delivery_cycle',cr.delivery_cycle,'lines',(SELECT jsonb_agg(to_jsonb(l)-'exact'-'position' ORDER BY l.position,l.id) FROM lines l)),
  (SELECT COALESCE(bool_and(exact),false) FROM lines)
 INTO report,complete FROM current_receipt cr JOIN public.inventory_purchase_orders po ON po.id=cr.purchase_order_id
 JOIN public.restaurants s ON s.id=po.restaurant_id JOIN public.inventory_suppliers v ON v.id=po.supplier_id;
 IF report IS NULL THEN RAISE EXCEPTION 'PROCUREMENT_CONFIRMED_RECEIPT_REQUIRED'; END IF;
 report:=report||jsonb_build_object('kind',CASE WHEN complete THEN 'complete' ELSE 'discrepancy' END);
 INSERT INTO public.procurement_receipt_reports(receipt_id,restaurant_id,purchase_order_id,kind,data,source_hash)
 SELECT cr.id,cr.restaurant_id,cr.purchase_order_id,report->>'kind',report,
  encode(extensions.digest(convert_to(report::text,'UTF8'),'sha256'),'hex') FROM public.inventory_receipts cr WHERE cr.id=p_receipt_id
 ON CONFLICT(receipt_id) DO NOTHING;
END $$;
REVOKE ALL ON FUNCTION public.procurement_create_receipt_report(uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.procurement_receipt_report_data(p_store_id uuid,p_receipt_id uuid,p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb;report jsonb;
BEGIN
 actor:=public.procurement_actor(p_store_id,p_office_actor);
 SELECT to_jsonb(r) INTO report FROM public.procurement_receipt_reports r WHERE receipt_id=p_receipt_id AND restaurant_id=p_store_id;
 IF report IS NULL THEN RAISE EXCEPTION 'PROCUREMENT_REPORT_NOT_READY'; END IF;
 RETURN report;
END $$;
REVOKE ALL ON FUNCTION public.procurement_receipt_report_data(uuid,uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.procurement_receipt_report_data(uuid,uuid,jsonb) TO authenticated,service_role;

CREATE FUNCTION public.procurement_record_receipt_report(p_store_id uuid,p_receipt_id uuid,p_source_hash text,p_path text,p_file_hash text,p_size integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb;
BEGIN
 actor:=public.procurement_actor(p_store_id);
 IF p_path IS DISTINCT FROM p_store_id::text||'/procurement/receipt/'||p_receipt_id::text||'/supplier/'||p_source_hash||'/'||p_file_hash||'.pdf'
  OR p_file_hash!~'^[0-9a-f]{64}$' OR p_size NOT BETWEEN 1 AND 10485760 THEN RAISE EXCEPTION 'PROCUREMENT_DOCUMENT_PATH_INVALID'; END IF;
 IF NOT EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='inventory-purchase-documents' AND name=p_path) THEN RAISE EXCEPTION 'PROCUREMENT_DOCUMENT_OBJECT_REQUIRED'; END IF;
 UPDATE public.procurement_receipt_reports SET storage_path=p_path,byte_size=p_size,
 sent_at=CASE WHEN file_hash IS DISTINCT FROM p_file_hash THEN NULL ELSE sent_at END,sent_actor=CASE WHEN file_hash IS DISTINCT FROM p_file_hash THEN NULL ELSE sent_actor END,channel=CASE WHEN file_hash IS DISTINCT FROM p_file_hash THEN NULL ELSE channel END,delivery_reference=CASE WHEN file_hash IS DISTINCT FROM p_file_hash THEN NULL ELSE delivery_reference END,file_hash=p_file_hash
 WHERE receipt_id=p_receipt_id AND restaurant_id=p_store_id AND source_hash=p_source_hash;
 IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_DOCUMENT_SOURCE_CHANGED'; END IF;
END $$;
REVOKE ALL ON FUNCTION public.procurement_record_receipt_report(uuid,uuid,text,text,text,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.procurement_record_receipt_report(uuid,uuid,text,text,text,integer) TO authenticated;

CREATE FUNCTION public.can_access_procurement_receipt_file(p_path text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
 SELECT EXISTS(SELECT 1 FROM public.procurement_receipt_reports r WHERE p_path LIKE r.restaurant_id::text||'/procurement/receipt/'||r.receipt_id::text||'/supplier/'||r.source_hash||'/%'
  AND public.can_access_inventory_workflow(r.restaurant_id))
$$;
REVOKE ALL ON FUNCTION public.can_access_procurement_receipt_file(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.can_access_procurement_receipt_file(text) TO authenticated;
CREATE POLICY procurement_receipt_objects_read ON storage.objects FOR SELECT TO authenticated USING(bucket_id='inventory-purchase-documents' AND public.can_access_procurement_receipt_file(name));
CREATE POLICY procurement_receipt_objects_insert ON storage.objects FOR INSERT TO authenticated WITH CHECK(bucket_id='inventory-purchase-documents' AND public.can_access_procurement_receipt_file(name));

CREATE OR REPLACE FUNCTION public.verify_inventory_receipt_p1(
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
  IF v_order.commercial_terms->>'approval_policy_version'='3' THEN
    IF NOT public.can_create_inventory_purchase_order(v_receipt.restaurant_id) AND NOT public.can_verify_inventory_receipt(v_receipt.restaurant_id) THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_VERIFY_FORBIDDEN'; END IF;
  ELSE
    IF NOT public.can_verify_inventory_receipt(v_receipt.restaurant_id) THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_VERIFY_FORBIDDEN'; END IF;
    IF v_receipt.received_by IS NOT DISTINCT FROM auth.uid() OR EXISTS(SELECT 1 FROM public.inventory_receipt_submission_attempts a WHERE a.receipt_id=v_receipt.id AND a.actor_id=auth.uid()) THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_MAKER_CHECKER_REQUIRED'; END IF;
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

  IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines)>200 THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_LINES_REQUIRED'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_lines) x LEFT JOIN public.inventory_receipt_lines l ON l.receipt_id=v_receipt.id AND l.purchase_order_line_id=(x->>'purchase_order_line_id')::uuid WHERE l.id IS NULL) OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_lines) x GROUP BY x->>'purchase_order_line_id' HAVING count(*)>1) THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_LINE_NOT_FOUND'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_lines) x WHERE (x->>'accepted_quantity_base')::numeric<0 OR (x->>'rejected_quantity_base')::numeric<0 OR (x->>'actual_unit_price')::numeric<0 OR (x->>'accepted_quantity_base')::numeric::text IN ('NaN','Infinity','-Infinity') OR (x->>'rejected_quantity_base')::numeric::text IN ('NaN','Infinity','-Infinity') OR (x->>'actual_unit_price')::numeric::text IN ('NaN','Infinity','-Infinity')) THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_FINAL_VALUE_INVALID'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_lines) x JOIN public.inventory_receipt_lines l ON l.receipt_id=v_receipt.id AND l.purchase_order_line_id=(x->>'purchase_order_line_id')::uuid JOIN public.inventory_purchase_order_lines ol ON ol.id=l.purchase_order_line_id WHERE
    (COALESCE((x->>'accepted_quantity_base')::numeric,l.accepted_quantity_base)<>l.accepted_quantity_base OR COALESCE((x->>'actual_unit_price')::numeric,l.actual_unit_price,ol.unit_price)<>ol.unit_price) AND NULLIF(btrim(x->>'discrepancy_reason'),'') IS NULL) THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_DISCREPANCY_REASON_REQUIRED'; END IF;
  UPDATE public.inventory_receipt_lines l SET accepted_quantity_base=COALESCE((x->>'accepted_quantity_base')::numeric,l.accepted_quantity_base),
    rejected_quantity_base=COALESCE((x->>'rejected_quantity_base')::numeric,l.rejected_quantity_base),
    received_quantity_base=COALESCE((x->>'accepted_quantity_base')::numeric,l.accepted_quantity_base)+COALESCE((x->>'rejected_quantity_base')::numeric,l.rejected_quantity_base),
    actual_unit_price=COALESCE((x->>'actual_unit_price')::numeric,l.actual_unit_price,ol.unit_price),discrepancy_reason=COALESCE(NULLIF(btrim(x->>'discrepancy_reason'),''),l.discrepancy_reason),updated_at=now()
  FROM jsonb_array_elements(p_lines) x, public.inventory_purchase_order_lines ol WHERE l.receipt_id=v_receipt.id AND l.purchase_order_line_id=(x->>'purchase_order_line_id')::uuid AND ol.id=l.purchase_order_line_id;
  IF EXISTS(SELECT 1 FROM public.inventory_receipt_lines l JOIN public.inventory_purchase_order_lines ol ON ol.id=l.purchase_order_line_id WHERE l.receipt_id=v_receipt.id AND (ol.order_unit_quantity_base_snapshot IS NULL OR ol.order_unit_quantity_base_snapshot<=0 OR ol.tax_rate_snapshot IS NULL)) THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_ORDER_TERMS_REVIEW_REQUIRED'; END IF;
  UPDATE public.inventory_receipt_lines l SET actual_unit_price=COALESCE(l.actual_unit_price,ol.unit_price),
    final_supply_amount=round(round(l.accepted_quantity_base/ol.order_unit_quantity_base_snapshot,3)*COALESCE(l.actual_unit_price,ol.unit_price),2),
    final_tax_amount=round(round(l.accepted_quantity_base/ol.order_unit_quantity_base_snapshot,3)*COALESCE(l.actual_unit_price,ol.unit_price)*ol.tax_rate_snapshot/100,2),updated_at=now()
  FROM public.inventory_purchase_order_lines ol WHERE l.receipt_id=v_receipt.id AND ol.id=l.purchase_order_line_id;
  SELECT COALESCE(sum(final_supply_amount),0),COALESCE(sum(final_tax_amount),0) INTO v_receipt.total_supply_amount,v_receipt.tax_amount FROM public.inventory_receipt_lines WHERE receipt_id=v_receipt.id;

  IF EXISTS (
    SELECT 1 FROM public.inventory_receipt_lines rl
    LEFT JOIN public.inventory_purchase_order_lines ol ON ol.id=rl.purchase_order_line_id
    LEFT JOIN public.inventory_products pr ON pr.id=rl.product_id
    LEFT JOIN public.inventory_items it ON it.id=pr.inventory_item_id
    WHERE rl.receipt_id=v_receipt.id AND rl.accepted_quantity_base>0
      AND (ol.id IS NULL OR ol.purchase_order_id<>v_order.id
        OR ol.product_id<>rl.product_id OR pr.restaurant_id<>v_order.restaurant_id
        OR (ol.receipt_classification_snapshot='stock' AND (it.id IS NULL OR it.restaurant_id<>v_order.restaurant_id)))
  ) THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_STOCK_MAPPING_REQUIRED'; END IF;

  IF v_order.workflow_version=2 AND EXISTS(WITH accepted AS (
    SELECT l.purchase_order_line_id,sum(l.accepted_quantity_base) qty FROM public.inventory_receipt_lines l
    JOIN public.inventory_receipts r ON r.id=l.receipt_id AND r.status='confirmed' WHERE r.purchase_order_id=v_order.id GROUP BY l.purchase_order_line_id)
    SELECT 1 FROM public.inventory_receipt_lines l JOIN public.inventory_purchase_order_lines ol ON ol.id=l.purchase_order_line_id
    LEFT JOIN accepted a ON a.purchase_order_line_id=ol.id WHERE l.receipt_id=v_receipt.id
    AND l.accepted_quantity_base>ol.ordered_quantity_base-ol.cancelled_quantity_base-COALESCE(a.qty,0)) THEN
    RAISE EXCEPTION 'PROCUREMENT_ACCEPTED_EXCEEDS_REMAINING'; END IF;

  UPDATE public.inventory_items ii SET
    current_stock = COALESCE(ii.current_stock, 0) + received.accepted_quantity_base,
    quantity = COALESCE(ii.quantity, 0) + received.accepted_quantity_base,
    updated_at = now()
  FROM (
    SELECT ip.inventory_item_id,
      sum(irl.accepted_quantity_base) accepted_quantity_base
    FROM public.inventory_receipt_lines irl
    JOIN public.inventory_products ip ON ip.id = irl.product_id
    JOIN public.inventory_purchase_order_lines ol ON ol.id=irl.purchase_order_line_id AND ol.receipt_classification_snapshot='stock'
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
    JOIN public.inventory_purchase_order_lines ol ON ol.id=irl.purchase_order_line_id AND ol.receipt_classification_snapshot='stock'
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

  WITH accepted AS(SELECT rl.purchase_order_line_id,sum(rl.accepted_quantity_base) qty FROM public.inventory_receipt_lines rl JOIN public.inventory_receipts r ON r.id=rl.receipt_id WHERE r.purchase_order_id=v_order.id AND r.status='confirmed' GROUP BY rl.purchase_order_line_id),
  completion AS(SELECT bool_and(pol.ordered_quantity_base-pol.cancelled_quantity_base<=COALESCE(a.qty,0)) done FROM public.inventory_purchase_order_lines pol LEFT JOIN accepted a ON a.purchase_order_line_id=pol.id WHERE pol.purchase_order_id=v_order.id)
  UPDATE public.inventory_purchase_orders SET status=CASE WHEN completion.done THEN 'received' ELSE 'partially_received' END,row_version=row_version+1,updated_at=now() FROM completion WHERE id=v_order.id RETURNING inventory_purchase_orders.* INTO v_order;

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

CREATE OR REPLACE FUNCTION public.submit_inventory_receipt_batch(
  p_purchase_order_id uuid,p_receipt_id uuid,p_expected_order_version integer,
  p_expected_receipt_version integer,p_idempotency_key text,p_lines jsonb,
  p_inspector_name text,p_statement_storage_path text,
  p_statement_number text DEFAULT NULL,p_statement_date date DEFAULT NULL,p_memo text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE v_order public.inventory_purchase_orders%ROWTYPE; v_receipt public.inventory_receipts%ROWTYPE;
  v_line jsonb; v_po_line public.inventory_purchase_order_lines%ROWTYPE;
  v_qty numeric; v_rejected numeric; v_price numeric; v_ids uuid[]:=ARRAY[]::uuid[];
  v_hash text; v_previous public.inventory_receipt_submission_attempts%ROWTYPE;
  v_result jsonb; v_total numeric:=0; photo jsonb; v_remaining numeric;
BEGIN
  IF p_receipt_id IS NULL OR NULLIF(btrim(p_idempotency_key),'') IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_IDEMPOTENCY_KEY_REQUIRED'; END IF;
  SELECT * INTO v_order FROM public.inventory_purchase_orders WHERE id=p_purchase_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND'; END IF;
  IF NOT public.can_create_inventory_purchase_order(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_DRAFT_FORBIDDEN'; END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object('order',p_purchase_order_id,
    'lines',p_lines,'inspector',p_inspector_name,'file',p_statement_storage_path,
    'number',p_statement_number,'date',p_statement_date,'memo',p_memo)::text,'UTF8'),'sha256'),'hex');
  SELECT * INTO v_previous FROM public.inventory_receipt_submission_attempts
    WHERE receipt_id=p_receipt_id AND attempt_key=p_idempotency_key;
  IF FOUND THEN
    IF v_previous.actor_id<>auth.uid() OR v_previous.payload_hash<>v_hash THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_RETRY_MISMATCH'; END IF;
    RETURN v_previous.result;
  END IF;
  IF v_order.workflow_version=2 AND v_order.procurement_status<>'confirmed' THEN RAISE EXCEPTION 'PROCUREMENT_SUPPLIER_CONFIRMATION_REQUIRED'; END IF;
  IF v_order.status NOT IN ('ordered','partially_received','office_approved') THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_RECEIVABLE'; END IF;
  IF v_order.row_version IS DISTINCT FROM p_expected_order_version THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_STALE_VERSION'; END IF;
  SELECT * INTO v_receipt FROM public.inventory_receipts WHERE id=p_receipt_id FOR UPDATE;
  IF FOUND THEN
    IF v_receipt.purchase_order_id<>v_order.id OR v_receipt.status<>'draft' THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_NOT_EDITABLE'; END IF;
    IF v_receipt.row_version IS DISTINCT FROM p_expected_receipt_version THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_STALE_VERSION'; END IF;
    IF v_receipt.received_by IS DISTINCT FROM auth.uid() AND public.inventory_purchase_actor_role()='inventory_orderer' THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_DRAFT_OWNER_REQUIRED'; END IF;
  ELSE
    IF COALESCE(p_expected_receipt_version,0)<>0 OR EXISTS (
      SELECT 1 FROM public.inventory_receipts WHERE purchase_order_id=v_order.id AND status='draft') THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_STALE_VERSION'; END IF;
    INSERT INTO public.inventory_receipts(id,purchase_order_id,restaurant_id,supplier_id,received_by,status,delivery_cycle)
      SELECT p_receipt_id,v_order.id,v_order.restaurant_id,v_order.supplier_id,auth.uid(),'draft',COALESCE(max(delivery_cycle),0)+1
      FROM public.inventory_receipts WHERE purchase_order_id=v_order.id RETURNING * INTO v_receipt;
  END IF;
  PERFORM public.validate_inventory_receipt_attachment(v_order.restaurant_id,p_receipt_id,p_statement_storage_path,p_inspector_name);
  IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_LINES_REQUIRED'; END IF;
  IF jsonb_array_length(p_lines)<>(SELECT count(*) FROM public.inventory_purchase_order_lines WHERE purchase_order_id=v_order.id) OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_lines) x GROUP BY x->>'purchase_order_line_id' HAVING count(*)>1) OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_lines) x LEFT JOIN public.inventory_purchase_order_lines ol ON ol.id=(x->>'purchase_order_line_id')::uuid AND ol.purchase_order_id=v_order.id WHERE ol.id IS NULL) THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_LINE_INVALID'; END IF;
  PERFORM 1 FROM public.inventory_purchase_order_lines WHERE purchase_order_id=v_order.id ORDER BY id FOR UPDATE;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_lines) x WHERE (x->>'received_quantity_base')::numeric IS NULL OR (x->>'received_quantity_base')::numeric<0 OR COALESCE((x->>'rejected_quantity_base')::numeric,0)<0 OR COALESCE((x->>'rejected_quantity_base')::numeric,0)>(x->>'received_quantity_base')::numeric OR (x->>'actual_unit_price')::numeric<0 OR (x->>'received_quantity_base')::numeric::text IN ('NaN','Infinity','-Infinity') OR (x->>'rejected_quantity_base')::numeric::text IN ('NaN','Infinity','-Infinity') OR (x->>'actual_unit_price')::numeric::text IN ('NaN','Infinity','-Infinity')) THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_QUANTITY_INVALID'; END IF;
  IF v_order.workflow_version=2 THEN
    PERFORM public.procurement_validate_inspection_batch(v_order.restaurant_id,p_lines);
    IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_lines) x WHERE jsonb_typeof(x->'inspection'->'photo_paths') IS DISTINCT FROM 'array' OR jsonb_array_length(x->'inspection'->'photo_paths')>5 OR (COALESCE((x->>'rejected_quantity_base')::numeric,0)>0 AND x->'inspection'->>'issue_type'='none')) THEN RAISE EXCEPTION 'PROCUREMENT_PHOTOS_INVALID'; END IF;
    IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_lines) x CROSS JOIN LATERAL jsonb_array_elements(x->'inspection'->'photo_paths') image_path(value) LEFT JOIN storage.objects o ON o.bucket_id='inventory-receipt-statements' AND o.name=image_path.value#>>'{}' AND o.owner_id=auth.uid()::text WHERE split_part(image_path.value#>>'{}','/',1)<>v_order.restaurant_id::text OR split_part(image_path.value#>>'{}','/',2)<>p_receipt_id::text OR o.id IS NULL OR NOT COALESCE(lower(o.metadata->>'mimetype') IN ('application/pdf','image/png','image/jpeg'),false) OR NOT COALESCE((o.metadata->>'size')::bigint BETWEEN 1 AND 10485760,false)) THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_ATTACHMENT_REQUIRED'; END IF;
  END IF;
  WITH accepted AS(SELECT l.purchase_order_line_id,sum(l.accepted_quantity_base) qty FROM public.inventory_receipt_lines l JOIN public.inventory_receipts r ON r.id=l.receipt_id WHERE r.purchase_order_id=v_order.id AND r.status='confirmed' GROUP BY l.purchase_order_line_id)
  INSERT INTO public.inventory_receipt_lines(receipt_id,purchase_order_line_id,product_id,received_quantity_base,accepted_quantity_base,rejected_quantity_base,actual_unit_price,discrepancy_reason,inspection,expected_quantity_base_snapshot)
  SELECT p_receipt_id,ol.id,ol.product_id,(x->>'received_quantity_base')::numeric,(x->>'received_quantity_base')::numeric-COALESCE((x->>'rejected_quantity_base')::numeric,0),COALESCE((x->>'rejected_quantity_base')::numeric,0),COALESCE((x->>'actual_unit_price')::numeric,ol.unit_price),NULLIF(btrim(x->>'discrepancy_reason'),''),COALESCE(x->'inspection','{}'),greatest(0,ol.ordered_quantity_base-ol.cancelled_quantity_base-COALESCE(a.qty,0))
  FROM jsonb_array_elements(p_lines) x JOIN public.inventory_purchase_order_lines ol ON ol.id=(x->>'purchase_order_line_id')::uuid LEFT JOIN accepted a ON a.purchase_order_line_id=ol.id
  ON CONFLICT(receipt_id,purchase_order_line_id) WHERE purchase_order_line_id IS NOT NULL DO UPDATE SET received_quantity_base=EXCLUDED.received_quantity_base,accepted_quantity_base=EXCLUDED.accepted_quantity_base,rejected_quantity_base=EXCLUDED.rejected_quantity_base,actual_unit_price=EXCLUDED.actual_unit_price,discrepancy_reason=EXCLUDED.discrepancy_reason,inspection=EXCLUDED.inspection,expected_quantity_base_snapshot=EXCLUDED.expected_quantity_base_snapshot,updated_at=now();
  IF EXISTS(SELECT 1 FROM public.inventory_receipt_lines l JOIN public.inventory_purchase_order_lines ol ON ol.id=l.purchase_order_line_id WHERE l.receipt_id=p_receipt_id AND (l.received_quantity_base<>l.expected_quantity_base_snapshot OR l.actual_unit_price<>ol.unit_price) AND l.discrepancy_reason IS NULL) THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_DISCREPANCY_REASON_REQUIRED'; END IF;
  UPDATE public.inventory_receipts SET inspector_name=btrim(p_inspector_name),statement_storage_path=p_statement_storage_path,
    statement_number=NULLIF(btrim(p_statement_number),''),statement_date=p_statement_date,
    memo=NULLIF(btrim(p_memo),''),submitted_at=now(),row_version=row_version+1,updated_at=now()
    WHERE id=p_receipt_id RETURNING * INTO v_receipt;
  v_result:=jsonb_build_object('receipt_id',p_receipt_id,'row_version',v_receipt.row_version,'status',v_receipt.status);
  INSERT INTO public.inventory_receipt_submission_attempts(receipt_id,attempt_key,actor_id,payload_hash,result)
    VALUES(p_receipt_id,p_idempotency_key,auth.uid(),v_hash,v_result);
  RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION public.verify_inventory_receipt(p_receipt_id uuid,p_expected_version integer,p_idempotency_key text,
 p_lines jsonb DEFAULT '[]',p_verification_reason text DEFAULT NULL)
RETURNS public.inventory_purchase_orders LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE po public.inventory_purchase_orders%rowtype; result public.inventory_purchase_orders%rowtype; rl record; item jsonb; accepted numeric;
 saved_write text:=current_setting('app.procurement_write',true);
BEGIN
 SELECT o.* INTO po FROM public.inventory_purchase_orders o JOIN public.inventory_receipts r ON r.purchase_order_id=o.id WHERE r.id=p_receipt_id FOR UPDATE OF o;
 IF po.workflow_version=2 AND po.procurement_status<>'confirmed' THEN RAISE EXCEPTION 'PROCUREMENT_SUPPLIER_CONFIRMATION_REQUIRED'; END IF;
 IF po.workflow_version=2 AND EXISTS(SELECT 1 FROM public.inventory_receipts WHERE id=p_receipt_id AND status='draft') THEN
   IF EXISTS(SELECT 1 FROM public.inventory_receipt_lines l LEFT JOIN jsonb_array_elements(p_lines) x ON x->>'purchase_order_line_id'=l.purchase_order_line_id::text WHERE l.receipt_id=p_receipt_id AND COALESCE((x->>'accepted_quantity_base')::numeric,l.accepted_quantity_base)>l.received_quantity_base) THEN RAISE EXCEPTION 'PROCUREMENT_ACCEPTED_EXCEEDS_RECEIVED'; END IF;
   SELECT jsonb_agg(to_jsonb(l)||jsonb_build_object('accepted_quantity_base',COALESCE((x->>'accepted_quantity_base')::numeric,l.accepted_quantity_base))) INTO item FROM public.inventory_receipt_lines l LEFT JOIN jsonb_array_elements(p_lines) x ON x->>'purchase_order_line_id'=l.purchase_order_line_id::text WHERE l.receipt_id=p_receipt_id;
   PERFORM public.procurement_validate_inspection_batch(po.restaurant_id,item);
 END IF;
 PERFORM set_config('app.procurement_write','true',true);
 result:=public.verify_inventory_receipt_p1(p_receipt_id,p_expected_version,p_idempotency_key,p_lines,p_verification_reason);
 IF po.workflow_version=2 THEN
   INSERT INTO public.inventory_receipt_issues(restaurant_id,receipt_line_id,purchase_order_id,issue_type,ordered_quantity_base,received_quantity_base,accepted_quantity_base,reason)
   SELECT po.restaurant_id,l.id,po.id,CASE WHEN l.inspection->>'issue_type'<>'none' THEN l.inspection->>'issue_type'
     WHEN l.received_quantity_base>COALESCE(l.expected_quantity_base_snapshot,ol.ordered_quantity_base) THEN 'excess' ELSE 'shortage' END,
     COALESCE(l.expected_quantity_base_snapshot,ol.ordered_quantity_base),l.received_quantity_base,l.accepted_quantity_base,l.discrepancy_reason
   FROM public.inventory_receipt_lines l JOIN public.inventory_purchase_order_lines ol ON ol.id=l.purchase_order_line_id
   WHERE l.receipt_id=p_receipt_id AND (l.received_quantity_base<>COALESCE(l.expected_quantity_base_snapshot,ol.ordered_quantity_base) OR l.rejected_quantity_base>0 OR COALESCE(l.inspection->>'issue_type','none')<>'none')
   ON CONFLICT(receipt_line_id) DO NOTHING;
 END IF;
 PERFORM set_config('app.procurement_write',COALESCE(saved_write,''),true);
 IF po.workflow_version=2 THEN PERFORM public.procurement_create_receipt_report(p_receipt_id); END IF;
 RETURN result;
END $$;

-- Supplier evidence objects are append-only even for roles with broader legacy storage grants.
CREATE POLICY procurement_receipt_objects_no_update ON storage.objects AS RESTRICTIVE FOR UPDATE TO authenticated
 USING(bucket_id<>'inventory-purchase-documents' OR NOT(name LIKE '%/procurement/receipt/%'))
 WITH CHECK(bucket_id<>'inventory-purchase-documents' OR NOT(name LIKE '%/procurement/receipt/%'));
CREATE POLICY procurement_receipt_objects_no_delete ON storage.objects AS RESTRICTIVE FOR DELETE TO authenticated
 USING(bucket_id<>'inventory-purchase-documents' OR NOT(name LIKE '%/procurement/receipt/%'));
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_class WHERE oid='public.procurement_receipt_reports'::regclass AND relrowsecurity) OR has_table_privilege('authenticated','public.procurement_receipt_reports','INSERT') OR NOT EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='storage' AND policyname='procurement_receipt_objects_no_update') THEN RAISE EXCEPTION 'PROCUREMENT_20261013_BOUNDARY_INVALID'; END IF;
END $$;
COMMIT;
