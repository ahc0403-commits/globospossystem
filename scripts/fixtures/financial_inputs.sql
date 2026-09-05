-- Extends payroll_attendance.sql in a disposable test DB only.
DO $$ BEGIN
  IF current_database() <> 'payroll_test' THEN RAISE EXCEPTION 'TEST_DATABASE_REQUIRED'; END IF;
END $$;
ALTER TABLE public.store_employees ADD COLUMN store_id uuid,
  ADD COLUMN is_active boolean NOT NULL DEFAULT true;
CREATE OR REPLACE FUNCTION public.is_super_admin() RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT auth.uid() = '20000000-0000-0000-0000-000000000003'::uuid
$$;
CREATE OR REPLACE FUNCTION public.user_accessible_stores(p_actor uuid)
RETURNS TABLE(store_id uuid) LANGUAGE sql STABLE AS $$
  SELECT '10000000-0000-0000-0000-000000000001'::uuid
  WHERE p_actor IN ('20000000-0000-0000-0000-000000000001'::uuid,
                   '20000000-0000-0000-0000-000000000002'::uuid)
$$;
CREATE FUNCTION public.fixture_can_read(store_id uuid) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT public.is_super_admin() OR store_id IN (SELECT public.user_accessible_stores(auth.uid()))
$$;
CREATE FUNCTION public.fixture_can_manage(store_id uuid) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT public.is_super_admin() OR (public.fixture_can_read(store_id)
    AND auth.uid() = '20000000-0000-0000-0000-000000000001'::uuid)
$$;
CREATE TABLE public.employee_daily_allowances (
  id uuid PRIMARY KEY, store_id uuid NOT NULL, employee_id uuid NOT NULL,
  work_date date NOT NULL, is_split_shift boolean, meal_allowance_amount numeric,
  parking_allowance_amount numeric, UNIQUE(store_id, employee_id, work_date)
);
CREATE TABLE public.vietnam_public_holidays (holiday_date date PRIMARY KEY, is_active boolean);
CREATE TABLE public.orders (
  id uuid PRIMARY KEY, restaurant_id uuid NOT NULL, status text,
  sales_channel text, created_at timestamptz NOT NULL
);
CREATE TABLE public.payments (
  id uuid PRIMARY KEY, restaurant_id uuid NOT NULL, order_id uuid REFERENCES public.orders,
  amount numeric, amount_portion numeric, method text, created_at timestamptz NOT NULL,
  proof_required boolean, proof_photo_url text, is_revenue boolean
);
CREATE TABLE public.external_sales (
  id uuid PRIMARY KEY, restaurant_id uuid NOT NULL, net_amount numeric,
  completed_at timestamptz, is_revenue boolean, order_status text
);
CREATE TABLE public.order_items (
  id uuid PRIMARY KEY, order_id uuid REFERENCES public.orders, status text
);
CREATE TABLE public.meinvoice_jobs (
  id uuid PRIMARY KEY, store_id uuid NOT NULL, order_id uuid,
  status text, error_message text, manual_action_type text, created_at timestamptz NOT NULL
);
CREATE TABLE public.photo_objet_sales (
  id uuid PRIMARY KEY, store_id uuid NOT NULL, sale_date date NOT NULL,
  gross_sales numeric, service_amount numeric, transaction_count integer
);
CREATE VIEW public.v_photo_objet_daily_summary WITH (security_invoker = true) AS
SELECT store_id, sale_date, sum(gross_sales) AS total_gross_sales,
  sum(service_amount) AS total_service_amount, sum(transaction_count) AS total_transactions
FROM public.photo_objet_sales GROUP BY store_id, sale_date;
CREATE FUNCTION public.get_store_sales_cancellation_total(
  p_store_id uuid, p_start_at timestamptz, p_end_at timestamptz
) RETURNS numeric LANGUAGE sql STABLE AS $$ SELECT 7::numeric $$;

ALTER TABLE public.store_employees ENABLE ROW LEVEL SECURITY;
CREATE POLICY employees_read ON public.store_employees FOR SELECT TO authenticated
  USING (public.fixture_can_manage(store_id));
ALTER TABLE public.employee_daily_allowances ENABLE ROW LEVEL SECURITY;
CREATE POLICY allowances_read ON public.employee_daily_allowances FOR SELECT TO authenticated
  USING (public.fixture_can_manage(store_id));
ALTER TABLE public.vietnam_public_holidays ENABLE ROW LEVEL SECURITY;
CREATE POLICY holidays_read ON public.vietnam_public_holidays FOR SELECT TO authenticated USING (true);
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY orders_read ON public.orders FOR SELECT TO authenticated
  USING (public.fixture_can_read(restaurant_id));
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
CREATE POLICY payments_read ON public.payments FOR SELECT TO authenticated
  USING (public.fixture_can_read(restaurant_id));
ALTER TABLE public.external_sales ENABLE ROW LEVEL SECURITY;
CREATE POLICY external_read ON public.external_sales FOR SELECT TO authenticated
  USING (public.fixture_can_read(restaurant_id));
ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY items_read ON public.order_items FOR SELECT TO authenticated USING
  (EXISTS (SELECT 1 FROM public.orders o WHERE o.id = order_id));
ALTER TABLE public.meinvoice_jobs ENABLE ROW LEVEL SECURITY;
CREATE POLICY jobs_read ON public.meinvoice_jobs FOR SELECT TO authenticated
  USING (public.fixture_can_read(store_id));
ALTER TABLE public.photo_objet_sales ENABLE ROW LEVEL SECURITY;
CREATE POLICY photo_read ON public.photo_objet_sales FOR SELECT TO authenticated
  USING (public.fixture_can_read(store_id));
GRANT USAGE ON SCHEMA auth TO authenticated;
GRANT SELECT ON public.store_employees, public.employee_daily_allowances,
  public.vietnam_public_holidays, public.orders, public.payments, public.external_sales,
  public.order_items, public.meinvoice_jobs, public.photo_objet_sales,
  public.v_photo_objet_daily_summary TO authenticated;
