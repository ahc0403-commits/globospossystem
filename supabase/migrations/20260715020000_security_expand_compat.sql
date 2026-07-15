BEGIN;

-- Expand phase only. Legacy RPCs and verifier visibility intentionally remain
-- available until a separately approved Contract release.

CREATE TABLE IF NOT EXISTS public.payment_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  store_id uuid NOT NULL REFERENCES public.restaurants(id),
  attempt_id uuid NOT NULL,
  requested_amount numeric(15,2) NOT NULL CHECK (requested_amount > 0),
  requested_method text NOT NULL,
  actor_auth_id uuid NOT NULL,
  payment_id uuid REFERENCES public.payments(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz
);

DO $guard$
DECLARE
  v_required_columns integer;
BEGIN
  IF pg_catalog.to_regclass('public.payment_attempts') IS NULL THEN
    RAISE EXCEPTION 'SECURITY_EXPAND_PAYMENT_ATTEMPTS_MISSING';
  END IF;

  SELECT count(*)
  INTO v_required_columns
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'payment_attempts'
    AND (
      (column_name = 'id' AND udt_name = 'uuid' AND is_nullable = 'NO') OR
      (column_name = 'order_id' AND udt_name = 'uuid' AND is_nullable = 'NO') OR
      (column_name = 'store_id' AND udt_name = 'uuid' AND is_nullable = 'NO') OR
      (column_name = 'attempt_id' AND udt_name = 'uuid' AND is_nullable = 'NO') OR
      (column_name = 'requested_amount' AND udt_name = 'numeric' AND is_nullable = 'NO') OR
      (column_name = 'requested_method' AND udt_name = 'text' AND is_nullable = 'NO') OR
      (column_name = 'actor_auth_id' AND udt_name = 'uuid' AND is_nullable = 'NO') OR
      (column_name = 'payment_id' AND udt_name = 'uuid') OR
      (column_name = 'created_at' AND udt_name = 'timestamptz' AND is_nullable = 'NO') OR
      (column_name = 'completed_at' AND udt_name = 'timestamptz')
    );

  IF v_required_columns <> 10 THEN
    RAISE EXCEPTION 'SECURITY_EXPAND_PAYMENT_ATTEMPTS_INCOMPATIBLE';
  END IF;
END;
$guard$;

ALTER TABLE public.payment_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_attempts FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.payment_attempts FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.payment_attempts TO service_role;

CREATE INDEX IF NOT EXISTS idx_payment_attempts_payment_id
  ON public.payment_attempts(payment_id);
CREATE UNIQUE INDEX IF NOT EXISTS payment_attempts_order_attempt_uidx
  ON public.payment_attempts(order_id, attempt_id);

DO $guard$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_indexes
    WHERE schemaname = 'public'
      AND tablename = 'payment_attempts'
      AND indexname = 'payment_attempts_order_attempt_uidx'
      AND indexdef LIKE '%UNIQUE INDEX%'
      AND indexdef LIKE '%(order_id, attempt_id)%'
  ) THEN
    RAISE EXCEPTION 'SECURITY_EXPAND_PAYMENT_ATTEMPT_INDEX_INCOMPATIBLE';
  END IF;
END;
$guard$;

CREATE OR REPLACE FUNCTION public.process_payment(
  p_order_id uuid,
  p_store_id uuid,
  p_amount numeric,
  p_method text,
  p_payment_attempt_id uuid
)
RETURNS public.payments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_attempt public.payment_attempts%ROWTYPE;
  v_payment public.payments%ROWTYPE;
