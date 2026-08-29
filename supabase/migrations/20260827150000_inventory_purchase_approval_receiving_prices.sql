BEGIN;

-- production-gate: self-verifying
-- Additive POS purchase approval, maker-checker receiving, immutable document
-- metadata, and effective-dated supplier prices.
-- Existing Office RPC names and legacy statuses remain available.

ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_account_type_check;
ALTER TABLE public.users
  ADD CONSTRAINT users_account_type_check CHECK (account_type IN (
    'legacy_user', 'master', 'brand_manager', 'store_manager',
    'inventory_orderer', 'inventory_accounting', 'device_pos', 'device_tablet', 'device_kitchen',
    'device_print_station', 'device_customer_display',
    'device_emergency_station', 'store_operator'
  ));

ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE public.users
  ADD CONSTRAINT users_role_check CHECK (role IN (
    'super_admin', 'master_admin', 'brand_admin', 'store_admin', 'admin',
    'inventory_orderer', 'inventory_accounting', 'waiter', 'kitchen', 'cashier', 'print_station',
    'customer_display', 'emergency_station', 'photo_objet_master',
    'photo_objet_store_admin', 'photo_objet_store_operator'
  ));

CREATE TABLE IF NOT EXISTS public.user_tax_entity_access (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  tax_entity_id uuid NOT NULL REFERENCES public.tax_entity(id) ON DELETE RESTRICT,
  is_active boolean NOT NULL DEFAULT true,
  granted_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT user_tax_entity_access_unique UNIQUE (user_id, tax_entity_id)
);

CREATE INDEX IF NOT EXISTS user_tax_entity_access_user_active_idx
  ON public.user_tax_entity_access(user_id, is_active);
CREATE INDEX IF NOT EXISTS user_tax_entity_access_entity_active_idx
  ON public.user_tax_entity_access(tax_entity_id, is_active);

CREATE TABLE IF NOT EXISTS public.legal_entity_fixed_account_requirements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tax_entity_id uuid NOT NULL UNIQUE
    REFERENCES public.tax_entity(id) ON DELETE RESTRICT,
  account_code text NOT NULL UNIQUE,
  account_type text NOT NULL DEFAULT 'inventory_accounting'
    CHECK (account_type = 'inventory_accounting'),
  role text NOT NULL DEFAULT 'inventory_accounting'
    CHECK (role = 'inventory_accounting'),
  display_name text NOT NULL,
  scope text NOT NULL DEFAULT 'legal_entity'
    CHECK (scope = 'legal_entity'),
  provisioned_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT legal_entity_fixed_account_code_check
    CHECK (account_code ~ '^[a-z][a-z0-9_]{1,31}$')
);

-- Upgrade any pre-release store/brand accounting requirement into one legal
-- entity requirement before the store requirement constraints are tightened.
WITH ranked AS (
  SELECT
    q.*,
    r.tax_entity_id,
    row_number() OVER (
      PARTITION BY r.tax_entity_id ORDER BY (q.provisioned_user_id IS NOT NULL) DESC,
      q.created_at, q.id
    ) AS position
  FROM public.store_fixed_account_requirements q
  JOIN public.restaurants r ON r.id = q.store_id
  WHERE q.account_type = 'inventory_accounting'
)
INSERT INTO public.legal_entity_fixed_account_requirements(
  tax_entity_id, account_code, display_name, provisioned_user_id, is_active
)
SELECT tax_entity_id, account_code, display_name, provisioned_user_id, is_active
FROM ranked
WHERE position = 1
ON CONFLICT (tax_entity_id) DO UPDATE SET
  provisioned_user_id = COALESCE(
    public.legal_entity_fixed_account_requirements.provisioned_user_id,
    EXCLUDED.provisioned_user_id
  ),
  updated_at = now();

INSERT INTO public.user_tax_entity_access(user_id, tax_entity_id, is_active)
SELECT provisioned_user_id, tax_entity_id, true
FROM public.legal_entity_fixed_account_requirements
WHERE provisioned_user_id IS NOT NULL
ON CONFLICT (user_id, tax_entity_id) DO UPDATE SET
  is_active = true,
  updated_at = now();

UPDATE public.user_brand_access access SET
  is_active = false,
  updated_at = now()
WHERE access.user_id IN (
  SELECT provisioned_user_id
  FROM public.legal_entity_fixed_account_requirements
  WHERE provisioned_user_id IS NOT NULL
);

UPDATE public.user_store_access access SET
  is_active = false,
  updated_at = now()
WHERE access.source_type = 'brand_inherited'
  AND access.user_id IN (
    SELECT provisioned_user_id
    FROM public.legal_entity_fixed_account_requirements
    WHERE provisioned_user_id IS NOT NULL
  );

UPDATE public.users account SET brand_id = NULL
WHERE account.id IN (
  SELECT provisioned_user_id
  FROM public.legal_entity_fixed_account_requirements
  WHERE provisioned_user_id IS NOT NULL
);

DELETE FROM public.store_fixed_account_requirements
WHERE account_type = 'inventory_accounting';

ALTER TABLE public.store_fixed_account_requirements
  DROP CONSTRAINT IF EXISTS store_fixed_account_requirements_type_check;
ALTER TABLE public.store_fixed_account_requirements
  ADD CONSTRAINT store_fixed_account_requirements_type_check CHECK (
    account_type IN (
      'brand_manager', 'store_manager', 'inventory_orderer',
      'device_pos', 'device_tablet', 'device_kitchen', 'device_print_station',
      'device_customer_display', 'device_emergency_station', 'store_operator'
    )
  );

ALTER TABLE public.store_fixed_account_requirements
  DROP CONSTRAINT IF EXISTS store_fixed_account_requirements_role_check;
ALTER TABLE public.store_fixed_account_requirements
  ADD CONSTRAINT store_fixed_account_requirements_role_check CHECK (role IN (
    'brand_admin', 'store_admin', 'inventory_orderer',
    'cashier', 'kitchen', 'print_station', 'customer_display', 'emergency_station',
    'photo_objet_master', 'photo_objet_store_operator'
  ));

ALTER TABLE public.store_fixed_account_requirements
  DROP CONSTRAINT IF EXISTS store_fixed_account_requirements_role_type_check;
ALTER TABLE public.store_fixed_account_requirements
  ADD CONSTRAINT store_fixed_account_requirements_role_type_check CHECK (
    (account_type = 'brand_manager'
      AND role IN ('brand_admin', 'photo_objet_master') AND scope = 'brand')
    OR (account_type = 'store_manager'
      AND role = 'store_admin' AND scope = 'store')
    OR (account_type = 'inventory_orderer'
      AND role = 'inventory_orderer' AND scope = 'store')
    OR (account_type IN ('device_pos', 'device_tablet')
      AND role = 'cashier' AND scope = 'store')
    OR (account_type = 'device_kitchen'
      AND role = 'kitchen' AND scope = 'store')
    OR (account_type = 'device_print_station'
      AND role = 'print_station' AND scope = 'store')
    OR (account_type = 'device_customer_display'
      AND role = 'customer_display' AND scope = 'store')
    OR (account_type = 'device_emergency_station'
      AND role = 'emergency_station' AND scope = 'store')
    OR (account_type = 'store_operator'
      AND role = 'photo_objet_store_operator' AND scope = 'store')
  );

ALTER TABLE public.user_tax_entity_access ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.legal_entity_fixed_account_requirements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_tax_entity_access_super_admin_read
  ON public.user_tax_entity_access;
CREATE POLICY user_tax_entity_access_super_admin_read
  ON public.user_tax_entity_access FOR SELECT TO authenticated
  USING (public.is_super_admin());

DROP POLICY IF EXISTS legal_entity_fixed_accounts_super_admin_read
  ON public.legal_entity_fixed_account_requirements;
CREATE POLICY legal_entity_fixed_accounts_super_admin_read
  ON public.legal_entity_fixed_account_requirements FOR SELECT TO authenticated
  USING (public.is_super_admin());

CREATE OR REPLACE FUNCTION public.user_accessible_stores(uid uuid)
RETURNS SETOF uuid
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public, auth
AS $$
  WITH actor AS (
    SELECT id
    FROM public.users
    WHERE auth_id = uid AND is_active = true
  ),
  explicit_store_access AS (
    SELECT usa.store_id
    FROM public.user_store_access usa
    JOIN actor ON actor.id = usa.user_id
    JOIN public.restaurants r ON r.id = usa.store_id AND r.is_active = true
    WHERE usa.is_active = true
  ),
  legal_entity_store_access AS (
    SELECT r.id AS store_id
    FROM public.user_tax_entity_access ute
    JOIN actor ON actor.id = ute.user_id
    JOIN public.restaurants r
      ON r.tax_entity_id = ute.tax_entity_id AND r.is_active = true
    WHERE ute.is_active = true
  ),
  fallback_store AS (
    SELECT r.id AS store_id
    FROM public.users u
    JOIN public.restaurants r
      ON r.id = COALESCE(u.primary_store_id, u.restaurant_id)
     AND r.is_active = true
    WHERE u.auth_id = uid AND u.is_active = true
  )
  SELECT DISTINCT store_id
  FROM (
    SELECT store_id FROM explicit_store_access
    UNION
    SELECT store_id FROM legal_entity_store_access
    UNION
    SELECT store_id FROM fallback_store
  ) store_scope
  WHERE store_id IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION public.user_accessible_tax_entities(uid uuid)
