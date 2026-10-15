# Independent brand registration

Super Admin can register a brand without a store or legal entity, then link
existing legal entities and immediately select the brand when adding a store.
Registration never creates a store, Office record, accounting account or tax
profile. A valid organization group (`brand_master`) is required by the existing
schema; one available group is selected automatically. No group ID is hardcoded.

## UI and access

- The store toolbar exposes **Add brand** and **Manage brands** independently
  of **Add store**. The store form also opens the same brand editor and preserves
  its draft. Its selected legal entity is initially checked in that editor.
- Brand management includes brands with zero stores and no legal entity links.
  Search is debounced by 350 ms. Each cursor page contains at most 50 brands,
  their legal entity links and store counts, in one RPC. Store counts include
  active and inactive stores. Raw relations are aggregated separately.
- Legal entity links are additive. Existing links are disabled in the editor;
  the existing guarded v2 unlink contract is unchanged. Store creation continues
  through `admin_create_restaurant_v2`, including its legal entity/brand pair
  validation and Office compatibility rules.
- All four exposed brand RPCs require an active `public.users` super_admin
  profile mapped to `auth.uid()`. Anonymous execution is revoked and direct
  table writes are not opened. The private authorization helper is not granted
  to clients. Existing production test-entity guards continue to run.
- New codes are trimmed, lowercase, 2–64 ASCII letters/digits/underscores/hyphens,
  starting with a letter or digit. Existing codes are not rewritten. Normalized
  duplicate checks are serialized with a transaction advisory lock.
- The editor retains its UUID request ID across retries. A retry after a lost
  response returns the same brand only for the same actor and identical request;
  it does not insert another brand or creation audit. Changes to an already
  committed request return `BRAND_REQUEST_CONFLICT`. Linking is idempotent.
- Mutation responses update local brand/link state without reloading stores.
  A catalog request started before a mutation cannot overwrite the committed
  result. Pure brand insertion/link events refresh only the existing small
  brand/link catalogs, with coalesced requests; mixed/fallback events retain the
  existing reconciliation. Brand updates/deletes retain the broader refresh.

## Verification

```sh
flutter gen-l10n
dart analyze --fatal-infos
flutter test test/independent_brand_widget_test.dart test/brand_service_test.dart \
  test/super_admin_overlay_operational_test.dart \
  test/super_admin_legal_entity_contract_test.dart \
  test/legal_entity_brand_store_hierarchy_contract_test.dart test/catalog_query_test.dart
bash test/independent_brand_sql_test.sh
bash scripts/check_repo.sh
```

The SQL runner starts a disposable Supabase PostgreSQL container, applies the
new migration twice and runs the actual existing v2 store creation function.
It checks standalone registration, later multi-entity linking, idempotent
retries, atomic failures, active-admin authorization, anonymous function ACLs,
direct-write RLS, store count accuracy, Office type derivation and cursor ties.
Its dataset has 1,000 additional brands and 10,000 stores; all 1,000 brands are
visited in exactly 20 pages, without duplicate IDs. Timed calls report page row
count, response bytes, wall time and SQL execution time. These are local fixture
measurements, not production latency or a network load test. Service tests
separately assert one HTTP call per 50-brand management page, with no per-brand
queries. A normal mutation uses one write request; the editor loads organization
groups once. Catalog invalidation retains existing 100-row keyset batching,
with at most two concurrent catalog loads for pure brand events.

Optional UI captures for Korean, English and Vietnamese:

```sh
flutter test --no-pub --update-goldens --dart-define=BRAND_SCREENSHOT=true \
  test/independent_brand_widget_test.dart
```

Local verification on 2026-10-15:

- All 66 focused Flutter tests pass, including existing Super Admin overlays,
  legal-entity/store contracts, alert regression baselines and overlay coverage.
- The isolated SQL suite passes, including two concurrent sessions registering
  the same normalized code. Exactly one brand and one creation audit commit.
- With 1,000 brands and 10,000 stores, a 50-brand response is 13,520 bytes.
  The measured fixture call takes about 1.2 ms wall time and 0.5 ms SQL execution
  time. The printed EXPLAIN is the outer function call, not its nested plan.
  Production latency, load throughput and peak memory have not been measured.
- `dart analyze --fatal-infos` reports no issues. The release web build succeeds.
- The full `scripts/check_repo.sh` run reaches 2,071 passed, 97 skipped and
  8 failed Flutter tests. All failures are pixel comparisons in
  `test/pos_paperless_visual_test.dart` (kitchen/tray/floor/admin/cashier/customer
  receipt surfaces). Their source and existing reference images were not
  changed for this feature. The script stops at that Flutter test failure,
  so its later SQL/integration steps are not claimed as passed; the new brand
  SQL suite was run separately. Production release gates are not satisfied.

## Rollout

The release follow-up is isolated on current `origin/main`, preserving the
original working directory and unrelated changes. All eight paperless golden
tests also failed against the current main references on macOS before the
golden fix. Native macOS rasterization now has separate exact baselines under
`.design/2026-08-pos-print-paperless-receipts/goldens/macos`; Linux CI baselines
and representative screenshots are unchanged. After visual review, regeneration
and a separate normal comparison run both pass all eight tests. No fuzzy
comparison threshold or golden-test skip is introduced.

Production migration companions are
`scripts/preflight_independent_brand_registration.sql` and
`scripts/verify_independent_brand_registration.sql`. The isolated SQL runner
executes both. Release this feature through the official **DB-only** migration
mode followed by **web-only** mode, with successful required GitHub Actions on
the exact freshly fetched main SHA for both phases. No Edge Function change is
needed. Keep operational verification and deployment evidence separate from
these source-level results.

This source change does not establish production deployment. First apply
`supabase/migrations/20261015100000_independent_brand_registration.sql` through
`scripts/deploy_pos_production.sh`, following the production runbook and exact
pushed-head CI gate. Confirm valid `brand_master` groups and legal entities
exist. Deploy the client only with these RPCs available, then verify registration
and later linking using authorized operational data. Do not create test brands
in production. Never copy account passwords into fixtures, release commands,
screenshots or this document. Roll back the UI or use a forward fix while keeping
registered brand IDs, legal entity links and audit history intact.
