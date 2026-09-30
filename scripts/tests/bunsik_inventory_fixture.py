"""Canonical inventory tables in isolated Postgres; unrelated dependencies are reduced."""
from pathlib import Path
import csv,re,sys
root,output=map(Path,sys.argv[1:]);migrations=root/'supabase/migrations'
base=(migrations/'20260506000000_inventory_purchase_office_contracts.sql').read_text()
approval=(migrations/'20260827150000_inventory_purchase_approval_receiving_prices.sql').read_text()
receipt_guard=(migrations/'20260927010000_inventory_receipt_submission_lock_audit.sql').read_text()
def table(text,name):
 match=re.search(r'CREATE TABLE IF NOT EXISTS public\.'+name+r' \([\s\S]*?\n\);',text)
 assert match,name
 return match[0]
def function(text,name):
 match=re.search(r'CREATE OR REPLACE FUNCTION public\.'+name+r'\([\s\S]*?\n\$\$[^;]*;',text)
 assert match,name
 return match[0]
parts=[(root/'test/fixtures/inventory_workflow_setup.sql').read_text(),"""
ALTER TABLE public.inventory_items ADD COLUMN name text, ADD COLUMN unit text, ADD COLUMN created_at timestamptz DEFAULT now(), ADD COLUMN cost_per_unit numeric DEFAULT 0, ADD COLUMN supplier_name text, ADD COLUMN is_active boolean DEFAULT true;
ALTER TABLE public.inventory_items ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE public.inventory_items ALTER COLUMN updated_at SET DEFAULT now();
"""]
for name in ['inventory_suppliers','inventory_products','inventory_supplier_items','inventory_purchase_orders','inventory_purchase_order_lines','inventory_receipts','inventory_receipt_lines','inventory_daily_consumption','inventory_recommendation_runs','inventory_recommendation_lines','inventory_stock_audit_sessions','inventory_stock_audit_lines']:
 parts.append(table(base,name))
parts.append("ALTER TABLE public.inventory_supplier_items ADD COLUMN allows_fractional_quantity boolean GENERATED ALWAYS AS (order_unit IN ('kg','g','l','ml')) STORED;")
parts.append("ALTER TABLE public.inventory_receipts ADD COLUMN submitted_at timestamptz;")
for name in ['inventory_supplier_item_price_history','inventory_purchase_approval_events','inventory_purchase_documents']:
 parts.append(table(approval,name))
