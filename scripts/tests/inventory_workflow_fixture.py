"""Load canonical inventory DDL/functions into an isolated PostgreSQL fixture.
Only unrelated authentication/store tables are reduced fixtures. Business RPCs,
constraints, and policies are extracted from the checked-in migrations.
"""
from pathlib import Path
import re
import sys
root, output = map(Path, sys.argv[1:])
base = (root / 'supabase/migrations/20260506000000_inventory_purchase_office_contracts.sql').read_text()
approval = (root / 'supabase/migrations/20260827150000_inventory_purchase_approval_receiving_prices.sql').read_text()
attempts = (root / 'supabase/migrations/20260513010000_inventory_receiving_idempotency_observability.sql').read_text()
def function(source, name):
    match = re.search(r'CREATE OR REPLACE FUNCTION public\.' + name + r'\([\s\S]*?\n\$\$[^;]*;', source)
    assert match, name
    return match[0]
def table(source, name):
    match = re.search(r'CREATE TABLE IF NOT EXISTS public\.' + name + r' \([\s\S]*?\n\);', source)
    assert match, name
    return match[0]
parts = []
for name in ['inventory_suppliers', 'inventory_products', 'inventory_supplier_items', 'inventory_purchase_orders',
             'inventory_purchase_order_lines', 'inventory_receipts', 'inventory_receipt_lines']:
    parts.append(table(base, name))
parts.append(table(attempts, 'inventory_receipt_confirmation_attempts'))
parts.append(function(approval, 'inventory_purchase_actor_role'))
parts.append(function(approval, 'user_accessible_stores'))
parts.append(function(base, 'can_access_inventory_purchase_store'))
parts.append(approval[approval.index('ALTER TABLE public.inventory_purchase_orders\n  DROP CONSTRAINT'):approval.index('CREATE OR REPLACE FUNCTION public.inventory_purchase_actor_role')])
parts.append(function(approval, 'append_inventory_purchase_approval_event'))
parts.append(function(base, 'recalculate_inventory_purchase_order_totals'))
for name in ['inventory_products', 'inventory_suppliers', 'inventory_supplier_items', 'inventory_purchase_orders',
             'inventory_purchase_order_lines', 'inventory_receipts', 'inventory_receipt_lines']:
    parts.append(f'ALTER TABLE public.{name} ENABLE ROW LEVEL SECURITY;')
for policy in ['inventory_products_store_read','inventory_purchase_orders_store_read','inventory_purchase_order_lines_store_read',
               'inventory_receipts_store_read','inventory_receipt_lines_store_read','inventory_suppliers_scoped_read','inventory_supplier_items_scoped_read']:
    match = re.search(r'CREATE POLICY '+policy+r'\b[\s\S]*?;', base)
    assert match, policy
    parts.append(match[0])
# Historical permissive policy tests that restrictive master policies really close it.
parts.append('CREATE POLICY fixture_legacy_supplier_read ON public.inventory_supplier_items FOR SELECT TO authenticated USING (true);')
for file, name in [
    ('20260822150000_inventory_order_unit_conversion_sync.sql','upsert_inventory_supplier_item'),
    ('20260821120000_inventory_excel_supplier_creation.sql','bulk_upsert_inventory_ingredients'),
    ('20260506011000_inventory_cost_analysis.sql','get_inventory_cost_analysis'),
]:
    parts.append(function((root / 'supabase/migrations' / file).read_text(), name))
parts.append(function(approval, 'bulk_update_inventory_supplier_prices'))
for name in ['can_create_inventory_purchase_order', 'can_verify_inventory_receipt']:
    parts.append(function(approval, name))
for policy in ['inventory_purchase_document_objects_read', 'inventory_purchase_document_objects_write',
               'inventory_receipt_statement_objects_read', 'inventory_receipt_statement_objects_write']:
    match = re.search(r'CREATE POLICY '+policy+r'\b[\s\S]*?;', approval)
    assert match, policy
    parts.append(match[0])
parts.append((root / 'supabase/migrations/20260910120000_inventory_purchase_orderer_catalog_access.sql').read_text())
parts.append('GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated;')
parts.append('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;')
output.write_text('\n\n'.join(parts))
