import {
  clientAddress,
  createDirectOrderHandler,
  directOrderActionRegistry,
  type DirectOrderDependencies,
  directOrderLocale,
  directOrderSecretKeyName,
  normalizeRpcError,
  resolveProjectSecretKey,
  sqlDomainErrorRegistry,
  validateProofImage,
  validProofObjectPath,
  validProofPath,
} from "./index.ts";

const origin = "https://globospossystem.vercel.app";

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
  body: unknown = { action: "storefront", slug: "bunsik-binh-thanh" },
  overrides: {
    method?: string;
    origin?: string | null;
    headers?: HeadersInit;
  } = {},
) {
  const headers = new Headers({
    "Content-Type": "application/json",
    "x-forwarded-for": "203.0.113.19",
    ...overrides.headers,
  });
  if (overrides.origin !== null) {
    headers.set("Origin", overrides.origin ?? origin);
  }
  return new Request(
    "https://project.test/functions/v1/direct-order-public",
    {
      method: overrides.method ?? "POST",
      headers,
      body: (overrides.method ?? "POST") === "POST"
        ? JSON.stringify(body)
        : undefined,
    },
  );
}

function dependencies(
  overrides: Partial<DirectOrderDependencies> = {},
): DirectOrderDependencies {
  return {
    allowedOrigins: [origin],
    consumeRateLimit: () => Promise.resolve(true),
    allowInternalRequest: () => false,
    execute: (action) => Promise.resolve({ action, ok: true }),
    ...overrides,
  };
}

Deno.test("direct order key selector prefers its own name and safely reuses receipt rotation", () => {
  assertEquals(
    directOrderSecretKeyName("direct-runtime", "receipt-runtime"),
    "direct-runtime",
    "dedicated selector",
  );
  assertEquals(
    directOrderSecretKeyName(undefined, "receipt-runtime"),
    "receipt-runtime",
    "existing rotated key selector fallback",
  );
  assertEquals(
    directOrderSecretKeyName("   ", "receipt-runtime"),
    "receipt-runtime",
    "blank dedicated selector",
  );
  assertEquals(
    directOrderSecretKeyName(undefined, undefined),
    "",
    "missing selector fails later in key resolution",
  );
});

Deno.test("returns no-store data only to an allowed storefront origin", async () => {
  const response = await createDirectOrderHandler(dependencies())(request());
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
    await response.json(),
    { data: { action: "storefront", ok: true } },
    "safe response envelope",
  );
});

Deno.test("retired map actions are rejected without calling a provider", async () => {
  let executions = 0;
  const handler = createDirectOrderHandler(dependencies({
    execute: () => {
      executions++;
      return Promise.resolve({});
    },
  }));
  for (
    const action of ["places_autocomplete", "place_details", "reverse_geocode"]
  ) {
    const response = await handler(request({ action }));
    assertEquals(response.status, 400, "retired action rejected");
  }
  assertEquals(executions, 0, "no provider or database execution");
});

Deno.test("caches the exact-origin CORS preflight for chat polling", async () => {
  const response = await createDirectOrderHandler(dependencies())(
    request(undefined, { method: "OPTIONS" }),
  );
  assertEquals(response.status, 204, "preflight status");
  assertEquals(
    response.headers.get("access-control-max-age"),
    "600",
    "preflight cache duration",
  );
  assertEquals(
    response.headers.get("access-control-allow-origin"),
    origin,
    "preflight exact origin",
  );
});

Deno.test("blocks foreign origins and unsupported methods before execute", async () => {
  let executions = 0;
  const handler = createDirectOrderHandler(dependencies({
    execute: () => {
      executions += 1;
      return Promise.resolve({});
    },
  }));
  assertEquals(
    (await handler(request(undefined, { origin: "https://evil.test" }))).status,
    403,
    "foreign origin",
  );
  assertEquals(
    (await handler(request(undefined, { method: "GET" }))).status,
    405,
    "method",
  );
  assertEquals(executions, 0, "execute count");
});

Deno.test("rejects unknown actions and oversized payloads", async () => {
  const handler = createDirectOrderHandler(dependencies());
  const invalid = await handler(request({ action: "drop_database" }));
  assertEquals(invalid.status, 400, "invalid action status");
  assertEquals(
    await invalid.json(),
    { error: "INVALID_ACTION" },
    "invalid action body",
  );

  const oversized = await handler(request(
    { action: "message", message: "x".repeat(65537) },
  ));
  assertEquals(oversized.status, 413, "oversized status");
});

Deno.test("requires JSON and enforces the 64 KiB limit in UTF-8 bytes", async () => {
  const handler = createDirectOrderHandler(dependencies());
  const unsupported = await handler(request(undefined, {
    headers: { "Content-Type": "text/plain" },
  }));
  assertEquals(unsupported.status, 415, "content type status");
  assertEquals(
    await unsupported.json(),
    { error: "UNSUPPORTED_MEDIA_TYPE" },
    "content type body",
  );

  const malformed = await handler(
    new Request(
      "https://project.test/functions/v1/direct-order-public",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Origin: origin,
          "x-forwarded-for": "203.0.113.19",
        },
        body: "{not-json",
      },
    ),
  );
  assertEquals(malformed.status, 400, "malformed JSON status");

  const utf8Oversized = await handler(request({
    action: "message",
    message: "가".repeat(22000),
  }));
  assertEquals(utf8Oversized.status, 413, "UTF-8 byte limit status");
});