parts += [function(approval,'capture_inventory_supplier_price_history'),"CREATE TRIGGER inventory_supplier_item_price_history_trigger AFTER INSERT OR UPDATE OF unit_price,tax_rate ON public.inventory_supplier_items FOR EACH ROW EXECUTE FUNCTION public.capture_inventory_supplier_price_history();"]
# These empty sample dependencies only need their real FK edges to exercise reset ordering.
parts.append("""
CREATE TABLE public.inventory_receipt_confirmation_attempts(id uuid DEFAULT gen_random_uuid(),purchase_order_id uuid REFERENCES public.inventory_purchase_orders(id),receipt_id uuid REFERENCES public.inventory_receipts(id));
CREATE TABLE public.inventory_receipt_submission_attempts(receipt_id uuid REFERENCES public.inventory_receipts(id),attempt_key text);
CREATE TABLE public.inventory_receipt_issues(id uuid DEFAULT gen_random_uuid(),restaurant_id uuid,receipt_line_id uuid REFERENCES public.inventory_receipt_lines(id),purchase_order_id uuid REFERENCES public.inventory_purchase_orders(id));
CREATE TABLE public.inventory_supplier_returns(id uuid DEFAULT gen_random_uuid(),restaurant_id uuid,receipt_line_id uuid REFERENCES public.inventory_receipt_lines(id),purchase_order_id uuid REFERENCES public.inventory_purchase_orders(id));
CREATE TABLE public.inventory_purchase_request_lines(id uuid,product_id uuid REFERENCES public.inventory_products(id));
CREATE TABLE public.procurement_quote_lines(id uuid,supplier_item_id uuid REFERENCES public.inventory_supplier_items(id));
CREATE TABLE public.menu_recipes(id uuid,ingredient_id uuid REFERENCES public.inventory_items(id) ON DELETE CASCADE);
CREATE TABLE public.inventory_physical_counts(id uuid,ingredient_id uuid REFERENCES public.inventory_items(id) ON DELETE CASCADE);
""")
parts.append(receipt_guard[receipt_guard.index('CREATE TABLE public.inventory_receipt_change_history'):receipt_guard.index('CREATE INDEX inventory_receipt_change_history_receipt_time')])
parts.append("""
CREATE FUNCTION public.can_access_inventory_purchase_store(p_store_id uuid) RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT COALESCE(auth.role(),'')='service_role' OR EXISTS(SELECT 1 FROM public.users WHERE auth_id=auth.uid() AND restaurant_id=p_store_id AND is_active) $$;
CREATE FUNCTION public.can_verify_inventory_receipt(p_store_id uuid) RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT false $$;
INSERT INTO public.brands VALUES('a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878');
INSERT INTO public.restaurants(id,brand_id,name) VALUES('8bc9eef5-dcd5-46b1-b931-23f77132322c','a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878','BunsikClub Binh Thanh'),('3a268807-771f-4fd4-84fe-e1b0b00de40a','a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878','BunsikClub SAMPLE');
SET request.jwt.claim.role='service_role';
""")
q=lambda s:"'"+s.replace("'","''")+"'"
rows=list(csv.DictReader((root/'docs/plans/bunsik-inventory-20260930/code_mapping_123.csv').open(encoding='utf-8-sig')))
# Deterministic source IDs from workbook matching, changing stocks to prove preservation.
for r in rows:
 if not r['product_id']:continue
 parts.append(f"INSERT INTO public.inventory_items(id,restaurant_id,name,quantity,current_stock,unit,updated_at,cost_per_unit) VALUES({q(r['inventory_item_id'])},'8bc9eef5-dcd5-46b1-b931-23f77132322c',{q(r['name'])},123.5,123.5,{q(r['db_base_unit'])},'2026-09-30T00:00:00Z',5);")
 parts.append(f"INSERT INTO public.inventory_products(id,restaurant_id,brand_id,inventory_item_id,product_code,name,stock_unit,base_unit,base_unit_factor) VALUES({q(r['product_id'])},'8bc9eef5-dcd5-46b1-b931-23f77132322c','a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878',{q(r['inventory_item_id'])},{q(r['old_code'])},{q(r['name'])},{q(r['db_stock_unit'])},{q(r['db_base_unit'])},{r['db_base_factor']});")
 for sid in r['db_supplier_ids'].split(' / '):
  parts.append(f"INSERT INTO public.inventory_suppliers(id,brand_id,supplier_name) VALUES({q(sid)},'a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878',{q(sid)}) ON CONFLICT DO NOTHING;")
  parts.append(f"INSERT INTO public.inventory_supplier_items(supplier_id,product_id,order_unit,order_unit_quantity_base,unit_price,is_preferred) VALUES({q(sid)},{q(r['product_id'])},'box',{r['db_base_factor']},1000,true);")
