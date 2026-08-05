import {
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.177.0/testing/asserts.ts";

import {
  parseSePayTransaction,
  verifySePaySignature,
} from "../_shared/sepay_webhook.ts";

async function signature(secret: string, message: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const bytes = await crypto.subtle.sign("HMAC", key, encoder.encode(message));
  return [...new Uint8Array(bytes)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

Deno.test("verifies SePay raw-body HMAC and replay window", async () => {
  const rawBody = '{"id":92704,"transferAmount":350000}';
  const timestamp = "1785920400";
  const secret = "test-secret";
  const digest = await signature(secret, `${timestamp}.${rawBody}`);

  assertEquals(
    await verifySePaySignature({
      secret,
      rawBody,
      timestamp,
      signature: `sha256=${digest}`,
      nowMillis: 1785920400 * 1000,
    }),
    true,
  );
  assertEquals(
    await verifySePaySignature({
      secret,
      rawBody: `${rawBody} `,
      timestamp,
      signature: `sha256=${digest}`,
      nowMillis: 1785920400 * 1000,
    }),
    false,
  );
  assertEquals(
    await verifySePaySignature({
      secret,
      rawBody,
      timestamp,
      signature: `sha256=${digest}`,
      nowMillis: (1785920400 + 301) * 1000,
    }),
    false,
  );
});

Deno.test("parses the supported incoming SePay payload", () => {
  const parsed = parseSePayTransaction({
    id: 92704,
    gateway: "Vietcombank",
    transactionDate: "2026-08-05 17:00:00",
    accountNumber: "9358674202",
    subAccount: "SBSEPAYOA465N89VHYK",
    code: "GBA1B2C3D4",
    transferType: "in",
    transferAmount: 350000,
    referenceCode: "FT24012345678",
  });

  assertEquals(parsed.id, 92704);
  assertEquals(parsed.transferAmount, 350000);
  assertEquals(parsed.transactionAt, "2026-08-05T10:00:00.000Z");
  assertEquals(parsed.paymentCode, "GBA1B2C3D4");
});

Deno.test("rejects malformed or non-positive transactions", async () => {
  await assertRejects(
    async () => {
      parseSePayTransaction({ id: 1 });
    },
    Error,
    "SEPAY_PAYLOAD_UNSUPPORTED",
  );
  await assertRejects(
    async () => {
      parseSePayTransaction({
        id: 1,
        gateway: "Vietcombank",
        accountNumber: "1",
        transferType: "in",
        transferAmount: 0,
      });
    },
    Error,
    "SEPAY_PAYLOAD_UNSUPPORTED",
  );
});
