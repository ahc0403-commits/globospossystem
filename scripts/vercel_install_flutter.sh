#!/usr/bin/env bash
set -euo pipefail

[[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]] || {
  echo 'Pinned Vercel Flutter build requires Linux x86_64.' >&2; exit 1;
}
if [[ ! -x ./.flutter/bin/flutter ]]; then
  archive="$(mktemp)"
  trap 'rm -f "$archive"' EXIT
  curl -fsSL https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.41.6-stable.tar.xz -o "$archive"
  echo "503b3e6b7d352fca5d21b6474eca95ad544d8fc3b053782eab63a360c7fc7569  $archive" | sha256sum -c -
  mkdir .flutter
  tar --no-same-owner -xJf "$archive" -C .flutter --strip-components=1
fi
FLUTTER_BIN="./.flutter/bin/flutter"
"$FLUTTER_BIN" --version --machine | python3 -c '
import json,sys
v=json.load(sys.stdin)
assert v["frameworkVersion"]=="3.41.6" and v["dartSdkVersion"]=="3.11.4", "Pinned Flutter/Dart version mismatch"'

"$FLUTTER_BIN" config --enable-web
"$FLUTTER_BIN" pub get --enforce-lockfile
