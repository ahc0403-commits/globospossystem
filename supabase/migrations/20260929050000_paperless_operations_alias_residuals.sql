-- Keep the paperless timing view's menu identity aligned with the corrected
-- Binh Thanh ledger names, including unpaid and combo-component samples.
-- Fulfillment events, sales, payments, prices, and tax records are unchanged.
CREATE FUNCTION pg_temp.replace_paperless_fragment(
  definition text, old_fragment text, new_fragment text, expected_count integer
) RETURNS text LANGUAGE plpgsql AS $helper$
DECLARE occurrences integer;
BEGIN
  occurrences := (length(definition)-length(replace(definition,old_fragment,'')))
    / length(old_fragment);
  IF occurrences <> expected_count THEN
    RAISE EXCEPTION 'PAPERLESS_ALIAS_ANCHOR_CHANGED: expected %, found %',
      expected_count, occurrences;
  END IF;
  RETURN replace(definition,old_fragment,new_fragment);
END $helper$;

DO $apply$
DECLARE definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.get_paperless_operations_report_pre_meal_start(uuid,timestamptz,timestamptz)'::regprocedure
  ) INTO definition;

  definition := pg_temp.replace_paperless_fragment(definition,
    $old$(payment.ledger_paid_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date$old$,
    $new$COALESCE((payment.ledger_paid_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
        (scoped.received_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date)$new$,2);

  definition := pg_temp.replace_paperless_fragment(definition,
    $old$      COALESCE(item.component_menu_item_id::text,
        'combo:' || lower(item.name_ko)) AS menu_key,
      item.name_ko, item.name_vi, item.name_en,
      false AS was_corrected,$old$,
    $new$      COALESCE(alias.menu_id::text, item.component_menu_item_id::text,
        'combo:' || lower(item.name_ko)) AS menu_key,
      COALESCE(alias.name_ko, item.name_ko),
      COALESCE(alias.name_vi, item.name_vi),
      COALESCE(alias.name_en, item.name_en),
      alias.menu_id IS NOT NULL AS was_corrected,$new$,1);

  definition := pg_temp.replace_paperless_fragment(definition,
    $old$    JOIN public.order_items order_item ON order_item.id = item.order_item_id
    JOIN combo_line_events events ON events.line_id = item.id$old$,
    $new$    JOIN public.order_items order_item ON order_item.id = item.order_item_id
    LEFT JOIN payment_times payment ON payment.order_id = scoped.order_id
    LEFT JOIN LATERAL public.bunsik_ledger_menu_alias(
      p_store_id, item.component_menu_item_id,
      COALESCE((payment.ledger_paid_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
        (scoped.received_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date)
    ) alias ON true
    JOIN combo_line_events events ON events.line_id = item.id$new$,1);

  definition := pg_temp.replace_paperless_fragment(definition,
    $old$    LEFT JOIN payment_times payment ON payment.order_id = scoped.order_id
    LEFT JOIN LATERAL public.bunsik_ledger_menu_alias(
      p_store_id, COALESCE(order_item.menu_item_id_snapshot, order_item.menu_item_id),
      COALESCE((payment.ledger_paid_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
        (scoped.received_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date)
    ) alias ON item.component_menu_item_id =
      COALESCE(order_item.menu_item_id_snapshot, order_item.menu_item_id)
    JOIN direct_line_events events ON events.line_id = item.id$old$,
    $new$    LEFT JOIN payment_times payment ON payment.order_id = scoped.order_id
    LEFT JOIN LATERAL public.bunsik_ledger_menu_alias(
      p_store_id, item.component_menu_item_id,
      COALESCE((payment.ledger_paid_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
        (scoped.received_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date)
    ) alias ON true
    JOIN direct_line_events events ON events.line_id = item.id$new$,1);

  EXECUTE definition;
END $apply$;

-- The drill-down accepts a menu key from the summary. Resolve its samples
-- through the same alias so the corrected row retains every timing record.
DO $apply$
DECLARE definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.get_paperless_menu_timing_detail(uuid,timestamptz,timestamptz,text,text,integer,numeric,text)'::regprocedure
  ) INTO definition;

  definition := pg_temp.replace_paperless_fragment(definition,
    $old$      queue.id AS queue_id,
      queue.order_id,
      queue.queue_no,$old$,
    $new$      queue.id AS queue_id,
      queue.order_id,
      queue.created_at AS received_at,
      queue.queue_no,$new$,1);
  definition := pg_temp.replace_paperless_fragment(definition,
    $old$  ),
  standard_line_events AS MATERIALIZED ($old$,
    $new$  ),
  payment_times AS MATERIALIZED (
    SELECT payment.order_id,
      max(COALESCE(payment_group.completed_at, payment.created_at))
        FILTER (WHERE payment.is_revenue = true) AS ledger_paid_at
    FROM public.payments AS payment
    JOIN scoped_orders AS scoped ON scoped.order_id = payment.order_id
    LEFT JOIN public.combined_payment_groups AS payment_group
      ON payment_group.id = payment.combined_payment_group_id
    WHERE payment.restaurant_id = p_store_id
    GROUP BY payment.order_id
  ),
  standard_line_events AS MATERIALIZED ($new$,1);

  definition := pg_temp.replace_paperless_fragment(definition,
    $old$      COALESCE(
        order_item.menu_item_id::text,
        'standard:'$old$,
    $new$      COALESCE(
        alias.menu_id::text, order_item.menu_item_id::text,
        'standard:'$new$,1);
  definition := pg_temp.replace_paperless_fragment(definition,
    $old$      COALESCE(
        item.component_menu_item_id::text,
        'combo:'$old$,
    $new$      COALESCE(
        alias.menu_id::text, item.component_menu_item_id::text,
        'combo:'$new$,1);
  definition := pg_temp.replace_paperless_fragment(definition,
    $old$      COALESCE(
        item.component_menu_item_id::text,
        'direct:'$old$,
    $new$      COALESCE(
        alias.menu_id::text, item.component_menu_item_id::text,
        'direct:'$new$,1);

  definition := pg_temp.replace_paperless_fragment(definition,
    $old$    JOIN public.order_items AS order_item ON order_item.id = item.order_item_id
    JOIN standard_line_events AS events ON events.line_id = item.id$old$,
    $new$    JOIN public.order_items AS order_item ON order_item.id = item.order_item_id
    LEFT JOIN payment_times AS payment ON payment.order_id = scoped.order_id
    LEFT JOIN LATERAL public.bunsik_ledger_menu_alias(
      p_store_id, COALESCE(order_item.menu_item_id_snapshot, order_item.menu_item_id),
      COALESCE((payment.ledger_paid_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
        (scoped.received_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date)
    ) AS alias ON true
    JOIN standard_line_events AS events ON events.line_id = item.id$new$,1);
  definition := pg_temp.replace_paperless_fragment(definition,
    $old$    JOIN public.order_items AS order_item ON order_item.id = item.order_item_id
    JOIN combo_line_events AS events ON events.line_id = item.id$old$,
    $new$    JOIN public.order_items AS order_item ON order_item.id = item.order_item_id
    LEFT JOIN payment_times AS payment ON payment.order_id = scoped.order_id
    LEFT JOIN LATERAL public.bunsik_ledger_menu_alias(
      p_store_id, item.component_menu_item_id,
      COALESCE((payment.ledger_paid_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
        (scoped.received_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date)
    ) AS alias ON true
    JOIN combo_line_events AS events ON events.line_id = item.id$new$,1);
  definition := pg_temp.replace_paperless_fragment(definition,
    $old$    JOIN public.order_items AS order_item ON order_item.id = item.order_item_id
    JOIN direct_line_events AS events ON events.line_id = item.id$old$,
    $new$    JOIN public.order_items AS order_item ON order_item.id = item.order_item_id
    LEFT JOIN payment_times AS payment ON payment.order_id = scoped.order_id
    LEFT JOIN LATERAL public.bunsik_ledger_menu_alias(
      p_store_id, item.component_menu_item_id,
      COALESCE((payment.ledger_paid_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
        (scoped.received_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date)
    ) AS alias ON true
    JOIN direct_line_events AS events ON events.line_id = item.id$new$,1);

  EXECUTE definition;
END $apply$;
