import { serve } from "@std/http/server";
import { createClient } from "@supabase/supabase-js";

export type JsonObject = Record<string, unknown>;
type RpcClient = {
  rpc: (
    name: string,
    payload: JsonObject,
  ) => Promise<{ data: unknown; error: { message?: string } | null }>;
};

export type DirectOrderDependencies = {
  allowedOrigins: readonly string[];
  consumeRateLimit: (request: Request, action: string) => Promise<boolean>;
  allowInternalRequest: (request: Request, action: string) => boolean;
  execute: (
    action: string,
    body: JsonObject,
    request: Request,
  ) => Promise<unknown>;
};

export class SafeHttpError extends Error {
  constructor(public status: number, public code: string) {
    super(code);
    this.name = "SafeHttpError";
  }
}

export const directOrderActionRegistry = Object.freeze(
  {
    storefront: { actor: "public", rateLimit: 60 },
    storefront_v2: { actor: "public", rateLimit: 60 },
    create_session: { actor: "public", rateLimit: 60 },
    submit: { actor: "public", rateLimit: 60 },
    submit_v2: { actor: "public", rateLimit: 60 },
    submit_v3: { actor: "public", rateLimit: 60 },
    resume_storefront: { actor: "public", rateLimit: 60 },
    decide_pickup: { actor: "public", rateLimit: 60 },
    status: { actor: "public", rateLimit: 60 },
    status_v2: { actor: "public", rateLimit: 60 },
    status_v3: { actor: "public", rateLimit: 60 },
    status_v4: { actor: "public", rateLimit: 60 },
    status_v5: { actor: "public", rateLimit: 60 },
    orders_v2: { actor: "public", rateLimit: 60 },
    orders_v3: { actor: "public", rateLimit: 60 },
    push_subscription: { actor: "public", rateLimit: 10 },
    message: { actor: "public", rateLimit: 60 },
    charge_consent: { actor: "public", rateLimit: 30 },
    customer_attachment_upload: { actor: "public", rateLimit: 10 },
    customer_attachment_commit: { actor: "public", rateLimit: 30 },
    customer_attachment_url: { actor: "public", rateLimit: 60 },
    staff_attachment_upload: { actor: "staff", rateLimit: null },
    staff_attachment_commit: { actor: "staff", rateLimit: null },
    staff_attachment_url: { actor: "staff", rateLimit: null },
    cancel: { actor: "public", rateLimit: 60 },
    proof_upload_url: { actor: "public", rateLimit: 10 },
    proof_upload_url_v2: { actor: "public", rateLimit: 10 },
    proof_commit: { actor: "public", rateLimit: 60 },
    proof_commit_v2: { actor: "public", rateLimit: 60 },
    staff_proof_url: { actor: "staff", rateLimit: null },
    cleanup_expired_pii: { actor: "internal", rateLimit: null },
  } as const,
);

const publicActions = new Set(
  Object.entries(directOrderActionRegistry)
    .filter(([, contract]) => contract.actor === "public")
    .map(([action]) => action),
);
const internalActions = new Set(
  Object.entries(directOrderActionRegistry)
    .filter(([, contract]) => contract.actor === "internal")
    .map(([action]) => action),
);
const allActions = new Set(Object.keys(directOrderActionRegistry));

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const slugPattern = /^[a-z0-9][a-z0-9-]{2,62}$/;
const secretPattern = /^[A-Za-z0-9_-]{40,128}$/;
const allowedProofTypes = new Map([
  ["image/jpeg", "jpg"],
  ["image/png", "png"],
  ["image/webp", "webp"],
]);

function proofDimensions(
  bytes: Uint8Array,
  extension: string,
): { width: number; height: number } | null {
  if (extension === "png") {
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (
      bytes.length < 24 ||
      !signature.every((value, index) => bytes[index] === value)
    ) return null;
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    return { width: view.getUint32(16), height: view.getUint32(20) };
  }
  if (extension === "jpg") {
    if (bytes.length < 12 || bytes[0] !== 0xff || bytes[1] !== 0xd8) {
      return null;
    }
    const sofMarkers = new Set([
      0xc0,
      0xc1,
      0xc2,
      0xc3,
      0xc5,
      0xc6,
      0xc7,
      0xc9,
      0xca,
      0xcb,
      0xcd,
      0xce,
      0xcf,
    ]);
    for (let index = 2; index + 8 < bytes.length;) {
      if (bytes[index] !== 0xff) {
        index += 1;
        continue;
      }
      while (index < bytes.length && bytes[index] === 0xff) index += 1;
      if (index >= bytes.length) return null;
      const marker = bytes[index++];
      if (marker === 0xd8 || marker === 0xd9 || marker === 0x01) continue;
      if (marker >= 0xd0 && marker <= 0xd7) continue;
      if (index + 1 >= bytes.length) return null;
      const length = (bytes[index] << 8) | bytes[index + 1];
      if (length < 2 || index + length > bytes.length) return null;
      if (sofMarkers.has(marker) && length >= 7) {
        return {
          height: (bytes[index + 3] << 8) | bytes[index + 4],
          width: (bytes[index + 5] << 8) | bytes[index + 6],
        };
      }
      index += length;
    }
    return null;
  }
  if (extension === "webp") {
    if (
      bytes.length < 30 ||
      String.fromCharCode(...bytes.slice(0, 4)) !== "RIFF" ||
      String.fromCharCode(...bytes.slice(8, 12)) !== "WEBP"
    ) return null;
    const chunk = String.fromCharCode(...bytes.slice(12, 16));
    if (chunk === "VP8X") {
      return {
        width: 1 + bytes[24] + (bytes[25] << 8) + (bytes[26] << 16),
        height: 1 + bytes[27] + (bytes[28] << 8) + (bytes[29] << 16),
      };
    }
    if (chunk === "VP8L" && bytes[20] === 0x2f) {
      return {
        width: 1 + bytes[21] + ((bytes[22] & 0x3f) << 8),
        height: 1 + ((bytes[22] & 0xc0) >> 6) +
          (bytes[23] << 2) + ((bytes[24] & 0x0f) << 10),
      };
    }
    if (
      chunk === "VP8 " && bytes[23] === 0x9d && bytes[24] === 0x01 &&
      bytes[25] === 0x2a
    ) {
      return {
        width: (bytes[26] | (bytes[27] << 8)) & 0x3fff,
        height: (bytes[28] | (bytes[29] << 8)) & 0x3fff,
      };
    }
  }
  return null;
}

export function validateProofImage(
  bytes: Uint8Array,
  extension: string,
): boolean {
  if (bytes.length < 12 || bytes.length > 5242880) return false;
  const dimensions = proofDimensions(bytes, extension);
  if (!dimensions) return false;
  const { width, height } = dimensions;
  return width > 0 && height > 0 && width <= 12000 && height <= 12000 &&
    width * height <= 25000000;
}

export function resolveProjectSecretKey(
  rawSecretKeys: string,
  configuredName: string,
): string {
  const keyName = configuredName.trim();
  if (!keyName || keyName.length > 128) {
    throw new Error("PROJECT_SECRET_KEY_NAME_INVALID");
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawSecretKeys);
  } catch (_) {
    throw new Error("PROJECT_SECRET_KEYS_INVALID");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("PROJECT_SECRET_KEYS_INVALID");
  }
  const key = (parsed as JsonObject)[keyName];
  if (
    typeof key !== "string" || !key.startsWith("sb_secret_") ||
    key.length < 32
  ) {
    throw new Error("PROJECT_SECRET_KEY_MISSING");
  }
  return key;
}

function allowedOrigin(
  request: Request,
  allowedOrigins: readonly string[],
): string | null {
  const origin = request.headers.get("Origin") ?? "";
  return allowedOrigins.includes(origin) ? origin : null;
}

