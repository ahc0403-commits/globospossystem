-- General selections through POS, QR, direct request and approval.
-- Full effective function bodies preserve the existing permission and payment contracts.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';
ALTER TABLE public.direct_order_requests ADD COLUMN submission_hash text;
ALTER TABLE public.qr_order_batches ADD COLUMN submission_hash text;
ALTER TABLE public.direct_order_request_items DROP CONSTRAINT direct_order_request_items_request_id_menu_item_id_key;
CREATE INDEX direct_order_request_items_request_menu_idx ON public.direct_order_request_items(request_id,menu_item_id);


CREATE OR REPLACE FUNCTION "public"."validate_menu_option_batch"("p_store_id" "uuid", "p_items" "jsonb", "p_channel" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $_$
BEGIN
 IF jsonb_typeof(p_items)='array' AND (jsonb_array_length(p_items)>500 OR octet_length(p_items::text)>1048576) THEN RAISE EXCEPTION 'MENU_SELECTION_BATCH_LIMIT'; END IF;
 IF jsonb_typeof(p_items)='array' THEN
  PERFORM m.id FROM public.menu_items m JOIN (
   SELECT DISTINCT CASE WHEN x->>'menu_item_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN (x->>'menu_item_id')::uuid END id
   FROM jsonb_array_elements(p_items)x) ids ON ids.id=m.id
   WHERE m.restaurant_id=p_store_id ORDER BY m.id FOR SHARE OF m;
 END IF;
 IF jsonb_typeof(p_items)='array' AND EXISTS(
  SELECT 1 FROM jsonb_array_elements(p_items)x JOIN public.menu_items m
   ON m.id=CASE WHEN x->>'menu_item_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN (x->>'menu_item_id')::uuid END
   AND m.restaurant_id=p_store_id
  WHERE CASE WHEN m.choice_definition='{}'::jsonb THEN x->>'menu_option_key' IS DISTINCT FROM m.menu_option_key ELSE public.menu_choice_snapshot(to_jsonb(m),x->>'menu_option_key',p_channel) IS NULL END
 ) THEN
  IF p_channel='direct' THEN RAISE EXCEPTION 'DIRECT_ORDER_MENU_CHANGED';
  ELSIF p_channel='qr' THEN RAISE EXCEPTION 'QR_MENU_ITEM_UNAVAILABLE';
  ELSE RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID'; END IF;
 END IF;
EXCEPTION WHEN raise_exception THEN
 IF SQLERRM LIKE 'MENU_SELECTION_%' THEN
  IF p_channel='direct' THEN RAISE EXCEPTION 'DIRECT_ORDER_MENU_CHANGED';
  ELSIF p_channel='qr' THEN RAISE EXCEPTION 'QR_MENU_ITEM_UNAVAILABLE';
  ELSE RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID'; END IF;
 END IF;
 RAISE;
END $_$;

CREATE OR REPLACE FUNCTION "public"."create_order_pre_takeout_core"("p_store_id" "uuid", "p_table_id" "uuid", "p_items" "jsonb") RETURNS "public"."orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_table public.tables%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_item_count int := 0;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED';
  END IF;

  SELECT *
  INTO v_table
  FROM public.tables
  WHERE id = p_table_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  IF v_table.status <> 'available' THEN
    RAISE EXCEPTION 'TABLE_NOT_AVAILABLE';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    WHERE NULLIF(item->>'menu_item_id', '') IS NULL
       OR COALESCE((item->>'quantity')::int, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    LEFT JOIN public.menu_items m
      ON m.id = (item->>'menu_item_id')::uuid
     AND m.restaurant_id = p_store_id
     AND m.is_available = TRUE
    WHERE m.id IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE';
  END IF;

  INSERT INTO public.orders (restaurant_id, table_id, status, created_by)
  VALUES (p_store_id, p_table_id, 'pending', auth.uid())
  RETURNING * INTO v_order;

  INSERT INTO public.order_items (
    order_id,
    menu_item_id,
    quantity,
    unit_price,
    label,
    display_name,
    restaurant_id,
    item_type, menu_option_snapshot
  )
  SELECT
    v_order.id,
    m.id,
    (item->>'quantity')::int,
    coalesce((choice.snapshot->>'unit_price')::numeric,m.price),
    coalesce(choice.snapshot->>'name_ko',m.name),
    coalesce(choice.snapshot->>'name_ko',m.name),
    p_store_id,
    'menu_item', choice.snapshot
  FROM jsonb_array_elements(p_items) item
  JOIN public.menu_items m
    ON m.id = (item->>'menu_item_id')::uuid
   AND m.restaurant_id = p_store_id
   AND m.is_available = TRUE
  CROSS JOIN LATERAL (SELECT public.menu_choice_snapshot(to_jsonb(m),item->>'menu_option_key','pos') snapshot) choice;

  GET DIAGNOSTICS v_item_count = ROW_COUNT;

  UPDATE public.tables
  SET status = 'occupied',
      updated_at = now()
  WHERE id = p_table_id;

  PERFORM public.enqueue_print_jobs(
    v_order.id,
    ARRAY['kitchen', 'floor'],
    p_items,
    'initial'
  );

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'create_order',
    'orders',
    v_order.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'table_id', p_table_id,
      'item_count', v_item_count,
      'sales_channel', 'dine_in'
    )
  );

  RETURN v_order;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."add_items_to_order_pre_takeout_core"("p_order_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb") RETURNS SETOF "public"."order_items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_line record;
  v_item public.order_items%ROWTYPE;
  v_inserted_count int := 0;
  v_result_ids jsonb;
  v_print_items jsonb := '[]'::jsonb;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED';
  END IF;

  SELECT *
  INTO v_order
  FROM public.orders
  WHERE id = p_order_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    WHERE NULLIF(item->>'menu_item_id', '') IS NULL
       OR COALESCE((item->>'quantity')::int, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    LEFT JOIN public.menu_items m
      ON m.id = (item->>'menu_item_id')::uuid
     AND m.restaurant_id = p_store_id
     AND m.is_available = TRUE
    WHERE m.id IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE';
  END IF;

  WITH input AS MATERIALIZED (
    SELECT gen_random_uuid() id,raw,ord FROM jsonb_array_elements(p_items) WITH ORDINALITY item(raw,ord)
  ), inserted AS (
    INSERT INTO public.order_items(id,order_id,menu_item_id,quantity,unit_price,label,display_name,restaurant_id,item_type,menu_option_snapshot)
    SELECT src.id,p_order_id,m.id,(raw->>'quantity')::int,coalesce((c.snapshot->>'unit_price')::numeric,m.price),coalesce(c.snapshot->>'name_ko',m.name),coalesce(c.snapshot->>'name_ko',m.name),p_store_id,'menu_item',c.snapshot
    FROM input src JOIN public.menu_items m ON m.id=(raw->>'menu_item_id')::uuid
      AND m.restaurant_id=p_store_id AND m.is_available
    CROSS JOIN LATERAL (SELECT public.menu_choice_snapshot(to_jsonb(m),raw->>'menu_option_key','pos') snapshot)c ORDER BY ord RETURNING *
  ) SELECT count(*)::integer,coalesce(jsonb_agg(i.id ORDER BY src.ord),'[]'),
    coalesce(jsonb_agg(jsonb_build_object('item_id',i.id::text,'menu_item_id',i.menu_item_id::text,
      'label',coalesce(nullif(i.label,''),nullif(i.display_name,''),'Item'),'quantity',i.quantity,
      'notes',i.notes,'supplemental',true,'components',coalesce(i.combo_components,'[]')) ORDER BY src.ord),'[]')
    INTO v_inserted_count,v_result_ids,v_print_items FROM inserted i JOIN input src ON src.id=i.id;

  PERFORM public.recalc_order_status(p_order_id);
  PERFORM public.void_active_order_discount_for_item_change(
    p_order_id,
    p_store_id,
    'order_items_changed'
  );
  PERFORM public.enqueue_print_jobs(
    p_order_id,
    ARRAY['kitchen', 'floor'],
    v_print_items,
    'added_items'
  );

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'add_items_to_order',
    'orders',
    p_order_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'added_item_count', v_inserted_count
    )
  );

  RETURN QUERY SELECT item.* FROM jsonb_array_elements_text(v_result_ids) WITH ORDINALITY ids(id,ord)
    JOIN public.order_items item ON item.id=ids.id::uuid ORDER BY ids.ord;
  RETURN;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."qr_place_order_pre_takeout_core"("p_token" "text", "p_items" "jsonb", "p_client_order_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $_$
DECLARE
  v_token text := NULLIF(btrim(COALESCE(p_token, '')), '');
  v_table record;
  v_existing_batch public.qr_order_batches%ROWTYPE;
  v_items jsonb := COALESCE(p_items, '[]'::jsonb);
  v_item_count int;
  v_line record;
  v_inserted_item public.order_items%ROWTYPE;
  v_live_order public.orders%ROWTYPE;
  v_order_id uuid;
  v_is_new_order boolean := false;
  v_batch_no int;
  v_items_snapshot jsonb := '[]'::jsonb;
  v_print_items jsonb := '[]'::jsonb;
  v_result jsonb;
  v_print_reason text;
BEGIN
  IF p_client_order_id IS NULL THEN
    RAISE EXCEPTION 'QR_CLIENT_ORDER_ID_REQUIRED';
  END IF;

  SELECT
    q.restaurant_id,
    q.table_id,
    t.table_number,
    COALESCE(t.floor_label, '1F') AS floor_label,
    r.name AS store_name
  INTO v_table
  FROM public.table_qr_tokens q
  JOIN public.tables t
    ON t.id = q.table_id
   AND t.restaurant_id = q.restaurant_id
  JOIN public.restaurants r
    ON r.id = q.restaurant_id
   AND r.is_active = true
  WHERE q.token = v_token
    AND q.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QR_TOKEN_INVALID';
  END IF;

  SELECT *
  INTO v_existing_batch
  FROM public.qr_order_batches
  WHERE client_order_id = p_client_order_id
    AND restaurant_id = v_table.restaurant_id
    AND table_id = v_table.table_id;

  IF FOUND THEN
    IF v_existing_batch.submission_hash IS NOT NULL AND v_existing_batch.submission_hash IS DISTINCT FROM md5(v_items::text) THEN RAISE EXCEPTION 'QR_ITEMS_INVALID'; END IF;
    RETURN v_existing_batch.result_snapshot;
  END IF;

  IF jsonb_typeof(v_items) <> 'array' THEN
    RAISE EXCEPTION 'QR_ITEMS_INVALID';
  END IF;

  v_item_count := jsonb_array_length(v_items);
  IF v_item_count < 1 OR v_item_count > 20 THEN
    RAISE EXCEPTION 'QR_ITEMS_INVALID';
  END IF;

  FOR v_line IN
    SELECT raw
    FROM jsonb_array_elements(v_items) AS line(raw)
  LOOP
    IF COALESCE(v_line.raw->>'menu_item_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION 'QR_ITEMS_INVALID';
    END IF;
    IF COALESCE(v_line.raw->>'quantity', '') !~ '^[0-9]+$'
       OR (v_line.raw->>'quantity')::int < 1
       OR (v_line.raw->>'quantity')::int > 20 THEN
      RAISE EXCEPTION 'QR_ITEMS_INVALID';
    END IF;
  END LOOP;

  IF EXISTS (
    SELECT 1
    FROM public.qr_order_batches b
    WHERE b.table_id = v_table.table_id
      AND b.created_at > now() - interval '20 seconds'
  ) THEN
    RAISE EXCEPTION 'QR_TOO_FREQUENT';
  END IF;

  WITH input_items AS (
    SELECT
      (raw->>'menu_item_id')::uuid AS menu_item_id,
      (raw->>'quantity')::int AS quantity,raw->>'menu_option_key' selection_key,
      ord
    FROM jsonb_array_elements(v_items) WITH ORDINALITY AS line(raw, ord)
  ),
  matched_items AS (
    SELECT
      i.menu_item_id,
      i.quantity,
      i.ord,
      coalesce(c.snapshot->>'name_ko',m.name) name,
      coalesce((c.snapshot->>'unit_price')::numeric,m.price) price,c.snapshot
    FROM input_items i
    JOIN public.menu_items m
      ON m.id = i.menu_item_id
     AND m.restaurant_id = v_table.restaurant_id
     AND m.is_available = true
     AND m.is_visible_public = true
    CROSS JOIN LATERAL (SELECT public.menu_choice_snapshot(to_jsonb(m),i.selection_key,'qr') snapshot)c
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'menu_item_id', menu_item_id::text,
        'quantity', quantity,
        'name', name,
        'unit_price', price,'menu_option_snapshot',snapshot
      )
      ORDER BY ord
    ),
    '[]'::jsonb
  )
  INTO v_items_snapshot
  FROM matched_items;

  IF jsonb_array_length(v_items_snapshot) <> v_item_count THEN
    RAISE EXCEPTION 'QR_MENU_ITEM_UNAVAILABLE';
  END IF;

  PERFORM 1
  FROM public.tables
  WHERE id = v_table.table_id
    AND restaurant_id = v_table.restaurant_id
  FOR UPDATE;

  SELECT *
  INTO v_live_order
  FROM public.orders
  WHERE table_id = v_table.table_id
    AND restaurant_id = v_table.restaurant_id
    AND status IN ('pending', 'confirmed', 'serving') AND public.table_order_is_current(orders)
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO public.orders (
      restaurant_id,
      table_id,
      sales_channel,
      status,
      created_by,
      order_source,
      order_purpose
    )
    VALUES (
      v_table.restaurant_id,
      v_table.table_id,
      'dine_in',
      'pending',
      NULL,
      'qr',
      'customer'
    )
    RETURNING * INTO v_live_order;

    v_is_new_order := true;

    UPDATE public.tables
    SET status = 'occupied',
        updated_at = now()
    WHERE id = v_table.table_id;
  ELSE
    -- Partial payments remain attached to this open order. A fully paid
    -- order is completed by process_payment and is not selected above.
  END IF;

  v_order_id := v_live_order.id;

  WITH input AS MATERIALIZED (
    SELECT gen_random_uuid() id,raw,ord FROM jsonb_array_elements(v_items_snapshot) WITH ORDINALITY item(raw,ord)
  ), inserted AS (
    INSERT INTO public.order_items(id,order_id,menu_item_id,quantity,unit_price,label,display_name,restaurant_id,item_type,menu_option_snapshot)
    SELECT id,v_order_id,(raw->>'menu_item_id')::uuid,(raw->>'quantity')::int,
      (raw->>'unit_price')::numeric,raw->>'name',raw->>'name',v_table.restaurant_id,'menu_item',raw->'menu_option_snapshot'
    FROM input ORDER BY ord RETURNING *
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('item_id',i.id::text,'menu_item_id',i.menu_item_id::text,
    'label',coalesce(nullif(i.label,''),nullif(i.display_name,''),'Item'),'quantity',i.quantity,
    'notes',i.notes,'supplemental',NOT v_is_new_order) ORDER BY src.ord),'[]')
  INTO v_print_items FROM inserted i JOIN input src ON src.id=i.id;

  IF NOT v_is_new_order THEN
    PERFORM public.void_active_order_discount_for_item_change(
      v_order_id,
      v_table.restaurant_id,
      'order_items_changed'
    );
  END IF;

  PERFORM public.recalc_order_status(v_order_id);

  SELECT COALESCE(MAX(batch_no), 0) + 1
  INTO v_batch_no
  FROM public.print_jobs
  WHERE order_id = v_order_id
    AND copy_type IN ('kitchen', 'floor', 'confirmation');

  v_print_reason := CASE WHEN v_batch_no = 1 THEN 'initial' ELSE 'added_items' END;

  PERFORM public.enqueue_print_jobs(
    v_order_id,
    ARRAY['kitchen', 'floor', 'confirmation'],
    v_print_items,
    v_print_reason
  );

  v_result := jsonb_build_object(
    'order_id', v_order_id::text,
    'order_code', substring(v_order_id::text from 1 for 8),
    'batch_no', v_batch_no,
    'table_number', v_table.table_number,
    'floor_label', v_table.floor_label,
    'items', (
      SELECT COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'name', item->>'name',
            'quantity', (item->>'quantity')::int
          )
        ),
        '[]'::jsonb
      )
      FROM jsonb_array_elements(v_items_snapshot) item
    )
  );

  INSERT INTO public.qr_order_batches (
    restaurant_id,
    table_id,
    order_id,
    batch_no,
    client_order_id,
    items_snapshot,
    result_snapshot,submission_hash
  )
  VALUES (
    v_table.restaurant_id,
    v_table.table_id,
    v_order_id,
    v_batch_no,
    p_client_order_id,
    v_items_snapshot,
    v_result,md5(v_items::text)
  );

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    NULL,
    'qr_place_order',
    'orders',
    v_order_id,
    jsonb_build_object(
      'store_id', v_table.restaurant_id,
      'table_id', v_table.table_id,
      'batch_no', v_batch_no,
      'client_order_id', p_client_order_id,
      'item_count', v_item_count
    )
  );

  RETURN v_result;
