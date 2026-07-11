import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  asString,
  buildCashRegisterInvoicePayload,
  getCashRegisterInvoiceStatus,
  getMeInvoiceToken,
  json,
  loadRuntimeConfig,
  loadSellerConfig,
  logMeInvoiceEvent,
  parsePublishResult,
  publishCashRegisterInvoice,
  safeMeInvoiceErrorMessage,
  safeMisaResponseCode,
  type SellerConfig,
  summarizePublishResponse,
  validateCashRegisterInvoicePayload,
} from "../_shared/meinvoice.ts";

type JsonRecord = Record<string, unknown>;

const DISPATCH_CLAIM_TIMEOUT_MS = 15 * 60 * 1000;

async function claimPendingJob(supabase: any, job: JsonRecord) {
  const claimId = crypto.randomUUID();
  const now = new Date();
  const staleBefore = new Date(
    now.getTime() - DISPATCH_CLAIM_TIMEOUT_MS,
  ).toISOString();
  const attempt = Number(job.dispatch_attempts ?? 0) + 1;
  const { data, error } = await supabase.from("meinvoice_jobs").update({
    dispatch_claim_id: claimId,
    dispatch_claimed_at: now.toISOString(),
    dispatch_attempts: attempt,
    last_dispatch_at: now.toISOString(),
    updated_at: now.toISOString(),
  })
    .eq("id", job.id)
    .eq("status", "pending")
    .or(`dispatch_claim_id.is.null,dispatch_claimed_at.lt.${staleBefore}`)
    .select("*")
    .maybeSingle();

  if (error) throw error;
  if (!data || data.dispatch_claim_id !== claimId) return null;
  return data as JsonRecord;
}

async function markConfigBlocked(
  supabase: any,
  job: JsonRecord,
  message: string,
) {
  await supabase.from("meinvoice_jobs").update({
    status: "dispatch_paused",
    error_message: message.slice(0, 1000),
    dispatch_claim_id: null,
    dispatch_claimed_at: null,
    updated_at: new Date().toISOString(),
  }).eq("id", job.id);
  await logMeInvoiceEvent(
    supabase,
    String(job.id),
    "dispatch_config_blocked",
    message,
  );
}

async function markFailed(
  supabase: any,
  job: JsonRecord,
  message: string,
  publishMetadata: JsonRecord | null = null,
) {
  await supabase.from("meinvoice_jobs").update({
    status: "failed",
    error_message: message.slice(0, 1000),
    dispatch_claim_id: null,
    dispatch_claimed_at: null,
    updated_at: new Date().toISOString(),
  }).eq("id", job.id);
  await logMeInvoiceEvent(
    supabase,
    String(job.id),
    "dispatch_failed",
    message,
    {
      retryCount: Number(job.dispatch_attempts ?? 0),
      metadata: publishMetadata,
    },
  );
}

// MISA portal docs: InvoiceNumberNotCotinuous means the series is allocating
// a number to a concurrent request. Release the claim and keep the job
// pending so the next run retries; requests must stay sequential per series.
async function markTransient(
  supabase: any,
  job: JsonRecord,
  message: string,
) {
  await supabase.from("meinvoice_jobs").update({
    error_message: message.slice(0, 1000),
    dispatch_claim_id: null,
    dispatch_claimed_at: null,
    updated_at: new Date().toISOString(),
  }).eq("id", job.id);
  await logMeInvoiceEvent(
    supabase,
    String(job.id),
    "dispatch_retry_scheduled",
    message,
    { retryCount: Number(job.dispatch_attempts ?? 0) },
  );
}

