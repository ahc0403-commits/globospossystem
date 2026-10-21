-- Old clients must retain all bounded evidence rows; only clients explicitly
-- advertising the 50-row protocol may receive cursor pages.
BEGIN;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
DO $$ DECLARE shop uuid:='8bc9eef5-dcd5-46b1-b931-23f77132322c'; legacy jsonb; first_page jsonb; second_page jsonb; expected integer;
BEGIN
 WITH items AS(INSERT INTO inventory_items(restaurant_id,name,unit,current_stock)
 SELECT shop,'Compatibility item '||n,'g',0 FROM generate_series(1,61)n RETURNING id,name)
 INSERT INTO inventory_products(restaurant_id,brand_id,inventory_item_id,product_code,name,stock_unit,base_unit,base_unit_factor,specification)
 SELECT shop,'91000000-0000-4000-8000-000000000003',id,'COMPAT-'||split_part(name,' ',3),name,'g','g',1,'Isolated client protocol fixture' FROM items;
 SELECT count(*) INTO expected FROM inventory_products WHERE restaurant_id=shop AND is_active AND is_orderable AND receipt_classification='stock';
 ASSERT expected>50 AND expected<=2000;
 legacy:=procurement_workspace_page(shop,'{"include_evidence":true}');
 ASSERT jsonb_array_length(legacy->'demand')=expected,'legacy client lost evidence beyond first page';
 ASSERT NOT (legacy?'demand_next_cursor'),'legacy response silently changed to cursor protocol';
 first_page:=procurement_workspace_page(shop,'{"include_evidence":true,"demand_page_size":50}');
 ASSERT jsonb_array_length(first_page->'demand')=50 AND first_page->>'demand_next_cursor' IS NOT NULL;
 second_page:=procurement_workspace_page(shop,jsonb_build_object('include_evidence',true,'demand_page_size',50,'demand_after',first_page->>'demand_next_cursor'));
 ASSERT jsonb_array_length(second_page->'demand')=expected-50;
 ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(first_page->'demand')a JOIN jsonb_array_elements(second_page->'demand')b ON a->>'product_id'=b->>'product_id'),'cursor duplicated products';
 ASSERT jsonb_array_length(procurement_workspace_page(shop,'{"include_evidence":true}')->'demand')=expected,'new client changed the legacy protocol';
END $$;
SELECT 'DEMAND_CLIENT_COMPAT=PASS legacy full bounded evidence; explicit 50-row client, complete cursor coverage, no duplicates';
ROLLBACK;
