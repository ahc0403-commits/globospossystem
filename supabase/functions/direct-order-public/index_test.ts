import {
  clientAddress,
  createDirectOrderHandler,
  directOrderActionRegistry,
  directOrderAttachmentSpec,
  type DirectOrderDependencies,
  directOrderDinerCount,
  directOrderLocale,
  directOrderPushSubscriptionArgs,
  directOrderSecretKeyName,
  normalizeRpcError,
  resolveProjectSecretKey,
  SafeHttpError,
  sqlDomainErrorRegistry,
  validateProofImage,
  validProofObjectPath,
  validProofPath,
  verifyProofUpload,
} from "./index.ts";

Deno.test("proof verification retains files on list/download/read failures", async () => {
  const path = "store/request/photo.png";
  for (const stage of ["list", "download", "read"]) {
    let removed = 0;
    const brokenBlob = new Blob([new Uint8Array(24)]);
    if (stage === "read") {
      brokenBlob.arrayBuffer = () => Promise.reject(new Error("interrupted"));
    }
    const storage = {
      list: () =>
        Promise.resolve({
          data: [{ name: "photo.png" }],
          error: stage === "list" ? new Error("temporary") : null,
        }),
      download: () =>
        Promise.resolve({
          data: brokenBlob,
          error: stage === "download" ? new Error("temporary") : null,
        }),
      remove: () => {
        removed++;
        return Promise.resolve({});
      },
    };
    try {
      await verifyProofUpload(storage, path);
      throw new Error("expected failure");
    } catch (error) {
      assertEquals(
        error instanceof SafeHttpError && error.status,
        503,
        `${stage} temporary status`,
      );
      assertEquals(
        error instanceof SafeHttpError && error.code,
        "PROOF_TEMPORARILY_UNAVAILABLE",
        `${stage} public error`,
      );
    }
    assertEquals(removed, 0, `${stage} must not delete valid/unknown bytes`);
  }
});

Deno.test("proof verification distinguishes absent, invalid and valid objects", async () => {
  for (const kind of ["absent", "invalid", "valid"]) {
    let removed = 0;
    let downloaded = 0;
    const png = new Uint8Array(24);
    png.set([137, 80, 78, 71, 13, 10, 26, 10]);
    png.set([0, 0, 0, 1], 16);
    png.set([0, 0, 0, 1], 20);
    const storage = {
      list: () =>
        Promise.resolve({
          data: kind === "absent" ? [] : [{ name: "photo.png" }],
          error: null,
        }),
      download: () => {
        downloaded++;
        return Promise.resolve({
          data: new Blob([kind === "valid" ? png : new Uint8Array(24)]),
          error: null,
        });
      },
      remove: () => {
        removed++;
        return Promise.resolve({});
      },
    };
    let code: unknown = null;
    try {
      await verifyProofUpload(storage, "store/request/photo.png");
    } catch (error) {
      code = error instanceof SafeHttpError ? error.code : "unexpected";
    }
    assertEquals(
      code,
      kind === "absent"
        ? "PROOF_UPLOAD_INCOMPLETE"
        : kind === "invalid"
        ? "INVALID_PROOF"
        : null,
      `${kind} result`,
    );
    assertEquals(removed, kind === "invalid" ? 1 : 0, `${kind} deletion`);
    assertEquals(downloaded, kind === "absent" ? 0 : 1, `${kind} download`);
  }
});

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

