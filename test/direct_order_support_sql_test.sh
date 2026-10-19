#!/usr/bin/env bash
set -euo pipefail
SUPPORT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIRECT_ORDER_CUSTOMER_EXPERIENCE_TEST=1 DIRECT_ORDER_SUPPORT_TEST=1 bash "$SUPPORT_ROOT/test/direct_order_delivery_fallback_sql_test.sh"
