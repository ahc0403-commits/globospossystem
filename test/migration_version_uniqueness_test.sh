#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

duplicate_versions="$({
  find supabase/migrations -maxdepth 1 -type f -name '*.sql' -exec basename {} \;
} | sed -E 's/_.*$//' | sort | uniq -d)"

if [[ -n "$duplicate_versions" ]]; then
  printf 'Duplicate Supabase migration versions:\n%s\n' "$duplicate_versions" >&2
  while IFS= read -r version; do
    find supabase/migrations -maxdepth 1 -type f -name "${version}_*.sql" -print >&2
  done <<<"$duplicate_versions"
  exit 1
fi

printf 'Supabase migration versions are unique.\n'
