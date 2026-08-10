-- Every kitchen print event must immediately produce a cooking ticket and a
-- tray ticket. The tray route falls back to the kitchen printer when a
-- dedicated tray destination is not configured.
-- production-gate: self-verifying

CREATE OR REPLACE FUNCTION public.enqueue_tray_copy_for_kitchen_job()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $$
DECLARE
  v_destination_id uuid;
  v_status text := 'pending';
  v_error text;
BEGIN
  IF NEW.copy_type <> 'kitchen' THEN
    RETURN NEW;
  END IF;

  SELECT destination.id
  INTO v_destination_id
  FROM public.printer_destinations destination
  WHERE destination.restaurant_id = NEW.restaurant_id
    AND destination.purpose = 'tray'
    AND destination.is_active = true
  ORDER BY destination.created_at, destination.id
  LIMIT 1;

  v_destination_id := COALESCE(v_destination_id, NEW.destination_id);
  IF v_destination_id IS NULL THEN
    v_status := 'failed';
    v_error := 'NO_DESTINATION';
  END IF;

  INSERT INTO public.print_jobs(
    restaurant_id,
    order_id,
    copy_type,
    batch_no,
    destination_id,
    payload,
    status,
    last_error
  )
  VALUES (
    NEW.restaurant_id,
    NEW.order_id,
    'tray',
    NEW.batch_no,
    v_destination_id,
    jsonb_set(NEW.payload, '{ticket}', to_jsonb('tray'::text), true),
    v_status,
    v_error
  )
  ON CONFLICT DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS print_jobs_enqueue_immediate_tray
  ON public.print_jobs;
CREATE TRIGGER print_jobs_enqueue_immediate_tray
AFTER INSERT ON public.print_jobs
FOR EACH ROW
EXECUTE FUNCTION public.enqueue_tray_copy_for_kitchen_job();

-- Tray tickets are now created together with kitchen tickets. Recalculate
-- order state without creating another tray ticket when cooking finishes.
CREATE OR REPLACE FUNCTION public.recalc_order_status(
  p_order_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_active int;
  v_done int;
  v_started int;
  v_next text;
BEGIN
  SELECT *
  INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RETURN;
  END IF;

  SELECT
    count(*) FILTER (WHERE status <> 'cancelled'),
    count(*) FILTER (WHERE status IN ('ready', 'served')),
    count(*) FILTER (WHERE status IN ('preparing', 'ready', 'served'))
  INTO v_active, v_done, v_started
  FROM public.order_items
  WHERE order_id = p_order_id;

  IF v_active = 0 THEN
    v_next := 'cancelled';
  ELSIF v_done = v_active THEN
    v_next := 'serving';
  ELSIF v_started > 0 THEN
    v_next := 'confirmed';
  ELSE
    v_next := 'pending';
  END IF;

  IF v_next = v_order.status THEN
    UPDATE public.orders SET updated_at = now() WHERE id = p_order_id;
    RETURN;
  END IF;

  UPDATE public.orders
  SET status = v_next,
      updated_at = now()
  WHERE id = p_order_id;

  IF v_next = 'cancelled' AND v_order.table_id IS NOT NULL THEN
    UPDATE public.tables
    SET status = 'available',
        updated_at = now()
    WHERE id = v_order.table_id
      AND NOT EXISTS (
        SELECT 1
        FROM public.orders other_order
        WHERE other_order.table_id = v_order.table_id
          AND other_order.id <> p_order_id
          AND other_order.status IN ('pending', 'confirmed', 'serving')
      );
  END IF;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'recalc_order_status',
    'orders',
    p_order_id,
    jsonb_build_object(
      'from_status', v_order.status,
      'to_status', v_next
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_tray_copy_for_kitchen_job()
  FROM PUBLIC, anon, authenticated;

DO $$
DECLARE
  v_trigger_enabled "char";
  v_recalc_definition text;
BEGIN
  SELECT trigger.tgenabled
  INTO v_trigger_enabled
  FROM pg_catalog.pg_trigger trigger
  WHERE trigger.tgrelid = 'public.print_jobs'::regclass
    AND trigger.tgname = 'print_jobs_enqueue_immediate_tray'
    AND NOT trigger.tgisinternal;

  IF v_trigger_enabled IS DISTINCT FROM 'O'::"char" THEN
    RAISE EXCEPTION 'IMMEDIATE_KITCHEN_TRAY_TRIGGER_VERIFICATION_FAILED';
  END IF;

  SELECT pg_catalog.pg_get_functiondef(
    'public.recalc_order_status(uuid)'::regprocedure
  )
  INTO v_recalc_definition;

  IF v_recalc_definition LIKE '%ARRAY[''tray'']%' THEN
    RAISE EXCEPTION 'LATE_TRAY_DUPLICATE_GUARD_VERIFICATION_FAILED';
  END IF;
END;
$$;
