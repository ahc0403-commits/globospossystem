#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_SCRIPT="$ROOT_DIR/scripts/deploy_pos_production.sh"

for migration in \
  supabase/migrations/20260715000000_security_audit_hardening.sql \
  supabase/migrations/20260715020000_security_expand_compat.sql; do
  MIGRATION_FILE="$migration" bash -c '
    source "$1"
    DRY_RUN=1
    SKIP_DB=0
    SKIP_VERCEL=1
    apply_migration
  ' security-rollout "$DEPLOY_SCRIPT" >/dev/null
done

set +e
contract_output="$(MIGRATION_FILE=docs/security_rollout/sql/security_contract_draft.sql \
  bash -c '
    source "$1"
    DRY_RUN=1
    SKIP_DB=0
    SKIP_VERCEL=1
    apply_migration
  ' security-rollout "$DEPLOY_SCRIPT" 2>&1)"
contract_status=$?
set -e
[[ "$contract_status" -ne 0 ]]
[[ "$contract_output" == *'Contract draft is never deployable'* ]]

set +e
combined_output="$(bash -c '
  source "$1"
  parse_args \
    --migration supabase/migrations/20260715000000_security_audit_hardening.sql \
    --migration supabase/migrations/20260715020000_security_expand_compat.sql
' security-rollout "$DEPLOY_SCRIPT" 2>&1)"
combined_status=$?
set -e
[[ "$combined_status" -ne 0 ]]
[[ "$combined_output" == *'Only one explicitly approved migration'* ]]

set +e
coupled_output="$(MIGRATION_FILE=supabase/migrations/20260715020000_security_expand_compat.sql \
  bash -c '
    source "$1"
    DRY_RUN=1
    SKIP_DB=0
    SKIP_VERCEL=0
    apply_migration
  ' security-rollout "$DEPLOY_SCRIPT" 2>&1)"
coupled_status=$?
set -e
[[ "$coupled_status" -ne 0 ]]
[[ "$coupled_output" == *'old-client smoke can run before the Flutter release'* ]]

printf 'PASS: security rollout migration isolation and Contract refusal\n'
