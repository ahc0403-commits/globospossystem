#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
db_url="${1:-${DIRECT_DELIVERY_TEST_DB_URL:-}}"

if [[ -z "$db_url" ]]; then
  echo "usage: $0 <disposable codex_direct_* database URL>" >&2
  exit 2
fi

db_name="$(psql -X -qAt -v ON_ERROR_STOP=1 "$db_url" \
  -c 'select current_database()')"
if [[ ! "$db_name" =~ ^codex_direct_ ]]; then
  echo "refusing concurrency test on non-disposable database: $db_name" >&2
  exit 2
fi

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/direct-delivery-concurrency.XXXXXX")"

cleanup() {
  local pid
  while read -r pid; do
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done < <(jobs -pr)

  psql -X -q -v ON_ERROR_STOP=1 "$db_url" >/dev/null 2>&1 <<'SQL' || true
DROP TRIGGER IF EXISTS direct_test_pause_approval
  ON public.direct_order_financials;
DROP TRIGGER IF EXISTS direct_test_pause_reject
  ON public.direct_order_requests;
DROP FUNCTION IF EXISTS direct_delivery_test.pause_approval();
DROP FUNCTION IF EXISTS direct_delivery_test.pause_reject();
SQL

  case "$temp_dir" in
    */direct-delivery-concurrency.*)
      rm -rf -- "$temp_dir"
      ;;
  esac
}
trap cleanup EXIT

psql -X -q -v ON_ERROR_STOP=1 "$db_url" <<'SQL'
DO $cleanup_fixture$
BEGIN
  IF current_database() !~ '^codex_direct_' THEN
    RAISE EXCEPTION 'DIRECT_DELIVERY_TEST_REQUIRES_CODEX_DISPOSABLE_DB';
  END IF;
  DELETE FROM public.restaurants
  WHERE id = 'de100000-0000-4000-8000-000000000001';
END;
$cleanup_fixture$;
SQL

psql -X -q -v ON_ERROR_STOP=1 "$db_url" \
  -f "$repo_root/supabase/tests/fixtures/direct_delivery_test_fixture.sql"

psql -X -q -v ON_ERROR_STOP=1 "$db_url" <<'SQL'
CREATE OR REPLACE FUNCTION direct_delivery_test.pause_approval()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF current_setting('application_name') LIKE 'direct_approval_a_%' THEN
    PERFORM pg_sleep(0.15);
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER direct_test_pause_approval
AFTER INSERT ON public.direct_order_financials
FOR EACH ROW
EXECUTE FUNCTION direct_delivery_test.pause_approval();

CREATE OR REPLACE FUNCTION direct_delivery_test.pause_reject()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF current_setting('application_name') = 'direct_reject_a' AND
     OLD.state = 'awaiting_payment_review' AND NEW.state = 'rejected' THEN
    PERFORM pg_sleep(0.15);
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER direct_test_pause_reject
AFTER UPDATE ON public.direct_order_requests
FOR EACH ROW
EXECUTE FUNCTION direct_delivery_test.pause_reject();

CREATE OR REPLACE FUNCTION direct_delivery_test.assert_concurrency_graph(
  p_request_id uuid,
  p_order_id uuid,
  p_payment_id uuid,
  p_ticket_id uuid
) RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE v_financial public.direct_order_financials%ROWTYPE;
BEGIN
  PERFORM direct_delivery_test.assert_single_graph(p_request_id);
  SELECT * INTO STRICT v_financial
  FROM public.direct_order_financials financial
  WHERE financial.request_id = p_request_id;
  IF v_financial.order_id <> p_order_id
     OR v_financial.payment_id <> p_payment_id
     OR NOT EXISTS (
       SELECT 1 FROM public.direct_delivery_fulfillment_tickets ticket
       WHERE ticket.id = p_ticket_id AND ticket.request_id = p_request_id
     )
     OR (SELECT count(*) FROM public.payments payment
         WHERE payment.order_id = p_order_id) <> 1
     OR (SELECT count(*) FROM public.direct_order_messages message
         WHERE message.request_id = p_request_id
           AND message.body = 'DIRECT_ORDER_PAYMENT_APPROVED') <> 1
     OR (SELECT count(*) FROM public.audit_logs audit
         WHERE audit.action = 'direct_order_payment_approved'
           AND audit.entity_id = p_request_id) <> 1 THEN
    RAISE EXCEPTION 'DIRECT_DELIVERY_CONCURRENCY_GRAPH_MISMATCH:%',
      p_request_id;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION direct_delivery_test.assert_empty_graph(
  p_request_id uuid,
  p_expected_state text
) RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NOT EXISTS (
       SELECT 1 FROM public.direct_order_requests request_row
       WHERE request_row.id = p_request_id
         AND request_row.state = p_expected_state
     )
     OR EXISTS (
       SELECT 1 FROM public.direct_order_financials financial
       WHERE financial.request_id = p_request_id
     )
     OR EXISTS (
       SELECT 1 FROM public.direct_delivery_fulfillment_tickets ticket
       WHERE ticket.request_id = p_request_id
     )
     OR EXISTS (
       SELECT 1
       FROM public.orders order_row
       JOIN public.direct_order_requests request_row
         ON order_row.notes = 'Direct delivery ' || request_row.reference_code
       WHERE request_row.id = p_request_id
     ) THEN
    RAISE EXCEPTION 'DIRECT_DELIVERY_CONCURRENCY_GRAPH_NOT_EMPTY:%',
      p_request_id;
  END IF;
