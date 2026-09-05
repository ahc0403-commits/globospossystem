-- Synthetic fixture only; not a full production schema or authorization model.
DO $$ BEGIN
  IF current_database()<>'payroll_test' THEN RAISE EXCEPTION 'TEST_DATABASE_REQUIRED'; END IF;
END $$;
CREATE TABLE IF NOT EXISTS public.emergency_fulfillment_items (
  id uuid PRIMARY KEY, session_id uuid, order_id uuid, queue_id uuid,
  order_item_id uuid, created_at timestamptz, is_cancelled boolean,
  ordered_quantity integer, kitchen_done_quantity integer
);
CREATE INDEX IF NOT EXISTS emergency_items_order ON public.emergency_fulfillment_items(session_id,order_id);
CREATE INDEX IF NOT EXISTS idx_payments_restaurant ON public.payments(restaurant_id);
CREATE INDEX IF NOT EXISTS orders_store_status_created_id ON public.orders(restaurant_id,status,created_at,id);
CREATE INDEX IF NOT EXISTS order_items_order_id_idx ON public.order_items(order_id);
CREATE INDEX IF NOT EXISTS external_sales_store_completed ON public.external_sales(restaurant_id,completed_at);
CREATE INDEX IF NOT EXISTS photo_sales_store_date ON public.photo_objet_sales(store_id,sale_date);
CREATE INDEX IF NOT EXISTS meinvoice_jobs_store_created ON public.meinvoice_jobs(store_id,created_at);
-- Extracted KDS queue item read, not a replacement for the full station RPC.
CREATE OR REPLACE FUNCTION public.fixture_kds_queue_items(p_queue_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'order_item_id',order_item_id,
    'created_at',created_at,'ordered_quantity',ordered_quantity,
    'kitchen_done_quantity',kitchen_done_quantity) ORDER BY created_at,order_item_id),'[]'::jsonb)
  FROM public.emergency_fulfillment_items WHERE queue_id=p_queue_id AND is_cancelled=false
$$;
GRANT SELECT ON public.emergency_fulfillment_items TO authenticated;
GRANT EXECUTE ON FUNCTION public.fixture_kds_queue_items(uuid) TO authenticated;
