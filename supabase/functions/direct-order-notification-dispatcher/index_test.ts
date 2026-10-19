import { createDirectOrderPushHandler } from "./index.ts";
import {
  buildDirectOrderFcmMessage,
  directOrderPushOutcome,
  mapDirectOrderPush,
} from "../_shared/direct_order_push.ts";
function assert(ok: boolean, message: string) {
  if (!ok) throw new Error(message);
}
const row = {
  id: "delivery",
  lease_id: "lease",
  event_id: "event",
  event_kind: "pickup_ready",
  request_id: "request",
  reference_code: "DFIXTURE1",
  slug: "fixture-store",
  store_name: "Fixture store",
  locale: "ko",
  push_token: "fixture-token-0123456789",
  token_hash: "hash",
};
Deno.test("fulfillment push uses customer locale, safe link and one event tag", () => {
  for (const locale of ["ko", "vi", "en"]) {
    for (const kind of ["pickup_ready", "driver_handoff"]) {
      const payload = buildDirectOrderFcmMessage(
        mapDirectOrderPush({ ...row, locale, event_kind: kind }),
        "https://pos.example",
      );
      assert(
        payload.message.data.type === "direct_order_customer",
        "customer routing",
      );
      assert(
        payload.message.webpush.notification.tag === "event",
        "deduplication tag",
      );
      assert(
        payload.message.webpush.fcm_options.link ===
          "https://pos.example/order/fixture-store",
        "customer route",
      );
      assert(
        !JSON.stringify(payload).includes("secret"),
        "no session secret in push",
      );
      if (locale === "ko") {
        assert(
          payload.message.data.body.includes(
            kind === "pickup_ready" ? "매장 카운터" : "배송 중",
          ),
          "Korean fulfillment copy",
        );
      }
    }
  }
});
Deno.test("transient and invalid-token failures have distinct retry outcomes", () => {
  assert(
    directOrderPushOutcome(200, { name: "projects/fixture/messages/1" }) ===
      "sent",
    "provider acceptance",
  );
  assert(directOrderPushOutcome(429, {}) === "retry", "rate limit retry");
  assert(
    directOrderPushOutcome(503, {}) === "retry",
    "provider downtime retry",
  );
  assert(
    directOrderPushOutcome(404, {
      error: { details: [{ errorCode: "UNREGISTERED" }] },
    }) === "invalid_token",
    "expired token",
  );
  assert(
    directOrderPushOutcome(400, {}) === "failed",
    "bad payload must not retry forever",
  );
});
Deno.test("dispatcher rejects unauthenticated callers before claiming tokens", async () => {
  let claims = 0;
  const handler = createDirectOrderPushHandler({
    authorized: () => false,
    claim: () => {
      claims++;
      return Promise.resolve([]);
    },
    send: () => Promise.resolve("sent"),
    complete: () => Promise.resolve(true),
  });
  const result = await handler(
    new Request("https://edge.example", { method: "POST" }),
  );
  assert(result.status === 401 && claims === 0, "auth precedes data access");
});
Deno.test("dispatcher batches once, retries failures and acknowledges only current leases", async () => {
  let claims = 0;
  const outcomes: string[] = [];
  const handler = createDirectOrderPushHandler({
    authorized: () => true,
    claim: () => {
      claims++;
      return Promise.resolve([row, { ...row, id: "failed" }]);
    },
    send: (delivery) =>
      delivery.id === "failed"
        ? Promise.reject(new Error("offline"))
        : Promise.resolve("sent"),
    complete: (delivery, outcome) => {
      outcomes.push(outcome);
      return Promise.resolve(delivery.id !== "failed");
    },
  });
  const result = await handler(
    new Request("https://edge.example", { method: "POST" }),
  );
  const stats = await result.json();
  assert(
    claims === 1 && stats.claimed === 2 && stats.accepted === 1 &&
      stats.failed === 1,
    "bounded batch totals",
  );
  assert(
    outcomes.includes("retry") && outcomes.includes("sent"),
    "outcomes acknowledged",
  );
});

Deno.test("payment requests tell customers to review the amount and pay in KO EN VI", () => {
  for (
    const [locale, phrase] of [["ko", "결제 요청"], ["en", "payment request"], [
      "vi",
      "yêu cầu thanh toán",
    ]]
  ) {
    const payload = buildDirectOrderFcmMessage(
      mapDirectOrderPush({ ...row, locale, event_kind: "payment_request" }),
      "https://pos.example",
    );
    assert(
      payload.message.data.body.includes(phrase),
      "localized payment notice",
    );
    assert(
      payload.message.data.event_kind === "payment_request",
      "correct payment event",
    );
    assert(
      payload.message.webpush.notification.tag === "event",
      "one notification identity",
    );
  }
});

Deno.test("cooking and packing notices describe preparation without claiming handoff", () => {
  for (const locale of ["ko", "vi", "en"]) {
    for (const event_kind of ["cooking_complete", "packing_complete"]) {
      const payload = buildDirectOrderFcmMessage(
        mapDirectOrderPush({ ...row, locale, event_kind }),
        "https://pos.example",
      );
      assert(
        payload.message.data.event_kind === event_kind,
        "progress identity",
      );
      if (locale === "ko") {
        assert(
          payload.message.data.body.includes(
            event_kind === "cooking_complete"
              ? "포장하고"
              : "기사 전달을 기다리고",
          ),
          "verified progress",
        );
      }
    }
  }
});