END;
$function$;
SQL

create_request() {
  psql -X -qAt -v ON_ERROR_STOP=1 "$db_url" -c \
    "select (result->>'request_id') || '|' || (result->>'final_total')
       from (select direct_delivery_test.create_request('payment_review') result) fixture"
}

approval_query() {
  local request_id="$1"
  local total="$2"
  printf "%s" "select concat_ws('|', result->>'request_id', result->>'order_id', result->>'payment_id', result->>'ticket_id', result->>'final_total', result->>'idempotent') from (select direct_delivery_test.approve('$request_id', $total) result) approval"
}

validate_fixture_values() {
  local request_id="$1"
  local total="$2"
  if [[ ! "$request_id" =~ ^[0-9a-f-]{36}$ ]] ||
     [[ ! "$total" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "invalid disposable fixture output" >&2
    exit 1
  fi
}

wait_for_approval_lock() {
  local app_name="$1"
  local observed="f"
  local attempt
  for ((attempt = 0; attempt < 100; attempt += 1)); do
    observed="$(psql -X -qAt -v ON_ERROR_STOP=1 "$db_url" -c \
      "select exists(
         select 1
         from pg_stat_activity activity
         join pg_locks held_lock on held_lock.pid = activity.pid
         where activity.application_name = '$app_name'
           and activity.state = 'active'
           and held_lock.locktype = 'advisory'
           and held_lock.granted
       )")"
    if [[ "$observed" == "t" ]]; then
      return 0
    fi
    sleep 0.01
  done
  echo "approval connection never exposed its advisory lock: $app_name" >&2
  return 1
}

wait_for_reject_pause() {
  local observed="f"
  local attempt
  for ((attempt = 0; attempt < 100; attempt += 1)); do
    observed="$(psql -X -qAt -v ON_ERROR_STOP=1 "$db_url" -c \
      "select exists(
         select 1 from pg_stat_activity activity
         where activity.application_name = 'direct_reject_a'
           and activity.state = 'active'
           and activity.wait_event = 'PgSleep'
       )")"
    if [[ "$observed" == "t" ]]; then
      return 0
    fi
    sleep 0.01
  done
  echo "reject connection never reached its row-lock pause" >&2
  return 1
}

run_identical_approval_race() {
  local iteration="$1"
  local fixture request_id total app_a query
  local a_out b_out a_err b_err a_pid b_pid
  local a_request a_order a_payment a_ticket a_total a_idempotent
  local b_request b_order b_payment b_ticket b_total b_idempotent

  fixture="$(create_request)"
  IFS='|' read -r request_id total <<<"$fixture"
  validate_fixture_values "$request_id" "$total"
  app_a="direct_approval_a_$iteration"
  query="$(approval_query "$request_id" "$total")"
  a_out="$temp_dir/approval_${iteration}_a.out"
  b_out="$temp_dir/approval_${iteration}_b.out"
  a_err="$temp_dir/approval_${iteration}_a.err"
  b_err="$temp_dir/approval_${iteration}_b.err"

  psql -X -qAt -v ON_ERROR_STOP=1 "$db_url" \
    -c "set application_name = '$app_a'; $query" \
    >"$a_out" 2>"$a_err" &
  a_pid=$!
  wait_for_approval_lock "$app_a"
  psql -X -qAt -v ON_ERROR_STOP=1 "$db_url" \
    -c "set application_name = 'direct_approval_b_$iteration'; $query" \
    >"$b_out" 2>"$b_err" &
  b_pid=$!

  if ! wait "$a_pid"; then
    sed -n '1,20p' "$a_err" >&2
    return 1
  fi
  if ! wait "$b_pid"; then
    sed -n '1,20p' "$b_err" >&2
    return 1
  fi

  IFS='|' read -r a_request a_order a_payment a_ticket a_total a_idempotent <"$a_out"
  IFS='|' read -r b_request b_order b_payment b_ticket b_total b_idempotent <"$b_out"
  if [[ "$a_request|$a_order|$a_payment|$a_ticket|$a_total" != "$b_request|$b_order|$b_payment|$b_ticket|$b_total" ]] ||
     [[ "$a_idempotent" != "false" ]] || [[ "$b_idempotent" != "true" ]]; then
    echo "approval identity mismatch at iteration $iteration" >&2
    return 1
  fi

  psql -X -qAt -v ON_ERROR_STOP=1 "$db_url" -c \
    "select direct_delivery_test.assert_concurrency_graph(
       '$request_id', '$a_order', '$a_payment', '$a_ticket'
     )" >/dev/null
}

for ((iteration = 1; iteration <= 50; iteration += 1)); do
  run_identical_approval_race "$iteration"
  if ((iteration % 10 == 0)); then
    echo "identical approval races passed: $iteration/50"
  fi
done

run_approval_wins_race() {
  local operation="$1"
  local expected_error="$2"
  local fixture request_id total query app_a a_pid b_pid a_code b_code
  local a_out="$temp_dir/${operation}_approval.out"
  local a_err="$temp_dir/${operation}_approval.err"
  local b_out="$temp_dir/${operation}_terminal.out"
  local b_err="$temp_dir/${operation}_terminal.err"

  fixture="$(create_request)"
  IFS='|' read -r request_id total <<<"$fixture"
  validate_fixture_values "$request_id" "$total"
  query="$(approval_query "$request_id" "$total")"
  app_a="direct_approval_a_${operation}"

  psql -X -qAt -v ON_ERROR_STOP=1 "$db_url" \
    -c "set application_name = '$app_a'; $query" >"$a_out" 2>"$a_err" &
  a_pid=$!
  wait_for_approval_lock "$app_a"
  if [[ "$operation" == "reject" ]]; then
    psql -X -qAt -v ON_ERROR_STOP=1 "$db_url" -c \
      "select direct_delivery_test.reject('$request_id')" >"$b_out" 2>"$b_err" &
  else
    psql -X -qAt -v ON_ERROR_STOP=1 "$db_url" -c \
      "select direct_delivery_test.cancel('$request_id')" >"$b_out" 2>"$b_err" &
  fi
  b_pid=$!

  a_code=0
  b_code=0
  wait "$a_pid" || a_code=$?
  wait "$b_pid" || b_code=$?
  if ((a_code != 0 || b_code == 0)) ||
     ! rg -q "$expected_error" "$b_err"; then
    sed -n '1,20p' "$a_err" >&2
    sed -n '1,20p' "$b_err" >&2
    echo "approve-vs-$operation contract failed" >&2
    return 1
  fi

  IFS='|' read -r _ a_order a_payment a_ticket _ _ <"$a_out"
  psql -X -qAt -v ON_ERROR_STOP=1 "$db_url" -c \
    "select direct_delivery_test.assert_concurrency_graph(
       '$request_id', '$a_order', '$a_payment', '$a_ticket'
     )" >/dev/null
  echo "approve-vs-$operation passed: approval won, loser returned $expected_error"
}

