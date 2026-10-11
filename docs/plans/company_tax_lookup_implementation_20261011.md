# ESGOO company tax-code lookup

> 이 문서는 당시 소스 검증 기록이다. 최신 main 통합·운영 적용 절차와 API 버전은 [통합 배포 문서](../pos/POS_RECIPIENT_TAX_BOUNDED_RELEASE_20261011.md)를 참조한다.
Implemented in the POS buyer-information form; not applied or deployed to production.
Scope: Vietnamese company tax code → compare customer-provided company name → fill
the returned company name. Addresses, email, phone, payments and MISA issuance are
outside this lookup. Existing explicit buyer-save/version contracts are retained.

Provider sources checked on 2026-10-11 (Asia/Ho_Chi_Minh):
[API](https://esgoo.net/api-lay-thong-tin-doanh-nghiep-tu-ma-so-thue-bv4.htm),
[free-service statement](https://esgoo.net/gioi-thieu.htm).
No provider key/client ID is used. No published quota, freshness guarantee or SLA
was found. ESGOO is a reference source, not an authoritative registration certificate.

## Behavior and bounds

- Enter or leaving a valid `vn_tax` field triggers one lookup. A lookup button
  permits explicit retry. Other buyer-number types are not sent to this provider.
- Preserve leading zeroes and accept 10 digits or 10 digits-3 digits, suffix 001–999.
  Lookup validation does not require the remaining invoice fields to be complete.
- Retain the customer-provided name in the open form. Compare trimmed/collapsed
  whitespace and case; retain accents and legal words. On mismatch, show both
  names and “check company name”; the returned name fills the company field.
- Changes to number, name, type, store, session or screen invalidate pending UI
  results. Repeated lookup preserves the original comparison. Number/store/session
  changes restore the original name if the field still contains the auto-filled name.
- Unknown/provider failure is “lookup unavailable”, not proof of an unregistered
  company. Do not add a payment or save gate based on lookup status.
- New lookup: one Auth verification, one claim RPC, at most one provider GET,
  one release RPC. No per-list-row lookup and no database contact-cache reads.
- Success-only session cache: token/session + store + tax code + provider; TTL 5 min,
  maximum 50 entries, shared in-flight request. Auth events invalidate the cache.
  At most two distinct client requests in flight. Cache hit: zero provider/RPC requests.
- Server: 1 KiB request JSON, 64 KiB streamed provider response, 300-codepoint name.
  Check `error === 0`, exact `data.mst` and nonempty `data.ten`; return name-only
  normalized JSON. Fixed HTTPS host, redirects rejected, TLS verification enabled.
- Provider abort after 5 s; Auth/DB transports after 2 s each; client wait after 12 s.
  No automatic retries. The client wait limit does not itself cancel HTTP; server
  transport cancellation and database leases bound the underlying provider work.
- Database contains one settings row per pilot store, one fixed-window quota row
  per active caller profile and exactly two shared provider-slot rows. The claim is
  one transaction and uses row locks/`SKIP LOCKED`, not process-local concurrency.
  Limit: 10 admitted calls per caller in a 60 s window; two provider calls globally.
  These are our conservative limits, not ESGOO's published limits.
- A lease expires after 10 s and is released only by matching verified Auth user and
  lease ID. Both RPCs and all three tables are inaccessible to anon/authenticated;
  only Edge service-role access is allowed. Store access uses the existing
  `user_accessible_stores(verified_auth_id)` contract and active billing staff roles.

## Pilot and release

`company_tax_lookup_settings` starts empty: every store is disabled. After the
approved migration/function/app release, enable exactly the selected pilot store
using the project's production SQL/deployment runbook, binding its real UUID:

```sql
INSERT INTO public.company_tax_lookup_settings(store_id, enabled)
VALUES (:pilot_store_id, true)
ON CONFLICT (store_id) DO UPDATE SET enabled = EXCLUDED.enabled;
```

Set `enabled=false` to stop new provider calls. Already received session results
can remain for at most the 5-minute TTL; logging out clears them immediately.
`ALLOWED_ORIGINS` uses the existing exact POS origin setting. Function config
disables gateway JWT verification; the handler verifies the bearer token through
Auth before its service-role claim. The function is included in the guarded release
script's file checks, deploy list and origin probes. Do not deploy it directly.
Existing Supabase usage still applies; provider pricing is not a permanence promise.

## Verification evidence

Reproduction commands:

```sh
flutter test test/company_tax_lookup_test.dart test/pos_buyer_information_test.dart
deno test --config supabase/functions/company-tax-lookup/deno.json supabase/functions/company-tax-lookup/handler_test.ts
python3 scripts/tests/company_tax_lookup_sql.py
bash scripts/check_repo.sh
```

- Focused Flutter/buyer/e-invoice regression tests: 24 passed on the final form source.
- Handler tests: 6 passed; real handler with mocked transport measured one Auth,
  one claim, one fetch and one release. Returned fields contain no address/contact data.
- Real service with mocked transport: 100 same-code callers share one request;
  immediately repeated lookup adds zero requests. No provider load test was used.
- Isolated PostgreSQL 17.6: cross-store, inactive and non-billing-role rejection;
  default-disabled flag; actual anon/authenticated RPC/table ACL denial; 10-per-60s
  quota; lease expiry, stale/wrong-owner release; 1/2/8 simultaneous DB sessions.
  The 8-session run admitted 2 and rejected 6, with two slot rows.
- Provider smoke test through `fetchCompany`: public example codes 0316956049,
  0316794479 and branch 0316794479-001 each succeeded with one GET. Measured
  338/95/78 ms and 581/734/398 upstream bytes on 2026-10-11. Three samples are
  not production p95, coverage, freshness or availability evidence.
- A rendered mobile mismatch preview is produced by the English widget test at
  [company_tax_lookup_preview_20261011.png](company_tax_lookup_preview_20261011.png); checked for readable text and wrapping.
- SQL fixture uses official plain PostgreSQL 17.6 and a minimal existing-scope
  fixture. Supabase's bundled image crashed on deliberate permission errors;
  no production database was used. Actual Supabase Auth/store-helper integration
  remains a post-release smoke check; existing helper source was reviewed.

Durable raw metrics: [provider smoke](../audits/company_tax_lookup_20261011/provider_smoke.json),
[client request sharing](../audits/company_tax_lookup_20261011/client_request_sharing.json),
[SQL limits](../audits/company_tax_lookup_20261011/sql_limits.json).

Optional low-volume provider reproduction (not a CI/release dependency):

```sh
deno run --no-config --allow-net=esgoo.net scripts/tests/company_tax_lookup_smoke.ts
```

Final repository check completed successfully (`bash scripts/check_repo.sh`, exit 0).
The main Flutter suite passed 1,918 tests with 97 skips; the final form refinement
also passed the 24 focused buyer/company/e-invoice tests and
`dart analyze --fatal-infos`. Changed Dart files were formatted. Deno formatting,
lint, type checking and handler tests, isolated database tests, Node/security
contracts, deployment/migration shell contracts and the web release build passed.
The build emitted existing optional WebAssembly/image-library and Cupertino font
warnings; the JavaScript web build completed. Production migration, Edge Function,
app deployment and post-release Auth smoke checks have not been performed.
