#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
operating_fixture="pos-operating-profiles-$$"
trap 'docker rm -f "$operating_fixture" >/dev/null 2>&1 || true' EXIT
docker run --detach --rm --name "$operating_fixture" --env POSTGRES_PASSWORD=fixture-only \
  public.ecr.aws/supabase/postgres:17.6.1.104 \
  -c shared_preload_libraries=pg_stat_statements -c pg_stat_statements.track=all >/dev/null
for attempt in {1..60}; do
  if docker exec "$operating_fixture" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then break; fi
  if [[ "$attempt" == 60 ]]; then exit 1; fi
  sleep 1
done
run_sql() { docker exec -i --env PGPASSWORD=fixture-only "$operating_fixture" psql -X -U postgres -v ON_ERROR_STOP=1; }
run_sql < test/fixtures/store_operating_profiles_setup.sql >/dev/null
python3 - <<'PY' | run_sql >/dev/null
from pathlib import Path
s=Path('supabase/migrations/20260717170000_workforce_fixed_accounts.sql').read_text()
a=s.index('CREATE OR REPLACE FUNCTION public.require_admin_actor_for_restaurant(')
print(s[a:s.index('$$;',a)+3])
PY
run_sql < supabase/migrations/20261021163000_store_operating_profiles.sql >/dev/null
run_sql < supabase/migrations/20261021172000_operating_profile_purge_compat.sql >/dev/null
run_sql < test/sql/store_operating_profiles_test.sql
python3 scripts/tests/store_operating_profile_concurrency.py "$operating_fixture"
