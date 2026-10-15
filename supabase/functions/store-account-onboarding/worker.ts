export type Item = {
  account_code: string;
  display_name: string;
  role: string;
  account_type: string;
  scope: string;
  owner_id: string;
  auth_exists: boolean;
};

/** Auth has no bulk create API. DB preparation/reconciliation remain two RPCs;
 * at most 50 Auth writes, concurrency 2, no password updates or deletion. */
export async function createMissingAccounts(
  items: Item[],
  password: string,
  create: (attributes: Record<string, unknown>) => Promise<unknown>,
  now = () => Date.now(),
): Promise<{ attempted: number; failed: number }> {
  if (!password || password.length < 12) {
    throw new Error("BOOTSTRAP_SECRET_MISSING");
  }
  if (!Array.isArray(items) || items.length > 50) {
    throw new Error("ACCOUNT_LIMIT");
  }
  const pending = items.filter((item) => !item.auth_exists);
  let cursor = 0;
  let failed = 0;
  let attempted = 0;
  const deadline = now() + 65000;
  const worker = async () => {
    while (cursor < pending.length && now() < deadline) {
      const item = pending[cursor++];
      attempted++;
      try {
        const result = await create({
          email: `${item.account_code}@globos.world`,
          password,
          email_confirm: true,
          user_metadata: { full_name: item.display_name },
          app_metadata: {
            store_onboarding: {
              code: item.account_code,
              role: item.role,
              type: item.account_type,
              scope: item.scope,
              owner_id: item.owner_id,
            },
          },
        }) as { error?: unknown };
        if (result?.error) failed++;
      } catch {
        // Lost acknowledgements are reconciled by indexed Auth email in SQL.
        failed++;
      }
    }
  };
  await Promise.all([worker(), worker()]);
  return { attempted, failed };
}
