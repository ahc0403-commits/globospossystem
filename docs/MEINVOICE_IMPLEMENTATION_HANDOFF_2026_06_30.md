# MISA meInvoice Implementation Handoff

Date: 2026-06-30

## 1. Current Status

WeTax transmission is being replaced by MISA meInvoice.

Implementation status:

- WeTax dispatch path is shut down at DB level.
- Restaurant POS sales now create `meinvoice_jobs`.
- MISA meInvoice adapter and dispatcher are implemented.
- Admin UI can review readiness, seller config, queue status, retries, and event history.
- Photo Objet Moers sales pull now stores raw rows first and queues new cash sales to `meinvoice_jobs`.
- Live MISA dispatch is still gated off until AppID and runtime secrets are configured.

No password is stored in this document. Do not add MISA or Moers passwords to git, docs, SQL migrations, or Flutter UI.

Known company/account context:

- Company: `CÔNG TY TNHH AKJ INTERNATIONAL`
- Company tax code: `0318453298`
- API username discussed with MISA support: `0348079884`
- MISA AppID: not received yet

## 2. Architecture Summary

The implementation uses one async queue for all first-issuance cash-register invoices:

```text
Restaurant POS completed order
  -> public.meinvoice_jobs
  -> supabase/functions/meinvoice-dispatcher
  -> MISA meInvoice

Photo Objet Moers sales raw row
  -> public.photo_objet_sales_raw
  -> public.meinvoice_jobs
  -> supabase/functions/meinvoice-dispatcher
  -> MISA meInvoice
```

The crawler never calls MISA directly. It only writes source sales rows. MISA dispatch stays isolated in the meInvoice dispatcher so retry, dry-run, readiness, and failure handling are shared.

## 3. Restaurant POS Flow

Trigger:

- Order status changes to `completed`.
- DB trigger `trg_enqueue_meinvoice_cash_register_job` calls `public.enqueue_meinvoice_cash_register_job()`.

Queue behavior:

- Inserts one row into `public.meinvoice_jobs`.
- Keeps payment completion independent from MISA availability.
- Anonymous default buyer is `Người mua không lấy hóa đơn`.
- Registered buyer data can be added later through the existing red/VAT invoice request flow.
- If MISA config is not active, job status remains `pending_manual_config`.
- If config is active and dispatch is enabled, job status can become `pending`.

Important table:

- `public.meinvoice_jobs`

Important migration:

- `supabase/migrations/20260630000000_wetax_shutdown_meinvoice_foundation.sql`
- `supabase/migrations/20260630001000_meinvoice_buyer_fields.sql`

## 4. Photo Objet Flow

Photo Objet is different from restaurant POS:

- No POS API integration.
- Sales are pulled from Moers.
- All Photo Objet sales are treated as cash.
- VNPAY/QR wallet data must not be mixed into this ledger.
- D7 is removed from the active pull list because the store is scheduled to close.

Current pull workflow:

- Workflow: `.github/workflows/photo_objet_sales.yml`
- Script: `scripts/pull_moers_sales.js`
- Schedule: every 10 minutes
- Active stores: Bien Hoa, Di An, Long Thanh, Thao Dien, Quang Trung, Now Zone

Photo flow:

```text
Moers login
  -> day.php
  -> Excel download if available
  -> HTML table fallback if Excel button is not available
  -> normalize rows
  -> upsert public.photo_objet_sales_raw by source_hash
  -> DB trigger queues new raw rows to public.meinvoice_jobs
  -> aggregate table public.photo_objet_sales remains for dashboard
```

New raw tables:

- `public.photo_objet_sales_raw`
- `public.photo_objet_sales_pull_runs`

Dashboard table retained:

- `public.photo_objet_sales`
- `public.v_photo_objet_daily_summary`

Important migration:

- `supabase/migrations/20260630007000_photo_objet_raw_meinvoice_queue.sql`

Idempotency:

