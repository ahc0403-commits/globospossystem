import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type JsonRecord = Record<string, unknown>;

function json(body: JsonRecord, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function asString(value: unknown): string | null {
  if (typeof value === "string" && value.trim().length > 0) {
    return value.trim();
  }
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return null;
}

function actionStatus(eventType: unknown): string | null {
  switch (asString(eventType)) {
    case "DELIBERRY_ORDER_ACCEPTED":
      return "accepted";
    case "DELIBERRY_ORDER_REJECTED":
      return "rejected";
    case "DELIBERRY_ORDER_READY":
      return "ready";
    default:
      return null;
  }
}

function uniqueStrings(values: unknown[]): string[] {
  return [
    ...new Set(
      values.map(asString).filter((value): value is string => value != null),
    ),
  ];
}

function resolveEndpoint(): string | null {
  const explicit = Deno.env.get("DELIBERRY_OPERATIONAL_EVENT_ENDPOINT");
  if (explicit && explicit.trim().length > 0) return explicit.trim();
  const base = Deno.env.get("DELIBERRY_API_BASE_URL");
  if (!base || base.trim().length === 0) return null;
  return `${base.replace(/\/+$/, "")}/operational-orders/events`;
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
  const bytes = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, encoder.encode(message)),
  );
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function signedHeaders(body: string, event: JsonRecord) {
  const headers: Record<string, string> = {
    "content-type": "application/json",
    "x-pos-idempotency-key": String(event.event_id),
    "x-pos-event-id": String(event.event_id),
    "x-pos-trace-id": String(event.trace_id ?? ""),
  };

  const token = Deno.env.get("DELIBERRY_API_TOKEN");
  if (token && token.trim().length > 0) {
    headers.authorization = `Bearer ${token}`;
  }

  const outboundSecret = Deno.env.get("DELIBERRY_OUTBOUND_SECRET");
  if (outboundSecret && outboundSecret.trim().length > 0) {
    const timestamp = Math.floor(Date.now() / 1000).toString();
    headers["x-pos-timestamp"] = timestamp;
    headers["x-pos-signature"] = `sha256=${await hmacSha256Hex(
      outboundSecret,
      `${timestamp}.${body}`,
    )}`;
  }

  return headers;
}

function eventEnvelope(event: JsonRecord): JsonRecord {
  return {
    event_id: event.event_id,
    trace_id: event.trace_id,
    event_sequence: event.event_sequence,
    event_type: event.event_type,
    order_status: actionStatus(event.event_type),
    external_order_id: event.external_order_id,
    store_id: event.restaurant_id,
    reason: event.reason,
    payload_version: event.payload_version,
    channel_id: event.channel_id,
    occurred_at: event.event_occurred_at,
    payload: event.payload ?? {},
  };
}

async function collectRetryableEvents(
  supabase: any,
  storeIds: string[],
  limit: number,
): Promise<JsonRecord[]> {
  const events: JsonRecord[] = [];
  for (const storeId of storeIds) {
    const remaining = Math.max(0, limit - events.length);
    if (remaining === 0) break;
    const { data, error } = await supabase.rpc(
      "get_deliberry_operational_order_events_for_retry",
      {
        p_store_id: storeId,
        p_limit: remaining,
      },
    );
    if (error) throw error;
    events.push(...((data ?? []) as JsonRecord[]));
  }
  return events.filter((event) => actionStatus(event.event_type) != null);
}

