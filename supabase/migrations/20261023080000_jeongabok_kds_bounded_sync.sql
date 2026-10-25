-- production-gate: self-verifying
-- JeonGabok only. Additive read capability; no rollout, account or quantity writes.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
ALTER FUNCTION public.get_kds_sync_config() RENAME TO get_kds_sync_config_pre_jeongabok;
REVOKE ALL ON FUNCTION public.get_kds_sync_config_pre_jeongabok() FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.get_kds_sync_config() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE c jsonb;
BEGIN
 c:=public.get_kds_sync_config_pre_jeongabok();
 IF c->>'restaurant_id'='273b057e-3b69-46e3-93c1-6194c2802849'
  AND c->>'mode'='active' AND c->>'assigned'='true'
  AND c->>'station_type' IN ('kitchen','floor') THEN
  c:=c||jsonb_build_object('bounded_sync_version',3);
 END IF;
 RETURN c;
END $$;
REVOKE ALL ON FUNCTION public.get_kds_sync_config() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_kds_sync_config() TO authenticated;

CREATE FUNCTION public.jeongabok_kds_batch_timings_v1(p_orders jsonb)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH orders AS MATERIALIZED (
  SELECT value,ordinality ord FROM jsonb_array_elements(p_orders) WITH ORDINALITY
 ), queue_orders AS MATERIALIZED (
  SELECT DISTINCT q.order_id,q.created_at FROM orders o
  JOIN public.emergency_order_queue q ON q.id=(o.value->>'queue_id')::uuid
  WHERE q.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849'
 ), requested_order_items AS MATERIALIZED (
  SELECT oi.id,oi.created_at FROM (SELECT DISTINCT order_id FROM queue_orders) q
  JOIN public.order_items oi ON oi.order_id=q.order_id
  WHERE oi.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849'
 ), items AS MATERIALIZED (
  SELECT o.ord,i.ordinality item_ord,i.value,
   CASE WHEN i.value->>'fulfillment_route'='floor_direct' THEN 'direct'
    WHEN i.value->>'source_kind'='combo_component' THEN 'component' ELSE 'base' END kind,
   nullif(i.value->>'id','')::uuid source_id,
   nullif(i.value->>'order_item_id','')::uuid order_item_id
  FROM orders o CROSS JOIN LATERAL jsonb_array_elements(coalesce(o.value->'items','[]')) WITH ORDINALITY i
 ), wanted AS MATERIALIZED (
  SELECT DISTINCT kind,source_id,order_item_id FROM items
 ), bounds AS MATERIALIZED (
  -- All requested queues/items already belong to an authorized response.
  -- Their earliest creation day bounds event reads even when the planner
  -- estimates a large JSON input and chooses a hash join. Keep the earlier
  -- item boundary for transferred/additional order lines.
  SELECT date_trunc('day',least(
   (SELECT min(created_at) FROM queue_orders),
   (SELECT min(created_at) FROM requested_order_items)
  )) since
 ), events AS MATERIALIZED (
  SELECT w.kind,w.source_id,e.stage,e.created_at
  FROM wanted w JOIN public.emergency_fulfillment_events e ON e.order_item_id=w.order_item_id
  WHERE w.kind='base' AND e.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849'
   AND e.created_at >= (SELECT since FROM bounds)
   AND e.delta>0 AND e.combo_component_item_id IS NULL AND e.floor_direct_item_id IS NULL
   AND e.stage IN ('kitchen_done','tray_dispatched','floor_served')
  UNION ALL
  SELECT w.kind,w.source_id,e.stage,e.created_at
  FROM wanted w JOIN public.emergency_fulfillment_events e ON e.combo_component_item_id=w.source_id
  WHERE w.kind='component' AND e.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849'
   AND e.created_at >= (SELECT since FROM bounds)
   AND e.delta>0 AND e.stage IN ('kitchen_done','tray_dispatched','floor_served')
  UNION ALL
  SELECT w.kind,w.source_id,e.stage,e.created_at
  FROM wanted w JOIN public.emergency_fulfillment_events e ON e.floor_direct_item_id=w.source_id
  WHERE w.kind='direct' AND e.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849'
   AND e.created_at >= (SELECT since FROM bounds)
   AND e.delta>0 AND e.stage IN ('kitchen_done','tray_dispatched','floor_served')
 ), times AS (
  SELECT kind,source_id,
   min(created_at) FILTER(WHERE stage='kitchen_done') kitchen_first_done_at,
   max(created_at) FILTER(WHERE stage='kitchen_done') kitchen_last_done_at,
   min(created_at) FILTER(WHERE stage IN ('tray_dispatched','kitchen_done')) tray_first_dispatched_at,
   max(created_at) FILTER(WHERE stage IN ('tray_dispatched','kitchen_done')) tray_last_dispatched_at,
   min(created_at) FILTER(WHERE stage='floor_served') floor_first_served_at,
   max(created_at) FILTER(WHERE stage='floor_served') floor_last_served_at
  FROM events GROUP BY kind,source_id
 ), enriched AS (
  SELECT i.ord,i.item_ord,i.value||jsonb_strip_nulls(jsonb_build_object(
   'batch_received_at',oi.created_at,
   'kitchen_first_done_at',t.kitchen_first_done_at,'kitchen_last_done_at',t.kitchen_last_done_at,
   'tray_first_dispatched_at',t.tray_first_dispatched_at,'tray_last_dispatched_at',t.tray_last_dispatched_at,
   'floor_first_served_at',t.floor_first_served_at,'floor_last_served_at',t.floor_last_served_at)) value
  FROM items i LEFT JOIN requested_order_items oi ON oi.id=i.order_item_id
  LEFT JOIN times t ON t.kind=i.kind AND t.source_id=i.source_id
 ), grouped AS (
  SELECT ord,jsonb_agg(value ORDER BY item_ord) items FROM enriched GROUP BY ord
 )
 SELECT coalesce(jsonb_agg(jsonb_set(o.value,'{items}',coalesce(g.items,'[]'),true) ORDER BY o.ord),'[]')
 FROM orders o LEFT JOIN grouped g USING(ord);
