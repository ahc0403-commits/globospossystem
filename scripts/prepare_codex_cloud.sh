#!/usr/bin/env bash
# Bootstrap the pinned Linux Flutter SDK without system-wide changes.
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || {
  printf 'Expected Linux x86_64; use the matching approved platform environment.\n' >&2
  exit 1
}
for cmd in curl sha256sum tar git node deno docker python3 psql; do
  command -v "$cmd" >/dev/null || { printf 'Missing required tool: %s\n' "$cmd" >&2; exit 1; }
done
[[ "$(node --version)" == v22.* ]] || { echo 'Node 22 required' >&2; exit 1; }
[[ "$(deno --version | head -n 1)" == 'deno 2.7.13 '* ]] || { echo 'Deno 2.7.13 required' >&2; exit 1; }
docker info >/dev/null || { echo 'Docker daemon unavailable' >&2; exit 1; }
install_root="${HOME}/.local/opt/globos-flutter-3.41.6"
if [[ ! -x "$install_root/flutter/bin/flutter" ]]; then
  [[ ! -e "$install_root" ]] || { echo 'Incomplete Flutter installation exists; inspect it before retrying' >&2; exit 1; }
  mkdir -p "$(dirname "$install_root")"
  temp_dir="$(mktemp -d "${HOME}/.local/opt/.globos-flutter.XXXXXXXX")"
  trap 'rm -rf "$temp_dir"' EXIT
  curl --fail --location --silent --show-error \
    https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.41.6-stable.tar.xz \
    --output "$temp_dir/flutter.tar.xz"
  printf '%s  %s\n' 503b3e6b7d352fca5d21b6474eca95ad544d8fc3b053782eab63a360c7fc7569 "$temp_dir/flutter.tar.xz" | sha256sum --check -
  tar -xJf "$temp_dir/flutter.tar.xz" -C "$temp_dir"
  rm "$temp_dir/flutter.tar.xz"
  mv "$temp_dir" "$install_root"
  trap - EXIT
fi
export PATH="$install_root/flutter/bin:$PATH"
[[ "$(flutter --version | head -n 1)" == 'Flutter 3.41.6 '* ]] || { echo 'Flutter version mismatch' >&2; exit 1; }
flutter pub get --enforce-lockfile
(cd scripts && npm ci)
printf '\nFor each new shell use: export PATH="%s/flutter/bin:$PATH"\n' "$install_root"
printf 'Setup completed; run the verification checks and review their results before publishing the environment.\n'