Deno.test("action registry is exact and dispatches all supported boundaries", async () => {
  assertEquals(
    Object.keys(directOrderActionRegistry),
    [
      "storefront",
      "storefront_v2",
      "create_session",
      "submit",
      "submit_v2",
      "submit_v3",
      "resume_storefront",
      "decide_pickup",
      "status",
      "status_v2",
      "status_v3",
      "status_v4",
      "status_v5",
      "orders_v2",
      "orders_v3",
      "push_subscription",
      "message",
      "charge_consent",
      "customer_attachment_upload",
      "customer_attachment_commit",
      "customer_attachment_url",
      "staff_attachment_upload",
      "staff_attachment_commit",
      "staff_attachment_url",
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
    135,
    "registered SQL error count",
  );
  assertEquals(
    normalizeRpcError("DIRECT_ORDER_FULFILLMENT_TYPE_LOCKED").status,
    409,
    "fulfillment retry conflict",
  );
  assertEquals(
    normalizeRpcError("DIRECT_ORDER_PICKUP_USE_KDS private detail").status,
    409,
    "pickup preparation requires the quantity queue",
  );
  assertEquals(
    normalizeRpcError("DIRECT_ORDER_PICKUP_ITEMS_REQUIRED private detail").code,
    "DIRECT_ORDER_TEMPORARILY_UNAVAILABLE",
    "broken pickup graph does not expose internal details",
  );
  const packingFailure = normalizeRpcError(
    "DIRECT_ORDER_PACKING_CONTRACT_VERIFICATION_FAILED",
  );
  assertEquals(packingFailure.status, 503, "packing invariant failure status");
  assertEquals(
    packingFailure.code,
    "DIRECT_ORDER_TEMPORARILY_UNAVAILABLE",
    "packing invariant sanitized",
  );
  const detailPrivilegeFailure = normalizeRpcError(
    "DIRECT_ORDER_DETAIL_PRIVILEGES_INVALID private detail",
  );
  assertEquals(detailPrivilegeFailure.status, 503, "detail privilege status");
  assertEquals(
    detailPrivilegeFailure.code,
    "DIRECT_ORDER_TEMPORARILY_UNAVAILABLE",
    "detail privilege failure sanitized",
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
  const changedPhoto = normalizeRpcError("DIRECT_ORDER_PAYMENT_REVIEW_CHANGED");
  assertEquals(changedPhoto.status, 409, "changed payment photo status");
  assertEquals(
    changedPhoto.code,
    "DIRECT_ORDER_PAYMENT_REVIEW_CHANGED",
    "changed payment photo code",
  );
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

Deno.test("diner count accepts whole people and rejects missing or invalid values", () => {
  for (const n of [1, 3, 100]) {
    assertEquals(directOrderDinerCount(n), n, "valid count");
  }
  for (const n of [null, undefined, "3", 0, -1, 101, 1.5, NaN, Infinity]) {
    let rejected = false;
    try {
      directOrderDinerCount(n);
    } catch {
      rejected = true;
    }
    assertEquals(rejected, true, "invalid count rejected");
  }
});

Deno.test("customer push registration validates ownership arguments without forwarding raw secrets", async () => {
  const body = {
    session_id: "d1000000-0000-4000-8000-000000000001",
    device_id: "d1000000-0000-4000-8000-000000000002",
    secret: "s".repeat(43),
    locale: "ko",
    enabled: true,
    token: "fixture_token_0123456789",
  };
  const args = await directOrderPushSubscriptionArgs(body);
  assertEquals(args.p_session_id, body.session_id, "session identity");
  assertEquals(String(args.p_secret_hash).length, 64, "hashed session proof");
  assertEquals("secret" in args, false, "raw secret excluded");
  assertEquals(args.p_token, body.token, "token bound to validated session");
  assertEquals(
    (await directOrderPushSubscriptionArgs({
      ...body,
      enabled: false,
      token: undefined,
    })).p_token,
    null,
    "unsubscribe needs no token",
  );
  for (
    const invalid of [
      { ...body, enabled: "true" },
      { ...body, token: "short" },
      { ...body, locale: "xx" },
      { ...body, device_id: "bad" },
    ]
  ) {
    let status = 0;
    try {
      await directOrderPushSubscriptionArgs(invalid);
    } catch (error) {
      if (error instanceof SafeHttpError) status = error.status;
    }
    assertEquals(status, 400, "invalid push input rejected");
  }
});

Deno.test("chat attachments bind storage scope and permit staff PDFs only", () => {
  const store = "11111111-1111-4111-8111-111111111111",
    request = "22222222-2222-4222-8222-222222222222",
    file = "33333333-3333-4333-8333-333333333333";
  const pdf = {
    filename: "../proof.pdf",
    mime_type: "application/pdf",
    path: `${store}/${request}/${file}.pdf`,
  };
  assertEquals(
    directOrderAttachmentSpec(pdf, store, request, true).filename,
    ".._proof.pdf",
    "filename sanitized",
  );
  for (
    const [body, staff] of [
      [pdf, false],
      [{
        ...pdf,
        path: `${store}/44444444-4444-4444-8444-444444444444/${file}.pdf`,
      }, true],
      [{ ...pdf, mime_type: "text/html" }, true],
      [{ ...pdf, path: `${store}/${request}/../${file}.pdf` }, true],
    ] as const
  ) {
    let code = "";
    try {
      directOrderAttachmentSpec(body, store, request, staff);
    } catch (e) {
      code = e instanceof SafeHttpError ? e.code : "unexpected";
    }
    assertEquals(
      code,
      "DIRECT_ORDER_ATTACHMENT_INVALID",
      "unsafe file rejected before token issuance",
    );
  }
  const jpeg = {
    filename: "photo.jpeg",
    mime_type: "image/jpeg",
    path: `${store}/${request}/${file}.jpeg`,
  };
  assertEquals(
    directOrderAttachmentSpec(jpeg, store, request, false).extension,
    "jpeg",
    "JPEG supported",
  );
});