function securityHeaders(
  request: Request,
  allowedOrigins: readonly string[],
): Record<string, string> {
  const origin = allowedOrigin(request, allowedOrigins);
  return {
    ...(origin ? { "Access-Control-Allow-Origin": origin } : {}),
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type, x-direct-order-cleanup-secret",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "600",
    "Cache-Control": "no-store, max-age=0",
    "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
    "Content-Type": "application/json; charset=utf-8",
    "Cross-Origin-Resource-Policy": "same-site",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "X-Robots-Tag": "noindex, nofollow, noarchive, nosnippet",
    Vary: "Origin",
  };
}

function jsonResponse(
  request: Request,
  allowedOrigins: readonly string[],
  status: number,
  payload: JsonObject,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      ...securityHeaders(request, allowedOrigins),
      ...extraHeaders,
    },
  });
}

export function createDirectOrderHandler(
  dependencies: DirectOrderDependencies,
) {
  return async (request: Request): Promise<Response> => {
    const { allowedOrigins } = dependencies;
    if (request.method === "OPTIONS") {
      if (!allowedOrigin(request, allowedOrigins)) {
        return jsonResponse(request, allowedOrigins, 403, {
          error: "REQUEST_FORBIDDEN",
        });
      }
      return new Response(null, {
        status: 204,
        headers: securityHeaders(request, allowedOrigins),
      });
    }
    if (request.method !== "POST") {
      return jsonResponse(request, allowedOrigins, 405, {
        error: "METHOD_NOT_ALLOWED",
      });
    }

    const contentType = request.headers.get("Content-Type")
      ?.split(";", 1)[0]
      ?.trim()
      .toLowerCase();
    if (contentType !== "application/json") {
      return jsonResponse(request, allowedOrigins, 415, {
        error: "UNSUPPORTED_MEDIA_TYPE",
      });
    }

    const contentLength = Number(request.headers.get("Content-Length") ?? 0);
    if (Number.isFinite(contentLength) && contentLength > 65536) {
      return jsonResponse(request, allowedOrigins, 413, {
        error: "REQUEST_TOO_LARGE",
      });
    }

    let body: JsonObject;
    try {
      const rawBody = await request.text();
      if (new TextEncoder().encode(rawBody).byteLength > 65536) {
        return jsonResponse(request, allowedOrigins, 413, {
          error: "REQUEST_TOO_LARGE",
        });
      }
      const parsed = JSON.parse(rawBody);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        throw new Error("INVALID_REQUEST");
      }
      body = parsed as JsonObject;
    } catch (_) {
      return jsonResponse(request, allowedOrigins, 400, {
        error: "INVALID_REQUEST",
      });
    }

    const action = typeof body.action === "string" ? body.action : "";
    if (!allActions.has(action)) {
      return jsonResponse(request, allowedOrigins, 400, {
        error: "INVALID_ACTION",
      });
    }

    const internal = dependencies.allowInternalRequest(request, action);
    if (!internal && !allowedOrigin(request, allowedOrigins)) {
      return jsonResponse(request, allowedOrigins, 403, {
        error: "REQUEST_FORBIDDEN",
      });
    }
    if (internalActions.has(action) && !internal) {
      return jsonResponse(request, allowedOrigins, 401, {
        error: "UNAUTHORIZED",
      });
    }

    try {
      if (
        publicActions.has(action) &&
        !await dependencies.consumeRateLimit(request, action)
      ) {
        return jsonResponse(
          request,
          allowedOrigins,
          429,
          { error: "TOO_MANY_REQUESTS" },
          { "Retry-After": "60" },
        );
      }
      const data = await dependencies.execute(action, body, request);
      return jsonResponse(request, allowedOrigins, 200, {
        data: data ?? null,
      });
    } catch (error) {
      if (error instanceof SafeHttpError) {
        return jsonResponse(request, allowedOrigins, error.status, {
          error: error.code,
        });
      }
      // Never log request bodies, session secrets, addresses, proof paths,
      // Google responses, bank data, or signed URLs.
      console.error(
        "direct-order-public failed",
        error instanceof Error ? error.name : "unknown",
      );
      return jsonResponse(request, allowedOrigins, 503, {
        error: "DIRECT_ORDER_TEMPORARILY_UNAVAILABLE",
      });
    }
  };
}

function requiredString(
  body: JsonObject,
  key: string,
  maxLength: number,
  pattern?: RegExp,
): string {
  const value = typeof body[key] === "string" ? body[key].trim() : "";
  if (!value || value.length > maxLength || (pattern && !pattern.test(value))) {
    throw new SafeHttpError(400, "INVALID_REQUEST");
  }
  return value;
}

function requiredUuid(body: JsonObject, key: string): string {
  return requiredString(body, key, 36, uuidPattern).toLowerCase();
}

export function directOrderLocale(
  value: unknown,
  defaultLocale?: "vi",
): "ko" | "vi" | "en" {
  if (value == null && defaultLocale != null) return defaultLocale;
  if (value === "ko" || value === "vi" || value === "en") return value;
  throw new SafeHttpError(400, "INVALID_REQUEST");
}

export async function directOrderPushSubscriptionArgs(
  body: JsonObject,
): Promise<JsonObject> {
  const sessionId = requiredUuid(body, "session_id");
  const secret = requiredString(body, "secret", 128, secretPattern);
  const deviceId = requiredUuid(body, "device_id");
  const locale = directOrderLocale(body.locale);
  if (typeof body.enabled !== "boolean") {
    throw new SafeHttpError(400, "INVALID_REQUEST");
  }
  const token = body.enabled
    ? requiredString(body, "token", 2048, /^[A-Za-z0-9_:\-]+$/)
    : null;
  if (token != null && token.length < 16) {
    throw new SafeHttpError(400, "INVALID_REQUEST");
  }
  return {
    p_session_id: sessionId,
    p_secret_hash: await sha256Hex(secret),
    p_device_id: deviceId,
    p_token: token,
    p_locale: locale,
    p_enabled: body.enabled,
  };
}

