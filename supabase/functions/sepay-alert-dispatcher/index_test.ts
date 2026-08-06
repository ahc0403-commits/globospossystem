import {
  assertEquals,
  assertThrows,
} from "https://deno.land/std@0.177.0/testing/asserts.ts";

import {
  buildFcmMessage,
  mapClaimedDelivery,
  parseFirebaseServiceAccount,
} from "../_shared/sepay_push.ts";

const claimed = {
  delivery_id: "delivery-1",
  transaction_id: "transaction-1",
  restaurant_id: "store-1",
  device_id: "device-1",
  platform: "ios",
  push_provider: "fcm",
  push_token: "push-token-long-enough",
  amount: "93456",
  payment_code: "GBTEST",
  received_at: "2026-08-06T01:00:00Z",
  attempt_count: 1,
};

Deno.test("builds a non-collapsible mutable iOS payment alert", () => {
  const payload = buildFcmMessage(mapClaimedDelivery(claimed));
  const data = payload.message.data as Record<string, string>;
  const apns = payload.message.apns as {
    payload: {
      aps: {
        "mutable-content": number;
        alert: { body: string };
      };
    };
  };
  assertEquals(data.amount, "93456");
  assertEquals(data.event_id, "delivery-1");
  assertEquals(
    apns.payload.aps["mutable-content"],
    1,
  );
  assertEquals(
    (apns.payload.aps as Record<string, unknown>)["content-available"],
    1,
  );
  assertEquals(apns.payload.aps.alert.body, "93.456 VND");
  assertEquals("collapse_key" in payload.message, false);
});

Deno.test("builds high-priority Android data delivery", () => {
  const payload = buildFcmMessage(
    mapClaimedDelivery({ ...claimed, platform: "android" }),
  );
  assertEquals(
    (payload.message.android as Record<string, unknown>).priority,
    "HIGH",
  );
  assertEquals("notification" in payload.message, false);
});

Deno.test("rejects malformed Firebase service credentials", () => {
  assertThrows(
    () => parseFirebaseServiceAccount('{"project_id":"only-project"}'),
    Error,
    "FIREBASE_SERVICE_ACCOUNT_INVALID",
  );
});
