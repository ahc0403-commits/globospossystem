CREATE TABLE public.emergency_order_queue (
  id uuid PRIMARY KEY,
  workflow_version smallint NOT NULL DEFAULT 1
);

CREATE TABLE public.emergency_fulfillment_items (
  id uuid PRIMARY KEY,
  kitchen_started_quantity integer,
  excused_quantity integer
);

CREATE TABLE public.emergency_combo_component_items (
  id uuid PRIMARY KEY,
  kitchen_started_quantity integer,
  excused_quantity integer
);

CREATE TABLE public.emergency_floor_direct_items (
  id uuid PRIMARY KEY,
  excused_quantity integer
);

CREATE TABLE public.emergency_floor_ready_lots (
  source_kind text NOT NULL,
  source_id uuid NOT NULL,
  queue_id uuid NOT NULL,
  ready_sequence bigint NOT NULL,
  served_quantity integer NOT NULL DEFAULT 0,
  voided_quantity integer NOT NULL DEFAULT 0,
  ready_quantity integer NOT NULL
);

CREATE INDEX emergency_floor_ready_lots_queue_pending
  ON public.emergency_floor_ready_lots(queue_id, ready_sequence)
  WHERE served_quantity + voided_quantity < ready_quantity;
CREATE INDEX emergency_floor_ready_lots_line_pending
  ON public.emergency_floor_ready_lots(
    source_kind, source_id, ready_sequence
  ) WHERE served_quantity + voided_quantity < ready_quantity;

