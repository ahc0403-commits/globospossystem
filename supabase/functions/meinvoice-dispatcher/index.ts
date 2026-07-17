import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  asString,
  buildCashRegisterInvoicePayload,
  getMeInvoiceToken,
  json,
  loadRuntimeConfig,
  loadSellerConfig,
  logMeInvoiceEvent,
  parsePublishResult,
  publishCashRegisterInvoice,
  summarizePublishResponse,
  validateCashRegisterInvoicePayload,
} from "../_shared/meinvoice.ts";

type JsonRecord = Record<string, unknown>;

async function markConfigBlocked(
  supabase: any,
  job: JsonRecord,
  message: string,
) {
  await supabase.from("meinvoice_jobs").update({
    status: "dispatch_paused",
    error_message: message.slice(0, 1000),
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
    sent_at: now,
    updated_at: now,
  }).eq("id", job.id);
  await logMeInvoiceEvent(
    supabase,
    String(job.id),
    "dispatch_success",
    "MISA cash-register invoice accepted",
    {
      retryCount: Number(job.dispatch_attempts ?? 0) + 1,
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

  for (const job of jobs ?? []) {
    try {
      const seller = await loadSellerConfig(supabase, job.tax_entity_id);
      const payload = validateCashRegisterInvoicePayload(
        buildCashRegisterInvoicePayload(job, seller),
      );

      if (dryRun) {
        dryRunPayloads.push({
          job_id: job.id,
          tax_entity_id: job.tax_entity_id,
          payload,
        });
        continue;
      }

      const token = await getMeInvoiceToken(
        supabase,
        seller,
        runtime.tokenRefreshSkewMinutes,
      );
      const attempt = Number(job.dispatch_attempts ?? 0) + 1;
      await supabase.from("meinvoice_jobs").update({
        dispatch_attempts: attempt,
        last_dispatch_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      }).eq("id", job.id);

      const response = await publishCashRegisterInvoice(seller, token, payload);
      const publishMetadata = {
        httpStatus: response.status,
        ...summarizePublishResponse(response.body),
      };
      await logMeInvoiceEvent(
        supabase,
        job.id,
        "dispatch_attempt",
        `MISA cash-register publish HTTP ${response.status}`,
        {
          retryCount: attempt,
          metadata: publishMetadata,
        },
      );

      const publishResult = parsePublishResult(response.body);
      const errorCode = asString(publishResult?.ErrorCode) ??
        asString(publishResult?.errorCode) ??
        asString(publishResult?.ErrorMessage) ??
        asString((response.body as any)?.ErrorCode) ??
        asString((response.body as any)?.errorCode);
      const responseSuccess = (response.body as any)?.success ??
        (response.body as any)?.Success;
      const success = response.ok &&
        responseSuccess !== false &&
        !errorCode;

      if (success) {
        await markSuccess(supabase, job, publishResult, publishMetadata);
        dispatched.push({ job_id: job.id, status: response.status });
      } else {
        const message = errorCode ??
          `MISA publish failed HTTP ${response.status}`;
        await markFailed(supabase, job, message, publishMetadata);
        failed.push({ job_id: job.id, error: message });
      }
    } catch (error) {
      const message = String((error as Error).message);
      if (
        message.startsWith("MEINVOICE_INTEGRATION_NOT_ACTIVE") ||
        message.startsWith("MEINVOICE_APP_ID_NOT_CONFIGURED") ||
        message.startsWith("MEINVOICE_INVOICE_SERIES_NOT_CONFIGURED") ||
        message.startsWith("MEINVOICE_CONFIG_NOT_FOUND")
      ) {
        if (!dryRun) await markConfigBlocked(supabase, job, message);
        paused.push({ job_id: job.id, error: message });
      } else {
        if (!dryRun) await markFailed(supabase, job, message);
        failed.push({ job_id: job.id, error: message });
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
    dry_run_payloads: dryRunPayloads,
    dispatched,
    failed,
    paused,
  });
});
