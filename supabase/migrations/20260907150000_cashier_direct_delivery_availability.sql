-- Cashiers can pause only new direct-delivery intake from the POS home screen.
-- Existing requests and approved fulfillment tickets remain operational.
-- production-gate: self-verifying

BEGIN;

CREATE OR REPLACE FUNCTION public.direct_order_staff_get_availability(
  p_store_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_storefront public.direct_order_storefronts%ROWTYPE;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );

  SELECT * INTO v_storefront
  FROM public.direct_order_storefronts storefront
  WHERE storefront.restaurant_id = p_store_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'configured', false,
      'enabled', false,
      'paused', false,
      'updated_at', NULL
    );
  END IF;

  RETURN jsonb_build_object(
    'configured', true,
    'enabled', v_storefront.is_enabled,
    'paused', v_storefront.is_paused,
    'updated_at', v_storefront.updated_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_staff_get_availability(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_get_availability(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_order_staff_set_paused(
  p_store_id uuid,
  p_is_paused boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_storefront public.direct_order_storefronts%ROWTYPE;
  v_previous boolean;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );

  IF p_is_paused IS NULL THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_INPUT_INVALID';
  END IF;

  SELECT * INTO v_storefront
  FROM public.direct_order_storefronts storefront
  WHERE storefront.restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND OR NOT v_storefront.is_enabled THEN
    RAISE EXCEPTION 'DIRECT_ORDER_STOREFRONT_DISABLED';
  END IF;

  v_previous := v_storefront.is_paused;
  IF v_previous IS DISTINCT FROM p_is_paused THEN
    UPDATE public.direct_order_storefronts
    SET is_paused = p_is_paused,
        updated_by = (SELECT auth.uid()),
        updated_at = now()
    WHERE restaurant_id = p_store_id
    RETURNING * INTO v_storefront;

    INSERT INTO public.audit_logs(
      actor_id, action, entity_type, entity_id, details
    ) VALUES (
      (SELECT auth.uid()),
      'direct_order_intake_availability_changed',
      'direct_order_storefronts',
      p_store_id,
      jsonb_build_object(
        'store_id', p_store_id,
        'previous_paused', v_previous,
        'paused', v_storefront.is_paused,
        'source', 'cashier_main'
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'configured', true,
    'enabled', v_storefront.is_enabled,
    'paused', v_storefront.is_paused,
    'updated_at', v_storefront.updated_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_staff_set_paused(uuid, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_set_paused(uuid, boolean)
  TO authenticated, service_role;

-- The original pilot treated pause as a full stop and also blocked quote and
-- approval. Operational CLOSED now means no new intake, so retain the submit
-- guard while allowing already-submitted customers to finish their flow.
DO $patch_existing_requests$
DECLARE
  v_quote regprocedure := to_regprocedure(
    'public.direct_order_staff_quote(uuid,uuid,numeric,text)'
  );
  v_approve regprocedure := to_regprocedure(
    'public.direct_order_approve_payment(uuid,uuid,numeric,text)'
  );
  v_submit regprocedure := to_regprocedure(
    'public.direct_order_public_submit(uuid,text,uuid,jsonb)'
  );
  v_definition text;
  v_guard constant text := E'\n    AND storefront.is_paused = false';
  v_occurrences integer;
BEGIN
  IF v_quote IS NULL OR v_approve IS NULL OR v_submit IS NULL THEN
    RAISE EXCEPTION
      'CASHIER_DELIVERY_AVAILABILITY_MIGRATION_FAILED: required function missing';
  END IF;

  SELECT pg_get_functiondef(v_quote::oid) INTO v_definition;
  v_occurrences := (
    length(v_definition) - length(replace(v_definition, v_guard, ''))
  ) / length(v_guard);
  IF v_occurrences <> 1 THEN
    RAISE EXCEPTION
      'CASHIER_DELIVERY_AVAILABILITY_MIGRATION_FAILED: quote pause guard count %',
      v_occurrences;
  END IF;
  EXECUTE replace(v_definition, v_guard, '');

  SELECT pg_get_functiondef(v_approve::oid) INTO v_definition;
  v_occurrences := (
    length(v_definition) - length(replace(v_definition, v_guard, ''))
  ) / length(v_guard);
  IF v_occurrences <> 1 THEN
    RAISE EXCEPTION
      'CASHIER_DELIVERY_AVAILABILITY_MIGRATION_FAILED: approval pause guard count %',
      v_occurrences;
  END IF;
  EXECUTE replace(v_definition, v_guard, '');

  SELECT pg_get_functiondef(v_quote::oid) INTO v_definition;
  IF position('storefront.is_paused' IN v_definition) > 0 THEN
    RAISE EXCEPTION
      'CASHIER_DELIVERY_AVAILABILITY_MIGRATION_FAILED: quote still blocks pause';
  END IF;

  SELECT pg_get_functiondef(v_approve::oid) INTO v_definition;
  IF position('storefront.is_paused' IN v_definition) > 0 THEN
    RAISE EXCEPTION
      'CASHIER_DELIVERY_AVAILABILITY_MIGRATION_FAILED: approval still blocks pause';
  END IF;

  SELECT pg_get_functiondef(v_submit::oid) INTO v_definition;
  IF position('v_storefront.is_paused' IN v_definition) = 0 THEN
    RAISE EXCEPTION
      'CASHIER_DELIVERY_AVAILABILITY_MIGRATION_FAILED: submit pause guard missing';
  END IF;
END;
$patch_existing_requests$;

DO $verify$
BEGIN
  IF to_regprocedure(
       'public.direct_order_staff_get_availability(uuid)'
     ) IS NULL
     OR to_regprocedure(
       'public.direct_order_staff_set_paused(uuid,boolean)'
     ) IS NULL THEN
    RAISE EXCEPTION
      'CASHIER_DELIVERY_AVAILABILITY_MIGRATION_FAILED: RPC missing';
  END IF;

  IF has_function_privilege(
       'anon',
       'public.direct_order_staff_get_availability(uuid)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'anon',
       'public.direct_order_staff_set_paused(uuid,boolean)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.direct_order_staff_get_availability(uuid)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.direct_order_staff_set_paused(uuid,boolean)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION
      'CASHIER_DELIVERY_AVAILABILITY_MIGRATION_FAILED: privilege drift';
  END IF;
END;
$verify$;

COMMIT;
