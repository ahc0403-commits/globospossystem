BEGIN;

-- production-gate: self-verifying

-- Preserve the finalized all-store report as an internal source, then enrich
-- each receipt with the Red Invoice delivery contact fields.
ALTER FUNCTION public.get_restaurant_daily_sales_export(date)
  RENAME TO get_restaurant_daily_sales_export_without_contact;

REVOKE ALL ON FUNCTION
  public.get_restaurant_daily_sales_export_without_contact(date)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_restaurant_daily_sales_export(
  p_business_date date
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_payload jsonb;
  v_receipts jsonb;
BEGIN
  v_payload := public.get_restaurant_daily_sales_export_without_contact(
    p_business_date
  );

  IF v_payload->>'status' <> 'finalized' THEN
    RETURN v_payload;
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      receipt.value || jsonb_build_object(
        'buyer_email', COALESCE(intake.buyer_email, ''),
        'buyer_phone', COALESCE(intake.buyer_phone, '')
      )
      ORDER BY receipt.ordinality
    ),
    '[]'::jsonb
  )
  INTO v_receipts
  FROM jsonb_array_elements(v_payload->'receipts')
    WITH ORDINALITY AS receipt(value, ordinality)
  LEFT JOIN public.red_invoice_intakes intake
    ON intake.order_id = (receipt.value->>'receipt_id')::uuid;

  RETURN jsonb_set(v_payload, '{receipts}', v_receipts, true);
END;
$$;

REVOKE ALL ON FUNCTION public.get_restaurant_daily_sales_export(date)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_restaurant_daily_sales_export(date)
  TO authenticated;

COMMENT ON FUNCTION public.get_restaurant_daily_sales_export(date) IS
  'Super-admin unified MISA workbook source including Red Invoice delivery email and contact phone.';

DROP FUNCTION public.upsert_red_invoice_intake_minimal(
  uuid, uuid, text, text, text, text, text, text
);

