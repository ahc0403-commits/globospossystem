#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="office-n1-pos-contract-$$"
log_file="$(mktemp -t office-pos-batch.XXXXXX)"
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -f "$log_file"
}
trap cleanup EXIT

docker run -d --name "$container" --network none \
  -e POSTGRES_PASSWORD=local-test-only -e PGPASSWORD=local-test-only \
  public.ecr.aws/supabase/postgres:17.6.1.104 >/dev/null
ready=0
for _ in {1..60}; do
  if docker exec "$container" psql -X -U supabase_admin -d postgres \
    -Atc 'select 1' >/dev/null 2>&1; then
    ready=$((ready + 1))
    [[ "$ready" -ge 3 ]] && break
  else
    ready=0
  fi
  sleep 1
done
[[ "$ready" -ge 3 ]] || { echo "Isolated POS test DB did not start" >&2; exit 1; }

python3 "$root_dir/scripts/test_office_store_batch_reads.py" \
  --container "$container" \
  --original-contract "$root_dir/supabase/migrations/20260901010000_office_inventory_source_contract.sql" \
  --purchase-contract "$root_dir/supabase/migrations/20260506000000_inventory_purchase_office_contracts.sql" \
  --purchase-detail-contract "$root_dir/supabase/migrations/20260909130000_add_supplier_name_to_inventory_purchase_detail.sql" \
  --procurement-snapshot-contract "$root_dir/supabase/migrations/20260913162000_procurement_accounting_snapshot.sql" \
  --output "$log_file" || { cat "$log_file" >&2; exit 1; }

docker exec -i "$container" psql -X -U supabase_admin \
  -d office_pos_batch_test -v ON_ERROR_STOP=1 \
  < "$root_dir/scripts/preflight_office_store_batch_reads.sql"
docker exec -i "$container" psql -X -U supabase_admin \
  -d office_pos_batch_test -v ON_ERROR_STOP=1 \
  < "$root_dir/scripts/verify_office_store_batch_reads.sql"
