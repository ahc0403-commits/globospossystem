BEGIN;

-- production-gate: self-verifying

-- ensure_digital_receipt inserts one immutable snapshot. Rewrite only the
-- newly inserted snapshot's display labels from the order-time menu relation,
-- while preserving every amount, quantity, VAT and payment field it produced.
CREATE OR REPLACE FUNCTION public.digital_receipt_force_vietnamese_items()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $$
DECLARE
  v_items jsonb;
BEGIN
  WITH snapshot_item AS (
    SELECT raw.value, raw.ordinality
    FROM jsonb_array_elements(COALESCE(NEW.snapshot->'items', '[]'::jsonb))
      WITH ORDINALITY AS raw(value, ordinality)
  ), ordered_item AS (
    SELECT item.id, item.menu_item_id,
      row_number() OVER (ORDER BY item.created_at, item.id) AS ordinality
    FROM public.order_items item
    WHERE item.order_id = NEW.order_id
      AND item.status <> 'cancelled'
  )
  SELECT COALESCE(
    jsonb_agg(
      snapshot_item.value || jsonb_build_object(
        'label', COALESCE(NULLIF(menu.name_vi, ''), 'Món')
      )
      ORDER BY snapshot_item.ordinality
    ),
    '[]'::jsonb
  )
  INTO v_items
  FROM snapshot_item
  LEFT JOIN ordered_item
    ON ordered_item.ordinality = snapshot_item.ordinality
  LEFT JOIN public.menu_items menu
    ON menu.id = ordered_item.menu_item_id;

  NEW.snapshot := jsonb_set(NEW.snapshot, '{items}', v_items, true);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS digital_receipt_force_vietnamese_items_trigger
  ON public.digital_receipts;
CREATE TRIGGER digital_receipt_force_vietnamese_items_trigger
BEFORE INSERT ON public.digital_receipts
FOR EACH ROW
EXECUTE FUNCTION public.digital_receipt_force_vietnamese_items();

REVOKE ALL ON FUNCTION public.digital_receipt_force_vietnamese_items()
  FROM PUBLIC, anon, authenticated;

DO $$
DECLARE
  v_trigger_enabled "char";
  v_function_definition text;
BEGIN
  SELECT trigger.tgenabled
  INTO v_trigger_enabled
  FROM pg_catalog.pg_trigger trigger
  WHERE trigger.tgrelid = 'public.digital_receipts'::regclass
    AND trigger.tgname = 'digital_receipt_force_vietnamese_items_trigger'
    AND NOT trigger.tgisinternal;

  IF v_trigger_enabled IS DISTINCT FROM 'O'::"char" THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_VI_TRIGGER_VERIFICATION_FAILED';
  END IF;

  SELECT pg_catalog.pg_get_functiondef(
    'public.digital_receipt_force_vietnamese_items()'::regprocedure
  )
  INTO v_function_definition;

  IF v_function_definition NOT LIKE '%name_vi%'
     OR v_function_definition NOT LIKE '%Món%' THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_VI_ITEMS_VERIFICATION_FAILED';
  END IF;
END;
$$;

COMMIT;
