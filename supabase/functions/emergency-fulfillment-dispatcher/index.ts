import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import {
  getFirebaseAccessToken,
  parseFirebaseServiceAccount,
} from "../_shared/sepay_push.ts";
import {
  buildEmergencyFcmMessage,
  mapEmergencyPushDelivery,
} from "../_shared/emergency_push.ts";

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

serve(async (req) => {
  if (req.method !== "POST") {
    return json({ success: false, error: "METHOD_NOT_ALLOWED" }, 405);
  }
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const cronSecret = Deno.env.get("CRON_SECRET");
  const serviceAccountRaw = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON");
  if (!supabaseUrl || !serviceRoleKey || !serviceAccountRaw) {
    return json({ success: false, error: "PUSH_SERVICE_NOT_CONFIGURED" }, 503);
  }
  const authorization = req.headers.get("authorization");
  if (
    authorization !== `Bearer ${serviceRoleKey}` &&
    (!cronSecret || authorization !== `Bearer ${cronSecret}`)
  ) {
    return json({ success: false, error: "AUTH_REQUIRED" }, 401);
  }

  const deadline = Date.now() + 45_000;
  const boundedFetch: typeof fetch = (input, init) =>
    fetch(input, {
      ...init,
      signal: AbortSignal.timeout(
        Math.max(1, Math.min(10_000, deadline - Date.now())),
      ),
    });
  const client = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { fetch: boundedFetch },
  });
  let serviceAccount:
    | ReturnType<typeof parseFirebaseServiceAccount>
    | undefined;
  let accessToken: string | undefined;
  let claimed = 0, accepted = 0, failed = 0;
  for (let batch = 0; batch < 20 && Date.now() < deadline - 12_000; batch++) {
    const claimId = crypto.randomUUID();
    const { data, error } = await client.rpc("claim_emergency_push_batch", {
      p_claim_id: claimId,
      p_limit: 50,
    });
    if (error) {
      return json(
        { success: false, error: "EMERGENCY_PUSH_CLAIM_FAILED" },
        500,
      );
    }
    if (
      !data || !Array.isArray(data.rows) || typeof data.has_more !== "boolean"
    ) {
      return json(
        { success: false, error: "EMERGENCY_PUSH_BATCH_INVALID" },
        500,
      );
    }
    const rows = data.rows;
    if (rows.length === 0) break;
    if (rows.length > 50) {
      return json(
        { success: false, error: "EMERGENCY_PUSH_BATCH_INVALID" },
        500,
      );
    }
    claimed += rows.length;
    if (!serviceAccount) {
      try {
        serviceAccount = parseFirebaseServiceAccount(serviceAccountRaw);
        accessToken = await getFirebaseAccessToken(
          serviceAccount,
          boundedFetch,
        );
      } catch {
        // Owned leases expire; no permanent failure is inferred from OAuth.
        return json({ success: false, error: "FIREBASE_AUTH_FAILED" }, 503);
      }
    }
    const results: Record<string, unknown>[] = [];
    let next = 0;
    await Promise.all(
      Array.from({ length: Math.min(4, rows.length) }, async () => {
        while (next < rows.length) {
          const raw = rows[next++];
          if (Date.now() >= deadline - 12_000) {
            results.push({ id: raw.id, deferred: true, retry_seconds: 30 });
            continue;
          }
          let providerMessageId: string | null = null;
          let failure: string | null = null;
          let permanent = false;
          let retryAfter = 0;
          try {
            const delivery = mapEmergencyPushDelivery(
              raw as Record<string, unknown>,
            );
            const response = await fetch(
              `https://fcm.googleapis.com/v1/projects/${
                serviceAccount!.projectId
              }/messages:send`,
              {
                method: "POST",
                headers: {
                  authorization: `Bearer ${accessToken}`,
                  "content-type": "application/json",
                },
                body: JSON.stringify(buildEmergencyFcmMessage(delivery)),
                signal: AbortSignal.timeout(
                  Math.min(10_000, deadline - Date.now() - 1_000),
                ),
              },
            );
            const body = await response.json().catch(() => ({})) as Record<
              string,
              unknown
            >;
            if (!response.ok) {
              const error = body.error as {
                status?: string;
                details?: { errorCode?: string }[];
              } | undefined;
              const code = error?.details?.find((detail) =>
                detail.errorCode
              )?.errorCode ?? error?.status;
              permanent = code === "UNREGISTERED" ||
                (response.status >= 400 && response.status < 500 &&
                  response.status !== 429);
              failure = code === "UNREGISTERED"
                ? "FCM_UNREGISTERED"
                : `FCM_SEND_FAILED_${response.status}`;
              const retry = response.headers.get("retry-after");
              retryAfter = retry
                ? Number(retry) ||
                  Math.max(0, (Date.parse(retry) - Date.now()) / 1000)
                : 0;
            } else providerMessageId = String(body.name ?? "") || null;
          } catch (error) {
            failure = error instanceof Error
              ? error.message
              : "FCM_SEND_FAILED";
            permanent = failure === "EMERGENCY_PUSH_STATION_INVALID" ||
              failure === "EMERGENCY_PUSH_TOKEN_INVALID";
          }
          const retrySeconds = Math.min(
            3600,
            Math.max(
              retryAfter,
              30 * 2 ** Math.max(0, Number(raw.attempt_count ?? 1) - 1) +
                Math.floor(Math.random() * 15),
            ),
          );
          results.push({
            id: raw.id,
            accepted: failure == null,
            permanent,
            provider_message_id: providerMessageId,
            error: failure,
            retry_seconds: Math.ceil(retrySeconds),
          });
        }
      }),
    );
    const { data: completed, error: completionError } = await client.rpc(
      "complete_emergency_push_batch",
      { p_claim_id: claimId, p_results: results },
    );
    if (completionError || completed !== results.length) {
      return json({
        success: false,
        error: "EMERGENCY_PUSH_COMPLETION_FAILED",
        claimed,
        accepted,
        failed,
      }, 500);
    }
    accepted += results.filter((r) => r.accepted).length;
    failed += results.filter((r) => !r.accepted && !r.deferred).length;
    if (!data.has_more || results.some((r) => r.deferred)) break;
  }
  return json({ success: true, claimed, accepted, failed });
});
