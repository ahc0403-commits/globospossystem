BEGIN;

CREATE OR REPLACE FUNCTION public.get_sepay_payment_alerts_after(
  p_store_id uuid,
  p_after_received_at timestamptz,
  p_after_provider_transaction_id bigint DEFAULT 0,
  p_limit integer DEFAULT 100
) RETURNS TABLE (
  transaction_id uuid,
  provider_transaction_id bigint,
  amount bigint,
  payment_code text,
  gateway text,
  transaction_at timestamptz,
  received_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  IF p_after_received_at IS NULL THEN
    RAISE EXCEPTION 'SEPAY_ALERT_CURSOR_REQUIRED';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) accessible(store_id)
       WHERE accessible.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_DENIED';
  END IF;

  RETURN QUERY
  SELECT
    txn.id,
    txn.sepay_transaction_id,
    txn.transfer_amount,
    txn.payment_code,
    txn.gateway,
    txn.transaction_at,
    txn.received_at
  FROM public.sepay_transactions txn
  WHERE txn.restaurant_id = p_store_id
    AND txn.transfer_type = 'in'
    AND txn.resolution_status = 'matched'
    AND (
      txn.received_at > p_after_received_at
      OR (
        txn.received_at = p_after_received_at
        AND txn.sepay_transaction_id > COALESCE(
          p_after_provider_transaction_id,
          0
        )
      )
    )
  ORDER BY txn.received_at ASC, txn.sepay_transaction_id ASC
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.get_sepay_payment_alerts_after(
  uuid, timestamptz, bigint, integer
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_sepay_payment_alerts_after(
  uuid, timestamptz, bigint, integer
) TO authenticated;

COMMENT ON FUNCTION public.get_sepay_payment_alerts_after(
  uuid, timestamptz, bigint, integer
) IS
  'Store-scoped ordered SePay alert backlog after a stable received/provider cursor.';

COMMIT;
