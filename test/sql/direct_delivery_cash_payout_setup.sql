\set ON_ERROR_STOP on
DO $$ BEGIN
  IF current_database()<>'codex_direct_manual' THEN RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED'; END IF;
END $$;
-- Reduced unrelated dependencies. Dispatch DDL and all four tested RPCs are
-- loaded verbatim from the effective repository predecessors by the runner.
CREATE TABLE public.orders(id uuid PRIMARY KEY, restaurant_id uuid, status text, created_at timestamptz);
CREATE TABLE public.order_items(id uuid PRIMARY KEY, order_id uuid, status text);
CREATE TABLE public.payments(id uuid PRIMARY KEY,restaurant_id uuid,is_revenue boolean,
  method text,amount numeric,amount_portion numeric,created_at timestamptz);
CREATE TABLE public.inventory_items(restaurant_id uuid,is_active boolean,reorder_point numeric,current_stock numeric);
CREATE TABLE public.users(auth_id uuid,full_name text);
CREATE TABLE public.audit_logs(actor_id uuid,action text,entity_type text,entity_id uuid,details jsonb);
CREATE TABLE public.direct_order_financials(request_id uuid PRIMARY KEY,restaurant_id uuid,delivery_fee_total numeric);
CREATE TABLE public.daily_closings(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), restaurant_id uuid NOT NULL, closing_date date NOT NULL,
  closed_by uuid, close_source text NOT NULL DEFAULT 'manual', created_at timestamptz DEFAULT now(),
  orders_total int DEFAULT 0,orders_completed int DEFAULT 0,orders_cancelled int DEFAULT 0,items_cancelled int DEFAULT 0,
  payments_count int DEFAULT 0,payments_total numeric DEFAULT 0,payments_cash numeric DEFAULT 0,
  payments_card numeric DEFAULT 0,payments_pay numeric DEFAULT 0,service_count int DEFAULT 0,
  service_total numeric DEFAULT 0,low_stock_count int DEFAULT 0,notes text,
  opening_cash_amount numeric DEFAULT 0,cash_denominations jsonb DEFAULT '{}',
  expected_cash_amount numeric DEFAULT 0,counted_cash_amount numeric DEFAULT 0,cash_variance numeric DEFAULT 0,
  UNIQUE(restaurant_id,closing_date)
);
CREATE FUNCTION public.require_pos_admin_actor_for_store(p_store uuid,p_code text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
  IF p_store::text IS DISTINCT FROM current_setting('fixture.store_id',true) THEN RAISE EXCEPTION '%',p_code; END IF;
END $$;
CREATE FUNCTION public.direct_order_require_actor(p_store uuid,p_roles text[]) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
  PERFORM public.require_pos_admin_actor_for_store(p_store,'DIRECT_ORDER_FORBIDDEN');
END $$;