function configuredOrigins(): string[] {
  return (Deno.env.get("ALLOWED_ORIGINS") ?? "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
}

export function clientAddress(request: Request): string | null {
  const forwarded = request.headers.get("x-forwarded-for")
    ?.split(",")[0]
    ?.trim();
  const candidate = forwarded ||
    request.headers.get("x-real-ip")?.trim() ||
    request.headers.get("cf-connecting-ip")?.trim() ||
    "";
  return candidate.length > 0 && candidate.length <= 128 ? candidate : null;
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

async function hmacSha256Hex(value: string, secret: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(value),
  );
  return Array.from(new Uint8Array(signature))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function randomSecret(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const binary = String.fromCharCode(...bytes);
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

type SqlErrorContract = Readonly<{ status: number; publicCode: string }>;

const invalidRequest = (publicCode: string): SqlErrorContract => ({
  status: 400,
  publicCode,
});
const forbidden = (publicCode: string): SqlErrorContract => ({
  status: 403,
  publicCode,
});
const unavailable = (publicCode: string): SqlErrorContract => ({
  status: 404,
  publicCode,
});
const conflict = (publicCode: string): SqlErrorContract => ({
  status: 409,
  publicCode,
});
const internalFailure: SqlErrorContract = {
  status: 503,
  publicCode: "DIRECT_ORDER_TEMPORARILY_UNAVAILABLE",
};

// This is the single public mapping for every DIRECT_ORDER_*/DIRECT_DELIVERY_*
// SQL exception in the direct migration. Do not infer a status from substrings:
// adding a SQL domain error requires adding an explicit entry and tests.
export const sqlDomainErrorRegistry: Readonly<
  Record<string, SqlErrorContract>
> = Object.freeze({
  DIRECT_ORDER_ACTOR_INPUT_REQUIRED: invalidRequest("INVALID_REQUEST"),
  DIRECT_ORDER_FORBIDDEN: forbidden("REQUEST_FORBIDDEN"),
  DIRECT_ORDER_RATE_INPUT_INVALID: invalidRequest("INVALID_REQUEST"),
  DIRECT_ORDER_SESSION_INPUT_INVALID: invalidRequest("INVALID_REQUEST"),
  DIRECT_ORDER_STOREFRONT_NOT_FOUND: unavailable("DIRECT_ORDER_UNAVAILABLE"),
  DIRECT_ORDER_SESSION_INVALID: unavailable("DIRECT_ORDER_UNAVAILABLE"),
  DIRECT_ORDER_REQUEST_INPUT_INVALID: invalidRequest("INVALID_REQUEST"),
  DIRECT_ORDER_FULFILLMENT_TYPE_LOCKED: conflict(
    "DIRECT_ORDER_FULFILLMENT_TYPE_LOCKED",
  ),
  DIRECT_ORDER_PICKUP_FEE_INVALID: invalidRequest("INVALID_REQUEST"),
  DIRECT_ORDER_PICKUP_DISPATCH_FORBIDDEN: conflict(
    "DIRECT_ORDER_PICKUP_DISPATCH_FORBIDDEN",
  ),
  DIRECT_ORDER_PICKUP_NOT_APPROVED: conflict(
    "DIRECT_ORDER_PICKUP_NOT_APPROVED",
  ),
  DIRECT_ORDER_PICKUP_NOT_READY: conflict("DIRECT_ORDER_PICKUP_NOT_READY"),
  DIRECT_ORDER_PICKUP_KDS_SESSION_REQUIRED: conflict(
    "DIRECT_ORDER_PICKUP_KDS_SESSION_REQUIRED",
  ),
  DIRECT_ORDER_PICKUP_ITEMS_REQUIRED: internalFailure,
  DIRECT_ORDER_PICKUP_FLOOR_FORBIDDEN: forbidden("REQUEST_FORBIDDEN"),
  DIRECT_ORDER_PICKUP_HANDOFF_FINALIZED: conflict(
    "DIRECT_ORDER_PICKUP_HANDOFF_FINALIZED",
  ),
  DIRECT_ORDER_PICKUP_USE_KDS: conflict("DIRECT_ORDER_PICKUP_USE_KDS"),
  DIRECT_ORDER_STOREFRONT_PAUSED: conflict("DIRECT_ORDER_STOREFRONT_PAUSED"),
  DIRECT_ORDER_OUTSIDE_HOURS: conflict("DIRECT_ORDER_OUTSIDE_HOURS"),
  DIRECT_ORDER_OPEN_REQUEST_EXISTS: conflict(
    "DIRECT_ORDER_OPEN_REQUEST_EXISTS",
  ),
  DIRECT_ORDER_ADDRESS_INVALID: invalidRequest("DIRECT_ORDER_ADDRESS_INVALID"),
  DIRECT_ORDER_ITEM_INVALID: invalidRequest("DIRECT_ORDER_ITEM_INVALID"),
  DIRECT_ORDER_MENU_UNAVAILABLE: conflict("DIRECT_ORDER_MENU_UNAVAILABLE"),
  DIRECT_ORDER_QUANTITY_LIMIT: invalidRequest("DIRECT_ORDER_QUANTITY_LIMIT"),
  DIRECT_ORDER_REQUEST_NOT_CHATABLE: conflict(
    "DIRECT_ORDER_REQUEST_NOT_CHATABLE",
  ),
  DIRECT_ORDER_MESSAGE_INVALID: invalidRequest("DIRECT_ORDER_MESSAGE_INVALID"),
  DIRECT_ORDER_REQUEST_NOT_FOUND: unavailable("DIRECT_ORDER_UNAVAILABLE"),
  DIRECT_ORDER_REQUEST_NOT_CANCELLABLE: conflict(
    "DIRECT_ORDER_REQUEST_NOT_CANCELLABLE",
  ),
  DIRECT_ORDER_PROOF_NOT_ALLOWED: conflict("DIRECT_ORDER_PROOF_NOT_ALLOWED"),
  DIRECT_ORDER_PROOF_NOT_FOUND: unavailable("DIRECT_ORDER_PROOF_NOT_FOUND"),
  DIRECT_ORDER_PROOF_REVIEW_INPUT_INVALID: invalidRequest("INVALID_REQUEST"),
  DIRECT_ORDER_PROOF_REVIEW_NOT_ALLOWED: conflict(
    "DIRECT_ORDER_PROOF_REVIEW_NOT_ALLOWED",
  ),
  DIRECT_ORDER_PROOF_REVIEW_ALREADY_OPEN: conflict(
    "DIRECT_ORDER_PROOF_REVIEW_ALREADY_OPEN",
  ),
  DIRECT_ORDER_PROOF_RESUBMISSION_PENDING: conflict(
    "DIRECT_ORDER_PROOF_RESUBMISSION_PENDING",
  ),
  DIRECT_ORDER_QUOTE_EXPIRED: conflict("DIRECT_ORDER_QUOTE_EXPIRED"),
  DIRECT_ORDER_PROOF_PATH_INVALID: invalidRequest("INVALID_PROOF"),
  DIRECT_ORDER_LIMIT_INVALID: invalidRequest("INVALID_REQUEST"),
  DIRECT_ORDER_FULFILLMENT_INVALID: invalidRequest("INVALID_REQUEST"),
  DIRECT_ORDER_PUSH_INPUT_INVALID: invalidRequest("INVALID_REQUEST"),
  DIRECT_ORDER_PUSH_DEVICE_LIMIT: conflict("DIRECT_ORDER_PUSH_DEVICE_LIMIT"),
  DIRECT_ORDER_KDS_READY_ANCHOR_DRIFT: internalFailure,
  DIRECT_ORDER_CUSTOMER_EXPERIENCE_CONTRACT_FAILED: internalFailure,
  DIRECT_ORDER_QUOTE_INPUT_INVALID: invalidRequest("INVALID_REQUEST"),
  DIRECT_ORDER_REQUEST_NOT_QUOTABLE: conflict(
    "DIRECT_ORDER_REQUEST_NOT_QUOTABLE",
  ),
  DIRECT_ORDER_STOREFRONT_DISABLED: conflict(
    "DIRECT_ORDER_STOREFRONT_DISABLED",
  ),
  DIRECT_ORDER_ACCOUNTING_APPROVAL_REQUIRED: conflict(
    "DIRECT_ORDER_STOREFRONT_DISABLED",
  ),
  DIRECT_ORDER_MENU_CHANGED: conflict("DIRECT_ORDER_MENU_CHANGED"),
  DIRECT_ORDER_BELOW_MINIMUM: conflict("DIRECT_ORDER_BELOW_MINIMUM"),
  DIRECT_ORDER_REJECTION_REASON_INVALID: invalidRequest("INVALID_REQUEST"),
  DIRECT_ORDER_REQUEST_NOT_REJECTABLE: conflict(
    "DIRECT_ORDER_REQUEST_NOT_REJECTABLE",
  ),
  DIRECT_ORDER_QUOTE_NOT_FOUND: unavailable("DIRECT_ORDER_UNAVAILABLE"),
  DIRECT_ORDER_SEPAY_CANDIDATE_INVALID: conflict(
    "DIRECT_ORDER_SEPAY_CANDIDATE_INVALID",
  ),
  DIRECT_ORDER_APPROVAL_INPUT_INVALID: invalidRequest("INVALID_REQUEST"),
  DIRECT_ORDER_REQUEST_NOT_APPROVABLE: conflict(
    "DIRECT_ORDER_REQUEST_NOT_APPROVABLE",
  ),
  DIRECT_ORDER_APPROVAL_CUTOFF: conflict("DIRECT_ORDER_APPROVAL_CUTOFF"),
  DIRECT_ORDER_REQUIRES_POS_PRINT: conflict("DIRECT_ORDER_REQUIRES_POS_PRINT"),
  DIRECT_ORDER_EMERGENCY_ACTIVE: conflict("DIRECT_ORDER_EMERGENCY_ACTIVE"),
  DIRECT_ORDER_PROMOTION_ACTIVE: conflict("DIRECT_ORDER_PROMOTION_ACTIVE"),
  DIRECT_ORDER_PAYMENT_AMOUNT_MISMATCH: conflict(
    "DIRECT_ORDER_PAYMENT_AMOUNT_MISMATCH",
  ),
  DIRECT_ORDER_PAYMENT_PROOF_REQUIRED: conflict(
    "DIRECT_ORDER_PAYMENT_PROOF_REQUIRED",
  ),
  DIRECT_ORDER_PAYMENT_REVIEW_CHANGED: conflict(
    "DIRECT_ORDER_PAYMENT_REVIEW_CHANGED",
  ),
  DIRECT_ORDER_VERIFIED_PAYMENT_REQUIRED: conflict(
    "DIRECT_ORDER_VERIFIED_PAYMENT_REQUIRED",
  ),
  DIRECT_ORDER_SEPAY_TRANSACTION_ALREADY_USED: conflict(
    "DIRECT_ORDER_SEPAY_TRANSACTION_ALREADY_USED",
  ),
  DIRECT_ORDER_CUSTOMER_DIRECT_FEE_MUST_BE_EMPTY: invalidRequest(
    "INVALID_REQUEST",
  ),
  DIRECT_ORDER_DELIVERY_PAYMENT_MODE_CONFLICT: conflict(
    "DIRECT_ORDER_DELIVERY_PAYMENT_MODE_CONFLICT",
  ),
  DIRECT_ORDER_FINANCIAL_RECONCILIATION_FAILED: internalFailure,
  DIRECT_ORDER_DRIVER_RECEIPT_ADDRESS_UNAVAILABLE: internalFailure,
  DIRECT_ORDER_DRIVER_RECEIPT_DESTINATION_INVALID: internalFailure,
  DIRECT_ORDER_DRIVER_RECEIPT_ITEMS_UNAVAILABLE: internalFailure,
  DIRECT_ORDER_DRIVER_RECEIPT_PAYLOAD_INVALID: internalFailure,
  DIRECT_ORDER_DRIVER_RECEIPT_REPRINT_NOT_AVAILABLE: internalFailure,
  DIRECT_ORDER_CUSTOMER_RECEIPT_REPRINT_NOT_AVAILABLE: conflict(
    "DIRECT_ORDER_CUSTOMER_RECEIPT_REPRINT_NOT_AVAILABLE",
  ),
  DIRECT_ORDER_DRIVER_RECEIPT_TOTAL_MISMATCH: internalFailure,
  DIRECT_ORDER_DRIVER_RECEIPT_USE_DEDICATED_REPRINT: internalFailure,
  DIRECT_DELIVERY_TICKET_NOT_FOUND: unavailable("DIRECT_ORDER_UNAVAILABLE"),
  DIRECT_DELIVERY_TICKET_VERSION_CONFLICT: conflict(
    "DIRECT_DELIVERY_TICKET_VERSION_CONFLICT",
  ),
  DIRECT_DELIVERY_TICKET_TRANSITION_INVALID: conflict(
    "DIRECT_DELIVERY_TICKET_TRANSITION_INVALID",
  ),
  DIRECT_ORDER_DELIVERY_NOT_DISPATCHED: conflict(
    "DIRECT_ORDER_DELIVERY_NOT_DISPATCHED",
  ),
  DIRECT_ORDER_DISPATCH_INPUT_INVALID: invalidRequest("INVALID_REQUEST"),
  DIRECT_ORDER_CASH_PAYOUT_LOCKED: conflict(
    "DIRECT_ORDER_CASH_PAYOUT_LOCKED",
  ),
  DIRECT_ORDER_NOT_APPROVED: conflict("DIRECT_ORDER_NOT_APPROVED"),
  DIRECT_ORDER_ANALYTICS_RANGE_INVALID: invalidRequest("INVALID_REQUEST"),
  DIRECT_ORDER_CLEANUP_INPUT_INVALID: invalidRequest("INVALID_REQUEST"),
  DIRECT_ORDER_CLEANUP_NOT_ELIGIBLE: conflict(
    "DIRECT_ORDER_CLEANUP_NOT_ELIGIBLE",
  ),
  DIRECT_ORDER_CLEANUP_TOO_EARLY: conflict("DIRECT_ORDER_CLEANUP_TOO_EARLY"),
  DIRECT_ORDER_CLEANUP_LIMIT_INVALID: invalidRequest("INVALID_REQUEST"),
  DIRECT_ORDER_PUBLIC_FUNCTION_PRIVILEGE_LEAK: internalFailure,
  DIRECT_ORDER_PREFLIGHT_TABLE_MISSING: internalFailure,
  DIRECT_ORDER_RLS_DISABLED: internalFailure,
  DIRECT_ORDER_PROOF_BUCKET_INVALID: internalFailure,
  DIRECT_ORDER_PAYMENT_ANCHOR_MISSING: internalFailure,
  DIRECT_ORDER_VERIFIED_PAYMENT_MIGRATION_BLOCKED: internalFailure,
  DIRECT_ORDER_VERIFIED_PAYMENT_MIGRATION_FAILED: internalFailure,
  DIRECT_ORDER_PILOT_SAFETY_MIGRATION_FAILED: internalFailure,
  DIRECT_ORDER_PILOT_SAFETY_VERIFY_FAILED: internalFailure,
  DIRECT_ORDER_CUSTOMER_STATUS_MIGRATION_FAILED: internalFailure,
  DIRECT_ORDER_CUSTOMER_STATUS_MIGRATION_VERIFY_FAILED: internalFailure,
  DIRECT_ORDER_DETAIL_PRIVILEGES_INVALID: internalFailure,
  DIRECT_ORDER_DINER_COUNT_INVALID: invalidRequest(
    "DIRECT_ORDER_DINER_COUNT_INVALID",
  ),
  DIRECT_ORDER_PICKUP_INPUT_INVALID: invalidRequest(
    "DIRECT_ORDER_PICKUP_INPUT_INVALID",
  ),
  DIRECT_ORDER_FULFILLMENT_CHANGED: conflict(
    "DIRECT_ORDER_FULFILLMENT_CHANGED",
  ),
  DIRECT_ORDER_PICKUP_NOT_ALLOWED: conflict("DIRECT_ORDER_PICKUP_NOT_ALLOWED"),
  DIRECT_ORDER_REFUND_NOT_DUE: conflict("DIRECT_ORDER_REFUND_NOT_DUE"),
  DIRECT_ORDER_REFUND_RECONCILIATION_REQUIRED: conflict(
    "DIRECT_ORDER_REFUND_RECONCILIATION_REQUIRED",
  ),
  DIRECT_ORDER_PICKUP_OFFER_PENDING: conflict(
    "DIRECT_ORDER_PICKUP_OFFER_PENDING",
  ),
  DIRECT_ORDER_ACTIVE_REQUESTS_EXIST: conflict(
    "DIRECT_ORDER_ACTIVE_REQUESTS_EXIST",
  ),
  DIRECT_ORDER_PACKING_CONTRACT_VERIFICATION_FAILED: internalFailure,
  DIRECT_ORDER_FALLBACK_ANCHOR_DRIFT: internalFailure,
  DIRECT_ORDER_FALLBACK_VERIFICATION_FAILED: internalFailure,
  DIRECT_ORDER_QUOTE_CHANGED: conflict("DIRECT_ORDER_QUOTE_CHANGED"),
  DIRECT_ORDER_ADDRESS_ANCHOR_DRIFT: internalFailure,
  DIRECT_ORDER_ANALYTICS_ANCHOR_DRIFT: internalFailure,
  DIRECT_ORDER_CLEANUP_ANCHOR_DRIFT: internalFailure,
  DIRECT_ORDER_LIST_ANCHOR_DRIFT: internalFailure,
  DIRECT_ORDER_PUSH_ANCHOR_DRIFT: internalFailure,
  DIRECT_ORDER_QUOTE_ANCHOR_DRIFT: internalFailure,
  DIRECT_ORDER_RECEIPT_ANCHOR_DRIFT: internalFailure,
  DIRECT_ORDER_PAYMENT_ANCHOR_CHANGED: internalFailure,
  DIRECT_ORDER_SUPPORT_VERIFICATION_FAILED: internalFailure,
  DIRECT_ORDER_CHARGE_CHANGED: conflict("DIRECT_ORDER_CHARGE_CHANGED"),
  DIRECT_ORDER_CHARGE_INVALID: conflict("DIRECT_ORDER_CHARGE_INVALID"),
  DIRECT_ORDER_ATTACHMENT_INVALID: conflict("DIRECT_ORDER_ATTACHMENT_INVALID"),
  DIRECT_ORDER_SUPPORT_CHANGED: conflict("DIRECT_ORDER_SUPPORT_CHANGED"),
  DIRECT_ORDER_SUPPORT_INPUT_INVALID: conflict(
    "DIRECT_ORDER_SUPPORT_INPUT_INVALID",
  ),
  DIRECT_ORDER_INVOICE_INVALID: conflict("DIRECT_ORDER_INVOICE_INVALID"),
  DIRECT_ORDER_RECEIPT_INVALID: conflict("DIRECT_ORDER_RECEIPT_INVALID"),
  DIRECT_ORDER_ALREADY_PAID: conflict("DIRECT_ORDER_ALREADY_PAID"),
  DIRECT_ORDER_AMOUNT_EXCEEDS_DUE: conflict("DIRECT_ORDER_AMOUNT_EXCEEDS_DUE"),
  DIRECT_ORDER_AMOUNT_MISMATCH: conflict("DIRECT_ORDER_AMOUNT_MISMATCH"),
  DIRECT_ORDER_PAYMENT_PENDING: conflict("DIRECT_ORDER_PAYMENT_PENDING"),
  DIRECT_ORDER_REFUND_NOT_ALLOWED: conflict("DIRECT_ORDER_REFUND_NOT_ALLOWED"),
  DIRECT_ORDER_REFUND_AMOUNT_INVALID: conflict(
    "DIRECT_ORDER_REFUND_AMOUNT_INVALID",
  ),
  DIRECT_ORDER_REFUND_PENDING: conflict("DIRECT_ORDER_REFUND_PENDING"),
  DIRECT_ORDER_PHOTO_APPROVAL_ANCHOR_DRIFT: internalFailure,
  DIRECT_ORDER_PHOTO_APPROVAL_VERIFICATION_FAILED: internalFailure,
});

export function directOrderDinerCount(value: unknown): number {
  if (
    typeof value !== "number" || !Number.isInteger(value) || value < 1 ||
    value > 100
  ) {
    throw new SafeHttpError(400, "DIRECT_ORDER_DINER_COUNT_INVALID");
  }
  return value;
}

export function normalizeRpcError(message: string): SafeHttpError {
  const code = Object.keys(sqlDomainErrorRegistry).find((candidate) =>
    message.includes(candidate)
  );
  const contract = code ? sqlDomainErrorRegistry[code] : undefined;
  return contract
    ? new SafeHttpError(contract.status, contract.publicCode)
    : new SafeHttpError(503, "DIRECT_ORDER_TEMPORARILY_UNAVAILABLE");
}

async function rpc(
  client: unknown,
  name: string,
  payload: JsonObject,
): Promise<unknown> {
  const { data, error } = await (client as RpcClient).rpc(name, payload);
  if (error) throw normalizeRpcError(error.message ?? "RPC_FAILED");
  return data;
}

function asObject(value: unknown): JsonObject {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new SafeHttpError(503, "DIRECT_ORDER_TEMPORARILY_UNAVAILABLE");
  }
  return value as JsonObject;
}

export function validProofObjectPath(path: string): boolean {
  const segments = path.split("/");
  if (segments.length !== 3) return false;
  const [storeId, requestId, fileName] = segments;
  const fileMatch = /^([0-9a-f-]{36})[.](jpg|jpeg|png|webp)$/.exec(fileName);
  return uuidPattern.test(storeId) && uuidPattern.test(requestId) &&
    fileMatch !== null && uuidPattern.test(fileMatch[1]);
}

export function validProofPath(path: string, requestId: string): boolean {
  return validProofObjectPath(path) && path.split("/")[1] === requestId;
}

type ProofStorage = {
  list: (
    folder: string,
    options: { limit: number; search: string },
  ) => Promise<{
    data: { name: string }[] | null;
    error: unknown;
  }>;
  download: (path: string) => Promise<{ data: Blob | null; error: unknown }>;
  remove: (paths: string[]) => Promise<unknown>;
};

// V1 and V2 share the same verification. Temporary Storage failures must not
// destroy a valid photo whose upload/commit response may simply have been lost.
export async function verifyProofUpload(storage: ProofStorage, path: string) {
  const [storeId, requestId, fileName] = path.split("/");
  const { data: objects, error: listError } = await storage.list(
    `${storeId}/${requestId}`,
    { limit: 2, search: fileName },
  );
  if (listError || !objects) {
    throw new SafeHttpError(503, "PROOF_TEMPORARILY_UNAVAILABLE");
  }
  if (!objects.some((object) => object.name === fileName)) {
    throw new SafeHttpError(409, "PROOF_UPLOAD_INCOMPLETE");
  }
  const { data: blob, error: downloadError } = await storage.download(path);
  if (downloadError || !blob) {
    throw new SafeHttpError(503, "PROOF_TEMPORARILY_UNAVAILABLE");
  }
  let bytes: Uint8Array;
  try {
    bytes = new Uint8Array(await blob.arrayBuffer());
  } catch {
    throw new SafeHttpError(503, "PROOF_TEMPORARILY_UNAVAILABLE");
  }
  if (
    !validateProofImage(bytes, fileName.split(".").pop()?.toLowerCase() ?? "")
  ) {
    await storage.remove([path]);
    throw new SafeHttpError(400, "INVALID_PROOF");
  }
}

/** Validate a file against the authenticated request scope before issuing a token. */
export function directOrderAttachmentSpec(
  body: JsonObject,
  storeId: string,
  requestId: string,
  staff: boolean,
) {
  const filename = requiredString(body, "filename", 255).replace(
    // deno-lint-ignore no-control-regex -- strip filename control characters
    /[\/\\\u0000-\u001f]/g,
    "_",
  );
  const mime = requiredString(body, "mime_type", 100);
  const extension = allowedProofTypes.get(mime) ??
    (staff && mime === "application/pdf" ? "pdf" : null);
  const path = requiredString(body, "path", 200);
  const pathExtension = path.split(".").pop() ?? "";
  const expectedExtension = extension === "jpg" ? "(?:jpg|jpeg)" : extension;
  const expected = new RegExp(
    `^${storeId}/${requestId}/[0-9a-f-]{36}\\.${expectedExtension}$`,
  );
  if (
    !extension || !expected.test(path) ||
    !uuidPattern.test(path.split("/")[2].split(".")[0])
  ) {
    throw new SafeHttpError(400, "DIRECT_ORDER_ATTACHMENT_INVALID");
  }
  return { filename, mime, path, extension: pathExtension };
}

export function directOrderSecretKeyName(
  directOrderName: string | undefined,
  publicReceiptName: string | undefined,
): string {
  return directOrderName?.trim() || publicReceiptName?.trim() || "";
}

function productionDependencies(): DirectOrderDependencies {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const keyName = directOrderSecretKeyName(
    Deno.env.get("DIRECT_ORDER_SUPABASE_SECRET_KEY_NAME"),
    Deno.env.get("PUBLIC_RECEIPT_SUPABASE_SECRET_KEY_NAME"),
  );
  const projectSecretKey = resolveProjectSecretKey(
    Deno.env.get("SUPABASE_SECRET_KEYS") ?? "",
    keyName,
  );
  const rateLimitSecret = Deno.env.get("DIRECT_ORDER_RATE_LIMIT_SECRET") ?? "";
  const cleanupSecret = Deno.env.get("DIRECT_ORDER_CLEANUP_SECRET") ?? "";
  const allowedOrigins = configuredOrigins();
  if (
    !supabaseUrl || allowedOrigins.length === 0 ||
    rateLimitSecret.length < 32
  ) {
    throw new Error("SERVER_CONFIGURATION_MISSING");
  }
  const parsedUrl = new URL(supabaseUrl);
  if (parsedUrl.protocol !== "https:" && parsedUrl.hostname !== "127.0.0.1") {
    throw new Error("SUPABASE_URL_INVALID");
  }

  const service = createClient(supabaseUrl, projectSecretKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const authenticateStaff = async (request: Request) => {
    const authorization = request.headers.get("Authorization") ?? "";
    if (!authorization.startsWith("Bearer ")) {
      throw new SafeHttpError(401, "UNAUTHORIZED");
    }
    const jwt = authorization.slice(7).trim();
    const { data: authData, error: authError } = await service.auth.getUser(
      jwt,
    );
    if (authError || !authData.user) {
      throw new SafeHttpError(401, "UNAUTHORIZED");
    }
    const actorClient = createClient(supabaseUrl, projectSecretKey, {
      global: { headers: { Authorization: `Bearer ${jwt}` } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    return { actorAuthId: authData.user.id, actorClient };
  };

  const execute = async (
    action: string,
    body: JsonObject,
    request: Request,
  ): Promise<unknown> => {
    switch (action) {
      case "storefront":
      case "storefront_v2": {
        const slug = requiredString(body, "slug", 63, slugPattern);
        const value = await rpc(
          service,
          action === "storefront_v2"
            ? "direct_order_public_storefront_v2"
            : "direct_order_public_storefront",
          { p_slug: slug },
        );
        if (!value) throw new SafeHttpError(404, "DIRECT_ORDER_UNAVAILABLE");
        return {
          ...asObject(value),
          // Legacy response compatibility only; no map credential is used.
          google_maps_browser_key: null,
        };
      }
      case "create_session": {
        const slug = requiredString(body, "slug", 63, slugPattern);
        const locale = directOrderLocale(body.locale, "vi");
        const secret = randomSecret();
        const value = asObject(
          await rpc(
            service,
            "direct_order_public_create_session",
            {
              p_slug: slug,
              p_secret_hash: await sha256Hex(secret),
              p_locale: locale,
            },
          ),
        );
        return { ...value, secret };
      }
      case "submit":
      case "submit_v2":
      case "submit_v3": {
        const sessionId = requiredUuid(body, "session_id");
        const secret = requiredString(body, "secret", 128, secretPattern);
        const clientRequestId = requiredUuid(body, "client_request_id");
        if (
          !body.payload || typeof body.payload !== "object" ||
          Array.isArray(body.payload)
        ) {
          throw new SafeHttpError(400, "INVALID_REQUEST");
        }
        const payload = body.payload as JsonObject;
        directOrderLocale(payload.locale);
        if (action === "submit_v3") directOrderDinerCount(payload.diner_count);
        return await rpc(
          service,
          action === "submit_v3"
            ? "direct_order_public_submit_v3"
            : action === "submit_v2"
            ? "direct_order_public_submit_v2"
            : "direct_order_public_submit",
          {
            p_session_id: sessionId,
            p_secret_hash: await sha256Hex(secret),
            p_client_request_id: clientRequestId,
            p_payload: payload,
          },
        );
      }
      case "status": {
        const sessionId = requiredUuid(body, "session_id");
        const requestId = requiredUuid(body, "request_id");
        const secret = requiredString(body, "secret", 128, secretPattern);
        return await rpc(service, "direct_order_public_status", {
          p_session_id: sessionId,
          p_secret_hash: await sha256Hex(secret),
          p_request_id: requestId,
        });
      }
      case "status_v2":
      case "status_v3":
      case "status_v4":
      case "status_v5": {
        const sessionId = requiredUuid(body, "session_id");
        const requestId = requiredUuid(body, "request_id");
        const secret = requiredString(body, "secret", 128, secretPattern);
        return await rpc(
          service,
          `direct_order_public_${action}`,
          {
            p_session_id: sessionId,
            p_secret_hash: await sha256Hex(secret),
            p_request_id: requestId,
          },
        );
      }
      case "resume_storefront": {
        const sessionId = requiredUuid(body, "session_id");
        const secret = requiredString(body, "secret", 128, secretPattern);
        const value = asObject(
          await rpc(service, "direct_order_public_resume_storefront", {
            p_session_id: sessionId,
            p_secret_hash: await sha256Hex(secret),
          }),
        );
        return { ...value, google_maps_browser_key: null };
      }
      case "decide_pickup": {
        const sessionId = requiredUuid(body, "session_id");
        const secret = requiredString(body, "secret", 128, secretPattern);
        if (
          typeof body.accept !== "boolean" ||
          typeof body.already_paid !== "boolean"
        ) {
          throw new SafeHttpError(400, "DIRECT_ORDER_PICKUP_INPUT_INVALID");
        }
        return await rpc(service, "direct_order_public_decide_pickup", {
          p_session_id: sessionId,
          p_secret_hash: await sha256Hex(secret),
          p_request_id: requiredUuid(body, "request_id"),
          p_offer_id: requiredUuid(body, "offer_id"),
          p_accept: body.accept,
          p_already_paid: body.already_paid,
        });
      }
      case "push_subscription": {
        return await rpc(
          service,
          "direct_order_public_push_subscription",
          await directOrderPushSubscriptionArgs(body),
        );
      }
      case "orders_v2":
      case "orders_v3": {
        const sessionId = requiredUuid(body, "session_id");
        const secret = requiredString(body, "secret", 128, secretPattern);
        return await rpc(
          service,
          action === "orders_v3"
            ? "direct_order_public_orders_v3"
            : "direct_order_public_orders_v2",
          {
            p_session_id: sessionId,
            p_secret_hash: await sha256Hex(secret),
            p_limit: 50,
          },
        );
      }
      case "message": {
        const sessionId = requiredUuid(body, "session_id");
        const requestId = requiredUuid(body, "request_id");
        const secret = requiredString(body, "secret", 128, secretPattern);
        const message = requiredString(body, "message", 2000);
        return await rpc(service, "direct_order_public_message", {
          p_session_id: sessionId,
          p_secret_hash: await sha256Hex(secret),
          p_request_id: requestId,
          p_body: message,
        });
      }
      case "charge_consent": {
        if (typeof body.accept !== "boolean") {
          throw new SafeHttpError(400, "INVALID_REQUEST");
        }
        return await rpc(service, "direct_order_public_charge_consent", {
          p_session_id: requiredUuid(body, "session_id"),
          p_secret_hash: await sha256Hex(
            requiredString(body, "secret", 128, secretPattern),
          ),
          p_request_id: requiredUuid(body, "request_id"),
          p_charge_id: requiredUuid(body, "charge_id"),
          p_accept: body.accept,
        });
      }
      case "customer_attachment_upload":
      case "customer_attachment_commit":
      case "customer_attachment_url":
      case "staff_attachment_upload":
      case "staff_attachment_commit":
      case "staff_attachment_url": {
        const staff = action.startsWith("staff_");
        const requestId = requiredUuid(body, "request_id");
        let storeId: string;
        let actorId: string | null = null;
        let status: JsonObject;
        if (staff) {
          storeId = requiredUuid(body, "store_id");
          const actor = await authenticateStaff(request);
          actorId = actor.actorAuthId;
          status = asObject(
            await rpc(actor.actorClient, "direct_order_staff_detail_v3", {
              p_store_id: storeId,
              p_request_id: requestId,
            }),
          );
        } else {
          status = asObject(
            await rpc(service, "direct_order_public_status_v3", {
              p_session_id: requiredUuid(body, "session_id"),
              p_secret_hash: await sha256Hex(
                requiredString(body, "secret", 128, secretPattern),
              ),
              p_request_id: requestId,
            }),
          );
          storeId = String(status.store_id);
        }
        if (action.endsWith("_url")) {
          const { data: message, error } = await service.from(
            "direct_order_messages",
          )
            .select("attachment_storage_path,metadata").eq(
              "id",
              requiredUuid(body, "message_id"),
            )
            .eq("request_id", requestId).eq("restaurant_id", storeId)
            .maybeSingle();
          if (error || !message?.attachment_storage_path) {
            throw new SafeHttpError(404, "PROOF_NOT_FOUND");
          }
          const bucket =
            message.metadata?.attachment_bucket === "direct-order-chat"
              ? "direct-order-chat"
              : "direct-order-proofs";
          const signed = await service.storage.from(bucket).createSignedUrl(
            message.attachment_storage_path,
            300,
          );
          if (signed.error || !signed.data?.signedUrl) {
            throw new SafeHttpError(503, "PROOF_TEMPORARILY_UNAVAILABLE");
          }
          return { signed_url: signed.data.signedUrl, expires_in: 300 };
        }
        const chargeId = staff ? null : requiredUuid(body, "charge_id");
        const { filename, path, extension } = directOrderAttachmentSpec(
          body,
          storeId,
          requestId,
          staff,
        );
        if (action.endsWith("_commit")) {
          const existing = await service.from("direct_order_messages")
            .select("id,created_at,sender_type,metadata")
            .eq("restaurant_id", storeId).eq("request_id", requestId)
            .eq("attachment_storage_path", path).maybeSingle();
          if (existing.error) {
            throw new SafeHttpError(503, "PROOF_TEMPORARILY_UNAVAILABLE");
          }
          if (existing.data) {
            if (
              existing.data.sender_type !== (staff ? "cashier" : "customer") ||
              (existing.data.metadata?.charge_id ?? null) !== chargeId
            ) {
              throw new SafeHttpError(409, "DIRECT_ORDER_ATTACHMENT_INVALID");
            }
            return {
              message_id: existing.data.id,
              created_at: existing.data.created_at,
            };
          }
        }
        const support = asObject(status.support);
        if (support.chat_open !== true) {
          throw new SafeHttpError(409, "DIRECT_ORDER_REQUEST_NOT_CHATABLE");
        }
        if (
          !staff &&
          !(Array.isArray(support.charges) && support.charges.some((raw) => {
            const c = asObject(raw);
            return c.id === chargeId &&
              ["pending", "review"].includes(String(c.status));
          }))
        ) throw new SafeHttpError(409, "DIRECT_ORDER_CHARGE_CHANGED");
        if (action.endsWith("_upload")) {
          const upload = await service.storage.from("direct-order-chat")
            .createSignedUploadUrl(path);
          if (upload.error || !upload.data?.token) {
            throw new SafeHttpError(503, "PROOF_TEMPORARILY_UNAVAILABLE");
          }
          return { path, token: upload.data.token };
        }
        const downloaded = await service.storage.from("direct-order-chat")
          .download(path);
        if (downloaded.error || !downloaded.data) {
          throw new SafeHttpError(409, "PROOF_UPLOAD_INCOMPLETE");
        }
        const bytes = new Uint8Array(await downloaded.data.arrayBuffer());
        const valid = bytes.length > 0 && bytes.length <= 5242880 &&
          (extension === "pdf"
            ? bytes.length >= 8 &&
              new TextDecoder().decode(bytes.subarray(0, 5)) === "%PDF-"
            : validateProofImage(bytes, extension));
        if (!valid) {
          throw new SafeHttpError(400, "DIRECT_ORDER_ATTACHMENT_INVALID");
        }
        return await rpc(service, "direct_order_commit_attachment", {
          p_request_id: requestId,
          p_store_id: storeId,
          p_sender: staff ? "cashier" : "customer",
          p_actor: actorId,
          p_path: path,
          p_filename: filename,
          p_charge_id: chargeId,
        });
      }
      case "cancel": {
        const sessionId = requiredUuid(body, "session_id");
        const requestId = requiredUuid(body, "request_id");
        const secret = requiredString(body, "secret", 128, secretPattern);
        return await rpc(service, "direct_order_public_cancel", {
          p_session_id: sessionId,
          p_secret_hash: await sha256Hex(secret),
          p_request_id: requestId,
        });
      }
      case "proof_upload_url":
      case "proof_upload_url_v2": {
        const isV2 = body.action === "proof_upload_url_v2";
        const sessionId = requiredUuid(body, "session_id");
        const requestId = requiredUuid(body, "request_id");
        const secret = requiredString(body, "secret", 128, secretPattern);
        const mimeType = requiredString(body, "mime_type", 64);
        const extension = allowedProofTypes.get(mimeType);
        const sizeBytes = Number(body.size_bytes);
        if (
          !extension || !Number.isInteger(sizeBytes) || sizeBytes < 1 ||
          sizeBytes > 5242880
        ) {
          throw new SafeHttpError(400, "INVALID_PROOF");
        }
        const status = asObject(
          await rpc(
            service,
            isV2
              ? "direct_order_public_status_v2"
              : "direct_order_public_status",
            {
              p_session_id: sessionId,
              p_secret_hash: await sha256Hex(secret),
              p_request_id: requestId,
            },
          ),
        );
        const storeId = typeof status.store_id === "string"
          ? status.store_id
          : "";
        if (!uuidPattern.test(storeId)) {
          throw new SafeHttpError(503, "DIRECT_ORDER_TEMPORARILY_UNAVAILABLE");
        }
        if (isV2) {
          const quoteId = requiredUuid(body, "quote_id");
          const reviewRequestId = body.review_request_id == null
            ? null
            : requiredUuid(body, "review_request_id");
          if (
            !status.quote || typeof status.quote !== "object" ||
            Array.isArray(status.quote)
          ) {
            throw new SafeHttpError(409, "DIRECT_ORDER_PROOF_NOT_ALLOWED");
          }
          const quote = status.quote as JsonObject;
          if (quote.id !== quoteId) {
            throw new SafeHttpError(409, "DIRECT_ORDER_PROOF_NOT_ALLOWED");
          }
          if (reviewRequestId == null) {
            if (status.state !== "quoted" || quote.status !== "active") {
              throw new SafeHttpError(409, "DIRECT_ORDER_PROOF_NOT_ALLOWED");
            }
          } else {
            if (
              !status.proof_review ||
              typeof status.proof_review !== "object" ||
              Array.isArray(status.proof_review)
            ) {
              throw new SafeHttpError(
                409,
                "DIRECT_ORDER_PROOF_REVIEW_NOT_ALLOWED",
              );
            }
            const review = status.proof_review as JsonObject;
            if (
              review.id !== reviewRequestId || review.can_resubmit !== true
            ) {
              throw new SafeHttpError(
                409,
                "DIRECT_ORDER_PROOF_REVIEW_NOT_ALLOWED",
              );
            }
          }
        }
        const objectId = crypto.randomUUID();
        const path = `${storeId}/${requestId}/${objectId}.${extension}`;
        const { data, error } = await service.storage
          .from("direct-order-proofs")
          .createSignedUploadUrl(path, { upsert: false });
        if (error || !data) {
          throw new SafeHttpError(503, "PROOF_UPLOAD_TEMPORARILY_UNAVAILABLE");
        }
        return {
          path,
          token: data.token,
          signed_url: data.signedUrl,
          max_bytes: 5242880,
          mime_type: mimeType,
        };
      }
      case "proof_commit":
      case "proof_commit_v2": {
        const isV2 = body.action === "proof_commit_v2";
        const sessionId = requiredUuid(body, "session_id");
        const requestId = requiredUuid(body, "request_id");
        const secret = requiredString(body, "secret", 128, secretPattern);
        const path = requiredString(body, "path", 240);
        if (!validProofPath(path, requestId)) {
          throw new SafeHttpError(400, "INVALID_PROOF");
        }
        await verifyProofUpload(
          service.storage.from("direct-order-proofs"),
          path,
        );
        if (isV2) {
          const quoteId = requiredUuid(body, "quote_id");
          const reviewRequestId = body.review_request_id == null
            ? null
            : requiredUuid(body, "review_request_id");
          return await rpc(service, "direct_order_public_commit_proof_v2", {
            p_session_id: sessionId,
            p_secret_hash: await sha256Hex(secret),
            p_request_id: requestId,
            p_quote_id: quoteId,
            p_storage_path: path,
            p_review_request_id: reviewRequestId,
          });
        }
        return await rpc(service, "direct_order_public_commit_proof", {
          p_session_id: sessionId,
          p_secret_hash: await sha256Hex(secret),
          p_request_id: requestId,
          p_storage_path: path,
        });
      }
      case "staff_proof_url": {
        const storeId = requiredUuid(body, "store_id");
        const requestId = requiredUuid(body, "request_id");
        const messageId = requiredUuid(body, "message_id");
        const { actorClient } = await authenticateStaff(request);
        await rpc(actorClient, "direct_order_staff_detail", {
          p_store_id: storeId,
          p_request_id: requestId,
        });
        const { data: message, error: messageError } = await service
          .from("direct_order_messages")
          .select("attachment_storage_path,metadata")
          .eq("id", messageId)
          .eq("request_id", requestId)
          .eq("restaurant_id", storeId)
          .eq("message_type", "payment_proof")
          .maybeSingle();
        const path = message?.attachment_storage_path;
        if (messageError || typeof path !== "string") {
          throw new SafeHttpError(404, "PROOF_NOT_FOUND");
        }
        const { data, error } = await service.storage
          .from(
            message?.metadata?.attachment_bucket === "direct-order-chat"
              ? "direct-order-chat"
              : "direct-order-proofs",
          )
          .createSignedUrl(path, 300);
        if (error || !data?.signedUrl) {
          throw new SafeHttpError(503, "PROOF_TEMPORARILY_UNAVAILABLE");
        }
        return { signed_url: data.signedUrl, expires_in: 300 };
      }
      case "cleanup_expired_pii": {
        const orphanCandidates = await rpc(
          service,
          "direct_order_orphan_proof_candidates",
          { p_limit: 100 },
        );
        const orphanPaths = Array.isArray(orphanCandidates)
          ? orphanCandidates.filter((path): path is string =>
            typeof path === "string" && validProofObjectPath(path)
          )
          : [];
        const candidates = await rpc(
          service,
          "direct_order_cleanup_candidates",
          { p_limit: 100 },
        );
        const rows = Array.isArray(candidates) ? candidates : [];
        const requestIds: string[] = [];
        const paths = new Set<string>(orphanPaths);
        const chatPaths = new Set<string>();
        for (const raw of rows) {
          if (!raw || typeof raw !== "object") continue;
          const row = raw as JsonObject;
          if (typeof row.request_id !== "string") continue;
          const requestId = row.request_id;
          if (!uuidPattern.test(requestId)) continue;
          requestIds.push(requestId);
          if (Array.isArray(row.proof_paths)) {
            for (const path of row.proof_paths) {
              if (
                typeof path === "string" &&
                validProofPath(path, requestId)
              ) {
                paths.add(path);
              }
            }
          }
        }
        for (const raw of rows) {
          const row = asObject(raw);
          if (Array.isArray(row.chat_paths)) {
            for (const path of row.chat_paths) {
              if (
                typeof path === "string" &&
                /^[0-9a-f-]{36}\/[0-9a-f-]{36}\/[0-9a-f-]{36}\.(jpg|jpeg|png|webp|pdf)$/
                  .test(path) &&
                path.split("/")[1] === row.request_id
              ) {
                chatPaths.add(path);
              }
            }
          }
        }
        if (chatPaths.size > 0) {
          const removed = await service.storage.from("direct-order-chat")
            .remove([...chatPaths]);
          if (removed.error) {
            throw new SafeHttpError(503, "CLEANUP_TEMPORARILY_UNAVAILABLE");
          }
        }
        if (paths.size > 0) {
          const { error } = await service.storage
            .from("direct-order-proofs")
            .remove([...paths]);
          if (error) {
            throw new SafeHttpError(503, "CLEANUP_TEMPORARILY_UNAVAILABLE");
          }
        }
        const cleanupResult = requestIds.length === 0
          ? { requests: 0 }
          : asObject(
            await rpc(service, "direct_order_cleanup_expired_pii", {
              p_request_ids: requestIds,
            }),
          );
        return {
          ...cleanupResult,
          orphan_proofs: orphanPaths.length,
        };
      }
      default:
        throw new SafeHttpError(400, "INVALID_ACTION");
    }
  };

  return {
    allowedOrigins,
    consumeRateLimit: async (request: Request, action: string) => {
      const address = clientAddress(request);
      if (!address) return false;
      const key = await hmacSha256Hex(
        `${action.replace(/_v[23]$/, "")}:${address}`,
        rateLimitSecret,
      );
      const data = await rpc(service, "direct_order_consume_public_rate", {
        p_request_key: key,
        p_limit: directOrderActionRegistry[
          action as keyof typeof directOrderActionRegistry
        ]?.rateLimit ?? 60,
        p_window_seconds: 60,
      });
      return data === true;
    },
    allowInternalRequest: (request: Request, action: string) =>
      action === "cleanup_expired_pii" && cleanupSecret.length >= 32 &&
      request.headers.get("x-direct-order-cleanup-secret") === cleanupSecret,
    execute,
  } satisfies DirectOrderDependencies;
}

if (import.meta.main) {
  try {
    serve(createDirectOrderHandler(productionDependencies()));
  } catch (error) {
    console.error(
      "direct-order-public configuration failed",
      error instanceof Error ? error.name : "unknown",
    );
    serve(() =>
      new Response(
        JSON.stringify({ error: "DIRECT_ORDER_TEMPORARILY_UNAVAILABLE" }),
        {
          status: 503,
          headers: {
            "Cache-Control": "no-store, max-age=0",
            "Content-Type": "application/json; charset=utf-8",
          },
        },
      )
    );
  }
}
