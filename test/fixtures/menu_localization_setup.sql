-- Disposable read-model fixture. Identity/access helpers below model the
-- supported BM/store scopes; the production read functions run unchanged.
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;
CREATE SCHEMA auth;
CREATE TABLE auth.users(id uuid PRIMARY KEY, email text);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
CREATE TABLE companies(id uuid PRIMARY KEY, name text);
CREATE TABLE brand_master(id uuid PRIMARY KEY, company_id uuid, name text, type text);
CREATE TABLE tax_entity(id uuid PRIMARY KEY, tax_code text, name text, owner_type text);
CREATE TABLE brands(id uuid PRIMARY KEY, code text, name text, brand_master_id uuid);
CREATE TABLE restaurants(id uuid PRIMARY KEY, name text, slug text, brand_id uuid, tax_entity_id uuid, is_active boolean DEFAULT true);
CREATE TABLE users(id uuid PRIMARY KEY, auth_id uuid, restaurant_id uuid, primary_store_id uuid, brand_id uuid, role text, full_name text, fixed_account_code text, is_active boolean DEFAULT true);
CREATE TABLE tables(id uuid PRIMARY KEY, restaurant_id uuid, table_number text);
CREATE TABLE menu_items(id uuid PRIMARY KEY, restaurant_id uuid, name text, name_ko text, name_vi text, name_en text, price numeric);
CREATE TABLE orders(id uuid PRIMARY KEY, restaurant_id uuid, table_id uuid, status text, order_purpose text DEFAULT 'customer', sales_channel text DEFAULT 'dine_in', notes text, created_by uuid, created_at timestamptz DEFAULT now());
CREATE TABLE order_items(id uuid PRIMARY KEY, restaurant_id uuid, order_id uuid, menu_item_id uuid, menu_item_id_snapshot uuid, item_type text DEFAULT 'menu_item', label text, display_name text, quantity integer, unit_price numeric, status text, is_service_item boolean DEFAULT false, paying_amount_inc_tax numeric, combo_components jsonb DEFAULT '[]', created_at timestamptz DEFAULT now());
CREATE TABLE audit_logs(id uuid PRIMARY KEY, actor_id uuid, action text, entity_type text, entity_id uuid, details jsonb, created_at timestamptz DEFAULT now());
CREATE TABLE order_cancellation_ledger(id uuid PRIMARY KEY, restaurant_id uuid, order_id uuid, order_item_id uuid, cancelled_amount numeric, quantity numeric, unit_price numeric, order_status_snapshot text, cancellation_scope text, item_snapshot jsonb, created_by uuid, created_at timestamptz DEFAULT now());
CREATE TABLE order_cancellation_reversals(id uuid PRIMARY KEY, cancellation_ledger_id uuid, restaurant_id uuid, order_id uuid, order_item_id uuid, restored_by uuid, restored_at timestamptz DEFAULT now());
CREATE TABLE combined_payment_groups(id uuid PRIMARY KEY, completed_at timestamptz);
CREATE TABLE payments(id uuid PRIMARY KEY, order_id uuid, restaurant_id uuid, combined_payment_group_id uuid, amount numeric, amount_portion numeric, method text, processed_by uuid, is_revenue boolean DEFAULT true, created_at timestamptz DEFAULT now());
CREATE TABLE payment_adjustments(id uuid PRIMARY KEY, payment_id uuid, restaurant_id uuid, amount numeric, created_at timestamptz DEFAULT now());
CREATE TABLE digital_receipts(id uuid PRIMARY KEY, order_id uuid, combined_payment_group_id uuid, receipt_number text, snapshot jsonb);
CREATE TABLE external_sales(id uuid PRIMARY KEY, restaurant_id uuid, external_order_id text, completed_at timestamptz, created_at timestamptz, sales_channel text, source_system text, gross_amount numeric, net_amount numeric, order_status text, is_revenue boolean);
CREATE FUNCTION user_accessible_stores(actor uuid) RETURNS TABLE(store_id uuid) LANGUAGE sql STABLE AS $$
  SELECT r.id FROM restaurants r JOIN users u ON u.auth_id = actor
  WHERE u.is_active AND r.is_active AND (
    u.role = 'super_admin' OR (u.role = 'brand_admin' AND r.brand_id = u.brand_id)
    OR (u.role <> 'brand_admin' AND r.id = u.restaurant_id)
  )
$$;
CREATE FUNCTION require_admin_actor_for_restaurant(store uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM users u JOIN user_accessible_stores(auth.uid()) scope ON scope.store_id = store WHERE u.auth_id=auth.uid() AND u.role IN ('brand_admin','store_admin','admin','super_admin')) THEN
    RAISE EXCEPTION 'ADMIN_MUTATION_FORBIDDEN';
  END IF;
END $$;