RETURNS SETOF uuid
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public, auth
AS $$
  WITH actor AS (
    SELECT id
    FROM public.users
    WHERE auth_id = uid AND is_active = true
  ),
  explicit_entities AS (
    SELECT ute.tax_entity_id
    FROM public.user_tax_entity_access ute
    JOIN actor ON actor.id = ute.user_id
    WHERE ute.is_active = true
  ),
  store_entities AS (
    SELECT r.tax_entity_id
    FROM public.user_accessible_stores(uid) scope(store_id)
    JOIN public.restaurants r ON r.id = scope.store_id
    WHERE r.tax_entity_id IS NOT NULL
  )
  SELECT DISTINCT tax_entity_id
  FROM (
    SELECT tax_entity_id FROM explicit_entities
    UNION
    SELECT tax_entity_id FROM store_entities
  ) entity_scope
  WHERE tax_entity_id IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION public.admin_configure_legal_entity_inventory_accounting(
  p_tax_entity_id uuid,
  p_account_code text,
  p_display_name text
) RETURNS public.legal_entity_fixed_account_requirements
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_existing public.legal_entity_fixed_account_requirements%ROWTYPE;
  v_result public.legal_entity_fixed_account_requirements%ROWTYPE;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'LEGAL_ENTITY_ACCOUNTING_CONFIG_FORBIDDEN';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.tax_entity WHERE id = p_tax_entity_id) THEN
    RAISE EXCEPTION 'LEGAL_ENTITY_NOT_FOUND';
  END IF;
  IF lower(btrim(COALESCE(p_account_code, ''))) !~ '^[a-z][a-z0-9_]{1,31}$' THEN
    RAISE EXCEPTION 'LEGAL_ENTITY_ACCOUNT_CODE_INVALID';
  END IF;
  IF NULLIF(btrim(COALESCE(p_display_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'LEGAL_ENTITY_ACCOUNT_DISPLAY_NAME_REQUIRED';
  END IF;

  SELECT * INTO v_existing
  FROM public.legal_entity_fixed_account_requirements
  WHERE tax_entity_id = p_tax_entity_id
  FOR UPDATE;
  IF FOUND AND v_existing.provisioned_user_id IS NOT NULL
     AND lower(v_existing.account_code) <> lower(btrim(p_account_code)) THEN
    RAISE EXCEPTION 'LEGAL_ENTITY_ACCOUNT_CODE_IMMUTABLE_AFTER_PROVISION';
  END IF;

  INSERT INTO public.legal_entity_fixed_account_requirements(
    tax_entity_id, account_code, display_name
  ) VALUES (
    p_tax_entity_id, lower(btrim(p_account_code)), btrim(p_display_name)
  )
  ON CONFLICT (tax_entity_id) DO UPDATE SET
    account_code = EXCLUDED.account_code,
    display_name = EXCLUDED.display_name,
    is_active = true,
    updated_at = now()
  RETURNING * INTO v_result;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_configure_store_workforce(
  p_store_id uuid,
  p_short_code text,
  p_management_model text,
  p_brand_manager_slots integer,
  p_account_templates jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_brand_id uuid;
  v_existing_short_code text;
  v_item jsonb;
  v_count integer := 0;
BEGIN
  v_actor := public.require_workforce_manager(p_store_id);
  SELECT brand_id, short_code INTO v_brand_id, v_existing_short_code
  FROM public.restaurants WHERE id = p_store_id;
  IF v_brand_id IS NULL THEN RAISE EXCEPTION 'STORE_BRAND_REQUIRED'; END IF;
  IF upper(btrim(p_short_code)) !~ '^[A-Z0-9]{2,6}$' THEN
    RAISE EXCEPTION 'STORE_SHORT_CODE_INVALID';
  END IF;
  IF p_management_model NOT IN ('brand_centralized', 'store_managed') THEN
    RAISE EXCEPTION 'MANAGEMENT_MODEL_INVALID';
  END IF;
  IF p_brand_manager_slots NOT BETWEEN 1 AND 20 THEN
    RAISE EXCEPTION 'BRAND_MANAGER_SLOTS_INVALID';
  END IF;
  IF jsonb_typeof(p_account_templates) <> 'array'
     OR jsonb_array_length(p_account_templates) = 0 THEN
    RAISE EXCEPTION 'ACCOUNT_TEMPLATES_REQUIRED';
  END IF;
  IF jsonb_array_length(p_account_templates) > 50 THEN
    RAISE EXCEPTION 'ACCOUNT_TEMPLATE_LIMIT';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_account_templates) item(value)
    GROUP BY lower(value->>'account_code') HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'ACCOUNT_TEMPLATE_DUPLICATE_CODE';
  END IF;
  IF (
    SELECT count(*) FROM jsonb_array_elements(p_account_templates) item(value)
    WHERE value->>'account_type' = 'brand_manager'
  ) NOT IN (0, p_brand_manager_slots) THEN
    RAISE EXCEPTION 'BRAND_MANAGER_TEMPLATE_COUNT_INVALID';
  END IF;
  IF v_existing_short_code IS NOT NULL
     AND v_existing_short_code <> upper(btrim(p_short_code))
     AND (
       EXISTS (SELECT 1 FROM public.store_employees WHERE store_id = p_store_id)
       OR EXISTS (
         SELECT 1 FROM public.store_fixed_account_requirements
         WHERE store_id = p_store_id AND provisioned_user_id IS NOT NULL
       )
     ) THEN
    RAISE EXCEPTION 'STORE_SHORT_CODE_IMMUTABLE_AFTER_USE';
  END IF;

  UPDATE public.restaurants SET short_code = upper(btrim(p_short_code))
  WHERE id = p_store_id;
  UPDATE public.brands SET
    management_model = p_management_model,
    brand_manager_slots = p_brand_manager_slots
  WHERE id = v_brand_id;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_account_templates) LOOP
    IF COALESCE(v_item->>'account_code', '') !~ '^[a-z][a-z0-9_]{1,31}$'
       OR COALESCE(v_item->>'scope', '') NOT IN ('brand', 'store')
       OR COALESCE(v_item->>'account_type', '') NOT IN (
         'brand_manager', 'store_manager', 'inventory_orderer',
         'device_pos', 'device_tablet', 'device_kitchen', 'device_print_station',
         'device_customer_display', 'device_emergency_station', 'store_operator'
       )
       OR COALESCE(v_item->>'role', '') NOT IN (
         'brand_admin', 'store_admin', 'inventory_orderer',
         'cashier', 'kitchen', 'print_station', 'customer_display', 'emergency_station',
         'photo_objet_master', 'photo_objet_store_operator'
       )
       OR NULLIF(btrim(COALESCE(v_item->>'display_name', '')), '') IS NULL THEN
      RAISE EXCEPTION 'ACCOUNT_TEMPLATE_INVALID';
    END IF;
    IF (v_item->>'account_type') = 'brand_manager'
       AND v_actor.role <> 'super_admin' THEN
      RAISE EXCEPTION 'BRAND_MANAGER_TEMPLATE_FORBIDDEN';
    END IF;
    IF (v_item->>'account_type') = 'store_manager'
       AND v_actor.role NOT IN ('super_admin', 'brand_admin') THEN
      RAISE EXCEPTION 'STORE_MANAGER_TEMPLATE_FORBIDDEN';
    END IF;
    IF p_management_model = 'brand_centralized'
       AND (v_item->>'account_type') = 'store_manager' THEN
      RAISE EXCEPTION 'CENTRALIZED_STORE_MANAGER_FORBIDDEN';
    END IF;
    IF (v_item->>'account_type') IN (
      'inventory_orderer', 'device_pos', 'device_tablet', 'device_kitchen',
      'device_print_station', 'device_customer_display',
      'device_emergency_station', 'store_operator'
    ) AND (v_item->>'account_code') NOT LIKE
      lower(upper(btrim(p_short_code))) || '\_%' ESCAPE '\' THEN
      RAISE EXCEPTION 'STORE_ACCOUNT_CODE_PREFIX_INVALID';
    END IF;
    INSERT INTO public.store_fixed_account_requirements(
      store_id, account_code, account_type, role, display_name, scope
    ) VALUES (
      p_store_id, v_item->>'account_code', v_item->>'account_type',
      v_item->>'role', btrim(v_item->>'display_name'), v_item->>'scope'
    ) ON CONFLICT (store_id, account_code) DO UPDATE SET
      account_type = EXCLUDED.account_type,
      role = EXCLUDED.role,
      display_name = EXCLUDED.display_name,
      scope = EXCLUDED.scope,
      is_active = true,
      updated_at = now();
    v_count := v_count + 1;
  END LOOP;
  UPDATE public.store_fixed_account_requirements q SET
    is_active = false,
    updated_at = now()
  WHERE q.store_id = p_store_id
    AND q.provisioned_user_id IS NULL
    AND q.is_active = true
    AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_account_templates) item(value)
      WHERE lower(value->>'account_code') = lower(q.account_code)
    );
  RETURN jsonb_build_object(
    'configured', true,
    'store_id', p_store_id,
    'short_code', upper(btrim(p_short_code)),
    'management_model', p_management_model,
    'template_count', v_count
  );
END;
$$;

ALTER TABLE public.inventory_purchase_orders
  DROP CONSTRAINT IF EXISTS inventory_purchase_orders_status_check;
ALTER TABLE public.inventory_purchase_orders
  ADD CONSTRAINT inventory_purchase_orders_status_check CHECK (status IN (
    'draft', 'submitted', 'store_approved', 'brand_approved',
    'office_approved', 'office_returned', 'office_rejected', 'ordered',
    'partially_received', 'received', 'cancelled'
  ));

ALTER TABLE public.inventory_purchase_orders
  ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS submitted_at timestamptz,
  ADD COLUMN IF NOT EXISTS row_version integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS store_approved_by uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS store_approved_at timestamptz,
  ADD COLUMN IF NOT EXISTS brand_approved_by uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS brand_approved_at timestamptz,
  ADD COLUMN IF NOT EXISTS approval_snapshot jsonb,
  ADD COLUMN IF NOT EXISTS approval_snapshot_version integer,
  ADD COLUMN IF NOT EXISTS approval_snapshot_hash text,
  ADD COLUMN IF NOT EXISTS document_status text NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS document_last_error text;

UPDATE public.inventory_purchase_orders
SET created_by = COALESCE(created_by, submitted_by),
    submitted_at = COALESCE(submitted_at, created_at)
WHERE created_by IS NULL OR submitted_at IS NULL;

ALTER TABLE public.inventory_purchase_orders
  DROP CONSTRAINT IF EXISTS inventory_purchase_orders_row_version_check;
ALTER TABLE public.inventory_purchase_orders
  ADD CONSTRAINT inventory_purchase_orders_row_version_check
    CHECK (row_version > 0);
ALTER TABLE public.inventory_purchase_orders
  DROP CONSTRAINT IF EXISTS inventory_purchase_orders_document_status_check;
ALTER TABLE public.inventory_purchase_orders
  ADD CONSTRAINT inventory_purchase_orders_document_status_check
    CHECK (document_status IN ('none', 'pending', 'ready', 'failed'));

CREATE TABLE IF NOT EXISTS public.inventory_purchase_approval_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_order_id uuid NOT NULL
    REFERENCES public.inventory_purchase_orders(id) ON DELETE CASCADE,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  actor_id uuid REFERENCES auth.users(id),
  actor_role text NOT NULL,
  action text NOT NULL CHECK (action IN (
    'draft_created', 'draft_updated', 'draft_deleted', 'submitted',
    'store_approved', 'store_returned', 'brand_approved', 'brand_returned',
    'document_ready', 'document_failed'
  )),
  from_status text,
  to_status text,
  reason text,
  order_version integer NOT NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS inventory_purchase_approval_events_order_idx
  ON public.inventory_purchase_approval_events(purchase_order_id, created_at);

CREATE TABLE IF NOT EXISTS public.inventory_purchase_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_order_id uuid NOT NULL
    REFERENCES public.inventory_purchase_orders(id) ON DELETE CASCADE,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  snapshot_version integer NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'ready', 'failed')),
  storage_path text,
  sha256 text,
  byte_size bigint,
  last_error text,
  generated_by uuid REFERENCES auth.users(id),
  generated_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (purchase_order_id, snapshot_version)
);

