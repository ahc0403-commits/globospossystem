-- Additional kitchen stages project only their final handoff into the existing
-- tray/floor FIFO ledger. No stock or payment is posted by preparation stages.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.store_preparation_tasks (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
 release_id uuid NOT NULL, order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE, order_item_id uuid NOT NULL REFERENCES public.order_items(id) ON DELETE CASCADE,
 source_kind text NOT NULL CHECK(source_kind IN ('base','combo_component','direct_ticket')), source_id uuid NOT NULL,
 menu_item_id uuid NOT NULL, ticket_id uuid, created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY(restaurant_id,release_id) REFERENCES public.store_workflow_releases(restaurant_id,id) ON DELETE CASCADE,
 UNIQUE(source_kind,source_id), UNIQUE(restaurant_id,id)
);
CREATE INDEX store_preparation_tasks_order ON public.store_preparation_tasks(order_id,order_item_id);
CREATE INDEX store_preparation_tasks_item ON public.store_preparation_tasks(order_item_id);
CREATE TABLE public.store_preparation_steps (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), restaurant_id uuid NOT NULL,
 task_id uuid NOT NULL, station_id uuid NOT NULL, position integer NOT NULL CHECK(position BETWEEN 1 AND 8),
 started integer NOT NULL DEFAULT 0, done integer NOT NULL DEFAULT 0, revision bigint NOT NULL DEFAULT 0,
 started_at timestamptz, done_at timestamptz, updated_by uuid,
 FOREIGN KEY(restaurant_id,task_id) REFERENCES public.store_preparation_tasks(restaurant_id,id) ON DELETE CASCADE,
 FOREIGN KEY(restaurant_id,station_id) REFERENCES public.store_service_stations(restaurant_id,id) ON DELETE CASCADE,
 UNIQUE(task_id,position), CHECK(done>=0 AND started>=done)
);
CREATE INDEX store_preparation_steps_station ON public.store_preparation_steps(restaurant_id,station_id,task_id);
CREATE TABLE public.store_preparation_events (
 id uuid PRIMARY KEY, restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE, actor_id uuid NOT NULL,
 payload jsonb NOT NULL, response jsonb NOT NULL, before_steps jsonb NOT NULL DEFAULT '[]', after_steps jsonb NOT NULL DEFAULT '[]', created_at timestamptz NOT NULL DEFAULT now()
);
CREATE VIEW public.store_preparation_sources WITH (security_invoker=true) AS
 SELECT i.restaurant_id,i.order_id,i.order_item_id,'base'::text source_kind,i.id source_id,oi.menu_item_id,
  i.queue_id,ticket.id ticket_id,i.ordered_quantity-i.excused_quantity quantity,i.is_cancelled OR i.needs_review OR coalesce(ticket.status IN ('completed','cancelled'),false) blocked,
  coalesce(nullif(oi.menu_option_snapshot->>'name_ko',''),nullif(menu.name_ko,''),oi.display_name) name_ko,
  coalesce(nullif(oi.menu_option_snapshot->>'name_vi',''),nullif(menu.name_vi,''),oi.display_name) name_vi,
  coalesce(nullif(oi.menu_option_snapshot->>'name_en',''),nullif(menu.name_en,''),oi.display_name) name_en,oi.notes,q.table_number,q.floor_label,i.created_at
 FROM public.emergency_fulfillment_items i JOIN public.order_items oi ON oi.id=i.order_item_id LEFT JOIN public.menu_items menu ON menu.id=oi.menu_item_id JOIN public.emergency_order_queue q ON q.id=i.queue_id
 LEFT JOIN public.direct_order_financials financials ON financials.order_id=i.order_id
 LEFT JOIN public.direct_delivery_fulfillment_tickets ticket ON ticket.request_id=financials.request_id
 WHERE NOT EXISTS(SELECT 1 FROM public.emergency_combo_component_items c WHERE c.order_item_id=i.order_item_id AND NOT c.is_cancelled)
 AND coalesce(oi.fulfillment_route_snapshot,'kitchen_tray_floor')<>'floor_direct'
 UNION ALL
 SELECT i.restaurant_id,i.order_id,i.order_item_id,'combo_component',i.id,i.component_menu_item_id,
  i.queue_id,ticket.id,i.ordered_quantity-i.excused_quantity,i.is_cancelled OR i.needs_review OR coalesce(ticket.status IN ('completed','cancelled'),false),
  i.name_ko,i.name_vi,i.name_en,oi.notes,q.table_number,q.floor_label,i.created_at
 FROM public.emergency_combo_component_items i JOIN public.order_items oi ON oi.id=i.order_item_id JOIN public.emergency_order_queue q ON q.id=i.queue_id
 LEFT JOIN public.direct_order_financials financials ON financials.order_id=i.order_id
 LEFT JOIN public.direct_delivery_fulfillment_tickets ticket ON ticket.request_id=financials.request_id
 UNION ALL
 SELECT i.restaurant_id,o.id,oi.id,'direct_ticket',i.id,oi.menu_item_id,NULL::uuid,t.id,i.quantity,t.status IN ('cancelled','completed') OR oi.status='cancelled',
  i.display_name_ko,i.display_name_vi,i.display_name_en,oi.notes,t.pickup_code,NULL::text,t.created_at
 FROM public.direct_delivery_fulfillment_ticket_items i JOIN public.direct_delivery_fulfillment_tickets t ON t.id=i.ticket_id
 JOIN public.direct_order_financials f ON f.request_id=t.request_id JOIN public.orders o ON o.id=f.order_id
 JOIN public.order_items oi ON oi.id=i.id
 WHERE NOT EXISTS(SELECT 1 FROM public.emergency_fulfillment_items b WHERE b.order_id=o.id AND NOT b.is_cancelled)
 AND NOT EXISTS(SELECT 1 FROM public.emergency_combo_component_items c WHERE c.order_id=o.id AND NOT c.is_cancelled);

CREATE FUNCTION public.store_preparation_seed(p_order_ids uuid[]) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF current_setting('globos.cashier_item_mutation',true)='on' OR nullif(current_setting('app.direct_order_request_id',true),'') IS NOT NULL THEN RETURN; END IF;
 WITH added AS (
  INSERT INTO public.store_preparation_tasks(restaurant_id,release_id,order_id,order_item_id,source_kind,source_id,menu_item_id,ticket_id,created_at)
  SELECT s.restaurant_id,o.operating_release_id,s.order_id,s.order_item_id,s.source_kind,s.source_id,s.menu_item_id,s.ticket_id,s.created_at
  FROM public.store_preparation_sources s JOIN public.orders o ON o.id=s.order_id
  WHERE s.order_id=ANY(p_order_ids) AND o.operating_release_id IS NOT NULL AND NOT s.blocked
  ON CONFLICT(source_kind,source_id) DO NOTHING RETURNING *
 ) INSERT INTO public.store_preparation_steps(restaurant_id,task_id,station_id,position)
 SELECT t.restaurant_id,t.id,p.station::uuid,p.n FROM added t JOIN public.orders o ON o.id=t.order_id
 JOIN public.store_workflow_releases r ON r.id=t.release_id JOIN public.menu_items m ON m.id=t.menu_item_id JOIN public.order_items oi ON oi.id=t.order_item_id
 CROSS JOIN LATERAL jsonb_array_elements_text(public.store_workflow_path(r.definition,t.menu_item_id,CASE WHEN oi.is_takeout THEN 'pickup' ELSE o.sales_channel END,m.size_parent_id)) WITH ORDINALITY p(station,n);
 IF FOUND THEN PERFORM public.store_preparation_ready_notify(p_order_ids); END IF;
END;
$$;
CREATE FUNCTION public.store_preparation_seed_items() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE ids uuid[];
BEGIN
 SELECT array_agg(DISTINCT order_id) INTO ids FROM new_workflow_items;
 PERFORM public.store_preparation_seed(ids); RETURN NULL;
END;
$$;
CREATE TRIGGER zzzz_workflow_seed AFTER INSERT ON public.order_items REFERENCING NEW TABLE AS new_workflow_items FOR EACH STATEMENT EXECUTE FUNCTION public.store_preparation_seed_items();
CREATE TRIGGER zzzz_workflow_seed AFTER INSERT ON public.direct_order_financials REFERENCING NEW TABLE AS new_workflow_items FOR EACH STATEMENT EXECUTE FUNCTION public.store_preparation_seed_items();
CREATE FUNCTION public.store_preparation_seed_tickets() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE ids uuid[];
BEGIN
 SELECT array_agg(DISTINCT f.order_id) INTO ids FROM new_workflow_tickets i JOIN public.direct_delivery_fulfillment_tickets t ON t.id=i.ticket_id JOIN public.direct_order_financials f ON f.request_id=t.request_id;
 PERFORM public.store_preparation_seed(ids); RETURN NULL;
END;
$$;
CREATE TRIGGER zzzz_workflow_seed AFTER INSERT ON public.direct_delivery_fulfillment_ticket_items REFERENCING NEW TABLE AS new_workflow_tickets FOR EACH STATEMENT EXECUTE FUNCTION public.store_preparation_seed_tickets();

