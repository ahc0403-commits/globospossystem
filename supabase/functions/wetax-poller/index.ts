/**
 * wetax-poller — Phase 2 Step 7
 * Polls WT06 invoices-status for dispatched einvoice_jobs.
 * Called by pg_cron on a schedule (configured in Step 9).
 *
 * Scope: stage1_scope_v1.3.md Section 6.5
 * NOTE: wetax_polling_enabled=false by default (apitest WT06 bug).
 *       Enable via Appendix B procedure after vendor fix.
 */

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Supabase returns bytea as hex "\\x313233..." — decode correctly
function decodeByteaToString(v) {
  if (!v) return "";
  if (v instanceof Uint8Array) return new TextDecoder().decode(v);
  const s = String(v);
  const hexMatch = s.match(/^[\\\\]?x([0-9a-fA-F]+)$/);
  if (hexMatch) {
    const bytes = new Uint8Array(hexMatch[1].length / 2);
    for (let i = 0; i < hexMatch[1].length; i += 2)
      bytes[i / 2] = parseInt(hexMatch[1].substring(i, i + 2), 16);
    return new TextDecoder().decode(bytes);
  }
  try { return atob(s); } catch { return s; }
}


const WETAX_BASE_URL = Deno.env.get("WETAX_BASE_URL") ??
  "https://apitest.wetax.com.vn";
const POLL_BATCH_SIZE = 50; // max ref_ids per WT06 call
const STALE_HOURS = 24; // jobs older than this since dispatched_at → stale

async function getConfig(supabase: any): Promise<Record<string, string>> {
  const { data } = await supabase
    .from("system_config")
    .select("key,value")
    .in("key", ["wetax_polling_enabled"]);
  const config: Record<string, string> = {};
  for (const row of data ?? []) config[row.key] = row.value;
  return config;
}

