-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';
ALTER TABLE public.order_items ADD COLUMN billing_cancelled_quantity integer NOT NULL DEFAULT 0 CHECK(billing_cancelled_quantity>=0), ADD COLUMN cancelled_consumed_quantity integer NOT NULL DEFAULT 0 CHECK(cancelled_consumed_quantity>=0);
CREATE TABLE public.cashier_item_operations(
 id uuid PRIMARY KEY,restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),order_id uuid NOT NULL REFERENCES public.orders(id),
 kind text NOT NULL CHECK(kind IN ('partial_cancel','move')),payload jsonb NOT NULL,response jsonb NOT NULL,
 before_progress jsonb,after_progress jsonb,ledger_id uuid REFERENCES public.order_cancellation_ledger(id),created_by uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.cashier_item_operations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.cashier_item_operations FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.cashier_item_operations TO service_role;
CREATE FUNCTION public.cashier_item_operation_immutable() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'CASHIER_OPERATION_IMMUTABLE'; END; $$;
CREATE TRIGGER cashier_item_operation_immutable BEFORE UPDATE OR DELETE ON public.cashier_item_operations FOR EACH ROW EXECUTE FUNCTION public.cashier_item_operation_immutable();
CREATE FUNCTION public.cashier_require_item_actor(p_store_id uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.users WHERE auth_id=auth.uid() AND is_active AND role IN ('cashier','admin','store_admin','brand_admin','super_admin')) OR NOT public.is_super_admin() AND NOT EXISTS(SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(store_id) WHERE s.store_id=p_store_id) THEN RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN'; END IF;
END;
$$;
CREATE FUNCTION public.cashier_assert_unpaid(p_order_id uuid,p_store_id uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.orders WHERE id=$1 AND restaurant_id=$2 AND status NOT IN ('cancelled','completed')) THEN RAISE EXCEPTION 'ORDER_NOT_MUTABLE'; END IF;
 IF EXISTS(SELECT 1 FROM public.payments WHERE order_id=$1) THEN RAISE EXCEPTION 'ORDER_HAS_PAYMENTS_USE_ADJUSTMENT'; END IF;
 IF EXISTS(SELECT 1 FROM public.direct_order_financials WHERE order_id=$1) THEN RAISE EXCEPTION 'DIRECT_ORDER_FINAL_AMOUNT_LOCKED'; END IF;
END;
$$;
CREATE FUNCTION public.cashier_invalidate_changed_display(p_store_id uuid,p_order_ids uuid[]) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF to_regclass('public.customer_payment_displays') IS NOT NULL THEN
  UPDATE public.customer_payment_displays SET status='idle',order_id=NULL,payload=NULL,updated_at=now()
  WHERE store_id=p_store_id AND status='showing' AND COALESCE(payload->>'phase','payment')='payment'
   AND (order_id=ANY(p_order_ids) OR payload->>'is_combined'='true');
 END IF;
END; $$;
CREATE FUNCTION public.cashier_item_progress(p_item_id uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT jsonb_build_object('base',COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.id) FROM public.emergency_fulfillment_items t WHERE order_item_id=$1),'[]'::jsonb),
 'combo',COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.id) FROM public.emergency_combo_component_items t WHERE order_item_id=$1),'[]'::jsonb),
 'direct',COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.id) FROM public.emergency_floor_direct_items t WHERE order_item_id=$1),'[]'::jsonb),
 'floor_lots',COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.id) FROM public.emergency_floor_ready_lots t WHERE order_item_id=$1),'[]'::jsonb),
 'tray_lots',COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.id) FROM public.emergency_tray_ready_lots t WHERE order_item_id=$1),'[]'::jsonb));
$$;
-- Only these scoped RPCs suppress the ordinary new-order enqueue during a split.
DO $skip_sync$
DECLARE signature text; d text;
BEGIN
 FOREACH signature IN ARRAY ARRAY['public.emergency_sync_order_item()','public.emergency_sync_combo_component_items()'] LOOP
  SELECT pg_get_functiondef(signature::regprocedure) INTO d;
  IF strpos(d,'BEGIN')=0 THEN RAISE EXCEPTION 'CASHIER_KDS_SYNC_ANCHOR_DRIFT'; END IF;
  EXECUTE regexp_replace(d,'BEGIN','BEGIN IF current_setting(''globos.cashier_item_mutation'',true) IN (''on'',''repair'') THEN RETURN NEW; END IF; IF NEW.billing_cancelled_quantity>0 AND NEW.status<>''cancelled'' THEN RETURN NEW; END IF;');
 END LOOP;
END; $skip_sync$;
DO $preserve_cancelled_history$
DECLARE d text; needle text:='IF NEW.source_quantity < NEW.kitchen_started_quantity THEN';
BEGIN
 SELECT pg_get_functiondef('public.emergency_preserve_started_quantity()'::regprocedure) INTO d;
 IF strpos(d,needle)=0 THEN RAISE EXCEPTION 'CASHIER_STARTED_HISTORY_ANCHOR_DRIFT'; END IF;
 EXECUTE replace(d,needle,'IF NEW.source_quantity < NEW.kitchen_started_quantity AND NOT EXISTS(SELECT 1 FROM public.order_items WHERE id=NEW.order_item_id AND billing_cancelled_quantity>0) THEN');
