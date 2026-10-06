import { serve } from "@std/http/server";
import { createClient } from "@supabase/supabase-js";
import {
  getFirebaseAccessToken,
  parseFirebaseServiceAccount,
} from "../_shared/sepay_push.ts";
import {
  buildDirectOrderFcmMessage,
  directOrderPushOutcome,
  mapDirectOrderPush,
} from "../_shared/direct_order_push.ts";
import type {
  DirectOrderPushDelivery,
  DirectOrderPushOutcome,
} from "../_shared/direct_order_push.ts";

export interface DirectOrderPushDependencies {
  authorized: (req: Request) => boolean;
  claim: () => Promise<Record<string, unknown>[]>;
  send: (delivery: DirectOrderPushDelivery) => Promise<DirectOrderPushOutcome>;
  complete: (
    delivery: DirectOrderPushDelivery,
    outcome: DirectOrderPushOutcome,
  ) => Promise<boolean>;
}

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export function createDirectOrderPushHandler(
  deps: DirectOrderPushDependencies,
) {
  return async (req: Request): Promise<Response> => {
    if (!deps.authorized(req)) return json({ error: "AUTH_REQUIRED" }, 401);
    if (req.method !== "POST") {
      return json({ error: "METHOD_NOT_ALLOWED" }, 405);
    }
    let accepted = 0;
    let failed = 0;
    let rows: Record<string, unknown>[];
    try {
      rows = await deps.claim();
    } catch (_) {
      return json({ error: "DIRECT_ORDER_PUSH_CLAIM_FAILED" }, 503);
    }
    // Eight workers bound request fanout; a batch fits within the database lease.
    let next = 0;
    await Promise.all(
      Array.from({ length: Math.min(8, rows.length) }, async () => {
        while (next < rows.length) {
          const row = rows[next++];
          try {
            const delivery = mapDirectOrderPush(row);
            let outcome: DirectOrderPushOutcome;
            try {
              outcome = await deps.send(delivery);
            } catch (_) {
              outcome = "retry";
            }
            const completed = await deps.complete(delivery, outcome);
            if (completed && outcome === "sent") accepted++;
            else failed++;
          } catch (_) {
            failed++;
          } // lease expiry recovers unacknowledged rows
        }
      }),
    );
    return json({ claimed: rows.length, accepted, failed });
  };
}

function productionDependencies(): DirectOrderPushDependencies {
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const cronSecret = Deno.env.get("CRON_SECRET") ?? "";
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const origin = Deno.env.get("DIRECT_ORDER_PUBLIC_ORIGIN") ??
    "https://globospossystem.vercel.app";
  const accountRaw = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON") ?? "";
  const client = url && serviceKey
    ? createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    })
    : null;
  let accessToken: string | null = null;
  let projectId: string | null = null;
  return {
    authorized: (req) => {
      const bearer = req.headers.get("authorization");
      return Boolean(
        serviceKey && bearer === `Bearer ${serviceKey}` ||
          cronSecret && bearer === `Bearer ${cronSecret}`,
      );
    },
    claim: async () => {
      if (!client || !accountRaw) throw new Error("PUSH_NOT_CONFIGURED");
      // Authenticate before claiming so configuration errors do not use retries.
      const account = parseFirebaseServiceAccount(accountRaw);
      accessToken = await getFirebaseAccessToken(account);
      projectId = account.projectId;
      const { data, error } = await client.rpc(
        "claim_direct_order_push_deliveries",
        { p_limit: 50 },
      );
      if (error || !Array.isArray(data)) throw new Error("PUSH_CLAIM_FAILED");
      return data;
    },
    send: async (delivery) => {
      const response = await fetch(
        `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
        {
          method: "POST",
          signal: AbortSignal.timeout(10000),
          headers: {
            authorization: `Bearer ${accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify(buildDirectOrderFcmMessage(delivery, origin)),
        },
      );
      const body = await response.json().catch(() => ({})) as Record<
        string,
        unknown
      >;
      return directOrderPushOutcome(response.status, body);
    },
    complete: async (delivery, outcome) => {
      if (!client) return false;
      const { data, error } = await client.rpc(
        "complete_direct_order_push_delivery",
        {
          p_delivery_id: delivery.id,
          p_lease_id: delivery.leaseId,
          p_outcome: outcome,
          p_token_hash: delivery.tokenHash,
        },
      );
      return !error && data === true;
    },
  };
}

if (import.meta.main) {
  serve(createDirectOrderPushHandler(productionDependencies()));
}