CREATE FUNCTION public.upsert_red_invoice_intake_minimal(
  p_order_id uuid,
  p_store_id uuid,
  p_source text DEFAULT 'cashier',
  p_status text DEFAULT 'awaiting_information',
  p_buyer_tax_code text DEFAULT NULL,
  p_buyer_legal_name text DEFAULT NULL,
  p_buyer_address text DEFAULT NULL,
  p_buyer_email text DEFAULT NULL,
  p_buyer_phone text DEFAULT NULL,
  p_source_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_payload jsonb;
  v_intake public.red_invoice_intakes%ROWTYPE;
  v_complete_buyer boolean := p_status IN ('ready', 'exported', 'completed');
  v_effective_status text := p_status;
BEGIN
  IF v_complete_buyer AND (
    COALESCE(btrim(p_buyer_tax_code), '') = ''
    OR COALESCE(btrim(p_buyer_legal_name), '') = ''
    OR COALESCE(btrim(p_buyer_address), '') = ''
    OR COALESCE(btrim(p_buyer_email), '') = ''
    OR position('@' IN p_buyer_email) = 0
    OR COALESCE(btrim(p_buyer_phone), '') = ''
  ) THEN
    RAISE EXCEPTION 'RED_INVOICE_BUYER_INFORMATION_INCOMPLETE';
  END IF;

  v_payload := public.upsert_red_invoice_intake(
    p_order_id,
    p_store_id,
    p_source,
    CASE WHEN v_complete_buyer THEN 'awaiting_information' ELSE p_status END,
    p_buyer_tax_code,
    NULL,
    p_buyer_legal_name,
    NULL,
    p_buyer_address,
    p_buyer_email,
    NULL,
    p_buyer_phone,
    NULL,
    p_source_note
  );

  IF NOT v_complete_buyer THEN
    RETURN v_payload;
  END IF;

  IF v_payload->>'status' = 'manual_review' THEN
    v_effective_status := 'manual_review';
  END IF;

  UPDATE public.red_invoice_intakes
  SET status = v_effective_status,
      buyer_tax_code = NULLIF(btrim(p_buyer_tax_code), ''),
      buyer_legal_name = NULLIF(btrim(p_buyer_legal_name), ''),
      buyer_address = NULLIF(btrim(p_buyer_address), ''),
      buyer_email = NULLIF(btrim(p_buyer_email), ''),
      buyer_phone = NULLIF(btrim(p_buyer_phone), ''),
      buyer_unit_code = NULL,
      buyer_full_name = NULL,
      buyer_email_cc = NULL,
      buyer_id = NULL,
      ready_at = CASE
        WHEN v_effective_status = 'ready' THEN COALESCE(ready_at, now())
        ELSE ready_at
      END,
      updated_at = now()
  WHERE order_id = p_order_id AND store_id = p_store_id
  RETURNING * INTO v_intake;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RED_INVOICE_INTAKE_NOT_FOUND';
  END IF;

  UPDATE public.meinvoice_jobs
  SET buyer_kind = 'registered',
      buyer_snapshot = jsonb_build_object(
        'tax_code', btrim(p_buyer_tax_code),
        'tin_cic_household_head_id', btrim(p_buyer_tax_code),
        'unit_name', btrim(p_buyer_legal_name),
        'address', btrim(p_buyer_address),
        'email', btrim(p_buyer_email),
        'phone', btrim(p_buyer_phone),
        'source', 'red_invoice_intake'
      ),
      status = CASE
        WHEN status IN ('sent_to_misa', 'sent_to_tax_authority', 'valid_invoice')
          THEN 'manual_action_required'
        WHEN status IN ('pending', 'pending_manual_config')
          THEN 'dispatch_paused'
        ELSE status
      END,
      manual_action_type = CASE
        WHEN status IN ('sent_to_misa', 'sent_to_tax_authority', 'valid_invoice')
          THEN 'buyer_info_after_issue'
        ELSE manual_action_type
      END,
      updated_at = now()
  WHERE id = v_intake.meinvoice_job_id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'upsert_red_invoice_intake_minimal',
    'red_invoice_intakes', v_intake.id,
    jsonb_build_object(
      'order_id', p_order_id,
      'store_id', p_store_id,
      'status', v_effective_status,
      'required_fields', jsonb_build_array(
        'buyer_tax_code', 'buyer_legal_name', 'buyer_address',
        'buyer_email', 'buyer_phone'
      )
    )
  );

  RETURN to_jsonb(v_intake);
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_red_invoice_intake_minimal(
  uuid, uuid, text, text, text, text, text, text, text, text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_red_invoice_intake_minimal(
  uuid, uuid, text, text, text, text, text, text, text, text
) TO authenticated;

DO $verification$
DECLARE
  v_export regprocedure :=
    'public.get_restaurant_daily_sales_export(date)'::regprocedure;
  v_intake regprocedure :=
    'public.upsert_red_invoice_intake_minimal(uuid,uuid,text,text,text,text,text,text,text,text)'::regprocedure;
  v_definition text;
BEGIN
  SELECT pg_get_functiondef(v_export::oid) INTO v_definition;
  IF position('buyer_email' IN v_definition) = 0
     OR position('buyer_phone' IN v_definition) = 0
     OR pg_catalog.has_function_privilege('anon', v_export, 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', v_export, 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'RED_INVOICE_CONTACT_EXPORT_VERIFY_FAILED';
  END IF;

  SELECT pg_get_functiondef(v_intake::oid) INTO v_definition;
  IF position('p_buyer_email' IN v_definition) = 0
     OR position('p_buyer_phone' IN v_definition) = 0
     OR position('buyer_email = NULLIF' IN v_definition) = 0
     OR position('buyer_phone = NULLIF' IN v_definition) = 0
     OR pg_catalog.has_function_privilege('anon', v_intake, 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', v_intake, 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'RED_INVOICE_CONTACT_INTAKE_VERIFY_FAILED';
  END IF;
END;
$verification$;

COMMIT;
