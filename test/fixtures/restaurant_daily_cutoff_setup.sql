CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN BYPASSRLS;

CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT NULL::uuid $$;

CREATE TABLE public.restaurants (
  id uuid PRIMARY KEY,
  name text NOT NULL,
  address text,
  is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE public.restaurant_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL UNIQUE REFERENCES public.restaurants(id),
  settings_json jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE public.orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  sales_channel text NOT NULL DEFAULT 'dine_in',
  status text NOT NULL DEFAULT 'pending',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.order_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  item_type text NOT NULL DEFAULT 'menu_item',
  display_name text,
  unit_price numeric NOT NULL DEFAULT 0,
  quantity integer NOT NULL DEFAULT 1,
  status text NOT NULL DEFAULT 'pending',
  paying_amount_inc_tax numeric
);

CREATE TABLE public.payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  amount numeric NOT NULL,
  method text NOT NULL DEFAULT 'CASH',
  is_revenue boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.external_sales (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  source_system text NOT NULL DEFAULT 'deliberry',
  external_order_id text NOT NULL,
  sales_channel text NOT NULL DEFAULT 'delivery',
  gross_amount numeric NOT NULL,
  order_status text NOT NULL DEFAULT 'completed',
  is_revenue boolean NOT NULL DEFAULT true,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.photo_objet_monitoring_policies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.restaurants(id),
  is_enabled boolean NOT NULL DEFAULT true,
  effective_to timestamptz
);

CREATE TABLE public.photo_objet_sales_raw (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.restaurants(id),
  sold_at timestamptz NOT NULL,
  amount numeric NOT NULL
);

CREATE FUNCTION public.is_super_admin() RETURNS boolean
LANGUAGE sql STABLE AS $$ SELECT true $$;

CREATE FUNCTION public.user_accessible_stores(p_auth_id uuid)
RETURNS TABLE(store_id uuid)
LANGUAGE sql STABLE AS $$ SELECT id FROM public.restaurants $$;

CREATE FUNCTION public.create_order(uuid, uuid, jsonb)
RETURNS public.orders
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_result public.orders%ROWTYPE;
BEGIN
  INSERT INTO public.orders (restaurant_id)
  VALUES ($1)
  RETURNING * INTO v_result;
  RETURN v_result;
END $$;

CREATE FUNCTION public.add_items_to_order(uuid, uuid, jsonb)
RETURNS SETOF public.order_items
LANGUAGE sql SECURITY DEFINER AS $$
  SELECT * FROM public.order_items WHERE false
$$;

CREATE FUNCTION public.create_buffet_order(uuid, uuid, integer, jsonb)
RETURNS public.orders
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_result public.orders%ROWTYPE;
BEGIN
  INSERT INTO public.orders (restaurant_id)
  VALUES ($1)
  RETURNING * INTO v_result;
  RETURN v_result;
END $$;

CREATE FUNCTION public.process_payment(uuid, uuid, numeric, text)
RETURNS public.payments
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_result public.payments%ROWTYPE;
BEGIN
  INSERT INTO public.payments (order_id, restaurant_id, amount, method)
  VALUES ($1, $2, $3, $4)
  RETURNING * INTO v_result;
  RETURN v_result;
END $$;

INSERT INTO public.restaurants (id, name, address) VALUES
  ('81000000-0000-4000-8000-000000000001', 'Restaurant fixture', 'HCM'),
  ('81000000-0000-4000-8000-000000000002', 'Photo fixture', 'HCM');

INSERT INTO public.restaurant_settings (restaurant_id) VALUES
  ('81000000-0000-4000-8000-000000000001'),
  ('81000000-0000-4000-8000-000000000002');

INSERT INTO public.photo_objet_monitoring_policies (store_id) VALUES
  ('81000000-0000-4000-8000-000000000002');

GRANT USAGE ON SCHEMA public, auth TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public
  TO authenticated, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public, auth
  TO authenticated, service_role;