$$;
REVOKE ALL ON FUNCTION public.jeongabok_kds_batch_timings_v1(jsonb) FROM PUBLIC,anon,authenticated;


CREATE FUNCTION public.jeongabok_kds_localize_orders_v1("p_orders" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
 WITH orders AS MATERIALIZED (
  SELECT value,ordinality ord FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_orders)='array' THEN p_orders ELSE '[]'::jsonb END) WITH ORDINALITY
 ), queue_context AS MATERIALIZED (
  SELECT DISTINCT q.id,q.order_id FROM orders o JOIN public.emergency_order_queue q ON q.id=nullif(o.value->>'queue_id','')::uuid
  WHERE q.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849'
 ), requested_order_items AS MATERIALIZED (
  SELECT oi.id,oi.menu_item_id FROM (SELECT DISTINCT order_id FROM queue_context) q
  JOIN public.order_items oi ON oi.order_id=q.order_id
  WHERE oi.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849'
 ), requested_direct_items AS MATERIALIZED (
  SELECT d.id,d.component_menu_item_id FROM queue_context q JOIN public.emergency_floor_direct_items d ON d.queue_id=q.id
  WHERE d.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849' AND NOT d.is_cancelled
 ), items AS MATERIALIZED (
  SELECT o.ord,i.ordinality item_ord,i.value item FROM orders o
  CROSS JOIN LATERAL jsonb_array_elements(coalesce(o.value->'items','[]')) WITH ORDINALITY i(value,ordinality)
 ), components AS (
  SELECT i.ord,i.item_ord,jsonb_agg(c.value||jsonb_build_object('name_vi',coalesce(nullif(btrim(m.paperless_name_vi),''),nullif(c.value->>'name_vi',''),'Món')) ORDER BY c.ordinality) value
  FROM items i CROSS JOIN LATERAL jsonb_array_elements(coalesce(i.item->'combo_components','[]')) WITH ORDINALITY c(value,ordinality)
  LEFT JOIN public.menu_items m ON m.id=nullif(c.value->>'menu_item_id','')::uuid AND m.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849' GROUP BY i.ord,i.item_ord
 ), localized AS (
  SELECT i.ord,i.item_ord,i.item||jsonb_build_object('name_vi',coalesce(nullif(btrim(m.paperless_name_vi),''),nullif(i.item->>'name_vi',''),'Món'),
   'combo_components',coalesce(c.value,'[]')) value
  FROM items i LEFT JOIN requested_order_items oi ON i.item->>'fulfillment_route' IS DISTINCT FROM 'floor_direct' AND oi.id=nullif(i.item->>'order_item_id','')::uuid
  LEFT JOIN requested_direct_items d ON i.item->>'fulfillment_route'='floor_direct' AND d.id=nullif(i.item->>'id','')::uuid
  LEFT JOIN public.menu_items m ON m.id=CASE WHEN i.item->>'fulfillment_route'='floor_direct' THEN d.component_menu_item_id ELSE oi.menu_item_id END
  LEFT JOIN components c ON c.ord=i.ord AND c.item_ord=i.item_ord
 ), grouped AS (SELECT ord,jsonb_agg(value ORDER BY item_ord) items FROM localized GROUP BY ord)
 SELECT coalesce(jsonb_agg(jsonb_set(o.value,'{items}',coalesce(g.items,'[]'),true) ORDER BY o.ord),'[]') FROM orders o LEFT JOIN grouped g USING(ord);
$$;


