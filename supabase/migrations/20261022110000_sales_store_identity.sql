-- Capture future sale identities without inventing names for historical sales.
-- Physical restaurants / restaurant_id and MISA financial snapshots stay intact.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.store_sale_identities (
 order_id uuid PRIMARY KEY REFERENCES public.orders(id) ON DELETE CASCADE,
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
 store_code text,store_name text NOT NULL,
 brand_id uuid,tax_entity_id uuid,
 captured_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX store_sale_identities_store ON public.store_sale_identities(restaurant_id,order_id);
ALTER TABLE public.store_sale_identities ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.store_sale_identities FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.store_capture_sale_identity_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 INSERT INTO store_sale_identities(order_id,restaurant_id,store_code,store_name,brand_id,tax_entity_id)
 SELECT n.id,r.id,r.short_code,r.name,r.brand_id,r.tax_entity_id FROM new_sale_orders n JOIN restaurants r ON r.id=n.restaurant_id;
 RETURN NULL;
END $$;
CREATE TRIGGER store_capture_sale_identity AFTER INSERT ON public.orders REFERENCING NEW TABLE AS new_sale_orders
 FOR EACH STATEMENT EXECUTE FUNCTION public.store_capture_sale_identity_v1();
CREATE TRIGGER store_sale_identity_immutable BEFORE UPDATE ON public.store_sale_identities FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
REVOKE ALL ON FUNCTION public.store_capture_sale_identity_v1() FROM PUBLIC,anon,authenticated,service_role;

DO $$ DECLARE definition text; BEGIN
 definition:=pg_get_functiondef('public.pos_restaurant_receipt_rows_v2(date,uuid[])'::regprocedure);
 IF position('restaurant.name AS store_name' IN definition)=0 OR position('JOIN public.restaurants restaurant ON restaurant.id = paid.store_id' IN definition)=0 THEN RAISE EXCEPTION 'SALE_IDENTITY_SOURCE_PATCH_MISMATCH'; END IF;
 definition:=replace(definition,'restaurant.name AS store_name','coalesce(sale_identity.store_name,restaurant.name) AS store_name');
 definition:=replace(definition,'JOIN public.restaurants restaurant ON restaurant.id = paid.store_id',
 'JOIN public.restaurants restaurant ON restaurant.id = paid.store_id LEFT JOIN public.store_sale_identities sale_identity ON sale_identity.order_id=paid.order_id');
 EXECUTE definition;
 definition:=pg_get_functiondef('public.get_pos_daily_sales_export_page(date,uuid,text,timestamptz,text,integer)'::regprocedure);
 IF position('jsonb_agg(to_jsonb(r) ORDER BY r.sold_at,r.receipt_id)' IN definition)=0 THEN RAISE EXCEPTION 'SALE_IDENTITY_PAGE_PATCH_MISMATCH'; END IF;
 definition:=replace(definition,'jsonb_agg(to_jsonb(r) ORDER BY r.sold_at,r.receipt_id)',
 'jsonb_agg(to_jsonb(r)||jsonb_build_object(''store_code'',CASE WHEN si.order_id IS NULL THEN shop.short_code ELSE si.store_code END,''store_name_origin'',CASE WHEN si.order_id IS NULL THEN ''current_registry'' ELSE ''order_snapshot'' END) ORDER BY r.sold_at,r.receipt_id)');
 definition:=replace(definition,')) r WHERE r.tax_entity_id=p_tax_entity_id;',
 ')) r LEFT JOIN public.store_sale_identities si ON si.order_id=r.receipt_id::uuid LEFT JOIN public.restaurants shop ON shop.id=r.store_id WHERE r.tax_entity_id=p_tax_entity_id;');
 IF position('si.order_id=r.receipt_id::uuid' IN definition)=0 THEN RAISE EXCEPTION 'SALE_IDENTITY_PAGE_JOIN_MISMATCH'; END IF;
 EXECUTE definition;
END $$;
COMMIT;
