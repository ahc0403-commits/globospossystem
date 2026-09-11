-- Common workflow policy for every operating store, including future stores.
-- Supplier master administration stays separate from purchase/receipt access.
BEGIN;

CREATE OR REPLACE FUNCTION public.can_access_inventory_workflow(p_store_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, auth AS $$
  SELECT p_store_id IS NOT NULL AND (
    COALESCE(auth.role(),'') = 'service_role' OR
    (COALESCE(public.inventory_purchase_actor_role(),'') IN
      ('admin','store_admin','brand_admin','super_admin','inventory_orderer','inventory_accounting')
     AND (COALESCE(public.inventory_purchase_actor_role(),'') = 'super_admin' OR EXISTS (
       SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id))))
$$;

CREATE OR REPLACE FUNCTION public.can_access_inventory_purchase_store(p_store_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, auth AS $$
  SELECT public.can_access_inventory_workflow(p_store_id) AND
    (COALESCE(auth.role(),'') = 'service_role' OR COALESCE(public.inventory_purchase_actor_role(),'') IN
      ('admin','store_admin','brand_admin','super_admin'))
$$;

ALTER TABLE public.inventory_receipts ADD COLUMN IF NOT EXISTS inspector_name text;
ALTER TABLE public.inventory_receipts ADD COLUMN IF NOT EXISTS submitted_at timestamptz;
ALTER TABLE public.inventory_purchase_orders ADD COLUMN IF NOT EXISTS urgent_approval_reason text;

ALTER TABLE public.inventory_purchase_approval_events
  DROP CONSTRAINT inventory_purchase_approval_events_action_check;
ALTER TABLE public.inventory_purchase_approval_events
  ADD CONSTRAINT inventory_purchase_approval_events_action_check CHECK (action IN (
    'draft_created','draft_updated','draft_deleted','submitted','store_approved','store_returned',
    'brand_approved','brand_returned','document_ready','document_failed',
    'store_approval_skipped','legacy_return_restored'));

CREATE TABLE public.inventory_receipt_submission_attempts (
  receipt_id uuid NOT NULL REFERENCES public.inventory_receipts(id),
  attempt_key text NOT NULL,
  actor_id uuid NOT NULL,
  payload_hash text NOT NULL,
  result jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (receipt_id, attempt_key)
);
ALTER TABLE public.inventory_receipt_submission_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inventory_receipt_submission_attempts FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.inventory_receipt_submission_attempts TO service_role;

-- Restrictive policies also close older permissive policies (which combine with OR).
CREATE POLICY inventory_supplier_items_master_only ON public.inventory_supplier_items
AS RESTRICTIVE FOR ALL TO authenticated USING (
  EXISTS (SELECT 1 FROM public.inventory_products p WHERE p.id = product_id
          AND public.can_access_inventory_purchase_store(p.restaurant_id))
) WITH CHECK (
  EXISTS (SELECT 1 FROM public.inventory_products p WHERE p.id = product_id
          AND public.can_access_inventory_purchase_store(p.restaurant_id))
);
CREATE POLICY inventory_price_history_master_only ON public.inventory_supplier_item_price_history
AS RESTRICTIVE FOR SELECT TO authenticated
USING (public.can_access_inventory_purchase_store(restaurant_id));
-- Direct line access includes internal recommendation prices. Workflow clients use
-- the sanitized detail RPC below; Office/master readers retain the old contract.
CREATE POLICY inventory_order_lines_master_only ON public.inventory_purchase_order_lines
AS RESTRICTIVE FOR SELECT TO authenticated USING (
  EXISTS (SELECT 1 FROM public.inventory_purchase_orders po WHERE po.id = purchase_order_id
          AND public.can_access_inventory_purchase_store(po.restaurant_id))
);


CREATE OR REPLACE FUNCTION public.can_create_inventory_purchase_order(
  p_store_id uuid
) RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT public.can_access_inventory_workflow(p_store_id)
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
  SELECT public.can_access_inventory_workflow(p_store_id)
    AND COALESCE(public.inventory_purchase_actor_role(), '') =
      'inventory_accounting'
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
  IF NOT public.can_access_inventory_workflow(v_order.restaurant_id)
     OR v_role NOT IN ('admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_STORE_APPROVAL_FORBIDDEN';
  END IF;
  IF v_order.status <> 'submitted' THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_INVALID_TRANSITION'; END IF;
  IF v_order.row_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_STALE_VERSION'; END IF;
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
  IF NOT public.can_access_inventory_workflow(v_order.restaurant_id)
     OR v_role NOT IN ('brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_BRAND_APPROVAL_FORBIDDEN';
  END IF;
  IF v_order.store_approved_by IS NOT DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_DISTINCT_APPROVER_REQUIRED';
  END IF;
  IF v_order.status <> 'store_approved' THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_INVALID_TRANSITION'; END IF;
  IF v_order.row_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_STALE_VERSION'; END IF;
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
        'memo', po.memo, 'urgent_approval_reason', po.urgent_approval_reason,
        'store_approved_by', po.store_approved_by,
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
    v_hash := encode(
      extensions.digest(convert_to(v_snapshot::text, 'UTF8'), 'sha256'),
      'hex'
    );

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
  IF NOT public.can_access_inventory_workflow(v_order.restaurant_id)
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
    IF v_ordered_quantity_unit IS NULL OR v_ordered_quantity_unit <= 0 OR v_ordered_quantity_unit::text IN ('NaN','Infinity','-Infinity') THEN
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
    IF NOT EXISTS (SELECT 1 FROM public.inventory_products p
      JOIN public.inventory_suppliers s ON s.id = v_supplier_item.supplier_id
      WHERE p.id = v_supplier_item.product_id AND p.restaurant_id = p_store_id
        AND p.is_active AND p.is_orderable AND s.status = 'active') THEN
      RAISE EXCEPTION 'INVENTORY_PURCHASE_SUPPLIER_ITEM_NOT_FOUND';
    END IF;
    v_unit_price := COALESCE(
      NULLIF(v_line->>'unit_price', '')::numeric,
      v_supplier_item.unit_price
    );
    IF public.inventory_purchase_actor_role() = 'inventory_orderer' THEN
      v_unit_price := v_supplier_item.unit_price;
    END IF;
    IF v_unit_price < 0 OR v_unit_price::text IN ('NaN','Infinity','-Infinity') THEN
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
  IF v_order.row_version IS DISTINCT FROM p_expected_version THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_STALE_VERSION';
  END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array'
     OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_LINES_REQUIRED';
  END IF;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_line_id := NULLIF(v_line->>'line_id', '')::uuid;
    v_quantity := NULLIF(v_line->>'ordered_quantity_unit', '')::numeric;
    IF v_quantity IS NULL OR v_quantity <= 0 OR v_quantity::text IN ('NaN','Infinity','-Infinity') THEN
      RAISE EXCEPTION 'INVENTORY_PURCHASE_LINE_QUANTITY_INVALID';
    END IF;
    SELECT * INTO v_supplier_item FROM public.inventory_supplier_items
    WHERE id = NULLIF(v_line->>'supplier_item_id', '')::uuid
      AND supplier_id = v_order.supplier_id AND is_active = true;
    IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_SUPPLIER_ITEM_NOT_FOUND'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.inventory_products p
      JOIN public.inventory_suppliers s ON s.id = v_supplier_item.supplier_id
      WHERE p.id = v_supplier_item.product_id AND p.restaurant_id = v_order.restaurant_id
        AND p.is_active AND p.is_orderable AND s.status = 'active') THEN
      RAISE EXCEPTION 'INVENTORY_PURCHASE_SUPPLIER_ITEM_NOT_FOUND';
    END IF;
    v_price := COALESCE(
      NULLIF(v_line->>'unit_price', '')::numeric, v_supplier_item.unit_price
    );
    IF public.inventory_purchase_actor_role() = 'inventory_orderer' THEN
      v_price := v_supplier_item.unit_price;
    END IF;
    IF v_price < 0 OR v_price::text IN ('NaN','Infinity','-Infinity') THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_LINE_PRICE_INVALID'; END IF;

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
  IF v_order.row_version IS DISTINCT FROM p_expected_version THEN
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
  IF v_order.row_version IS DISTINCT FROM p_expected_version THEN
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
        status = 'cancelled', submitted_at = NULL, row_version = row_version + 1, updated_at = now()
      WHERE id = v_receipt.id RETURNING * INTO v_receipt;
    ELSE
      UPDATE public.inventory_receipts SET
        submitted_at = NULL, row_version = row_version + 1, updated_at = now()
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
    submitted_at = NULL, row_version = row_version + 1, updated_at = now()
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

-- Update only workflow reads. Master mutations and cost analysis continue to use
-- the administrator-only can_access_inventory_purchase_store predicate.
DO $policies$
DECLARE p record; expr text;
BEGIN
  FOR p IN SELECT pol.polname, ns.nspname, c.relname, pg_get_expr(pol.polqual,pol.polrelid) AS qual
    FROM pg_policy pol JOIN pg_class c ON c.oid=pol.polrelid
    JOIN pg_namespace ns ON ns.oid=c.relnamespace
    WHERE pol.polcmd='r' AND (
      (ns.nspname='public' AND c.relname IN ('inventory_products','inventory_purchase_orders',
        'inventory_receipts','inventory_receipt_lines','inventory_purchase_documents','inventory_purchase_approval_events'))
      OR (ns.nspname='storage' AND pol.polname IN
        ('inventory_purchase_document_objects_read','inventory_receipt_statement_objects_read')))
  LOOP
    expr := replace(p.qual,'can_access_inventory_purchase_store(', 'can_access_inventory_workflow(');
    EXECUTE format('ALTER POLICY %I ON %I.%I USING (%s)',p.polname,p.nspname,p.relname,expr);
  END LOOP;
END $policies$;

CREATE OR REPLACE FUNCTION public.get_inventory_order_catalog(p_store_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE result jsonb;
BEGIN
  IF NOT public.can_create_inventory_purchase_order(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;
  SELECT jsonb_build_object(
    'suppliers', COALESCE((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.supplier_name)
      FROM public.inventory_suppliers s WHERE s.status='active' AND EXISTS (
        SELECT 1 FROM public.inventory_supplier_items i JOIN public.inventory_products p ON p.id=i.product_id
        WHERE i.supplier_id=s.id AND i.is_active AND p.restaurant_id=p_store_id
          AND p.is_active AND p.is_orderable)), '[]'::jsonb),
    'items', COALESCE((SELECT jsonb_agg(
      jsonb_build_object('id',i.id,'supplier_id',i.supplier_id,'product_id',i.product_id,
        'order_unit',i.order_unit,'order_unit_quantity_base',i.order_unit_quantity_base,
        'min_order_quantity',i.min_order_quantity,'is_active',i.is_active,
        'product',jsonb_build_object('id',p.id,'name',p.name,'is_active',p.is_active,'is_orderable',p.is_orderable),
        'supplier',jsonb_build_object('supplier_name',s.supplier_name,'status',s.status))
      || CASE WHEN public.inventory_purchase_actor_role()='inventory_orderer' THEN '{}'::jsonb
         ELSE to_jsonb(i) END
      ORDER BY p.name,i.id)
      FROM public.inventory_supplier_items i JOIN public.inventory_products p ON p.id=i.product_id
      JOIN public.inventory_suppliers s ON s.id=i.supplier_id
      WHERE p.restaurant_id=p_store_id AND p.is_active AND p.is_orderable AND i.is_active AND s.status='active'), '[]'::jsonb)
  ) INTO result;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.get_inventory_workflow_orders(
  p_store_id uuid DEFAULT NULL, p_statuses text[] DEFAULT NULL,
  p_mine_only boolean DEFAULT false, p_offset integer DEFAULT 0, p_limit integer DEFAULT 80
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE result jsonb; v_role text := public.inventory_purchase_actor_role();
BEGIN
  IF v_role NOT IN ('admin','store_admin','brand_admin','super_admin','inventory_orderer','inventory_accounting')
     OR v_role IS NULL THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN'; END IF;
  IF p_store_id IS NOT NULL AND NOT public.can_access_inventory_workflow(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;
  WITH accessible AS (
    SELECT po.* FROM public.inventory_purchase_orders po
    WHERE public.can_access_inventory_workflow(po.restaurant_id)
      AND (v_role <> 'inventory_accounting' OR po.status IN ('ordered','partially_received','received','office_approved'))
  ), scoped AS (
    SELECT * FROM accessible po WHERE (p_store_id IS NULL OR po.restaurant_id=p_store_id)
      AND (NOT COALESCE(p_mine_only,false) OR
        (po.status='submitted' AND v_role IN ('admin','store_admin','super_admin')) OR
        (po.status='store_approved' AND v_role IN ('brand_admin','super_admin')
          AND po.store_approved_by IS DISTINCT FROM auth.uid()))
  ), filtered AS (
    SELECT * FROM scoped WHERE p_statuses IS NULL OR status=ANY(p_statuses)
  ), page AS (
    SELECT * FROM filtered ORDER BY
      CASE WHEN status IN ('draft','submitted','store_approved','office_returned') THEN 0 ELSE 1 END,
      CASE WHEN status IN ('draft','submitted','store_approved','office_returned') THEN COALESCE(submitted_at,created_at) END ASC,
      updated_at DESC,id
    LIMIT LEAST(GREATEST(COALESCE(p_limit,80),1),240) OFFSET GREATEST(COALESCE(p_offset,0),0)
  ) SELECT jsonb_build_object(
    'orders',COALESCE((SELECT jsonb_agg((to_jsonb(po)-'approval_snapshot') || jsonb_build_object(
      'supplier',jsonb_build_object('id',s.id,'supplier_name',s.supplier_name),
      'store',jsonb_build_object('id',r.id,'name',r.name)) ORDER BY
        CASE WHEN po.status IN ('draft','submitted','store_approved','office_returned') THEN 0 ELSE 1 END,
        CASE WHEN po.status IN ('draft','submitted','store_approved','office_returned') THEN COALESCE(po.submitted_at,po.created_at) END ASC,
        po.updated_at DESC,po.id)
      FROM page po JOIN public.inventory_suppliers s ON s.id=po.supplier_id
      JOIN public.restaurants r ON r.id=po.restaurant_id),'[]'::jsonb),
    'total',(SELECT count(*) FROM filtered),
    'counts',COALESCE((SELECT jsonb_object_agg(status,n) FROM (SELECT status,count(*) n FROM scoped GROUP BY status) c),'{}'::jsonb),
    'stores',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',r.id,'name',r.name) ORDER BY r.name)
      FROM public.restaurants r WHERE public.can_access_inventory_workflow(r.id)),'[]'::jsonb)
  ) INTO result;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.can_urgent_approve_inventory_order(p_store_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
  SELECT public.can_access_inventory_workflow(p_store_id) AND EXISTS (
    SELECT 1 FROM public.users u WHERE u.auth_id=auth.uid() AND u.is_active
      AND u.role IN ('brand_admin','super_admin')
      AND 'inventory_purchase_urgent_approve'=ANY(COALESCE(u.extra_permissions,ARRAY[]::text[])))
$$;

CREATE OR REPLACE FUNCTION public.get_inventory_workflow_detail(p_purchase_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE v_order public.inventory_purchase_orders%ROWTYPE; result jsonb;
BEGIN
  SELECT * INTO v_order FROM public.inventory_purchase_orders WHERE id=p_purchase_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND'; END IF;
  IF NOT public.can_access_inventory_workflow(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN'; END IF;
  SELECT jsonb_build_object(
    'order',(to_jsonb(v_order)-'approval_snapshot') || jsonb_build_object(
      'supplier',(SELECT jsonb_build_object('id',s.id,'supplier_name',s.supplier_name,'email',s.email,'phone',s.phone)
                  FROM public.inventory_suppliers s WHERE s.id=v_order.supplier_id),
      'store',(SELECT jsonb_build_object('id',r.id,'name',r.name) FROM public.restaurants r WHERE r.id=v_order.restaurant_id),
      'created_by_name',(SELECT full_name FROM public.users WHERE auth_id=v_order.created_by LIMIT 1),
      'store_approved_by_name',(SELECT full_name FROM public.users WHERE auth_id=v_order.store_approved_by LIMIT 1),
      'brand_approved_by_name',(SELECT full_name FROM public.users WHERE auth_id=v_order.brand_approved_by LIMIT 1)),
    'can_urgent_approve',public.can_urgent_approve_inventory_order(v_order.restaurant_id),
    'lines',COALESCE((SELECT jsonb_agg((to_jsonb(l)-'recommendation_snapshot') || jsonb_build_object(
      'product',jsonb_build_object('name',p.name),
      'supplier_item',jsonb_build_object('order_unit_quantity_base',COALESCE(
        NULLIF(l.ordered_quantity_base,0)/NULLIF(l.ordered_quantity_unit,0),1))) ORDER BY l.created_at,l.id)
      FROM public.inventory_purchase_order_lines l JOIN public.inventory_products p ON p.id=l.product_id
      WHERE l.purchase_order_id=v_order.id),'[]'::jsonb),
    'receipts',COALESCE((SELECT jsonb_agg(to_jsonb(r) || jsonb_build_object(
      'line_details',COALESCE((SELECT jsonb_agg(to_jsonb(l)) FROM public.inventory_receipt_lines l WHERE l.receipt_id=r.id),'[]'::jsonb))
      ORDER BY r.created_at DESC) FROM public.inventory_receipts r WHERE r.purchase_order_id=v_order.id),'[]'::jsonb),
    'documents',COALESCE((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.snapshot_version DESC)
      FROM public.inventory_purchase_documents d WHERE d.purchase_order_id=v_order.id),'[]'::jsonb),
    'approval_events',COALESCE((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.created_at DESC,e.id)
      FROM public.inventory_purchase_approval_events e WHERE e.purchase_order_id=v_order.id),'[]'::jsonb)
  ) INTO result;
  RETURN result;
END $$;

-- No fake store approver: the skipped step is recorded as an explicit exception.
CREATE OR REPLACE FUNCTION public.urgent_approve_inventory_purchase_order(
  p_purchase_order_id uuid,p_expected_version integer,p_reason text
) RETURNS public.inventory_purchase_orders LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE v_order public.inventory_purchase_orders%ROWTYPE; v_reason text:=NULLIF(btrim(p_reason),'');
BEGIN
  SELECT * INTO v_order FROM public.inventory_purchase_orders WHERE id=p_purchase_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND'; END IF;
  IF NOT public.can_urgent_approve_inventory_order(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_URGENT_FORBIDDEN'; END IF;
  IF v_reason IS NULL THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_URGENT_REASON_REQUIRED'; END IF;
  IF v_order.status <> 'submitted' THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_INVALID_TRANSITION'; END IF;
  IF v_order.row_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_STALE_VERSION'; END IF;
  UPDATE public.inventory_purchase_orders SET status='store_approved', store_approved_by=NULL,
    store_approved_at=NULL,urgent_approval_reason=v_reason WHERE id=v_order.id;
  PERFORM public.append_inventory_purchase_approval_event(v_order.id,'store_approval_skipped',
    'submitted','store_approved',v_reason,jsonb_build_object('urgent',true,'skipped_step','store'));
  -- Same transaction and normal final-approval snapshot/document contract.
  SELECT * INTO v_order FROM public.brand_decide_inventory_purchase_order(v_order.id,p_expected_version,true,v_reason);
  RETURN v_order;
END $$;

CREATE OR REPLACE FUNCTION public.restore_returned_inventory_draft(
  p_purchase_order_id uuid,p_expected_version integer,p_reason text
) RETURNS public.inventory_purchase_orders LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE v_order public.inventory_purchase_orders%ROWTYPE;
BEGIN
  SELECT * INTO v_order FROM public.inventory_purchase_orders WHERE id=p_purchase_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND'; END IF;
  IF NOT public.can_access_inventory_purchase_store(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN'; END IF;
  IF v_order.status <> 'office_returned' THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_INVALID_TRANSITION'; END IF;
  IF v_order.row_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_STALE_VERSION'; END IF;
  IF NULLIF(btrim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_RETURN_REASON_REQUIRED'; END IF;
  UPDATE public.inventory_purchase_orders SET status='draft',row_version=row_version+1,
    store_approved_by=NULL,store_approved_at=NULL,updated_at=now() WHERE id=v_order.id RETURNING * INTO v_order;
  PERFORM public.append_inventory_purchase_approval_event(v_order.id,'legacy_return_restored','office_returned','draft',p_reason);
  RETURN v_order;
END $$;

CREATE OR REPLACE FUNCTION public.validate_inventory_receipt_attachment(
  p_store_id uuid,p_receipt_id uuid,p_path text,p_inspector_name text
) RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
BEGIN
  IF NULLIF(btrim(p_inspector_name),'') IS NULL OR length(p_inspector_name)>200 THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_INSPECTOR_REQUIRED'; END IF;
  IF p_path IS NULL OR split_part(p_path,'/',1) <> p_store_id::text
    OR split_part(p_path,'/',2) <> p_receipt_id::text
    OR NOT EXISTS (SELECT 1 FROM storage.objects o WHERE o.bucket_id='inventory-receipt-statements'
      AND o.name=p_path
      AND (o.owner_id=auth.uid()::text OR EXISTS (
        SELECT 1 FROM public.inventory_receipts r WHERE r.id=p_receipt_id
          AND r.restaurant_id=p_store_id AND r.statement_storage_path=p_path))
      AND lower(o.metadata->>'mimetype') IN ('application/pdf','image/png','image/jpeg')
      AND (o.metadata->>'size')::bigint BETWEEN 1 AND 10485760) THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_ATTACHMENT_REQUIRED'; END IF;
END $$;
REVOKE ALL ON FUNCTION public.validate_inventory_receipt_attachment(uuid,uuid,text,text) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.submit_inventory_receipt_batch(
  p_purchase_order_id uuid,p_receipt_id uuid,p_expected_order_version integer,
  p_expected_receipt_version integer,p_idempotency_key text,p_lines jsonb,
  p_inspector_name text,p_statement_storage_path text,
  p_statement_number text DEFAULT NULL,p_statement_date date DEFAULT NULL,p_memo text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE v_order public.inventory_purchase_orders%ROWTYPE; v_receipt public.inventory_receipts%ROWTYPE;
  v_line jsonb; v_po_line public.inventory_purchase_order_lines%ROWTYPE;
  v_qty numeric; v_rejected numeric; v_price numeric; v_ids uuid[]:=ARRAY[]::uuid[];
  v_hash text; v_previous public.inventory_receipt_submission_attempts%ROWTYPE;
  v_result jsonb; v_total numeric:=0;
BEGIN
  IF p_receipt_id IS NULL OR NULLIF(btrim(p_idempotency_key),'') IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_IDEMPOTENCY_KEY_REQUIRED'; END IF;
  SELECT * INTO v_order FROM public.inventory_purchase_orders WHERE id=p_purchase_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND'; END IF;
  IF NOT public.can_create_inventory_purchase_order(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_DRAFT_FORBIDDEN'; END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object('order',p_purchase_order_id,
    'lines',p_lines,'inspector',p_inspector_name,'file',p_statement_storage_path,
    'number',p_statement_number,'date',p_statement_date,'memo',p_memo)::text,'UTF8'),'sha256'),'hex');
  SELECT * INTO v_previous FROM public.inventory_receipt_submission_attempts
    WHERE receipt_id=p_receipt_id AND attempt_key=p_idempotency_key;
  IF FOUND THEN
    IF v_previous.actor_id<>auth.uid() OR v_previous.payload_hash<>v_hash THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_RETRY_MISMATCH'; END IF;
    RETURN v_previous.result;
  END IF;
  IF v_order.status NOT IN ('ordered','partially_received','office_approved') THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_RECEIVABLE'; END IF;
  IF v_order.row_version IS DISTINCT FROM p_expected_order_version THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_STALE_VERSION'; END IF;
  SELECT * INTO v_receipt FROM public.inventory_receipts WHERE id=p_receipt_id FOR UPDATE;
  IF FOUND THEN
    IF v_receipt.purchase_order_id<>v_order.id OR v_receipt.status<>'draft' THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_NOT_EDITABLE'; END IF;
    IF v_receipt.row_version IS DISTINCT FROM p_expected_receipt_version THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_STALE_VERSION'; END IF;
    IF v_receipt.received_by IS DISTINCT FROM auth.uid() AND public.inventory_purchase_actor_role()='inventory_orderer' THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_DRAFT_OWNER_REQUIRED'; END IF;
  ELSE
    IF COALESCE(p_expected_receipt_version,0)<>0 OR EXISTS (
      SELECT 1 FROM public.inventory_receipts WHERE purchase_order_id=v_order.id AND status='draft') THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_STALE_VERSION'; END IF;
    INSERT INTO public.inventory_receipts(id,purchase_order_id,restaurant_id,supplier_id,received_by,status,delivery_cycle)
      SELECT p_receipt_id,v_order.id,v_order.restaurant_id,v_order.supplier_id,auth.uid(),'draft',COALESCE(max(delivery_cycle),0)+1
      FROM public.inventory_receipts WHERE purchase_order_id=v_order.id RETURNING * INTO v_receipt;
  END IF;
  PERFORM public.validate_inventory_receipt_attachment(v_order.restaurant_id,p_receipt_id,p_statement_storage_path,p_inspector_name);
  IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines)=0 THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_LINES_REQUIRED'; END IF;
  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    SELECT * INTO v_po_line FROM public.inventory_purchase_order_lines
      WHERE id=(v_line->>'purchase_order_line_id')::uuid AND purchase_order_id=v_order.id FOR UPDATE;
    IF NOT FOUND OR v_po_line.id=ANY(v_ids) THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_LINE_INVALID'; END IF;
    v_ids:=array_append(v_ids,v_po_line.id);
    v_qty:=NULLIF(v_line->>'received_quantity_base','')::numeric;
    v_rejected:=COALESCE(NULLIF(v_line->>'rejected_quantity_base','')::numeric,0);
    v_price:=COALESCE(NULLIF(v_line->>'actual_unit_price','')::numeric,v_po_line.unit_price);
    IF v_qty IS NULL OR v_qty<0 OR v_rejected<0 OR v_rejected>v_qty OR v_price<0
      OR v_rejected::text IN ('NaN','Infinity','-Infinity')
      OR v_qty::text IN ('NaN','Infinity','-Infinity') OR v_price::text IN ('NaN','Infinity','-Infinity') THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_QUANTITY_INVALID'; END IF;
    IF (v_qty<>v_po_line.ordered_quantity_base OR v_price<>v_po_line.unit_price)
      AND NULLIF(btrim(v_line->>'discrepancy_reason'),'') IS NULL THEN
      RAISE EXCEPTION 'INVENTORY_RECEIPT_DISCREPANCY_REASON_REQUIRED'; END IF;
    v_total:=v_total+v_qty;
    INSERT INTO public.inventory_receipt_lines(receipt_id,purchase_order_line_id,product_id,
      received_quantity_base,accepted_quantity_base,rejected_quantity_base,actual_unit_price,discrepancy_reason)
    VALUES (p_receipt_id,v_po_line.id,v_po_line.product_id,v_qty,v_qty-v_rejected,v_rejected,v_price,
      NULLIF(btrim(v_line->>'discrepancy_reason'),''))
    ON CONFLICT (receipt_id,purchase_order_line_id) WHERE purchase_order_line_id IS NOT NULL
    DO UPDATE SET received_quantity_base=EXCLUDED.received_quantity_base,
      accepted_quantity_base=EXCLUDED.accepted_quantity_base,rejected_quantity_base=EXCLUDED.rejected_quantity_base,
      actual_unit_price=EXCLUDED.actual_unit_price,discrepancy_reason=EXCLUDED.discrepancy_reason,updated_at=now();
  END LOOP;
  IF cardinality(v_ids)<>(SELECT count(*) FROM public.inventory_purchase_order_lines WHERE purchase_order_id=v_order.id)
     OR v_total<=0 THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_LINES_REQUIRED'; END IF;
  UPDATE public.inventory_receipts SET inspector_name=btrim(p_inspector_name),statement_storage_path=p_statement_storage_path,
    statement_number=NULLIF(btrim(p_statement_number),''),statement_date=p_statement_date,
    memo=NULLIF(btrim(p_memo),''),submitted_at=now(),row_version=row_version+1,updated_at=now()
    WHERE id=p_receipt_id RETURNING * INTO v_receipt;
  v_result:=jsonb_build_object('receipt_id',p_receipt_id,'row_version',v_receipt.row_version,'status',v_receipt.status);
  INSERT INTO public.inventory_receipt_submission_attempts(receipt_id,attempt_key,actor_id,payload_hash,result)
    VALUES(p_receipt_id,p_idempotency_key,auth.uid(),v_hash,v_result);
  RETURN v_result;
END $$;
CREATE OR REPLACE FUNCTION public.update_inventory_receipt_metadata_v2(
  p_receipt_id uuid,
  p_expected_version integer,
  p_inspector_name text,
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
  IF v_receipt.row_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_STALE_VERSION'; END IF;
  IF v_receipt.received_by IS DISTINCT FROM auth.uid()
     AND public.inventory_purchase_actor_role() = 'inventory_orderer' THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_DRAFT_OWNER_REQUIRED';
  END IF;
  PERFORM public.validate_inventory_receipt_attachment(
    v_receipt.restaurant_id, v_receipt.id, p_statement_storage_path, p_inspector_name);
  UPDATE public.inventory_receipts SET
    inspector_name = btrim(p_inspector_name),
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
  WHERE id = p_receipt_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_NOT_FOUND'; END IF;
  SELECT * INTO v_order FROM public.inventory_purchase_orders
  WHERE id = v_receipt.purchase_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND'; END IF;
  SELECT * INTO v_receipt FROM public.inventory_receipts
  WHERE id = p_receipt_id FOR UPDATE;
  IF NOT public.can_verify_inventory_receipt(v_receipt.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_VERIFY_FORBIDDEN';
  END IF;
  IF v_receipt.received_by IS NOT DISTINCT FROM auth.uid() OR EXISTS (
    SELECT 1 FROM public.inventory_receipt_submission_attempts a
    WHERE a.receipt_id=v_receipt.id AND a.actor_id=auth.uid()) THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_MAKER_CHECKER_REQUIRED';
  END IF;
  IF v_receipt.status = 'confirmed' THEN RETURN v_order; END IF;
  IF v_receipt.status <> 'draft' THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_NOT_VERIFIABLE'; END IF;
  IF v_receipt.row_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_STALE_VERSION'; END IF;
  PERFORM public.validate_inventory_receipt_attachment(
    v_receipt.restaurant_id, v_receipt.id, v_receipt.statement_storage_path, v_receipt.inspector_name);
  IF v_receipt.submitted_at IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_SUBMISSION_REQUIRED';
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
      IF v_accepted < 0 OR v_rejected < 0 OR v_price < 0
         OR v_accepted::text IN ('NaN','Infinity','-Infinity')
         OR v_rejected::text IN ('NaN','Infinity','-Infinity')
         OR v_price::text IN ('NaN','Infinity','-Infinity') THEN
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

  v_receipt.total_supply_amount := 0;
  v_receipt.tax_amount := 0;
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
    'Verified supplier statement ' || COALESCE(v_receipt.statement_number, v_receipt.id::text), auth.uid()
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
-- Explicit public API grants; helper/attempt records remain private.
DO $grants$
DECLARE f record;
BEGIN
 FOR f IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.proname=ANY(ARRAY[
   'can_access_inventory_workflow','can_urgent_approve_inventory_order','get_inventory_order_catalog',
   'get_inventory_workflow_orders','get_inventory_workflow_detail','urgent_approve_inventory_purchase_order',
   'restore_returned_inventory_draft','submit_inventory_receipt_batch','update_inventory_receipt_metadata_v2'])
 LOOP
   EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon',f.signature);
   EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated,service_role',f.signature);
 END LOOP;
END $grants$;
COMMIT;
