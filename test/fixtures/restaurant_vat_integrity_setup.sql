CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT '00000000-0000-4000-8000-000000000001'::uuid $$;
CREATE FUNCTION public.is_super_admin() RETURNS boolean LANGUAGE sql AS $$ SELECT true $$;
CREATE FUNCTION public.user_accessible_stores(uuid) RETURNS TABLE(store_id uuid) LANGUAGE sql AS $$ SELECT NULL::uuid WHERE false $$;
CREATE TABLE users(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),auth_id uuid,role text,is_active boolean);
INSERT INTO users(auth_id,role,is_active) VALUES(auth.uid(),'cashier',true);
CREATE TABLE brands(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),service_charge_enabled boolean DEFAULT false,service_charge_rate numeric DEFAULT 0);
CREATE TABLE restaurants(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),brand_id uuid,vat_pricing_mode text DEFAULT 'exclusive');
CREATE TABLE tables(id uuid PRIMARY KEY,status text);
CREATE TABLE orders(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),restaurant_id uuid,status text DEFAULT 'serving',order_purpose text DEFAULT 'customer',table_id uuid,updated_at timestamptz DEFAULT now());
CREATE TABLE menu_items(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),vat_category text);
CREATE TABLE order_items(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),restaurant_id uuid,order_id uuid,menu_item_id uuid,item_type text DEFAULT 'menu_item',label text,display_name text,unit_price numeric(12,2),quantity integer,status text DEFAULT 'served',vat_rate numeric(5,2),vat_amount numeric(15,2),total_amount_ex_tax numeric(15,2),paying_amount_inc_tax numeric(15,2),is_service_item boolean DEFAULT false,created_at timestamptz DEFAULT now(),CONSTRAINT order_items_wet_tissue_charge_check CHECK (item_type <> 'wet_tissue_charge' OR vat_rate=0));
CREATE UNIQUE INDEX one_tissue ON order_items(order_id) WHERE item_type='wet_tissue_charge';
CREATE TABLE payments(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),order_id uuid,restaurant_id uuid,amount numeric(15,2),method text,processed_by uuid,is_revenue boolean,amount_portion numeric(15,2),created_at timestamptz DEFAULT now());
CREATE TABLE order_discounts(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),order_id uuid,restaurant_id uuid,status text DEFAULT 'active',discount_mode text,discount_value numeric(12,2),discount_amount numeric(15,2),approved_via text,updated_at timestamptz DEFAULT now());
CREATE TABLE order_discount_lines(order_discount_id uuid,order_item_id uuid,discount_amount numeric(15,2),PRIMARY KEY(order_discount_id,order_item_id));
CREATE TABLE menu_recipes(menu_item_id uuid,restaurant_id uuid,ingredient_id uuid,quantity_g numeric);
CREATE TABLE inventory_items(id uuid,restaurant_id uuid,current_stock numeric,updated_at timestamptz);
CREATE TABLE inventory_transactions(restaurant_id uuid,ingredient_id uuid,transaction_type text,quantity_g numeric,reference_type text,reference_id uuid,created_by uuid);
CREATE TABLE audit_logs(actor_id uuid,action text,entity_type text,entity_id uuid,details jsonb);
-- Capture at the real production AFTER UPDATE OF status trigger boundary.
CREATE TABLE captured_invoice(order_id uuid,lines jsonb);
CREATE FUNCTION capture_invoice() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.status='completed' AND OLD.status<>'completed' THEN
 INSERT INTO captured_invoice SELECT NEW.id,jsonb_agg(to_jsonb(i)) FROM order_items i WHERE i.order_id=NEW.id AND i.status<>'cancelled' AND NOT i.is_service_item;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER capture AFTER UPDATE OF status ON orders FOR EACH ROW EXECUTE FUNCTION capture_invoice();
CREATE FUNCTION get_restaurant_daily_sales_exports_by_tax_entity(date) RETURNS jsonb
LANGUAGE sql AS $$ SELECT jsonb_agg(jsonb_build_object(
  'quantity', item.quantity, 'total_amount_ex_tax', item.total_amount_ex_tax
)) FROM order_items item $$;
