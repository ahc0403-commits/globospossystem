CREATE EXTENSION pgcrypto;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END $$;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$
SELECT nullif(current_setting('request.jwt.claim.role',true),'') $$;
GRANT USAGE ON SCHEMA auth TO anon,authenticated,service_role;
CREATE TABLE restaurants(id uuid PRIMARY KEY,name text,is_active boolean DEFAULT true);
CREATE TABLE users(id uuid PRIMARY KEY,auth_id uuid,restaurant_id uuid,role text,is_active boolean DEFAULT true);
CREATE FUNCTION is_super_admin() RETURNS boolean LANGUAGE sql STABLE AS $$
SELECT EXISTS(SELECT 1 FROM users WHERE auth_id=auth.uid() AND role='super_admin' AND is_active) $$;
CREATE FUNCTION user_accessible_stores(uuid) RETURNS SETOF uuid LANGUAGE sql STABLE AS $$
SELECT restaurant_id FROM users WHERE auth_id=$1 AND is_active $$;
CREATE TABLE tables(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),restaurant_id uuid REFERENCES restaurants,
 table_number text,status text DEFAULT 'available',seat_count int DEFAULT 4,floor_label text DEFAULT '1F',
 created_at timestamptz DEFAULT now(),updated_at timestamptz DEFAULT now());
CREATE TABLE orders(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),restaurant_id uuid REFERENCES restaurants,
 table_id uuid REFERENCES tables,status text DEFAULT 'pending',sales_channel text DEFAULT 'dine_in',
 order_source text DEFAULT 'staff',order_purpose text DEFAULT 'customer',fulfillment_mode_snapshot text DEFAULT 'paperless',
 created_by uuid,guest_count integer,notes text,created_at timestamptz DEFAULT now(),updated_at timestamptz DEFAULT now());
CREATE TABLE menu_items(id uuid PRIMARY KEY,restaurant_id uuid,name text,name_ko text,name_vi text,name_en text,
 price numeric,is_available boolean DEFAULT true,is_visible_public boolean DEFAULT true);
CREATE TABLE order_items(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),order_id uuid REFERENCES orders,
 restaurant_id uuid,menu_item_id uuid,label text,display_name text,unit_price numeric DEFAULT 100,
 quantity integer DEFAULT 1,status text DEFAULT 'pending',item_type text DEFAULT 'menu_item',notes text,
 is_service_item boolean DEFAULT false,paying_amount_inc_tax numeric DEFAULT 0,is_takeout boolean DEFAULT false,
 created_at timestamptz DEFAULT now(),updated_at timestamptz DEFAULT now());
CREATE TABLE payments(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),order_id uuid REFERENCES orders,
 restaurant_id uuid,amount numeric,method text DEFAULT 'CASH',is_revenue boolean DEFAULT true,
 created_at timestamptz DEFAULT now());
CREATE TABLE customer_payment_displays(store_id uuid PRIMARY KEY,order_id uuid,status text DEFAULT 'idle',
 payload jsonb,shown_by_user_id uuid,shown_at timestamptz,updated_at timestamptz DEFAULT now());
CREATE TABLE audit_logs(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),actor_id uuid,action text,
 entity_type text,entity_id uuid,details jsonb,created_at timestamptz DEFAULT now());
CREATE TABLE print_jobs(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),order_id uuid REFERENCES orders,
 status text DEFAULT 'pending',copy_type text DEFAULT 'kitchen',batch_no int DEFAULT 1,
 updated_at timestamptz DEFAULT now());
CREATE FUNCTION enqueue_print_jobs(uuid,text[],jsonb,text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO print_jobs(order_id,copy_type) SELECT $1,unnest($2); END $$;
CREATE FUNCTION void_active_order_discount_for_item_change(uuid,uuid,text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN END $$;
CREATE TABLE emergency_fulfillment_sessions(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),status text DEFAULT 'active',activated_at timestamptz DEFAULT now());
CREATE TABLE emergency_fulfillment_items(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),order_id uuid REFERENCES orders,
 order_item_id uuid,restaurant_id uuid,session_id uuid,queue_id uuid,line_key text DEFAULT 'base',source_kind text DEFAULT 'order_item',
 name_ko text,name_vi text,name_en text,source_quantity int DEFAULT 1,ordered_quantity int DEFAULT 1,
 kitchen_started_quantity int DEFAULT 0,kitchen_done_quantity int DEFAULT 0,tray_received_quantity int DEFAULT 0,
 tray_dispatched_quantity int DEFAULT 0,floor_served_quantity int DEFAULT 0,excused_quantity int DEFAULT 0,
 is_cancelled boolean DEFAULT false,needs_review boolean DEFAULT false,
 created_at timestamptz DEFAULT now(),updated_at timestamptz DEFAULT now());
