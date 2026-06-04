-- ============================================================
-- First-login personal data protection consent
-- 2026-05-19
-- ============================================================

CREATE TABLE IF NOT EXISTS public.user_privacy_consents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
  restaurant_id uuid REFERENCES public.restaurants(id) ON DELETE SET NULL,
  document_version text NOT NULL,
  consented_at timestamptz NOT NULL DEFAULT now(),
  consent_locale text NOT NULL DEFAULT 'vi',
  consent_source text NOT NULL DEFAULT 'first_login',
  legal_basis text NOT NULL DEFAULT 'consent',
  consent_text_hash text NOT NULL,
  data_categories text[] NOT NULL,
  processing_purposes text[] NOT NULL,
  processor_categories text[] NOT NULL,
  withdrawal_notice_acknowledged boolean NOT NULL DEFAULT true,
  cross_border_acknowledged boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (auth_id, document_version)
);

COMMENT ON TABLE public.user_privacy_consents IS
  'Verifiable first-login personal data processing consent records for POS users.';
COMMENT ON COLUMN public.user_privacy_consents.document_version IS
  'Required privacy consent document version accepted by the user.';
COMMENT ON COLUMN public.user_privacy_consents.consent_text_hash IS
  'Stable hash of the disclosed privacy consent content for audit proof.';

CREATE INDEX IF NOT EXISTS idx_user_privacy_consents_auth_id
  ON public.user_privacy_consents(auth_id);
CREATE INDEX IF NOT EXISTS idx_user_privacy_consents_user_id
  ON public.user_privacy_consents(user_id);
CREATE INDEX IF NOT EXISTS idx_user_privacy_consents_restaurant_id
  ON public.user_privacy_consents(restaurant_id);

ALTER TABLE public.user_privacy_consents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_privacy_consents_select_own
  ON public.user_privacy_consents;
CREATE POLICY user_privacy_consents_select_own
ON public.user_privacy_consents
FOR SELECT TO authenticated
USING (
  auth_id = auth.uid()
  OR is_super_admin()
);

CREATE OR REPLACE FUNCTION public.current_privacy_consent_document_version()
RETURNS text AS $$
BEGIN
  RETURN 'vn-pdpl-2026-01';
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public;

CREATE OR REPLACE FUNCTION public.current_privacy_consent_text_hash()
RETURNS text AS $$
BEGIN
  RETURN 'sha256:f994925276732656f7adb8a972f6b8385d90d3bd7f30b8cae27ebb0655245be9';
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public;

CREATE OR REPLACE FUNCTION public.has_accepted_current_privacy_consent()
RETURNS boolean AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1
    FROM public.user_privacy_consents c
    WHERE c.auth_id = auth.uid()
      AND c.document_version = public.current_privacy_consent_document_version()
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.accept_my_privacy_consent(
  p_consent_locale text DEFAULT 'vi'
) RETURNS public.user_privacy_consents AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_consent public.user_privacy_consents%ROWTYPE;
  v_locale text := COALESCE(NULLIF(btrim(p_consent_locale), ''), 'vi');
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRIVACY_CONSENT_USER_REQUIRED';
  END IF;

  INSERT INTO public.user_privacy_consents (
    auth_id,
    user_id,
    restaurant_id,
    document_version,
    consent_locale,
    consent_source,
    legal_basis,
    consent_text_hash,
    data_categories,
    processing_purposes,
    processor_categories,
    withdrawal_notice_acknowledged,
    cross_border_acknowledged
  ) VALUES (
    auth.uid(),
    v_actor.id,
    v_actor.restaurant_id,
    public.current_privacy_consent_document_version(),
    v_locale,
    'first_login',
    'consent',
    public.current_privacy_consent_text_hash(),
    ARRAY[
      'account_profile_role_store_permissions',
      'pos_orders_payments_receipts_einvoice_inventory_qc_attendance',
      'device_session_security_audit_photo_biometric_when_enabled'
    ]::text[],
    ARRAY[
      'authentication_authorization',
      'restaurant_pos_operations_payment_einvoice_settlement',
      'attendance_quality_control_security_audit_legal_compliance',
      'support_diagnostics_reporting_backup_service_improvement'
    ]::text[],
    ARRAY[
      'globosvn_pos_and_store_brand_operator',
      'authorized_admins_cloud_storage_email_printing_device_processors',
      'wetax_einvoice_tax_and_legal_authorities_when_required'
    ]::text[],
    TRUE,
    TRUE
  )
  ON CONFLICT (auth_id, document_version) DO UPDATE
  SET user_id = EXCLUDED.user_id,
      restaurant_id = EXCLUDED.restaurant_id
  RETURNING * INTO v_consent;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'accept_privacy_consent',
    'user_privacy_consents',
    v_consent.id,
    jsonb_build_object(
      'restaurant_id', v_consent.restaurant_id,
      'document_version', v_consent.document_version,
      'consent_locale', v_consent.consent_locale,
      'consent_source', v_consent.consent_source,
      'consent_text_hash', v_consent.consent_text_hash,
      'cross_border_acknowledged', v_consent.cross_border_acknowledged,
      'withdrawal_notice_acknowledged',
      v_consent.withdrawal_notice_acknowledged
    )
  );

  RETURN v_consent;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

GRANT SELECT ON public.user_privacy_consents TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_privacy_consent_document_version()
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_privacy_consent_text_hash()
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_accepted_current_privacy_consent()
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_my_privacy_consent(text)
  TO authenticated;
