# Procurement approval inbox and automatic store links

Status: source implementation and local regression verification completed. On 2026-10-14 the user explicitly reauthorized production deployment with login smoke tests omitted. Production application and deployment evidence is recorded separately; source tests do not prove real-account login or business approval.

## Operator behavior

- Store managers open the PR approval inbox by default. Pending requests have no implicit recent-month cutoff and use `(submitted_at, id)` ascending cursors. Counts distinguish pending, actionable and blocked requests. Approved/cancelled history switches out of the current-stage filter.
- Approval actions share the server's ownership/distinct-approver rules. Policy 3 has store approval followed by the fixed Office buyer; historical policy 1/2 records and issued documents retain their state and snapshots.
- PR/header/line/event changes emit payload-free invalidations per changed store and statement. In-flight refreshes are merged; request editing and uncertain command retries retain their state. Receiving actions use server capabilities, including the registered receiver roster, rather than the inventory-orderer role alone.
- Office can open a cross-store approval inbox, then open a request with its native Office store ID. POS and Office store IDs and Auth IDs remain distinct. Reads use 100 scoped stores per RPC and at most two concurrent batches; request pages contain at most 50 rows.

## New stores and identities

1. Configure the store short code and workforce requirements. New store-manager/requester/receiver codes are store-specific. Reapplying a preset preserves existing configured identities. Cross-store code collisions and changes to provisioned role/type/scope are rejected.
2. Provision actual Auth accounts through the existing fixed-account function. Only the completed `provisioned_user_id` and an active store-access binding create POS roster entries. The requirement references the POS profile ID; the roster references the Auth ID.
3. A bounded Office metadata job runs every minute using dedicated private onboarding dispatch configuration (`procurement_onboarding_function_url` / `procurement_onboarding_dispatch_token`, matching the Edge secret `PROCUREMENT_ONBOARDING_DISPATCH_TOKEN`). It reads verified POS store metadata, commits native Office store links, confirms existing active native buyer/finance grants, then acknowledges the POS stage. A failure before the acknowledgment retries the same stage; it never creates central Auth accounts or activates the separate legacy purchase auto-sync job.
4. Automatic legal-entity inheritance requires one existing approved brand/tax-entity binding. Unknown or ambiguous entities remain blocked for explicit legal-entity mapping. SAMPLE keeps its own binding. A new policy enables version 3 only after required connections are ready; an existing policy is never replaced by onboarding.

Requester/receiver presets use the existing `inventory_orderer` account type and separate codes (`<store>_pr1` and `<store>_order`). Receiving permission additionally requires a current receiver roster when the identity belongs to a configured store requirement. Central buyer, accounting and Super Admin identities are reused.

## PR document

Internal PRs use landscape A4 for ordinary values, repeat the table on subsequent pages, show the actual material code without a label prefix, and preserve quantities, units, stock, estimates, VAT and source references. Measured text widths expand the columns/page for large numbers and long units; fonts remain 8pt. Supplier projections remain price-free. No QR or delivery-fee item was introduced.

## Verification and deployment boundary

Local tests cover the 31-account role distribution with fresh UUIDs, inactive/cross-store denial, current-stage/self-approval behavior, stable cursors, set-based invalidations, retry-safe onboarding, fixed central identities, native Office ID separation, banned central identities and unknown-entity blocking. These fixtures are not evidence of production account login.

POS tests: `bash scripts/check_repo.sh`, `bash scripts/test_procurement_v2.sh`, targeted Flutter tests and PDF extraction/rendering checks. Office tests: `scripts/run_office.sh unit-test`, `dart analyze --fatal-infos`, bridge Deno tests, i18n checks and `bash scripts/test_procurement_store_links.sh`. Office desktop golden differences on this macOS host also reproduce byte-for-byte pixel counts against the unchanged baseline; do not regenerate Ubuntu goldens here.

The authorized combined deployment must apply POS migrations `20261014080000` and `20261014081000`, the Office migration `20261014080000`, the Office bridge and both clients through their existing production gates. POS deployment uses `scripts/deploy_pos_production.sh`, clean exact `origin/main`, the exact pushed SHA GitHub gate, migration verification and build checks. The user explicitly requested omission of login smoke; use the script’s existing `--skip-login-smoke` option and do not label the release login-verified. Office deployment preserves the existing source identity, approved Edge inventory and native Auth immutability checks; these checks do not log into operator accounts.

Final local verification on 2026-10-14: all 49 POS repository checks passed, including Flutter tests, SQL invariants, web build and whitespace. Office procurement Flutter tests: 26 passed; bridge Deno tests: 114 passed; Office static analysis and three-locale checks passed. New inbox EXPLAIN covers 2/20/100 stores and 100/1000/10000 pending PRs, 50 returned rows, one RPC and one PR-relation scan. After eliminating repeated JSON row conversion and per-action guard queries, database execution at 10,000 PRs was about 0.25 seconds on this host; this excludes network/UI time. The 2-second CI regression budget remains unchanged.