BEGIN
  IF p_order_id IS NULL OR p_store_id IS NULL OR p_payment_attempt_id IS NULL THEN
    RAISE EXCEPTION 'PAYMENT_ATTEMPT_REQUIRED';
  END IF;
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'PAYMENT_FORBIDDEN';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_order_id::text || ':' || p_payment_attempt_id::text, 0)
  );

  SELECT *
  INTO v_attempt
  FROM public.payment_attempts
  WHERE order_id = p_order_id
    AND attempt_id = p_payment_attempt_id
  FOR UPDATE;

  IF FOUND THEN
    IF v_attempt.store_id <> p_store_id
       OR v_attempt.requested_amount <> p_amount
       OR v_attempt.requested_method <> p_method
       OR v_attempt.actor_auth_id <> auth.uid() THEN
      RAISE EXCEPTION 'PAYMENT_ATTEMPT_MISMATCH';
    END IF;
    IF v_attempt.payment_id IS NULL THEN
      RAISE EXCEPTION 'PAYMENT_ATTEMPT_INCOMPLETE';
    END IF;

    SELECT *
    INTO v_payment
    FROM public.payments
    WHERE id = v_attempt.payment_id
      AND order_id = p_order_id
      AND restaurant_id = p_store_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'PAYMENT_ATTEMPT_CORRUPT';
    END IF;
    RETURN v_payment;
  END IF;

  INSERT INTO public.payment_attempts (
    order_id, store_id, attempt_id, requested_amount, requested_method, actor_auth_id
  ) VALUES (
    p_order_id, p_store_id, p_payment_attempt_id, p_amount, p_method, auth.uid()
  )
  RETURNING * INTO v_attempt;

  SELECT *
  INTO v_payment
  FROM public.process_payment(p_order_id, p_store_id, p_amount, p_method);

  UPDATE public.payment_attempts
  SET payment_id = v_payment.id,
      completed_at = now()
  WHERE id = v_attempt.id;

  RETURN v_payment;
END;
$$;