serve(async (req) => {
  if (req.method !== "POST") {
    return json({ ok: false, error: "METHOD_NOT_ALLOWED" }, 405);
  }

  const cronSecret = Deno.env.get("CRON_SECRET");
  if (!cronSecret) {
    return json({ ok: false, error: "CRON_SECRET_NOT_CONFIGURED" }, 503);
  }
  if (req.headers.get("authorization") !== `Bearer ${cronSecret}`) {
    return json({ ok: false, error: "UNAUTHORIZED" }, 401);
  }

  const body = await req.json().catch(() => ({})) as JsonRecord;
  const dryRun = body.dry_run === true;
  const limit = Math.min(Math.max(Number(body.limit ?? 100), 1), 500);
  const endpoint = resolveEndpoint();
  const hasCredential = Boolean(Deno.env.get("DELIBERRY_API_TOKEN")) ||
    Boolean(Deno.env.get("DELIBERRY_OUTBOUND_SECRET"));

  if (!dryRun && !endpoint) {
    return json({
      ok: false,
      error: "DELIBERRY_OPERATIONAL_EVENT_ENDPOINT_NOT_CONFIGURED",
    }, 503);
  }
  if (!dryRun && !hasCredential) {
    return json({
      ok: false,
      error: "DELIBERRY_OUTBOUND_CREDENTIAL_NOT_CONFIGURED",
    }, 503);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return json({ ok: false, error: "SUPABASE_SERVICE_NOT_CONFIGURED" }, 503);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);
  const explicitStoreId = asString(body.store_id);
  let storeIds = explicitStoreId != null ? [explicitStoreId] : [];

  if (storeIds.length === 0) {
    const { data, error } = await supabase
      .from("deliberry_operational_order_events")
      .select("restaurant_id")
      .eq("source_system", "pos")
      .eq("destination_system", "deliberry")
      .in("status", ["pending", "failed"])
      .order("created_at", { ascending: true })
      .limit(limit);
    if (error) {
      return json(
        { ok: false, error: "DELIBERRY_RETRY_STORE_QUERY_FAILED" },
        500,
      );
    }
    storeIds = uniqueStrings(
      (data ?? []).map((row: JsonRecord) => row.restaurant_id),
    );
  }

  let events: JsonRecord[];
  try {
    events = await collectRetryableEvents(supabase, storeIds, limit);
  } catch (error) {
    return json({
      ok: false,
      error: "DELIBERRY_RETRY_RPC_FAILED",
      message: String((error as Error).message),
    }, 500);
  }

  const dispatched: JsonRecord[] = [];
  const failed: JsonRecord[] = [];
  const dryRunEvents: JsonRecord[] = [];

  for (const event of events) {
    const envelope = eventEnvelope(event);
    const serialized = JSON.stringify(envelope);

    if (dryRun) {
      dryRunEvents.push(envelope);
      continue;
    }

    try {
      const response = await fetch(endpoint!, {
        method: "POST",
        headers: await signedHeaders(serialized, event),
        body: serialized,
      });
      const responseText = await response.text().catch(() => "");
      if (response.ok || response.status === 409) {
        const { error } = await supabase.rpc(
          "mark_deliberry_operational_event_processed",
          {
            p_store_id: event.restaurant_id,
            p_event_id: event.event_id,
          },
        );
        if (error) throw error;
        dispatched.push({ event_id: event.event_id, status: response.status });
      } else {
        const lastError = `HTTP ${response.status}: ${
          responseText.slice(0, 500)
        }`;
        await supabase.rpc("mark_deliberry_operational_event_failed", {
          p_store_id: event.restaurant_id,
          p_event_id: event.event_id,
          p_last_error: lastError,
          p_dead_after_attempts: Number(body.dead_after_attempts ?? 5),
        });
        failed.push({ event_id: event.event_id, status: response.status });
      }
    } catch (error) {
      await supabase.rpc("mark_deliberry_operational_event_failed", {
        p_store_id: event.restaurant_id,
        p_event_id: event.event_id,
        p_last_error: String((error as Error).message).slice(0, 500),
        p_dead_after_attempts: Number(body.dead_after_attempts ?? 5),
      });
      failed.push({ event_id: event.event_id, status: "exception" });
    }
  }

  return json({
    ok: failed.length === 0,
    dry_run: dryRun,
    store_count: storeIds.length,
    event_count: events.length,
    dispatched_count: dispatched.length,
    failed_count: failed.length,
    dry_run_events: dryRunEvents,
    dispatched,
    failed,
  });
});