run_approval_wins_race reject DIRECT_ORDER_REQUEST_NOT_REJECTABLE
run_approval_wins_race cancel DIRECT_ORDER_REQUEST_NOT_CANCELLABLE

fixture="$(create_request)"
IFS='|' read -r request_id total <<<"$fixture"
validate_fixture_values "$request_id" "$total"
reject_out="$temp_dir/reject_wins.out"
reject_err="$temp_dir/reject_wins.err"
approval_out="$temp_dir/reject_wins_approval.out"
approval_err="$temp_dir/reject_wins_approval.err"
psql -X -qAt -v ON_ERROR_STOP=1 "$db_url" \
  -c "set application_name = 'direct_reject_a'; select direct_delivery_test.reject('$request_id')" \
  >"$reject_out" 2>"$reject_err" &
reject_pid=$!
wait_for_reject_pause
psql -X -qAt -v ON_ERROR_STOP=1 "$db_url" \
  -c "$(approval_query "$request_id" "$total")" \
  >"$approval_out" 2>"$approval_err" &
approval_pid=$!
reject_code=0
approval_code=0
wait "$reject_pid" || reject_code=$?
wait "$approval_pid" || approval_code=$?
if ((reject_code != 0 || approval_code == 0)) ||
   ! rg -q 'DIRECT_ORDER_REQUEST_NOT_APPROVABLE' "$approval_err"; then
  sed -n '1,20p' "$reject_err" >&2
  sed -n '1,20p' "$approval_err" >&2
  echo "reject-vs-approve contract failed" >&2
  exit 1
fi
psql -X -qAt -v ON_ERROR_STOP=1 "$db_url" -c \
  "select direct_delivery_test.assert_empty_graph('$request_id', 'rejected')" \
  >/dev/null
echo "reject-vs-approve passed: rejection won, approval returned DIRECT_ORDER_REQUEST_NOT_APPROVABLE"

echo "DIRECT_DELIVERY_CONCURRENCY_PASS: 50 identical races, 3 terminal races, 0 duplicate graphs"
