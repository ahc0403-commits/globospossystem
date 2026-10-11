export type LookupClaim = {
  outcome: "claimed" | "disabled" | "forbidden" | "rate_limited";
};
export type ProviderFetch = (
  input: string,
  init: { signal: AbortSignal; redirect: "error"; headers: { Accept: string } },
) => Promise<Response>;
export type LookupDependencies = {
  authenticate: (authorization: string) => Promise<string | null>;
  claim: (
    userId: string,
    storeId: string,
    leaseId: string,
  ) => Promise<LookupClaim>;
  release: (userId: string, leaseId: string) => Promise<void>;
  fetch: ProviderFetch;
  origins: string[];
  now?: () => Date;
};
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function validTaxCode(value: string): boolean {
  return /^[0-9]{10}(?:-[0-9]{3})?$/.test(value) && !value.endsWith("-000");
}

/** Bound streamed bodies as well as advertised sizes, including chunked JSON. */
async function readBounded(
  body: Response | Request,
  limit: number,
): Promise<string> {
  const length = body.headers.get("content-length");
  if (length !== null && Number(length) > limit) throw new Error("BODY_LIMIT");
  if (!body.body) throw new Error("BODY_MISSING");
  const reader = body.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > limit) throw new Error("BODY_LIMIT");
      chunks.push(value);
    }
  } catch (failure) {
    await reader.cancel().catch(() => {});
    throw failure;
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}

export type CompanyMatch = { name: string; source: "esgoo" | "vietqr" };

async function fetchProvider(
  taxCode: string,
  source: CompanyMatch["source"],
  fetcher: ProviderFetch,
  timeoutMs: number,
): Promise<CompanyMatch | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const url = source === "esgoo"
    ? `https://esgoo.net/api-mst/${taxCode}.htm`
    : `https://api.vietqr.io/v2/business/${taxCode}`;
  try {
    const result = await fetcher(url, {
      signal: controller.signal,
      redirect: "error",
      headers: { Accept: "application/json" },
    });
    if (!result.ok) {
      await result.body?.cancel();
      return null;
    }
    const value = JSON.parse(await readBounded(result, 64 * 1024));
    if (controller.signal.aborted) return null;
    const valid = source === "esgoo"
      ? value?.error === 0 && value.data?.mst === taxCode
      : value?.code === "00" && value.data?.id === taxCode;
    const rawName = source === "esgoo" ? value?.data?.ten : value?.data?.name;
    if (!valid || typeof rawName !== "string") return null;
    const name = rawName.trim();
    return name.length > 0 && Array.from(name).length <= 300 &&
        Array.from(name).every((ch) =>
          ch.codePointAt(0)! >= 32 && ch.codePointAt(0)! !== 127
        )
      ? { name, source }
      : null;
  } catch (_) {
    // Provider failures do not prove that a company/tax code is unregistered.
    return null;
  } finally {
    clearTimeout(timer);
    controller.abort();
  }
}

/** At most two sequential providers, sharing one five-second deadline. No retries. */
export async function fetchCompany(
  taxCode: string,
  fetcher: ProviderFetch,
  timeoutMs = 5000,
): Promise<CompanyMatch | null> {
  if (!validTaxCode(taxCode) || timeoutMs <= 0) return null;
  const deadline = performance.now() + timeoutMs;
  // Reserve half the budget so an unresponsive primary cannot starve fallback.
  const primary = await fetchProvider(taxCode, "esgoo", fetcher, timeoutMs / 2);
  if (primary) return primary;
  const remaining = deadline - performance.now();
  return remaining > 0
    ? await fetchProvider(taxCode, "vietqr", fetcher, remaining)
    : null;
}

export function createLookupHandler(deps: LookupDependencies) {
  return async (req: Request): Promise<Response> => {
    const origin = req.headers.get("origin");
    const headers = {
      "Access-Control-Allow-Origin": origin && deps.origins.includes(origin)
        ? origin
        : deps.origins[0] ?? "",
      "Access-Control-Allow-Headers":
        "authorization, x-client-info, apikey, content-type",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "Vary": "Origin",
    };
    const reply = (status: number, outcome: string, extra = {}) =>
      new Response(JSON.stringify({ outcome, ...extra }), { status, headers });
    if (origin && !deps.origins.includes(origin)) {
      return reply(403, "forbidden");
    }
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers });
    }
    if (req.method !== "POST") return reply(405, "unavailable");
    const authorization = req.headers.get("authorization") ?? "";
    if (!/^Bearer\s+\S+$/i.test(authorization)) return reply(401, "forbidden");
    let userId: string | null;
    try {
      userId = await deps.authenticate(authorization);
    } catch (_) {
      return reply(503, "unavailable");
    }
    if (!userId) return reply(401, "forbidden");
    let storeId: string, taxCode: string;
    try {
      const body = JSON.parse(await readBounded(req, 1024));
      storeId = typeof body?.store_id === "string" ? body.store_id : "";
      taxCode = typeof body?.tax_code === "string" ? body.tax_code.trim() : "";
      if (!uuid.test(storeId) || !validTaxCode(taxCode)) {
        return reply(400, "invalid_input");
      }
    } catch (_) {
      return reply(400, "invalid_input");
    }
    const leaseId = crypto.randomUUID();
    let claimed = false;
    try {
      const claim = await deps.claim(userId, storeId, leaseId);
      if (claim.outcome !== "claimed") {
        const status = claim.outcome === "forbidden"
          ? 403
          : claim.outcome === "rate_limited"
          ? 429
          : 200;
        return reply(status, claim.outcome);
      }
      claimed = true;
      const company = await fetchCompany(taxCode, deps.fetch);
      if (!company) return reply(200, "unavailable");
      return reply(200, "success", {
        tax_code: taxCode,
        company_name: company.name,
        source: company.source,
        fetched_at: (deps.now?.() ?? new Date()).toISOString(),
      });
    } catch (_) {
      return reply(503, "unavailable");
    } finally {
      if (claimed) {
        // A bounded lease also expires if the process or release transport dies.
        await deps.release(userId, leaseId).catch(() => {});
      }
    }
  };
}
