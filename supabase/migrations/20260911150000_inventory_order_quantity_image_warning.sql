BEGIN;

-- production-gate: self-verifying

ALTER TABLE public.inventory_supplier_items
  ADD COLUMN IF NOT EXISTS allows_fractional_quantity boolean
  GENERATED ALWAYS AS (
    upper(btrim(order_unit)) IN ('KG', 'KGS', 'KILOGRAM', 'KILOGRAMS')
  ) STORED;

CREATE INDEX IF NOT EXISTS inventory_purchase_orders_quantity_history_idx
  ON public.inventory_purchase_orders(
    restaurant_id, supplier_id, brand_approved_at DESC
  )
  WHERE status IN ('ordered', 'partially_received', 'received', 'office_approved');

CREATE OR REPLACE FUNCTION public.inventory_purchase_quantity_text_is_valid(
  p_value text
) RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog
AS $$
  SELECT COALESCE(btrim(p_value) ~ '^[0-9]{1,9}([.][0-9]{1,3})?$', false)
    AND CASE
      WHEN COALESCE(btrim(p_value), '') ~ '^[0-9]{1,9}([.][0-9]{1,3})?$'
      THEN btrim(p_value)::numeric > 0
      ELSE false
    END
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
  v_quantity_text text;
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
    v_quantity_text := v_line->>'ordered_quantity_unit';
    IF NOT public.inventory_purchase_quantity_text_is_valid(v_quantity_text) THEN
      RAISE EXCEPTION 'INVENTORY_MANUAL_PURCHASE_QUANTITY_INVALID';
    END IF;
    v_ordered_quantity_unit := btrim(v_quantity_text)::numeric;
    v_line_memo := NULLIF(btrim(COALESCE(v_line->>'memo', '')), '');

    SELECT * INTO v_supplier_item
    FROM public.inventory_supplier_items
    WHERE id = NULLIF(v_line->>'supplier_item_id', '')::uuid
      AND supplier_id = p_supplier_id AND is_active = true;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'INVENTORY_MANUAL_PURCHASE_SUPPLIER_ITEM_NOT_FOUND';
    END IF;
    IF NOT v_supplier_item.allows_fractional_quantity
       AND v_ordered_quantity_unit < v_supplier_item.min_order_quantity THEN
      RAISE EXCEPTION 'INVENTORY_PURCHASE_MINIMUM_QUANTITY:%',
        v_supplier_item.min_order_quantity;
    END IF;
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
    v_quantity := v_line.ordered_quantity_unit;
    IF v_quantity <= 0 THEN
      RAISE EXCEPTION 'INVENTORY_REPEAT_PURCHASE_QUANTITY_INVALID';
    END IF;
    IF NOT v_supplier_item.allows_fractional_quantity
       AND v_quantity < v_supplier_item.min_order_quantity THEN
      RAISE EXCEPTION 'INVENTORY_PURCHASE_MINIMUM_QUANTITY:%',
        v_supplier_item.min_order_quantity;
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
  v_quantity_text text;
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
    v_quantity_text := v_line->>'ordered_quantity_unit';
    IF NOT public.inventory_purchase_quantity_text_is_valid(v_quantity_text) THEN
      RAISE EXCEPTION 'INVENTORY_PURCHASE_LINE_QUANTITY_INVALID';
    END IF;
    v_quantity := btrim(v_quantity_text)::numeric;
    SELECT * INTO v_supplier_item FROM public.inventory_supplier_items
    WHERE id = NULLIF(v_line->>'supplier_item_id', '')::uuid
      AND supplier_id = v_order.supplier_id AND is_active = true;
    IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_SUPPLIER_ITEM_NOT_FOUND'; END IF;
    IF NOT v_supplier_item.allows_fractional_quantity
       AND v_quantity < v_supplier_item.min_order_quantity THEN
      RAISE EXCEPTION 'INVENTORY_PURCHASE_MINIMUM_QUANTITY:%',
        v_supplier_item.min_order_quantity;
    END IF;
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

