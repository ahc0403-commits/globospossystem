-- production-gate: self-verifying
-- JeonGabok already posts floor-ready lots without a checker. Finish the
-- realtime cutover: the store had no rollout row and was still polling legacy
-- table changes. Other stores retain their current rollout and checker routes.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE FUNCTION pg_temp.direct_floor_live_patch(signature text,old_text text,new_text text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE definition text;
BEGIN
 definition:=pg_get_functiondef(to_regprocedure(signature));
 IF definition IS NULL OR (length(definition)-length(replace(definition,old_text,'')))/length(old_text)<>1 THEN
  RAISE EXCEPTION 'DIRECT_FLOOR_LIVE_PREDECESSOR_DRIFT:%',signature;
 END IF;
 EXECUTE replace(definition,old_text,new_text);
END $$;
-- Target the floor at the source, in addition to the existing last-writer
-- anti-checker guard. Delivery/pickup preparation still has no floor service.
SELECT pg_temp.direct_floor_live_patch('public.kds_capture_fulfillment_event()',
 $old$WHEN 'kitchen' THEN ARRAY['kitchen', 'tray']::text[]$old$,
 $new$WHEN 'kitchen' THEN CASE WHEN public.kds_is_direct_floor_store(NEW.restaurant_id)
   THEN CASE WHEN v_delivery THEN ARRAY['kitchen']::text[] ELSE ARRAY['kitchen','floor']::text[] END
   ELSE ARRAY['kitchen','tray']::text[] END$new$);
SELECT pg_temp.direct_floor_live_patch('public.kds_capture_fulfillment_event()',
 $old$ELSIF NEW.stage = 'kitchen_done' THEN
    v_targets := ARRAY['kitchen', 'tray']::text[];$old$,
 $new$ELSIF NEW.stage = 'kitchen_done' THEN
    v_targets := CASE WHEN public.kds_is_direct_floor_store(NEW.restaurant_id)
      THEN CASE WHEN v_delivery THEN ARRAY['kitchen']::text[] ELSE ARRAY['kitchen','floor']::text[] END
      ELSE ARRAY['kitchen','tray']::text[] END;$new$);
SELECT pg_temp.direct_floor_live_patch('public.kds_capture_fulfillment_event()',
 $old$WHEN 'leftover_requested' THEN ARRAY['floor']::text[]$old$,
 $new$WHEN 'leftover_requested' THEN ARRAY['floor']::text[]
      WHEN 'leftover_floor_to_kitchen' THEN ARRAY['floor','kitchen']::text[]
      WHEN 'leftover_kitchen_to_floor' THEN ARRAY['kitchen','floor']::text[]$new$);
SELECT pg_temp.direct_floor_live_patch('public.get_kds_ticket_v2_pre_business_day(uuid)',
 $old$WHEN 'floor' THEN 'tray_dispatched'$old$,
 $new$WHEN 'floor' THEN CASE WHEN public.kds_is_direct_floor_store(v_queue.restaurant_id) THEN 'kitchen_done' ELSE 'tray_dispatched' END$new$);

-- Reused bootstrap/ticket readers must not issue a catalog query for every
-- menu/component. Aggregate each one-to-many relation before joining it back.
CREATE OR REPLACE FUNCTION public.emergency_localize_paperless_orders(p_orders jsonb)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH orders AS MATERIALIZED (
  SELECT value,ordinality ord FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_orders)='array' THEN p_orders ELSE '[]'::jsonb END) WITH ORDINALITY
 ), items AS MATERIALIZED (
  SELECT o.ord,i.ordinality item_ord,i.value item FROM orders o
  CROSS JOIN LATERAL jsonb_array_elements(coalesce(o.value->'items','[]')) WITH ORDINALITY i(value,ordinality)
 ), components AS (
  SELECT i.ord,i.item_ord,jsonb_agg(c.value||jsonb_build_object('name_vi',coalesce(nullif(btrim(m.paperless_name_vi),''),nullif(c.value->>'name_vi',''),'Món')) ORDER BY c.ordinality) value
  FROM items i CROSS JOIN LATERAL jsonb_array_elements(coalesce(i.item->'combo_components','[]')) WITH ORDINALITY c(value,ordinality)
  LEFT JOIN public.menu_items m ON m.id=nullif(c.value->>'menu_item_id','')::uuid GROUP BY i.ord,i.item_ord
 ), localized AS (
  SELECT i.ord,i.item_ord,i.item||jsonb_build_object('name_vi',coalesce(nullif(btrim(m.paperless_name_vi),''),nullif(i.item->>'name_vi',''),'Món'),
   'combo_components',coalesce(c.value,'[]')) value
  FROM items i LEFT JOIN public.order_items oi ON i.item->>'fulfillment_route' IS DISTINCT FROM 'floor_direct' AND oi.id=nullif(i.item->>'order_item_id','')::uuid
  LEFT JOIN public.emergency_floor_direct_items d ON i.item->>'fulfillment_route'='floor_direct' AND d.id=nullif(i.item->>'id','')::uuid
  LEFT JOIN public.menu_items m ON m.id=CASE WHEN i.item->>'fulfillment_route'='floor_direct' THEN d.component_menu_item_id ELSE oi.menu_item_id END
  LEFT JOIN components c ON c.ord=i.ord AND c.item_ord=i.item_ord
 ), grouped AS (SELECT ord,jsonb_agg(value ORDER BY item_ord) items FROM localized GROUP BY ord)
 SELECT coalesce(jsonb_agg(jsonb_set(o.value,'{items}',coalesce(g.items,'[]'),true) ORDER BY o.ord),'[]') FROM orders o LEFT JOIN grouped g USING(ord);