// MISA portal docs: InvoiceDuplicated with our stable RefID (= job id) can
// mean the invoice was already issued on an earlier attempt whose response
// was lost. Look it up by RefID before declaring failure.
async function reconcileDuplicated(
  seller: SellerConfig,
  token: string,
  job: JsonRecord,
): Promise<JsonRecord | null> {
  try {
    const statusResponse = await getCashRegisterInvoiceStatus(
      seller,
      token,
      [String(job.id)],
    );
    const raw = statusResponse.body as any;
    const data = raw?.Data ?? raw?.data;
    const list = Array.isArray(data) ? data : (data ? [data] : []);
    for (const entry of list) {
      if (asString(entry?.InvNo)) {
        return {
          RefID: asString(entry?.RefID) ?? String(job.id),
          TransactionID: asString(entry?.TransactionID),
          InvSeries: asString(entry?.InvSeries),
          InvNo: asString(entry?.InvNo),
          InvCode: asString(entry?.InvoiceCode) ?? asString(entry?.InvCode),
        };
      }
    }
  } catch (_error) {
    // Fall through to failed handling; reconciliation is best-effort.
  }
  return null;
}

async function markSuccess(
  supabase: any,
  job: JsonRecord,
  result: JsonRecord | null,
  publishMetadata: JsonRecord,
) {
  const now = new Date().toISOString();
  await supabase.from("meinvoice_jobs").update({
    status: "valid_invoice",
    misa_ref_id: asString(result?.RefID) ?? asString(result?.refid) ??
      String(job.id),
    transaction_id: asString(result?.TransactionID),
    invoice_series: asString(result?.InvSeries),
    invoice_number: asString(result?.InvNo),
    tax_authority_code: asString(result?.InvCode),
    search_code: asString(result?.TransactionID) ?? asString(result?.InvCode),
    dispatch_claim_id: null,
    dispatch_claimed_at: null,
    sent_at: now,
    updated_at: now,
  }).eq("id", job.id);
  await logMeInvoiceEvent(
    supabase,
    String(job.id),
    "dispatch_success",
    "MISA cash-register invoice accepted",
    {
      retryCount: Number(job.dispatch_attempts ?? 1),
      metadata: publishMetadata,
    },
  );
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

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return json({ ok: false, error: "SUPABASE_SERVICE_NOT_CONFIGURED" }, 503);
  }

  const body = await req.json().catch(() => ({})) as JsonRecord;
  const dryRun = body.dry_run === true;
  const explicitLimit = Number(body.limit ?? 0);
  const taxEntityId = asString(body.tax_entity_id);
  const supabase = createClient(supabaseUrl, serviceRoleKey);

  let runtime;
  try {
    runtime = await loadRuntimeConfig(supabase);
  } catch (error) {
    return json({
      ok: false,
      error: "MEINVOICE_RUNTIME_CONFIG_QUERY_FAILED",
      message: String((error as Error).message),
    }, 500);
  }

  if (!dryRun && !runtime.dispatchEnabled) {
    return json({ ok: true, skipped: "meinvoice_dispatch_disabled" });
  }

  const limit = Math.min(
    Math.max(explicitLimit || runtime.batchSize, 1),
    runtime.batchSize,
  );
  let query = supabase.from("meinvoice_jobs")
    .select("*")
    .eq("status", "pending")
    .or(
      `dispatch_claim_id.is.null,dispatch_claimed_at.lt.${
        new Date(Date.now() - DISPATCH_CLAIM_TIMEOUT_MS).toISOString()
      }`,
    )
    .order("created_at", { ascending: true })
    .limit(limit);
  if (taxEntityId) query = query.eq("tax_entity_id", taxEntityId);

  const { data: jobs, error: jobsError } = await query;
  if (jobsError) {
    return json({
      ok: false,
      error: "MEINVOICE_JOB_QUERY_FAILED",
      message: jobsError.message,
    }, 500);
  }

  const dryRunPayloads: JsonRecord[] = [];
  const dispatched: JsonRecord[] = [];
  const failed: JsonRecord[] = [];
  const paused: JsonRecord[] = [];
  const retried: JsonRecord[] = [];

  for (const job of jobs ?? []) {
    let activeJob = job;
    try {
      const claimedJob = dryRun ? job : await claimPendingJob(supabase, job);
      if (!claimedJob) continue;
      activeJob = claimedJob;

      const seller = await loadSellerConfig(supabase, claimedJob.tax_entity_id);
      const payload = validateCashRegisterInvoicePayload(
        buildCashRegisterInvoicePayload(claimedJob, seller),
      );

      if (dryRun) {
        dryRunPayloads.push({
          job_id: claimedJob.id,
          tax_entity_id: claimedJob.tax_entity_id,
          payload,
        });
        continue;
      }

      const token = await getMeInvoiceToken(
        supabase,
        seller,
        runtime.tokenRefreshSkewMinutes,
      );
      const attempt = Number(claimedJob.dispatch_attempts ?? 1);

      const response = await publishCashRegisterInvoice(seller, token, payload);
      const publishMetadata = {
        httpStatus: response.status,
        ...summarizePublishResponse(response.body),
      };
      await logMeInvoiceEvent(
        supabase,
        claimedJob.id,
        "dispatch_attempt",
        `MISA cash-register publish HTTP ${response.status}`,
        {
          retryCount: attempt,
          metadata: publishMetadata,
        },
      );

      const publishResult = parsePublishResult(response.body);
      const errorCode = safeMisaResponseCode(
        publishResult ?? response.body,
        `MISA_PUBLISH_HTTP_${response.status}`,
      );
      const responseSuccess = (response.body as any)?.success ??
        (response.body as any)?.Success;
      const success = response.ok &&
        responseSuccess !== false &&
        !safeMisaResponseCode(publishResult ?? response.body, "");

      if (success) {
        await markSuccess(supabase, claimedJob, publishResult, publishMetadata);
        dispatched.push({ job_id: claimedJob.id, status: response.status });
      } else if (errorCode === "InvoiceNumberNotCotinuous") {
        await markTransient(supabase, claimedJob, errorCode);
        retried.push({ job_id: claimedJob.id, error: errorCode });
      } else if (errorCode === "InvoiceDuplicated") {
        const issued = await reconcileDuplicated(seller, token, claimedJob);
        if (issued) {
          await markSuccess(supabase, claimedJob, issued, publishMetadata);
          dispatched.push({
            job_id: claimedJob.id,
            status: response.status,
            reconciled: true,
          });
        } else {
          const message = "MISA_INVOICE_DUPLICATED_UNRESOLVED";
          await markFailed(supabase, claimedJob, message, publishMetadata);
          failed.push({ job_id: claimedJob.id, error: message });
        }
      } else {
        const message = response.ok
          ? errorCode
          : `MISA_PUBLISH_HTTP_${response.status}`;
        await markFailed(supabase, claimedJob, message, publishMetadata);
        failed.push({ job_id: claimedJob.id, error: message });
      }
    } catch (error) {
      const message = safeMeInvoiceErrorMessage(error);
      if (
        message.startsWith("MEINVOICE_INTEGRATION_NOT_ACTIVE") ||
        message.startsWith("MEINVOICE_CLIENT_ID_NOT_CONFIGURED") ||
        message.startsWith("MEINVOICE_CLIENT_SECRET_NOT_CONFIGURED") ||
        message.startsWith("MEINVOICE_INVOICE_SERIES_NOT_CONFIGURED") ||
        message.startsWith("MEINVOICE_CONFIG_NOT_FOUND") ||
        message.startsWith("MEINVOICE_CREDENTIAL_NOT_CONFIGURED")
      ) {
        if (!dryRun) await markConfigBlocked(supabase, activeJob, message);
        paused.push({ job_id: activeJob.id, error: message });
      } else {
        if (!dryRun) await markFailed(supabase, activeJob, message);
        failed.push({ job_id: activeJob.id, error: message });
      }
    }
  }

  return json({
    ok: failed.length === 0,
    dry_run: dryRun,
    processed_count: (jobs ?? []).length,
    dispatched_count: dispatched.length,
    failed_count: failed.length,
    paused_count: paused.length,
    retried_count: retried.length,
    dry_run_payloads: dryRunPayloads,
    dispatched,
    failed,
    paused,
    retried,
  });
});
