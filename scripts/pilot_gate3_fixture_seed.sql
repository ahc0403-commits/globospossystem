-- pilot_gate3_fixture_seed.sql
-- Idempotent Gate 3 fixture seed for a dedicated pilot test store.
--
-- Runtime wrapper must replace __SMOKE_SHARED_PASSWORD__ in a temporary copy.
-- Do not commit or print the generated password.

-- Fail closed unless a local-only test runner explicitly enables this seed in
-- the same database session. Production runners do not set this GUC.
DO $local_only_guard$
BEGIN
  IF current_setting('app.allow_local_pos_fixture_seed', true)
       IS DISTINCT FROM 'LOCAL_ONLY' THEN
    RAISE EXCEPTION
      'LOCAL_FIXTURE_SEED_ONLY: test accounts and fixture restaurants are forbidden in production';
  END IF;
END;
$local_only_guard$;

BEGIN;

DO $secret$
BEGIN
  PERFORM set_config(
    'pilot_gate3.smoke_password',
    '__SMOKE_SHARED_PASSWORD__',
    true
  );
END;
$secret$;

DO $fixture$
DECLARE
  v_password text;
  v_store uuid := '90000000-0000-4000-8000-000000000301';
  v_table_1f uuid := '90000000-0000-4000-8000-000000000321';
  v_table_2f uuid := '90000000-0000-4000-8000-000000000322';
  v_table_3f uuid := '90000000-0000-4000-8000-000000000323';
  v_category uuid := '90000000-0000-4000-8000-000000000331';
  v_menu_item uuid := '90000000-0000-4000-8000-000000000332';
  v_inventory_item uuid := '90000000-0000-4000-8000-000000000341';
  v_product uuid := '90000000-0000-4000-8000-000000000342';
  v_supplier uuid := '90000000-0000-4000-8000-000000000343';
  v_supplier_item uuid := '90000000-0000-4000-8000-000000000344';
  v_po uuid := '90000000-0000-4000-8000-000000000345';
  v_po_line uuid := '90000000-0000-4000-8000-000000000346';
  v_receipt uuid := '90000000-0000-4000-8000-000000000347';
  v_receipt_line uuid := '90000000-0000-4000-8000-000000000348';
  v_qc_template uuid := '90000000-0000-4000-8000-000000000351';
  v_qc_check uuid := '90000000-0000-4000-8000-000000000352';
  v_qc_followup uuid := '90000000-0000-4000-8000-000000000353';
  v_order uuid := '90000000-0000-4000-8000-000000000361';
  v_order_item uuid := '90000000-0000-4000-8000-000000000362';
  v_payment uuid := '90000000-0000-4000-8000-000000000363';
  v_dest_kitchen uuid := '90000000-0000-4000-8000-000000000371';
  v_dest_1f uuid := '90000000-0000-4000-8000-000000000372';
  v_dest_2f uuid := '90000000-0000-4000-8000-000000000373';
  v_dest_3f uuid := '90000000-0000-4000-8000-000000000374';
  v_dest_receipt uuid := '90000000-0000-4000-8000-000000000375';
  v_brand uuid;
  v_tax_entity uuid;
  v_waiter_auth uuid := '90000000-0000-4000-8000-000000000311';
  v_kitchen_auth uuid := '90000000-0000-4000-8000-000000000312';
  v_cashier_auth uuid := '90000000-0000-4000-8000-000000000313';
  v_admin_auth uuid := '90000000-0000-4000-8000-000000000314';
  v_super_auth uuid := '90000000-0000-4000-8000-000000000315';
  v_validation_auth uuid := '90000000-0000-4000-8000-000000000316';
  v_qa_run_id text := 'pilot_gate3_fixture';
  v_waiter_user uuid;
  v_admin_user uuid;
  v_actor record;