CREATE OR REPLACE FUNCTION public.inventory_purchase_quantity_warning_payload(
  p_purchase_order_id uuid
) RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  WITH target_order AS (
    SELECT po.*
    FROM public.inventory_purchase_orders po
    WHERE po.id = p_purchase_order_id
  ), current_lines AS (
    SELECT
      pol.product_id,
      min(p.name) AS product_name,
      sum(pol.ordered_quantity_base) AS ordered_quantity_base,
      sum(pol.ordered_quantity_unit) AS ordered_quantity_unit,
      min(pol.order_unit) AS order_unit,
      sum(pol.ordered_quantity_base) /
        NULLIF(sum(pol.ordered_quantity_unit), 0) AS conversion
    FROM public.inventory_purchase_order_lines pol
    JOIN public.inventory_products p ON p.id = pol.product_id
    WHERE pol.purchase_order_id = p_purchase_order_id
    GROUP BY pol.product_id
  ), history_sums AS (
    SELECT
      pol.product_id,
      po.id AS order_id,
      sum(pol.ordered_quantity_base) AS quantity_base,
      COALESCE(po.brand_approved_at, po.updated_at, po.created_at) AS approved_at
    FROM target_order target
    JOIN public.inventory_purchase_orders po
      ON po.restaurant_id = target.restaurant_id
     AND po.supplier_id = target.supplier_id
    JOIN public.inventory_purchase_order_lines pol
      ON pol.purchase_order_id = po.id
    WHERE po.id <> target.id
      AND po.status IN ('ordered', 'partially_received', 'received', 'office_approved')
      AND COALESCE(po.brand_approved_at, po.updated_at, po.created_at)
        >= now() - interval '30 days'
    GROUP BY pol.product_id, po.id,
      COALESCE(po.brand_approved_at, po.updated_at, po.created_at)
  ), ranked_history AS (
    SELECT history_sums.*,
      row_number() OVER (
        PARTITION BY product_id ORDER BY approved_at DESC, order_id DESC
      ) AS history_rank
    FROM history_sums
  ), baselines AS (
    SELECT
      product_id,
      count(*)::integer AS sample_count,
      percentile_cont(0.5) WITHIN GROUP (
        ORDER BY quantity_base::double precision
      )::numeric AS usual_quantity_base
    FROM ranked_history
    WHERE history_rank <= 20
    GROUP BY product_id
    HAVING count(*) >= 5
  ), warning_rows AS (
    SELECT jsonb_build_object(
      'product_id', current.product_id,
      'product_name', current.product_name,
      'ordered_quantity_base', current.ordered_quantity_base,
      'ordered_quantity_unit', current.ordered_quantity_unit,
      'order_unit', current.order_unit,
      'usual_quantity_base', baseline.usual_quantity_base,
      'usual_quantity_unit', round(
        baseline.usual_quantity_base / NULLIF(current.conversion, 0), 3
      ),
      'ratio', round(
        current.ordered_quantity_base / NULLIF(baseline.usual_quantity_base, 0), 3
      ),
      'sample_count', baseline.sample_count
    ) AS warning
    FROM current_lines current
    JOIN baselines baseline ON baseline.product_id = current.product_id
    WHERE current.ordered_quantity_base >= baseline.usual_quantity_base * 6
    ORDER BY current.product_name, current.product_id
  ), warnings AS (
    SELECT COALESCE(jsonb_agg(warning), '[]'::jsonb) AS value
    FROM warning_rows
  ), token_source AS (
    SELECT jsonb_build_object(
      'policy_version', 'recent_30d_last_20_median_min_5_v1',
      'purchase_order_id', target.id,
      'row_version', target.row_version,
      'warnings', warnings.value
    ) AS value
    FROM target_order target CROSS JOIN warnings
  )
  SELECT jsonb_build_object(
    'policy_version', 'recent_30d_last_20_median_min_5_v1',
    'warning_token', encode(
      extensions.digest(convert_to(token_source.value::text, 'UTF8'), 'sha256'),
      'hex'
    ),
    'warnings', token_source.value->'warnings'
  )
  FROM token_source
$$;

