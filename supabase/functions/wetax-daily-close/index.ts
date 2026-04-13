/**
 * wetax-daily-close — Phase 2 Step 7
 * Calls WT08 inform-closing-store for all active stores.
 * Triggered by pg_cron at 00:00 Asia/Ho_Chi_Minh daily (Step 9).
 *
 * Scope: stage1_scope_v1.3.md Section 6.7
 * Fixed 00:00 HCMC close time — not per-store (Vietnamese calendar date standard).
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
    credential_id: cred.id, access_reason: "daily_close_token_refresh",
    accessed_by_function: "wetax-daily-close", success: true,
  });
  return token;
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
    // Previous calendar day in HCMC timezone (UTC+7)
    const nowUTC = new Date();
    const hcmcOffset = 7 * 60 * 60 * 1000;
    const hcmcNow = new Date(nowUTC.getTime() + hcmcOffset);
    const hcmcYesterday = new Date(hcmcNow);
    hcmcYesterday.setDate(hcmcYesterday.getDate() - 1);

    const closingDate = hcmcYesterday.toISOString().slice(0, 10).replace(/-/g, ""); // yyyymmdd
    const closingTime = `${closingDate}235959`; // 14-char format

    // Date range for counting orders (previous day in HCMC)
    const dayStartUTC = new Date(Date.UTC(
      hcmcYesterday.getUTCFullYear(), hcmcYesterday.getUTCMonth(), hcmcYesterday.getUTCDate(),
      0 - 7, 0, 0, 0, // midnight HCMC = 17:00 UTC previous day
    ));
    const dayEndUTC = new Date(dayStartUTC.getTime() + 24 * 60 * 60 * 1000 - 1);

    // Get all active stores with their WeTax shop info
    const { data: stores } = await supabase
      .from("restaurants")
      .select(`
        id, name,
        tax_entity_id,
        tax_entity:tax_entity_id (
          tax_code, declaration_status
        )
      `)
      .eq("is_active", true);

    if (!stores?.length) {
      return new Response(JSON.stringify({ closed: 0, message: "no active stores" }), {
        status: 200, headers: { "Content-Type": "application/json" },
      });
    }

    const token = await getToken(supabase);
    const results = [];

    for (const store of stores) {
      // Skip stores with placeholder or no tax entity (not onboarded yet)
      const te = store.tax_entity;
      if (!te || te.tax_code === "PLACEHOLDER_DEV_000") {
        results.push({ store_id: store.id, skipped: "not_onboarded" });
        continue;
      }

      // Count completed orders for the previous calendar day
      const { count } = await supabase
        .from("orders")
        .select("id", { count: "exact", head: true })
        .eq("restaurant_id", store.id)
        .eq("status", "completed")
        .gte("created_at", dayStartUTC.toISOString())
        .lte("created_at", dayEndUTC.toISOString());

      const totalOrderCount = String(count ?? 0);

      // Get einvoice_shop for this store's tax_entity
      const { data: shop } = await supabase
        .from("einvoice_shop")
        .select("provider_shop_code, shop_name")
        .eq("tax_entity_id", store.tax_entity_id)
        .limit(1)
        .single();

      const storeCode = shop?.provider_shop_code ?? te.tax_code;
      const storeName = shop?.shop_name ?? store.name;

      // Call WT08
      const wt08Res = await fetch(
        `${WETAX_BASE_URL}/api/wtx/pa/v1/pos/shops/inform-closing-store`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Authorization": `Bearer ${token}`,
          },
          body: JSON.stringify({
            closing_date: closingDate,
            closing_time: closingTime,
            store_code: storeCode,
            store_name: storeName,
            total_order_count: totalOrderCount,
          }),
        },
      );

      const wt08Body = await wt08Res.json().catch(() => null);
      const success = wt08Res.ok && wt08Body?.status?.success !== false;

      console.log(`Daily close [${store.name}]: HTTP ${wt08Res.status}, orders=${totalOrderCount}, ok=${success}`);

      results.push({
        store_id: store.id,
        store_name: store.name,
        store_code: storeCode,
        closing_date: closingDate,
        total_order_count: Number(totalOrderCount),
        http_status: wt08Res.status,
        success,
        message: wt08Body?.status?.message ?? null,
      });
    }

    const succeeded = results.filter((r: any) => r.success).length;
    const failed = results.filter((r: any) => !r.success && !r.skipped).length;

    return new Response(JSON.stringify({
      closing_date: closingDate,
      total_stores: stores.length,
      succeeded, failed,
      results,
    }), { status: 200, headers: { "Content-Type": "application/json" } });
  } catch (err) {
    console.error("Daily close error:", err);
    return new Response(JSON.stringify({ error: (err as Error).message }), {
      status: 500, headers: { "Content-Type": "application/json" },
    });
  }
});
