#!/usr/bin/env python3
"""Build the atomic corporate-account, sales-report and invoice-contact release."""
import argparse
import hashlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMPONENTS = [
    '20261011200000_corporate_collection_accounts.sql',
    '20261011201000_invoice_ledger_export_contract.sql',
    '20261011202000_sales_reporting_pages.sql',
    '20261011203000_invoice_contacts_payment_methods.sql',
]
OUTPUT = ROOT / 'scripts/releases/20261011204000_corporate_sales_invoice_contacts_release.sql'


def build():
    result = (ROOT / 'scripts/releases/pos_corporate_sales_release_header.sql').read_text()
    result += (ROOT / 'scripts/preflight_corporate_sales_invoice_contacts_release.sql').read_text() + '\n'
    for name in COMPONENTS:
        raw = (ROOT / 'supabase/migrations' / name).read_bytes()
        source = re.sub(r'(?m)^BEGIN;\s*$|^COMMIT;\s*$', '', raw.decode())
        result += f'-- COMPONENT {name} SHA256 {hashlib.sha256(raw).hexdigest()}\n{source.rstrip()}\n\n'
    return result + (ROOT / 'scripts/releases/pos_corporate_sales_release_footer.sql').read_text()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    expected = build()
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text() != expected:
            raise SystemExit('Corporate release bundle is stale; run scripts/build_pos_corporate_sales_release.py')
        if (ROOT / 'scripts/preflight_corporate_sales_invoice_contacts_release.sql').read_text() not in expected:
            raise SystemExit('Corporate release preflight differs from the atomic bundle')
        print('CORPORATE_ATOMIC_RELEASE_BUNDLE=PASS components=4')
    else:
        OUTPUT.write_text(expected)
