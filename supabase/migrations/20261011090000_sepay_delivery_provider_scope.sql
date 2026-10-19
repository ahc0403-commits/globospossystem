BEGIN;
CREATE OR REPLACE FUNCTION public.ingest_sepay_transaction_with_delivery_scope(
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
    'push_dispatch_required', EXISTS (
      SELECT 1 FROM public.sepay_alert_deliveries d JOIN public.sepay_alert_devices device ON device.id=d.device_id
      WHERE d.transaction_id=v_transaction.id AND d.status IN ('queued','failed')
        AND device.is_enabled AND device.push_provider='fcm'
    ),
    'transaction_id', v_transaction.id,
    'restaurant_id', v_transaction.restaurant_id,
    'resolution_status', v_transaction.resolution_status
  );
END;
$$;
REVOKE ALL ON FUNCTION public.ingest_sepay_transaction_with_delivery_scope(bigint,text,text,text,text,bigint,text,text,timestamptz,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ingest_sepay_transaction_with_delivery_scope(bigint,text,text,text,text,bigint,text,text,timestamptz,jsonb) TO service_role;
COMMIT;
