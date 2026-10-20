-- Minimal predecessor helpers isolate the actual new migration. The full live
-- predecessor schema is also exercised separately by menu_size_prices_test.sql.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
END $$;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.menu_categories(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),restaurant_id uuid,name text);
CREATE TABLE public.menu_items(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),restaurant_id uuid NOT NULL,category_id uuid,
 name text,name_ko text,name_vi text,name_en text,paperless_name_vi text,
 price numeric NOT NULL,portion_code text NOT NULL DEFAULT '',spice_level text NOT NULL DEFAULT 'unknown',spice_choice text NOT NULL DEFAULT '',option_base_names jsonb NOT NULL DEFAULT '{}',
 sort_order int DEFAULT 0,is_available boolean DEFAULT true,is_archived boolean DEFAULT false,is_visible_public boolean DEFAULT false,is_combo boolean DEFAULT false,
 description text,image_url text,image_storage_path text,fulfillment_route text DEFAULT 'kitchen_tray_floor',vat_category text DEFAULT 'food',
 beverage_sugar_tax_class text DEFAULT 'not_applicable',sugar_g_per_100ml numeric,tax_basis_note text,invoice_sale_unit text,updated_at timestamptz DEFAULT now(),
 UNIQUE(id,restaurant_id)
);
CREATE TABLE public.audit_logs(actor_id uuid,action text,entity_type text,entity_id uuid,details jsonb);
CREATE FUNCTION public.require_admin_actor_for_restaurant(p_store uuid) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 IF auth.uid() IS NULL OR p_store IS NULL THEN RAISE EXCEPTION 'ADMIN_MUTATION_FORBIDDEN'; END IF;
END $$;
CREATE FUNCTION public.admin_create_menu_item_with_invoice(uuid,uuid,text,text,text,text,numeric,integer DEFAULT 0,boolean DEFAULT true,jsonb DEFAULT NULL,text DEFAULT NULL)
RETURNS public.menu_items LANGUAGE sql AS $$
 INSERT INTO public.menu_items(restaurant_id,category_id,name,name_ko,name_vi,name_en,paperless_name_vi,price,sort_order,is_available,invoice_sale_unit)
 VALUES($1,$2,$3,$3,$4,$5,$6,$7,$8,$9,$11) RETURNING *;
$$;
CREATE FUNCTION public.admin_update_menu_item_i18n_paperless(uuid,text,text,text,text,numeric)
RETURNS public.menu_items LANGUAGE sql AS $$ UPDATE public.menu_items SET name=$2,name_ko=$2,name_vi=$3,name_en=$4,paperless_name_vi=$5,price=$6 WHERE id=$1 RETURNING * $$;
CREATE FUNCTION public.admin_set_menu_beverage_tax(uuid,jsonb) RETURNS public.menu_items LANGUAGE sql AS $$ SELECT * FROM public.menu_items WHERE id=$1 $$;
CREATE FUNCTION public.admin_import_menu_items(uuid,jsonb) RETURNS jsonb LANGUAGE sql AS $$ SELECT '{}'::jsonb $$;
CREATE FUNCTION public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb) RETURNS jsonb LANGUAGE sql AS $$ SELECT '{}'::jsonb $$;
