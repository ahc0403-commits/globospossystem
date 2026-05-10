BEGIN;

-- Assumes the latest WeTax read-scope migration has already been applied.
-- This smoke test creates a temporary fixture, verifies RLS behavior, then rolls back.

DO $$
BEGIN
  INSERT INTO auth.users (
    instance_id,
    id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at
  )
  VALUES
    (
      '00000000-0000-0000-0000-000000000000',
      '11111111-1111-1111-1111-111111111111',
      'authenticated',
      'authenticated',
      'wetax-store-admin@example.com',
      '',
      now(),
      '{}'::jsonb,
      '{}'::jsonb,
      now(),
      now()
    ),
    (
      '00000000-0000-0000-0000-000000000000',
      '22222222-2222-2222-2222-222222222222',
      'authenticated',
      'authenticated',
      'wetax-brand-admin@example.com',
      '',
      now(),
      '{}'::jsonb,
      '{}'::jsonb,
      now(),
      now()
    );

  INSERT INTO public.companies (id, name, created_at)
  VALUES ('30000000-0000-0000-0000-000000000000', 'WeTax Smoke Co', now());

  INSERT INTO public.brand_master (
    id,
    company_id,
    name,
    type,
    created_at,
    updated_at
  )
  VALUES (
    '40000000-0000-0000-0000-000000000000',
    '30000000-0000-0000-0000-000000000000',
    'WeTax Smoke Master',
    'internal',
    now(),
    now()
  );

  INSERT INTO public.tax_entity (
    id,
    tax_code,
    name,
    owner_type,
    einvoice_provider,
    data_source,
    created_at,
    updated_at
  )
  VALUES
    (
      '50000000-0000-0000-0000-000000000001',
      'TAX-SMOKE-1',
      'Shared Tax Entity',
      'internal',
      'wetax',
      'VNPT_EPAY',
      now(),
      now()
    ),
    (
      '50000000-0000-0000-0000-000000000002',
      'TAX-SMOKE-2',
      'Isolated Tax Entity',
      'internal',
      'wetax',
      'VNPT_EPAY',
      now(),
      now()
    );

  INSERT INTO public.brands (
    id,
    company_id,
    code,
    name,
    created_at,
    brand_master_id,
    service_charge_enabled,
    service_charge_rate
  )
  VALUES (
    '60000000-0000-0000-0000-000000000000',
    '30000000-0000-0000-0000-000000000000',
    'SMOKE',
    'Smoke Brand',
    now(),
    '40000000-0000-0000-0000-000000000000',
    false,
    0
  );

  INSERT INTO public.einvoice_shop (
    id,
    tax_entity_id,
    provider_shop_code,
    shop_name,
    templates,
    created_at,
    updated_at
  )
  VALUES
    (
      '70000000-0000-0000-0000-000000000001',
      '50000000-0000-0000-0000-000000000001',
      'SHOP-A',
      'Shop A',
      '[{"serial_no":"C26MTT","status_code":"1"}]'::jsonb,
      now(),
      now()
    ),
    (
      '70000000-0000-0000-0000-000000000002',
      '50000000-0000-0000-0000-000000000002',
      'SHOP-C',
      'Shop C',
      '[{"serial_no":"C26MTT","status_code":"1"}]'::jsonb,
      now(),
      now()
    );

  INSERT INTO public.restaurants (
    id,
    name,
    address,
    slug,
    operation_mode,
    is_active,
    created_at,
    brand_id,
    store_type,
    tax_entity_id,
    vat_pricing_mode
  )
  VALUES
    (
      '80000000-0000-0000-0000-00000000000a',
      'Store A',
      'A Street',
      'store-a',
      'standard',
      true,
      now(),
      '60000000-0000-0000-0000-000000000000',
      'direct',
      '50000000-0000-0000-0000-000000000001',
      'exclusive'
    ),
    (
      '80000000-0000-0000-0000-00000000000b',
      'Store B',
      'B Street',
      'store-b',
      'standard',
      true,
      now(),
      '60000000-0000-0000-0000-000000000000',
      'direct',
      '50000000-0000-0000-0000-000000000001',
      'exclusive'
    ),
    (
      '80000000-0000-0000-0000-00000000000c',
      'Store C',
      'C Street',
      'store-c',
      'standard',
      true,
      now(),
      '60000000-0000-0000-0000-000000000000',
      'direct',
      '50000000-0000-0000-0000-000000000002',
      'exclusive'
    );

  INSERT INTO public.users (
    id,
    auth_id,
    restaurant_id,
    role,
    full_name,
    is_active,
    created_at,
    extra_permissions,
    brand_id,
    primary_store_id
  )
  VALUES
    (
      '90000000-0000-0000-0000-000000000001',
      '11111111-1111-1111-1111-111111111111',
      '80000000-0000-0000-0000-00000000000a',
      'store_admin',
      'Store Admin',
      true,
      now(),
      '{}'::text[],
      '60000000-0000-0000-0000-000000000000',
      '80000000-0000-0000-0000-00000000000a'
    ),
    (
      '90000000-0000-0000-0000-000000000002',
      '22222222-2222-2222-2222-222222222222',
      '80000000-0000-0000-0000-00000000000a',
      'brand_admin',
      'Brand Admin',
      true,
      now(),
      '{}'::text[],
      '60000000-0000-0000-0000-000000000000',
      '80000000-0000-0000-0000-00000000000a'
    );

  INSERT INTO public.user_store_access (
    id,
    user_id,
    store_id,
    is_primary,
    is_active,
    source_type,
    created_at,
    updated_at
  )
  VALUES
    (
      'a0000000-0000-0000-0000-000000000001',
      '90000000-0000-0000-0000-000000000001',
      '80000000-0000-0000-0000-00000000000a',
      true,
      true,
      'direct',
      now(),
      now()
    ),
    (
      'a0000000-0000-0000-0000-000000000002',
      '90000000-0000-0000-0000-000000000002',
      '80000000-0000-0000-0000-00000000000a',
      true,
      true,
      'direct',
      now(),
      now()
    ),
    (
      'a0000000-0000-0000-0000-000000000003',
      '90000000-0000-0000-0000-000000000002',
      '80000000-0000-0000-0000-00000000000b',
      false,
      true,
      'direct',
      now(),
      now()
    );

  INSERT INTO public.orders (
    id,
    restaurant_id,
    sales_channel,
    status,
    created_at,
    updated_at
  )
  VALUES
    (
      'b0000000-0000-0000-0000-00000000000a',
      '80000000-0000-0000-0000-00000000000a',
      'dine_in',
      'completed',
      now(),
      now()
    ),
    (
      'b0000000-0000-0000-0000-00000000000b',
      '80000000-0000-0000-0000-00000000000b',
      'dine_in',
      'completed',
      now(),
      now()
    ),
    (
      'b0000000-0000-0000-0000-00000000000c',
      '80000000-0000-0000-0000-00000000000c',
      'dine_in',
      'completed',
      now(),
      now()
    );

  INSERT INTO public.einvoice_jobs (
    id,
    ref_id,
    order_id,
    tax_entity_id,
    einvoice_shop_id,
    redinvoice_requested,
    status,
    send_order_payload,
    created_at,
    updated_at
  )
  VALUES
    (
      'c0000000-0000-0000-0000-00000000000a',
      '018f0f10-1111-7111-8111-11111111111a',
      'b0000000-0000-0000-0000-00000000000a',
      '50000000-0000-0000-0000-000000000001',
      '70000000-0000-0000-0000-000000000001',
      false,
      'reported',
      '{"ref_id":"018f0f10-1111-7111-8111-11111111111a"}'::jsonb,
      now(),
      now()
    ),
    (
      'c0000000-0000-0000-0000-00000000000b',
      '018f0f10-2222-7222-8222-22222222222b',
      'b0000000-0000-0000-0000-00000000000b',
      '50000000-0000-0000-0000-000000000001',
      '70000000-0000-0000-0000-000000000001',
      false,
      'reported',
      '{"ref_id":"018f0f10-2222-7222-8222-22222222222b"}'::jsonb,
      now(),
      now()
    ),
    (
      'c0000000-0000-0000-0000-00000000000c',
      '018f0f10-3333-7333-8333-33333333333c',
      'b0000000-0000-0000-0000-00000000000c',
      '50000000-0000-0000-0000-000000000002',
      '70000000-0000-0000-0000-000000000002',
      false,
      'reported',
      '{"ref_id":"018f0f10-3333-7333-8333-33333333333c"}'::jsonb,
      now(),
      now()
    );

  INSERT INTO public.einvoice_events (
    id,
    job_id,
    event_type,
    description,
    created_at
  )
  VALUES
    (
      'd0000000-0000-0000-0000-00000000000a',
      'c0000000-0000-0000-0000-00000000000a',
      'poll_result',
      'Store A event',
      now()
    ),
    (
      'd0000000-0000-0000-0000-00000000000b',
      'c0000000-0000-0000-0000-00000000000b',
      'poll_result',
      'Store B event',
      now()
    );

  INSERT INTO public.b2b_buyer_cache (
    store_id,
    buyer_tax_code,
    tax_company_name,
    receiver_email,
    tax_entity_id,
    first_used_at,
    last_used_at,
    use_count,
    email_bounce_count
  )
  VALUES
    (
      '80000000-0000-0000-0000-00000000000a',
      'BUYER-A',
      'Buyer A',
      'a@example.com',
      '50000000-0000-0000-0000-000000000001',
      now(),
      now(),
      1,
      0
    ),
    (
      '80000000-0000-0000-0000-00000000000b',
      'BUYER-B',
      'Buyer B',
      'b@example.com',
      '50000000-0000-0000-0000-000000000001',
      now(),
      now(),
      1,
      0
    );
