/**
 * wetax-dispatcher — v5 (AES256 password encryption 2026-04-13)
 *
 * Vendor confirmed encryption spec:
 *   Algorithm: AES/CBC/PKCS5Padding
 *   Key:  SHA-256(WETAX_ENCRYPTION_KEY) → 32 bytes
 *   IV:   hex(key_bytes)[0:16] as UTF-8 bytes (16 bytes)
 *   Output: Base64
 *
 * WETAX_ENCRYPTION_KEY secret:
 *   - apitest: "mytestkeyasdddds" (vendor demo key)
 *   - production: key from WeTax application.yml (to be provided)
 *   - If secret not set: falls back to plaintext (current apitest behavior)
 */
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  getConfig,
  getToken,
  logEvent,
  WETAX_BASE_URL,
} from "../_shared/wetax.ts";

const BATCH_SIZE = 10;
const DISPATCH_CONFIG_KEYS = [
  "wetax_dispatch_enabled",
  "wetax_polling_enabled",
  "wetax_request_einvoice_max_retries",
  "wetax_request_einvoice_backoff_seconds",
];
const TOKEN_OPTIONS = {
  functionName: "wetax-dispatcher",
  accessReason: "token_refresh",
  formatLoginError: (status: number, body: unknown) =>
    `WT00 failed ${status}: ${JSON.stringify(body)}`,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
async function wetaxPost(path: string, body: unknown, token: string) {
  const res = await fetch(`${WETAX_BASE_URL}${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${token}`,
    },
    body: JSON.stringify(body),
  });
  return {
    ok: res.ok,
    status: res.status,
    body: await res.json().catch(() => null),
  };
}

async function processSendOrder(
  supabase: any,
  job: any,
  token: string,
  pollingEnabled: boolean,
) {
  const { data: te } = await supabase.from("tax_entity")
    .select("declaration_status").eq("id", job.tax_entity_id).single();
  if (!te || te.declaration_status !== "5") {
    await supabase.from("einvoice_jobs").update({
      status: "failed_terminal",
      error_classification: "declaration_not_accepted",
      error_message: `declaration_status=${te?.declaration_status ?? "null"}`,
      updated_at: new Date().toISOString(),
    }).eq("id", job.id);
    await logEvent(
      supabase,
      job.id,
      "status_transition",
      `declaration_status not 5`,
    );
    return;
  }

  const reqBody = { invoices: [job.send_order_payload] };
  await supabase.from("einvoice_jobs").update({
    dispatch_attempts: (job.dispatch_attempts ?? 0) + 1,
    last_dispatch_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  }).eq("id", job.id);

  const result = await wetaxPost("/api/wtx/pa/v1/pos/invoices", reqBody, token);
  await logEvent(
    supabase,
    job.id,
    "send_order_attempt",
    `WT03 /pos/invoices ${
      result.ok ? "success" : "failed"
    } HTTP ${result.status}`,
    { rawRequest: reqBody, rawResponse: result.body },
  );

  if (!result.ok) {
    if (result.status === 409) { /* idempotent */ }
    else if (result.status === 401) {
      await logEvent(
        supabase,
        job.id,
        "send_order_attempt",
        "401 token refresh next cycle",
      );
      return;
    } else if (result.status >= 400 && result.status < 500) {
      await supabase.from("einvoice_jobs").update({
        status: "failed_terminal",
        error_classification: "send_order_client_error",
        error_message: JSON.stringify(result.body),
        updated_at: new Date().toISOString(),
      }).eq("id", job.id);
      return;
    } else {
      await logEvent(
        supabase,
        job.id,
        "send_order_attempt",
        `5xx retry HTTP ${result.status}`,
      );
      return;
    }
  }

  const items: any[] = Array.isArray(result.body?.data) ? result.body.data : [];
  const sid: string | null = items[0]?.sid ?? null;
  const newStatus = pollingEnabled
    ? "dispatched"
    : "dispatched_polling_disabled";
  const now = new Date().toISOString();

  await supabase.from("einvoice_jobs").update({
    status: newStatus,
    sid,
    dispatched_at: now,
    polling_next_at: pollingEnabled ? now : null,
    updated_at: now,
  }).eq("id", job.id);
  await logEvent(
    supabase,
    job.id,
    "status_transition",
    `-> ${newStatus}. sid=${sid}. WT03 code=${items[0]?.status?.code}`,
  );
}

