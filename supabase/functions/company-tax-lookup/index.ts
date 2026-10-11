import { createClient } from "@supabase/supabase-js";
import { createLookupHandler, type LookupClaim } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL") ?? "";
const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
// Database/Auth transports are bounded too; no automatic retries.
const client = createClient(url, key, {
  auth: { persistSession: false, autoRefreshToken: false },
  global: {
    fetch: (input, init) =>
      fetch(input, { ...init, signal: AbortSignal.timeout(2000) }),
  },
});
Deno.serve(createLookupHandler({
  origins: (Deno.env.get("ALLOWED_ORIGINS") ?? "").split(",").map((s) =>
    s.trim()
  ).filter(Boolean),
  authenticate: async (authorization) => {
    const { data, error } = await client.auth.getUser(
      authorization.replace(/^Bearer\s+/i, ""),
    );
    return error ? null : data.user?.id ?? null;
  },
  claim: async (userId, storeId, leaseId) => {
    const { data, error } = await client.rpc("pos_claim_company_tax_lookup", {
      p_auth_user_id: userId,
      p_store_id: storeId,
      p_lease_id: leaseId,
    });
    if (
      error ||
      !["claimed", "disabled", "forbidden", "rate_limited"].includes(
        data?.outcome,
      )
    ) {
      throw new Error("LOOKUP_CLAIM_UNAVAILABLE");
    }
    return data as LookupClaim;
  },
  release: async (userId, leaseId) => {
    const { error } = await client.rpc("pos_release_company_tax_lookup", {
      p_auth_user_id: userId,
      p_lease_id: leaseId,
    });
    if (error) throw new Error("LOOKUP_RELEASE_UNAVAILABLE");
  },
  fetch,
}));
