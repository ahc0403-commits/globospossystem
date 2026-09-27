-- Lock a submitted receipt for its maker while retaining the independent
-- accountant's verification path and an inspectable before/after history.
BEGIN;

CREATE TABLE public.inventory_receipt_change_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_id uuid NOT NULL REFERENCES public.inventory_receipts(id),
  record_type text NOT NULL CHECK (record_type IN ('receipt', 'line')),
  record_id uuid NOT NULL,
  action text NOT NULL CHECK (action IN ('insert', 'update', 'delete')),
  previous_state jsonb,
  next_state jsonb,
  changed_by uuid DEFAULT auth.uid(),
  changed_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX inventory_receipt_change_history_receipt_time
  ON public.inventory_receipt_change_history(receipt_id, changed_at DESC, id);

ALTER TABLE public.inventory_receipt_change_history ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inventory_receipt_change_history FROM PUBLIC, anon;
GRANT SELECT ON public.inventory_receipt_change_history TO authenticated, service_role;
CREATE POLICY inventory_receipt_change_history_accounting_read
  ON public.inventory_receipt_change_history FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.inventory_receipts receipt
    WHERE receipt.id = receipt_id
      AND public.can_verify_inventory_receipt(receipt.restaurant_id)
  ));

CREATE FUNCTION public.guard_inventory_receipt_header_change()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'confirmed' OR OLD.submitted_at IS NOT NULL THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_SUBMITTED_LOCKED';
    END IF;
    RETURN OLD;
  END IF;

  IF OLD.status = 'confirmed' THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_CONFIRMED_IMMUTABLE';
  END IF;
  IF OLD.submitted_at IS NOT NULL
     AND NOT public.can_verify_inventory_receipt(OLD.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_SUBMITTED_LOCKED';
  END IF;
  IF NEW.submitted_at IS NOT NULL AND OLD IS DISTINCT FROM NEW THEN
    INSERT INTO public.inventory_receipt_change_history(
      receipt_id, record_type, record_id, action, previous_state, next_state
    ) VALUES (OLD.id, 'receipt', OLD.id, 'update', to_jsonb(OLD), to_jsonb(NEW));
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER inventory_receipt_header_change_guard
BEFORE UPDATE OR DELETE ON public.inventory_receipts
FOR EACH ROW EXECUTE FUNCTION public.guard_inventory_receipt_header_change();

CREATE FUNCTION public.guard_inventory_receipt_line_change()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth AS $$
DECLARE
  v_receipt public.inventory_receipts%ROWTYPE;
  v_receipt_id uuid := CASE WHEN TG_OP = 'INSERT' THEN NEW.receipt_id ELSE OLD.receipt_id END;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.receipt_id IS DISTINCT FROM OLD.receipt_id THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_LINE_REPARENT_FORBIDDEN';
  END IF;
  SELECT * INTO v_receipt FROM public.inventory_receipts
  WHERE id = v_receipt_id FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_NOT_FOUND'; END IF;
  IF v_receipt.status = 'confirmed' THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_CONFIRMED_IMMUTABLE';
  END IF;
  IF v_receipt.submitted_at IS NOT NULL
     AND NOT public.can_verify_inventory_receipt(v_receipt.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_SUBMITTED_LOCKED';
  END IF;
  IF v_receipt.submitted_at IS NOT NULL THEN
    INSERT INTO public.inventory_receipt_change_history(
      receipt_id, record_type, record_id, action, previous_state, next_state
    ) VALUES (
      v_receipt.id, 'line',
      CASE WHEN TG_OP = 'INSERT' THEN NEW.id ELSE OLD.id END,
      lower(TG_OP),
      CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE to_jsonb(OLD) END,
      CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE to_jsonb(NEW) END
    );
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE TRIGGER inventory_receipt_line_change_guard
BEFORE INSERT OR UPDATE OR DELETE ON public.inventory_receipt_lines
FOR EACH ROW EXECUTE FUNCTION public.guard_inventory_receipt_line_change();

REVOKE ALL ON FUNCTION public.guard_inventory_receipt_header_change()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.guard_inventory_receipt_line_change()
  FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
      WHERE tgrelid = 'public.inventory_receipts'::regclass
        AND tgname = 'inventory_receipt_header_change_guard'
        AND NOT tgisinternal)
     OR NOT EXISTS (SELECT 1 FROM pg_trigger
      WHERE tgrelid = 'public.inventory_receipt_lines'::regclass
        AND tgname = 'inventory_receipt_line_change_guard'
        AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_SUBMISSION_GUARD_MISSING';
  END IF;
END;
$$;

COMMIT;