CREATE OR REPLACE FUNCTION public.emergency_enrich_start_ready_orders(
  p_orders jsonb
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $function$
DECLARE
  v_result jsonb := '[]'::jsonb;
  v_order jsonb;
  v_item jsonb;
  v_items jsonb;
  v_workflow smallint;
  v_started integer;
  v_excused integer;
  v_sequence bigint;
BEGIN
  IF COALESCE(jsonb_typeof(p_orders), 'null') <> 'array' THEN
    RETURN '[]'::jsonb;
  END IF;
  FOR v_order IN SELECT value FROM jsonb_array_elements(p_orders)
  LOOP
    SELECT queue.workflow_version INTO v_workflow
    FROM public.emergency_order_queue queue
    WHERE queue.id = NULLIF(v_order->>'queue_id', '')::uuid;
    v_workflow := COALESCE(v_workflow, 1);
    v_items := '[]'::jsonb;
    FOR v_item IN
      SELECT value FROM jsonb_array_elements(COALESCE(v_order->'items', '[]'))
    LOOP
      v_started := NULL;
      v_excused := 0;
      v_sequence := NULL;
      IF v_item->>'source_kind' = 'combo_component' THEN
        SELECT component.kitchen_started_quantity, component.excused_quantity
        INTO v_started, v_excused
        FROM public.emergency_combo_component_items component
        WHERE component.id = NULLIF(v_item->>'id', '')::uuid;
        SELECT min(lot.ready_sequence) INTO v_sequence
        FROM public.emergency_floor_ready_lots lot
        WHERE lot.source_kind = 'combo_component'
          AND lot.source_id = NULLIF(v_item->>'id', '')::uuid
          AND lot.served_quantity + lot.voided_quantity < lot.ready_quantity;
      ELSIF COALESCE(v_item->>'fulfillment_route', '') <> 'floor_direct' THEN
        SELECT item.kitchen_started_quantity, item.excused_quantity
        INTO v_started, v_excused
        FROM public.emergency_fulfillment_items item
        WHERE item.id = NULLIF(v_item->>'id', '')::uuid;
        SELECT min(lot.ready_sequence) INTO v_sequence
        FROM public.emergency_floor_ready_lots lot
        WHERE lot.source_kind = 'base'
          AND lot.source_id = NULLIF(v_item->>'id', '')::uuid
          AND lot.served_quantity + lot.voided_quantity < lot.ready_quantity;
      ELSE
        SELECT direct_item.excused_quantity INTO v_excused
        FROM public.emergency_floor_direct_items direct_item
        WHERE direct_item.id = NULLIF(v_item->>'id', '')::uuid;
      END IF;
      v_items := v_items || jsonb_build_array(v_item || jsonb_build_object(
        'workflow_version', v_workflow,
        'kitchen_started_quantity', COALESCE(
          v_started, (v_item->>'kitchen_done_quantity')::integer, 0
        ),
        'excused_quantity', COALESCE(v_excused, 0),
        'required_quantity', GREATEST(
          COALESCE((v_item->>'ordered_quantity')::integer, 0)
            - COALESCE(v_excused, 0),
          0
        ),
        'oldest_ready_sequence', v_sequence
      ));
    END LOOP;
    SELECT min(lot.ready_sequence) INTO v_sequence
    FROM public.emergency_floor_ready_lots lot
    WHERE lot.queue_id = NULLIF(v_order->>'queue_id', '')::uuid
      AND lot.served_quantity + lot.voided_quantity < lot.ready_quantity;
    v_result := v_result || jsonb_build_array(
      jsonb_set(v_order, '{items}', v_items, true) || jsonb_build_object(
        'workflow_version', v_workflow,
        'oldest_ready_sequence', v_sequence
      )
    );
  END LOOP;
  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.emergency_enrich_start_ready_orders(jsonb)
  FROM PUBLIC, anon, authenticated;

INSERT INTO public.emergency_order_queue(id, workflow_version) VALUES
  ('10000000-0000-0000-0000-000000000001', 2),
  ('10000000-0000-0000-0000-000000000002', 2);
INSERT INTO public.emergency_fulfillment_items(
  id, kitchen_started_quantity, excused_quantity
) VALUES ('20000000-0000-0000-0000-000000000001', 2, 1);
INSERT INTO public.emergency_combo_component_items(
  id, kitchen_started_quantity, excused_quantity
) VALUES ('30000000-0000-0000-0000-000000000001', 4, 2);
INSERT INTO public.emergency_floor_direct_items(id, excused_quantity)
VALUES ('40000000-0000-0000-0000-000000000001', 1);
INSERT INTO public.emergency_floor_ready_lots(
  source_kind, source_id, queue_id, ready_sequence,
  served_quantity, voided_quantity, ready_quantity
) VALUES
  (
    'base',
    '20000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    10, 1, 0, 3
  ),
  (
    'combo_component',
    '30000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    5, 0, 0, 2
  ),
  (
    'base',
    '20000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    1, 3, 0, 3
  );

CREATE TABLE public.kds_enrichment_expected(input jsonb, expected jsonb);
INSERT INTO public.kds_enrichment_expected(input)
VALUES (
  jsonb_build_array(
    jsonb_build_object(
      'queue_id', '10000000-0000-0000-0000-000000000001',
      'marker', 'first',
      'items', jsonb_build_array(
        jsonb_build_object(
          'id', '20000000-0000-0000-0000-000000000001',
          'source_kind', 'base',
          'fulfillment_route', 'kitchen_tray_floor',
          'ordered_quantity', 3,
          'kitchen_done_quantity', 1
        ),
        jsonb_build_object(
          'id', '30000000-0000-0000-0000-000000000001',
          'source_kind', 'combo_component',
          'fulfillment_route', 'kitchen_tray_floor',
          'ordered_quantity', 5,
          'kitchen_done_quantity', 2
        ),
        jsonb_build_object(
          'id', '40000000-0000-0000-0000-000000000001',
          'source_kind', 'base',
          'fulfillment_route', 'floor_direct',
          'ordered_quantity', 2,
          'kitchen_done_quantity', 0
        )
      )
    ),
    jsonb_build_object(
      'queue_id', '10000000-0000-0000-0000-000000000002',
      'marker', 'empty-items',
      'items', jsonb_build_array()
    ),
    jsonb_build_object(
      'queue_id', '10000000-0000-0000-0000-000000000099',
      'marker', 'missing-db-rows',
      'items', jsonb_build_array(
        jsonb_build_object(
          'id', '90000000-0000-0000-0000-000000000001',
          'source_kind', 'base',
          'ordered_quantity', 2,
          'kitchen_done_quantity', 1
        )
      )
    )
  )
);
UPDATE public.kds_enrichment_expected
SET expected = public.emergency_enrich_start_ready_orders(input);
