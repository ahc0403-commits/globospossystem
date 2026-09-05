#!/usr/bin/env bash
set -euo pipefail
VAT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAT_TMP="$(mktemp -d)"
VAT_CONTAINER="globos-vat-test-$$"
cleanup() { docker rm -f "$VAT_CONTAINER" >/dev/null 2>&1 || true; rm -rf "$VAT_TMP"; }
trap cleanup EXIT
python3 - "$VAT_ROOT" "$VAT_TMP" <<'PY'
import sys
from pathlib import Path
root,tmp=map(Path,sys.argv[1:])
s=(root/'supabase/migrations/20260707010000_service_item_exclusion_v1.sql').read_text()
a=s.index('CREATE OR REPLACE FUNCTION public.process_payment(')
b=s.index('CREATE OR REPLACE FUNCTION public.enqueue_meinvoice',a)
(tmp/'base.sql').write_text(s[a:b])
s=(root/'supabase/migrations/20260817110000_menu_scoped_promotion_integrity.sql').read_text()
a=s.index('ALTER FUNCTION public.process_payment(')
b=s.index('-- Avoid promotion resync',a)
(tmp/'wrapper.sql').write_text(s[a:b])
s=(root/'supabase/migrations/20260807180000_wet_tissue_price_2000.sql').read_text()
(tmp/'setter.sql').write_text(s[s.index('CREATE OR REPLACE FUNCTION'):s.rindex('COMMIT;')])
PY
docker run --detach --rm --name "$VAT_CONTAINER" --env POSTGRES_HOST_AUTH_METHOD=trust --publish 127.0.0.1::5432 postgres:15 >/dev/null
VAT_PORT="$(docker port "$VAT_CONTAINER" 5432/tcp | sed 's/.*://')"
VAT_READY=0
for ((i=0;i<100;i++)); do
  if psql -h 127.0.0.1 -p "$VAT_PORT" -U postgres -Atqc 'SELECT 1' >/dev/null 2>&1; then VAT_READY=1; break; fi
  sleep .2
done
[[ "$VAT_READY" == 1 ]]
run_sql() { psql -X -h 127.0.0.1 -p "$VAT_PORT" -U postgres -v ON_ERROR_STOP=1 -f "$1"; }
run_sql "$VAT_ROOT/test/fixtures/restaurant_vat_integrity_setup.sql" >/dev/null
run_sql "$VAT_TMP/base.sql" >/dev/null
run_sql "$VAT_ROOT/supabase/migrations/20260807190000_payment_discount_safe_update.sql" >/dev/null
run_sql "$VAT_TMP/wrapper.sql" >/dev/null
run_sql "$VAT_TMP/setter.sql" >/dev/null
run_sql "$VAT_ROOT/test/fixtures/restaurant_vat_legacy_setup.sql" >/dev/null
if [[ "${VAT_TEST_SKIP_FIX:-0}" != 1 ]]; then
  run_sql "$VAT_ROOT/supabase/migrations/20260905150000_restaurant_vat_integrity.sql" >/dev/null
fi
run_sql "$VAT_ROOT/test/fixtures/restaurant_vat_snapshot_assertions.sql"
if [[ "${VAT_TEST_SNAPSHOT_ONLY:-0}" == 1 ]]; then exit 0; fi
run_sql "$VAT_ROOT/test/fixtures/restaurant_vat_integrity_assertions.sql"
run_sql "$VAT_ROOT/test/fixtures/restaurant_vat_legacy_assertions.sql"
