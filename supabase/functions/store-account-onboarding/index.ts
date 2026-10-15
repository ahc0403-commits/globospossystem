import { createClient } from "@supabase/supabase-js";
import { createMissingAccounts, type Item } from "./worker.ts";

const origins = (Deno.env.get("ALLOWED_ORIGINS") ?? "").split(",").map((s) =>
  s.trim()
).filter(Boolean);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
Deno.serve(async (req) => {
  const origin = req.headers.get("origin");
  const headers = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": origin && origins.includes(origin)
      ? origin
      : (origins[0] ?? ""),
    "Access-Control-Allow-Headers":
      "authorization,x-client-info,apikey,content-type",
    "Vary": "Origin",
  };
  const reply = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), { status, headers });
  if (origin && !origins.includes(origin)) {
    return reply(403, { error: "ORIGIN_FORBIDDEN" });
  }
  if (req.method === "OPTIONS") return reply(200, {});
  if (req.method !== "POST") return reply(405, { error: "METHOD_NOT_ALLOWED" });
  const token = req.headers.get("authorization") ?? "";
  if (!token) return reply(401, { error: "UNAUTHORIZED" });
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const password = Deno.env.get("STORE_ONBOARDING_INITIAL_PASSWORD") ?? "";
  if (!url || !key || password.length < 12) {
    return reply(503, { error: "BOOTSTRAP_SECRET_MISSING" });
  }
  const service = createClient(url, key, {
    global: {
      fetch: (input, init) =>
        fetch(input, { ...init, signal: AbortSignal.timeout(12000) }),
    },
  });
  try {
    if (Number(req.headers.get("content-length") ?? 0) > 2048) {
      return reply(413, { error: "REQUEST_TOO_LARGE" });
    }
    const body = await req.json();
    const cron = Deno.env.get("CRON_SECRET");
    const internal = !!cron && token === `Bearer ${cron}`;
    const jobId = typeof body.job_id === "string" ? body.job_id : null;
    if (!internal) {
      if (!jobId || !uuid.test(jobId)) {
        return reply(400, { error: "JOB_ID_REQUIRED" });
      }
      const caller = createClient(
        url,
        Deno.env.get("SUPABASE_ANON_KEY") ?? "",
        { global: { headers: { Authorization: token } } },
      );
      const { data, error } = await caller.auth.getUser();
      if (error || !data.user) return reply(401, { error: "UNAUTHORIZED" });
      // Master authorization is checked again by the database, including active status.
      const status = await caller.rpc("admin_store_onboarding_status_v1", {
        p_job_id: jobId,
        p_retry: body.retry === true,
      });
      if (status.error) return reply(403, { error: "ONBOARDING_FORBIDDEN" });
      if (status.data.status === "complete") return reply(200, status.data);
    }
    const { data: job, error } = await service.rpc(
      "claim_store_onboarding_v1",
      { p_job_id: internal ? null : jobId },
    );
    if (error) throw error;
    if (!job) return reply(202, { status: "running", job_id: jobId });
    await createMissingAccounts(
      job.items as Item[],
      password,
      (attributes) => service.auth.admin.createUser(attributes),
    );
    const result = await service.rpc("finish_store_onboarding_v1", {
      p_job_id: job.job_id,
      p_lease_id: job.lease_id,
    });
    if (result.error) throw result.error;
    return reply(200, result.data);
  } catch {
    // Never log Auth responses, request bodies or passwords.
    return reply(503, { error: "ONBOARDING_RETRY_REQUIRED" });
  }
});
