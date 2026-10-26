#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
fixture_name="pos-menu-meal-cart-$$"
fixture_tmp="$(mktemp -d)"
cleanup() { docker rm -f "$fixture_name" >/dev/null 2>&1 || true; rm -rf "$fixture_tmp"; }
trap cleanup EXIT
python3 - "$fixture_tmp/predecessor.sql" <<'PY'
from pathlib import Path
import sys,re
s=Path('supabase/migrations/20261020100000_menu_portion_spice.sql').read_text()
parts=[]
for name in ['menu_registered_option_key','menu_option_name','menu_apply_option_names','menu_apply_registered_options','admin_create_menu_item_with_options','admin_update_menu_item_with_options','validate_menu_option_batch']:
 a=re.search(r'CREATE FUNCTION public\.'+name+r'\(',s).start()
 parts.append(s[a:s.index('$$;',a)+3])
parts.append("ALTER TABLE public.menu_items ADD COLUMN menu_option_key text GENERATED ALWAYS AS (public.menu_registered_option_key(portion_code,spice_level,spice_choice,price)) STORED;")
parts.append('CREATE TRIGGER zz_menu_option_names BEFORE INSERT OR UPDATE ON public.menu_items FOR EACH ROW EXECUTE FUNCTION public.menu_apply_option_names();')
Path(sys.argv[1]).write_text('\n'.join(parts))
PY
docker run --detach --rm --name "$fixture_name" --env POSTGRES_PASSWORD=size-fixture --env POSTGRES_DB=size_fixture public.ecr.aws/supabase/postgres:17.6.1.104 >/dev/null
for attempt in $(seq 1 60); do
 if docker exec "$fixture_name" pg_isready -h 127.0.0.1 -U postgres -d size_fixture >/dev/null 2>&1; then break; fi
 if [[ "$attempt" == 60 ]]; then exit 1; fi
 sleep 1
done
run_sql() { docker exec -i --env PGPASSWORD=size-fixture "$fixture_name" psql -X -v ON_ERROR_STOP=1 -U supabase_admin -d size_fixture; }
run_sql < test/fixtures/menu_size_prices_setup.sql >/dev/null
run_sql < "$fixture_tmp/predecessor.sql" >/dev/null
run_sql < scripts/preflight_menu_size_prices.sql >/dev/null
run_sql < supabase/migrations/20261020160000_menu_size_prices.sql >/dev/null
run_sql < scripts/verify_menu_size_prices.sql >/dev/null
run_sql < test/sql/menu_size_prices_contract_test.sql

run_sql < supabase/migrations/20261021090000_menu_meal_choices_cart.sql >/dev/null
run_sql < test/sql/menu_meal_choices_cart_test.sql

run_sql < supabase/migrations/20261021110000_admin_menu_item_order.sql >/dev/null
run_sql < scripts/verify_admin_menu_item_order.sql
run_sql < test/sql/admin_menu_item_order_test.sql

run_sql <<'SQL' >/dev/null
CREATE TABLE public.inventory_items(id uuid PRIMARY KEY,restaurant_id uuid,name text);
SQL
run_sql < supabase/migrations/20261021180000_registered_menu_choices.sql >/dev/null
run_sql < test/sql/registered_menu_choice_definition_test.sql

python3 - <<'PYINTAKE' > "$fixture_tmp/choice_validation.sql"
from pathlib import Path
source=Path('supabase/migrations/20261021181000_menu_choice_intake.sql').read_text()
a=source.index('CREATE OR REPLACE FUNCTION "public"."validate_menu_option_batch"')
b=source.index('CREATE OR REPLACE FUNCTION',a+1)
print(source[a:b])
PYINTAKE
run_sql < "$fixture_tmp/choice_validation.sql" >/dev/null
run_sql < test/fixtures/menu_catalog_consolidation_predecessor.sql >/dev/null
python3 - <<'PYCONSOLIDATE' > "$fixture_tmp/consolidation.sql"
from pathlib import Path
source=Path('supabase/migrations/20261026120000_direct_order_cashier_kimchi.sql').read_text()
print('BEGIN;\n'+source.split('-- menu-consolidation-section')[1])
PYCONSOLIDATE
run_sql < "$fixture_tmp/consolidation.sql" >/dev/null
run_sql < test/sql/kimchi_consolidation_test.sql
