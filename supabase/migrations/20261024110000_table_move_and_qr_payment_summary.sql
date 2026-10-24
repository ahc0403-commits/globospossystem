-- Repair cashier movement under pg-safeupdate and expose the current table balance.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';
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
  'combo_components',coalesce((SELECT jsonb_agg(CASE WHEN coalesce((c->>'is_total_quantity')::boolean,false) THEN jsonb_set(c,'{quantity}',to_jsonb((c->>'quantity')::integer*move_count/original_count)) ELSE c END) FROM jsonb_array_elements(coalesce(original->'combo_components','[]'))c),'[]'::jsonb)) WHERE m.source_item_id IS NOT NULL AND m.move_count>0;
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
   coalesce((SELECT jsonb_object_agg(k,least(units,(original->>k)::integer)) FROM unnest(ARRAY['kitchen_started_quantity','kitchen_done_quantity','tray_received_quantity','tray_dispatched_quantity','floor_served_quantity','excused_quantity'])k WHERE original ? k AND move_count<original_count),'{}') WHERE m.new_id IS NOT NULL AND m.units>0;
  UPDATE pg_temp.workflow_progress_map m SET original=CASE WHEN move_count=original_count THEN copied ELSE original||jsonb_build_object('source_quantity',(original->>'source_quantity')::integer-units,'ordered_quantity',(original->>'ordered_quantity')::integer-units)||
   coalesce((SELECT jsonb_object_agg(k,(original->>k)::integer-(copied->>k)::integer) FROM unnest(ARRAY['kitchen_started_quantity','kitchen_done_quantity','tray_received_quantity','tray_dispatched_quantity','floor_served_quantity','excused_quantity'])k WHERE original ? k),'{}') END WHERE m.new_id IS NOT NULL AND m.units>0;
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

