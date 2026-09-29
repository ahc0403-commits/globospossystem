#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_name="pos-menu-analytics-$$"
base_sql="$(mktemp)"
cleanup() { docker rm -f "$fixture_name" >/dev/null 2>&1 || true; rm -f "$base_sql"; }
trap cleanup EXIT

python3 - "$base_sql" <<'PY'
from pathlib import Path
import sys

source = Path('supabase/migrations/20260822110000_paperless_menu_operation_and_dining_analytics.sql').read_text()
start = source.index('CREATE OR REPLACE FUNCTION public.get_paperless_operations_report(')
end = source.index('$$;', start) + 3
definition = source[start:end].replace(
    'FUNCTION public.get_paperless_operations_report(',
    'FUNCTION public.get_paperless_operations_report_pre_meal_start(', 1)
Path(sys.argv[1]).write_text(definition + '\n')
PY

docker run --detach --rm --name "$fixture_name" \
  --env POSTGRES_PASSWORD=menu-fixture --env POSTGRES_DB=menu_fixture \
  postgres:15 >/dev/null
for attempt in $(seq 1 60); do
  if docker exec "$fixture_name" pg_isready -U postgres -d menu_fixture >/dev/null 2>&1; then break; fi
  if [[ "$attempt" == 60 ]]; then exit 1; fi
  sleep 1
done
run_sql() { docker exec -i "$fixture_name" psql -X -v ON_ERROR_STOP=1 -U postgres -d menu_fixture; }
run_sql < test/fixtures/menu_localization_setup.sql >/dev/null
run_sql < "$base_sql" >/dev/null
run_sql < supabase/migrations/20260915200000_menu_display_localization.sql >/dev/null
run_sql < test/fixtures/menu_analytics_correction_setup.sql >/dev/null
run_sql < supabase/migrations/20260929040000_menu_analytics_ledger_names_and_groups.sql >/dev/null
run_sql < test/sql/menu_analytics_correction_test.sql >/dev/null
printf 'MENU_ANALYTICS_CORRECTION_SQL_TEST=PASS\n'