-- Enforce the protocol at the data boundary, including older callable RPC aliases.
CREATE FUNCTION public.store_preparation_guard_legacy() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF current_setting('globos.workflow_projection',true)='on' OR current_setting('globos.cashier_item_mutation',true) IN ('on','repair') THEN RETURN NULL; END IF;
 IF EXISTS(SELECT 1 FROM public.store_workflow_devices d JOIN public.users u ON u.id=d.user_id WHERE u.auth_id=auth.uid() AND d.quiesced) AND EXISTS(SELECT 1 FROM new_workflow_progress n JOIN old_workflow_progress o USING(id) WHERE n.kitchen_started_quantity>o.kitchen_started_quantity OR n.kitchen_done_quantity>o.kitchen_done_quantity OR n.tray_dispatched_quantity>o.tray_dispatched_quantity OR n.floor_served_quantity>o.floor_served_quantity) THEN RAISE EXCEPTION 'WORKFLOW_DEVICE_QUIESCED'; END IF;
 IF EXISTS(SELECT 1 FROM new_workflow_progress n JOIN old_workflow_progress o USING(id)
  JOIN public.store_preparation_tasks t ON t.source_id=n.id
  WHERE n.kitchen_started_quantity IS DISTINCT FROM o.kitchen_started_quantity OR n.kitchen_done_quantity IS DISTINCT FROM o.kitchen_done_quantity)
 THEN RAISE EXCEPTION 'WORKFLOW_CLIENT_UPDATE_REQUIRED'; END IF;
 RETURN NULL;
END;
$$;
CREATE TRIGGER workflow_legacy_guard AFTER UPDATE ON public.emergency_fulfillment_items REFERENCING OLD TABLE AS old_workflow_progress NEW TABLE AS new_workflow_progress FOR EACH STATEMENT EXECUTE FUNCTION public.store_preparation_guard_legacy();
CREATE TRIGGER workflow_legacy_guard AFTER UPDATE ON public.emergency_combo_component_items REFERENCING OLD TABLE AS old_workflow_progress NEW TABLE AS new_workflow_progress FOR EACH STATEMENT EXECUTE FUNCTION public.store_preparation_guard_legacy();
CREATE FUNCTION public.store_preparation_guard_ticket() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM public.store_preparation_tasks t JOIN public.store_preparation_steps s ON s.task_id=t.id
  JOIN public.store_preparation_sources src ON src.source_id=t.source_id AND src.source_kind=t.source_kind
  WHERE t.ticket_id=NEW.id AND NOT src.blocked AND s.done<src.quantity)
  AND (NEW.cooking_completed_at IS NOT NULL AND NEW.cooking_completed_at IS DISTINCT FROM OLD.cooking_completed_at OR NEW.status IN ('ready','dispatched','completed') AND NEW.status<>OLD.status)
 THEN RAISE EXCEPTION 'WORKFLOW_PREPARATION_INCOMPLETE'; END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER workflow_ticket_guard BEFORE UPDATE ON public.direct_delivery_fulfillment_tickets FOR EACH ROW EXECUTE FUNCTION public.store_preparation_guard_ticket();

CREATE FUNCTION public.store_workflow_device_v1(p_store_id uuid,p_device_id uuid DEFAULT NULL,p_release_id uuid DEFAULT NULL,p_pending_count integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE usr public.users%ROWTYPE; cfg public.store_workflow_configs%ROWTYPE; station jsonb; definition jsonb;
BEGIN
 SELECT * INTO usr FROM public.users WHERE auth_id=auth.uid() AND restaurant_id=p_store_id AND is_active;
 IF NOT FOUND THEN RAISE EXCEPTION 'WORKFLOW_ACTOR_REQUIRED'; END IF;
 SELECT * INTO cfg FROM public.store_workflow_configs WHERE restaurant_id=p_store_id;
 IF p_release_id IS NOT NULL THEN
  IF p_device_id IS NULL OR p_pending_count IS NULL OR p_pending_count NOT BETWEEN -1 AND 10000 OR (p_release_id IS DISTINCT FROM cfg.candidate_id AND p_release_id IS DISTINCT FROM cfg.active_id)
   OR NOT EXISTS(SELECT 1 FROM public.emergency_station_assignments WHERE restaurant_id=p_store_id AND user_id=usr.id AND is_active)
  THEN RAISE EXCEPTION 'WORKFLOW_DEVICE_INVALID'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.store_workflow_devices WHERE restaurant_id=p_store_id AND user_id=usr.id AND device_id=p_device_id)
   AND (SELECT count(*) FROM public.store_workflow_devices WHERE restaurant_id=p_store_id AND user_id=usr.id)>=10 THEN RAISE EXCEPTION 'WORKFLOW_DEVICE_LIMIT'; END IF;
  INSERT INTO public.store_workflow_devices(restaurant_id,user_id,device_id,release_id,pending_count,quiesced) VALUES(p_store_id,usr.id,p_device_id,p_release_id,greatest(0,p_pending_count),p_pending_count=0 AND p_release_id IS DISTINCT FROM cfg.active_id)
   ON CONFLICT(restaurant_id,user_id,device_id) DO UPDATE SET release_id=excluded.release_id,pending_count=excluded.pending_count,quiesced=excluded.quiesced,seen_at=now();
 END IF;
 SELECT r.definition INTO definition FROM public.store_workflow_releases r WHERE r.id=cfg.active_id;
 SELECT s INTO station FROM jsonb_array_elements(definition->'stations')s WHERE s->'user_ids' ? usr.id::text;
 RETURN jsonb_build_object('quiesced',EXISTS(SELECT 1 FROM public.store_workflow_devices d WHERE d.restaurant_id=p_store_id AND d.user_id=usr.id AND d.quiesced),'active_id',cfg.active_id,'candidate_id',cfg.candidate_id,'revision',coalesce(cfg.revision,0),'station',station,
 'candidate_station',(SELECT s FROM public.store_workflow_releases r,jsonb_array_elements(r.definition->'stations')s WHERE r.id=cfg.candidate_id AND s->'user_ids' ? usr.id::text),
 'candidate_definition_hash',(SELECT md5(v.definition::text) FROM public.store_workflow_releases v WHERE v.id=cfg.candidate_id));
END;
$$;
CREATE FUNCTION public.store_preparation_snapshot_v1(p_store_id uuid,p_after timestamptz DEFAULT NULL,p_after_id uuid DEFAULT NULL,p_completed boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE usr public.users%ROWTYPE; release uuid; station jsonb; result jsonb;
BEGIN
 SELECT * INTO usr FROM public.users WHERE auth_id=auth.uid() AND restaurant_id=p_store_id AND is_active;
 IF NOT FOUND THEN RAISE EXCEPTION 'WORKFLOW_ACTOR_REQUIRED'; END IF;
 SELECT c.active_id,s INTO release,station FROM public.store_workflow_configs c JOIN public.store_workflow_releases r ON r.id=c.active_id,
 jsonb_array_elements(r.definition->'stations')s WHERE c.restaurant_id=p_store_id AND s->'user_ids' ? usr.id::text;
 IF station IS NULL OR NOT EXISTS(SELECT 1 FROM public.emergency_station_assignments WHERE restaurant_id=p_store_id AND user_id=usr.id AND is_active AND station_type='kitchen') THEN RAISE EXCEPTION 'WORKFLOW_STATION_FORBIDDEN'; END IF;
 WITH rows AS MATERIALIZED (
  SELECT s.id,s.task_id,s.position,s.started,s.done,s.revision,s.started_at,s.done_at,t.created_at,
   src.quantity,src.name_ko,src.name_vi,src.name_en,src.notes,src.table_number,src.floor_label,
   coalesce(prev.done,src.quantity) available,coalesce(prev.done_at,t.created_at) ready_at,
   greatest(0,s.started-s.done) undo_start_available,
   greatest(0,s.done-CASE WHEN next_step.id IS NOT NULL THEN next_step.started WHEN ticket.id IS NOT NULL AND ticket.status NOT IN ('pending','preparing') THEN s.done WHEN t.source_kind='direct_ticket' THEN 0 WHEN queue.kitchen_direct_to_floor THEN coalesce(base.floor_served_quantity,component.floor_served_quantity) ELSE coalesce(base.tray_received_quantity,component.tray_received_quantity) END) undo_done_available,
   NOT EXISTS(SELECT 1 FROM public.store_preparation_steps n WHERE n.task_id=t.id AND n.position>s.position) final_step
  FROM public.store_preparation_steps s JOIN public.store_preparation_tasks t ON t.id=s.task_id
  JOIN public.store_preparation_sources src ON src.source_id=t.source_id AND src.source_kind=t.source_kind
  LEFT JOIN public.store_preparation_steps prev ON prev.task_id=t.id AND prev.position=s.position-1
  LEFT JOIN public.store_preparation_steps next_step ON next_step.task_id=t.id AND next_step.position=s.position+1
  LEFT JOIN public.emergency_fulfillment_items base ON t.source_kind='base' AND base.id=t.source_id
  LEFT JOIN public.emergency_combo_component_items component ON t.source_kind='combo_component' AND component.id=t.source_id
  LEFT JOIN public.emergency_order_queue queue ON queue.id=coalesce(base.queue_id,component.queue_id)
  LEFT JOIN public.direct_delivery_fulfillment_tickets ticket ON ticket.id=t.ticket_id
  WHERE s.restaurant_id=p_store_id AND s.station_id=(station->>'id')::uuid AND t.release_id=release
   AND NOT src.blocked AND CASE WHEN p_completed THEN s.done>=src.quantity AND s.done_at>now()-interval '24 hours' ELSE s.done<src.quantity END AND (p_after IS NULL OR (t.created_at,s.id)>(p_after,p_after_id))
  ORDER BY t.created_at,s.id LIMIT 101
 ) SELECT jsonb_build_object('release_id',release,'station',station,'has_more',(SELECT count(*)>100 FROM rows),
   'items',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY created_at,id) FROM (SELECT * FROM rows ORDER BY created_at,id LIMIT 100)x),'[]'::jsonb)) INTO result;
 RETURN result;