ALTER TABLE public.inventory_receipts
  ADD COLUMN IF NOT EXISTS row_version integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS delivery_cycle integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS statement_number text,
  ADD COLUMN IF NOT EXISTS statement_date date,
  ADD COLUMN IF NOT EXISTS statement_storage_path text,
  ADD COLUMN IF NOT EXISTS verified_by uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS verified_at timestamptz,
  ADD COLUMN IF NOT EXISTS total_supply_amount numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS tax_amount numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_amount numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS verification_reason text;

ALTER TABLE public.inventory_receipts
  DROP CONSTRAINT IF EXISTS inventory_receipts_row_version_check;
ALTER TABLE public.inventory_receipts
  ADD CONSTRAINT inventory_receipts_row_version_check CHECK (row_version > 0);
ALTER TABLE public.inventory_receipts
  DROP CONSTRAINT IF EXISTS inventory_receipts_delivery_cycle_check;
ALTER TABLE public.inventory_receipts
  ADD CONSTRAINT inventory_receipts_delivery_cycle_check
    CHECK (delivery_cycle > 0);

CREATE UNIQUE INDEX IF NOT EXISTS inventory_receipts_one_open_draft_idx
  ON public.inventory_receipts(purchase_order_id)
  WHERE status = 'draft';

ALTER TABLE public.inventory_receipt_lines
  ADD COLUMN IF NOT EXISTS actual_unit_price numeric(12,2),
  ADD COLUMN IF NOT EXISTS final_supply_amount numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS final_tax_amount numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS discrepancy_reason text,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

CREATE UNIQUE INDEX IF NOT EXISTS inventory_receipt_lines_order_line_idx
  ON public.inventory_receipt_lines(receipt_id, purchase_order_line_id)
  WHERE purchase_order_line_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.inventory_supplier_item_price_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_item_id uuid NOT NULL
    REFERENCES public.inventory_supplier_items(id) ON DELETE CASCADE,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  supplier_id uuid NOT NULL REFERENCES public.inventory_suppliers(id),
  product_id uuid NOT NULL REFERENCES public.inventory_products(id),
  old_unit_price numeric(12,2),
  new_unit_price numeric(12,2) NOT NULL,
  old_tax_rate numeric(5,2),
  new_tax_rate numeric(5,2) NOT NULL,
  effective_date date NOT NULL DEFAULT current_date,
  source text NOT NULL DEFAULT 'manual'
    CHECK (source IN ('manual', 'excel', 'system')),
  import_id uuid,
  source_row integer,
  note text,
  changed_by uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS inventory_supplier_price_history_item_idx
  ON public.inventory_supplier_item_price_history(
    supplier_item_id, effective_date DESC, created_at DESC
  );

ALTER TABLE public.inventory_purchase_approval_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_purchase_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_supplier_item_price_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS inventory_purchase_approval_events_read
  ON public.inventory_purchase_approval_events;
CREATE POLICY inventory_purchase_approval_events_read
  ON public.inventory_purchase_approval_events FOR SELECT TO authenticated
  USING (public.can_access_inventory_purchase_store(restaurant_id));

DROP POLICY IF EXISTS inventory_purchase_documents_read
  ON public.inventory_purchase_documents;
CREATE POLICY inventory_purchase_documents_read
  ON public.inventory_purchase_documents FOR SELECT TO authenticated
  USING (public.can_access_inventory_purchase_store(restaurant_id));

DROP POLICY IF EXISTS inventory_supplier_price_history_read
  ON public.inventory_supplier_item_price_history;
CREATE POLICY inventory_supplier_price_history_read
  ON public.inventory_supplier_item_price_history FOR SELECT TO authenticated
  USING (public.can_access_inventory_purchase_store(restaurant_id));

CREATE OR REPLACE FUNCTION public.inventory_purchase_actor_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT u.role
  FROM public.users u
  WHERE u.auth_id = auth.uid() AND u.is_active = true
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.can_create_inventory_purchase_order(
  p_store_id uuid
) RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT public.can_access_inventory_purchase_store(p_store_id)
    AND COALESCE(public.inventory_purchase_actor_role(), '') IN (
      'inventory_orderer', 'admin', 'store_admin', 'brand_admin', 'super_admin'
    )
$$;

CREATE OR REPLACE FUNCTION public.can_verify_inventory_receipt(
  p_store_id uuid
) RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT public.can_access_inventory_purchase_store(p_store_id)
    AND COALESCE(public.inventory_purchase_actor_role(), '') =
      'inventory_accounting'
$$;

