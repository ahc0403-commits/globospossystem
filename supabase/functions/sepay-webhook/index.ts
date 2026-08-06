import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import {
  parseSePayTransaction,
  verifySePaySignature,
} from "../_shared/sepay_webhook.ts";

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

  const secret = Deno.env.get("SEPAY_WEBHOOK_SECRET");
  if (!secret) {
    return json({ success: false, error: "SEPAY_SECRET_NOT_CONFIGURED" }, 503);
  }

  const rawBody = await req.text();
  if (rawBody.length > 131072) {
    return json({ success: false, error: "PAYLOAD_TOO_LARGE" }, 413);
  }
  const signatureValid = await verifySePaySignature({
    secret,
    rawBody,
    signature: req.headers.get("x-sepay-signature"),
    timestamp: req.headers.get("x-sepay-timestamp"),
    replayWindowSeconds: Number(
      Deno.env.get("SEPAY_WEBHOOK_REPLAY_WINDOW_SECONDS") ?? "300",
    ),
  });
  if (!signatureValid) {
    return json({ success: false, error: "SEPAY_SIGNATURE_INVALID" }, 401);
  }

  let transaction;
  try {
    transaction = parseSePayTransaction(JSON.parse(rawBody));
  } catch (error) {
    return json({
      success: false,
      error: error instanceof Error ? error.message : "SEPAY_PAYLOAD_INVALID",
    }, 422);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return json(
      { success: false, error: "SUPABASE_SERVICE_NOT_CONFIGURED" },
      503,
    );
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);
  const { data, error } = await supabase.rpc("ingest_sepay_transaction", {
    p_sepay_transaction_id: transaction.id,
    p_gateway: transaction.gateway,
    p_account_number: transaction.accountNumber,
    p_sub_account: transaction.subAccount,
    p_transfer_type: transaction.transferType,
    p_transfer_amount: transaction.transferAmount,
    p_payment_code: transaction.paymentCode,
    p_reference_code: transaction.referenceCode,
    p_transaction_at: transaction.transactionAt,
    p_raw_payload: transaction.rawPayload,
  });

  if (error) {
    return json({
      success: false,
      error: "SEPAY_INGEST_FAILED",
      code: error.code,
    }, 500);
  }

  const ingest = data as Record<string, unknown> | null;
  if (ingest?.status === "accepted" && ingest.resolution_status === "matched") {
    const dispatch = fetch(
      `${supabaseUrl}/functions/v1/sepay-alert-dispatcher`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${serviceRoleKey}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({ source: "sepay-webhook" }),
      },
    ).catch(() => null);
    const runtime = (globalThis as unknown as {
      EdgeRuntime?: { waitUntil(promise: Promise<unknown>): void };
    }).EdgeRuntime;
    if (runtime) runtime.waitUntil(dispatch);
    else await dispatch;
  }

  // SePay requires this exact success contract for delivery acknowledgement.
  return json({ success: true });
});