- `source_hash` is unique.
- Re-pulling the same Excel rows updates existing rows instead of creating duplicate invoice jobs.
- Only newly inserted raw rows trigger invoice queue creation.

## 5. MISA Adapter and Dispatcher

Shared adapter:

- `supabase/functions/_shared/meinvoice.ts`

Dispatcher:

- `supabase/functions/meinvoice-dispatcher/index.ts`

MISA API shape implemented:

- Token: `/auth/token`
- Publish cash-register invoice:
  `POST /api/integration/invoice` with `SignType = 5`
- Template lookup helper:
  `GET /api/integration/invoice/templates`
- Status lookup helper:
  `POST /api/integration/invoice/status?invoiceCalcu=true`
- Download helper:
  `POST /api/integration/invoice/Download?invoiceCalcu=true`
- Default auth base URL:
  `https://api.meinvoice.vn/api/integration`
- Default API base URL:
  `https://api.meinvoice.vn/api/integration/invoice`

Implemented safeguards:

- Requires `CRON_SECRET`.
- Requires Supabase service role key.
- Honors `meinvoice_dispatch_enabled`.
- Supports `dry_run`.
- Builds and validates payload before calling token/publish.
- Stores safe metadata only.
- Does not persist raw MISA request/response bodies.
- Token is cached in `public.meinvoice_token_cache`.

Dispatch readiness rules:

- `integration_status = active`
- `app_id` exists
- `invoice_series` exists
- runtime env username/password exists
- `meinvoice_dispatch_enabled = true`

Payload dry-run can be built before AppID is available as long as invoice series exists.

## 6. Admin UI

Admin e-invoice surface:

- `lib/features/admin/tabs/einvoice_tab.dart`

Capabilities:

- Reads `meinvoice_jobs`.
- Shows readiness blockers.
- Shows job event history from `meinvoice_job_events`.
- Lets admin configure non-secret seller settings.
- Lets admin retry failed jobs.
- Lets admin mark manual issues resolved.
- Lets admin release config-ready jobs from `pending_manual_config` to `pending`.

Admin RPC migrations:

- `supabase/migrations/20260630003000_meinvoice_admin_ops.sql`
- `supabase/migrations/20260630004000_meinvoice_readiness.sql`
- `supabase/migrations/20260630005000_meinvoice_config_admin.sql`
- `supabase/migrations/20260630006000_meinvoice_ready_queue_admin.sql`

Do not add password fields to the admin UI. Secrets must stay in runtime env.

## 7. Runtime Config and Secrets

Database runtime config:

- `meinvoice_dispatch_enabled`
- `meinvoice_dispatch_batch_size`
- `meinvoice_token_refresh_skew_minutes`

Default dispatch state:

- Dispatch is disabled until explicitly enabled.

Supabase Edge Function env vars:

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `CRON_SECRET`
- `MISA_MEINVOICE_USERNAME`
- `MISA_MEINVOICE_PASSWORD`

Tax-code-specific variants are also supported by the adapter:

- `MISA_MEINVOICE_USERNAME_0318453298`
- `MISA_MEINVOICE_PASSWORD_0318453298`

MISA AppID is not an env var in this implementation. It is stored as non-secret config in:

- `public.meinvoice_tax_entity_config.app_id`

Invoice series is also stored there:

- `public.meinvoice_tax_entity_config.invoice_series`

Current AKJ portal-observed cash-register series:

- `1C26MAJ`

Evidence:

- MISA portal path:
  `Invoice > Invoices from Cash Registers`
- The actual issued cash-register invoice list for
  `CÔNG TY TNHH AKJ INTERNATIONAL`, tax code `0318453298`, shows
  `Series = 1C26MAJ` on June 2026 invoices.
- This value is the runtime `InvSeries` to send in publish requests.
- Do not hardcode this value in Edge Function code. Store it in
  `public.meinvoice_tax_entity_config.invoice_series`.

