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

const WETAX_BASE_URL = Deno.env.get("WETAX_BASE_URL") ?? "https://apitest.wetax.com.vn";
const WETAX_ENCRYPTION_KEY = Deno.env.get("WETAX_ENCRYPTION_KEY"); // undefined → plaintext fallback
const BATCH_SIZE = 10;

// ---------------------------------------------------------------------------
// AES-256-CBC password encryption (WeTax spec)
// Key: SHA-256(encryptionKey) → 32 bytes
// IV:  hex(keyBytes)[0:16] as UTF-8 (16 bytes, deterministic from key)
// Out: Base64
// ---------------------------------------------------------------------------
async function encryptPassword(plain: string, encryptionKey: string): Promise<string> {
  const enc = new TextEncoder();

  // SHA-256 the key string → 32-byte AES key
  const keyHash = await crypto.subtle.digest("SHA-256", enc.encode(encryptionKey));
  const keyBytes = new Uint8Array(keyHash);

  // IV = first 16 chars of hex(keyBytes) as UTF-8 bytes
  const keyHex = Array.from(keyBytes).map(b => b.toString(16).padStart(2, "0")).join("");
  const iv = enc.encode(keyHex.substring(0, 16)); // 16 bytes

  // Import key for AES-CBC
  const cryptoKey = await crypto.subtle.importKey(
    "raw", keyBytes, { name: "AES-CBC" }, false, ["encrypt"]
  );

  // PKCS7 pad to 16-byte boundary
  const plainBytes = enc.encode(plain);
  const pad = 16 - (plainBytes.length % 16);
  const padded = new Uint8Array(plainBytes.length + pad);
  padded.set(plainBytes);
  padded.fill(pad, plainBytes.length);

  const encrypted = await crypto.subtle.encrypt({ name: "AES-CBC", iv }, cryptoKey, padded);
  return btoa(String.fromCharCode(...new Uint8Array(encrypted)));
}

// ---------------------------------------------------------------------------
// bytea hex decode (Supabase returns bytea as \x313233...)
// ---------------------------------------------------------------------------
function decodeByteaToString(v: unknown): string {
  if (!v) return "";
  if (v instanceof Uint8Array) return new TextDecoder().decode(v);
  const s = String(v);
  const m = s.match(/^[\\]?x([0-9a-fA-F]+)$/);
  if (m) {
    const bytes = new Uint8Array(m[1].length / 2);
    for (let i = 0; i < m[1].length; i += 2)
      bytes[i / 2] = parseInt(m[1].substring(i, i + 2), 16);
    return new TextDecoder().decode(bytes);
  }
  try { return atob(s); } catch { return s; }
}