async function getToken(supabase: any): Promise<string> {
  const { data: cred } = await supabase
    .from("partner_credentials")
    .select("id,user_id,password_value,current_token,token_expires_at")
    .eq("data_source", "VNPT_EPAY")
    .single();

  if (!cred) throw new Error("partner_credentials not found");

  const now = new Date();
  const expiresAt = cred.token_expires_at ? new Date(cred.token_expires_at) : null;
  const threshold = expiresAt ? new Date(expiresAt.getTime() - 15 * 60 * 1000) : now;

  if (cred.current_token && expiresAt && now < threshold) return cred.current_token;

  const password = decodeByteaToString(cred.password_value);

  const loginRes = await fetch(`${WETAX_BASE_URL}/api/wtx/pa/v1/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ user_id: cred.user_id, password }),
  });
  const loginBody = await loginRes.json();
  if (!loginRes.ok || !loginBody?.data?.access_token) {
    throw new Error(`WT00 failed: ${loginRes.status}`);
  }

  const token = loginBody.data.access_token;
  const expiresIn = loginBody.data.expires_in ?? 86400;
  await supabase.from("partner_credentials").update({
    current_token: token,
    token_expires_at: new Date(now.getTime() + expiresIn * 1000).toISOString(),
    last_verified_at: now.toISOString(),
    updated_at: now.toISOString(),
  }).eq("id", cred.id);

  await supabase.from("partner_credential_access_log").insert({
    credential_id: cred.id, access_reason: "token_refresh_poller",
    accessed_by_function: "wetax-poller", success: true,
  });
  return token;
}

async function logEvent(
  supabase: any, jobId: string | null, eventType: string,
  description: string, rawResponse?: any,
) {
  await supabase.from("einvoice_events").insert({
    job_id: jobId, event_type: eventType, description,
    raw_response: rawResponse ? JSON.stringify(rawResponse) : null,
  });
}

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

    if (config.wetax_polling_enabled !== "true") {
      await logEvent(supabase, null, "polling_skipped",
        "wetax_polling_enabled=false — skipping poll cycle (AP2)");
      return new Response(JSON.stringify({ skipped: "polling_disabled" }), {
        status: 200, headers: { "Content-Type": "application/json" },
      });
    }

    // Move stale jobs (dispatched > 24h ago)
    const staleThreshold = new Date(Date.now() - STALE_HOURS * 60 * 60 * 1000).toISOString();
    const { data: staleJobs } = await supabase
      .from("einvoice_jobs")
      .select("id")
      .eq("status", "dispatched")
      .lt("dispatched_at", staleThreshold);

    for (const sj of staleJobs ?? []) {
      await supabase.from("einvoice_jobs").update({
        status: "stale", updated_at: new Date().toISOString(),
      }).eq("id", sj.id);
      await logEvent(supabase, sj.id, "status_transition",
        `Job moved to stale: dispatched_at exceeded ${STALE_HOURS}h window`);
    }

    // Fetch jobs due for polling
    const now = new Date().toISOString();
    const { data: jobs } = await supabase
      .from("einvoice_jobs")
      .select("id,ref_id,sid,tax_entity_id,redinvoice_requested")
      .eq("status", "dispatched")
      .lte("polling_next_at", now)
      .order("dispatched_at", { ascending: true })
      .limit(POLL_BATCH_SIZE);

    if (!jobs || jobs.length === 0) {
      return new Response(JSON.stringify({ polled: 0 }), {
        status: 200, headers: { "Content-Type": "application/json" },
      });
    }

    const token = await getToken(supabase);
    const refIds = jobs.map((j: any) => j.ref_id);

    // WT06 invoices-status — batch call
    const pollRes = await fetch(
      `${WETAX_BASE_URL}/api/wtx/pa/v1/pos/invoices-status`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${token}`,
        },
        body: JSON.stringify({ invoices: refIds }),
      },
    );

    const pollBody = await pollRes.json().catch(() => null);

    await logEvent(supabase, null, "poll_result",
      `WT06 batch: ${jobs.length} jobs, HTTP ${pollRes.status}`,
      pollBody);

    if (!pollRes.ok) {
      // Known apitest NPE — log and skip
      const msg = pollBody?.status?.message ?? "";
      if (msg.includes("null") || msg.includes("NPE") || msg.includes("getGuid")) {
        await logEvent(supabase, null, "poll_result",
          "WT06 known apitest NPE — no status updates applied");
      }
      return new Response(JSON.stringify({ polled: 0, error: msg }), {
        status: 200, headers: { "Content-Type": "application/json" },
      });
    }

    // Process each result
    const statusData: any[] = pollBody?.data ?? [];
    const jobMap = new Map(jobs.map((j: any) => [j.ref_id, j]));
    const updated = [];

    for (const item of statusData) {
      const job = jobMap.get(item.ref_id);
      if (!job) continue;

      // AP1: populate sid if missing and WT06 has it
      const sid = item.sid ?? null;

      // Determine new status from issuance_status + cqt_report_status
      const issuance = item.issuance_status ?? "";
      const cqt = item.cqt_report_status ?? "";
      let newStatus = "dispatched"; // keep polling by default

      if (issuance === "Issued" && cqt === "Issued") {
        newStatus = job.redinvoice_requested ? "issued_by_portal" : "reported";
      } else if (issuance === "Not Issued" || issuance === "Error") {
        newStatus = "failed_terminal";
      }

      // Calculate next polling time (exponential schedule per scope Section 6.5)
      const dispatched = new Date(job.dispatched_at ?? Date.now());
      const ageMs = Date.now() - dispatched.getTime();
      const nextPollDelay = ageMs < 30_000 ? 10
        : ageMs < 120_000 ? 30
        : ageMs < 600_000 ? 120
        : ageMs < 1_800_000 ? 600
        : ageMs < 7_200_000 ? 1800
        : 7200; // seconds

      const nextPollAt = newStatus === "dispatched"
        ? new Date(Date.now() + nextPollDelay * 1000).toISOString()
        : null;

      await supabase.from("einvoice_jobs").update({
        status: newStatus,
        sid: sid ?? job.sid,
        cqt_report_status: cqt || null,
        issuance_status: issuance || null,
        lookup_url: item.lookup_url ?? null,
        polling_next_at: nextPollAt,
        updated_at: new Date().toISOString(),
        ...(newStatus === "failed_terminal" ? {
          error_classification: "wetax_issuance_error",
          error_message: `issuance=${issuance}, cqt=${cqt}`,
        } : {}),
      }).eq("id", job.id);

      if (newStatus !== "dispatched") {
        await logEvent(supabase, job.id, "status_transition",
          `WT06 → ${newStatus} (issuance=${issuance}, cqt=${cqt})`, item);
      }
      updated.push({ id: job.id, status: newStatus });
    }

    // Jobs not in WT06 response: update polling_next_at only
    for (const job of jobs) {
      if (!statusData.find((s: any) => s.ref_id === job.ref_id)) {
        const nextPollAt = new Date(Date.now() + 30_000).toISOString();
        await supabase.from("einvoice_jobs").update({
          polling_next_at: nextPollAt, updated_at: new Date().toISOString(),
        }).eq("id", job.id);
      }
    }

    return new Response(JSON.stringify({ polled: jobs.length, updated }), {
      status: 200, headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("Poller error:", err);
    return new Response(JSON.stringify({ error: (err as Error).message }), {
      status: 500, headers: { "Content-Type": "application/json" },
    });
  }
});
