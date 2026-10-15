#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
onboarding_test_dir="$(mktemp -d)"
trap 'rm -rf "$onboarding_test_dir"' EXIT
export ONBOARDING_TEST_ROOT="$PWD" ONBOARDING_TEST_DIR="$onboarding_test_dir"
python3 - <<'PY'
import os
p=os.path.join(os.environ['ONBOARDING_TEST_DIR'],'bootstrap.env')
with open(p,'w') as f: f.write('STORE_ONBOARDING_INITIAL_PASSWORD=fixture-secret-only\n')
os.chmod(p,0o600)
PY
# Gate parsing is exercised in a fresh shell: failing options must stop before
# any Auth/DB/secret/deploy side effects.
for option in --skip-checks --skip-auth-check --skip-login-smoke --skip-smoke-tests --skip-db --skip-build --skip-vercel --no-tests --web-only; do
 if bash -c 'source scripts/deploy_pos_production.sh; parse_args --onboarding-edge-only "$1"; validate_onboarding_edge_only_options' _ "$option" >"$onboarding_test_dir/rejected.log" 2>&1; then
  printf 'Unexpectedly allowed scoped release option %s\n' "$option" >&2; exit 1
 fi
done
bash -c '
 source scripts/deploy_pos_production.sh
 parse_args --onboarding-edge-only
 validate_onboarding_edge_only_options
 load_env(){ :; }; verify_allowed_production_origins(){ :; }
 run_auth_check(){ printf "AUTH_GATE\n"; }; run_checks(){ printf "TEST_GATE\n"; }
 run_login_smoke(){ printf "LOGIN_GATE\n"; }
 bash(){ :; }; deno(){ :; }
 run(){ printf "%s\n" "$*"; }
 STORE_ONBOARDING_SECRET_ENV_FILE="$ONBOARDING_TEST_DIR/bootstrap.env"
 run_onboarding_edge_only_flow
' >"$onboarding_test_dir/scoped.log"
python3 - <<'PY'
import os
s=open(os.path.join(os.environ['ONBOARDING_TEST_DIR'],'scoped.log')).read()
assert all(x in s for x in ['AUTH_GATE','TEST_GATE','LOGIN_GATE','secrets set --env-file','deploy store-account-onboarding','deploy provision-fixed-pos-account'])
assert 'fixture-secret-only' not in s
assert 'deploy meinvoice' not in s and 'vercel deploy' not in s
assert s.count('functions deploy ')==2
print('STORE_ACCOUNT_ONBOARDING_DEPLOY_CONTRACT=PASS')
PY
