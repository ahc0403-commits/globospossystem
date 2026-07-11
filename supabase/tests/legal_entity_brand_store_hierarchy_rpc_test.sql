-- Executable RPC smoke for legal-entity assignment history. All fixtures and
-- mutations are rolled back.
--
-- Run against a fully migrated database:
--   psql "$DB_URL" -f supabase/tests/legal_entity_brand_store_hierarchy_rpc_test.sql

\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE _hierarchy_rpc_results (
  scenario text PRIMARY KEY,
  ok boolean NOT NULL,
  detail text
);

CREATE FUNCTION pg_temp.add_result(
  p_scenario text,
  p_ok boolean,
  p_detail text DEFAULT NULL
) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO _hierarchy_rpc_results (scenario, ok, detail)
  VALUES (p_scenario, p_ok, p_detail);
$$;

DO $smoke$
DECLARE
  v_actor public.users%ROWTYPE;
  v_store public.restaurants%ROWTYPE;
  v_source uuid := 'a5510000-0000-4000-8000-000000000001';
  v_destination uuid := 'a5510000-0000-4000-8000-000000000002';
  v_brand uuid;
  v_initial_history public.store_tax_entity_history%ROWTYPE;
  v_closed_history public.store_tax_entity_history%ROWTYPE;
  v_active_history public.store_tax_entity_history%ROWTYPE;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE role = 'super_admin' AND is_active
  ORDER BY created_at, id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'HIERARCHY_RPC_SMOKE_REQUIRES_ACTIVE_SUPER_ADMIN';
  END IF;

  SELECT id INTO v_brand
  FROM public.brands
  ORDER BY created_at, id
  LIMIT 1;

  IF v_brand IS NULL THEN
    RAISE EXCEPTION 'HIERARCHY_RPC_SMOKE_REQUIRES_BRAND';
  END IF;

  INSERT INTO public.tax_entity (
    id, tax_code, name, owner_type, einvoice_provider, data_source
  ) VALUES
    (v_source, 'RPC_HIERARCHY_SOURCE', 'RPC Hierarchy Source', 'external', 'meinvoice', 'VNPT_EPAY'),
    (v_destination, 'RPC_HIERARCHY_DEST', 'RPC Hierarchy Destination', 'external', 'meinvoice', 'VNPT_EPAY');

  INSERT INTO public.tax_entity_brands (tax_entity_id, brand_id, created_by)
  VALUES
    (v_source, v_brand, v_actor.auth_id),
    (v_destination, v_brand, v_actor.auth_id);

  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_actor.auth_id, 'role', 'authenticated')::text,
    true
  );

  v_store := public.admin_create_restaurant_v2(
    'Hierarchy RPC Smoke Store',
    'hierarchy-rpc-smoke-store',
    'standard',
    v_source,
    v_brand,
    'contract fixture',
    NULL,
    NULL
  );

  SELECT * INTO STRICT v_initial_history
  FROM public.store_tax_entity_history
  WHERE store_id = v_store.id AND effective_to IS NULL;

  PERFORM pg_temp.add_result(
    'create opens exactly one active history row',
    (SELECT count(*) = 1 FROM public.store_tax_entity_history WHERE store_id = v_store.id)
      AND v_initial_history.tax_entity_id = v_source
      AND v_initial_history.created_by = v_actor.id
      AND v_initial_history.reason = format(
        'admin_create_restaurant_v2;actor=%s;source=none;destination=%s;reason=initial_assignment',
        v_actor.id,
        v_source
      ),
    v_initial_history::text
  );

  PERFORM public.admin_update_restaurant_v2(
    v_store.id,
    v_store.name,
    v_store.slug,
    v_store.operation_mode,
    v_source,
    v_brand,
    v_store.address,
    v_store.per_person_charge,
    NULL
  );

  PERFORM pg_temp.add_result(
    'same-entity update is a history no-op',
    (SELECT count(*) = 1 FROM public.store_tax_entity_history WHERE store_id = v_store.id)
      AND EXISTS (
        SELECT 1
        FROM public.store_tax_entity_history
        WHERE id = v_initial_history.id
          AND effective_from = v_initial_history.effective_from
          AND effective_to IS NULL
          AND reason = v_initial_history.reason
          AND created_at = v_initial_history.created_at
          AND created_by = v_initial_history.created_by
      ),
    'initial period remains unchanged'
  );

  PERFORM public.admin_update_restaurant_v2(
    v_store.id,
    v_store.name,
    v_store.slug,
    v_store.operation_mode,
    v_destination,
    v_brand,
    v_store.address,
    v_store.per_person_charge,
    NULL
  );

  SELECT * INTO STRICT v_closed_history
  FROM public.store_tax_entity_history
  WHERE id = v_initial_history.id;

  SELECT * INTO STRICT v_active_history
  FROM public.store_tax_entity_history
  WHERE store_id = v_store.id AND effective_to IS NULL;

  PERFORM pg_temp.add_result(
    'reassignment closes the prior period without rewriting it',
    v_closed_history.tax_entity_id = v_source
      AND v_closed_history.effective_from = v_initial_history.effective_from
      AND v_closed_history.effective_to = v_active_history.effective_from
      AND v_closed_history.reason = v_initial_history.reason
      AND v_closed_history.created_at = v_initial_history.created_at
      AND v_closed_history.created_by = v_initial_history.created_by,
    v_closed_history::text
  );

  PERFORM pg_temp.add_result(
    'reassignment opens one actor-attributed destination period',
    (SELECT count(*) = 2 FROM public.store_tax_entity_history WHERE store_id = v_store.id)
      AND (SELECT count(*) = 1 FROM public.store_tax_entity_history WHERE store_id = v_store.id AND effective_to IS NULL)
      AND v_active_history.tax_entity_id = v_destination
      AND v_active_history.created_by = v_actor.id
      AND v_active_history.reason = format(
        'admin_update_restaurant_v2;actor=%s;source=%s;destination=%s;reason=legal_entity_reassignment',
        v_actor.id,
        v_source,
        v_destination
      )
      AND (SELECT tax_entity_id = v_destination FROM public.restaurants WHERE id = v_store.id),
    v_active_history::text
  );
END;
$smoke$;

DO $report$
DECLARE
  v_report text;
  v_failures integer;
BEGIN
  SELECT
    string_agg(
      (CASE WHEN ok THEN 'PASS ' ELSE 'FAIL ' END) || scenario
        || CASE WHEN ok THEN '' ELSE ' :: ' || COALESCE(detail, '') END,
      ' | ' ORDER BY scenario
    ),
    count(*) FILTER (WHERE NOT ok)
  INTO v_report, v_failures
  FROM _hierarchy_rpc_results;

  IF v_failures > 0 THEN
    RAISE EXCEPTION 'HIERARCHY_RPC_SMOKE fail=% >>> %', v_failures, v_report;
  END IF;

  RAISE NOTICE 'HIERARCHY_RPC_SMOKE fail=% >>> %', v_failures, v_report;
END;
$report$;

ROLLBACK;
