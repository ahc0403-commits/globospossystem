#!/usr/bin/env bash
set -euo pipefail

if command -v flutter >/dev/null 2>&1; then
  FLUTTER_BIN="flutter"
else
  if [[ ! -x ./.flutter/bin/flutter ]]; then
    git clone https://github.com/flutter/flutter.git --depth 1 -b stable .flutter
  fi
  FLUTTER_BIN="./.flutter/bin/flutter"
fi

"$FLUTTER_BIN" config --enable-web
"$FLUTTER_BIN" pub get