async function processRequestEinvoice(
  supabase: any,
  job: any,
  token: string,
  config: Record<string, string>,
) {
  if (!job.redinvoice_requested || !job.request_einvoice_payload) return;
  const nextRetry = job.request_einvoice_next_retry_at
    ? new Date(job.request_einvoice_next_retry_at)
    : null;
  if (nextRetry && new Date() < nextRetry) return;
  const maxRetries = parseInt(config.wetax_request_einvoice_max_retries ?? "5");
  const backoff =
    (config.wetax_request_einvoice_backoff_seconds ?? "0,3,10,30,60").split(",")
      .map(Number);
  // WT05 body: {seller:{...}, invoices:[...]} — stored as complete body in request_einvoice_payload
  const reqBody = job.request_einvoice_payload;
  const result = await wetaxPost(
    "/api/wtx/pa/v1/pos/invoices-issue",
    reqBody,
    token,
  );
  const retryCount = job.request_einvoice_retry_count ?? 0;
  await logEvent(
    supabase,
    job.id,
    "request_einvoice_attempt",
    `WT05 ${result.ok ? "success" : "failed"} HTTP ${result.status}`,
    { retryCount, rawRequest: reqBody, rawResponse: result.body },
  );
  if (result.ok) {
    await supabase.from("einvoice_jobs").update({
      request_einvoice_retry_count: 0,
      request_einvoice_next_retry_at: null,
      updated_at: new Date().toISOString(),
    }).eq("id", job.id);
    return;
  }
  const newCount = retryCount + 1;
  if (newCount >= maxRetries) {
    await supabase.from("einvoice_jobs").update({
      status: "failed_terminal",
      error_classification: "einvoice_request_not_found_after_retries",
      error_message: result.body?.status?.message ?? "",
      request_einvoice_retry_count: newCount,
      request_einvoice_next_retry_at: null,
      updated_at: new Date().toISOString(),
    }).eq("id", job.id);
  } else {
    const delay = backoff[newCount] ?? backoff[backoff.length - 1];
    await supabase.from("einvoice_jobs").update({
      request_einvoice_retry_count: newCount,
      request_einvoice_next_retry_at: new Date(Date.now() + delay * 1000)
        .toISOString(),
      updated_at: new Date().toISOString(),
    }).eq("id", job.id);
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
serve(async (req: Request) => {
  const cronSecret = Deno.env.get("CRON_SECRET");
  if (!cronSecret) {
    return new Response("CRON_SECRET not configured", { status: 503 });
  }
  if (req.headers.get("Authorization") !== `Bearer ${cronSecret}`) {
    return new Response("Unauthorized", { status: 401 });
  }
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  try {
    const config = await getConfig(supabase, DISPATCH_CONFIG_KEYS);
    if (config.wetax_dispatch_enabled !== "true") {
      return new Response(JSON.stringify({ skipped: "dispatch_disabled" }), {
        status: 200,
      });
    }
    const { data: jobs, error } = await supabase.from("einvoice_jobs")
      .select("*").eq("status", "pending").order("created_at", {
        ascending: true,
      }).limit(BATCH_SIZE);
    if (error) throw error;
    if (!jobs?.length) {
      return new Response(JSON.stringify({ processed: 0 }), { status: 200 });
    }

    const token = await getToken(supabase, TOKEN_OPTIONS);
    const pollingEnabled = config.wetax_polling_enabled === "true";
    const results = [];

    for (const job of jobs) {
      try {
        await processSendOrder(supabase, job, token, pollingEnabled);
        const { data: updated } = await supabase.from("einvoice_jobs").select(
          "*",
        ).eq("id", job.id).single();
        if (
          updated &&
          (updated.status === "dispatched" ||
            updated.status === "dispatched_polling_disabled") &&
          updated.redinvoice_requested
        ) {
          await processRequestEinvoice(supabase, updated, token, config);
        }
        results.push({ id: job.id, ok: true });
      } catch (e) {
        await logEvent(
          supabase,
          job.id,
          "dispatcher_error",
          (e as Error).message,
        );
        results.push({ id: job.id, ok: false, error: (e as Error).message });
      }
    }
    return new Response(JSON.stringify({ processed: jobs.length, results }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: (err as Error).message }), {
      status: 500,
    });
  }
});
