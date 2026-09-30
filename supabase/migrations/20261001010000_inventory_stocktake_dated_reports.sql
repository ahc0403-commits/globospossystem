-- Capture physical stock changes independently of legacy document annotations.
-- A change is counted once even if a writer also inserts a transaction document.
-- production-gate: self-verifying
BEGIN;
LOCK TABLE public.inventory_items IN SHARE ROW EXCLUSIVE MODE;
ALTER TABLE public.inventory_transactions ADD COLUMN IF NOT EXISTS effective_at timestamptz;
ALTER TABLE public.inventory_stock_audit_sessions
 ADD COLUMN count_business_date date,
 ADD COLUMN effective_at timestamptz,
 ADD COLUMN uploaded_at timestamptz,
 ADD COLUMN template_version integer NOT NULL DEFAULT 1,
 ADD COLUMN report_snapshot jsonb;

-- Unknown historical baselines remain NULL in both storage and reports.
ALTER TABLE public.inventory_stock_audit_lines ALTER COLUMN theoretical_quantity_base DROP NOT NULL;

CREATE INDEX inventory_transactions_item_effective_time ON public.inventory_transactions(ingredient_id,effective_at);

CREATE TABLE public.inventory_stock_checkpoints (
 ingredient_id uuid PRIMARY KEY REFERENCES public.inventory_items(id) ON DELETE CASCADE,
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
 tracked_from timestamptz NOT NULL,
 opening_stock numeric NOT NULL
);
CREATE TABLE public.inventory_stock_movements (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
 ingredient_id uuid NOT NULL REFERENCES public.inventory_items(id) ON DELETE CASCADE,
 quantity_base numeric NOT NULL,
 stock_before numeric NOT NULL,
 stock_after numeric NOT NULL,
 effective_at timestamptz NOT NULL,
 business_date date NOT NULL,
 recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 transaction_id uuid,
 transaction_type text NOT NULL DEFAULT 'adjust',
 reference_type text,
 reference_id uuid,
 note text,
 created_by uuid,
 writer_txid bigint NOT NULL DEFAULT txid_current(),
 CHECK(stock_after-stock_before=quantity_base)
);
CREATE INDEX inventory_stock_movements_item_time ON public.inventory_stock_movements(ingredient_id,effective_at,id);
CREATE INDEX inventory_stock_movements_writer ON public.inventory_stock_movements(writer_txid,ingredient_id) WHERE transaction_id IS NULL;
CREATE INDEX inventory_stock_movements_store_time ON public.inventory_stock_movements(restaurant_id,effective_at,id);
INSERT INTO public.inventory_stock_checkpoints
 SELECT id,restaurant_id,clock_timestamp(),coalesce(current_stock,0) FROM public.inventory_items;
ALTER TABLE public.inventory_stock_checkpoints ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_stock_movements ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inventory_stock_checkpoints,public.inventory_stock_movements FROM anon,authenticated;
GRANT SELECT ON public.inventory_stock_checkpoints,public.inventory_stock_movements TO authenticated;
CREATE POLICY stock_checkpoint_read ON public.inventory_stock_checkpoints FOR SELECT TO authenticated USING(public.can_access_inventory_purchase_store(restaurant_id));
CREATE POLICY stock_movement_read ON public.inventory_stock_movements FOR SELECT TO authenticated USING(public.can_access_inventory_purchase_store(restaurant_id));

