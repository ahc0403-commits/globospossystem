/**
 * wetax-onboarding — Phase 2 Step 7
 * Handles WeTax seller/shop onboarding API calls.
 * Called on demand by admin UI (not by cron).
 *
 * Operations (POST body: { "operation": "...", ...params }):
 *   company_lookup    — WT09: get company info by tax code
 *   seller_register   — agency/sellers: register new external seller
 *   shops_register    — agency/seller-shops: bulk register shops
 *   seller_info       — WT01: fetch seller info + templates
 *   commons_refresh   — fetch payment-methods/tax-rates/currency, cache in DB
 *
 * Scope: stage1_scope_v1.3.md Section 7
 */

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getToken, WETAX_BASE_URL } from "../_shared/wetax.ts";

const TOKEN_OPTIONS = {
  functionName: "wetax-onboarding",
  accessReason: "onboarding_token_refresh",
  formatLoginError: (status: number, body: unknown) =>
    `WT00 failed: ${status} ${JSON.stringify(body)}`,
};

const USER_ALLOWED_OPERATIONS = new Set(["company_lookup"]);
const ADMIN_ALLOWED_OPERATIONS = new Set([
  "seller_register",
  "shops_register",
  "seller_info",
]);
const INTERNAL_ALLOWED_OPERATIONS = new Set([
  "company_lookup",
  "seller_register",
  "shops_register",
  "seller_info",
  "commons_refresh",
]);

type Actor = {
  auth_id: string;
  role: string;
  is_active: boolean;
};

function authHeaders(token: string) {
  return {
    "Content-Type": "application/json",
    "Authorization": `Bearer ${token}`,
  };
}

function isUserAllowedOperation(operation: string, role: string) {
  return USER_ALLOWED_OPERATIONS.has(operation) &&
    ["cashier", "admin", "store_admin", "brand_admin", "super_admin"].includes(
      role,
    );
}

function isAdminAllowedOperation(operation: string, role: string) {
  return ADMIN_ALLOWED_OPERATIONS.has(operation) &&
    ["admin", "store_admin", "brand_admin", "super_admin"].includes(role);
}

async function actorCanAccessTaxEntity(
  supabase: any,
  actor: Actor,
  taxEntityId: string | undefined,
) {
  if (!taxEntityId || actor.role === "super_admin") return true;

  const { data, error } = await supabase.rpc("user_accessible_tax_entities", {
    uid: actor.auth_id,
  });
  if (error) throw error;

  return Array.isArray(data) &&
    data.some((id) => String(id) === String(taxEntityId));
}

// WT09: company lookup by tax code
async function companyLookup(supabase: any, params: any) {
  const { tax_code } = params;
  if (!tax_code) throw new Error("tax_code required");

  const token = await getToken(supabase, TOKEN_OPTIONS);
  const res = await fetch(
    `${WETAX_BASE_URL}/api/wtx/pa/v1/pos/company/${
      encodeURIComponent(tax_code)
    }`,
    { method: "GET", headers: authHeaders(token) },
  );
  const body = await res.json().catch(() => null);
  return { http_status: res.status, body };
}

// agency/sellers: register new seller
async function sellerRegister(supabase: any, params: any) {
  const { tax_code, company_name, address, phone, email, owner_type } = params;
  if (!tax_code || !company_name) {
    throw new Error("tax_code and company_name required");
  }

  const token = await getToken(supabase, TOKEN_OPTIONS);
  const res = await fetch(`${WETAX_BASE_URL}/api/wtx/pa/v1/agency/sellers`, {
    method: "POST",
    headers: authHeaders(token),
    body: JSON.stringify({ tax_code, company_name, address, phone, email }),
  });
  const body = await res.json().catch(() => null);

  if (res.ok && body?.data?.res_key) {
    // Insert or update tax_entity
    await supabase.from("tax_entity").upsert({
      tax_code,
      name: company_name,
      owner_type: owner_type ?? "external",
      res_key: body.data.res_key,
      data_source: "VNPT_EPAY",
      updated_at: new Date().toISOString(),
    }, { onConflict: "tax_code" });
  }
  return { http_status: res.status, body };
}

// agency/seller-shops: bulk register shops
async function shopsRegister(supabase: any, params: any) {
  const { tax_entity_id, shops } = params;
  if (!tax_entity_id || !shops?.length) {
    throw new Error("tax_entity_id and shops[] required");
  }

  const { data: te } = await supabase
    .from("tax_entity")
    .select("tax_code,res_key")
    .eq("id", tax_entity_id)
    .single();
  if (!te) throw new Error("tax_entity not found");

  const token = await getToken(supabase, TOKEN_OPTIONS);
  const res = await fetch(
    `${WETAX_BASE_URL}/api/wtx/pa/v1/agency/seller-shops`,
    {
      method: "POST",
      headers: authHeaders(token),
      body: JSON.stringify({ res_key: te.res_key, shops }),
    },
  );
  const body = await res.json().catch(() => null);
  return { http_status: res.status, body };
}

