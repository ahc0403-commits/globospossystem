import { retiredDeliberryResponse } from "./retired_deliberry.ts";

for (const method of ["GET", "POST", "OPTIONS", "PUT", "DELETE"]) {
  Deno.test(`retired Deliberry rejects ${method} without credentials`, async () => {
    const request = new Request("http://localhost/retired", {
      method,
      ...(method === "POST" ? { body: "invalid-json" } : {}),
    });
    const response = retiredDeliberryResponse(request);
    if (response.status !== 410) throw new Error("Expected HTTP 410");
    const body = await response.json();
    if (body.ok !== false || body.error !== "DELIBERRY_INTEGRATION_RETIRED") {
      throw new Error("Unexpected retirement response");
    }
    if (request.bodyUsed) throw new Error("Retired handler read the request");
  });
}

Deno.test("retired Deliberry does not read even a failing request body", () => {
  const request = new Request("http://localhost/retired", {
    method: "POST",
    body: new ReadableStream({
      pull() {
        throw new Error("Must not read retired vendor payload");
      },
    }, { highWaterMark: 0 }),
  });
  if (retiredDeliberryResponse(request).status !== 410) {
    throw new Error("Expected HTTP 410");
  }
});
