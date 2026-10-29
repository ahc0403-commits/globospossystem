#!/usr/bin/env bash
set -euo pipefail
DIRECT_ORDER_AMENDMENTS_TEST=1 bash "$(dirname "${BASH_SOURCE[0]}")/direct_order_integrated_sql_test.sh"
