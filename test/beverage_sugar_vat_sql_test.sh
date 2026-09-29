#!/usr/bin/env bash
set -euo pipefail
VAT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAT_TMP="$(mktemp -d)"
VAT_CONTAINER="globos-beverage-vat-test-$$"
cleanup() { docker rm -f "$VAT_CONTAINER" >/dev/null 2>&1 || true; rm -rf "$VAT_TMP"; }
trap cleanup EXIT
python3 - "$VAT_ROOT" "$VAT_TMP" <<'PY'
import sys,re
from pathlib import Path
root,tmp=map(Path,sys.argv[1:])
def extract(file,name):
 s=(root/'supabase/migrations'/file).read_text()
 start=re.search(r'CREATE (?:OR REPLACE )?FUNCTION public\.'+name+r'\(',s).start()
 return s[start:s.index('$$;',start)+3]+'\n'
out=''
for name in ['calculate_order_discountable_total','process_payment','enqueue_meinvoice_cash_register_job']:
 out+=extract('20260707010000_service_item_exclusion_v1.sql',name)
(tmp/'base.sql').write_text(out)
s=(root/'supabase/migrations/20260817110000_menu_scoped_promotion_integrity.sql').read_text()
a=s.index('ALTER FUNCTION public.process_payment(');b=s.index('-- Avoid promotion resync',a)
(tmp/'wrapper.sql').write_text(s[a:b])
out=''
for name in ['admin_create_menu_item_i18n_paperless','admin_update_menu_item_i18n_paperless']:
 out+=extract('20260815180000_paperless_menu_name_and_voice.sql',name)
for name in ['direct_order_staff_quote','direct_order_approve_payment']:
 out+=extract('20260821130000_direct_delivery_ordering.sql',name)
out+=extract('20260905090000_promotion_allocation_live_refresh.sql','sync_active_order_promotion')
out+=extract('20260721040000_red_invoice_intake_export.sql','upsert_red_invoice_intake')
out+='DROP FUNCTION public.get_restaurant_daily_sales_exports_by_tax_entity(date);\n'
out+=extract('20260904120000_restaurant_sales_report_ready_at_2200.sql','get_restaurant_daily_sales_exports_by_tax_entity')
types=sorted(set(re.findall(r'public\.([a-z_]+)%ROWTYPE',out)))
prefix='\n'.join(f'CREATE TABLE IF NOT EXISTS public.{name}(id uuid PRIMARY KEY);' for name in types)+'\n'
(tmp/'others.sql').write_text(prefix+out)
s=(root/'supabase/migrations/20260807180000_wet_tissue_price_2000.sql').read_text()
(tmp/'setter.sql').write_text(s[s.index('CREATE OR REPLACE FUNCTION'):s.rindex('COMMIT;')])
PY
docker run --detach --rm --name "$VAT_CONTAINER" --env POSTGRES_HOST_AUTH_METHOD=trust postgres:15 >/dev/null
for ((i=0;i<60;i++)); do
 if docker exec "$VAT_CONTAINER" psql -h 127.0.0.1 -U postgres -Atqc 'SELECT 1' >/dev/null 2>&1; then break; fi
 sleep 1
done
run_sql() { docker exec -i "$VAT_CONTAINER" psql -X -U postgres -v ON_ERROR_STOP=1 < "$1"; }
run_sql "$VAT_ROOT/test/fixtures/restaurant_vat_integrity_setup.sql" >/dev/null
run_sql "$VAT_ROOT/test/fixtures/beverage_sugar_vat_setup.sql" >/dev/null
run_sql "$VAT_TMP/base.sql" >/dev/null
run_sql "$VAT_ROOT/supabase/migrations/20260807190000_payment_discount_safe_update.sql" >/dev/null
run_sql "$VAT_TMP/wrapper.sql" >/dev/null
run_sql "$VAT_TMP/setter.sql" >/dev/null
run_sql "$VAT_TMP/others.sql" >/dev/null
run_sql "$VAT_ROOT/supabase/migrations/20260905150000_restaurant_vat_integrity.sql" >/dev/null
printf '%s\n' 'ALTER FUNCTION public.process_payment(uuid,uuid,numeric,text) RENAME TO process_payment_before_promotion_read_split;' > "$VAT_TMP/rename.sql"
run_sql "$VAT_TMP/rename.sql" >/dev/null
run_sql "$VAT_ROOT/scripts/preflight_beverage_sugar_vat.sql" >/dev/null
run_sql "$VAT_ROOT/supabase/migrations/20260929010000_beverage_sugar_vat.sql" >/dev/null
run_sql "$VAT_ROOT/scripts/verify_beverage_sugar_vat.sql" >/dev/null
run_sql "$VAT_ROOT/supabase/tests/beverage_sugar_vat_test.sql"
run_sql "$VAT_ROOT/test/fixtures/bunsik_beverage_vat_setup.sql" >/dev/null
run_sql "$VAT_ROOT/scripts/preflight_bunsik_beverage_vat.sql" >/dev/null
run_sql "$VAT_ROOT/supabase/migrations/20260929020000_bunsik_beverage_vat.sql" >/dev/null
run_sql "$VAT_ROOT/scripts/verify_bunsik_beverage_vat.sql" >/dev/null
run_sql "$VAT_ROOT/test/fixtures/bunsik_beverage_vat_assertions.sql" >/dev/null
run_sql "$VAT_ROOT/scripts/rollback_bunsik_beverage_vat.sql" >/dev/null
run_sql "$VAT_ROOT/scripts/rollback_beverage_sugar_vat.sql" >/dev/null
printf 'BEVERAGE_SUGAR_VAT_SQL_TEST=PASS\n'
