/** Deliberry was retired by the owner on 2026-10-05. No DB/vendor calls. */
export function retiredDeliberryResponse(_request: Request): Response {
  return new Response(
    JSON.stringify({ ok: false, error: "DELIBERRY_INTEGRATION_RETIRED" }),
    {
      status: 410,
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, content-type",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Cache-Control": "no-store",
      },
    },
  );
}
