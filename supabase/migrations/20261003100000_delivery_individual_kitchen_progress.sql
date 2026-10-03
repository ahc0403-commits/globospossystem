-- Legacy delivery buttons update kitchen_done directly. The existing quantity
-- compatibility function must run for that column before the chain constraint.
-- production-gate: self-verifying
BEGIN;

DO $preflight$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.emergency_fulfillment_items'::regclass
      AND tgname = 'emergency_preserve_started_quantity_trigger'
      AND tgfoid = 'public.emergency_preserve_started_quantity()'::regprocedure
      AND NOT tgisinternal
  ) OR position('NEW.kitchen_started_quantity, NEW.kitchen_done_quantity' IN
    pg_get_functiondef('public.emergency_preserve_started_quantity()'::regprocedure)
  ) = 0 THEN
    RAISE EXCEPTION 'DELIVERY_KITCHEN_PROGRESS_PREDECESSOR_DRIFT';
  END IF;
END;
$preflight$;

DROP TRIGGER emergency_preserve_started_quantity_trigger
  ON public.emergency_fulfillment_items;
CREATE TRIGGER emergency_preserve_started_quantity_trigger
BEFORE INSERT OR UPDATE OF source_quantity, ordered_quantity,
  kitchen_started_quantity, kitchen_done_quantity, excused_quantity
ON public.emergency_fulfillment_items
FOR EACH ROW EXECUTE FUNCTION public.emergency_preserve_started_quantity();

DO $verify$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger trigger_row
    JOIN pg_attribute attribute_row
      ON attribute_row.attrelid = trigger_row.tgrelid
      AND attribute_row.attname = 'kitchen_done_quantity'
      AND attribute_row.attnum = ANY(trigger_row.tgattr::smallint[])
    WHERE trigger_row.tgrelid = 'public.emergency_fulfillment_items'::regclass
      AND trigger_row.tgname = 'emergency_preserve_started_quantity_trigger'
      AND trigger_row.tgfoid = 'public.emergency_preserve_started_quantity()'::regprocedure
      AND trigger_row.tgtype = 23 -- BEFORE ROW INSERT/UPDATE
      AND trigger_row.tgenabled = 'O'
  ) THEN
    RAISE EXCEPTION 'DELIVERY_KITCHEN_PROGRESS_TRIGGER_VERIFICATION_FAILED';
  END IF;
END;
$verify$;
COMMIT;
