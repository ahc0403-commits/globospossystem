-- Held goods retain the original inspected price; external evidence cannot
-- reconcile an unknown historical conversion as a zero credit.
-- production-gate: self-verifying
BEGIN;
DO $$ DECLARE d text; BEGIN
 d:=pg_get_functiondef('public.submit_inventory_receipt_batch(uuid,uuid,integer,integer,text,jsonb,text,text,text,date,text)'::regprocedure);
 IF position('COALESCE((x->>''actual_unit_price'')::numeric,ol.unit_price)' IN d)=0 THEN RAISE EXCEPTION 'HELD_PRICE_PATCH_MISMATCH'; END IF;
 d:=replace(d,'COALESCE((x->>''actual_unit_price'')::numeric,ol.unit_price)','COALESCE(parent_receipt.actual_unit_price,(x->>''actual_unit_price'')::numeric,ol.unit_price)');
 d:=replace(d,'LEFT JOIN accepted a ON a.purchase_order_line_id=ol.id', 'LEFT JOIN accepted a ON a.purchase_order_line_id=ol.id LEFT JOIN inventory_lot_receipt_origins origin ON origin.receipt_id=p_receipt_id LEFT JOIN inventory_lots parent_lot ON parent_lot.id=origin.parent_lot_id LEFT JOIN inventory_receipt_lines parent_receipt ON parent_receipt.id=parent_lot.receipt_line_id AND parent_receipt.purchase_order_line_id=ol.id'); EXECUTE d;
 d:=pg_get_functiondef('public.get_procurement_reconciliation_source_v1(uuid,uuid[])'::regprocedure);
 d:=replace(d,'/ol.order_unit_quantity_base_snapshot','/nullif(ol.order_unit_quantity_base_snapshot,0)');
 d:=replace(d,'t.purchase_order_id,sum(', 't.purchase_order_id,bool_and(coalesce(ol.order_unit_quantity_base_snapshot>0 AND ol.tax_rate_snapshot IS NOT NULL AND rl.actual_unit_price IS NOT NULL,false)) terms_complete,sum(');
 d:=replace(d,'''expected_credit'',coalesce(c.amount,0)', '''terms_complete'',coalesce(c.terms_complete,true),''expected_credit'',coalesce(c.amount,0)'); EXECUTE d;
 d:=pg_get_functiondef('public.admin_record_procurement_reconciliation_v1(uuid,uuid,uuid,text,jsonb)'::regprocedure);
 d:=replace(d,'matched:=(p_payload', 'matched:=coalesce((source->>''terms_complete'')::boolean,false) AND (p_payload'); EXECUTE d;
 d:=pg_get_functiondef('public.store_closure_pending_v1(uuid)'::regprocedure);
 d:=replace(d,'''orders'',', '''kds_handoffs'',(SELECT count(*) FROM (SELECT order_id FROM emergency_fulfillment_items WHERE restaurant_id=p_store AND NOT is_cancelled AND floor_served_quantity+excused_quantity<ordered_quantity UNION ALL SELECT order_id FROM emergency_combo_component_items WHERE restaurant_id=p_store AND NOT is_cancelled AND floor_served_quantity+excused_quantity<ordered_quantity UNION ALL SELECT order_id FROM emergency_floor_direct_items WHERE restaurant_id=p_store AND NOT is_cancelled AND floor_served_quantity+excused_quantity<ordered_quantity)i WHERE NOT EXISTS(SELECT 1 FROM direct_order_financials f JOIN direct_delivery_fulfillment_tickets t ON t.request_id=f.request_id WHERE f.order_id=i.order_id AND t.status IN(''completed'',''cancelled''))),''orders'','); EXECUTE d;
END $$;
COMMIT;
