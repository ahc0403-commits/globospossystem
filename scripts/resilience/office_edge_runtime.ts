// Preload local port adapter. The actual entrypoint remains Deno.mainModule, so
// import.meta.main and both modern/legacy production listeners retain semantics.
// No handler, authorization, RPC result or business dependency is replaced.
const source = Deno.env.get("POS_FIXTURE_EDGE_SOURCE") ?? "";
const ready = Deno.env.get("POS_FIXTURE_EDGE_READY") ?? "";
const runId = Deno.env.get("POS_FIXTURE_RUN_ID") ?? "";
const functionName = Deno.env.get("POS_FIXTURE_EDGE_FUNCTION") ?? "pos-bridge";
if (!["pos-bridge","store-account-onboarding","complete-initial-password-change"].includes(functionName) ||
    !source?.startsWith("file:///") || !source.endsWith(`/supabase/functions/${functionName}/index.ts`) ||
    Deno.mainModule !== source ||
    !ready.startsWith("/") || !/^[a-f0-9]{32}$/.test(runId)) {
  throw new Error("EXPLICIT_OWNED_EDGE_SOURCE_REQUIRED");
}
const originalServe = Deno.serve;
const originalListen = Deno.listen;
let started = false;
function record(port: number) {
  Deno.writeTextFileSync(ready, JSON.stringify({runId,pid:Deno.pid,port}));
}
Deno.serve = ((handler: Deno.ServeHandler) => {
  if (started || typeof handler !== "function") throw new Error("ONE_EDGE_HANDLER_REQUIRED");
  started = true;
  const server = originalServe({ hostname: "127.0.0.1", port: 0, onListen() {} }, handler);
  record(server.addr.port);
  return server;
}) as typeof Deno.serve;
Deno.listen = ((options: Deno.ListenOptions & {transport?: string}) => {
  if (started || options.transport && options.transport !== "tcp") throw new Error("ONE_TCP_EDGE_LISTENER_REQUIRED");
  started = true;
  const listener = originalListen({hostname:"127.0.0.1",port:0,transport:"tcp"});
  record(listener.addr.port);
  return listener;
}) as typeof Deno.listen;
export {};
