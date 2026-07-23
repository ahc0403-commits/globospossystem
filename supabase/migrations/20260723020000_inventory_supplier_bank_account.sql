ALTER TABLE public.inventory_suppliers
  ADD COLUMN IF NOT EXISTS bank_account_number text;

DROP FUNCTION IF EXISTS public.upsert_inventory_supplier(
  uuid, uuid, text, text, text, text, text, text, text, text, date, date, text
);

CREATE OR REPLACE FUNCTION public.upsert_inventory_supplier(
  p_store_id uuid,
  p_supplier_id uuid DEFAULT NULL,
  p_supplier_name text DEFAULT NULL,
  p_supplier_type text DEFAULT NULL,
  p_contact_name text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_email text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_business_registration_no text DEFAULT NULL,
  p_payment_terms text DEFAULT NULL,
  p_contract_start_date date DEFAULT NULL,
  p_contract_end_date date DEFAULT NULL,
  p_memo text DEFAULT NULL,
  p_bank_account_number text DEFAULT NULL
) RETURNS public.inventory_suppliers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_store public.restaurants%ROWTYPE;
  v_supplier public.inventory_suppliers%ROWTYPE;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_SUPPLIER_FORBIDDEN';
  END IF;

  SELECT * INTO v_store
  FROM public.restaurants
  WHERE id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORE_NOT_FOUND';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_supplier_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'SUPPLIER_NAME_REQUIRED';
  END IF;

  IF p_supplier_id IS NULL THEN
    INSERT INTO public.inventory_suppliers (
      brand_id,
      supplier_name,
      supplier_type,
      contact_name,
      phone,
      email,
      address,
      business_registration_no,
      bank_account_number,
      payment_terms,
      contract_start_date,
      contract_end_date,
      status,
      memo
    ) VALUES (
      v_store.brand_id,
      BTRIM(p_supplier_name),
      NULLIF(BTRIM(COALESCE(p_supplier_type, '')), ''),
      NULLIF(BTRIM(COALESCE(p_contact_name, '')), ''),
      NULLIF(BTRIM(COALESCE(p_phone, '')), ''),
      NULLIF(BTRIM(COALESCE(p_email, '')), ''),
      NULLIF(BTRIM(COALESCE(p_address, '')), ''),
      NULLIF(BTRIM(COALESCE(p_business_registration_no, '')), ''),
      NULLIF(BTRIM(COALESCE(p_bank_account_number, '')), ''),
      NULLIF(BTRIM(COALESCE(p_payment_terms, '')), ''),
      p_contract_start_date,
      p_contract_end_date,
      'active',
      NULLIF(BTRIM(COALESCE(p_memo, '')), '')
    )
    RETURNING * INTO v_supplier;
  ELSE
    UPDATE public.inventory_suppliers
    SET supplier_name = BTRIM(p_supplier_name),
        supplier_type = NULLIF(BTRIM(COALESCE(p_supplier_type, '')), ''),
        contact_name = NULLIF(BTRIM(COALESCE(p_contact_name, '')), ''),
        phone = NULLIF(BTRIM(COALESCE(p_phone, '')), ''),
        email = NULLIF(BTRIM(COALESCE(p_email, '')), ''),
        address = NULLIF(BTRIM(COALESCE(p_address, '')), ''),
        business_registration_no = NULLIF(BTRIM(COALESCE(p_business_registration_no, '')), ''),
        bank_account_number = NULLIF(BTRIM(COALESCE(p_bank_account_number, '')), ''),
        payment_terms = NULLIF(BTRIM(COALESCE(p_payment_terms, '')), ''),
        contract_start_date = p_contract_start_date,
        contract_end_date = p_contract_end_date,
        memo = NULLIF(BTRIM(COALESCE(p_memo, '')), ''),
        updated_at = now()
    WHERE id = p_supplier_id
      AND (brand_id IS NULL OR brand_id = v_store.brand_id)
    RETURNING * INTO v_supplier;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'SUPPLIER_NOT_FOUND';
    END IF;
  END IF;

  RETURN v_supplier;
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_inventory_supplier(
  uuid, uuid, text, text, text, text, text, text, text, text, date, date, text, text
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.upsert_inventory_supplier(
  uuid, uuid, text, text, text, text, text, text, text, text, date, date, text, text
) TO authenticated;

COMMENT ON COLUMN public.inventory_suppliers.bank_account_number
IS 'Supplier bank account number used for settlement and payment reference.';
