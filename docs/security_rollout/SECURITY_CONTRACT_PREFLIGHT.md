# Security Contract preflight specification

The Contract draft is intentionally outside `supabase/migrations` and must not be promoted during the Expand release. A later release owner must collect all of the following evidence before assigning it a new migration version:

- The security-audit migration and Expand migration each appear in remote migration history and their post-apply verification scripts pass.
- Old-client smoke succeeds against Expand before the new client is released.
- The exact-main Flutter release with persistent payment-attempt IDs, v2 proof/PIN RPCs, authenticated proof reads, and legacy-role removal is deployed.
- Every POS terminal has completed a full refresh and reports the new release identifier.
- At least one full business cycle has completed without legacy RPC dependency or idempotency/proof/PIN errors.
- Logs/telemetry show no supported client calls to the four-argument payment RPC, legacy proof RPC, or legacy PIN setter/reader for the agreed observation window.
- Existing `admin` rows still route and operate, while no new `admin` creation is possible.
- A canary backup and the emergency regrant draft have been peer-reviewed and rehearsed in an isolated database.
- Office reads of `restaurants(id, name, address, is_active)` remain unchanged, and both settlement Functions remain separate.

The promoted Contract must be the only approved migration in its invocation. It must run its read-only preflight first, use a new timestamp (not `20260715020000`), and must not be bundled with an Edge Function or Vercel deployment.
