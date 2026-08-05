BEGIN;

CREATE TABLE IF NOT EXISTS public.sepay_bank_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  gateway text NOT NULL,
  account_number text NOT NULL,
  sub_account text,
  label text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sepay_bank_accounts_gateway_not_blank
    CHECK (btrim(gateway) <> ''),
  CONSTRAINT sepay_bank_accounts_number_not_blank
    CHECK (btrim(account_number) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS sepay_bank_accounts_provider_identity_idx
  ON public.sepay_bank_accounts (
    lower(btrim(gateway)),
    regexp_replace(account_number, '[^a-zA-Z0-9]', '', 'g'),
    COALESCE(
      regexp_replace(sub_account, '[^a-zA-Z0-9]', '', 'g'),
      ''
    )
  );

CREATE INDEX IF NOT EXISTS sepay_bank_accounts_store_idx
  ON public.sepay_bank_accounts (restaurant_id)
  WHERE is_active = true;

CREATE TABLE IF NOT EXISTS public.sepay_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sepay_transaction_id bigint NOT NULL UNIQUE,
  restaurant_id uuid REFERENCES public.restaurants(id) ON DELETE SET NULL,
  sepay_bank_account_id uuid
    REFERENCES public.sepay_bank_accounts(id) ON DELETE SET NULL,
  gateway text NOT NULL,
  account_number text NOT NULL,
  sub_account text,
  transfer_type text NOT NULL,
  transfer_amount bigint NOT NULL,
  payment_code text,
  reference_code text,
  transaction_at timestamptz,
  resolution_status text NOT NULL,
  raw_payload jsonb NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sepay_transactions_transfer_type_check
    CHECK (transfer_type IN ('in', 'out')),
  CONSTRAINT sepay_transactions_amount_check CHECK (transfer_amount > 0),
  CONSTRAINT sepay_transactions_resolution_check
    CHECK (resolution_status IN ('matched', 'unmatched', 'ambiguous'))
);

CREATE INDEX IF NOT EXISTS sepay_transactions_store_received_idx
  ON public.sepay_transactions (restaurant_id, received_at DESC)
  WHERE restaurant_id IS NOT NULL;

ALTER TABLE public.sepay_bank_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sepay_transactions ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.sepay_bank_accounts FROM anon, authenticated;
REVOKE ALL ON public.sepay_transactions FROM anon, authenticated;
GRANT ALL ON public.sepay_bank_accounts TO service_role;
GRANT ALL ON public.sepay_transactions TO service_role;

COMMENT ON TABLE public.sepay_bank_accounts IS
  'Server-only mapping from a SePay bank or VA identity to one POS store.';
COMMENT ON TABLE public.sepay_transactions IS
  'Verified SePay webhook ledger. Raw provider payload is server-only.';