$$;
CREATE OR REPLACE FUNCTION public.emergency_add_combo_component_progress(p_orders jsonb)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH orders AS MATERIALIZED (
  SELECT value,ordinality ord FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_orders)='array' THEN p_orders ELSE '[]'::jsonb END) WITH ORDINALITY
 ), queues AS MATERIALIZED (SELECT DISTINCT nullif(value->>'queue_id','')::uuid id FROM orders),
 components AS (
  SELECT c.queue_id,jsonb_agg(jsonb_build_object('id',c.id,'order_item_id',c.order_item_id,'line_key',c.line_key,'source_kind','combo_component',
   'fulfillment_route','kitchen_tray_floor','name_ko',c.name_ko,'name_vi',coalesce(nullif(btrim(m.paperless_name_vi),''),c.name_vi,'Món'),'name_en',c.name_en,
   'combo_components','[]'::jsonb,'ordered_quantity',c.ordered_quantity,'kitchen_done_quantity',c.kitchen_done_quantity,
   'tray_received_quantity',c.tray_received_quantity,'tray_dispatched_quantity',c.tray_dispatched_quantity,'floor_served_quantity',c.floor_served_quantity,'needs_review',c.needs_review)
   ORDER BY c.created_at,c.order_item_id,c.line_key) items
  FROM queues q JOIN public.emergency_combo_component_items c ON c.queue_id=q.id AND NOT c.is_cancelled
  LEFT JOIN public.menu_items m ON m.id=c.component_menu_item_id GROUP BY c.queue_id
 )
 SELECT coalesce(jsonb_agg(jsonb_set(o.value,'{items}',coalesce(o.value->'items','[]')||coalesce(c.items,'[]'),true) ORDER BY o.ord),'[]')
 FROM orders o LEFT JOIN components c ON c.queue_id=nullif(o.value->>'queue_id','')::uuid;
$$;
REVOKE ALL ON FUNCTION public.emergency_localize_paperless_orders(jsonb),public.emergency_add_combo_component_progress(jsonb) FROM PUBLIC,anon,authenticated;

-- One request/response for bootstrap and revision-based floor invalidation.
INSERT INTO public.kds_realtime_rollouts(restaurant_id,mode,updated_by,updated_at)
SELECT id,'active',NULL,now() FROM public.restaurants
WHERE id='273b057e-3b69-46e3-93c1-6194c2802849'
ON CONFLICT(restaurant_id) DO UPDATE SET mode='active',updated_by=NULL,updated_at=now();
INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
VALUES(NULL,'jeongabok_direct_floor_live_sync','restaurants','273b057e-3b69-46e3-93c1-6194c2802849',
 jsonb_build_object('operator','Codex maintenance','owner_request','2026-10-21 kitchen directly to floor; no tray',
 'rollout_mode','active','fulfillment_quantities_changed',false,'other_store_rollouts_changed',false));
-- Refresh already-connected floor clients without inventing a kitchen/service
-- event or changing any real preparation/delivery quantity.
SELECT public.kds_append_change(s.restaurant_id,s.id,gen_random_uuid(),'bootstrap_required',
 ARRAY['kitchen','floor'],NULL,NULL,NULL,NULL,
 jsonb_build_object('kind','bootstrap_required','reason','direct_floor_live_sync'),
 'direct-floor-live-sync:20261021100000')
FROM public.emergency_fulfillment_sessions s
WHERE s.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849' AND s.status='active';
DO $$ BEGIN
 IF (EXISTS(SELECT 1 FROM public.restaurants WHERE id='273b057e-3b69-46e3-93c1-6194c2802849')
 AND NOT EXISTS(SELECT 1 FROM public.kds_realtime_rollouts WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849' AND mode='active'))
 OR EXISTS(SELECT 1 FROM public.emergency_station_assignments WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849' AND station_type='tray' AND is_active)
 THEN RAISE EXCEPTION 'DIRECT_FLOOR_LIVE_SYNC_VERIFY_FAILED'; END IF;
END $$;
COMMIT;
