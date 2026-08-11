BEGIN;

CREATE OR REPLACE FUNCTION public.issue_digital_receipt_link(
  p_receipt_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_receipt public.digital_receipts%ROWTYPE;
  v_token text;
  v_link_id uuid;
  v_expires_at timestamptz;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND OR v_actor.role NOT IN (
    'cashier', 'customer_display', 'admin', 'store_admin',
    'brand_admin', 'super_admin'
  ) THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_LINK_FORBIDDEN';
  END IF;

  SELECT * INTO v_receipt
  FROM public.digital_receipts
  WHERE id = p_receipt_id AND revoked_at IS NULL
  FOR UPDATE;
  IF NOT FOUND OR (
    NOT public.is_super_admin() AND NOT EXISTS (
      SELECT 1 FROM public.user_accessible_stores(auth.uid()) scope(store_id)
      WHERE scope.store_id = v_receipt.restaurant_id
    )
  ) THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_LINK_FORBIDDEN';
  END IF;

  v_token := rtrim(translate(
    encode(extensions.gen_random_bytes(24), 'base64'), '+/', '-_'
  ), '=');

  UPDATE public.digital_receipt_links
  SET revoked_at = COALESCE(revoked_at, now())
  WHERE id IN (
    SELECT link.id
    FROM public.digital_receipt_links link
    WHERE link.digital_receipt_id = v_receipt.id
      AND link.revoked_at IS NULL
      AND link.expires_at > now()
    ORDER BY link.created_at DESC, link.id DESC
    OFFSET 2
  );

  INSERT INTO public.digital_receipt_links (
    digital_receipt_id, token_hash
  ) VALUES (
    v_receipt.id, extensions.digest(v_token, 'sha256')
  ) RETURNING id, expires_at INTO v_link_id, v_expires_at;

  RETURN jsonb_build_object(
    'receipt_id', v_receipt.id,
    'link_id', v_link_id,
    'token', v_token,
    'expires_at', v_expires_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_public_receipt(
  p_token text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_snapshot jsonb;
  v_receipt_id uuid;
  v_issued_at timestamptz;
  v_expires_at timestamptz;
  v_link_id uuid;
BEGIN
  IF COALESCE(p_token, '') !~ '^[A-Za-z0-9_-]{32}$' THEN
    RETURN NULL;
  END IF;

  SELECT receipt.snapshot, receipt.id, receipt.created_at,
    link.expires_at, link.id
  INTO v_snapshot, v_receipt_id, v_issued_at, v_expires_at, v_link_id
  FROM public.digital_receipt_links link
  JOIN public.digital_receipts receipt
    ON receipt.id = link.digital_receipt_id
  WHERE link.token_hash = extensions.digest(p_token, 'sha256')
    AND link.revoked_at IS NULL
    AND link.expires_at > now()
    AND receipt.revoked_at IS NULL
  LIMIT 1;

  IF NOT FOUND THEN RETURN NULL; END IF;

  UPDATE public.digital_receipt_links
  SET last_presented_at = now()
  WHERE id = v_link_id
    AND (
      last_presented_at IS NULL
      OR last_presented_at < now() - interval '1 day'
    );

  RETURN v_snapshot || jsonb_build_object(
    'receipt_id', v_receipt_id,
    'issued_at', v_issued_at,
    'link_expires_at', v_expires_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.issue_digital_receipt_link(uuid)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_public_receipt(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.issue_digital_receipt_link(uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_public_receipt(text)
  TO service_role;

SELECT pg_notify('pgrst', 'reload schema');

COMMIT;