CREATE OR REPLACE FUNCTION public.append_inventory_purchase_approval_event(
  p_order_id uuid,
  p_action text,
  p_from_status text,
  p_to_status text,
  p_reason text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
BEGIN
  SELECT * INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = p_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND';
  END IF;

  INSERT INTO public.inventory_purchase_approval_events(
    purchase_order_id, restaurant_id, actor_id, actor_role, action,
    from_status, to_status, reason, order_version, metadata
  ) VALUES (
    v_order.id, v_order.restaurant_id, auth.uid(),
    COALESCE(public.inventory_purchase_actor_role(), 'service_role'),
    p_action, p_from_status, p_to_status,
    NULLIF(btrim(COALESCE(p_reason, '')), ''), v_order.row_version,
    COALESCE(p_metadata, '{}'::jsonb)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.capture_inventory_supplier_price_history()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_store_id uuid;
  v_source text;
  v_import_id uuid;
  v_effective_date date;
  v_source_row integer;
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.unit_price IS NOT DISTINCT FROM OLD.unit_price
     AND NEW.tax_rate IS NOT DISTINCT FROM OLD.tax_rate THEN
    RETURN NEW;
  END IF;

  SELECT restaurant_id INTO v_store_id
  FROM public.inventory_products
  WHERE id = NEW.product_id;

  v_source := COALESCE(
    NULLIF(current_setting('app.inventory_price_source', true), ''),
    CASE WHEN TG_OP = 'INSERT' THEN 'system' ELSE 'manual' END
  );
  IF v_source NOT IN ('manual', 'excel', 'system') THEN v_source := 'manual'; END IF;

  BEGIN
    v_import_id := NULLIF(
      current_setting('app.inventory_price_import_id', true), ''
    )::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    v_import_id := NULL;
  END;
  BEGIN
    v_effective_date := COALESCE(
      NULLIF(current_setting('app.inventory_price_effective_date', true), '')::date,
      current_date
    );
  EXCEPTION WHEN invalid_datetime_format THEN
    v_effective_date := current_date;
  END;
  BEGIN
    v_source_row := NULLIF(
      current_setting('app.inventory_price_source_row', true), ''
    )::integer;
  EXCEPTION WHEN invalid_text_representation THEN
    v_source_row := NULL;
  END;

  INSERT INTO public.inventory_supplier_item_price_history(
    supplier_item_id, restaurant_id, supplier_id, product_id,
    old_unit_price, new_unit_price, old_tax_rate, new_tax_rate,
    effective_date, source, import_id, source_row, note, changed_by
  ) VALUES (
    NEW.id, v_store_id, NEW.supplier_id, NEW.product_id,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.unit_price ELSE NULL END,
    NEW.unit_price,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.tax_rate ELSE NULL END,
    NEW.tax_rate,
    v_effective_date, v_source, v_import_id, v_source_row,
    NULLIF(current_setting('app.inventory_price_note', true), ''), auth.uid()
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS inventory_supplier_item_price_history_trigger
  ON public.inventory_supplier_items;
CREATE TRIGGER inventory_supplier_item_price_history_trigger
AFTER INSERT OR UPDATE OF unit_price, tax_rate
ON public.inventory_supplier_items
FOR EACH ROW EXECUTE FUNCTION public.capture_inventory_supplier_price_history();

CREATE OR REPLACE FUNCTION public.create_manual_inventory_purchase_order(
  p_store_id uuid,
  p_supplier_id uuid,
  p_lines jsonb,
  p_requested_delivery_date date DEFAULT NULL,
  p_memo text DEFAULT NULL
) RETURNS public.inventory_purchase_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_brand_id uuid;
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_line jsonb;
  v_supplier_item public.inventory_supplier_items%ROWTYPE;
  v_ordered_quantity_unit numeric(12,3);
  v_unit_price numeric(12,2);
  v_line_memo text;
BEGIN
  IF NOT public.can_create_inventory_purchase_order(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_MANUAL_PURCHASE_FORBIDDEN';
  END IF;
  IF p_supplier_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_MANUAL_PURCHASE_SUPPLIER_REQUIRED';
  END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array'
     OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'INVENTORY_MANUAL_PURCHASE_LINES_REQUIRED';
  END IF;

  SELECT brand_id INTO v_brand_id
  FROM public.restaurants WHERE id = p_store_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_MANUAL_PURCHASE_STORE_NOT_FOUND'; END IF;

  INSERT INTO public.inventory_purchase_orders(
    purchase_order_no, restaurant_id, brand_id, supplier_id, status,
    order_type, source, requested_delivery_date, created_by, memo
  ) VALUES (
    'PO-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' ||
      upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6)),
    p_store_id, v_brand_id, p_supplier_id, 'draft', 'manual', 'pos',
    p_requested_delivery_date, auth.uid(),
    NULLIF(btrim(COALESCE(p_memo, '')), '')
  ) RETURNING * INTO v_order;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_ordered_quantity_unit := NULLIF(
      v_line->>'ordered_quantity_unit', ''
    )::numeric;
    v_line_memo := NULLIF(btrim(COALESCE(v_line->>'memo', '')), '');
    IF v_ordered_quantity_unit IS NULL OR v_ordered_quantity_unit <= 0 THEN
      RAISE EXCEPTION 'INVENTORY_MANUAL_PURCHASE_QUANTITY_INVALID';
    END IF;

    SELECT * INTO v_supplier_item
    FROM public.inventory_supplier_items
    WHERE id = NULLIF(v_line->>'supplier_item_id', '')::uuid
      AND supplier_id = p_supplier_id AND is_active = true;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'INVENTORY_MANUAL_PURCHASE_SUPPLIER_ITEM_NOT_FOUND';
    END IF;

    v_ordered_quantity_unit := GREATEST(
      v_ordered_quantity_unit, v_supplier_item.min_order_quantity
    );
    v_unit_price := COALESCE(
      NULLIF(v_line->>'unit_price', '')::numeric,
      v_supplier_item.unit_price
    );
    IF v_unit_price < 0 THEN
      RAISE EXCEPTION 'INVENTORY_PURCHASE_LINE_PRICE_INVALID';
    END IF;

    INSERT INTO public.inventory_purchase_order_lines(
      purchase_order_id, product_id, supplier_item_id,
      recommended_quantity_base, ordered_quantity_base,
      ordered_quantity_unit, order_unit, unit_price, supply_amount,
      tax_amount, memo, recommendation_snapshot
    ) VALUES (
      v_order.id, v_supplier_item.product_id, v_supplier_item.id, 0,
      v_ordered_quantity_unit * v_supplier_item.order_unit_quantity_base,
      v_ordered_quantity_unit, v_supplier_item.order_unit, v_unit_price,
      round(v_ordered_quantity_unit * v_unit_price, 2),
      round(v_ordered_quantity_unit * v_unit_price *
        COALESCE(v_supplier_item.tax_rate, 0) / 100, 2),
      v_line_memo,
      jsonb_build_object(
        'source', 'manual_pos_draft',
        'supplier_item_id', v_supplier_item.id,
        'supplier_default_unit_price', v_supplier_item.unit_price,
        'order_unit_quantity_base', v_supplier_item.order_unit_quantity_base,
        'tax_rate', v_supplier_item.tax_rate
      )
    );
  END LOOP;

  PERFORM public.recalculate_inventory_purchase_order_totals(v_order.id);
  SELECT * INTO v_order FROM public.inventory_purchase_orders
  WHERE id = v_order.id;
  PERFORM public.append_inventory_purchase_approval_event(
    v_order.id, 'draft_created', NULL, 'draft', NULL,
    jsonb_build_object('order_type', 'manual')
  );
  RETURN v_order;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_repeat_inventory_purchase_order(
  p_source_purchase_order_id uuid,
  p_requested_delivery_date date DEFAULT NULL,
  p_memo text DEFAULT NULL
) RETURNS public.inventory_purchase_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_source public.inventory_purchase_orders%ROWTYPE;
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_line public.inventory_purchase_order_lines%ROWTYPE;
  v_supplier_item public.inventory_supplier_items%ROWTYPE;
  v_line_count integer := 0;
  v_quantity numeric(12,3);
BEGIN
  SELECT * INTO v_source FROM public.inventory_purchase_orders
  WHERE id = p_source_purchase_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_REPEAT_PURCHASE_SOURCE_NOT_FOUND'; END IF;
  IF NOT public.can_create_inventory_purchase_order(v_source.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_REPEAT_PURCHASE_FORBIDDEN';
  END IF;

  INSERT INTO public.inventory_purchase_orders(
    purchase_order_no, restaurant_id, brand_id, supplier_id, status,
    order_type, source, requested_delivery_date, created_by, memo
  ) VALUES (
    'PO-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' ||
      upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6)),
    v_source.restaurant_id, v_source.brand_id, v_source.supplier_id, 'draft',
    'repeat', 'pos', p_requested_delivery_date, auth.uid(),
    COALESCE(NULLIF(btrim(COALESCE(p_memo, '')), ''),
      'Repeat from ' || v_source.purchase_order_no)
  ) RETURNING * INTO v_order;

  FOR v_line IN SELECT * FROM public.inventory_purchase_order_lines
    WHERE purchase_order_id = v_source.id ORDER BY created_at, id
  LOOP
    SELECT * INTO v_supplier_item FROM public.inventory_supplier_items
    WHERE id = v_line.supplier_item_id
      AND supplier_id = v_source.supplier_id AND is_active = true;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'INVENTORY_REPEAT_PURCHASE_SUPPLIER_ITEM_NOT_FOUND';
    END IF;
    v_quantity := GREATEST(
      v_line.ordered_quantity_unit, v_supplier_item.min_order_quantity
    );
    IF v_quantity <= 0 THEN
      RAISE EXCEPTION 'INVENTORY_REPEAT_PURCHASE_QUANTITY_INVALID';
    END IF;

    INSERT INTO public.inventory_purchase_order_lines(
      purchase_order_id, product_id, supplier_item_id,
      recommended_quantity_base, ordered_quantity_base,
      ordered_quantity_unit, order_unit, unit_price, supply_amount,
      tax_amount, memo, recommendation_snapshot
    ) VALUES (
      v_order.id, v_supplier_item.product_id, v_supplier_item.id, 0,
      v_quantity * v_supplier_item.order_unit_quantity_base, v_quantity,
      v_supplier_item.order_unit, v_supplier_item.unit_price,
      round(v_quantity * v_supplier_item.unit_price, 2),
      round(v_quantity * v_supplier_item.unit_price *
        COALESCE(v_supplier_item.tax_rate, 0) / 100, 2),
      v_line.memo,
      jsonb_build_object(
        'source', 'repeat_pos_draft',
        'source_purchase_order_id', v_source.id,
        'source_purchase_order_line_id', v_line.id,
        'supplier_default_unit_price', v_supplier_item.unit_price,
        'order_unit_quantity_base', v_supplier_item.order_unit_quantity_base,
        'tax_rate', v_supplier_item.tax_rate
      )
    );
    v_line_count := v_line_count + 1;
  END LOOP;

  IF v_line_count = 0 THEN
    RAISE EXCEPTION 'INVENTORY_REPEAT_PURCHASE_LINES_REQUIRED';
  END IF;
  PERFORM public.recalculate_inventory_purchase_order_totals(v_order.id);
  SELECT * INTO v_order FROM public.inventory_purchase_orders
  WHERE id = v_order.id;
  PERFORM public.append_inventory_purchase_approval_event(
    v_order.id, 'draft_created', NULL, 'draft', NULL,
    jsonb_build_object('order_type', 'repeat', 'source_order_id', v_source.id)
  );
  RETURN v_order;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_purchase_orders_from_recommendation(
  p_run_id uuid,
  p_requested_delivery_date date DEFAULT NULL
) RETURNS SETOF public.inventory_purchase_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_run public.inventory_recommendation_runs%ROWTYPE;
  v_supplier_id uuid;
  v_order public.inventory_purchase_orders%ROWTYPE;
BEGIN
  SELECT * INTO v_run FROM public.inventory_recommendation_runs
  WHERE id = p_run_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_RECOMMENDATION_RUN_NOT_FOUND'; END IF;
  IF NOT public.can_create_inventory_purchase_order(v_run.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;

  FOR v_supplier_id IN
    SELECT DISTINCT supplier_id FROM public.inventory_recommendation_lines
    WHERE run_id = p_run_id AND supplier_id IS NOT NULL
      AND COALESCE(adjusted_order_units, recommended_order_units) > 0
  LOOP
    INSERT INTO public.inventory_purchase_orders(
      purchase_order_no, restaurant_id, brand_id, supplier_id, status,
      order_type, source, requested_delivery_date, created_by
    ) VALUES (
      'PO-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' ||
        upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6)),
      v_run.restaurant_id, v_run.brand_id, v_supplier_id, 'draft',
      'recommended', 'pos', p_requested_delivery_date, auth.uid()
    ) RETURNING * INTO v_order;

    INSERT INTO public.inventory_purchase_order_lines(
      purchase_order_id, product_id, supplier_item_id,
      recommended_quantity_base, ordered_quantity_base,
      ordered_quantity_unit, order_unit, unit_price, supply_amount,
      tax_amount, recommendation_snapshot
    )
    SELECT
      v_order.id, rl.product_id, isi.id, rl.recommended_quantity_base,
      COALESCE(rl.adjusted_order_units, rl.recommended_order_units) *
        isi.order_unit_quantity_base,
      COALESCE(rl.adjusted_order_units, rl.recommended_order_units),
      isi.order_unit, isi.unit_price,
      round(COALESCE(rl.adjusted_order_units, rl.recommended_order_units) *
        isi.unit_price, 2),
      round(COALESCE(rl.adjusted_order_units, rl.recommended_order_units) *
        isi.unit_price * COALESCE(isi.tax_rate, 0) / 100, 2),
      jsonb_build_object(
        'source', 'recommendation_pos_draft', 'run_id', p_run_id,
        'supplier_default_unit_price', isi.unit_price,
        'order_unit_quantity_base', isi.order_unit_quantity_base,
        'tax_rate', isi.tax_rate, 'risk_status', rl.risk_status
      )
    FROM public.inventory_recommendation_lines rl
    JOIN public.inventory_supplier_items isi
      ON isi.product_id = rl.product_id
     AND isi.supplier_id = rl.supplier_id AND isi.is_active = true
    WHERE rl.run_id = p_run_id AND rl.supplier_id = v_supplier_id
      AND COALESCE(rl.adjusted_order_units, rl.recommended_order_units) > 0;

    PERFORM public.recalculate_inventory_purchase_order_totals(v_order.id);
    SELECT * INTO v_order FROM public.inventory_purchase_orders
    WHERE id = v_order.id;
    PERFORM public.append_inventory_purchase_approval_event(
      v_order.id, 'draft_created', NULL, 'draft', NULL,
      jsonb_build_object('order_type', 'recommended', 'run_id', p_run_id)
    );
    RETURN NEXT v_order;
  END LOOP;
  RETURN;
END;
$$;

CREATE OR REPLACE FUNCTION public.save_inventory_purchase_order_draft(
  p_purchase_order_id uuid,
  p_expected_version integer,
  p_requested_delivery_date date,
  p_memo text,
  p_lines jsonb
) RETURNS public.inventory_purchase_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_line jsonb;
  v_line_id uuid;
  v_supplier_item public.inventory_supplier_items%ROWTYPE;
  v_quantity numeric(12,3);
  v_price numeric(12,2);
  v_seen_ids uuid[] := ARRAY[]::uuid[];
