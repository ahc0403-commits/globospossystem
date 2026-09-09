BEGIN;

-- production-gate: self-verifying

-- pgcrypto is installed in the extensions schema on hosted Supabase projects.
-- Keep the SECURITY DEFINER search_path narrow and qualify digest explicitly.
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

DO $verify$
DECLARE
  v_brand_definition text;
BEGIN
  IF to_regprocedure('extensions.digest(bytea,text)') IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_PGCRYPTO_DIGEST_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.brand_decide_inventory_purchase_order(uuid,integer,boolean,text)'::regprocedure
  ) INTO v_brand_definition;

  IF v_brand_definition NOT LIKE '%extensions.digest(convert_to(%' THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_DIGEST_NOT_SCHEMA_QUALIFIED';
  END IF;
END;
$verify$;

COMMIT;