EXCEPTION
  WHEN unique_violation THEN
    SELECT *
    INTO v_existing_batch
    FROM public.qr_order_batches
    WHERE client_order_id = p_client_order_id
      AND restaurant_id = v_table.restaurant_id
      AND table_id = v_table.table_id;
    IF FOUND THEN
      IF v_existing_batch.submission_hash IS NOT NULL AND v_existing_batch.submission_hash IS DISTINCT FROM md5(v_items::text) THEN RAISE EXCEPTION 'QR_ITEMS_INVALID'; END IF;
    RETURN v_existing_batch.result_snapshot;
    END IF;
    RAISE;
END;
$_$;

CREATE OR REPLACE FUNCTION "public"."qr_place_order"("p_token" "text", "p_items" "jsonb", "p_client_order_id" "uuid", "p_validate_combo_choices" boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_catalog'
    AS $_$
DECLARE
  v_token text := NULLIF(btrim(COALESCE(p_token, '')), '');
  v_items jsonb := COALESCE(p_items, '[]'::jsonb);
  v_table record;
  v_existing public.qr_order_batches%ROWTYPE;
  v_line record;
  v_choice_count integer;
  v_expected_count integer;
BEGIN
  IF p_client_order_id IS NULL OR jsonb_typeof(v_items) <> 'array' THEN
    RAISE EXCEPTION 'QR_ITEMS_INVALID';
  END IF;

  IF (
    SELECT count(*)
    FROM (
      SELECT line.raw->>'menu_item_id',line.raw->>'menu_option_key',
             COALESCE((line.raw->>'is_takeout')::boolean, false)
      FROM jsonb_array_elements(v_items) line(raw)
      GROUP BY line.raw->>'menu_item_id',line.raw->>'menu_option_key',
               COALESCE((line.raw->>'is_takeout')::boolean, false)
    ) unique_lines
  ) <> jsonb_array_length(v_items) THEN
    RAISE EXCEPTION 'QR_ITEMS_INVALID';
  END IF;

  SELECT q.restaurant_id, q.table_id
  INTO v_table
  FROM public.table_qr_tokens q
  JOIN public.tables t ON t.id = q.table_id AND t.restaurant_id = q.restaurant_id
  JOIN public.restaurants r ON r.id = q.restaurant_id AND r.is_active = true
  WHERE q.token = v_token AND q.is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'QR_TOKEN_INVALID'; END IF;

  SELECT * INTO v_existing
  FROM public.qr_order_batches
  WHERE client_order_id = p_client_order_id
    AND restaurant_id = v_table.restaurant_id
    AND table_id = v_table.table_id;
  IF FOUND THEN
   IF v_existing.submission_hash IS NOT NULL AND v_existing.submission_hash IS DISTINCT FROM md5(v_items::text) THEN RAISE EXCEPTION 'QR_ITEMS_INVALID'; END IF;
   RETURN v_existing.result_snapshot; END IF;

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) line(raw)
    WHERE coalesce(raw->>'menu_item_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      OR coalesce(raw->>'quantity','') !~ '^[0-9]+$'
      OR (raw ? 'is_takeout' AND jsonb_typeof(raw->'is_takeout')<>'boolean')) THEN
    RAISE EXCEPTION 'QR_ITEMS_INVALID';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_items) line(raw)
    WHERE jsonb_typeof(coalesce(raw->'combo_drink_choices','[]'))<>'array') THEN
    RAISE EXCEPTION 'QR_COMBO_DRINK_CHOICES_INVALID';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_items) line(raw)
    LEFT JOIN public.menu_items menu ON menu.id=(raw->>'menu_item_id')::uuid
    WHERE jsonb_array_length(coalesce(raw->'combo_drink_choices','[]'))<>
      CASE WHEN menu.is_combo THEN coalesce(menu.combo_drink_choice_count,0) ELSE 0 END*(raw->>'quantity')::integer) THEN
    RAISE EXCEPTION 'QR_COMBO_DRINK_CHOICES_INVALID';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_items) line(raw)
    CROSS JOIN LATERAL jsonb_array_elements_text(coalesce(raw->'combo_drink_choices','[]')) choice(value)
    LEFT JOIN public.menu_items option_item ON option_item.id=CASE
      WHEN choice.value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN choice.value::uuid ELSE NULL END
      AND option_item.restaurant_id=v_table.restaurant_id AND NOT option_item.is_archived
      AND option_item.is_available AND option_item.is_visible_public AND NOT option_item.is_combo
    LEFT JOIN public.menu_categories drink_category ON drink_category.id=option_item.category_id
      AND drink_category.restaurant_id=v_table.restaurant_id AND drink_category.system_key='drink' AND drink_category.is_active
    WHERE option_item.id IS NULL OR drink_category.id IS NULL) THEN
    RAISE EXCEPTION 'QR_COMBO_DRINK_CHOICES_INVALID';
  END IF;

  PERFORM public.validate_menu_option_batch(v_table.restaurant_id,v_items,'qr');
  PERFORM set_config('pos.qr_combo_payload', v_items::text, true);
  RETURN public.qr_place_order(p_token, p_items, p_client_order_id);
END;
$_$;