BEGIN
  SELECT * INTO v_order FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND'; END IF;
  IF NOT public.can_create_inventory_purchase_order(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;
  IF public.inventory_purchase_actor_role() = 'inventory_orderer'
     AND v_order.created_by IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_DRAFT_OWNER_REQUIRED';
  END IF;
  IF v_order.status <> 'draft' THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_EDITABLE';
  END IF;
  IF v_order.row_version <> p_expected_version THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_STALE_VERSION';
  END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array'
     OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_LINES_REQUIRED';
  END IF;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_line_id := NULLIF(v_line->>'line_id', '')::uuid;
    v_quantity := NULLIF(v_line->>'ordered_quantity_unit', '')::numeric;
    IF v_quantity IS NULL OR v_quantity <= 0 THEN
      RAISE EXCEPTION 'INVENTORY_PURCHASE_LINE_QUANTITY_INVALID';
    END IF;
    SELECT * INTO v_supplier_item FROM public.inventory_supplier_items
    WHERE id = NULLIF(v_line->>'supplier_item_id', '')::uuid
      AND supplier_id = v_order.supplier_id AND is_active = true;
    IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_SUPPLIER_ITEM_NOT_FOUND'; END IF;
    v_price := COALESCE(
      NULLIF(v_line->>'unit_price', '')::numeric, v_supplier_item.unit_price
    );
    IF v_price < 0 THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_LINE_PRICE_INVALID'; END IF;

    IF v_line_id IS NULL THEN
      INSERT INTO public.inventory_purchase_order_lines(
        purchase_order_id, product_id, supplier_item_id,
        recommended_quantity_base, ordered_quantity_base,
        ordered_quantity_unit, order_unit, unit_price, supply_amount,
        tax_amount, memo, recommendation_snapshot
      ) VALUES (
        v_order.id, v_supplier_item.product_id, v_supplier_item.id, 0,
        v_quantity * v_supplier_item.order_unit_quantity_base, v_quantity,
        v_supplier_item.order_unit, v_price, round(v_quantity * v_price, 2),
        round(v_quantity * v_price * COALESCE(v_supplier_item.tax_rate, 0) / 100, 2),
        NULLIF(btrim(COALESCE(v_line->>'memo', '')), ''),
        jsonb_build_object(
          'source', 'draft_edit',
          'supplier_default_unit_price', v_supplier_item.unit_price,
          'order_unit_quantity_base', v_supplier_item.order_unit_quantity_base,
          'tax_rate', v_supplier_item.tax_rate
        )
      ) RETURNING id INTO v_line_id;
    ELSE
      UPDATE public.inventory_purchase_order_lines SET
        product_id = v_supplier_item.product_id,
        supplier_item_id = v_supplier_item.id,
        ordered_quantity_base = v_quantity * v_supplier_item.order_unit_quantity_base,
        ordered_quantity_unit = v_quantity,
        order_unit = v_supplier_item.order_unit,
        unit_price = v_price,
        supply_amount = round(v_quantity * v_price, 2),
        tax_amount = round(v_quantity * v_price *
          COALESCE(v_supplier_item.tax_rate, 0) / 100, 2),
        memo = NULLIF(btrim(COALESCE(v_line->>'memo', '')), ''),
        recommendation_snapshot = COALESCE(recommendation_snapshot, '{}'::jsonb)
          || jsonb_build_object(
            'supplier_default_unit_price', v_supplier_item.unit_price,
            'order_unit_quantity_base', v_supplier_item.order_unit_quantity_base,
            'tax_rate', v_supplier_item.tax_rate
          ),
        updated_at = now()
      WHERE id = v_line_id AND purchase_order_id = v_order.id;
      IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_LINE_NOT_FOUND'; END IF;
    END IF;
    v_seen_ids := array_append(v_seen_ids, v_line_id);
  END LOOP;

  DELETE FROM public.inventory_purchase_order_lines
  WHERE purchase_order_id = v_order.id AND NOT (id = ANY(v_seen_ids));

  UPDATE public.inventory_purchase_orders SET
    requested_delivery_date = p_requested_delivery_date,
    memo = NULLIF(btrim(COALESCE(p_memo, '')), ''),
    row_version = row_version + 1,
    updated_at = now()
  WHERE id = v_order.id;
  PERFORM public.recalculate_inventory_purchase_order_totals(v_order.id);
  SELECT * INTO v_order FROM public.inventory_purchase_orders WHERE id = v_order.id;
  PERFORM public.append_inventory_purchase_approval_event(
    v_order.id, 'draft_updated', 'draft', 'draft'
  );
  RETURN v_order;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_inventory_purchase_order_draft(
  p_purchase_order_id uuid,
  p_expected_version integer,
  p_reason text DEFAULT 'deleted_before_submit'
) RETURNS public.inventory_purchase_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
BEGIN
  SELECT * INTO v_order FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND'; END IF;
  IF NOT public.can_create_inventory_purchase_order(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;
  IF public.inventory_purchase_actor_role() = 'inventory_orderer'
     AND v_order.created_by IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_DRAFT_OWNER_REQUIRED';
  END IF;
  IF v_order.status <> 'draft' THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_EDITABLE'; END IF;
  IF v_order.row_version <> p_expected_version THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_STALE_VERSION';
  END IF;
  UPDATE public.inventory_purchase_orders SET
    status = 'cancelled', row_version = row_version + 1, updated_at = now()
  WHERE id = v_order.id RETURNING * INTO v_order;
  PERFORM public.append_inventory_purchase_approval_event(
    v_order.id, 'draft_deleted', 'draft', 'cancelled', p_reason
  );
  RETURN v_order;
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_inventory_purchase_order(
  p_purchase_order_id uuid,
  p_expected_version integer
) RETURNS public.inventory_purchase_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
BEGIN
  SELECT * INTO v_order FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND'; END IF;
  IF NOT public.can_create_inventory_purchase_order(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;
  IF public.inventory_purchase_actor_role() = 'inventory_orderer'
     AND v_order.created_by IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_DRAFT_OWNER_REQUIRED';
  END IF;
  IF v_order.status <> 'draft' THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_SUBMITTABLE'; END IF;
  IF v_order.row_version <> p_expected_version THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_STALE_VERSION';
  END IF;
  IF v_order.requested_delivery_date IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_DELIVERY_DATE_REQUIRED';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.inventory_purchase_order_lines
    WHERE purchase_order_id = v_order.id AND ordered_quantity_unit > 0
  ) THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_LINES_REQUIRED'; END IF;

  UPDATE public.inventory_purchase_orders SET
    status = 'submitted', submitted_by = auth.uid(), submitted_at = now(),
    row_version = row_version + 1, updated_at = now()
  WHERE id = v_order.id RETURNING * INTO v_order;
  PERFORM public.append_inventory_purchase_approval_event(
    v_order.id, 'submitted', 'draft', 'submitted'
  );
  RETURN v_order;
END;
$$;

CREATE OR REPLACE FUNCTION public.store_decide_inventory_purchase_order(
  p_purchase_order_id uuid,
  p_expected_version integer,
  p_approve boolean,
  p_reason text DEFAULT NULL
) RETURNS public.inventory_purchase_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_role text := public.inventory_purchase_actor_role();
  v_reason text := NULLIF(btrim(COALESCE(p_reason, '')), '');
BEGIN
  SELECT * INTO v_order FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND'; END IF;
  IF NOT public.can_access_inventory_purchase_store(v_order.restaurant_id)
     OR v_role NOT IN ('admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_STORE_APPROVAL_FORBIDDEN';
  END IF;
  IF v_order.created_by IS NOT DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_SELF_APPROVAL_FORBIDDEN';
  END IF;
  IF v_order.status <> 'submitted' THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_INVALID_TRANSITION'; END IF;
  IF v_order.row_version <> p_expected_version THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_STALE_VERSION'; END IF;
  IF NOT p_approve AND v_reason IS NULL THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_RETURN_REASON_REQUIRED'; END IF;

  UPDATE public.inventory_purchase_orders SET
    status = CASE WHEN p_approve THEN 'store_approved' ELSE 'draft' END,
    store_approved_by = CASE WHEN p_approve THEN auth.uid() ELSE NULL END,
    store_approved_at = CASE WHEN p_approve THEN now() ELSE NULL END,
    row_version = row_version + 1, updated_at = now()
  WHERE id = v_order.id RETURNING * INTO v_order;
  PERFORM public.append_inventory_purchase_approval_event(
    v_order.id,
    CASE WHEN p_approve THEN 'store_approved' ELSE 'store_returned' END,
    'submitted', CASE WHEN p_approve THEN 'store_approved' ELSE 'draft' END,
    v_reason
  );
  RETURN v_order;
END;
$$;

CREATE OR REPLACE FUNCTION public.brand_decide_inventory_purchase_order(
  p_purchase_order_id uuid,
  p_expected_version integer,
  p_approve boolean,
  p_reason text DEFAULT NULL
) RETURNS public.inventory_purchase_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_role text := public.inventory_purchase_actor_role();
  v_reason text := NULLIF(btrim(COALESCE(p_reason, '')), '');
  v_snapshot jsonb;
  v_hash text;
  v_snapshot_version integer;
BEGIN
  SELECT * INTO v_order FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND'; END IF;
  IF NOT public.can_access_inventory_purchase_store(v_order.restaurant_id)
     OR v_role NOT IN ('brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_BRAND_APPROVAL_FORBIDDEN';
  END IF;
  IF v_order.created_by IS NOT DISTINCT FROM auth.uid()
     OR v_order.store_approved_by IS NOT DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_SELF_APPROVAL_FORBIDDEN';
  END IF;
  IF v_order.status <> 'store_approved' THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_INVALID_TRANSITION'; END IF;
  IF v_order.row_version <> p_expected_version THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_STALE_VERSION'; END IF;
  IF NOT p_approve AND v_reason IS NULL THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_RETURN_REASON_REQUIRED'; END IF;

  IF p_approve THEN
    SELECT jsonb_build_object(
      'order', jsonb_build_object(
        'id', po.id, 'purchase_order_no', po.purchase_order_no,
        'restaurant_id', po.restaurant_id, 'brand_id', po.brand_id,
        'supplier_id', po.supplier_id,
        'requested_delivery_date', po.requested_delivery_date,
        'total_supply_amount', po.total_supply_amount,
        'tax_amount', po.tax_amount, 'total_amount', po.total_amount,
        'memo', po.memo, 'store_approved_by', po.store_approved_by,
        'store_approved_at', po.store_approved_at,
        'brand_approved_by', auth.uid(), 'brand_approved_at', now()
      ),
      'lines', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', pol.id, 'product_id', pol.product_id,
          'supplier_item_id', pol.supplier_item_id,
          'ordered_quantity_base', pol.ordered_quantity_base,
          'ordered_quantity_unit', pol.ordered_quantity_unit,
          'order_unit', pol.order_unit, 'unit_price', pol.unit_price,
          'supply_amount', pol.supply_amount, 'tax_amount', pol.tax_amount,
          'memo', pol.memo
        ) ORDER BY pol.created_at, pol.id)
        FROM public.inventory_purchase_order_lines pol
        WHERE pol.purchase_order_id = po.id
      ), '[]'::jsonb)
    ) INTO v_snapshot
    FROM public.inventory_purchase_orders po WHERE po.id = v_order.id;
    v_snapshot_version := COALESCE(v_order.approval_snapshot_version, 0) + 1;
    v_hash := encode(digest(convert_to(v_snapshot::text, 'UTF8'), 'sha256'), 'hex');

    UPDATE public.inventory_purchase_orders SET
      status = 'ordered', brand_approved_by = auth.uid(),
      brand_approved_at = now(), approval_snapshot = v_snapshot,
      approval_snapshot_version = v_snapshot_version,
      approval_snapshot_hash = v_hash, document_status = 'pending',
      document_last_error = NULL, row_version = row_version + 1,
      updated_at = now()
    WHERE id = v_order.id RETURNING * INTO v_order;

    INSERT INTO public.inventory_purchase_documents(
      purchase_order_id, restaurant_id, snapshot_version, status
    ) VALUES (v_order.id, v_order.restaurant_id, v_snapshot_version, 'pending')
    ON CONFLICT (purchase_order_id, snapshot_version) DO NOTHING;
  ELSE
    UPDATE public.inventory_purchase_orders SET
      status = 'draft', store_approved_by = NULL, store_approved_at = NULL,
      row_version = row_version + 1, updated_at = now()
    WHERE id = v_order.id RETURNING * INTO v_order;
  END IF;

  PERFORM public.append_inventory_purchase_approval_event(
    v_order.id,
    CASE WHEN p_approve THEN 'brand_approved' ELSE 'brand_returned' END,
    'store_approved', CASE WHEN p_approve THEN 'ordered' ELSE 'draft' END,
    v_reason,
    CASE WHEN p_approve THEN jsonb_build_object(
      'snapshot_version', v_snapshot_version, 'snapshot_hash', v_hash
    ) ELSE '{}'::jsonb END
  );
  RETURN v_order;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_inventory_purchase_document_result(
  p_purchase_order_id uuid,
  p_snapshot_version integer,
  p_success boolean,
  p_storage_path text DEFAULT NULL,
  p_sha256 text DEFAULT NULL,
  p_byte_size bigint DEFAULT NULL,
  p_error text DEFAULT NULL
) RETURNS public.inventory_purchase_documents
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_document public.inventory_purchase_documents%ROWTYPE;
BEGIN
  SELECT * INTO v_order FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND'; END IF;
  IF NOT public.can_access_inventory_purchase_store(v_order.restaurant_id)
     OR public.inventory_purchase_actor_role() NOT IN ('brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_DOCUMENT_FORBIDDEN';
  END IF;
  IF v_order.status NOT IN ('ordered', 'partially_received', 'received')
     OR v_order.approval_snapshot_version IS DISTINCT FROM p_snapshot_version THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_DOCUMENT_SNAPSHOT_INVALID';
  END IF;
  IF p_success AND (
    NULLIF(btrim(COALESCE(p_storage_path, '')), '') IS NULL
    OR p_sha256 !~ '^[a-f0-9]{64}$'
  ) THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_DOCUMENT_METADATA_INVALID'; END IF;

  UPDATE public.inventory_purchase_documents SET
    status = CASE WHEN p_success THEN 'ready' ELSE 'failed' END,
    storage_path = CASE WHEN p_success THEN p_storage_path ELSE storage_path END,
    sha256 = CASE WHEN p_success THEN p_sha256 ELSE sha256 END,
    byte_size = CASE WHEN p_success THEN p_byte_size ELSE byte_size END,
    last_error = CASE WHEN p_success THEN NULL ELSE p_error END,
    generated_by = auth.uid(), generated_at = now(), updated_at = now()
  WHERE purchase_order_id = v_order.id AND snapshot_version = p_snapshot_version
  RETURNING * INTO v_document;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_DOCUMENT_NOT_FOUND'; END IF;

  UPDATE public.inventory_purchase_orders SET
    document_status = CASE WHEN p_success THEN 'ready' ELSE 'failed' END,
    document_last_error = CASE WHEN p_success THEN NULL ELSE p_error END,
    updated_at = now()
  WHERE id = v_order.id;
  PERFORM public.append_inventory_purchase_approval_event(
    v_order.id, CASE WHEN p_success THEN 'document_ready' ELSE 'document_failed' END,
    v_order.status, v_order.status, p_error,
    jsonb_build_object('snapshot_version', p_snapshot_version)
  );
  RETURN v_document;
END;
$$;

CREATE OR REPLACE FUNCTION public.upsert_inventory_receipt_draft_line(
  p_purchase_order_id uuid,
  p_purchase_order_line_id uuid,
  p_received_quantity_base numeric,
  p_rejected_quantity_base numeric DEFAULT 0,
  p_actual_unit_price numeric DEFAULT NULL,
  p_discrepancy_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_order_line public.inventory_purchase_order_lines%ROWTYPE;
  v_receipt public.inventory_receipts%ROWTYPE;
  v_received numeric(12,3) := COALESCE(p_received_quantity_base, 0);
  v_rejected numeric(12,3) := COALESCE(p_rejected_quantity_base, 0);
  v_accepted numeric(12,3);
  v_cycle integer;
  v_line_count integer;
BEGIN
  SELECT * INTO v_order FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND'; END IF;
  IF NOT public.can_create_inventory_purchase_order(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_DRAFT_FORBIDDEN';
  END IF;
  IF v_order.status NOT IN ('ordered', 'partially_received', 'office_approved') THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_RECEIVABLE';
  END IF;
  IF v_received < 0 OR v_rejected < 0 OR v_rejected > v_received THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_QUANTITY_INVALID';
  END IF;
  IF p_actual_unit_price IS NOT NULL AND p_actual_unit_price < 0 THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_PRICE_INVALID';
  END IF;

  SELECT * INTO v_order_line FROM public.inventory_purchase_order_lines
  WHERE id = p_purchase_order_line_id
    AND purchase_order_id = v_order.id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_LINE_NOT_FOUND'; END IF;

  SELECT * INTO v_receipt FROM public.inventory_receipts
  WHERE purchase_order_id = v_order.id AND status = 'draft'
  ORDER BY created_at DESC LIMIT 1 FOR UPDATE;

  IF v_received <= 0 THEN
    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'receipt_id', NULL, 'status', 'empty', 'row_version', 0,
        'line_count', 0
      );
    END IF;
    IF v_receipt.received_by IS DISTINCT FROM auth.uid()
       AND public.inventory_purchase_actor_role() = 'inventory_orderer' THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_DRAFT_OWNER_REQUIRED';
    END IF;
    DELETE FROM public.inventory_receipt_lines
    WHERE receipt_id = v_receipt.id
      AND purchase_order_line_id = v_order_line.id;
    SELECT count(*) INTO v_line_count FROM public.inventory_receipt_lines
    WHERE receipt_id = v_receipt.id;
    IF v_line_count = 0 THEN
      UPDATE public.inventory_receipts SET
        status = 'cancelled', row_version = row_version + 1, updated_at = now()
      WHERE id = v_receipt.id RETURNING * INTO v_receipt;
    ELSE
      UPDATE public.inventory_receipts SET
        row_version = row_version + 1, updated_at = now()
      WHERE id = v_receipt.id RETURNING * INTO v_receipt;
    END IF;
    RETURN jsonb_build_object(
      'receipt_id', v_receipt.id, 'status', v_receipt.status,
      'row_version', v_receipt.row_version, 'line_count', v_line_count
    );
  END IF;

  IF v_receipt.id IS NULL THEN
    SELECT COALESCE(max(delivery_cycle), 0) + 1 INTO v_cycle
    FROM public.inventory_receipts WHERE purchase_order_id = v_order.id;
    INSERT INTO public.inventory_receipts(
      purchase_order_id, restaurant_id, supplier_id, received_by,
      status, delivery_cycle
    ) VALUES (
      v_order.id, v_order.restaurant_id, v_order.supplier_id, auth.uid(),
      'draft', v_cycle
    ) RETURNING * INTO v_receipt;
  ELSIF v_receipt.received_by IS DISTINCT FROM auth.uid()
        AND public.inventory_purchase_actor_role() = 'inventory_orderer' THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_DRAFT_OWNER_REQUIRED';
  END IF;

  v_accepted := v_received - v_rejected;
  INSERT INTO public.inventory_receipt_lines(
    receipt_id, purchase_order_line_id, product_id,
    received_quantity_base, accepted_quantity_base,
    rejected_quantity_base, actual_unit_price, discrepancy_reason, updated_at
  ) VALUES (
    v_receipt.id, v_order_line.id, v_order_line.product_id,
    v_received, v_accepted, v_rejected,
    COALESCE(p_actual_unit_price, v_order_line.unit_price),
    NULLIF(btrim(COALESCE(p_discrepancy_reason, '')), ''), now()
  ) ON CONFLICT (receipt_id, purchase_order_line_id)
    WHERE purchase_order_line_id IS NOT NULL
  DO UPDATE SET
    received_quantity_base = EXCLUDED.received_quantity_base,
    accepted_quantity_base = EXCLUDED.accepted_quantity_base,
    rejected_quantity_base = EXCLUDED.rejected_quantity_base,
    actual_unit_price = EXCLUDED.actual_unit_price,
    discrepancy_reason = EXCLUDED.discrepancy_reason,
    updated_at = now();

  UPDATE public.inventory_receipts SET
    row_version = row_version + 1, updated_at = now()
  WHERE id = v_receipt.id RETURNING * INTO v_receipt;
  SELECT count(*) INTO v_line_count FROM public.inventory_receipt_lines
  WHERE receipt_id = v_receipt.id;
  RETURN jsonb_build_object(
    'receipt_id', v_receipt.id, 'status', v_receipt.status,
    'row_version', v_receipt.row_version, 'line_count', v_line_count,
    'saved_at', v_receipt.updated_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.update_inventory_receipt_draft_metadata(
  p_receipt_id uuid,
  p_expected_version integer,
  p_statement_number text,
  p_statement_date date,
  p_statement_storage_path text DEFAULT NULL,
  p_memo text DEFAULT NULL
) RETURNS public.inventory_receipts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_receipt public.inventory_receipts%ROWTYPE;
BEGIN
  SELECT * INTO v_receipt FROM public.inventory_receipts
  WHERE id = p_receipt_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_NOT_FOUND'; END IF;
  IF NOT (
    public.can_create_inventory_purchase_order(v_receipt.restaurant_id)
    OR public.can_verify_inventory_receipt(v_receipt.restaurant_id)
  ) THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_DRAFT_FORBIDDEN';
  END IF;
  IF v_receipt.status <> 'draft' THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_NOT_EDITABLE'; END IF;
  IF v_receipt.row_version <> p_expected_version THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_STALE_VERSION'; END IF;
  IF v_receipt.received_by IS DISTINCT FROM auth.uid()
     AND public.inventory_purchase_actor_role() = 'inventory_orderer' THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_DRAFT_OWNER_REQUIRED';
  END IF;
  UPDATE public.inventory_receipts SET
    statement_number = NULLIF(btrim(COALESCE(p_statement_number, '')), ''),
    statement_date = p_statement_date,
    statement_storage_path = NULLIF(btrim(COALESCE(p_statement_storage_path, '')), ''),
    memo = NULLIF(btrim(COALESCE(p_memo, '')), ''),
    row_version = row_version + 1, updated_at = now()
  WHERE id = v_receipt.id RETURNING * INTO v_receipt;
  RETURN v_receipt;
END;
$$;

CREATE OR REPLACE FUNCTION public.verify_inventory_receipt(
  p_receipt_id uuid,
  p_expected_version integer,
  p_idempotency_key text,
  p_lines jsonb DEFAULT '[]'::jsonb,
  p_verification_reason text DEFAULT NULL
) RETURNS public.inventory_purchase_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_receipt public.inventory_receipts%ROWTYPE;
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_line jsonb;
  v_receipt_line public.inventory_receipt_lines%ROWTYPE;
  v_order_line public.inventory_purchase_order_lines%ROWTYPE;
  v_accepted numeric(12,3);
  v_rejected numeric(12,3);
  v_price numeric(12,2);
  v_reason text;
  v_conversion numeric(12,3);
  v_unit_quantity numeric(12,3);
  v_tax_rate numeric(5,2);
  v_supply numeric(12,2) := 0;
  v_tax numeric(12,2) := 0;
  v_ordered_total numeric(12,3);
  v_accepted_before numeric(12,3);
  v_accepted_after numeric(12,3);
  v_attempt_key text := NULLIF(btrim(COALESCE(p_idempotency_key, '')), '');
BEGIN
  IF v_attempt_key IS NULL THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_IDEMPOTENCY_KEY_REQUIRED'; END IF;
  SELECT * INTO v_receipt FROM public.inventory_receipts
  WHERE id = p_receipt_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_NOT_FOUND'; END IF;
  SELECT * INTO v_order FROM public.inventory_purchase_orders
  WHERE id = v_receipt.purchase_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND'; END IF;
  IF NOT public.can_verify_inventory_receipt(v_receipt.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_VERIFY_FORBIDDEN';
  END IF;
  IF v_receipt.received_by IS NOT DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_MAKER_CHECKER_REQUIRED';
  END IF;
  IF v_receipt.status = 'confirmed' THEN RETURN v_order; END IF;
  IF v_receipt.status <> 'draft' THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_NOT_VERIFIABLE'; END IF;
  IF v_receipt.row_version <> p_expected_version THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_STALE_VERSION'; END IF;
  IF v_receipt.statement_number IS NULL OR v_receipt.statement_date IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_STATEMENT_REQUIRED';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.inventory_receipt_confirmation_attempts
    WHERE purchase_order_id = v_order.id AND attempt_key = v_attempt_key
  ) THEN RETURN v_order; END IF;

  SELECT COALESCE(sum(ordered_quantity_base), 0) INTO v_ordered_total
  FROM public.inventory_purchase_order_lines WHERE purchase_order_id = v_order.id;
  SELECT COALESCE(sum(irl.accepted_quantity_base), 0) INTO v_accepted_before
  FROM public.inventory_receipt_lines irl
  JOIN public.inventory_receipts ir ON ir.id = irl.receipt_id
  WHERE ir.purchase_order_id = v_order.id AND ir.status = 'confirmed';

  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array'
     AND jsonb_array_length(p_lines) > 0 THEN
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
      SELECT * INTO v_receipt_line FROM public.inventory_receipt_lines
      WHERE receipt_id = v_receipt.id
        AND purchase_order_line_id = NULLIF(
          v_line->>'purchase_order_line_id', ''
        )::uuid FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_LINE_NOT_FOUND'; END IF;
      SELECT * INTO v_order_line FROM public.inventory_purchase_order_lines
      WHERE id = v_receipt_line.purchase_order_line_id;
      v_accepted := COALESCE(
        NULLIF(v_line->>'accepted_quantity_base', '')::numeric,
        v_receipt_line.accepted_quantity_base
      );
      v_rejected := COALESCE(
        NULLIF(v_line->>'rejected_quantity_base', '')::numeric,
        v_receipt_line.rejected_quantity_base
      );
      v_price := COALESCE(
        NULLIF(v_line->>'actual_unit_price', '')::numeric,
        v_receipt_line.actual_unit_price, v_order_line.unit_price
      );
      v_reason := COALESCE(
        NULLIF(btrim(COALESCE(v_line->>'discrepancy_reason', '')), ''),
        v_receipt_line.discrepancy_reason
      );
      IF v_accepted < 0 OR v_rejected < 0 OR v_price < 0 THEN
        RAISE EXCEPTION 'INVENTORY_RECEIPT_FINAL_VALUE_INVALID';
      END IF;
      IF (v_accepted IS DISTINCT FROM v_receipt_line.accepted_quantity_base
          OR v_price IS DISTINCT FROM v_order_line.unit_price)
         AND v_reason IS NULL THEN
        RAISE EXCEPTION 'INVENTORY_RECEIPT_DISCREPANCY_REASON_REQUIRED';
      END IF;
      UPDATE public.inventory_receipt_lines SET
        received_quantity_base = v_accepted + v_rejected,
        accepted_quantity_base = v_accepted,
        rejected_quantity_base = v_rejected,
        actual_unit_price = v_price,
        discrepancy_reason = v_reason,
        updated_at = now()
      WHERE id = v_receipt_line.id;
    END LOOP;
  END IF;

  FOR v_receipt_line IN
    SELECT * FROM public.inventory_receipt_lines
    WHERE receipt_id = v_receipt.id FOR UPDATE
  LOOP
    SELECT * INTO v_order_line FROM public.inventory_purchase_order_lines
    WHERE id = v_receipt_line.purchase_order_line_id;
    SELECT COALESCE(isi.order_unit_quantity_base,
      NULLIF(v_order_line.ordered_quantity_base, 0) /
        NULLIF(v_order_line.ordered_quantity_unit, 0), 1),
      COALESCE(isi.tax_rate, 0)
    INTO v_conversion, v_tax_rate
    FROM public.inventory_supplier_items isi
    WHERE isi.id = v_order_line.supplier_item_id;
    v_conversion := COALESCE(v_conversion, 1);
    v_tax_rate := COALESCE(v_tax_rate, 0);
    v_unit_quantity := v_receipt_line.accepted_quantity_base / v_conversion;
    UPDATE public.inventory_receipt_lines SET
      actual_unit_price = COALESCE(actual_unit_price, v_order_line.unit_price),
      final_supply_amount = round(v_unit_quantity *
        COALESCE(actual_unit_price, v_order_line.unit_price), 2),
      final_tax_amount = round(v_unit_quantity *
        COALESCE(actual_unit_price, v_order_line.unit_price) * v_tax_rate / 100, 2),
      updated_at = now()
    WHERE id = v_receipt_line.id
    RETURNING final_supply_amount, final_tax_amount INTO v_supply, v_tax;
    v_receipt.total_supply_amount := v_receipt.total_supply_amount + v_supply;
    v_receipt.tax_amount := v_receipt.tax_amount + v_tax;
  END LOOP;

  UPDATE public.inventory_items ii SET
    current_stock = COALESCE(ii.current_stock, 0) + received.accepted_quantity_base,
    quantity = COALESCE(ii.quantity, 0) + received.accepted_quantity_base,
    updated_at = now()
  FROM (
    SELECT ip.inventory_item_id,
      sum(irl.accepted_quantity_base) accepted_quantity_base
    FROM public.inventory_receipt_lines irl
    JOIN public.inventory_products ip ON ip.id = irl.product_id
    WHERE irl.receipt_id = v_receipt.id AND ip.inventory_item_id IS NOT NULL
    GROUP BY ip.inventory_item_id
  ) received
  WHERE ii.id = received.inventory_item_id
    AND ii.restaurant_id = v_order.restaurant_id;

  INSERT INTO public.inventory_transactions(
    restaurant_id, ingredient_id, transaction_type, quantity_g,
    reference_type, reference_id, note, created_by
  )
  SELECT v_order.restaurant_id, ip.inventory_item_id, 'restock',
    sum(irl.accepted_quantity_base), 'inventory_purchase_receipt', v_receipt.id,
    'Verified supplier statement ' || v_receipt.statement_number, auth.uid()
  FROM public.inventory_receipt_lines irl
  JOIN public.inventory_products ip ON ip.id = irl.product_id
  WHERE irl.receipt_id = v_receipt.id AND ip.inventory_item_id IS NOT NULL
    AND irl.accepted_quantity_base > 0
  GROUP BY ip.inventory_item_id;

  UPDATE public.inventory_receipts SET
    status = 'confirmed', verified_by = auth.uid(), verified_at = now(),
    total_supply_amount = v_receipt.total_supply_amount,
    tax_amount = v_receipt.tax_amount,
    total_amount = v_receipt.total_supply_amount + v_receipt.tax_amount,
    verification_reason = NULLIF(btrim(COALESCE(p_verification_reason, '')), ''),
    row_version = row_version + 1, updated_at = now()
  WHERE id = v_receipt.id RETURNING * INTO v_receipt;

  SELECT COALESCE(sum(irl.accepted_quantity_base), 0) INTO v_accepted_after
  FROM public.inventory_receipt_lines irl
  JOIN public.inventory_receipts ir ON ir.id = irl.receipt_id
  WHERE ir.purchase_order_id = v_order.id AND ir.status = 'confirmed';

  UPDATE public.inventory_purchase_orders SET
    status = CASE WHEN v_accepted_after >= v_ordered_total
      THEN 'received' ELSE 'partially_received' END,
    row_version = row_version + 1, updated_at = now()
  WHERE id = v_order.id RETURNING * INTO v_order;

  INSERT INTO public.inventory_receipt_confirmation_attempts(
    purchase_order_id, receipt_id, restaurant_id, actor_id, attempt_key,
    attempt_status, requested_line_count, accepted_total_quantity_base,
    rejected_total_quantity_base, remaining_quantity_before_base,
    remaining_quantity_after_base, metadata
  ) SELECT
    v_order.id, v_receipt.id, v_order.restaurant_id, auth.uid(), v_attempt_key,
    'succeeded', count(*)::integer,
    COALESCE(sum(accepted_quantity_base), 0),
    COALESCE(sum(rejected_quantity_base), 0),
    GREATEST(v_ordered_total - v_accepted_before, 0),
    GREATEST(v_ordered_total - v_accepted_after, 0),
    jsonb_build_object(
      'maker_checker', true, 'statement_number', v_receipt.statement_number,
      'order_status_after', v_order.status,
      'total_amount', v_receipt.total_amount
    )
  FROM public.inventory_receipt_lines WHERE receipt_id = v_receipt.id;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'inventory_receipt_verified', 'inventory_purchase_order',
    v_order.id, jsonb_build_object(
      'receipt_id', v_receipt.id,
      'statement_number', v_receipt.statement_number,
      'total_amount', v_receipt.total_amount,
      'order_status_after', v_order.status
    )
  );
  RETURN v_order;
END;
$$;

-- Cached clients may no longer create a confirmed receipt and mutate stock in
-- one call. They must first create a draft and use independent verification.
CREATE OR REPLACE FUNCTION public.confirm_inventory_purchase_receipt(
  p_purchase_order_id uuid,
  p_memo text DEFAULT NULL,
  p_lines jsonb DEFAULT '[]'::jsonb
) RETURNS public.inventory_purchase_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
  RAISE EXCEPTION 'INVENTORY_RECEIPT_DRAFT_AND_VERIFIER_REQUIRED';
END;
$$;

CREATE OR REPLACE FUNCTION public.bulk_update_inventory_supplier_prices(
  p_store_id uuid,
  p_rows jsonb,
  p_apply boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_row jsonb;
  v_item public.inventory_supplier_items%ROWTYPE;
  v_source_row integer;
  v_price numeric(12,2);
  v_tax numeric(5,2);
  v_effective date;
  v_error text;
  v_status text;
  v_errors jsonb := '[]'::jsonb;
  v_preview jsonb := '[]'::jsonb;
  v_seen uuid[] := ARRAY[]::uuid[];
  v_changed integer := 0;
  v_unchanged integer := 0;
  v_error_count integer := 0;
  v_import_id uuid := gen_random_uuid();
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id)
     OR public.inventory_purchase_actor_role() NOT IN (
       'admin', 'store_admin', 'brand_admin', 'super_admin'
     ) THEN RAISE EXCEPTION 'INVENTORY_PRICE_IMPORT_FORBIDDEN'; END IF;
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array'
     OR jsonb_array_length(p_rows) = 0 THEN
    RAISE EXCEPTION 'INVENTORY_PRICE_IMPORT_ROWS_REQUIRED';
  END IF;
  IF jsonb_array_length(p_rows) > 1000 THEN
    RAISE EXCEPTION 'INVENTORY_PRICE_IMPORT_LIMIT';
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    v_source_row := COALESCE(NULLIF(v_row->>'source_row', '')::integer, 0);
    v_error := NULL;
    BEGIN
      SELECT isi.* INTO v_item
      FROM public.inventory_supplier_items isi
      JOIN public.inventory_products ip ON ip.id = isi.product_id
      WHERE isi.id = NULLIF(v_row->>'supplier_item_id', '')::uuid
        AND ip.restaurant_id = p_store_id AND isi.is_active = true;
      IF NOT FOUND THEN v_error := 'SUPPLIER_ITEM_NOT_FOUND'; END IF;
    EXCEPTION WHEN invalid_text_representation THEN
      v_error := 'SUPPLIER_ITEM_ID_INVALID';
    END;
    IF v_error IS NULL AND v_item.id = ANY(v_seen) THEN
      v_error := 'DUPLICATE_SUPPLIER_ITEM';
    END IF;
    BEGIN
      v_price := NULLIF(v_row->>'new_unit_price', '')::numeric;
      IF v_price IS NULL OR v_price < 0 THEN v_error := COALESCE(v_error, 'UNIT_PRICE_INVALID'); END IF;
    EXCEPTION WHEN invalid_text_representation THEN
      v_error := COALESCE(v_error, 'UNIT_PRICE_INVALID');
    END;
    BEGIN
      v_tax := COALESCE(NULLIF(v_row->>'tax_rate', '')::numeric, v_item.tax_rate, 0);
      IF v_tax < 0 OR v_tax > 100 THEN v_error := COALESCE(v_error, 'TAX_RATE_INVALID'); END IF;
    EXCEPTION WHEN invalid_text_representation THEN
      v_error := COALESCE(v_error, 'TAX_RATE_INVALID');
    END;
    BEGIN
      v_effective := COALESCE(NULLIF(v_row->>'effective_date', '')::date, current_date);
    EXCEPTION WHEN invalid_datetime_format THEN
      v_error := COALESCE(v_error, 'EFFECTIVE_DATE_INVALID');
      v_effective := current_date;
    END;

    IF v_item.id IS NOT NULL THEN v_seen := array_append(v_seen, v_item.id); END IF;
    IF v_error IS NOT NULL THEN
      v_status := 'error'; v_error_count := v_error_count + 1;
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'source_row', v_source_row, 'error', v_error
      ));
    ELSIF v_item.unit_price IS NOT DISTINCT FROM v_price
          AND v_item.tax_rate IS NOT DISTINCT FROM v_tax THEN
      v_status := 'unchanged'; v_unchanged := v_unchanged + 1;
    ELSE
      v_status := 'changed'; v_changed := v_changed + 1;
    END IF;
    v_preview := v_preview || jsonb_build_array(jsonb_build_object(
      'source_row', v_source_row,
      'supplier_item_id', v_item.id,
      'old_unit_price', v_item.unit_price,
      'new_unit_price', v_price,
      'tax_rate', v_tax,
      'effective_date', v_effective,
      'status', v_status,
      'error', v_error
    ));
  END LOOP;

  IF p_apply AND v_error_count = 0 THEN
    FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
      SELECT * INTO v_item FROM public.inventory_supplier_items
      WHERE id = (v_row->>'supplier_item_id')::uuid FOR UPDATE;
      v_price := (v_row->>'new_unit_price')::numeric;
      v_tax := COALESCE(NULLIF(v_row->>'tax_rate', '')::numeric, v_item.tax_rate, 0);
      v_effective := COALESCE(NULLIF(v_row->>'effective_date', '')::date, current_date);
      PERFORM set_config('app.inventory_price_source', 'excel', true);
      PERFORM set_config('app.inventory_price_import_id', v_import_id::text, true);
      PERFORM set_config('app.inventory_price_effective_date', v_effective::text, true);
      PERFORM set_config('app.inventory_price_source_row', COALESCE(v_row->>'source_row', ''), true);
      PERFORM set_config('app.inventory_price_note', COALESCE(v_row->>'note', ''), true);
      UPDATE public.inventory_supplier_items SET
        unit_price = v_price, tax_rate = v_tax, updated_at = now()
      WHERE id = v_item.id
        AND (unit_price IS DISTINCT FROM v_price OR tax_rate IS DISTINCT FROM v_tax);
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'import_id', v_import_id,
    'applied', p_apply AND v_error_count = 0,
    'can_apply', v_error_count = 0,
    'changed_count', v_changed,
    'unchanged_count', v_unchanged,
    'error_count', v_error_count,
    'errors', v_errors,
    'rows', v_preview
  );
