import {
  assertEquals,
  assertThrows,
} from "https://deno.land/std@0.177.0/testing/asserts.ts";
import {
  buildEmergencyFcmMessage,
  mapEmergencyPushDelivery,
} from "../_shared/emergency_push.ts";

const row = {
  id: "delivery-1",
  event_id: "event-1",
  restaurant_id: "store-1",
  order_id: "order-1",
  station_type: "floor",
  floor_label: "2F",
  stage: "tray_dispatched",
  push_token: "token-token-token-token",
  attempt_count: 1,
};

Deno.test("emergency push targets the assigned web floor", () => {
  const delivery = mapEmergencyPushDelivery(row);
  const payload = buildEmergencyFcmMessage(delivery);
  assertEquals(payload.message.data.type, "emergency_fulfillment");
  assertEquals(payload.message.data.floor_label, "2F");
  assertEquals(payload.message.data.url, "/emergency");
  assertEquals(payload.message.webpush.headers.Urgency, "high");
});

Deno.test("emergency push rejects an unknown station", () => {
  assertThrows(
    () => mapEmergencyPushDelivery({ ...row, station_type: "G" }),
    Error,
    "EMERGENCY_PUSH_STATION_INVALID",
  );
});
