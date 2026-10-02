"""Use real inventory DDL and RPCs in a disposable database."""
from pathlib import Path
import re
import sys
root, output = map(Path, sys.argv[1:])
migrations = root / 'supabase/migrations'
base = (migrations / '20260506000000_inventory_purchase_office_contracts.sql').read_text()
def function(source, name):
    match = re.search(r'CREATE OR REPLACE FUNCTION public\.' + name + r'\([\s\S]*?\n\$\$[^;]*;', source)
    assert match, name
    return match[0]
parts = [(root / 'test/fixtures/inventory_workflow_setup.sql').read_text(), '''
ALTER TABLE inventory_items ADD COLUMN name text, ADD COLUMN unit text,
 ADD COLUMN cost_per_unit numeric DEFAULT 0, ADD COLUMN supplier_name text,
 ADD COLUMN is_active boolean DEFAULT true;
ALTER TABLE inventory_items ALTER COLUMN id SET DEFAULT gen_random_uuid();
''']
for name in ['inventory_suppliers', 'inventory_products', 'inventory_supplier_items']:
    match = re.search(r'CREATE TABLE IF NOT EXISTS public\.' + name + r' \([\s\S]*?\n\);', base)
    assert match, name
    parts.append(match[0])
for file, names in [
 ('20260827150000_inventory_purchase_approval_receiving_prices.sql', ['user_accessible_stores']),
 ('20260910120000_inventory_purchase_orderer_catalog_access.sql', ['can_access_inventory_purchase_store']),
 ('20260822150000_inventory_order_unit_conversion_sync.sql', ['upsert_inventory_supplier_item']),
 ('20260506008000_inventory_product_management.sql', ['upsert_inventory_product']),
 ('20260728005705_inventory_ingredient_supplier_link.sql', ['upsert_inventory_product_with_supplier']),
]:
    source = (migrations / file).read_text()
    parts.extend(function(source, name) for name in names)
output.write_text('\n\n'.join(parts))
