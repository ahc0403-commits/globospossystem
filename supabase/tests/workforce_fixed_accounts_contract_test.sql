-- Executable fixed-account and auth-less workforce behavior contract.
-- Run against a fully migrated disposable database only.
BEGIN;

CREATE TEMP TABLE _workforce_results (
  scenario text PRIMARY KEY,
  ok boolean NOT NULL,
  detail text NOT NULL
);

DO $contract$
DECLARE
  v_admin_auth uuid := '57100000-0000-4000-8000-000000000001';
  v_operator_auth uuid := '57100000-0000-4000-8000-000000000002';
  v_super_auth uuid := '57100000-0000-4000-8000-000000000003';
  v_photo_auth uuid := '57100000-0000-4000-8000-000000000004';
  v_store uuid := '57100000-0000-4000-8000-000000000010';
  v_other_store uuid := '57100000-0000-4000-8000-000000000020';
  v_brand uuid := '57100000-0000-4000-8000-000000000030';
  v_tax uuid := '57100000-0000-4000-8000-000000000040';
  v_company uuid := '57100000-0000-4000-8000-000000000050';
  v_brand_master uuid := '57100000-0000-4000-8000-000000000060';
  v_inventory_item uuid := '57100000-0000-4000-8000-000000000070';
  v_admin_id uuid;
  v_operator_id uuid;
  v_photo_id uuid;
  v_first public.store_employees%ROWTYPE;
  v_second public.store_employees%ROWTYPE;
  v_third public.store_employees%ROWTYPE;
  v_attendance public.attendance_logs%ROWTYPE;
  v_inventory public.inventory_transactions%ROWTYPE;
  v_blocked boolean;
  v_profile_count integer;
  v_profile_version bigint;
