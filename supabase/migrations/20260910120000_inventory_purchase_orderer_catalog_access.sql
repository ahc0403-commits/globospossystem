BEGIN;

-- production-gate: self-verifying
-- Keep master-data mutation restricted to managers while allowing purchase
-- operators to read and work with the catalog for their assigned stores.

CREATE OR REPLACE FUNCTION public.can_access_inventory_purchase_store(
  p_store_id uuid
) RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_role text;
BEGIN
  IF p_store_id IS NULL THEN
    RETURN false;
  END IF;

  IF auth.role() = 'service_role' THEN
    RETURN true;
  END IF;

  SELECT actor.role
  INTO v_role
  FROM public.users actor
  WHERE actor.auth_id = auth.uid()
    AND actor.is_active = true
  LIMIT 1;

  IF v_role = 'super_admin' THEN
    RETURN true;
  END IF;

  IF COALESCE(v_role, '') NOT IN ('admin', 'store_admin', 'brand_admin') THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.user_accessible_stores(auth.uid()) scope(store_id)
    WHERE scope.store_id = p_store_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.can_read_inventory_purchase_store(
  p_store_id uuid
) RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_role text;
BEGIN
  IF p_store_id IS NULL THEN
    RETURN false;
  END IF;

  IF auth.role() = 'service_role' THEN
    RETURN true;
  END IF;

  SELECT actor.role
  INTO v_role
  FROM public.users actor
  WHERE actor.auth_id = auth.uid()
    AND actor.is_active = true
  LIMIT 1;

  IF v_role = 'super_admin' THEN
    RETURN true;
  END IF;

  IF COALESCE(v_role, '') NOT IN (
    'inventory_orderer',
    'inventory_accounting',
    'admin',
    'store_admin',
    'brand_admin'
  ) THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.user_accessible_stores(auth.uid()) scope(store_id)
    WHERE scope.store_id = p_store_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.can_create_inventory_purchase_order(
  p_store_id uuid
) RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT public.can_read_inventory_purchase_store(p_store_id)
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
  SELECT public.can_read_inventory_purchase_store(p_store_id)
    AND COALESCE(public.inventory_purchase_actor_role(), '') =
      'inventory_accounting'
$$;

DROP POLICY IF EXISTS inventory_products_store_read
  ON public.inventory_products;
CREATE POLICY inventory_products_store_read
  ON public.inventory_products FOR SELECT TO authenticated
  USING (public.can_read_inventory_purchase_store(restaurant_id));

DROP POLICY IF EXISTS inventory_suppliers_authenticated_read
  ON public.inventory_suppliers;
DROP POLICY IF EXISTS inventory_suppliers_scoped_read
  ON public.inventory_suppliers;
DROP POLICY IF EXISTS inventory_suppliers_store_read
  ON public.inventory_suppliers;
DROP POLICY IF EXISTS inventory_suppliers_purchase_read
  ON public.inventory_suppliers;
CREATE POLICY inventory_suppliers_purchase_read
  ON public.inventory_suppliers FOR SELECT TO authenticated
  USING (
    auth.role() = 'service_role'
    OR EXISTS (
      SELECT 1
      FROM public.restaurants store
      WHERE (
        inventory_suppliers.brand_id IS NULL
        OR store.brand_id = inventory_suppliers.brand_id
      )
        AND public.can_read_inventory_purchase_store(store.id)
    )
  );

DROP POLICY IF EXISTS inventory_supplier_items_authenticated_read
  ON public.inventory_supplier_items;
DROP POLICY IF EXISTS inventory_supplier_items_scoped_read
  ON public.inventory_supplier_items;
DROP POLICY IF EXISTS inventory_supplier_items_store_read
  ON public.inventory_supplier_items;
DROP POLICY IF EXISTS inventory_supplier_items_purchase_read
  ON public.inventory_supplier_items;
CREATE POLICY inventory_supplier_items_purchase_read
  ON public.inventory_supplier_items FOR SELECT TO authenticated
  USING (
    auth.role() = 'service_role'
    OR EXISTS (
      SELECT 1
      FROM public.inventory_products product
      JOIN public.inventory_suppliers supplier
        ON supplier.id = inventory_supplier_items.supplier_id
      WHERE product.id = inventory_supplier_items.product_id
        AND (
          supplier.brand_id IS NULL
          OR supplier.brand_id = product.brand_id
        )
        AND public.can_read_inventory_purchase_store(product.restaurant_id)
    )
  );

DROP POLICY IF EXISTS inventory_purchase_orders_store_read
  ON public.inventory_purchase_orders;
CREATE POLICY inventory_purchase_orders_store_read
  ON public.inventory_purchase_orders FOR SELECT TO authenticated
  USING (public.can_read_inventory_purchase_store(restaurant_id));

DROP POLICY IF EXISTS inventory_purchase_order_lines_store_read
  ON public.inventory_purchase_order_lines;
CREATE POLICY inventory_purchase_order_lines_store_read
  ON public.inventory_purchase_order_lines FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.inventory_purchase_orders purchase_order
      WHERE purchase_order.id =
        inventory_purchase_order_lines.purchase_order_id
        AND public.can_read_inventory_purchase_store(
          purchase_order.restaurant_id
        )
    )
  );

DROP POLICY IF EXISTS inventory_receipts_store_read
  ON public.inventory_receipts;
CREATE POLICY inventory_receipts_store_read
  ON public.inventory_receipts FOR SELECT TO authenticated
  USING (public.can_read_inventory_purchase_store(restaurant_id));

