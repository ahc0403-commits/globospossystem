CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;

CREATE SCHEMA auth;

CREATE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE
AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

CREATE FUNCTION auth.role() RETURNS text
LANGUAGE sql STABLE
AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.role', true), '')
$$;

CREATE TABLE public.users (
  id uuid PRIMARY KEY,
  auth_id uuid UNIQUE NOT NULL,
  role text NOT NULL,
  is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE public.restaurants (
  id uuid PRIMARY KEY,
  brand_id uuid,
  is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE public.user_store_access (
  user_id uuid NOT NULL REFERENCES public.users(id),
  store_id uuid NOT NULL REFERENCES public.restaurants(id),
  is_active boolean NOT NULL DEFAULT true
);

CREATE FUNCTION public.user_accessible_stores(uid uuid)
RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT access.store_id
  FROM public.user_store_access access
  JOIN public.users actor ON actor.id = access.user_id
  JOIN public.restaurants store ON store.id = access.store_id
  WHERE actor.auth_id = uid
    AND actor.is_active
    AND access.is_active
    AND store.is_active
$$;

CREATE FUNCTION public.inventory_purchase_actor_role()
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT actor.role
  FROM public.users actor
  WHERE actor.auth_id = auth.uid() AND actor.is_active
  LIMIT 1
$$;

CREATE TABLE public.inventory_suppliers (
  id uuid PRIMARY KEY,
  brand_id uuid,
  status text NOT NULL DEFAULT 'active'
);

CREATE TABLE public.inventory_products (
  id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  brand_id uuid,
  is_active boolean NOT NULL DEFAULT true,
  is_orderable boolean NOT NULL DEFAULT true
);

CREATE TABLE public.inventory_supplier_items (
  id uuid PRIMARY KEY,
  supplier_id uuid NOT NULL REFERENCES public.inventory_suppliers(id),
  product_id uuid NOT NULL REFERENCES public.inventory_products(id),
  is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE public.inventory_purchase_orders (
  id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  supplier_id uuid NOT NULL REFERENCES public.inventory_suppliers(id)
);

CREATE TABLE public.inventory_purchase_order_lines (
  id uuid PRIMARY KEY,
  purchase_order_id uuid NOT NULL REFERENCES public.inventory_purchase_orders(id),
  product_id uuid NOT NULL REFERENCES public.inventory_products(id),
  supplier_item_id uuid REFERENCES public.inventory_supplier_items(id)
);

CREATE TABLE public.inventory_receipts (
  id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id)
);

CREATE TABLE public.inventory_receipt_lines (
  id uuid PRIMARY KEY,
  receipt_id uuid NOT NULL REFERENCES public.inventory_receipts(id)
);

CREATE TABLE public.inventory_purchase_approval_events (
  id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id)
);

CREATE TABLE public.inventory_purchase_documents (
  id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id)
);

CREATE TABLE public.inventory_supplier_item_price_history (
  id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id)
);

CREATE TABLE public.inventory_receipt_confirmation_attempts (
  id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id)
);

ALTER TABLE public.inventory_suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_supplier_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_purchase_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_purchase_order_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_receipt_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_purchase_approval_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_purchase_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_supplier_item_price_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_receipt_confirmation_attempts ENABLE ROW LEVEL SECURITY;

GRANT USAGE ON SCHEMA public, auth TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated;

INSERT INTO public.restaurants(id, brand_id) VALUES
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002');

INSERT INTO public.users(id, auth_id, role) VALUES
  ('30000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', 'inventory_orderer'),
  ('30000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000002', 'inventory_accounting'),
  ('30000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000003', 'store_admin'),
  ('30000000-0000-0000-0000-000000000004', '40000000-0000-0000-0000-000000000004', 'kitchen');

INSERT INTO public.user_store_access(user_id, store_id)
SELECT actor.id, '10000000-0000-0000-0000-000000000001'::uuid
FROM public.users actor;

INSERT INTO public.inventory_suppliers(id, brand_id) VALUES
  ('50000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001'),
  ('50000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002');

INSERT INTO public.inventory_products(id, restaurant_id, brand_id) VALUES
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001'),
  ('60000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002');

INSERT INTO public.inventory_supplier_items(id, supplier_id, product_id) VALUES
  ('70000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001'),
  ('70000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000002');

INSERT INTO public.inventory_purchase_orders(id, restaurant_id, supplier_id) VALUES
  ('80000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001'),
  ('80000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000002');
