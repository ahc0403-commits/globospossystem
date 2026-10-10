-- Customer fulfillment progress, independent utensils, and bounded batch reads.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';

ALTER TABLE public.direct_order_requests
  ADD COLUMN utensils_requested boolean NOT NULL DEFAULT true;
COMMENT ON COLUMN public.direct_order_requests.utensils_requested IS
  'Disposable utensils only. Food containers are always provided. Legacy orders default to one set per diner.';

-- Preserve submit/access idempotency: a replay must not change the saved choice.
DO $submit$
DECLARE d text; anchor text := 'SET diner_count = v_count';
BEGIN
  SELECT pg_get_functiondef('public.direct_order_public_submit_v3(uuid,text,uuid,jsonb)'::regprocedure) INTO d;
  IF strpos(d,anchor)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_PROGRESS_SUBMIT_DRIFT'; END IF;
  d := replace(d, 'v_count := (p_payload', E'IF p_payload ? ''utensils_requested'' AND jsonb_typeof(p_payload->''utensils_requested'') IS DISTINCT FROM ''boolean'' THEN\n RAISE EXCEPTION ''DIRECT_ORDER_UTENSILS_INVALID''; END IF;\n v_count := (p_payload');
  EXECUTE replace(d,anchor,anchor||', utensils_requested = COALESCE((p_payload->>''utensils_requested'')::boolean,true)');
END;
$submit$;

