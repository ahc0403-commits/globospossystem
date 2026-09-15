BEGIN;
INSERT INTO restaurants(id,name,brand_id) VALUES ('b1000000-0000-4000-8000-000000000005','Bunsik','b1000000-0000-4000-8000-000000000004');
INSERT INTO users(id,auth_id,brand_id,role,full_name) VALUES ('b1000000-0000-4000-8000-0000000000b1','b1000000-0000-4000-8000-0000000000a1','b1000000-0000-4000-8000-000000000004','brand_admin','BM');
SELECT set_config('request.jwt.claim.sub','b1000000-0000-4000-8000-0000000000a1',true);
INSERT INTO menu_items(id,restaurant_id,name,name_ko,name_en,name_vi,price) VALUES
('b1000000-0000-4000-8000-000000000012','b1000000-0000-4000-8000-000000000005','밥','밥','Steamed Rice','Cơm Trắng',10000),
('b1000000-0000-4000-8000-000000000013','b1000000-0000-4000-8000-000000000005','생수','생수','Dasani Water','Nước Suối',5000);
INSERT INTO menu_categories(id,restaurant_id,name,name_ko,name_en,name_vi) VALUES
('b1000000-0000-4000-8000-000000000031','b1000000-0000-4000-8000-000000000005','식사','식사','Meals','Bữa ăn');
UPDATE menu_items
SET category_id = 'b1000000-0000-4000-8000-000000000031'
WHERE id = 'b1000000-0000-4000-8000-000000000012';
INSERT INTO orders(id,restaurant_id,status,order_purpose,created_at) VALUES
('b1000000-0000-4000-8000-000000000010','b1000000-0000-4000-8000-000000000005','completed','staff_meal','2026-09-15 14:00:00Z');
INSERT INTO order_items(id,restaurant_id,order_id,menu_item_id,menu_item_id_snapshot,label,display_name,quantity,unit_price,status,paying_amount_inc_tax,created_at) VALUES
('b1000000-0000-4000-8000-000000000011','b1000000-0000-4000-8000-000000000005','b1000000-0000-4000-8000-000000000010','b1000000-0000-4000-8000-000000000012','b1000000-0000-4000-8000-000000000012','밥','밥',2,10000,'served',20000,'2026-09-15 14:00:00Z'),
('b1000000-0000-4000-8000-000000000014','b1000000-0000-4000-8000-000000000005','b1000000-0000-4000-8000-000000000010','b1000000-0000-4000-8000-000000000013',NULL,'생수','생수',1,5000,'served',5000,'2026-09-15 14:01:00Z');
INSERT INTO audit_logs(id,actor_id,action,entity_id,details,created_at) VALUES
('b1000000-0000-4000-8000-000000000020',auth.uid(),'mark_order_item_service','b1000000-0000-4000-8000-000000000011','{"label":"밥","quantity":2,"unit_price":10000}','2026-09-15 14:02:00Z');
INSERT INTO order_cancellation_ledger(id,restaurant_id,order_id,cancellation_scope,item_snapshot,created_by,created_at) VALUES
('b1000000-0000-4000-8000-000000000021','b1000000-0000-4000-8000-000000000005','b1000000-0000-4000-8000-000000000010','item','[{"order_item_id":"b1000000-0000-4000-8000-000000000011","label":"밥","quantity":2,"unit_price":10000}]',auth.uid(),'2026-09-15 14:03:00Z');
INSERT INTO order_cancellation_reversals(id,cancellation_ledger_id,restored_by,restored_at) VALUES
('b1000000-0000-4000-8000-000000000022','b1000000-0000-4000-8000-000000000021',auth.uid(),'2026-09-15 14:04:00Z');
INSERT INTO payments(id,order_id,restaurant_id,amount,method,created_at) VALUES
('b1000000-0000-4000-8000-000000000023','b1000000-0000-4000-8000-000000000010','b1000000-0000-4000-8000-000000000005',25000,'CASH','2026-09-15 14:05:00Z');
DO $$
DECLARE r jsonb; line jsonb; kind text;
BEGIN
  FOREACH kind IN ARRAY ARRAY['service','cancellation','staff_meal'] LOOP
    r := get_bm_menu_exception_history('b1000000-0000-4000-8000-000000000005','2026-09-15','2026-09-16',kind,true,'Steamed Rice');
    IF jsonb_array_length(r->'items') < 1 THEN RAISE EXCEPTION 'English search lost %',kind; END IF;
    FOR line IN SELECT value FROM jsonb_array_elements(r->'items') LOOP
      IF line #>> '{item_names,0,name_en}' IS DISTINCT FROM 'Steamed Rice' OR line #>> '{item_names,0,name_vi}' IS DISTINCT FROM 'Cơm Trắng' OR line #>> '{item_names,0,name_ko}' IS DISTINCT FROM '밥' THEN
        RAISE EXCEPTION 'History translations lost: %',line;
      END IF;
      IF kind='staff_meal' AND (jsonb_array_length(line->'item_names') IS DISTINCT FROM 2 OR line->>'item_name' IS DISTINCT FROM '밥, 생수' OR (line->>'quantity')::numeric IS DISTINCT FROM 3 OR (line->>'reference_amount')::numeric IS DISTINCT FROM 25000) THEN
        RAISE EXCEPTION 'Grouping, original names or amounts changed: %',line;
      END IF;
    END LOOP;
  END LOOP;
  r := get_bm_order_history_detail('b1000000-0000-4000-8000-000000000010');
  IF r #>> '{items,0,name_en}' IS DISTINCT FROM 'Steamed Rice' OR r #>> '{items,1,name_vi}' IS DISTINCT FROM 'Nước Suối' THEN RAISE EXCEPTION 'Order detail translation lost'; END IF;
  r := get_store_menu_sales_analytics('b1000000-0000-4000-8000-000000000005','2026-09-15','2026-09-16','all');
  IF r #>> '{menu_rows,0,name_en}' IS DISTINCT FROM 'Steamed Rice' OR r #>> '{top_menu_hour_rows,0,name_vi}' IS DISTINCT FROM 'Cơm Trắng' OR (r #>> '{summary,menu_sales_amount}')::numeric IS DISTINCT FROM 25000 THEN RAISE EXCEPTION 'Analytics localization changed totals: %',r; END IF;
  r := get_receipt_ledger('2026-09-15','b1000000-0000-4000-8000-000000000005');
  IF r #>> '{receipts,0,items,0,name_en}' IS DISTINCT FROM 'Steamed Rice' OR (r #>> '{summary,net_amount}')::numeric IS DISTINCT FROM 25000 THEN RAISE EXCEPTION 'Receipt localization lost: %',r; END IF;
  -- A combined tender keeps its table prefix in each translated name.
  INSERT INTO combined_payment_groups(id,completed_at) VALUES ('b1000000-0000-4000-8000-000000000025','2026-09-15 14:05:00Z');
  UPDATE payments SET combined_payment_group_id='b1000000-0000-4000-8000-000000000025';
  r := get_receipt_ledger('2026-09-15','b1000000-0000-4000-8000-000000000005');
  IF r #>> '{receipts,0,items,0,name_en}' IS DISTINCT FROM '[TAKEAWAY] Steamed Rice' OR (r #>> '{summary,net_amount}')::numeric IS DISTINCT FROM 25000 THEN RAISE EXCEPTION 'Combined receipt changed: %',r; END IF;
  r := get_paperless_operations_report('b1000000-0000-4000-8000-000000000005','2026-09-15','2026-09-16');
  IF r #>> '{menu_operation_times,0,name_ko}' IS DISTINCT FROM '밥'
     OR r #>> '{menu_operation_times,0,name_en}' IS DISTINCT FROM 'Steamed Rice'
     OR r #>> '{menu_operation_times,0,name_vi}' IS DISTINCT FROM 'Cơm Trắng' THEN
    RAISE EXCEPTION 'Paperless menu translations lost: %', r;
  END IF;
  r := get_paperless_operations_insights_report('b1000000-0000-4000-8000-000000000005','2026-09-15','2026-09-16');
  IF r #>> '{menu_operation_times,0,category_name_en}' IS DISTINCT FROM 'Meals'
     OR r #>> '{menu_operation_times,0,category_name_vi}' IS DISTINCT FROM 'Bữa ăn'
     OR r #>> '{category_operation_times,0,name_en}' IS DISTINCT FROM 'Meals' THEN
    RAISE EXCEPTION 'Paperless category translations lost: %', r;
  END IF;
  UPDATE menu_items
  SET name_en = NULL
  WHERE id = 'b1000000-0000-4000-8000-000000000012';
  r := get_paperless_operations_report('b1000000-0000-4000-8000-000000000005','2026-09-15','2026-09-16');
  IF r #>> '{menu_operation_times,0,name_en}' IS NOT NULL
     OR r #>> '{menu_operation_times,0,name}' IS DISTINCT FROM '밥' THEN
    RAISE EXCEPTION 'Paperless missing English was silently replaced: %', r;
  END IF;
  UPDATE menu_items
  SET name_en = 'Steamed Rice'
  WHERE id = 'b1000000-0000-4000-8000-000000000012';
  -- Archived/deleted catalog entries must not erase historical rows or labels.
  DELETE FROM menu_items;
  r := get_bm_order_history_detail('b1000000-0000-4000-8000-000000000010');
  IF r #>> '{items,0,name}' IS DISTINCT FROM '밥' OR jsonb_array_length(r->'items') IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'Historical names erased'; END IF;
END $$;
ROLLBACK;
