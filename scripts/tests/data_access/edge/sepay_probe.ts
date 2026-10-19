// Production webhook and real signature verifier; only DB/HTTP transports stubbed.
const g = globalThis as any;
g.__handlers = [];
Deno.env.set("SEPAY_WEBHOOK_SECRET", "synthetic-secret");
Deno.env.set("SUPABASE_URL", "https://fixture.invalid");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "fixture");
await import(`${Deno.cwd()}/supabase/functions/sepay-webhook/index.ts`);
const handler = g.__handlers.pop(), results = [];
for (
  const [status, resolution, push, expected] of [
    ["accepted", "matched", false, 0],
    ["accepted", "matched", true, 1],
    ["duplicate", "matched", true, 0],
    ["accepted", "unmatched", true, 0],
  ] as const
) {
  let kicks = 0, ingests = 0;
  g.__client = {
    rpc: async (name: string) => {
      if (name !== "ingest_sepay_transaction_with_delivery_scope") {
        throw new Error(name);
      }
      ingests++;
      return {
        data: {
          status,
          resolution_status: resolution,
          push_dispatch_required: push,
        },
        error: null,
      };
    },
  };
  g.fetch = async () => {
    kicks++;
    return new Response("{}");
  };
  const body = JSON.stringify({
    id: 123,
    gateway: "synthetic",
    accountNumber: "123",
    transferType: "in",
    transferAmount: 1000,
  });
  const timestamp = String(Math.floor(Date.now() / 1000)),
    encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode("synthetic-secret"),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = Array.from(
    new Uint8Array(
      await crypto.subtle.sign(
        "HMAC",
        key,
        encoder.encode(`${timestamp}.${body}`),
      ),
    ),
  ).map((v) => v.toString(16).padStart(2, "0")).join("");
  const response = await handler(
    new Request("https://fixture.invalid", {
      method: "POST",
      body,
      headers: {
        "x-sepay-signature": signature,
        "x-sepay-timestamp": timestamp,
      },
    }),
  );
  if (response.status !== 200 || ingests !== 1 || kicks !== expected) {
    throw new Error(JSON.stringify({ status, resolution, push, kicks }));
  }
  results.push({ status, resolution, push, kicks, ingests });
}
console.log(
  JSON.stringify(
    {
      cases: results,
      note:
        "Actual signed production handler; synthetic transport. Current Windows polling trigger is verified separately in disposable SQL.",
    },
    null,
    2,
  ),
);
