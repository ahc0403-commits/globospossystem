-- Every deactivation path shares the same pending-work boundary. Closing retains
-- accounting/sales history and never fabricates a paid/reported external state.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE FUNCTION public.store_closure_pending_v1(p_store uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT jsonb_build_object(
  'orders',(SELECT count(*) FROM orders WHERE restaurant_id=p_store AND status IN('pending','confirmed','serving')),
  'occupied_tables',(SELECT count(*) FROM tables WHERE restaurant_id=p_store AND status='occupied'),
  'direct_requests',(SELECT count(*) FROM direct_order_requests WHERE restaurant_id=p_store AND state IN('awaiting_quote','quoted','awaiting_payment_review')),
  'account_jobs',(SELECT count(*) FROM store_account_onboarding_jobs WHERE store_id=p_store AND status<>'complete'),
  'purchase_requests',(SELECT count(*) FROM inventory_purchase_requests WHERE restaurant_id=p_store AND status NOT IN('allocated','cancelled')),
  'purchase_orders',(SELECT count(*) FROM inventory_purchase_orders WHERE restaurant_id=p_store AND status NOT IN('received','cancelled','office_rejected')),
  'draft_receipts',(SELECT count(*) FROM inventory_receipts WHERE restaurant_id=p_store AND status='draft'),
  'held_lots',(SELECT count(*) FROM inventory_lots WHERE restaurant_id=p_store AND state IN('held','rejected') AND quantity_base>0),
  'accounting',(SELECT count(*) FROM inventory_purchase_orders o LEFT JOIN procurement_accounting_status a ON a.purchase_order_id=o.id
    WHERE o.restaurant_id=p_store AND EXISTS(SELECT 1 FROM inventory_receipts r WHERE r.purchase_order_id=o.id AND r.status='confirmed')
    AND (a.purchase_order_id IS NULL OR a.source_order_version<>o.row_version OR a.reconciliation_required OR a.held_count>0 OR a.payable_count>a.paid_count)),
  'supplier_reports',(SELECT count(*) FROM procurement_receipt_reports WHERE restaurant_id=p_store AND sent_at IS NULL),
  'print_retries',(SELECT count(*) FROM print_jobs WHERE restaurant_id=p_store AND status IN('pending','failed','printing')),
  'misa_retries',(SELECT count(*) FROM meinvoice_jobs WHERE store_id=p_store AND status IN('pending_manual_config','pending','dispatch_paused','failed','manual_action_required')),
  'invoice_retries',(SELECT count(*) FROM einvoice_jobs j JOIN orders o ON o.id=j.order_id WHERE o.restaurant_id=p_store AND j.status IN('pending','failed_terminal','stale')),
  'device_outbox',(SELECT count(*) FROM store_workflow_devices WHERE restaurant_id=p_store AND pending_count>0)
 );
$$;
CREATE FUNCTION public.admin_get_store_closure_readiness_v1(p_store uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE pending jsonb;
BEGIN
 PERFORM require_brand_admin_v1();
 IF NOT EXISTS(SELECT 1 FROM restaurants WHERE id=p_store) THEN RAISE EXCEPTION 'STORE_NOT_FOUND'; END IF;
 pending:=store_closure_pending_v1(p_store);
 RETURN jsonb_build_object('pending',pending,'ready',NOT EXISTS(SELECT 1 FROM jsonb_each_text(pending)x WHERE x.value::bigint>0));
END $$;
CREATE FUNCTION public.store_guard_closure_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE pending jsonb;
BEGIN
 IF OLD.is_active AND NOT NEW.is_active THEN
  PERFORM pg_advisory_xact_lock(hashtextextended('store-opening:'||OLD.id,0));
  pending:=store_closure_pending_v1(OLD.id);
  IF EXISTS(SELECT 1 FROM jsonb_each_text(pending)x WHERE x.value::bigint>0) THEN RAISE EXCEPTION 'STORE_CLOSURE_PENDING' USING DETAIL=pending::text; END IF;
  UPDATE store_lifecycle SET state='closed',revision=revision+1,changed_by=auth.uid(),changed_at=now() WHERE restaurant_id=OLD.id;
 ELSIF NOT OLD.is_active AND NEW.is_active AND EXISTS(SELECT 1 FROM store_lifecycle WHERE restaurant_id=OLD.id AND state='closed') THEN
  RAISE EXCEPTION 'STORE_REOPEN_REQUIRES_PREPARATION';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER store_closure_guard BEFORE UPDATE OF is_active ON public.restaurants FOR EACH ROW EXECUTE FUNCTION public.store_guard_closure_v1();
-- Equivalent claims refresh for the entire affected set, with each relation
-- aggregated once. The old per-user function remains available to its callers.
CREATE FUNCTION public.store_refresh_closed_claims_v1(p_store uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE n integer;
BEGIN
 WITH affected AS MATERIALIZED(SELECT u.* FROM users u WHERE u.auth_id IS NOT NULL AND (u.restaurant_id=p_store OR u.primary_store_id=p_store OR EXISTS(SELECT 1 FROM user_store_access s WHERE s.user_id=u.id AND s.store_id=p_store))),
 store_scope AS MATERIALIZED(SELECT u.id user_id,s.store_id FROM affected u JOIN user_store_access s ON s.user_id=u.id AND s.is_active JOIN restaurants r ON r.id=s.store_id AND r.is_active WHERE u.is_active
 UNION SELECT u.id,r.id FROM affected u JOIN restaurants r ON r.id=coalesce(u.primary_store_id,u.restaurant_id) AND r.is_active WHERE u.is_active),
 brand_scope AS(SELECT u.id user_id,b.brand_id FROM affected u JOIN user_brand_access b ON b.user_id=u.id AND b.is_active WHERE u.is_active UNION SELECT id,brand_id FROM affected WHERE is_active AND brand_id IS NOT NULL),
 entity_scope AS(SELECT u.id user_id,e.tax_entity_id FROM affected u JOIN user_tax_entity_access e ON e.user_id=u.id AND e.is_active WHERE u.is_active UNION SELECT s.user_id,r.tax_entity_id FROM store_scope s JOIN restaurants r ON r.id=s.store_id WHERE r.tax_entity_id IS NOT NULL),
 stores AS(SELECT user_id,jsonb_agg(store_id ORDER BY store_id) ids FROM store_scope GROUP BY user_id),
 brands AS(SELECT user_id,jsonb_agg(brand_id ORDER BY brand_id) ids FROM brand_scope GROUP BY user_id),
 entities AS(SELECT user_id,jsonb_agg(tax_entity_id ORDER BY tax_entity_id) ids FROM entity_scope GROUP BY user_id)
 UPDATE auth.users a SET raw_app_meta_data=coalesce(a.raw_app_meta_data,'{}')||jsonb_build_object('role',CASE WHEN u.is_active THEN u.role END,'brand_ids',coalesce(b.ids,'[]'),'accessible_store_ids',coalesce(s.ids,'[]'),'accessible_tax_entity_ids',coalesce(e.ids,'[]'),'primary_store_id',CASE WHEN u.is_active THEN coalesce(u.primary_store_id,u.restaurant_id) END)
 FROM affected u LEFT JOIN stores s ON s.user_id=u.id LEFT JOIN brands b ON b.user_id=u.id LEFT JOIN entities e ON e.user_id=u.id WHERE a.id=u.auth_id;
 GET DIAGNOSTICS n=ROW_COUNT;
 RETURN n;
END $$;
DO $$ DECLARE d text; start_at integer; end_at integer; BEGIN
 d:=pg_get_functiondef('public.admin_close_store(uuid,text)'::regprocedure);
 d:=replace(d,'  SELECT * INTO v_store FROM public.restaurants', '  PERFORM pg_advisory_xact_lock(hashtextextended(''store-opening:''||p_store_id,0)); SELECT * INTO v_store FROM public.restaurants');
 start_at:=position('  FOR v_auth IN' IN d); end_at:=position('END LOOP;' IN d);
 IF start_at=0 OR end_at<start_at THEN RAISE EXCEPTION 'STORE_CLOSURE_BATCH_PATCH_MISMATCH'; END IF;
 d:=substring(d FROM 1 FOR start_at-1)||'  v_claims_refreshed:=public.store_refresh_closed_claims_v1(p_store_id);'||substring(d FROM end_at+length('END LOOP;')); EXECUTE d;
END $$;
CREATE OR REPLACE FUNCTION public.admin_deactivate_restaurant(p_store_id uuid) RETURNS public.stores
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result stores;
BEGIN
 PERFORM admin_close_store(p_store_id,'Closure through compatible deactivation entry point');
 SELECT * INTO result FROM stores WHERE id=p_store_id;
 RETURN result;
END $$;
CREATE FUNCTION public.store_guard_closed_procurement_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 PERFORM pg_advisory_xact_lock_shared(hashtextextended('store-opening:'||restaurant_id,0)) FROM (SELECT DISTINCT restaurant_id FROM new_procurement_intake ORDER BY restaurant_id)s;
 IF EXISTS(SELECT 1 FROM new_procurement_intake n JOIN restaurants r ON r.id=n.restaurant_id WHERE NOT r.is_active) THEN RAISE EXCEPTION 'STORE_CLOSED_FOR_NEW_PROCUREMENT'; END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER store_procurement_intake_requests AFTER INSERT ON public.inventory_purchase_requests REFERENCING NEW TABLE AS new_procurement_intake FOR EACH STATEMENT EXECUTE FUNCTION public.store_guard_closed_procurement_v1();
CREATE TRIGGER store_procurement_intake_orders AFTER INSERT ON public.inventory_purchase_orders REFERENCING NEW TABLE AS new_procurement_intake FOR EACH STATEMENT EXECUTE FUNCTION public.store_guard_closed_procurement_v1();
REVOKE ALL ON FUNCTION public.store_closure_pending_v1(uuid),public.store_guard_closure_v1(),public.store_refresh_closed_claims_v1(uuid),public.store_guard_closed_procurement_v1() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.admin_get_store_closure_readiness_v1(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_get_store_closure_readiness_v1(uuid) TO authenticated;
COMMIT;