END; $preserve_cancelled_history$;
CREATE FUNCTION public.cashier_trim_ready_lots(p_source_id uuid,p_floor_remaining integer,p_tray_remaining integer) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE kind text; name text; used text; excess integer; lot record; take integer;
BEGIN
 FOREACH kind IN ARRAY ARRAY['floor','tray'] LOOP
  name:='emergency_'||kind||'_ready_lots'; used:=CASE WHEN kind='floor' THEN 'served_quantity' ELSE 'handed_quantity' END;
  EXECUTE format('SELECT greatest(0,COALESCE(sum(ready_quantity-%I-voided_quantity),0)-$2)::integer FROM public.%I WHERE source_id=$1',used,name) INTO excess USING p_source_id,CASE WHEN kind='floor' THEN p_floor_remaining ELSE p_tray_remaining END;
  FOR lot IN EXECUTE format('SELECT id,ready_quantity-%I-voided_quantity remaining FROM public.%I WHERE source_id=$1 AND ready_quantity>%I+voided_quantity ORDER BY ready_sequence DESC,id DESC FOR UPDATE',used,name,used) USING p_source_id LOOP
   EXIT WHEN excess<=0; take:=least(excess,lot.remaining);
   EXECUTE format('UPDATE public.%I SET voided_quantity=voided_quantity+$2,updated_at=now() WHERE id=$1',name) USING lot.id,take; excess:=excess-take;
  END LOOP;
 END LOOP;
END;
$$;
CREATE FUNCTION public.cashier_resize_combo(p_components jsonb,p_before integer,p_after integer) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path=public,pg_catalog AS $$
DECLARE component jsonb; result jsonb:='[]'::jsonb; remaining integer; units integer;
BEGIN
 SELECT ceil(COALESCE(sum((c->>'quantity')::integer),0)*p_after::numeric/p_before)::integer INTO remaining FROM jsonb_array_elements(COALESCE(p_components,'[]'::jsonb)) c WHERE COALESCE((c->>'is_total_quantity')::boolean,false);
 FOR component IN SELECT value FROM jsonb_array_elements(COALESCE(p_components,'[]'::jsonb)) LOOP
  IF COALESCE((component->>'is_total_quantity')::boolean,false) THEN
   units:=least(remaining,(component->>'quantity')::integer); remaining:=remaining-units;
   IF units>0 THEN result:=result||jsonb_build_array(jsonb_set(component,'{quantity}',to_jsonb(units))); END IF;
  ELSE result:=result||jsonb_build_array(component); END IF;
 END LOOP;
 RETURN result;
END;
$$;
-- A moved line carries the original price, choices and VAT snapshot.
DO $preserve_moved_snapshots$
DECLARE signature text; d text;
BEGIN
 FOREACH signature IN ARRAY ARRAY['public.snapshot_order_item_combo_components()','public.snapshot_order_item_vat()'] LOOP
  IF to_regprocedure(signature) IS NOT NULL THEN
   SELECT pg_get_functiondef(signature::regprocedure) INTO d;
   EXECUTE regexp_replace(d,'BEGIN','BEGIN IF current_setting(''globos.cashier_item_mutation'',true)=''on'' THEN RETURN NEW; END IF;');
  END IF;
 END LOOP;
END; $preserve_moved_snapshots$;
CREATE FUNCTION public.cashier_partial_progress_sync() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE table_name text; line record; ratio numeric; source integer; required integer; ordered integer; component jsonb; active boolean;
BEGIN
 IF NEW.billing_cancelled_quantity=0 OR NEW.status='cancelled' OR current_setting('globos.cashier_item_mutation',true)='on' THEN RETURN NEW; END IF;
 FOREACH table_name IN ARRAY ARRAY['emergency_fulfillment_items','emergency_combo_component_items','emergency_floor_direct_items'] LOOP
  FOR line IN EXECUTE format('SELECT * FROM public.%I WHERE order_item_id=$1 FOR UPDATE',table_name) USING NEW.id LOOP
   ratio:=CASE WHEN table_name='emergency_fulfillment_items' OR to_jsonb(line)->>'line_key'='base' THEN 1 ELSE greatest(1,line.ordered_quantity::numeric/(NEW.quantity+NEW.billing_cancelled_quantity)) END;
   ordered:=greatest(line.ordered_quantity,ceil((NEW.quantity+NEW.billing_cancelled_quantity)*ratio)::integer);
   source:=ceil(NEW.quantity*ratio)::integer;
   IF table_name='emergency_combo_component_items' OR table_name='emergency_floor_direct_items' AND to_jsonb(line)->>'line_key'<>'base' THEN
    SELECT c INTO component FROM jsonb_array_elements(COALESCE(NEW.combo_components,'[]'::jsonb)) c WHERE c->>'menu_item_id'=line.component_menu_item_id::text;
    source:=CASE WHEN component IS NULL THEN 0 WHEN COALESCE((component->>'is_total_quantity')::boolean,false) THEN (component->>'quantity')::integer ELSE (component->>'quantity')::integer*NEW.quantity END;
   END IF;
   active:=source>0; required:=greatest(source,line.floor_served_quantity); source:=greatest(1,source);
   IF table_name='emergency_floor_direct_items' THEN
    EXECUTE format('UPDATE public.%I SET source_quantity=$2,ordered_quantity=$3,excused_quantity=$3-$4,needs_review=false,is_cancelled=NOT $5,updated_at=now() WHERE id=$1',table_name) USING line.id,source,ordered,required,active;
   ELSE
    EXECUTE format('UPDATE public.%I SET source_quantity=$2,ordered_quantity=$3,excused_quantity=$3-$4,kitchen_started_quantity=least(kitchen_started_quantity,$4),kitchen_done_quantity=least(kitchen_done_quantity,$4),tray_received_quantity=least(tray_received_quantity,$4),tray_dispatched_quantity=least(tray_dispatched_quantity,$4),needs_review=false,is_cancelled=NOT $5,updated_at=now() WHERE id=$1',table_name) USING line.id,source,ordered,required,active;
    PERFORM public.cashier_trim_ready_lots(line.id,greatest(0,least(line.tray_dispatched_quantity,required)-line.floor_served_quantity),greatest(0,least(line.kitchen_done_quantity,required)-least(line.tray_dispatched_quantity,required)));
   END IF;
  END LOOP;
 END LOOP;
 RETURN NEW;
