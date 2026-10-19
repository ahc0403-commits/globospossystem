BEGIN;

SET LOCAL lock_timeout = '5s';

DO $rollback_non_revenue_checkout_concurrency$
DECLARE
  v_definition text;
BEGIN
  IF to_regclass(
       'public.non_revenue_checkout_20260923010000_backup'
     ) IS NULL THEN
    RAISE EXCEPTION 'NON_REVENUE_CONCURRENCY_ROLLBACK_BACKUP_MISSING';
  END IF;

  DROP FUNCTION public.add_items_to_order(uuid, uuid, jsonb);
  ALTER FUNCTION public.add_items_to_order_before_non_revenue_guard(
    uuid, uuid, jsonb
  ) RENAME TO add_items_to_order;

  DROP FUNCTION public.qr_place_order(text, jsonb, uuid, boolean, uuid);
  ALTER FUNCTION public.qr_place_order_before_non_revenue_guard(
    text, jsonb, uuid, boolean, uuid
  ) RENAME TO qr_place_order;

  FOR v_definition IN
    SELECT definition
    FROM public.non_revenue_checkout_20260923010000_backup
    WHERE object_identity IN (
      'public.process_payment(uuid,uuid,numeric,text)',
      'public.process_non_revenue_payment(uuid,uuid,numeric,text,text,text,text)'
    )
    ORDER BY object_identity
  LOOP
    EXECUTE v_definition;
  END LOOP;
END;
$rollback_non_revenue_checkout_concurrency$;

REVOKE ALL ON FUNCTION public.process_payment(uuid, uuid, numeric, text)
FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.process_payment(uuid, uuid, numeric, text)
TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.process_non_revenue_payment(
  uuid, uuid, numeric, text, text, text, text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_non_revenue_payment(
  uuid, uuid, numeric, text, text, text, text
) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.add_items_to_order(uuid, uuid, jsonb)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_items_to_order(uuid, uuid, jsonb)
TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.qr_place_order(
  text, jsonb, uuid, boolean, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qr_place_order(
  text, jsonb, uuid, boolean, uuid
) TO anon, authenticated, service_role;

DROP TABLE public.non_revenue_checkout_20260923010000_backup;

COMMIT;
