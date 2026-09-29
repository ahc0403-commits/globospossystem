-- Reporting-only menu identity correction matching the Binh Thanh receipt ledger.
-- Neither order_items nor their price, tax, payment, or invoice values change.
ALTER TABLE public.menu_categories
  ADD COLUMN analytics_group text NOT NULL DEFAULT 'food'
  CONSTRAINT menu_categories_analytics_group_check
    CHECK (analytics_group IN ('food', 'drink'));

UPDATE public.menu_categories
SET analytics_group = 'drink'
WHERE name_ko IN ('음료', '주류');

CREATE OR REPLACE FUNCTION public.bunsik_ledger_menu_alias(
  p_store_id uuid, p_menu_id uuid, p_business_date date
) RETURNS TABLE(menu_id uuid, name_ko text, name_vi text, name_en text)
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog
AS $function$
  SELECT alias.target_id, alias.name_ko, alias.name_vi, alias.name_en
  FROM (VALUES
    ('53249604-fd2e-40f5-a776-3e1bc5f32153'::uuid,
     '1917ec7d-c11e-4ed6-aced-c679d2104fba'::uuid,
     '코카콜라 제로'::text, 'Coca-Cola Zero'::text, 'Coca-Cola Zero'::text),
    ('4eda734f-4ac9-4f05-9eeb-0a4e4b122988'::uuid,
     '8ce1a136-f51a-4ee6-a14e-73184a874646'::uuid,
     '환타 오렌지'::text, 'Fanta Cam'::text, 'Fanta Orange'::text)
  ) AS alias(original_id, target_id, name_ko, name_vi, name_en)
  WHERE p_store_id = '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid
    AND p_business_date BETWEEN DATE '2026-08-08' AND DATE '2026-09-28'
    AND p_menu_id = alias.original_id;
$function$;

