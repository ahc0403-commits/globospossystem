#!/usr/bin/env bash
set -euo pipefail
if ! command -v initdb >/dev/null 2>&1 && command -v pg_config >/dev/null 2>&1; then
 export PATH="$(pg_config --bindir):$PATH"
fi
BUNSIK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNSIK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/bunsik-inventory.XXXXXX")"
BUNSIK_PORT="$(python3 - <<'PY'
import socket
with socket.socket() as s:
 s.bind(('127.0.0.1',0));print(s.getsockname()[1])
PY
)"
cleanup() { pg_ctl -D "$BUNSIK_TMP/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$BUNSIK_TMP"; }
trap cleanup EXIT
initdb -D "$BUNSIK_TMP/data" --auth=trust --encoding=UTF8 --locale=C >/dev/null
pg_ctl -D "$BUNSIK_TMP/data" -l "$BUNSIK_TMP/server.log" -o "-h 127.0.0.1 -p $BUNSIK_PORT -k $BUNSIK_TMP" -w start >/dev/null
python3 "$BUNSIK_ROOT/scripts/tests/bunsik_inventory_fixture.py" "$BUNSIK_ROOT" "$BUNSIK_TMP/fixture.sql"
run_sql() { psql -X -h 127.0.0.1 -p "$BUNSIK_PORT" -d postgres -v ON_ERROR_STOP=1 -f "$1"; }
run_sql "$BUNSIK_TMP/fixture.sql" >/dev/null
run_sql "$BUNSIK_ROOT/scripts/preflight_bunsik_inventory_code_reset.sql"
psql -X -h 127.0.0.1 -p "$BUNSIK_PORT" -d postgres -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 BEGIN DELETE FROM inventory_receipt_lines WHERE id=test_uuid(3); RAISE EXCEPTION 'SUBMITTED_GUARD_MISSING';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'INVENTORY_RECEIPT_SUBMITTED_LOCKED' THEN RAISE; END IF; END;
 BEGIN DELETE FROM inventory_receipts WHERE id=test_uuid(4); RAISE EXCEPTION 'CONFIRMED_GUARD_MISSING';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'INVENTORY_RECEIPT_SUBMITTED_LOCKED' THEN RAISE; END IF; END;
END $$;
SQL
run_sql "$BUNSIK_ROOT/supabase/migrations/20260930010000_bunsik_inventory_code_reset.sql"
run_sql "$BUNSIK_ROOT/scripts/verify_bunsik_inventory_code_reset.sql"
psql -X -h 127.0.0.1 -p "$BUNSIK_PORT" -d postgres -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM inventory_receipts WHERE id=test_uuid(7) AND status='confirmed') THEN RAISE EXCEPTION 'BINH_RECEIPT_CHANGED'; END IF;
 BEGIN DELETE FROM inventory_receipt_lines WHERE id=test_uuid(8); RAISE EXCEPTION 'CONFIRMED_LINE_GUARD_NOT_RESTORED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'INVENTORY_RECEIPT_CONFIRMED_IMMUTABLE' THEN RAISE; END IF; END;
 BEGIN DELETE FROM inventory_receipts WHERE id=test_uuid(7); RAISE EXCEPTION 'CONFIRMED_HEADER_GUARD_NOT_RESTORED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'INVENTORY_RECEIPT_SUBMITTED_LOCKED' THEN RAISE; END IF; END;
