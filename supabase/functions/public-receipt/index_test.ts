import {
  createPublicReceiptHandler,
  type PublicReceiptDependencies,
} from "./index.ts";

const origin = "https://globospossystem.vercel.app";
const token = "abcdefghijklmnopqrstuvwxyzABCDEF";

function assertEquals(actual: unknown, expected: unknown, message: string) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `${message}: expected ${JSON.stringify(expected)}, got ${
        JSON.stringify(actual)
      }`,
    );
  }
}

function request(
  body: unknown = { token },
  overrides: { method?: string; origin?: string; headers?: HeadersInit } = {},
) {
  return new Request("https://project.test/functions/v1/public-receipt", {
    method: overrides.method ?? "POST",
    headers: {
      Origin: overrides.origin ?? origin,
      "Content-Type": "application/json",
      "x-forwarded-for": "203.0.113.8",
      ...overrides.headers,
    },
    body: (overrides.method ?? "POST") === "POST"
      ? JSON.stringify(body)
      : undefined,
  });
}

function dependencies(
  overrides: Partial<PublicReceiptDependencies> = {},
): PublicReceiptDependencies {
  return {
    allowedOrigins: [origin],
    consumeRateLimit: () => Promise.resolve(true),
    loadReceipt: () => Promise.resolve({ receipt_number: "BC-1" }),
    ...overrides,
  };
}

Deno.test("returns only a no-store receipt to an allowed origin", async () => {
  const response = await createPublicReceiptHandler(dependencies())(request());
  assertEquals(response.status, 200, "success status");
  assertEquals(
    response.headers.get("access-control-allow-origin"),
    origin,
    "exact CORS origin",
  );
  assertEquals(
    response.headers.get("cache-control"),
    "no-store, max-age=0",
    "cache policy",
  );
  assertEquals(
    response.headers.get("referrer-policy"),
    "no-referrer",
    "referrer policy",
  );
  assertEquals(
    (await response.json()).receipt_number,
    "BC-1",
    "receipt payload",
  );
});

Deno.test("blocks other origins and unsupported methods before lookup", async () => {
  let lookups = 0;
  const handler = createPublicReceiptHandler(dependencies({
    loadReceipt: () => {
      lookups += 1;
      return Promise.resolve(null);
    },
  }));
  assertEquals(
    (await handler(request(undefined, { origin: "https://evil.test" }))).status,
    403,
    "foreign origin status",
  );
  assertEquals(
    (await handler(request(undefined, { method: "GET" }))).status,
    405,
    "method status",
  );
  assertEquals(lookups, 0, "lookup count");
});

Deno.test("uses the same safe response for malformed and missing receipts", async () => {
  const handler = createPublicReceiptHandler(dependencies({
    loadReceipt: () => Promise.resolve(null),
  }));
  const malformed = await handler(request({ token: "short" }));
  const missing = await handler(request());
  assertEquals(malformed.status, 404, "malformed status");
  assertEquals(missing.status, 404, "missing status");
  assertEquals(await malformed.json(), await missing.json(), "safe error body");
});

Deno.test("stops rate-limited requests before receipt lookup", async () => {
  let lookups = 0;
  const response = await createPublicReceiptHandler(dependencies({
    consumeRateLimit: () => Promise.resolve(false),
    loadReceipt: () => {
      lookups += 1;
      return Promise.resolve(null);
    },
  }))(request());
  assertEquals(response.status, 429, "rate limit status");
  assertEquals(response.headers.get("retry-after"), "60", "retry header");
  assertEquals(lookups, 0, "lookup count");
});

Deno.test("fails closed without exposing backend errors", async () => {
  const response = await createPublicReceiptHandler(dependencies({
    consumeRateLimit: () => Promise.reject(new Error("contains secret")),
  }))(request());
  assertEquals(response.status, 503, "failure status");
  assertEquals(
    await response.json(),
    { error: "RECEIPT_TEMPORARILY_UNAVAILABLE" },
    "sanitized body",
  );
});
