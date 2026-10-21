-- Set-based movement preserves immutable choices and every kitchen stage.
-- production-gate: self-verifying
BEGIN;
CREATE OR REPLACE FUNCTION "public"."cashier_item_progress"("p_item_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $_$
 SELECT jsonb_build_object('base',COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.id) FROM public.emergency_fulfillment_items t WHERE order_item_id=$1),'[]'::jsonb),
 'combo',COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.id) FROM public.emergency_combo_component_items t WHERE order_item_id=$1),'[]'::jsonb),
 'direct',COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.id) FROM public.emergency_floor_direct_items t WHERE order_item_id=$1),'[]'::jsonb),
 'floor_lots',COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.id) FROM public.emergency_floor_ready_lots t WHERE order_item_id=$1),'[]'::jsonb),
 'preparation',COALESCE((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.id) FROM public.store_preparation_steps s JOIN public.store_preparation_tasks t ON t.id=s.task_id WHERE t.order_item_id=$1),'[]'::jsonb),
 'tray_lots',COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.id) FROM public.emergency_tray_ready_lots t WHERE order_item_id=$1),'[]'::jsonb));
$_$;


CREATE OR REPLACE FUNCTION "public"."cashier_restore_item_quantity"("p_store_id" "uuid", "p_operation_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_catalog'
    AS $_$
DECLARE operation public.cashier_item_operations%ROWTYPE; item public.order_items%ROWTYPE; kind text; table_name text; row jsonb; assignments text;
BEGIN
 PERFORM public.cashier_require_item_actor(p_store_id);
 SELECT op.* INTO operation FROM public.cashier_item_operations op WHERE op.id=p_operation_id AND op.restaurant_id=p_store_id AND op.kind='partial_cancel';
 IF NOT FOUND THEN RAISE EXCEPTION 'CANCELLATION_NOT_FOUND'; END IF;
 PERFORM 1 FROM public.orders WHERE id=operation.order_id FOR UPDATE; PERFORM public.cashier_assert_unpaid(operation.order_id,p_store_id);
 IF EXISTS(SELECT 1 FROM public.order_cancellation_reversals WHERE cancellation_ledger_id=operation.ledger_id) THEN RETURN operation.response||jsonb_build_object('restored',true); END IF;
 SELECT * INTO item FROM public.order_items WHERE id=(operation.payload->>'item_id')::uuid FOR UPDATE;
 PERFORM 1 FROM public.emergency_fulfillment_items WHERE order_item_id=item.id ORDER BY id FOR UPDATE;
 PERFORM 1 FROM public.emergency_combo_component_items WHERE order_item_id=item.id ORDER BY id FOR UPDATE;
 PERFORM 1 FROM public.emergency_floor_direct_items WHERE order_item_id=item.id ORDER BY id FOR UPDATE;
 IF item.order_id<>operation.order_id OR item.quantity<>(operation.payload->>'new_quantity')::integer OR item.status='cancelled' OR public.cashier_item_progress(item.id)<>operation.after_progress THEN RAISE EXCEPTION 'CASHIER_ITEM_CHANGED'; END IF;
 PERFORM set_config('globos.cashier_item_mutation','on',true);
 PERFORM 1 FROM public.store_preparation_steps s JOIN public.store_preparation_tasks t ON t.id=s.task_id WHERE t.order_item_id=item.id ORDER BY s.id FOR UPDATE;
 UPDATE public.order_items SET quantity=(operation.payload->>'expected_quantity')::integer,billing_cancelled_quantity=billing_cancelled_quantity-((operation.payload->>'expected_quantity')::integer-item.quantity),
  cancelled_consumed_quantity=(SELECT (item_snapshot->0->>'cancelled_consumed_quantity')::integer FROM public.order_cancellation_ledger WHERE id=operation.ledger_id),
  paying_amount_inc_tax=(SELECT (item_snapshot->0->>'before_paying_amount_inc_tax')::numeric FROM public.order_cancellation_ledger WHERE id=operation.ledger_id),vat_amount=(SELECT (item_snapshot->0->>'vat_amount')::numeric FROM public.order_cancellation_ledger WHERE id=operation.ledger_id),total_amount_ex_tax=(SELECT (item_snapshot->0->>'total_amount_ex_tax')::numeric FROM public.order_cancellation_ledger WHERE id=operation.ledger_id),combo_components=(SELECT item_snapshot->0->'combo_components' FROM public.order_cancellation_ledger WHERE id=operation.ledger_id) WHERE id=item.id;
 FOREACH kind IN ARRAY ARRAY['base','combo','direct','floor_lots','tray_lots'] LOOP
  table_name:=CASE kind WHEN 'base' THEN 'emergency_fulfillment_items' WHEN 'combo' THEN 'emergency_combo_component_items' WHEN 'direct' THEN 'emergency_floor_direct_items' WHEN 'floor_lots' THEN 'emergency_floor_ready_lots' ELSE 'emergency_tray_ready_lots' END;
  SELECT string_agg(format('%I=x.%I',a.attname,a.attname),',') INTO assignments FROM pg_attribute a WHERE a.attrelid=('public.'||table_name)::regclass AND a.attnum>0 AND NOT a.attisdropped AND a.attname<>'id';
  EXECUTE format('UPDATE public.%I t SET %s FROM jsonb_populate_recordset(NULL::public.%I,$1) x WHERE t.id=x.id',table_name,assignments,table_name) USING operation.before_progress->kind;

 END LOOP;
 UPDATE public.store_preparation_steps s SET started=x.started,done=x.done,revision=x.revision,started_at=x.started_at,done_at=x.done_at,updated_by=x.updated_by
 FROM jsonb_populate_recordset(NULL::public.store_preparation_steps,coalesce(operation.before_progress->'preparation','[]'))x WHERE s.id=x.id;
 PERFORM set_config('globos.cashier_item_mutation','off',true);
 INSERT INTO public.order_cancellation_reversals(cancellation_ledger_id,restaurant_id,order_id,order_item_id,restored_by) VALUES(operation.ledger_id,p_store_id,operation.order_id,item.id,auth.uid());
 PERFORM public.void_active_order_discount_for_item_change(item.order_id,p_store_id,'order_items_changed'); PERFORM public.recalc_order_status(item.order_id);
 PERFORM public.cashier_invalidate_changed_display(p_store_id,ARRAY[item.order_id]);
 PERFORM public.store_workflow_notify(p_store_id);
 RETURN operation.response||jsonb_build_object('restored',true);
END;
$_$;


CREATE OR REPLACE FUNCTION "public"."cashier_move_order_items"("p_store_id" "uuid", "p_source_order_id" "uuid", "p_target_table_id" "uuid", "p_items" "jsonb", "p_operation_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_catalog'
    AS $_$
DECLARE old public.cashier_item_operations%ROWTYPE; source public.orders%ROWTYPE; target public.orders%ROWTYPE; target_table public.tables%ROWTYPE;
 payload jsonb; response jsonb; table_name text; assignments text; kind text; key text; lot_table text; moved_ids jsonb:='[]'::jsonb;
BEGIN
 PERFORM public.cashier_require_item_actor(p_store_id);
 IF p_operation_id IS NULL OR p_target_table_id IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'CASHIER_MOVE_INPUT_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_to_recordset(p_items) x(item_id uuid,quantity integer,expected_quantity integer) WHERE item_id IS NULL OR quantity IS NULL OR quantity<1 OR expected_quantity IS NULL OR expected_quantity<quantity) OR EXISTS(SELECT 1 FROM jsonb_to_recordset(p_items) x(item_id uuid) GROUP BY item_id HAVING count(*)>1) THEN RAISE EXCEPTION 'CASHIER_MOVE_INPUT_INVALID'; END IF;
 payload:=jsonb_build_object('source_order_id',p_source_order_id,'target_table_id',p_target_table_id,'items',p_items);
 PERFORM pg_advisory_xact_lock(hashtextextended(p_operation_id::text,0));
 SELECT * INTO old FROM public.cashier_item_operations WHERE id=p_operation_id;
 IF FOUND THEN IF old.restaurant_id<>p_store_id OR old.kind<>'move' OR old.payload<>payload THEN RAISE EXCEPTION 'CASHIER_OPERATION_CHANGED'; END IF; RETURN old.response; END IF;
 SELECT * INTO source FROM public.orders WHERE id=p_source_order_id AND restaurant_id=p_store_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
 IF source.table_id IS NULL OR source.table_id=p_target_table_id OR source.order_purpose<>'customer' OR source.sales_channel<>'dine_in' THEN RAISE EXCEPTION 'CASHIER_MOVE_INPUT_INVALID'; END IF;
 PERFORM 1 FROM public.tables WHERE id IN (source.table_id,p_target_table_id) AND restaurant_id=p_store_id ORDER BY id FOR UPDATE;
 SELECT * INTO target_table FROM public.tables WHERE id=p_target_table_id AND restaurant_id=p_store_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'TABLE_NOT_FOUND'; END IF;
 IF (SELECT count(*) FROM public.orders WHERE table_id=p_target_table_id AND restaurant_id=p_store_id AND status NOT IN ('completed','cancelled'))>1 THEN RAISE EXCEPTION 'CASHIER_TARGET_ORDER_AMBIGUOUS'; END IF;
 SELECT * INTO target FROM public.orders WHERE table_id=p_target_table_id AND restaurant_id=p_store_id AND status NOT IN ('completed','cancelled');
 PERFORM 1 FROM public.orders WHERE id IN (source.id,target.id) ORDER BY id FOR UPDATE NOWAIT;
 IF source.table_id IS DISTINCT FROM (SELECT table_id FROM public.orders WHERE id=source.id) THEN RAISE EXCEPTION 'CASHIER_ITEM_CHANGED'; END IF;
 PERFORM public.cashier_assert_unpaid(source.id,p_store_id);
 IF target.id IS NOT NULL THEN
  PERFORM public.cashier_assert_unpaid(target.id,p_store_id);
  IF target.order_purpose<>source.order_purpose OR target.fulfillment_mode_snapshot<>source.fulfillment_mode_snapshot OR target.sales_channel<>source.sales_channel OR target.operating_release_id IS DISTINCT FROM source.operating_release_id THEN RAISE EXCEPTION 'CASHIER_TARGET_INCOMPATIBLE'; END IF;
 ELSE
  INSERT INTO public.orders(restaurant_id,table_id,sales_channel,status,guest_count,created_by,notes,order_source,order_purpose,fulfillment_mode_snapshot)
  VALUES(p_store_id,p_target_table_id,source.sales_channel,'confirmed',source.guest_count,auth.uid(),source.notes,source.order_source,source.order_purpose,source.fulfillment_mode_snapshot) RETURNING * INTO target;
 END IF;
 PERFORM 1 FROM public.order_items i JOIN jsonb_to_recordset(p_items) x(item_id uuid) ON x.item_id=i.id WHERE i.order_id=source.id ORDER BY i.id FOR UPDATE OF i;
 PERFORM s.id FROM public.store_preparation_steps s JOIN public.store_preparation_tasks t ON t.id=s.task_id WHERE t.order_id IN (source.id,target.id) ORDER BY s.id FOR UPDATE;
 PERFORM 1 FROM public.emergency_fulfillment_items WHERE order_id IN (source.id,target.id) ORDER BY id FOR UPDATE;
 PERFORM 1 FROM public.emergency_combo_component_items WHERE order_id IN (source.id,target.id) ORDER BY id FOR UPDATE;
 PERFORM 1 FROM public.emergency_floor_direct_items WHERE order_id IN (source.id,target.id) ORDER BY id FOR UPDATE;
 PERFORM set_config('globos.cashier_item_mutation','on',true);

 DROP TABLE IF EXISTS pg_temp.workflow_move_map;
 CREATE TEMP TABLE workflow_move_map ON COMMIT DROP AS
 SELECT i.id source_item_id,CASE WHEN x.quantity=i.quantity THEN i.id ELSE gen_random_uuid() END target_item_id,
  x.quantity move_count,i.quantity original_count,to_jsonb(i) original
 FROM public.order_items i JOIN jsonb_to_recordset(p_items)x(item_id uuid,quantity integer,expected_quantity integer) ON x.item_id=i.id
 WHERE i.order_id=source.id AND i.restaurant_id=p_store_id AND i.quantity=x.expected_quantity AND i.item_type='menu_item' AND i.status<>'cancelled' AND x.quantity<=i.quantity;
 IF (SELECT count(*) FROM pg_temp.workflow_move_map)<>jsonb_array_length(p_items) THEN RAISE EXCEPTION 'CASHIER_ITEM_CHANGED'; END IF;
 IF EXISTS(SELECT 1 FROM pg_temp.workflow_move_map WHERE move_count<original_count AND (original->>'billing_cancelled_quantity')::integer>0) THEN RAISE EXCEPTION 'CASHIER_MOVE_CANCELLED_SPLIT'; END IF;
 ALTER TABLE pg_temp.workflow_move_map ADD COLUMN copied jsonb;
 UPDATE pg_temp.workflow_move_map m SET copied=original||jsonb_build_object('id',target_item_id,'order_id',target.id,'quantity',move_count,
  'paying_amount_inc_tax',round((original->>'paying_amount_inc_tax')::numeric*move_count/original_count,2),
  'vat_amount',round((original->>'vat_amount')::numeric*move_count/original_count,2),
  'total_amount_ex_tax',round((original->>'total_amount_ex_tax')::numeric*move_count/original_count,2),
  'combo_components',coalesce((SELECT jsonb_agg(CASE WHEN coalesce((c->>'is_total_quantity')::boolean,false) THEN jsonb_set(c,'{quantity}',to_jsonb((c->>'quantity')::integer*move_count/original_count)) ELSE c END) FROM jsonb_array_elements(coalesce(original->'combo_components','[]'))c),'[]'::jsonb));
 INSERT INTO public.order_items SELECT (jsonb_populate_record(NULL::public.order_items,copied)).* FROM pg_temp.workflow_move_map WHERE move_count<original_count;
 UPDATE public.order_items i SET order_id=CASE WHEN m.move_count=m.original_count THEN target.id ELSE source.id END,
  quantity=CASE WHEN m.move_count=m.original_count THEN i.quantity ELSE i.quantity-m.move_count END,
  paying_amount_inc_tax=CASE WHEN m.move_count=m.original_count THEN i.paying_amount_inc_tax ELSE i.paying_amount_inc_tax-(m.copied->>'paying_amount_inc_tax')::numeric END,
  vat_amount=CASE WHEN m.move_count=m.original_count THEN i.vat_amount ELSE i.vat_amount-(m.copied->>'vat_amount')::numeric END,
  total_amount_ex_tax=CASE WHEN m.move_count=m.original_count THEN i.total_amount_ex_tax ELSE i.total_amount_ex_tax-(m.copied->>'total_amount_ex_tax')::numeric END,
  combo_components=CASE WHEN m.move_count=m.original_count THEN i.combo_components ELSE coalesce((SELECT jsonb_agg(CASE WHEN coalesce((c->>'is_total_quantity')::boolean,false) THEN jsonb_set(c,'{quantity}',to_jsonb((c->>'quantity')::integer*(m.original_count-m.move_count)/m.original_count)) ELSE c END) FROM jsonb_array_elements(coalesce(m.original->'combo_components','[]'))c),'[]'::jsonb) END
 FROM pg_temp.workflow_move_map m WHERE i.id=m.source_item_id;
 -- Queue allocation is serialized per session, independent of item count.
 PERFORM sess.id FROM public.emergency_fulfillment_sessions sess WHERE sess.id IN(SELECT session_id FROM public.emergency_order_queue WHERE order_id=source.id) ORDER BY sess.id FOR UPDATE;
 INSERT INTO public.emergency_order_queue(session_id,restaurant_id,order_id,queue_no,table_number,floor_label,workflow_version,created_at)
 SELECT q.session_id,p_store_id,target.id,coalesce((SELECT max(queue_no)+1 FROM public.emergency_order_queue WHERE session_id=q.session_id),1),target_table.table_number,
  public.emergency_floor_label(p_store_id,target_table.floor_label,target_table.table_number),q.workflow_version,q.created_at
 FROM public.emergency_order_queue q WHERE q.order_id=source.id AND NOT EXISTS(SELECT 1 FROM public.emergency_order_queue x WHERE x.session_id=q.session_id AND x.order_id=target.id);
 FOREACH table_name IN ARRAY ARRAY['emergency_fulfillment_items','emergency_combo_component_items','emergency_floor_direct_items'] LOOP
  kind:=CASE table_name WHEN 'emergency_fulfillment_items' THEN 'base' WHEN 'emergency_combo_component_items' THEN 'combo_component' ELSE 'floor_direct' END;
  DROP TABLE IF EXISTS pg_temp.workflow_progress_map;
  EXECUTE format('CREATE TEMP TABLE workflow_progress_map ON COMMIT DROP AS SELECT to_jsonb(p) original,m.target_item_id,m.move_count,m.original_count,CASE WHEN m.move_count=m.original_count THEN p.id ELSE gen_random_uuid() END new_id,q.id target_queue,(p.source_quantity*m.move_count/m.original_count)::integer units FROM public.%I p JOIN pg_temp.workflow_move_map m ON m.source_item_id=p.order_item_id JOIN public.emergency_order_queue q ON q.session_id=p.session_id AND q.order_id=$1',table_name) USING target.id;
  IF EXISTS(SELECT 1 FROM pg_temp.workflow_progress_map WHERE move_count<original_count AND ((original->>'source_quantity')::integer%original_count<>0 OR (original->>'excused_quantity')::integer>0 OR (original->>'is_cancelled')::boolean OR (original->>'needs_review')::boolean)) THEN RAISE EXCEPTION 'CASHIER_COMBO_QUANTITY_CHANGED'; END IF;
  ALTER TABLE pg_temp.workflow_progress_map ADD COLUMN copied jsonb;
  UPDATE pg_temp.workflow_progress_map m SET copied=original||jsonb_build_object('id',new_id,'order_item_id',target_item_id,'order_id',target.id,'queue_id',target_queue,'source_quantity',units,'ordered_quantity',CASE WHEN move_count=original_count THEN (original->>'ordered_quantity')::integer ELSE units END)||
   coalesce((SELECT jsonb_object_agg(k,least(units,(original->>k)::integer)) FROM unnest(ARRAY['kitchen_started_quantity','kitchen_done_quantity','tray_received_quantity','tray_dispatched_quantity','floor_served_quantity','excused_quantity'])k WHERE original ? k AND move_count<original_count),'{}');
  UPDATE pg_temp.workflow_progress_map m SET original=CASE WHEN move_count=original_count THEN copied ELSE original||jsonb_build_object('source_quantity',(original->>'source_quantity')::integer-units,'ordered_quantity',(original->>'ordered_quantity')::integer-units)||
   coalesce((SELECT jsonb_object_agg(k,(original->>k)::integer-(copied->>k)::integer) FROM unnest(ARRAY['kitchen_started_quantity','kitchen_done_quantity','tray_received_quantity','tray_dispatched_quantity','floor_served_quantity','excused_quantity'])k WHERE original ? k),'{}') END;
  SELECT string_agg(format('%I=x.%I',a.attname,a.attname),',') INTO assignments FROM pg_attribute a WHERE a.attrelid=('public.'||table_name)::regclass AND a.attnum>0 AND NOT a.attisdropped AND a.attname<>'id';
  EXECUTE format('UPDATE public.%I t SET %s FROM (SELECT (jsonb_populate_record(NULL::public.%I,original)).* FROM pg_temp.workflow_progress_map)x WHERE t.id=x.id',table_name,assignments,table_name);
  EXECUTE format('INSERT INTO public.%I SELECT (jsonb_populate_record(NULL::public.%I,copied)).* FROM pg_temp.workflow_progress_map WHERE move_count<original_count',table_name,table_name);
  -- Each split retains per-stage counters, timers and actor, with an auditable task lineage.
  DROP TABLE IF EXISTS pg_temp.workflow_task_map;
  CREATE TEMP TABLE workflow_task_map ON COMMIT DROP AS SELECT t.id old_id,gen_random_uuid() new_id,m.new_id source_id,m.target_item_id,m.units,t.restaurant_id,t.release_id,t.source_kind,t.menu_item_id,t.ticket_id,t.created_at FROM public.store_preparation_tasks t JOIN pg_temp.workflow_progress_map m ON t.source_id=(m.original->>'id')::uuid AND t.source_kind=kind WHERE m.move_count<m.original_count;
  INSERT INTO public.store_preparation_tasks(id,restaurant_id,release_id,order_id,order_item_id,source_kind,source_id,menu_item_id,ticket_id,created_at)
   SELECT new_id,restaurant_id,release_id,target.id,target_item_id,source_kind,source_id,menu_item_id,ticket_id,created_at FROM pg_temp.workflow_task_map;
  INSERT INTO public.store_preparation_steps(restaurant_id,task_id,station_id,position,started,done,revision,started_at,done_at,updated_by)
   SELECT s.restaurant_id,m.new_id,s.station_id,s.position,least(m.units,s.started),least(m.units,s.done),s.revision,s.started_at,s.done_at,s.updated_by FROM pg_temp.workflow_task_map m JOIN public.store_preparation_steps s ON s.task_id=m.old_id;
  UPDATE public.store_preparation_steps s SET started=s.started-least(m.units,s.started),done=s.done-least(m.units,s.done),revision=s.revision+1 FROM pg_temp.workflow_task_map m WHERE s.task_id=m.old_id;
  UPDATE public.store_preparation_tasks t SET order_id=target.id FROM pg_temp.workflow_progress_map m WHERE m.move_count=m.original_count AND t.source_id=(m.original->>'id')::uuid AND t.source_kind=kind;
  FOREACH lot_table IN ARRAY ARRAY['emergency_floor_ready_lots','emergency_tray_ready_lots'] LOOP
   key:=CASE lot_table WHEN 'emergency_floor_ready_lots' THEN 'served_quantity' ELSE 'handed_quantity' END;
   DROP TABLE IF EXISTS pg_temp.workflow_lot_map;
   EXECUTE format('CREATE TEMP TABLE workflow_lot_map ON COMMIT DROP AS WITH fifo AS (SELECT l.*,m.new_id,m.target_item_id,m.target_queue,m.move_count=m.original_count whole,coalesce((m.copied->>$1)::integer,0) capacity,coalesce(sum(l.ready_quantity-l.voided_quantity) OVER(PARTITION BY l.source_id ORDER BY l.ready_sequence,l.id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) prior FROM public.%I l JOIN pg_temp.workflow_progress_map m ON l.source_id=(m.original->>''id'')::uuid) SELECT id,to_jsonb(fifo)-ARRAY[''new_id'',''target_item_id'',''target_queue'',''whole'',''capacity'',''prior''] original,new_id,target_item_id,target_queue,CASE WHEN whole THEN ready_quantity ELSE greatest(0,least(ready_quantity-voided_quantity,capacity-prior))::integer END take FROM fifo',lot_table) USING CASE lot_table WHEN 'emergency_floor_ready_lots' THEN 'tray_dispatched_quantity' ELSE 'kitchen_done_quantity' END;
   ALTER TABLE pg_temp.workflow_lot_map ADD COLUMN copied jsonb;
   UPDATE pg_temp.workflow_lot_map m SET copied=original||jsonb_build_object('id',CASE WHEN take=(original->>'ready_quantity')::integer THEN m.id ELSE gen_random_uuid() END,'order_id',target.id,'order_item_id',target_item_id,'queue_id',target_queue,'source_id',new_id,'ready_quantity',take,'voided_quantity',CASE WHEN take=(original->>'ready_quantity')::integer THEN (original->>'voided_quantity')::integer ELSE 0 END,key,least(take,(original->>key)::integer)) WHERE take>0;
   SELECT string_agg(format('%I=x.%I',a.attname,a.attname),',') INTO assignments FROM pg_attribute a WHERE a.attrelid=('public.'||lot_table)::regclass AND a.attnum>0 AND NOT a.attisdropped AND a.attname<>'id';
   EXECUTE format('UPDATE public.%I t SET %s FROM (SELECT (jsonb_populate_record(NULL::public.%I,copied)).* FROM pg_temp.workflow_lot_map WHERE take=(original->>''ready_quantity'')::integer)x WHERE t.id=x.id',lot_table,assignments,lot_table);
   EXECUTE format('UPDATE public.%I t SET ready_quantity=t.ready_quantity-m.take,%I=t.%I-least(m.take,(m.original->>$1)::integer) FROM pg_temp.workflow_lot_map m WHERE t.id=m.id AND m.take>0 AND m.take<(m.original->>''ready_quantity'')::integer',lot_table,key,key) USING key;
   EXECUTE format('INSERT INTO public.%I SELECT (jsonb_populate_record(NULL::public.%I,copied)).* FROM pg_temp.workflow_lot_map WHERE take>0 AND take<(original->>''ready_quantity'')::integer',lot_table,lot_table);
  END LOOP;
 END LOOP;
 SELECT jsonb_agg(jsonb_build_object('source_item_id',source_item_id,'target_item_id',target_item_id,'quantity',move_count) ORDER BY source_item_id) INTO moved_ids FROM pg_temp.workflow_move_map;
 PERFORM set_config('globos.cashier_item_mutation','off',true);
 PERFORM public.void_active_order_discount_for_item_change(source.id,p_store_id,'order_items_changed'); PERFORM public.void_active_order_discount_for_item_change(target.id,p_store_id,'order_items_changed');
 PERFORM public.recalc_order_status(source.id); PERFORM public.recalc_order_status(target.id);
 IF NOT EXISTS(SELECT 1 FROM public.order_items WHERE order_id=source.id AND status<>'cancelled' AND item_type='menu_item') THEN UPDATE public.orders SET status='cancelled',updated_at=now() WHERE id=source.id; END IF;
 UPDATE public.tables SET status='occupied',updated_at=now() WHERE id=p_target_table_id;
 UPDATE public.tables SET status='available',updated_at=now() WHERE id=source.table_id AND NOT EXISTS(SELECT 1 FROM public.orders WHERE table_id=source.table_id AND status NOT IN ('completed','cancelled'));
 PERFORM public.cashier_invalidate_changed_display(p_store_id,ARRAY[source.id,target.id]);
 PERFORM public.store_workflow_notify(p_store_id);
 response:=jsonb_build_object('source_order_id',source.id,'target_order_id',target.id,'target_table_id',p_target_table_id,'moved',moved_ids,'operation_id',p_operation_id,'discount_review_required',true);
 INSERT INTO public.cashier_item_operations(id,restaurant_id,order_id,kind,payload,response,created_by) VALUES(p_operation_id,p_store_id,source.id,'move',payload,response,auth.uid());
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES(auth.uid(),'cashier_move_order_items','orders',source.id,response);
 RETURN response;
EXCEPTION WHEN lock_not_available THEN RAISE EXCEPTION 'CASHIER_ITEM_CHANGED';
END;
$_$;


CREATE FUNCTION public.store_preparation_reconcile_items() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF current_setting('globos.cashier_item_mutation',true)='on' THEN RETURN NULL; END IF;
 UPDATE public.store_preparation_steps s SET started=least(s.started,src.quantity),done=least(s.done,src.quantity),revision=s.revision+1
 FROM public.store_preparation_tasks t JOIN public.store_preparation_sources src ON src.source_id=t.source_id AND src.source_kind=t.source_kind
 JOIN changed_workflow_items i ON i.id=t.order_item_id
 WHERE s.task_id=t.id AND NOT src.blocked AND (s.started>src.quantity OR s.done>src.quantity);
 RETURN NULL;
END;
$$;
CREATE TRIGGER zzzz_workflow_reconcile AFTER UPDATE ON public.order_items REFERENCING NEW TABLE AS changed_workflow_items FOR EACH STATEMENT EXECUTE FUNCTION public.store_preparation_reconcile_items();
REVOKE ALL ON FUNCTION public.store_preparation_reconcile_items() FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.cashier_partial_progress_sync() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE table_name text; lot_table text; used text; quantities jsonb; changes text;
BEGIN
 IF NEW.billing_cancelled_quantity=0 OR NEW.status='cancelled' OR current_setting('globos.cashier_item_mutation',true)='on' THEN RETURN NEW; END IF;
 IF NEW.menu_option_snapshot IS DISTINCT FROM OLD.menu_option_snapshot AND (to_jsonb(NEW)-'menu_option_snapshot')=(to_jsonb(OLD)-'menu_option_snapshot') THEN RETURN NEW; END IF;
 FOREACH table_name IN ARRAY ARRAY['emergency_fulfillment_items','emergency_combo_component_items','emergency_floor_direct_items'] LOOP
  changes:=CASE WHEN table_name='emergency_floor_direct_items' THEN '' ELSE ',kitchen_started_quantity=least(t.kitchen_started_quantity,x.required),kitchen_done_quantity=least(t.kitchen_done_quantity,x.required),tray_received_quantity=least(t.tray_received_quantity,x.required),tray_dispatched_quantity=least(t.tray_dispatched_quantity,x.required)' END;
  EXECUTE format($q$
   WITH lines AS MATERIALIZED(SELECT t.*,to_jsonb(t) data,CASE WHEN $2='emergency_fulfillment_items' OR to_jsonb(t)->>'line_key'='base' THEN 1 ELSE greatest(1,t.ordered_quantity::numeric/($3+$4)) END ratio
    FROM public.%I t WHERE order_item_id=$1 FOR UPDATE),
   counted AS (SELECT l.*,CASE WHEN $2='emergency_combo_component_items' OR $2='emergency_floor_direct_items' AND data->>'line_key'<>'base'
    THEN coalesce((SELECT CASE WHEN coalesce((c->>'is_total_quantity')::boolean,false) THEN (c->>'quantity')::integer ELSE (c->>'quantity')::integer*$3 END FROM jsonb_array_elements(coalesce($5,'[]'))c WHERE c->>'menu_item_id'=data->>'component_menu_item_id'),0)
    ELSE ceil($3*ratio)::integer END needed FROM lines l),
   computed AS(SELECT id,greatest(1,needed) source,greatest(ordered_quantity,ceil(($3+$4)*ratio)::integer) ordered,greatest(needed,floor_served_quantity) required,needed>0 active FROM counted),
   updated AS(UPDATE public.%I t SET source_quantity=x.source,ordered_quantity=x.ordered,excused_quantity=x.ordered-x.required,needs_review=false,is_cancelled=NOT x.active,updated_at=now()%s FROM computed x WHERE t.id=x.id RETURNING t.*)
   SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'floor',greatest(0,coalesce((to_jsonb(updated)->>'tray_dispatched_quantity')::integer,0)-floor_served_quantity),'tray',greatest(0,coalesce((to_jsonb(updated)->>'kitchen_done_quantity')::integer,0)-coalesce((to_jsonb(updated)->>'tray_dispatched_quantity')::integer,0)))),'[]') FROM updated
  $q$,table_name,table_name,changes) INTO quantities USING NEW.id,table_name,NEW.quantity,NEW.billing_cancelled_quantity,NEW.combo_components;
  IF table_name='emergency_floor_direct_items' THEN CONTINUE; END IF;
  FOREACH lot_table IN ARRAY ARRAY['emergency_floor_ready_lots','emergency_tray_ready_lots'] LOOP
   used:=CASE lot_table WHEN 'emergency_floor_ready_lots' THEN 'served_quantity' ELSE 'handed_quantity' END;
   EXECUTE format($q$
    WITH lots AS MATERIALIZED(SELECT l.id,l.source_id,l.ready_sequence,l.ready_quantity-l.%I-l.voided_quantity remaining,coalesce((q->>$2)::integer,0) allowed
     FROM public.%I l JOIN jsonb_array_elements($1)q ON (q->>'id')::uuid=l.source_id FOR UPDATE OF l),
    allocations AS(SELECT id,remaining,greatest(0,sum(remaining)OVER(PARTITION BY source_id)-allowed) excess,
     coalesce(sum(remaining)OVER(PARTITION BY source_id ORDER BY ready_sequence DESC,id DESC ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) prior FROM lots)
    UPDATE public.%I l SET voided_quantity=l.voided_quantity+greatest(0,least(a.remaining,a.excess-a.prior))::integer,updated_at=now() FROM allocations a WHERE l.id=a.id AND a.excess>a.prior AND a.remaining>0
   $q$,used,lot_table,lot_table) USING quantities,CASE lot_table WHEN 'emergency_floor_ready_lots' THEN 'floor' ELSE 'tray' END;
  END LOOP;
 END LOOP;
 RETURN NEW;
END;
$$;

DO $verify$ BEGIN
 IF strpos(pg_get_functiondef('public.cashier_move_order_items(uuid,uuid,uuid,jsonb,uuid)'::regprocedure),'store_preparation_steps')=0
 OR strpos(pg_get_functiondef('public.cashier_restore_item_quantity(uuid,uuid)'::regprocedure),'store_preparation_steps')=0
 OR has_function_privilege('authenticated','public.store_preparation_reconcile_items()','EXECUTE')
 THEN RAISE EXCEPTION 'WORKFLOW_MUTATION_CONTRACT_INVALID'; END IF;
END $verify$;
COMMIT;
