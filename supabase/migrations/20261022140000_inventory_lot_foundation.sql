-- Opt-in lot balances attach to the existing signed inventory transaction.
-- A deferred, once-per-transaction set reconciliation also catches writes that
-- forget the journal. Legacy untracked ingredients retain their original path.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.inventory_locations (
 id uuid PRIMARY KEY,restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
 name text NOT NULL CHECK(length(btrim(name)) BETWEEN 1 AND 80),kind text NOT NULL CHECK(kind IN('storage','quarantine','rejected')),
 is_active boolean NOT NULL DEFAULT true,revision bigint NOT NULL DEFAULT 1,created_by uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX inventory_locations_store ON public.inventory_locations(restaurant_id,id);
CREATE TABLE public.inventory_lot_counts (
 id uuid PRIMARY KEY,restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
 employee_id uuid NOT NULL,employee_snapshot jsonb NOT NULL,rows jsonb NOT NULL,reason text NOT NULL,
 input_hash text NOT NULL,created_by uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.inventory_lot_tracking (
 ingredient_id uuid PRIMARY KEY REFERENCES public.inventory_items(id) ON DELETE CASCADE,
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
 opening_count_id uuid NOT NULL REFERENCES public.inventory_lot_counts(id),started_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.inventory_lots (
 id uuid PRIMARY KEY,restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
 ingredient_id uuid NOT NULL REFERENCES public.inventory_items(id) ON DELETE CASCADE,
 location_id uuid NOT NULL REFERENCES public.inventory_locations(id),
 supplier_lot_code text,expiry_date date,quantity_base numeric(18,3) NOT NULL CHECK(quantity_base>=0 AND quantity_base::text NOT IN('NaN','Infinity','-Infinity')),
 state text NOT NULL CHECK(state IN('available','held','rejected','returned','waste')),
 source_kind text NOT NULL CHECK(source_kind IN('opening_count','count','receipt','hold_release','unknown_legacy','disposition')),
 source_id uuid NOT NULL,source_component integer NOT NULL,receipt_line_id uuid REFERENCES public.inventory_receipt_lines(id) ON DELETE CASCADE,
 parent_lot_id uuid REFERENCES public.inventory_lots(id) DEFERRABLE INITIALLY DEFERRED,
 created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(source_kind,source_id,source_component,state)
);
CREATE INDEX inventory_lots_available ON public.inventory_lots(ingredient_id,expiry_date,created_at,id) WHERE state='available' AND quantity_base>0;
CREATE INDEX inventory_lots_receipt ON public.inventory_lots(receipt_line_id,state) WHERE quantity_base>0;
CREATE INDEX inventory_lots_store ON public.inventory_lots(restaurant_id,id);
CREATE TABLE public.inventory_lot_movements (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),lot_id uuid NOT NULL REFERENCES public.inventory_lots(id) ON DELETE CASCADE,
 event_kind text NOT NULL,event_id uuid NOT NULL,quantity_base numeric(18,3) NOT NULL,
 inventory_transaction_id uuid REFERENCES public.inventory_transactions(id) ON DELETE CASCADE,
 created_by uuid,created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(event_kind,event_id,lot_id)
);
CREATE INDEX inventory_lot_movements_event ON public.inventory_lot_movements(inventory_transaction_id,lot_id);
CREATE TABLE public.inventory_lot_dispositions (
 id uuid PRIMARY KEY,restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
 lot_id uuid NOT NULL REFERENCES public.inventory_lots(id),action text NOT NULL CHECK(action IN('release','reject','return','waste','move')),
 quantity_base numeric(18,3) NOT NULL CHECK(quantity_base>0),payload_hash text NOT NULL,payload jsonb NOT NULL,
 actor_id uuid NOT NULL,result jsonb,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.inventory_lot_receipt_origins (
 receipt_id uuid PRIMARY KEY REFERENCES public.inventory_receipts(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
 disposition_id uuid NOT NULL REFERENCES public.inventory_lot_dispositions(id),
 parent_lot_id uuid NOT NULL REFERENCES public.inventory_lots(id),quantity_base numeric(18,3) NOT NULL CHECK(quantity_base>0)
);
CREATE TABLE public.inventory_lot_reconcile_queue (transaction_id bigint PRIMARY KEY,ingredient_ids uuid[] NOT NULL);
ALTER TABLE public.inventory_locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_lot_counts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_lot_tracking ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_lots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_lot_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_lot_dispositions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_lot_receipt_origins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_lot_reconcile_queue ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inventory_locations,public.inventory_lot_counts,public.inventory_lot_tracking,public.inventory_lots,public.inventory_lot_movements,public.inventory_lot_dispositions,public.inventory_lot_receipt_origins,public.inventory_lot_reconcile_queue FROM PUBLIC,anon,authenticated;
CREATE TRIGGER inventory_lot_counts_immutable BEFORE UPDATE ON public.inventory_lot_counts FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE TRIGGER inventory_lot_movements_immutable BEFORE UPDATE ON public.inventory_lot_movements FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();

CREATE FUNCTION public.inventory_queue_lot_reconciliation_v1(p_ids uuid[]) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF p_ids IS NULL OR cardinality(p_ids)=0 THEN RETURN; END IF;
 INSERT INTO inventory_lot_reconcile_queue VALUES(txid_current(),p_ids)
 ON CONFLICT(transaction_id) DO UPDATE SET ingredient_ids=ARRAY(SELECT DISTINCT id FROM unnest(inventory_lot_reconcile_queue.ingredient_ids||EXCLUDED.ingredient_ids)id);
END $$;
CREATE FUNCTION public.inventory_check_lot_reconciliation_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE ids uuid[];
BEGIN
 SELECT ingredient_ids INTO ids FROM inventory_lot_reconcile_queue WHERE transaction_id=NEW.transaction_id;
 IF ids IS NULL THEN RETURN NULL; END IF;
 IF EXISTS(WITH available AS(SELECT ingredient_id,sum(quantity_base) qty FROM inventory_lots WHERE ingredient_id=ANY(ids) AND state='available' GROUP BY ingredient_id)
 SELECT 1 FROM inventory_lot_tracking t JOIN inventory_items i ON i.id=t.ingredient_id LEFT JOIN available a ON a.ingredient_id=i.id WHERE i.id=ANY(ids) AND coalesce(i.current_stock,0)<>coalesce(a.qty,0)) THEN RAISE EXCEPTION 'INVENTORY_LOT_BALANCE_MISMATCH'; END IF;
 DELETE FROM inventory_lot_reconcile_queue WHERE transaction_id=NEW.transaction_id;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER inventory_lot_reconcile_at_commit AFTER INSERT ON public.inventory_lot_reconcile_queue DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.inventory_check_lot_reconciliation_v1();
CREATE FUNCTION public.inventory_queue_changed_lots_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE ids uuid[];
BEGIN
 SELECT array_agg(n.id) INTO ids FROM new_inventory_balances n JOIN old_inventory_balances p ON p.id=n.id JOIN inventory_lot_tracking t ON t.ingredient_id=n.id WHERE n.current_stock IS DISTINCT FROM p.current_stock;
 PERFORM inventory_queue_lot_reconciliation_v1(ids);
 RETURN NULL;
END $$;
CREATE TRIGGER inventory_queue_changed_lots AFTER UPDATE ON public.inventory_items REFERENCING OLD TABLE AS old_inventory_balances NEW TABLE AS new_inventory_balances FOR EACH STATEMENT EXECUTE FUNCTION public.inventory_queue_changed_lots_v1();

CREATE FUNCTION public.admin_save_inventory_location_v1(p_id uuid,p_store uuid,p_name text,p_kind text,p_active boolean,p_expected_revision bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE loc inventory_locations;
BEGIN
 PERFORM require_brand_admin_v1();
 IF p_id IS NULL OR p_active IS NULL OR p_expected_revision IS NULL OR p_expected_revision<0 THEN RAISE EXCEPTION 'INVENTORY_LOCATION_INVALID'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('inventory-location:'||p_id,0));
 SELECT * INTO loc FROM inventory_locations WHERE id=p_id FOR UPDATE;
 IF loc.restaurant_id IS NOT NULL AND loc.restaurant_id<>p_store THEN RAISE EXCEPTION 'PROCUREMENT_SCOPE_FORBIDDEN'; END IF;
 IF (loc.name,loc.kind,loc.is_active,loc.revision) IS NOT DISTINCT FROM (btrim(p_name),p_kind,p_active,p_expected_revision+1) THEN RETURN to_jsonb(loc); END IF;
 IF coalesce(loc.revision,0)<>p_expected_revision THEN RAISE EXCEPTION 'INVENTORY_LOCATION_STALE'; END IF;
 IF (NOT p_active OR loc.kind IS DISTINCT FROM p_kind) AND EXISTS(SELECT 1 FROM inventory_lots WHERE location_id=p_id AND state IN('available','held','rejected') AND quantity_base>0) THEN RAISE EXCEPTION 'INVENTORY_LOCATION_HAS_STOCK'; END IF;
 INSERT INTO inventory_locations(id,restaurant_id,name,kind,is_active,revision,created_by) VALUES(p_id,p_store,btrim(p_name),p_kind,p_active,p_expected_revision+1,auth.uid())
 ON CONFLICT(id) DO UPDATE SET name=EXCLUDED.name,kind=EXCLUDED.kind,is_active=EXCLUDED.is_active,revision=EXCLUDED.revision RETURNING * INTO loc;
 RETURN to_jsonb(loc);
END $$;

CREATE FUNCTION public.inventory_attach_lot_transactions_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE ids uuid[]; allocations jsonb; today date:=(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date;
BEGIN
 SELECT array_agg(DISTINCT n.ingredient_id) INTO ids FROM new_lot_transactions n JOIN inventory_lot_tracking t ON t.ingredient_id=n.ingredient_id AND t.restaurant_id=n.restaurant_id;
 IF ids IS NULL THEN RETURN NULL; END IF;
 IF (SELECT count(*) FROM new_lot_transactions)>10000 THEN RAISE EXCEPTION 'INVENTORY_LOT_TRANSACTION_LIMIT'; END IF;
 PERFORM 1 FROM inventory_lots WHERE ingredient_id=ANY(ids) AND state='available' AND quantity_base>0 ORDER BY ingredient_id,id FOR UPDATE;
 IF (SELECT count(*) FROM inventory_lots WHERE ingredient_id=ANY(ids) AND state='available' AND quantity_base>0)>20000 THEN RAISE EXCEPTION 'INVENTORY_LOT_ACTIVE_PAGE_LIMIT'; END IF;
 -- A positive balance must have a real inspected receipt or an explicit count.
 IF EXISTS(SELECT 1 FROM new_lot_transactions n WHERE n.ingredient_id=ANY(ids) AND n.quantity_g>0 AND
  NOT (n.reference_type='inventory_purchase_receipt' AND EXISTS(SELECT 1 FROM inventory_receipts r WHERE r.id=n.reference_id AND r.restaurant_id=n.restaurant_id))
  AND NOT (n.reference_type='inventory_lot_count' AND EXISTS(SELECT 1 FROM inventory_lot_counts c WHERE c.id=n.reference_id AND c.restaurant_id=n.restaurant_id))) THEN RAISE EXCEPTION 'INVENTORY_LOT_DETAILS_REQUIRED'; END IF;
 WITH received AS MATERIALIZED(SELECT n.id transaction_id,n.restaurant_id,n.ingredient_id,rl.id line_id,l.ordinality component,l.value lot,
  coalesce(origin.parent_lot_id,NULL::uuid) parent_id,CASE WHEN origin.receipt_id IS NULL THEN 'receipt' ELSE 'hold_release' END kind
  FROM new_lot_transactions n JOIN inventory_receipt_lines rl ON rl.receipt_id=n.reference_id JOIN inventory_products p ON p.id=rl.product_id AND p.inventory_item_id=n.ingredient_id
  CROSS JOIN LATERAL jsonb_array_elements(coalesce(rl.inspection->'lots','[]')) WITH ORDINALITY l(value,ordinality)
  LEFT JOIN inventory_lot_receipt_origins origin ON origin.receipt_id=rl.receipt_id
  WHERE n.ingredient_id=ANY(ids) AND n.quantity_g>0 AND n.reference_type='inventory_purchase_receipt'),
 created AS(INSERT INTO inventory_lots(id,restaurant_id,ingredient_id,location_id,supplier_lot_code,expiry_date,quantity_base,state,source_kind,source_id,source_component,receipt_line_id,parent_lot_id)
 SELECT md5(line_id::text||':'||component||':available')::uuid,restaurant_id,ingredient_id,(lot->>'location_id')::uuid,lot->>'code',nullif(lot->>'expiry_date','')::date,(lot->>'accepted')::numeric,
 'available',kind,line_id,component::integer,line_id,parent_id FROM received WHERE (lot->>'accepted')::numeric>0 RETURNING *)
 INSERT INTO inventory_lot_movements(lot_id,event_kind,event_id,quantity_base,inventory_transaction_id,created_by)
 SELECT c.id,'transaction',r.transaction_id,c.quantity_base,r.transaction_id,auth.uid() FROM created c JOIN received r ON r.line_id=c.source_id AND r.component=c.source_component;
 IF EXISTS(SELECT 1 FROM new_lot_transactions n LEFT JOIN (SELECT inventory_transaction_id,sum(quantity_base) qty FROM inventory_lot_movements WHERE inventory_transaction_id IN(SELECT id FROM new_lot_transactions) GROUP BY inventory_transaction_id)m ON m.inventory_transaction_id=n.id
 WHERE n.ingredient_id=ANY(ids) AND n.quantity_g>0 AND n.reference_type='inventory_purchase_receipt' AND n.quantity_g<>coalesce(m.qty,0)) THEN RAISE EXCEPTION 'INVENTORY_LOT_RECEIPT_TOTAL_MISMATCH'; END IF;
 -- All negative rows in one statement share a consumption scope per ingredient.
 -- Existing returns issue one event; recipe deductions form one bounded batch.
 IF EXISTS(SELECT ingredient_id FROM new_lot_transactions WHERE ingredient_id=ANY(ids) AND quantity_g<0 AND reference_type IS DISTINCT FROM 'inventory_lot_count'
 GROUP BY ingredient_id HAVING count(DISTINCT CASE WHEN reference_type IN('inventory_supplier_return','inventory_lot_disposition') THEN reference_type||':'||reference_id::text WHEN transaction_type='waste' THEN 'waste' ELSE 'general' END)>1) THEN RAISE EXCEPTION 'INVENTORY_LOT_MIXED_SCOPE'; END IF;
 WITH demand AS MATERIALIZED(SELECT n.*,CASE WHEN n.reference_type='inventory_supplier_return' THEN ret.receipt_line_id END return_line,
  CASE WHEN n.reference_type='inventory_lot_disposition' THEN disposition.lot_id END chosen_lot,
  sum(-n.quantity_g) OVER(PARTITION BY n.ingredient_id ORDER BY n.created_at,n.id) finish,
  sum(-n.quantity_g) OVER(PARTITION BY n.ingredient_id ORDER BY n.created_at,n.id)+n.quantity_g start
 FROM new_lot_transactions n LEFT JOIN inventory_supplier_returns ret ON n.reference_type='inventory_supplier_return' AND ret.id=n.reference_id
 LEFT JOIN inventory_lot_dispositions disposition ON n.reference_type='inventory_lot_disposition' AND disposition.id=n.reference_id
 WHERE n.ingredient_id=ANY(ids) AND n.quantity_g<0 AND n.reference_type IS DISTINCT FROM 'inventory_lot_count'),
 scope AS MATERIALIZED(SELECT ingredient_id,bool_or(transaction_type='waste') allow_expired,bool_or(reference_type='inventory_supplier_return') restrict_return,bool_or(reference_type='inventory_lot_disposition') selected,max(return_line::text)::uuid return_line,max(chosen_lot::text)::uuid chosen_lot FROM demand GROUP BY ingredient_id),
 supply AS MATERIALIZED(SELECT l.*,sum(l.quantity_base) OVER(PARTITION BY l.ingredient_id ORDER BY l.expiry_date NULLS LAST,l.created_at,l.id) finish,
 sum(l.quantity_base) OVER(PARTITION BY l.ingredient_id ORDER BY l.expiry_date NULLS LAST,l.created_at,l.id)-l.quantity_base start
 FROM inventory_lots l JOIN scope s ON s.ingredient_id=l.ingredient_id WHERE l.state='available' AND l.quantity_base>0
 AND (s.allow_expired OR s.chosen_lot IS NOT NULL OR l.expiry_date IS NULL OR l.expiry_date>=today)
 AND (NOT coalesce(s.restrict_return,false) OR l.receipt_line_id=s.return_line OR l.source_kind='unknown_legacy')
 AND (NOT coalesce(s.selected,false) OR l.id=s.chosen_lot))
 SELECT coalesce(jsonb_agg(jsonb_build_object('transaction',d.id,'lot',s.id,'quantity',least(d.finish,s.finish)-greatest(d.start,s.start))),'[]') INTO allocations
 FROM demand d JOIN supply s ON s.ingredient_id=d.ingredient_id AND d.finish>s.start AND s.finish>d.start;
 IF EXISTS(SELECT 1 FROM new_lot_transactions n LEFT JOIN(SELECT (x->>'transaction')::uuid id,sum((x->>'quantity')::numeric) qty FROM jsonb_array_elements(allocations)x GROUP BY x->>'transaction') a ON a.id=n.id
 WHERE n.ingredient_id=ANY(ids) AND n.quantity_g<0 AND n.reference_type IS DISTINCT FROM 'inventory_lot_count' AND -n.quantity_g<>coalesce(a.qty,0)) THEN RAISE EXCEPTION 'INVENTORY_AVAILABLE_LOT_SHORTAGE'; END IF;
 UPDATE inventory_lots l SET quantity_base=l.quantity_base-a.qty FROM(SELECT (x->>'lot')::uuid id,sum((x->>'quantity')::numeric) qty FROM jsonb_array_elements(allocations)x GROUP BY x->>'lot')a WHERE l.id=a.id;
 INSERT INTO inventory_lot_movements(lot_id,event_kind,event_id,quantity_base,inventory_transaction_id,created_by)
 SELECT (x->>'lot')::uuid,'transaction',(x->>'transaction')::uuid,-(x->>'quantity')::numeric,(x->>'transaction')::uuid,auth.uid() FROM jsonb_array_elements(allocations)x;
 PERFORM inventory_queue_lot_reconciliation_v1(ids);
 RETURN NULL;
END $$;
CREATE TRIGGER inventory_attach_lot_transactions AFTER INSERT ON public.inventory_transactions REFERENCING NEW TABLE AS new_lot_transactions FOR EACH STATEMENT EXECUTE FUNCTION public.inventory_attach_lot_transactions_v1();
REVOKE ALL ON FUNCTION public.inventory_queue_lot_reconciliation_v1(uuid[]),public.inventory_check_lot_reconciliation_v1(),public.inventory_queue_changed_lots_v1(),public.inventory_attach_lot_transactions_v1() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.admin_save_inventory_location_v1(uuid,uuid,text,text,boolean,bigint) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_save_inventory_location_v1(uuid,uuid,text,text,boolean,bigint) TO authenticated;
COMMIT;
