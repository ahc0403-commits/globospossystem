-- Minimal security remediation for pilot-safe rollout.
-- The goal is to tighten server-side authorization without changing login,
-- POS order/payment completion, Office table coupling, or WeTax async dispatch.

BEGIN;

-- Legacy POS helpers must not authorize inactive users with still-valid sessions.
CREATE OR REPLACE FUNCTION public.get_user_restaurant_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
  SELECT restaurant_id
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.get_user_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
  SELECT role
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.get_user_store_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
  SELECT public.get_user_restaurant_id()
$$;

CREATE OR REPLACE FUNCTION public.has_any_role(required_roles text[])
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.users
    WHERE auth_id = auth.uid()
      AND is_active = TRUE
      AND role = ANY(required_roles)
  )
$$;

CREATE OR REPLACE FUNCTION public.is_super_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.users
    WHERE auth_id = auth.uid()
      AND is_active = TRUE
      AND role = 'super_admin'
  )
$$;

-- Office / Photo Objet helpers must also treat is_active as an authorization
-- predicate. This preserves the existing Office table and column contract.
CREATE OR REPLACE FUNCTION public.is_master_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public
AS $$
  SELECT EXISTS(
    SELECT 1
    FROM public.office_user_profiles
    WHERE auth_id = auth.uid()
      AND is_active = TRUE
      AND account_level = 'master_admin'
  );
$$;

CREATE OR REPLACE FUNCTION public.get_master_admin_restaurant_ids()
RETURNS uuid[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public
AS $$
  SELECT array(
    SELECT mar.restaurant_id
    FROM public.master_admin_restaurants mar
    JOIN public.office_user_profiles oup
      ON oup.auth_id = mar.user_auth_id
    WHERE mar.user_auth_id = auth.uid()
      AND oup.is_active = TRUE
  );
$$;

CREATE OR REPLACE FUNCTION public.is_photo_objet_master()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public
AS $$
  SELECT EXISTS(
    SELECT 1
    FROM public.office_user_profiles
    WHERE auth_id = auth.uid()
      AND is_active = TRUE
      AND account_level in ('super_admin', 'platform_admin', 'office_admin', 'photo_objet_master')
  );
$$;

CREATE OR REPLACE FUNCTION public.get_photo_objet_store_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public
AS $$
  SELECT (scope_ids[1])::uuid
  FROM public.office_user_profiles
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
    AND account_level = 'photo_objet_store_admin'
    AND scope_type = 'store'
  LIMIT 1;
$$;

-- Remove legacy broad QC photo policy; scoped policies from the hardening
-- migration remain in force.
DROP POLICY IF EXISTS "authenticated_access_qc_photos" ON storage.objects;

-- Payment proof evidence: allow normal first upload, but prevent same-store
-- overwrite/delete unless the actor is an active admin-level user.
DROP POLICY IF EXISTS storage_payment_proofs_scoped ON storage.objects;
DROP POLICY IF EXISTS storage_payment_proofs_select ON storage.objects;
DROP POLICY IF EXISTS storage_payment_proofs_insert ON storage.objects;
DROP POLICY IF EXISTS storage_payment_proofs_update_admin ON storage.objects;
DROP POLICY IF EXISTS storage_payment_proofs_delete_admin ON storage.objects;

CREATE POLICY storage_payment_proofs_select ON storage.objects
FOR SELECT TO authenticated
USING (
  bucket_id = 'payment-proofs'
  AND (
    EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id::text = (storage.foldername(name))[2]
    )
    OR public.is_super_admin()
  )
);

CREATE POLICY storage_payment_proofs_insert ON storage.objects
FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'payment-proofs'
  AND (
    EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id::text = (storage.foldername(name))[2]
    )
    OR public.is_super_admin()
  )
);

CREATE POLICY storage_payment_proofs_update_admin ON storage.objects
FOR UPDATE TO authenticated
USING (
  bucket_id = 'payment-proofs'
  AND EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.auth_id = auth.uid()
      AND u.is_active = TRUE
      AND u.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin')
      AND (
        u.role = 'super_admin'
        OR EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) s(store_id)
          WHERE s.store_id::text = (storage.foldername(name))[2]
        )
      )
  )
)
WITH CHECK (
  bucket_id = 'payment-proofs'
  AND EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.auth_id = auth.uid()
      AND u.is_active = TRUE
      AND u.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin')
      AND (
        u.role = 'super_admin'
        OR EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) s(store_id)
          WHERE s.store_id::text = (storage.foldername(name))[2]
        )
      )
  )
);

