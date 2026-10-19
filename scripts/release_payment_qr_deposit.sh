#!/usr/bin/env bash
set -euo pipefail

# Release only the receipt-bank and deposit-classification changes.
# Source review/merge must happen before this command; never stages user files.
PAYMENT_RELEASE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAYMENT_RELEASE_SHA=""
PAYMENT_RELEASE_STAGE=all
PAYMENT_RELEASE_EXECUTE=0

payment_release_usage() {
  cat <<'EOF'
Usage: bash scripts/release_payment_qr_deposit.sh --sha APPROVED_MAIN_SHA
       [--stage all|receipt|deposit|web] [--dry-run|--execute]

Default: dry-run. Execute applies exactly two migrations, then POS web/mobile web.
No Edge functions, Office releases, native installation, staging, or commits.
Use a reviewed clean exact-main checkout whose required CI passed on that SHA.
If a phase already applied successfully, resume with the next --stage.
EOF
}

payment_release_main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sha) shift; PAYMENT_RELEASE_SHA="${1:-}" ;;
      --stage) shift; PAYMENT_RELEASE_STAGE="${1:-}" ;;
      --execute) PAYMENT_RELEASE_EXECUTE=1 ;;
      --dry-run) PAYMENT_RELEASE_EXECUTE=0 ;;
      --help|-h) payment_release_usage; return 0 ;;
      *) printf 'ERROR: Unknown release argument: %s\n' "$1" >&2; return 1 ;;
    esac
    [[ $# -gt 0 ]] || return 1
    shift
  done
  [[ "$PAYMENT_RELEASE_SHA" =~ ^[0-9a-f]{40}$ ]] || {
    printf 'ERROR: --sha requires the reviewed full 40-character main SHA.\n' >&2
    return 1
  }
  case "$PAYMENT_RELEASE_STAGE" in
    all|receipt|deposit|web) ;;
    *) printf 'ERROR: Invalid --stage.\n' >&2; return 1 ;;
  esac
  [[ "$(git -C "$PAYMENT_RELEASE_ROOT" rev-parse HEAD)" == "$PAYMENT_RELEASE_SHA" ]] || {
    printf 'ERROR: Checkout HEAD differs from the approved release SHA.\n' >&2
    return 1
  }
  [[ -z "$(git -C "$PAYMENT_RELEASE_ROOT" status --porcelain)" ]] || {
    printf 'ERROR: Release checkout must be clean; preserve unrelated work separately.\n' >&2
    return 1
  }
  export ENV_FILE="${ENV_FILE:-/Users/andreahn/.config/globos/pos-production.env}"
  export TEST_TARGETS=all REQUIRE_CLEAN_GIT=1
  local -a mode=(--dry-run)
  if [[ "$PAYMENT_RELEASE_EXECUTE" == "1" ]]; then
    mode=(--yes)
    export CONFIRM_PRODUCTION_DEPLOY=DEPLOY_GLOBOS_PROD
  fi
  local stage migration
  for stage in receipt deposit web; do
    [[ "$PAYMENT_RELEASE_STAGE" == all || "$PAYMENT_RELEASE_STAGE" == "$stage" ]] || continue
    [[ "$(git -C "$PAYMENT_RELEASE_ROOT" rev-parse HEAD)" == "$PAYMENT_RELEASE_SHA" ]] || return 1
    printf '\nPOS release stage: %s / %s\n' "$stage" "$PAYMENT_RELEASE_SHA"
    case "$stage" in
      receipt) migration=20261012183000_receipt_collection_bank.sql ;;
      deposit) migration=20261012210000_deposit_breakdown.sql ;;
      web)
        bash "$PAYMENT_RELEASE_ROOT/scripts/deploy_pos_production.sh" \
          --web-only --mode prebuilt "${mode[@]}"
        continue
        ;;
    esac
    bash "$PAYMENT_RELEASE_ROOT/scripts/deploy_pos_production.sh" \
      --db-only --mode prebuilt \
      --migration "$PAYMENT_RELEASE_ROOT/supabase/migrations/$migration" \
      "${mode[@]}"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  payment_release_main "$@"
fi
