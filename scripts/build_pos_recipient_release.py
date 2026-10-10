#!/usr/bin/env python3
"""Build/check the reviewed production-only atomic bundle from canonical SQL."""
from pathlib import Path
import argparse
import hashlib
import re

ROOT = Path(__file__).resolve().parents[1]
COMPONENTS = ['20261010050000_direct_order_recipient_delivery.sql', '20261010051000_direct_order_recipient_receipts.sql', '20261010052000_direct_order_batch_refund_invoice.sql', '20261010053000_pos_buyer_information.sql', '20261010054000_pos_receipt_ledger.sql', '20261011010000_bounded_data_reads.sql', '20261011020000_employee_scoped_payroll.sql', '20261011030000_fixed_account_exact_lookup.sql', '20261011040000_report_summary_and_issue_pages.sql', '20261011050000_receipt_page_item_reads.sql', '20261011060000_emergency_push_batch_lease.sql', '20261011070000_inventory_dashboard_shared_stock.sql', '20261011080000_meinvoice_owned_batches.sql', '20261011090000_sepay_delivery_provider_scope.sql', '20261011100000_inventory_catalog_pages.sql', '20261011110000_table_preview_delta.sql', '20261011120000_recipe_export_pages.sql', '20261011130000_company_tax_lookup.sql']
OUTPUT = ROOT / "scripts/releases/20261011140000_pos_recipient_buyer_lookup_bounded_release.sql"

def build():
    result = (ROOT / "scripts/releases/pos_recipient_release_header.sql").read_text()
    for name in COMPONENTS:
        raw = (ROOT / "supabase/migrations" / name).read_bytes()
        source = raw.decode()
        # Strip only top-level standalone wrappers; PL/pgSQL BEGIN/END stay.
        source = re.sub(r"(?m)^BEGIN;\s*$|^COMMIT;\s*$", "", source)
        result += "-- COMPONENT " + name + " SHA256 " + hashlib.sha256(raw).hexdigest() + "\n" + source.rstrip() + "\n\n"
    return result + (ROOT / "scripts/releases/pos_recipient_release_footer.sql").read_text()

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    result = build()
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text() != result:
            raise SystemExit("Atomic release bundle is stale; run scripts/build_pos_recipient_release.py")
        print("POS_ATOMIC_RELEASE_BUNDLE=PASS components=" + str(len(COMPONENTS)))
    else:
        OUTPUT.write_text(result)
