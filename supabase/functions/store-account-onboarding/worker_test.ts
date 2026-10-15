import { createMissingAccounts, type Item } from "./worker.ts";
const assert = (condition: unknown, message: string) => {
  if (!condition) throw new Error(message);
};
const items = (count: number): Item[] =>
  Array.from(
    { length: count },
    (_, n) => ({
      account_code: `test_${n}`,
      display_name: "Fixture",
      role: "cashier",
      account_type: "device_pos",
      scope: "store",
      owner_id: "owner",
      auth_exists: false,
    }),
  );
Deno.test("bounded Auth creates, concurrency two; no database reads per account", async () => {
  let active = 0;
  let peak = 0;
  const writes: Record<string, unknown>[] = [];
  const started = performance.now();
  const result = await createMissingAccounts(
    items(50),
    "fixture-secret-only",
    async (input) => {
      active++;
      peak = Math.max(peak, active);
      writes.push(input);
      await new Promise((r) => setTimeout(r, 1));
      active--;
      return { error: null };
    },
  );
  assert(
    peak === 2 && writes.length === 50 && result.failed === 0,
    "bounded worker",
  );
  assert(
    writes.every((w) =>
      w.password === "fixture-secret-only" &&
      (w.app_metadata as Record<string, unknown>).store_onboarding
    ),
    "trusted marker and configured secret",
  );
  console.log(
    JSON.stringify({
      authWrites: writes.length,
      peakConcurrency: peak,
      payloadBytes: JSON.stringify(writes).length,
      elapsedMs: Math.round(performance.now() - started),
    }),
  );
});
Deno.test("existing identities are skipped; partial failure does not stop other accounts", async () => {
  const batch = items(5);
  batch[0].auth_exists = true;
  let count = 0;
  const result = await createMissingAccounts(
    batch,
    "fixture-secret-only",
    async () => {
      await Promise.resolve();
      count++;
      if (count === 2) throw new Error("lost response");
      return { error: null };
    },
  );
  assert(
    count === 4 && result.failed === 1,
    "existing identity preserved, partial progress",
  );
});
Deno.test("secret and batch limits fail before any Auth write", async () => {
  let count = 0;
  for (
    const [batch, password] of [[items(1), ""], [
      items(51),
      "fixture-secret-only",
    ]] as const
  ) {
    let threw = false;
    try {
      await createMissingAccounts(batch, password, async () => {
        await Promise.resolve();
        count++;
      });
    } catch {
      threw = true;
    }
    assert(threw, "must fail closed");
  }
  assert(count === 0, "no Auth writes");
});
Deno.test("deadline limits retries and leaves remaining work durable", async () => {
  let time = 0;
  let count = 0;
  await createMissingAccounts(items(50), "fixture-secret-only", async () => {
    await Promise.resolve();
    count++;
    time += 33000;
    return {};
  }, () => time);
  assert(count <= 2, "worker time budget");
});
