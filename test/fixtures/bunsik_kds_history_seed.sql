\set ON_ERROR_STOP on
-- Synthetic rows only. Run exclusively in the disposable fixture database.
SET session_replication_role=replica;
CREATE SCHEMA IF NOT EXISTS kds_test;
CREATE OR REPLACE FUNCTION kds_test.id(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
 SELECT ('ba000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
$$;
INSERT INTO restaurants(id,name,brand_id,tax_entity_id) VALUES
 ('8bc9eef5-dcd5-46b1-b931-23f77132322c','Bunsik fixture',kds_test.id(900001),kds_test.id(900002)),
 ('273b057e-3b69-46e3-93c1-6194c2802849','Other fixture',kds_test.id(900001),kds_test.id(900002));
INSERT INTO users(id,auth_id,restaurant_id,role,is_active)
SELECT kds_test.id(900010+n),kds_test.id(900020+n),
 CASE WHEN n=4 THEN '273b057e-3b69-46e3-93c1-6194c2802849'::uuid
 ELSE '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid END,
 CASE WHEN n=1 THEN 'kitchen' ELSE 'emergency_station' END,true FROM generate_series(1,5)n;
INSERT INTO emergency_station_assignments(user_id,restaurant_id,station_type,floor_label,service_area_codes,is_active)
SELECT id,restaurant_id,CASE n WHEN 1 THEN 'kitchen' WHEN 2 THEN 'tray' ELSE 'floor' END,
 CASE WHEN n=3 THEN '1F' WHEN n IN (4,5) THEN '2F' END,'{}',true
FROM generate_series(1,5)n JOIN users u ON u.id=kds_test.id(900010+n);
INSERT INTO emergency_fulfillment_sessions(id,restaurant_id,reason,status)
VALUES(kds_test.id(900030),'8bc9eef5-dcd5-46b1-b931-23f77132322c','Synthetic bounded history','active');
INSERT INTO restaurant_settings(restaurant_id,fulfillment_mode,kds_workflow)
VALUES('8bc9eef5-dcd5-46b1-b931-23f77132322c','paperless','kitchen_tray_floor');
INSERT INTO menu_items(id,restaurant_id,name,name_ko,name_vi,name_en,price,paperless_name_vi)
VALUES(kds_test.id(900040),'8bc9eef5-dcd5-46b1-b931-23f77132322c','Fixture','메뉴','Món','Meal',1,'Món');
-- Scale is supplied as psql variables: historical queues and today's queues.
INSERT INTO orders(id,restaurant_id,status,created_at)
SELECT kds_test.id(n),'8bc9eef5-dcd5-46b1-b931-23f77132322c','serving',
 CASE WHEN n<=:historical THEN now()-interval '10 days' ELSE date_trunc('day',now()) END
FROM generate_series(1,:historical+:today)n;
INSERT INTO order_items(id,restaurant_id,order_id,menu_item_id,display_name,unit_price,quantity,created_at)
SELECT kds_test.id(100000+n),'8bc9eef5-dcd5-46b1-b931-23f77132322c',kds_test.id(n),kds_test.id(900040),'Fixture',1,1,o.created_at
FROM generate_series(1,:historical+:today)n JOIN orders o ON o.id=kds_test.id(n);
INSERT INTO emergency_order_queue(id,session_id,restaurant_id,order_id,queue_no,table_number,floor_label,created_at,workflow_version)
SELECT kds_test.id(200000+n),kds_test.id(900030),'8bc9eef5-dcd5-46b1-b931-23f77132322c',kds_test.id(n),
 n,'T'||n,CASE WHEN n%2=0 THEN '1F' ELSE '2F' END,o.created_at,2
FROM generate_series(1,:historical+:today)n JOIN orders o ON o.id=kds_test.id(n);
INSERT INTO emergency_fulfillment_items(id,session_id,restaurant_id,queue_id,order_id,order_item_id,
 source_quantity,ordered_quantity,kitchen_started_quantity,kitchen_done_quantity,tray_received_quantity,tray_dispatched_quantity,floor_served_quantity,created_at)
SELECT kds_test.id(300000+n),kds_test.id(900030),'8bc9eef5-dcd5-46b1-b931-23f77132322c',kds_test.id(200000+n),kds_test.id(n),kds_test.id(100000+n),
 1,1,1,1,1,1,1,o.created_at
FROM generate_series(1,:historical+:today)n JOIN orders o ON o.id=kds_test.id(n);
INSERT INTO emergency_fulfillment_events(event_id,session_id,restaurant_id,order_id,order_item_id,stage,delta,created_at)
SELECT kds_test.id(400000+n*3+s),kds_test.id(900030),'8bc9eef5-dcd5-46b1-b931-23f77132322c',kds_test.id(n),kds_test.id(100000+n),
 CASE s WHEN 0 THEN 'kitchen_done' WHEN 1 THEN 'tray_dispatched' ELSE 'floor_served' END,1,
 o.created_at+(n%1000)*interval '1 millisecond'
FROM generate_series(1,:historical+:today)n CROSS JOIN generate_series(0,2)s JOIN orders o ON o.id=kds_test.id(n);

-- Match the observed Bunsik seven-day line distribution: mean 4.45,
-- approximately p95 9, maximum 15. Names/prices remain synthetic.
INSERT INTO order_items(id,restaurant_id,order_id,menu_item_id,display_name,unit_price,quantity,created_at)
SELECT kds_test.id(10000000+n*20+line),'8bc9eef5-dcd5-46b1-b931-23f77132322c',kds_test.id(n),kds_test.id(900040),'Fixture line',1,1,o.created_at
FROM generate_series(1,:historical+:today)n CROSS JOIN generate_series(2,15)line
JOIN orders o ON o.id=kds_test.id(n)
WHERE line<=(ARRAY[1,1,2,2,2,2,3,3,4,4,4,4,4,4,5,5,6,9,9,15])[((n-1)%20)+1];
INSERT INTO emergency_fulfillment_items(id,session_id,restaurant_id,queue_id,order_id,order_item_id,
 source_quantity,ordered_quantity,kitchen_started_quantity,kitchen_done_quantity,tray_received_quantity,tray_dispatched_quantity,floor_served_quantity,created_at)
SELECT kds_test.id(20000000+n*20+line),kds_test.id(900030),'8bc9eef5-dcd5-46b1-b931-23f77132322c',kds_test.id(200000+n),kds_test.id(n),kds_test.id(10000000+n*20+line),
 1,1,1,1,1,1,1,o.created_at
FROM generate_series(1,:historical+:today)n CROSS JOIN generate_series(2,15)line
JOIN orders o ON o.id=kds_test.id(n)
WHERE line<=(ARRAY[1,1,2,2,2,2,3,3,4,4,4,4,4,4,5,5,6,9,9,15])[((n-1)%20)+1];
INSERT INTO emergency_fulfillment_events(event_id,session_id,restaurant_id,order_id,order_item_id,stage,delta,created_at)
SELECT kds_test.id(40000000+n*60+line*3+s),kds_test.id(900030),'8bc9eef5-dcd5-46b1-b931-23f77132322c',kds_test.id(n),kds_test.id(10000000+n*20+line),
 CASE s WHEN 0 THEN 'kitchen_done' WHEN 1 THEN 'tray_dispatched' ELSE 'floor_served' END,1,
 o.created_at+(n%1000)*interval '1 millisecond'
FROM generate_series(1,:historical+:today)n CROSS JOIN generate_series(2,15)line CROSS JOIN generate_series(0,2)s
JOIN orders o ON o.id=kds_test.id(n)
WHERE line<=(ARRAY[1,1,2,2,2,2,3,3,4,4,4,4,4,4,5,5,6,9,9,15])[((n-1)%20)+1];

SET session_replication_role=origin;
ANALYZE public.users;
ANALYZE public.emergency_order_queue;
ANALYZE public.emergency_fulfillment_items;
ANALYZE public.emergency_fulfillment_events;
ANALYZE public.order_items;
