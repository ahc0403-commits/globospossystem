"""Use canonical fixed-account DDL/checks in the isolated procurement DB."""
from pathlib import Path
import re
import sys

root, output = map(Path, sys.argv[1:])
migrations = root / 'supabase/migrations'
workforce = (migrations / '20260717170000_workforce_fixed_accounts.sql').read_text()
approval = (migrations / '20260827150000_inventory_purchase_approval_receiving_prices.sql').read_text()
security = (migrations / '300_security_remediation_minimal.sql').read_text()
parts = [
    'ALTER TABLE public.restaurants ADD COLUMN short_code text;',
    'ALTER TABLE public.users ADD COLUMN fixed_account_code text, ADD COLUMN account_type text;',
    'CREATE TABLE public.tax_entity(id uuid PRIMARY KEY);',
]
for source, name in [(workforce, 'store_fixed_account_requirements'),
                     (approval, 'legal_entity_fixed_account_requirements')]:
    match = re.search(r'CREATE TABLE IF NOT EXISTS public\.' + name + r' \([\s\S]*?\n\);', source)
    assert match, name
    parts.append(match[0])
start = approval.index('ALTER TABLE public.store_fixed_account_requirements\n  DROP CONSTRAINT')
end = approval.index('ALTER TABLE public.user_tax_entity_access ENABLE ROW LEVEL SECURITY', start)
parts.append(approval[start:end])
match = re.search(r'CREATE OR REPLACE FUNCTION public\.is_super_admin\([\s\S]*?\n\$\$;', security)
assert match
parts.append(match[0])
output.write_text('\n\n'.join(parts))
