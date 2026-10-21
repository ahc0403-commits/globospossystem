-- Isolated rollback fixture: 100 stores x 2,000 products, one bounded 100-store
-- readiness RPC and 50-row demand pages. No business values are provisioned.
BEGIN;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
CREATE TEMP TABLE scale_stores(id uuid PRIMARY KEY);
INSERT INTO scale_stores SELECT gen_random_uuid() FROM generate_series(1,100);
INSERT INTO restaurants(id,name,slug,brand_id,tax_entity_id)
SELECT id,'Scale branch '||row_number() OVER(),'scale-'||id,'91000000-0000-4000-8000-000000000003','91000000-0000-4000-8000-000000000004' FROM scale_stores;
CREATE TEMP TABLE scale_products(id uuid PRIMARY KEY,store uuid,n integer);
INSERT INTO scale_products SELECT gen_random_uuid(),s.id,n FROM scale_stores s CROSS JOIN generate_series(1,2000)n;
INSERT INTO inventory_items(id,restaurant_id,name,unit,current_stock) SELECT id,store,'Scale item '||n,'g',0 FROM scale_products;
INSERT INTO inventory_products(id,restaurant_id,brand_id,inventory_item_id,product_code,name,stock_unit,base_unit,base_unit_factor,specification)
SELECT id,store,'91000000-0000-4000-8000-000000000003',id,'SCALE-'||n,'Scale product '||n,'g','g',1,'Performance fixture only' FROM scale_products;
ANALYZE restaurants; ANALYZE inventory_products; ANALYZE inventory_items;
CREATE TEMP TABLE scale_samples(kind text,elapsed_ms numeric,bytes integer,rows integer);
DO $$ DECLARE ids uuid[]; shop uuid; result jsonb; started timestamptz; i integer;
BEGIN
 SELECT array_agg(id ORDER BY id) INTO ids FROM scale_stores; shop:=ids[1];
 FOR i IN 1..10 LOOP
  started:=clock_timestamp(); result:=store_procurement_readiness_v1(ids);
  INSERT INTO scale_samples VALUES('readiness_100_stores_200000_products',extract(epoch FROM clock_timestamp()-started)*1000,octet_length(result::text),jsonb_array_length(result));
  ASSERT jsonb_array_length(result)=100;
  started:=clock_timestamp(); result:=procurement_demand_page_v1(shop);
  INSERT INTO scale_samples VALUES('demand_50_of_2000',extract(epoch FROM clock_timestamp()-started)*1000,octet_length(result::text),jsonb_array_length(result->'demand'));
  ASSERT jsonb_array_length(result->'demand')=50 AND result->>'demand_next_cursor' IS NOT NULL;
  started:=clock_timestamp(); result:=inventory_lot_workspace_v1(shop);
  INSERT INTO scale_samples VALUES('lot_workspace_empty_2000_items',extract(epoch FROM clock_timestamp()-started)*1000,octet_length(result::text),jsonb_array_length(result->'lots'));
 END LOOP;
END $$;
SELECT kind,count(*) samples,round(percentile_cont(0.5) WITHIN GROUP(ORDER BY elapsed_ms)::numeric,2) p50_ms,round(percentile_cont(0.95) WITHIN GROUP(ORDER BY elapsed_ms)::numeric,2) p95_ms,max(bytes) max_response_bytes,max(rows) max_rows FROM scale_samples GROUP BY kind ORDER BY kind;
EXPLAIN (ANALYZE,BUFFERS) SELECT id FROM inventory_products WHERE restaurant_id=(SELECT min(id::text)::uuid FROM scale_stores) AND is_active AND is_orderable AND receipt_classification='stock' ORDER BY id LIMIT 51;
ROLLBACK;
