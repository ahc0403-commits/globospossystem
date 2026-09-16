DO $test$
DECLARE
  v_menu jsonb;
  v_created public.menu_items%ROWTYPE;
BEGIN
  IF NOT (
    SELECT is_visible_public
    FROM public.menu_items
    WHERE id = '55555555-5555-4555-8555-555555555555'
  ) THEN
    RAISE EXCEPTION 'TOP7 fixture was not made public';
  END IF;

  v_menu := public.qr_get_menu('fixture-token');
  IF jsonb_array_length(v_menu -> 'categories') <> 2
     OR v_menu #>> '{categories,0,name}' <> '메뉴 TOP7'
     OR v_menu #>> '{categories,1,name}' <> '신규' THEN
    RAISE EXCEPTION 'QR category list did not mirror active admin categories: %',
      v_menu -> 'categories';
  END IF;

  IF jsonb_array_length(v_menu -> 'items') <> 1
     OR v_menu #>> '{items,0,category_id}' <>
       '33333333-3333-4333-8333-333333333333' THEN
    RAISE EXCEPTION 'TOP7 item was not returned by QR menu: %',
      v_menu -> 'items';
  END IF;

  SELECT * INTO v_created
  FROM public.admin_create_menu_item_i18n_paperless(
    '11111111-1111-4111-8111-111111111111',
    '44444444-4444-4444-8444-444444444444',
    '신규 메뉴', 'Món mới', 'New menu', NULL,
    40000, 0, true
  );

  IF NOT v_created.is_visible_public THEN
    RAISE EXCEPTION 'New admin menu was not public by default';
  END IF;
END;
$test$;
