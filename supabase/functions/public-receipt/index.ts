import { serve } from "@std/http/server";

type JsonObject = Record<string, unknown>;
type Fetcher = (
  input: string | URL | Request,
  init?: globalThis.RequestInit,
) => Promise<Response>;
type RpcCaller = (name: string, payload: JsonObject) => Promise<unknown>;

export type PublicReceiptDependencies = {
  allowedOrigins: readonly string[];
  consumeRateLimit: (request: Request) => Promise<boolean>;
  loadReceipt: (token: string) => Promise<JsonObject | null>;
};

const tokenPattern = /^[A-Za-z0-9_-]{32}$/;
const rpcNamePattern = /^[a-z][a-z0-9_]*$/;

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

  const key = (parsed as Record<string, unknown>)[keyName];
  if (
    typeof key !== "string" || !key.startsWith("sb_secret_") ||
    key.length < 32
  ) {
    throw new Error("PROJECT_SECRET_KEY_MISSING");
  }
  return key;
}

export function createProjectRpcCaller(
  supabaseUrl: string,
  projectSecretKey: string,
  fetcher: Fetcher = fetch,
): RpcCaller {
  const baseUrl = new URL(supabaseUrl);
  if (baseUrl.protocol !== "https:") {
    throw new Error("SUPABASE_URL_INVALID");
  }

  return async (name, payload) => {
    if (!rpcNamePattern.test(name)) throw new Error("RPC_NAME_INVALID");
    const endpoint = new URL(`/rest/v1/rpc/${name}`, baseUrl);
    const response = await fetcher(endpoint, {
      method: "POST",
      headers: {
        // New Supabase secret keys are opaque, not JWTs. Sending one as a
        // Bearer token makes the gateway reject it, so it must be carried only
        // in the apikey header.
        apikey: projectSecretKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    });
    if (!response.ok) throw new Error("RPC_REQUEST_FAILED");
    return await response.json();
  };
}

function originIsAllowed(
  request: Request,
  allowedOrigins: readonly string[],
): boolean {
  const origin = request.headers.get("Origin") ?? "";
  return origin.length > 0 && allowedOrigins.includes(origin);
}

function securityHeaders(
  request: Request,
  allowedOrigins: readonly string[],
): Record<string, string> {
  const origin = request.headers.get("Origin") ?? "";
  return {
    ...(allowedOrigins.includes(origin)
      ? { "Access-Control-Allow-Origin": origin }
      : {}),
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Cache-Control": "no-store, max-age=0",
    "Content-Type": "application/json",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
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

export function createPublicReceiptHandler(
  dependencies: PublicReceiptDependencies,
) {
  return async (request: Request): Promise<Response> => {
    const { allowedOrigins } = dependencies;

    if (!originIsAllowed(request, allowedOrigins)) {
      return jsonResponse(request, allowedOrigins, 403, {
        error: "REQUEST_FORBIDDEN",
      });
    }
    if (request.method === "OPTIONS") {
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

    const contentLength = Number(request.headers.get("Content-Length") ?? 0);
    if (Number.isFinite(contentLength) && contentLength > 2048) {
      return jsonResponse(request, allowedOrigins, 413, {
        error: "REQUEST_TOO_LARGE",
      });
    }

    let body: JsonObject;
    try {
      const rawBody = await request.text();
      if (rawBody.length > 2048) {
        return jsonResponse(request, allowedOrigins, 413, {
          error: "REQUEST_TOO_LARGE",
        });
      }
      body = JSON.parse(rawBody) as JsonObject;
    } catch (_) {
      return jsonResponse(request, allowedOrigins, 400, {
        error: "INVALID_REQUEST",
      });
    }

    const token = typeof body.token === "string" ? body.token : "";
    if (!tokenPattern.test(token)) {
      return jsonResponse(request, allowedOrigins, 404, {
        error: "RECEIPT_UNAVAILABLE",
      });
    }

    try {
      if (!await dependencies.consumeRateLimit(request)) {
        return jsonResponse(
          request,
          allowedOrigins,
          429,
          { error: "TOO_MANY_REQUESTS" },
          { "Retry-After": "60" },
        );
      }

      const receipt = await dependencies.loadReceipt(token);
      if (!receipt) {
        return jsonResponse(request, allowedOrigins, 404, {
          error: "RECEIPT_UNAVAILABLE",
        });
      }
      return jsonResponse(request, allowedOrigins, 200, receipt);
    } catch (error) {
      // Never log the request body, URL fragment, raw token, or receipt data.
      console.error(
        "public-receipt failed",
        error instanceof Error ? error.name : "unknown",
      );
      return jsonResponse(request, allowedOrigins, 503, {
        error: "RECEIPT_TEMPORARILY_UNAVAILABLE",
      });
    }
  };
}

function configuredOrigins(): string[] {
  return (Deno.env.get("ALLOWED_ORIGINS") ?? "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
}

function clientAddress(request: Request): string | null {
  const forwarded = request.headers.get("x-forwarded-for")
    ?.split(",")[0]
    ?.trim();
  const candidate = forwarded ||
    request.headers.get("x-real-ip")?.trim() ||
    request.headers.get("cf-connecting-ip")?.trim() ||
    "";
  return candidate.length > 0 && candidate.length <= 128 ? candidate : null;
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

function productionDependencies(): PublicReceiptDependencies {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const secretKeyName = Deno.env.get(
    "PUBLIC_RECEIPT_SUPABASE_SECRET_KEY_NAME",
  ) ?? "";
  const projectSecretKey = resolveProjectSecretKey(
    Deno.env.get("SUPABASE_SECRET_KEYS") ?? "",
    secretKeyName,
  );
  const rateLimitSecret = Deno.env.get("DIGITAL_RECEIPT_RATE_LIMIT_SECRET") ??
    "";
  const allowedOrigins = configuredOrigins();
  if (
    !supabaseUrl || rateLimitSecret.length < 32 ||
    allowedOrigins.length === 0
  ) {
    throw new Error("SERVER_CONFIGURATION_MISSING");
  }
  const callRpc = createProjectRpcCaller(supabaseUrl, projectSecretKey);

  return {
    allowedOrigins,
    consumeRateLimit: async (request) => {
      const address = clientAddress(request);
      if (!address) return false;
      const requestKey = await hmacSha256Hex(address, rateLimitSecret);
      const data = await callRpc("consume_digital_receipt_rate_limit", {
        p_request_key: requestKey,
      });
      return data === true;
    },
    loadReceipt: async (token) => {
      const data = await callRpc("get_public_receipt", {
        p_token: token,
      });
      return data && typeof data === "object" ? data as JsonObject : null;
    },
  };
}

if (import.meta.main) {
  try {
    serve(createPublicReceiptHandler(productionDependencies()));
  } catch (error) {
    console.error(
      "public-receipt configuration failed",
      error instanceof Error ? error.name : "unknown",
    );
    serve(() =>
      new Response(
        JSON.stringify({
          error: "RECEIPT_TEMPORARILY_UNAVAILABLE",
        }),
        {
          status: 503,
          headers: {
            "Cache-Control": "no-store, max-age=0",
            "Content-Type": "application/json",
          },
        },
      )
    );
  }
}
