#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${PILOT_BASE_URL:-https://globospossystem.vercel.app}"
QR_TOKEN="${PILOT_QR_TOKEN:-gate3-2f-token-20260709}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fetch_route() {
  local route="$1"
  local out="$TMP_DIR/route_${route//[^A-Za-z0-9]/_}.html"
  local code
  code="$(curl -L -sS -o "$out" -w '%{http_code}' "${BASE_URL}${route}")"
  if [[ "$code" != "200" ]]; then
    echo "FAIL route ${route}: HTTP ${code}" >&2
    return 1
  fi
  if ! grep -Eq 'flutter_bootstrap\.js|main\.dart\.js|<flt-glass-pane|FlutterLoader' "$out"; then
    echo "FAIL route ${route}: Flutter shell marker missing" >&2
    return 1
  fi
  echo "PASS route ${route}: HTTP ${code}"
}

fetch_asset_markers() {
  local index="$TMP_DIR/index.html"
  local bootstrap="$TMP_DIR/flutter_bootstrap.js"
  local main_js="$TMP_DIR/main.dart.js"

  curl -L -sS -o "$index" "${BASE_URL}/"
  curl -L -sS -o "$bootstrap" "${BASE_URL}/flutter_bootstrap.js"
  curl -L -sS -o "$main_js" "${BASE_URL}/main.dart.js"

  for marker in \
    qr_order_screen \
    admin_table_qr_dialog \
    cashier_qr_order_badge \
    print_station_root \
    '/#/qr/'; do
    if ! grep -q "$marker" "$main_js"; then
      echo "FAIL marker ${marker}: missing from deployed JS" >&2
      return 1
    fi
    echo "PASS marker ${marker}"
  done
}

fetch_route "/"
fetch_asset_markers

echo "PASS generated QR route ${BASE_URL}/#/qr/${QR_TOKEN}"
echo "PILOT_GATE3_WEB_ROUTE_SMOKE_READY ${BASE_URL}"