END;
$$;

INSERT INTO storage.buckets(id, name, public, file_size_limit)
VALUES ('inventory-purchase-documents', 'inventory-purchase-documents', false, 10485760)
ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = 10485760;

INSERT INTO storage.buckets(id, name, public, file_size_limit)
VALUES ('inventory-receipt-statements', 'inventory-receipt-statements', false, 10485760)
ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = 10485760;

DROP POLICY IF EXISTS inventory_purchase_document_objects_read ON storage.objects;
CREATE POLICY inventory_purchase_document_objects_read
ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'inventory-purchase-documents'
  AND public.can_access_inventory_purchase_store(
    NULLIF((storage.foldername(name))[1], '')::uuid
  )
);

DROP POLICY IF EXISTS inventory_purchase_document_objects_write ON storage.objects;
CREATE POLICY inventory_purchase_document_objects_write
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'inventory-purchase-documents'
  AND public.can_access_inventory_purchase_store(
    NULLIF((storage.foldername(name))[1], '')::uuid
  )
  AND public.inventory_purchase_actor_role() IN ('brand_admin', 'super_admin')
);

DROP POLICY IF EXISTS inventory_receipt_statement_objects_read ON storage.objects;
CREATE POLICY inventory_receipt_statement_objects_read
ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'inventory-receipt-statements'
  AND public.can_access_inventory_purchase_store(
    NULLIF((storage.foldername(name))[1], '')::uuid
  )
);