DROP POLICY IF EXISTS inventory_receipt_lines_store_read
  ON public.inventory_receipt_lines;
CREATE POLICY inventory_receipt_lines_store_read
  ON public.inventory_receipt_lines FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.inventory_receipts receipt
      WHERE receipt.id = inventory_receipt_lines.receipt_id
        AND public.can_read_inventory_purchase_store(receipt.restaurant_id)
    )
  );

DROP POLICY IF EXISTS inventory_purchase_approval_events_read
  ON public.inventory_purchase_approval_events;
CREATE POLICY inventory_purchase_approval_events_read
  ON public.inventory_purchase_approval_events FOR SELECT TO authenticated
  USING (public.can_read_inventory_purchase_store(restaurant_id));

DROP POLICY IF EXISTS inventory_purchase_documents_read
  ON public.inventory_purchase_documents;
CREATE POLICY inventory_purchase_documents_read
  ON public.inventory_purchase_documents FOR SELECT TO authenticated
  USING (public.can_read_inventory_purchase_store(restaurant_id));

DROP POLICY IF EXISTS inventory_supplier_price_history_read
  ON public.inventory_supplier_item_price_history;
CREATE POLICY inventory_supplier_price_history_read
  ON public.inventory_supplier_item_price_history FOR SELECT TO authenticated
  USING (public.can_read_inventory_purchase_store(restaurant_id));

DROP POLICY IF EXISTS inventory_receipt_attempts_scoped_read
  ON public.inventory_receipt_confirmation_attempts;
CREATE POLICY inventory_receipt_attempts_scoped_read
  ON public.inventory_receipt_confirmation_attempts FOR SELECT TO authenticated
  USING (public.can_read_inventory_purchase_store(restaurant_id));

CREATE OR REPLACE FUNCTION public.enforce_inventory_purchase_order_line_scope()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_item record;
BEGIN
  IF NEW.supplier_item_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders purchase_order
  WHERE purchase_order.id = NEW.purchase_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND';
  END IF;

  SELECT
    supplier_item.product_id,
    supplier_item.supplier_id,
    supplier_item.is_active AS supplier_item_active,
    product.restaurant_id,
    product.is_active AS product_active,
    product.is_orderable,
    supplier.status AS supplier_status
  INTO v_item
  FROM public.inventory_supplier_items supplier_item
  JOIN public.inventory_products product
    ON product.id = supplier_item.product_id
  JOIN public.inventory_suppliers supplier
    ON supplier.id = supplier_item.supplier_id
  WHERE supplier_item.id = NEW.supplier_item_id;

  IF NOT FOUND
     OR v_item.product_id IS DISTINCT FROM NEW.product_id
     OR v_item.supplier_id IS DISTINCT FROM v_order.supplier_id
     OR v_item.restaurant_id IS DISTINCT FROM v_order.restaurant_id
     OR NOT v_item.supplier_item_active
     OR NOT v_item.product_active
     OR NOT v_item.is_orderable
     OR v_item.supplier_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_SUPPLIER_ITEM_SCOPE_INVALID';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS inventory_purchase_order_line_scope_trigger
  ON public.inventory_purchase_order_lines;
CREATE TRIGGER inventory_purchase_order_line_scope_trigger
BEFORE INSERT OR UPDATE OF purchase_order_id, product_id, supplier_item_id
ON public.inventory_purchase_order_lines
FOR EACH ROW
EXECUTE FUNCTION public.enforce_inventory_purchase_order_line_scope();

REVOKE ALL ON FUNCTION public.can_read_inventory_purchase_store(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_read_inventory_purchase_store(uuid)
  TO authenticated;

REVOKE ALL ON FUNCTION public.enforce_inventory_purchase_order_line_scope()
  FROM PUBLIC, anon, authenticated;

DO $verify$
DECLARE
  v_master_access_definition text;
  v_create_definition text;
  v_verify_definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.can_access_inventory_purchase_store(uuid)'::regprocedure
  ) INTO v_master_access_definition;
  SELECT pg_get_functiondef(
    'public.can_create_inventory_purchase_order(uuid)'::regprocedure
  ) INTO v_create_definition;
  SELECT pg_get_functiondef(
    'public.can_verify_inventory_receipt(uuid)'::regprocedure
  ) INTO v_verify_definition;

  IF v_master_access_definition LIKE '%inventory_orderer%'
     OR v_master_access_definition LIKE '%inventory_accounting%' THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_MASTER_ACCESS_TOO_BROAD';
  END IF;

  IF v_create_definition NOT LIKE '%can_read_inventory_purchase_store%'
     OR v_verify_definition NOT LIKE '%can_read_inventory_purchase_store%' THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_WORKFLOW_ACCESS_NOT_WIRED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies policy
    WHERE policy.schemaname = 'public'
      AND policy.tablename = 'inventory_products'
      AND policy.policyname = 'inventory_products_store_read'
      AND policy.qual LIKE '%can_read_inventory_purchase_store%'
  ) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_PRODUCT_READ_POLICY_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid =
        'public.inventory_purchase_order_lines'::regclass
      AND trigger_row.tgname =
        'inventory_purchase_order_line_scope_trigger'
      AND NOT trigger_row.tgisinternal
  ) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_LINE_SCOPE_TRIGGER_MISSING';
  END IF;
END;
$verify$;

COMMIT;