CREATE OR REPLACE FUNCTION "public"."direct_order_prepare_combo_items"("p_store_id" "uuid", "p_items" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $_$
DECLARE prepared jsonb;
BEGIN
 IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 50 THEN
  RAISE EXCEPTION 'DIRECT_ORDER_ITEM_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_items) e WHERE jsonb_typeof(e) IS DISTINCT FROM 'object'
  OR COALESCE(e->>'menu_item_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  OR COALESCE(e->>'quantity','') !~ '^[1-9][0-9]?$'
  OR jsonb_typeof(COALESCE(e->'combo_drink_choices','[]')) IS DISTINCT FROM 'array'
  OR char_length(COALESCE(e->>'note',''))>300) THEN RAISE EXCEPTION 'DIRECT_ORDER_ITEM_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_items) e WHERE (e->>'quantity')::integer>50
  OR jsonb_array_length(COALESCE(e->'combo_drink_choices','[]'))>500)
 OR (SELECT count(DISTINCT ROW((e->>'menu_item_id')::uuid,e->>'menu_option_key')) FROM jsonb_array_elements(p_items)e)<>jsonb_array_length(p_items)
 THEN RAISE EXCEPTION 'DIRECT_ORDER_ITEM_INVALID'; END IF;
 IF (SELECT sum((e->>'quantity')::integer) FROM jsonb_array_elements(p_items)e)>100 THEN RAISE EXCEPTION 'DIRECT_ORDER_QUANTITY_LIMIT'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_items)e CROSS JOIN LATERAL jsonb_array_elements(COALESCE(e->'combo_drink_choices','[]'))c
  WHERE jsonb_typeof(c) IS DISTINCT FROM 'string' OR (c#>>'{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
 THEN RAISE EXCEPTION 'DIRECT_ORDER_COMBO_CHOICES_INVALID'; END IF;
 PERFORM public.validate_menu_option_batch(p_store_id,p_items,'direct');
 -- Stable lock order covers parent menus, fixed components and chosen drinks.
 PERFORM m.id FROM public.menu_items m JOIN (
  SELECT (e->>'menu_item_id')::uuid id FROM jsonb_array_elements(p_items)e
  UNION SELECT co.component_menu_item_id FROM public.menu_combo_components co
   JOIN jsonb_array_elements(p_items)e ON co.combo_menu_item_id=(e->>'menu_item_id')::uuid WHERE co.restaurant_id=p_store_id
  UNION SELECT c::uuid FROM jsonb_array_elements(p_items)e CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(e->'combo_drink_choices','[]'))c
 ) ids ON ids.id=m.id WHERE m.restaurant_id=p_store_id ORDER BY m.id FOR SHARE OF m;
 WITH lines AS MATERIALIZED(
  SELECT e.raw,e.ord,gen_random_uuid() line_id,m.id,
   coalesce(c.snapshot->>'name_ko',m.name) name,coalesce(c.snapshot->>'name_ko',m.name_ko) name_ko,
   coalesce(c.snapshot->>'name_vi',m.name_vi) name_vi,coalesce(c.snapshot->>'name_en',m.name_en) name_en,
   m.vat_category,coalesce((c.snapshot->>'unit_price')::numeric,m.price) price,m.is_combo,c.snapshot,
   m.combo_drink_choice_count,m.effective_vat_rate,(e.raw->>'quantity')::integer qty,
   m.restaurant_id=p_store_id AND m.is_available AND m.is_visible_public AND NOT m.is_archived
    AND (m.category_id IS NULL OR cat.is_active) valid
  FROM jsonb_array_elements(p_items) WITH ORDINALITY e(raw,ord)
  LEFT JOIN public.menu_items m ON m.id=(e.raw->>'menu_item_id')::uuid AND m.restaurant_id=p_store_id
  LEFT JOIN public.menu_categories cat ON cat.id=m.category_id AND cat.restaurant_id=p_store_id
  CROSS JOIN LATERAL (SELECT public.menu_choice_snapshot(to_jsonb(m),e.raw->>'menu_option_key','direct') snapshot)c
 ), fixed AS MATERIALIZED(
  SELECT l.line_id parent,co.component_menu_item_id id,co.quantity,co.sort_order,
   m.name,m.name_ko,m.name_vi,m.name_en,m.price,m.effective_vat_rate,m.fulfillment_route,
   m.id IS NOT NULL AND m.is_available AND m.is_visible_public AND NOT m.is_archived AND NOT m.is_combo
    AND m.price>0 AND co.quantity>0 AND (m.category_id IS NULL OR cat.is_active) valid
  FROM lines l JOIN public.menu_combo_components co ON co.combo_menu_item_id=l.id AND co.restaurant_id=p_store_id AND l.is_combo
  LEFT JOIN public.menu_items m ON m.id=co.component_menu_item_id AND m.restaurant_id=p_store_id
  LEFT JOIN public.menu_categories cat ON cat.id=m.category_id AND cat.restaurant_id=p_store_id
  WHERE m.id IS NULL OR COALESCE(l.combo_drink_choice_count,0)=0 OR lower(btrim(COALESCE(NULLIF(m.name_ko,''),m.name))) NOT IN('음료','drink','beverage','đồ uống','nước uống')
 ), selected AS MATERIALIZED(
  SELECT l.line_id parent,c.id::uuid id,count(*)::integer quantity,min(c.ord)::integer sort_order
  FROM lines l CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(l.raw->'combo_drink_choices','[]')) WITH ORDINALITY c(id,ord)
  GROUP BY l.line_id,c.id
 ), drinks AS MATERIALIZED(
  SELECT s.*,m.name,m.name_ko,m.name_vi,m.name_en,m.price,m.effective_vat_rate,m.fulfillment_route,
   m.id IS NOT NULL AND m.is_available AND m.is_visible_public AND NOT m.is_archived AND NOT m.is_combo
    AND m.price>0 AND cat.is_active AND cat.system_key='drink' valid
  FROM selected s LEFT JOIN public.menu_items m ON m.id=s.id AND m.restaurant_id=p_store_id
  LEFT JOIN public.menu_categories cat ON cat.id=m.category_id AND cat.restaurant_id=p_store_id
 ), parts AS MATERIALIZED(
  SELECT *,false is_total FROM fixed UNION ALL SELECT *,true FROM drinks
 ), normalized AS MATERIALIZED(
  SELECT p.parent,p.id,p.name,p.name_ko,p.name_vi,p.name_en,p.price,p.effective_vat_rate,p.fulfillment_route,
   min(p.sort_order) sort_order,bool_and(p.valid) valid,bool_or(p.is_total) is_total,
   COALESCE(sum(p.quantity) FILTER(WHERE NOT p.is_total),0)::integer fixed_quantity,
   CASE WHEN bool_or(p.is_total) AND bool_or(NOT p.is_total)
    THEN sum(p.quantity*CASE WHEN p.is_total THEN 1 ELSE l.qty END) ELSE sum(p.quantity) END quantity
  FROM parts p JOIN lines l ON l.line_id=p.parent
  GROUP BY p.parent,p.id,p.name,p.name_ko,p.name_vi,p.name_en,p.price,p.effective_vat_rate,p.fulfillment_route
 ), snapshots AS(
  SELECT parent,bool_and(valid) valid,count(*) component_count,jsonb_agg(jsonb_build_object(
   'menu_item_id',id,'label',name,'name_ko',COALESCE(NULLIF(name_ko,''),name),
   'name_vi',COALESCE(NULLIF(name_vi,''),name),'name_en',COALESCE(NULLIF(name_en,''),name),
   'quantity',quantity,'fixed_quantity',fixed_quantity,'is_total_quantity',is_total,'fulfillment_route',fulfillment_route,
   'tax_unit_price',price,'tax_vat_rate',effective_vat_rate) ORDER BY is_total,sort_order,id) components
  FROM normalized GROUP BY parent
 ), rates AS(
  SELECT p.parent,p.effective_vat_rate rate,sum(p.price*p.quantity*CASE WHEN p.is_total THEN 1 ELSE l.qty END) weight
  FROM parts p JOIN lines l ON l.line_id=p.parent GROUP BY p.parent,p.effective_vat_rate
 ), profiles AS(SELECT parent,jsonb_agg(jsonb_build_object('rate',rate,'weight',weight) ORDER BY rate) profile FROM rates GROUP BY parent)
 SELECT jsonb_agg(jsonb_build_object('line_id',l.line_id,'menu_option_snapshot',l.snapshot,'menu_item_id',l.id,'display_name',l.name,
  'name_ko',COALESCE(NULLIF(l.name_ko,''),l.name),'name_vi',COALESCE(NULLIF(l.name_vi,''),l.name),'name_en',COALESCE(NULLIF(l.name_en,''),l.name),
  'vat_category',COALESCE(l.vat_category,'food'),'unit_price',l.price,'quantity',l.qty,'item_note',NULLIF(btrim(l.raw->>'note'),''),'sort_order',l.ord-1,
  'combo_drink_choices',COALESCE(l.raw->'combo_drink_choices','[]'),'combo_components',COALESCE(s.components,'[]'),
  'vat_profile_snapshot',CASE WHEN l.is_combo THEN pr.profile ELSE jsonb_build_array(jsonb_build_object('rate',l.effective_vat_rate,'weight',1)) END,
  'valid',COALESCE(l.valid,false) AND (NOT l.is_combo OR (COALESCE(s.valid,false) AND s.component_count>0))
   AND jsonb_array_length(COALESCE(l.raw->'combo_drink_choices','[]'))=COALESCE(l.combo_drink_choice_count,0)*l.qty
  ) ORDER BY l.ord) INTO prepared FROM lines l LEFT JOIN snapshots s ON s.parent=l.line_id LEFT JOIN profiles pr ON pr.parent=l.line_id;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(prepared)e WHERE NOT (e->>'valid')::boolean) THEN
  RAISE EXCEPTION 'DIRECT_ORDER_COMBO_UNAVAILABLE'; END IF;
 RETURN prepared;
END $_$;

