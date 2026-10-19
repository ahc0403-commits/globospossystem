#!/usr/bin/env bash
set -euo pipefail
worker_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$worker_root"
"${DART_BIN:-dart}" compile js --packages=.dart_tool/package_config.json --no-source-maps --minify \
  web/photo_import_worker.dart -o web/photo_import_worker.js