-- Only the existing atomic payment contract provides exact legacy occurrence
-- evidence. Unknown dates remain unknown; no blanket created_at backfill.
UPDATE public.inventory_transactions t SET effective_at=t.created_at,
 effective_date=(t.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
 FROM public.order_items oi
 WHERE t.reference_type='order_item' AND t.reference_id=oi.id
 AND t.effective_at IS NULL AND t.transaction_type='deduct' AND t.quantity_g<0
 AND EXISTS(SELECT 1 FROM public.payments p WHERE p.order_id=oi.order_id AND p.created_at=t.created_at);

CREATE FUNCTION public.capture_inventory_stock_movement() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE sid uuid; moment timestamptz:=clock_timestamp(); previous numeric; business_day date;
BEGIN
 IF TG_OP='INSERT' THEN
  INSERT INTO public.inventory_stock_checkpoints VALUES(NEW.id,NEW.restaurant_id,moment,coalesce(NEW.current_stock,0));
  RETURN NEW;
 END IF;
 IF NEW.restaurant_id IS DISTINCT FROM OLD.restaurant_id THEN RAISE EXCEPTION 'INVENTORY_STOCK_STORE_IMMUTABLE'; END IF;
 previous:=coalesce(OLD.current_stock,0);
 IF coalesce(NEW.current_stock,0)=previous THEN RETURN NEW; END IF;
 sid:=nullif(current_setting('globos.stocktake_session',true),'')::uuid;
 IF sid IS NOT NULL THEN SELECT effective_at,count_business_date INTO moment,business_day FROM public.inventory_stock_audit_sessions WHERE id=sid AND restaurant_id=NEW.restaurant_id; END IF;
 business_day:=coalesce(business_day,(moment AT TIME ZONE 'Asia/Ho_Chi_Minh')::date);
 INSERT INTO public.inventory_stock_movements(restaurant_id,ingredient_id,quantity_base,stock_before,stock_after,effective_at,business_date,reference_type,reference_id,created_by)
 VALUES(NEW.restaurant_id,NEW.id,coalesce(NEW.current_stock,0)-previous,previous,coalesce(NEW.current_stock,0),coalesce(moment,clock_timestamp()),business_day,CASE WHEN sid IS NULL THEN 'direct_stock_change' ELSE 'inventory_stock_audit' END,sid,auth.uid());
 RETURN NEW;
END $$;
CREATE TRIGGER inventory_stock_movement_capture AFTER INSERT OR UPDATE ON public.inventory_items FOR EACH ROW EXECUTE FUNCTION public.capture_inventory_stock_movement();

-- Enrich the captured change with its source document. Never sum this legacy
-- annotation a second time. Unannotated direct changes remain visible as ±.
CREATE FUNCTION public.annotate_inventory_stock_movement() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE m public.inventory_stock_movements%ROWTYPE; cutoff timestamptz;
BEGIN
 SELECT * INTO m FROM public.inventory_stock_movements WHERE writer_txid=txid_current()
  AND ingredient_id=NEW.ingredient_id AND restaurant_id=NEW.restaurant_id
  AND transaction_id IS NULL AND quantity_base=NEW.quantity_g ORDER BY id LIMIT 1 FOR UPDATE;
 IF FOUND THEN
  IF NEW.effective_at IS NULL AND NEW.effective_date IS NOT NULL AND NEW.effective_date<>(m.effective_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date THEN RAISE EXCEPTION 'INVENTORY_STOCK_EFFECTIVE_TIME_REQUIRED'; END IF;
  NEW.effective_at:=coalesce(NEW.effective_at,m.effective_at);
  IF NEW.effective_at>clock_timestamp() THEN RAISE EXCEPTION 'INVENTORY_STOCK_FUTURE_EVENT_INVALID'; END IF;
  NEW.effective_date:=coalesce(NEW.effective_date,(NEW.effective_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date);
  NEW.stock_before:=m.stock_before; NEW.stock_after:=m.stock_after;
  UPDATE public.inventory_stock_movements SET transaction_id=NEW.id,transaction_type=NEW.transaction_type,
   reference_type=NEW.reference_type,reference_id=NEW.reference_id,note=NEW.note,effective_at=NEW.effective_at,business_date=NEW.effective_date WHERE id=m.id;
  -- An explicitly backdated event arriving after a newer physical count must
  -- not deduct that already observed stock again. Reject atomically for review.
  SELECT max(s.effective_at) INTO cutoff FROM public.inventory_stock_audit_sessions s
   JOIN public.inventory_stock_audit_lines l ON l.session_id=s.id
   JOIN public.inventory_products p ON p.id=l.product_id
   WHERE s.restaurant_id=NEW.restaurant_id AND s.status='completed'
   AND p.inventory_item_id=NEW.ingredient_id AND l.status='counted'
   AND s.id IS DISTINCT FROM NEW.reference_id;
  IF cutoff IS NOT NULL AND NEW.effective_at<=cutoff AND NEW.reference_type IS DISTINCT FROM 'inventory_stock_audit' THEN
   RAISE EXCEPTION 'INVENTORY_STOCK_LATE_EVENT_REQUIRES_REVIEW';
  END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER inventory_stock_movement_annotation BEFORE INSERT ON public.inventory_transactions FOR EACH ROW EXECUTE FUNCTION public.annotate_inventory_stock_movement();

CREATE FUNCTION public.inventory_stock_at(p_item_id uuid,p_at timestamptz) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE c public.inventory_stock_checkpoints%ROWTYPE; q numeric; known boolean:=true; origin text:='tracked'; registered timestamptz; unknown_history boolean:=false;
BEGIN
 SELECT * INTO c FROM public.inventory_stock_checkpoints WHERE ingredient_id=p_item_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_LEDGER_MISSING'; END IF;
 SELECT created_at INTO registered FROM public.inventory_items WHERE id=p_item_id;
 q:=c.opening_stock;
 IF p_at<c.tracked_from THEN
  origin:='legacy_reconstructed';
  unknown_history:=EXISTS(SELECT 1 FROM public.inventory_transactions t
   WHERE t.ingredient_id=p_item_id AND t.created_at>=p_at AND t.created_at<c.tracked_from AND t.effective_at IS NULL);
  known:=registered<=p_at AND NOT unknown_history;
  SELECT q-coalesce(sum(quantity_g),0) INTO q FROM public.inventory_transactions
   WHERE ingredient_id=p_item_id AND created_at<c.tracked_from AND effective_at>p_at;
  SELECT q+coalesce(sum(quantity_base),0) INTO q FROM public.inventory_stock_movements WHERE ingredient_id=p_item_id AND effective_at<=p_at;
 ELSE
  SELECT q+coalesce(sum(quantity_base),0) INTO q FROM public.inventory_stock_movements WHERE ingredient_id=p_item_id AND effective_at<=p_at;
 END IF;
 IF NOT known THEN q:=NULL; origin:='unavailable'; END IF;
 RETURN jsonb_build_object('quantity',q,'source',origin,'tracked_from',c.tracked_from,'unverified_history',unknown_history);
END $$;

CREATE FUNCTION public.get_inventory_stock_audit_v2(p_store_id uuid,p_session_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE s public.inventory_stock_audit_sessions%ROWTYPE; store_name text;
BEGIN
 IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_FORBIDDEN'; END IF;
 SELECT * INTO s FROM public.inventory_stock_audit_sessions WHERE id=p_session_id AND restaurant_id=p_store_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_SESSION_NOT_FOUND'; END IF;
 SELECT name INTO store_name FROM public.restaurants WHERE id=p_store_id;
 RETURN jsonb_build_object('id',s.id,'store_id',p_store_id,'store_name',store_name,'version',s.row_version,
  'status',s.status,'template_version',s.template_version,'business_date',coalesce(s.count_business_date,s.planned_date),'effective_at',s.effective_at,
  'exported_at',s.started_at,'uploaded_at',s.uploaded_at,'completed_at',s.completed_at,'snapshot',s.count_snapshot,
  'lines',s.saved_count_lines,'memo',s.memo,'report',s.report_snapshot);
END $$;

CREATE FUNCTION public.prepare_inventory_stock_audit_v2(p_store_id uuid,p_business_date date,p_effective_at timestamptz) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE sid uuid; snapshot jsonb; moment timestamptz:=clock_timestamp();
BEGIN
 IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_FORBIDDEN'; END IF;
 IF p_business_date IS NULL OR p_effective_at IS NULL OR p_effective_at>moment+interval '7 days'
 OR p_business_date NOT BETWEEN (p_effective_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date-1 AND (p_effective_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_DATE_INVALID'; END IF;
 -- Serialize preparation with commerce while reading the stock checkpoint.
 PERFORM id FROM public.inventory_items WHERE restaurant_id=p_store_id ORDER BY id FOR UPDATE;
 SELECT id INTO sid FROM public.inventory_stock_audit_sessions WHERE restaurant_id=p_store_id
  AND template_version=2 AND status IN('planned','in_progress') AND created_by IS NOT DISTINCT FROM auth.uid()
  AND count_business_date=p_business_date AND effective_at=p_effective_at ORDER BY created_at DESC LIMIT 1;
 IF sid IS NOT NULL THEN RETURN public.get_inventory_stock_audit_v2(p_store_id,sid); END IF;
 SELECT jsonb_agg(jsonb_build_object('product_id',p.id,'product_code',p.product_code,'product_name',p.name,
  'base_unit',p.base_unit,'base_unit_factor',p.base_unit_factor,'stock_unit',p.stock_unit,'inventory_item_id',i.id,
  'product_updated_at',p.updated_at,'current_stock_base',public.inventory_stock_at(i.id,least(p_effective_at,moment))->'quantity',
  'baseline_source',public.inventory_stock_at(i.id,least(p_effective_at,moment))->>'source',
  'baseline_provisional',p_effective_at>moment,'unit_cost',nullif(i.cost_per_unit,0),
  'supplier_name',coalesce(i.supplier_name,'')) ORDER BY p.product_code,p.id) INTO snapshot
 FROM public.inventory_products p JOIN public.inventory_items i ON i.id=p.inventory_item_id
 WHERE p.restaurant_id=p_store_id AND p.is_active AND i.is_active;
 IF snapshot IS NULL THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_LINES_REQUIRED'; END IF;
 INSERT INTO public.inventory_stock_audit_sessions(restaurant_id,brand_id,audit_no,audit_type,status,planned_date,
  started_at,created_by,assigned_to,count_snapshot,count_business_date,effective_at,template_version)
 SELECT p_store_id,brand_id,'INV-'||gen_random_uuid()::text,'ad_hoc','planned',p_business_date,moment,
  auth.uid(),auth.uid(),snapshot,p_business_date,p_effective_at,2 FROM public.restaurants WHERE id=p_store_id RETURNING id INTO sid;
 RETURN public.get_inventory_stock_audit_v2(p_store_id,sid);
END $$;

CREATE FUNCTION public.preview_inventory_stock_audit_v3(p_store_id uuid,p_session_id uuid,p_lines jsonb,
 p_initialize_missing boolean DEFAULT false,p_acknowledge_legacy boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE s public.inventory_stock_audit_sessions%ROWTYPE; line jsonb; snap jsonb; p public.inventory_products%ROWTYPE;
 item public.inventory_items%ROWTYPE; at_stock jsonb; baseline numeric; actual numeric; normalized numeric;
 observed timestamptz; net numeric; plus numeric; minus numeric; window_net numeric; expected numeric;
 result jsonb:='[]'; token text; canonical jsonb; issue text; moment timestamptz:=clock_timestamp();
BEGIN
 IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_FORBIDDEN'; END IF;
 SELECT * INTO s FROM public.inventory_stock_audit_sessions WHERE id=p_session_id AND restaurant_id=p_store_id;
 IF NOT FOUND OR s.template_version<>2 THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_SESSION_NOT_FOUND'; END IF;
 IF p_lines IS NULL OR jsonb_typeof(p_lines)<>'array' OR jsonb_array_length(p_lines)=0 THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_LINES_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_lines) x GROUP BY x->>'product_id' HAVING count(*)>1) THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_DUPLICATE_PRODUCT'; END IF;
 FOR line IN SELECT x FROM jsonb_array_elements(p_lines) x ORDER BY x->>'product_id' LOOP
  issue:=NULL;
  SELECT x INTO snap FROM jsonb_array_elements(s.count_snapshot) x WHERE x->>'product_id'=line->>'product_id';
  IF snap IS NULL THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_PRODUCT_NOT_FOUND'; END IF;
  SELECT * INTO p FROM public.inventory_products WHERE id=(snap->>'product_id')::uuid AND restaurant_id=p_store_id AND is_active;
  IF NOT FOUND OR p.inventory_item_id IS DISTINCT FROM (snap->>'inventory_item_id')::uuid OR p.base_unit IS DISTINCT FROM snap->>'base_unit'
   OR p.base_unit_factor IS DISTINCT FROM (snap->>'base_unit_factor')::numeric OR p.product_code IS DISTINCT FROM snap->>'product_code'
   OR p.name IS DISTINCT FROM snap->>'product_name' THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_STOCK_CHANGED: %',snap->>'product_code'; END IF;
  SELECT * INTO item FROM public.inventory_items WHERE id=p.inventory_item_id AND restaurant_id=p_store_id AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_ITEM_NOT_FOUND'; END IF;
  actual:=NULL; observed:=NULL;
  IF nullif(btrim(line->>'excluded_reason'),'') IS NOT NULL THEN
   IF line->>'actual_quantity_base' IS NOT NULL THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_ACTUAL_INVALID'; END IF;
  ELSE
   IF jsonb_typeof(line->'actual_quantity_base') IS DISTINCT FROM 'number' OR (line->>'actual_quantity_base') !~ '^[0-9]+(\.[0-9]{1,3})?$' THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_ACTUAL_INVALID: %',snap->>'product_code'; END IF;
   actual:=(line->>'actual_quantity_base')::numeric;
   IF actual>999999999.999 THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_ACTUAL_INVALID'; END IF;
   IF coalesce(line->>'counted_at','') !~ '(Z|[+-][0-9]{2}:[0-9]{2})$' THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_COUNT_TIME_INVALID'; END IF;
   observed:=(line->>'counted_at')::timestamptz;
   IF observed>moment+interval '5 minutes' OR abs(extract(epoch FROM observed-s.effective_at))>86400 THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_COUNT_TIME_INVALID'; END IF;
  END IF;
  at_stock:=public.inventory_stock_at(item.id,least(s.effective_at,moment)); baseline:=(at_stock->>'quantity')::numeric;
  SELECT coalesce(sum(quantity_base),0) INTO expected FROM public.inventory_stock_movements WHERE ingredient_id=item.id;
  SELECT opening_stock+expected INTO expected FROM public.inventory_stock_checkpoints WHERE ingredient_id=item.id;
  IF expected IS DISTINCT FROM coalesce(item.current_stock,0) THEN issue:='LEDGER_MISMATCH'; END IF;
  IF baseline IS NULL AND NOT coalesce(p_initialize_missing,false) THEN issue:='BASELINE_MISSING'; END IF;
  IF coalesce((at_stock->>'unverified_history')::boolean,false) THEN issue:='HISTORY_UNVERIFIED'; END IF;
  IF at_stock->>'source'='legacy_reconstructed' AND NOT coalesce(p_acknowledge_legacy,false) THEN issue:='LEGACY_RECONCILIATION_REQUIRED'; END IF;
  IF s.effective_at>moment THEN issue:='REFERENCE_TIME_NOT_REACHED'; END IF;
  IF EXISTS(SELECT 1 FROM public.inventory_stock_audit_sessions newer JOIN public.inventory_stock_audit_lines l ON l.session_id=newer.id
   WHERE newer.restaurant_id=p_store_id AND newer.id<>s.id AND newer.status='completed' AND l.product_id=p.id AND l.status='counted'
   AND coalesce(newer.effective_at,newer.completed_at)>=s.effective_at) THEN issue:='NEWER_COUNT_EXISTS'; END IF;
  SELECT coalesce(sum(quantity_base),0),coalesce(sum(quantity_base) FILTER(WHERE quantity_base>0),0),coalesce(sum(quantity_base) FILTER(WHERE quantity_base<0),0)
   INTO net,plus,minus FROM public.inventory_stock_movements WHERE ingredient_id=item.id AND effective_at>s.effective_at;
  IF s.effective_at<(SELECT tracked_from FROM public.inventory_stock_checkpoints WHERE ingredient_id=item.id) THEN
   SELECT net+coalesce(sum(quantity_g),0),plus+coalesce(sum(quantity_g) FILTER(WHERE quantity_g>0),0),minus+coalesce(sum(quantity_g) FILTER(WHERE quantity_g<0),0)
    INTO net,plus,minus FROM public.inventory_transactions t WHERE ingredient_id=item.id AND effective_at>s.effective_at
    AND created_at<(SELECT tracked_from FROM public.inventory_stock_checkpoints WHERE ingredient_id=item.id);
  END IF;
  window_net:=0;
  IF actual IS NOT NULL AND observed IS DISTINCT FROM s.effective_at THEN
   IF observed<(SELECT tracked_from FROM public.inventory_stock_checkpoints WHERE ingredient_id=item.id) AND public.inventory_stock_at(item.id,observed)->>'source'='unavailable' THEN issue:='OBSERVATION_HISTORY_MISSING';
   ELSE window_net:=(public.inventory_stock_at(item.id,observed)->>'quantity')::numeric-baseline; END IF;
  END IF;
  normalized:=actual-window_net;
  IF normalized<0 OR normalized>999999999.999 OR normalized+net NOT BETWEEN -999999999.999 AND 999999999.999 OR abs(normalized-baseline)>999999999.999 OR abs(normalized+net-coalesce(item.current_stock,0))>999999999.999 THEN issue:='RESULT_QUANTITY_INVALID'; END IF;
  IF baseline IS NULL THEN
   -- Explicit initial anchor: comparison remains NULL, no invented POS zero.
   normalized:=actual;
   IF actual IS NOT NULL AND observed IS DISTINCT FROM s.effective_at THEN issue:='INITIAL_COUNT_TIME_MUST_MATCH'; END IF;
  END IF;
  result:=result||jsonb_build_array(snap||jsonb_build_object('baseline_quantity_base',baseline,'baseline_source',at_stock->>'source',
   'observed_quantity_base',actual,'actual_quantity_base',normalized,'counted_at',observed,'excluded_reason',nullif(btrim(line->>'excluded_reason'),''),
   'memo',nullif(btrim(line->>'memo'),''),'variance_quantity_base',normalized-baseline,'after_increase_base',plus,'after_decrease_base',minus,
   'after_net_base',net,'current_before_base',item.current_stock,'current_after_base',CASE WHEN actual IS NULL THEN item.current_stock ELSE normalized+net END,
   'adjustment_base',CASE WHEN actual IS NULL THEN NULL ELSE normalized+net-coalesce(item.current_stock,0) END,
   'variance_amount',round((normalized-baseline)*(snap->>'unit_cost')::numeric,2),'issue',CASE WHEN actual IS NULL THEN NULL ELSE issue END));
 END LOOP;
 SELECT jsonb_agg(x ORDER BY x->>'product_id') INTO canonical FROM jsonb_array_elements(p_lines) x;
 token:=md5(result::text||s.row_version::text);
 RETURN jsonb_build_object('rows',result,'token',token,'as_of',moment,'business_date',s.count_business_date,'effective_at',s.effective_at,
  'can_complete',s.effective_at<=moment AND jsonb_array_length(result)=jsonb_array_length(s.count_snapshot) AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(result) x WHERE x->>'issue' IS NOT NULL));
END $$;

-- A cached v1 client cannot bypass the dated contract through the old RPC.
ALTER FUNCTION public.save_inventory_stock_audit_v2(uuid,uuid,integer,jsonb,boolean,text) RENAME TO save_inventory_stock_audit_v2_legacy_impl;
REVOKE ALL ON FUNCTION public.save_inventory_stock_audit_v2_legacy_impl(uuid,uuid,integer,jsonb,boolean,text) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.save_inventory_stock_audit_v2(p_store_id uuid,p_session_id uuid,p_expected_version integer,p_lines jsonb,p_complete boolean DEFAULT false,p_memo text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
BEGIN
 IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_FORBIDDEN'; END IF;
 IF EXISTS(SELECT 1 FROM public.inventory_stock_audit_sessions WHERE id=p_session_id AND restaurant_id=p_store_id AND template_version=2) THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_DATED_FORMAT_REQUIRED'; END IF;
 RETURN public.save_inventory_stock_audit_v2_legacy_impl(p_store_id,p_session_id,p_expected_version,p_lines,p_complete,p_memo);
END $$;
REVOKE ALL ON FUNCTION public.save_inventory_stock_audit_v2(uuid,uuid,integer,jsonb,boolean,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_inventory_stock_audit_v2(uuid,uuid,integer,jsonb,boolean,text) TO authenticated,service_role;

CREATE FUNCTION public.save_inventory_stock_audit_v3(p_store_id uuid,p_session_id uuid,p_expected_version integer,p_lines jsonb,
 p_complete boolean DEFAULT false,p_memo text DEFAULT NULL,p_preview_token text DEFAULT NULL,
 p_initialize_missing boolean DEFAULT false,p_acknowledge_legacy boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE s public.inventory_stock_audit_sessions%ROWTYPE; canonical jsonb; preview jsonb; row jsonb; item_id uuid; report jsonb;
BEGIN
 IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_FORBIDDEN'; END IF;
 SELECT * INTO s FROM public.inventory_stock_audit_sessions WHERE id=p_session_id AND restaurant_id=p_store_id FOR UPDATE;
 IF NOT FOUND OR s.template_version<>2 THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_SESSION_NOT_FOUND'; END IF;
 SELECT jsonb_agg(jsonb_build_object('product_id',x->>'product_id','actual_quantity_base',x->'actual_quantity_base',
  'counted_at',x->>'counted_at','excluded_reason',nullif(btrim(x->>'excluded_reason'),''),'memo',nullif(btrim(x->>'memo'),'')) ORDER BY x->>'product_id') INTO canonical FROM jsonb_array_elements(p_lines) x;
 IF s.status='completed' THEN
  IF p_complete AND canonical=s.saved_count_lines AND s.memo IS NOT DISTINCT FROM nullif(btrim(p_memo),'') THEN RETURN public.get_inventory_stock_audit_v2(p_store_id,s.id); END IF;
  RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_SESSION_NOT_EDITABLE';
 END IF;
 IF s.status NOT IN('planned','in_progress') THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_SESSION_NOT_EDITABLE'; END IF;
 IF s.row_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_VERSION_CHANGED'; END IF;
 IF p_complete IS NULL THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_ACTUAL_INVALID'; END IF;
 PERFORM i.id FROM public.inventory_items i WHERE i.restaurant_id=p_store_id ORDER BY i.id FOR UPDATE;
 PERFORM p.id FROM public.inventory_products p WHERE p.restaurant_id=p_store_id ORDER BY p.id FOR SHARE;
 preview:=public.preview_inventory_stock_audit_v3(p_store_id,p_session_id,canonical,p_initialize_missing,p_acknowledge_legacy);
 IF p_complete THEN
  IF jsonb_array_length(canonical)<>jsonb_array_length(s.count_snapshot) THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_INCOMPLETE'; END IF;
  IF (SELECT count(*) FROM public.inventory_products p JOIN public.inventory_items i ON i.id=p.inventory_item_id WHERE p.restaurant_id=p_store_id AND p.is_active AND i.is_active)<>jsonb_array_length(s.count_snapshot) THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_STOCK_CHANGED'; END IF;
  IF NOT (preview->>'can_complete')::boolean THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_RECONCILIATION_REQUIRED: %',preview->'rows'; END IF;
  IF p_preview_token IS DISTINCT FROM preview->>'token' THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_PREVIEW_CHANGED'; END IF;
 END IF;
 DELETE FROM public.inventory_stock_audit_lines WHERE session_id=s.id;
 FOR row IN SELECT x FROM jsonb_array_elements(preview->'rows') x LOOP
  INSERT INTO public.inventory_stock_audit_lines(session_id,product_id,theoretical_quantity_base,actual_quantity_base,variance_quantity_base,variance_amount,status,memo)
  VALUES(s.id,(row->>'product_id')::uuid,(row->>'baseline_quantity_base')::numeric,(row->>'actual_quantity_base')::numeric,
   (row->>'variance_quantity_base')::numeric,(row->>'variance_amount')::numeric,CASE WHEN row->>'actual_quantity_base' IS NULL THEN 'skipped' ELSE 'counted' END,coalesce(row->>'excluded_reason',row->>'memo'));
  IF p_complete AND row->>'actual_quantity_base' IS NOT NULL THEN
   item_id:=(row->>'inventory_item_id')::uuid;
   PERFORM set_config('globos.stocktake_session',s.id::text,true);
   -- quantity is the nonnegative counted anchor; current_stock is the
   -- subsequent POS balance and may be negative after later consumption.
   UPDATE public.inventory_items SET current_stock=(row->>'current_after_base')::numeric,quantity=(row->>'actual_quantity_base')::numeric,updated_at=clock_timestamp() WHERE id=item_id;
   INSERT INTO public.inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,reference_type,reference_id,
    note,created_by,effective_at,effective_date,stock_before,stock_after)
   VALUES(p_store_id,item_id,'adjust',(row->>'adjustment_base')::numeric,'inventory_stock_audit',s.id,coalesce(row->>'memo',p_memo,'Dated stocktake'),auth.uid(),s.effective_at,s.count_business_date,(row->>'current_before_base')::numeric,(row->>'current_after_base')::numeric);
   PERFORM set_config('globos.stocktake_session','',true);
  END IF;
 END LOOP;
 report:=preview||jsonb_build_object('completed_at',clock_timestamp(),'created_by',auth.uid(),'initialized_missing_baseline',p_initialize_missing,'legacy_acknowledged',p_acknowledge_legacy,'valuation_at',s.started_at);
 UPDATE public.inventory_stock_audit_sessions SET saved_count_lines=canonical,row_version=row_version+1,
  status=CASE WHEN p_complete THEN 'completed' ELSE 'in_progress' END,uploaded_at=clock_timestamp(),
  completed_at=CASE WHEN p_complete THEN clock_timestamp() ELSE NULL END,report_snapshot=CASE WHEN p_complete THEN report ELSE NULL END,
  memo=nullif(btrim(p_memo),''),updated_at=clock_timestamp() WHERE id=s.id;
 RETURN public.get_inventory_stock_audit_v2(p_store_id,s.id);
END $$;

CREATE FUNCTION public.list_inventory_stock_audits(p_store_id uuid,p_business_date date DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
BEGIN
 IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_FORBIDDEN'; END IF;
 RETURN coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT id,audit_no,status,coalesce(count_business_date,planned_date) business_date,
  effective_at,completed_at,template_version FROM public.inventory_stock_audit_sessions WHERE restaurant_id=p_store_id
  AND (p_business_date IS NULL OR coalesce(count_business_date,planned_date)=p_business_date) ORDER BY created_at DESC LIMIT 100) x),'[]');
END $$;

CREATE FUNCTION public.get_inventory_stock_audit_report(p_store_id uuid,p_session_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE session jsonb; s public.inventory_stock_audit_sessions%ROWTYPE; movements jsonb; rows jsonb;
BEGIN
 session:=public.get_inventory_stock_audit_v2(p_store_id,p_session_id);
 SELECT * INTO s FROM public.inventory_stock_audit_sessions WHERE id=p_session_id;
 rows:=coalesce(s.report_snapshot->'rows','[]');
 IF s.template_version=2 AND s.status='in_progress' AND jsonb_array_length(s.saved_count_lines)>0 THEN
  rows:=public.preview_inventory_stock_audit_v3(p_store_id,p_session_id,s.saved_count_lines)->'rows';
 END IF;
 IF s.template_version=1 THEN
  SELECT coalesce(jsonb_agg(snap||jsonb_build_object('baseline_quantity_base',l.theoretical_quantity_base,'actual_quantity_base',l.actual_quantity_base,
   'variance_quantity_base',l.variance_quantity_base,'variance_amount',l.variance_amount,'excluded_reason',CASE WHEN l.status='skipped' THEN l.memo END)),'[]') INTO rows
   FROM public.inventory_stock_audit_lines l JOIN LATERAL (SELECT x snap FROM jsonb_array_elements(s.count_snapshot) x WHERE x->>'product_id'=l.product_id::text) q ON true WHERE l.session_id=s.id;
 END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.effective_at,x.id),'[]') INTO movements FROM (
  SELECT m.id,m.ingredient_id,snap->>'product_code' product_code,snap->>'product_name' product_name,snap->>'base_unit' base_unit,
   m.business_date,m.effective_at,m.recorded_at,m.quantity_base,
   m.transaction_type,m.reference_type,m.reference_id,m.note
  FROM public.inventory_stock_movements m JOIN LATERAL (SELECT x snap FROM jsonb_array_elements(s.count_snapshot) x WHERE x->>'inventory_item_id'=m.ingredient_id::text) q ON true
  WHERE m.restaurant_id=p_store_id AND m.effective_at>coalesce(s.effective_at,s.completed_at)
  AND m.reference_id IS DISTINCT FROM s.id
  UNION ALL
  SELECT NULL::bigint,t.ingredient_id,snap->>'product_code',snap->>'product_name',snap->>'base_unit',t.effective_date,t.effective_at,t.created_at,
   t.quantity_g,t.transaction_type,t.reference_type,t.reference_id,t.note
  FROM public.inventory_transactions t JOIN public.inventory_stock_checkpoints c ON c.ingredient_id=t.ingredient_id
  JOIN LATERAL (SELECT x snap FROM jsonb_array_elements(s.count_snapshot) x WHERE x->>'inventory_item_id'=t.ingredient_id::text) q ON true
  WHERE t.restaurant_id=p_store_id AND t.created_at<c.tracked_from AND t.effective_at>coalesce(s.effective_at,s.completed_at)
 ) x;
 RETURN session||jsonb_build_object('rows',rows,'movements',movements,'as_of',statement_timestamp());
END $$;

REVOKE ALL ON FUNCTION public.inventory_stock_at(uuid,timestamptz),public.capture_inventory_stock_movement(),public.annotate_inventory_stock_movement() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.get_inventory_stock_audit_v2(uuid,uuid),public.prepare_inventory_stock_audit_v2(uuid,date,timestamptz),public.preview_inventory_stock_audit_v3(uuid,uuid,jsonb,boolean,boolean),public.save_inventory_stock_audit_v3(uuid,uuid,integer,jsonb,boolean,text,text,boolean,boolean),public.list_inventory_stock_audits(uuid,date),public.get_inventory_stock_audit_report(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_stock_audit_v2(uuid,uuid),public.prepare_inventory_stock_audit_v2(uuid,date,timestamptz),public.preview_inventory_stock_audit_v3(uuid,uuid,jsonb,boolean,boolean),public.save_inventory_stock_audit_v3(uuid,uuid,integer,jsonb,boolean,text,text,boolean,boolean),public.list_inventory_stock_audits(uuid,date),public.get_inventory_stock_audit_report(uuid,uuid) TO authenticated,service_role;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.inventory_items i LEFT JOIN public.inventory_stock_checkpoints c ON c.ingredient_id=i.id WHERE c.ingredient_id IS NULL OR c.opening_stock IS DISTINCT FROM coalesce(i.current_stock,0)) THEN RAISE EXCEPTION 'STOCKTAKE_CHECKPOINT_FAILED'; END IF;
 IF to_regprocedure('public.save_inventory_stock_audit_v3(uuid,uuid,integer,jsonb,boolean,text,text,boolean,boolean)') IS NULL THEN RAISE EXCEPTION 'STOCKTAKE_DATED_RPC_MISSING'; END IF;
END $$;
NOTIFY pgrst,'reload schema';
COMMIT;
