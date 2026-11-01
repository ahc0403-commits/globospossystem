-- production-gate: self-verifying
BEGIN;
-- Read existing authoritative receipts; never replay a handoff to discover its
-- result. JeonGabok's one-item completion uses a kitchen-batch request UUID,
-- whose resulting event has its own UUID. Both paths are resolved set-wise.
CREATE FUNCTION public.get_kds_progress_receipts_v1(p_store_id uuid,p_operation_ids uuid[])
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE actor_id uuid; actor_count integer; result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE insufficient_privilege; END IF;
  IF p_store_id IS NULL OR p_operation_ids IS NULL OR cardinality(p_operation_ids)>100
    OR coalesce(array_ndims(p_operation_ids),1)<>1 THEN
    RAISE EXCEPTION 'KDS_RECEIPT_BATCH_INVALID' USING ERRCODE='22023'; END IF;
  IF array_position(p_operation_ids,NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'KDS_RECEIPT_BATCH_INVALID' USING ERRCODE='22023'; END IF;
  SELECT min(u.id::text)::uuid,count(*) INTO actor_id,actor_count
    FROM public.users u WHERE u.auth_id=auth.uid() AND u.is_active;
  IF actor_count<>1 OR NOT(public.is_super_admin() OR EXISTS(
    SELECT 1 FROM public.user_accessible_stores(auth.uid()) s WHERE s.store_id=p_store_id)) THEN
    RAISE insufficient_privilege; END IF;
  WITH requested AS MATERIALIZED(SELECT DISTINCT unnest(p_operation_ids) operation_id),
  single_events AS (
    SELECT r.operation_id,e.event_id,e.session_id,e.stage,e.delta,e.order_item_id,
      e.floor_direct_item_id,e.combo_component_item_id,e.details
    FROM requested r JOIN public.emergency_fulfillment_events e ON e.event_id=r.operation_id
    WHERE e.restaurant_id=p_store_id AND e.actor_user_id=actor_id
  ), batch_events AS (
    SELECT r.operation_id,e.event_id,e.session_id,e.stage,e.delta,e.order_item_id,
      e.floor_direct_item_id,e.combo_component_item_id,e.details
    FROM requested r JOIN public.emergency_kitchen_batch_actions b ON b.request_id=r.operation_id
    JOIN public.emergency_fulfillment_events e ON e.event_id=(b.response->'event_ids'->>0)::uuid
    WHERE b.restaurant_id=p_store_id AND b.created_by=actor_id
      AND e.restaurant_id=p_store_id AND e.actor_user_id=actor_id
      AND jsonb_array_length(b.response->'event_ids')=1
      AND NOT EXISTS(SELECT 1 FROM single_events s WHERE s.operation_id=r.operation_id)
  ), receipts AS (SELECT * FROM single_events UNION ALL SELECT * FROM batch_events)
  SELECT coalesce(jsonb_agg(jsonb_build_object('event_id',operation_id,'actual_event_id',event_id,
    'session_id',session_id,'stage',stage,'delta',delta,'order_item_id',order_item_id,
    'floor_direct_item_id',floor_direct_item_id,'combo_component_item_id',combo_component_item_id,
    'details',jsonb_strip_nulls(jsonb_build_object('workflow_action',details->>'workflow_action',
      'source_kind',details->>'source_kind','source_id',details->>'source_id')))
      ORDER BY operation_id),'[]'::jsonb) INTO result FROM receipts;
  RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.get_kds_progress_receipts_v1(uuid,uuid[]) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.get_kds_progress_receipts_v1(uuid,uuid[]) TO authenticated;
DO $$ BEGIN
  IF has_function_privilege('anon','public.get_kds_progress_receipts_v1(uuid,uuid[])','EXECUTE')
    OR NOT has_function_privilege('authenticated','public.get_kds_progress_receipts_v1(uuid,uuid[])','EXECUTE')
    OR NOT (SELECT prosecdef AND proconfig @> ARRAY['search_path=""'] FROM pg_proc
      WHERE oid='public.get_kds_progress_receipts_v1(uuid,uuid[])'::regprocedure) THEN
    RAISE EXCEPTION 'KDS_PROGRESS_RECEIPT_ACL_FAILED'; END IF;
END $$;
COMMIT;