END $$;
SQL
# An accidental rerun must refuse to delete the newly cloned sample.
if run_sql "$BUNSIK_ROOT/supabase/migrations/20260930010000_bunsik_inventory_code_reset.sql" >"$BUNSIK_TMP/rerun.log" 2>&1; then echo 'Reset rerun unexpectedly accepted' >&2; exit 1; fi
run_sql "$BUNSIK_ROOT/scripts/rollback_bunsik_inventory_code_reset.sql"
psql -X -h 127.0.0.1 -p "$BUNSIK_PORT" -d postgres -v ON_ERROR_STOP=1 -c "DO \$\$ BEGIN IF (SELECT count(*) FROM inventory_products WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a')<>104 OR NOT EXISTS(SELECT 1 FROM inventory_purchase_orders WHERE purchase_order_no='SAMPLE-OLD') THEN RAISE EXCEPTION 'ROLLBACK_FAILED'; END IF; END \$\$;" >/dev/null
psql -X -h 127.0.0.1 -p "$BUNSIK_PORT" -d postgres -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM inventory_receipts WHERE id=test_uuid(4) AND status='confirmed' AND submitted_at IS NOT NULL)
 OR NOT EXISTS(SELECT 1 FROM inventory_receipt_lines WHERE id=test_uuid(5))
 OR NOT EXISTS(SELECT 1 FROM inventory_receipt_change_history WHERE receipt_id=test_uuid(2)) THEN RAISE EXCEPTION 'LOCKED_RECEIPT_ROLLBACK_FAILED'; END IF;
 BEGIN DELETE FROM inventory_receipt_lines WHERE id=test_uuid(3); RAISE EXCEPTION 'ROLLBACK_GUARD_NOT_RESTORED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'INVENTORY_RECEIPT_SUBMITTED_LOCKED' THEN RAISE; END IF; END;
END $$;
SQL
run_sql "$BUNSIK_ROOT/supabase/migrations/20260930020000_inventory_stock_audit_excel.sql"
run_sql "$BUNSIK_ROOT/supabase/tests/inventory_stock_audit_excel_test.sql"

python3 "$BUNSIK_ROOT/scripts/tests/stock_audit_concurrency.py" "$BUNSIK_PORT"

run_sql "$BUNSIK_ROOT/supabase/migrations/20261001010000_inventory_stocktake_dated_reports.sql"
run_sql "$BUNSIK_ROOT/supabase/tests/inventory_stocktake_dated_reports_test.sql"
python3 "$BUNSIK_ROOT/scripts/tests/stocktake_dated_concurrency.py" "$BUNSIK_PORT"

run_sql "$BUNSIK_ROOT/scripts/preflight_inventory_stocktake_counted_balances.sql"
run_sql "$BUNSIK_ROOT/supabase/migrations/20261002010000_inventory_stocktake_counted_balances.sql"
run_sql "$BUNSIK_ROOT/scripts/verify_inventory_stocktake_counted_balances.sql"
run_sql "$BUNSIK_ROOT/supabase/tests/inventory_stocktake_counted_balances_test.sql"
run_sql "$BUNSIK_ROOT/scripts/rollback_inventory_stocktake_counted_balances.sql"

psql -X -h 127.0.0.1 -p "$BUNSIK_PORT" -d postgres -v ON_ERROR_STOP=1 -c "CREATE TABLE dated_rollback_stock AS SELECT id,current_stock FROM inventory_items;" >/dev/null
run_sql "$BUNSIK_ROOT/scripts/rollback_inventory_stocktake_dated_reports.sql"
psql -X -h 127.0.0.1 -p "$BUNSIK_PORT" -d postgres -v ON_ERROR_STOP=1 <<'SQL'
SET request.jwt.claim.role='service_role';
DO $$ DECLARE sid uuid; report jsonb; BEGIN
 IF EXISTS(SELECT 1 FROM dated_rollback_stock b JOIN inventory_items i USING(id) WHERE b.current_stock IS DISTINCT FROM i.current_stock) THEN RAISE EXCEPTION 'ROLLBACK_CHANGED_STOCK'; END IF;
 SELECT id INTO sid FROM inventory_stock_audit_sessions WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a' AND template_version=2 AND status='completed' LIMIT 1;
 report:=get_inventory_stock_audit_report('3a268807-771f-4fd4-84fe-e1b0b00de40a',sid);
 IF jsonb_array_length(report->'rows')=0 OR report->'report' IS NULL THEN RAISE EXCEPTION 'ROLLBACK_LOST_REPORT'; END IF;
END $$;
SELECT 'Rollback retains quantities and completed report: PASS';
SQL
