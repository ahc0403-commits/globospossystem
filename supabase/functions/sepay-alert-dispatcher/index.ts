import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import {
  buildFcmMessage,
  getFirebaseAccessToken,
  mapClaimedDelivery,
  parseFirebaseServiceAccount,
} from "../_shared/sepay_push.ts";

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

  let serviceAccount;
  let accessToken;
  try {
    serviceAccount = parseFirebaseServiceAccount(serviceAccountRaw);
    accessToken = await getFirebaseAccessToken(serviceAccount);
  } catch (error) {
    return json({
      success: false,
      error: error instanceof Error ? error.message : "FIREBASE_AUTH_FAILED",
    }, 503);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  let claimed = 0;
  let accepted = 0;
  let failed = 0;
  for (let batch = 0; batch < 10; batch += 1) {
    const { data, error } = await supabase.rpc(
      "claim_sepay_alert_deliveries",
      { p_limit: 100 },
    );
    if (error) {
      return json({ success: false, error: "SEPAY_ALERT_CLAIM_FAILED" }, 500);
    }
    const rows = data ?? [];
    claimed += rows.length;

    for (const raw of rows) {
      const delivery = mapClaimedDelivery(raw as Record<string, unknown>);
      let providerMessageId: string | null = null;
      let failure: string | null = null;
      try {
        const response = await fetch(
          `https://fcm.googleapis.com/v1/projects/${serviceAccount.projectId}/messages:send`,
          {
            method: "POST",
            headers: {
              authorization: `Bearer ${accessToken}`,
              "content-type": "application/json",
            },
            body: JSON.stringify(buildFcmMessage(delivery)),
          },
        );
        const body = await response.json().catch(() => ({})) as Record<
          string,
          unknown
        >;
        if (!response.ok) {
          throw new Error(`FCM_SEND_FAILED_${response.status}`);
        }
        providerMessageId = String(body.name ?? "") || null;
      } catch (error) {
        failure = error instanceof Error ? error.message : "FCM_SEND_FAILED";
      }

      const retrySeconds = Math.min(
        3600,
        30 * (2 ** Math.max(0, delivery.attemptCount - 1)),
      );
      const { error: completionError } = await supabase.rpc(
        "complete_sepay_alert_delivery",
        {
          p_delivery_id: delivery.deliveryId,
          p_accepted: failure == null,
          p_provider_message_id: providerMessageId,
          p_error: failure,
          p_retry_after_seconds: retrySeconds,
        },
      );
      if (completionError || failure) failed += 1;
      else accepted += 1;
    }
    if (rows.length < 100) break;
  }

  return json({ success: true, claimed, accepted, failed });
});
