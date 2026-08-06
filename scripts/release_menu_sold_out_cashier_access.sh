#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

for argument in "$@"; do
  case "$argument" in
    --migration|--skip-db|--skip-vercel|--db-only|--rollback-hierarchy)
      printf 'ERROR: %s is incompatible with the combined Sold out release.\n' \
        "$argument" >&2
      exit 1
      ;;
  esac
done

exec "$SCRIPT_DIR/deploy_pos_production.sh" \
  --migration \
  "$ROOT_DIR/supabase/migrations/20260806122400_menu_sold_out_cashier_access.sql" \
  --test test/menu_sold_out_access_contract_test.dart \
  "$@"