BEGIN
  v_password := current_setting('pilot_gate3.smoke_password', true);

  IF v_password IS NULL
     OR v_password = ('__SMOKE' || '_SHARED_PASSWORD__')
     OR length(v_password) < 16 THEN
    RAISE EXCEPTION 'pilot_gate3 smoke password missing or too short';
  END IF;

  SELECT brand_id, tax_entity_id
  INTO v_brand, v_tax_entity
  FROM public.restaurants
  WHERE is_active
    AND brand_id IS NOT NULL
    AND tax_entity_id IS NOT NULL
  ORDER BY created_at
  LIMIT 1;

  IF v_brand IS NULL OR v_tax_entity IS NULL THEN
    RAISE EXCEPTION 'No active store with brand_id/tax_entity_id available';
  END IF;

  INSERT INTO public.restaurants (
    id, name, address, slug, operation_mode, is_active,
    brand_id, store_type, tax_entity_id, vat_pricing_mode
  ) VALUES (
    v_store,
    'Pilot Gate3 Fixture Store',
    'Pilot fixture only - do not use for live sales',
    'pilot-gate3-fixture',
    'standard',
    true,
    v_brand,
    'direct',
    v_tax_entity,
    'exclusive'
  )
  ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    address = EXCLUDED.address,
    slug = EXCLUDED.slug,
    operation_mode = EXCLUDED.operation_mode,
    is_active = true,
    brand_id = EXCLUDED.brand_id,
    store_type = EXCLUDED.store_type,
    tax_entity_id = EXCLUDED.tax_entity_id,
    vat_pricing_mode = EXCLUDED.vat_pricing_mode;

  INSERT INTO public.restaurant_settings (restaurant_id, settings_json)
  VALUES (
    v_store,
    jsonb_build_object(
      'fixture', 'pilot_gate3',
      'qa_run_id', v_qa_run_id,
      'cleanup_scope', 'dedicated_fixture_store',
      'discount_manager_pin_enabled', true,
      'pilot_gate3_seeded_at', now()
    )
  )
  ON CONFLICT (restaurant_id) DO UPDATE SET
    settings_json = public.restaurant_settings.settings_json || EXCLUDED.settings_json,
    updated_at = now();

  FOR v_actor IN
    SELECT * FROM (VALUES
      (v_waiter_auth, 'gate3.waiter@globos.test', 'waiter', 'Gate3 Waiter'),
      (v_kitchen_auth, 'gate3.kitchen@globos.test', 'kitchen', 'Gate3 Kitchen'),
      (v_cashier_auth, 'gate3.cashier@globos.test', 'cashier', 'Gate3 Cashier'),
      (v_admin_auth, 'gate3.admin@globos.test', 'admin', 'Gate3 Admin'),
      (v_super_auth, 'gate3.superadmin@globos.test', 'super_admin', 'Gate3 Super Admin'),
      (v_validation_auth, 'gate3.validation@globos.test', 'admin', 'Gate3 Validation')
    ) AS t(auth_id, email, staff_role, full_name)
  LOOP
    INSERT INTO auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at,
      confirmation_token, recovery_token, email_change, email_change_token_new
    ) VALUES (
      '00000000-0000-0000-0000-000000000000',
      v_actor.auth_id,
      'authenticated',
      'authenticated',
      v_actor.email,
      crypt(v_password, gen_salt('bf')),
      now(),
      jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
      jsonb_build_object('fixture', 'pilot_gate3', 'qa_run_id', v_qa_run_id),
      now(),
      now(),
      '',
      '',
      '',
      ''
    )
    ON CONFLICT (id) DO UPDATE SET
      aud = EXCLUDED.aud,
      role = EXCLUDED.role,
      email = EXCLUDED.email,
      encrypted_password = EXCLUDED.encrypted_password,
      email_confirmed_at = EXCLUDED.email_confirmed_at,
      raw_app_meta_data = EXCLUDED.raw_app_meta_data,
      raw_user_meta_data = EXCLUDED.raw_user_meta_data,
      updated_at = now(),
      deleted_at = NULL,
      banned_until = NULL;

    INSERT INTO auth.identities (
      id, user_id, provider_id, provider, identity_data,
      last_sign_in_at, created_at, updated_at
    ) VALUES (
      v_actor.auth_id,
      v_actor.auth_id,
      v_actor.auth_id::text,
      'email',
      jsonb_build_object(
        'sub', v_actor.auth_id::text,
        'email', v_actor.email,
        'email_verified', true
      ),
      now(),
      now(),
      now()
    )
    ON CONFLICT (provider_id, provider) DO UPDATE SET
      user_id = EXCLUDED.user_id,
      identity_data = EXCLUDED.identity_data,
      updated_at = now();

    INSERT INTO public.users (
      auth_id, restaurant_id, role, full_name, is_active, brand_id,
      primary_store_id, extra_permissions
    ) VALUES (
      v_actor.auth_id,
      v_store,
      v_actor.staff_role,
      v_actor.full_name,
      true,
      v_brand,
      v_store,
      ARRAY[]::text[]
    )
    ON CONFLICT (auth_id) DO UPDATE SET
      restaurant_id = EXCLUDED.restaurant_id,
      role = EXCLUDED.role,
      full_name = EXCLUDED.full_name,
      is_active = true,
      brand_id = EXCLUDED.brand_id,
      primary_store_id = EXCLUDED.primary_store_id;

    INSERT INTO public.user_store_access (
      user_id, store_id, is_primary, is_active, source_type
    )
    SELECT u.id, v_store, true, true, 'direct'
    FROM public.users u
    WHERE u.auth_id = v_actor.auth_id
    ON CONFLICT (user_id, store_id, source_type) DO UPDATE SET
      is_primary = true,
      is_active = true,
      updated_at = now();

    PERFORM public.refresh_user_claims(v_actor.auth_id);
  END LOOP;

  SELECT id INTO v_waiter_user FROM public.users WHERE auth_id = v_waiter_auth;
  SELECT id INTO v_admin_user FROM public.users WHERE auth_id = v_admin_auth;

  INSERT INTO public.tables (
    id, restaurant_id, table_number, seat_count, status,
    layout_x, layout_y, layout_w, layout_h, layout_sort_order, floor_label
  ) VALUES
    (v_table_1f, v_store, 'G3-1F-01', 4, 'available', 0.05, 0.08, 0.18, 0.14, 1, '1F'),
    (v_table_2f, v_store, 'G3-2F-01', 4, 'available', 0.05, 0.28, 0.18, 0.14, 2, '2F'),
    (v_table_3f, v_store, 'G3-3F-01', 4, 'available', 0.05, 0.48, 0.18, 0.14, 3, '3F')
  ON CONFLICT (id) DO UPDATE SET
    table_number = EXCLUDED.table_number,
    seat_count = EXCLUDED.seat_count,
    status = EXCLUDED.status,
    layout_x = EXCLUDED.layout_x,
    layout_y = EXCLUDED.layout_y,
    layout_w = EXCLUDED.layout_w,
    layout_h = EXCLUDED.layout_h,
    layout_sort_order = EXCLUDED.layout_sort_order,
    floor_label = EXCLUDED.floor_label,
    updated_at = now();

  INSERT INTO public.printer_destinations (
    id, restaurant_id, name, ip, port, purpose, floor_label, is_active
  ) VALUES
    (v_dest_kitchen, v_store, 'Gate3 Kitchen XP-Q807K', '192.168.88.171', 9100, 'kitchen', NULL, true),
    (v_dest_1f, v_store, 'Gate3 1F/Cashier XP-N160', '192.168.88.172', 9100, 'floor', '1F', true),
    (v_dest_2f, v_store, 'Gate3 2F XP-N160', '192.168.88.173', 9100, 'floor', '2F', true),
    (v_dest_3f, v_store, 'Gate3 3F XP-N160', '192.168.88.174', 9100, 'floor', '3F', true),
    (v_dest_receipt, v_store, 'Gate3 Cashier Receipt XP-N160', '192.168.88.172', 9100, 'receipt', NULL, true)
  ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    ip = EXCLUDED.ip,
    port = EXCLUDED.port,
    purpose = EXCLUDED.purpose,
    floor_label = EXCLUDED.floor_label,
    is_active = true,
    updated_at = now();

  INSERT INTO public.menu_categories (id, restaurant_id, name, sort_order, is_active)
  VALUES (v_category, v_store, 'Gate3 Smoke Menu', 1, true)
  ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    sort_order = EXCLUDED.sort_order,
    is_active = true;

  INSERT INTO public.menu_items (
    id, restaurant_id, category_id, name, description, price,
    is_available, is_visible_public, sort_order, vat_category
  ) VALUES (
    v_menu_item,
    v_store,
    v_category,
    'Gate3 Pho Smoke',
    'Pilot fixture public QR menu item',
    120000,
    true,
    true,
    1,
    'food'
  )
  ON CONFLICT (id) DO UPDATE SET
    category_id = EXCLUDED.category_id,
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    price = EXCLUDED.price,
    is_available = true,
    is_visible_public = true,
    sort_order = EXCLUDED.sort_order,
    vat_category = EXCLUDED.vat_category,
    updated_at = now();

  INSERT INTO public.table_qr_tokens (
    restaurant_id, table_id, token, is_active, created_by
  ) VALUES
    (v_store, v_table_1f, 'gate3-1f-token-20260709', true, v_admin_auth),
    (v_store, v_table_2f, 'gate3-2f-token-20260709', true, v_admin_auth),
    (v_store, v_table_3f, 'gate3-3f-token-20260709', true, v_admin_auth)
  ON CONFLICT (token) DO UPDATE SET
    restaurant_id = EXCLUDED.restaurant_id,
    table_id = EXCLUDED.table_id,
    is_active = true,
    created_by = EXCLUDED.created_by,
    rotated_at = NULL;

  INSERT INTO public.inventory_items (
    id, restaurant_id, name, quantity, unit, current_stock,
    reorder_point, cost_per_unit, supplier_name, is_active
  ) VALUES (
    v_inventory_item,
    v_store,
    'Gate3 Beef Stock',
    5000,
    'g',
    5000,
    1000,
    45,
    'Gate3 Supplier',
    true
  )
  ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    quantity = EXCLUDED.quantity,
    unit = EXCLUDED.unit,
    current_stock = EXCLUDED.current_stock,
    reorder_point = EXCLUDED.reorder_point,
    cost_per_unit = EXCLUDED.cost_per_unit,
    supplier_name = EXCLUDED.supplier_name,
    is_active = true,
    updated_at = now();

  INSERT INTO public.inventory_suppliers (
    id, brand_id, supplier_name, supplier_type, contact_name,
    phone, email, status, memo
  ) VALUES (
    v_supplier,
    v_brand,
    'Gate3 Supplier',
    'food',
    'Gate3 Contact',
    '+84000000000',
    'gate3.supplier@globos.test',
    'active',
    'Pilot Gate3 fixture'
  )
  ON CONFLICT (id) DO UPDATE SET
    supplier_name = EXCLUDED.supplier_name,
    supplier_type = EXCLUDED.supplier_type,
    contact_name = EXCLUDED.contact_name,
    phone = EXCLUDED.phone,
    email = EXCLUDED.email,
    status = EXCLUDED.status,
    memo = EXCLUDED.memo,
    updated_at = now();

  INSERT INTO public.inventory_products (
    id, restaurant_id, brand_id, inventory_item_id, product_code,
    name, category, stock_unit, base_unit, base_unit_factor,
    storage_type, shelf_life_days, is_orderable, is_active
  ) VALUES (
    v_product,
    v_store,
    v_brand,
    v_inventory_item,
    'GATE3-BEEF-STOCK',
    'Gate3 Beef Stock Product',
    'ingredient',
    'kg',
    'g',
    1000,
    'cold',
    3,
    true,
    true
  )
  ON CONFLICT (id) DO UPDATE SET
    inventory_item_id = EXCLUDED.inventory_item_id,
    product_code = EXCLUDED.product_code,
    name = EXCLUDED.name,
    category = EXCLUDED.category,
    stock_unit = EXCLUDED.stock_unit,
    base_unit = EXCLUDED.base_unit,
    base_unit_factor = EXCLUDED.base_unit_factor,
    storage_type = EXCLUDED.storage_type,
    shelf_life_days = EXCLUDED.shelf_life_days,
    is_orderable = true,
    is_active = true,
    updated_at = now();

  INSERT INTO public.inventory_supplier_items (
    id, supplier_id, product_id, supplier_sku, order_unit,
    order_unit_quantity_base, min_order_quantity, unit_price,
    tax_rate, lead_time_days, is_preferred, is_active
  ) VALUES (
    v_supplier_item,
    v_supplier,
    v_product,
    'G3-BEEF-1KG',
    'kg',
    1000,
    1,
    45000,
    0,
    1,
    true,
    true
  )
  ON CONFLICT (supplier_id, product_id, order_unit) DO UPDATE SET
    supplier_sku = EXCLUDED.supplier_sku,
    order_unit_quantity_base = EXCLUDED.order_unit_quantity_base,
    min_order_quantity = EXCLUDED.min_order_quantity,
    unit_price = EXCLUDED.unit_price,
    tax_rate = EXCLUDED.tax_rate,
    lead_time_days = EXCLUDED.lead_time_days,
    is_preferred = true,
    is_active = true,
    updated_at = now();

  INSERT INTO public.inventory_purchase_orders (
    id, purchase_order_no, restaurant_id, brand_id, supplier_id,
    status, order_type, source, requested_delivery_date, ordered_at,
    submitted_by, total_supply_amount, tax_amount, total_amount, memo
  ) VALUES (
    v_po,
    'GATE3-PO-20260709',
    v_store,
    v_brand,
    v_supplier,
    'received',
    'manual',
    'pos',
    current_date,
    now(),
    v_admin_auth,
    45000,
    0,
    45000,
    'Pilot Gate3 fixture purchase order qa_run_id=pilot_gate3_fixture'
  )
  ON CONFLICT (id) DO UPDATE SET
    status = EXCLUDED.status,
    ordered_at = EXCLUDED.ordered_at,
    submitted_by = EXCLUDED.submitted_by,
    total_supply_amount = EXCLUDED.total_supply_amount,
    tax_amount = EXCLUDED.tax_amount,
    total_amount = EXCLUDED.total_amount,
    memo = EXCLUDED.memo,
    updated_at = now();

  INSERT INTO public.inventory_purchase_order_lines (
    id, purchase_order_id, product_id, supplier_item_id,
    recommended_quantity_base, ordered_quantity_base, ordered_quantity_unit,
    order_unit, unit_price, supply_amount, tax_amount, memo
  ) VALUES (
    v_po_line,
    v_po,
    v_product,
    v_supplier_item,
    1000,
    1000,
    1,
    'kg',
    45000,
    45000,
    0,
    'Pilot Gate3 fixture PO line qa_run_id=pilot_gate3_fixture'
  )
  ON CONFLICT (id) DO UPDATE SET
    supplier_item_id = EXCLUDED.supplier_item_id,
    recommended_quantity_base = EXCLUDED.recommended_quantity_base,
    ordered_quantity_base = EXCLUDED.ordered_quantity_base,
    ordered_quantity_unit = EXCLUDED.ordered_quantity_unit,
    order_unit = EXCLUDED.order_unit,
    unit_price = EXCLUDED.unit_price,
    supply_amount = EXCLUDED.supply_amount,
    tax_amount = EXCLUDED.tax_amount,
    memo = EXCLUDED.memo,
    updated_at = now();

  INSERT INTO public.inventory_receipts (
    id, purchase_order_id, restaurant_id, supplier_id, received_at,
    received_by, status, memo
  ) VALUES (
    v_receipt,
    v_po,
    v_store,
    v_supplier,
    now(),
    v_admin_auth,
    'confirmed',
    'Pilot Gate3 fixture receipt qa_run_id=pilot_gate3_fixture'
  )
  ON CONFLICT (id) DO UPDATE SET
    received_at = EXCLUDED.received_at,
    received_by = EXCLUDED.received_by,
    status = EXCLUDED.status,
    memo = EXCLUDED.memo,
    updated_at = now();

  INSERT INTO public.inventory_receipt_lines (
    id, receipt_id, purchase_order_line_id, product_id,
    received_quantity_base, accepted_quantity_base, rejected_quantity_base, memo
  ) VALUES (
    v_receipt_line,
    v_receipt,
    v_po_line,
    v_product,
    1000,
    1000,
    0,
    'Pilot Gate3 fixture receipt line qa_run_id=pilot_gate3_fixture'
  )
  ON CONFLICT (id) DO UPDATE SET
    received_quantity_base = EXCLUDED.received_quantity_base,
    accepted_quantity_base = EXCLUDED.accepted_quantity_base,
    rejected_quantity_base = EXCLUDED.rejected_quantity_base,
    memo = EXCLUDED.memo;

  INSERT INTO public.inventory_transactions (
    restaurant_id, ingredient_id, transaction_type, quantity_g,
    reference_type, reference_id, note, created_by
  )
  SELECT v_store, v_inventory_item, 'restock', 1000, 'pilot_gate3',
         v_receipt, 'Pilot Gate3 fixture restock qa_run_id=pilot_gate3_fixture', v_admin_auth
  WHERE NOT EXISTS (
    SELECT 1 FROM public.inventory_transactions
    WHERE restaurant_id = v_store
      AND ingredient_id = v_inventory_item
      AND reference_type = 'pilot_gate3'
      AND reference_id = v_receipt
  );

  INSERT INTO public.attendance_logs (
    restaurant_id, user_id, type, logged_at
  ) VALUES
    (v_store, v_waiter_user, 'clock_in', now() - interval '2 hours'),
    (v_store, v_waiter_user, 'clock_out', now() - interval '1 hour')
  ON CONFLICT DO NOTHING;

  INSERT INTO public.staff_wage_configs (
    restaurant_id, user_id, wage_type, hourly_rate, effective_from, is_active
  ) VALUES (
    v_store,
    v_waiter_user,
    'hourly',
    25000,
    current_date,
    true
  )
  ON CONFLICT DO NOTHING;

  INSERT INTO public.qc_templates (
    id, restaurant_id, category, criteria_text, sort_order, is_active,
    is_global, qsc_domain, requires_photo, required_photo_count, weight
  ) VALUES (
    v_qc_template,
    v_store,
    'cleanliness',
    'Gate3 kitchen station clean',
    1,
    true,
    false,
    'cleanliness',
    false,
    0,
    1
  )
  ON CONFLICT (id) DO UPDATE SET
    criteria_text = EXCLUDED.criteria_text,
    is_active = true,
    qsc_domain = EXCLUDED.qsc_domain,
    requires_photo = false,
    required_photo_count = 0,
    updated_at = now();

  INSERT INTO public.qc_checks (
    id, restaurant_id, template_id, check_date, checked_by, result,
    note, submitted_at, submission_status, photo_required_count,
    photo_uploaded_count, score, grade
  ) VALUES (
    v_qc_check,
    v_store,
    v_qc_template,
    current_date,
    v_admin_auth,
    'pass',
    'Pilot Gate3 fixture QC pass qa_run_id=pilot_gate3_fixture',
    now(),
    'submitted',
    0,
    0,
    100,
    'good'
  )
  ON CONFLICT (id) DO UPDATE SET
    check_date = EXCLUDED.check_date,
    checked_by = EXCLUDED.checked_by,
    result = EXCLUDED.result,
    note = EXCLUDED.note,
    submitted_at = EXCLUDED.submitted_at,
    submission_status = EXCLUDED.submission_status,
    score = EXCLUDED.score,
    grade = EXCLUDED.grade;

  INSERT INTO public.qc_followups (
    id, restaurant_id, source_check_id, status, assigned_to_name,
    resolution_notes, created_by, resolved_at
  ) VALUES (
    v_qc_followup,
    v_store,
    v_qc_check,
    'open',
    'Gate3 Admin',
    NULL,
    v_admin_auth,
    NULL
  )
  ON CONFLICT (id) DO UPDATE SET
    status = EXCLUDED.status,
    assigned_to_name = EXCLUDED.assigned_to_name,
    updated_at = now();

  INSERT INTO public.orders (
    id, restaurant_id, table_id, sales_channel, status,
    guest_count, created_by, notes, order_purpose, order_source
  ) VALUES (
    v_order,
    v_store,
    v_table_1f,
    'dine_in',
    'completed',
    2,
    v_waiter_auth,
    'Pilot Gate3 fixture completed order qa_run_id=pilot_gate3_fixture',
    'customer',
    'staff'
  )
  ON CONFLICT (id) DO UPDATE SET
    table_id = EXCLUDED.table_id,
    status = EXCLUDED.status,
    guest_count = EXCLUDED.guest_count,
    created_by = EXCLUDED.created_by,
    notes = EXCLUDED.notes,
    order_purpose = EXCLUDED.order_purpose,
    order_source = EXCLUDED.order_source,
    updated_at = now();

  INSERT INTO public.order_items (
    id, restaurant_id, order_id, menu_item_id, label, unit_price,
    quantity, status, display_name, total_amount_ex_tax, paying_amount_inc_tax
  ) VALUES (
    v_order_item,
    v_store,
    v_order,
    v_menu_item,
    'Gate3 Pho Smoke',
    120000,
    1,
    'served',
    'Gate3 Pho Smoke',
    120000,
    120000
  )
  ON CONFLICT (id) DO UPDATE SET
    menu_item_id = EXCLUDED.menu_item_id,
    label = EXCLUDED.label,
    unit_price = EXCLUDED.unit_price,
    quantity = EXCLUDED.quantity,
    status = EXCLUDED.status,
    display_name = EXCLUDED.display_name,
    total_amount_ex_tax = EXCLUDED.total_amount_ex_tax,
    paying_amount_inc_tax = EXCLUDED.paying_amount_inc_tax;

  INSERT INTO public.payments (
    id, restaurant_id, order_id, amount, method, is_revenue,
    processed_by, notes, amount_portion
  ) VALUES (
    v_payment,
    v_store,
    v_order,
    120000,
    'CASH',
    true,
    v_cashier_auth,
    'Pilot Gate3 fixture payment qa_run_id=pilot_gate3_fixture',
    120000
  )
  ON CONFLICT (id) DO UPDATE SET
    amount = EXCLUDED.amount,
    method = EXCLUDED.method,
    is_revenue = EXCLUDED.is_revenue,
    processed_by = EXCLUDED.processed_by,
    notes = EXCLUDED.notes,
    amount_portion = EXCLUDED.amount_portion;

  INSERT INTO public.print_jobs (
    restaurant_id, order_id, copy_type, batch_no, destination_id,
    payload, status, attempts, claimed_by, last_error
  )
  SELECT v_store, v_order, 'kitchen', 1, v_dest_kitchen,
         jsonb_build_object(
           'fixture', 'pilot_gate3',
           'qa_run_id', v_qa_run_id,
           'order_id', v_order
         ),
         'done', 1, v_admin_auth, NULL
  WHERE NOT EXISTS (
    SELECT 1 FROM public.print_jobs
    WHERE restaurant_id = v_store
      AND order_id = v_order
      AND copy_type = 'kitchen'
      AND payload->>'fixture' = 'pilot_gate3'
  );

  INSERT INTO public.print_jobs (
    restaurant_id, order_id, copy_type, batch_no, destination_id,
    payload, status, attempts, claimed_by, last_error
  )
  SELECT v_store, v_order, 'floor', 1, v_dest_1f,
         jsonb_build_object(
           'fixture', 'pilot_gate3',
           'qa_run_id', v_qa_run_id,
           'order_id', v_order
         ),
         'pending', 0, NULL, NULL
  WHERE NOT EXISTS (
    SELECT 1 FROM public.print_jobs
    WHERE restaurant_id = v_store
      AND order_id = v_order
      AND copy_type = 'floor'
      AND payload->>'fixture' = 'pilot_gate3'
  );

  INSERT INTO public.daily_closings (
    restaurant_id, closing_date, closed_by, orders_total,
    orders_completed, payments_count, payments_total, payments_cash, notes
  ) VALUES (
    v_store,
    current_date - 1,
    v_admin_auth,
    1,
    1,
    1,
    120000,
    120000,
    'Pilot Gate3 fixture daily close qa_run_id=pilot_gate3_fixture'
  )
  ON CONFLICT (restaurant_id, closing_date) DO UPDATE SET
    closed_by = EXCLUDED.closed_by,
    orders_total = EXCLUDED.orders_total,
    orders_completed = EXCLUDED.orders_completed,
    payments_count = EXCLUDED.payments_count,
    payments_total = EXCLUDED.payments_total,
    payments_cash = EXCLUDED.payments_cash,
    notes = EXCLUDED.notes;

  PERFORM public.refresh_user_claims(v_waiter_auth);
  PERFORM public.refresh_user_claims(v_kitchen_auth);
  PERFORM public.refresh_user_claims(v_cashier_auth);
  PERFORM public.refresh_user_claims(v_admin_auth);
  PERFORM public.refresh_user_claims(v_super_auth);
  PERFORM public.refresh_user_claims(v_validation_auth);
