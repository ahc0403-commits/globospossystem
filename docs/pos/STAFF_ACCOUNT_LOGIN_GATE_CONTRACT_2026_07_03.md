# Staff Creation / Login Gate Contract

Date: 2026-07-03
Status: DRAFT — pending review
Source: Harness audit 2026-07-03 (defects C3, H6)
Related: `docs/pos/POS_DEPLOY_AUTH_ROOT_CAUSE_AUDIT_2026_06_25.md`,
`docs/pos/ORDER_LIFECYCLE_STATE_CONTRACT_2026_07_03.md`

## Problem Statement

A staff account can end up "half-provisioned": auth user exists but JWT
claims (`accessible_store_ids`) are empty because `refresh_user_claims`
failure in `create_staff_user` is logged but non-fatal
(`supabase/functions/create_staff_user/index.ts:351-356`). Login then
succeeds with `storeId = null` (`auth_provider.dart:243-291`), the user
lands on a home screen where order creation silently fails. Unknown/null
roles route back to `/login` with no error while the session stays alive
(`role_routes.dart:3-13`). Pilots read all of this as "the app is broken."

## Core Principle

**A login either produces a fully operable session (valid role + ≥1 store
scope) or a specific, user-visible error. There is no third state.**

Same on the write side: `create_staff_user` either provisions everything
(auth + profile + store access + claims) or nothing.

## Requirements

### P0-1: `create_staff_user` is all-or-nothing (C3)

- `refresh_user_claims` failure is FATAL: roll back brand access, store
  access, profile row, and auth user (same rollback chain that already
  exists for the earlier steps), return
  `{ error: 'CLAIMS_REFRESH_FAILED' }` with HTTP 500.
- After a successful claims refresh, the function VERIFIES the result:
  re-read the auth user's `app_metadata.accessible_store_ids` and assert it
  is a non-empty array containing the requested store id. Mismatch = fatal,
  same rollback.
- Function response on success includes the provisioned
  `{ auth_user_id, role, accessible_store_ids }` so callers/scripts can
  assert without a second query.

### P0-2: Login blocks `storeId = null` sessions (C3)

In `auth_provider._fetchUserProfile` / `_resolveAccessibleStores`:

- Roles that require store scope: `admin`, `store_admin`, `brand_admin`,
  `waiter`, `kitchen`, `cashier`, `photo_objet_store_admin`.
  If resolution (app metadata, then `restaurant_id` fallback) yields an
  empty list for these roles → sign out with new error constant
  `authErrorNoStoreScope` (message names the account email and says
  "contact admin — account has no store assigned").
- `super_admin` / `photo_objet_master` are exempt (cross-store roles).
- The `restaurant_id` fallback stays (compatibility with pre-claims
  accounts) but MUST log a diagnostic (`claims_fallback_used`) so stale
  accounts are findable.

### P0-3: Unknown/null role is a surfaced error, not a silent loop (C3)

- `homeRouteForRole` keeps returning `/login` for unknown roles (router
  contract unchanged), BUT `_fetchUserProfile` validates role against the
  known set BEFORE setting auth state. Unknown/null role → sign out with
  `authErrorUnknownRole` including the raw role value in the message.
- Known role set (single source of truth, shared constant used by both
  `auth_provider` and `role_routes`): `super_admin`, `brand_admin`,
  `store_admin`, `admin`, `waiter`, `kitchen`, `cashier`,
  `photo_objet_master`, `photo_objet_store_admin`.
- Result: an authenticated session with an unroutable role can no longer
  exist; the router loop case in `app_router.dart:41-85` becomes dead.

### P1-1: Deploy-gate script upgrade (H6, script half)

Extend `scripts/check_pilot_auth_accounts.sh` (or a sibling
`check_pilot_account_readiness.sh`) to assert per required pilot email:

1. auth user exists, email confirmed;
2. `public.users` profile exists, `is_active = true`;
3. `role` is in the known role set;
4. `app_metadata.accessible_store_ids` is non-empty and every id exists in
   `restaurants`;
