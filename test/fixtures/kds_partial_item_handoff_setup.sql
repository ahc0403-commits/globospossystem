\set ON_ERROR_STOP on
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
 SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid;
$$;
CREATE FUNCTION test_uuid(n int) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
 SELECT ('00000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
$$;
CREATE TABLE users(id uuid PRIMARY KEY,auth_id uuid,restaurant_id uuid,is_active boolean DEFAULT true);
CREATE TABLE emergency_station_assignments(id uuid PRIMARY KEY,user_id uuid,restaurant_id uuid,
 station_type text,floor_label text,service_area_codes text[] DEFAULT '{}',is_active boolean DEFAULT true);
CREATE TABLE emergency_fulfillment_sessions(id uuid PRIMARY KEY,restaurant_id uuid,status text);
CREATE TABLE orders(id uuid PRIMARY KEY,sales_channel text);
CREATE TABLE emergency_order_queue(id uuid PRIMARY KEY,session_id uuid,restaurant_id uuid,order_id uuid,
 floor_label text,workflow_version int DEFAULT 2,kitchen_direct_to_floor boolean DEFAULT false,
 created_at timestamptz DEFAULT now(),queue_no int DEFAULT 1);
CREATE TABLE emergency_fulfillment_items(id uuid PRIMARY KEY,restaurant_id uuid,session_id uuid,
 queue_id uuid,order_id uuid,order_item_id uuid,ordered_quantity int DEFAULT 2,excused_quantity int DEFAULT 0,
 kitchen_started_quantity int DEFAULT 0,kitchen_done_quantity int DEFAULT 0,tray_received_quantity int DEFAULT 0,
 tray_dispatched_quantity int DEFAULT 0,floor_served_quantity int DEFAULT 0,
 is_cancelled boolean DEFAULT false,needs_review boolean DEFAULT false,updated_at timestamptz,
 CHECK(0<=floor_served_quantity AND floor_served_quantity<=tray_dispatched_quantity
 AND tray_dispatched_quantity<=tray_received_quantity AND tray_received_quantity<=kitchen_done_quantity
 AND kitchen_done_quantity<=kitchen_started_quantity AND kitchen_started_quantity+excused_quantity<=ordered_quantity));
CREATE INDEX ON emergency_fulfillment_items(queue_id);
CREATE TABLE emergency_combo_component_items(LIKE emergency_fulfillment_items INCLUDING ALL);
CREATE INDEX ON emergency_combo_component_items(session_id,order_item_id);
CREATE TABLE emergency_floor_direct_items(id uuid PRIMARY KEY,queue_id uuid,floor_served_quantity int DEFAULT 0);
CREATE TABLE emergency_fulfillment_actions(action_id uuid PRIMARY KEY,session_id uuid,restaurant_id uuid,
 queue_id uuid,order_id uuid,station_type text,floor_label text,action_kind text,stage text,
 original_action_id uuid,actor_user_id uuid,created_at timestamptz DEFAULT now());
CREATE TABLE emergency_fulfillment_events(event_id uuid PRIMARY KEY,session_id uuid,restaurant_id uuid,
 order_id uuid,order_item_id uuid,combo_component_item_id uuid,stage text,delta int,
 actor_user_id uuid,details jsonb,action_id uuid);
CREATE TABLE emergency_tray_ready_lots(id uuid DEFAULT gen_random_uuid() PRIMARY KEY,restaurant_id uuid,
 session_id uuid,queue_id uuid,order_id uuid,order_item_id uuid,source_kind text,source_id uuid,
 kitchen_event_id uuid,ready_sequence bigint,ready_quantity int,handed_quantity int DEFAULT 0,
 voided_quantity int DEFAULT 0,updated_at timestamptz,
 CHECK(handed_quantity+voided_quantity<=ready_quantity));
CREATE INDEX ON emergency_tray_ready_lots(source_kind,source_id,ready_sequence,id);
CREATE TABLE emergency_floor_ready_lots(id uuid DEFAULT gen_random_uuid() PRIMARY KEY,restaurant_id uuid,
 session_id uuid,queue_id uuid,order_id uuid,order_item_id uuid,source_kind text,source_id uuid,
 ready_action_id uuid,ready_sequence bigint,ready_quantity int,served_quantity int DEFAULT 0,
 voided_quantity int DEFAULT 0,updated_at timestamptz,
 CHECK(served_quantity+voided_quantity<=ready_quantity));
CREATE INDEX ON emergency_floor_ready_lots(source_kind,source_id,ready_sequence,id);
CREATE TABLE emergency_tray_ready_sequences(restaurant_id uuid PRIMARY KEY,current_sequence bigint,updated_at timestamptz);
CREATE TABLE emergency_floor_ready_sequences(LIKE emergency_tray_ready_sequences INCLUDING ALL);
CREATE TABLE emergency_station_push_log(event_id uuid,station_type text);
CREATE TABLE emergency_web_push_devices(id uuid,restaurant_id uuid,station_assignment_id uuid,token text,is_enabled boolean);
CREATE TABLE emergency_push_deliveries(event_id uuid,restaurant_id uuid,device_id uuid,push_token text,
 station_type text,floor_label text,order_id uuid,stage text,UNIQUE(event_id,device_id));
CREATE TABLE direct_order_financials(request_id uuid,restaurant_id uuid,order_id uuid);
CREATE TABLE direct_order_requests(id uuid,fulfillment_type text);
CREATE TABLE direct_delivery_fulfillment_tickets(id uuid,request_id uuid,status text,version int,
 accepted_at timestamptz,ready_at timestamptz,updated_at timestamptz);
CREATE FUNCTION kds_is_direct_floor_store(id uuid) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
 SELECT id='273b057e-3b69-46e3-93c1-6194c2802849'::uuid;
$$;
CREATE FUNCTION kds_uses_direct_floor_workflow(id uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT kds_is_direct_floor_store(id);
$$;
CREATE FUNCTION store_assignment_area_codes_v1(a emergency_station_assignments) RETURNS text[]
 LANGUAGE sql IMMUTABLE AS $$SELECT coalesce(nullif(a.service_area_codes,'{}'),ARRAY[a.floor_label])$$;
CREATE FUNCTION emergency_next_tray_ready_sequence(id uuid) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE n bigint; BEGIN
 INSERT INTO emergency_tray_ready_sequences AS s VALUES(id,1,now())
 ON CONFLICT(restaurant_id) DO UPDATE SET current_sequence=s.current_sequence+1
 RETURNING current_sequence INTO n; RETURN n; END$$;
CREATE FUNCTION emergency_next_floor_ready_sequence(id uuid) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE n bigint; BEGIN
 INSERT INTO emergency_floor_ready_sequences AS s VALUES(id,1,now())
 ON CONFLICT(restaurant_id) DO UPDATE SET current_sequence=s.current_sequence+1
 RETURNING current_sequence INTO n; RETURN n; END$$;
CREATE FUNCTION emergency_enqueue_push(event uuid,store uuid,ord uuid,station text,floor text,stage text)
 RETURNS void LANGUAGE sql AS $$INSERT INTO emergency_station_push_log VALUES(event,station)$$;
-- Fixture identity/configuration only; progress kernels below are extracted
-- from actual migrations by the runner, not reimplemented test doubles.
INSERT INTO users VALUES(test_uuid(1),test_uuid(101),test_uuid(1000),true),
 (test_uuid(2),test_uuid(102),'273b057e-3b69-46e3-93c1-6194c2802849',true),
 (test_uuid(3),test_uuid(103),test_uuid(2000),true);
INSERT INTO emergency_station_assignments(id,user_id,restaurant_id,station_type,floor_label,service_area_codes)
 SELECT id,id,restaurant_id,'floor','1F',ARRAY['1F','2F'] FROM users;
INSERT INTO emergency_fulfillment_sessions VALUES(test_uuid(100),test_uuid(1000),'active'),
 (test_uuid(200),'273b057e-3b69-46e3-93c1-6194c2802849','active');
CREATE FUNCTION test_line(n int,qty int,started int,done int,handed int,
 direct boolean DEFAULT false,floor text DEFAULT '1F') RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE store uuid:=CASE WHEN direct THEN '273b057e-3b69-46e3-93c1-6194c2802849'::uuid ELSE test_uuid(1000) END;
 sess uuid:=CASE WHEN direct THEN test_uuid(200) ELSE test_uuid(100) END;
BEGIN
 INSERT INTO orders VALUES(test_uuid(n+10000),'dine_in');
 INSERT INTO emergency_order_queue(id,session_id,restaurant_id,order_id,floor_label,kitchen_direct_to_floor)
 VALUES(test_uuid(n+20000),sess,store,test_uuid(n+10000),floor,direct);
 INSERT INTO emergency_fulfillment_items(id,restaurant_id,session_id,queue_id,order_id,order_item_id,
 ordered_quantity,kitchen_started_quantity,kitchen_done_quantity,tray_received_quantity,tray_dispatched_quantity)
 VALUES(test_uuid(n),store,sess,test_uuid(n+20000),test_uuid(n+10000),test_uuid(n+30000),
 qty,started,done,handed,handed);
 IF handed>0 THEN INSERT INTO emergency_floor_ready_lots(restaurant_id,session_id,queue_id,order_id,
 order_item_id,source_kind,source_id,ready_sequence,ready_quantity)
 VALUES(store,sess,test_uuid(n+20000),test_uuid(n+10000),test_uuid(n+30000),'base',test_uuid(n),1,handed); END IF;
 IF NOT direct AND done>handed THEN INSERT INTO emergency_tray_ready_lots(restaurant_id,session_id,queue_id,
 order_id,order_item_id,source_kind,source_id,ready_sequence,ready_quantity)
 VALUES(store,sess,test_uuid(n+20000),test_uuid(n+10000),test_uuid(n+30000),'base',test_uuid(n),1,done-handed); END IF;
 RETURN test_uuid(n);
END$$;
