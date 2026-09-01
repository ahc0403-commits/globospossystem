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
    create_session: { actor: "public", rateLimit: 60 },
    places_autocomplete: { actor: "public", rateLimit: 30 },
    place_details: { actor: "public", rateLimit: 30 },
    reverse_geocode: { actor: "public", rateLimit: 30 },
    submit: { actor: "public", rateLimit: 60 },
    status: { actor: "public", rateLimit: 60 },
    message: { actor: "public", rateLimit: 60 },
    cancel: { actor: "public", rateLimit: 60 },
    proof_upload_url: { actor: "public", rateLimit: 10 },
    proof_commit: { actor: "public", rateLimit: 60 },
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
const placeIdPattern = /^[A-Za-z0-9_-]{5,255}$/;
const placeSessionTokenPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
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
  DIRECT_ORDER_QUOTE_EXPIRED: conflict("DIRECT_ORDER_QUOTE_EXPIRED"),
  DIRECT_ORDER_PROOF_PATH_INVALID: invalidRequest("INVALID_PROOF"),
  DIRECT_ORDER_LIMIT_INVALID: invalidRequest("INVALID_REQUEST"),
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
  DIRECT_ORDER_FINANCIAL_RECONCILIATION_FAILED: internalFailure,
  DIRECT_ORDER_DRIVER_RECEIPT_ADDRESS_UNAVAILABLE: internalFailure,
  DIRECT_ORDER_DRIVER_RECEIPT_DESTINATION_INVALID: internalFailure,
  DIRECT_ORDER_DRIVER_RECEIPT_ITEMS_UNAVAILABLE: internalFailure,
  DIRECT_ORDER_DRIVER_RECEIPT_PAYLOAD_INVALID: internalFailure,
  DIRECT_ORDER_DRIVER_RECEIPT_REPRINT_NOT_AVAILABLE: internalFailure,
  DIRECT_ORDER_DRIVER_RECEIPT_TOTAL_MISMATCH: internalFailure,
  DIRECT_ORDER_DRIVER_RECEIPT_USE_DEDICATED_REPRINT: internalFailure,
  DIRECT_DELIVERY_TICKET_NOT_FOUND: unavailable("DIRECT_ORDER_UNAVAILABLE"),
  DIRECT_DELIVERY_TICKET_VERSION_CONFLICT: conflict(
    "DIRECT_DELIVERY_TICKET_VERSION_CONFLICT",
  ),
  DIRECT_DELIVERY_TICKET_TRANSITION_INVALID: conflict(
    "DIRECT_DELIVERY_TICKET_TRANSITION_INVALID",
  ),
  DIRECT_ORDER_DISPATCH_INPUT_INVALID: invalidRequest("INVALID_REQUEST"),
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
});

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

function addressParts(
  components: unknown,
): { district?: string; ward?: string } {
  if (!Array.isArray(components)) return {};
  let district: string | undefined;
  let ward: string | undefined;
  for (const raw of components) {
    if (!raw || typeof raw !== "object") continue;
    const component = raw as JsonObject;
    const types = Array.isArray(component.types) ? component.types : [];
    const name = typeof component.longText === "string"
      ? component.longText
      : typeof component.long_name === "string"
      ? component.long_name
      : undefined;
    if (!name) continue;
    if (
      !district &&
      (types.includes("administrative_area_level_2") ||
        types.includes("sublocality_level_1"))
    ) district = name;
    if (
      !ward &&
      (types.includes("administrative_area_level_3") ||
        types.includes("sublocality_level_2"))
    ) ward = name;
  }
  return { district, ward };
}

export function validPlacesSessionToken(value: unknown): value is string {
  return typeof value === "string" && placeSessionTokenPattern.test(value);
}

export function requireGoogleServerKey(value: string): string {
  if (!value) {
    throw new SafeHttpError(503, "MAP_TEMPORARILY_UNAVAILABLE");
  }
  return value;
}

export function googleAutocompletePayload(
  query: string,
  locale: string,
  sessionToken: string,
  latitude?: number,
  longitude?: number,
): JsonObject {
  const payload: JsonObject = {
    input: query,
    includedRegionCodes: ["vn"],
    languageCode: locale,
    regionCode: "VN",
    sessionToken,
  };
  if (
    typeof latitude === "number" && Number.isFinite(latitude) &&
    typeof longitude === "number" && Number.isFinite(longitude)
  ) {
    payload.locationBias = {
      circle: {
        center: { latitude, longitude },
        radius: 50000,
      },
    };
  }
  return payload;
}