REVOKE ALL ON FUNCTION public.process_payment(uuid, uuid, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_payment(uuid, uuid, numeric, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.process_payment(uuid, uuid, numeric, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_payment(uuid, uuid, numeric, text, uuid) TO authenticated, service_role;

COMMENT ON FUNCTION public.process_payment(uuid, uuid, numeric, text, uuid) IS
  'Expand-phase idempotent payment boundary. The authenticated four-argument overload remains until Contract.';

ALTER TABLE public.payments
  ADD COLUMN IF NOT EXISTS proof_object_path text;

DO $guard$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'payments'
      AND column_name = 'proof_object_path'
      AND udt_name = 'text'
  ) THEN
    RAISE EXCEPTION 'SECURITY_EXPAND_PROOF_PATH_INCOMPATIBLE';
  END IF;
END;
$guard$;

COMMENT ON COLUMN public.payments.proof_object_path IS
  'Private payment-proofs Storage object path; read with the caller JWT and Storage RLS.';

CREATE OR REPLACE FUNCTION public.attach_payment_proof_v2(
  p_payment_id uuid,
  p_store_id uuid,
  p_proof_object_path text,
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
  IF p_payment_id IS NULL
     OR p_store_id IS NULL
     OR COALESCE(pg_catalog.btrim(p_proof_object_path), '') = ''
     OR p_proof_object_path LIKE '%..%'
     OR p_proof_object_path ~ '^[a-zA-Z][a-zA-Z0-9+.-]*:'
     OR split_part(p_proof_object_path, '/', 2) <> p_store_id::text
     OR split_part(p_proof_object_path, '/', 3) !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
     OR split_part(p_proof_object_path, '/', 4) <> p_payment_id::text || '.jpg'
     OR array_length(string_to_array(p_proof_object_path, '/'), 1) <> 4 THEN
    RAISE EXCEPTION 'PAYMENT_PROOF_INVALID';
  END IF;
  IF NOT public.is_super_admin()
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
      proof_object_path = p_proof_object_path,
      proof_photo_taken_at = COALESCE(p_taken_at, now()),
      proof_photo_by = v_actor.id
  WHERE id = v_payment.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'attach_payment_proof_v2',
    'payments',
    v_payment.id,
    jsonb_build_object('store_id', p_store_id, 'order_id', v_payment.order_id)
  );

  RETURN jsonb_build_object(
    'ok', true,
    'payment_id', v_payment.id,
    'proof_object_path', p_proof_object_path
  );
END;
$$;

REVOKE ALL ON FUNCTION public.attach_payment_proof_v2(uuid, uuid, text, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.attach_payment_proof_v2(uuid, uuid, text, timestamptz) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.attach_payment_proof(uuid, uuid, text, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.attach_payment_proof(uuid, uuid, text, timestamptz) TO authenticated, service_role;

CREATE TABLE IF NOT EXISTS public.payroll_pin_rate_limits (
  actor_auth_id uuid NOT NULL,
  store_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  window_started_at timestamptz NOT NULL DEFAULT now(),
  failed_attempts integer NOT NULL DEFAULT 0 CHECK (failed_attempts >= 0),
  locked_until timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (actor_auth_id, store_id)
);

ALTER TABLE public.payroll_pin_rate_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payroll_pin_rate_limits FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.payroll_pin_rate_limits FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.payroll_pin_rate_limits TO service_role;

ALTER TABLE public.restaurant_settings
  ADD COLUMN IF NOT EXISTS payroll_pin_verifier text;

DO $guard$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'restaurant_settings'
      AND column_name = 'payroll_pin_verifier'
      AND udt_name = 'text'
  ) THEN
    RAISE EXCEPTION 'SECURITY_EXPAND_PIN_VERIFIER_INCOMPATIBLE';
  END IF;
END;
$guard$;

REVOKE SELECT ON public.restaurant_settings FROM PUBLIC, anon, authenticated;
GRANT SELECT (id, restaurant_id, payroll_pin, settings_json, updated_at)
  ON public.restaurant_settings TO authenticated;

CREATE OR REPLACE FUNCTION public.clear_payroll_pin_verifier_on_legacy_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.payroll_pin IS DISTINCT FROM OLD.payroll_pin THEN
    NEW.payroll_pin_verifier := NULL;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.clear_payroll_pin_verifier_on_legacy_change() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS clear_payroll_pin_verifier_on_legacy_change ON public.restaurant_settings;
CREATE TRIGGER clear_payroll_pin_verifier_on_legacy_change
BEFORE UPDATE OF payroll_pin ON public.restaurant_settings
FOR EACH ROW
EXECUTE FUNCTION public.clear_payroll_pin_verifier_on_legacy_change();

CREATE OR REPLACE FUNCTION public.set_payroll_pin_v2(
  p_store_id uuid,
  p_pin text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_settings_id uuid;
  v_legacy_hash text;
  v_bcrypt_hash text;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_ID_REQUIRED';
  END IF;
  IF p_pin !~ '^[0-9]{4}$' THEN
    RAISE EXCEPTION 'PAYROLL_PIN_FORMAT_INVALID';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);
  v_legacy_hash := encode(extensions.digest(p_pin, 'sha256'), 'hex');
  v_bcrypt_hash := extensions.crypt(
    p_pin,
    extensions.gen_salt('bf', 10)
  );

  INSERT INTO public.restaurant_settings (
    restaurant_id, payroll_pin, payroll_pin_verifier, updated_at
  ) VALUES (
    p_store_id, v_legacy_hash, v_bcrypt_hash, now()
  )
  ON CONFLICT (restaurant_id)
  DO UPDATE SET payroll_pin = EXCLUDED.payroll_pin,
                updated_at = now()
  RETURNING id INTO v_settings_id;

  UPDATE public.restaurant_settings
  SET payroll_pin_verifier = v_bcrypt_hash,
      updated_at = now()
  WHERE id = v_settings_id;

  DELETE FROM public.payroll_pin_rate_limits
  WHERE actor_auth_id = auth.uid()
    AND store_id = p_store_id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'set_payroll_pin_v2', 'restaurant_settings', v_settings_id,
    jsonb_build_object('store_id', p_store_id, 'updated_at_utc', now())
  );
  RETURN jsonb_build_object('ok', true, 'has_pin', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.clear_payroll_pin_v2(p_store_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_settings_id uuid;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_ID_REQUIRED';
  END IF;
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  INSERT INTO public.restaurant_settings (
    restaurant_id, payroll_pin, payroll_pin_verifier, updated_at
  ) VALUES (
    p_store_id, NULL, NULL, now()
  )
  ON CONFLICT (restaurant_id)
  DO UPDATE SET payroll_pin = NULL,
                payroll_pin_verifier = NULL,
                updated_at = now()
  RETURNING id INTO v_settings_id;

  DELETE FROM public.payroll_pin_rate_limits WHERE store_id = p_store_id;
  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'clear_payroll_pin_v2', 'restaurant_settings', v_settings_id,
    jsonb_build_object('store_id', p_store_id, 'updated_at_utc', now())
  );
  RETURN jsonb_build_object('ok', true, 'has_pin', false);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_payroll_pin_status(p_store_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_has_pin boolean;
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);
  SELECT COALESCE(NULLIF(payroll_pin_verifier, ''), NULLIF(payroll_pin, '')) IS NOT NULL
  INTO v_has_pin
  FROM public.restaurant_settings
  WHERE restaurant_id = p_store_id;
  RETURN jsonb_build_object('has_pin', COALESCE(v_has_pin, false));
END;
$$;

CREATE OR REPLACE FUNCTION public.verify_payroll_pin(
  p_store_id uuid,
  p_pin text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_rate public.payroll_pin_rate_limits%ROWTYPE;
  v_legacy_hash text;
  v_bcrypt_hash text;
  v_valid boolean := false;
  v_failed_attempts integer;
  v_locked_until timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'PAYROLL_PIN_FORBIDDEN';
  END IF;
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  INSERT INTO public.payroll_pin_rate_limits (actor_auth_id, store_id)
  VALUES (auth.uid(), p_store_id)
  ON CONFLICT (actor_auth_id, store_id) DO NOTHING;

  SELECT *
  INTO v_rate
  FROM public.payroll_pin_rate_limits
  WHERE actor_auth_id = auth.uid()
    AND store_id = p_store_id
  FOR UPDATE;

  IF v_rate.window_started_at < now() - interval '15 minutes' THEN
    UPDATE public.payroll_pin_rate_limits
    SET window_started_at = now(), failed_attempts = 0,
        locked_until = NULL, updated_at = now()
    WHERE actor_auth_id = auth.uid() AND store_id = p_store_id
    RETURNING * INTO v_rate;
  END IF;
  IF v_rate.locked_until IS NOT NULL AND v_rate.locked_until > now() THEN
    RAISE EXCEPTION 'PAYROLL_PIN_RATE_LIMITED';
  END IF;

  SELECT payroll_pin, payroll_pin_verifier
  INTO v_legacy_hash, v_bcrypt_hash
  FROM public.restaurant_settings
  WHERE restaurant_id = p_store_id;
  IF COALESCE(v_bcrypt_hash, v_legacy_hash, '') = '' THEN
    RAISE EXCEPTION 'PAYROLL_PIN_NOT_CONFIGURED';
  END IF;

  IF p_pin ~ '^[0-9]{4}$' THEN
    IF COALESCE(v_bcrypt_hash, '') <> '' THEN
      v_valid := extensions.crypt(p_pin, v_bcrypt_hash) = v_bcrypt_hash;
    ELSIF v_legacy_hash ~ '^[0-9a-f]{64}$' THEN
      v_valid := encode(extensions.digest(p_pin, 'sha256'), 'hex') = v_legacy_hash;
    END IF;
  END IF;

  IF v_valid THEN
    IF COALESCE(v_bcrypt_hash, '') = '' THEN
      UPDATE public.restaurant_settings
      SET payroll_pin_verifier = extensions.crypt(
            p_pin,
            extensions.gen_salt('bf', 10)
          ),
          updated_at = now()
      WHERE restaurant_id = p_store_id;
    END IF;
    UPDATE public.payroll_pin_rate_limits
    SET window_started_at = now(), failed_attempts = 0,
        locked_until = NULL, updated_at = now()
    WHERE actor_auth_id = auth.uid() AND store_id = p_store_id;
    RETURN true;
  END IF;

  v_failed_attempts := v_rate.failed_attempts + 1;
  v_locked_until := CASE
    WHEN v_failed_attempts >= 5 THEN now() + interval '15 minutes'
    ELSE NULL
  END;
  UPDATE public.payroll_pin_rate_limits
  SET failed_attempts = v_failed_attempts,
      locked_until = v_locked_until,
      updated_at = now()
  WHERE actor_auth_id = auth.uid() AND store_id = p_store_id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'verify_payroll_pin_failed', 'restaurant_settings', p_store_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'failed_attempts', v_failed_attempts,
      'locked', v_locked_until IS NOT NULL
    )
  );
  RETURN false;
END;
$$;

REVOKE ALL ON FUNCTION public.set_payroll_pin_v2(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.clear_payroll_pin_v2(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_payroll_pin_status(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.verify_payroll_pin(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_payroll_pin_v2(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.clear_payroll_pin_v2(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_payroll_pin_status(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.verify_payroll_pin(uuid, text) TO authenticated, service_role;

-- Compatibility grants intentionally remain during Expand.
REVOKE ALL ON FUNCTION public.set_payroll_pin(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.clear_payroll_pin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_payroll_pin(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.clear_payroll_pin(uuid) TO authenticated, service_role;

COMMIT;