Do not confuse:

- `1C26MAJ`: invoice series / `InvSeries` / config value
- `00007477`-style values: MISA-issued invoice numbers after publish
- `M1-26-...`-style values: tax authority code/result data after publish
- MISA AppID: non-secret API app identifier stored in DB config
- MISA username/password: secrets stored only in Supabase Edge Function env

Moers/GitHub Actions secrets:

- `SUPABASE_URL`
- `SUPABASE_SERVICE_KEY`
- `MOERS_BIENHOA_PASS`
- `MOERS_DIAN_PASS`
- `MOERS_LONGTHANH_PASS`
- `MOERS_THAODIEN_PASS`
- `MOERS_QUANGTRUNG_PASS`
- `MOERS_NOWZONE_PASS`
- `PHOTO_OBJET_BIENHOA_STORE_ID`
- `PHOTO_OBJET_DIAN_STORE_ID`
- `PHOTO_OBJET_LONGTHANH_STORE_ID`
- `PHOTO_OBJET_THAODIEN_STORE_ID`
- `PHOTO_OBJET_QUANGTRUNG_STORE_ID`
- `PHOTO_OBJET_NOWZONE_STORE_ID`

## 8. Operational Activation Checklist

Before live dispatch:

1. Apply migrations through `20260630007000_photo_objet_raw_meinvoice_queue.sql`.
2. Deploy `supabase/functions/meinvoice-dispatcher`.
3. Confirm the target POS tax entity/store mapping:
   - `public.tax_entity.tax_code = '0318453298'`
   - `public.tax_entity.einvoice_provider = 'meinvoice'`
   - active AKJ stores reference that `tax_entity_id`
4. Configure Supabase function env secrets:
   - preferred: `MISA_MEINVOICE_USERNAME_0318453298`
   - preferred: `MISA_MEINVOICE_PASSWORD_0318453298`
   - fallback supported: `MISA_MEINVOICE_USERNAME`
   - fallback supported: `MISA_MEINVOICE_PASSWORD`
5. Get MISA AppID from MISA support.
6. Configure `meinvoice_tax_entity_config`:
   - `app_id`
   - `invoice_series = '1C26MAJ'`
   - `integration_status = configured`
   - payment method labels
7. Keep `meinvoice_dispatch_enabled = false`.
8. Run readiness checks and confirm only the expected blocker remains.
9. Run dispatcher with `dry_run = true`.
10. Verify payload shape, totals, and `InvSeries = 1C26MAJ`.
11. Set `integration_status = active` only after AppID, series, and secrets are
    present.
12. Enable one store/tax entity for limited live dispatch.
13. Verify MISA token, publish, status, and download behavior:
    - token endpoint succeeds
    - publish returns `TransactionID`, `InvNo`, `InvCode`/lookup code
    - status lookup returns the issued invoice
    - PDF or HTML download succeeds
14. Only then set `meinvoice_dispatch_enabled = true` for normal operation.

Do not enable live dispatch before AppID, tax-code-scoped credentials, invoice
series, and a limited live publish/status/download test are confirmed.

## 9. Manual Exception Handling

MISA portal remains the system of record for post-issuance exceptions:

- Replace invoice
- Adjustment invoice
- Notification of incorrect invoice
- Cancel invoice
- Manual portal review

The POS system marks jobs with:

- `manual_action_required`
- `manual_action_type`
- `manual_action_note`

The POS does not rebuild MISA's exception workflows.

## 10. Validation Commands

Commands already used during implementation:

