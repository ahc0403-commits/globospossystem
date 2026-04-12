/**
 * wetax-dispatcher — Phase 2 Step 7
 * Processes pending einvoice_jobs: sendOrderInfo + requestEinvoiceInfo
 * Called by pg_cron every 30 seconds (configured in Step 9).
 *
 * Scope: stage1_scope_v1.3.md Section 6.3, 6.4
 * Adaptation points for apitest vendor bugs:
 *   AP1: sid is nullable (sendOrderInfo returns data:"", no sid)
 *   AP2: dispatched_polling_disabled state when polling is off
 *   AP3: requestEinvoiceInfo exponential backoff retry
 */

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const WETAX_BASE_URL = Deno.env.get("WETAX_BASE_URL") ??
  "https://apitest.wetax.com.vn";
const BATCH_SIZE = 10;

// ---------------------------------------------------------------------------
// Token management
// ---------------------------------------------------------------------------
async function getToken(supabase: any): Promise<string> {
  const { data: cred, error } = await supabase
    .from("partner_credentials")
    .select("id,user_id,password_value,password_format,current_token,token_expires_at")
    .eq("data_source", "VNPT_EPAY")
    .single();

  if (error || !cred) throw new Error("partner_credentials not found");

  const now = new Date();
  const expiresAt = cred.token_expires_at ? new Date(cred.token_expires_at) : null;
  const refreshThreshold = expiresAt
    ? new Date(expiresAt.getTime() - 15 * 60 * 1000)
    : now;

  if (cred.current_token && expiresAt && now < refreshThreshold) {
    return cred.current_token;
  }

  // password_value is bytea — supabase-js returns it as base64 string
  const password = typeof cred.password_value === "string"
    ? atob(cred.password_value)
    : new TextDecoder().decode(cred.password_value);

  const loginRes = await fetch(`${WETAX_BASE_URL}/api/wtx/pa/v1/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ user_id: cred.user_id, password }),
  });

  const loginBody = await loginRes.json();
  if (!loginRes.ok || !loginBody?.data?.access_token) {
    await supabase.from("partner_credential_access_log").insert({
      credential_id: cred.id, access_reason: "token_refresh",
      accessed_by_function: "wetax-dispatcher", success: false,
    });
    throw new Error(`WT00 login failed ${loginRes.status}: ${JSON.stringify(loginBody)}`);
  }

  const token: string = loginBody.data.access_token;
  const expiresIn: number = loginBody.data.expires_in ?? 86400;
  const newExpiry = new Date(now.getTime() + expiresIn * 1000);

  await supabase.from("partner_credentials").update({
    current_token: token,
    token_expires_at: newExpiry.toISOString(),
    last_verified_at: now.toISOString(),
    updated_at: now.toISOString(),
  }).eq("id", cred.id);

  await supabase.from("partner_credential_access_log").insert({
    credential_id: cred.id, access_reason: "token_refresh",
    accessed_by_function: "wetax-dispatcher", success: true,
  });

  return token;
}

// ---------------------------------------------------------------------------
// WeTax API call helper
// ---------------------------------------------------------------------------
async function wetaxPost(
  path: string, body: unknown, token: string,
): Promise<{ ok: boolean; status: number; body: any }> {
  const res = await fetch(`${WETAX_BASE_URL}${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${token}`,
    },
    body: JSON.stringify(body),
  });
  const resBody = await res.json().catch(() => null);
  return { ok: res.ok, status: res.status, body: resBody };
}

// ---------------------------------------------------------------------------
// Read system_config values
// ---------------------------------------------------------------------------
async function getConfig(supabase: any): Promise<Record<string, string>> {
  const { data } = await supabase
    .from("system_config")
    .select("key,value")
    .in("key", [
      "wetax_dispatch_enabled",
      "wetax_polling_enabled",
      "wetax_request_einvoice_max_retries",
      "wetax_request_einvoice_backoff_seconds",
    ]);
  const config: Record<string, string> = {};
  for (const row of data ?? []) config[row.key] = row.value;
  return config;
}

// ---------------------------------------------------------------------------
// Log einvoice event
// ---------------------------------------------------------------------------
async function logEvent(
  supabase: any,
  jobId: string | null,
  eventType: string,
  description: string,
  opts: { retryCount?: number; rawRequest?: any; rawResponse?: any } = {},
) {
  await supabase.from("einvoice_events").insert({
    job_id: jobId,
    event_type: eventType,
    description,
    retry_count: opts.retryCount ?? null,
    raw_request: opts.rawRequest ? JSON.stringify(opts.rawRequest) : null,
    raw_response: opts.rawResponse ? JSON.stringify(opts.rawResponse) : null,
  });
}

// ---------------------------------------------------------------------------
// Process a single job: sendOrderInfo
// ---------------------------------------------------------------------------
async function processSendOrder(supabase: any, job: any, token: string, pollingEnabled: boolean) {
  // Check declaration_status (Invariant I10)
  const { data: taxEntity } = await supabase
    .from("tax_entity")
    .select("declaration_status")
    .eq("id", job.tax_entity_id)
    .single();

  if (!taxEntity || taxEntity.declaration_status !== "5") {
    await supabase.from("einvoice_jobs").update({
      status: "failed_terminal",
      error_classification: "declaration_not_accepted",
      error_message: `declaration_status=${taxEntity?.declaration_status ?? "null"}`,
      updated_at: new Date().toISOString(),
    }).eq("id", job.id);
    await logEvent(supabase, job.id, "status_transition",
      `Job failed: declaration_status not 5 (actual: ${taxEntity?.declaration_status})`);
    return;
  }

  const payload = job.send_order_payload;
  const reqBody = { bills: [payload] };

  await supabase.from("einvoice_jobs").update({
    dispatch_attempts: (job.dispatch_attempts ?? 0) + 1,
    last_dispatch_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  }).eq("id", job.id);

  const result = await wetaxPost("/api/wtx/pa/v1/pos/sendOrderInfo", reqBody, token);

  await logEvent(supabase, job.id, "send_order_attempt",
    `sendOrderInfo ${result.ok ? "success" : "failed"} (HTTP ${result.status})`,
    { rawRequest: reqBody, rawResponse: result.body });

  if (!result.ok) {
    // 409 Duplicate = idempotent success
    if (result.status === 409) {
      console.log(`Job ${job.id}: 409 duplicate treated as success`);
    } else if (result.status === 401) {
      // 401: token expired mid-session, will retry next invocation
      await logEvent(supabase, job.id, "send_order_attempt",
        "401 received during dispatch — token will refresh next cycle");
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
      // 5xx or network: leave as pending, retry next invocation
      await logEvent(supabase, job.id, "send_order_attempt",
        `5xx error — will retry (HTTP ${result.status})`);
      return;
    }
  }

  // AP1: sid is nullable — sendOrderInfo on apitest returns data:""
  const sid = result.body?.data?.sid ??
    result.body?.data?.data?.sid ??
    result.body?.sid ?? null;

  // AP2: state transition depends on polling flag
  const newStatus = pollingEnabled ? "dispatched" : "dispatched_polling_disabled";
  const now = new Date().toISOString();

  await supabase.from("einvoice_jobs").update({
    status: newStatus,
    sid: sid,
    dispatched_at: now,
    polling_next_at: pollingEnabled ? now : null,
    updated_at: now,
  }).eq("id", job.id);

  await logEvent(supabase, job.id, "status_transition",
    `Transitioned to ${newStatus}. sid=${sid ?? "null (AP1 — will populate from WT06)"}`);
}

// ---------------------------------------------------------------------------
// Process requestEinvoiceInfo for a dispatched job (AP3: backoff)
// ---------------------------------------------------------------------------
async function processRequestEinvoice(
  supabase: any, job: any, token: string, config: Record<string, string>,
) {
  if (!job.redinvoice_requested) return;
  if (!job.request_einvoice_payload) return;

  // Check backoff schedule
  const nextRetry = job.request_einvoice_next_retry_at
    ? new Date(job.request_einvoice_next_retry_at)
    : null;
  if (nextRetry && new Date() < nextRetry) return; // still in backoff window

  const maxRetries = parseInt(config.wetax_request_einvoice_max_retries ?? "5");
  const backoffStr = config.wetax_request_einvoice_backoff_seconds ?? "0,3,10,30,60";
  const backoff = backoffStr.split(",").map(Number);

  const payload = job.request_einvoice_payload;
  const reqBody = { bills: [payload] };

  const result = await wetaxPost(
    "/api/wtx/pa/v1/pos/requestEinvoiceInfo", reqBody, token,
  );

  const retryCount = (job.request_einvoice_retry_count ?? 0);

  await logEvent(supabase, job.id, "request_einvoice_attempt",
    `requestEinvoiceInfo ${result.ok ? "success" : "failed"} (HTTP ${result.status})`,
    { retryCount, rawRequest: reqBody, rawResponse: result.body });

  if (result.ok) {
    await supabase.from("einvoice_jobs").update({
      request_einvoice_retry_count: 0,
      request_einvoice_next_retry_at: null,
      updated_at: new Date().toISOString(),
    }).eq("id", job.id);
    return;
  }

  // AP3: "POS ID not found" → exponential backoff
  const msg = result.body?.status?.message ?? "";
  const isPosIdNotFound = msg.includes("POS ID not found") || result.status === 400;

  if (isPosIdNotFound || result.status === 400) {
    const newCount = retryCount + 1;
    if (newCount >= maxRetries) {
      await supabase.from("einvoice_jobs").update({
        status: "failed_terminal",
        error_classification: "einvoice_request_not_found_after_retries",
        error_message: msg,
        request_einvoice_retry_count: newCount,
        request_einvoice_next_retry_at: null,
        updated_at: new Date().toISOString(),
      }).eq("id", job.id);
      await logEvent(supabase, job.id, "status_transition",
        `requestEinvoiceInfo exhausted ${newCount} retries → failed_terminal`);
    } else {
      const delaySeconds = backoff[newCount] ?? backoff[backoff.length - 1];
      const nextRetryAt = new Date(Date.now() + delaySeconds * 1000).toISOString();
      await supabase.from("einvoice_jobs").update({
        request_einvoice_retry_count: newCount,
        request_einvoice_next_retry_at: nextRetryAt,
        updated_at: new Date().toISOString(),
      }).eq("id", job.id);
    }
  }
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------
serve(async (req: Request) => {
  const authHeader = req.headers.get("Authorization");
  const cronSecret = Deno.env.get("CRON_SECRET");
  if (cronSecret && authHeader !== `Bearer ${cronSecret}`) {
    return new Response("Unauthorized", { status: 401 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  try {
    const config = await getConfig(supabase);

    if (config.wetax_dispatch_enabled !== "true") {
      return new Response(JSON.stringify({ skipped: "dispatch_disabled" }), {
        status: 200, headers: { "Content-Type": "application/json" },
      });
    }

    // Fetch pending jobs in FIFO order
    const { data: jobs, error } = await supabase
      .from("einvoice_jobs")
      .select("*")
      .eq("status", "pending")
      .order("created_at", { ascending: true })
      .limit(BATCH_SIZE);

    if (error) throw error;
    if (!jobs || jobs.length === 0) {
      return new Response(JSON.stringify({ processed: 0 }), {
        status: 200, headers: { "Content-Type": "application/json" },
      });
    }

    let token = await getToken(supabase);
    const pollingEnabled = config.wetax_polling_enabled === "true";
    const results = [];

    for (const job of jobs) {
      try {
        await processSendOrder(supabase, job, token, pollingEnabled);

        // Reload job to get updated status for requestEinvoiceInfo decision
        const { data: updated } = await supabase
          .from("einvoice_jobs").select("*").eq("id", job.id).single();

        if (
          updated &&
          (updated.status === "dispatched" || updated.status === "dispatched_polling_disabled") &&
          updated.redinvoice_requested
        ) {
          await processRequestEinvoice(supabase, updated, token, config);
        }

        results.push({ id: job.id, ok: true });
      } catch (jobErr) {
        console.error(`Job ${job.id} error:`, jobErr);
        await logEvent(supabase, job.id, "dispatcher_error",
          `Unhandled error: ${(jobErr as Error).message}`);
        results.push({ id: job.id, ok: false, error: (jobErr as Error).message });
      }
    }

    return new Response(JSON.stringify({ processed: jobs.length, results }), {
      status: 200, headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("Dispatcher fatal error:", err);
    return new Response(JSON.stringify({ error: (err as Error).message }), {
      status: 500, headers: { "Content-Type": "application/json" },
    });
  }
});
