import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  asString,
  buildCashRegisterInvoicePayload,
  getMeInvoiceToken,
  json,
  loadRuntimeConfig,
  parsePublishResult,
  publishCashRegisterInvoice,
  sellerConfigFromRows,
  summarizePublishResponse,
  validateCashRegisterInvoicePayload,
} from "../_shared/meinvoice.ts";

type JsonRecord = Record<string, unknown>;

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
  const url = Deno.env.get("SUPABASE_URL"),
    key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) {
    return json({ ok: false, error: "SUPABASE_SERVICE_NOT_CONFIGURED" }, 503);
  }
  const deadline = Date.now() + 45_000;
  const boundedFetch: typeof fetch = (input, init) =>
    fetch(input, {
      ...init,
      signal: AbortSignal.timeout(
        Math.max(1, Math.min(10_000, deadline - Date.now())),
      ),
    });
  const supabase = createClient(url, key, {
    global: { fetch: boundedFetch },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const body = await req.json().catch(() => ({})) as JsonRecord;
  const dryRun = body.dry_run === true;
  let runtime;
  try {
    runtime = await loadRuntimeConfig(supabase);
  } catch {
    return json(
      { ok: false, error: "MEINVOICE_RUNTIME_CONFIG_QUERY_FAILED" },
      500,
    );
  }
  if (!dryRun && !runtime.dispatchEnabled) {
    return json({ ok: true, skipped: "meinvoice_dispatch_disabled" });
  }
  const requested = Number(body.limit ?? runtime.batchSize);
  const limit = Math.min(
    50,
    runtime.batchSize,
    Math.max(1, Number.isFinite(requested) ? requested : runtime.batchSize),
  );
  const taxEntityId = asString(body.tax_entity_id);
  const claimId = crypto.randomUUID();
  let jobs: JsonRecord[];
  try {
    if (dryRun) {
      let query = supabase.from("meinvoice_jobs").select("*").eq(
        "status",
        "pending",
      ).order("created_at").limit(limit);
      if (taxEntityId) query = query.eq("tax_entity_id", taxEntityId);
      const result = await query;
      if (result.error) throw result.error;
      jobs = result.data ?? [];
    } else {
      const result = await supabase.rpc("claim_meinvoice_jobs", {
        p_claim_id: claimId,
        p_limit: limit,
        p_tax_entity_id: taxEntityId,
      });
      if (result.error) throw result.error;
      jobs = result.data ?? [];
    }
  } catch {
    return json({ ok: false, error: "MEINVOICE_JOB_QUERY_FAILED" }, 500);
  }
  if (jobs.length > 50) {
    return json({ ok: false, error: "MEINVOICE_BATCH_INVALID" }, 500);
  }
  if (jobs.length === 0) {
    return json({
      ok: true,
      dry_run: dryRun,
      processed_count: 0,
      dispatched_count: 0,
      failed_count: 0,
      paused_count: 0,
    });
  }
  const ids = [...new Set(jobs.map((job) => String(job.tax_entity_id)))];
  const [entityResult, configResult, tokenResult] = await Promise.all([
    supabase.from("tax_entity").select("id,tax_code,name").in("id", ids),
    supabase.from("meinvoice_tax_entity_config").select(
      "tax_entity_id,auth_base_url,api_base_url,app_id,invoice_series,integration_status",
    ).in("tax_entity_id", ids),
    supabase.from("meinvoice_token_cache").select(
      "tax_entity_id,current_token,token_expires_at",
    ).in("tax_entity_id", ids),
  ]);
  if (entityResult.error || configResult.error || tokenResult.error) {
    if (!dryRun) {
      await supabase.rpc("complete_meinvoice_batch", {
        p_claim_id: claimId,
        p_results: jobs.map((job) => ({
          id: String(job.id),
          status: "pending",
          event_type: "dispatch_deferred",
          error_message: "MEINVOICE_SELLER_QUERY_FAILED",
        })),
      });
    }
    return json({ ok: false, error: "MEINVOICE_SELLER_QUERY_FAILED" }, 500);
  }
  const entities = new Map(
    (entityResult.data ?? []).map((r) => [String(r.id), r as JsonRecord]),
  );
  const configs = new Map(
    (configResult.data ?? []).map((
      r,
    ) => [String(r.tax_entity_id), r as JsonRecord]),
  );
  const tokens = new Map(
    (tokenResult.data ?? []).map((r) => [String(r.tax_entity_id), r]),
  );
  const tokenLoads = new Map<string, Promise<string>>();
  const completed: JsonRecord[] = [];
  const dispatched: JsonRecord[] = [];
  const failed: JsonRecord[] = [];
  const paused: JsonRecord[] = [];
  const dryRunPayloads: JsonRecord[] = [];
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(2, jobs.length) }, async () => {
      while (next < jobs.length) {
        const job = jobs[next++],
          id = String(job.id),
          entityId = String(job.tax_entity_id);
        if (Date.now() >= deadline - 12_000) {
          completed.push({
            id,
            status: "pending",
            event_type: "dispatch_deferred",
          });
          paused.push({ job_id: id, error: "DISPATCH_TIME_BUDGET" });
          continue;
        }
        let publishStarted = false;
        try {
          const entity = entities.get(entityId), config = configs.get(entityId);
          if (!entity || !config) throw new Error("MEINVOICE_CONFIG_NOT_FOUND");
          const seller = sellerConfigFromRows(entityId, entity, config);
          const payload = validateCashRegisterInvoicePayload(
            buildCashRegisterInvoicePayload(job, seller),
          );
          if (dryRun) {
            dryRunPayloads.push({ job_id: id, payload });
            continue;
          }
          let tokenLoad = tokenLoads.get(entityId);
          if (!tokenLoad) {
            tokenLoad = (async () => {
              const cached = tokens.get(entityId) ?? null;
              const needsRefresh = !cached?.current_token ||
                !Number.isFinite(Date.parse(cached.token_expires_at)) ||
                Date.parse(cached.token_expires_at) <=
                  Date.now() + runtime.tokenRefreshSkewMinutes * 60_000;
              if (!needsRefresh) {
                return getMeInvoiceToken(
                  supabase,
                  seller,
                  runtime.tokenRefreshSkewMinutes,
                  cached,
                  boundedFetch,
                );
              }
              const lock = await supabase.rpc("claim_meinvoice_token_refresh", {
                p_tax_entity_id: entityId,
                p_owner_id: claimId,
              });
              if (lock.error || lock.data !== true) {
                throw new Error("MEINVOICE_TOKEN_REFRESH_BUSY");
              }
              try {
                return await getMeInvoiceToken(
                  supabase,
                  seller,
                  runtime.tokenRefreshSkewMinutes,
                  (await supabase.from("meinvoice_token_cache").select(
                    "current_token,token_expires_at",
                  ).eq("tax_entity_id", entityId).maybeSingle()).data ?? cached,
                  boundedFetch,
                );
              } finally {
                await supabase.from("meinvoice_token_refresh_leases").delete()
                  .eq("tax_entity_id", entityId).eq("owner_id", claimId);
              }
            })();
            tokenLoads.set(entityId, tokenLoad);
          }
          const token = await tokenLoad;
          publishStarted = true;
          const response = await publishCashRegisterInvoice(
            seller,
            token,
            payload,
            boundedFetch,
          );
          const result = parsePublishResult(response.body);
          const metadata = {
            httpStatus: response.status,
            ...summarizePublishResponse(response.body),
          };
          const error = asString(result?.ErrorCode) ??
            asString(result?.errorCode) ?? asString(result?.ErrorMessage) ??
            asString((response.body as JsonRecord)?.ErrorCode) ??
            asString((response.body as JsonRecord)?.errorCode);
          const success = response.ok &&
            (response.body as JsonRecord)?.success !== false &&
            (response.body as JsonRecord)?.Success !== false && !error;
          if (success) {
            completed.push({
              id,
              status: "valid_invoice",
              misa_ref_id: asString(result?.RefID) ?? asString(result?.refid) ??
                id,
              transaction_id: asString(result?.TransactionID),
              invoice_series: asString(result?.InvSeries),
              invoice_number: asString(result?.InvNo),
              tax_authority_code: asString(result?.InvCode),
              search_code: asString(result?.TransactionID) ??
                asString(result?.InvCode),
              event_type: "dispatch_success",
              metadata,
            });
            dispatched.push({ job_id: id, status: response.status });
          } else {
            const message = error ??
              `MISA publish failed HTTP ${response.status}`;
            completed.push({
              id,
              status: "failed",
              error_message: message,
              event_type: "dispatch_failed",
              metadata,
            });
            failed.push({ job_id: id, error: message });
          }
        } catch (error) {
          const message = error instanceof Error
            ? error.message
            : "MEINVOICE_DISPATCH_FAILED";
          const configBlocked =
            /MEINVOICE_(INTEGRATION_NOT_ACTIVE|APP_ID_NOT_CONFIGURED|INVOICE_SERIES_NOT_CONFIGURED|CONFIG_NOT_FOUND)/
              .test(message);
          const status = publishStarted
            ? "manual_action_required"
            : message === "MEINVOICE_TOKEN_REFRESH_BUSY"
            ? "pending"
            : configBlocked
            ? "dispatch_paused"
            : "failed";
          completed.push({
            id,
            status,
            error_message: publishStarted
              ? "DISPATCH_OUTCOME_UNKNOWN"
              : message,
            event_type: publishStarted
              ? "dispatch_outcome_unknown"
              : configBlocked
              ? "dispatch_config_blocked"
              : "dispatch_failed",
          });
          (configBlocked || status === "pending" ? paused : failed).push({
            job_id: id,
            error: message,
          });
        }
      }
    }),
  );
  if (!dryRun) {
    const result = await supabase.rpc("complete_meinvoice_batch", {
      p_claim_id: claimId,
      p_results: completed,
    });
    if (result.error || result.data !== completed.length) {
      return json({ ok: false, error: "MEINVOICE_COMPLETION_FAILED" }, 500);
    }
  }
  return json({
    ok: failed.length === 0,
    dry_run: dryRun,
    processed_count: jobs.length,
    dispatched_count: dispatched.length,
    failed_count: failed.length,
    paused_count: paused.length,
    dry_run_payloads: dryRunPayloads,
    dispatched,
    failed,
    paused,
  });
});
