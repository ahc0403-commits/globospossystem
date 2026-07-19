#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

printf 'CHECK_REPO_STEP=flutter_dependencies\n'
flutter pub get --enforce-lockfile
printf 'CHECK_REPO_STEP=static_analysis\n'
dart analyze --fatal-infos
printf 'CHECK_REPO_STEP=flutter_tests\n'
flutter test

printf 'CHECK_REPO_STEP=node_contracts\n'
(
  cd scripts
  PUPPETEER_SKIP_DOWNLOAD=true npm ci
  npm test
  npm audit
  npm run security-scan
)

printf 'CHECK_REPO_STEP=deploy_shell_syntax\n'
bash -n scripts/deploy_pos_production.sh
printf 'CHECK_REPO_STEP=deploy_clean_worktree_contract\n'
bash test/pos_deploy_clean_worktree_checks_test.sh
printf 'CHECK_REPO_STEP=deploy_git_history_contract\n'
bash test/pos_deploy_git_history_guard_test.sh
printf 'CHECK_REPO_STEP=deploy_psql_runner_contract\n'
bash test/pos_deploy_psql_runner_test.sh
printf 'CHECK_REPO_STEP=production_sql_wrapper_contract\n'
bash test/pos_production_sql_wrapper_test.sh
printf 'CHECK_REPO_STEP=photo_expected_slot_contract\n'
bash test/photo_objet_expected_slot_ledger_test.sh

printf 'CHECK_REPO_STEP=flutter_web_release_build\n'
flutter build web --release
printf 'CHECK_REPO_STEP=git_whitespace_contract\n'
git diff --check
git show --check --format= HEAD
