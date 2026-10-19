#!/usr/bin/env bash
set -euo pipefail
RETIREMENT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RETIREMENT_TMP="$(mktemp -d)"
trap 'rm -rf "$RETIREMENT_TMP"' EXIT
mkdir "$RETIREMENT_TMP/bin"
cat >"$RETIREMENT_TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
response_file=''
endpoint=''
for arg in "$@"; do
  [[ "$arg" != *Authorization* ]] || exit 93
done
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) response_file="$2"; shift ;;
    https://*/functions/v1/*) endpoint="${1##*/}" ;;
  esac
  shift
done
[[ -n "$response_file" && -n "$endpoint" ]] || exit 94
printf '%s\n' "$endpoint" >>"$RETIREMENT_CALL_LOG"
printf '%s' "${RETIREMENT_MOCK_BODY:-DELIBERRY_INTEGRATION_RETIRED}" >"$response_file"
printf '%s' "${RETIREMENT_MOCK_STATUS:-410}"
exit "${RETIREMENT_MOCK_EXIT:-0}"
EOF
chmod +x "$RETIREMENT_TMP/bin/curl"
export PATH="$RETIREMENT_TMP/bin:$PATH"
export RETIREMENT_CALL_LOG="$RETIREMENT_TMP/calls"
source "$RETIREMENT_ROOT/scripts/deploy_pos_production.sh"
SUPABASE_URL='https://retirement.invalid'
DRY_RUN=0
verify_deliberry_retirement_readiness >"$RETIREMENT_TMP/success"
cat >"$RETIREMENT_TMP/expected" <<'EOF'
deliberry-webhook
deliberry-dispatcher
generate-settlement
generate_delivery_settlement
EOF
cmp "$RETIREMENT_TMP/expected" "$RETIREMENT_CALL_LOG"
for rejected_status in 200 401 500; do
  if (RETIREMENT_MOCK_STATUS="$rejected_status" verify_deliberry_retirement_readiness) \
    >"$RETIREMENT_TMP/rejected" 2>&1; then
    echo "Retirement gate accepted HTTP $rejected_status" >&2
    exit 1
  fi
done
if (RETIREMENT_MOCK_BODY='unrelated response' verify_deliberry_retirement_readiness) \
  >"$RETIREMENT_TMP/rejected" 2>&1; then
  echo 'Retirement gate accepted the wrong response body' >&2
  exit 1
fi
if (RETIREMENT_MOCK_EXIT=7 verify_deliberry_retirement_readiness) \
  >"$RETIREMENT_TMP/rejected" 2>&1; then
  echo 'Retirement gate accepted a network failure' >&2
  exit 1
fi
: >"$RETIREMENT_CALL_LOG"
DRY_RUN=1
verify_deliberry_retirement_readiness >"$RETIREMENT_TMP/dry-run"
[[ ! -s "$RETIREMENT_CALL_LOG" ]]
printf 'PASS: four retired endpoints require HTTP 410 and fail closed on unexpected responses\n'
