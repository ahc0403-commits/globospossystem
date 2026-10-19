#!/usr/bin/env bash
# Called only by the disposable integrated runner; never accepts a remote DB URL.
set -euo pipefail
recipient_container="$1"
recipient_logs="$2"
[[ "$recipient_container" == globos-direct-fallback-test-* || "$recipient_container" == globos-recipient-quick-* ]] || exit 1
recipient_sql() { docker exec "$recipient_container" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "$1"; }
recipient_book="SELECT public.direct_order_booking_action(restaurant_id,request_id,version,booking_id,'book','{\"provider\":\"grab\",\"driver_contact\":\"0901234567\"}'::jsonb)->>'status' FROM recipient_measurement.race"
recipient_sql "BEGIN; SELECT id FROM public.direct_order_requests WHERE id=(SELECT request_id FROM recipient_measurement.race) FOR UPDATE; SELECT pg_sleep(1); COMMIT;" > "$recipient_logs/recipient_lock.log" 2>&1 &
recipient_lock=$!
recipient_sql "$recipient_book" > "$recipient_logs/recipient_book_a.log" 2>&1 &
recipient_a=$!
recipient_sql "$recipient_book" > "$recipient_logs/recipient_book_b.log" 2>&1 &
recipient_b=$!
wait "$recipient_lock" || { cat "$recipient_logs/recipient_lock.log"; exit 1; }
wait "$recipient_a" || { cat "$recipient_logs/recipient_book_a.log"; exit 1; }
wait "$recipient_b" || { cat "$recipient_logs/recipient_book_b.log"; exit 1; }
recipient_count="$(recipient_sql "SELECT count(*) FROM public.direct_order_delivery_bookings b JOIN recipient_measurement.race r ON b.id=r.booking_id" | sed -n '3p' | tr -d ' ')"
[[ "$recipient_count" == "1" ]] || exit 1
recipient_sql "UPDATE recipient_measurement.race r SET version=t.version FROM public.direct_delivery_fulfillment_tickets t WHERE t.id=r.ticket_id" >/dev/null
recipient_sql "BEGIN; SELECT id FROM public.direct_order_requests WHERE id=(SELECT request_id FROM recipient_measurement.race) FOR UPDATE; SELECT pg_sleep(1); COMMIT;" > "$recipient_logs/recipient_lock.log" 2>&1 &
recipient_lock=$!
recipient_sql "SELECT public.direct_order_handoff_booking(restaurant_id,request_id,version,booking_id) IS NOT NULL FROM recipient_measurement.race" > "$recipient_logs/recipient_handoff.log" 2>&1 &
recipient_a=$!
recipient_sql "SELECT public.direct_order_booking_action(restaurant_id,request_id,version,gen_random_uuid(),'cancel','{\"reason\":\"race cancellation\"}'::jsonb)->>'status' FROM recipient_measurement.race" > "$recipient_logs/recipient_cancel.log" 2>&1 &
recipient_b=$!
wait "$recipient_lock" || { cat "$recipient_logs/recipient_lock.log"; exit 1; }
recipient_success=0
if wait "$recipient_a"; then recipient_success=$((recipient_success+1)); else rg -q 'DIRECT_ORDER_BOOKING_CHANGED' "$recipient_logs/recipient_handoff.log" || { cat "$recipient_logs/recipient_handoff.log"; exit 1; }; fi
if wait "$recipient_b"; then recipient_success=$((recipient_success+1)); else rg -q 'DIRECT_ORDER_BOOKING_CHANGED' "$recipient_logs/recipient_cancel.log" || { cat "$recipient_logs/recipient_cancel.log"; exit 1; }; fi
[[ "$recipient_success" == "1" ]] || { cat "$recipient_logs/recipient_handoff.log" "$recipient_logs/recipient_cancel.log"; exit 1; }
recipient_sql "DO \$race\$ BEGIN IF EXISTS(SELECT 1 FROM public.direct_order_delivery_bookings b JOIN recipient_measurement.race r ON r.booking_id=b.id LEFT JOIN public.direct_order_dispatches d ON d.request_id=r.request_id WHERE (b.status='handed_off') IS DISTINCT FROM (d.request_id IS NOT NULL)) OR EXISTS(SELECT 1 FROM public.direct_order_driver_cash_movements c JOIN recipient_measurement.race r USING(request_id)) THEN RAISE EXCEPTION 'RECIPIENT_RACE_FALSE_HANDOFF'; END IF; END; \$race\$;" >/dev/null
printf 'RECIPIENT_CONCURRENCY=PASS duplicate_booking=1 handoff_cancel_winners=1\n'