END;
$fixture$;

DO $verify$
DECLARE
  v jsonb;
BEGIN
  SELECT jsonb_build_object(
    'stores', (SELECT count(*) FROM public.restaurants WHERE slug = 'pilot-gate3-fixture' AND is_active),
    'users', (
      SELECT count(*)
      FROM auth.users
      WHERE email IN (
        'gate3.waiter@globos.test',
        'gate3.kitchen@globos.test',
        'gate3.cashier@globos.test',
        'gate3.admin@globos.test',
        'gate3.superadmin@globos.test',
        'gate3.validation@globos.test'
      )
      AND encrypted_password IS NOT NULL
      AND email_confirmed_at IS NOT NULL
    ),
    'profiles', (
      SELECT count(*)
      FROM public.users u
      JOIN public.restaurants r ON r.id = u.restaurant_id
      WHERE r.slug = 'pilot-gate3-fixture'
        AND u.is_active
    ),
    'floors', (
      SELECT count(DISTINCT floor_label)
      FROM public.tables
      WHERE restaurant_id = '90000000-0000-4000-8000-000000000301'
    ),
    'printers', (
      SELECT count(*)
      FROM public.printer_destinations
      WHERE restaurant_id = '90000000-0000-4000-8000-000000000301'
        AND is_active
    ),
    'qr_tokens', (
      SELECT count(*)
      FROM public.table_qr_tokens
      WHERE restaurant_id = '90000000-0000-4000-8000-000000000301'
        AND is_active
    ),
    'public_menu', (
      SELECT count(*)
      FROM public.menu_items
      WHERE restaurant_id = '90000000-0000-4000-8000-000000000301'
        AND is_available
        AND is_visible_public
    ),
    'attendance_logs', (
      SELECT count(*)
      FROM public.attendance_logs
      WHERE restaurant_id = '90000000-0000-4000-8000-000000000301'
    ),
    'inventory', (
      SELECT count(*)
      FROM public.inventory_items
      WHERE restaurant_id = '90000000-0000-4000-8000-000000000301'
        AND is_active
    ),
    'purchase_orders', (
      SELECT count(*)
      FROM public.inventory_purchase_orders
      WHERE restaurant_id = '90000000-0000-4000-8000-000000000301'
    ),
    'receipts', (
      SELECT count(*)
      FROM public.inventory_receipts
      WHERE restaurant_id = '90000000-0000-4000-8000-000000000301'
    ),
    'qc_checks', (
      SELECT count(*)
      FROM public.qc_checks
      WHERE restaurant_id = '90000000-0000-4000-8000-000000000301'
    ),
    'paid_orders', (
      SELECT count(*)
      FROM public.orders
      WHERE restaurant_id = '90000000-0000-4000-8000-000000000301'
        AND status = 'completed'
    ),
    'payments', (
      SELECT count(*)
      FROM public.payments
      WHERE restaurant_id = '90000000-0000-4000-8000-000000000301'
    ),
    'print_jobs', (
      SELECT count(*)
      FROM public.print_jobs
      WHERE restaurant_id = '90000000-0000-4000-8000-000000000301'
    ),
    'daily_closings', (
      SELECT count(*)
      FROM public.daily_closings
      WHERE restaurant_id = '90000000-0000-4000-8000-000000000301'
    )
  ) INTO v;

  IF (v->>'stores')::int <> 1
     OR (v->>'users')::int < 6
     OR (v->>'profiles')::int < 6
     OR (v->>'floors')::int < 3
     OR (v->>'printers')::int < 4
     OR (v->>'qr_tokens')::int < 3
     OR (v->>'public_menu')::int < 1
     OR (v->>'attendance_logs')::int < 2
     OR (v->>'inventory')::int < 1
     OR (v->>'purchase_orders')::int < 1
     OR (v->>'receipts')::int < 1
     OR (v->>'qc_checks')::int < 1
     OR (v->>'paid_orders')::int < 1
     OR (v->>'payments')::int < 1
     OR (v->>'print_jobs')::int < 2
     OR (v->>'daily_closings')::int < 1 THEN
    RAISE EXCEPTION 'PILOT_GATE3_FIXTURE_VERIFY_FAILED %', v;
  END IF;

  RAISE NOTICE 'PILOT_GATE3_FIXTURE_READY %', v;
END;
$verify$;

COMMIT;
