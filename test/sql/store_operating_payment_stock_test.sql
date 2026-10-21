-- Complete production functions/triggers, no payment or inventory stubs.
BEGIN;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
DO $$ DECLARE shop uuid:='8bc9eef5-dcd5-46b1-b931-23f77132322c';
 menu uuid; stock uuid; second_stock uuid; oid uuid; iid uuid; p public.payments;
BEGIN
 PERFORM public.approve_invoice_mapping_policy(shop,'91000000-0000-4000-8000-000000000004',
  'payment-stock-fixture','{"category_units":{},"menu_units":{},"combo_unit":"Phần"}','Isolated stock regression');
 UPDATE brands SET service_charge_enabled=false WHERE id='91000000-0000-4000-8000-000000000003';
 UPDATE restaurants SET vat_pricing_mode='exclusive' WHERE id=shop;
 INSERT INTO menu_items(restaurant_id,name,name_vi,price,invoice_sale_unit)
 VALUES(shop,'Stock fixture','Món thử kho',10000,'Phần') RETURNING id INTO menu;
 INSERT INTO inventory_items(restaurant_id,name,unit,current_stock) VALUES(shop,'Fixture ingredient 1','g',10000) RETURNING id INTO stock;
 INSERT INTO inventory_items(restaurant_id,name,unit,current_stock) VALUES(shop,'Fixture ingredient 2','g',10000) RETURNING id INTO second_stock;
 INSERT INTO menu_recipes(restaurant_id,menu_item_id,ingredient_id,quantity_g) VALUES(shop,menu,stock,10),(shop,menu,second_stock,2);
 INSERT INTO orders(restaurant_id,status) VALUES(shop,'serving') RETURNING id INTO oid;
 -- 500 active lines, one previously cooked cancelled unit on each line.
 -- An additional fully cancelled line retains two consumed units.
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,item_type,label,display_name,unit_price,quantity,status,cancelled_consumed_quantity)
 SELECT shop,oid,menu,'menu_item','Stock fixture','Stock fixture',10000,3,'served',1 FROM generate_series(1,500);
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,item_type,label,display_name,unit_price,quantity,status,cancelled_consumed_quantity)
 VALUES(shop,oid,menu,'menu_item','Cancelled fixture','Cancelled fixture',10000,2,'cancelled',2) RETURNING id INTO iid;
 p:=public.process_payment(oid,shop,8000000,'CASH');
 ASSERT (SELECT status<>'completed' FROM orders WHERE id=oid), 'partial payment prematurely completed';
 ASSERT (SELECT current_stock=10000 FROM inventory_items WHERE id=stock), 'partial payment consumed stock';
 ASSERT NOT EXISTS(SELECT 1 FROM inventory_transactions WHERE reference_id IN(SELECT id FROM order_items WHERE order_id=oid));
 p:=public.process_payment(oid,shop,8200000,'BANKTRANSFER');
 ASSERT (SELECT status='completed' FROM orders WHERE id=oid), 'payment did not complete';
 ASSERT (SELECT current_stock=10000-2002*10 FROM inventory_items WHERE id=stock), 'cooked cancellation stock mismatch';
 ASSERT (SELECT current_stock=10000-2002*2 FROM inventory_items WHERE id=second_stock), 'second ingredient mismatch';
 ASSERT (SELECT count(*)=1002 AND sum(quantity_g)=-2002*12 FROM inventory_transactions
  WHERE reference_id IN(SELECT id FROM order_items WHERE order_id=oid)), 'stock journal mismatch';
 ASSERT (SELECT sum(quantity_g)=-24 FROM inventory_transactions WHERE reference_id=iid), 'cancelled consumed quantity lost';
 BEGIN PERFORM public.process_payment(oid,shop,8200000,'BANKTRANSFER');
  RAISE EXCEPTION 'duplicate payment accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'ORDER_NOT_PAYABLE' THEN RAISE; END IF; END;
 ASSERT (SELECT count(*)=2 AND sum(amount)=16200000 FROM payments WHERE order_id=oid), 'payment duplicate';
 ASSERT (SELECT count(*)=1 FROM meinvoice_jobs WHERE order_id=oid), 'asynchronous invoice job lost';
 RAISE NOTICE 'PAYMENT_STOCK_500_LINES=PASS partial payment, consumed cancellations, 1002 ledger rows, retry, invoice job';
END $$;
ROLLBACK;
