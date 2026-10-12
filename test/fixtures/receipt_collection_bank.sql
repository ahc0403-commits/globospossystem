CREATE TABLE brands(id uuid PRIMARY KEY, name text);
CREATE TABLE tax_entity(id uuid PRIMARY KEY, name text, tax_code text);
CREATE TABLE restaurants(id uuid PRIMARY KEY, name text, address text, brand_id uuid, tax_entity_id uuid);
CREATE TABLE orders(id uuid PRIMARY KEY, restaurant_id uuid);
CREATE TABLE order_items(order_id uuid, unit_price numeric, quantity numeric, status text, is_service_item boolean);
CREATE TABLE order_discounts(order_id uuid, discount_amount numeric, status text);
CREATE TABLE users(auth_id uuid PRIMARY KEY, fixed_account_code text, full_name text);
CREATE TABLE payments(id uuid PRIMARY KEY, order_id uuid, processed_by uuid, created_at timestamptz);
CREATE TABLE print_jobs(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), copy_type text, order_id uuid, payload jsonb);
CREATE TABLE tax_entity_collection_accounts(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tax_entity_id uuid,
  bank_bin text, bank_label text, account_number text, account_holder text,
  effective_from timestamptz DEFAULT now(), retired_at timestamptz
);
CREATE UNIQUE INDEX collection_account_one_active ON tax_entity_collection_accounts(tax_entity_id) WHERE retired_at IS NULL;
INSERT INTO tax_entity VALUES
  ('10000000-0000-0000-0000-000000000001','AKJ INTERNATIONAL CO., LTD','FIXTURE-A'),
  ('10000000-0000-0000-0000-000000000002','Other company','FIXTURE-B');
INSERT INTO restaurants(id,name,tax_entity_id) VALUES
  ('20000000-0000-0000-0000-000000000001','AKJ store','10000000-0000-0000-0000-000000000001'),
  ('20000000-0000-0000-0000-000000000002','Other store','10000000-0000-0000-0000-000000000002'),
  ('20000000-0000-0000-0000-000000000003','Unconfigured store',NULL);
INSERT INTO brands VALUES('50000000-0000-0000-0000-000000000001','BunsikClub');
UPDATE restaurants SET brand_id='50000000-0000-0000-0000-000000000001'
WHERE id='20000000-0000-0000-0000-000000000002';
INSERT INTO orders SELECT ('30000000-0000-0000-0000-00000000000'||n)::uuid,id FROM restaurants CROSS JOIN LATERAL (SELECT right(id::text,1) AS n) v;
INSERT INTO order_items SELECT id,100000,1,'served',false FROM orders;
INSERT INTO tax_entity_collection_accounts(tax_entity_id,bank_bin,bank_label,account_number,account_holder) VALUES
  ('10000000-0000-0000-0000-000000000001','970426','MSB','80002014298','AKJ INTERNATIONAL CO., LTD'),
  ('10000000-0000-0000-0000-000000000002','970426','Other bank','99999000001','Other company');
