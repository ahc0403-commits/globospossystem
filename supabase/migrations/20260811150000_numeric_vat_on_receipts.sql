BEGIN;

-- production-gate: self-verifying

CREATE OR REPLACE FUNCTION public.attach_cashier_receipt_vat_payload()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $$
DECLARE
  v_vat_amount numeric(15,2) := 0;
BEGIN
  IF NEW.copy_type <> 'receipt' OR NEW.order_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT ROUND(COALESCE(SUM(oi.vat_amount), 0), 2)
  INTO v_vat_amount
  FROM public.order_items oi
  WHERE oi.order_id = NEW.order_id
    AND oi.status <> 'cancelled'
    AND NOT COALESCE(oi.is_service_item, false);

  NEW.payload := NEW.payload || jsonb_build_object(
    'vat_amount', v_vat_amount
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enrich_cashier_receipt_vat_payload_trigger
  ON public.print_jobs;
CREATE TRIGGER enrich_cashier_receipt_vat_payload_trigger
BEFORE INSERT OR UPDATE OF payload ON public.print_jobs
FOR EACH ROW EXECUTE FUNCTION public.attach_cashier_receipt_vat_payload();

REVOKE ALL ON FUNCTION public.attach_cashier_receipt_vat_payload()
  FROM PUBLIC, anon, authenticated;

DO $$
DECLARE
  v_trigger_enabled "char";
  v_function_definition text;
BEGIN
  SELECT trigger.tgenabled
  INTO v_trigger_enabled
  FROM pg_catalog.pg_trigger trigger
  WHERE trigger.tgrelid = 'public.print_jobs'::regclass
    AND trigger.tgname = 'enrich_cashier_receipt_vat_payload_trigger'
    AND NOT trigger.tgisinternal;

  IF v_trigger_enabled IS DISTINCT FROM 'O'::"char" THEN
    RAISE EXCEPTION 'RECEIPT_VAT_TRIGGER_VERIFICATION_FAILED';
  END IF;

  SELECT pg_catalog.pg_get_functiondef(
    'public.attach_cashier_receipt_vat_payload()'::regprocedure
  )
  INTO v_function_definition;

  IF v_function_definition NOT LIKE '%SUM(oi.vat_amount)%'
     OR v_function_definition NOT LIKE '%''vat_amount''%' THEN
    RAISE EXCEPTION 'RECEIPT_VAT_PAYLOAD_VERIFICATION_FAILED';
  END IF;
END;
$$;

COMMIT;
