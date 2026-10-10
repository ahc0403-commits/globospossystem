#!/usr/bin/env bash
set -euo pipefail
buyer_db="$1"
buyer_dir="$(mktemp -d "${2:-/tmp}/pos-buyer-race.XXXXXX")"
trap 'rm -rf "$buyer_dir"' EXIT
buyer_query="SELECT public.pos_save_buyer_information(s.store_id,s.order_id,s.version,jsonb_build_object('buyer_address','Concurrent fixture address'),true) IS NOT NULL FROM buyer_measurement.scope s;"
for buyer_worker in 1 2; do
  docker exec "$buyer_db" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "$buyer_query" > "$buyer_dir/$buyer_worker.log" 2>&1 &
done
wait || true
buyer_success=0
buyer_stale=0
for buyer_worker in 1 2; do
  if rg -q '^ t$' "$buyer_dir/$buyer_worker.log"; then buyer_success=$((buyer_success+1)); fi
  if rg -q 'POS_BUYER_CHANGED' "$buyer_dir/$buyer_worker.log"; then buyer_stale=$((buyer_stale+1)); fi
done
if [[ "$buyer_success" != 1 || "$buyer_stale" != 1 ]]; then
  cat "$buyer_dir/1.log" "$buyer_dir/2.log"
  exit 1
fi
printf 'POS_BUYER_CONCURRENT_SAVE=PASS winners=%s stale=%s\n' "$buyer_success" "$buyer_stale"
