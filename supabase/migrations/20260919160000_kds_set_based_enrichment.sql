-- KDS snapshot enrichment migration 20260919160000 must scale with a set of tickets, not issue queries
-- once per order and once or twice per item.
-- production-gate: self-verifying

BEGIN;

SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';

DO $preflight$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure(
       'public.emergency_enrich_start_ready_orders(jsonb)'
     ) IS NULL
     OR to_regclass('public.emergency_order_queue') IS NULL
     OR to_regclass('public.emergency_fulfillment_items') IS NULL
     OR to_regclass('public.emergency_combo_component_items') IS NULL
     OR to_regclass('public.emergency_floor_direct_items') IS NULL
     OR to_regclass('public.emergency_floor_ready_lots') IS NULL THEN
    RAISE EXCEPTION 'KDS_SET_ENRICHMENT_PREREQUISITES_MISSING';
  END IF;
  IF to_regprocedure(
       'public.emergency_enrich_start_ready_orders_pre_500_scale(jsonb)'
     ) IS NOT NULL THEN
    RAISE EXCEPTION 'KDS_SET_ENRICHMENT_BACKUP_ALREADY_EXISTS';
  END IF;
  SELECT pg_get_functiondef(
    'public.emergency_enrich_start_ready_orders(jsonb)'::regprocedure
  ) INTO v_definition;
  IF position('emergency_floor_ready_lots' IN v_definition) = 0
     OR position('workflow_version' IN v_definition) = 0
     OR position('excused_quantity' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'KDS_SET_ENRICHMENT_UNEXPECTED_PREDECESSOR';
  END IF;
END;
$preflight$;

ALTER FUNCTION public.emergency_enrich_start_ready_orders(jsonb)
  RENAME TO emergency_enrich_start_ready_orders_pre_500_scale;
REVOKE ALL ON FUNCTION
  public.emergency_enrich_start_ready_orders_pre_500_scale(jsonb)
  FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.emergency_enrich_start_ready_orders(
  p_orders jsonb
) RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $function$
  WITH parsed_orders AS MATERIALIZED (
    SELECT
      source_order.value AS order_json,
      source_order.ordinality AS order_ordinal,
      NULLIF(source_order.value->>'queue_id', '')::uuid AS queue_id
    FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(p_orders) = 'array' THEN p_orders
        ELSE '[]'::jsonb
      END
    ) WITH ORDINALITY AS source_order(value, ordinality)
  ),
  order_context AS MATERIALIZED (
    SELECT
      source.order_json,
      source.order_ordinal,
      source.queue_id,
      COALESCE(queue.workflow_version, 1)::smallint AS workflow_version
    FROM parsed_orders source
    LEFT JOIN public.emergency_order_queue queue
      ON queue.id = source.queue_id
  ),
  parsed_items AS MATERIALIZED (
    SELECT
      source.order_ordinal,
      source.workflow_version,
      item.value AS item_json,
      item.ordinality AS item_ordinal,
      NULLIF(item.value->>'id', '')::uuid AS item_id,
      item.value->>'source_kind' AS source_kind,
      COALESCE(item.value->>'fulfillment_route', '') AS fulfillment_route
    FROM order_context source
    CROSS JOIN LATERAL jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(source.order_json->'items') = 'array'
          THEN source.order_json->'items'
        ELSE '[]'::jsonb
      END
    ) WITH ORDINALITY AS item(value, ordinality)
  ),
  requested_source_lines AS MATERIALIZED (
    SELECT DISTINCT
      CASE
        WHEN item.source_kind = 'combo_component'
          THEN 'combo_component'
        ELSE 'base'
      END AS source_kind,
      item.item_id AS source_id
    FROM parsed_items item
    WHERE item.item_id IS NOT NULL
      AND item.fulfillment_route <> 'floor_direct'
  ),
  pending_source_ready AS MATERIALIZED (
    SELECT
      lot.source_kind,
      lot.source_id,
      min(lot.ready_sequence) AS ready_sequence
    FROM requested_source_lines requested
    JOIN public.emergency_floor_ready_lots lot
      ON lot.source_kind = requested.source_kind
     AND lot.source_id = requested.source_id
     AND lot.served_quantity + lot.voided_quantity < lot.ready_quantity
    GROUP BY lot.source_kind, lot.source_id
  ),
  requested_queues AS MATERIALIZED (
    SELECT DISTINCT source.queue_id
    FROM order_context source
    WHERE source.queue_id IS NOT NULL
  ),
  pending_queue_ready AS MATERIALIZED (
    SELECT lot.queue_id, min(lot.ready_sequence) AS ready_sequence
    FROM requested_queues requested
    JOIN public.emergency_floor_ready_lots lot
      ON lot.queue_id = requested.queue_id
     AND lot.served_quantity + lot.voided_quantity < lot.ready_quantity
    GROUP BY lot.queue_id
  ),
  joined_items AS MATERIALIZED (
    SELECT
      item.*,
      CASE
        WHEN item.source_kind = 'combo_component'
          THEN component.kitchen_started_quantity
        WHEN item.fulfillment_route <> 'floor_direct'
          THEN base.kitchen_started_quantity
        ELSE NULL
      END AS stored_started_quantity,
      COALESCE(
        CASE
          WHEN item.source_kind = 'combo_component'
            THEN component.excused_quantity
          WHEN item.fulfillment_route <> 'floor_direct'
            THEN base.excused_quantity
          ELSE direct_item.excused_quantity
        END,
        0
      ) AS stored_excused_quantity,
      ready.ready_sequence
    FROM parsed_items item
    LEFT JOIN public.emergency_combo_component_items component
      ON item.source_kind = 'combo_component'
     AND component.id = item.item_id
    LEFT JOIN public.emergency_fulfillment_items base
      ON item.source_kind IS DISTINCT FROM 'combo_component'
     AND item.fulfillment_route <> 'floor_direct'
     AND base.id = item.item_id
    LEFT JOIN public.emergency_floor_direct_items direct_item
      ON item.source_kind IS DISTINCT FROM 'combo_component'
     AND item.fulfillment_route = 'floor_direct'
     AND direct_item.id = item.item_id
    LEFT JOIN pending_source_ready ready
      ON ready.source_kind = CASE
           WHEN item.source_kind = 'combo_component'
             THEN 'combo_component'
           ELSE 'base'
         END
     AND ready.source_id = item.item_id
  ),
  item_groups AS MATERIALIZED (
    SELECT
      item.order_ordinal,
      jsonb_agg(
        item.item_json || jsonb_build_object(
          'workflow_version', item.workflow_version,
          'kitchen_started_quantity', COALESCE(
            item.stored_started_quantity,
            (item.item_json->>'kitchen_done_quantity')::integer,
            0
          ),
          'excused_quantity', item.stored_excused_quantity,
          'required_quantity', GREATEST(
            COALESCE(
              (item.item_json->>'ordered_quantity')::integer,
              0
            ) - item.stored_excused_quantity,
            0
          ),
          'oldest_ready_sequence', item.ready_sequence
        )
        ORDER BY item.item_ordinal
      ) AS items
    FROM joined_items item
    GROUP BY item.order_ordinal
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_set(
        source.order_json,
        '{items}',
        COALESCE(item_group.items, '[]'::jsonb),
        true
      ) || jsonb_build_object(
        'workflow_version', source.workflow_version,
        'oldest_ready_sequence', queue_ready.ready_sequence
      )
      ORDER BY source.order_ordinal
    ),
    '[]'::jsonb
  )
  FROM order_context source
  LEFT JOIN item_groups item_group
    ON item_group.order_ordinal = source.order_ordinal
  LEFT JOIN pending_queue_ready queue_ready
    ON queue_ready.queue_id = source.queue_id;
