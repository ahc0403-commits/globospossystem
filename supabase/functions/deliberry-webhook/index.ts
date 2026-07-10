import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type JsonRecord = Record<string, unknown>;

const replayWindowSeconds = Number(
  Deno.env.get("DELIBERRY_WEBHOOK_REPLAY_WINDOW_SECONDS") ?? "300",
);

function json(body: JsonRecord, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function textField(source: JsonRecord, keys: string[]): string | null {
  for (const key of keys) {
    const value = source[key];
    if (typeof value === "string" && value.trim().length > 0) {
      return value.trim();
    }
    if (typeof value === "number" && Number.isFinite(value)) {
      return String(value);
    }
  }
  return null;
}

function numberField(source: JsonRecord, keys: string[]): number | null {
  for (const key of keys) {
    const value = source[key];
    if (typeof value === "number" && Number.isFinite(value)) return value;
    if (typeof value === "string" && value.trim().length > 0) {
      const parsed = Number(value);
      if (Number.isFinite(parsed)) return parsed;
    }
  }
  return null;
}

function parseTimestampMillis(value: string | null): number | null {
  if (!value) return null;
  const numeric = Number(value);
  if (Number.isFinite(numeric)) {
    return numeric > 10_000_000_000 ? numeric : numeric * 1000;
  }
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function normalizeSignature(value: string | null): string | null {
  if (!value) return null;
  const trimmed = value.trim();
  return trimmed.startsWith("sha256=")
    ? trimmed.slice("sha256=".length)
    : trimmed;
}

function hex(bytes: ArrayBuffer): string {
  return [...new Uint8Array(bytes)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function constantTimeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let index = 0; index < left.length; index += 1) {
    diff |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return diff === 0;
}

async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return hex(await crypto.subtle.sign("HMAC", key, encoder.encode(message)));
}

async function verifySignature(
  req: Request,
  rawBody: string,
): Promise<boolean> {
  const secret = Deno.env.get("DELIBERRY_WEBHOOK_SECRET");
  if (!secret) {
    throw new Error("DELIBERRY_WEBHOOK_SECRET_NOT_CONFIGURED");
  }

  const timestamp = req.headers.get("x-deliberry-timestamp");
  const signature = normalizeSignature(
    req.headers.get("x-deliberry-signature"),
  );
  if (!timestamp || !signature) return false;

  const timestampMillis = parseTimestampMillis(timestamp);
  if (timestampMillis == null) return false;
  const ageSeconds = Math.abs(Date.now() - timestampMillis) / 1000;
  if (ageSeconds > replayWindowSeconds) return false;

  const expected = await hmacSha256Hex(secret, `${timestamp}.${rawBody}`);
  return constantTimeEqual(expected, signature.toLowerCase());
}

function normalizeEventType(value: string | null): string | null {
  const normalized = (value ?? "").toLowerCase().replace(/[\s.-]+/g, "_");
  switch (normalized) {
    case "deliberry_order_received":
    case "order_received":
    case "order_created":
    case "received":
    case "new":
      return "DELIBERRY_ORDER_RECEIVED";
    case "deliberry_order_delivered":
    case "order_delivered":
    case "delivered":
      return "DELIBERRY_ORDER_DELIVERED";
    case "deliberry_order_customer_cancelled":
    case "deliberry_order_customer_canceled":
    case "order_customer_cancelled":
    case "order_customer_canceled":
    case "cancelled_by_customer":
    case "canceled_by_customer":
    case "customer_cancelled":
    case "customer_canceled":
      return "DELIBERRY_ORDER_CUSTOMER_CANCELLED";
    default:
      return null;
  }
}

serve(async (req) => {
  if (req.method !== "POST") {
    return json({ ok: false, error: "METHOD_NOT_ALLOWED" }, 405);
  }

  const rawBody = await req.text();

  try {
    if (!(await verifySignature(req, rawBody))) {
      return json(
        { ok: false, error: "DELIBERRY_WEBHOOK_SIGNATURE_INVALID" },
        401,
      );
    }
  } catch (error) {
    return json({ ok: false, error: String((error as Error).message) }, 503);
  }

  let payload: JsonRecord;
  try {
    const parsed = JSON.parse(rawBody);
    payload = parsed != null && typeof parsed === "object"
      ? parsed as JsonRecord
      : {};
  } catch {
    return json({ ok: false, error: "INVALID_JSON" }, 400);
  }

  const storeId = textField(payload, [
    "store_id",
    "restaurant_id",
    "merchant_store_id",
  ]);
  const externalOrderId = textField(payload, [
    "external_order_id",
    "order_id",
    "id",
  ]);
  const eventId = req.headers.get("x-deliberry-event-id") ??
    textField(payload, ["event_id", "idempotency_key"]);
  const eventType = normalizeEventType(
    textField(payload, ["event_type", "type", "status", "order_status"]),
  );
  const eventSequence = req.headers.get("x-deliberry-event-sequence") ??
    numberField(payload, ["event_sequence", "sequence"])?.toString() ??
    "0";
  const traceId = req.headers.get("x-deliberry-trace-id") ??
    textField(payload, ["trace_id", "request_id"]);
  const occurredAt = textField(payload, [
    "event_occurred_at",
    "occurred_at",
    "updated_at",
  ]);

  if (!storeId || !externalOrderId || !eventId || !eventType) {
    return json({
      ok: false,
      error: "DELIBERRY_WEBHOOK_PAYLOAD_UNSUPPORTED",
      missing: {
        store_id: !storeId,
        external_order_id: !externalOrderId,
        event_id: !eventId,
        event_type: !eventType,
      },
    }, 422);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return json({ ok: false, error: "SUPABASE_SERVICE_NOT_CONFIGURED" }, 503);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);
  const rpcPayload = {
    ...payload,
    event_sequence: eventSequence,
    event_occurred_at: occurredAt ?? new Date().toISOString(),
    trace_id: traceId,
    payload_version: textField(payload, ["payload_version"]) ??
      "deliberry.operational_order.v1",
    channel_id: textField(payload, ["channel_id"]) ?? "DELIBERRY",
  };

  const { data, error } = eventType === "DELIBERRY_ORDER_RECEIVED"
    ? await supabase.rpc("receive_deliberry_operational_order", {
      p_store_id: storeId,
      p_external_order_id: externalOrderId,
      p_event_id: eventId,
      p_payload: rpcPayload,
    })
    : await supabase.rpc("apply_deliberry_operational_order_event", {
      p_store_id: storeId,
      p_external_order_id: externalOrderId,
      p_event_id: eventId,
      p_event_type: eventType,
      p_payload: rpcPayload,
      p_actor_id: null,
      p_reason: textField(payload, ["reason", "reject_reason"]),
      p_source_system: "deliberry",
      p_destination_system: "pos",
    });

  if (error) {
    return json({
      ok: false,
      error: "DELIBERRY_WEBHOOK_RPC_FAILED",
      code: error.code,
      message: error.message,
    }, 500);
  }

  return json({
    ok: true,
    event_id: eventId,
    event_type: eventType,
    external_order_id: externalOrderId,
    trace_id: traceId,
    status: (data as JsonRecord | null)?.status,
  });
});