DROP POLICY IF EXISTS inventory_receipt_statement_objects_write ON storage.objects;
CREATE POLICY inventory_receipt_statement_objects_write
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'inventory-receipt-statements'
  AND (
    public.can_create_inventory_purchase_order(
      NULLIF((storage.foldername(name))[1], '')::uuid
    )
    OR public.can_verify_inventory_receipt(
      NULLIF((storage.foldername(name))[1], '')::uuid
    )
  )
);

GRANT SELECT ON public.inventory_purchase_approval_events,
  public.inventory_purchase_documents,
  public.inventory_supplier_item_price_history TO authenticated;
GRANT SELECT ON public.legal_entity_fixed_account_requirements TO authenticated;
GRANT ALL ON public.user_tax_entity_access,
  public.legal_entity_fixed_account_requirements TO service_role;

REVOKE ALL ON FUNCTION public.admin_configure_legal_entity_inventory_accounting(
  uuid, text, text
) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.inventory_purchase_actor_role() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.can_create_inventory_purchase_order(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.can_verify_inventory_receipt(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.append_inventory_purchase_approval_event(
  uuid, text, text, text, text, jsonb
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.save_inventory_purchase_order_draft(
  uuid, integer, date, text, jsonb
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.delete_inventory_purchase_order_draft(
  uuid, integer, text
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.submit_inventory_purchase_order(
  uuid, integer
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.store_decide_inventory_purchase_order(
  uuid, integer, boolean, text
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.brand_decide_inventory_purchase_order(
  uuid, integer, boolean, text
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.record_inventory_purchase_document_result(
  uuid, integer, boolean, text, text, bigint, text
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.upsert_inventory_receipt_draft_line(
  uuid, uuid, numeric, numeric, numeric, text
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_inventory_receipt_draft_metadata(
  uuid, integer, text, date, text, text
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.verify_inventory_receipt(
  uuid, integer, text, jsonb, text
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.bulk_update_inventory_supplier_prices(
  uuid, jsonb, boolean
) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.inventory_purchase_actor_role() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_configure_legal_entity_inventory_accounting(
  uuid, text, text
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_create_inventory_purchase_order(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_verify_inventory_receipt(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_inventory_purchase_order_draft(
  uuid, integer, date, text, jsonb
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_inventory_purchase_order_draft(
  uuid, integer, text
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_inventory_purchase_order(
  uuid, integer
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.store_decide_inventory_purchase_order(
  uuid, integer, boolean, text
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.brand_decide_inventory_purchase_order(
  uuid, integer, boolean, text
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_inventory_purchase_document_result(
  uuid, integer, boolean, text, text, bigint, text
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_inventory_receipt_draft_line(
  uuid, uuid, numeric, numeric, numeric, text
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_inventory_receipt_draft_metadata(
  uuid, integer, text, date, text, text
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_inventory_receipt(
  uuid, integer, text, jsonb, text
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bulk_update_inventory_supplier_prices(
  uuid, jsonb, boolean
) TO authenticated;

DO $$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.confirm_inventory_purchase_receipt(uuid,text,jsonb)'::regprocedure
  ) INTO v_definition;
  IF position('INVENTORY_RECEIPT_DRAFT_AND_VERIFIER_REQUIRED' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_LEGACY_RECEIPT_GATE_FAILED';
  END IF;
  IF to_regclass('public.inventory_purchase_approval_events') IS NULL
     OR to_regclass('public.inventory_purchase_documents') IS NULL
     OR to_regclass('public.inventory_supplier_item_price_history') IS NULL
     OR to_regclass('public.user_tax_entity_access') IS NULL
     OR to_regclass('public.legal_entity_fixed_account_requirements') IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FOUNDATION_MISSING';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.users'::regclass
      AND conname = 'users_role_check'
      AND pg_get_constraintdef(oid) LIKE '%inventory_orderer%'
      AND pg_get_constraintdef(oid) LIKE '%inventory_accounting%'
  ) THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_ROLE_CONTRACT_FAILED'; END IF;
  SELECT pg_get_functiondef(
    'public.user_accessible_stores(uuid)'::regprocedure
  ) INTO v_definition;
  IF position('user_tax_entity_access' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'LEGAL_ENTITY_ACCOUNTING_STORE_SCOPE_FAILED';
  END IF;
  SELECT pg_get_functiondef(
    'public.can_verify_inventory_receipt(uuid)'::regprocedure
  ) INTO v_definition;
  IF position('inventory_accounting' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'LEGAL_ENTITY_ACCOUNTING_RECEIPT_GATE_FAILED';
  END IF;
END;
$$;

COMMIT;