CREATE OR REPLACE FUNCTION public.ingest_sepay_transaction(
  p_sepay_transaction_id bigint,
  p_gateway text,
  p_account_number text,
  p_sub_account text,
  p_transfer_type text,
  p_transfer_amount bigint,
  p_payment_code text,
  p_reference_code text,
  p_transaction_at timestamptz,
  p_raw_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_number text := regexp_replace(
    COALESCE(p_account_number, ''),
    '[^a-zA-Z0-9]',
    '',
    'g'
  );
  v_sub_account text := NULLIF(
    regexp_replace(COALESCE(p_sub_account, ''), '[^a-zA-Z0-9]', '', 'g'),
    ''
  );
  v_candidate_count integer := 0;
  v_mapping_id uuid;
  v_mapping public.sepay_bank_accounts%ROWTYPE;
  v_transaction public.sepay_transactions%ROWTYPE;
BEGIN
  IF p_sepay_transaction_id IS NULL
     OR btrim(COALESCE(p_gateway, '')) = ''
     OR v_account_number = ''
     OR p_transfer_type NOT IN ('in', 'out')
     OR COALESCE(p_transfer_amount, 0) <= 0
     OR p_raw_payload IS NULL THEN
    RAISE EXCEPTION 'SEPAY_TRANSACTION_INVALID';
  END IF;

  SELECT count(*), (array_agg(mapping.id))[1]
  INTO v_candidate_count, v_mapping_id
  FROM public.sepay_bank_accounts mapping
  WHERE mapping.is_active = true
    AND lower(btrim(mapping.gateway)) = lower(btrim(p_gateway))
    AND regexp_replace(
      mapping.account_number,
      '[^a-zA-Z0-9]',
      '',
      'g'
    ) = v_account_number
    AND COALESCE(
      NULLIF(
        regexp_replace(
          COALESCE(mapping.sub_account, ''),
          '[^a-zA-Z0-9]',
          '',
          'g'
        ),
        ''
      ),
      ''
    ) = COALESCE(v_sub_account, '');

  IF v_candidate_count = 1 THEN
    SELECT * INTO v_mapping
    FROM public.sepay_bank_accounts
    WHERE id = v_mapping_id;
  END IF;

  INSERT INTO public.sepay_transactions (
    sepay_transaction_id,
    restaurant_id,
    sepay_bank_account_id,
    gateway,
    account_number,
    sub_account,
    transfer_type,
    transfer_amount,
    payment_code,
    reference_code,
    transaction_at,
    resolution_status,
    raw_payload
  ) VALUES (
    p_sepay_transaction_id,
    CASE WHEN v_candidate_count = 1 THEN v_mapping.restaurant_id END,
    CASE WHEN v_candidate_count = 1 THEN v_mapping.id END,
    btrim(p_gateway),
    v_account_number,
    v_sub_account,
    p_transfer_type,
    p_transfer_amount,
    NULLIF(btrim(COALESCE(p_payment_code, '')), ''),
    NULLIF(btrim(COALESCE(p_reference_code, '')), ''),
    p_transaction_at,
    CASE
      WHEN v_candidate_count = 1 THEN 'matched'
      WHEN v_candidate_count = 0 THEN 'unmatched'
      ELSE 'ambiguous'
    END,
    p_raw_payload
  )
  ON CONFLICT (sepay_transaction_id) DO NOTHING
  RETURNING * INTO v_transaction;

  IF v_transaction.id IS NULL THEN
    SELECT * INTO v_transaction
    FROM public.sepay_transactions
    WHERE sepay_transaction_id = p_sepay_transaction_id;

    RETURN jsonb_build_object(
      'status', 'duplicate',
      'transaction_id', v_transaction.id,
      'restaurant_id', v_transaction.restaurant_id,
      'resolution_status', v_transaction.resolution_status
    );
  END IF;

  RETURN jsonb_build_object(
    'status', 'accepted',
    'transaction_id', v_transaction.id,
    'restaurant_id', v_transaction.restaurant_id,
    'resolution_status', v_transaction.resolution_status
  );
END;
$$;

REVOKE ALL ON FUNCTION public.ingest_sepay_transaction(
  bigint, text, text, text, text, bigint, text, text, timestamptz, jsonb
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ingest_sepay_transaction(
  bigint, text, text, text, text, bigint, text, text, timestamptz, jsonb
) TO service_role;

CREATE OR REPLACE FUNCTION public.get_latest_sepay_payment_alert(
  p_store_id uuid
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
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
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
  ORDER BY txn.received_at DESC, txn.sepay_transaction_id DESC
  LIMIT 1;
END;
$$;

REVOKE ALL ON FUNCTION public.get_latest_sepay_payment_alert(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_latest_sepay_payment_alert(uuid)
  TO authenticated;

DROP TRIGGER IF EXISTS pos_live_event_trigger
  ON public.sepay_transactions;
CREATE TRIGGER pos_live_event_trigger
AFTER INSERT ON public.sepay_transactions
FOR EACH ROW
WHEN (NEW.restaurant_id IS NOT NULL AND NEW.transfer_type = 'in')
EXECUTE FUNCTION public.emit_pos_live_event('bank_transfer');

COMMIT;
