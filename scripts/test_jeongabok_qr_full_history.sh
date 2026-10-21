#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
fixture_name="pos-qr-full-history-$$"
fixture_tmp="$(mktemp -d)"
cleanup() { docker rm -f "$fixture_name" >/dev/null 2>&1 || true; rm -rf "$fixture_tmp"; }
trap cleanup EXIT
python3 - "$fixture_tmp/predecessor.sql" <<'PY'
from pathlib import Path
import sys
s=Path('supabase/migrations/20260909160000_qr_order_display_reset.sql').read_text()
start=s.index('CREATE OR REPLACE FUNCTION public.qr_get_active_order(p_token text)')
end=s.index('$$;',start)+3
s=s[start:end].replace('FUNCTION public.qr_get_active_order(', 'FUNCTION public.qr_get_active_order_pre_start_ready(')
s+='\nREVOKE ALL ON FUNCTION public.qr_get_active_order_pre_start_ready(text) FROM PUBLIC,anon,authenticated;\n'
Path(sys.argv[1]).write_text(s)
PY
docker run --detach --rm --name "$fixture_name" --env POSTGRES_PASSWORD=qr-history-fixture --env POSTGRES_DB=qr_history_fixture postgres:15 >/dev/null
for attempt in $(seq 1 60); do
 if docker exec "$fixture_name" pg_isready -U postgres -d qr_history_fixture >/dev/null 2>&1; then break; fi
 if [[ "$attempt" == 60 ]]; then exit 1; fi
 sleep 1
done
run_sql() { docker exec -i "$fixture_name" psql -X -v ON_ERROR_STOP=1 -U postgres -d qr_history_fixture; }
run_sql < test/fixtures/jeongabok_qr_full_history_setup.sql >/dev/null
run_sql < "$fixture_tmp/predecessor.sql" >/dev/null
run_sql < supabase/migrations/20261021140000_jeongabok_qr_full_active_order_history.sql >/dev/null
run_sql < test/sql/jeongabok_qr_full_history_test.sql
