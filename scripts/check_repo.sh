#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

flutter pub get --enforce-lockfile
dart analyze --fatal-infos
flutter test

(
  cd scripts
  PUPPETEER_SKIP_DOWNLOAD=true npm ci
  npm test
  npm audit
  npm run security-scan
)

bash -n scripts/deploy_pos_production.sh
bash test/pos_deploy_clean_worktree_checks_test.sh
bash test/pos_deploy_git_history_guard_test.sh
bash test/pos_deploy_psql_runner_test.sh
bash test/pos_production_sql_wrapper_test.sh
bash test/photo_objet_expected_slot_ledger_test.sh

flutter build web --release
git diff --check
git show --check --format= HEAD
