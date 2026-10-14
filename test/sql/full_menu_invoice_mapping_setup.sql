CREATE TABLE public.menu_categories(id uuid PRIMARY KEY,restaurant_id uuid,name_vi text,analytics_group text,sort_order integer);
ALTER TABLE public.menu_items ADD COLUMN category_id uuid,ADD COLUMN name_vi text,ADD COLUMN is_combo boolean DEFAULT false,ADD COLUMN is_archived boolean DEFAULT false,ADD COLUMN is_available boolean DEFAULT true,ADD COLUMN is_visible_public boolean DEFAULT false;
CREATE FUNCTION public.require_admin_actor_for_restaurant(p_store_id uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 IF auth.uid() IS NULL OR (NOT public.is_super_admin() AND p_store_id<>'20000000-0000-0000-0000-000000000001'::uuid) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
END $$;
INSERT INTO menu_categories VALUES('21000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','Food','food',0),('21000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000001','Drink','drink',1);
UPDATE menu_items SET name_vi=name,category_id='21000000-0000-0000-0000-000000000001';
ALTER TABLE menu_items ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE menu_items ADD COLUMN name_ko text,ADD COLUMN name_en text,ADD COLUMN paperless_name_vi text,ADD COLUMN description text,ADD COLUMN price numeric DEFAULT 10000,ADD COLUMN sort_order integer DEFAULT 0,ADD COLUMN created_at timestamptz DEFAULT now(),ADD COLUMN updated_at timestamptz DEFAULT now(),ADD COLUMN image_url text,ADD COLUMN image_storage_path text,ADD COLUMN vat_category text DEFAULT 'food',ADD COLUMN beverage_sugar_tax_class text DEFAULT 'not_applicable',ADD COLUMN sugar_g_per_100ml numeric,ADD COLUMN tax_basis_note text,ADD COLUMN effective_vat_rate numeric GENERATED ALWAYS AS (CASE WHEN beverage_sugar_tax_class='gt_5' THEN 10 ELSE 8 END) STORED;
ALTER TABLE menu_categories ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE menu_categories ADD COLUMN name text,ADD COLUMN name_ko text,ADD COLUMN name_en text,ADD COLUMN is_active boolean DEFAULT true,ADD COLUMN created_at timestamptz DEFAULT now();
UPDATE menu_categories SET name=name_vi,name_ko=name_vi,name_en=name_vi;
CREATE TABLE audit_logs(actor_id uuid,action text,entity_type text,entity_id uuid,details jsonb);
