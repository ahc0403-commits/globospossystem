# GLOBOSVN POS Security Best-Practices Assessment

Assessment date: 2026-07-15

Repository: `/Users/andreahn/globos_pos_system`

Assessed branch/commit: `main` / `ef484e8ad8957caf6906211b12845f51ac780d15`

Mode: repository assessment with source-only remediation; no migration apply, production access, secret change, infrastructure change, or deployment

## Executive summary

This review found one CRITICAL, five HIGH, six MEDIUM, and two LOW issues, plus one confirmed vendor integration constraint. Source remediations for SBP-001 through SBP-004, SBP-006, SBP-008 through SBP-010, and SBP-012 through SBP-015 are present in the working tree. The formerly monolithic second migration is now a backward-compatible Expand migration; the guarded Contract draft is outside `supabase/migrations` and the deployment harness refuses it. Local isolated PostgreSQL tests exercised Security Audit → Expand → Contract/regrant, but production remains unchanged and this report does not claim that production is fixed. Moers credentialed browser collection is required because the vendor does not provide an API and is not classified as a vulnerability. WeTax remains intentionally preserved at the user's direction (SBP-007 deferred), while MISA is confirmed as not yet implemented (SBP-011 accepted as a current scope/evidence gap). New payment-proof creation no longer mints durable URLs or queues plaintext local copies; legacy queued files are retained until upload and v2 attach both succeed, while previously issued long-lived bearer URLs require a separate operational cleanup.

| Severity | Count | IDs |
|---|---:|---|
| CRITICAL | 1 | SBP-001 |
| HIGH | 5 | SBP-002–SBP-004, SBP-006–SBP-007 |
| MEDIUM | 6 | SBP-008–SBP-013 |
| LOW | 2 | SBP-014–SBP-015 |
| CONFIRMED | 1 | SBP-005 (accepted integration constraint; not a vulnerability) |

### Source remediation and classification status

| Item | Repository status | Production status |
|---|---|---|
| SBP-001 | Remediated in source by the forward hardening migration; targeted view ACL/invoker contracts added | Pending migration application and tenant/anon catalog tests |
| SBP-002 | Remediated in source by dropping the permissive audit policy | Pending migration application and effective-policy tests |
| SBP-003 | Remediated in source by revoking internal helper execution and tightening future default function ACLs | Pending migration application and catalog/runtime tests |
| SBP-004 | Remediated in source across canonical helpers, affected Storage policies, and `create_staff_user` | Pending migration/Function deployment and stale-session tests |
| SBP-005 | Reclassified as an accepted integration constraint; credentialed browser collection is required because Moers provides no API | No security remediation required; retain existing collector behavior and operational controls |
| SBP-006 | Remediated in source with full-SHA action pins and step-only secret mappings | Pending workflow deployment and GitHub settings review |
| SBP-007 | Deferred by explicit user decision; WeTax source and behavior are preserved | Existing deployed exposure, if any, remains unverified; no remediation applied |
| SBP-008 | Remediated in source with a mixed-version-safe five-argument boundary and restart-persistent, caller/store/order/split/method/amount-scoped IDs; local concurrent replay passed | Pending staged migration/app deployment and production observation |
| SBP-009 | Remediated in source by rejecting new legacy `admin`, requiring sync/claim success, checking claim postconditions, and rolling back all provisioned resources on failure | Pending Function deployment and failure-injection testing |
| SBP-010 | Partially remediated in source: new proofs persist private object paths, authenticated reads use Storage JWT/RLS, and legacy queued files are migrated before deletion | Pending staged migration/app deployment; legacy long-lived URLs still require a separately authorized cleanup |
| SBP-011 | Accepted as an unimplemented MISA integration and evidence gap; no MISA implementation was requested | No active MISA release/security claim; reassess when implementation begins |
| SBP-012 | Remediated in source by quarantining the bulk reset script so it performs no Auth calls and exits non-zero | Pending merge; approved single-user recovery remains the operational path |
| SBP-013 | Remediated in source by pinning all seven assessed Edge imports to Supabase JS `2.110.2` | Pending Function deployment; excluded WeTax type errors remain |
| SBP-014 | Remediated in source with a private bcrypt verifier, temporary legacy SHA compatibility during Expand, per-actor/store lockout, and fail-closed Flutter behavior; isolated SQL tests passed | Pending staged deployment and production observation; verifier masking is deferred to Contract |
| SBP-015 | Remediated in source for the current WeTax portal boundary with HTTPS/host/userinfo/port validation at both launch points | Pending app deployment; authoritative MISA hosts must be added only when MISA is implemented |

### Review baseline and limitations

