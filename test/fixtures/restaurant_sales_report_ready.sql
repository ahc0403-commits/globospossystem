-- Synthetic data only, matching the columns read by the actual export RPC.
DO $$ BEGIN
  IF current_database() <> 'report_ready_test' THEN RAISE EXCEPTION 'TEST_DB_REQUIRED'; END IF;
END $$;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE FUNCTION is_super_admin() RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT COALESCE(current_setting('fixture.super_admin',true),'true')='true'
$$;
CREATE TABLE restaurant_daily_sales_finalizations(business_date date PRIMARY KEY,status text,finalized_at timestamptz);
CREATE TABLE tax_entity(id uuid PRIMARY KEY,tax_code text,name text);
CREATE TABLE restaurants(id uuid PRIMARY KEY,name text,brand_id uuid,tax_entity_id uuid);
CREATE TABLE orders(id uuid PRIMARY KEY,status text,sales_channel text);
CREATE TABLE payments(order_id uuid,restaurant_id uuid,created_at timestamptz,amount_portion numeric,amount numeric,method text,is_revenue boolean);
CREATE TABLE red_invoice_intakes(id uuid,order_id uuid,status text,buyer_tax_code text,buyer_legal_name text,buyer_address text,buyer_email text,buyer_phone text);
CREATE TABLE meinvoice_jobs(id uuid,order_id uuid,source_system text,created_at timestamptz,tax_entity_id uuid,payment_method_snapshot text,line_items_snapshot jsonb);
CREATE TABLE store_tax_entity_history(store_id uuid,tax_entity_id uuid,effective_from timestamptz,effective_to timestamptz,created_at timestamptz);
CREATE TABLE order_items(id uuid,order_id uuid,display_name text,label text,quantity numeric,unit_price numeric,total_amount_ex_tax numeric,vat_rate numeric,vat_amount numeric,created_at timestamptz,status text,is_service_item boolean);
CREATE FUNCTION meinvoice_payment_method_label(uuid,text[]) RETURNS text LANGUAGE sql AS $$ SELECT 'TM'::text $$;
CREATE FUNCTION fixture_assert(value boolean,label text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
  IF value IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %',label; END IF;
  RAISE NOTICE 'PASS: %',label;
END $$;
INSERT INTO tax_entity VALUES('10000000-0000-0000-0000-000000000001','FIXTURE-TAX','Fixture seller');
INSERT INTO restaurants VALUES
 ('20000000-0000-0000-0000-000000000001','Restaurant',NULL,'10000000-0000-0000-0000-000000000001'),
 ('20000000-0000-0000-0000-000000000002','Photo','77000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001');
INSERT INTO orders VALUES
 ('30000000-0000-0000-0000-000000000001','completed','dine_in'),
 ('30000000-0000-0000-0000-000000000002','completed','dine_in'),
 ('30000000-0000-0000-0000-000000000003','serving','dine_in');
INSERT INTO payments VALUES
 ('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','2026-09-04 21:00+07',100,100,'CASH',true),
 ('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','2026-09-04 21:30+07',50,50,'CASH',true),
 ('30000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000002','2026-09-04 21:00+07',300,300,'CASH',true),
 ('30000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000001','2026-09-04 21:00+07',200,200,'CASH',true);