CREATE POLICY storage_payment_proofs_delete_admin ON storage.objects
FOR DELETE TO authenticated
USING (
  bucket_id = 'payment-proofs'
  AND EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.auth_id = auth.uid()
      AND u.is_active = TRUE
      AND u.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin')
      AND (
        u.role = 'super_admin'
        OR EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) s(store_id)
          WHERE s.store_id::text = (storage.foldername(name))[2]
        )
      )
  )
);

-- Keep cashier first-upload flow, but reject proof URLs that are not Supabase
-- signed URLs for the requested store's payment-proofs folder.
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
  v_expected_url_fragment TEXT;
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

  v_expected_url_fragment :=
    '/storage/v1/object/sign/payment-proofs/%/' || p_store_id::text || '/%';
  IF p_proof_photo_url NOT LIKE v_expected_url_fragment THEN
    RAISE EXCEPTION 'PAYMENT_PROOF_PATH_INVALID';
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
      'method', v_payment.method,
      'taken_at', COALESCE(p_taken_at, now())
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'payment_id', v_payment.id,
    'proof_required', true,
    'proof_photo_url', p_proof_photo_url
  );
END;
$$;

-- Payroll-sensitive wage configuration should require payroll/admin scope,
-- not only same-store membership.
DROP POLICY IF EXISTS "restaurant_isolation" ON public.staff_wage_configs;
CREATE POLICY staff_wage_configs_payroll_read ON public.staff_wage_configs
FOR SELECT TO authenticated
USING (
  public.is_super_admin()
  OR (
    restaurant_id IN (
      SELECT store_id FROM public.user_accessible_stores(auth.uid()) s(store_id)
    )
    AND public.has_any_role(ARRAY['admin', 'store_admin', 'brand_admin', 'super_admin'])
  )
);

CREATE POLICY staff_wage_configs_payroll_write ON public.staff_wage_configs
FOR ALL TO authenticated
USING (
  public.is_super_admin()
  OR (
    restaurant_id IN (
      SELECT store_id FROM public.user_accessible_stores(auth.uid()) s(store_id)
    )
    AND public.has_any_role(ARRAY['admin', 'store_admin', 'brand_admin', 'super_admin'])
  )
)
WITH CHECK (
  public.is_super_admin()
  OR (
    restaurant_id IN (
      SELECT store_id FROM public.user_accessible_stores(auth.uid()) s(store_id)
    )
    AND public.has_any_role(ARRAY['admin', 'store_admin', 'brand_admin', 'super_admin'])
  )
);

-- Supplier catalog data should be scoped server-side before it reaches clients.
DROP POLICY IF EXISTS "inventory_supplier_items_authenticated_read" ON public.inventory_supplier_items;
DROP POLICY IF EXISTS "inventory_suppliers_authenticated_read" ON public.inventory_suppliers;

CREATE POLICY inventory_suppliers_store_read ON public.inventory_suppliers
FOR SELECT TO authenticated
USING (
  public.is_super_admin()
  OR EXISTS (
    SELECT 1
    FROM public.restaurants r
    JOIN public.user_accessible_stores(auth.uid()) s(store_id)
      ON s.store_id = r.id
    WHERE r.brand_id = inventory_suppliers.brand_id
       OR inventory_suppliers.brand_id IS NULL
  )
);

CREATE POLICY inventory_supplier_items_store_read ON public.inventory_supplier_items
FOR SELECT TO authenticated
USING (
  public.is_super_admin()
  OR EXISTS (
    SELECT 1
    FROM public.inventory_products p
    JOIN public.user_accessible_stores(auth.uid()) s(store_id)
      ON s.store_id = p.restaurant_id
    WHERE p.id = inventory_supplier_items.product_id
  )
);

-- B2B buyer cache lookup is used by red-invoice workflows. Keep cashier
-- support, but deny generic same-store roles with no billing purpose.
CREATE OR REPLACE FUNCTION public.lookup_b2b_buyer(
  p_store_id uuid,
  p_tax_code text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_tax_entity_id uuid;
  v_row b2b_buyer_cache%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'B2B_BUYER_LOOKUP_FORBIDDEN';
  END IF;

  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_REQUIRED';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  SELECT tax_entity_id
  INTO v_tax_entity_id
  FROM restaurants
  WHERE id = p_store_id;

  SELECT *
  INTO v_row
  FROM b2b_buyer_cache
  WHERE buyer_tax_code = p_tax_code
    AND (
      store_id = p_store_id
      OR (v_tax_entity_id IS NOT NULL AND tax_entity_id = v_tax_entity_id)
    )
  ORDER BY (store_id = p_store_id) DESC, last_used_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'tax_company_name', v_row.tax_company_name,
    'tax_address', v_row.tax_address,
    'receiver_email', v_row.receiver_email,
    'receiver_email_cc', v_row.receiver_email_cc
  );
END;
$$;

COMMIT;