export function googlePlaceDetailsUrl(
  placeId: string,
  locale: string,
  sessionToken: string,
): URL {
  const url = new URL(`https://places.googleapis.com/v1/places/${placeId}`);
  url.searchParams.set("languageCode", locale);
  url.searchParams.set("regionCode", "VN");
  url.searchParams.set("sessionToken", sessionToken);
  return url;
}

export function googleAutocompleteSuggestions(data: JsonObject): JsonObject[] {
  return Array.isArray(data.suggestions)
    ? data.suggestions.slice(0, 8).flatMap((raw) => {
      if (!raw || typeof raw !== "object") return [];
      const prediction = (raw as JsonObject).placePrediction;
      if (!prediction || typeof prediction !== "object") return [];
      const row = prediction as JsonObject;
      const text = row.text && typeof row.text === "object"
        ? (row.text as JsonObject).text
        : null;
      return typeof row.placeId === "string" &&
          placeIdPattern.test(row.placeId) &&
          typeof text === "string" && text.trim().length > 0
        ? [{ place_id: row.placeId, text: text.trim() }]
        : [];
    })
    : [];
}

function providerPlace(
  placeId: unknown,
  formattedAddress: unknown,
  latitude: unknown,
  longitude: unknown,
  components: unknown,
): JsonObject {
  if (
    typeof formattedAddress !== "string" ||
    formattedAddress.trim().length === 0 ||
    typeof latitude !== "number" || !Number.isFinite(latitude) ||
    latitude < -90 || latitude > 90 ||
    typeof longitude !== "number" || !Number.isFinite(longitude) ||
    longitude < -180 || longitude > 180 ||
    (placeId != null &&
      (typeof placeId !== "string" || !placeIdPattern.test(placeId)))
  ) {
    throw new SafeHttpError(404, "MAP_LOCATION_NOT_FOUND");
  }
  const parts = addressParts(components);
  return {
    place_id: placeId ?? null,
    formatted_address: formattedAddress.trim(),
    latitude,
    longitude,
    district: parts.district ?? null,
    ward: parts.ward ?? null,
  };
}

export function googlePlaceDetailsResult(data: JsonObject): JsonObject {
  const location = data.location;
  if (!location || typeof location !== "object" || Array.isArray(location)) {
    throw new SafeHttpError(404, "MAP_LOCATION_NOT_FOUND");
  }
  const coordinates = location as JsonObject;
  return providerPlace(
    data.id,
    data.formattedAddress,
    coordinates.latitude,
    coordinates.longitude,
    data.addressComponents,
  );
}

export function googleReverseGeocodeResult(
  data: JsonObject,
  latitude: number,
  longitude: number,
): JsonObject {
  const results = Array.isArray(data.results) ? data.results : [];
  const first = results[0];
  if (!first || typeof first !== "object" || Array.isArray(first)) {
    throw new SafeHttpError(404, "MAP_LOCATION_NOT_FOUND");
  }
  const result = first as JsonObject;
  return providerPlace(
    result.place_id,
    result.formatted_address,
    latitude,
    longitude,
    result.address_components,
  );
}