parts.append("""
CREATE TEMP TABLE seed_clone AS SELECT id product_id,inventory_item_id item_id,gen_random_uuid() sample_product,gen_random_uuid() sample_item FROM public.inventory_products;
INSERT INTO public.inventory_items(id,restaurant_id,name,quantity,current_stock,unit) SELECT c.sample_item,'3a268807-771f-4fd4-84fe-e1b0b00de40a',i.name,17,17,i.unit FROM seed_clone c JOIN public.inventory_items i ON i.id=c.item_id;
INSERT INTO public.inventory_products(id,restaurant_id,brand_id,inventory_item_id,product_code,name,stock_unit,base_unit,base_unit_factor) SELECT c.sample_product,'3a268807-771f-4fd4-84fe-e1b0b00de40a',p.brand_id,c.sample_item,p.product_code,p.name,p.stock_unit,p.base_unit,p.base_unit_factor FROM seed_clone c JOIN public.inventory_products p ON p.id=c.product_id;
INSERT INTO public.inventory_supplier_items(supplier_id,product_id,order_unit,order_unit_quantity_base,unit_price) SELECT s.supplier_id,c.sample_product,s.order_unit,s.order_unit_quantity_base,s.unit_price FROM seed_clone c JOIN public.inventory_supplier_items s ON s.product_id=c.product_id;
INSERT INTO public.inventory_purchase_orders(id,purchase_order_no,restaurant_id,supplier_id) SELECT test_uuid(1),'SAMPLE-OLD','3a268807-771f-4fd4-84fe-e1b0b00de40a',id FROM public.inventory_suppliers LIMIT 1;
INSERT INTO public.inventory_purchase_order_lines(purchase_order_id,product_id,supplier_item_id,ordered_quantity_unit,ordered_quantity_base,order_unit,unit_price) SELECT test_uuid(1),p.id,s.id,1,1000,'box',1000 FROM public.inventory_products p JOIN public.inventory_supplier_items s ON s.product_id=p.id WHERE p.restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a' LIMIT 1;
""")
parts.append("""
INSERT INTO public.inventory_receipts(id,purchase_order_id,restaurant_id,supplier_id) SELECT test_uuid(2),test_uuid(1),'3a268807-771f-4fd4-84fe-e1b0b00de40a',supplier_id FROM public.inventory_purchase_orders WHERE id=test_uuid(1);
INSERT INTO public.inventory_receipt_lines(id,receipt_id,purchase_order_line_id,product_id,received_quantity_base) SELECT test_uuid(3),test_uuid(2),id,product_id,100 FROM public.inventory_purchase_order_lines WHERE purchase_order_id=test_uuid(1);
INSERT INTO public.inventory_receipt_confirmation_attempts(purchase_order_id,receipt_id) VALUES(test_uuid(1),test_uuid(2));
INSERT INTO public.inventory_receipt_submission_attempts VALUES(test_uuid(2),'old-attempt');
INSERT INTO public.inventory_receipt_change_history(receipt_id,record_type,record_id,action) VALUES(test_uuid(2),'receipt',test_uuid(2),'update');
INSERT INTO public.inventory_receipt_issues(restaurant_id,receipt_line_id,purchase_order_id) VALUES('3a268807-771f-4fd4-84fe-e1b0b00de40a',test_uuid(3),test_uuid(1));
INSERT INTO public.inventory_supplier_returns(restaurant_id,receipt_line_id,purchase_order_id) VALUES('3a268807-771f-4fd4-84fe-e1b0b00de40a',test_uuid(3),test_uuid(1));
UPDATE public.inventory_items SET current_stock=-5 WHERE id=(SELECT inventory_item_id FROM public.inventory_products WHERE restaurant_id='8bc9eef5-dcd5-46b1-b931-23f77132322c' ORDER BY product_code LIMIT 1);
UPDATE public.inventory_receipts SET submitted_at=now() WHERE id=test_uuid(2);
INSERT INTO public.inventory_receipts(id,purchase_order_id,restaurant_id,supplier_id,status,submitted_at) SELECT test_uuid(4),test_uuid(1),'3a268807-771f-4fd4-84fe-e1b0b00de40a',supplier_id,'confirmed',now() FROM public.inventory_purchase_orders WHERE id=test_uuid(1);
INSERT INTO public.inventory_receipt_lines(id,receipt_id,product_id,received_quantity_base) SELECT test_uuid(5),test_uuid(4),id,100 FROM public.inventory_products WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a' LIMIT 1;
INSERT INTO public.inventory_purchase_orders(id,purchase_order_no,restaurant_id,supplier_id) SELECT test_uuid(6),'BINH-KEEP','8bc9eef5-dcd5-46b1-b931-23f77132322c',id FROM public.inventory_suppliers LIMIT 1;
INSERT INTO public.inventory_receipts(id,purchase_order_id,restaurant_id,supplier_id,status,submitted_at) SELECT test_uuid(7),test_uuid(6),'8bc9eef5-dcd5-46b1-b931-23f77132322c',supplier_id,'confirmed',now() FROM public.inventory_purchase_orders WHERE id=test_uuid(6);
INSERT INTO public.inventory_receipt_lines(id,receipt_id,product_id,received_quantity_base) SELECT test_uuid(8),test_uuid(7),id,100 FROM public.inventory_products WHERE restaurant_id='8bc9eef5-dcd5-46b1-b931-23f77132322c' LIMIT 1;
""")
# Install the production guards after seed creation, including immutable
# confirmed and locked submitted receipts. Reset/rollback must handle both.
parts.append(receipt_guard[receipt_guard.index('CREATE FUNCTION public.guard_inventory_receipt_header_change'):receipt_guard.index('REVOKE ALL ON FUNCTION public.guard_inventory_receipt_header_change')])
output.write_text('\n\n'.join(parts))
