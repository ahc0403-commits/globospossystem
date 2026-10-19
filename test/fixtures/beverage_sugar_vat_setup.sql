ALTER TABLE public.menu_items
 ADD COLUMN restaurant_id uuid, ADD COLUMN category_id uuid, ADD COLUMN name text,
 ADD COLUMN name_ko text, ADD COLUMN name_vi text, ADD COLUMN name_en text,
 ADD COLUMN paperless_name_vi text, ADD COLUMN description text,
 ADD COLUMN price numeric(12,2), ADD COLUMN sort_order integer,
 ADD COLUMN is_available boolean DEFAULT true, ADD COLUMN is_visible_public boolean DEFAULT true,
 ADD COLUMN is_archived boolean DEFAULT false, ADD COLUMN is_combo boolean DEFAULT false,
 ADD COLUMN combo_drink_choice_count integer DEFAULT 0,
 ADD COLUMN created_at timestamptz DEFAULT now(),ADD COLUMN updated_at timestamptz DEFAULT now();
ALTER TABLE public.menu_items ALTER COLUMN vat_category SET DEFAULT 'food';
ALTER TABLE public.order_items ADD COLUMN combo_components jsonb DEFAULT '[]';
ALTER TABLE public.orders ADD COLUMN order_source text DEFAULT 'pos';
ALTER TABLE public.order_discounts ADD COLUMN discount_type text,ADD COLUMN reason text,ADD COLUMN coupon_code text,
 ADD COLUMN proof_storage_path text,ADD COLUMN applied_by uuid,ADD COLUMN void_reason text;
ALTER TABLE public.order_discount_lines ADD COLUMN menu_item_id uuid,ADD COLUMN restaurant_id uuid,
 ADD COLUMN promotion_id uuid,ADD COLUMN line_amount_before_discount numeric,ADD COLUMN discount_percent numeric;
CREATE TABLE public.store_promotions(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),restaurant_id uuid,name text,
 discount_percent numeric,scope text DEFAULT 'all_menu',channel text DEFAULT 'both',starts_at timestamptz DEFAULT now()-interval '1 hour',
 ends_at timestamptz DEFAULT now()+interval '1 hour',is_active boolean DEFAULT true,created_by uuid);
CREATE TABLE public.store_promotion_menu_items(promotion_id uuid,restaurant_id uuid,menu_item_id uuid);
CREATE TABLE public.menu_categories(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),restaurant_id uuid,name text);
CREATE TABLE public.menu_combo_components(restaurant_id uuid,combo_menu_item_id uuid,component_menu_item_id uuid,quantity integer);
CREATE TABLE public.direct_order_request_items(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),request_id uuid,restaurant_id uuid,menu_item_id uuid,vat_category text,unit_price numeric,quantity integer,sort_order integer);
CREATE TABLE public.direct_order_requests(id uuid PRIMARY KEY,restaurant_id uuid,state text DEFAULT 'awaiting_quote',updated_at timestamptz);
CREATE TABLE public.direct_order_quotes(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),request_id uuid,restaurant_id uuid,version integer,
 menu_pretax numeric,menu_vat numeric,menu_total numeric,service_charge_pretax numeric,service_charge_vat numeric,service_charge_total numeric,
 delivery_fee_pretax numeric,delivery_fee_vat numeric,delivery_fee_total numeric,final_total numeric,delivery_fee_vat_rate numeric,
 status text,cashier_note text,created_by uuid,expires_at timestamptz);
CREATE TABLE public.direct_order_storefronts(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),restaurant_id uuid,is_enabled boolean DEFAULT true,
 is_paused boolean DEFAULT false,accounting_approved_at timestamptz DEFAULT now(),accounting_approved_by uuid DEFAULT gen_random_uuid(),
 delivery_fee_vat_rate numeric DEFAULT 0,minimum_order_amount numeric DEFAULT 0,quote_ttl_minutes integer DEFAULT 30);
CREATE TABLE public.direct_order_messages(request_id uuid,restaurant_id uuid,sender_type text,sender_auth_id uuid,message_type text,body text,metadata jsonb);
CREATE FUNCTION public.direct_order_require_actor(uuid,text[]) RETURNS void LANGUAGE plpgsql AS $$ BEGIN RETURN; END $$;
CREATE TABLE public.direct_order_financials(id uuid PRIMARY KEY);
CREATE TABLE public.direct_delivery_fulfillment_tickets(id uuid PRIMARY KEY);
CREATE TABLE public.meinvoice_jobs(id uuid PRIMARY KEY);
CREATE TABLE public.red_invoice_intakes(id uuid PRIMARY KEY);
CREATE FUNCTION public.require_admin_actor_for_restaurant(store uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 IF current_setting('beverage_test.deny_admin',true)='true' THEN RAISE EXCEPTION 'ADMIN_MUTATION_FORBIDDEN'; END IF;
END $$;
-- Catalogue mutation behavior stays in the existing independently tested RPCs.
-- These fixture predecessors isolate the additive tax wrapper's atomicity.
CREATE FUNCTION public.admin_update_menu_workbook_i18n(p_store_id uuid,p_categories jsonb,p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$ BEGIN
 PERFORM public.require_admin_actor_for_restaurant(p_store_id);
 UPDATE public.menu_items m SET price=(e->>'price')::numeric FROM jsonb_array_elements(p_items) e
 WHERE m.id=(e->>'item_id')::uuid AND m.restaurant_id=p_store_id;
 RETURN '{}'; END $$;
CREATE FUNCTION public.admin_import_menu_items(p_store_id uuid,p_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$ BEGIN
 PERFORM public.require_admin_actor_for_restaurant(p_store_id);
 RETURN '{}'; END $$;