export async function googleJson(
  url: string | URL,
  init: RequestInit,
  fetcher: typeof fetch = fetch,
): Promise<JsonObject> {
  try {
    const response = await fetcher(url, init);
    if (!response.ok) {
      throw new SafeHttpError(503, "MAP_TEMPORARILY_UNAVAILABLE");
    }
    return asObject(await response.json());
  } catch (error) {
    if (error instanceof SafeHttpError) throw error;
    throw new SafeHttpError(503, "MAP_TEMPORARILY_UNAVAILABLE");
  }
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
  const googleServerKey = Deno.env.get("GOOGLE_MAPS_SERVER_API_KEY") ?? "";
  const googleBrowserKey = Deno.env.get("GOOGLE_MAPS_BROWSER_KEY") ?? "";
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
      case "storefront": {
        const slug = requiredString(body, "slug", 63, slugPattern);
        const value = await rpc(
          service,
          "direct_order_public_storefront",
          { p_slug: slug },
        );
        if (!value) throw new SafeHttpError(404, "DIRECT_ORDER_UNAVAILABLE");
        return {
          ...asObject(value),
          google_maps_browser_key: googleBrowserKey || null,
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
      case "places_autocomplete": {
        const apiKey = requireGoogleServerKey(googleServerKey);
        const query = requiredString(body, "query", 200);
        if (query.length < 2) throw new SafeHttpError(400, "INVALID_REQUEST");
        const slug = requiredString(body, "slug", 63, slugPattern);
        const storefront = asObject(
          await rpc(
            service,
            "direct_order_public_storefront",
            { p_slug: slug },
          ),
        );
        const latitude = Number(storefront.default_latitude);
        const longitude = Number(storefront.default_longitude);
        const locale = directOrderLocale(body.locale, "vi");
        if (!validPlacesSessionToken(body.session_token)) {
          throw new SafeHttpError(400, "INVALID_REQUEST");
        }
        const payload = googleAutocompletePayload(
          query,
          locale,
          body.session_token,
          latitude,
          longitude,
        );
        const data = await googleJson(
          "https://places.googleapis.com/v1/places:autocomplete",
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "X-Goog-Api-Key": apiKey,
              "X-Goog-FieldMask":
                "suggestions.placePrediction.placeId,suggestions.placePrediction.text",
            },
            body: JSON.stringify(payload),
          },
        );
        return { suggestions: googleAutocompleteSuggestions(data) };
      }
      case "place_details": {
        const apiKey = requireGoogleServerKey(googleServerKey);
        const placeId = requiredString(body, "place_id", 255, placeIdPattern);
        const locale = directOrderLocale(body.locale, "vi");
        if (!validPlacesSessionToken(body.session_token)) {
          throw new SafeHttpError(400, "INVALID_REQUEST");
        }
        const url = googlePlaceDetailsUrl(
          placeId,
          locale,
          body.session_token,
        );
        const data = await googleJson(url, {
          headers: {
            "X-Goog-Api-Key": apiKey,
            "X-Goog-FieldMask":
              "id,formattedAddress,location,addressComponents",
          },
        });
        return googlePlaceDetailsResult(data);
      }
      case "reverse_geocode": {
        const apiKey = requireGoogleServerKey(googleServerKey);
        const latitude = Number(body.latitude);
        const longitude = Number(body.longitude);
        if (
          !Number.isFinite(latitude) || latitude < -90 || latitude > 90 ||
          !Number.isFinite(longitude) || longitude < -180 || longitude > 180
        ) throw new SafeHttpError(400, "INVALID_REQUEST");
        const locale = directOrderLocale(body.locale, "vi");
        const url = new URL(
          "https://maps.googleapis.com/maps/api/geocode/json",
        );
        url.searchParams.set("latlng", `${latitude},${longitude}`);
        url.searchParams.set("key", apiKey);
        url.searchParams.set("region", "vn");
        url.searchParams.set("language", locale);
        const data = await googleJson(url, {});
        return googleReverseGeocodeResult(data, latitude, longitude);
      }
      case "submit": {
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
        return await rpc(service, "direct_order_public_submit", {
          p_session_id: sessionId,
          p_secret_hash: await sha256Hex(secret),
          p_client_request_id: clientRequestId,
          p_payload: payload,
        });
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
      case "proof_upload_url": {
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
            "direct_order_public_status",
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
      case "proof_commit": {
        const sessionId = requiredUuid(body, "session_id");
        const requestId = requiredUuid(body, "request_id");
        const secret = requiredString(body, "secret", 128, secretPattern);
        const path = requiredString(body, "path", 240);
        if (!validProofPath(path, requestId)) {
          throw new SafeHttpError(400, "INVALID_PROOF");
        }
        const [storeId, , fileName] = path.split("/");
        const { data: objects, error: listError } = await service.storage
          .from("direct-order-proofs")
          .list(`${storeId}/${requestId}`, {
            limit: 2,
            search: fileName,
          });
        if (
          listError || !objects?.some((object) => object.name === fileName)
        ) throw new SafeHttpError(409, "PROOF_UPLOAD_INCOMPLETE");
        const extension = fileName.split(".").pop()?.toLowerCase() ?? "";
        const { data: proofBlob, error: downloadError } = await service.storage
          .from("direct-order-proofs")
          .download(path);
        const proofBytes = downloadError || !proofBlob
          ? null
          : new Uint8Array(await proofBlob.arrayBuffer());
        if (!proofBytes || !validateProofImage(proofBytes, extension)) {
          await service.storage.from("direct-order-proofs").remove([path]);
          throw new SafeHttpError(400, "INVALID_PROOF");
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
          .select("attachment_storage_path")
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
          .from("direct-order-proofs")
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
        `${action}:${address}`,
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
