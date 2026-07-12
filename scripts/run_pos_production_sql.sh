#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_SCRIPT="$ROOT_DIR/scripts/deploy_pos_production.sh"
ENV_FILE="${ENV_FILE:-$HOME/.config/globos/pos-production.env}"

usage() {
  printf 'Usage: %s SQL_FILE LABEL\n' "$0"
}

[[ $# -eq 2 ]] || {
  usage >&2
  exit 2
}
SQL_FILE="$1"
LABEL="$2"
[[ -f "$SQL_FILE" ]] || SQL_FILE="$ROOT_DIR/$SQL_FILE"
[[ -f "$SQL_FILE" ]] || {
  printf 'ERROR: missing SQL file\n' >&2
  exit 1
}

# shellcheck disable=SC1090
source "$DEPLOY_SCRIPT"

[[ -f "$ENV_FILE" ]] || {
  printf 'ERROR: secure POS production env is missing\n' >&2
  exit 1
}
[[ "$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE")" == "600" ]] || {
  printf 'ERROR: secure POS production env must have mode 600\n' >&2
  exit 1
}

load_env
reject_target_overrides
need_cmd git
need_cmd supabase
need_cmd psql

[[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]] ||
  fail "Refusing production SQL from a dirty worktree."
git -C "$ROOT_DIR" fetch --quiet origin +refs/heads/main:refs/remotes/origin/main
git -C "$ROOT_DIR" merge-base --is-ancestor origin/main HEAD ||
  fail "HEAD is not descended from current origin/main."

[[ -f "$ROOT_DIR/supabase/.temp/project-ref" ]] ||
  fail "Missing linked Supabase project ref."
[[ "$(tr -d '\r\n' < "$ROOT_DIR/supabase/.temp/project-ref")" == "$POS_PROJECT_REF" ]] ||
  fail "Linked Supabase project is not POS production."

run_linked_psql_file "$SQL_FILE" "$LABEL"
