#!/usr/bin/env bash

# Convention-based production migration gate.
# The caller owns shell strict mode and provides the deployment helper
# functions used below.

resolve_production_migration_gate() {
  local migration_path="$1"
  local scripts_dir="${2:-$ROOT_DIR/scripts}"
  local migration_name migration_version migration_slug

  migration_name="$(basename "$migration_path")"
  migration_version="${migration_name%%_*}"
  if [[ ! "$migration_name" =~ ^[0-9]{14}_[a-z0-9_]+\.sql$ ]]; then
    fail "Production migration must use TIMESTAMP_snake_case.sql: $migration_name"
    return 1
  fi
  migration_slug="${migration_name#*_}"
  migration_slug="${migration_slug%.sql}"

  PRODUCTION_MIGRATION_NAME="$migration_name"
  PRODUCTION_MIGRATION_VERSION="$migration_version"
  PRODUCTION_MIGRATION_PREFLIGHT="$scripts_dir/preflight_${migration_slug}.sql"
  PRODUCTION_MIGRATION_APPLY="$scripts_dir/apply_${migration_slug}.sql"
  PRODUCTION_MIGRATION_VERIFY="$scripts_dir/verify_${migration_slug}.sql"
  PRODUCTION_MIGRATION_ROLLBACK="$scripts_dir/rollback_${migration_slug}.sql"
  PRODUCTION_MIGRATION_VERIFICATION_MODE="external"

  if [[ ! -f "$PRODUCTION_MIGRATION_VERIFY" ]]; then
    if ! grep -Fqx -- '-- production-gate: self-verifying' "$migration_path"; then
      fail "Migration $migration_name requires $PRODUCTION_MIGRATION_VERIFY or an explicit self-verifying contract."
      return 1
    fi
    PRODUCTION_MIGRATION_VERIFICATION_MODE="embedded"
  fi
}

apply_migration_by_convention() {
  local requested_migration="$1"
  local scripts_dir="${2:-$ROOT_DIR/scripts}"

  if [[ "$SKIP_DB" == "1" ]]; then
    log "Supabase migration skipped"
    return 0
  fi
  if [[ -z "$requested_migration" ]]; then
    log "No Supabase migration requested"
    return 0
  fi

  local migration_path="$requested_migration"
  [[ "$migration_path" = /* ]] || migration_path="$ROOT_DIR/$migration_path"
  if [[ ! -f "$migration_path" ]]; then
    fail "Missing migration: $migration_path"
    return 1
  fi

  resolve_production_migration_gate "$migration_path" "$scripts_dir" || return 1

  if [[ -f "$PRODUCTION_MIGRATION_ROLLBACK" ]]; then
    log "Migration rollback readiness"
    printf 'Rollback ready (not executed): %s\n' "$PRODUCTION_MIGRATION_ROLLBACK"
  fi

  require_migration_history_absent "$PRODUCTION_MIGRATION_VERSION"

  if [[ -f "$PRODUCTION_MIGRATION_PREFLIGHT" ]]; then
    log "Production migration preflight"
    run_linked_psql_file \
      "$PRODUCTION_MIGRATION_PREFLIGHT" \
      "migration $PRODUCTION_MIGRATION_VERSION preflight"
  else
    log "No separate production migration preflight"
  fi

  log "Apply Supabase migration"
  if [[ -f "$PRODUCTION_MIGRATION_APPLY" ]]; then
    run_linked_psql_file \
      "$PRODUCTION_MIGRATION_APPLY" \
      "migration $PRODUCTION_MIGRATION_VERSION guarded apply"
  else
    run_linked_psql_file \
      "$migration_path" \
      "migration $PRODUCTION_MIGRATION_VERSION"
  fi

  if [[ "$PRODUCTION_MIGRATION_VERIFICATION_MODE" == "external" ]]; then
    log "Production migration verification"
    run_linked_psql_file \
      "$PRODUCTION_MIGRATION_VERIFY" \
      "migration $PRODUCTION_MIGRATION_VERSION verification"
  else
    log "Production migration verification completed inside the atomic migration"
  fi

  log "Repair Supabase migration history"
  run supabase migration repair \
    "$PRODUCTION_MIGRATION_VERSION" --status applied --yes
  require_migration_history_present "$PRODUCTION_MIGRATION_VERSION"
}
