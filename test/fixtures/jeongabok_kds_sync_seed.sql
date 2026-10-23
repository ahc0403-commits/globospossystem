\set ON_ERROR_STOP on
-- Synthetic rows only. Run exclusively in the disposable fixture database.
SET session_replication_role=replica;
CREATE SCHEMA IF NOT EXISTS kds_test;
CREATE OR REPLACE FUNCTION kds_test.id(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
 SELECT ('ba000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
$$;
INSERT INTO restaurants(id,name,brand_id,tax_entity_id) VALUES
 ('273b057e-3b69-46e3-93c1-6194c2802849','JeonGabok fixture',kds_test.id(900001),kds_test.id(900002)),
 ('8bc9eef5-dcd5-46b1-b931-23f77132322c','Other fixture',kds_test.id(900001),kds_test.id(900002));
INSERT INTO users(id,auth_id,restaurant_id,role,is_active)
SELECT kds_test.id(900010+n),kds_test.id(900020+n),
 CASE WHEN n=4 THEN '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid
 ELSE '273b057e-3b69-46e3-93c1-6194c2802849'::uuid END,
 CASE WHEN n=1 THEN 'kitchen' ELSE 'emergency_station' END,true FROM generate_series(1,5)n;
INSERT INTO emergency_station_assignments(user_id,restaurant_id,station_type,floor_label,service_area_codes,is_active)
SELECT id,restaurant_id,CASE n WHEN 1 THEN 'kitchen' ELSE 'floor' END,
 CASE WHEN n=2 THEN '2F' WHEN n IN (3,4,5) THEN '3F' END,'{}',true
FROM generate_series(1,5)n JOIN users u ON u.id=kds_test.id(900010+n);
INSERT INTO emergency_fulfillment_sessions(id,restaurant_id,reason,status)
VALUES(kds_test.id(900030),'273b057e-3b69-46e3-93c1-6194c2802849','Synthetic bounded history','active');
INSERT INTO restaurant_settings(restaurant_id,fulfillment_mode,kds_workflow)
VALUES('273b057e-3b69-46e3-93c1-6194c2802849','paperless','kitchen_floor');
INSERT INTO menu_items(id,restaurant_id,name,name_ko,name_vi,name_en,price,paperless_name_vi)
VALUES(kds_test.id(900040),'273b057e-3b69-46e3-93c1-6194c2802849','Fixture','메뉴','Món','Meal',1,'Món');
INSERT INTO kds_realtime_rollouts(restaurant_id,mode) VALUES('273b057e-3b69-46e3-93c1-6194c2802849','active');
INSERT INTO kds_store_revisions(restaurant_id,current_revision) VALUES('273b057e-3b69-46e3-93c1-6194c2802849',120);
INSERT INTO orders(id,restaurant_id,status,created_at)
SELECT kds_test.id(n),'273b057e-3b69-46e3-93c1-6194c2802849','serving',
 CASE WHEN n<=:historical THEN now()-interval '10 days' ELSE date_trunc('day',now() AT TIME ZONE 'Asia/Ho_Chi_Minh') AT TIME ZONE 'Asia/Ho_Chi_Minh' END
FROM generate_series(1,:historical+:today)n;
INSERT INTO emergency_order_queue(id,session_id,restaurant_id,order_id,queue_no,table_number,floor_label,created_at,workflow_version,kitchen_direct_to_floor)
SELECT kds_test.id(200000+n),kds_test.id(900030),'273b057e-3b69-46e3-93c1-6194c2802849',kds_test.id(n),
 n,'T'||n,CASE WHEN n%2=0 THEN '2F' ELSE '3F' END,o.created_at,2,true
FROM generate_series(1,:historical+:today)n JOIN orders o ON o.id=kds_test.id(n);
INSERT INTO order_items(id,restaurant_id,order_id,menu_item_id,display_name,unit_price,quantity,created_at)
SELECT kds_test.id(10000000+n*32+line),'273b057e-3b69-46e3-93c1-6194c2802849',kds_test.id(n),kds_test.id(900040),'Fixture line',1,1,o.created_at
FROM generate_series(1,:historical+:today)n CROSS JOIN generate_series(1,22)line
JOIN orders o ON o.id=kds_test.id(n)
WHERE line<=(ARRAY[0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,2,2,2,2,2,2,2,2,2,2,2,2,3,3,3,3,3,3,3,3,3,3,3,3,4,4,4,4,4,4,4,4,4,4,5,5,5,6,6,6,6,6,6,6,6,6,6,6,7,7,7,7,8,8,8,8,8,8,9,9,9,22])[((n-1)%80)+1];
INSERT INTO emergency_fulfillment_items(id,session_id,restaurant_id,queue_id,order_id,order_item_id,
 source_quantity,ordered_quantity,kitchen_started_quantity,kitchen_done_quantity,tray_received_quantity,tray_dispatched_quantity,floor_served_quantity,created_at)
SELECT kds_test.id(20000000+n*32+line),kds_test.id(900030),'273b057e-3b69-46e3-93c1-6194c2802849',kds_test.id(200000+n),kds_test.id(n),kds_test.id(10000000+n*32+line),
 1,1,1,1,1,1,1,o.created_at
FROM generate_series(1,:historical+:today)n CROSS JOIN generate_series(1,22)line
JOIN orders o ON o.id=kds_test.id(n)
WHERE line<=(ARRAY[0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,2,2,2,2,2,2,2,2,2,2,2,2,3,3,3,3,3,3,3,3,3,3,3,3,4,4,4,4,4,4,4,4,4,4,5,5,5,6,6,6,6,6,6,6,6,6,6,6,7,7,7,7,8,8,8,8,8,8,9,9,9,22])[((n-1)%80)+1];
INSERT INTO emergency_fulfillment_events(event_id,session_id,restaurant_id,order_id,order_item_id,stage,delta,created_at)
SELECT kds_test.id(40000000+n*96+line*3+s),kds_test.id(900030),'273b057e-3b69-46e3-93c1-6194c2802849',kds_test.id(n),kds_test.id(10000000+n*32+line),
 CASE s WHEN 0 THEN 'kitchen_done' WHEN 1 THEN 'tray_dispatched' ELSE 'floor_served' END,1,
 o.created_at+(n%1000)*interval '1 millisecond'
FROM generate_series(1,:historical+:today)n CROSS JOIN generate_series(1,22)line CROSS JOIN generate_series(0,2)s
JOIN orders o ON o.id=kds_test.id(n)
WHERE line<=(ARRAY[0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,2,2,2,2,2,2,2,2,2,2,2,2,3,3,3,3,3,3,3,3,3,3,3,3,4,4,4,4,4,4,4,4,4,4,5,5,5,6,6,6,6,6,6,6,6,6,6,6,7,7,7,7,8,8,8,8,8,8,9,9,9,22])[((n-1)%80)+1];
SET session_replication_role=origin;
ANALYZE;
