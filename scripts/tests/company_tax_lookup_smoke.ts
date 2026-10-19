import {
  fetchCompany,
  type ProviderFetch,
} from "../../supabase/functions/company-tax-lookup/handler.ts";
const records = [];
for (const code of ["0316956049", "0316794479", "0316794479-001"]) {
  let calls = 0, bytes = 0;
  const tracked: ProviderFetch = async (input, init) => {
    calls++;
    const res = await fetch(input, init);
    const body = res.body?.pipeThrough(
      new TransformStream({
        transform(chunk, controller) {
          bytes += chunk.byteLength;
          controller.enqueue(chunk);
        },
      }),
    );
    return new Response(body, { status: res.status, headers: res.headers });
  };
  const start = performance.now();
  const name = await fetchCompany(code, tracked);
  records.push({
    taxCode: code,
    outcome: name ? "success" : "unavailable",
    calls,
    upstreamBytes: bytes,
    companyNameCharacters: name?.length ?? 0,
    elapsedMs: Math.round(performance.now() - start),
  });
}
console.log(
  JSON.stringify({ measuredAt: new Date().toISOString(), records }, null, 2),
);