Deno.test("action registry is exact and dispatches all 14 boundaries", async () => {
  assertEquals(
    Object.keys(directOrderActionRegistry),
    [
      "storefront",
      "create_session",
      "submit",
      "status",
      "status_v2",
      "orders_v2",
      "message",
      "cancel",
      "proof_upload_url",
      "proof_upload_url_v2",
      "proof_commit",
      "proof_commit_v2",
      "staff_proof_url",
      "cleanup_expired_pii",
    ],
    "action names",
  );
  assertEquals(
    directOrderActionRegistry.proof_upload_url.rateLimit,
    10,
    "proof upload reservation rate class",
  );
  assertEquals(
    directOrderActionRegistry.cleanup_expired_pii.actor,
    "internal",
    "cleanup actor",
  );

  const executed: string[] = [];
  const handler = createDirectOrderHandler(dependencies({
    allowInternalRequest: (_incoming, action) =>
      action === "cleanup_expired_pii",
    execute: (action) => {
      executed.push(action);
      return Promise.resolve({ action });
    },
  }));
  for (const action of Object.keys(directOrderActionRegistry)) {
    const response = await handler(request({ action }));
    assertEquals(response.status, 200, `${action} dispatch status`);
  }
  assertEquals(
    executed,
    Object.keys(directOrderActionRegistry),
    "executed action order",
  );
});

Deno.test("rate limits public actions before executing them", async () => {
  let executions = 0;
  const response = await createDirectOrderHandler(dependencies({
    consumeRateLimit: () => Promise.resolve(false),
    execute: () => {
      executions += 1;
      return Promise.resolve({});
    },
  }))(request());
  assertEquals(response.status, 429, "rate status");
  assertEquals(response.headers.get("retry-after"), "60", "retry header");
  assertEquals(executions, 0, "execute count");
});

Deno.test("missing or malformed client address fails closed", async () => {
  const noAddress = request(undefined, {
    headers: { "x-forwarded-for": "" },
  });
  assertEquals(clientAddress(noAddress), null, "missing client address");
  const oversizedAddress = request(undefined, {
    headers: { "x-forwarded-for": "x".repeat(129) },
  });
  assertEquals(clientAddress(oversizedAddress), null, "oversized address");

  const response = await createDirectOrderHandler(dependencies({
    consumeRateLimit: (incoming) =>
      Promise.resolve(clientAddress(incoming) !== null),
  }))(noAddress);
  assertEquals(response.status, 429, "missing address rate status");
});

Deno.test("staff proof requests skip public rate limiting but still need origin", async () => {
  let rateChecks = 0;
  const handler = createDirectOrderHandler(dependencies({
    consumeRateLimit: () => {
      rateChecks += 1;
      return Promise.resolve(false);
    },
  }));
  const response = await handler(request({ action: "staff_proof_url" }));
  assertEquals(response.status, 200, "staff response");
  assertEquals(rateChecks, 0, "public rate checks");
});

Deno.test("internal cleanup can run without browser origin only when authorized", async () => {
  const handler = createDirectOrderHandler(dependencies({
    allowInternalRequest: (incoming, action) =>
      action === "cleanup_expired_pii" &&
      incoming.headers.get("x-direct-order-cleanup-secret") === "allowed",
  }));
  const denied = await handler(request(
    { action: "cleanup_expired_pii" },
    { origin: null },
  ));
  assertEquals(denied.status, 403, "missing internal secret");
  const allowed = await handler(request(
    { action: "cleanup_expired_pii" },
    {
      origin: null,
      headers: { "x-direct-order-cleanup-secret": "allowed" },
    },
  ));
  assertEquals(allowed.status, 200, "authorized cleanup");
});

Deno.test("backend failures never expose secrets or request data", async () => {
  const logLines: string[] = [];
  const originalError = console.error;
  console.error = (...values: unknown[]) => {
    logLines.push(values.map(String).join(" "));
  };
  let response: Response | null = null;
  try {
    response = await createDirectOrderHandler(dependencies({
      execute: () => Promise.reject(new Error("session-secret-and-address")),
    }))(request());
  } finally {
    console.error = originalError;
  }
  if (!response) throw new Error("handler did not return a response");
  assertEquals(response.status, 503, "failure status");
  assertEquals(
    await response.json(),
    { error: "DIRECT_ORDER_TEMPORARILY_UNAVAILABLE" },
    "sanitized body",
  );
  assertEquals(
    logLines,
    ["direct-order-public failed Error"],
    "sanitized log",
  );
});