BEGIN
  INSERT INTO auth.users(id, email) VALUES
    (v_admin_auth, 'workforce.admin@globos.test'),
    (v_operator_auth, 'bt_ops1@globos.world'),
    (v_super_auth, 'andre@globos.world'),
    (v_photo_auth, 'photo_bm1@globos.world');
  INSERT INTO public.tax_entity(
    id, tax_code, name, owner_type, einvoice_provider, data_source
  ) VALUES (
    v_tax, 'WORKFORCE_CONTRACT', 'Workforce Contract Entity',
    'internal', 'meinvoice', 'VNPT_EPAY'
  );
  INSERT INTO public.companies(id, name)
  VALUES (v_company, 'Workforce Contract Company');
  INSERT INTO public.brand_master(id, company_id, name, type)
  VALUES (v_brand_master, v_company, 'Workforce Contract Master', 'internal');
  INSERT INTO public.brands(
    id, company_id, code, name, brand_master_id, suggested_tax_entity_id
  ) VALUES (
    v_brand, v_company, 'workforce_contract', 'Workforce Contract Brand',
    v_brand_master, v_tax
  );
  INSERT INTO public.tax_entity_brands(tax_entity_id, brand_id)
  VALUES (v_tax, v_brand);
  INSERT INTO public.restaurants(
    id, name, operation_mode, is_active, brand_id, tax_entity_id
  ) VALUES
    (v_store, 'Workforce Store', 'standard', true, v_brand, v_tax),
    (v_other_store, 'Other Workforce Store', 'standard', true, v_brand, v_tax);
  INSERT INTO public.users(
    auth_id, restaurant_id, primary_store_id, brand_id, role, full_name,
    is_active, account_type, fixed_account_code
  ) VALUES
    (v_admin_auth, v_store, v_store, v_brand, 'store_admin', 'Manager', true,
      'legacy_user', NULL),
    (v_operator_auth, v_store, v_store, v_brand, 'photo_objet_store_operator',
      'Shared Operator', true, 'store_operator', 'bt_ops1'),
    (v_super_auth, v_store, v_store, v_brand, 'super_admin', 'Andre', true,
      'master', 'andre'),
    (v_photo_auth, v_other_store, v_other_store, v_brand, 'photo_objet_master',
      'Photo BM 1', true, 'brand_manager', 'photo_bm1');
  SELECT id INTO v_admin_id FROM public.users WHERE auth_id = v_admin_auth;
  SELECT id INTO v_operator_id FROM public.users WHERE auth_id = v_operator_auth;
  SELECT id INTO v_photo_id FROM public.users WHERE auth_id = v_photo_auth;
  INSERT INTO public.user_store_access(
    user_id, store_id, is_primary, is_active, source_type
  ) VALUES
    (v_admin_id, v_store, true, true, 'direct'),
    (v_operator_id, v_store, true, true, 'direct'),
    (v_photo_id, v_other_store, true, true, 'direct');
  INSERT INTO public.inventory_items(id, restaurant_id, name, quantity, unit)
  VALUES (v_inventory_item, v_store, 'Contract Rice', 10, 'g');

  PERFORM set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_admin_auth, 'role', 'authenticated'
  )::text, true);

  PERFORM public.admin_configure_store_workforce(
    v_store, 'BT', 'store_managed', 1,
    '[
      {"account_code":"bt_pos1","account_type":"device_pos","role":"cashier","display_name":"BT POS 1","scope":"store"},
      {"account_code":"bt_kit1","account_type":"device_kitchen","role":"kitchen","display_name":"BT Kitchen 1","scope":"store"},
      {"account_code":"bt_ops1","account_type":"store_operator","role":"photo_objet_store_operator","display_name":"BT Operator 1","scope":"store"}
    ]'::jsonb
  );
  INSERT INTO _workforce_results VALUES (
    'wizard stores generic fixed-account requirements',
    (SELECT short_code = 'BT' FROM public.restaurants WHERE id = v_store)
      AND (SELECT count(*) = 3 FROM public.store_fixed_account_requirements WHERE store_id = v_store),
    'short code and three generic templates persisted'
  );

  v_blocked := false;
  BEGIN
    PERFORM public.admin_configure_store_workforce(
      v_store, 'BT', 'store_managed', 1,
      '[{"account_code":"bunsik_bm1","account_type":"brand_manager","role":"brand_admin","display_name":"Bunsik BM 1","scope":"brand"}]'::jsonb
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%BRAND_MANAGER_TEMPLATE_FORBIDDEN%';
  END;
  INSERT INTO _workforce_results VALUES (
    'store manager cannot create brand manager template', v_blocked,
    'elevated fixed-account template rejected'
  );

  PERFORM set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_super_auth, 'role', 'authenticated'
  )::text, true);
  PERFORM public.admin_configure_store_workforce(
    v_store, 'BT', 'store_managed', 1,
    '[
      {"account_code":"bunsik_bm1","account_type":"brand_manager","role":"brand_admin","display_name":"Bunsik BM 1","scope":"brand"},
      {"account_code":"bunsik_sm1","account_type":"store_manager","role":"store_admin","display_name":"Bunsik SM 1","scope":"store"},
      {"account_code":"bt_pos1","account_type":"device_pos","role":"cashier","display_name":"BT POS 1","scope":"store"},
      {"account_code":"bt_tab1","account_type":"device_tablet","role":"cashier","display_name":"BT Tablet 1","scope":"store"},
      {"account_code":"bt_kit1","account_type":"device_kitchen","role":"kitchen","display_name":"BT Kitchen 1","scope":"store"}
    ]'::jsonb
  );
  PERFORM public.admin_configure_store_workforce(
    v_other_store, 'NZ', 'brand_centralized', 2,
    '[
      {"account_code":"photo_bm1","account_type":"brand_manager","role":"photo_objet_master","display_name":"Photo BM 1","scope":"brand"},
      {"account_code":"photo_bm2","account_type":"brand_manager","role":"photo_objet_master","display_name":"Photo BM 2","scope":"brand"},
      {"account_code":"nz_ops1","account_type":"store_operator","role":"photo_objet_store_operator","display_name":"NZ Operator 1","scope":"store"}
    ]'::jsonb
  );
  INSERT INTO _workforce_results VALUES (
    'named management presets use fixed globos account codes',
    (SELECT fixed_account_code = 'andre' AND role = 'super_admin'
      FROM public.users WHERE auth_id = v_super_auth)
      AND (SELECT count(*) = 2 FROM public.store_fixed_account_requirements
        WHERE store_id = v_store AND account_code IN ('bunsik_bm1', 'bunsik_sm1'))
      AND (SELECT count(*) = 2 FROM public.store_fixed_account_requirements
        WHERE store_id = v_other_store AND account_code IN ('photo_bm1', 'photo_bm2'))
      AND NOT EXISTS (
        SELECT 1 FROM public.store_fixed_account_requirements
        WHERE store_id = v_other_store AND account_type = 'store_manager'
      ),
    'Andre, Bunsik and two centralized Photo managers match the naming contract'
  );

  PERFORM set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_photo_auth, 'role', 'authenticated'
  )::text, true);
  INSERT INTO _workforce_results VALUES (
    'centralized Photo manager inherits store manager authority',
    (public.require_admin_actor_for_restaurant(v_other_store)).id = v_photo_id
      AND public.workforce_can_manage_store(v_other_store),
    'Photo master can manage its accessible centralized store'
  );

  PERFORM set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_admin_auth, 'role', 'authenticated'
  )::text, true);

  v_first := public.create_store_employee(
    v_store, 'Employee One', 'part_timer', '0901', '1111', 'EMPLOYEE ONE'
  );
  v_second := public.create_store_employee(
    v_store, 'Employee Two', 'part_timer', '0902', '2222', 'EMPLOYEE TWO'
  );
  PERFORM public.deactivate_store_employee(v_store, v_first.id);
  v_third := public.create_store_employee(
    v_store, 'Employee Three', 'part_timer', '0903', '3333', 'EMPLOYEE THREE'
  );
  INSERT INTO _workforce_results VALUES (
    'employee numbers are monotonic and never reused',
    v_first.employee_number = 'BT1'
      AND v_second.employee_number = 'BT2'
      AND v_third.employee_number = 'BT3'
      AND (SELECT NOT is_active FROM public.store_employees WHERE id = v_first.id),
    v_first.employee_number || ',' || v_second.employee_number || ',' || v_third.employee_number
  );

  v_blocked := false;
  BEGIN
    PERFORM public.create_store_employee(
      v_other_store, 'Cross Tenant', 'part_timer', NULL, NULL, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%WORKFORCE_MANAGEMENT_FORBIDDEN%';
  END;
  INSERT INTO _workforce_results VALUES (
    'employee management is tenant isolated', v_blocked,
    'store manager cross-store create rejected'
  );

  PERFORM set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_operator_auth, 'role', 'authenticated'
  )::text, true);
  v_attendance := public.record_employee_attendance(v_store, 'bt2', 'clock_in');
  INSERT INTO _workforce_results VALUES (
    'shared operator records attendance by employee number only',
    v_attendance.employee_id = v_second.id
      AND v_attendance.user_id IS NULL
      AND v_attendance.recorded_by_user_id = v_operator_id,
    'employee and fixed operator identities are separate'
  );

  v_inventory := public.record_employee_inventory_adjustment(
    v_store, 'BT2', v_inventory_item, 'restock', 5, 'contract'
  );
  INSERT INTO _workforce_results VALUES (
    'limited inventory audit stores actual employee identity',
    v_inventory.performed_by_employee_id = v_second.id
      AND v_inventory.created_by = v_operator_auth
      AND (SELECT current_stock = 5 FROM public.inventory_items WHERE id = v_inventory_item),
    'employee id and fixed Auth actor id both recorded'
  );

  SELECT payment_profile_version INTO v_profile_version
  FROM public.store_employees WHERE id = v_second.id;
  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('role', 'service_role')::text, true);
  SELECT count(*) INTO v_profile_count
  FROM public.office_list_employee_payment_profiles(0, 500) p
  WHERE p.pos_employee_id = v_second.id
    AND p.pos_store_id = v_store
    AND p.phone = '0902'
    AND p.bank_account_number = '2222'
    AND p.bank_account_holder = 'EMPLOYEE TWO'
    AND p.profile_version = v_profile_version;
  INSERT INTO _workforce_results VALUES (
    'Office export is allowlisted and versioned', v_profile_count = 1,
    'only payment profile fields returned by RPC'
  );

  INSERT INTO _workforce_results VALUES (
    'Office export contains no identity or attendance columns',
    NOT EXISTS (
      SELECT 1 FROM information_schema.parameters
      WHERE specific_schema = 'public'
        AND specific_name LIKE 'office_list_employee_payment_profiles_%'
        AND parameter_mode IN ('OUT', 'INOUT')
        AND parameter_name IN ('full_name', 'employment_role', 'logged_at', 'attendance_type')
    ),
    'forbidden columns absent from return contract'
  );
END;
$contract$;

DO $$
DECLARE
  v_failed text;
BEGIN
  SELECT string_agg(scenario || ': ' || detail, E'\n' ORDER BY scenario)
  INTO v_failed FROM _workforce_results WHERE NOT ok;
  IF v_failed IS NOT NULL THEN
    RAISE EXCEPTION E'WORKFORCE_CONTRACT_FAILED:\n%', v_failed;
  END IF;
END;
$$;

TABLE _workforce_results;
ROLLBACK;