5. exit non-zero listing every failing account and which check failed.

(The behavioral smoke — login → order → handoff — is specced separately in
the pilot smoke gate testing strategy, not here.)

### P2: Self-healing provisioning repair command (`refresh_user_claims`
backfill for all active users) — future; manual repair path in the deploy
audit doc remains the fallback.

## Non-Goals

- No change to RLS policies or `get_user_store_id()`.
- No change to the Office app coupling (`restaurants` table contract).
- No multi-store store-switcher UX changes.
- No privacy-consent flow changes (separate MEDIUM finding).
- No CI wiring of the full integration smoke test (covered by
  `/testing-strategy` deliverable).

## Acceptance Criteria

**AC1 — claims failure rolls back everything**
Given `refresh_user_claims` will fail (e.g. RPC revoked in test env)
When `create_staff_user` is called with a valid waiter payload
Then the response is HTTP 500 with `CLAIMS_REFRESH_FAILED`
And no row exists in `auth.users`, `public.users`, `user_store_access`
for that email.

**AC2 — successful creation is immediately loginable**
Given `create_staff_user` returned success for a new cashier
When that account logs in via `signInWithPassword`
Then auth state has `role = 'cashier'`, `storeId` equal to the requested
store, and `accessibleStores` non-empty
And no `claims_fallback_used` diagnostic is logged.

**AC3 — empty store scope cannot reach home**
Given a `waiter` account whose `app_metadata.accessible_store_ids` is `[]`
and whose `users.restaurant_id` is NULL
When the account logs in
Then the session is signed out before any home route push
And the login screen shows `authErrorNoStoreScope`.

**AC4 — restaurant_id fallback still works but is logged**
Given a legacy `waiter` account with empty app metadata and
`users.restaurant_id = R1`
When the account logs in
Then login succeeds with `storeId = R1`
And a `claims_fallback_used` diagnostic is emitted.

**AC5 — unknown role is surfaced**
Given a `users` row with `role = 'manager'` (not in the known set)
When the account logs in
Then the session is signed out
And the login screen shows `authErrorUnknownRole` containing `manager`
And the router never enters a redirect loop (single navigation event).

**AC6 — super_admin exempt from store-scope gate**
Given a `super_admin` with empty `accessible_store_ids`
When the account logs in
Then login succeeds and routes to `/super-admin`.

**AC7 — deactivated account unchanged (regression guard)**
Given an account with `is_active = false`
When it logs in
Then it is signed out with `authErrorAccountDeactivated` (existing
behavior preserved).

**AC8 — readiness script fails loudly**
Given one pilot email whose claims array is empty
When `check_pilot_account_readiness.sh` runs
Then it exits non-zero and its output names that email and the failed
check (`accessible_store_ids empty`).

## Breaking Changes

- Legacy accounts with unknown roles or no store scope, which today land
  on a broken-but-quiet screen, will now be refused at login with an
  explicit message. This is intended; run the readiness script against
  pilot accounts BEFORE deploying this change.

## Implementation Surfaces

| Change | File |
|--------|------|
| Fatal claims refresh + post-verify | `supabase/functions/create_staff_user/index.ts:351-356` |
| Store-scope gate + role validation + new error constants | `lib/features/auth/auth_provider.dart` (`_fetchUserProfile`, `_resolveAccessibleStores`) |
| Shared known-role constant | `lib/core/utils/role_routes.dart` (+ import in auth_provider) |
| Readiness script | `scripts/check_pilot_auth_accounts.sh` (extend) |
| Error strings ×3 languages | `lib/l10n/app_en.arb`, `app_ko.arb`, `app_vi.arb` |

No DB migration required.

## Open Questions

1. Should `authErrorNoStoreScope` / `authErrorUnknownRole` include a
   support contact line for pilot staff? → Hyochang (copy decision only).
