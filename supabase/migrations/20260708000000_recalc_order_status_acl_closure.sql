BEGIN;

-- F-1/M-1 closure: recalc_order_status is an internal derivation helper.
-- Client-callable RPCs may invoke it through SECURITY DEFINER owner privileges,
-- but anon/authenticated clients must not execute it directly.
REVOKE EXECUTE ON FUNCTION public.recalc_order_status(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.recalc_order_status(uuid)
  TO service_role;

COMMIT;