Deno.test("SQL errors use an explicit registry and unknown errors are sanitized", () => {
  assertEquals(
    Object.keys(sqlDomainErrorRegistry).length,
    81,
    "registered SQL error count",
  );
  const conflict = normalizeRpcError(
    "duplicate: DIRECT_ORDER_OPEN_REQUEST_EXISTS detail=private",
  );
  assertEquals(conflict.status, 409, "conflict status");
  assertEquals(
    conflict.code,
    "DIRECT_ORDER_OPEN_REQUEST_EXISTS",
    "conflict public code",
  );
  const forbidden = normalizeRpcError("DIRECT_ORDER_FORBIDDEN");
  assertEquals(forbidden.status, 403, "forbidden status");
  assertEquals(forbidden.code, "REQUEST_FORBIDDEN", "forbidden public code");
  const proofReview = normalizeRpcError(
    "DIRECT_ORDER_PROOF_REVIEW_NOT_ALLOWED private detail",
  );
  assertEquals(proofReview.status, 409, "proof review conflict status");
  assertEquals(
    proofReview.code,
    "DIRECT_ORDER_PROOF_REVIEW_NOT_ALLOWED",
    "proof review public code",
  );
  const delivery = normalizeRpcError("DIRECT_ORDER_DELIVERY_NOT_DISPATCHED");
  assertEquals(delivery.status, 409, "delivery completion conflict status");
  const internal = normalizeRpcError(
    "DIRECT_ORDER_FINANCIAL_RECONCILIATION_FAILED sql private detail",
  );
  assertEquals(internal.status, 503, "internal status");
  assertEquals(
    internal.code,
    "DIRECT_ORDER_TEMPORARILY_UNAVAILABLE",
    "internal public code",
  );
  const driverReceiptInternal = normalizeRpcError(
    "DIRECT_ORDER_DRIVER_RECEIPT_PAYLOAD_INVALID private payload",
  );
  assertEquals(driverReceiptInternal.status, 503, "driver receipt status");
  assertEquals(
    driverReceiptInternal.code,
    "DIRECT_ORDER_TEMPORARILY_UNAVAILABLE",
    "driver receipt public code",
  );
  const unknown = normalizeRpcError(
    "DIRECT_ORDER_NEW_INVALID_NOT_FOUND secret address",
  );
  assertEquals(unknown.status, 503, "unknown status");
  assertEquals(
    unknown.code,
    "DIRECT_ORDER_TEMPORARILY_UNAVAILABLE",
    "unknown sanitized code",
  );
});

Deno.test("requires a named modern Supabase project secret key", () => {
  const secret = `sb_secret_${"x".repeat(48)}`;
  assertEquals(
    resolveProjectSecretKey(
      JSON.stringify({ direct_order_edge: secret }),
      "direct_order_edge",
    ),
    secret,
    "resolved key",
  );

  let legacyRejected = false;
  try {
    resolveProjectSecretKey(
      JSON.stringify({ direct_order_edge: "legacy-service-role-jwt" }),
      "direct_order_edge",
    );
  } catch (_) {
    legacyRejected = true;
  }
  assertEquals(legacyRejected, true, "legacy key rejection");
});

Deno.test("validates proof bytes and rejects oversized image dimensions", () => {
  const png = new Uint8Array(24);
  png.set([137, 80, 78, 71, 13, 10, 26, 10]);
  png.set([0, 0, 0, 1], 16);
  png.set([0, 0, 0, 1], 20);
  assertEquals(validateProofImage(png, "png"), true, "small PNG");

  const oversized = png.slice();
  oversized.set([0, 0, 46, 225], 16);
  oversized.set([0, 0, 46, 225], 20);
  assertEquals(
    validateProofImage(oversized, "png"),
    false,
    "oversized dimensions",
  );
  assertEquals(
    validateProofImage(new TextEncoder().encode("not-an-image"), "jpg"),
    false,
    "spoofed file",
  );
});

Deno.test("proof path is bound to the request and a supported image name", () => {
  const storeId = "dd000000-0000-4000-8000-000000000001";
  const requestId = "dd000000-0000-4000-8000-000000000002";
  const objectId = "dd000000-0000-4000-8000-000000000003";
  assertEquals(
    validProofPath(`${storeId}/${requestId}/${objectId}.jpg`, requestId),
    true,
    "valid path",
  );
  assertEquals(
    validProofPath(`${storeId}/${storeId}/${objectId}.jpg`, requestId),
    false,
    "forged request segment",
  );
  assertEquals(
    validProofPath(`${storeId}/${requestId}/${objectId}.pdf`, requestId),
    false,
    "unsupported extension",
  );
  assertEquals(
    validProofObjectPath(`${storeId}/${requestId}/not-a-uuid.jpg`),
    false,
    "malformed orphan candidate",
  );
});

Deno.test("direct order locale accepts only ko vi en", () => {
  for (const locale of ["ko", "vi", "en"] as const) {
    assertEquals(directOrderLocale(locale), locale, `accepted ${locale}`);
  }
  assertEquals(directOrderLocale(undefined, "vi"), "vi", "optional default");
  for (const invalid of [undefined, null, "", "fr", "VI", 1]) {
    let caught: unknown;
    try {
      directOrderLocale(invalid);
    } catch (error) {
      caught = error;
    }
    assertEquals(
      caught instanceof Error ? caught.message : null,
      "INVALID_REQUEST",
      `rejected ${String(invalid)}`,
    );
  }
});
