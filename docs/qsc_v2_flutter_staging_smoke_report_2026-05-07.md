# QSC v2 Flutter Staging Smoke Report — 2026-05-07

## Scope

This report captures app-side staging smoke validation after the QSC v2 draft
database migrations were applied to POS Supabase project
`ynriuoomotxuwhuxxmhj`.

The goal of this pass was not full end-to-end role verification. It was to
confirm:

1. the app boots against staging configuration,
2. Supabase initialization succeeds,
3. the login surface renders in at least one runtime,
4. auth error handling still surfaces correctly,
5. any remaining blocker is clearly identified.

## Commands Run

### 1. Flutter device discovery

```bash
flutter devices
```

Observed devices:

- `macos`
- `chrome`

### 2. Widget/integration smoke attempts

```bash
flutter test integration_test/app_test.dart -d chrome \
  --dart-define=SUPABASE_URL=$SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY
```

Result:

- failed immediately because Flutter does not support web devices for
  `integration_test` in this path.

```bash
flutter test integration_test/app_test.dart \
  --dart-define=SUPABASE_URL=$SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY
```

Result:

- failed because multiple devices were connected and no explicit device was
  selected.

```bash
flutter test integration_test/app_test.dart -d macos \
  --dart-define=SUPABASE_URL=$SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY
```

Result:

- macOS test runner booted the app bundle,
- test failed with:

```text
Bad state: SUPABASE_URL not configured. Set via --dart-define or .env
```

Interpretation:

- this test path did not provide configuration to `AppConstants` the way the
  runtime path does,
- it is not evidence of a staging outage.

### 3. Runtime smoke — Chrome

```bash
flutter run -d chrome --web-port 3000 --dart-define-from-file=.env.local
```

Observed runtime output:

- app launched,
- debug service connected,
- `supabase.supabase_flutter: INFO: ***** Supabase init completed *****`

Observed UI state:

- tab title changed to `GLOBOS POS`,
- URL loaded at `http://127.0.0.1:3000/`,
- widget tree existed (`debugDumpApp` showed `GlobosPosApp`, `MaterialApp`,
  router stack, and scaffold structure),
- visible viewport remained a solid dark/black screen in Chrome.

Interpretation:

- staging configuration and app boot both succeeded,
- the remaining issue is likely web-specific rendering/presentation behavior,
  not missing Supabase configuration and not an app startup crash.

### 4. Runtime smoke — macOS

```bash
flutter run -d macos --dart-define-from-file=.env.local
```

Observed runtime output:

- build succeeded,
- app launched,
- `supabase.supabase_flutter: INFO: ***** Supabase init completed *****`

Observed UI state:

- login screen rendered correctly,
- branding panel and login card were visible,
- email/password fields and submit button were present,
- this confirms the app runtime is healthy on native desktop with staging
  configuration.

## Auth Surface Validation

Using desktop UI automation on the macOS app:

- login form fields were present,
- submit button transitioned into loading state when clicked,
- auth error state rendered on screen when the email field was effectively
  missing,
- rendered error text:

```text
missing email or phone
```

This confirms:

1. auth submission path is wired,
2. backend auth responses still surface into the UI,
3. error rendering on the login page still works after QSC v2 changes.

## Limitation Encountered

The desktop automation layer did not reliably persist the full email string into
the login email field during this pass. Because of that, a full authenticated
admin session was **not** completed here.

This is an automation-input issue, not evidence that staging auth itself is
broken.

While shutting down the native `flutter run` session after simulated keyboard
input, Flutter also emitted a `HardwareKeyboard` assertion around a mismatched
`KeyUpEvent` for the `A` key. This appeared after automation-driven typing and
is treated as an input-simulation artifact for this smoke pass, not as evidence
of an application-level QSC regression.

## Conclusion

### Confirmed

- QSC v2 staging database draft is applied.
- Office wrapper views are queryable on staging.
- POS Flutter app boots against staging.
- Supabase init completes on both Chrome runtime and macOS runtime.
- Native macOS login UI renders correctly.
- Login error handling still works.

### Not Yet Confirmed

- successful authenticated login to a role-scoped workspace during this smoke,
- post-login QSC flows (`/qc-check`, `/qc-review`, admin QC tab) in a live
  staging session,
- root cause of the Chrome debug black-screen runtime presentation.

## Follow-up Web Rendering Check

After the initial smoke, the Chrome debug black-screen case was investigated
with Chrome DevTools Protocol.

Findings:

- the debug URL was correctly routed to `/#/login`,
- `Supabase init completed` was logged,
- the Flutter widget tree existed,
- the Flutter web DOM contained a `flutter-view`,
- the initial debug runtime canvas path still displayed only the dark
  `web/index.html` body background.

The release web build was then tested:

```bash
flutter build web --dart-define-from-file=.env.local
python3 -m http.server 3001 --directory build/web
```

Opening `http://127.0.0.1:3001/#/login` rendered the POS login screen correctly
in Chrome.

Updated interpretation:

- the POS web release build is not blocked by the black-screen behavior,
- the black screen is isolated to the local Chrome debug runtime path used by
  `flutter run -d chrome`,
- native macOS runtime and release web runtime both render the login screen.

## Recommended Next Step

Use one of these two paths:

1. manual/native login on the macOS app with known staging credentials, then
   verify:
   - staff QC submit,
   - multi-photo upload,
   - admin QC tab,
   - SV review;
2. investigate web-only rendering behavior separately, since native runtime is
   already healthy and isolates the issue away from Supabase/QSC data changes.

## Authenticated Release Web Smoke

After the release web build rendered correctly, an authenticated staging smoke
was completed in Chrome using:

- URL: `http://127.0.0.1:3001/#/login`
- Account: `admin@globos.test`
- Workspace: `K-Noodle / GLOBOS Test Restaurant`