// WT01: fetch seller info + templates, store in einvoice_shop
async function sellerInfo(supabase: any, params: any) {
  const { tax_entity_id } = params;

  const token = await getToken(supabase, TOKEN_OPTIONS);
  const res = await fetch(`${WETAX_BASE_URL}/api/wtx/pa/v1/seller-info`, {
    method: "GET",
    headers: authHeaders(token),
  });
  const body = await res.json().catch(() => null);

  if (!res.ok || !body?.data) return { http_status: res.status, body };

  // Parse and upsert einvoice_shop rows
  const shops: any[] = body.data.shops ?? body.data.seller_shops ?? [];
  const declaration = body.data.declaration ?? {};
  const posKey = body.data.pos_key ?? body.data.posKey ?? null;

  if (tax_entity_id) {
    await supabase.from("tax_entity").update({
      pos_key: posKey,
      declaration_status: declaration.status_code ?? null,
      updated_at: new Date().toISOString(),
    }).eq("id", tax_entity_id);

    for (const shop of shops) {
      await supabase.from("einvoice_shop").upsert({
        tax_entity_id,
        provider_shop_code: shop.store_code ?? shop.shop_code ?? shop.code,
        shop_name: shop.store_name ?? shop.shop_name ?? shop.name ?? "",
        templates: shop.templates ?? shop.invoice_templates ?? [],
        updated_at: new Date().toISOString(),
      }, { onConflict: "tax_entity_id,provider_shop_code" });
    }
  }

  return { http_status: res.status, body, shops_saved: shops.length };
}

// Refresh commons cache (payment-methods, tax-rates, currency)
async function commonsRefresh(supabase: any) {
  const token = await getToken(supabase, TOKEN_OPTIONS);
  const categories = ["payment-methods", "tax-rates", "currency"];
  const results: any = {};

  for (const cat of categories) {
    const res = await fetch(
      `${WETAX_BASE_URL}/api/wtx/pa/v1/commons/${cat}`,
      { method: "GET", headers: authHeaders(token) },
    );
    const body = await res.json().catch(() => null);
    results[cat] = { http_status: res.status };

    if (res.ok) {
      const items: any[] = body?.data ?? [];
      for (const item of items) {
        await supabase.from("wetax_reference_values").upsert({
          category: cat,
          code: item.code ?? item.method_code ?? item.currency_code ??
            item.value,
          label: item.label ?? item.name ?? item.method_name ??
            item.description ?? "",
          extra_data: item,
          fetched_at: new Date().toISOString(),
        }, { onConflict: "category,code" });
      }
      results[cat].items_saved = items.length;
    }
  }
  return results;
}

serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const { operation, ...params } = body;
  const authHeader = req.headers.get("Authorization");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  // Allow service_role key OR internal caller header
  const internalSecret = Deno.env.get("INTERNAL_SECRET");
  const cronSecret = Deno.env.get("CRON_SECRET");
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const internalAuthorized = INTERNAL_ALLOWED_OPERATIONS.has(operation) &&
    (authHeader === `Bearer ${serviceKey}` ||
      (internalSecret && authHeader === `Bearer ${internalSecret}`) ||
      (operation === "commons_refresh" && cronSecret &&
        authHeader === `Bearer ${cronSecret}`));

  let actor: Actor | null = null;

  if (!internalAuthorized && authHeader?.startsWith("Bearer ")) {
    const jwt = authHeader.replace("Bearer ", "").trim();
    const { data: authData } = await supabase.auth.getUser(jwt);
    const user = authData.user;

    if (user) {
      const { data: actorRow } = await supabase
        .from("users")
        .select("auth_id,role,is_active")
        .eq("auth_id", user.id)
        .maybeSingle();

      if (actorRow?.is_active === true) {
        actor = actorRow as Actor;
      }
    }
  }

  const userAuthorized = actor !== null &&
    (isUserAllowedOperation(operation, actor.role) ||
      isAdminAllowedOperation(operation, actor.role)) &&
    await actorCanAccessTaxEntity(supabase, actor, params.tax_entity_id);

  if (!internalAuthorized && !userAuthorized) {
    return new Response("Unauthorized", { status: 401 });
  }

  try {
    let result: any;
    switch (operation) {
      case "company_lookup":
        result = await companyLookup(supabase, params);
        break;
      case "seller_register":
        result = await sellerRegister(supabase, params);
        break;
      case "shops_register":
        result = await shopsRegister(supabase, params);
        break;
      case "seller_info":
        result = await sellerInfo(supabase, params);
        break;
      case "commons_refresh":
        result = await commonsRefresh(supabase);
        break;
      default:
        return new Response(
          JSON.stringify({
            error: "Unknown operation",
            valid_operations: [
              "company_lookup",
              "seller_register",
              "shops_register",
              "seller_info",
              "commons_refresh",
            ],
          }),
          { status: 400, headers: { "Content-Type": "application/json" } },
        );
    }

    return new Response(JSON.stringify({ ok: true, result }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("Onboarding error:", err);
    return new Response(JSON.stringify({ error: (err as Error).message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