- The requested `security-best-practices` skill has no concrete Deno/Supabase/Postgres/Dart reference package. Its report discipline was used, while technical conclusions were grounded in repository evidence and official Supabase, PostgreSQL, and GitHub documentation.
- Supabase documents that views created by a privileged owner bypass underlying RLS by default and should use `security_invoker=true`; functions are executable by `PUBLIC` by default unless revoked. See [Supabase RLS views](https://supabase.com/docs/guides/database/postgres/row-level-security), [database functions](https://supabase.com/docs/guides/database/functions), and [API security](https://supabase.com/docs/guides/api/securing-your-api).
- GitHub documents that full commit SHAs are the immutable way to reference Actions and that a compromised action can access secrets available to its job. See [GitHub Actions secure use](https://docs.github.com/en/actions/reference/security/secure-use).
- Findings are confirmed against source, migrations, reflected schema, and tests. Whether the same state is deployed is explicitly marked as an evidence gap.

## CRITICAL findings

### SBP-001 — Public owner-privileged views bypass tenant RLS

- **Severity:** CRITICAL
- **Confidence:** High for repository state; Medium-High for production until catalog grants/view options are queried.
- **Remediation status:** **REMEDIATED IN SOURCE — PENDING DEPLOYMENT.** `supabase/migrations/20260715000000_security_audit_hardening.sql:3-93` preflights all 12 named views, enables `security_invoker`, revokes `PUBLIC`/`anon`, and retains explicit authenticated/service-role reads. `test/security_database_hardening_contract_test.dart:23-58` locks the source contract. The migration has not been applied.
- **Impact statement:** An unauthenticated caller can likely read sensitive data across every tenant, including sales, attendance, inventory costs/suppliers, QSC evidence and notes, settings JSON, and payroll PIN hashes.
- **Repository evidence:**
  - `store_settings` is owned by `postgres`, selects `payroll_pin` and `settings_json`, and has no `security_invoker`: `supabase/schema.sql:11087-11096`.
  - It is granted to `anon`: `supabase/schema.sql:14675-14677`.
  - `v_store_daily_sales`, `v_store_attendance_summary`, `v_inventory_status`, and `v_brand_kpi` aggregate all direct stores without a caller/tenant predicate or invoker option: `supabase/migrations/20260405000012_store_type_classification.sql:52-87`, `:107-155`.
  - Their reflected grants include `anon`: `supabase/schema.sql:14711-14743`, `:14795-14803`.
  - QSC views expose photo URLs, notes, reviewer identities, scores, and issue status without invoker security: `supabase/migrations/20260507000002_qsc_v2_monitoring_views.sql:18-105`, `20260507000006_qsc_v2_office_read_model_views.sql:17-140`; reflected grants include `anon` at `supabase/schema.sql:14741-14773`.
  - Public-table default privileges also grant future views/tables to `anon`: `supabase/schema.sql:14833-14836`.
- **Attack prerequisites and realistic abuse path:** The caller needs only the public Supabase URL/key embedded in the client. They directly query the view through PostgREST; because the owner is privileged and `security_invoker` is absent, underlying table RLS is evaluated as the owner rather than the caller. The caller paginates all rows and brute-forces low-entropy payroll hashes offline.
- **Affected tenant, asset, and business impact:** All brands/stores; revenue, staff attendance, inventory cost/suppliers, operational QSC evidence, settings, and payroll privacy. Impact includes competitive intelligence, employee privacy breach, targeted fraud preparation, and cross-tenant confidentiality failure.
- **Recommended minimal remediation:**
  1. Inventory every view in exposed schemas with owner, ACL, and `reloptions`.
  2. Revoke all non-public business views from `PUBLIC` and `anon`.
  3. Set `security_invoker=true` for views intended to inherit base-table RLS; add explicit tenant predicates or security-barrier functions where aggregates cannot safely inherit RLS.
  4. Replace public default table privileges with opt-in grants. Do not change the physical `restaurants` Office contract.
- **Concrete verification/regression plan:** In a transaction or isolated test database, `SET ROLE anon` and assert permission denied/zero access for every non-public view. With JWT claims for tenant A/B, assert A cannot see B and vice versa. Add catalog assertions that every public-schema view is either explicitly allowlisted as public or has `security_invoker=true` and no anon grant. Include `store_settings`, all `v_qsc_*`, all `v_office_qsc_*`, `v_inventory_status`, `v_brand_kpi`, and store sales/attendance views.

## HIGH findings

### SBP-002 — A permissive audit policy exposes all audit logs to every authenticated role

- **Severity:** HIGH
- **Confidence:** High for reflected schema; Medium-High for current production.
- **Remediation status:** **REMEDIATED IN SOURCE — PENDING DEPLOYMENT.** The forward migration drops `audit_logs_authenticated_select` while retaining the scoped admin policy (`supabase/migrations/20260715000000_security_audit_hardening.sql:95-96`); the regression contract checks the effective source policy set. No live policy query or migration application was performed.
- **Repository evidence:** `audit_logs_authenticated_select` grants every authenticated user every row with `USING (true)`: `supabase/schema.sql:13213-13222`. The intended later policy scopes active admin-like roles by accessible stores but drops/recreates only `audit_logs_admin_read`, not the permissive sibling: `supabase/migrations/20260425000001_harden_audit_logs_scope_for_reports.sql:3-43`. The table includes actor, action, entity identifiers, arbitrary details, and time: `supabase/schema.sql:10130-10138`.
- **Attack prerequisites and realistic abuse path:** Any valid waiter/kitchen/cashier JWT directly selects `audit_logs`. PostgreSQL combines permissive policies with OR, so the `USING (true)` policy defeats the scoped policy. The caller exports cross-tenant entity IDs, payment/order actions, amounts, staff attribution, and mutation details.
- **Affected tenant, asset, and business impact:** All tenants; audit confidentiality and operational metadata. The leak aids resource enumeration, insider surveillance, fraud planning, and social engineering.
- **Recommended minimal remediation:** Drop `audit_logs_authenticated_select`; retain one policy requiring `users.is_active`, approved role, and accessible-store match. Avoid granting raw-table audit reads where a scoped RPC/view suffices.
- **Concrete verification/regression plan:** Test the **effective policy set**, not only migration text: low-privilege user gets zero/denied; store admin sees own accessible stores; brand admin sees its stores; inactive and cross-tenant admins see none; super-admin sees the intended global scope. Update `test/report_audit_access_contract_test.dart:8-31`, which currently only checks that the intended policy text exists.

### SBP-003 — Internal `SECURITY DEFINER` helpers are executable by anonymous callers

- **Severity:** HIGH
- **Confidence:** High for schema/migration state; Medium-High for production.
- **Remediation status:** **REMEDIATED IN SOURCE — PENDING DEPLOYMENT.** The forward migration conditionally revokes `PUBLIC`, `anon`, and `authenticated` from all seven named internal helpers, preserves service-role execution, and removes future public/authenticated default function execution (`supabase/migrations/20260715000000_security_audit_hardening.sql:98-130`). Targeted source contracts cover every signature; live catalog ACLs remain unverified.
- **Repository evidence:**
  - `refresh_user_claims(p_auth_user_id)` runs as definer, reads any profile, writes `auth.users.raw_app_meta_data`, and returns claims without validating the caller: `supabase/schema.sql:7101-7158`; it is granted to `anon` at `:14279-14281`.
  - `sync_all_store_access`, `sync_brand_store_access`, and `sync_user_store_access` run as definer and mutate access rows without caller authorization: `supabase/schema.sql:8075-8149`; anon grants are `:14363-14377`.
  - `refresh_qc_check_photo_summary` updates a caller-supplied QC check without caller authorization: `supabase/migrations/20260507000003_qsc_v2_rpc_extensions.sql:16-74`; reflected anon grant is `supabase/schema.sql:14273-14275`.
  - `recalculate_inventory_purchase_order_totals` accepts any order UUID and performs a definer update without caller checks: `supabase/schema.sql:6637-6662`.
  - New function defaults grant all functions to `anon` and `authenticated`: `supabase/schema.sql:14823-14826`.
  - The Photo Objet MISA enqueue helper is definer and explicitly granted to service-role but never revoked from `PUBLIC`, so PostgreSQL's default execution remains relevant: `supabase/migrations/20260630007000_photo_objet_raw_meinvoice_queue.sql:151-174`, `:280-324`.
- **Attack prerequisites and realistic abuse path:** An unauthenticated caller knows or enumerates public RPC names and supplies victim UUIDs where needed. They force all-user access synchronization for database load, refresh/inspect another user's claims, recompute QC/inventory state, or prematurely queue invoice work if the MISA foundation exists.
- **Affected tenant, asset, and business impact:** All tenants; access mappings, Auth metadata, QC records, inventory purchase totals, database availability, and invoice queues. Effects range from metadata disclosure and audit noise to unauthorized state transitions and targeted DoS.
- **Recommended minimal remediation:** Revoke execute on all public-schema functions from `PUBLIC`, `anon`, and `authenticated` by default; explicitly grant only reviewed API RPCs. Move trigger/internal helpers to an unexposed schema. Add active caller/role/tenant checks to any helper that must remain callable. Keep a fixed/empty `search_path` and fully qualify objects.
- **Concrete verification/regression plan:** Catalog-test every `SECURITY DEFINER` function for owner, `proconfig`, ACL, and exposure. Under `SET ROLE anon`, assert every internal helper is denied. Under tenant JWTs, fuzz UUID parameters across tenants and assert no rows change. Confirm triggers still work without direct API execute grants.

### SBP-004 — Deactivated users can retain server-side authority; inactive super-admin can provision a replacement account

- **Severity:** HIGH
- **Confidence:** High for code path; runtime window depends on Supabase session settings.
- **Remediation status:** **REMEDIATED IN SOURCE — PENDING DEPLOYMENT.** Canonical identity helpers and attendance/QC/payment-proof Storage policies now require an active profile, including removal of the older broad QSC policy (`supabase/migrations/20260715000000_security_audit_hardening.sql:132-327`). `create_staff_user` selects and rejects inactive callers before role checks (`supabase/functions/create_staff_user/index.ts:61-94`). Source contracts cover both paths. Auth-session ban/revocation behavior remains a separate operational control.
- **Repository evidence:** Legacy identity helpers resolve store/role/super-admin without `is_active`: `supabase/schema.sql:5398-5427`, `:5449-5458`, `:5478-5488`. Many RLS policies depend on them, including orders, payments, restaurants, settings, and users (`supabase/schema.sql:13202-13209`, `:13469-13492`, `:13575-13578`, `:13647-13650`). Attendance/QSC storage policies also omit active checks (`supabase/migrations/20260408000000_security_hardening.sql:140-203`), and payment-proof storage's super-admin branch omits it (`20260414000012_payment_proof_and_wt09_access.sql:13-47`). Deactivation updates only the public profile and refreshes claims (`20260414000013_contract_store_naming_active_paths.sql:160-199`). The Flutter client signs out inactive users, but that is client-side (`lib/features/auth/auth_provider.dart:45-57`). `create_staff_user` selects no `is_active`, accepts a super-admin role, and uses service-role provisioning (`supabase/functions/create_staff_user/index.ts:50-87`, `:128-156`, `:251-282`).
- **Attack prerequisites and realistic abuse path:** A formerly privileged user retains a usable JWT/refresh session after `public.users.is_active=false`. Direct REST/RPC/Storage calls still satisfy legacy helpers. An inactive super-admin calls `create_staff_user`; active-filtered accessible-store sets are empty, but super-admin bypass branches permit selecting a target store and creating a new admin-like user.
- **Affected tenant, asset, and business impact:** Potentially all tenants for super-admin, otherwise the former tenant/store. Assets include orders, payments, staff, configuration, Storage objects, and role mappings. Deactivation does not reliably terminate authority.
- **Recommended minimal remediation:** Add `u.is_active=true` to every identity helper and direct role lookup; make Edge Functions require active caller profiles; use a single canonical active-user authorization helper. On deactivation, ban/revoke the Supabase Auth user/session in addition to clearing claims. Review Storage policies independently of Flutter behavior.
- **Concrete verification/regression plan:** Obtain a test JWT, deactivate the corresponding profile, and assert denial across representative base-table reads/writes, exposed RPCs, Storage list/download/upload, and `create_staff_user`. Include inactive super-admin, brand admin, store admin, and cashier. Verify reactivation is explicit and audited.

## CONFIRMED integration constraints

### SBP-005 — Moers credentialed browser collection is an accepted vendor integration constraint

- **Severity:** CONFIRMED — not a vulnerability.
- **Confidence:** High for the repository behavior; vendor API unavailability is user-confirmed operational context.
- **Classification status:** Moers does not provide an API, so the scheduled integration must use browser automation with vendor-issued IDs and passwords. This required integration method is not a security finding and requires no HTTPS-only source rewrite.
- **Repository evidence:** Puppeteer opens the Moers login page, enters the supplied credentials, loads the daily report, parses the result, and ingests normalized rows (`scripts/pull_moers_sales.js:540-623`). The scheduled workflow maps each password from GitHub Secrets only onto the collector steps that consume it (`.github/workflows/photo_objet_sales_collect.yml:49-85`).
- **Operational boundary:** This is not a direct Moers database or API connection. It is a browser session against the vendor portal, used because no supported API is available.
- **Affected tenant and asset:** Photo Objet stores and their Moers-derived sales data. The integration is required business functionality, not an optional insecure substitute for an available API.
- **Accepted controls:** Keep passwords in GitHub Secrets, do not log credentials, retain narrow workflow permissions and step-scoped secret mappings, validate store mappings, preserve immutable source hashes, and monitor collection health.
- **Verification plan:** Continue preflight, mapping, parser, source-hash, interval, and health-ledger tests. Verify successful credentialed collection only through the approved operational workflow without printing credentials or raw secret-bearing payloads.

## HIGH findings (continued)

### SBP-006 — Mutable GitHub Action tags run inside jobs containing broad production secrets

- **Severity:** HIGH
- **Confidence:** High for workflow source; organization-level action policies are unknown.
- **Remediation status:** **REMEDIATED IN SOURCE — PENDING DEPLOYMENT.** All 14 action uses across the five reviewed workflows are pinned to tag-resolved 40-character SHAs with version comments. Supabase, Moers, and Vercel secrets are mapped only on the steps that consume them. `scripts/tests/workflow_security.test.js:35-64` rejects mutable refs, missing version comments, and workflow/job-wide secret mappings.
- **Repository evidence:** Collection secrets are job-wide at `.github/workflows/photo_objet_sales_collect.yml:22-54`, while `actions/checkout@v4`, `actions/setup-node@v4`, and `actions/github-script@v7` run at `:55-87`. Health gives service-role credentials to the whole job and uses three `github-script@v7` steps (`photo_objet_sales_health.yml:23-52`, `:83-113`). Release proof gives service-role/Vercel credentials to the whole job and uses mutable action tags (`photo_objet_release_proof.yml:17-26`, `:52-60`, `:145-149`). Backfill follows the same pattern (`photo_objet_sales_backfill.yml:27-67`).
- **Attack prerequisites and realistic abuse path:** An upstream action repository/tag is compromised or a tag is moved. The action runs within a secret-bearing job, reads environment variables, and exfiltrates service-role/vendor/Vercel credentials or tampers with evidence.
- **Affected tenant, asset, and business impact:** All tenants where service-role is accepted; vendor accounts and production deployment evidence. A stolen service-role key bypasses RLS.
- **Recommended minimal remediation:** Pin every action to a reviewed full commit SHA; enforce a repository/organization policy requiring full SHA pins. Move each secret to only the step that requires it, split untrusted setup/actions from secret-bearing runtime jobs, use protected GitHub environments and short-lived/OIDC credentials where supported.
- **Concrete verification/regression plan:** CI linter rejects `uses:` values not ending in a 40-hex SHA. A workflow test confirms checkout/setup/action steps do not receive production secrets. Review environment approvals, branch restrictions, and outbound network telemetry in GitHub settings.

### SBP-007 — Historical WeTax functions retain fail-open cron auth and overly broad cashier authorization

- **Severity:** HIGH **if deployed**; otherwise residual-code/decommissioning risk.
- **Confidence:** High for source behavior; Low for present deployment reachability.
- **Remediation status:** **DEFERRED BY USER — WETAX PRESERVED.** No WeTax behavior was removed or tightened in this change. The only WeTax edits are the exact dependency pins described under SBP-013.
- **Repository evidence:** The authoritative rule says WeTax is historical (`CLAUDE.md:21-23`, `:51-56`), but Flutter still invokes `wetax-onboarding` for company lookup (`lib/core/services/einvoice_service.dart:3-8`). Dispatcher, poller, and daily close reject a bad bearer token only when `CRON_SECRET` is non-empty; an absent secret therefore allows service-role work (`supabase/functions/wetax-dispatcher/index.ts:249-260`, `wetax-poller/index.ts:98-118`, `wetax-daily-close/index.ts:73-83`). Onboarding authorizes any active cashier/admin-like role and then exposes company lookup, seller registration, shop registration, seller info, and commons refresh under the same gate (`wetax-onboarding/index.ts:217-275`). Polling stores raw vendor bodies (`wetax-poller/index.ts:88-95`, `:156-173`).
- **Attack prerequisites and realistic abuse path:** At least one historical function remains deployed. For batch functions, `CRON_SECRET` is absent; an internet caller invokes a service-role worker. For onboarding, an active cashier directly calls seller/shop registration operations not exposed by normal UI. Vendor responses may also be retained with unnecessary sensitive content.
- **Affected tenant, asset, and business impact:** Tax entities and stores reachable by the historical credential set; vendor tokens/credentials, registration state, invoice jobs/events, buyer/vendor response data. Impact includes invoice control-plane mutation, legal/tax processing errors, unexpected vendor calls, and data retention exposure.
- **Recommended minimal remediation:** None in this pass. The user explicitly requires WeTax to remain preserved. If that decision changes, re-open the authorization, missing-secret, schema, replay/rate-limit, redaction, and retention review before changing runtime behavior.
- **Concrete verification/regression plan:** No WeTax runtime test was added or executed in this pass. A future authorized review should compare deployed function hashes without retrieving secret values and test missing/wrong secrets, cashier scope, cross-tenant identifiers, replay, oversized payloads, and vendor error redaction.

## MEDIUM findings

### SBP-008 — Partial and split payments lack a request idempotency key

- **Severity:** MEDIUM
- **Confidence:** High.
- **Remediation status:** **REMEDIATED IN SOURCE — PENDING STAGED DEPLOYMENT.** A private forced-RLS `payment_attempts` ledger and unique `(order_id, attempt_id)` key serialize duplicate attempts and return the original payment on an exact replay; mismatched caller or parameters fail. Expand explicitly preserves the authenticated four-argument RPC. Flutter persists a hashed scope and attempt UUID in SharedPreferences before the first call, reuses it after provider/browser/app recreation, retains all split IDs until the full split succeeds, and bounds stale metadata. An isolated PostgreSQL test ran two concurrent identical attempts and observed one payment and one invoice job; 100 concurrent client-store lookups converged on one ID. Production has not been changed.
- **Baseline evidence at assessed commit:** The RPC accepted only order, store, amount, and method (`supabase/migrations/20260428000002_vat_pricing_mode.sql:17-22`). It locked the order, summed prior payments, prevented overpayment, then unconditionally inserted a new row (`:94-110`, `:248-288`). The Flutter split flow called the RPC sequentially for each part without an attempt identifier. A historical unique-per-order constraint was deliberately removed for split payments (`supabase/migrations/20260412150420_phase_2_step_5_existing_table_extensions.sql:104`).
- **Attack prerequisites and realistic abuse path:** A partial split commits, but the response is lost or the user retries before the order is fully paid. The same portion is inserted again if total remains within the order amount. Deliberate direct callers can similarly distort payment-method allocation while respecting the total cap.
- **Affected tenant, asset, and business impact:** The active store/order; payment rows, method reconciliation, cash/card reporting, and customer dispute evidence. Total revenue is capped, so this is below HIGH.
- **Recommended minimal remediation:** Add a client-generated immutable `payment_attempt_id`/idempotency key, unique per order/attempt. On conflict, return the original payment. Consider an atomic server-side split RPC accepting the complete validated split set.
- **Concrete verification/regression plan:** Retain the isolated exact-replay/concurrency/mismatch coverage and run the same checks after Expand under representative production-like roles. Smoke old and new clients separately, then simulate response loss for first/middle/final split and verify one payment/invoice job per attempt.

### SBP-009 — Staff provisioning can report success after claim/access synchronization failure and still permits new legacy `admin`

- **Severity:** MEDIUM
- **Confidence:** High.
- **Remediation status:** **REMEDIATED IN SOURCE — PENDING FUNCTION DEPLOYMENT.** New `admin` targets are rejected, every post-Auth failure invokes compensating cleanup, sync/claim errors are fatal, and returned claims must match role, primary store, and requested accessible-store membership before success (`supabase/functions/create_staff_user/index.ts:30-58`, `:146-164`, `:309-455`). Rollback failure is surfaced instead of reporting successful provisioning.
- **Baseline evidence at assessed commit:** The authoritative Stage 1 maintenance contract says new staff creation rejects `admin` and must roll back unless access synchronization, claim refresh, and post-refresh store-scope verification all succeed: `/Users/andreahn/Documents/restaurant-ops-vault/GLOBOSVN POS/Stage 1/stage1_scope_v1.4.md:25`. The assessed commit accepted legacy `admin`, logged sync/claim failures without making them fatal, and had no post-refresh requested-store assertion. The working-tree remediation is cited above.
- **Attack prerequisites and realistic abuse path:** An authorized admin provisions a user while sync/claim refresh fails due transient DB/config error. A login-capable account is left with inconsistent or stale claims and the operator is told provisioning succeeded. Higher-level admins can also continue creating the superseded `admin` role, increasing mixed authorization semantics.
- **Affected tenant, asset, and business impact:** Target store/brand; staff identity, authorization claims, and operational availability. The likely effect is inconsistent access or delayed privilege cleanup rather than direct external escalation.
- **Recommended minimal remediation:** Reject new legacy `admin`; make sync/claim refresh mandatory. If any post-create step fails, roll back access/profile/Auth user. Read back claims and verify active role, primary store, and requested accessible-store membership before success.
- **Concrete verification/regression plan:** Inject failure at Auth create, profile insert, store access, brand access, inherited sync, claim refresh, and postcondition readback. Assert no orphan Auth/profile/access row remains and no success response is returned. Add a contract test rejecting legacy `admin`.

### SBP-010 — Payment-proof bearer URLs last ten years and offline evidence is stored unencrypted

- **Severity:** MEDIUM
- **Confidence:** High.
- **Remediation status:** **PARTIALLY REMEDIATED IN SOURCE — PENDING STAGED DEPLOYMENT AND LEGACY CLEANUP.** New uploads store a validated private object path and never call `createSignedUrl` or create a new offline copy. Existing queue entries are parsed defensively; missing, malformed, outside-directory, unauthorized, upload-failed, or attach-failed entries remain queued. The file and record are removed only after idempotent upload plus `attach_payment_proof_v2` succeeds. Payment detail downloads object bytes with the active Storage JWT/RLS and retains a validated legacy Supabase URL fallback during Expand. Previously issued ten-year signed URLs remain an operational residual risk.
- **Baseline evidence at assessed commit:** The client minted a ten-year signed URL, persisted it through `attach_payment_proof`, and copied failed uploads into application documents with queue metadata in SharedPreferences. The original attach RPC wrote that URL into audit details (`supabase/migrations/20260414000012_payment_proof_and_wt09_access.sql:172-189`). The working-tree remediation is cited above.
- **Attack prerequisites and realistic abuse path:** An attacker obtains a signed URL through a screenshot, UI/API/audit leak, logs, or device backup, or reads the app's documents on a shared/rooted/compromised device. The bearer URL stays valid for years without rechecking current tenant authorization.
- **Affected tenant, asset, and business impact:** Individual payment/store; payment-evidence confidentiality and possible customer/merchant PII. Long lifetime greatly increases leak persistence.
- **Recommended minimal remediation:** Deploy the prepared object-path/JWT read flow after Expand, migrate legacy queued files without premature deletion, and execute the separately authorized copy → size/hash verify → DB path update → authenticated-read verify → old-object delete runbook in bounded canaries. Do not use project-wide JWT rotation as URL cleanup.
- **Concrete verification/regression plan:** Unit tests cover missing/invalid/cross-store/success/fallback reads and queue retention/deletion boundaries. After deployment, canary an authenticated same-store read and cross-store denial before any legacy URL/object mutation; then verify size/hash and rollback behavior per batch.

### SBP-011 — Canonical `main` cannot reproduce the authoritative MISA integration

- **Severity:** MEDIUM security-assurance gap; availability/operational impact may be HIGH during restore/deploy.
- **Confidence:** High for Git/source state; Low for deployed state.
- **Remediation status:** **ACCEPTED CURRENT STATE — MISA NOT IMPLEMENTED.** The user confirmed MISA is not implemented and excluded it from this improvement pass. No MISA worker, migration, credential path, or portal host was invented.
- **Repository evidence:** MISA is authoritative and async (`CLAUDE.md:21-23`, `:51-56`, `:93-98`), and the current Stage 1 maintenance contract explicitly names `public.meinvoice_jobs` plus `supabase/functions/meinvoice-dispatcher` as the active first-issuance path: `/Users/andreahn/Documents/restaurant-ops-vault/GLOBOSVN POS/Stage 1/stage1_scope_v1.4.md:25`. Current `main` migration `supabase/migrations/20260630007000_photo_objet_raw_meinvoice_queue.sql:1-14`, `:151-208` immediately alters/references `meinvoice_jobs`, `meinvoice_tax_entity_config`, and `meinvoice_payment_method_label`, but no tracked migration in current `main` creates those MISA objects. `supabase/functions/meinvoice-dispatcher/index.ts` is absent. Git history places the foundation/dispatcher only on unmerged `codex/meinvoice-misa-main`. Meanwhile the current Flutter service still invokes historical WeTax lookup and reads legacy `einvoice_jobs` (`lib/core/services/einvoice_service.dart:3-8`, `lib/core/services/payment_service.dart:115-122`).
- **Attack prerequisites and realistic abuse path:** No direct remote exploit is required. During restore, migration, incident response, or worker redeploy, operators must depend on out-of-band production state or an unmerged branch. A stale or vulnerable worker/config can remain deployed without canonical review or reproducible verification.
- **Affected tenant, asset, and business impact:** All invoice-enabled tenants; MISA credentials/tokens, legal invoice state, async failure isolation, and disaster recovery. Security patches and credential-source constraints cannot be proven from canonical source.
- **Recommended minimal remediation:** Reconcile the reviewed MISA foundation, adapter, dispatcher, tests, and migrations into the canonical production branch; do not deploy during this report task. Establish exact deployed-source hashes and a clean migration replay from zero. Keep WeTax code outside active runtime.
- **Concrete verification/regression plan:** Fresh isolated database migration replay must succeed without manual objects. Build/test the canonical dispatcher, compare deployed hashes to main, verify only approved secret source names exist, and run mocked MISA tests for auth, token cache, response schema, retry, replay/idempotency, timeout, failure isolation, redaction, and lookup URL validation.

### SBP-012 — Bulk Auth reset script collapses all accounts to one fixed password without a guard

- **Severity:** MEDIUM
- **Confidence:** High.
- **Remediation status:** **REMEDIATED IN SOURCE.** The script contains no Supabase client, enumeration, password, or mutation path; it emits `BULK_AUTH_PASSWORD_RESET_DISABLED` and exits non-zero (`scripts/reset_all_auth_passwords.js:1-12`). A Node regression test verifies the quarantine and absence of Auth-admin calls (`scripts/tests/reset_all_auth_passwords.test.js:1-20`).
- **Baseline evidence at assessed commit:** `scripts/reset_all_auth_passwords.js` used service-role Auth admin and a fixed `NEW_PASSWORD` literal, enumerated every Auth user, reset each account, and logged identifiers/results without a dry run, project allowlist, bounded selection, or production guard. The working-tree file is now the non-mutating quarantine cited above.
- **Attack prerequisites and realistic abuse path:** An operator or attacker already holding the service-role environment runs the script accidentally or maliciously. Every account receives the same known repository-defined password, and staff identifiers are emitted to logs.
- **Affected tenant, asset, and business impact:** All Auth users/tenants; authentication confidentiality, availability, and privacy. This does not independently expose service-role credentials, so it is not rated HIGH.
- **Recommended minimal remediation:** Remove/quarantine from normal tooling or require explicit project-ref/environment allowlist, `--dry-run` default, typed confirmation, bounded user selection, unique random temporary credentials, forced reset, and redacted output. Prefer Supabase recovery/admin workflows.
- **Concrete verification/regression plan:** With a fake Auth client, default invocation changes zero users; wrong project/confirmation fails; bounded selection affects only intended test users; logs contain no emails/passwords; generated credentials are unique and never printed.

### SBP-013 — Edge Function imports use a mutable major-version URL

- **Severity:** MEDIUM
- **Confidence:** High.
- **Remediation status:** **REMEDIATED IN SOURCE — PENDING FUNCTION DEPLOYMENT.** All seven assessed Edge Functions now import exact Supabase JS `2.110.2`, matching the repository's exact Node dependency. Non-WeTax changed Functions pass `deno check`; the full check still finds pre-existing WeTax typing errors that were excluded from this pass.
- **Baseline evidence at assessed commit:** Every assessed Edge Function imported mutable `https://esm.sh/@supabase/supabase-js@2`, which could resolve to different patch code on a future deploy. The working-tree imports are exact-pinned as cited above.
- **Attack prerequisites and realistic abuse path:** A future deployment resolves a malicious/compromised or behaviorally incompatible upstream `@2` package. The imported code executes inside a service-role function and can read environment secrets or alter requests.
- **Affected tenant, asset, and business impact:** Potentially all tenants and backend secrets on the redeployed function. The upstream/deployment precondition lowers likelihood.
- **Recommended minimal remediation:** Pin an exact reviewed Supabase JS version and lock/vendor dependencies using the supported Deno/Supabase dependency mechanism. Add automated update review rather than mutable major resolution.
- **Concrete verification/regression plan:** CI rejects non-exact remote imports, builds functions without resolving a moving tag, records dependency integrity/version, and tests an intentional dependency bump separately.

## LOW findings

### SBP-014 — Payroll PIN verification is low-entropy, unsalted, and fails open on fetch errors

- **Severity:** LOW standalone; its impact increases sharply when combined with SBP-001.
- **Confidence:** High.
- **Remediation status:** **REMEDIATED IN SOURCE — PENDING STAGED DEPLOYMENT.** Expand stores bcrypt in a new non-readable verifier column while temporarily preserving the legacy SHA-256 value/read/set path so old clients continue working. The new Flutter client uses only `set_payroll_pin_v2`, `clear_payroll_pin_v2`, status, and server verification. Five failures lock the actor/store for 15 minutes, success resets the window, a successful legacy check adds bcrypt without removing compatibility, and inactive/cross-store actors fail. The later Contract masks/revokes the legacy path. These paths passed isolated PostgreSQL tests; production is unchanged.
- **Baseline evidence at assessed commit:** The client hashed the PIN with raw SHA-256, returned `null` on fetch errors, treated a missing hash as successful verification, and exposed payroll metrics before a reliable lock decision. The working tree moves verification/rate limiting server-side, treats unknown PIN state as locked, verifies before fetching preview data, and hides metrics until unlock.
- **Attack prerequisites and realistic abuse path:** The attacker is already at an authorized admin UI/device or obtains the hash through SBP-001. They force a settings read error to bypass the UI lock or brute-force the 10,000-value PIN space offline.
- **Affected tenant, asset, and business impact:** One store's payroll preview UI privacy. Backend payroll calculation authorization remains a separate control, so this is defense in depth rather than primary authorization.
- **Recommended minimal remediation:** Never expose the verifier hash; verify server-side with a slow password hash, rate limit, and audit failures. Fail closed on missing/error unless no PIN is explicitly configured by an authenticated admin.
- **Concrete verification/regression plan:** Network/permission errors keep payroll locked; wrong PINs are rate-limited; no hash is returned to clients; tenant/cross-store attempts fail; explicit no-PIN configuration remains distinguishable from an error.

### SBP-015 — Vendor-provided lookup URLs are opened without scheme/host validation

- **Severity:** LOW
- **Confidence:** Medium.
- **Remediation status:** **REMEDIATED IN SOURCE FOR CURRENT WETAX HOSTS — PENDING APP DEPLOYMENT.** Both launch points use a shared validator that permits only HTTPS `wetax.com.vn` or its subdomains, rejects userinfo and non-443 ports, and hides/rejects unsafe links (`lib/core/utils/vendor_portal_url.dart:1-20`; `lib/features/payment/payment_detail_screen.dart:414-423`; `lib/features/payment/einvoice_status_badge.dart:106-110`). MISA is unimplemented; its authoritative host allowlist must be added only with that implementation.
- **Baseline evidence at assessed commit:** Payment detail accepted any parseable URI and the invoice badge directly launched `job.lookupUrl`. The value originates in invoice job/vendor state. The current working tree routes both launches through the shared validator cited above.
- **Attack prerequisites and realistic abuse path:** An attacker compromises the vendor response, invoice worker, or database job row and supplies a phishing HTTPS host or custom scheme. A staff user taps it, leaving the trusted POS context for attacker-controlled content/application handling.
- **Affected tenant, asset, and business impact:** The staff user/device and invoice workflow; phishing, unsafe scheme invocation, or credential capture. Strong upstream compromise is required.
- **Recommended minimal remediation:** Deploy the current WeTax HTTPS/host validator with the compatible Flutter build. Do not add speculative MISA hosts; extend the allowlist only from the authoritative MISA contract when implementation begins.
- **Concrete verification/regression plan:** Keep unit coverage for valid WeTax hosts and rejection of `http`, custom schemes, lookalikes, userinfo, IP literals, malformed input, and invalid ports. Add MISA cases only when its authoritative portal hosts exist.

## Category coverage summary

| Category | Result |
|---|---|
| Secrets and configuration | No committed high-risk credential confirmed; service-role absent from Flutter. Moers passwords are required vendor credentials and are step-scoped from GitHub Secrets. The destructive bulk Auth reset is quarantined and Edge imports are exact-pinned in source. |
| Authentication and authorization | JWT verification exists. Inactive-user and staff-provisioning hardening is present in source; deployment and stale-session/failure-injection validation remain pending. |
| Multi-tenant isolation | Base-table RLS is extensive; exposed owner-privileged views and audit policy create critical/high bypasses. |
| PostgreSQL and RPC security | Many RPCs use `SECURITY DEFINER` with fixed search paths and actor checks; internal functions/default grants remain overexposed. No unsafe attacker-controlled dynamic SQL was confirmed in active payment/auth paths. |
| Edge Functions | Staff/settlement functions authenticate; provisioning rollback/claim postconditions and exact imports are now present in source. WeTax behavior is intentionally preserved/deferred. No general CORS wildcard was found in `create_staff_user`; CORS is configured through an origin list. |
| Payment and invoice integrity | Server-side totals, tenant/role checks, row lock, atomic completion, overpayment prevention, UUIDv7, async invoice creation, and retry idempotency are present in source. The new idempotency boundary remains unapplied; MISA is acknowledged as unimplemented. |
| External integrations | Moers credentialed browser collection is an accepted vendor constraint because no API is provided. WeTax is preserved by user direction. MISA is not implemented and was not assessed as active. |
| Flutter client | No embedded service-role secret confirmed. New payment-proof capture stores paths without durable URLs/local queue copies, payroll PIN errors fail closed, and current WeTax portal URLs are allowlisted. Legacy proof URLs remain an operational residual. |
| Dependencies and CI | Node audit found zero known vulnerabilities and lockfiles exist. Action and Edge dependencies are immutable/exact-pinned in source; no CodeQL/Semgrep workflow is present. |
| Auditability and abuse resistance | Payment/admin mutations are widely audited and Photo ledgers/alerts are strong. Raw audit logs are over-readable, audit-table immutability against service-role is unverified, and no repository-defined app rate limiter exists. |

## Confirmed security controls

| Status | Control | Evidence |
|---|---|---|
| CONFIRMED | `process_payment` requires active cashier/admin-like actor and accessible store | `supabase/migrations/20260428000002_vat_pricing_mode.sql:61-82` |
| CONFIRMED | Order lock, completed/cancelled rejection, server recomputation, and overpayment prevention | `20260428000002_vat_pricing_mode.sql:94-110`, `:248-268` |
| CONFIRMED | Payment/order/table/inventory/invoice job/audit operations share one Postgres transaction | `20260428000002_vat_pricing_mode.sql:270-420` |
| CONFIRMED | UUIDv7 is generated and schema-constrained | `20260428000002_vat_pricing_mode.sql:361-390`; `20260412145159_phase_2_step_4_wetax_tables.sql:198-225` |
| CONFIRMED | Payment is independent of synchronous vendor availability; invoice work is queued | `CLAUDE.md:51-56`; `20260428000002_vat_pricing_mode.sql:337-390` |
| CONFIRMED | Core tables broadly enable RLS and newer accessible-store helpers check active access | `supabase/schema.sql:13206-13662`; `user_accessible_stores` in `:10017-10087` |
| CONFIRMED | Payment-proof bucket is private, type/size limited, and path scoped | `supabase/migrations/20260414000012_payment_proof_and_wt09_access.sql:3-47` |
| CONFIRMED | Settlement functions fail closed if `CRON_SECRET` is missing and remain separate domains | `supabase/functions/generate-settlement/index.ts:4-16`; `generate_delivery_settlement/index.ts:18-29`; `CLAUDE.md:57-59` |
| CONFIRMED | Photo collector has immutable identity/hash controls, bounded backfill, health alerts, and exact-main proof | `scripts/pull_moers_sales.js:500-537`; `.github/workflows/photo_objet_sales_backfill.yml:3-31`; `photo_objet_release_proof.yml:28-130` |
| CONFIRMED | Moers credentialed browser collection is the approved integration path because the vendor provides no API; passwords remain secret-scoped to collector steps | `scripts/pull_moers_sales.js:540-623`; `.github/workflows/photo_objet_sales_collect.yml:49-85` |
| CONFIRMED | GitHub token permissions are explicitly narrow in all reviewed workflows | `.github/workflows/photo_objet_sales_collect.yml:14-16`; `photo_objet_release_proof.yml:9-12` |
| CONFIRMED | Node dependencies are exact-pinned; Flutter git dependency resolves to a commit | `scripts/package.json:5-16`; `pubspec.lock:1452-1460` |
| CONFIRMED | No Flutter reference to service-role variables was found; client loads only URL and anon key | `lib/core/constants/app_constants.dart:9-50`; `lib/main.dart:15-30` |
| CONFIRMED | Repository secret scan, Node tests/audit, Flutter analysis, and Flutter tests passed | Commands recorded below |
| CONFIRMED | Office `restaurants` coupling was preserved; no finding requires breaking it | `CLAUDE.md:61-80` |
| SOURCE ONLY | SBP-001–SBP-004 database and inactive-user remediations are encoded in one forward transactional migration with source-contract coverage | `supabase/migrations/20260715000000_security_audit_hardening.sql`; `test/security_database_hardening_contract_test.dart`; `test/create_staff_user_active_caller_contract_test.dart` |
| SOURCE ONLY | SBP-006 workflows pin action commits and keep secrets out of workflow/job-wide environments | `.github/workflows/photo_objet_*.yml`; `scripts/tests/workflow_security.test.js` |
| SOURCE ONLY / LOCALLY VERIFIED | SBP-008 payment retries use a private idempotency ledger and restart-persistent, bounded attempt metadata; old/new RPCs coexist in Expand | `supabase/migrations/20260715020000_security_expand_compat.sql`; `lib/core/services/payment_attempt_store.dart`; `test/security_expand_sql_test.sh` |
| SOURCE ONLY | SBP-009 provisioning is fail-closed with compensating rollback and claims postconditions; new legacy `admin` is rejected | `supabase/functions/create_staff_user/index.ts:30-58`, `:146-164`, `:309-455` |
| SOURCE ONLY / LOCALLY VERIFIED | SBP-010 new proofs use v2 object paths/JWT downloads; legacy queue records and files survive every failure before attach success | `20260715020000_security_expand_compat.sql`; `lib/core/services/payment_proof_service.dart`; `test/payment_proof_migration_test.dart` |
| SOURCE ONLY | SBP-012 bulk Auth reset cannot enumerate or mutate users | `scripts/reset_all_auth_passwords.js:1-12`; `scripts/tests/reset_all_auth_passwords.test.js` |
| SOURCE ONLY | SBP-013 all assessed Edge Functions exact-pin Supabase JS `2.110.2` | `supabase/functions/*/index.ts`; `test/security_followup_hardening_contract_test.dart` |
| SOURCE ONLY / LOCALLY VERIFIED | SBP-014 uses private bcrypt plus Expand-only legacy SHA compatibility, lockout/audit, and fail-closed client handling | `20260715020000_security_expand_compat.sql`; `lib/core/services/pin_service.dart`; `test/security_expand_sql_test.sh` |
| SOURCE ONLY | SBP-015 external invoice links are validated against the current HTTPS WeTax portal boundary | `lib/core/utils/vendor_portal_url.dart`; `test/vendor_portal_url_test.dart` |

## Unverified assumptions and evidence gaps

- Production DB may differ from `supabase/schema.sql` and tracked migrations through manual changes or unapplied files. No catalog query was made.
- Neither new security hardening migration has been applied, and the Flutter/Edge Function/workflow changes have not been deployed; every source remediation remains a production risk until coordinated deployment and runtime verification.
- Moers API availability and portal transport are vendor-controlled. The user-confirmed integration contract requires the existing credentialed browser collector, which is recorded as an accepted constraint rather than a vulnerability.
- The reflected schema predates July migrations; later migration files were analyzed for forward state, but a complete live effective schema was not available.
- MISA is user-confirmed as unimplemented. Credential sources, token caching, polling/webhook trust, response validation, retry/idempotency, SSRF, rate limits, payload retention, and portal hosts must be assessed when implementation begins.
- WeTax is intentionally preserved and SBP-007 is deferred; no claim is made that its auth/authorization observations are remediated.
- Previously issued payment-proof signed URLs may remain valid for their original lifetime. Revocation/object rotation and legacy row cleanup require a separate authorized operational procedure.
- The idempotency ledger, PIN rate limiter, proof path validation, old/new grants, Contract, and emergency regrant passed in a disposable local PostgreSQL database, including concurrent duplicate payment calls. This is not production evidence and used a minimal test implementation for the pre-existing four-argument payment body.
- Supabase Auth dashboard controls—session revocation, JWT lifetime, MFA, CAPTCHA, password policy, and brute-force protections—are not versioned here.
- Edge Function deployment names, JWT verification flags, secret presence, and deployed hashes were not retrieved.
- GitHub organization/repository action allowlists, required-SHA policies, environment reviewers, workflow enablement, and current secret scopes are not visible in YAML.
- Audit-log retention, immutability against service-role, external SIEM export, alert ownership, and incident-response procedures are not documented in active repository sources.
- No real device was available to validate OS backup/encryption behavior for application documents and SharedPreferences.

## Top attack paths

Paths 1–5 and 7 are closed by the current source changes but remain residual production paths until those changes are reviewed, applied/deployed, and verified. Path 6 is explicitly deferred because WeTax must remain available.

1. Anonymous Data API caller → owner-privileged view → bulk all-tenant data and payroll hash exfiltration (SBP-001).
2. Anonymous RPC caller → internal `SECURITY DEFINER` helper → unauthorized maintenance/state mutation or database load (SBP-003).
3. Deactivated privileged JWT → legacy RLS/Storage helper → continued access; inactive super-admin → new privileged staff account (SBP-004).
4. Mutable GitHub Action compromise → job-wide production/vendor secrets → RLS bypass and production tampering (SBP-006).
5. Any staff JWT → permissive audit policy → cross-tenant mutation intelligence (SBP-002).
6. Residual WeTax endpoint with missing secret/broad cashier role → service-role/vendor control-plane operations (SBP-007, user-deferred).
7. Lost partial-payment response → duplicate retry; the source idempotency ledger deduplicates it, but production remains exposed until migration/app deployment (SBP-008).
8. Leaked legacy payment-proof bearer URL → long-lived evidence access until an authorized operational cleanup invalidates it (SBP-010 residual).

## Priority Fix List

1. **SBP-001:** Source remediation exists; independently review, apply the migration, then run anon/cross-tenant catalog and runtime tests.
2. **SBP-003:** Source remediation exists; apply the migration and verify every named helper/default ACL in the live catalog.
3. **SBP-002:** Source remediation exists; apply it and test the complete effective audit policy set under representative roles.
4. **SBP-004:** Source remediation exists; deploy it, test stale inactive sessions across RLS/Storage/Function paths, and implement Auth-session ban/revocation.
5. **SBP-006:** Source remediation exists; merge/deploy pinned workflows, review GitHub environment protections, and prefer short-lived credentials where possible.
6. **SBP-008/SBP-010/SBP-014:** Apply Security Audit and Expand one at a time, smoke the old client, then deploy the compatible Flutter build and fully refresh terminals. Do not promote Contract yet.
7. **SBP-009/SBP-013:** After the compatible client is cut over, deploy the exact-pinned strict `create_staff_user`, run failure-injection rollback/claim tests, and compare the deployed hash/imports with source.
8. **Contract / SBP-010 residual:** Observe one full business cycle, satisfy the Contract preflight in a separate release, and later run legacy URL cleanup as a bounded copy/size/hash/authenticated-read/delete operation without logging bearer values.
9. **SBP-012:** Merge the quarantined reset script and retain only the approved single-user recovery workflow.
10. **SBP-015:** Deploy the shared WeTax URL validator; add MISA hosts only from an authoritative contract when MISA implementation begins.
11. **SBP-007/SBP-011:** No implementation action in this pass: WeTax is preserved by user direction and MISA is confirmed unimplemented. Reassess when either scope decision changes.

## Commands and checks executed

- Read `~/.claude/CLAUDE.md`, project `CLAUDE.md`, `README.md`, authoritative repository scope/architecture references, and the requested security skills before assessment.
- Used `git status`, `git branch --show-current`, `git rev-parse`, `git log`, `git show`, `git branch -a --contains`, and `git merge-base --is-ancestor` to establish canonical source and MISA branch divergence.
- Used `rg --files`, targeted `rg -n`, `nl -ba`, and `sed` to map Flutter, schema/migrations, RLS, RPCs, Storage, Edge Functions, tests, CI, imports, and integration flows.
- `node scripts/scan_repository_secrets.js` → `REPOSITORY_SECRET_SCAN_PASS`; no discovered secret value was printed.
- `npm test` in `scripts` → 44 tests passed, including workflow pin/secret-scope contracts, bulk-reset quarantine, and existing collector integrity/health coverage.
- `npm audit --omit=dev --audit-level=low` in `scripts` → 0 known vulnerabilities.
- `flutter analyze` → no issues.
- `flutter test` → 127 tests passed, including restart persistence, 250-file proof migration, bounded cleanup planning, mixed-version rollout, database/Edge authorization, and vendor URL contracts.
- `bash test/security_expand_sql_test.sh` → disposable local PostgreSQL passed Security Audit, replay-safe Expand, old/new client RPCs, concurrent payment deduplication, PIN lockout/reset/legacy upgrade/tenant denial, proof v2, guarded Contract, and emergency regrant.
- `flutter build web --release` with local placeholder configuration → passed; `bash test/flutter_web_cache_contract_test.sh` confirmed Flutter 3.41.6 unregistering service-worker output and shell-only Vercel revalidation.
- Deployment shell tests passed, including exact-main/history guards, psql transaction rollback, one-migration-only enforcement, migration-specific preflight/verification, security migration/Vercel separation, and Contract refusal.
- `deno check --quiet` for `create_staff_user`, `generate-settlement`, and `generate_delivery_settlement` → passed.
- Required checks passed for changed non-WeTax Functions. A final report-search command accidentally invoked repository-wide `deno check` through shell quoting; it reproduced five pre-existing WeTax typing errors but performed no runtime request or file change. No WeTax Function was edited.
- Reviewed official primary guidance for Supabase views/RLS/function privileges/API grants, PostgreSQL view invoker behavior, and GitHub Actions immutable pins/secret exposure.
- A prior unauthenticated TLS observation was not used to classify the approved Moers browser integration as a vulnerability.
- `git ls-remote` against the official action repositories confirmed the pinned commits for checkout v4.2.2, setup-node v4.4.0, github-script v7.0.1, upload-artifact v4.6.2, and flutter-action v2.21.0.
- `git diff --check` → exit 0 after source and report updates.

## Checks that were not executed and why

- No production/staging/linked Supabase migration apply, clean DB reset, live SQL impersonation, Edge invocation, Storage mutation, or Auth admin call. SQL execution was limited to a disposable local PostgreSQL database created and dropped by the test harness.
- No production database/catalog/secret/function/log access: the task explicitly prohibited production secrets/data and deployment changes.
- No release workflow, deploy script, Vercel promotion/query, completed phase rerun, or release-gate PASS declaration.
- No dynamic credential brute force, rate-limit/replay attack, SSRF probe, MITM, vendor polling/webhook simulation, or invoice issuance.
- No authenticated Moers login/report collection and no MISA/WeTax request was executed.
- No production concurrent replay, staff rollback injection, signed-URL revocation, or legacy proof-object cleanup occurred. Concurrency and PIN lockout were exercised only in the disposable local SQL harness.
- No Android/iOS device storage forensics or deep-link/custom-scheme execution.
- No CodeQL, Semgrep, Trivy, gitleaks, or container scan because those tools/workflows are not configured or installed in the assessed repository; the repository scanner, package audit, analyzers, tests, and manual source review were used.
- No full security assessment of `codex/meinvoice-misa-main`; it is not canonical `main`. Only its Git history/presence was used to explain the evidence gap.

**No migration or migration-history change, Function deployment, Vercel deployment, production query, Storage mutation, secret rotation, or release-gate PASS occurred.**
