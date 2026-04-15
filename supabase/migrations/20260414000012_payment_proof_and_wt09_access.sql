BEGIN;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'payment-proofs',
  'payment-proofs',
  false,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS storage_payment_proofs_scoped ON storage.objects;
CREATE POLICY storage_payment_proofs_scoped ON storage.objects
FOR ALL TO authenticated
USING (
  bucket_id = 'payment-proofs'
  AND (
    EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id::text = (storage.foldername(name))[2]
    )
    OR EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.auth_id = auth.uid()
        AND u.role = 'super_admin'
    )
  )
)
WITH CHECK (
  bucket_id = 'payment-proofs'
  AND (
    EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id::text = (storage.foldername(name))[2]
    )
    OR EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.auth_id = auth.uid()
        AND u.role = 'super_admin'
    )
  )
);

CREATE OR REPLACE FUNCTION public.mark_payment_proof_required(
  p_payment_id uuid,
  p_store_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_payment public.payments%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'PAYMENT_PROOF_FORBIDDEN';
  END IF;

  IF p_payment_id IS NULL OR p_store_id IS NULL THEN
    RAISE EXCEPTION 'PAYMENT_PROOF_INVALID';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_payment
  FROM public.payments
  WHERE id = p_payment_id
    AND restaurant_id = p_store_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PAYMENT_NOT_FOUND';
  END IF;

  UPDATE public.payments
  SET proof_required = TRUE
  WHERE id = v_payment.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'mark_payment_proof_required',
    'payments',
    v_payment.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', v_payment.order_id,
      'method', v_payment.method
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'payment_id', v_payment.id,
    'proof_required', true
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.attach_payment_proof(
  p_payment_id uuid,
  p_store_id uuid,
  p_proof_photo_url text,
  p_taken_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_payment public.payments%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'PAYMENT_PROOF_FORBIDDEN';
  END IF;

  IF p_payment_id IS NULL OR p_store_id IS NULL OR COALESCE(trim(p_proof_photo_url), '') = '' THEN
    RAISE EXCEPTION 'PAYMENT_PROOF_INVALID';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_payment
  FROM public.payments
  WHERE id = p_payment_id
    AND restaurant_id = p_store_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PAYMENT_NOT_FOUND';
  END IF;

  UPDATE public.payments
  SET proof_required = TRUE,
      proof_photo_url = p_proof_photo_url,
      proof_photo_taken_at = COALESCE(p_taken_at, now()),
      proof_photo_by = v_actor.id
  WHERE id = v_payment.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'attach_payment_proof',
    'payments',
    v_payment.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', v_payment.order_id,
      'proof_photo_url', p_proof_photo_url
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'payment_id', v_payment.id,
    'proof_photo_url', p_proof_photo_url
  );
END;
$$;

COMMIT;
