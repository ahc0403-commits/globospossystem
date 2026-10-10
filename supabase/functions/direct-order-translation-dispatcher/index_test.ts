import {
  createTranslationHandler,
  translateBatch,
  validateTranslations,
} from "./index.ts";
import type {
  TranslationDependencies,
  TranslationJob,
  TranslationResult,
} from "./index.ts";
function assert(value: boolean, message: string) {
  if (!value) throw new Error(message);
}
const jobs: TranslationJob[] = [
  {
    id: "customer",
    lease_id: "lease1",
    text: "양파 빼 주세요. 10,000 VND",
    target_locale: "vi",
  },
  {
    id: "cashier",
    lease_id: "lease2",
    text: "Đã hoàn 10,000 VND",
    target_locale: "ko",
  },
];
Deno.test("missing credentials and authorization never claim private text", async () => {
  let claims = 0;
  const deps: TranslationDependencies = {
    authorized: () => false,
    configured: () => false,
    claim: () => {
      claims++;
      return Promise.resolve(jobs);
    },
    translate: () => Promise.resolve(new Map()),
    complete: () => Promise.resolve(0),
  };
  let response = await createTranslationHandler(deps)(
    new Request("https://edge.example", { method: "POST" }),
  );
  assert(response.status === 401 && claims === 0, "auth before data access");
  deps.authorized = () => true;
  response = await createTranslationHandler(deps)(
    new Request("https://edge.example", { method: "POST" }),
  );
  assert(
    response.status === 503 && claims === 0,
    "no key must not consume retries",
  );
});
Deno.test("batch results match IDs and reject changed monetary values", () => {
  const value = {
    translations: [{
      id: "cashier",
      translated_text: "10,000 VND를 환불했습니다",
    }, { id: "customer", translated_text: "Không hành tây. 10,000 VND" }],
  };
  assert(
    validateTranslations(jobs, value).get("customer") ===
      "Không hành tây. 10,000 VND",
    "reordered IDs matched",
  );
  for (
    const invalid of [
      {
        translations: [{
          id: "customer",
          translated_text: "Không hành tây. 100,000 VND",
        }],
      },
      { translations: [value.translations[0], value.translations[0]] },
      { translations: [{ id: "unknown", translated_text: "unknown" }] },
    ]
  ) {
    assert(
      validateTranslations(jobs, invalid).size === 0,
      "invalid output omitted",
    );
  }
});
Deno.test("one Responses call sends text only, disables storage and uses strict schema", async () => {
  let calls = 0;
  const fakeFetch: typeof fetch = (_input, init) => {
    calls++;
    const payload = JSON.parse(String((init as { body?: unknown })?.body));
    assert(
      payload.store === false && payload.text.format.strict === true,
      "privacy and schema",
    );
    assert(
      !payload.input.includes("lease"),
      "database leases are not sent to provider",
    );
    assert(
      payload.input.includes('"target_locale":"vi"') &&
        payload.input.includes('"target_locale":"ko"'),
      "both translation directions",
    );
    return Promise.resolve(
      new Response(
        JSON.stringify({
          status: "completed",
          output: [{
            content: [{
              type: "output_text",
              text: JSON.stringify({
                translations: [
                  {
                    id: "customer",
                    translated_text: "Không hành tây. 10,000 VND",
                  },
                  {
                    id: "cashier",
                    translated_text: "10,000 VND를 환불했습니다",
                  },
                ],
              }),
            }],
          }],
        }),
        { headers: { "content-type": "application/json" } },
      ),
    );
  };
  assert(
    (await translateBatch(jobs, "test-key", "test-model", fakeFetch)).size ===
        2 && calls === 1,
    "one request per batch",
  );
});
Deno.test("API outage acknowledges a retry for every lease without overwriting source", async () => {
  let results: TranslationResult[] = [];
  const response = await createTranslationHandler({
    authorized: () => true,
    configured: () => true,
    claim: () => Promise.resolve(jobs),
    translate: () => Promise.reject(new Error("outage")),
    complete: (rows) => {
      results = rows;
      return Promise.resolve(0);
    },
  })(new Request("https://edge.example", { method: "POST" }));
  assert(
    response.status === 200 && results.length === 2 &&
      results.every((r) => r.translated_text === null),
    "all leases retry",
  );
  assert(jobs[0].text === "양파 빼 주세요. 10,000 VND", "original unchanged");
});

Deno.test("currency and signed amount changes are rejected", () => {
  for (
    const [source, translated] of [["Send 10,000 VND", "Chuyển 10,000 USD"], [
      "Refund -10,000 VND",
      "Hoàn 10,000 VND",
    ], ["Send 10,000 ₫", "Chuyển 10,000 $"]]
  ) {
    const result = validateTranslations([{ ...jobs[0], text: source }], {
      translations: [{ id: jobs[0].id, translated_text: translated }],
    });
    assert(result.size === 0, "protected currency or sign changed");
  }
});
Deno.test("invalid translation retries only that text and preserves another result", async () => {
  let calls = 0;
  const fakeFetch: typeof fetch = (_input, init) => {
    calls++;
    const input = JSON.parse(
      JSON.parse(String((init as { body?: unknown })?.body)).input,
    );
    return Promise.resolve(
      new Response(JSON.stringify({
        status: "completed",
        output: [{
          content: [{
            type: "output_text",
            text: JSON.stringify({
              translations: input.map((item: { id: string }) => ({
                id: item.id,
                translated_text: item.id === "customer"
                  ? "Không hành tây. 100,000 VND"
                  : "10,000 VND를 환불했습니다",
              })),
            }),
          }],
        }],
      })),
    );
  };
  const result = await translateBatch(
    jobs,
    "test-key",
    "test-model",
    fakeFetch,
  );
  assert(
    calls === 1 && result.size === 1 && result.has("cashier"),
    "valid result survives a bad amount in another text without per-item requests",
  );
});