CREATE OR REPLACE FUNCTION "public"."direct_order_public_submit"("p_session_id" "uuid", "p_secret_hash" "text", "p_client_request_id" "uuid", "p_payload" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $_$
DECLARE
  v_prepared jsonb; v_previous_prepared text;
  v_session public.direct_order_sessions%ROWTYPE;
  v_storefront public.direct_order_storefronts%ROWTYPE;
  v_request public.direct_order_requests%ROWTYPE;
  v_existing public.direct_order_requests%ROWTYPE;
  v_address jsonb;
  v_item jsonb;
  v_menu public.menu_items%ROWTYPE;
  v_item_count integer := 0;
  v_total_quantity integer := 0;
  v_reference text;
  v_local_time time;
BEGIN
  IF p_client_request_id IS NULL
     OR p_payload IS NULL
     OR jsonb_typeof(p_payload) <> 'object'
     OR jsonb_typeof(p_payload->'items') <> 'array'
     OR jsonb_array_length(p_payload->'items') NOT BETWEEN 1 AND 50
     OR jsonb_typeof(p_payload->'address') <> 'object'
     OR COALESCE(p_payload->>'locale', '') NOT IN ('ko', 'vi', 'en') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_INPUT_INVALID';
  END IF;

  v_session := public.direct_order_validate_session(
    p_session_id, p_secret_hash
  );

  PERFORM pg_advisory_xact_lock(hashtextextended(v_session.restaurant_id::text||':direct-submit:'||p_client_request_id::text,0));
  SELECT * INTO v_existing
  FROM public.direct_order_requests request_row
  WHERE request_row.client_request_id = p_client_request_id;
  IF FOUND THEN
    IF v_existing.session_id <> v_session.id
       OR v_existing.restaurant_id <> v_session.restaurant_id THEN
      RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_INPUT_INVALID';
    END IF;
    IF v_existing.submission_hash IS NOT NULL AND v_existing.submission_hash IS DISTINCT FROM md5(p_payload::text) THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_INPUT_INVALID'; END IF;
    RETURN jsonb_build_object(
      'request_id', v_existing.id,
      'reference_code', v_existing.reference_code,
      'state', v_existing.state,
      'idempotent', true
    );
  END IF;

  SELECT * INTO v_storefront
  FROM public.direct_order_storefronts storefront
  WHERE storefront.restaurant_id = v_session.restaurant_id
    AND storefront.is_enabled = true
  FOR SHARE;

  IF NOT FOUND OR v_storefront.is_paused THEN
    RAISE EXCEPTION 'DIRECT_ORDER_STOREFRONT_PAUSED';
  END IF;

  v_local_time := (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::time;
  IF v_storefront.ordering_hours_enforced
     AND (v_local_time < v_storefront.ordering_starts_at
          OR v_local_time >= v_storefront.ordering_cutoff_at) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_OUTSIDE_HOURS';
  END IF;


  v_address := p_payload->'address';
  IF char_length(btrim(COALESCE(v_address->>'customer_name', ''))) NOT BETWEEN 1 AND 100
     OR COALESCE(v_address->>'customer_phone', '') !~ '^[+]?[0-9][0-9 -]{7,19}$'
     OR char_length(btrim(COALESCE(v_address->>'formatted_address', ''))) NOT BETWEEN 3 AND 500
     OR char_length(btrim(COALESCE(v_address->>'detail_address', ''))) NOT BETWEEN 0 AND 300 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_INVALID';
  END IF;

  IF v_address->>'address_source' = 'manual' THEN
    -- A typed address has no verified location. Never manufacture coordinates
    -- or reuse a stale pin when the customer edits a previously saved address.
    IF v_address->>'latitude' IS NOT NULL
       OR v_address->>'longitude' IS NOT NULL
       OR NULLIF(btrim(COALESCE(v_address->>'google_place_id', '')), '') IS NOT NULL
       OR COALESCE(v_address->>'location_verified', 'false') <> 'false' THEN
      RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_INVALID';
    END IF;
  ELSIF COALESCE(v_address->>'address_source', '') NOT IN ('search', 'map_pin')
     OR COALESCE(v_address->>'location_verified', 'false') <> 'true'
     OR v_address->>'latitude' IS NULL
     OR v_address->>'longitude' IS NULL THEN
    -- Preserve in-flight legacy client compatibility without relaxing its
    -- existing location requirements.
    RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_INVALID';
  END IF;

  v_reference := 'D' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

  INSERT INTO public.direct_order_requests(
    restaurant_id, session_id, client_request_id, reference_code,
    state, locale, customer_note
  ) VALUES (
    v_session.restaurant_id,
    v_session.id,
    p_client_request_id,
    v_reference,
    'awaiting_quote',
    COALESCE(NULLIF(p_payload->>'locale', ''), v_session.locale),
    NULLIF(btrim(COALESCE(p_payload->>'customer_note', '')), '')
  ) RETURNING * INTO v_request;

  UPDATE public.direct_order_requests SET submission_hash=md5(p_payload::text) WHERE id=v_request.id;
  v_prepared:=public.direct_order_prepare_combo_items(v_session.restaurant_id,p_payload->'items');
  v_previous_prepared:=current_setting('pos.direct_prepared_items',true);
  PERFORM set_config('pos.direct_prepared_items',(SELECT jsonb_object_agg(e->>'line_id',e) FROM jsonb_array_elements(v_prepared)e)::text,true);
  INSERT INTO public.direct_order_request_items(id,request_id,restaurant_id,menu_item_id,display_name,name_ko,name_vi,name_en,vat_category,unit_price,quantity,item_note,sort_order,combo_drink_choices,combo_components,vat_profile_snapshot,menu_option_snapshot)
  SELECT (e->>'line_id')::uuid,v_request.id,v_request.restaurant_id,(e->>'menu_item_id')::uuid,e->>'display_name',e->>'name_ko',e->>'name_vi',e->>'name_en',e->>'vat_category',
   (e->>'unit_price')::numeric,(e->>'quantity')::integer,e->>'item_note',(e->>'sort_order')::integer,e->'combo_drink_choices',e->'combo_components',e->'vat_profile_snapshot',e->'menu_option_snapshot'
  FROM jsonb_array_elements(v_prepared)e;
  PERFORM set_config('pos.direct_prepared_items',COALESCE(v_previous_prepared,''),true);
  SELECT sum((e->>'quantity')::integer) INTO v_total_quantity FROM jsonb_array_elements(v_prepared)e;
  IF v_total_quantity > 100 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_QUANTITY_LIMIT';
  END IF;

  INSERT INTO public.direct_order_request_addresses(
    request_id, restaurant_id, customer_name, customer_phone,
    formatted_address, detail_address, latitude, longitude,
    google_place_id, district, ward, address_source, location_verified
  ) VALUES (
    v_request.id,
    v_request.restaurant_id,
    btrim(v_address->>'customer_name'),
    btrim(v_address->>'customer_phone'),
    btrim(v_address->>'formatted_address'),
    btrim(v_address->>'detail_address'),
    (v_address->>'latitude')::numeric,
    (v_address->>'longitude')::numeric,
    NULLIF(btrim(COALESCE(v_address->>'google_place_id', '')), ''),
    NULLIF(btrim(COALESCE(v_address->>'district', '')), ''),
    NULLIF(btrim(COALESCE(v_address->>'ward', '')), ''),
    v_address->>'address_source',
    v_address->>'address_source' <> 'manual'
  );

  IF v_address->>'address_source' <> 'manual' THEN
    INSERT INTO public.direct_order_location_facts(
      request_id, restaurant_id, district, ward,
      coarse_latitude, coarse_longitude, requested_at
    ) VALUES (
      v_request.id,
      v_request.restaurant_id,
      NULLIF(btrim(COALESCE(v_address->>'district', '')), ''),
      NULLIF(btrim(COALESCE(v_address->>'ward', '')), ''),
      round((v_address->>'latitude')::numeric, 3),
      round((v_address->>'longitude')::numeric, 3),
      v_request.created_at
    );
  END IF;

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, message_type, body
  ) VALUES (
    v_request.id,
    v_request.restaurant_id,
    'system',
    'system',
    'DIRECT_ORDER_REQUEST_RECEIVED'
  );

  RETURN jsonb_build_object(
    'request_id', v_request.id,
    'reference_code', v_request.reference_code,
    'state', v_request.state,
    'idempotent', false
  );
END;
$_$;

CREATE OR REPLACE FUNCTION "public"."direct_order_public_submit_v2"("p_session_id" "uuid", "p_secret_hash" "text", "p_client_request_id" "uuid", "p_payload" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $_$
DECLARE
  v_prepared jsonb; v_previous_prepared text;
  v_session public.direct_order_sessions%ROWTYPE;
  v_storefront public.direct_order_storefronts%ROWTYPE;
  v_request public.direct_order_requests%ROWTYPE;
  v_existing public.direct_order_requests%ROWTYPE;
  v_address jsonb;
  v_type text := p_payload->>'fulfillment_type';
  v_item jsonb;
  v_menu public.menu_items%ROWTYPE;
  v_item_count integer := 0;
  v_total_quantity integer := 0;
  v_reference text;
  v_local_time time;
BEGIN
  IF p_client_request_id IS NULL
     OR p_payload IS NULL
     OR jsonb_typeof(p_payload) <> 'object'
     OR jsonb_typeof(p_payload->'items') <> 'array'
     OR jsonb_array_length(p_payload->'items') NOT BETWEEN 1 AND 50
     OR jsonb_typeof(p_payload->'address') <> 'object'
     OR COALESCE(p_payload->>'locale', '') NOT IN ('ko', 'vi', 'en') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_INPUT_INVALID';
  END IF;

  IF v_type IS NULL OR v_type NOT IN ('delivery','pickup') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_INPUT_INVALID';
  END IF;
  v_session := public.direct_order_validate_session(
    p_session_id, p_secret_hash
  );

  PERFORM pg_advisory_xact_lock(hashtextextended(v_session.restaurant_id::text||':direct-submit:'||p_client_request_id::text,0));
  SELECT * INTO v_existing
  FROM public.direct_order_requests request_row
  WHERE request_row.client_request_id = p_client_request_id;
  IF FOUND THEN
    IF v_existing.session_id <> v_session.id
       OR v_existing.restaurant_id <> v_session.restaurant_id THEN
      RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_INPUT_INVALID';
    END IF;
    IF v_existing.fulfillment_type <> v_type THEN
      RAISE EXCEPTION 'DIRECT_ORDER_FULFILLMENT_TYPE_LOCKED';
    END IF;
    IF v_existing.submission_hash IS NOT NULL AND v_existing.submission_hash IS DISTINCT FROM md5(p_payload::text) THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_INPUT_INVALID'; END IF;
    RETURN jsonb_build_object(
      'request_id', v_existing.id,
      'reference_code', v_existing.reference_code,
      'state', v_existing.state,
      'idempotent', true
    );
  END IF;

  SELECT * INTO v_storefront
  FROM public.direct_order_storefronts storefront
  WHERE storefront.restaurant_id = v_session.restaurant_id
    AND storefront.is_enabled = true
  FOR SHARE;

  IF NOT FOUND OR v_storefront.is_paused THEN
    RAISE EXCEPTION 'DIRECT_ORDER_STOREFRONT_PAUSED';
  END IF;

  v_local_time := (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::time;
  IF v_storefront.ordering_hours_enforced
     AND (v_local_time < v_storefront.ordering_starts_at
          OR v_local_time >= v_storefront.ordering_cutoff_at) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_OUTSIDE_HOURS';
  END IF;


  v_address := p_payload->'address';
  IF char_length(btrim(COALESCE(v_address->>'customer_name', ''))) NOT BETWEEN 1 AND 100
     OR COALESCE(v_address->>'customer_phone', '') !~ '^[+]?[0-9][0-9 -]{7,19}$'
     OR (v_type='delivery' AND (char_length(btrim(COALESCE(v_address->>'formatted_address', ''))) NOT BETWEEN 3 AND 500
     OR char_length(btrim(COALESCE(v_address->>'detail_address', ''))) NOT BETWEEN 0 AND 300)) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_INVALID';
  END IF;

  IF v_type='pickup' THEN
    IF v_address->>'address_source' IS DISTINCT FROM 'pickup'
       OR v_address->>'formatted_address' IS NOT NULL OR v_address->>'detail_address' IS NOT NULL
       OR v_address->>'latitude' IS NOT NULL OR v_address->>'longitude' IS NOT NULL
       OR v_address->>'google_place_id' IS NOT NULL
       OR v_address->>'district' IS NOT NULL OR v_address->>'ward' IS NOT NULL
       OR COALESCE(v_address->>'location_verified','false') <> 'false' THEN
      RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_INVALID';
    END IF;
  ELSIF v_address->>'address_source' = 'manual' THEN
    -- A typed address has no verified location. Never manufacture coordinates
    -- or reuse a stale pin when the customer edits a previously saved address.
    IF v_address->>'latitude' IS NOT NULL
       OR v_address->>'longitude' IS NOT NULL
       OR NULLIF(btrim(COALESCE(v_address->>'google_place_id', '')), '') IS NOT NULL
       OR COALESCE(v_address->>'location_verified', 'false') <> 'false' THEN
      RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_INVALID';
    END IF;
  ELSIF COALESCE(v_address->>'address_source', '') NOT IN ('search', 'map_pin')
     OR COALESCE(v_address->>'location_verified', 'false') <> 'true'
     OR v_address->>'latitude' IS NULL
     OR v_address->>'longitude' IS NULL THEN
    -- Preserve in-flight legacy client compatibility without relaxing its
    -- existing location requirements.
    RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_INVALID';
  END IF;

  v_reference := 'D' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

  INSERT INTO public.direct_order_requests(
    restaurant_id, session_id, client_request_id, reference_code,
    state, locale, customer_note, fulfillment_type
  ) VALUES (
    v_session.restaurant_id,
    v_session.id,
    p_client_request_id,
    v_reference,
    'awaiting_quote',
    COALESCE(NULLIF(p_payload->>'locale', ''), v_session.locale),
    NULLIF(btrim(COALESCE(p_payload->>'customer_note', '')), ''), v_type
  ) RETURNING * INTO v_request;

  UPDATE public.direct_order_requests SET submission_hash=md5(p_payload::text) WHERE id=v_request.id;
  v_prepared:=public.direct_order_prepare_combo_items(v_session.restaurant_id,p_payload->'items');
  v_previous_prepared:=current_setting('pos.direct_prepared_items',true);
  PERFORM set_config('pos.direct_prepared_items',(SELECT jsonb_object_agg(e->>'line_id',e) FROM jsonb_array_elements(v_prepared)e)::text,true);
  INSERT INTO public.direct_order_request_items(id,request_id,restaurant_id,menu_item_id,display_name,name_ko,name_vi,name_en,vat_category,unit_price,quantity,item_note,sort_order,combo_drink_choices,combo_components,vat_profile_snapshot,menu_option_snapshot)
  SELECT (e->>'line_id')::uuid,v_request.id,v_request.restaurant_id,(e->>'menu_item_id')::uuid,e->>'display_name',e->>'name_ko',e->>'name_vi',e->>'name_en',e->>'vat_category',
   (e->>'unit_price')::numeric,(e->>'quantity')::integer,e->>'item_note',(e->>'sort_order')::integer,e->'combo_drink_choices',e->'combo_components',e->'vat_profile_snapshot',e->'menu_option_snapshot'
  FROM jsonb_array_elements(v_prepared)e;
  PERFORM set_config('pos.direct_prepared_items',COALESCE(v_previous_prepared,''),true);
  SELECT sum((e->>'quantity')::integer) INTO v_total_quantity FROM jsonb_array_elements(v_prepared)e;
  IF v_total_quantity > 100 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_QUANTITY_LIMIT';
  END IF;

  INSERT INTO public.direct_order_request_addresses(
    request_id, restaurant_id, customer_name, customer_phone,
    formatted_address, detail_address, latitude, longitude,
    google_place_id, district, ward, address_source, location_verified
  ) VALUES (
    v_request.id,
    v_request.restaurant_id,
    btrim(v_address->>'customer_name'),
    btrim(v_address->>'customer_phone'),
    btrim(v_address->>'formatted_address'),
    btrim(v_address->>'detail_address'),
    (v_address->>'latitude')::numeric,
    (v_address->>'longitude')::numeric,
    NULLIF(btrim(COALESCE(v_address->>'google_place_id', '')), ''),
    NULLIF(btrim(COALESCE(v_address->>'district', '')), ''),
    NULLIF(btrim(COALESCE(v_address->>'ward', '')), ''),
    v_address->>'address_source',
    v_address->>'address_source' IN ('search','map_pin')
  );

  IF v_address->>'address_source' IN ('search','map_pin') THEN
    INSERT INTO public.direct_order_location_facts(
      request_id, restaurant_id, district, ward,
      coarse_latitude, coarse_longitude, requested_at
    ) VALUES (
      v_request.id,
      v_request.restaurant_id,
      NULLIF(btrim(COALESCE(v_address->>'district', '')), ''),
      NULLIF(btrim(COALESCE(v_address->>'ward', '')), ''),
      round((v_address->>'latitude')::numeric, 3),
      round((v_address->>'longitude')::numeric, 3),
      v_request.created_at
    );
  END IF;

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, message_type, body
  ) VALUES (
    v_request.id,
    v_request.restaurant_id,
    'system',
    'system',
    'DIRECT_ORDER_REQUEST_RECEIVED'
  );

  RETURN jsonb_build_object(
    'request_id', v_request.id,
    'reference_code', v_request.reference_code,
    'state', v_request.state,
    'idempotent', false
  );
END;
$_$;

CREATE OR REPLACE FUNCTION "public"."direct_order_approve_payment_before_combo"("p_store_id" "uuid", "p_request_id" "uuid", "p_confirmed_amount" numeric, "p_confirmed_bank_reference" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_catalog'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_reviewed_proof_id uuid;
  v_request public.direct_order_requests%ROWTYPE;
  v_quote public.direct_order_quotes%ROWTYPE;
  v_existing public.direct_order_financials%ROWTYPE;
  v_storefront public.direct_order_storefronts%ROWTYPE;
  v_mode text;
  v_order public.orders%ROWTYPE;
  v_previous_direct_pos text := current_setting('app.direct_order_pos_id',true);
  v_previous_direct_request text := current_setting('app.direct_order_request_id',true);
  v_payment public.payments%ROWTYPE;
  v_ticket public.direct_delivery_fulfillment_tickets%ROWTYPE;
  v_order_total numeric(15,2);
  v_local_time time;
BEGIN
  v_actor := public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  IF p_confirmed_amount IS NULL OR p_confirmed_amount <= 0
     OR char_length(COALESCE(p_confirmed_bank_reference, '')) > 200 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_APPROVAL_INPUT_INVALID';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('direct-order-approval:' || p_request_id::text, 0)
  );

  SELECT * INTO v_existing
  FROM public.direct_order_financials financial
  WHERE financial.request_id = p_request_id
    AND financial.restaurant_id = p_store_id;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'request_id', v_existing.request_id,
      'order_id', v_existing.order_id,
      'payment_id', v_existing.payment_id,
      'ticket_id', (
        SELECT ticket.id
        FROM public.direct_delivery_fulfillment_tickets ticket
        WHERE ticket.request_id = v_existing.request_id
          AND ticket.restaurant_id = p_store_id
      ),
      'final_total', v_existing.final_total,
      'idempotent', true
    );
  END IF;

  SELECT * INTO v_request
  FROM public.direct_order_requests request_row
  WHERE request_row.id = p_request_id
    AND request_row.restaurant_id = p_store_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
  IF v_request.state <> 'awaiting_payment_review' THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_APPROVABLE';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.direct_order_proof_review_requests review
    WHERE review.request_id = p_request_id
      AND review.restaurant_id = p_store_id
      AND review.status = 'requested'
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PROOF_RESUBMISSION_PENDING';
  END IF;

  SELECT * INTO v_storefront
  FROM public.direct_order_storefronts storefront
  WHERE storefront.restaurant_id = p_store_id
    AND storefront.is_enabled = true
  FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_STOREFRONT_DISABLED'; END IF;

  v_local_time := (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::time;
  -- The intake window never blocks review of an already submitted payment.

  SELECT COALESCE(settings.fulfillment_mode, 'pos_print') INTO v_mode
  FROM public.restaurant_settings settings
  WHERE settings.restaurant_id = p_store_id;
  v_mode := COALESCE(v_mode, 'pos_print');
  -- Direct delivery is routed through its isolated fulfillment ticket graph.
  -- Keep its financial order snapshots on pos_print so a paperless dine-in
  -- workflow cannot intercept or duplicate the delivery ticket.

  -- Direct delivery uses its own fulfillment ticket graph, so an active
  -- paperless emergency session cannot intercept or duplicate this ticket.

  IF EXISTS (
    SELECT 1 FROM public.store_promotions promotion
    WHERE promotion.restaurant_id = p_store_id
      AND promotion.is_active = true
      AND now() >= promotion.starts_at
      AND now() < promotion.ends_at
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PROMOTION_ACTIVE';
  END IF;

  SELECT * INTO v_quote
  FROM public.direct_order_quotes quote
  WHERE quote.request_id = v_request.id
    AND quote.restaurant_id = p_store_id
    AND quote.status = 'locked'
  ORDER BY quote.version DESC
  LIMIT 1
  FOR UPDATE;
  -- Uploading payment proof locks the quoted amount. The locked quote remains
  -- approvable after its browsing TTL because amount, proof, and menu integrity
  -- are all revalidated below before the atomic payment is created.
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_EXPIRED';
  END IF;
  IF round(p_confirmed_amount, 2) IS DISTINCT FROM round(v_quote.final_total, 2) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_AMOUNT_MISMATCH';
  END IF;
  SELECT message.id INTO v_reviewed_proof_id
  FROM public.direct_order_messages message
  WHERE message.request_id = v_request.id
    AND message.restaurant_id = p_store_id
    AND message.sender_type = 'customer'
    AND message.message_type = 'payment_proof'
    AND message.attachment_storage_path IS NOT NULL
    AND message.metadata->>'quote_id' = v_quote.id::text
    AND message.metadata->>'quote_version' = v_quote.version::text
  ORDER BY message.created_at DESC, message.id DESC
  LIMIT 1;

  -- Preserve the optional legacy verified-transfer caller. Photo review is
  -- sufficient for authenticated staff and never requires that integration.
  IF v_reviewed_proof_id IS NULL AND NOT EXISTS (
    SELECT 1
    FROM public.direct_order_sepay_candidates payment_link
    JOIN public.sepay_transactions payment_transaction
      ON payment_transaction.id = payment_link.sepay_transaction_id
    WHERE payment_link.request_id = v_request.id
      AND payment_link.restaurant_id = p_store_id
      AND payment_transaction.restaurant_id = p_store_id
      AND payment_transaction.transfer_type = 'in'
      AND payment_transaction.resolution_status = 'matched'
      AND payment_transaction.transfer_amount::numeric = v_quote.final_total
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_PROOF_REQUIRED';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.direct_order_request_items request_item
    LEFT JOIN public.menu_items menu ON menu.id = request_item.menu_item_id
    WHERE request_item.request_id = v_request.id
      AND (
        menu.id IS NULL OR menu.restaurant_id <> p_store_id
        OR menu.is_available = false OR menu.is_visible_public = false
        OR CASE WHEN request_item.menu_option_snapshot->>'choice_schema'='1' THEN
          request_item.menu_option_snapshot->>'catalog_revision' IS DISTINCT FROM md5(menu.menu_option_key)
          OR (request_item.menu_option_snapshot->>'unit_price')::numeric IS DISTINCT FROM request_item.unit_price
        ELSE menu.choice_definition<>'{}'::jsonb OR menu.price IS DISTINCT FROM request_item.unit_price END
      )
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_MENU_CHANGED';
  END IF;

  IF v_quote.delivery_fee_total IS DISTINCT FROM 0::numeric THEN
    RAISE EXCEPTION 'DELIVERY_FEE_DISABLED';
  END IF;

  INSERT INTO public.orders(
    restaurant_id, table_id, sales_channel, status, guest_count,
    created_by, notes, order_source, order_purpose,
    fulfillment_mode_snapshot
  ) VALUES (
    p_store_id, NULL, CASE WHEN v_request.fulfillment_type='pickup' THEN 'takeaway' ELSE 'delivery' END, 'serving', v_request.diner_count,
    (SELECT auth.uid()),
    CASE WHEN v_request.fulfillment_type='pickup' THEN 'Direct pickup ' ELSE 'Direct delivery ' END || v_request.reference_code,
    'staff', 'customer', 'pos_print'
  ) RETURNING * INTO v_order;
  PERFORM set_config('app.direct_order_pos_id',v_order.id::text,true);
  PERFORM set_config('app.direct_order_request_id',v_request.id::text,true);

  PERFORM set_config('pos.direct_vat_request',v_request.id::text,true);
  INSERT INTO public.order_items(
    id, restaurant_id, order_id, menu_item_id, item_type, label,
    display_name, unit_price, quantity, status, notes,
    vat_rate, vat_amount, total_amount_ex_tax, paying_amount_inc_tax,
    is_service_item, fulfillment_mode_snapshot, menu_option_snapshot
  )
  SELECT
    item.id,
    p_store_id,
    v_order.id,
    item.menu_item_id,
    'menu_item',
    item.display_name,
    item.display_name,
    item.unit_price,
    item.quantity,
    'served',
    item.item_note,
    0, 0, 0, 0,
    false,
    'pos_print',item.menu_option_snapshot
  FROM public.direct_order_request_items item
  WHERE item.request_id = v_request.id
  ORDER BY item.sort_order, item.id;

  -- No delivery fee item is created, including a zero-value placeholder.

  INSERT INTO public.direct_delivery_fulfillment_tickets(
    request_id, restaurant_id, pickup_code, updated_by
  ) VALUES (
    v_request.id, p_store_id, v_request.reference_code, (SELECT auth.uid())
  ) RETURNING * INTO v_ticket;

  INSERT INTO public.direct_delivery_fulfillment_ticket_items(
    id, ticket_id, restaurant_id, menu_item_id,
    display_name_ko, display_name_vi, display_name_en,
    quantity, item_note, sort_order
  )
  SELECT
    item.id, v_ticket.id, p_store_id, item.menu_item_id,
    item.name_ko, item.name_vi, item.name_en,
    item.quantity, item.item_note, item.sort_order
  FROM public.direct_order_request_items item
  WHERE item.request_id = v_request.id
  ORDER BY item.sort_order, item.id;

  PERFORM set_config('pos.direct_vat_request','',true);
  -- This is the unchanged, authoritative payment anchor. It also produces
  -- brand service-charge lines, VAT snapshots, inventory deductions, and the
  -- asynchronous MISA queue record. Any mismatch below rolls all of it back.
  v_payment := public.process_payment(
    v_order.id, p_store_id, v_quote.final_total, 'BANKTRANSFER'
  );

  SELECT round(COALESCE(sum(item.paying_amount_inc_tax), 0), 2)
  INTO v_order_total
  FROM public.order_items item
  WHERE item.order_id = v_order.id
    AND item.status <> 'cancelled'
    AND COALESCE(item.is_service_item, false) = false;

  IF v_order_total IS DISTINCT FROM round(v_quote.final_total, 2)
     OR round(v_payment.amount_portion, 2) IS DISTINCT FROM round(v_quote.final_total, 2)
     OR NOT EXISTS (
       SELECT 1 FROM public.orders completed_order
       WHERE completed_order.id = v_order.id
         AND completed_order.status = 'completed'
     ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_FINANCIAL_RECONCILIATION_FAILED';
  END IF;

  INSERT INTO public.direct_order_financials(
    request_id, restaurant_id, quote_id, order_id, payment_id,
    delivery_fee_item_id, menu_total, service_charge_total,
    delivery_fee_total, final_total, confirmed_bank_reference, delivery_payment_mode,
    approved_by
  ) VALUES (
    v_request.id, p_store_id, v_quote.id, v_order.id, v_payment.id,
    NULL::uuid, v_quote.menu_total, v_quote.service_charge_total,
    v_quote.delivery_fee_total, v_quote.final_total,
    NULLIF(btrim(COALESCE(p_confirmed_bank_reference, '')), ''), v_quote.delivery_payment_mode,
    (SELECT auth.uid())
  );

  UPDATE public.direct_order_requests
  SET state = 'approved', approved_at = now(), updated_at = now()
  WHERE id = v_request.id;

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, message_type, body,
    metadata
  ) VALUES (
    v_request.id, p_store_id, 'system', 'system',
    'DIRECT_ORDER_PAYMENT_APPROVED',
    jsonb_build_object('order_id', v_order.id, 'ticket_id', v_ticket.id)
  );

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    (SELECT auth.uid()),
    'direct_order_payment_approved',
    'direct_order_requests',
    v_request.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'quote_id', v_quote.id,
      'order_id', v_order.id,
      'payment_id', v_payment.id,
      'ticket_id', v_ticket.id,
      'final_total', v_quote.final_total,
      'review_method', CASE WHEN v_reviewed_proof_id IS NOT NULL
        THEN 'customer_photo' ELSE 'sepay' END,
      'proof_message_id', v_reviewed_proof_id
    )
  );

  PERFORM set_config('app.direct_order_pos_id',COALESCE(v_previous_direct_pos,''),true);
  PERFORM set_config('app.direct_order_request_id',COALESCE(v_previous_direct_request,''),true);
  RETURN jsonb_build_object(
    'request_id', v_request.id,
    'order_id', v_order.id,
    'payment_id', v_payment.id,
    'ticket_id', v_ticket.id,
    'final_total', v_quote.final_total,
    'idempotent', false
  );
END;
$$;

CREATE OR REPLACE FUNCTION "public"."capture_menu_option_batch"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
 IF current_setting('globos.cashier_item_mutation',true) IS DISTINCT FROM 'on' AND EXISTS(
  SELECT 1 FROM new_menu_lines n JOIN public.menu_items m ON m.id=n.menu_item_id
  WHERE m.choice_definition<>'{}'::jsonb AND (n.menu_option_snapshot->>'choice_schema' IS DISTINCT FROM '1'
   OR (n.menu_option_snapshot->>'unit_price')::numeric IS DISTINCT FROM n.unit_price)
 ) THEN RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID'; END IF;
 IF TG_TABLE_NAME='order_items' THEN
  -- Cashier splits copy the original immutable row; never reprice or replace it.
  IF current_setting('globos.cashier_item_mutation',true)='on' THEN RETURN NULL; END IF;
  IF EXISTS(SELECT 1 FROM new_menu_lines n JOIN public.menu_items m ON m.id=n.menu_item_id
    WHERE n.menu_option_snapshot='{}'::jsonb AND (m.meal_choice<>'' OR m.portion_code<>'' OR m.spice_level<>'unknown' OR m.spice_choice<>'')
     AND (n.restaurant_id<>m.restaurant_id OR NOT m.is_available OR m.is_archived
      OR (NOT n.is_service_item AND n.unit_price<>m.price))) THEN RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID'; END IF;
  UPDATE public.order_items o SET menu_option_snapshot=jsonb_build_object(
    'menu_item_id',m.id,'meal_choice',m.meal_choice,'portion_code',m.portion_code,'spice_level',m.spice_level,'spice_choice',m.spice_choice,
    'unit_price',n.unit_price,'name_ko',m.name_ko,'name_vi',m.name_vi,'name_en',m.name_en),
    label=m.name,display_name=m.name
  FROM new_menu_lines n JOIN public.menu_items m ON m.id=n.menu_item_id
  WHERE o.id=n.id AND n.menu_option_snapshot='{}'::jsonb AND (m.meal_choice<>'' OR m.portion_code<>'' OR m.spice_level<>'unknown' OR m.spice_choice<>'');
  IF nullif(current_setting('app.direct_order_request_id',true),'') IS NOT NULL THEN
   UPDATE public.order_items o SET menu_option_snapshot=r.menu_option_snapshot,
    label=r.display_name,display_name=r.display_name
   FROM new_menu_lines n JOIN public.direct_order_request_items r
    ON r.request_id=nullif(current_setting('app.direct_order_request_id',true),'')::uuid
    AND r.id=n.id AND r.restaurant_id=n.restaurant_id
   WHERE o.id=n.id AND r.menu_option_snapshot<>'{}'::jsonb;
  END IF;
 ELSE
  UPDATE public.direct_order_request_items o SET menu_option_snapshot=jsonb_build_object(
    'menu_item_id',m.id,'meal_choice',m.meal_choice,'portion_code',m.portion_code,'spice_level',m.spice_level,'spice_choice',m.spice_choice,
    'unit_price',n.unit_price,'name_ko',n.name_ko,'name_vi',n.name_vi,'name_en',n.name_en)
  FROM new_menu_lines n JOIN public.menu_items m ON m.id=n.menu_item_id AND m.restaurant_id=n.restaurant_id
  WHERE o.id=n.id AND n.menu_option_snapshot='{}'::jsonb AND (m.meal_choice<>'' OR m.portion_code<>'' OR m.spice_level<>'unknown' OR m.spice_choice<>'');
 END IF;

 -- Component choices are keyed by their stable sellable ID in the order-time
 -- snapshot. One aggregate JOIN covers the complete inserted batch.
 IF TG_TABLE_NAME='order_items' AND nullif(current_setting('app.direct_order_request_id',true),'') IS NULL THEN
  WITH parts AS (
   SELECT n.id,jsonb_object_agg(m.id::text,jsonb_build_object('menu_item_id',m.id,
    'meal_choice',m.meal_choice,'portion_code',m.portion_code,'spice_level',m.spice_level,'spice_choice',m.spice_choice,
    'name_ko',coalesce(c->>'name_ko',m.name_ko),'name_vi',coalesce(c->>'name_vi',m.name_vi),
    'name_en',coalesce(c->>'name_en',m.name_en),'unit_price',coalesce(c->'tax_unit_price',to_jsonb(m.price)))) data
   FROM new_menu_lines n CROSS JOIN LATERAL jsonb_array_elements(coalesce(n.combo_components,'[]'))c
   JOIN public.menu_items m ON m.id=(c->>'menu_item_id')::uuid AND m.restaurant_id=n.restaurant_id
   WHERE m.menu_option_key IS NOT NULL GROUP BY n.id
  ) UPDATE public.order_items o SET menu_option_snapshot=
   CASE WHEN o.menu_option_snapshot='{}'::jsonb THEN jsonb_build_object('menu_item_id',m.id,
    'meal_choice',m.meal_choice,'portion_code',m.portion_code,'spice_level',m.spice_level,'spice_choice',m.spice_choice,
    'name_ko',m.name_ko,'name_vi',m.name_vi,'name_en',m.name_en,'unit_price',o.unit_price)
    ELSE o.menu_option_snapshot END || jsonb_build_object('components',p.data)
   FROM parts p,new_menu_lines n,public.menu_items m WHERE o.id=p.id AND n.id=o.id AND m.id=n.menu_item_id;
 ELSIF TG_TABLE_NAME='direct_order_request_items' THEN
  WITH parts AS (
   SELECT n.id,jsonb_object_agg(m.id::text,jsonb_build_object('menu_item_id',m.id,
    'meal_choice',m.meal_choice,'portion_code',m.portion_code,'spice_level',m.spice_level,'spice_choice',m.spice_choice,
    'name_ko',coalesce(c->>'name_ko',m.name_ko),'name_vi',coalesce(c->>'name_vi',m.name_vi),
    'name_en',coalesce(c->>'name_en',m.name_en),'unit_price',coalesce(c->'tax_unit_price',to_jsonb(m.price)))) data
   FROM new_menu_lines n CROSS JOIN LATERAL jsonb_array_elements(coalesce(n.combo_components,'[]'))c
   JOIN public.menu_items m ON m.id=(c->>'menu_item_id')::uuid AND m.restaurant_id=n.restaurant_id
   WHERE m.menu_option_key IS NOT NULL GROUP BY n.id
  ) UPDATE public.direct_order_request_items o SET menu_option_snapshot=
   CASE WHEN o.menu_option_snapshot='{}'::jsonb THEN jsonb_build_object('menu_item_id',m.id,
    'meal_choice',m.meal_choice,'portion_code',m.portion_code,'spice_level',m.spice_level,'spice_choice',m.spice_choice,
    'name_ko',m.name_ko,'name_vi',m.name_vi,'name_en',m.name_en,'unit_price',o.unit_price)
    ELSE o.menu_option_snapshot END || jsonb_build_object('components',p.data)
   FROM parts p,new_menu_lines n,public.menu_items m WHERE o.id=p.id AND n.id=o.id AND m.id=n.menu_item_id;
 END IF;
 -- Freeze the registered recipe basis for configured choices in one aggregate
 -- per inserted batch. A later menu recipe edit cannot reprice stock history.
 EXECUTE format($basis$
  WITH lines AS MATERIALIZED(SELECT * FROM new_menu_lines WHERE menu_option_snapshot->>'choice_schema'='1' AND NOT menu_option_snapshot ? 'recipe_basis'),
  base AS(SELECT n.id,jsonb_agg(jsonb_build_object('ingredient_id',r.ingredient_id,'quantity_g',r.quantity_g*n.quantity) ORDER BY r.ingredient_id) items
   FROM lines n JOIN public.menu_recipes r ON r.menu_item_id=n.menu_item_id AND r.restaurant_id=n.restaurant_id GROUP BY n.id),
  combo_totals AS(SELECT n.id,r.ingredient_id,sum(r.quantity_g*(c->>'quantity')::numeric*CASE WHEN coalesce((c->>'is_total_quantity')::boolean,false) THEN 1 ELSE n.quantity END) quantity_g
   FROM lines n CROSS JOIN LATERAL jsonb_array_elements(coalesce(n.combo_components,'[]'))c JOIN public.menu_recipes r ON r.menu_item_id=(c->>'menu_item_id')::uuid AND r.restaurant_id=n.restaurant_id GROUP BY n.id,r.ingredient_id),
  combo AS(SELECT id,jsonb_agg(jsonb_build_object('ingredient_id',ingredient_id,'quantity_g',quantity_g) ORDER BY ingredient_id) items FROM combo_totals GROUP BY id),
  snapshots AS(SELECT n.id,jsonb_build_object('recipe_basis',jsonb_build_object('quantity',n.quantity,'items',coalesce(b.items,'[]')),'combo_recipe_basis',jsonb_build_object('quantity',n.quantity,'items',coalesce(c.items,'[]'))) data
   FROM lines n LEFT JOIN base b ON b.id=n.id LEFT JOIN combo c ON c.id=n.id)
  UPDATE public.%I o SET menu_option_snapshot=o.menu_option_snapshot||s.data||jsonb_build_object('choice_signature',md5((o.menu_option_snapshot->>'choice_signature')||s.data::text)) FROM snapshots s WHERE o.id=s.id
 $basis$,TG_TABLE_NAME);
 RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION "public"."snapshot_order_item_takeout"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_payload_text text;
  v_payload jsonb;
  v_selected jsonb;
  v_selected_ordinal bigint;
  v_remaining jsonb;
BEGIN
  v_payload_text := current_setting('pos.order_takeout_payload', true);
  IF NULLIF(v_payload_text, '') IS NULL THEN
    RETURN NEW;
  END IF;

  v_payload := v_payload_text::jsonb;
  SELECT line.raw, line.ord
  INTO v_selected, v_selected_ordinal
  FROM jsonb_array_elements(v_payload)
    WITH ORDINALITY AS line(raw, ord)
  WHERE line.raw->>'menu_item_id' = NEW.menu_item_id::text
    AND (NOT (NEW.menu_option_snapshot ? 'selection_key') OR line.raw->>'menu_option_key'=NEW.menu_option_snapshot->>'selection_key')
    AND COALESCE((line.raw->>'quantity')::integer, 0) = NEW.quantity
  ORDER BY line.ord
  LIMIT 1;

  IF v_selected IS NULL THEN
    SELECT line.raw, line.ord
    INTO v_selected, v_selected_ordinal
    FROM jsonb_array_elements(v_payload)
      WITH ORDINALITY AS line(raw, ord)
    WHERE line.raw->>'menu_item_id' = NEW.menu_item_id::text
    AND (NOT (NEW.menu_option_snapshot ? 'selection_key') OR line.raw->>'menu_option_key'=NEW.menu_option_snapshot->>'selection_key')
    ORDER BY line.ord
    LIMIT 1;
  END IF;

  IF v_selected IS NOT NULL THEN
    NEW.is_takeout := COALESCE((v_selected->>'is_takeout')::boolean, false);
    SELECT COALESCE(jsonb_agg(line.raw ORDER BY line.ord), '[]'::jsonb)
    INTO v_remaining
    FROM jsonb_array_elements(v_payload)
      WITH ORDINALITY AS line(raw, ord)
    WHERE line.ord <> v_selected_ordinal;
    PERFORM set_config('pos.order_takeout_payload', v_remaining::text, true);
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."snapshot_order_item_combo_components"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_payload_text text;
  v_selected jsonb := '[]'::jsonb;
  v_fixed jsonb := '[]'::jsonb;
  v_drinks jsonb := '[]'::jsonb;
  v_direct_enabled boolean := false;
BEGIN
 IF TG_OP='INSERT' AND NULLIF(current_setting('pos.direct_line_snapshots',true),'') IS NOT NULL
  AND current_setting('pos.direct_line_snapshots',true)::jsonb ? NEW.id::text THEN
  NEW.combo_components:=current_setting('pos.direct_line_snapshots',true)::jsonb->NEW.id::text->'combo_components';
  RETURN NEW;
 END IF;
 IF current_setting('globos.cashier_item_mutation',true)='on' THEN RETURN NEW; END IF;
  IF NEW.menu_item_id IS NULL THEN
    NEW.combo_components := '[]'::jsonb;
    RETURN NEW;
  END IF;

  SELECT COALESCE(settings.floor_direct_beverages_enabled, false)
  INTO v_direct_enabled
  FROM public.restaurant_settings settings
  WHERE settings.restaurant_id = NEW.restaurant_id;

  IF EXISTS (
    SELECT 1 FROM public.orders order_row
    WHERE order_row.id = NEW.order_id
      AND order_row.sales_channel = 'delivery'
  ) THEN
    v_direct_enabled := false;
  END IF;

  v_payload_text := current_setting('pos.qr_combo_payload', true);
  IF NULLIF(v_payload_text, '') IS NOT NULL THEN
    SELECT COALESCE(line.raw->'combo_drink_choices', '[]'::jsonb)
    INTO v_selected
    FROM jsonb_array_elements(v_payload_text::jsonb) line(raw)
    WHERE line.raw->>'menu_item_id' = NEW.menu_item_id::text
      AND (NOT (NEW.menu_option_snapshot ? 'selection_key') OR line.raw->>'menu_option_key'=NEW.menu_option_snapshot->>'selection_key')
      AND COALESCE((line.raw->>'is_takeout')::boolean, false) = NEW.is_takeout
    LIMIT 1;
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'menu_item_id', component_item.id::text,
      'label', component_item.name,
      'name_ko', COALESCE(NULLIF(component_item.name_ko, ''), component_item.name),
      'name_vi', COALESCE(NULLIF(component_item.name_vi, ''), component_item.name),
      'name_en', COALESCE(NULLIF(component_item.name_en, ''), component_item.name),
      'quantity', component.quantity,
      'fulfillment_route', CASE
        WHEN NEW.fulfillment_mode_snapshot = 'paperless'
          AND v_direct_enabled
          THEN component_item.fulfillment_route
        ELSE 'kitchen_tray_floor'
      END
    ) ORDER BY component.sort_order, component.created_at, component.id
  ), '[]'::jsonb)
  INTO v_fixed
  FROM public.menu_combo_components component
  JOIN public.menu_items component_item
    ON component_item.id = component.component_menu_item_id
   AND component_item.restaurant_id = component.restaurant_id
  WHERE component.combo_menu_item_id = NEW.menu_item_id
    AND component.restaurant_id = NEW.restaurant_id
    AND (
      jsonb_array_length(v_selected) = 0
      OR lower(btrim(COALESCE(NULLIF(component_item.name_ko, ''), component_item.name)))
        NOT IN ('음료', 'drink', 'beverage', 'đồ uống', 'nước uống')
    );

  IF jsonb_array_length(v_selected) > 0 THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'menu_item_id', selected_item.id::text,
      'label', selected_item.name,
      'name_ko', COALESCE(NULLIF(selected_item.name_ko, ''), selected_item.name),
      'name_vi', COALESCE(NULLIF(selected_item.name_vi, ''), selected_item.name),
      'name_en', COALESCE(NULLIF(selected_item.name_en, ''), selected_item.name),
      'quantity', selected.quantity,
      'is_total_quantity', true,
      'fulfillment_route', CASE
        WHEN NEW.fulfillment_mode_snapshot = 'paperless'
          AND v_direct_enabled
          THEN selected_item.fulfillment_route
        ELSE 'kitchen_tray_floor'
      END
    ) ORDER BY selected.first_ordinal), '[]'::jsonb)
    INTO v_drinks
    FROM (
      SELECT choice.value::uuid AS item_id,
             count(*)::integer AS quantity,
             min(choice.ordinality) AS first_ordinal
      FROM jsonb_array_elements_text(v_selected)
        WITH ORDINALITY choice(value, ordinality)
      GROUP BY choice.value
    ) selected
    JOIN public.menu_items selected_item
      ON selected_item.id = selected.item_id
     AND selected_item.restaurant_id = NEW.restaurant_id;
  END IF;

  NEW.combo_components := v_fixed || v_drinks;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."direct_order_enrich_translations"("p_base" "jsonb", "p_request_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $_$
 WITH notes AS (
 SELECT source_kind,source_id,source_text,jsonb_object_agg(target_locale,translated_text) FILTER(WHERE status='translated') translations,
 CASE WHEN bool_and(status='translated') THEN 'translated' WHEN bool_or(status='failed') THEN 'failed' ELSE 'pending' END status
 FROM public.direct_order_translation_jobs WHERE request_id=$2 GROUP BY source_kind,source_id,source_text
 ), messages AS (
 SELECT COALESCE(jsonb_agg(e.value||jsonb_build_object('metadata',m.metadata||jsonb_build_object('translation_status',COALESCE(n.status,'original'))) ORDER BY e.ordinality),'[]'::jsonb) value
 FROM jsonb_array_elements(COALESCE($1->'messages','[]'::jsonb)) WITH ORDINALITY e LEFT JOIN public.direct_order_messages m ON m.id=(e.value->>'id')::uuid
 LEFT JOIN notes n ON n.source_kind='message' AND n.source_id=m.id AND n.source_text=m.body
 ), items AS (
 SELECT COALESCE(jsonb_agg(e.value||jsonb_build_object('note_translations',COALESCE(n.translations,'{}'::jsonb),'translation_status',COALESCE(n.status,'original')) ORDER BY e.ordinality),'[]'::jsonb) value
 FROM jsonb_array_elements(COALESCE($1->'items','[]'::jsonb)) WITH ORDINALITY e
 LEFT JOIN (SELECT i.*,row_number() OVER(ORDER BY sort_order,id) ord FROM public.direct_order_request_items i WHERE request_id=$2)i ON i.ord=e.ordinality
 LEFT JOIN notes n ON n.source_kind='item_note' AND n.source_id=i.id AND n.source_text=i.item_note
 ), quotes AS (
 SELECT COALESCE(jsonb_agg(e.value||jsonb_build_object('note_translations',COALESCE(n.translations,'{}'::jsonb),'translation_status',COALESCE(n.status,'original')) ORDER BY e.ordinality),'[]'::jsonb) value
 FROM jsonb_array_elements(COALESCE($1->'quotes','[]'::jsonb)) WITH ORDINALITY e LEFT JOIN notes n ON n.source_kind='cashier_note' AND n.source_id::text=e.value->>'id' AND n.source_text=e.value->>'cashier_note'
 )
 SELECT $1||jsonb_build_object('messages',messages.value,'items',items.value)||CASE WHEN $1?'quotes' THEN jsonb_build_object('quotes',quotes.value) ELSE '{}'::jsonb END
 ||CASE WHEN jsonb_typeof($1->'quote')='object' THEN jsonb_build_object('quote',($1->'quote')||(SELECT jsonb_build_object('cashier_note',q.cashier_note,'note_translations',COALESCE(n.translations,'{}'::jsonb),'translation_status',COALESCE(n.status,'original')) FROM public.direct_order_quotes q LEFT JOIN notes n ON n.source_kind='cashier_note' AND n.source_id=q.id AND n.source_text=q.cashier_note WHERE q.id::text=$1->'quote'->>'id')) ELSE '{}'::jsonb END
 ||CASE WHEN $1?'request' THEN jsonb_build_object('request',($1->'request')||jsonb_build_object('note_translations',COALESCE((SELECT translations FROM notes WHERE source_kind='customer_note' AND source_text=$1->'request'->>'customer_note'),'{}'::jsonb),'translation_status',COALESCE((SELECT status FROM notes WHERE source_kind='customer_note' AND source_text=$1->'request'->>'customer_note'),'original'))) ELSE '{}'::jsonb END
 FROM messages CROSS JOIN items CROSS JOIN quotes;
$_$;

CREATE OR REPLACE FUNCTION "public"."direct_order_public_status_v11"("p_session_id" "uuid", "p_secret_hash" "text", "p_request_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $_$
DECLARE payload jsonb; items jsonb;
BEGIN
 payload:=public.direct_order_public_status_v10($1,$2,$3);
 SELECT COALESCE(jsonb_agg(e.raw||CASE WHEN jsonb_array_length(i.combo_components)>0 THEN jsonb_build_object('combo_components',i.combo_components) ELSE '{}'::jsonb END ORDER BY e.ord),'[]')
 INTO items FROM jsonb_array_elements(payload->'items') WITH ORDINALITY e(raw,ord)
 LEFT JOIN (SELECT i.*,row_number() OVER(ORDER BY sort_order,id) ord FROM public.direct_order_request_items i WHERE request_id=$3)i ON i.ord=e.ord;
 RETURN jsonb_set(payload,'{items}',items);
END $_$;

CREATE OR REPLACE FUNCTION "public"."direct_order_staff_detail_v8"("p_store_id" "uuid", "p_request_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_catalog'
    AS $_$
DECLARE payload jsonb; items jsonb;
BEGIN
 payload:=public.direct_order_staff_detail_v7($1,$2);
 SELECT COALESCE(jsonb_agg(e.raw||CASE WHEN jsonb_array_length(i.combo_components)>0 THEN jsonb_build_object('combo_components',i.combo_components) ELSE '{}'::jsonb END ORDER BY e.ord),'[]')
 INTO items FROM jsonb_array_elements(payload->'items') WITH ORDINALITY e(raw,ord)
 LEFT JOIN public.direct_order_request_items i ON i.request_id=$2 AND i.restaurant_id=$1 AND i.id::text=e.raw->>'id';
 RETURN jsonb_set(payload,'{items}',items);
END $_$;

CREATE OR REPLACE FUNCTION "public"."direct_order_quote_preview_core"("p_store_id" "uuid", "p_request_id" "uuid", "p_validate_menu" boolean DEFAULT true) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE v_combo boolean; mode text; enabled boolean; rate numeric; minimum numeric; result jsonb; n integer;
BEGIN
 SELECT COALESCE(s.vat_pricing_mode,'exclusive'),COALESCE(b.service_charge_enabled,false),COALESCE(b.service_charge_rate,0),sf.minimum_order_amount
 INTO mode,enabled,rate,minimum FROM public.restaurants s LEFT JOIN public.brands b ON b.id=s.brand_id
 JOIN public.direct_order_storefronts sf ON sf.restaurant_id=s.id WHERE s.id=p_store_id AND sf.is_enabled
 AND sf.accounting_approved_at IS NOT NULL AND sf.accounting_approved_by IS NOT NULL;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_ACCOUNTING_APPROVAL_REQUIRED'; END IF;
 SELECT count(*) INTO n FROM public.direct_order_request_items WHERE request_id=p_request_id AND restaurant_id=p_store_id;
 IF n NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_INPUT_INVALID'; END IF;
 IF p_validate_menu AND EXISTS(SELECT 1 FROM public.direct_order_request_items i LEFT JOIN public.menu_items m ON m.id=i.menu_item_id
 WHERE i.request_id=p_request_id AND (m.id IS NULL OR m.restaurant_id<>p_store_id OR NOT m.is_available OR NOT m.is_visible_public OR CASE WHEN i.menu_option_snapshot->>'choice_schema'='1' THEN i.menu_option_snapshot->>'catalog_revision' IS DISTINCT FROM md5(m.menu_option_key) OR (i.menu_option_snapshot->>'unit_price')::numeric IS DISTINCT FROM i.unit_price ELSE m.choice_definition<>'{}'::jsonb OR m.price IS DISTINCT FROM i.unit_price END))
 THEN RAISE EXCEPTION 'DIRECT_ORDER_MENU_CHANGED'; END IF;
 IF p_validate_menu THEN PERFORM public.direct_order_validate_combo_request(p_store_id,p_request_id); END IF;
 SELECT EXISTS(SELECT 1 FROM public.direct_order_request_items WHERE request_id=p_request_id AND restaurant_id=p_store_id AND jsonb_array_length(combo_components)>0) INTO v_combo;
 WITH priced AS MATERIALIZED(
  SELECT i.*,CASE WHEN v_combo THEN public.direct_order_combo_vnd_vat(COALESCE(NULLIF(to_jsonb(i)->'vat_profile_snapshot','null'::jsonb),
   jsonb_build_array(jsonb_build_object('rate',CASE WHEN i.vat_category='alcohol' THEN 10 ELSE 8 END,'weight',1))),round(i.unit_price*i.quantity,2),mode) ELSE public.calculate_item_vat(COALESCE(NULLIF(to_jsonb(i)->'vat_profile_snapshot','null'::jsonb),jsonb_build_array(jsonb_build_object('rate',CASE WHEN i.vat_category='alcohol' THEN 10 ELSE 8 END,'weight',1))),round(i.unit_price*i.quantity,2),mode) END tax
  FROM public.direct_order_request_items i WHERE i.request_id=p_request_id AND i.restaurant_id=p_store_id
 ), totals AS(SELECT sum((tax->>'supply')::numeric) supply,sum((tax->>'vat')::numeric) vat,sum((tax->>'total')::numeric) total FROM priced),
 parts AS(SELECT (e->>'vat_rate')::numeric vat_rate,sum((e->>'total_amount_ex_tax')::numeric) supply FROM priced CROSS JOIN LATERAL jsonb_array_elements(tax->'parts') e GROUP BY 1),
 service AS(SELECT COALESCE(sum(round(supply*rate/100,CASE WHEN v_combo THEN 0 ELSE 2 END)),0) supply,COALESCE(sum(round(round(supply*rate/100,CASE WHEN v_combo THEN 0 ELSE 2 END)*vat_rate/100,CASE WHEN v_combo THEN 0 ELSE 2 END)),0) vat FROM parts WHERE enabled AND rate>0 AND vat_rate IN(8,10))
 SELECT jsonb_build_object('menu_pretax',t.supply,'menu_vat',t.vat,'menu_total',t.total,
  'service_charge_pretax',s.supply,'service_charge_vat',s.vat,'service_charge_total',s.supply+s.vat,
  'delivery_fee_total',0,'delivery_fee_pretax',0,'delivery_fee_vat',0,'final_total',t.total+s.supply+s.vat,
  'vat_pricing_mode',mode) INTO result FROM totals t CROSS JOIN service s;
 IF (result->>'menu_total')::numeric<minimum THEN RAISE EXCEPTION 'DIRECT_ORDER_BELOW_MINIMUM'; END IF;
 RETURN result;
END $$;


CREATE OR REPLACE FUNCTION "public"."direct_order_staff_quote_before_final_amount"("p_store_id" "uuid", "p_request_id" "uuid", "p_delivery_fee_total" numeric, "p_cashier_note" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_catalog'
    AS $$
DECLARE
  v_tax jsonb;
  v_request public.direct_order_requests%ROWTYPE;
  v_storefront public.direct_order_storefronts%ROWTYPE;
  v_brand public.brands%ROWTYPE;
  v_vat_pricing_mode text;
  v_line record;
  v_line_gross numeric(15,2);
  v_line_pretax numeric(15,2);
  v_line_vat numeric(15,2);
  v_line_total numeric(15,2);
  v_vat_rate numeric(5,2);
  v_food_pretax numeric(15,2) := 0;
  v_alcohol_pretax numeric(15,2) := 0;
  v_menu_pretax numeric(15,2) := 0;
  v_menu_vat numeric(15,2) := 0;
  v_menu_total numeric(15,2) := 0;
  v_sc_pretax numeric(15,2) := 0;
  v_sc_vat numeric(15,2) := 0;
  v_sc_total numeric(15,2) := 0;
  v_fee_pretax numeric(15,2);
  v_fee_vat numeric(15,2);
  v_final_total numeric(15,2);
  v_version integer;
  v_quote public.direct_order_quotes%ROWTYPE;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  IF p_delivery_fee_total IS NULL OR p_delivery_fee_total < 0
     OR char_length(COALESCE(p_cashier_note, '')) > 500 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_INPUT_INVALID';
  END IF;

  SELECT * INTO v_request
  FROM public.direct_order_requests request_row
  WHERE request_row.id = p_request_id
    AND request_row.restaurant_id = p_store_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
  IF v_request.state NOT IN ('awaiting_quote', 'quoted') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_QUOTABLE';
  END IF;

  IF v_request.fulfillment_type='pickup' AND p_delivery_fee_total <> 0 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_FEE_INVALID';
  END IF;

  IF v_request.fulfillment_method = 'pickup' AND p_delivery_fee_total <> 0 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_FEE_INVALID';
  END IF;
  IF v_request.fulfillment_method = 'pickup' AND v_request.state = 'quoted' AND EXISTS (SELECT 1 FROM public.direct_order_quotes WHERE request_id=p_request_id AND status IN ('active','locked') AND delivery_fee_total>0) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_PROOF_REQUIRED';
  END IF;

  SELECT * INTO v_storefront
  FROM public.direct_order_storefronts storefront
  WHERE storefront.restaurant_id = p_store_id
    AND storefront.is_enabled = true
  FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_STOREFRONT_DISABLED'; END IF;
  IF v_storefront.accounting_approved_at IS NULL
     OR v_storefront.accounting_approved_by IS NULL THEN
    RAISE EXCEPTION 'DIRECT_ORDER_ACCOUNTING_APPROVAL_REQUIRED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.direct_order_request_items request_item
    LEFT JOIN public.menu_items menu ON menu.id = request_item.menu_item_id
    WHERE request_item.request_id = v_request.id
      AND (
        menu.id IS NULL
        OR menu.restaurant_id <> p_store_id
        OR menu.is_available = false
        OR menu.is_visible_public = false
        OR CASE WHEN request_item.menu_option_snapshot->>'choice_schema'='1' THEN request_item.menu_option_snapshot->>'catalog_revision' IS DISTINCT FROM md5(menu.menu_option_key) OR (request_item.menu_option_snapshot->>'unit_price')::numeric IS DISTINCT FROM request_item.unit_price ELSE menu.choice_definition<>'{}'::jsonb OR menu.price IS DISTINCT FROM request_item.unit_price END
      )
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_MENU_CHANGED';
  END IF;

  v_tax:=public.direct_order_quote_preview_core(p_store_id,v_request.id);
  v_menu_pretax:=(v_tax->>'menu_pretax')::numeric;
  v_menu_vat:=(v_tax->>'menu_vat')::numeric;
  v_menu_total:=(v_tax->>'menu_total')::numeric;
  v_sc_pretax:=(v_tax->>'service_charge_pretax')::numeric;
  v_sc_vat:=(v_tax->>'service_charge_vat')::numeric;
  v_sc_total:=(v_tax->>'service_charge_total')::numeric;
  IF v_storefront.delivery_fee_vat_rate = 0 THEN
    v_fee_pretax := round(p_delivery_fee_total, 2);
    v_fee_vat := 0;
  ELSE
    v_fee_pretax := round(
      p_delivery_fee_total / (1 + v_storefront.delivery_fee_vat_rate / 100),
      2
    );
    v_fee_vat := round(p_delivery_fee_total, 2) - v_fee_pretax;
  END IF;

  v_menu_pretax := round(v_menu_pretax, 2);
  v_menu_vat := round(v_menu_vat, 2);
  v_menu_total := round(v_menu_total, 2);
  v_sc_pretax := round(v_sc_pretax, 2);
  v_sc_vat := round(v_sc_vat, 2);
  v_sc_total := round(v_sc_total, 2);
  v_final_total := round(v_menu_total + v_sc_total + p_delivery_fee_total, 2);

  IF v_menu_total < v_storefront.minimum_order_amount THEN
    RAISE EXCEPTION 'DIRECT_ORDER_BELOW_MINIMUM';
  END IF;

  UPDATE public.direct_order_quotes
  SET status = 'superseded'
  WHERE request_id = v_request.id
    AND status = 'active';

  SELECT COALESCE(max(version), 0) + 1 INTO v_version
  FROM public.direct_order_quotes
  WHERE request_id = v_request.id;

  INSERT INTO public.direct_order_quotes(
    request_id, restaurant_id, version,
    menu_pretax, menu_vat, menu_total,
    service_charge_pretax, service_charge_vat, service_charge_total,
    delivery_fee_pretax, delivery_fee_vat, delivery_fee_total,
    final_total, delivery_fee_vat_rate, status, cashier_note,
    created_by, expires_at, delivery_payment_mode
  ) VALUES (
    v_request.id, p_store_id, v_version,
    v_menu_pretax, v_menu_vat, v_menu_total,
    v_sc_pretax, v_sc_vat, v_sc_total,
    v_fee_pretax, v_fee_vat, round(p_delivery_fee_total, 2),
    v_final_total, v_storefront.delivery_fee_vat_rate, 'active',
    NULLIF(btrim(COALESCE(p_cashier_note, '')), ''),
    (SELECT auth.uid()),
    now() + make_interval(mins => v_storefront.quote_ttl_minutes), CASE WHEN to_jsonb(v_request)->>'fulfillment_type'='pickup' THEN 'not_applicable' WHEN to_jsonb(v_request)->>'fulfillment_type' IS NULL AND v_request.fulfillment_method='pickup' THEN 'customer_direct' WHEN v_request.delivery_policy_version=2 THEN 'customer_direct' ELSE 'store_prepaid' END
  ) RETURNING * INTO v_quote;

  UPDATE public.direct_order_requests
  SET state = 'quoted', updated_at = now()
  WHERE id = v_request.id;

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, sender_auth_id,
    message_type, body, metadata
  ) VALUES (
    v_request.id,
    p_store_id,
    'cashier',
    (SELECT auth.uid()),
    'quote',
    'DIRECT_ORDER_QUOTE_SENT',
    jsonb_build_object(
      'quote_id', v_quote.id,
      'version', v_quote.version,
      'delivery_fee_total', v_quote.delivery_fee_total,
      'final_total', v_quote.final_total,
      'expires_at', v_quote.expires_at
    )
  );

  RETURN to_jsonb(v_quote) - ARRAY['restaurant_id', 'created_by'];
END;
$$;


CREATE OR REPLACE FUNCTION "public"."qr_place_order_before_daily_reset"("p_token" "text", "p_items" "jsonb", "p_client_order_id" "uuid", "p_validate_combo_choices" boolean, "p_expected_order_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_catalog'
    AS $$
DECLARE
  v_token text := NULLIF(btrim(COALESCE(p_token, '')), '');
  v_table record;
  v_existing public.qr_order_batches%ROWTYPE;
  v_current_order_id uuid;
BEGIN
  SELECT qr.restaurant_id, qr.table_id
  INTO v_table
  FROM public.table_qr_tokens qr
  JOIN public.tables table_row
    ON table_row.id = qr.table_id
   AND table_row.restaurant_id = qr.restaurant_id
  JOIN public.restaurants restaurant
    ON restaurant.id = qr.restaurant_id
   AND restaurant.is_active = true
  WHERE qr.token = v_token
    AND qr.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QR_TOKEN_INVALID';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.qr_order_batches batch
  WHERE batch.client_order_id = p_client_order_id
    AND batch.restaurant_id = v_table.restaurant_id
    AND batch.table_id = v_table.table_id;

  IF FOUND THEN
    IF v_existing.submission_hash IS NOT NULL AND v_existing.submission_hash IS DISTINCT FROM md5(p_items::text) THEN RAISE EXCEPTION 'QR_ITEMS_INVALID'; END IF;
    RETURN v_existing.result_snapshot;
  END IF;

  SELECT order_row.id
  INTO v_current_order_id
  FROM public.orders order_row
  WHERE order_row.table_id = v_table.table_id
    AND order_row.restaurant_id = v_table.restaurant_id
    AND order_row.status IN ('pending', 'confirmed', 'serving') AND public.table_order_is_current(order_row)
  ORDER BY order_row.created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF v_current_order_id IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.payments payment
       WHERE payment.order_id = v_current_order_id
         AND payment.is_revenue IS DISTINCT FROM true
     ) THEN
    RAISE EXCEPTION 'QR_ORDER_PAYMENT_IN_PROGRESS';
  END IF;

  RETURN public.qr_place_order_before_non_revenue_guard(
    p_token,
    p_items,
    p_client_order_id,
    p_validate_combo_choices,
    p_expected_order_id
  );
END;
$$;


CREATE OR REPLACE FUNCTION "public"."qr_place_order_pre_takeout_availability"("p_token" "text", "p_items" "jsonb", "p_client_order_id" "uuid", "p_validate_combo_choices" boolean, "p_expected_order_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_catalog'
    AS $$
DECLARE
  v_token text := NULLIF(btrim(COALESCE(p_token, '')), '');
  v_table record;
  v_current_order_id uuid;
  v_existing public.qr_order_batches%ROWTYPE;
  v_result jsonb;
BEGIN
  SELECT qr.restaurant_id, qr.table_id INTO v_table
  FROM public.table_qr_tokens qr
  JOIN public.tables table_row
    ON table_row.id = qr.table_id
   AND table_row.restaurant_id = qr.restaurant_id
  JOIN public.restaurants restaurant
    ON restaurant.id = qr.restaurant_id AND restaurant.is_active = true
  WHERE qr.token = v_token AND qr.is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'QR_TOKEN_INVALID'; END IF;

  SELECT * INTO v_existing
  FROM public.qr_order_batches batch
  WHERE batch.client_order_id = p_client_order_id
    AND batch.restaurant_id = v_table.restaurant_id
    AND batch.table_id = v_table.table_id;
  IF FOUND THEN IF v_existing.submission_hash IS NOT NULL AND v_existing.submission_hash IS DISTINCT FROM md5(p_items::text) THEN RAISE EXCEPTION 'QR_ITEMS_INVALID'; END IF;
    RETURN v_existing.result_snapshot; END IF;

  -- Payment locks the order before releasing its table. Match that order for
  -- an existing check so a payment completion and a QR addition cannot form
  -- an order/table lock cycle. If no active order exists, lock the table and
  -- recheck before allowing the delegated function to create one.
  SELECT order_row.id INTO v_current_order_id
  FROM public.orders order_row
  WHERE order_row.table_id = v_table.table_id
    AND order_row.restaurant_id = v_table.restaurant_id
    AND order_row.status IN ('pending', 'confirmed', 'serving') AND public.table_order_is_current(order_row)
  ORDER BY order_row.created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF v_current_order_id IS NULL THEN
    PERFORM 1
    FROM public.tables table_row
    WHERE table_row.id = v_table.table_id
      AND table_row.restaurant_id = v_table.restaurant_id
    FOR UPDATE;

    SELECT order_row.id INTO v_current_order_id
    FROM public.orders order_row
    WHERE order_row.table_id = v_table.table_id
      AND order_row.restaurant_id = v_table.restaurant_id
      AND order_row.status IN ('pending', 'confirmed', 'serving') AND public.table_order_is_current(order_row)
    ORDER BY order_row.created_at DESC
    LIMIT 1
    FOR UPDATE;
  ELSE
    PERFORM 1
    FROM public.tables table_row
    WHERE table_row.id = v_table.table_id
      AND table_row.restaurant_id = v_table.restaurant_id
    FOR UPDATE;
  END IF;

  IF v_current_order_id IS DISTINCT FROM p_expected_order_id THEN
    RAISE EXCEPTION 'QR_ORDER_CONTEXT_CHANGED';
  END IF;

  IF v_current_order_id IS NOT NULL THEN
    PERFORM public.qr_apply_due_order_display_reset(v_current_order_id);
  END IF;

  v_result := public.qr_place_order(
    p_token,
    p_items,
    p_client_order_id,
    p_validate_combo_choices
  );

  PERFORM public.qr_refresh_order_display_state((v_result->>'order_id')::uuid);
  RETURN v_result;
END;
$$;


NOTIFY pgrst,'reload schema';
DO $verify$ BEGIN
 IF EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.direct_order_request_items'::regclass AND conname='direct_order_request_items_request_id_menu_item_id_key')
 OR to_regclass('public.direct_order_request_items_request_menu_idx') IS NULL
 OR strpos(pg_get_functiondef('public.capture_menu_option_batch()'::regprocedure),'recipe_basis')=0
 THEN RAISE EXCEPTION 'MENU_CHOICE_INTAKE_CONTRACT_INVALID'; END IF;
END $verify$;
COMMIT;