```bash
node --check scripts/pull_moers_sales.js
dart format --set-exit-if-changed test/photo_objet_meinvoice_raw_contract_test.dart
flutter test test/photo_objet_meinvoice_raw_contract_test.dart
flutter test test/meinvoice_dispatcher_contract_test.dart test/meinvoice_migration_contract_test.dart test/meinvoice_buyer_fields_contract_test.dart
flutter analyze test/photo_objet_meinvoice_raw_contract_test.dart
git diff --check -- .github/workflows/photo_objet_sales.yml docs/photo_objet_sales_pull_setup.md scripts/pull_moers_sales.js supabase/migrations/20260630007000_photo_objet_raw_meinvoice_queue.sql test/photo_objet_meinvoice_raw_contract_test.dart
```

Additional useful checks:

```bash
rg -n "wetax_dispatch_enabled|wetax_polling_enabled|einvoice_jobs" lib supabase/functions supabase/migrations/202606300*.sql test -S
rg -n "MISA_MEINVOICE_PASSWORD|raw_request|raw_response" lib supabase/functions supabase/migrations test -S
```

Expected:

- Active Flutter/Admin reads should use `meinvoice_jobs`.
- No password should appear in Flutter UI or SQL migrations.
- No raw MISA request/response should be persisted in job events.

## 11. Important Files

Core MISA:

- `supabase/functions/_shared/meinvoice.ts`
- `supabase/functions/meinvoice-dispatcher/index.ts`
- `supabase/migrations/20260630000000_wetax_shutdown_meinvoice_foundation.sql`
- `supabase/migrations/20260630001000_meinvoice_buyer_fields.sql`
- `supabase/migrations/20260630002000_meinvoice_dispatcher_foundation.sql`
- `supabase/migrations/20260630003000_meinvoice_admin_ops.sql`
- `supabase/migrations/20260630004000_meinvoice_readiness.sql`
- `supabase/migrations/20260630005000_meinvoice_config_admin.sql`
- `supabase/migrations/20260630006000_meinvoice_ready_queue_admin.sql`

Photo Objet:

- `supabase/migrations/20260630007000_photo_objet_raw_meinvoice_queue.sql`
- `scripts/pull_moers_sales.js`
- `.github/workflows/photo_objet_sales.yml`
- `docs/photo_objet_sales_pull_setup.md`

Flutter/Admin:

- `lib/features/admin/tabs/einvoice_tab.dart`
- `lib/core/services/einvoice_service.dart`
- `lib/core/services/payment_service.dart`
- `lib/features/payment/einvoice_provider.dart`
- `lib/features/payment/einvoice_status_badge.dart`
- `lib/features/payment/payment_detail_screen.dart`
- `lib/features/cashier/red_invoice_modal.dart`

Tests:

- `test/meinvoice_migration_contract_test.dart`
- `test/meinvoice_buyer_fields_contract_test.dart`
- `test/meinvoice_dispatcher_contract_test.dart`
- `test/einvoice_admin_ui_contract_test.dart`
- `test/photo_objet_meinvoice_raw_contract_test.dart`

## 12. Remaining Blockers

Hard blockers:

- MISA AppID is not available yet.
- MISA live token call has not been verified.
- Real invoice publish has not been tested.
- Real template/status/download calls have not been tested.

Operational blockers:

- Supabase migrations must be applied.
- Edge Function must be deployed.
- Runtime secrets must be configured.
- `SUPABASE_SERVICE_KEY` must exist for Photo Objet GitHub Actions.
- D7 Moers secrets are not required for the active pull.

Risk notes:

- Photo Objet source hash includes row index because Moers may not provide a transaction ID. If Moers reorders same-day rows frequently, review duplicate behavior during pilot.
- Start with 10-minute polling. Do not reduce to 5 minutes until operational logs show stable Moers behavior.
- Keep dispatch disabled while validating totals.

## 13. Recommended Next Step

Next safest sequence:

1. Apply migrations in staging.
2. Configure Moers secrets and run one manual workflow for active stores.
3. Compare Moers Excel total vs `photo_objet_sales_raw`.
4. Configure MISA AppID and invoice series when received.
5. Run meInvoice dispatcher `dry_run`.
6. Do one real dispatch only after payload and totals are confirmed.
