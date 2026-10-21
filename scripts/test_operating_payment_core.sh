#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Reproducible financial-core regression, requiring no remote schema or secrets.
# This deliberately uses a narrow schema and fixture authorization. The separate
# current-schema upgrade suite verifies real RLS/triggers/invoice integration.
payment_fixture="pos-operating-payment-core-$$"
trap 'docker rm -f "$payment_fixture" >/dev/null 2>&1 || true' EXIT
docker run --detach --rm --name "$payment_fixture" \
  --env POSTGRES_PASSWORD=fixture-only postgres:15 >/dev/null
for attempt in {1..60}; do
  if docker exec "$payment_fixture" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then break; fi
  if [[ "$attempt" == 60 ]]; then exit 1; fi
  sleep 1
done
run_sql() { docker exec -i --env PGPASSWORD=fixture-only "$payment_fixture" psql -X -U postgres -v ON_ERROR_STOP=1; }
run_sql < test/fixtures/restaurant_vat_integrity_setup.sql >/dev/null
run_sql <<'SQL' >/dev/null
CREATE SCHEMA operating_test;
ALTER TABLE menu_items ADD COLUMN effective_vat_rate numeric DEFAULT 8;
ALTER TABLE order_items ADD COLUMN vat_profile_snapshot jsonb, ADD COLUMN vat_breakdown jsonb,
 ADD COLUMN cancelled_consumed_quantity integer NOT NULL DEFAULT 0;
ALTER TABLE tables ADD COLUMN updated_at timestamptz;
SQL
python3 - <<'PY' | run_sql >/dev/null
from pathlib import Path
import re

def function(path, name):
    source = Path(path).read_text()
    match = re.search(r'CREATE (?:OR REPLACE )?FUNCTION (?:public\.|"public"\.")'
                      + re.escape(name) + r'"?\(', source)
    if match is None:
        raise RuntimeError(f'Missing function: {name}')
    body = source[match.start():]
    delimiter = re.search(r'\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$', body)
    if delimiter is None:
        raise RuntimeError(f'Missing function delimiter: {name}')
    end = body.index(delimiter.group() + ';', delimiter.end())
    return body[:end + len(delimiter.group()) + 1]

vat = 'supabase/migrations/20260929010000_beverage_sugar_vat.sql'
combo = 'supabase/migrations/20261013030000_direct_order_combo_ordering.sql'
for name in ['allocate_vat_cents', 'calculate_item_vat']:
    print(function(vat, name))
for name in ['direct_order_combo_vnd_vat', 'direct_order_payment_vat']:
    print(function(combo, name))
baseline = function('test/fixtures/direct_order_combo_payment_anchor.sql',
                    'process_payment_without_scoped_promotions')
print(baseline.replace('public.process_payment_without_scoped_promotions(',
                       'operating_test.payment_before_operating(', 1))
wrapper = function('test/fixtures/direct_order_combo_payment_anchor.sql',
                   'process_payment_before_promotion_read_split')
print(wrapper.replace('public.process_payment_before_promotion_read_split(',
                      'operating_test.payment_wrapper_before_operating(', 1)
      .replace('public.process_payment_without_scoped_promotions(', 'operating_test.payment_before_operating('))
print(function('supabase/migrations/20261021170000_direct_order_line_identity.sql',
               'process_payment_without_scoped_promotions'))
print(function('supabase/migrations/20261021173000_batch_promotion_payment_allocations.sql',
               'process_payment_before_promotion_read_split'))
PY
run_sql < test/sql/operating_payment_core_regression_test.sql