END;
$$;
CREATE TRIGGER zzzz_cashier_partial_progress_sync AFTER UPDATE ON public.order_items FOR EACH ROW EXECUTE FUNCTION public.cashier_partial_progress_sync();
CREATE FUNCTION public.cashier_remaining_consumed_quantity(p_item_id uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE item public.order_items%ROWTYPE; progress jsonb; prepared integer;
BEGIN
 SELECT * INTO item FROM public.order_items WHERE id=p_item_id;
 PERFORM 1 FROM public.emergency_fulfillment_items WHERE order_item_id=item.id ORDER BY id FOR UPDATE;
 PERFORM 1 FROM public.emergency_combo_component_items WHERE order_item_id=item.id ORDER BY id FOR UPDATE;
 PERFORM 1 FROM public.emergency_floor_direct_items WHERE order_item_id=item.id ORDER BY id FOR UPDATE;
 progress:=public.cashier_item_progress(item.id);
 IF jsonb_array_length(progress->'base')+jsonb_array_length(progress->'combo')+jsonb_array_length(progress->'direct')>0 THEN
  SELECT COALESCE(max(ceil(COALESCE((x->>'kitchen_started_quantity')::numeric,(x->>'floor_served_quantity')::numeric,0)/greatest(1,(x->>'ordered_quantity')::numeric/(item.quantity+item.billing_cancelled_quantity)))::integer),0) INTO prepared
  FROM jsonb_array_elements((progress->'base')||(progress->'combo')||(progress->'direct')) x;
 ELSE prepared:=CASE WHEN item.status IN ('preparing','ready','served') THEN item.quantity ELSE 0 END; END IF;
 RETURN least(item.quantity,prepared);
END;
$$;
REVOKE ALL ON FUNCTION public.cashier_remaining_consumed_quantity(uuid) FROM PUBLIC,anon,authenticated;
-- Whole-line cancellation and its undo must share the order-first lock order.
-- A whole-line undo must never reverse an earlier partial-cancellation entry.
DO $whole_cancel_compatibility$
DECLARE signature text; d text; anchor text:='  SELECT * INTO v_item';
BEGIN
 FOREACH signature IN ARRAY ARRAY['public.cancel_order_item(uuid,uuid)','public.restore_cancelled_order_item(uuid,uuid)'] LOOP
  SELECT pg_get_functiondef(signature::regprocedure) INTO d;
  IF strpos(d,anchor)=0 THEN RAISE EXCEPTION 'CASHIER_CANCELLATION_ANCHOR_DRIFT'; END IF;
  d:=replace(d,anchor,'  PERFORM 1 FROM public.orders WHERE id=(SELECT order_id FROM public.order_items WHERE id=p_item_id AND restaurant_id=p_store_id) FOR UPDATE;'||chr(10)||anchor);
  IF signature LIKE '%restore_%' THEN
   IF strpos(d,'AND l.cancellation_scope = ''item''')=0 THEN RAISE EXCEPTION 'CASHIER_CANCELLATION_ANCHOR_DRIFT'; END IF;
   d:=replace(d,'AND l.cancellation_scope = ''item''','AND l.cancellation_scope = ''item'' AND (l.item_snapshot->0->>''partial'') IS DISTINCT FROM ''true''');
   IF strpos(d,'SET status = v_restore_status')=0 THEN RAISE EXCEPTION 'CASHIER_CANCELLATION_ANCHOR_DRIFT'; END IF;
   d:=replace(d,'SET status = v_restore_status','SET status = v_restore_status, cancelled_consumed_quantity=COALESCE((v_ledger.item_snapshot->0->>''cancelled_consumed_quantity'')::integer,v_item.cancelled_consumed_quantity)');
  ELSE
   IF strpos(d,'''is_service_item'', v_item.is_service_item')=0 OR strpos(d,'SET status = ''cancelled''')=0 THEN RAISE EXCEPTION 'CASHIER_CANCELLATION_ANCHOR_DRIFT'; END IF;
   d:=replace(d,'''is_service_item'', v_item.is_service_item','''is_service_item'', v_item.is_service_item, ''cancelled_consumed_quantity'', v_item.cancelled_consumed_quantity');
   d:=replace(d,'SET status = ''cancelled''','SET status = ''cancelled'', cancelled_consumed_quantity=cancelled_consumed_quantity+CASE WHEN billing_cancelled_quantity>0 THEN public.cashier_remaining_consumed_quantity(id) ELSE 0 END');
  END IF;
  EXECUTE d;
 END LOOP;
END; $whole_cancel_compatibility$;
CREATE FUNCTION public.cashier_cancel_item_quantity(p_store_id uuid,p_item_id uuid,p_expected_quantity integer,p_new_quantity integer,p_operation_id uuid,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE item public.order_items%ROWTYPE; old public.cashier_item_operations%ROWTYPE; payload jsonb; before_state jsonb; after_state jsonb; ledger uuid; delta integer; consumed integer; prepared integer; amount numeric; response jsonb; original_order uuid;
BEGIN
 PERFORM public.cashier_require_item_actor(p_store_id);
 payload:=jsonb_build_object('item_id',p_item_id,'expected_quantity',p_expected_quantity,'new_quantity',p_new_quantity,'reason',p_reason);
 IF p_operation_id IS NULL THEN RAISE EXCEPTION 'INVALID_QUANTITY'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_operation_id::text,0));
 SELECT * INTO old FROM public.cashier_item_operations WHERE id=p_operation_id;
 IF FOUND THEN IF old.restaurant_id<>p_store_id OR old.kind<>'partial_cancel' OR old.payload<>payload THEN RAISE EXCEPTION 'CASHIER_OPERATION_CHANGED'; END IF; RETURN old.response; END IF;
 SELECT * INTO item FROM public.order_items WHERE id=p_item_id AND restaurant_id=p_store_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND'; END IF;
 original_order:=item.order_id;
 PERFORM 1 FROM public.orders WHERE id=original_order FOR UPDATE;
 PERFORM public.cashier_assert_unpaid(original_order,p_store_id);
 SELECT * INTO item FROM public.order_items WHERE id=p_item_id AND restaurant_id=p_store_id FOR UPDATE;
 IF NOT FOUND OR item.order_id IS DISTINCT FROM original_order THEN RAISE EXCEPTION 'CASHIER_ITEM_CHANGED'; END IF;
 IF p_new_quantity IS NULL OR p_new_quantity<1 OR p_new_quantity>=item.quantity OR item.quantity IS DISTINCT FROM p_expected_quantity OR item.status NOT IN ('pending','preparing','ready','served') OR item.item_type<>'menu_item' OR char_length(btrim(COALESCE(p_reason,''))) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'CASHIER_ITEM_CHANGED'; END IF;
 -- Lock progress against kitchen, tray and floor actions before taking the snapshot.
 PERFORM 1 FROM public.emergency_fulfillment_items WHERE order_item_id=item.id ORDER BY id FOR UPDATE;
 PERFORM 1 FROM public.emergency_combo_component_items WHERE order_item_id=item.id ORDER BY id FOR UPDATE;
 PERFORM 1 FROM public.emergency_floor_direct_items WHERE order_item_id=item.id ORDER BY id FOR UPDATE;
 before_state:=public.cashier_item_progress(item.id); delta:=item.quantity-p_new_quantity;
 IF jsonb_array_length(before_state->'base')+jsonb_array_length(before_state->'combo')+jsonb_array_length(before_state->'direct')>0 THEN
  SELECT COALESCE(max(ceil(COALESCE((x->>'kitchen_started_quantity')::numeric,(x->>'floor_served_quantity')::numeric,0)/greatest(1,(x->>'ordered_quantity')::numeric/(item.quantity+item.billing_cancelled_quantity)))::integer),0) INTO prepared
  FROM jsonb_array_elements((before_state->'base')||(before_state->'combo')||(before_state->'direct')) x;
  -- Counters for cancelled, unserved work have already been trimmed on prior
  -- edits. Count the newly cancelled prepared units from the remaining bill;
  -- do not subtract the previously recorded consumed units a second time.
  consumed:=least(delta,greatest(0,least(item.quantity,prepared)-p_new_quantity));
 ELSE consumed:=CASE WHEN item.status IN ('preparing','ready','served') THEN delta ELSE 0 END; END IF;
 amount:=CASE WHEN item.is_service_item THEN 0 ELSE round(COALESCE(NULLIF(item.paying_amount_inc_tax,0),item.unit_price*item.quantity)*delta/item.quantity,2) END;
 INSERT INTO public.order_cancellation_ledger(restaurant_id,order_id,order_item_id,cancellation_scope,cancelled_amount,quantity,unit_price,item_snapshot,order_status_snapshot,created_by)
 SELECT p_store_id,item.order_id,item.id,'item',amount,delta,item.unit_price,jsonb_build_array(to_jsonb(item)||jsonb_build_object('quantity',delta,'partial',true,'before_quantity',item.quantity,'after_quantity',p_new_quantity,'reason',p_reason,'paying_amount_inc_tax',amount,'before_paying_amount_inc_tax',item.paying_amount_inc_tax)),status,auth.uid() FROM public.orders WHERE id=item.order_id RETURNING id INTO ledger;
 PERFORM set_config('globos.cashier_item_mutation','on',true);
 UPDATE public.order_items SET quantity=p_new_quantity,paying_amount_inc_tax=round(item.paying_amount_inc_tax*p_new_quantity/item.quantity,2),vat_amount=round(item.vat_amount*p_new_quantity/item.quantity,2),total_amount_ex_tax=round(item.total_amount_ex_tax*p_new_quantity/item.quantity,2),billing_cancelled_quantity=billing_cancelled_quantity+delta,cancelled_consumed_quantity=cancelled_consumed_quantity+consumed,
  combo_components=public.cashier_resize_combo(item.combo_components,item.quantity,p_new_quantity)
 WHERE id=item.id;
 PERFORM set_config('globos.cashier_item_mutation','off',true);
 -- An unchanged billing update runs the final progress reconciliation without re-enqueueing food.
 PERFORM set_config('globos.cashier_item_mutation','on',true);
 -- Invoke reconciliation explicitly through a dedicated repair trigger mode.
 PERFORM set_config('globos.cashier_item_mutation','repair',true);
 UPDATE public.order_items SET billing_cancelled_quantity=billing_cancelled_quantity WHERE id=item.id;
 PERFORM set_config('globos.cashier_item_mutation','off',true);
 PERFORM public.void_active_order_discount_for_item_change(item.order_id,p_store_id,'order_items_changed');
 PERFORM public.recalc_order_status(item.order_id);
 PERFORM public.cashier_invalidate_changed_display(p_store_id,ARRAY[item.order_id]);
 after_state:=public.cashier_item_progress(item.id);response:=jsonb_build_object('order_id',item.order_id,'item_id',item.id,'quantity',p_new_quantity,'operation_id',p_operation_id,'cancelled_amount',amount);
 INSERT INTO public.cashier_item_operations(id,restaurant_id,order_id,kind,payload,response,before_progress,after_progress,ledger_id,created_by) VALUES(p_operation_id,p_store_id,item.order_id,'partial_cancel',payload,response,before_state,after_state,ledger,auth.uid());
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES(auth.uid(),'cashier_partial_cancel','order_items',item.id,response||jsonb_build_object('reason',p_reason,'cancelled_quantity',delta,'consumed_quantity',consumed));
 RETURN response;
END;
$$;
CREATE FUNCTION public.cashier_restore_item_quantity(p_store_id uuid,p_operation_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
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
 UPDATE public.order_items SET quantity=(operation.payload->>'expected_quantity')::integer,billing_cancelled_quantity=billing_cancelled_quantity-((operation.payload->>'expected_quantity')::integer-item.quantity),
  cancelled_consumed_quantity=(SELECT (item_snapshot->0->>'cancelled_consumed_quantity')::integer FROM public.order_cancellation_ledger WHERE id=operation.ledger_id),
  paying_amount_inc_tax=(SELECT (item_snapshot->0->>'before_paying_amount_inc_tax')::numeric FROM public.order_cancellation_ledger WHERE id=operation.ledger_id),vat_amount=(SELECT (item_snapshot->0->>'vat_amount')::numeric FROM public.order_cancellation_ledger WHERE id=operation.ledger_id),total_amount_ex_tax=(SELECT (item_snapshot->0->>'total_amount_ex_tax')::numeric FROM public.order_cancellation_ledger WHERE id=operation.ledger_id),combo_components=(SELECT item_snapshot->0->'combo_components' FROM public.order_cancellation_ledger WHERE id=operation.ledger_id) WHERE id=item.id;
 FOREACH kind IN ARRAY ARRAY['base','combo','direct','floor_lots','tray_lots'] LOOP
  table_name:=CASE kind WHEN 'base' THEN 'emergency_fulfillment_items' WHEN 'combo' THEN 'emergency_combo_component_items' WHEN 'direct' THEN 'emergency_floor_direct_items' WHEN 'floor_lots' THEN 'emergency_floor_ready_lots' ELSE 'emergency_tray_ready_lots' END;
  SELECT string_agg(format('%I=x.%I',a.attname,a.attname),',') INTO assignments FROM pg_attribute a WHERE a.attrelid=('public.'||table_name)::regclass AND a.attnum>0 AND NOT a.attisdropped AND a.attname<>'id';
  FOR row IN SELECT value FROM jsonb_array_elements(operation.before_progress->kind) LOOP
   EXECUTE format('UPDATE public.%I t SET %s FROM jsonb_populate_record(NULL::public.%I,$1) x WHERE t.id=x.id',table_name,assignments,table_name) USING row;
  END LOOP;
 END LOOP;
 PERFORM set_config('globos.cashier_item_mutation','off',true);
 INSERT INTO public.order_cancellation_reversals(cancellation_ledger_id,restaurant_id,order_id,order_item_id,restored_by) VALUES(operation.ledger_id,p_store_id,operation.order_id,item.id,auth.uid());
 PERFORM public.void_active_order_discount_for_item_change(item.order_id,p_store_id,'order_items_changed'); PERFORM public.recalc_order_status(item.order_id);
 PERFORM public.cashier_invalidate_changed_display(p_store_id,ARRAY[item.order_id]);
 RETURN operation.response||jsonb_build_object('restored',true);
END;
$$;
CREATE FUNCTION public.cashier_move_order_items(p_store_id uuid,p_source_order_id uuid,p_target_table_id uuid,p_items jsonb,p_operation_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE old public.cashier_item_operations%ROWTYPE; source public.orders%ROWTYPE; target public.orders%ROWTYPE; target_table public.tables%ROWTYPE;
 item public.order_items%ROWTYPE; selection record; payload jsonb; response jsonb; new_item uuid; move_count integer; table_name text; line record; target_queue uuid; queue public.emergency_order_queue%ROWTYPE; copied jsonb; original jsonb; progress_id uuid; assignments text; ratio integer; units integer; key text; lot_table text; lot record; capacity integer; take integer; lot_copy jsonb; moved_ids jsonb:='[]'::jsonb;
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
  IF target.order_purpose<>source.order_purpose OR target.fulfillment_mode_snapshot<>source.fulfillment_mode_snapshot OR target.sales_channel<>source.sales_channel THEN RAISE EXCEPTION 'CASHIER_TARGET_INCOMPATIBLE'; END IF;
 ELSE
  INSERT INTO public.orders(restaurant_id,table_id,sales_channel,status,guest_count,created_by,notes,order_source,order_purpose,fulfillment_mode_snapshot)
  VALUES(p_store_id,p_target_table_id,source.sales_channel,'confirmed',source.guest_count,auth.uid(),source.notes,source.order_source,source.order_purpose,source.fulfillment_mode_snapshot) RETURNING * INTO target;
 END IF;
 PERFORM 1 FROM public.order_items i JOIN jsonb_to_recordset(p_items) x(item_id uuid) ON x.item_id=i.id WHERE i.order_id=source.id ORDER BY i.id FOR UPDATE OF i;
 PERFORM 1 FROM public.emergency_fulfillment_items WHERE order_id IN (source.id,target.id) ORDER BY id FOR UPDATE;
 PERFORM 1 FROM public.emergency_combo_component_items WHERE order_id IN (source.id,target.id) ORDER BY id FOR UPDATE;
 PERFORM 1 FROM public.emergency_floor_direct_items WHERE order_id IN (source.id,target.id) ORDER BY id FOR UPDATE;
 PERFORM set_config('globos.cashier_item_mutation','on',true);
 FOR selection IN SELECT * FROM jsonb_to_recordset(p_items) x(item_id uuid,quantity integer,expected_quantity integer) ORDER BY item_id LOOP
  SELECT * INTO item FROM public.order_items WHERE id=selection.item_id AND order_id=source.id AND restaurant_id=p_store_id;
  IF NOT FOUND OR item.quantity<>selection.expected_quantity OR item.item_type<>'menu_item' OR item.status='cancelled' OR selection.quantity>item.quantity THEN RAISE EXCEPTION 'CASHIER_ITEM_CHANGED'; END IF;
  move_count:=selection.quantity; new_item:=item.id;
  IF move_count<item.quantity THEN
   -- A partially cancelled line retains its history intact; move that entire line.
   IF item.billing_cancelled_quantity>0 THEN RAISE EXCEPTION 'CASHIER_MOVE_CANCELLED_SPLIT'; END IF;
   new_item:=gen_random_uuid();
   copied:=to_jsonb(item)||jsonb_build_object('id',new_item,'order_id',target.id,'quantity',move_count,'paying_amount_inc_tax',round(item.paying_amount_inc_tax*move_count/item.quantity,2),'vat_amount',round(item.vat_amount*move_count/item.quantity,2),'total_amount_ex_tax',round(item.total_amount_ex_tax*move_count/item.quantity,2),'combo_components',COALESCE((SELECT jsonb_agg(CASE WHEN COALESCE((c->>'is_total_quantity')::boolean,false) THEN jsonb_set(c,'{quantity}',to_jsonb((c->>'quantity')::integer*move_count/item.quantity)) ELSE c END) FROM jsonb_array_elements(COALESCE(item.combo_components,'[]'::jsonb)) c),'[]'::jsonb));
   INSERT INTO public.order_items SELECT (jsonb_populate_record(NULL::public.order_items,copied)).*;
   UPDATE public.order_items SET quantity=quantity-move_count,paying_amount_inc_tax=item.paying_amount_inc_tax-(copied->>'paying_amount_inc_tax')::numeric,vat_amount=item.vat_amount-(copied->>'vat_amount')::numeric,total_amount_ex_tax=item.total_amount_ex_tax-(copied->>'total_amount_ex_tax')::numeric,combo_components=COALESCE((SELECT jsonb_agg(CASE WHEN COALESCE((c->>'is_total_quantity')::boolean,false) THEN jsonb_set(c,'{quantity}',to_jsonb((c->>'quantity')::integer*(item.quantity-move_count)/item.quantity)) ELSE c END) FROM jsonb_array_elements(COALESCE(item.combo_components,'[]'::jsonb)) c),'[]'::jsonb) WHERE id=item.id;
  ELSE UPDATE public.order_items SET order_id=target.id WHERE id=item.id; END IF;
  FOREACH table_name IN ARRAY ARRAY['emergency_fulfillment_items','emergency_combo_component_items','emergency_floor_direct_items'] LOOP
   FOR line IN EXECUTE format('SELECT * FROM public.%I WHERE order_item_id=$1 ORDER BY id FOR UPDATE',table_name) USING item.id LOOP
    SELECT * INTO queue FROM public.emergency_order_queue WHERE id=line.queue_id;
    PERFORM 1 FROM public.emergency_fulfillment_sessions WHERE id=queue.session_id FOR UPDATE;
    SELECT id INTO target_queue FROM public.emergency_order_queue WHERE session_id=queue.session_id AND order_id=target.id;
    IF NOT FOUND THEN
     INSERT INTO public.emergency_order_queue(session_id,restaurant_id,order_id,queue_no,table_number,floor_label,workflow_version,created_at)
     VALUES(queue.session_id,p_store_id,target.id,COALESCE((SELECT max(queue_no)+1 FROM public.emergency_order_queue WHERE session_id=queue.session_id),1),target_table.table_number,public.emergency_floor_label(p_store_id,target_table.floor_label,target_table.table_number),queue.workflow_version,queue.created_at) RETURNING id INTO target_queue;
    END IF;
    IF move_count=item.quantity THEN
     EXECUTE format('UPDATE public.%I SET order_id=$2,queue_id=$3,updated_at=now() WHERE id=$1',table_name) USING line.id,target.id,target_queue;
     UPDATE public.emergency_floor_ready_lots SET order_id=target.id,queue_id=target_queue,updated_at=now() WHERE source_id=line.id;
     UPDATE public.emergency_tray_ready_lots SET order_id=target.id,queue_id=target_queue,updated_at=now() WHERE source_id=line.id;
    ELSE
     IF line.source_quantity%item.quantity<>0 OR line.source_quantity<=0 OR line.excused_quantity>0 OR line.is_cancelled OR line.needs_review THEN RAISE EXCEPTION 'CASHIER_COMBO_QUANTITY_CHANGED'; END IF;
     ratio:=line.source_quantity/item.quantity;units:=move_count*ratio; progress_id:=gen_random_uuid();original:=to_jsonb(line);copied:=original||jsonb_build_object('id',progress_id,'order_item_id',new_item,'order_id',target.id,'queue_id',target_queue,'source_quantity',units,'ordered_quantity',units);
     original:=original||jsonb_build_object('source_quantity',line.source_quantity-units,'ordered_quantity',line.ordered_quantity-units);
     FOREACH key IN ARRAY ARRAY['kitchen_started_quantity','kitchen_done_quantity','tray_received_quantity','tray_dispatched_quantity','floor_served_quantity','excused_quantity'] LOOP
      IF copied ? key THEN copied:=jsonb_set(copied,ARRAY[key],to_jsonb(least(units,(copied->>key)::integer))); original:=jsonb_set(original,ARRAY[key],to_jsonb((original->>key)::integer-(copied->>key)::integer)); END IF;
     END LOOP;
     SELECT string_agg(format('%I=x.%I',a.attname,a.attname),',') INTO assignments FROM pg_attribute a WHERE a.attrelid=('public.'||table_name)::regclass AND a.attnum>0 AND NOT a.attisdropped AND a.attname<>'id';
     EXECUTE format('UPDATE public.%I t SET %s FROM jsonb_populate_record(NULL::public.%I,$1) x WHERE t.id=x.id',table_name,assignments,table_name) USING original;
     EXECUTE format('INSERT INTO public.%I SELECT (jsonb_populate_record(NULL::public.%I,$1)).*',table_name,table_name) USING copied;
     FOREACH lot_table IN ARRAY ARRAY['emergency_floor_ready_lots','emergency_tray_ready_lots'] LOOP
      capacity:=CASE WHEN lot_table='emergency_floor_ready_lots' THEN COALESCE((copied->>'tray_dispatched_quantity')::integer,0) ELSE COALESCE((copied->>'kitchen_done_quantity')::integer,0) END;
      FOR lot IN EXECUTE format('SELECT * FROM public.%I WHERE source_id=$1 ORDER BY ready_sequence,id FOR UPDATE',lot_table) USING line.id LOOP
       EXIT WHEN capacity<=0; take:=least(capacity,lot.ready_quantity);
       lot_copy:=to_jsonb(lot)||jsonb_build_object('id',gen_random_uuid(),'order_id',target.id,'order_item_id',new_item,'queue_id',target_queue,'source_id',progress_id,'ready_quantity',take,'voided_quantity',0);
       key:=CASE WHEN lot_table='emergency_floor_ready_lots' THEN 'served_quantity' ELSE 'handed_quantity' END;
       lot_copy:=jsonb_set(lot_copy,ARRAY[key],to_jsonb(least(take,(to_jsonb(lot)->>key)::integer)));
       IF take=lot.ready_quantity THEN
        -- A whole lot can retain its identity and FIFO sequence.
        EXECUTE format('UPDATE public.%I SET order_id=$2,order_item_id=$3,queue_id=$4,source_id=$5 WHERE id=$1',lot_table) USING lot.id,target.id,new_item,target_queue,progress_id;
       ELSE
        EXECUTE format('UPDATE public.%I SET ready_quantity=ready_quantity-$2,%I=%I-$3 WHERE id=$1',lot_table,key,key) USING lot.id,take,(lot_copy->>key)::integer;
        EXECUTE format('INSERT INTO public.%I SELECT (jsonb_populate_record(NULL::public.%I,$1)).*',lot_table,lot_table) USING lot_copy;
       END IF;
       capacity:=capacity-take;
      END LOOP;
     END LOOP;
    END IF;
   END LOOP;
  END LOOP;
  moved_ids:=moved_ids||jsonb_build_array(jsonb_build_object('source_item_id',item.id,'target_item_id',new_item,'quantity',move_count));
 END LOOP;
 PERFORM set_config('globos.cashier_item_mutation','off',true);
 PERFORM public.void_active_order_discount_for_item_change(source.id,p_store_id,'order_items_changed'); PERFORM public.void_active_order_discount_for_item_change(target.id,p_store_id,'order_items_changed');
 PERFORM public.recalc_order_status(source.id); PERFORM public.recalc_order_status(target.id);
 IF NOT EXISTS(SELECT 1 FROM public.order_items WHERE order_id=source.id AND status<>'cancelled' AND item_type='menu_item') THEN UPDATE public.orders SET status='cancelled',updated_at=now() WHERE id=source.id; END IF;
 UPDATE public.tables SET status='occupied',updated_at=now() WHERE id=p_target_table_id;
 UPDATE public.tables SET status='available',updated_at=now() WHERE id=source.table_id AND NOT EXISTS(SELECT 1 FROM public.orders WHERE table_id=source.table_id AND status NOT IN ('completed','cancelled'));
 PERFORM public.cashier_invalidate_changed_display(p_store_id,ARRAY[source.id,target.id]);
 response:=jsonb_build_object('source_order_id',source.id,'target_order_id',target.id,'target_table_id',p_target_table_id,'moved',moved_ids,'operation_id',p_operation_id,'discount_review_required',true);
 INSERT INTO public.cashier_item_operations(id,restaurant_id,order_id,kind,payload,response,created_by) VALUES(p_operation_id,p_store_id,source.id,'move',payload,response,auth.uid());
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES(auth.uid(),'cashier_move_order_items','orders',source.id,response);
 RETURN response;
EXCEPTION WHEN lock_not_available THEN RAISE EXCEPTION 'CASHIER_ITEM_CHANGED';
END;
$$;
-- Keep the atomic payment path and every financial formula; consumed cancelled
-- food is deducted once when the remaining bill is finally settled.
DO $inventory_consumption$
DECLARE d text; suffix text; needle text:='oi.quantity AS ordered_qty';
BEGIN
 SELECT pg_get_functiondef(COALESCE(to_regprocedure('public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)'),to_regprocedure('public.process_payment(uuid,uuid,numeric,text)'))) INTO d;
 IF strpos(d,needle)=0 THEN RAISE EXCEPTION 'CASHIER_PAYMENT_INVENTORY_ANCHOR_DRIFT'; END IF;
 -- Only modify the inventory loop, leaving every financial query unchanged.
 suffix:=substr(d,strpos(d,needle));
 IF strpos(suffix,'AND oi.status <> ''cancelled''')=0 THEN RAISE EXCEPTION 'CASHIER_PAYMENT_INVENTORY_ANCHOR_DRIFT'; END IF;
 suffix:=replace(suffix,needle,'CASE WHEN oi.status=''cancelled'' THEN oi.cancelled_consumed_quantity ELSE oi.quantity+oi.cancelled_consumed_quantity END AS ordered_qty');
 suffix:=replace(suffix,'AND oi.status <> ''cancelled''','AND (oi.status <> ''cancelled'' OR oi.cancelled_consumed_quantity>0)');
 EXECUTE substr(d,1,strpos(d,needle)-1)||suffix;
END; $inventory_consumption$;
DO $permissions$
DECLARE signature regprocedure;
BEGIN
 FOREACH signature IN ARRAY ARRAY['public.cashier_invalidate_changed_display(uuid,uuid[])'::regprocedure,'public.cashier_require_item_actor(uuid)'::regprocedure,'public.cashier_assert_unpaid(uuid,uuid)'::regprocedure,'public.cashier_item_progress(uuid)'::regprocedure,'public.cashier_trim_ready_lots(uuid,integer,integer)'::regprocedure] LOOP EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',signature); END LOOP;
 FOREACH signature IN ARRAY ARRAY['public.cashier_cancel_item_quantity(uuid,uuid,integer,integer,uuid,text)'::regprocedure,'public.cashier_restore_item_quantity(uuid,uuid)'::regprocedure,'public.cashier_move_order_items(uuid,uuid,uuid,jsonb,uuid)'::regprocedure] LOOP EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon',signature); EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated,service_role',signature); END LOOP;
 IF has_function_privilege('anon','public.cashier_move_order_items(uuid,uuid,uuid,jsonb,uuid)','EXECUTE') THEN RAISE EXCEPTION 'CASHIER_OPERATION_PERMISSION_DRIFT'; END IF;
END; $permissions$;
COMMIT;
