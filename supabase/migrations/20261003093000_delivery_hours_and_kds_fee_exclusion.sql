-- New intake: daily 11:00 <= Vietnam time < 22:00. Existing orders can finish.
-- Fees remain financial lines, never kitchen/tray work.
-- production-gate: self-verifying
BEGIN;

ALTER TABLE public.direct_order_storefronts
  DROP CONSTRAINT direct_order_storefronts_window_valid,
  ALTER COLUMN ordering_starts_at SET DEFAULT '11:00',
  ALTER COLUMN ordering_cutoff_at SET DEFAULT '22:00',
  ALTER COLUMN ordering_hours_enforced SET DEFAULT true;
ALTER TABLE public.direct_order_storefronts
  ADD CONSTRAINT direct_order_storefronts_window_valid CHECK (
    ordering_starts_at < ordering_cutoff_at AND ordering_cutoff_at <= '22:00'::time
  );
UPDATE public.direct_order_storefronts
SET ordering_starts_at = '11:00', ordering_cutoff_at = '22:00',
    ordering_hours_enforced = true, updated_at = now();
COMMENT ON COLUMN public.direct_order_storefronts.ordering_hours_enforced IS
  'Enforces the Vietnam local-time window for new intake only; existing orders remain operational.';

CREATE OR REPLACE FUNCTION public.direct_order_is_within_hours(
  p_starts_at time, p_cutoff_at time, p_observed_at timestamptz DEFAULT now()
) RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog
AS $$
  SELECT (p_observed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::time >= p_starts_at
     AND (p_observed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::time < p_cutoff_at;
$$;
REVOKE ALL ON FUNCTION public.direct_order_is_within_hours(time,time,timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_is_within_hours(time,time,timestamptz)
  TO service_role;

-- Patch only exact anchors, preserving all payment, VAT, pickup and stock logic.
CREATE FUNCTION pg_temp.delivery_hours_patch(
  p_signature text, p_old text, p_new text, p_expected integer DEFAULT 1
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_definition text; v_count integer;
BEGIN
  SELECT pg_get_functiondef(p_signature::regprocedure) INTO v_definition;
  v_count := (length(v_definition)-length(replace(v_definition,p_old,''))) / length(p_old);
  IF v_count <> p_expected THEN
    RAISE EXCEPTION 'DELIVERY_HOURS_ANCHOR_DRIFT: %, count %',p_signature,v_count;
  END IF;
  EXECUTE replace(v_definition,p_old,p_new);
END;
$$;

SELECT pg_temp.delivery_hours_patch('public.emergency_sync_order_item()',
  $old$NEW.item_type IN ('wet_tissue_charge', 'buffet_cover_charge')$old$,
  $new$NEW.item_type IN ('wet_tissue_charge', 'buffet_cover_charge', 'service_charge')$new$);

-- Older production releases may lack the cashier availability RPCs. Install
-- their current-main contracts before applying the scheduled-closure anchors.
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

-- Keep the legacy public/staff JSON contracts: paused now includes auto-close.
SELECT pg_temp.delivery_hours_patch('public.direct_order_public_storefront(text)',
  $old$'paused', storefront.is_paused,$old$,
  $new$'paused', storefront.is_paused OR (
      storefront.ordering_hours_enforced AND NOT public.direct_order_is_within_hours(
        storefront.ordering_starts_at, storefront.ordering_cutoff_at
      )
    ),$new$);
SELECT pg_temp.delivery_hours_patch('public.direct_order_staff_get_availability(uuid)',
  $old$'paused', v_storefront.is_paused,$old$,
  $new$'paused', v_storefront.is_paused OR (
      v_storefront.ordering_hours_enforced AND NOT public.direct_order_is_within_hours(
        v_storefront.ordering_starts_at, v_storefront.ordering_cutoff_at
      )
    ),$new$);
SELECT pg_temp.delivery_hours_patch('public.direct_order_staff_set_paused(uuid,boolean)',
  $old$  RETURN jsonb_build_object(
    'configured', true,
    'enabled', v_storefront.is_enabled,
    'paused', v_storefront.is_paused,
    'updated_at', v_storefront.updated_at
  );$old$,
  $new$  RETURN public.direct_order_staff_get_availability(p_store_id);$new$);

-- Admin saves (including old clients) must not reset the requested schedule.
SELECT pg_temp.delivery_hours_patch(
  'public.direct_order_admin_upsert_storefront(uuid,text,boolean,boolean,time,time,numeric,integer,numeric,numeric,text,text,text,text,numeric,integer,integer,boolean)',
  $old$COALESCE(p_ordering_starts_at, '10:00'::time)$old$, $new$'11:00'::time$new$);
SELECT pg_temp.delivery_hours_patch(
  'public.direct_order_admin_upsert_storefront(uuid,text,boolean,boolean,time,time,numeric,integer,numeric,numeric,text,text,text,text,numeric,integer,integer,boolean)',
  $old$COALESCE(p_ordering_cutoff_at, '21:30'::time)$old$, $new$'22:00'::time$new$);

SELECT pg_temp.delivery_hours_patch('public.direct_order_approve_payment(uuid,uuid,numeric,text)',
  $old$  IF v_storefront.ordering_hours_enforced
     AND v_local_time >= LEAST(v_storefront.ordering_cutoff_at, '21:30'::time) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_APPROVAL_CUTOFF';
  END IF;$old$,
  $new$  -- The intake window never blocks review of an already submitted payment.$new$);
-- Some historical/current production approval definitions retain this guard.
DO $approval_pause$
DECLARE v_definition text; v_guard text := E'\n    AND storefront.is_paused = false'; v_signature text;
BEGIN
  FOREACH v_signature IN ARRAY ARRAY[
    'public.direct_order_staff_quote(uuid,uuid,numeric,text)',
    'public.direct_order_approve_payment(uuid,uuid,numeric,text)'
  ] LOOP
  SELECT pg_get_functiondef(v_signature::regprocedure)
    INTO v_definition;
  IF (length(v_definition)-length(replace(v_definition,v_guard,''))) / length(v_guard) > 1 THEN
    RAISE EXCEPTION 'DELIVERY_HOURS_APPROVAL_PAUSE_DRIFT';
  END IF;
  EXECUTE replace(v_definition,v_guard,'');
  END LOOP;
END;
$approval_pause$;

-- A versioned staff RPC explains scheduled closure without breaking old clients.
CREATE OR REPLACE FUNCTION public.direct_order_staff_get_availability_v2(p_store_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE v_result jsonb; v_hours_open boolean;
BEGIN
  v_result := public.direct_order_staff_get_availability(p_store_id);
  SELECT NOT storefront.ordering_hours_enforced OR public.direct_order_is_within_hours(
    storefront.ordering_starts_at, storefront.ordering_cutoff_at
  ) INTO v_hours_open
  FROM public.direct_order_storefronts storefront WHERE restaurant_id = p_store_id;
  RETURN v_result || jsonb_build_object('hours_open',COALESCE(v_hours_open,false));
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_staff_get_availability_v2(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_get_availability_v2(uuid) TO authenticated, service_role;

-- Retire only erroneous work ledgers; retain financial rows and progress history.
UPDATE public.emergency_fulfillment_items fulfillment
SET is_cancelled = true, updated_at = now()
FROM public.order_items item
WHERE item.id = fulfillment.order_item_id AND item.item_type = 'service_charge'
  AND fulfillment.is_cancelled = false;

DO $verify$
DECLARE v_submit text; v_sync text; v_approve text;
BEGIN
  SELECT pg_get_functiondef('public.direct_order_public_submit(uuid,text,uuid,jsonb)'::regprocedure) INTO v_submit;
  SELECT pg_get_functiondef('public.emergency_sync_order_item()'::regprocedure) INTO v_sync;
  SELECT pg_get_functiondef('public.direct_order_approve_payment(uuid,uuid,numeric,text)'::regprocedure) INTO v_approve;
  IF position('v_storefront.ordering_hours_enforced' IN v_submit)=0
     OR position('v_local_time < v_storefront.ordering_starts_at' IN v_submit)=0
     OR position('v_local_time >= v_storefront.ordering_cutoff_at' IN v_submit)=0
     OR position('''service_charge''' IN v_sync)=0
     OR position('DIRECT_ORDER_APPROVAL_CUTOFF' IN v_approve)>0
     OR position('storefront.is_paused = false' IN v_approve)>0
     OR position('storefront.is_paused = false' IN pg_get_functiondef(
       'public.direct_order_staff_quote(uuid,uuid,numeric,text)'::regprocedure))>0
     OR EXISTS(SELECT 1 FROM public.direct_order_storefronts WHERE
       ordering_starts_at <> '11:00' OR ordering_cutoff_at <> '22:00' OR NOT ordering_hours_enforced)
     OR EXISTS(SELECT 1 FROM public.emergency_fulfillment_items f JOIN public.order_items i
       ON i.id=f.order_item_id WHERE i.item_type='service_charge' AND NOT f.is_cancelled)
     OR has_function_privilege('anon','public.direct_order_staff_get_availability_v2(uuid)','EXECUTE')
     OR NOT has_function_privilege('authenticated','public.direct_order_staff_get_availability_v2(uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'DELIVERY_HOURS_AND_FEE_EXCLUSION_VERIFICATION_FAILED';
  END IF;
END;
$verify$;
COMMIT;
