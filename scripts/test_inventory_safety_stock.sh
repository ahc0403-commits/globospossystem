#!/usr/bin/env bash
set -euo pipefail
if ! command -v initdb >/dev/null 2>&1 && command -v pg_config >/dev/null 2>&1; then
 export PATH="$(pg_config --bindir):$PATH"
fi
SAFETY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAFETY_TMP="$(mktemp -d "${TMPDIR:-/tmp}/inventory-safety.XXXXXX")"
SAFETY_PORT="$(python3 - <<'PY'
import socket
with socket.socket() as s:
 s.bind(('127.0.0.1',0)); print(s.getsockname()[1])
PY
)"
cleanup() { pg_ctl -D "$SAFETY_TMP/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$SAFETY_TMP"; }
trap cleanup EXIT
initdb -D "$SAFETY_TMP/data" --auth=trust --encoding=UTF8 --locale=C >/dev/null
pg_ctl -D "$SAFETY_TMP/data" -l "$SAFETY_TMP/server.log" -o "-h 127.0.0.1 -p $SAFETY_PORT -k $SAFETY_TMP" -w start >/dev/null
python3 "$SAFETY_ROOT/scripts/tests/inventory_safety_stock_fixture.py" "$SAFETY_ROOT" "$SAFETY_TMP/fixture.sql"
run_sql() { psql -X -h 127.0.0.1 -p "$SAFETY_PORT" -d postgres -v ON_ERROR_STOP=1 -f "$1"; }
run_sql "$SAFETY_TMP/fixture.sql" >/dev/null
run_sql "$SAFETY_ROOT/scripts/preflight_inventory_safety_stock_settings.sql"
run_sql "$SAFETY_ROOT/supabase/migrations/20261002020000_inventory_safety_stock_settings.sql"
run_sql "$SAFETY_ROOT/scripts/verify_inventory_safety_stock_settings.sql"
run_sql "$SAFETY_ROOT/supabase/tests/inventory_safety_stock_settings_test.sql"
run_sql "$SAFETY_ROOT/scripts/rollback_inventory_safety_stock_settings.sql"
psql -X -h 127.0.0.1 -p "$SAFETY_PORT" -d postgres -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 ASSERT to_regprocedure('public.upsert_inventory_product_with_supplier_v2(uuid,uuid,uuid,text,text,text,text,text,numeric,text,text,integer,boolean,text,numeric)') IS NULL;
 ASSERT (SELECT current_stock=24770 AND quantity=25000 AND reorder_point=5000 FROM inventory_items WHERE id=test_uuid(501));
 ASSERT to_regprocedure('public.upsert_inventory_product_with_supplier(uuid,uuid,uuid,text,text,text,text,text,numeric,text,text,integer,boolean,text)') IS NOT NULL;
END $$;
SELECT 'Safety stock rollback preserves stock and settings: PASS';
SQL
