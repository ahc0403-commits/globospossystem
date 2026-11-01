// Local port adapter only. Imports the actual unmodified Office Edge entrypoint.
// No handler, authorization, RPC result or business dependency is replaced.
const [source] = Deno.args;
const ready = Deno.env.get("POS_FIXTURE_EDGE_READY") ?? "";
const runId = Deno.env.get("POS_FIXTURE_RUN_ID") ?? "";
const functionName = Deno.env.get("POS_FIXTURE_EDGE_FUNCTION") ?? "pos-bridge";
if (!["pos-bridge","store-account-onboarding"].includes(functionName) ||
    !source?.startsWith("file:///") || !source.endsWith(`/supabase/functions/${functionName}/index.ts`) ||
    !ready.startsWith("/") || !/^[a-f0-9]{32}$/.test(runId)) {
  throw new Error("EXPLICIT_OWNED_EDGE_SOURCE_REQUIRED");
}
const originalServe = Deno.serve;
let started = false;
Deno.serve = ((handler: Deno.ServeHandler) => {
  if (started || typeof handler !== "function") throw new Error("ONE_EDGE_HANDLER_REQUIRED");
  started = true;
  const server = originalServe({ hostname: "127.0.0.1", port: 0, onListen() {} }, handler);
  Deno.writeTextFileSync(ready, JSON.stringify({runId,pid:Deno.pid,port:server.addr.port}));
  return server;
}) as typeof Deno.serve;
await import(source);