REVOKE ALL ON FUNCTION public.jeongabok_kds_localize_orders_v1(jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.jeongabok_kds_add_component_progress_v1("p_orders" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
 WITH orders AS MATERIALIZED (
  SELECT value,ordinality ord FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_orders)='array' THEN p_orders ELSE '[]'::jsonb END) WITH ORDINALITY
 ), queues AS MATERIALIZED (SELECT DISTINCT q.id FROM orders o JOIN public.emergency_order_queue q ON q.id=nullif(o.value->>'queue_id','')::uuid WHERE q.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849'),
 components AS (
  SELECT c.queue_id,jsonb_agg(jsonb_build_object('id',c.id,'order_item_id',c.order_item_id,'line_key',c.line_key,'source_kind','combo_component',
   'fulfillment_route','kitchen_tray_floor','name_ko',c.name_ko,'name_vi',coalesce(nullif(btrim(m.paperless_name_vi),''),c.name_vi,'Món'),'name_en',c.name_en,
   'combo_components','[]'::jsonb,'ordered_quantity',c.ordered_quantity,'kitchen_done_quantity',c.kitchen_done_quantity,
   'tray_received_quantity',c.tray_received_quantity,'tray_dispatched_quantity',c.tray_dispatched_quantity,'floor_served_quantity',c.floor_served_quantity,'needs_review',c.needs_review)
   ORDER BY c.created_at,c.order_item_id,c.line_key) items
  FROM queues q JOIN public.emergency_combo_component_items c ON c.queue_id=q.id AND NOT c.is_cancelled AND c.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849'
  LEFT JOIN public.menu_items m ON m.id=c.component_menu_item_id GROUP BY c.queue_id
 )
 SELECT coalesce(jsonb_agg(jsonb_set(o.value,'{items}',coalesce(o.value->'items','[]')||coalesce(c.items,'[]'),true) ORDER BY o.ord),'[]')
 FROM orders o LEFT JOIN components c ON c.queue_id=nullif(o.value->>'queue_id','')::uuid;
$$;


REVOKE ALL ON FUNCTION public.jeongabok_kds_add_component_progress_v1(jsonb) FROM PUBLIC,anon,authenticated;

-- Build JeonGabok station metadata in one batch. Repeated JSON reparsing through
-- every historical wrapper was the dominant cost under concurrent terminals.
CREATE FUNCTION public.jeongabok_kds_enrich_orders_v1(p_orders jsonb,p_station text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH orders AS MATERIALIZED (
  SELECT value,ordinality ord FROM jsonb_array_elements(
   public.jeongabok_kds_batch_timings_v1(public.jeongabok_kds_add_component_progress_v1(
    public.jeongabok_kds_localize_orders_v1(p_orders)))) WITH ORDINALITY
 ), queues AS MATERIALIZED (
  SELECT o.*,q.id queue_id,q.workflow_version,q.kitchen_direct_to_floor
  FROM orders o JOIN public.emergency_order_queue q ON q.id=nullif(o.value->>'queue_id','')::uuid
  WHERE q.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849'
 ), queue_ids AS MATERIALIZED (
  SELECT DISTINCT queue_id FROM queues
 ), requested_order_items AS MATERIALIZED (
  SELECT oi.id,oi.order_id,oi.notes,oi.is_takeout,oi.menu_option_snapshot
  FROM (SELECT DISTINCT (value->>'order_id')::uuid order_id FROM queues) q
  JOIN public.order_items oi ON oi.order_id=q.order_id
  WHERE oi.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849'
 ), base_ledgers AS MATERIALIZED (
  SELECT f.id,f.kitchen_started_quantity,f.excused_quantity FROM queue_ids q
  JOIN public.emergency_fulfillment_items f ON f.queue_id=q.queue_id
  WHERE f.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849' AND NOT f.is_cancelled
 ), component_ledgers AS MATERIALIZED (
  SELECT f.id,f.kitchen_started_quantity,f.excused_quantity FROM queue_ids q
  JOIN public.emergency_combo_component_items f ON f.queue_id=q.queue_id
  WHERE f.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849' AND NOT f.is_cancelled
 ), direct_ledgers AS MATERIALIZED (
  SELECT f.id,f.excused_quantity FROM queue_ids q
  JOIN public.emergency_floor_direct_items f ON f.queue_id=q.queue_id
  WHERE f.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849' AND NOT f.is_cancelled
 ), requests AS MATERIALIZED (
  SELECT DISTINCT ON(f.order_id) f.order_id,r.id,r.fulfillment_type,r.reference_code,
   r.diner_count,r.utensils_requested,r.fulfillment_method
  FROM queues q JOIN public.direct_order_financials f ON f.order_id=(q.value->>'order_id')::uuid
   AND f.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849'
  JOIN public.direct_order_requests r ON r.id=f.request_id AND r.restaurant_id=f.restaurant_id
  ORDER BY f.order_id,r.id
 ), notes AS (
  SELECT n.request_id,string_agg(coalesce(n.item_label_vi||': ','')||n.print_reply_vi,E'\n' ORDER BY n.created_at,n.id) text
  FROM requests r JOIN public.direct_order_customer_requirements n ON n.request_id=r.id
  WHERE n.status='confirmed' AND n.print_scope IN ('preparation','both') GROUP BY n.request_id
 ), items AS MATERIALIZED (
  SELECT q.ord,q.queue_id,q.workflow_version,q.kitchen_direct_to_floor,i.ordinality item_ord,i.value,
   CASE WHEN i.value->>'source_kind'='combo_component' THEN 'combo_component' ELSE 'base' END source_kind,
   nullif(i.value->>'id','')::uuid source_id
  FROM queues q CROSS JOIN LATERAL jsonb_array_elements(coalesce(q.value->'items','[]')) WITH ORDINALITY i
 ), floor_lots AS MATERIALIZED (
  SELECT l.queue_id,l.source_kind,l.source_id,l.ready_sequence FROM queue_ids q
  JOIN public.emergency_floor_ready_lots l ON l.queue_id=q.queue_id
  WHERE l.served_quantity+l.voided_quantity<l.ready_quantity
 ), tray_lots AS MATERIALIZED (
  SELECT l.queue_id,l.source_kind,l.source_id,l.ready_sequence FROM queue_ids q
  JOIN public.emergency_tray_ready_lots l ON l.queue_id=q.queue_id
  WHERE l.handed_quantity+l.voided_quantity<l.ready_quantity
 ), floor_ready AS (
  SELECT source_kind,source_id,min(ready_sequence) seq FROM floor_lots GROUP BY source_kind,source_id
 ), tray_ready AS (
  SELECT source_kind,source_id,min(ready_sequence) seq FROM tray_lots GROUP BY source_kind,source_id
 ), queue_floor_ready AS (
  SELECT queue_id,min(ready_sequence) seq FROM floor_lots GROUP BY queue_id
 ), queue_tray_ready AS (
  SELECT queue_id,min(ready_sequence) seq FROM tray_lots GROUP BY queue_id
 ), joined AS (
  SELECT i.*,oi.notes,oi.is_takeout,r.fulfillment_type,
   CASE WHEN i.source_kind='combo_component' THEN oi.menu_option_snapshot->'components'->split_part(i.value->>'line_key',':',2)
    ELSE oi.menu_option_snapshot END frozen,
   coalesce(CASE WHEN i.source_kind='combo_component' THEN c.kitchen_started_quantity
    WHEN i.value->>'fulfillment_route' IS DISTINCT FROM 'floor_direct' THEN b.kitchen_started_quantity END,
    (i.value->>'kitchen_done_quantity')::integer,0) started,
   coalesce(CASE WHEN i.source_kind='combo_component' THEN c.excused_quantity
    WHEN i.value->>'fulfillment_route'='floor_direct' THEN d.excused_quantity ELSE b.excused_quantity END,0) excused,
   fr.seq floor_seq,tr.seq tray_seq
  FROM items i
  LEFT JOIN requested_order_items oi ON oi.id=nullif(i.value->>'order_item_id','')::uuid
  LEFT JOIN base_ledgers b ON i.source_kind='base'
   AND i.value->>'fulfillment_route' IS DISTINCT FROM 'floor_direct' AND b.id=i.source_id
  LEFT JOIN component_ledgers c ON i.source_kind='combo_component' AND c.id=i.source_id
  LEFT JOIN direct_ledgers d ON i.value->>'fulfillment_route'='floor_direct' AND d.id=i.source_id
  LEFT JOIN floor_ready fr ON fr.source_kind=i.source_kind AND fr.source_id=i.source_id
  LEFT JOIN tray_ready tr ON tr.source_kind=i.source_kind AND tr.source_id=i.source_id
  LEFT JOIN queues q ON q.ord=i.ord
  LEFT JOIN requests r ON r.order_id=(q.value->>'order_id')::uuid
 ), grouped AS (
  SELECT ord,jsonb_agg(jsonb_strip_nulls(value||jsonb_build_object(
   'workflow_version',workflow_version,'kitchen_direct_to_floor',kitchen_direct_to_floor,
   'kitchen_started_quantity',started,'excused_quantity',excused,
   'required_quantity',greatest(coalesce((value->>'ordered_quantity')::integer,0)-excused,0),
   'oldest_ready_sequence',floor_seq,'oldest_tray_ready_sequence',tray_seq,
   'notes',nullif(btrim(notes),''),'is_takeout',coalesce(is_takeout,false) OR coalesce(fulfillment_type='pickup',false)
  )||CASE WHEN coalesce(frozen,'{}')<>'{}'::jsonb THEN jsonb_build_object(
   'menu_option_snapshot',frozen,'name_ko',frozen->>'name_ko','name_vi',frozen->>'name_vi','name_en',frozen->>'name_en'
  ) ELSE '{}'::jsonb END) ORDER BY item_ord) items FROM joined GROUP BY ord
 )
 SELECT coalesce(jsonb_agg(q.value||jsonb_build_object(
  'items',coalesce(g.items,'[]'),'workflow_version',q.workflow_version,
  'kitchen_direct_to_floor',q.kitchen_direct_to_floor,'oldest_ready_sequence',fr.seq,
  'oldest_tray_ready_sequence',tr.seq,'sales_channel',coalesce(o.sales_channel,'dine_in')
 )||CASE WHEN r.id IS NOT NULL THEN jsonb_build_object('direct_order_packing',jsonb_build_object(
  'diner_count',r.diner_count,'utensils_requested',r.utensils_requested,'reference_code',r.reference_code,
  'fulfillment_method',r.fulfillment_method,'confirmed_notes',n.text)) ELSE '{}'::jsonb END
 ||CASE WHEN r.fulfillment_type='pickup' THEN jsonb_build_object('direct_fulfillment_type','pickup',
  'direct_reference_code',r.reference_code) ELSE '{}'::jsonb END ORDER BY q.ord),'[]')
 FROM queues q LEFT JOIN grouped g USING(ord) LEFT JOIN public.orders o ON o.id=(q.value->>'order_id')::uuid
 LEFT JOIN requests r ON r.order_id=o.id LEFT JOIN notes n ON n.request_id=r.id
 LEFT JOIN queue_floor_ready fr ON fr.queue_id=q.queue_id LEFT JOIN queue_tray_ready tr ON tr.queue_id=q.queue_id
 WHERE p_station<>'floor' OR (coalesce(o.sales_channel,'dine_in')<>'delivery' AND coalesce(r.fulfillment_type,'delivery')<>'pickup');
$$;
REVOKE ALL ON FUNCTION public.jeongabok_kds_enrich_orders_v1(jsonb,text) FROM PUBLIC,anon,authenticated;


CREATE FUNCTION public.jeongabok_kds_tickets_core_v3(p_queue_ids uuid[]) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE c jsonb; v_day_start timestamptz; v_orders jsonb;
BEGIN
 c:=public.get_kds_sync_config();
 IF c->>'restaurant_id'<>'273b057e-3b69-46e3-93c1-6194c2802849'
  OR coalesce(c->>'bounded_sync_version','0')<>'3' THEN
  RAISE EXCEPTION 'JEONGABOK_KDS_SCOPE_REQUIRED';
 END IF;
 v_day_start:=date_trunc('day',now() AT TIME ZONE 'Asia/Ho_Chi_Minh') AT TIME ZONE 'Asia/Ho_Chi_Minh';
 WITH visible AS MATERIALIZED (
  SELECT q.* FROM public.emergency_order_queue q
  WHERE q.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849'
   AND q.session_id=nullif(c->>'session_id','')::uuid
   AND q.created_at>=v_day_start AND q.created_at<v_day_start+interval '1 day'
   AND (p_queue_ids IS NULL OR q.id=ANY(p_queue_ids))
   AND (c->>'station_type'<>'floor' OR q.floor_label=ANY(ARRAY(SELECT jsonb_array_elements_text(c->'service_area_codes'))))
 ),  item_rows AS (
            SELECT queue.id AS queue_id, fulfillment.created_at, fulfillment.order_item_id,
              'base'::text AS line_key,
              jsonb_build_object(
                'id', fulfillment.id,
                'order_item_id', fulfillment.order_item_id,
                'line_key', 'base',
                'source_kind', 'order_item',
                'fulfillment_route', 'kitchen_tray_floor',
                'name_ko', COALESCE(NULLIF(item.label, ''),
                  NULLIF(item.display_name, ''), menu.name_ko, menu.name, '메뉴'),
                'name_vi', COALESCE(NULLIF(menu.name_vi, ''),
                  NULLIF(item.display_name, ''), menu.name, 'Món'),
                'name_en', COALESCE(NULLIF(menu.name_en, ''),
                  NULLIF(item.display_name, ''), menu.name, 'Item'),
                'combo_components', COALESCE(item.combo_components, '[]'::jsonb),
                'ordered_quantity', fulfillment.ordered_quantity,
                'kitchen_done_quantity', fulfillment.kitchen_done_quantity,
                'tray_received_quantity', fulfillment.tray_received_quantity,
                'tray_dispatched_quantity', fulfillment.tray_dispatched_quantity,
                'floor_served_quantity', fulfillment.floor_served_quantity,
                'needs_review', fulfillment.needs_review
              ) AS item_payload
            FROM visible queue
            JOIN public.emergency_fulfillment_items fulfillment ON fulfillment.queue_id=queue.id
            JOIN public.order_items item ON item.id = fulfillment.order_item_id
            LEFT JOIN public.menu_items menu ON menu.id = item.menu_item_id
            WHERE fulfillment.queue_id = queue.id
              AND fulfillment.is_cancelled = false

            UNION ALL

            SELECT queue.id AS queue_id, direct.created_at, direct.order_item_id, direct.line_key,
              jsonb_build_object(
                'id', direct.id,
                'order_item_id', direct.order_item_id,
                'line_key', direct.line_key,
                'source_kind', direct.source_kind,
                'fulfillment_route', 'floor_direct',
                'name_ko', direct.name_ko,
                'name_vi', direct.name_vi,
                'name_en', direct.name_en,
                'combo_components', '[]'::jsonb,
                'ordered_quantity', direct.ordered_quantity,
                'kitchen_done_quantity', 0,
                'tray_received_quantity', 0,
                'tray_dispatched_quantity', 0,
                'floor_served_quantity', direct.floor_served_quantity,
                'needs_review', direct.needs_review
              ) AS item_payload
            FROM visible queue
            JOIN public.emergency_floor_direct_items direct ON direct.queue_id=queue.id
            WHERE true
              AND direct.is_cancelled = false


 ), grouped_items AS (
  SELECT queue_id,jsonb_agg(item_payload ORDER BY created_at,order_item_id,line_key) items
  FROM item_rows GROUP BY queue_id
 ), recent_actions AS MATERIALIZED (
  SELECT DISTINCT ON(a.queue_id) a.queue_id,a.action_id,a.created_at
  FROM visible q JOIN public.emergency_fulfillment_actions a ON a.queue_id=q.id
  WHERE a.station_type=c->>'station_type' AND a.action_kind='complete'
   AND NOT EXISTS(SELECT 1 FROM public.emergency_fulfillment_actions r
    WHERE r.original_action_id=a.action_id AND r.action_kind='revert')
  ORDER BY a.queue_id,a.created_at DESC,a.action_id DESC
 ), event_times AS MATERIALIZED (
  SELECT q.id queue_id,
   min(e.created_at) FILTER(WHERE e.stage='kitchen_done') previous_at,
   max(e.created_at) FILTER(WHERE e.stage=CASE c->>'station_type' WHEN 'kitchen' THEN 'kitchen_done' ELSE 'floor_served' END) completed_at
  FROM visible q JOIN public.emergency_fulfillment_events e
   ON e.restaurant_id=q.restaurant_id AND e.session_id=q.session_id AND e.order_id=q.order_id
  WHERE e.delta>0
  GROUP BY q.id
 ), direct_queues AS MATERIALIZED (
  SELECT DISTINCT d.queue_id FROM visible q JOIN public.emergency_floor_direct_items d ON d.queue_id=q.id
  WHERE NOT d.is_cancelled
 ), payloads AS (
  SELECT q.queue_no,q.id,jsonb_build_object(
   'queue_id',q.id,'order_id',q.order_id,'queue_no',q.queue_no,'table_number',q.table_number,
   'floor_label',q.floor_label,'created_at',q.created_at,'last_action_id',a.action_id,'last_action_at',a.created_at,
   'items',coalesce(g.items,'[]'))||jsonb_strip_nulls(jsonb_build_object(
   'station_started_at',CASE WHEN c->>'station_type'='kitchen' OR d.queue_id IS NOT NULL THEN q.created_at ELSE e.previous_at END,
   'station_completed_at',e.completed_at)) payload
  FROM visible q LEFT JOIN grouped_items g ON g.queue_id=q.id
  LEFT JOIN recent_actions a ON a.queue_id=q.id LEFT JOIN event_times e ON e.queue_id=q.id
  LEFT JOIN direct_queues d ON d.queue_id=q.id
 )
 SELECT coalesce(jsonb_agg(payload ORDER BY queue_no,id),'[]') INTO v_orders FROM payloads;
 RETURN public.jeongabok_kds_enrich_orders_v1(v_orders,c->>'station_type');
END $$;
REVOKE ALL ON FUNCTION public.jeongabok_kds_tickets_core_v3(uuid[]) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.get_jeongabok_kds_tickets_v3(p_queue_ids uuid[]) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE c jsonb; v_orders jsonb; v_tickets jsonb;
BEGIN
 IF p_queue_ids IS NULL OR cardinality(p_queue_ids)<1 OR cardinality(p_queue_ids)>100
  OR array_position(p_queue_ids,NULL) IS NOT NULL THEN RAISE EXCEPTION 'KDS_TICKET_BATCH_INVALID'; END IF;
 -- Same statement snapshot binds revision, scope, tickets and tombstones.
 c:=public.get_kds_sync_config();
 v_orders:=public.jeongabok_kds_tickets_core_v3(p_queue_ids);
 SELECT jsonb_agg(jsonb_build_object('queue_id',r.id,'ticket',o.value) ORDER BY r.id)
 INTO v_tickets FROM (SELECT DISTINCT unnest(p_queue_ids) id) r
 LEFT JOIN jsonb_array_elements(v_orders) o ON o.value->>'queue_id'=r.id::text;
 RETURN jsonb_build_object('revision',(c->>'revision')::bigint,'tickets',v_tickets,
  'session_id',c->'session_id','restaurant_id',c->'restaurant_id','sync',c);
END $$;
REVOKE ALL ON FUNCTION public.get_jeongabok_kds_tickets_v3(uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_jeongabok_kds_tickets_v3(uuid[]) TO authenticated;

CREATE FUNCTION public.jeongabok_kds_completed_core_v1(
 p_limit integer, p_before_completed_at timestamptz DEFAULT NULL,
 p_before_queue_id uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,auth,pg_catalog AS $$
DECLARE
 v_user public.users%ROWTYPE;
 v_assignment public.emergency_station_assignments%ROWTYPE;
 v_day_start timestamptz;
 v_result jsonb;
BEGIN
 IF p_limit IS NULL OR p_limit<1 OR p_limit>100
 OR (p_before_completed_at IS NULL)<>(p_before_queue_id IS NULL) THEN
  RAISE EXCEPTION 'KDS_HISTORY_PAGE_INVALID';
 END IF;
 SELECT * INTO v_user FROM public.users WHERE auth_id=auth.uid() AND is_active;
 IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;
 IF v_user.restaurant_id<>'273b057e-3b69-46e3-93c1-6194c2802849'::uuid THEN
  RAISE EXCEPTION 'JEONGABOK_KDS_SCOPE_REQUIRED';
 END IF;
 IF coalesce(public.get_kds_sync_config()->>'bounded_sync_version','0')<>'3' THEN RAISE EXCEPTION 'JEONGABOK_KDS_SCOPE_REQUIRED'; END IF;
 SELECT * INTO v_assignment FROM public.emergency_station_assignments
 WHERE user_id=v_user.id AND restaurant_id=v_user.restaurant_id AND is_active;
 IF NOT FOUND THEN RETURN jsonb_build_object('orders','[]'::jsonb,'has_more',false); END IF;
 v_day_start:=date_trunc('day',now() AT TIME ZONE 'Asia/Ho_Chi_Minh') AT TIME ZONE 'Asia/Ho_Chi_Minh';
 WITH scoped_queue AS MATERIALIZED (
  SELECT q.* FROM public.emergency_order_queue q
  WHERE q.restaurant_id=v_assignment.restaurant_id
   AND q.session_id=(SELECT id FROM public.emergency_fulfillment_sessions WHERE restaurant_id=v_assignment.restaurant_id AND status='active')
   AND q.created_at>=v_day_start AND q.created_at<v_day_start+interval '1 day'
   AND (v_assignment.station_type<>'floor' OR (q.floor_label=ANY(public.store_assignment_area_codes_v1(v_assignment))
    AND NOT EXISTS(SELECT 1 FROM public.orders o WHERE o.id=q.order_id AND o.sales_channel='delivery')
    AND NOT EXISTS(SELECT 1 FROM public.direct_order_financials f JOIN public.direct_order_requests r ON r.id=f.request_id
     WHERE f.order_id=q.order_id AND f.restaurant_id=q.restaurant_id AND r.fulfillment_type='pickup')))
 ) , completions AS MATERIALIZED (
  SELECT e.session_id,e.order_id,max(e.created_at) completed_at
  FROM scoped_queue q JOIN public.emergency_fulfillment_events e
   ON e.restaurant_id=v_assignment.restaurant_id AND e.session_id=q.session_id AND e.order_id=q.order_id
  WHERE e.created_at>=v_day_start AND e.created_at<v_day_start+interval '1 day'
   AND e.delta>0 AND e.stage=CASE v_assignment.station_type
    WHEN 'kitchen' THEN 'kitchen_done' WHEN 'tray' THEN 'tray_dispatched' ELSE 'floor_served' END
  GROUP BY e.session_id,e.order_id
 ), base_status AS MATERIALIZED (
  SELECT f.queue_id,
   bool_and(f.kitchen_done_quantity>=f.ordered_quantity) kitchen_complete,
   bool_and(f.tray_received_quantity>=f.ordered_quantity AND f.tray_dispatched_quantity>=f.ordered_quantity) tray_complete,
   bool_and(f.floor_served_quantity>=f.ordered_quantity) floor_complete
  FROM scoped_queue q JOIN public.emergency_fulfillment_items f ON f.queue_id=q.id
  WHERE NOT f.is_cancelled GROUP BY f.queue_id
 ), direct_status AS MATERIALIZED (
  SELECT d.queue_id,bool_and(d.floor_served_quantity>=d.ordered_quantity) floor_complete
  FROM scoped_queue q JOIN public.emergency_floor_direct_items d ON d.queue_id=q.id
  WHERE NOT d.is_cancelled GROUP BY d.queue_id
 ), candidates AS MATERIALIZED (
  SELECT q.*,c.completed_at FROM scoped_queue q
  JOIN completions c ON c.session_id=q.session_id AND c.order_id=q.order_id
  LEFT JOIN base_status b ON b.queue_id=q.id LEFT JOIN direct_status d ON d.queue_id=q.id
  WHERE CASE v_assignment.station_type
   WHEN 'kitchen' THEN coalesce(b.kitchen_complete,false)
   WHEN 'tray' THEN coalesce(b.tray_complete,false)
   ELSE (b.queue_id IS NOT NULL OR d.queue_id IS NOT NULL)
    AND coalesce(b.floor_complete,true) AND coalesce(d.floor_complete,true) END
   AND (p_before_completed_at IS NULL OR (c.completed_at,q.id)<(p_before_completed_at,p_before_queue_id))
  ORDER BY c.completed_at DESC,q.id DESC LIMIT p_limit+1
 ), visible AS MATERIALIZED (
  SELECT * FROM candidates ORDER BY completed_at DESC,id DESC LIMIT p_limit
 ), item_rows AS (
            SELECT queue.id AS queue_id, fulfillment.created_at, fulfillment.order_item_id,
              'base'::text AS line_key,
              jsonb_build_object(
                'id', fulfillment.id,
                'order_item_id', fulfillment.order_item_id,
                'line_key', 'base',
                'source_kind', 'order_item',
                'fulfillment_route', 'kitchen_tray_floor',
                'name_ko', COALESCE(NULLIF(item.label, ''),
                  NULLIF(item.display_name, ''), menu.name_ko, menu.name, '메뉴'),
                'name_vi', COALESCE(NULLIF(menu.name_vi, ''),
                  NULLIF(item.display_name, ''), menu.name, 'Món'),
                'name_en', COALESCE(NULLIF(menu.name_en, ''),
                  NULLIF(item.display_name, ''), menu.name, 'Item'),
                'combo_components', COALESCE(item.combo_components, '[]'::jsonb),
                'ordered_quantity', fulfillment.ordered_quantity,
                'kitchen_done_quantity', fulfillment.kitchen_done_quantity,
                'tray_received_quantity', fulfillment.tray_received_quantity,
                'tray_dispatched_quantity', fulfillment.tray_dispatched_quantity,
                'floor_served_quantity', fulfillment.floor_served_quantity,
                'needs_review', fulfillment.needs_review
              ) AS item_payload
            FROM visible queue
            JOIN public.emergency_fulfillment_items fulfillment ON fulfillment.queue_id=queue.id
            JOIN public.order_items item ON item.id = fulfillment.order_item_id
            LEFT JOIN public.menu_items menu ON menu.id = item.menu_item_id
            WHERE fulfillment.queue_id = queue.id
              AND fulfillment.is_cancelled = false

            UNION ALL

            SELECT queue.id AS queue_id, direct.created_at, direct.order_item_id, direct.line_key,
              jsonb_build_object(
                'id', direct.id,
                'order_item_id', direct.order_item_id,
                'line_key', direct.line_key,
                'source_kind', direct.source_kind,
                'fulfillment_route', 'floor_direct',
                'name_ko', direct.name_ko,
                'name_vi', direct.name_vi,
                'name_en', direct.name_en,
                'combo_components', '[]'::jsonb,
                'ordered_quantity', direct.ordered_quantity,
                'kitchen_done_quantity', 0,
                'tray_received_quantity', 0,
                'tray_dispatched_quantity', 0,
                'floor_served_quantity', direct.floor_served_quantity,
                'needs_review', direct.needs_review
              ) AS item_payload
            FROM visible queue
            JOIN public.emergency_floor_direct_items direct ON direct.queue_id=queue.id
            WHERE true
              AND direct.is_cancelled = false

 ), grouped_items AS (
  SELECT queue_id,jsonb_agg(item_payload ORDER BY created_at,order_item_id,line_key) items
  FROM item_rows GROUP BY queue_id
 ), recent_actions AS MATERIALIZED (
  SELECT DISTINCT ON (a.queue_id) a.queue_id,a.action_id
  FROM visible q JOIN public.emergency_fulfillment_actions a ON a.queue_id=q.id
  WHERE a.station_type=v_assignment.station_type AND a.action_kind='complete'
   AND NOT EXISTS(SELECT 1 FROM public.emergency_fulfillment_actions r
    WHERE r.original_action_id=a.action_id AND r.action_kind='revert')
  ORDER BY a.queue_id,a.created_at DESC,a.action_id DESC
 ), payloads AS (
  SELECT queue.id,queue.completed_at,
      jsonb_build_object(
        'queue_id', queue.id,
        'order_id', queue.order_id,
        'queue_no', queue.queue_no,
        'table_number', queue.table_number,
        'floor_label', queue.floor_label,
        'created_at', queue.created_at,
        'last_action_id', recent.action_id,
        'last_action_at', queue.completed_at,
        'items', COALESCE(grouped.items, '[]'::jsonb)
      ) AS payload
  FROM visible queue LEFT JOIN grouped_items grouped ON grouped.queue_id=queue.id
  LEFT JOIN recent_actions recent ON recent.queue_id=queue.id
 )
 SELECT jsonb_build_object(
  'orders',coalesce((SELECT jsonb_agg(payload ORDER BY completed_at DESC,id DESC) FROM payloads),'[]'::jsonb),
  'has_more',(SELECT count(*)>p_limit FROM candidates),
  'next_cursor',(SELECT jsonb_build_object('completed_at',completed_at,'queue_id',id)
   FROM visible ORDER BY completed_at,id LIMIT 1)
 ) INTO v_result;
 RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION public.jeongabok_kds_completed_core_v1(integer,timestamptz,uuid) FROM PUBLIC,anon,authenticated;


CREATE FUNCTION public.jeongabok_kds_station_timings_v3(p_orders jsonb,p_station text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH requested AS MATERIALIZED (
  SELECT o.value,o.ordinality ord,q.id,q.restaurant_id,q.session_id,q.order_id,q.created_at
  FROM jsonb_array_elements(p_orders) WITH ORDINALITY o
  JOIN public.emergency_order_queue q ON q.id=(o.value->>'queue_id')::uuid
  WHERE q.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849'
 ), times AS MATERIALIZED (
  SELECT q.id,min(e.created_at) FILTER(WHERE e.stage='kitchen_done') previous_at,
   max(e.created_at) FILTER(WHERE e.stage=CASE p_station WHEN 'kitchen' THEN 'kitchen_done' ELSE 'floor_served' END) completed_at
  FROM requested q JOIN public.emergency_fulfillment_events e
   ON e.restaurant_id=q.restaurant_id AND e.session_id=q.session_id AND e.order_id=q.order_id
  WHERE e.delta>0 GROUP BY q.id
 ), direct AS MATERIALIZED (
  SELECT DISTINCT d.queue_id FROM requested q JOIN public.emergency_floor_direct_items d ON d.queue_id=q.id WHERE NOT d.is_cancelled
 )
 SELECT coalesce(jsonb_agg(q.value||jsonb_strip_nulls(jsonb_build_object(
  'station_started_at',CASE WHEN p_station='kitchen' OR d.queue_id IS NOT NULL THEN q.created_at ELSE t.previous_at END,
  'station_completed_at',t.completed_at)) ORDER BY q.ord),'[]')
 FROM requested q LEFT JOIN times t USING(id) LEFT JOIN direct d ON d.queue_id=q.id;
$$;
REVOKE ALL ON FUNCTION public.jeongabok_kds_station_timings_v3(jsonb,text) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.get_jeongabok_kds_completed_page_v1(
 p_limit integer DEFAULT 50,p_before_completed_at timestamptz DEFAULT NULL,p_before_queue_id uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE v_page jsonb; v_station text;
BEGIN
 v_page:=public.jeongabok_kds_completed_core_v1(p_limit,p_before_completed_at,p_before_queue_id);
 SELECT a.station_type INTO v_station FROM public.users u
 JOIN public.emergency_station_assignments a ON a.user_id=u.id AND a.restaurant_id=u.restaurant_id AND a.is_active
 WHERE u.auth_id=auth.uid() AND u.is_active;
 RETURN (v_page||jsonb_build_object('sync',public.get_kds_sync_config()))||jsonb_build_object('orders',public.jeongabok_kds_station_timings_v3(public.jeongabok_kds_enrich_orders_v1(v_page->'orders',coalesce(v_station,'')),coalesce(v_station,'')));
END $$;
REVOKE ALL ON FUNCTION public.get_jeongabok_kds_completed_page_v1(integer,timestamptz,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_jeongabok_kds_completed_page_v1(integer,timestamptz,uuid) TO authenticated;




CREATE FUNCTION public.get_jeongabok_kds_bootstrap_v3() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE v_payload jsonb; v_config jsonb; v_workflow jsonb; v_tasks jsonb; v_day_start timestamptz;
BEGIN
 v_config:=public.get_kds_sync_config();
 v_payload:=jsonb_build_object('assigned',v_config->'assigned','active',v_config->>'session_id' IS NOT NULL,
  'session_id',v_config->'session_id','restaurant_id',v_config->'restaurant_id',
  'station_type',v_config->'station_type','floor_label',v_config->'floor_label',
  'service_area_configuration_known',v_config->'service_area_configuration_known',
  'service_area_codes',v_config->'service_area_codes',
  'activated_at',(SELECT activated_at FROM public.emergency_fulfillment_sessions WHERE id=(v_config->>'session_id')::uuid),
  'orders',public.jeongabok_kds_tickets_core_v3(NULL));
 v_config:=public.get_kds_sync_config();
 v_day_start:=date_trunc('day',now() AT TIME ZONE 'Asia/Ho_Chi_Minh') AT TIME ZONE 'Asia/Ho_Chi_Minh';
 v_workflow:=public.store_workflow_device_v1('273b057e-3b69-46e3-93c1-6194c2802849');
 IF v_workflow->>'active_id' IS NOT NULL AND v_payload->>'station_type'='kitchen' THEN
  v_payload:=v_payload||jsonb_build_object('orders','[]'::jsonb,'completed_orders','[]'::jsonb);

 END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'id',r.id,'order_id',r.order_id,'queue_id',r.queue_id,'queue_no',q.queue_no,
  'table_number',r.table_number,'floor_label',r.floor_label,'status',r.status,
  'requested_at',r.requested_at,'updated_at',r.updated_at) ORDER BY r.requested_at,r.id),'[]')
 INTO v_tasks FROM public.leftover_packaging_requests r
 JOIN public.emergency_order_queue q ON q.id=r.queue_id
 WHERE r.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849'
  AND q.restaurant_id=r.restaurant_id AND r.session_id=(v_payload->>'session_id')::uuid
  AND r.requested_at>=v_day_start AND r.requested_at<v_day_start+interval '1 day'
  AND ((v_payload->>'station_type'='floor'
    AND r.floor_label=ANY(ARRAY(SELECT jsonb_array_elements_text(v_config->'service_area_codes')))
    AND r.status IN ('awaiting_floor_pickup','awaiting_floor_delivery'))
   OR (v_payload->>'station_type'='tray' AND r.status IN ('awaiting_tray_to_kitchen','awaiting_tray_return'))
   OR (v_payload->>'station_type'='kitchen' AND r.status='awaiting_kitchen_packaging'));
 IF v_workflow->>'active_id' IS NOT NULL AND v_payload->>'station_type'='kitchen'
  AND v_workflow->'station'->>'id' IS DISTINCT FROM (
   SELECT coalesce(r.definition->>'packaging_station_id',r.definition->'default_path'->>0)
   FROM public.store_workflow_releases r WHERE r.id=(v_workflow->>'active_id')::uuid
  ) THEN v_tasks:='[]'; END IF;
 v_payload:=v_payload||jsonb_build_object('leftover_packaging_tasks',v_tasks,
  'operating_workflow',v_workflow,'kitchen_direct_to_floor',
  public.kds_uses_direct_floor_workflow('273b057e-3b69-46e3-93c1-6194c2802849'));
 RETURN jsonb_build_object('sync',v_config,'snapshot',v_payload,
  'completed_orders','[]'::jsonb,'timings','[]'::jsonb,
  'fulfillment_mode',coalesce(public.get_store_fulfillment_mode('273b057e-3b69-46e3-93c1-6194c2802849'),'paperless'));
END $$;
REVOKE ALL ON FUNCTION public.get_jeongabok_kds_bootstrap_v3() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_jeongabok_kds_bootstrap_v3() TO authenticated;

DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname LIKE 'jeongabok_kds_%'
   AND (has_function_privilege('anon',p.oid,'EXECUTE') OR has_function_privilege('authenticated',p.oid,'EXECUTE'))) THEN
  RAISE EXCEPTION 'JEONGABOK_PRIVATE_READER_EXPOSED'; END IF;
 IF position('get_kds_ticket_v2' IN pg_get_functiondef('public.jeongabok_kds_tickets_core_v3(uuid[])'::regprocedure))>0 THEN
  RAISE EXCEPTION 'JEONGABOK_BATCH_MUST_BE_SET_BASED'; END IF;
END $$;
NOTIFY pgrst,'reload schema';
COMMIT;