// ---------------------------------------------------------------------------
// Token management
// ---------------------------------------------------------------------------
async function getToken(supabase: any): Promise<string> {
  const { data: cred, error } = await supabase.from("partner_credentials")
    .select("id,user_id,password_value,password_format,current_token,token_expires_at")
    .eq("data_source", "VNPT_EPAY").single();
  if (error || !cred) throw new Error("partner_credentials not found: " + error?.message);

  const now = new Date();
  const expiresAt = cred.token_expires_at ? new Date(cred.token_expires_at) : null;
  const threshold = expiresAt ? new Date(expiresAt.getTime() - 15 * 60 * 1000) : now;
  if (cred.current_token && expiresAt && now < threshold) return cred.current_token;

  // Decode plaintext password from bytea
  const plainPassword = decodeByteaToString(cred.password_value);

  // Encrypt if WETAX_ENCRYPTION_KEY is set and password_format is plaintext
  let sendPassword = plainPassword;
  if (WETAX_ENCRYPTION_KEY && cred.password_format === "plaintext") {
    sendPassword = await encryptPassword(plainPassword, WETAX_ENCRYPTION_KEY);
    console.log("WT00: sending AES256-encrypted password");
  } else {
    console.log("WT00: sending plaintext password (no WETAX_ENCRYPTION_KEY set)");
  }

  const loginRes = await fetch(`${WETAX_BASE_URL}/api/wtx/pa/v1/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ user_id: cred.user_id, password: sendPassword }),
  });
  const loginBody = await loginRes.json();
  if (!loginRes.ok || !loginBody?.data?.access_token) {
    await supabase.from("partner_credential_access_log").insert({
      credential_id: cred.id, access_reason: "token_refresh",
      accessed_by_function: "wetax-dispatcher", success: false,
    });
    throw new Error(`WT00 failed ${loginRes.status}: ${JSON.stringify(loginBody)}`);
  }

  const token: string = loginBody.data.access_token;
  const expiresIn: number = loginBody.data.expires_in ?? 86400;
  await supabase.from("partner_credentials").update({
    current_token: token,
    token_expires_at: new Date(now.getTime() + expiresIn * 1000).toISOString(),
    last_verified_at: now.toISOString(), updated_at: now.toISOString(),
  }).eq("id", cred.id);
  await supabase.from("partner_credential_access_log").insert({
    credential_id: cred.id, access_reason: "token_refresh",
    accessed_by_function: "wetax-dispatcher", success: true,
  });
  return token;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
async function wetaxPost(path: string, body: unknown, token: string) {
  const res = await fetch(`${WETAX_BASE_URL}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${token}` },
    body: JSON.stringify(body),
  });
  return { ok: res.ok, status: res.status, body: await res.json().catch(() => null) };
}

async function getConfig(supabase: any): Promise<Record<string, string>> {
  const { data } = await supabase.from("system_config").select("key,value")
    .in("key", ["wetax_dispatch_enabled","wetax_polling_enabled",
                "wetax_request_einvoice_max_retries","wetax_request_einvoice_backoff_seconds"]);
  const c: Record<string, string> = {};
  for (const r of data ?? []) c[r.key] = r.value;
  return c;
}

async function logEvent(supabase: any, jobId: string|null, eventType: string, description: string, opts: any={}) {
  await supabase.from("einvoice_events").insert({
    job_id: jobId, event_type: eventType, description,
    retry_count: opts.retryCount ?? null,
    raw_request: opts.rawRequest ? JSON.stringify(opts.rawRequest) : null,
    raw_response: opts.rawResponse ? JSON.stringify(opts.rawResponse) : null,
  });
}

async function processSendOrder(supabase: any, job: any, token: string, pollingEnabled: boolean) {
  const { data: te } = await supabase.from("tax_entity")
    .select("declaration_status").eq("id", job.tax_entity_id).single();
  if (!te || te.declaration_status !== "5") {
    await supabase.from("einvoice_jobs").update({
      status: "failed_terminal", error_classification: "declaration_not_accepted",
      error_message: `declaration_status=${te?.declaration_status ?? "null"}`,
      updated_at: new Date().toISOString(),
    }).eq("id", job.id);
    await logEvent(supabase, job.id, "status_transition", `declaration_status not 5`);
    return;
  }

  const reqBody = { invoices: [job.send_order_payload] };
  await supabase.from("einvoice_jobs").update({
    dispatch_attempts: (job.dispatch_attempts ?? 0) + 1,
    last_dispatch_at: new Date().toISOString(), updated_at: new Date().toISOString(),
  }).eq("id", job.id);

  const result = await wetaxPost("/api/wtx/pa/v1/pos/invoices", reqBody, token);
  await logEvent(supabase, job.id, "send_order_attempt",
    `WT03 /pos/invoices ${result.ok ? "success" : "failed"} HTTP ${result.status}`,
    { rawRequest: reqBody, rawResponse: result.body });

  if (!result.ok) {
    if (result.status === 409) { /* idempotent */ }
    else if (result.status === 401) {
      await logEvent(supabase, job.id, "send_order_attempt", "401 token refresh next cycle");
      return;
    } else if (result.status >= 400 && result.status < 500) {
      await supabase.from("einvoice_jobs").update({
        status: "failed_terminal", error_classification: "send_order_client_error",
        error_message: JSON.stringify(result.body), updated_at: new Date().toISOString(),
      }).eq("id", job.id); return;
    } else {
      await logEvent(supabase, job.id, "send_order_attempt", `5xx retry HTTP ${result.status}`);
      return;
    }
  }

  const items: any[] = Array.isArray(result.body?.data) ? result.body.data : [];
  const sid: string | null = items[0]?.sid ?? null;
  const newStatus = pollingEnabled ? "dispatched" : "dispatched_polling_disabled";
  const now = new Date().toISOString();

  await supabase.from("einvoice_jobs").update({
    status: newStatus, sid, dispatched_at: now,
    polling_next_at: pollingEnabled ? now : null, updated_at: now,
  }).eq("id", job.id);
  await logEvent(supabase, job.id, "status_transition",
    `-> ${newStatus}. sid=${sid}. WT03 code=${items[0]?.status?.code}`);
}

async function processRequestEinvoice(supabase: any, job: any, token: string, config: Record<string,string>) {
  if (!job.redinvoice_requested || !job.request_einvoice_payload) return;
  const nextRetry = job.request_einvoice_next_retry_at ? new Date(job.request_einvoice_next_retry_at) : null;
  if (nextRetry && new Date() < nextRetry) return;
  const maxRetries = parseInt(config.wetax_request_einvoice_max_retries ?? "5");
  const backoff = (config.wetax_request_einvoice_backoff_seconds ?? "0,3,10,30,60").split(",").map(Number);
  // WT05 body: {seller:{...}, invoices:[...]} — stored as complete body in request_einvoice_payload
  const reqBody = job.request_einvoice_payload;
  const result = await wetaxPost("/api/wtx/pa/v1/pos/invoices-issue", reqBody, token);
  const retryCount = job.request_einvoice_retry_count ?? 0;
  await logEvent(supabase, job.id, "request_einvoice_attempt",
    `WT05 ${result.ok ? "success" : "failed"} HTTP ${result.status}`,
    { retryCount, rawRequest: reqBody, rawResponse: result.body });
  if (result.ok) {
    await supabase.from("einvoice_jobs").update({
      request_einvoice_retry_count: 0, request_einvoice_next_retry_at: null,
      updated_at: new Date().toISOString(),
    }).eq("id", job.id); return;
  }
  const newCount = retryCount + 1;
  if (newCount >= maxRetries) {
    await supabase.from("einvoice_jobs").update({
      status: "failed_terminal", error_classification: "einvoice_request_not_found_after_retries",
      error_message: result.body?.status?.message ?? "",
      request_einvoice_retry_count: newCount, request_einvoice_next_retry_at: null,
      updated_at: new Date().toISOString(),
    }).eq("id", job.id);
  } else {
    const delay = backoff[newCount] ?? backoff[backoff.length - 1];
    await supabase.from("einvoice_jobs").update({
      request_einvoice_retry_count: newCount,
      request_einvoice_next_retry_at: new Date(Date.now() + delay * 1000).toISOString(),
      updated_at: new Date().toISOString(),
    }).eq("id", job.id);
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
serve(async (req: Request) => {
  const cronSecret = Deno.env.get("CRON_SECRET");
  if (cronSecret && req.headers.get("Authorization") !== `Bearer ${cronSecret}`) {
    return new Response("Unauthorized", { status: 401 });
  }
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  try {
    const config = await getConfig(supabase);
    if (config.wetax_dispatch_enabled !== "true") {
      return new Response(JSON.stringify({ skipped: "dispatch_disabled" }), { status: 200 });
    }
    const { data: jobs, error } = await supabase.from("einvoice_jobs")
      .select("*").eq("status", "pending").order("created_at", { ascending: true }).limit(BATCH_SIZE);
    if (error) throw error;
    if (!jobs?.length) return new Response(JSON.stringify({ processed: 0 }), { status: 200 });

    const token = await getToken(supabase);
    const pollingEnabled = config.wetax_polling_enabled === "true";
    const results = [];

    for (const job of jobs) {
      try {
        await processSendOrder(supabase, job, token, pollingEnabled);
        const { data: updated } = await supabase.from("einvoice_jobs").select("*").eq("id", job.id).single();
        if (updated && (updated.status === "dispatched" || updated.status === "dispatched_polling_disabled") && updated.redinvoice_requested) {
          await processRequestEinvoice(supabase, updated, token, config);
        }
        results.push({ id: job.id, ok: true });
      } catch (e) {
        await logEvent(supabase, job.id, "dispatcher_error", (e as Error).message);
        results.push({ id: job.id, ok: false, error: (e as Error).message });
      }
    }
    return new Response(JSON.stringify({ processed: jobs.length, results }), {
      status: 200, headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: (err as Error).message }), { status: 500 });
  }
});
