BEGIN;
-- Temporarily grant direct DML to prove the trigger still blocks an outdated
-- or privileged client; the transaction rolls these grants back.
GRANT UPDATE, DELETE ON public.inventory_receipts, public.inventory_receipt_lines TO authenticated;
CREATE POLICY receipt_guard_test_header_write ON public.inventory_receipts
  FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY receipt_guard_test_line_write ON public.inventory_receipt_lines
  FOR ALL TO authenticated USING (true) WITH CHECK (true);
SET ROLE authenticated;
DO $receipt_lock$
DECLARE
  po public.inventory_purchase_orders%ROWTYPE;
  detail jsonb;
  submitted jsonb;
  payload jsonb;
  v_receipt_id uuid := test_uuid(8797);
  line_id uuid;
  evidence_path text := test_uuid(101) || '/' || test_uuid(8797) || '/receipt.pdf';
  stock_before numeric;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', test_uuid(1)::text, true);
  po := public.create_manual_inventory_purchase_order(
    test_uuid(101), test_uuid(201),
    jsonb_build_array(jsonb_build_object('supplier_item_id', test_uuid(401), 'ordered_quantity_unit', 1)),
    current_date, NULL);
  po := public.submit_inventory_purchase_order(po.id, po.row_version);
  PERFORM set_config('request.jwt.claim.sub', test_uuid(2)::text, true);
  po := public.store_decide_inventory_purchase_order(po.id, po.row_version, true, NULL);
  PERFORM set_config('request.jwt.claim.sub', test_uuid(3)::text, true);
  po := public.brand_decide_inventory_purchase_order(po.id, po.row_version, true, NULL);
  PERFORM set_config('request.jwt.claim.sub', test_uuid(1)::text, true);
  detail := public.get_inventory_workflow_detail(po.id);
  payload := jsonb_build_array(jsonb_build_object(
    'purchase_order_line_id', detail->'lines'->0->>'id',
    'received_quantity_base', 10));
  INSERT INTO storage.objects(bucket_id, name, metadata, owner_id)
  VALUES ('inventory-receipt-statements', evidence_path,
    '{"mimetype":"application/pdf","size":120}', test_uuid(1)::text);
  submitted := public.submit_inventory_receipt_batch(
    po.id, v_receipt_id, po.row_version, 0, 'lock-test-submit', payload,
    'Inspector', evidence_path);
  ASSERT public.submit_inventory_receipt_batch(
    po.id, v_receipt_id, po.row_version, 0, 'lock-test-submit', payload,
    'Inspector', evidence_path) = submitted,
    'An identical retry must replay without modifying the submitted receipt';
  SELECT id INTO line_id FROM public.inventory_receipt_lines WHERE receipt_id = v_receipt_id LIMIT 1;
  ASSERT (SELECT submitted_at FROM public.inventory_receipts WHERE id = v_receipt_id) IS NOT NULL;
  PERFORM public.test_expect_error(format(
    'UPDATE public.inventory_receipt_lines SET received_quantity_base=9 WHERE id=%L',
    line_id), 'INVENTORY_RECEIPT_SUBMITTED_LOCKED');
  PERFORM public.test_expect_error(format(
    'UPDATE public.inventory_receipts SET inspector_name=%L WHERE id=%L',
    'Changed without review', v_receipt_id), 'INVENTORY_RECEIPT_SUBMITTED_LOCKED');
  PERFORM public.test_expect_error(format(
    'DELETE FROM public.inventory_receipt_lines WHERE id=%L', line_id),
    'INVENTORY_RECEIPT_SUBMITTED_LOCKED');
  SELECT current_stock INTO stock_before FROM public.inventory_items WHERE id = test_uuid(501);
  PERFORM set_config('request.jwt.claim.sub', test_uuid(4)::text, true);
  po := public.verify_inventory_receipt(v_receipt_id,
    (submitted->>'row_version')::integer, 'lock-test-verify');
  ASSERT po.status = 'received';
  ASSERT (SELECT current_stock FROM public.inventory_items WHERE id = test_uuid(501)) = stock_before + 10;
  po := public.verify_inventory_receipt(v_receipt_id,
    (submitted->>'row_version')::integer, 'lock-test-verify');
  ASSERT po.status = 'received';
  ASSERT (SELECT current_stock FROM public.inventory_items WHERE id = test_uuid(501)) = stock_before + 10,
    'Verification replay must not post stock twice';
  ASSERT EXISTS (SELECT 1 FROM public.inventory_receipt_change_history
    WHERE inventory_receipt_change_history.receipt_id = v_receipt_id
      AND previous_state->>'status' = 'draft'
      AND next_state->>'status' = 'confirmed');
  PERFORM public.test_expect_error(format(
    'UPDATE public.inventory_receipt_lines SET received_quantity_base=9 WHERE id=%L',
    line_id), 'INVENTORY_RECEIPT_CONFIRMED_IMMUTABLE');
  RAISE NOTICE 'PASS: submitted maker locked, accountant verification and audit, confirmed immutable';
END $receipt_lock$;
ROLLBACK;
