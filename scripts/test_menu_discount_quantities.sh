#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_name="pos-menu-discount-quantity-$$"
fixture_tmp="$(mktemp -d)"
cleanup() { docker rm -f "$fixture_name" >/dev/null 2>&1 || true; rm -rf "$fixture_tmp"; }
trap cleanup EXIT
# Isolated PostgreSQL 17 fixture; no application/production connection.
docker run --detach --rm --network none --name "$fixture_name" --env POSTGRES_HOST_AUTH_METHOD=trust \
 --env POSTGRES_DB=promotion_test postgres:17.6 >/dev/null
for attempt in $(seq 1 60); do
 if docker exec "$fixture_name" pg_isready -h 127.0.0.1 -U postgres -d promotion_test >/dev/null 2>&1; then break; fi
 if [[ "$attempt" == 60 ]]; then exit 1; fi
 sleep 1
done
run_sql() { docker exec -i "$fixture_name" psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -U postgres -d promotion_test "$@"; }
run_sql < test/fixtures/menu_discount_quantities_setup.sql >/dev/null
python3 - "$fixture_tmp/predecessor.sql" <<'PYFIXTURE'
from pathlib import Path
import re,sys
parts=[]
def function(path,name):
 s=Path(path).read_text()
 m=re.search(r'CREATE (?:OR REPLACE )?FUNCTION (?:public\.'+re.escape(name)+r'|"public"\."'+re.escape(name)+r'")\(',s)
 if not m: raise ValueError(name)
 tag=re.search(r'AS (\$[a-zA-Z_]*\$)',s[m.start():]).group(1)
 end=s.index(tag+';',s.index(tag,m.start())+len(tag))+len(tag)+1
 return s[m.start():end]
s=Path('supabase/migrations/20260706010000_discount_staff_meal_v1_schema.sql').read_text()
parts.append(s[s.index('CREATE TABLE IF NOT EXISTS public.order_discounts ('):s.index('GRANT ALL ON public.order_discounts TO service_role;')+len('GRANT ALL ON public.order_discounts TO service_role;')])
s=Path('supabase/migrations/20260804010000_scheduled_closing_and_promotions.sql').read_text()
parts.append(s[s.index('CREATE TABLE IF NOT EXISTS public.store_promotions ('):s.index('GRANT ALL ON public.store_promotions TO service_role;')+len('GRANT ALL ON public.store_promotions TO service_role;')])
for n in ['refresh_store_order_promotions','trg_sync_order_promotion','void_active_order_discount_for_item_change']:
 parts.append(function('supabase/migrations/20260804010000_scheduled_closing_and_promotions.sql',n))
parts.append(Path('supabase/migrations/20260817110000_menu_scoped_promotion_integrity.sql').read_text())
parts.append(function('supabase/migrations/20260905090000_promotion_allocation_live_refresh.sql','sync_active_order_promotion'))
parts.append(function('supabase/migrations/20260916130000_qr_menu_category_auto_sync.sql','qr_get_menu'))
for n in ['allocate_vat_cents','calculate_item_vat']:
 parts.append(function('supabase/migrations/20260929010000_beverage_sugar_vat.sql',n))
for n in ['direct_order_combo_vnd_vat','direct_order_payment_vat']:
 parts.append(function('supabase/migrations/20261013030000_direct_order_combo_ordering.sql',n))
parts.append(function('supabase/migrations/20260805090000_pos_live_events_all_domains.sql','emit_pos_live_event'))
parts.append(function('supabase/migrations/20261021181000_menu_choice_intake.sql','validate_menu_option_batch'))
parts.append("CREATE TABLE fixture_payment_anchor AS SELECT pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure) definition;")
Path(sys.argv[1]).write_text('\n'.join(parts))
PYFIXTURE
run_sql < "$fixture_tmp/predecessor.sql" >/dev/null
run_sql -c 'CREATE SCHEMA supabase_migrations; CREATE TABLE supabase_migrations.schema_migrations(version text PRIMARY KEY,name text,statements text[]);' >/dev/null
# Exercise the actual official atomic wrapper, including pre/post preservation
# guards and original source/hash history, inside the isolated fixture.
python3 - "$fixture_tmp/atomic-migration.sql" <<'PYATOMIC'
from pathlib import Path
import sys
sys.path.insert(0,str(Path('scripts/cloud_deployment').resolve()))
from migration import prepare
prepared=prepare('supabase/migrations/20261030083248_menu_discount_quantities.sql','isolated-discount-fixture')
Path(sys.argv[1]).write_text(prepared['query'])
PYATOMIC
run_sql < "$fixture_tmp/atomic-migration.sql"
run_sql < supabase/migrations/20261031164134_pos_integrated_resilience.sql
run_sql < supabase/migrations/20261101022105_pos_resilience_completion_contracts.sql
run_sql < test/sql/menu_discount_quantities_test.sql
run_sql < test/sql/pos_resilience_batch_test.sql
run_sql < test/sql/menu_quantity_batch_events_test.sql
# Two independent sessions compete for the last portion while the first order
# remains unpaid. The second must wait and then receive no reservation.
run_sql -c "UPDATE menu_discount_quantities SET remaining=1 WHERE menu_item_id='40000000-0000-0000-0000-000000000001'; UPDATE store_promotions SET is_active=true,ends_at=now()+interval '1 hour' WHERE id='50000000-0000-0000-0000-000000000001';" >/dev/null
run_sql -c "SET application_name='discount-quantity-first'; BEGIN; INSERT INTO order_items(id,restaurant_id,order_id,menu_item_id,unit_price,quantity) VALUES('60000000-0000-0000-0000-000000000091','10000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002','40000000-0000-0000-0000-000000000001',100,1); SELECT pg_sleep(2); COMMIT;" > "$fixture_tmp/first.log" &
first_pid=$!
for attempt in $(seq 1 50); do
 if [[ "$(run_sql -Atc "SELECT count(*) FROM pg_stat_activity WHERE application_name='discount-quantity-first' AND wait_event='PgSleep'")" == 1 ]]; then break; fi
 if [[ "$attempt" == 50 ]]; then exit 1; fi
 sleep 0.1
done
run_sql -c "INSERT INTO order_items(id,restaurant_id,order_id,menu_item_id,unit_price,quantity) VALUES('60000000-0000-0000-0000-000000000092','10000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000003','40000000-0000-0000-0000-000000000001',100,1);" > "$fixture_tmp/second.log" &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
run_sql -c "SELECT fixture_assert((SELECT sum((promotion_quantity_snapshot->>'quantity')::int)=1 FROM order_items WHERE id IN('60000000-0000-0000-0000-000000000091','60000000-0000-0000-0000-000000000092')), 'concurrent unpaid orders allocate the last portion once'); SELECT fixture_assert((SELECT remaining=0 FROM menu_discount_quantities WHERE menu_item_id='40000000-0000-0000-0000-000000000001'),'concurrent quota never becomes negative');"
printf 'MENU_DISCOUNT_QUANTITIES_SQL_TEST=PASS\n'