$function$;

REVOKE ALL ON FUNCTION public.emergency_enrich_start_ready_orders(jsonb)
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.emergency_enrich_start_ready_orders(jsonb) IS
  'Set-based KDS workflow enrichment; internal only and read-only.';

DO $verify$
DECLARE
  v_definition text;
  v_probe jsonb;
BEGIN
  SELECT pg_get_functiondef(
    'public.emergency_enrich_start_ready_orders(jsonb)'::regprocedure
  ) INTO v_definition;
  IF position('WITH ORDINALITY' IN v_definition) = 0
     OR position('pending_source_ready' IN v_definition) = 0
     OR position('FOR v_order IN' IN v_definition) > 0
     OR position('FOR v_item IN' IN v_definition) > 0 THEN
    RAISE EXCEPTION 'KDS_SET_ENRICHMENT_DEFINITION_INVALID';
  END IF;
  IF has_function_privilege(
       'authenticated',
       'public.emergency_enrich_start_ready_orders(jsonb)',
       'EXECUTE'
     ) OR has_function_privilege(
       'anon',
       'public.emergency_enrich_start_ready_orders(jsonb)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'KDS_SET_ENRICHMENT_PRIVILEGES_INVALID';
  END IF;
  SELECT public.emergency_enrich_start_ready_orders(NULL::jsonb)
  INTO v_probe;
  IF v_probe <> '[]'::jsonb THEN
    RAISE EXCEPTION 'KDS_SET_ENRICHMENT_NULL_INPUT_INVALID';
  END IF;
END;
$verify$;

COMMIT;
