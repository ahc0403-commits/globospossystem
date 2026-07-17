-- ============================================================
-- Harden privacy consent RPC runtime behavior
-- 2026-05-19
-- ============================================================

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

  BEGIN
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
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'privacy consent audit log skipped: %', SQLERRM;
  END;

  RETURN v_consent;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

GRANT EXECUTE ON FUNCTION public.accept_my_privacy_consent(text)
  TO authenticated;
