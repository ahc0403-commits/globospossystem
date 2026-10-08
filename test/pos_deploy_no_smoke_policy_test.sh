#!/usr/bin/env bash
set -euo pipefail
POLICY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY_TMP="$(mktemp -d)"
trap 'rm -rf "$POLICY_TMP"' EXIT
source "$POLICY_ROOT/scripts/deploy_pos_production.sh"
parse_args --skip-smoke-tests
[[ "$SKIP_SMOKE_TESTS" == 1 && "$SKIP_LOGIN_SMOKE" == 1 ]]
[[ "$SKIP_AUTH_CHECK" == 0 && "$SKIP_CHECKS" == 0 && "$SKIP_DB" == 0 && "$SKIP_BUILD" == 0 ]]
curl() { printf 'UNEXPECTED_APPLICATION_HTTP_PROBE\n' >&2; return 97; }
ensure_flutter_env() { :; }
supabase() {
  [[ "$*" == *"--project-ref $POS_PROJECT_REF"* ]] || return 95
  if [[ "$1 $2" == 'functions list' ]]; then
    python3 - "${POLICY_MISSING_HANDLER:-0}" <<'PY'
import json,sys
names=['create_staff_user','provision-fixed-pos-account','complete-initial-password-change','sepay-webhook','emergency-fulfillment-dispatcher','public-receipt','direct-order-public','direct-order-notification-dispatcher','deliberry-webhook','deliberry-dispatcher','generate-settlement','generate_delivery_settlement']
if sys.argv[1]=='1': names.remove('direct-order-public')
print(json.dumps([{'slug':name,'status':'ACTIVE'} for name in names]))
PY
  elif [[ "$1 $2" == 'secrets list' ]]; then
    python3 - "${POLICY_WRONG_ORIGIN:-0}" "$LIVE_URL" <<'PY'
import hashlib,json,sys
origin='https://incorrect.invalid' if sys.argv[1]=='1' else sys.argv[2]
# Supabase CLI v2 serializes the digest in the `value` field.
print(json.dumps([{'name':'ALLOWED_ORIGINS','value':hashlib.sha256(origin.encode()).hexdigest()}]))
PY
  else return 96; fi
}
vercel() {
  case "$1" in
    build) return 0 ;;
    deploy)
      [[ "$*" == *'--prebuilt --prod --yes'* && "$*" == *'githubCommitSha='* ]] || return 94
      printf 'Production: https://release-policy.invalid.vercel.app\n'
      ;;
    inspect)
      local deployment_id='policy-build'
      if [[ "${POLICY_STALE_ALIAS:-0}" == 1 && "$2" == "$LIVE_URL" ]]; then deployment_id='stale-build'; fi
      printf '{"id":"%s","readyState":"READY","target":"production"}\n' "$deployment_id"
      ;;
    *) return 93 ;;
  esac
}
verify_no_smoke_edge_metadata > "$POLICY_TMP/metadata"
verify_deliberry_retirement_readiness > "$POLICY_TMP/retirement"
verify_remote_allowed_origin > "$POLICY_TMP/origin"
verify_emergency_dispatcher_readiness > "$POLICY_TMP/emergency"
verify_direct_order_dispatcher_readiness > "$POLICY_TMP/direct"
deploy_vercel > "$POLICY_TMP/deployment"
run_login_smoke > "$POLICY_TMP/login" 2>&1
grep -q 'metadata; no HTTP probe' "$POLICY_TMP/deployment"
grep -q 'login smoke skipped' "$POLICY_TMP/login"
for mode in POLICY_MISSING_HANDLER POLICY_WRONG_ORIGIN; do
  if (export "$mode=1"; verify_no_smoke_edge_metadata) > "$POLICY_TMP/rejected" 2>&1; then
    printf 'NO_SMOKE_ACCEPTED_INVALID_EDGE_METADATA\n'; exit 1
  fi
done
if (POLICY_STALE_ALIAS=1 deploy_vercel) > "$POLICY_TMP/rejected" 2>&1; then
  printf 'NO_SMOKE_ACCEPTED_STALE_PRODUCTION_ALIAS\n'; exit 1
fi
printf 'PASS: no-smoke deployment issues no application probes and fails closed on wrong Edge/origin/alias metadata\n'
