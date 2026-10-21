-- POS exposes its immutable source and records evidence of Office reconciliation.
-- This creates no payment, supplier credit or invoice in either system.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.procurement_store_identity (
 purchase_order_id uuid PRIMARY KEY REFERENCES public.inventory_purchase_orders(id) ON DELETE CASCADE,
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,tax_entity_id uuid,brand_id uuid,
 store_code text,store_name text NOT NULL,office_store_id uuid,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.procurement_reconciliation_evidence (
 id uuid PRIMARY KEY,restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
 purchase_order_id uuid NOT NULL REFERENCES public.inventory_purchase_orders(id) ON DELETE CASCADE,
 source_hash text NOT NULL,source_order_version integer NOT NULL,payload jsonb NOT NULL,input_hash text NOT NULL,
 expected_gross numeric NOT NULL,expected_credit numeric NOT NULL,matched boolean NOT NULL,settled boolean NOT NULL,
 actor_id uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX procurement_reconciliation_evidence_order ON public.procurement_reconciliation_evidence(purchase_order_id,created_at DESC,id DESC);
ALTER TABLE public.procurement_store_identity ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.procurement_reconciliation_evidence ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.procurement_store_identity,public.procurement_reconciliation_evidence FROM PUBLIC,anon,authenticated;
CREATE TRIGGER procurement_store_identity_immutable BEFORE UPDATE ON public.procurement_store_identity FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE TRIGGER procurement_reconciliation_evidence_immutable BEFORE UPDATE ON public.procurement_reconciliation_evidence FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE FUNCTION public.procurement_capture_store_identity_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 INSERT INTO procurement_store_identity(purchase_order_id,restaurant_id,tax_entity_id,brand_id,store_code,store_name,office_store_id)
 SELECT n.id,r.id,r.tax_entity_id,r.brand_id,r.short_code,r.name,l.external_id FROM new_identity_purchase_orders n JOIN restaurants r ON r.id=n.restaurant_id LEFT JOIN store_external_links l ON l.restaurant_id=r.id AND l.provider='office';
 RETURN NULL;
END $$;
CREATE TRIGGER procurement_capture_store_identity AFTER INSERT ON public.inventory_purchase_orders REFERENCING NEW TABLE AS new_identity_purchase_orders FOR EACH STATEMENT EXECUTE FUNCTION public.procurement_capture_store_identity_v1();
CREATE FUNCTION public.get_procurement_reconciliation_source_v1(p_store uuid,p_orders uuid[]) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE data jsonb; result jsonb; actor jsonb;
BEGIN
 IF auth.role() IS DISTINCT FROM 'service_role' THEN
  actor:=procurement_actor(p_store);
  IF NOT coalesce((actor->>'can_view_prices')::boolean,false) THEN RAISE EXCEPTION 'PROCUREMENT_PRICE_FORBIDDEN'; END IF;
 END IF;
 IF p_orders IS NULL OR cardinality(p_orders) NOT BETWEEN 1 AND 50 OR array_position(p_orders,NULL) IS NOT NULL THEN RAISE EXCEPTION 'PROCUREMENT_SCOPE_FORBIDDEN'; END IF;
 IF (SELECT count(*) FROM inventory_receipt_lines l JOIN inventory_receipts r ON r.id=l.receipt_id WHERE r.purchase_order_id=ANY(p_orders))>10000 THEN RAISE EXCEPTION 'PROCUREMENT_RECONCILIATION_PAGE_LIMIT'; END IF;
 data:=procurement_snapshots_data(ARRAY[p_store],p_orders);
 WITH credit AS(SELECT t.purchase_order_id,sum(round(round(t.quantity_base/ol.order_unit_quantity_base_snapshot,3)*rl.actual_unit_price,2)+round(round(t.quantity_base/ol.order_unit_quantity_base_snapshot,3)*rl.actual_unit_price*ol.tax_rate_snapshot/100,2)) amount
 FROM inventory_supplier_returns t JOIN inventory_receipt_lines rl ON rl.id=t.receipt_line_id JOIN inventory_purchase_order_lines ol ON ol.id=rl.purchase_order_line_id WHERE t.purchase_order_id=ANY(p_orders) GROUP BY t.purchase_order_id),
 previous AS(SELECT DISTINCT ON(purchase_order_id) * FROM procurement_reconciliation_evidence WHERE purchase_order_id=ANY(p_orders) ORDER BY purchase_order_id,created_at DESC,id DESC)
 SELECT jsonb_agg(jsonb_build_object('purchase_order_id',x->'order'->'id','store_id',p_store,'identity',CASE WHEN identity.purchase_order_id IS NOT NULL THEN to_jsonb(identity)||'{"basis":"order_snapshot"}' ELSE jsonb_build_object('restaurant_id',r.id,'tax_entity_id',r.tax_entity_id,'brand_id',r.brand_id,'store_code',r.short_code,'store_name',r.name,'basis','current_registry') END,
 'source_order_version',x->'order'->'row_version','source_hash',md5(jsonb_build_array(x,coalesce(to_jsonb(identity),jsonb_build_object('store',r.id,'entity',r.tax_entity_id,'brand',r.brand_id,'code',r.short_code,'name',r.name)))::text),'currency','VND',
 'expected_gross',coalesce((SELECT sum((receipt->>'total_amount')::numeric) FROM jsonb_array_elements(x->'receipts')receipt),0),
 'expected_credit',coalesce(c.amount,0),'source',x,'last_evidence',to_jsonb(previous)) ORDER BY x->'order'->>'id') INTO result
 FROM jsonb_array_elements(data)x JOIN restaurants r ON r.id=p_store LEFT JOIN procurement_store_identity identity ON identity.purchase_order_id=(x->'order'->>'id')::uuid LEFT JOIN credit c ON c.purchase_order_id=(x->'order'->>'id')::uuid LEFT JOIN previous ON previous.purchase_order_id=(x->'order'->>'id')::uuid;
 IF octet_length(result::text)>8388608 THEN RAISE EXCEPTION 'PROCUREMENT_RECONCILIATION_PAGE_LIMIT'; END IF;
 RETURN coalesce(result,'[]');
END $$;
CREATE FUNCTION public.admin_record_procurement_reconciliation_v1(p_id uuid,p_store uuid,p_order uuid,p_source_hash text,p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE prior procurement_reconciliation_evidence; source jsonb; input_hash text; matched boolean; settled boolean; gross numeric; credit numeric; net numeric;
BEGIN
 PERFORM require_brand_admin_v1();
 IF p_id IS NULL OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR octet_length(p_payload::text)>65536
 OR p_payload->>'currency' IS DISTINCT FROM 'VND' OR jsonb_typeof(p_payload->'invoice_ids') IS DISTINCT FROM 'array' OR jsonb_array_length(p_payload->'invoice_ids')>100
 OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_payload->'invoice_ids') x WHERE jsonb_typeof(x) IS DISTINCT FROM 'string' OR length(btrim(x#>>'{}')) NOT BETWEEN 1 AND 200)
 OR (SELECT count(*)<>count(DISTINCT x) FROM jsonb_array_elements(p_payload->'invoice_ids')x)
 OR length(btrim(coalesce(p_payload->>'office_reference',''))) NOT BETWEEN 5 AND 1000
 OR EXISTS(SELECT 1 FROM unnest(ARRAY['invoice_amount','credit_amount','paid_amount'])key WHERE jsonb_typeof(p_payload->key) IS DISTINCT FROM 'number' OR (p_payload->>key)::numeric<0 OR (p_payload->>key)::numeric<>round((p_payload->>key)::numeric,2))
 THEN RAISE EXCEPTION 'PROCUREMENT_ACCOUNTING_EVIDENCE_INVALID'; END IF;
 input_hash:=md5(jsonb_build_object('store',p_store,'order',p_order,'source',p_source_hash,'payload',p_payload,'actor',auth.uid())::text);
 PERFORM pg_advisory_xact_lock(hashtextextended('procurement-reconciliation:'||p_id,0));
 SELECT * INTO prior FROM procurement_reconciliation_evidence WHERE id=p_id;
 IF FOUND THEN IF prior.input_hash<>input_hash THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF; RETURN to_jsonb(prior); END IF;
 PERFORM 1 FROM inventory_purchase_orders WHERE id=p_order AND restaurant_id=p_store FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_SCOPE_FORBIDDEN'; END IF;
 source:=get_procurement_reconciliation_source_v1(p_store,ARRAY[p_order])->0;
 IF p_source_hash IS DISTINCT FROM source->>'source_hash' THEN RAISE EXCEPTION 'PROCUREMENT_ACCOUNTING_SOURCE_CHANGED'; END IF;
 gross:=(source->>'expected_gross')::numeric; credit:=(source->>'expected_credit')::numeric; net:=gross-credit;
 matched:=(p_payload->>'invoice_amount')::numeric=gross AND (p_payload->>'credit_amount')::numeric=credit AND net>=0 AND (p_payload->>'paid_amount')::numeric<=net AND (gross=0 OR jsonb_array_length(p_payload->'invoice_ids')>0);
 settled:=matched AND (p_payload->>'paid_amount')::numeric=net;
 INSERT INTO procurement_reconciliation_evidence VALUES(p_id,p_store,p_order,p_source_hash,(source->>'source_order_version')::integer,p_payload,input_hash,gross,credit,matched,settled,auth.uid(),clock_timestamp()) RETURNING * INTO prior;
 -- Compatibility projection describes the recorded external evidence. It is
 -- never used to create a new payment or to mark a supplier transmission sent.
 INSERT INTO procurement_accounting_status(purchase_order_id,restaurant_id,source_order_version,invoice_count,payable_count,held_count,paid_count,reconciliation_required,observed_at)
 VALUES(p_order,p_store,(source->>'source_order_version')::integer,jsonb_array_length(p_payload->'invoice_ids'),CASE WHEN net>0 THEN 1 ELSE 0 END,CASE WHEN matched THEN 0 ELSE 1 END,CASE WHEN settled AND net>0 THEN 1 ELSE 0 END,NOT matched,clock_timestamp())
 ON CONFLICT(purchase_order_id) DO UPDATE SET source_order_version=EXCLUDED.source_order_version,invoice_count=EXCLUDED.invoice_count,payable_count=EXCLUDED.payable_count,held_count=EXCLUDED.held_count,paid_count=EXCLUDED.paid_count,reconciliation_required=EXCLUDED.reconciliation_required,observed_at=EXCLUDED.observed_at;
 RETURN to_jsonb(prior);
END $$;
REVOKE ALL ON FUNCTION public.procurement_capture_store_identity_v1() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.get_procurement_reconciliation_source_v1(uuid,uuid[]),public.admin_record_procurement_reconciliation_v1(uuid,uuid,uuid,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_procurement_reconciliation_source_v1(uuid,uuid[]) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.admin_record_procurement_reconciliation_v1(uuid,uuid,uuid,text,jsonb) TO authenticated;
COMMIT;