END;
$$;

DO $$
DECLARE
  v_count integer;
BEGIN
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE 'SET LOCAL request.jwt.claim.sub = ''11111111-1111-1111-1111-111111111111''';

  SELECT count(*) INTO v_count FROM public.einvoice_jobs;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'store_admin should read exactly 1 einvoice_job, got %', v_count;
  END IF;

  SELECT count(*) INTO v_count FROM public.einvoice_events;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'store_admin should read exactly 1 einvoice_event, got %', v_count;
  END IF;

  SELECT count(*) INTO v_count FROM public.b2b_buyer_cache;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'store_admin should read exactly 1 buyer cache row, got %', v_count;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.einvoice_jobs
    WHERE order_id = 'b0000000-0000-0000-0000-00000000000b'
  ) THEN
    RAISE EXCEPTION 'store_admin unexpectedly read sibling-store einvoice_job via shared tax_entity';
  END IF;
END;
$$;

DO $$
DECLARE
  v_count integer;
BEGIN
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE 'SET LOCAL request.jwt.claim.sub = ''22222222-2222-2222-2222-222222222222''';

  SELECT count(*) INTO v_count FROM public.einvoice_jobs;
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'brand_admin should read 2 accessible-store einvoice_jobs, got %', v_count;
  END IF;

  SELECT count(*) INTO v_count FROM public.einvoice_events;
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'brand_admin should read 2 accessible-store einvoice_events, got %', v_count;
  END IF;

  SELECT count(*) INTO v_count FROM public.b2b_buyer_cache;
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'brand_admin should read 2 accessible-store buyer cache rows, got %', v_count;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.einvoice_jobs
    WHERE order_id = 'b0000000-0000-0000-0000-00000000000c'
  ) THEN
    RAISE EXCEPTION 'brand_admin unexpectedly read non-accessible store C einvoice_job';
  END IF;
END;
$$;

ROLLBACK;