CREATE OR REPLACE FUNCTION public.admin_create_menu_category_with_group(
  p_store_id uuid, p_name_ko text, p_name_vi text, p_name_en text,
  p_sort_order integer, p_analytics_group text
) RETURNS public.menu_categories
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth, pg_catalog
AS $function$
DECLARE v_category public.menu_categories%ROWTYPE;
BEGIN
  IF p_analytics_group IS NULL OR p_analytics_group NOT IN ('food', 'drink') THEN
    RAISE EXCEPTION 'MENU_CATEGORY_ANALYTICS_GROUP_INVALID';
  END IF;
  v_category := public.admin_create_menu_category_i18n(
    p_store_id, p_name_ko, p_name_vi, p_name_en, p_sort_order
  );
  UPDATE public.menu_categories SET analytics_group = p_analytics_group
  WHERE id = v_category.id RETURNING * INTO v_category;
  RETURN v_category;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_update_menu_category_with_group(
  p_category_id uuid, p_name_ko text, p_name_vi text, p_name_en text,
  p_analytics_group text
) RETURNS public.menu_categories
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth, pg_catalog
AS $function$
DECLARE v_category public.menu_categories%ROWTYPE;
BEGIN
  IF p_analytics_group IS NULL OR p_analytics_group NOT IN ('food', 'drink') THEN
    RAISE EXCEPTION 'MENU_CATEGORY_ANALYTICS_GROUP_INVALID';
  END IF;
  v_category := public.admin_update_menu_category_i18n(
    p_category_id, p_name_ko, p_name_vi, p_name_en
  );
  UPDATE public.menu_categories SET analytics_group = p_analytics_group
  WHERE id = v_category.id RETURNING * INTO v_category;
  RETURN v_category;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_create_menu_category_with_group(uuid,text,text,text,integer,text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_update_menu_category_with_group(uuid,text,text,text,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_create_menu_category_with_group(uuid,text,text,text,integer,text)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_update_menu_category_with_group(uuid,text,text,text,text)
  TO authenticated, service_role;

-- Fail closed if any upstream report body has moved: the edit anchors below
-- must be unique in the effective, already-deployed function definitions.
CREATE FUNCTION pg_temp.replace_report_fragment(
  definition text, old_fragment text, new_fragment text, expected_count integer
) RETURNS text LANGUAGE plpgsql AS $helper$
DECLARE occurrences integer;
BEGIN
  occurrences := (length(definition)-length(replace(definition,old_fragment,'')))
    / length(old_fragment);
  IF occurrences <> expected_count THEN
    RAISE EXCEPTION 'MENU_REPORT_ANCHOR_CHANGED: expected %, found % for %',
      expected_count, occurrences, left(old_fragment, 90);
  END IF;
  RETURN replace(definition,old_fragment,new_fragment);
END $helper$;

DO $apply$
DECLARE definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.get_store_menu_sales_analytics(uuid,timestamptz,timestamptz,text)'::regprocedure
  ) INTO definition;
  definition := pg_temp.replace_report_fragment(definition,
    $old$max(payment.created_at) AS paid_at$old$,
    $new$max(payment.created_at) AS paid_at,
      max(COALESCE(payment_group.completed_at, payment.created_at)) AS ledger_paid_at$new$,1);
  definition := pg_temp.replace_report_fragment(definition,
    $old$    WHERE order_row.restaurant_id = p_store_id$old$,
    $new$    LEFT JOIN public.combined_payment_groups payment_group
      ON payment_group.id = payment.combined_payment_group_id
    WHERE order_row.restaurant_id = p_store_id$new$,1);
  definition := pg_temp.replace_report_fragment(definition,
    $old$      paid.paid_at,
      item.created_at AS line_created_at,$old$,
    $new$      paid.paid_at,
      item.created_at AS line_created_at,
      alias.name_ko AS correction_name_ko,
      alias.name_vi AS correction_name_vi,
      alias.name_en AS correction_name_en,$new$,1);
  definition := pg_temp.replace_report_fragment(definition,
    $old$          THEN COALESCE(
            item.menu_item_id_snapshot,
            item.menu_item_id
          )::text$old$,
    $new$          THEN COALESCE(
            alias.menu_id,
            item.menu_item_id_snapshot,
            item.menu_item_id
          )::text$new$,1);
  definition := pg_temp.replace_report_fragment(definition,
    $old$      COALESCE(
        NULLIF(btrim(item.display_name), ''),
        NULLIF(btrim(item.label), ''),
        'Unnamed menu'
      ) AS display_name,$old$,
    $new$      COALESCE(
        alias.name_ko,
        NULLIF(btrim(item.display_name), ''),
        NULLIF(btrim(item.label), ''),
        'Unnamed menu'
      ) AS display_name,$new$,1);
  definition := pg_temp.replace_report_fragment(definition,
    $old$     AND item.restaurant_id = p_store_id
    WHERE item.item_type = 'menu_item'$old$,
    $new$     AND item.restaurant_id = p_store_id
    LEFT JOIN LATERAL public.bunsik_ledger_menu_alias(
      p_store_id,
      COALESCE(item.menu_item_id_snapshot, item.menu_item_id),
      (paid.ledger_paid_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
    ) alias ON true
    WHERE item.item_type = 'menu_item'$new$,1);
  definition := pg_temp.replace_report_fragment(definition,
    $old$      (array_agg(
        line.display_name
        ORDER BY line.paid_at DESC, line.line_created_at DESC, line.order_id
      ))[1] AS display_name,$old$,
    $new$      COALESCE(max(line.correction_name_ko), (array_agg(
        line.display_name
        ORDER BY line.paid_at DESC, line.line_created_at DESC, line.order_id
      ))[1]) AS display_name,$new$,1);
  definition := pg_temp.replace_report_fragment(definition,
    $old$      min(line.identity_quality) AS identity_quality,$old$,
    $new$      min(line.identity_quality) AS identity_quality,
      max(line.correction_name_ko) AS correction_name_ko,
      max(line.correction_name_vi) AS correction_name_vi,
      max(line.correction_name_en) AS correction_name_en,$new$,1);
  definition := pg_temp.replace_report_fragment(definition,
    $old$'name_ko', menu_item.name_ko,
        'name_vi', menu_item.name_vi,
        'name_en', menu_item.name_en,$old$,
    $new$'name_ko', COALESCE(menu.correction_name_ko, menu_item.name_ko),
        'name_vi', COALESCE(menu.correction_name_vi, menu_item.name_vi),
        'name_en', COALESCE(menu.correction_name_en, menu_item.name_en),$new$,2);
  definition := pg_temp.replace_report_fragment(definition,
    $old$        'is_combo', menu.is_combo,
        'sold_quantity'$old$,
    $new$        'is_combo', menu.is_combo,
        'analytics_group', CASE WHEN menu.is_combo THEN 'combo'
          ELSE COALESCE((SELECT category.analytics_group
            FROM public.menu_categories category
            WHERE category.id = menu_item.category_id), 'food') END,
        'sold_quantity'$new$,1);
  EXECUTE definition;
END $apply$;

DO $apply$
DECLARE definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.get_paperless_operations_report_pre_meal_start(uuid,timestamptz,timestamptz)'::regprocedure
  ) INTO definition;
  definition := pg_temp.replace_report_fragment(definition,
    $old$SELECT payment.order_id, max(payment.created_at) AS paid_at
    FROM public.payments payment
    JOIN scoped_orders scoped ON scoped.order_id = payment.order_id
    WHERE payment.restaurant_id = p_store_id$old$,
    $new$SELECT payment.order_id, max(payment.created_at) AS paid_at,
      max(COALESCE(payment_group.completed_at, payment.created_at))
        FILTER (WHERE payment.is_revenue = true) AS ledger_paid_at
    FROM public.payments payment
    JOIN scoped_orders scoped ON scoped.order_id = payment.order_id
    LEFT JOIN public.combined_payment_groups payment_group
      ON payment_group.id = payment.combined_payment_group_id
    WHERE payment.restaurant_id = p_store_id$new$,1);
  definition := pg_temp.replace_report_fragment(definition,
    $old$      COALESCE(order_item.menu_item_id::text,
        'standard:'$old$,
    $new$      COALESCE(alias.menu_id::text, order_item.menu_item_id::text,
        'standard:'$new$,1);
  definition := pg_temp.replace_report_fragment(definition,
    $old$      COALESCE(NULLIF(order_item.label, ''),
        NULLIF(order_item.display_name, ''), NULLIF(menu.name_ko, ''),
        NULLIF(menu.name, ''), '메뉴') AS name_ko,
      COALESCE(NULLIF(menu.name_vi, ''), NULLIF(order_item.display_name, ''),
        NULLIF(order_item.label, ''), NULLIF(menu.name, ''), 'Món') AS name_vi,
      COALESCE(NULLIF(menu.name_en, ''), NULLIF(order_item.display_name, ''),
        NULLIF(order_item.label, ''), NULLIF(menu.name, ''), 'Menu') AS name_en,$old$,
    $new$      COALESCE(alias.name_ko, NULLIF(order_item.label, ''),
        NULLIF(order_item.display_name, ''), NULLIF(menu.name_ko, ''),
        NULLIF(menu.name, ''), '메뉴') AS name_ko,
      COALESCE(alias.name_vi, NULLIF(menu.name_vi, ''), NULLIF(order_item.display_name, ''),
        NULLIF(order_item.label, ''), NULLIF(menu.name, ''), 'Món') AS name_vi,
      COALESCE(alias.name_en, NULLIF(menu.name_en, ''), NULLIF(order_item.display_name, ''),
        NULLIF(order_item.label, ''), NULLIF(menu.name, ''), 'Menu') AS name_en,
      alias.menu_id IS NOT NULL AS was_corrected,$new$,1);
  definition := pg_temp.replace_report_fragment(definition,
    $old$    LEFT JOIN public.menu_items menu ON menu.id = order_item.menu_item_id
    JOIN standard_line_events events ON events.line_id = item.id$old$,
    $new$    LEFT JOIN public.menu_items menu ON menu.id = order_item.menu_item_id
    LEFT JOIN payment_times payment ON payment.order_id = scoped.order_id
    LEFT JOIN LATERAL public.bunsik_ledger_menu_alias(
      p_store_id, COALESCE(order_item.menu_item_id_snapshot, order_item.menu_item_id),
      (payment.ledger_paid_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
    ) alias ON true
    JOIN standard_line_events events ON events.line_id = item.id$new$,1);
  definition := pg_temp.replace_report_fragment(definition,
    $old$      item.name_ko, item.name_vi, item.name_en,
      CASE WHEN item.kitchen_done_quantity$old$,
    $new$      item.name_ko, item.name_vi, item.name_en,
      false AS was_corrected,
      CASE WHEN item.kitchen_done_quantity$new$,1);
  definition := pg_temp.replace_report_fragment(definition,
    $old$      COALESCE(item.component_menu_item_id::text,
        'direct:' || lower(item.name_ko)) AS menu_key,
      item.name_ko, item.name_vi, item.name_en,
      NULL::numeric AS kitchen_seconds,$old$,
    $new$      COALESCE(alias.menu_id::text, item.component_menu_item_id::text,
        'direct:' || lower(item.name_ko)) AS menu_key,
      COALESCE(alias.name_ko, item.name_ko),
      COALESCE(alias.name_vi, item.name_vi),
      COALESCE(alias.name_en, item.name_en),
      alias.menu_id IS NOT NULL AS was_corrected,
      NULL::numeric AS kitchen_seconds,$new$,1);
  definition := pg_temp.replace_report_fragment(definition,
    $old$    JOIN direct_line_events events ON events.line_id = item.id
    WHERE item.restaurant_id = p_store_id$old$,
    $new$    LEFT JOIN payment_times payment ON payment.order_id = scoped.order_id
    LEFT JOIN LATERAL public.bunsik_ledger_menu_alias(
      p_store_id, COALESCE(order_item.menu_item_id_snapshot, order_item.menu_item_id),
      (payment.ledger_paid_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
    ) alias ON item.component_menu_item_id =
      COALESCE(order_item.menu_item_id_snapshot, order_item.menu_item_id)
    JOIN direct_line_events events ON events.line_id = item.id
    WHERE item.restaurant_id = p_store_id$new$,1);
  definition := pg_temp.replace_report_fragment(definition,
    $old$      max(name_ko) AS name_ko,
      max(name_vi) AS name_vi,
      max(name_en) AS name_en,$old$,
    $new$      COALESCE(max(name_ko) FILTER (WHERE was_corrected), max(name_ko)) AS name_ko,
      COALESCE(max(name_vi) FILTER (WHERE was_corrected), max(name_vi)) AS name_vi,
      COALESCE(max(name_en) FILTER (WHERE was_corrected), max(name_en)) AS name_en,
      bool_or(was_corrected) AS was_corrected,$new$,1);
  definition := pg_temp.replace_report_fragment(definition,
    $old$        'name_en', metric.name_en,$old$,
    $new$        'name_en', metric.name_en,
        'corrected_name', metric.was_corrected,$new$,1);
  definition := pg_temp.replace_report_fragment(definition,
    $old$        SELECT max(name_ko) AS name,
          count(kitchen_seconds)$old$,
    $new$        SELECT COALESCE(max(name_ko) FILTER (WHERE was_corrected),
            max(name_ko)) AS name,
          count(kitchen_seconds)$new$,1);
  EXECUTE definition;
END $apply$;

DO $apply$
DECLARE definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.get_paperless_operations_report(uuid,timestamptz,timestamptz)'::regprocedure
  ) INTO definition;
  definition := pg_temp.replace_report_fragment(definition,
    $old$        WHEN menu.id IS NULL THEN entry.metric$old$,
    $new$        WHEN menu.id IS NULL OR entry.metric ->> 'corrected_name' = 'true'
          THEN entry.metric$new$,1);
  EXECUTE definition;
END $apply$;