CREATE OR REPLACE FUNCTION public.get_inventory_purchase_quantity_warnings(
  p_purchase_order_id uuid,
  p_expected_version integer
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
BEGIN
  SELECT * INTO v_order FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND'; END IF;
  IF NOT public.can_create_inventory_purchase_order(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;
  IF public.inventory_purchase_actor_role() = 'inventory_orderer'
     AND v_order.created_by IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_DRAFT_OWNER_REQUIRED';
  END IF;
  IF v_order.status <> 'draft' THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_SUBMITTABLE';
  END IF;
  IF v_order.row_version IS DISTINCT FROM p_expected_version THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_STALE_VERSION';
  END IF;
  RETURN public.inventory_purchase_quantity_warning_payload(v_order.id);
END;
$$;

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
        'min_order_quantity',i.min_order_quantity,
        'allows_fractional_quantity',i.allows_fractional_quantity,
        'usual_order_quantity_unit',CASE WHEN history.sample_count >= 5 THEN
          round(history.usual_quantity_base / NULLIF(i.order_unit_quantity_base,0),3) END,
        'usual_order_sample_count',history.sample_count,
        'is_active',i.is_active,
        'product',jsonb_build_object('id',p.id,'name',p.name,'is_active',p.is_active,'is_orderable',p.is_orderable),
        'supplier',jsonb_build_object('supplier_name',s.supplier_name,'status',s.status))
      || CASE WHEN public.inventory_purchase_actor_role()='inventory_orderer' THEN '{}'::jsonb
         ELSE to_jsonb(i) END
      ORDER BY p.name,i.id)
      FROM public.inventory_supplier_items i JOIN public.inventory_products p ON p.id=i.product_id
      JOIN public.inventory_suppliers s ON s.id=i.supplier_id
      LEFT JOIN LATERAL (
        SELECT count(*)::integer AS sample_count,
          percentile_cont(0.5) WITHIN GROUP (
            ORDER BY recent.quantity_base::double precision
          )::numeric AS usual_quantity_base
        FROM (
          SELECT sum(pol.ordered_quantity_base) AS quantity_base
          FROM public.inventory_purchase_orders po
          JOIN public.inventory_purchase_order_lines pol ON pol.purchase_order_id=po.id
          WHERE po.restaurant_id=p_store_id AND po.supplier_id=i.supplier_id
            AND pol.product_id=i.product_id
            AND po.status IN ('ordered','partially_received','received','office_approved')
            AND COALESCE(po.brand_approved_at,po.updated_at,po.created_at)>=now()-interval '30 days'
          GROUP BY po.id,COALESCE(po.brand_approved_at,po.updated_at,po.created_at)
          ORDER BY COALESCE(po.brand_approved_at,po.updated_at,po.created_at) DESC,po.id DESC
          LIMIT 20
        ) recent
      ) history ON true
      WHERE p.restaurant_id=p_store_id AND p.is_active AND p.is_orderable AND i.is_active AND s.status='active'), '[]'::jsonb)
  ) INTO result;
  RETURN result;
END $$;

DROP FUNCTION public.submit_inventory_purchase_order(uuid, integer);

CREATE FUNCTION public.submit_inventory_purchase_order(
  p_purchase_order_id uuid,
  p_expected_version integer,
  p_warning_token text DEFAULT NULL
) RETURNS public.inventory_purchase_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_warning_payload jsonb;
  v_warnings jsonb;
  v_expected_token text;
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

  v_warning_payload := public.inventory_purchase_quantity_warning_payload(v_order.id);
  v_warnings := COALESCE(v_warning_payload->'warnings', '[]'::jsonb);
  v_expected_token := v_warning_payload->>'warning_token';
  IF jsonb_array_length(v_warnings) > 0
     AND p_warning_token IS DISTINCT FROM v_expected_token THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_QUANTITY_CONFIRMATION_REQUIRED:%',
      v_expected_token;
  END IF;

  UPDATE public.inventory_purchase_orders SET
    status = 'submitted', submitted_by = auth.uid(), submitted_at = now(),
    row_version = row_version + 1, updated_at = now()
  WHERE id = v_order.id RETURNING * INTO v_order;
  PERFORM public.append_inventory_purchase_approval_event(
    v_order.id, 'submitted', 'draft', 'submitted', NULL,
    jsonb_build_object(
      'quantity_warning_policy', v_warning_payload->>'policy_version',
      'quantity_warning_token', CASE WHEN jsonb_array_length(v_warnings)>0
        THEN v_expected_token ELSE NULL END,
      'quantity_warnings', v_warnings,
      'quantity_warning_confirmed', jsonb_array_length(v_warnings)>0
    )
  );
  RETURN v_order;
END;
$$;

REVOKE ALL ON FUNCTION public.inventory_purchase_quantity_text_is_valid(text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.inventory_purchase_quantity_warning_payload(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_inventory_purchase_quantity_warnings(uuid, integer)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.submit_inventory_purchase_order(uuid, integer, text)
  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.inventory_purchase_quantity_text_is_valid(text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_inventory_purchase_quantity_warnings(uuid, integer)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_inventory_purchase_order(uuid, integer, text)
  TO authenticated;

DO $verify$
BEGIN
  IF NOT public.inventory_purchase_quantity_text_is_valid('0.5')
     OR NOT public.inventory_purchase_quantity_text_is_valid('0.001')
     OR public.inventory_purchase_quantity_text_is_valid('0')
     OR public.inventory_purchase_quantity_text_is_valid('0.0001')
     OR public.inventory_purchase_quantity_text_is_valid('0,5') THEN
    RAISE EXCEPTION 'inventory purchase quantity validation contract failed';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='inventory_supplier_items'
      AND column_name='allows_fractional_quantity'
  ) THEN
    RAISE EXCEPTION 'fractional quantity capability column missing';
  END IF;
END
$verify$;

COMMIT;
