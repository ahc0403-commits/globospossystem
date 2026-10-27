#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
late_db="pos-late-invoice-test-$$"
late_tmp="$(mktemp -d)"
cleanup() { docker rm -f "$late_db" >/dev/null 2>&1 || true; rm -rf "$late_tmp"; }
trap cleanup EXIT
python3 - "$late_tmp/predecessor.sql" <<'PY'
from pathlib import Path
import re,sys
root=Path('supabase/migrations')
def function(file,name):
    s=(root/file).read_text()
    match=re.search(r'CREATE (?:OR REPLACE )?FUNCTION public\.'+name+r'\(',s,re.I)
    if not match: raise RuntimeError(name)
    return s[match.start():s.index('$$;',match.start())+3]+'\n'
s=(root/'20260721040000_red_invoice_intake_export.sql').read_text()
start=s.index('CREATE TABLE IF NOT EXISTS public.red_invoice_intakes')
out=s[start:s.index('\n);',start)+4]+'\n'
for file,name in [
 ('20260929010000_beverage_sugar_vat.sql','order_item_invoice_tax_lines'),
 ('20260721040000_red_invoice_intake_export.sql','upsert_red_invoice_intake'),
 ('20260816180000_red_invoice_contact_fields.sql','upsert_red_invoice_intake_minimal'),
 ('20261010052000_direct_order_batch_refund_invoice.sql','direct_order_sync_invoice_batch'),
 ('20261011203000_invoice_contacts_payment_methods.sql','preserve_meinvoice_export_snapshot'),
 ('20261011050000_receipt_page_item_reads.sql','get_receipt_ledger_page'),
]: out+=function(file,name)
out+='CREATE TRIGGER preserve_meinvoice_export_snapshot BEFORE UPDATE ON public.meinvoice_jobs FOR EACH ROW EXECUTE FUNCTION public.preserve_meinvoice_export_snapshot();\n'
Path(sys.argv[1]).write_text(out)
PY
docker run --detach --rm --name "$late_db" --env POSTGRES_PASSWORD=fixture-only --env POSTGRES_DB=late_invoice postgres:17-alpine -c track_functions=all >/dev/null
for attempt in {1..60}; do
 # The image briefly starts a temporary server during initialization. Wait for
 # that server to stop and the final server to become ready before running SQL.
 if docker logs "$late_db" 2>&1 | grep -Fq 'PostgreSQL init process complete; ready for start up.' &&
    docker exec "$late_db" pg_isready -U postgres -d late_invoice >/dev/null 2>&1; then break; fi
 if [[ "$attempt" == 60 ]]; then exit 1; fi
 sleep 1
done
sql() { docker exec -i "$late_db" psql -X -v ON_ERROR_STOP=1 -U postgres -d late_invoice "$@"; }
sql < test/fixtures/late_invoice_setup.sql >/dev/null
sql < "$late_tmp/predecessor.sql" >/dev/null
sql < supabase/migrations/20261010053000_pos_buyer_information.sql >/dev/null
sql < supabase/migrations/20261024220000_pos_late_red_invoice.sql >/dev/null
sql < test/sql/late_invoice_test.sql
sql < test/sql/late_invoice_performance.sql
sql -c 'SELECT pg_stat_force_next_flush();' >/dev/null
late_batch_calls="$(sql -Atqc "SELECT calls FROM pg_stat_user_functions WHERE funcname='capture_meinvoice_export_snapshots_batch';")"
[[ "$late_batch_calls" == "1" ]] || { printf 'LATE_INVOICE_ARCHIVE_BATCH_CALLS=%s\n' "$late_batch_calls"; exit 1; }
late_context_calls="$(sql -Atqc "SELECT calls FROM pg_stat_user_functions WHERE funcname='pos_late_invoice_context';")"
[[ "$late_context_calls" == "3" ]] || { printf 'LATE_INVOICE_CONTEXT_CALLS=%s\n' "$late_context_calls"; exit 1; }
printf 'LATE_INVOICE_WRITE_BATCH orders=50 archive_statements=%s context_calls=%s\n' "$late_batch_calls" "$late_context_calls"
python3 scripts/tests/late_invoice_concurrency.py "$late_db"
printf 'LATE_INVOICE_SQL_TEST=PASS\n'