-- Internal, set-based quote. No client can choose another table/order through it.
-- Money follows the cashier's VAT allocation and service-charge calculation;
-- paid amounts and discounts are preaggregated separately to avoid fan-out.
CREATE FUNCTION public.qr_table_payment_summary(p_store_id uuid,p_table_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH scope AS MATERIALIZED (
  SELECT o.id,r.vat_pricing_mode,coalesce(b.service_charge_enabled,false) sc_enabled,
   coalesce(b.service_charge_rate,0) sc_rate
  FROM public.orders o JOIN public.restaurants r ON r.id=o.restaurant_id
  LEFT JOIN public.brands b ON b.id=r.brand_id
  WHERE o.restaurant_id=p_store_id AND o.table_id=p_table_id
   AND o.status IN ('pending','confirmed','serving') AND o.order_purpose='customer'
   AND o.sales_channel='dine_in' AND public.table_order_is_current(o)
 ), lines AS MATERIALIZED (
  SELECT i.*,s.vat_pricing_mode FROM scope s JOIN public.order_items i ON i.order_id=s.id
  WHERE i.restaurant_id=p_store_id AND i.status<>'cancelled'
 ), priced AS MATERIALIZED (
  SELECT i.id,i.order_id,public.calculate_item_vat(
    coalesce(nullif(i.vat_profile_snapshot,'[]'::jsonb),jsonb_build_array(jsonb_build_object('rate',
     CASE WHEN i.vat_rate IN (8,10) THEN i.vat_rate WHEN m.vat_category='alcohol' THEN 10 ELSE 8 END,'weight',1))),
    round(i.unit_price*i.quantity,2),coalesce(i.vat_pricing_mode,'exclusive')) tax
  FROM lines i LEFT JOIN public.menu_items m ON m.id=i.menu_item_id AND m.restaurant_id=p_store_id
  WHERE i.item_type='menu_item' AND NOT coalesce(i.is_service_item,false)
 ), menu_totals AS (
  SELECT order_id,sum((tax->>'total')::numeric) gross FROM priced GROUP BY order_id
 ), tax_totals AS (
  SELECT order_id,sum((part->>'total_amount_ex_tax')::numeric) FILTER(WHERE (part->>'vat_rate')::numeric=8) food,
   sum((part->>'total_amount_ex_tax')::numeric) FILTER(WHERE (part->>'vat_rate')::numeric=10) alcohol
  FROM priced CROSS JOIN LATERAL jsonb_array_elements(tax->'parts') part GROUP BY order_id
 ), charges AS (
  SELECT order_id,bool_or(item_type='service_charge') has_service,
   sum(CASE WHEN item_type='service_charge' THEN
    CASE WHEN paying_amount_inc_tax>0 THEN paying_amount_inc_tax ELSE unit_price*quantity END ELSE 0 END) service,
   sum(CASE WHEN item_type='wet_tissue_charge' THEN coalesce(paying_amount_inc_tax,
    CASE WHEN vat_pricing_mode='inclusive' THEN round(unit_price*quantity,2)
     ELSE round(unit_price*quantity*1.08,2) END) ELSE 0 END) fixed
  FROM lines GROUP BY order_id
 ), allocation_totals AS (
  SELECT d.order_id,sum(least(greatest(a.discount_amount,0),(p.tax->>'total')::numeric)) amount
  FROM scope s JOIN public.order_discounts d ON d.order_id=s.id AND d.restaurant_id=p_store_id AND d.status='active'
  JOIN public.order_discount_lines a ON a.order_discount_id=d.id
  JOIN priced p ON p.id=a.order_item_id GROUP BY d.order_id
 ), paid AS (
  SELECT p.order_id,sum(p.amount_portion) amount FROM scope s JOIN public.payments p ON p.order_id=s.id
  WHERE p.restaurant_id=p_store_id GROUP BY p.order_id
 ), order_quotes AS (
  SELECT s.id,coalesce(m.gross,0) menu,coalesce(c.fixed,0) fixed,coalesce(p.amount,0) paid,
   CASE WHEN c.has_service THEN c.service WHEN s.sc_enabled AND s.sc_rate>0 THEN
    round(coalesce(t.food,0)*s.sc_rate/100,2)+round(round(coalesce(t.food,0)*s.sc_rate/100,2)*.08,2)+
    round(coalesce(t.alcohol,0)*s.sc_rate/100,2)+round(round(coalesce(t.alcohol,0)*s.sc_rate/100,2)*.10,2)
    ELSE 0 END service,
   round(least(coalesce(m.gross,0),greatest(0,
    CASE WHEN a.amount>0 THEN a.amount ELSE coalesce(d.discount_amount,0) END)),2) discount
  FROM scope s LEFT JOIN menu_totals m ON m.order_id=s.id LEFT JOIN tax_totals t ON t.order_id=s.id
  LEFT JOIN charges c ON c.order_id=s.id LEFT JOIN paid p ON p.order_id=s.id
  LEFT JOIN allocation_totals a ON a.order_id=s.id
  LEFT JOIN public.order_discounts d ON d.order_id=s.id AND d.restaurant_id=p_store_id AND d.status='active'
 ), balances AS (
  SELECT *,round(menu+service+fixed-discount,2) total FROM order_quotes
 ) SELECT jsonb_build_object('currency','VND','order_count',count(*),
  'total_amount',coalesce(sum(total),0),'paid_total',coalesce(sum(paid),0),
  'remaining_due',coalesce(sum(CASE WHEN total-paid<=.01 THEN 0 ELSE round(total-paid,2) END),0),
  'calculated_at',statement_timestamp()) FROM balances
$$;
REVOKE ALL ON FUNCTION public.qr_table_payment_summary(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;

-- Preserve the token validation, day boundary and delivery-history wrappers.
ALTER FUNCTION public.qr_get_active_order(text) RENAME TO qr_get_active_order_before_payment_summary;
REVOKE ALL ON FUNCTION public.qr_get_active_order_before_payment_summary(text) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.qr_get_active_order(p_token text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE result jsonb; shop uuid; tab uuid;
BEGIN
 result:=public.qr_get_active_order_before_payment_summary(p_token);
 SELECT q.restaurant_id,q.table_id INTO shop,tab FROM public.table_qr_tokens q
 JOIN public.tables t ON t.id=q.table_id AND t.restaurant_id=q.restaurant_id
 JOIN public.restaurants r ON r.id=q.restaurant_id AND r.is_active
 WHERE q.token=nullif(btrim(coalesce(p_token,'')),'') AND q.is_active;
 IF NOT FOUND THEN RAISE EXCEPTION 'QR_TOKEN_INVALID'; END IF;
 RETURN result||jsonb_build_object('payment_summary',public.qr_table_payment_summary(shop,tab));
END $$;
REVOKE ALL ON FUNCTION public.qr_get_active_order(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qr_get_active_order(text) TO anon,authenticated,service_role;

-- The legacy enricher performed OFFSET and a query for every item/part.
-- Carry stable item IDs through the history filter, then enrich the whole set.
CREATE OR REPLACE FUNCTION public.qr_get_active_order_pre_takeout(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $$
DECLARE
  v_token text := NULLIF(btrim(COALESCE(p_token, '')), '');
  v_table record;
  v_order public.orders%ROWTYPE;
  v_items jsonb := '[]'::jsonb;
BEGIN
  SELECT q.restaurant_id, q.table_id
  INTO v_table
  FROM public.table_qr_tokens q
  JOIN public.tables t
    ON t.id = q.table_id AND t.restaurant_id = q.restaurant_id
  JOIN public.restaurants r
    ON r.id = q.restaurant_id AND r.is_active = true
  WHERE q.token = v_token AND q.is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'QR_TOKEN_INVALID'; END IF;

  SELECT o.* INTO v_order
  FROM public.orders o
  WHERE o.restaurant_id = v_table.restaurant_id
    AND o.table_id = v_table.table_id
    AND o.status IN ('pending', 'confirmed', 'serving') AND public.table_order_is_current(o)
  ORDER BY o.created_at DESC
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'active', false, 'order_code', '', 'status', '',
      'fulfillment_mode', 'pos_print', 'items', '[]'::jsonb
    );
  END IF;

  WITH scoped AS MATERIALIZED (
    SELECT * FROM public.order_items WHERE order_id=v_order.id AND restaurant_id=v_table.restaurant_id
      AND status<>'cancelled' AND item_type='menu_item' AND NOT coalesce(is_service_item,false)
  ), standard AS MATERIALIZED (
    SELECT f.*,sess.activated_at,sess.status session_status FROM public.emergency_fulfillment_items f
    JOIN scoped i ON i.id=f.order_item_id JOIN public.emergency_fulfillment_sessions sess ON sess.id=f.session_id
    WHERE f.restaurant_id=v_table.restaurant_id AND NOT f.is_cancelled
  ), direct AS MATERIALIZED (
    SELECT f.*,sess.activated_at,sess.status session_status FROM public.emergency_floor_direct_items f
    JOIN scoped i ON i.id=f.order_item_id JOIN public.emergency_fulfillment_sessions sess ON sess.id=f.session_id
    WHERE f.restaurant_id=v_table.restaurant_id AND NOT f.is_cancelled
  ), base AS (
    SELECT DISTINCT ON(order_item_id) order_item_id,floor_served FROM (
      SELECT order_item_id,floor_served_quantity floor_served,activated_at,created_at FROM standard
      UNION ALL SELECT order_item_id,floor_served_quantity,activated_at,created_at FROM direct WHERE line_key='base'
    ) progress ORDER BY order_item_id,activated_at DESC,created_at DESC
  ), part_rows AS (
    SELECT st.order_item_id,st.created_at sort_key,'base'::text line_key,jsonb_build_object(
      'line_key','base','source_kind','order_item','fulfillment_route','kitchen_tray_floor',
      'name',coalesce(nullif(oi.display_name,''),nullif(oi.label,''),nullif(mi.name,''),'Item'),
      'name_ko',coalesce(nullif(mi.name_ko,''),nullif(oi.display_name,''),nullif(oi.label,''),nullif(mi.name,''),'메뉴'),
      'name_vi',coalesce(nullif(mi.name_vi,''),nullif(oi.display_name,''),nullif(oi.label,''),nullif(mi.name,''),'Món'),
      'name_en',coalesce(nullif(mi.name_en,''),nullif(oi.display_name,''),nullif(oi.label,''),nullif(mi.name,''),'Item'),
      'quantity',st.ordered_quantity,'served_quantity',st.floor_served_quantity) payload
    FROM standard st JOIN scoped oi ON oi.id=st.order_item_id
    LEFT JOIN public.menu_items mi ON mi.id=oi.menu_item_id AND mi.restaurant_id=oi.restaurant_id WHERE st.session_status='active'
    UNION ALL
    SELECT d.order_item_id,d.created_at,d.line_key,jsonb_build_object(
      'line_key',d.line_key,'source_kind',d.source_kind,'fulfillment_route','floor_direct',
      'name',d.name_en,'name_ko',d.name_ko,'name_vi',d.name_vi,'name_en',d.name_en,
      'quantity',d.ordered_quantity,'served_quantity',d.floor_served_quantity)
    FROM direct d WHERE d.session_status='active'
  ), parts AS (
    SELECT order_item_id,jsonb_agg(payload ORDER BY sort_key,line_key) payload FROM part_rows GROUP BY order_item_id
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'order_item_id', oi.id, 'name', COALESCE(NULLIF(oi.display_name, ''), NULLIF(oi.label, ''),
        NULLIF(mi.name, ''), 'Item'),
      'name_ko', COALESCE(NULLIF(mi.name_ko, ''), NULLIF(oi.display_name, ''),
        NULLIF(oi.label, ''), NULLIF(mi.name, ''), '메뉴'),
      'name_vi', COALESCE(NULLIF(mi.name_vi, ''), NULLIF(oi.display_name, ''),
        NULLIF(oi.label, ''), NULLIF(mi.name, ''), 'Món ăn'),
      'name_en', COALESCE(NULLIF(mi.name_en, ''), NULLIF(oi.display_name, ''),
        NULLIF(oi.label, ''), NULLIF(mi.name, ''), 'Item'),
      'quantity', oi.quantity,
      'status', oi.status,
      'served_quantity', CASE
        WHEN v_order.fulfillment_mode_snapshot = 'paperless'
          THEN LEAST(oi.quantity, GREATEST(COALESCE(base.floor_served, 0), 0))
        ELSE 0
      END,
      'fulfillment_parts', CASE
        WHEN v_order.fulfillment_mode_snapshot = 'paperless'
          THEN COALESCE(parts.payload, '[]'::jsonb)
        ELSE '[]'::jsonb
      END
    ) ORDER BY oi.created_at, oi.id
  ), '[]'::jsonb)
  INTO v_items
  FROM scoped oi
  LEFT JOIN public.menu_items mi ON mi.id=oi.menu_item_id AND mi.restaurant_id=oi.restaurant_id
  LEFT JOIN base ON base.order_item_id=oi.id
  LEFT JOIN parts ON parts.order_item_id=oi.id;

  RETURN jsonb_build_object(
    'active', true,
    'order_code', substring(v_order.id::text from 1 for 8),
    'status', v_order.status,
    'fulfillment_mode', v_order.fulfillment_mode_snapshot,
    'items', v_items
  );
END;
$$;
REVOKE ALL ON FUNCTION public.qr_get_active_order_pre_takeout(text) FROM PUBLIC,anon,authenticated,service_role;

-- The takeout wrapper used one OFFSET lookup per response line. Stable IDs
-- also prevent reset-filtered lines from being paired with a different menu.
DO $$ DECLARE d text; needle text:=$old$  LEFT JOIN LATERAL (
    SELECT oi.is_takeout
    FROM public.order_items oi
    WHERE oi.order_id = v_order.id
      AND oi.status <> 'cancelled'
      AND oi.item_type = 'menu_item'
      AND COALESCE(oi.is_service_item, false) = false
    ORDER BY oi.created_at, oi.id
    OFFSET (source_item.ord - 1) LIMIT 1
  ) order_item ON true;$old$;
BEGIN
 d:=pg_get_functiondef('public.qr_get_active_order_pre_display_reset(text)'::regprocedure);
 IF strpos(d,needle)=0 THEN RAISE EXCEPTION 'QR_TAKEOUT_BATCH_PREDECESSOR_DRIFT'; END IF;
 EXECUTE replace(d,needle,$new$  LEFT JOIN public.order_items order_item
   ON order_item.id=(source_item.raw->>'order_item_id')::uuid
   AND order_item.order_id=v_order.id AND order_item.restaurant_id=v_table.restaurant_id;$new$);
END $$;


CREATE OR REPLACE FUNCTION public.emergency_enrich_qr_unserved_items(p_order_id uuid,p_items jsonb)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH ordered AS MATERIALIZED (
  SELECT i.id,row_number() OVER(ORDER BY i.created_at,i.id) ord FROM public.order_items i
  WHERE i.order_id=p_order_id AND i.status<>'cancelled' AND i.item_type='menu_item' AND NOT coalesce(i.is_service_item,false)
 ), input AS MATERIALIZED (
  SELECT raw,ord,coalesce(nullif(raw->>'order_item_id','')::uuid,i.id) item_id
  FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items)='array' THEN p_items ELSE '[]'::jsonb END)
   WITH ORDINALITY x(raw,ord) LEFT JOIN ordered i USING(ord)
 ), base AS MATERIALIZED (
  SELECT DISTINCT ON(f.order_item_id) f.order_item_id,f.ordered_quantity-f.excused_quantity required,f.excused_quantity
  FROM public.emergency_fulfillment_items f JOIN ordered i ON i.id=f.order_item_id
  WHERE NOT f.is_cancelled ORDER BY f.order_item_id,f.created_at DESC,f.id DESC
 ), direct AS MATERIALIZED (
  SELECT DISTINCT ON(f.order_item_id,f.line_key) f.order_item_id,f.line_key,
   f.ordered_quantity-f.excused_quantity required,f.excused_quantity
  FROM public.emergency_floor_direct_items f JOIN ordered i ON i.id=f.order_item_id
  WHERE NOT f.is_cancelled ORDER BY f.order_item_id,f.line_key,f.created_at DESC,f.id DESC
 ), parts AS (
  SELECT x.ord,jsonb_agg(jsonb_set(part,'{quantity}',to_jsonb(greatest(0,coalesce((part->>'quantity')::integer,0)-
   CASE WHEN part->>'fulfillment_route'='floor_direct' THEN coalesce(d.excused_quantity,0)
    ELSE coalesce(b.excused_quantity,0) END)),true) ORDER BY n) payload
  FROM input x CROSS JOIN LATERAL jsonb_array_elements(coalesce(raw->'fulfillment_parts','[]'::jsonb)) WITH ORDINALITY p(part,n)
  LEFT JOIN base b ON b.order_item_id=x.item_id
  LEFT JOIN direct d ON d.order_item_id=x.item_id AND d.line_key=coalesce(part->>'line_key','base') GROUP BY x.ord
 ) SELECT coalesce(jsonb_agg(CASE WHEN i.id IS NULL THEN x.raw ELSE
  x.raw||jsonb_build_object('quantity',coalesce(b.required,d.required,(x.raw->>'quantity')::integer,0),
   'fulfillment_parts',coalesce(p.payload,'[]'::jsonb)) END ORDER BY x.ord),'[]'::jsonb)
 FROM input x LEFT JOIN ordered i ON i.id=x.item_id LEFT JOIN base b ON b.order_item_id=i.id
 LEFT JOIN direct d ON d.order_item_id=i.id AND d.line_key='base' LEFT JOIN parts p ON p.ord=x.ord
$$;
REVOKE ALL ON FUNCTION public.emergency_enrich_qr_unserved_items(uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;

DO $$ DECLARE d text; BEGIN
 d:=pg_get_functiondef('public.cashier_move_order_items(uuid,uuid,uuid,jsonb,uuid)'::regprocedure);
 IF strpos(d,'WHERE m.source_item_id IS NOT NULL AND m.move_count>0')=0
 OR strpos(d,'END WHERE m.new_id IS NOT NULL AND m.units>0')=0
 OR has_function_privilege('anon','public.qr_table_payment_summary(uuid,uuid)','EXECUTE')
 OR has_function_privilege('authenticated','public.qr_table_payment_summary(uuid,uuid)','EXECUTE')
 OR has_function_privilege('anon','public.qr_get_active_order_before_payment_summary(text)','EXECUTE')
 THEN RAISE EXCEPTION 'TABLE_MOVE_PAYMENT_SUMMARY_CONTRACT_INVALID'; END IF;
END $$;
COMMIT;
