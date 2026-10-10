// Actual production handlers with synthetic DB/vendor transports, no network.
const root = Deno.cwd();
const g = globalThis as any;
g.__handlers = [];
g.__oauthCalls = 0;
for (
  const [k, v] of Object.entries({
    CRON_SECRET: "fixture",
    SUPABASE_URL: "https://fixture.invalid",
    SUPABASE_SERVICE_ROLE_KEY: "fixture",
    FIREBASE_SERVICE_ACCOUNT_JSON: "fixture",
  })
) Deno.env.set(k, v);
await import(`${root}/supabase/functions/meinvoice-dispatcher/index.ts`);
const misa = g.__handlers.pop();
await import(
  `${root}/supabase/functions/emergency-fulfillment-dispatcher/index.ts`
);
const emergency = g.__handlers.pop();
const results: any[] = [];
const bytes = (v: unknown) =>
  new TextEncoder().encode(JSON.stringify(v)).length;
const pause = () => new Promise((r) => setTimeout(r, 1));
const request = (body: unknown = {}) =>
  new Request("https://fixture.invalid", {
    method: "POST",
    headers: {
      authorization: "Bearer fixture",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
function invoice(i: number, entity: string) {
  return {
    id: `00000000-0000-7000-8000-${String(i).padStart(12, "0")}`,
    tax_entity_id: entity,
    status: "pending",
    dispatch_attempts: 0,
    created_at: "2026-10-10T01:00:00Z",
    payment_method_snapshot: "Tien mat",
    line_items_snapshot: [{
      quantity: 1,
      unit_price_ex_tax: 100000,
      total_amount_ex_tax: 100000,
      vat_amount: 8000,
      paying_amount_inc_tax: 108000,
      vat_rate: 8,
      display_name: "Synthetic",
    }],
  };
}
function assert(ok: unknown, message: string) {
  if (!ok) throw new Error(message);
}
for (
  const [n, entities, dispatchers, scenario = "success"] of [
    [1, 1, 1],
    [10, 1, 1],
    [50, 1, 1],
    [50, 50, 1],
    [50, 1, 2],
    [50, 1, 8],
    [1, 1, 1, "lost_response"],
    [1, 1, 1, "malformed_body"],
  ]
) {
  const samples: any[] = [];
  for (var repeat = 0; repeat < 20; repeat++) {
    const jobs = Array.from(
      { length: n },
      (_, i) => invoice(i, `entity-${i % entities}`),
    );
    let calls = 0,
      settingCalls = 0,
      returned = 0,
      responseBytes = 0,
      active = 0,
      peak = 0;
    const published: string[] = [];
    g.__client = {
      from(table: string) {
        const q: any = {
          select() {
            return q;
          },
          in() {
            return q;
          },
          eq() {
            return q;
          },
          order() {
            return q;
          },
          limit() {
            return q;
          },
          maybeSingle() {
            return q;
          },
          then(resolve: any, reject: any) {
            return execute().then(resolve, reject);
          },
        };
        async function execute() {
          calls++;
          let data: any;
          if (table === "system_config") {
            data = [{ key: "meinvoice_dispatch_enabled", value: "true" }, {
              key: "meinvoice_dispatch_batch_size",
              value: "50",
            }, { key: "meinvoice_token_refresh_skew_minutes", value: "60" }];
          } else {
            settingCalls++;
            data = Array.from(
              { length: entities },
              (_, i) =>
                table === "tax_entity"
                  ? {
                    id: `entity-${i}`,
                    tax_code: "fixture-tax",
                    name: "Fixture",
                  }
                  : table === "meinvoice_tax_entity_config"
                  ? {
                    tax_entity_id: `entity-${i}`,
                    app_id: "fixture",
                    invoice_series: "1C26TAA",
                    integration_status: "active",
                  }
                  : {
                    tax_entity_id: `entity-${i}`,
                    current_token: "fixture",
                    token_expires_at: "2099-01-01T00:00:00Z",
                  },
            );
          }
          returned += data.length;
          responseBytes += bytes(data);
          await pause();
          return { data, error: null };
        }
        return q;
      },
      rpc: async (name: string, p: any) => {
        calls++;
        let data: any;
        if (name === "claim_meinvoice_jobs") {
          const selected = jobs.filter((j) =>
            j.status === "pending" && !(j as any).owner
          ).slice(0, p.p_limit);
          selected.forEach((j) => (j as any).owner = p.p_claim_id);
          data = structuredClone(selected);
          returned += data.length;
        } else if (name === "complete_meinvoice_batch") {
          for (const r of p.p_results) {
            const j = jobs.find((j) => j.id === r.id) as any;
            assert(j.owner === p.p_claim_id, "MISA completion owner");
            Object.assign(j, r);
          }
          data = p.p_results.length;
        } else throw new Error(name);
        responseBytes += bytes(data);
        await pause();
        return { data, error: null };
      },
    };
    g.fetch = async (_url: unknown, opts: any) => {
      active++;
      peak = Math.max(peak, active);
      const id = JSON.parse(opts.body).InvoiceData[0].RefID;
      published.push(id);
      await pause();
      active--;
      if (scenario === "lost_response") {
        throw new TypeError("synthetic lost acknowledgement");
      }
      if (scenario === "malformed_body") {
        return new Response("invalid-json", { status: 200 });
      }
      return new Response(
        JSON.stringify({
          Success: true,
          Data: [{ RefID: id, TransactionID: "fixture" }],
        }),
      );
    };
    const started = performance.now();
    const bodies = await Promise.all(
      Array.from(
        { length: dispatchers },
        async () => await (await misa(request())).json(),
      ),
    );
    assert(
      published.length === n && new Set(published).size === n,
      "MISA duplicate/lost publish",
    );
    assert(peak <= 2 * dispatchers, "MISA concurrency budget");
    if (scenario === "success") {
      assert(bodies.every((b) => b.ok), "MISA failure");
    } else {assert(
        jobs.every((j) => j.status === "manual_action_required"),
        "Unknown publish must require reconciliation",
      );}
    if (dispatchers === 1) {
      assert(calls === 6 && settingCalls === 3, "MISA fixed six reads/writes");
    }
    samples.push({
      calls,
      settingCalls,
      returned,
      responseBytes,
      publishes: published.length,
      uniquePublished: new Set(published).size,
      peakVendor: peak,
      ms: performance.now() - started,
    });
  }
  results.push({
    case: "MISA",
    jobs: n,
    entities,
    dispatchers,
    scenario,
    samples,
  });
}
for (
  const [n, status, dispatchers] of [
    [1, 200, 1],
    [50, 200, 1],
    [1000, 200, 1],
    [1000, 200, 2],
    [1000, 200, 8],
    [50, 404, 1],
    [50, 429, 1],
    [0, 200, 1],
  ]
) {
  const samples: any[] = [];
  for (var repeat = 0; repeat < 20; repeat++) {
    let calls = 0,
      claimed = 0,
      completed = 0,
      sends = 0,
      active = 0,
      peak = 0,
      responseBytes = 0;
    g.__oauthCalls = 0;
    const sentIds: string[] = [];
    const completionRows: any[] = [];
    const queue = Array.from({ length: n }, (_, i) => ({
      id: `delivery-${i}`,
      event_id: `event-${i}`,
      restaurant_id: "store",
      order_id: "order",
      station_type: "kitchen",
      stage: "cooking",
      push_token: "fixture-token-000000",
      attempt_count: 1,
      owner: null as string | null,
    }));
    g.__client = {
      rpc: async (name: string, p: any) => {
        calls++;
        let data: any;
        if (name === "claim_emergency_push_batch") {
          const remaining = queue.filter((r) => !r.owner);
          const selected = remaining.slice(0, 50);
          selected.forEach((r) => r.owner = p.p_claim_id);
          claimed += selected.length;
          data = {
            rows: structuredClone(selected),
            has_more: remaining.length > 50,
          };
        } else if (name === "complete_emergency_push_batch") {
          completed += p.p_results.length;
          completionRows.push(...p.p_results);
          data = p.p_results.length;
        } else throw new Error(name);
        responseBytes += bytes(data);
        await pause();
        return { data, error: null };
      },
    };
    g.fetch = async (_url: unknown, opts: any) => {
      sends++;
      active++;
      peak = Math.max(peak, active);
      const message = JSON.parse(opts.body).message;
      sentIds.push(message.data.event_id);
      assert(
        message.webpush.notification.renotify === false,
        "Unknown outcome must not re-alert same tag",
      );
      await pause();
      active--;
      return new Response(
        JSON.stringify(
          status === 200 ? { name: "fixture" } : status === 404
            ? {
              error: {
                status: "NOT_FOUND",
                details: [{ errorCode: "UNREGISTERED" }],
              },
            }
            : { error: { status: "RESOURCE_EXHAUSTED" } },
        ),
        { status, headers: { "retry-after": "120" } },
      );
    };
    const started = performance.now();
    const bodies = await Promise.all(
      Array.from(
        { length: dispatchers },
        async () => await (await emergency(request())).json(),
      ),
    );
    assert(
      claimed === n && completed === n && sends === n &&
        new Set(sentIds).size === n,
      "Push duplicate/loss",
    );
    assert(peak <= 4 * dispatchers, "Push concurrency budget");
    if (n === 50 && dispatchers === 1) {
      assert(calls === 2, "Push claim+complete pair");
    }
    if (n === 0) assert(g.__oauthCalls === 0, "Empty queue OAuth");
    if (status === 404) {
      assert(
        completionRows.every((r) =>
          r.permanent && r.error === "FCM_UNREGISTERED"
        ),
        "Permanent token classification",
      );
    }
    if (status === 429) {
      assert(
        completionRows.every((r) => !r.permanent && r.retry_seconds >= 120),
        "Retry-After",
      );
    }
    assert(bodies.every((b) => b.success), "Push failed completion");
    samples.push({
      calls,
      claimed,
      completed,
      sends,
      peakVendor: peak,
      oauthCalls: g.__oauthCalls,
      responseBytes,
      ms: performance.now() - started,
    });
  }
  results.push({
    case: "emergency",
    deliveries: n,
    status,
    dispatchers,
    samples,
  });
}
console.log(JSON.stringify(
  {
    limitations: [
      "Actual handler control flow with synthetic atomic claim transports and 1ms delays; no live vendor service. SQL concurrency/lease tests are independent. HTTP bytes are mock response bytes, not scanned DB rows.",
      "Times include JIT/instrumentation and are not production RTT.",
    ],
    results,
  },
  null,
  2,
));