END;
$$;
CREATE FUNCTION public.store_preparation_trim_lots(p_source_ids uuid[]) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE lot_table text; used text; allowed text;
BEGIN
 FOREACH lot_table IN ARRAY ARRAY['emergency_floor_ready_lots','emergency_tray_ready_lots'] LOOP
  used:=CASE lot_table WHEN 'emergency_floor_ready_lots' THEN 'served_quantity' ELSE 'handed_quantity' END;
  allowed:=CASE lot_table WHEN 'emergency_floor_ready_lots' THEN 'tray_dispatched_quantity-floor_served_quantity' ELSE 'kitchen_done_quantity-tray_dispatched_quantity' END;
  EXECUTE format($trim$
   WITH sources AS(SELECT id,%s allowed FROM public.emergency_fulfillment_items WHERE id=ANY($1) UNION ALL SELECT id,%s FROM public.emergency_combo_component_items WHERE id=ANY($1)),
   lots AS MATERIALIZED(SELECT l.id,l.source_id,l.ready_sequence,l.ready_quantity-l.%I-l.voided_quantity remaining,s.allowed FROM public.%I l JOIN sources s ON s.id=l.source_id FOR UPDATE OF l),
   allocations AS(SELECT id,remaining,greatest(0,sum(remaining)OVER(PARTITION BY source_id)-allowed) excess,coalesce(sum(remaining)OVER(PARTITION BY source_id ORDER BY ready_sequence DESC,id DESC ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) prior FROM lots)
   UPDATE public.%I l SET voided_quantity=l.voided_quantity+greatest(0,least(a.remaining,a.excess-a.prior))::integer,updated_at=now() FROM allocations a WHERE l.id=a.id AND a.excess>a.prior AND a.remaining>0
  $trim$,allowed,allowed,used,lot_table,lot_table) USING p_source_ids;
 END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.store_preparation_trim_lots(uuid[]) FROM PUBLIC,anon,authenticated,service_role;

-- Multi-kitchen start is already counted before final handoff. Keep the legacy
-- Bunsik implicit-start behavior for legacy callers, but never count it twice
-- when the versioned preparation protocol projects its explicit final handoff.
CREATE OR REPLACE FUNCTION "public"."kds_apply_station_progress_batch_v1"("p_request_id" "uuid", "p_restaurant_id" "uuid", "p_actor_user_id" "uuid", "p_action" "text", "p_floor_label" "text", "p_allocations" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_direct boolean := public.kds_uses_direct_floor_workflow(p_restaurant_id);
  v_allocation_count integer;
  v_changed_quantity integer;
  v_matched_count integer;
  v_workflow_two_quantity integer := 0;
  v_tray_sequence_end bigint;
  v_floor_sequence_end bigint;
  v_event_ids jsonb := '[]'::jsonb;
BEGIN
  IF p_request_id IS NULL OR p_restaurant_id IS NULL
     OR p_actor_user_id IS NULL
     OR p_action NOT IN ('kitchen_done', 'tray_dispatched', 'floor_served')
     OR jsonb_typeof(p_allocations) <> 'array'
     OR jsonb_array_length(p_allocations) = 0 THEN
    RAISE EXCEPTION 'KDS_BATCH_INPUT_INVALID';
  END IF;

  SELECT count(*)::integer, COALESCE(sum(a.quantity), 0)::integer
  INTO v_allocation_count, v_changed_quantity
  FROM jsonb_to_recordset(p_allocations) AS a(
    item_id uuid, queue_id uuid, source_kind text, quantity integer
  );
  IF v_allocation_count > 1000 OR v_changed_quantity <= 0
     OR v_changed_quantity > 1000 OR EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_allocations) AS a(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
    WHERE a.item_id IS NULL
      OR a.source_kind NOT IN ('base', 'combo_component')
      OR a.quantity IS NULL OR a.quantity <= 0
  ) OR EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_allocations) AS a(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
    GROUP BY a.item_id, a.source_kind
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'KDS_BATCH_INPUT_INVALID';
  END IF;

  -- A single global lock order prevents two mixed base/combo batches from
  -- deadlocking while still allowing different stores to progress in parallel.
  BEGIN
    PERFORM item.id
    FROM public.emergency_fulfillment_items item
    JOIN jsonb_to_recordset(p_allocations) AS allocation(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    ) ON allocation.item_id = item.id
      AND allocation.source_kind = 'base'
    ORDER BY item.id
    FOR UPDATE OF item NOWAIT;

    PERFORM component.id
    FROM public.emergency_combo_component_items component
    JOIN jsonb_to_recordset(p_allocations) AS allocation(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    ) ON allocation.item_id = component.id
      AND allocation.source_kind = 'combo_component'
    ORDER BY component.id
    FOR UPDATE OF component NOWAIT;

    PERFORM parent.id
    FROM public.emergency_fulfillment_items parent
    JOIN (
      SELECT DISTINCT component.session_id, component.order_item_id
      FROM public.emergency_combo_component_items component
      JOIN jsonb_to_recordset(p_allocations) AS allocation(
        item_id uuid, queue_id uuid, source_kind text, quantity integer
      ) ON allocation.item_id = component.id
        AND allocation.source_kind = 'combo_component'
    ) affected ON affected.session_id = parent.session_id
      AND affected.order_item_id = parent.order_item_id
    ORDER BY parent.id
    FOR UPDATE OF parent NOWAIT;
  EXCEPTION WHEN lock_not_available THEN
    RAISE EXCEPTION 'KDS_BATCH_STALE';
  END;

  WITH allocations AS (
    SELECT * FROM jsonb_to_recordset(p_allocations) AS a(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
  ), lines AS (
    SELECT item.id AS item_id, item.queue_id, 'base'::text AS source_kind,
      item.session_id, item.order_id, item.order_item_id,
      item.ordered_quantity, item.excused_quantity,
      item.kitchen_done_quantity, item.tray_dispatched_quantity,
      item.floor_served_quantity, queue.workflow_version,
      queue.floor_label, COALESCE(order_row.sales_channel, 'dine_in') AS channel,
      allocation.quantity
    FROM allocations allocation
    JOIN public.emergency_fulfillment_items item
      ON item.id = allocation.item_id
     AND allocation.source_kind = 'base'
    JOIN public.emergency_order_queue queue ON queue.id = item.queue_id
    JOIN public.emergency_fulfillment_sessions session
      ON session.id = item.session_id AND session.status = 'active'
    JOIN public.orders order_row ON order_row.id = item.order_id
    WHERE item.restaurant_id = p_restaurant_id
      AND item.is_cancelled = false AND item.needs_review = false
      AND (allocation.queue_id IS NULL OR allocation.queue_id = item.queue_id)
      AND NOT EXISTS (
        SELECT 1 FROM public.emergency_combo_component_items component
        WHERE component.session_id = item.session_id
          AND component.order_item_id = item.order_item_id
          AND component.is_cancelled = false
      )
    UNION ALL
    SELECT component.id, component.queue_id, 'combo_component',
      component.session_id, component.order_id, component.order_item_id,
      component.ordered_quantity, component.excused_quantity,
      component.kitchen_done_quantity, component.tray_dispatched_quantity,
      component.floor_served_quantity, queue.workflow_version,
      queue.floor_label, COALESCE(order_row.sales_channel, 'dine_in'),
      allocation.quantity
    FROM allocations allocation
    JOIN public.emergency_combo_component_items component
      ON component.id = allocation.item_id
     AND allocation.source_kind = 'combo_component'
    JOIN public.emergency_order_queue queue ON queue.id = component.queue_id
    JOIN public.emergency_fulfillment_sessions session
      ON session.id = component.session_id AND session.status = 'active'
    JOIN public.orders order_row ON order_row.id = component.order_id
    WHERE component.restaurant_id = p_restaurant_id
      AND component.is_cancelled = false AND component.needs_review = false
      AND (allocation.queue_id IS NULL OR allocation.queue_id = component.queue_id)
  )
  SELECT count(*)::integer,
    COALESCE(sum(quantity) FILTER (WHERE workflow_version = 2), 0)::integer
  INTO v_matched_count, v_workflow_two_quantity
  FROM lines
  WHERE CASE p_action
    WHEN 'kitchen_done' THEN
      kitchen_done_quantity + quantity <= ordered_quantity - excused_quantity
    WHEN 'tray_dispatched' THEN
      workflow_version = 2 AND channel <> 'delivery'
      AND upper(btrim(floor_label)) = upper(btrim(p_floor_label))
      AND tray_dispatched_quantity + quantity <= kitchen_done_quantity
    WHEN 'floor_served' THEN
      workflow_version = 2 AND channel <> 'delivery'
      AND upper(btrim(floor_label)) = upper(btrim(p_floor_label))
      AND floor_served_quantity + quantity <= tray_dispatched_quantity
    ELSE false END;

  IF v_matched_count <> v_allocation_count THEN
    RAISE EXCEPTION 'KDS_BATCH_STALE';
  END IF;

  IF p_action = 'tray_dispatched' AND EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_allocations) AS allocation(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
    LEFT JOIN LATERAL (
      SELECT COALESCE(sum(
        lot.ready_quantity - lot.handed_quantity - lot.voided_quantity
      ), 0)::integer AS available
      FROM public.emergency_tray_ready_lots lot
      WHERE lot.source_kind = allocation.source_kind
        AND lot.source_id = allocation.item_id
    ) ready ON true
    WHERE ready.available < allocation.quantity
  ) THEN
    RAISE EXCEPTION 'KDS_BATCH_STALE';
  END IF;

  IF p_action = 'floor_served' AND EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_allocations) AS allocation(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
    LEFT JOIN LATERAL (
      SELECT COALESCE(sum(
        lot.ready_quantity - lot.served_quantity - lot.voided_quantity
      ), 0)::integer AS available
      FROM public.emergency_floor_ready_lots lot
      WHERE lot.source_kind = allocation.source_kind
        AND lot.source_id = allocation.item_id
    ) ready ON true
    WHERE ready.available < allocation.quantity
  ) THEN
    RAISE EXCEPTION 'KDS_BATCH_STALE';
  END IF;

  IF p_action = 'kitchen_done' AND NOT v_direct AND v_workflow_two_quantity > 0 THEN
    INSERT INTO public.emergency_tray_ready_sequences AS sequence(
      restaurant_id, current_sequence, updated_at
    ) VALUES (p_restaurant_id, v_workflow_two_quantity, now())
    ON CONFLICT (restaurant_id) DO UPDATE
    SET current_sequence = sequence.current_sequence
          + EXCLUDED.current_sequence,
        updated_at = now()
    RETURNING current_sequence INTO v_tray_sequence_end;

    WITH allocations AS (
      SELECT * FROM jsonb_to_recordset(p_allocations) AS a(
        item_id uuid, queue_id uuid, source_kind text, quantity integer
      )
    ), lines AS (
      SELECT item.id AS item_id, item.session_id, item.queue_id, item.order_id,
        item.order_item_id, 'base'::text AS source_kind, allocation.quantity,
        queue.created_at, queue.queue_no
      FROM allocations allocation
      JOIN public.emergency_fulfillment_items item
        ON item.id = allocation.item_id AND allocation.source_kind = 'base'
      JOIN public.emergency_order_queue queue
        ON queue.id = item.queue_id AND queue.workflow_version = 2
      UNION ALL
      SELECT component.id, component.session_id, component.queue_id,
        component.order_id, component.order_item_id, 'combo_component',
        allocation.quantity, queue.created_at, queue.queue_no
      FROM allocations allocation
      JOIN public.emergency_combo_component_items component
        ON component.id = allocation.item_id
       AND allocation.source_kind = 'combo_component'
      JOIN public.emergency_order_queue queue
        ON queue.id = component.queue_id AND queue.workflow_version = 2
    ), ranked AS (
      SELECT lines.*,
        COALESCE(sum(quantity) OVER (
          ORDER BY created_at, queue_no, queue_id, source_kind, item_id
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ), 0)::bigint AS sequence_offset
      FROM lines
    )
    INSERT INTO public.emergency_tray_ready_lots(
      restaurant_id, session_id, queue_id, order_id, order_item_id,
      source_kind, source_id, kitchen_event_id, ready_sequence, ready_quantity
    )
    SELECT p_restaurant_id, ranked.session_id, ranked.queue_id,
      ranked.order_id, ranked.order_item_id, ranked.source_kind, ranked.item_id,
      md5(p_request_id::text || ':kitchen_done:' || ranked.source_kind || ':'
        || ranked.item_id::text)::uuid,
      v_tray_sequence_end - v_workflow_two_quantity
        + ranked.sequence_offset + 1,
      ranked.quantity
    FROM ranked;
  END IF;

  IF p_action = 'tray_dispatched' OR (v_direct AND p_action = 'kitchen_done') THEN
    WITH allocations AS (
      SELECT * FROM jsonb_to_recordset(p_allocations) AS a(
        item_id uuid, queue_id uuid, source_kind text, quantity integer
      )
    ), candidates AS (
      SELECT lot.id, allocation.item_id, allocation.source_kind,
        allocation.quantity,
        lot.ready_quantity - lot.handed_quantity - lot.voided_quantity
          AS available,
        COALESCE(sum(
          lot.ready_quantity - lot.handed_quantity - lot.voided_quantity
        ) OVER (
          PARTITION BY allocation.item_id, allocation.source_kind
          ORDER BY lot.ready_sequence, lot.id
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ), 0)::integer AS consumed_before
      FROM allocations allocation
      JOIN public.emergency_tray_ready_lots lot
        ON lot.source_kind = allocation.source_kind
       AND lot.source_id = allocation.item_id
       AND lot.handed_quantity + lot.voided_quantity < lot.ready_quantity
    ), consumed AS (
      SELECT id, LEAST(
        available, GREATEST(quantity - consumed_before, 0)
      )::integer AS take_quantity
      FROM candidates
    )
    UPDATE public.emergency_tray_ready_lots lot
    SET handed_quantity = lot.handed_quantity + consumed.take_quantity,
        updated_at = now()
    FROM consumed
    WHERE lot.id = consumed.id AND consumed.take_quantity > 0;

    INSERT INTO public.emergency_floor_ready_sequences AS sequence(
      restaurant_id, current_sequence, updated_at
    ) VALUES (p_restaurant_id, v_changed_quantity, now())
    ON CONFLICT (restaurant_id) DO UPDATE
    SET current_sequence = sequence.current_sequence
          + EXCLUDED.current_sequence,
        updated_at = now()
    RETURNING current_sequence INTO v_floor_sequence_end;

    WITH allocations AS (
      SELECT * FROM jsonb_to_recordset(p_allocations) AS a(
        item_id uuid, queue_id uuid, source_kind text, quantity integer
      )
    ), lines AS (
      SELECT item.id AS item_id, item.session_id, item.queue_id, item.order_id,
        item.order_item_id, 'base'::text AS source_kind, allocation.quantity,
        queue.created_at, queue.queue_no
      FROM allocations allocation
      JOIN public.emergency_fulfillment_items item
        ON item.id = allocation.item_id AND allocation.source_kind = 'base'
      JOIN public.emergency_order_queue queue ON queue.id = item.queue_id
      UNION ALL
      SELECT component.id, component.session_id, component.queue_id,
        component.order_id, component.order_item_id, 'combo_component',
        allocation.quantity, queue.created_at, queue.queue_no
      FROM allocations allocation
      JOIN public.emergency_combo_component_items component
        ON component.id = allocation.item_id
       AND allocation.source_kind = 'combo_component'
      JOIN public.emergency_order_queue queue ON queue.id = component.queue_id
    ), ranked AS (
      SELECT lines.*,
        COALESCE(sum(quantity) OVER (
          ORDER BY created_at, queue_no, queue_id, source_kind, item_id
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ), 0)::bigint AS sequence_offset
      FROM lines
    )
    INSERT INTO public.emergency_floor_ready_lots(
      restaurant_id, session_id, queue_id, order_id, order_item_id,
      source_kind, source_id, ready_action_id, ready_sequence, ready_quantity
    )
    SELECT p_restaurant_id, ranked.session_id, ranked.queue_id,
      ranked.order_id, ranked.order_item_id, ranked.source_kind, ranked.item_id,
      md5(p_request_id::text || ':' || p_action || ':' || ranked.source_kind || ':'
        || ranked.item_id::text)::uuid,
      v_floor_sequence_end - v_changed_quantity
        + ranked.sequence_offset + 1,
      ranked.quantity
    FROM ranked
    WHERE NOT v_direct OR (NOT EXISTS (
      SELECT 1 FROM public.orders o WHERE o.id = ranked.order_id AND o.sales_channel = 'delivery'
    ) AND NOT EXISTS (SELECT 1 FROM public.direct_order_financials f
      JOIN public.direct_order_requests r ON r.id = f.request_id AND r.fulfillment_type = 'pickup'
      WHERE f.order_id = ranked.order_id AND f.restaurant_id = p_restaurant_id));
  ELSIF p_action = 'floor_served' THEN
    WITH allocations AS (
      SELECT * FROM jsonb_to_recordset(p_allocations) AS a(
        item_id uuid, queue_id uuid, source_kind text, quantity integer
      )
    ), candidates AS (
      SELECT lot.id, allocation.item_id, allocation.source_kind,
        allocation.quantity,
        lot.ready_quantity - lot.served_quantity - lot.voided_quantity
          AS available,
        COALESCE(sum(
          lot.ready_quantity - lot.served_quantity - lot.voided_quantity
        ) OVER (
          PARTITION BY allocation.item_id, allocation.source_kind
          ORDER BY lot.ready_sequence, lot.id
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ), 0)::integer AS consumed_before
      FROM allocations allocation
      JOIN public.emergency_floor_ready_lots lot
        ON lot.source_kind = allocation.source_kind
       AND lot.source_id = allocation.item_id
       AND lot.served_quantity + lot.voided_quantity < lot.ready_quantity
    ), consumed AS (
      SELECT id, LEAST(
        available, GREATEST(quantity - consumed_before, 0)
      )::integer AS take_quantity
      FROM candidates
    )
    UPDATE public.emergency_floor_ready_lots lot
    SET served_quantity = lot.served_quantity + consumed.take_quantity,
        updated_at = now()
    FROM consumed
    WHERE lot.id = consumed.id AND consumed.take_quantity > 0;
  END IF;

  WITH allocations AS (
    SELECT * FROM jsonb_to_recordset(p_allocations) AS a(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
  )
  UPDATE public.emergency_fulfillment_items item
  SET kitchen_started_quantity = CASE WHEN p_action = 'kitchen_done'
        THEN CASE WHEN v_direct OR current_setting('globos.workflow_projection',true)='on' THEN greatest(item.kitchen_started_quantity,
        item.kitchen_done_quantity + allocation.quantity)
        ELSE item.kitchen_started_quantity + allocation.quantity END
        ELSE item.kitchen_started_quantity END,
      kitchen_done_quantity = CASE WHEN p_action = 'kitchen_done'
        THEN item.kitchen_done_quantity + allocation.quantity
        ELSE item.kitchen_done_quantity END,
      tray_received_quantity = CASE WHEN p_action = 'tray_dispatched' OR (v_direct AND p_action = 'kitchen_done')
        THEN item.tray_received_quantity + allocation.quantity
        ELSE item.tray_received_quantity END,
      tray_dispatched_quantity = CASE WHEN p_action = 'tray_dispatched' OR (v_direct AND p_action = 'kitchen_done')
        THEN item.tray_dispatched_quantity + allocation.quantity
        ELSE item.tray_dispatched_quantity END,
      floor_served_quantity = CASE WHEN p_action = 'floor_served'
        THEN item.floor_served_quantity + allocation.quantity
        ELSE item.floor_served_quantity END,
      updated_at = now()
  FROM allocations allocation
  WHERE allocation.source_kind = 'base' AND item.id = allocation.item_id;

  WITH allocations AS (
    SELECT * FROM jsonb_to_recordset(p_allocations) AS a(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
  )
  UPDATE public.emergency_combo_component_items component
  SET kitchen_started_quantity = CASE WHEN p_action = 'kitchen_done'
        THEN CASE WHEN v_direct OR current_setting('globos.workflow_projection',true)='on' THEN greatest(component.kitchen_started_quantity,
        component.kitchen_done_quantity + allocation.quantity)
        ELSE component.kitchen_started_quantity + allocation.quantity END
        ELSE component.kitchen_started_quantity END,
      kitchen_done_quantity = CASE WHEN p_action = 'kitchen_done'
        THEN component.kitchen_done_quantity + allocation.quantity
        ELSE component.kitchen_done_quantity END,
      tray_received_quantity = CASE WHEN p_action = 'tray_dispatched' OR (v_direct AND p_action = 'kitchen_done')
        THEN component.tray_received_quantity + allocation.quantity
        ELSE component.tray_received_quantity END,
      tray_dispatched_quantity = CASE WHEN p_action = 'tray_dispatched' OR (v_direct AND p_action = 'kitchen_done')
        THEN component.tray_dispatched_quantity + allocation.quantity
        ELSE component.tray_dispatched_quantity END,
      floor_served_quantity = CASE WHEN p_action = 'floor_served'
        THEN component.floor_served_quantity + allocation.quantity
        ELSE component.floor_served_quantity END,
      updated_at = now()
  FROM allocations allocation
  WHERE allocation.source_kind = 'combo_component'
    AND component.id = allocation.item_id;

  -- Recompute every affected combo parent once, after all component rows have
  -- advanced. This preserves the commercial-line projection without N+1 RPCs.
  WITH allocations AS (
    SELECT * FROM jsonb_to_recordset(p_allocations) AS a(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
  ), affected AS (
    SELECT DISTINCT component.session_id, component.order_item_id
    FROM allocations allocation
    JOIN public.emergency_combo_component_items component
      ON component.id = allocation.item_id
     AND allocation.source_kind = 'combo_component'
  ), parent_values AS (
    SELECT parent.id,
      COALESCE(min(
        CASE p_action
          WHEN 'kitchen_done' THEN component.kitchen_done_quantity
          WHEN 'tray_dispatched' THEN component.tray_dispatched_quantity
          ELSE component.floor_served_quantity
        END * parent.ordered_quantity / component.ordered_quantity
      ), 0)::integer AS stage_quantity
    FROM affected
    JOIN public.emergency_fulfillment_items parent
      ON parent.session_id = affected.session_id
     AND parent.order_item_id = affected.order_item_id
    JOIN public.emergency_combo_component_items component
      ON component.session_id = affected.session_id
     AND component.order_item_id = affected.order_item_id
     AND component.is_cancelled = false
    GROUP BY parent.id
  )
  UPDATE public.emergency_fulfillment_items parent
  SET kitchen_started_quantity = CASE WHEN p_action = 'kitchen_done'
        THEN CASE WHEN v_direct OR current_setting('globos.workflow_projection',true)='on' THEN greatest(parent.kitchen_started_quantity,
        parent_values.stage_quantity) ELSE parent_values.stage_quantity END
        ELSE parent.kitchen_started_quantity END,
      kitchen_done_quantity = CASE WHEN p_action = 'kitchen_done'
        THEN parent_values.stage_quantity ELSE parent.kitchen_done_quantity END,
      tray_received_quantity = CASE WHEN p_action = 'tray_dispatched' OR (v_direct AND p_action = 'kitchen_done')
        THEN parent_values.stage_quantity ELSE parent.tray_received_quantity END,
      tray_dispatched_quantity = CASE WHEN p_action = 'tray_dispatched' OR (v_direct AND p_action = 'kitchen_done')
        THEN parent_values.stage_quantity ELSE parent.tray_dispatched_quantity END,
      floor_served_quantity = CASE WHEN p_action = 'floor_served'
        THEN parent_values.stage_quantity ELSE parent.floor_served_quantity END,
      updated_at = now()
  FROM parent_values
  WHERE parent.id = parent_values.id;

  WITH allocations AS (
    SELECT * FROM jsonb_to_recordset(p_allocations) AS a(
      item_id uuid, queue_id uuid, source_kind text, quantity integer
    )
  ), lines AS (
    SELECT item.id AS item_id, item.session_id, item.order_id,
      item.order_item_id, NULL::uuid AS combo_component_item_id,
      'base'::text AS source_kind, allocation.quantity,
      item.kitchen_started_quantity, item.kitchen_done_quantity,
      item.tray_received_quantity, item.tray_dispatched_quantity,
      item.floor_served_quantity
    FROM allocations allocation
    JOIN public.emergency_fulfillment_items item
      ON item.id = allocation.item_id AND allocation.source_kind = 'base'
    UNION ALL
    SELECT component.id, component.session_id, component.order_id,
      component.order_item_id, component.id, 'combo_component',
      allocation.quantity, component.kitchen_started_quantity,
      component.kitchen_done_quantity, component.tray_received_quantity,
      component.tray_dispatched_quantity, component.floor_served_quantity
    FROM allocations allocation
    JOIN public.emergency_combo_component_items component
      ON component.id = allocation.item_id
     AND allocation.source_kind = 'combo_component'
  ), inserted AS (
    INSERT INTO public.emergency_fulfillment_events(
      event_id, session_id, restaurant_id, order_id, order_item_id,
      combo_component_item_id, stage, delta, actor_user_id, details
    )
    SELECT md5(p_request_id::text || ':' || p_action || ':'
        || lines.source_kind || ':' || lines.item_id::text)::uuid,
      lines.session_id, p_restaurant_id, lines.order_id, lines.order_item_id,
      lines.combo_component_item_id, p_action, lines.quantity, p_actor_user_id,
      jsonb_build_object(
        'kitchen_direct_to_floor', v_direct, 'workflow_action', p_action,
        'source_kind', lines.source_kind,
        'effective_action', p_action,
        'source_id', lines.item_id,
        'batch_request_id', p_request_id,
        'response', jsonb_build_object(
          'kitchen_started_quantity', lines.kitchen_started_quantity,
          'kitchen_done_quantity', lines.kitchen_done_quantity,
          'tray_received_quantity', lines.tray_received_quantity,
          'tray_dispatched_quantity', lines.tray_dispatched_quantity,
          'floor_served_quantity', lines.floor_served_quantity
        )
      )
    FROM lines
    RETURNING event_id
  )
  SELECT COALESCE(jsonb_agg(event_id ORDER BY event_id), '[]'::jsonb)
  INTO v_event_ids
  FROM inserted;

  IF v_direct AND p_action = 'kitchen_done' THEN
    WITH allocations AS (
      SELECT * FROM jsonb_to_recordset(p_allocations) AS a(item_id uuid, queue_id uuid, source_kind text, quantity integer)
    ), affected AS MATERIALIZED (
      SELECT i.order_id FROM allocations a JOIN public.emergency_fulfillment_items i
        ON i.id = a.item_id AND a.source_kind = 'base'
      UNION
      SELECT i.order_id FROM allocations a JOIN public.emergency_combo_component_items i
        ON i.id = a.item_id AND a.source_kind = 'combo_component'
    ), readiness AS (
      SELECT t.id, bool_and(i.is_cancelled OR i.kitchen_done_quantity >= i.ordered_quantity - i.excused_quantity) AS ready
      FROM affected a JOIN public.direct_order_financials f ON f.order_id = a.order_id AND f.restaurant_id = p_restaurant_id
      JOIN public.direct_delivery_fulfillment_tickets t ON t.request_id = f.request_id
      JOIN public.emergency_fulfillment_items i ON i.order_id = a.order_id
      WHERE t.status IN ('pending', 'preparing', 'ready')
      GROUP BY t.id
    )
    UPDATE public.direct_delivery_fulfillment_tickets t
    SET status = CASE WHEN r.ready THEN 'ready' ELSE 'preparing' END,
      version = t.version + 1, accepted_at = COALESCE(t.accepted_at, now()),
      ready_at = CASE WHEN r.ready THEN COALESCE(t.ready_at, now()) ELSE NULL END, updated_at = now()
    FROM readiness r WHERE t.id = r.id
      AND t.status IS DISTINCT FROM CASE WHEN r.ready THEN 'ready' ELSE 'preparing' END;
  END IF;

  -- Push fan-out is also one set operation. A slow or unavailable push worker
  -- therefore never holds the operator request open.
  IF p_action IN ('kitchen_done', 'tray_dispatched') THEN
    WITH allocations AS (
      SELECT * FROM jsonb_to_recordset(p_allocations) AS a(
        item_id uuid, queue_id uuid, source_kind text, quantity integer
      )
    ), event_rows AS (
      SELECT md5(p_request_id::text || ':' || p_action || ':base:'
          || item.id::text)::uuid AS event_id,
        item.order_id, queue.floor_label,
        COALESCE(order_row.sales_channel, 'dine_in') AS channel
      FROM allocations allocation
      JOIN public.emergency_fulfillment_items item
        ON item.id = allocation.item_id AND allocation.source_kind = 'base'
      JOIN public.emergency_order_queue queue ON queue.id = item.queue_id
      JOIN public.orders order_row ON order_row.id = item.order_id
      UNION ALL
      SELECT md5(p_request_id::text || ':' || p_action || ':combo_component:'
          || component.id::text)::uuid,
        component.order_id, queue.floor_label,
        COALESCE(order_row.sales_channel, 'dine_in')
      FROM allocations allocation
      JOIN public.emergency_combo_component_items component
        ON component.id = allocation.item_id
       AND allocation.source_kind = 'combo_component'
      JOIN public.emergency_order_queue queue ON queue.id = component.queue_id
      JOIN public.orders order_row ON order_row.id = component.order_id
    )
    INSERT INTO public.emergency_push_deliveries(
      event_id, restaurant_id, device_id, push_token, station_type,
      floor_label, order_id, stage
    )
    SELECT event_rows.event_id, p_restaurant_id, device.id, device.token,
      assignment.station_type, assignment.floor_label,
      event_rows.order_id, p_action
    FROM event_rows
    JOIN public.emergency_station_assignments assignment
      ON assignment.restaurant_id = p_restaurant_id
     AND assignment.is_active = true
     AND assignment.station_type = CASE p_action
       WHEN 'kitchen_done' THEN CASE WHEN v_direct THEN 'floor' ELSE 'tray' END ELSE 'floor' END
    JOIN public.emergency_web_push_devices device
      ON device.station_assignment_id = assignment.id
     AND device.restaurant_id = p_restaurant_id
     AND device.is_enabled = true
    WHERE (assignment.station_type <> 'floor'
      OR assignment.floor_label = event_rows.floor_label)
      AND NOT (assignment.station_type = 'floor'
        AND (event_rows.channel = 'delivery' OR (v_direct AND EXISTS (
    SELECT 1 FROM public.direct_order_financials f JOIN public.direct_order_requests r
      ON r.id = f.request_id AND r.fulfillment_type = 'pickup'
    WHERE f.order_id = event_rows.order_id AND f.restaurant_id = p_restaurant_id))))
    ON CONFLICT (event_id, device_id) DO NOTHING;
  END IF;

  RETURN jsonb_build_object(
    'changed_quantity', v_changed_quantity,
    'event_ids', v_event_ids
  );
EXCEPTION WHEN lock_not_available THEN
  RAISE EXCEPTION 'KDS_BATCH_STALE';
END;
$$;

CREATE FUNCTION public.store_preparation_progress_v1(p_store_id uuid,p_event_id uuid,p_action text,p_allocations jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE before_steps jsonb; usr public.users%ROWTYPE; release uuid; station jsonb; previous public.store_preparation_events%ROWTYPE;
 payload jsonb:=jsonb_build_object('action',p_action,'allocations',p_allocations); finals jsonb; result jsonb; requests uuid[];
BEGIN
 SELECT * INTO usr FROM public.users WHERE auth_id=auth.uid() AND restaurant_id=p_store_id AND is_active;
 IF NOT FOUND THEN RAISE EXCEPTION 'WORKFLOW_ACTOR_REQUIRED'; END IF;
 IF p_event_id IS NULL OR p_action IS NULL OR p_action NOT IN ('start','done','undo_start','undo_done') OR jsonb_typeof(p_allocations) IS DISTINCT FROM 'array' OR jsonb_array_length(p_allocations) NOT BETWEEN 1 AND 1000
  OR EXISTS(SELECT 1 FROM jsonb_to_recordset(p_allocations)a(step_id uuid,revision bigint,quantity integer) WHERE step_id IS NULL OR revision IS NULL OR quantity IS NULL OR quantity NOT BETWEEN 1 AND 1000)
  OR EXISTS(SELECT 1 FROM jsonb_to_recordset(p_allocations)a(step_id uuid) GROUP BY step_id HAVING count(*)>1)
  OR (SELECT sum(quantity) FROM jsonb_to_recordset(p_allocations)a(quantity integer))>1000 THEN RAISE EXCEPTION 'WORKFLOW_INPUT_INVALID'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('prep-event:'||p_event_id::text,0));
 SELECT * INTO previous FROM public.store_preparation_events WHERE id=p_event_id;
 IF FOUND THEN
  IF previous.restaurant_id<>p_store_id OR previous.actor_id<>usr.id OR previous.payload<>payload THEN RAISE EXCEPTION 'WORKFLOW_EVENT_CONFLICT'; END IF;
  RETURN previous.response;
 END IF;
 IF EXISTS(SELECT 1 FROM public.store_workflow_devices WHERE restaurant_id=p_store_id AND user_id=usr.id AND quiesced) THEN RAISE EXCEPTION 'WORKFLOW_DEVICE_QUIESCED'; END IF;
 SELECT c.active_id,s INTO release,station FROM public.store_workflow_configs c JOIN public.store_workflow_releases r ON r.id=c.active_id,
 jsonb_array_elements(r.definition->'stations')s WHERE c.restaurant_id=p_store_id AND s->'user_ids' ? usr.id::text;
 IF station IS NULL OR NOT EXISTS(SELECT 1 FROM public.emergency_station_assignments WHERE restaurant_id=p_store_id AND user_id=usr.id AND is_active AND station_type='kitchen') THEN RAISE EXCEPTION 'WORKFLOW_STATION_FORBIDDEN'; END IF;
 -- Direct fulfillment uses request -> ticket -> order; ordinary cashier mutations
 -- cannot move a direct-order line. NOWAIT safely rejects overlapping changes.
 PERFORM r.id FROM public.direct_order_requests r WHERE r.id IN(SELECT f.request_id FROM public.direct_order_financials f JOIN public.store_preparation_tasks t ON t.order_id=f.order_id JOIN public.store_preparation_steps s ON s.task_id=t.id JOIN jsonb_to_recordset(p_allocations)a(step_id uuid) ON a.step_id=s.id) ORDER BY r.id FOR UPDATE NOWAIT;
 PERFORM ticket.id FROM public.direct_delivery_fulfillment_tickets ticket WHERE ticket.request_id IN(SELECT f.request_id FROM public.direct_order_financials f JOIN public.store_preparation_tasks t ON t.order_id=f.order_id JOIN public.store_preparation_steps s ON s.task_id=t.id JOIN jsonb_to_recordset(p_allocations)a(step_id uuid) ON a.step_id=s.id) ORDER BY ticket.id FOR UPDATE NOWAIT;
 -- Match cash-register mutation lock order. NOWAIT turns an overlapping operation
 -- into a retryable conflict rather than taking locks in the reverse direction.
 PERFORM o.id FROM public.orders o WHERE o.id IN (SELECT t.order_id FROM public.store_preparation_tasks t JOIN public.store_preparation_steps s ON s.task_id=t.id JOIN jsonb_to_recordset(p_allocations)a(step_id uuid) ON a.step_id=s.id) ORDER BY o.id FOR UPDATE NOWAIT;
 PERFORM i.id FROM public.order_items i WHERE i.id IN (SELECT t.order_item_id FROM public.store_preparation_tasks t JOIN public.store_preparation_steps s ON s.task_id=t.id JOIN jsonb_to_recordset(p_allocations)a(step_id uuid) ON a.step_id=s.id) ORDER BY i.id FOR UPDATE NOWAIT;
 PERFORM s.id FROM public.store_preparation_steps s WHERE s.task_id IN (SELECT x.task_id FROM public.store_preparation_steps x JOIN jsonb_to_recordset(p_allocations)a(step_id uuid) ON a.step_id=x.id) ORDER BY s.id FOR UPDATE NOWAIT;
 IF (SELECT count(*) FROM jsonb_to_recordset(p_allocations)a(step_id uuid,revision bigint,quantity integer)
  JOIN public.store_preparation_steps s ON s.id=a.step_id AND s.revision=a.revision
  JOIN public.store_preparation_tasks t ON t.id=s.task_id AND t.release_id=release
  JOIN public.store_preparation_sources src ON src.source_id=t.source_id AND src.source_kind=t.source_kind
  LEFT JOIN public.store_preparation_steps prev ON prev.task_id=t.id AND prev.position=s.position-1
  LEFT JOIN public.store_preparation_steps next_step ON next_step.task_id=t.id AND next_step.position=s.position+1
  LEFT JOIN public.emergency_fulfillment_items base ON t.source_kind='base' AND base.id=t.source_id
  LEFT JOIN public.emergency_combo_component_items component ON t.source_kind='combo_component' AND component.id=t.source_id
  LEFT JOIN public.emergency_order_queue queue ON queue.id=coalesce(base.queue_id,component.queue_id)
  LEFT JOIN public.direct_delivery_fulfillment_tickets ticket ON ticket.id=t.ticket_id
  WHERE s.restaurant_id=p_store_id AND s.station_id=(station->>'id')::uuid AND NOT src.blocked
   AND CASE p_action WHEN 'start' THEN s.started+a.quantity<=least(src.quantity,coalesce(prev.done,src.quantity)) WHEN 'done' THEN s.done+a.quantity<=least(s.started,src.quantity,coalesce(prev.done,src.quantity))
    WHEN 'undo_start' THEN s.started-a.quantity>=s.done
    WHEN 'undo_done' THEN s.done-a.quantity>=CASE WHEN next_step.id IS NOT NULL THEN next_step.started
     WHEN ticket.id IS NOT NULL AND ticket.status NOT IN ('pending','preparing') THEN s.done WHEN t.source_kind='direct_ticket' THEN 0
     WHEN queue.kitchen_direct_to_floor THEN coalesce(base.floor_served_quantity,component.floor_served_quantity)
     ELSE coalesce(base.tray_received_quantity,component.tray_received_quantity) END ELSE false END)<>jsonb_array_length(p_allocations)
 THEN RAISE EXCEPTION 'WORKFLOW_PROGRESS_CHANGED'; END IF;
 SELECT jsonb_agg(to_jsonb(s) ORDER BY s.id) INTO before_steps FROM public.store_preparation_steps s JOIN jsonb_to_recordset(p_allocations)a(step_id uuid) ON a.step_id=s.id;
 UPDATE public.store_preparation_steps s SET started=started+CASE p_action WHEN 'start' THEN a.quantity WHEN 'undo_start' THEN -a.quantity ELSE 0 END,
  done=done+CASE p_action WHEN 'done' THEN a.quantity WHEN 'undo_done' THEN -a.quantity ELSE 0 END,revision=s.revision+1,updated_by=usr.id,
  started_at=CASE WHEN p_action='undo_start' AND started=a.quantity THEN NULL WHEN p_action='start' THEN coalesce(started_at,now()) ELSE started_at END,
  done_at=CASE WHEN p_action='undo_done' AND done=a.quantity THEN NULL WHEN p_action='done' THEN now() ELSE done_at END
 FROM jsonb_to_recordset(p_allocations)a(step_id uuid,quantity integer) WHERE s.id=a.step_id;
 PERFORM set_config('globos.workflow_projection','on',true);
 IF p_action='start' THEN
  UPDATE public.direct_delivery_fulfillment_tickets ticket SET status='preparing',accepted_at=coalesce(accepted_at,now()),version=version+1,updated_at=now(),updated_by=auth.uid()
   WHERE ticket.status='pending' AND ticket.request_id IN(SELECT f.request_id FROM public.direct_order_financials f JOIN public.store_preparation_tasks t ON t.order_id=f.order_id JOIN public.store_preparation_steps s ON s.task_id=t.id JOIN jsonb_to_recordset(p_allocations)a(step_id uuid) ON a.step_id=s.id);
  UPDATE public.emergency_fulfillment_items i SET kitchen_started_quantity=greatest(i.kitchen_started_quantity,s.started),updated_at=now()
   FROM public.store_preparation_tasks t JOIN public.store_preparation_steps s ON s.task_id=t.id AND s.position=1
   JOIN jsonb_to_recordset(p_allocations)a(step_id uuid) ON a.step_id=s.id WHERE t.source_kind='base' AND i.id=t.source_id;
  UPDATE public.emergency_combo_component_items i SET kitchen_started_quantity=greatest(i.kitchen_started_quantity,s.started),updated_at=now()
   FROM public.store_preparation_tasks t JOIN public.store_preparation_steps s ON s.task_id=t.id AND s.position=1
   JOIN jsonb_to_recordset(p_allocations)a(step_id uuid) ON a.step_id=s.id WHERE t.source_kind='combo_component' AND i.id=t.source_id;
 ELSIF p_action IN ('undo_start','undo_done') THEN
  -- The next stage and the existing tray/floor counters have already fenced
  -- consumed quantities above. Reverse only the unconsumed preparation units.
  UPDATE public.emergency_fulfillment_items i SET
   kitchen_started_quantity=CASE WHEN p_action='undo_start' AND s.position=1 THEN s.started ELSE i.kitchen_started_quantity END,
   kitchen_done_quantity=CASE WHEN p_action='undo_done' AND n.id IS NULL THEN s.done ELSE i.kitchen_done_quantity END,
   tray_received_quantity=CASE WHEN p_action='undo_done' AND n.id IS NULL AND q.kitchen_direct_to_floor THEN least(i.tray_received_quantity,s.done) ELSE i.tray_received_quantity END,
   tray_dispatched_quantity=CASE WHEN p_action='undo_done' AND n.id IS NULL AND q.kitchen_direct_to_floor THEN least(i.tray_dispatched_quantity,s.done) ELSE i.tray_dispatched_quantity END,updated_at=now()
  FROM jsonb_to_recordset(p_allocations)a(step_id uuid) JOIN public.store_preparation_steps s ON s.id=a.step_id
  JOIN public.store_preparation_tasks t ON t.id=s.task_id JOIN public.emergency_order_queue q ON q.order_id=t.order_id
  LEFT JOIN public.store_preparation_steps n ON n.task_id=t.id AND n.position=s.position+1
  WHERE t.source_kind='base' AND i.id=t.source_id AND i.queue_id=q.id;
  UPDATE public.emergency_combo_component_items i SET
   kitchen_started_quantity=CASE WHEN p_action='undo_start' AND s.position=1 THEN s.started ELSE i.kitchen_started_quantity END,
   kitchen_done_quantity=CASE WHEN p_action='undo_done' AND n.id IS NULL THEN s.done ELSE i.kitchen_done_quantity END,
   tray_received_quantity=CASE WHEN p_action='undo_done' AND n.id IS NULL AND q.kitchen_direct_to_floor THEN least(i.tray_received_quantity,s.done) ELSE i.tray_received_quantity END,
   tray_dispatched_quantity=CASE WHEN p_action='undo_done' AND n.id IS NULL AND q.kitchen_direct_to_floor THEN least(i.tray_dispatched_quantity,s.done) ELSE i.tray_dispatched_quantity END,updated_at=now()
  FROM jsonb_to_recordset(p_allocations)a(step_id uuid) JOIN public.store_preparation_steps s ON s.id=a.step_id
  JOIN public.store_preparation_tasks t ON t.id=s.task_id JOIN public.emergency_order_queue q ON q.order_id=t.order_id
  LEFT JOIN public.store_preparation_steps n ON n.task_id=t.id AND n.position=s.position+1
  WHERE t.source_kind='combo_component' AND i.id=t.source_id AND i.queue_id=q.id;
  IF p_action='undo_done' THEN
   PERFORM public.store_preparation_trim_lots(ARRAY(SELECT t.source_id FROM public.store_preparation_tasks t JOIN public.store_preparation_steps s ON s.task_id=t.id JOIN jsonb_to_recordset(p_allocations)a(step_id uuid) ON a.step_id=s.id));
   UPDATE public.direct_delivery_fulfillment_tickets ticket SET cooking_completed_at=NULL,version=version+1,updated_at=now(),updated_by=auth.uid()
    WHERE ticket.cooking_completed_at IS NOT NULL AND ticket.request_id IN(SELECT f.request_id FROM public.direct_order_financials f JOIN public.store_preparation_tasks t ON t.order_id=f.order_id JOIN public.store_preparation_steps s ON s.task_id=t.id JOIN jsonb_to_recordset(p_allocations)a(step_id uuid) ON a.step_id=s.id);
  END IF;
 ELSE
  SELECT jsonb_agg(jsonb_build_object('item_id',t.source_id,'source_kind',t.source_kind,'queue_id',src.queue_id,'quantity',a.quantity)) INTO finals
   FROM jsonb_to_recordset(p_allocations)a(step_id uuid,quantity integer) JOIN public.store_preparation_steps s ON s.id=a.step_id
   JOIN public.store_preparation_tasks t ON t.id=s.task_id JOIN public.store_preparation_sources src ON src.source_id=t.source_id AND src.source_kind=t.source_kind
   WHERE t.source_kind<>'direct_ticket' AND NOT EXISTS(SELECT 1 FROM public.store_preparation_steps n WHERE n.task_id=t.id AND n.position>s.position);
  IF finals IS NOT NULL THEN PERFORM public.kds_apply_station_progress_batch_v1(p_event_id,p_store_id,usr.id,'kitchen_done',NULL,finals); END IF;
  WITH changed AS (
   UPDATE public.direct_delivery_fulfillment_tickets ticket SET cooking_completed_at=now(),version=version+1,updated_at=now(),updated_by=auth.uid()
   WHERE ticket.id IN (SELECT t.ticket_id FROM public.store_preparation_tasks t JOIN public.store_preparation_steps s ON s.task_id=t.id JOIN jsonb_to_recordset(p_allocations)a(step_id uuid) ON a.step_id=s.id)
    AND ticket.cooking_completed_at IS NULL AND NOT EXISTS(SELECT 1 FROM public.store_preparation_tasks t JOIN public.store_preparation_steps s ON s.task_id=t.id
     JOIN public.store_preparation_sources src ON src.source_id=t.source_id AND src.source_kind=t.source_kind WHERE t.ticket_id=ticket.id AND NOT src.blocked AND s.done<src.quantity)
   RETURNING ticket.request_id
  ) SELECT array_agg(request_id) INTO requests FROM changed;
  SELECT ARRAY(SELECT DISTINCT id FROM (SELECT unnest(requests) id UNION ALL SELECT f.request_id FROM public.direct_order_financials f
   JOIN public.store_preparation_tasks t ON t.order_id=f.order_id JOIN public.store_preparation_steps s ON s.task_id=t.id JOIN jsonb_to_recordset(p_allocations)a(step_id uuid) ON a.step_id=s.id)x) INTO requests;
  PERFORM public.direct_order_progress_notice_batch(requests,'cooking_complete');
 END IF;
 PERFORM set_config('globos.workflow_projection','off',true);
 result:=jsonb_build_object('event_id',p_event_id,'release_id',release,'changed_quantity',(SELECT sum(quantity) FROM jsonb_to_recordset(p_allocations)a(quantity integer)));
 INSERT INTO public.store_preparation_events(id,restaurant_id,actor_id,payload,response,before_steps,after_steps) VALUES(p_event_id,p_store_id,usr.id,payload,result,before_steps,(SELECT jsonb_agg(to_jsonb(s) ORDER BY s.id) FROM public.store_preparation_steps s JOIN jsonb_to_recordset(p_allocations)a(step_id uuid) ON a.step_id=s.id));
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES(auth.uid(),'store_preparation_'||p_action,'restaurants',p_store_id,result);
 IF p_action='done' THEN
  PERFORM public.store_preparation_ready_notify(ARRAY(SELECT DISTINCT t.order_id FROM public.store_preparation_tasks t JOIN public.store_preparation_steps s ON s.task_id=t.id JOIN jsonb_to_recordset(p_allocations)a(step_id uuid) ON a.step_id=s.id));
 ELSE PERFORM public.store_workflow_notify(p_store_id); END IF;
 RETURN result;
EXCEPTION WHEN lock_not_available THEN RAISE EXCEPTION 'WORKFLOW_PROGRESS_CHANGED';
END;
$$;
ALTER TABLE public.store_preparation_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_preparation_steps ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_preparation_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.store_preparation_tasks,public.store_preparation_steps,public.store_preparation_events,public.store_preparation_sources FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.store_preparation_seed(uuid[]),public.store_preparation_seed_items(),public.store_preparation_seed_tickets(),public.store_preparation_guard_legacy(),public.store_preparation_guard_ticket() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.store_workflow_device_v1(uuid,uuid,uuid,integer),public.store_preparation_snapshot_v1(uuid,timestamptz,uuid,boolean),public.store_preparation_progress_v1(uuid,uuid,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.store_workflow_device_v1(uuid,uuid,uuid,integer),public.store_preparation_snapshot_v1(uuid,timestamptz,uuid,boolean),public.store_preparation_progress_v1(uuid,uuid,text,jsonb) TO authenticated,service_role;
CREATE OR REPLACE FUNCTION "public"."direct_order_approve_payment"("p_store_id" "uuid", "p_request_id" "uuid", "p_confirmed_amount" numeric, "p_confirmed_bank_reference" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_catalog'
    AS $$
DECLARE previous_snapshot text; previous_lines text; line_snapshots jsonb; result jsonb; snapshot jsonb; already_approved boolean;
BEGIN
 previous_snapshot:=current_setting('pos.direct_combo_snapshot',true);
 previous_lines:=current_setting('pos.direct_line_snapshots',true);
 PERFORM public.direct_order_require_actor(p_store_id,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 PERFORM pg_advisory_xact_lock(hashtextextended('direct-order-approval:'||p_request_id::text,0));
 PERFORM 1 FROM public.direct_order_requests WHERE id=p_request_id AND restaurant_id=p_store_id FOR UPDATE;
 already_approved:=EXISTS(SELECT 1 FROM public.direct_order_financials WHERE request_id=p_request_id);
 IF NOT already_approved THEN
  PERFORM public.direct_order_validate_combo_request(p_store_id,p_request_id);
 END IF;
 -- Hydrate every approved line in one query. Individual snapshot triggers
 -- read the transaction map instead of re-querying each request/menu/recipe.
 WITH lines AS MATERIALIZED (
  SELECT i.id,jsonb_array_length(i.combo_components)>0 is_combo,
   jsonb_build_object('vat_profile_snapshot',i.vat_profile_snapshot,'combo_components',
    coalesce((SELECT jsonb_agg(c||jsonb_build_object('fulfillment_route','kitchen_tray_floor'))
     FROM jsonb_array_elements(i.combo_components)c),'[]'::jsonb)) payload
  FROM public.direct_order_request_items i WHERE i.request_id=p_request_id AND i.restaurant_id=p_store_id
 ) SELECT jsonb_object_agg(id::text,payload),jsonb_object_agg(id::text,payload) FILTER(WHERE is_combo)
 INTO line_snapshots,snapshot FROM lines;
 IF NOT already_approved AND snapshot IS NOT NULL THEN PERFORM public.direct_order_lock_combo_stock(p_store_id,p_request_id); END IF;
 PERFORM set_config('pos.direct_combo_snapshot',COALESCE(snapshot,'{}')::text,true);
 PERFORM set_config('pos.direct_line_snapshots',COALESCE(line_snapshots,'{}')::text,true);
 result:=public.direct_order_approve_payment_before_combo(p_store_id,p_request_id,p_confirmed_amount,p_confirmed_bank_reference);
 IF NOT already_approved THEN PERFORM public.direct_order_deduct_combo_stock(p_store_id,p_request_id); END IF;
 PERFORM set_config('pos.direct_line_snapshots',COALESCE(previous_lines,''),true);
 PERFORM set_config('pos.direct_combo_snapshot',COALESCE(previous_snapshot,''),true);
 PERFORM public.store_preparation_seed(ARRAY(SELECT order_id FROM public.direct_order_financials WHERE request_id=p_request_id));
 RETURN result;
EXCEPTION WHEN OTHERS THEN
 PERFORM set_config('pos.direct_line_snapshots',COALESCE(previous_lines,''),true);
 PERFORM set_config('pos.direct_combo_snapshot',COALESCE(previous_snapshot,''),true); RAISE;
END $$;


DO $verify$ BEGIN
 IF has_table_privilege('authenticated','public.store_preparation_steps','SELECT')
 OR has_function_privilege('anon','public.store_preparation_progress_v1(uuid,uuid,text,jsonb)','EXECUTE')
 OR has_function_privilege('authenticated','public.store_preparation_seed(uuid[])','EXECUTE')
 OR NOT has_function_privilege('authenticated','public.store_preparation_snapshot_v1(uuid,timestamptz,uuid,boolean)','EXECUTE')
 THEN RAISE EXCEPTION 'WORKFLOW_PREPARATION_CONTRACT_INVALID'; END IF;
END $verify$;
COMMIT;