Observed result:

- login succeeded,
- admin workspace routed to `/#/admin`,
- the default Tables tab rendered but showed the pre-existing adjacent error
  `Failed to load tables.`,
- the admin QC tab loaded successfully.

Admin QC tab checks:

- `Template Management` rendered two staging templates:
  - `2 보장`
  - `1 위생`
- `Weekly Inspection Status` rendered week controls, filters, and template
  rows for the selected week.
- `Follow-ups` initially failed because the app called
  `get_qc_analytics(p_store_id, p_from, p_to)` while the active staging
  function signature still used the legacy `p_restaurant_id` argument.

Root cause confirmed:

- the error was a PostgREST `PGRST202` function signature miss,
- the hinted matching function was
  `public.get_qc_analytics(p_from, p_restaurant_id, p_to)`,
- this matches the POS store/restaurant dual-naming transition period described
  in `CLAUDE.md`.

Minimum app fix applied:

- `lib/core/services/qc_service.dart` now uses the existing
  `runRpcWithStoreCompat` helper for:
  - `create_qc_followup`,
  - `update_qc_followup_status`,
  - `get_qc_followups`,
  - `get_qc_analytics`.

Verification after fix:

```bash
dart format lib/core/services/qc_service.dart
flutter analyze lib/core/services/qc_service.dart \
  lib/features/qc/qc_provider.dart \
  lib/features/admin/tabs/qc_tab.dart
flutter build web --dart-define-from-file=.env.local
python3 -m http.server 3002 --directory build/web
```

Observed result on `http://127.0.0.1:3002/#/admin`:

- login succeeded,
- admin QC `Template Management` rendered,
- admin QC `Follow-ups` rendered the analytics card with zero-state values,
- the previous `PGRST202` RPC error message no longer appeared,
- direct route `/#/qc-check` rendered today's quality check screen with the two
  staging templates and save action,
- direct route `/#/qc-review` rendered the QSC Review screen with filters and
  empty pending/reviewed/rejected states.

Updated confirmed scope:

- successful authenticated login to a role-scoped workspace is confirmed in
  release web,
- admin QC template/status/follow-up screens are confirmed in release web,
- staff QC input route is render-confirmed in release web,
- SV/QSC review route is render-confirmed in release web.

Remaining gaps:

- actual photo-submit smoke exposed and fixed three Flutter web issues:
  - `dart:io File` usage in QSC photo paths caused
    `Unsupported operation: _Namespace`,
  - already uploaded v2 photos were not counted when no legacy
    `evidence_photo_url` existed,
  - direct `/#/qc-check` entry could pop to a blank page after save,
- `flutter analyze` and `flutter build web --dart-define-from-file=.env.local`
  pass after those fixes,
- DB smoke confirmed today's submitted `2 보장` row with
  `photo_required_count = 1` and `photo_uploaded_count = 1`,
- final rebuilt-bundle smoke on 2026-05-08 confirmed two submitted checks
  (`2 복장`, `1 위생`) and two normalized `qc_check_photos` rows with
  `photo_role = staff`, `is_primary = true`, and storage paths under the
  restaurant-scoped `qc-photos` folder contract,
- SV score/reject mutation was not executed in this pass,
- the Tables tab error is outside QSC v2 and remains as an adjacent staging
  issue,
- Chrome debug runtime black-screen remains isolated to `flutter run -d chrome`
  and is not blocking the release web build.

## Final Photo Submit Retest — 2026-05-08

The final release web bundle was rebuilt and served from:

```bash
flutter build web --dart-define-from-file=.env.local
python3 -m http.server 3002 --directory build/web
```

Actual browser flow:

- authenticated Chrome session opened `http://127.0.0.1:3002/#/qc-check`,
- both staging templates were visible:
  - `2 복장`
  - `1 위생`
- the same local PNG was attached to both items through the browser file picker,
- both items were marked `통과`,
- save completed and the direct-route fallback returned to `/#/admin` instead
  of a blank route.

Database verification:

```sql
select qc.id, qt.criteria_text, qc.check_date, qc.result,
       qc.submission_status, qc.photo_required_count,
       qc.photo_uploaded_count, qc.evidence_photo_url is not null as has_legacy_photo,
       qc.created_at
from qc_checks qc
join qc_templates qt on qt.id = qc.template_id
where qc.check_date = date '2026-05-08'
order by qc.created_at desc
limit 10;
```

Confirmed rows:

- `1 위생`: `result = pass`, `submission_status = submitted`,
  `photo_required_count = 1`, `photo_uploaded_count = 1`,
  `has_legacy_photo = true`
- `2 복장`: `result = pass`, `submission_status = submitted`,
  `photo_required_count = 1`, `photo_uploaded_count = 1`,
  `has_legacy_photo = true`

```sql
select p.check_id, qt.criteria_text, p.photo_role, p.is_primary,
       p.storage_path, p.uploaded_at, p.taken_at
from qc_check_photos p
join qc_checks qc on qc.id = p.check_id
join qc_templates qt on qt.id = qc.template_id
where qc.check_date = date '2026-05-08'
order by p.uploaded_at desc
limit 20;
```

Confirmed rows:

- `1 위생`: `photo_role = staff`, `is_primary = true`,
  storage path starts with
  `aaaaaaaa-0000-0000-0000-000000000001/checks/`
- `2 복장`: `photo_role = staff`, `is_primary = true`,
  storage path starts with
  `aaaaaaaa-0000-0000-0000-000000000001/checks/`

Additional app-side compatibility fix:

- `lib/core/services/qc_service.dart` now reads `qc_check_photos.uploaded_at`
  instead of a non-existent `created_at` column when fetching normalized check
  photos.
