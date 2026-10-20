# Persistent POS sessions and unified requester receiving

Owner authorization: 2026-10-20, retain login until explicit logout on every
surface and let the existing PR account receive, confirm and post stock.

Implementation starts from current main (73d180ca), which includes the prior
procurement onboarding and combined-receiving migrations. The older planning
checkout is preserved. No unrelated user files are included.

## Sessions

- Browser windows use durable localStorage slots and matching isolated Auth
  broadcast namespaces. Existing per-window sessionStorage sessions migrate
  once. A terminal identifier in the URL restores the same window after restart;
  a generic launch opens its last unnamed terminal. Named kitchen, floor,
  inventory and admin terminals are also supported.
- An authenticated session's last validated profile is cached within its
  project/terminal/user scope. Password and privacy consent gates remain part
  of that snapshot. Server RLS still authorizes every data operation.
- Temporary profile failures retain the current user/store/screen. JWT expiry
  refreshes once before retrying the profile. Missing/denied profiles block
  access on a recovery screen without deleting the refreshable session.
- The vendored Auth SDK treats refresh-token HTTP 429 as a retryable error,
  preserving the session while its existing bounded retry handles throttling.
- Initial-session and token-refresh events recover missing profile state.
  Profile retries are shared and bounded to two delayed attempts; requests
  time out after ten seconds. Fallback events reuse a profile for five minutes;
  staff/settings changes and lifecycle resume force validation.
- Explicit logout clears current-terminal session/profile data and session
  providers even while offline. Confirmed account deactivation and invalid
  roles still stop access. Revoked credentials are never restored from cache.

Read-only Auth management verification confirmed production settings:
`sessions_timebox=0`, `sessions_inactivity_timeout=0`,
`sessions_single_per_user=false`, `jwt_exp=3600`. No server session timeout
change is required; short-lived JWTs continue to refresh automatically.

## Receiving

Migration 20261020153000 adds requester, receiver and verifier stages to the
same provisioned `*_pr1` Auth principal using the existing bounded, set-based
store onboarding path. It backfills current active stores, audits the added
stages and verifies all eligible requesters have all three assignments.

The existing API capability flags already expose combined receiving to the UI.
The underlying policy-3 atomic endpoint and legacy combined submit/confirm
endpoint remain unchanged, preserving tenant access, inspection evidence,
idempotency, stock guards and price restrictions. Historical `*_order`
identities, approvals and completed receipts remain intact. The production
preflight found zero outstanding drafts owned by the former receiving IDs.

New stores and repeated provisioning use the same updated onboarding function,
so the receiving stages do not disappear on a later account synchronization.

## Verification

- Auth regression covers every known POS role, cached cold start during an
  outage, successful token refresh recovery, expired JWT, privacy RPC outage,
  blocked profile, shared fallback requests, stale response and offline logout.
- Chrome tests use real localStorage and Auth BroadcastChannel implementations
  to check window migration/restart and terminal isolation.
- Local Auth tests confirmed three profile/store/consent reads on initial
  login and zero additional profile reads for twenty fresh fallback events.
- The isolated procurement database tests create a real provisioned PR identity
  with distinct Auth/profile IDs. That ID receives six units through legacy
  combined receiving and four units through policy-3 finalization. Retrying
  finalization returns the original result and adds no further stock. Expired,
  inactive and wrong-store principals remain blocked.
- Existing integration tests measure 1/20/200-line receiving with one logical
  write RPC. Client network latency and application memory are not measured.

Deployment must use the official production script, an exact current-main SHA,
and a successful GitHub Actions `POS release contract` check for that SHA.
Production mutation and the live deployment are verified separately after
release; test fixtures never create operational orders or inventory movements.
