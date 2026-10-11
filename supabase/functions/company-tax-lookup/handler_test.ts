import {
  createLookupHandler,
  fetchCompany,
  type LookupDependencies,
  type ProviderFetch,
  validTaxCode,
} from "./handler.ts";
function assert(value: unknown, message = "assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
const code = "0316794479";
const name = "CÔNG TY TNHH CASSO";
const shop = "20000000-0000-0000-0000-000000000001";
function request(
  body: unknown = { store_id: shop, tax_code: code },
  authorization = "Bearer fixture",
) {
  return new Request("https://fixture.invalid", {
    method: "POST",
    headers: { authorization, origin: "https://pos.invalid" },
    body: JSON.stringify(body),
  });
}
function fixture(
  raw: unknown = {
    error: 0,
    data: { mst: code, ten: name, dc: "discarded address" },
  },
) {
  const counts = { auth: 0, claim: 0, fetch: 0, release: 0 };
  const deps: LookupDependencies = {
    origins: ["https://pos.invalid"],
    authenticate: () => {
      counts.auth++;
      return Promise.resolve("fixture-user");
    },
    claim: () => {
      counts.claim++;
      return Promise.resolve({ outcome: "claimed" });
    },
    release: () => {
      counts.release++;
      return Promise.resolve();
    },
    fetch: (input, init) => {
      counts.fetch++;
      assert(
        input === `https://esgoo.net/api-mst/${code}.htm` ||
          input === `https://api.vietqr.io/v2/business/${code}`,
        "fixed host/code",
      );
      assert(
        init?.redirect === "error" && init.signal,
        "no redirects; abortable request",
      );
      return Promise.resolve(new Response(JSON.stringify(raw)));
    },
    now: () => new Date("2026-10-11T01:00:00Z"),
  };
  return { deps, counts };
}
Deno.test("success returns name only with one provider call and two RPCs", async () => {
  const { deps, counts } = fixture();
  const response = await createLookupHandler(deps)(request());
  const body = await response.json();
  assert(
    response.status === 200 && body.company_name === name &&
      body.tax_code === code && body.source === "esgoo",
  );
  assert(
    Object.keys(body).sort().join() ===
      "company_name,fetched_at,outcome,source,tax_code",
  );
  assert(
    counts.auth === 1 && counts.claim === 1 && counts.fetch === 1 &&
      counts.release === 1,
  );
  console.log(
    JSON.stringify({
      case: "success",
      ...counts,
      responseBytes: new TextEncoder().encode(JSON.stringify(body)).length,
    }),
  );
});
Deno.test("auth, store gate, disabled flag and quota precede upstream access", async () => {
  for (const outcome of ["forbidden", "disabled", "rate_limited"] as const) {
    const { deps, counts } = fixture();
    deps.claim = () => {
      counts.claim++;
      return Promise.resolve({ outcome });
    };
    const response = await createLookupHandler(deps)(request());
    assert(
      (await response.json()).outcome === outcome && counts.fetch === 0 &&
        counts.release === 0,
    );
  }
  const { deps, counts } = fixture();
  const handler = createLookupHandler(deps);
  assert((await handler(request({}, ""))).status === 401);
  assert(counts.auth === 0 && counts.claim === 0);
  deps.authenticate = () => Promise.resolve(null);
  assert((await handler(request())).status === 401 && counts.claim === 0);
});
Deno.test("input types, leading zeroes, branch suffix and bounded request body", async () => {
  assert(validTaxCode("0012345678") && validTaxCode("0012345678-001"));
  for (
    const bad of ["0012345678-000", "012345678901", "../../", "00123456789-12"]
  ) assert(!validTaxCode(bad));
  const { deps, counts } = fixture();
  for (
    const body of [
      { store_id: shop, tax_code: 316794479 },
      { store_id: shop, tax_code: "bad" },
      { store_id: "bad", tax_code: code },
      { blob: "a".repeat(1100) },
    ]
  ) {
    assert((await createLookupHandler(deps)(request(body))).status === 400);
  }
  assert(counts.claim === 0 && counts.fetch === 0);
});
Deno.test("provider errors/malformed/mismatched/oversized JSON are inconclusive and release leases", async () => {
  for (
    const raw of [
      { error: 1 },
      { error: "0", data: { mst: code, ten: name } },
      { error: 0, data: { mst: "0000000000", ten: name } },
      { error: 0, data: { mst: code, ten: " " } },
      { error: 0, data: { mst: code, ten: "a".repeat(301) } },
      { error: 0, data: { mst: code, ten: "a\nname" } },
    ]
  ) {
    const { deps, counts } = fixture(raw);
    assert(
      (await (await createLookupHandler(deps)(request())).json()).outcome ===
        "unavailable",
    );
    assert(counts.fetch === 2 && counts.release === 1);
  }
  for (
    const response of [
      new Response("<html>error</html>"),
      new Response("a".repeat(65537)),
      new Response("failure", { status: 500 }),
    ]
  ) {
    assert(await fetchCompany(code, () => Promise.resolve(response)) === null);
  }
});
Deno.test("stream size limit and shared deadline abort requests without retry", async () => {
  let cancelled = false;
  const body = new ReadableStream<Uint8Array>({
    pull(c) {
      c.enqueue(new Uint8Array(32769));
    },
    cancel() {
      cancelled = true;
    },
  });
  assert(
    await fetchCompany(code, () => Promise.resolve(new Response(body))) ===
        null && cancelled,
  );
  let calls = 0, aborted = false;
  const fetcher: ProviderFetch = (_, init) =>
    new Promise((_, reject) => {
      calls++;
      init!.signal!.addEventListener("abort", () => {
        aborted = true;
        reject(new Error("aborted"));
      });
    });
  assert(
    await fetchCompany(code, fetcher, 40) === null && aborted && calls === 2,
  );
});
Deno.test("missing primary record falls back for the reported code with real provenance", async () => {
  const reportedCode = "0318453298";
  const reportedName = "CÔNG TY TNHH AKJ INTERNATIONAL";
  const { deps, counts } = fixture();
  const urls: string[] = [];
  deps.fetch = (url, init) => {
    counts.fetch++;
    urls.push(url);
    assert(init.redirect === "error");
    const raw = urls.length === 1 ? { error: 1, data: [] } : {
      code: "00",
      data: {
        id: reportedCode,
        name: reportedName,
        address: "must not be forwarded",
        status: "must not imply registered/active verification",
      },
    };
    return Promise.resolve(new Response(JSON.stringify(raw)));
  };
  const response = await createLookupHandler(deps)(
    request({ store_id: shop, tax_code: reportedCode }),
  );
  const body = await response.json();
  assert(body.outcome === "success" && body.company_name === reportedName);
  assert(body.tax_code === reportedCode && body.source === "vietqr");
  assert(!("address" in body) && !("status" in body));
  assert(
    urls.join() ===
      `https://esgoo.net/api-mst/${reportedCode}.htm,https://api.vietqr.io/v2/business/${reportedCode}`,
  );
  assert(counts.claim === 1 && counts.fetch === 2 && counts.release === 1);
});
Deno.test("fallback rejects wrong ID, branch ID, status, name and oversized body", async () => {
  for (
    const raw of [
      { code: "00", data: { id: "0000000000", name } },
      { code: "00", data: { id: `${code}-001`, name } },
      { code: 0, data: { id: code, name } },
      { code: "01", data: { id: code, name } },
      { code: "00", data: { id: code, name: " " } },
      { code: "00", data: { id: code, name: "a".repeat(301) } },
      { code: "00", data: { id: code, name: "a\nname" } },
      { code: "00", data: { id: code, name: 12 } },
      { code: "00", data: { id: code, name, padding: "a".repeat(65536) } },
    ]
  ) {
    let calls = 0;
    const result = await fetchCompany(code, () => {
      calls++;
      return Promise.resolve(
        new Response(JSON.stringify(calls === 1 ? { error: 1 } : raw)),
      );
    });
    assert(result === null && calls === 2);
  }
});
Deno.test("primary timeout reserves fallback budget and both failures stop after two calls", async () => {
  let calls = 0, primaryAborted = false;
  const result = await fetchCompany(code, (_, init) => {
    calls++;
    if (calls === 1) {
      return new Promise((_, reject) =>
        init.signal.addEventListener("abort", () => {
          primaryAborted = true;
          reject(new Error("aborted"));
        })
      );
    }
    return Promise.resolve(
      new Response(JSON.stringify({ code: "00", data: { id: code, name } })),
    );
  }, 80);
  assert(
    primaryAborted && calls === 2 && result?.name === name &&
      result.source === "vietqr",
  );
  for (const status of [429, 500]) {
    calls = 0;
    assert(
      await fetchCompany(code, () => {
            calls++;
            return Promise.resolve(new Response("failure", { status }));
          }) === null && calls === 2,
    );
  }
  const before = performance.now();
  calls = 0;
  assert(
    await fetchCompany(code, (_, init) =>
      new Promise((_, reject) => {
        calls++;
        init.signal.addEventListener(
          "abort",
          () => reject(new Error("aborted")),
        );
      }), 80) === null,
  );
  assert(
    calls === 2 && performance.now() - before < 150,
    "one shared deadline",
  );
});
Deno.test("CORS permits configured origin and OPTIONS is credential-free", async () => {
  const { deps, counts } = fixture();
  const handler = createLookupHandler(deps);
  const response = await handler(
    new Request("https://fixture.invalid", {
      method: "OPTIONS",
      headers: { origin: "https://pos.invalid" },
    }),
  );
  assert(
    response.status === 204 &&
      response.headers.get("access-control-allow-origin") ===
        "https://pos.invalid",
  );
  assert(counts.auth === 0);
  assert(
    (await handler(
      new Request("https://fixture.invalid", {
        method: "OPTIONS",
        headers: { origin: "https://other.invalid" },
      }),
    )).status === 403,
  );
});