-- One set operation for any page size. No per-order progress/context RPCs.
CREATE FUNCTION public.direct_order_cooking_progress(p_request_ids uuid[])
RETURNS TABLE(request_id uuid,cooking_complete boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
  WITH scope AS MATERIALIZED (
    SELECT request_id,order_id FROM public.direct_order_financials WHERE request_id=ANY(p_request_ids)
  ), units AS (
    SELECT f.request_id, i.kitchen_done_quantity>=greatest(0,i.ordered_quantity-COALESCE(i.excused_quantity,0))
      AND NOT i.needs_review AS done
    FROM scope f JOIN public.emergency_fulfillment_items i ON i.order_id=f.order_id WHERE NOT i.is_cancelled
    UNION ALL
    SELECT f.request_id, i.kitchen_done_quantity>=greatest(0,i.ordered_quantity-COALESCE(i.excused_quantity,0))
      AND NOT i.needs_review
    FROM scope f JOIN public.emergency_combo_component_items i ON i.order_id=f.order_id WHERE NOT i.is_cancelled
  ) SELECT request_id,bool_and(done) FROM units GROUP BY request_id;
$$;
REVOKE ALL ON FUNCTION public.direct_order_cooking_progress(uuid[]) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_cooking_progress(uuid[]) TO service_role;

CREATE FUNCTION public.direct_order_public_orders_v4(p_session_id uuid,p_secret_hash text,p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE s public.direct_order_sessions%ROWTYPE;
BEGIN
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 50 THEN RAISE EXCEPTION 'DIRECT_ORDER_LIMIT_INVALID'; END IF;
  s:=public.direct_order_validate_session(p_session_id,p_secret_hash);
  RETURN (
    WITH page AS MATERIALIZED (
      SELECT r.id,r.reference_code,r.state,r.created_at,r.fulfillment_method,CASE WHEN r.fulfillment_method='pickup' THEN 'pickup' ELSE r.fulfillment_type END AS fulfillment_type,t.status,t.completed_at,d.request_id IS NOT NULL AS has_dispatch
      FROM public.direct_order_requests r LEFT JOIN public.direct_delivery_fulfillment_tickets t ON t.request_id=r.id
      LEFT JOIN public.direct_order_dispatches d ON d.request_id=r.id
      WHERE r.session_id=s.id AND r.restaurant_id=s.restaurant_id AND r.created_at>=s.created_at
      ORDER BY r.created_at DESC,r.id DESC LIMIT p_limit
    ), items AS (
      SELECT i.request_id,sum(i.quantity) item_count FROM page p
      JOIN public.direct_order_request_items i ON i.request_id=p.id GROUP BY i.request_id
    ), quotes AS (
      SELECT DISTINCT ON(q.request_id) q.request_id,q.id,q.version,q.final_total
      FROM page p JOIN public.direct_order_quotes q ON q.request_id=p.id
      WHERE q.status IN ('active','locked') ORDER BY q.request_id,q.version DESC,q.id DESC
    ), reviews AS (
      SELECT DISTINCT ON(r.request_id) r.request_id,r.id FROM page p
      JOIN public.direct_order_proof_review_requests r ON r.request_id=p.id
      WHERE r.status='requested' ORDER BY r.request_id,r.requested_at DESC,r.id DESC
    ), cooking AS MATERIALIZED (
      SELECT * FROM public.direct_order_cooking_progress(ARRAY(SELECT id FROM page))
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'request_id',p.id,'reference_code',p.reference_code,'state',p.state,'created_at',p.created_at,
      'item_count',COALESCE(i.item_count,0),'final_total',q.final_total,'fulfillment_status',p.status,
      'completed_at',p.completed_at,'has_open_proof_review',v.id IS NOT NULL,
      'quote_id',q.id,'quote_version',q.version,'proof_review_id',v.id,
      'fulfillment_type',p.fulfillment_type,'fulfillment_method',p.fulfillment_method,'has_dispatch',p.has_dispatch,'cooking_complete',COALESCE(c.cooking_complete,false)
    ) ORDER BY p.created_at DESC,p.id DESC),'[]'::jsonb)
    FROM page p LEFT JOIN items i ON i.request_id=p.id LEFT JOIN quotes q ON q.request_id=p.id
    LEFT JOIN reviews v ON v.request_id=p.id LEFT JOIN cooking c ON c.request_id=p.id
  );
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_public_orders_v4(uuid,text,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_orders_v4(uuid,text,integer) TO service_role;

-- Older clients have strict DTOs. Keep their response keys exactly unchanged.
CREATE FUNCTION public.direct_order_public_status_v8(p_session_id uuid,p_secret_hash text,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE b jsonb; u boolean; c boolean;
BEGIN
  -- Existing authorization, translation, money and proof identities remain canonical.
  b:=public.direct_order_public_status_v7(p_session_id,p_secret_hash,p_request_id);
  SELECT utensils_requested INTO u FROM public.direct_order_requests WHERE id=p_request_id;
  SELECT cooking_complete INTO c FROM public.direct_order_cooking_progress(ARRAY[p_request_id]);
  RETURN b || jsonb_build_object('delivery',COALESCE(b->'delivery','{}'::jsonb)||
    jsonb_build_object('utensils_requested',u,'cooking_complete',COALESCE(c,false)),
    'support',COALESCE(b->'support','{}'::jsonb)||jsonb_build_object('access_open',public.direct_order_access_is_open(p_request_id)));
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_public_status_v8(uuid,text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_status_v8(uuid,text,uuid) TO service_role;

-- Add the flag to existing authorized joins / immutable new print snapshots.
DO $packing$
DECLARE d text; sig text;
BEGIN
  FOREACH sig IN ARRAY ARRAY['public.direct_order_receipt_packing_context(uuid,uuid)',
    'public.direct_order_enrich_digital_receipt_packing()'] LOOP
    SELECT pg_get_functiondef(sig::regprocedure) INTO d;
    IF strpos(d,'''diner_count'',r.diner_count')=0 AND strpos(d,'''diner_count'', r.diner_count')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_PACKING_DRIFT'; END IF;
    d:=replace(d,'''diner_count'',r.diner_count','''utensils_requested'',r.utensils_requested,''diner_count'',r.diner_count');
    EXECUTE replace(d,'''diner_count'', r.diner_count','''utensils_requested'', r.utensils_requested,''diner_count'', r.diner_count');
  END LOOP;
  SELECT pg_get_functiondef('public.direct_order_enrich_print_fulfillment()'::regprocedure) INTO d;
  IF strpos(d,'r.reference_code')=0 OR strpos(d,'v_reference text;')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_PRINT_DRIFT'; END IF;
  d:=replace(d,'v_reference text;','v_reference text; v_utensils boolean;');
  d:=replace(d,'r.reference_code','r.reference_code, r.utensils_requested');
  d:=replace(d,'INTO v_context, v_reference','INTO v_context, v_reference, v_utensils');
  EXECUTE replace(d,'''diner_count'',v_context','''utensils_requested'',v_utensils,''diner_count'',v_context');
  SELECT pg_get_functiondef('public.direct_delivery_tickets_before_translation(uuid,text[],integer)'::regprocedure) INTO d;
  IF strpos(d,'''diner_count'', request_row.diner_count')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_KITCHEN_DRIFT'; END IF;
  EXECUTE replace(d,'''diner_count'', request_row.diner_count','''utensils_requested'', request_row.utensils_requested, ''diner_count'', request_row.diner_count');
END;
$packing$;

-- Staff single detail uses the same persisted choice. No additional screen RPC.
ALTER FUNCTION public.direct_order_staff_detail_v3(uuid,uuid) RENAME TO direct_order_staff_detail_before_progress;
REVOKE ALL ON FUNCTION public.direct_order_staff_detail_before_progress(uuid,uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_staff_detail_v3(p_store_id uuid,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE b jsonb; u boolean;
BEGIN
 b:=public.direct_order_staff_detail_before_progress(p_store_id,p_request_id);
 SELECT utensils_requested INTO u FROM public.direct_order_requests WHERE id=p_request_id AND restaurant_id=p_store_id;
 RETURN b||jsonb_build_object('delivery',(b->'delivery')||jsonb_build_object('utensils_requested',u));
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_staff_detail_v3(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_detail_v3(uuid,uuid) TO authenticated,service_role;

-- Existing KDS and packing actions emit durable, deduplicated customer notices.
ALTER TABLE public.direct_order_customer_events DROP CONSTRAINT direct_order_customer_events_event_kind_check;
ALTER TABLE public.direct_order_customer_events ADD CONSTRAINT direct_order_customer_events_event_kind_check
 CHECK(event_kind IN ('pickup_ready','driver_handoff','payment_request','cooking_complete','packing_complete'));
CREATE FUNCTION public.direct_order_progress_notice_batch(p_ids uuid[],p_kind text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF p_ids IS NULL OR cardinality(p_ids)=0 THEN RETURN; END IF;
 IF p_kind='cooking_complete' THEN
  SELECT array_agg(request_id) INTO p_ids FROM public.direct_order_cooking_progress(p_ids) WHERE cooking_complete;
 ELSIF p_kind<>'packing_complete' THEN RETURN;
 END IF;
 -- For approved, active fulfillment this is the canonical access predicate's
 -- open branch; no per-order financial/access aggregate is needed here.
 WITH emitted AS (
  INSERT INTO public.direct_order_customer_events(request_id,session_id,restaurant_id,event_kind)
  SELECT r.id,r.session_id,r.restaurant_id,p_kind FROM public.direct_order_requests r
  LEFT JOIN public.direct_delivery_fulfillment_tickets t ON t.request_id=r.id
  WHERE r.id=ANY(p_ids) AND r.state='approved' AND r.support_closed_at IS NULL AND r.pii_purged_at IS NULL
   AND (t.status IS NULL OR t.status NOT IN ('completed','cancelled'))
   AND (p_kind<>'cooking_complete' OR t.status IS NULL OR t.status IN ('pending','preparing'))
   AND (p_kind<>'packing_complete' OR r.fulfillment_method<>'pickup')
  ON CONFLICT DO NOTHING RETURNING id,request_id,session_id,restaurant_id
 ), messages AS (
  INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body)
  SELECT request_id,restaurant_id,'system','system',CASE p_kind WHEN 'cooking_complete' THEN 'DIRECT_ORDER_COOKING_COMPLETE' ELSE 'DIRECT_ORDER_PACKING_COMPLETE' END FROM emitted
 )
 INSERT INTO public.direct_order_push_deliveries(event_id,session_id,device_id)
 SELECT e.id,d.session_id,d.device_id FROM emitted e
 JOIN public.direct_order_push_devices d ON d.session_id=e.session_id
 JOIN public.direct_order_sessions s ON s.id=d.session_id
 WHERE d.enabled AND s.expires_at>now() AND s.revoked_at IS NULL;
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_progress_notice_batch(uuid[],text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_progress_notice() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE ids uuid[]; kind text;
BEGIN
 IF TG_TABLE_NAME='direct_delivery_fulfillment_tickets' THEN
  SELECT array_agg(n.request_id) INTO ids FROM new_progress_rows n JOIN old_progress_rows o USING(request_id)
  WHERE n.status='ready' AND o.status IS DISTINCT FROM n.status;
  kind:='packing_complete';
 ELSE
  IF current_setting('globos.direct_order_progress_batch',true)='on' THEN RETURN NULL; END IF;
  SELECT array_agg(DISTINCT f.request_id) INTO ids FROM new_progress_rows e
  JOIN public.direct_order_financials f ON f.order_id=e.order_id WHERE e.stage='kitchen_done' AND e.delta>0;
  kind:='cooking_complete';
 END IF;
 PERFORM public.direct_order_progress_notice_batch(ids,kind);
 RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_progress_notice() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER direct_order_cooking_complete_notice AFTER INSERT ON public.emergency_fulfillment_events
 REFERENCING NEW TABLE AS new_progress_rows FOR EACH STATEMENT EXECUTE FUNCTION public.direct_order_progress_notice();
CREATE TRIGGER direct_order_packing_complete_notice AFTER UPDATE ON public.direct_delivery_fulfillment_tickets
 REFERENCING OLD TABLE AS old_progress_rows NEW TABLE AS new_progress_rows FOR EACH STATEMENT EXECUTE FUNCTION public.direct_order_progress_notice();

-- The existing atomic kitchen batch inserts individual quantity events. Defer
-- its customer aggregate until all mutations succeed, then emit in one set.
ALTER FUNCTION public.kds_complete_kitchen_batch_v1(uuid,jsonb) RENAME TO kds_complete_kitchen_batch_before_customer_progress;
REVOKE ALL ON FUNCTION public.kds_complete_kitchen_batch_before_customer_progress(uuid,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.kds_complete_kitchen_batch_v1(p_request_id uuid,p_allocations jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb; previous_setting text; ids uuid[];
BEGIN
 previous_setting:=current_setting('globos.direct_order_progress_batch',true);
 PERFORM set_config('globos.direct_order_progress_batch','on',true);
 result:=public.kds_complete_kitchen_batch_before_customer_progress(p_request_id,p_allocations);
 PERFORM set_config('globos.direct_order_progress_batch',COALESCE(previous_setting,''),true);
 WITH allocations AS MATERIALIZED (
  SELECT (value->>'item_id')::uuid id,value->>'source_kind' kind FROM jsonb_array_elements(p_allocations)
 ), orders AS (
  SELECT i.order_id FROM allocations a JOIN public.emergency_fulfillment_items i ON i.id=a.id WHERE a.kind='base'
  UNION
  SELECT i.order_id FROM allocations a JOIN public.emergency_combo_component_items i ON i.id=a.id WHERE a.kind='combo_component'
 ) SELECT array_agg(DISTINCT f.request_id) INTO ids FROM orders o JOIN public.direct_order_financials f ON f.order_id=o.order_id;
 PERFORM public.direct_order_progress_notice_batch(ids,'cooking_complete');
 RETURN result;
EXCEPTION WHEN OTHERS THEN
 PERFORM set_config('globos.direct_order_progress_batch',COALESCE(previous_setting,''),true);
 RAISE;
END;
$$;
REVOKE ALL ON FUNCTION public.kds_complete_kitchen_batch_v1(uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.kds_complete_kitchen_batch_v1(uuid,jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.direct_order_staff_list_before_reconciliation(
  p_store_id uuid, p_states text[] DEFAULT NULL, p_limit integer DEFAULT 100, p_fulfillment_type text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public,auth,pg_catalog AS $$
DECLARE v_day_start timestamptz;
BEGIN
  PERFORM public.direct_order_require_actor(p_store_id,
    ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_LIMIT_INVALID';
  END IF;
  IF p_fulfillment_type IS NOT NULL AND p_fulfillment_type NOT IN ('delivery','pickup') THEN RAISE EXCEPTION 'DIRECT_ORDER_FULFILLMENT_INVALID'; END IF;
  v_day_start := (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp
    AT TIME ZONE 'Asia/Ho_Chi_Minh';
  RETURN (
    WITH receipt_excess AS MATERIALIZED (
 SELECT x.request_id,sum(x.actual_amount-x.amount) amount FROM public.direct_order_payment_receipts x
 JOIN public.direct_order_requests r ON r.id=x.request_id WHERE r.restaurant_id=p_store_id GROUP BY x.request_id HAVING sum(x.actual_amount-x.amount)>0
 ), refunded_excess AS MATERIALIZED (
 SELECT request_id,sum(overpayment_amount) amount FROM public.direct_order_refund_records WHERE restaurant_id=p_store_id GROUP BY request_id
 ), refund_requests AS MATERIALIZED (
      SELECT DISTINCT o.request_id FROM public.direct_order_pickup_offers o
      JOIN public.direct_order_financials f ON f.request_id=o.request_id
      WHERE f.restaurant_id=p_store_id AND o.status='accepted'
        AND o.adjustment_id IS NULL AND f.delivery_fee_total>0
    ), page AS MATERIALIZED (
      SELECT r.id,r.restaurant_id,r.reference_code,r.state,r.created_at,
        CASE WHEN r.fulfillment_method='pickup' THEN 'pickup' ELSE r.fulfillment_type END AS fulfillment_type, t.status AS fulfillment_status,t.version AS fulfillment_version,t.completed_at,
        public.direct_order_display_stage(r.state,t.status) AS display_stage,
        refund.request_id IS NOT NULL AS refund_pending
      FROM public.direct_order_requests r
      LEFT JOIN public.direct_delivery_fulfillment_tickets t ON t.request_id=r.id LEFT JOIN receipt_excess rc ON rc.request_id=r.id LEFT JOIN refunded_excess rf ON rf.request_id=r.id
      LEFT JOIN refund_requests refund ON refund.request_id=r.id
      WHERE r.restaurant_id=p_store_id
        AND (p_states IS NULL OR r.state=ANY(p_states) OR t.status=ANY(p_states)
          OR public.direct_order_display_stage(r.state,t.status)=ANY(p_states))
        AND (p_fulfillment_type IS NULL OR CASE WHEN r.fulfillment_method='pickup' THEN 'pickup' ELSE r.fulfillment_type END=p_fulfillment_type)
        AND ((r.state IN ('cancelled','rejected','expired') AND r.support_closed_at IS NULL)
          OR r.created_at>=v_day_start AND r.created_at<v_day_start+interval '1 day'
          OR r.state IN ('awaiting_quote','quoted','awaiting_payment_review')
          OR r.state='approved' AND (t.id IS NULL OR t.status NOT IN ('completed','cancelled')) OR COALESCE(rc.amount,0)>COALESCE(rf.amount,0)
          OR refund.request_id IS NOT NULL)
      ORDER BY r.created_at DESC,r.id DESC LIMIT p_limit
    ), item_totals AS (
      SELECT i.request_id,sum(i.quantity) AS item_count FROM page p
      JOIN public.direct_order_request_items i ON i.request_id=p.id GROUP BY i.request_id
    ), messages AS (
      SELECT m.request_id,max(m.created_at) AS last_message_at,
        bool_or(m.message_type='payment_proof') AS has_payment_proof
      FROM page p JOIN public.direct_order_messages m ON m.request_id=p.id GROUP BY m.request_id
    ), reviews AS (
      SELECT r.request_id,bool_or(r.status='requested') AS has_open_proof_review
      FROM page p JOIN public.direct_order_proof_review_requests r ON r.request_id=p.id GROUP BY r.request_id
    )
    , quotes AS (
      SELECT DISTINCT ON(q.request_id) q.request_id,q.final_total FROM page p
      JOIN public.direct_order_quotes q ON q.request_id=p.id WHERE q.status IN ('active','locked')
      ORDER BY q.request_id,q.version DESC,q.id DESC
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'fulfillment_type',p.fulfillment_type,'id',p.id,'reference_code',p.reference_code,'state',p.state,'created_at',p.created_at,
      'customer_name',a.customer_name,'formatted_address',a.formatted_address,'district',a.district,
      'item_count',COALESCE(i.item_count,0),'final_total',q.final_total,
      'has_payment_proof',COALESCE(m.has_payment_proof,false),
      'has_open_proof_review',COALESCE(v.has_open_proof_review,false),
      'fulfillment_status',p.fulfillment_status,'fulfillment_version',p.fulfillment_version,
      'completed_at',p.completed_at,'last_message_at',m.last_message_at,
      'display_stage',p.display_stage,'refund_pending',p.refund_pending
    ) ORDER BY p.created_at DESC,p.id DESC),'[]'::jsonb)
    FROM page p
    LEFT JOIN public.direct_order_request_addresses a ON a.request_id=p.id
    LEFT JOIN quotes q ON q.request_id=p.id
    LEFT JOIN item_totals i ON i.request_id=p.id
    LEFT JOIN messages m ON m.request_id=p.id
    LEFT JOIN reviews v ON v.request_id=p.id
  );
END;
$$;

-- Enrich the entire KDS snapshot for kitchen/tray packing; no per-card access.
ALTER FUNCTION public.emergency_enrich_start_ready_orders(jsonb) RENAME TO emergency_enrich_start_ready_orders_before_packing;
REVOKE ALL ON FUNCTION public.emergency_enrich_start_ready_orders_before_packing(jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.emergency_enrich_start_ready_orders(p_orders jsonb)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH enriched AS MATERIALIZED (SELECT public.emergency_enrich_start_ready_orders_before_packing(p_orders) orders),
 page AS MATERIALIZED (
  SELECT e.value,e.ordinality FROM enriched CROSS JOIN LATERAL jsonb_array_elements(enriched.orders) WITH ORDINALITY e
 )
 SELECT COALESCE(jsonb_agg(p.value||CASE WHEN r.id IS NULL THEN '{}'::jsonb ELSE jsonb_build_object(
  'direct_order_packing',jsonb_build_object('diner_count',r.diner_count,'utensils_requested',r.utensils_requested,
   'reference_code',r.reference_code,'fulfillment_method',r.fulfillment_method)) END ORDER BY p.ordinality),'[]'::jsonb)
 FROM page p LEFT JOIN public.emergency_order_queue q ON q.id=NULLIF(p.value->>'queue_id','')::uuid
 LEFT JOIN public.direct_order_financials f ON f.order_id=q.order_id
 LEFT JOIN public.direct_order_requests r ON r.id=f.request_id AND r.restaurant_id=f.restaurant_id;
$$;
REVOKE ALL ON FUNCTION public.emergency_enrich_start_ready_orders(jsonb) FROM PUBLIC,anon,authenticated;

DO $verify$
BEGIN
 IF has_function_privilege('anon','public.direct_order_public_status_v8(uuid,text,uuid)','EXECUTE')
 OR has_function_privilege('authenticated','public.direct_order_public_orders_v4(uuid,text,integer)','EXECUTE')
 OR strpos(pg_get_functiondef('public.direct_order_public_orders_v4(uuid,text,integer)'::regprocedure),'LATERAL')>0
 OR strpos(pg_get_functiondef('public.direct_delivery_ticket_list_v3(uuid,text[],integer)'::regprocedure),'direct_order_fulfillment_context')>0
 THEN RAISE EXCEPTION 'DIRECT_ORDER_PROGRESS_VERIFICATION_FAILED'; END IF;
END;
$verify$;
COMMIT;