CREATE TABLE emergency_combo_component_items(LIKE emergency_fulfillment_items INCLUDING ALL);
CREATE TABLE emergency_floor_direct_items(LIKE emergency_fulfillment_items INCLUDING ALL);
CREATE TABLE emergency_floor_ready_lots(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),order_id uuid REFERENCES orders,
 ready_quantity int DEFAULT 1,served_quantity int DEFAULT 0,voided_quantity int DEFAULT 0,
 updated_at timestamptz DEFAULT now(),CHECK(served_quantity+voided_quantity<=ready_quantity));
CREATE TABLE leftover_packaging_requests(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),order_id uuid REFERENCES orders,
 status text DEFAULT 'awaiting_floor_pickup',updated_at timestamptz DEFAULT now());
CREATE TABLE table_qr_tokens(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),restaurant_id uuid,table_id uuid,
 token text UNIQUE,is_active boolean DEFAULT true);
CREATE TABLE qr_order_batches(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),restaurant_id uuid,table_id uuid,order_id uuid,
 batch_no int,client_order_id uuid UNIQUE,items_snapshot jsonb,result_snapshot jsonb,created_at timestamptz DEFAULT now());
CREATE TABLE qr_order_display_states(order_id uuid PRIMARY KEY,visible_from timestamptz,display_version bigint DEFAULT 0,
 reset_applied_at timestamptz,reset_due_at timestamptz);
CREATE FUNCTION qr_apply_due_order_display_reset(uuid) RETURNS qr_order_display_states LANGUAGE plpgsql AS $$
DECLARE r qr_order_display_states;
BEGIN INSERT INTO qr_order_display_states(order_id,visible_from) SELECT id,created_at FROM orders WHERE id=$1
 ON CONFLICT DO NOTHING; SELECT * INTO r FROM qr_order_display_states WHERE order_id=$1; RETURN r; END $$;
CREATE FUNCTION emergency_enrich_qr_unserved_items(uuid,jsonb) RETURNS jsonb LANGUAGE sql AS $$ SELECT $2 $$;
CREATE FUNCTION qr_refresh_order_display_state(uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN PERFORM qr_apply_due_order_display_reset($1); END $$;
CREATE TABLE pos_client_mutation_attempts(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),store_id uuid,
 actor_id uuid,client_mutation_id text,mutation_type text,entity_type text,entity_id uuid,result_payload jsonb,
 created_at timestamptz DEFAULT now(),updated_at timestamptz DEFAULT now(),UNIQUE(store_id,actor_id,client_mutation_id));
CREATE TABLE order_cancellation_ledger(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),restaurant_id uuid,order_id uuid,
 order_item_id uuid,cancellation_scope text,cancelled_amount numeric,quantity int,unit_price numeric,
 item_snapshot jsonb,order_status_snapshot text,created_by uuid,created_at timestamptz DEFAULT now());
CREATE TABLE order_cancellation_reversals(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),cancellation_ledger_id uuid,
 restaurant_id uuid,order_id uuid,restored_by uuid,created_at timestamptz DEFAULT now());
CREATE TABLE inventory_items(id uuid PRIMARY KEY,current_stock numeric);
CREATE TABLE inventory_transactions(id uuid PRIMARY KEY,item_id uuid,quantity numeric);
CREATE TABLE einvoice_jobs(id uuid PRIMARY KEY,order_id uuid,status text);
CREATE FUNCTION test_uuid(integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
SELECT ('91000000-0000-4000-8000-'||lpad($1::text,12,'0'))::uuid $$;
CREATE FUNCTION test_assert(boolean,text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF $1 IS DISTINCT FROM true THEN RAISE EXCEPTION 'ASSERTION_FAILED: %',$2; END IF; END $$;
INSERT INTO restaurants VALUES(test_uuid(1),'BunsikClub Binh Thanh',true),(test_uuid(2),'Other store',true);
INSERT INTO users VALUES(test_uuid(3),test_uuid(3),test_uuid(1),'cashier',true),
 (test_uuid(4),test_uuid(4),test_uuid(1),'waiter',true),(test_uuid(5),test_uuid(5),test_uuid(2),'cashier',true);
INSERT INTO tables(id,restaurant_id,table_number,status) SELECT test_uuid(100+n),test_uuid(1),n::text,'available' FROM generate_series(1,20) n;
INSERT INTO menu_items(id,restaurant_id,name,price) VALUES(test_uuid(10),test_uuid(1),'Kimbap',100),(test_uuid(11),test_uuid(1),'Cola',50);
INSERT INTO inventory_items VALUES(test_uuid(20),98);
INSERT INTO inventory_transactions VALUES(test_uuid(21),test_uuid(20),-2);
