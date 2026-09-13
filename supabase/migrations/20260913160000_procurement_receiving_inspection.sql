BEGIN;
ALTER TABLE public.inventory_receipt_lines ADD COLUMN inspection jsonb NOT NULL DEFAULT '{}';
CREATE TABLE public.inventory_receipt_issues(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
 receipt_line_id uuid NOT NULL UNIQUE REFERENCES public.inventory_receipt_lines(id),
 purchase_order_id uuid NOT NULL REFERENCES public.inventory_purchase_orders(id),
 issue_type text NOT NULL CHECK(issue_type IN ('shortage','excess','wrong_item','damaged','specification','quality','expiry','temperature')),
 ordered_quantity_base numeric NOT NULL, received_quantity_base numeric NOT NULL, accepted_quantity_base numeric NOT NULL,
 status text NOT NULL DEFAULT 'open' CHECK(status IN ('open','resolved')),
 resolution text CHECK(resolution IN ('additional_delivery','exchange','credit','cancel_remaining')),
 evidence_reference text, reason text, resolved_actor jsonb, row_version integer NOT NULL DEFAULT 1, created_at timestamptz NOT NULL DEFAULT now(),resolved_at timestamptz
);
ALTER TABLE public.inventory_receipt_issues ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inventory_receipt_issues FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.inventory_receipt_issues TO service_role;
CREATE FUNCTION public.validate_procurement_inspection(p_product_id uuid,p_inspection jsonb,p_accepted numeric)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE storage_type text; temp numeric;
BEGIN
 IF jsonb_typeof(p_inspection) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'PROCUREMENT_INSPECTION_REQUIRED'; END IF;
 IF p_inspection->>'issue_type' IS NULL OR p_inspection->>'issue_type' NOT IN ('none','shortage','excess','wrong_item','damaged','specification','quality','expiry','temperature') THEN RAISE EXCEPTION 'PROCUREMENT_ISSUE_TYPE_REQUIRED'; END IF;
 IF p_accepted<=0 THEN RETURN; END IF;
 IF NOT COALESCE((p_inspection->>'spec_ok')::boolean,false) OR NOT COALESCE((p_inspection->>'quality_ok')::boolean,false)
   OR NOT COALESCE((p_inspection->>'packaging_ok')::boolean,false) THEN RAISE EXCEPTION 'PROCUREMENT_FAILED_INSPECTION_CANNOT_ACCEPT'; END IF;
 IF NOT COALESCE((p_inspection->>'expiry_not_applicable')::boolean,false) AND
   (NULLIF(p_inspection->>'expiry_date','') IS NULL OR (p_inspection->>'expiry_date')::date<(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date) THEN RAISE EXCEPTION 'PROCUREMENT_EXPIRY_REVIEW_REQUIRED'; END IF;
 SELECT lower(COALESCE(p.storage_type,'')) INTO storage_type FROM public.inventory_products p WHERE id=p_product_id;
 IF storage_type ~ '(cold|chill|frozen|freez|refriger|냉장|냉동)' THEN
   temp:=NULLIF(p_inspection->>'temperature_c','')::numeric;
   IF temp IS NULL OR temp::text IN ('NaN','Infinity','-Infinity') OR temp NOT BETWEEN -100 AND 100
     OR NOT COALESCE((p_inspection->>'temperature_ok')::boolean,false) THEN RAISE EXCEPTION 'PROCUREMENT_TEMPERATURE_REVIEW_REQUIRED'; END IF;
 END IF;
END $$;
REVOKE ALL ON FUNCTION public.validate_procurement_inspection(uuid,jsonb,numeric) FROM PUBLIC,anon,authenticated;
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
  v_result jsonb; v_total numeric:=0; photo jsonb;
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
  IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines)=0 THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_LINES_REQUIRED'; END IF;
  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    SELECT * INTO v_po_line FROM public.inventory_purchase_order_lines
      WHERE id=(v_line->>'purchase_order_line_id')::uuid AND purchase_order_id=v_order.id FOR UPDATE;
    IF NOT FOUND OR v_po_line.id=ANY(v_ids) THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_LINE_INVALID'; END IF;
    v_ids:=array_append(v_ids,v_po_line.id);
    v_qty:=NULLIF(v_line->>'received_quantity_base','')::numeric;
    v_rejected:=COALESCE(NULLIF(v_line->>'rejected_quantity_base','')::numeric,0);
    v_price:=COALESCE(NULLIF(v_line->>'actual_unit_price','')::numeric,v_po_line.unit_price);
    IF v_qty IS NULL OR v_qty<0 OR v_rejected<0 OR v_rejected>v_qty OR v_price<0
      OR v_rejected::text IN ('NaN','Infinity','-Infinity')
      OR v_qty::text IN ('NaN','Infinity','-Infinity') OR v_price::text IN ('NaN','Infinity','-Infinity') THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_QUANTITY_INVALID'; END IF;
    IF (v_qty<>v_po_line.ordered_quantity_base OR v_price<>v_po_line.unit_price)
      AND NULLIF(btrim(v_line->>'discrepancy_reason'),'') IS NULL THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_DISCREPANCY_REASON_REQUIRED'; END IF;
    IF v_order.workflow_version=2 THEN
      PERFORM public.validate_procurement_inspection(v_po_line.product_id,v_line->'inspection',v_qty-v_rejected);
      IF jsonb_typeof(v_line->'inspection'->'photo_paths') IS DISTINCT FROM 'array' OR jsonb_array_length(v_line->'inspection'->'photo_paths')>5 THEN RAISE EXCEPTION 'PROCUREMENT_PHOTOS_INVALID'; END IF;
      FOR photo IN SELECT * FROM jsonb_array_elements(v_line->'inspection'->'photo_paths') LOOP
        PERFORM public.validate_inventory_receipt_attachment(v_order.restaurant_id,p_receipt_id,photo#>>'{}',p_inspector_name);
      END LOOP;
      IF v_rejected>0 AND COALESCE(v_line->'inspection'->>'issue_type','none')='none' THEN RAISE EXCEPTION 'PROCUREMENT_ISSUE_TYPE_REQUIRED'; END IF;
    END IF;
    v_total:=v_total+v_qty;
    INSERT INTO public.inventory_receipt_lines(receipt_id,purchase_order_line_id,product_id,
      received_quantity_base,accepted_quantity_base,rejected_quantity_base,actual_unit_price,discrepancy_reason,inspection)
    VALUES (p_receipt_id,v_po_line.id,v_po_line.product_id,v_qty,v_qty-v_rejected,v_rejected,v_price,
      NULLIF(btrim(v_line->>'discrepancy_reason'),''),COALESCE(v_line->'inspection','{}'))
    ON CONFLICT (receipt_id,purchase_order_line_id) WHERE purchase_order_line_id IS NOT NULL
    DO UPDATE SET received_quantity_base=EXCLUDED.received_quantity_base,
      accepted_quantity_base=EXCLUDED.accepted_quantity_base,rejected_quantity_base=EXCLUDED.rejected_quantity_base,
      actual_unit_price=EXCLUDED.actual_unit_price,discrepancy_reason=EXCLUDED.discrepancy_reason,inspection=EXCLUDED.inspection,updated_at=now();
  END LOOP;
  IF cardinality(v_ids)<>(SELECT count(*) FROM public.inventory_purchase_order_lines WHERE purchase_order_id=v_order.id)
     OR v_total<=0 THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_LINES_REQUIRED'; END IF;
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
   FOR rl IN SELECT * FROM public.inventory_receipt_lines WHERE receipt_id=p_receipt_id LOOP
     SELECT e INTO item FROM jsonb_array_elements(p_lines) e WHERE e->>'purchase_order_line_id'=rl.purchase_order_line_id::text;
     accepted:=COALESCE((item->>'accepted_quantity_base')::numeric,rl.accepted_quantity_base);
     IF accepted>rl.received_quantity_base THEN RAISE EXCEPTION 'PROCUREMENT_ACCEPTED_EXCEEDS_RECEIVED'; END IF;
     PERFORM public.validate_procurement_inspection(rl.product_id,rl.inspection,accepted);
   END LOOP;
 END IF;
 PERFORM set_config('app.procurement_write','true',true);
 result:=public.verify_inventory_receipt_p1(p_receipt_id,p_expected_version,p_idempotency_key,p_lines,p_verification_reason);
 IF po.workflow_version=2 THEN
   INSERT INTO public.inventory_receipt_issues(restaurant_id,receipt_line_id,purchase_order_id,issue_type,ordered_quantity_base,received_quantity_base,accepted_quantity_base,reason)
   SELECT po.restaurant_id,l.id,po.id,CASE WHEN l.inspection->>'issue_type'<>'none' THEN l.inspection->>'issue_type'
     WHEN l.received_quantity_base>ol.ordered_quantity_base THEN 'excess' ELSE 'shortage' END,
     ol.ordered_quantity_base,l.received_quantity_base,l.accepted_quantity_base,l.discrepancy_reason
   FROM public.inventory_receipt_lines l JOIN public.inventory_purchase_order_lines ol ON ol.id=l.purchase_order_line_id
   WHERE l.receipt_id=p_receipt_id AND (l.received_quantity_base<>ol.ordered_quantity_base OR l.rejected_quantity_base>0 OR COALESCE(l.inspection->>'issue_type','none')<>'none')
   ON CONFLICT(receipt_line_id) DO NOTHING;
 END IF;
 PERFORM set_config('app.procurement_write',COALESCE(saved_write,''),true);
 RETURN result;
END $$;
COMMIT;
