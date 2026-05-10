# Launch Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the remaining gaps between the current Stage 1 codebase and a real store-launchable POS product.

**Architecture:** Treat launch readiness as an operations program, not a feature sprint. Validate live vendor paths, real-device runtime flows, onboarding data integrity, hardware behavior, and release automation in that order, while preserving the already-green contract and widget test baseline.

**Tech Stack:** Flutter, Supabase Postgres/RLS/RPC, Supabase Edge Functions, GitHub Actions, Android devices, WeTax vendor APIs

---

## File Map

- Reference: `/Users/andreahn/globos_pos_system/docs/runtime_vendor_validation_plan_2026-04-15.md`
- Reference: `/Users/andreahn/globos_pos_system/docs/payment_proof_wt09_smoke_test.md`
- Reference: `/Users/andreahn/globos_pos_system/docs/phase_3_verification_report.md`
- Reference: `/Users/andreahn/globos_pos_system/integration_test/full_multi_account_smoke_test.dart`
- Reference: `/Users/andreahn/globos_pos_system/lib/core/services/einvoice_service.dart`
- Reference: `/Users/andreahn/globos_pos_system/lib/core/services/payment_service.dart`
- Reference: `/Users/andreahn/globos_pos_system/lib/core/hardware/wifi_printer_service.dart`
- Reference: `/Users/andreahn/globos_pos_system/lib/core/services/attendance_service.dart`
- Create: `/Users/andreahn/globos_pos_system/docs/runtime_vendor_validation_results_2026-05-05.md`
- Create: `/Users/andreahn/globos_pos_system/docs/device_smoke_results_2026-05-05.md`
- Create: `/Users/andreahn/globos_pos_system/docs/launch_go_no_go_2026-05-05.md`
- Modify: `/Users/andreahn/globos_pos_system/.github/workflows/` by adding a Flutter validation workflow

## Owners

- Product owner: Hyochang
- App validation owner: POS engineer
- Vendor validation owner: backend/integration engineer
- Device smoke owner: field operator or QA with real Android tablet and printer

### Task 1: Freeze Current Baseline

**Files:**
- Reference: `/Users/andreahn/globos_pos_system/CLAUDE.md`
- Reference: `/Users/andreahn/globos_pos_system/docs/phase_3_verification_report.md`
- Test: `/Users/andreahn/globos_pos_system/test/`

- [ ] **Step 1: Record the current repository truth**

Run:

```bash
git status --short
flutter analyze
flutter test
```

Expected:

- local modifications are visible and intentionally preserved
- `flutter analyze` prints `No issues found!`
- `flutter test` ends with `All tests passed!`

- [ ] **Step 2: Save the baseline evidence**

Create `/Users/andreahn/globos_pos_system/docs/launch_go_no_go_2026-05-05.md` with:

```md
# Launch Go/No-Go Decision

## Baseline

- `flutter analyze`: PASS
- `flutter test`: PASS
- Existing Stage 1 repo verification: PASS

## Notes

- Record any dirty worktree files here.
- Record exact command timestamps here.
```

- [ ] **Step 3: Gate the rest of the plan on this baseline**

Pass rule:

- Continue only if both commands are green.
- If either command fails, fix the repo baseline before doing any launch validation.

### Task 2: Close WeTax Live Onboarding

**Files:**
- Reference: `/Users/andreahn/globos_pos_system/supabase/functions/wetax-onboarding/index.ts`
- Reference: `/Users/andreahn/globos_pos_system/docs/phase_3_verification_report.md`
- Create: `/Users/andreahn/globos_pos_system/docs/runtime_vendor_validation_results_2026-05-05.md`

- [ ] **Step 1: Identify every store still on placeholder tax setup**

Run against the real Supabase project:

```sql
select id, name, tax_entity_id
from public.restaurants
order by name;
```

Expected:

- every launch-target store is listed
- any store still using a placeholder tax entity is clearly identifiable

- [ ] **Step 2: For each launch-target store, execute WeTax onboarding closure**

Use the existing `wetax-onboarding` function operations in this order:

1. `seller_register`
2. `shops_register`
3. `seller_info`
4. `commons_refresh`

Expected:

- seller exists in `tax_entity`
- physical shop exists in `einvoice_shop`
- templates and `pos_key` are populated

- [ ] **Step 3: Save onboarding evidence**

Append to `/Users/andreahn/globos_pos_system/docs/runtime_vendor_validation_results_2026-05-05.md`:

```md
## WeTax Onboarding Closure

- Store:
- Tax code:
- seller_register: PASS/FAIL
- shops_register: PASS/FAIL
- seller_info: PASS/FAIL
- commons_refresh: PASS/FAIL
- Final `tax_entity_id` attached to restaurant: PASS/FAIL
```

- [ ] **Step 4: Apply the pass rule**

Pass rule:

- No launch-target store may remain on placeholder tax setup.
- Any store that fails onboarding is automatically `NO-GO`.

### Task 3: Re-Run Runtime Vendor Validation

**Files:**
- Reference: `/Users/andreahn/globos_pos_system/docs/runtime_vendor_validation_plan_2026-04-15.md`
- Reference: `/Users/andreahn/globos_pos_system/lib/core/services/einvoice_service.dart`
- Reference: `/Users/andreahn/globos_pos_system/lib/core/services/payment_service.dart`
- Create: `/Users/andreahn/globos_pos_system/docs/runtime_vendor_validation_results_2026-05-05.md`

- [ ] **Step 1: Execute a fresh WT03 payment path from the app**

Use a real payable order and complete payment through the existing cashier flow.

Expected:

- payment succeeds
- `einvoice_jobs` row is created
- `ref_id` exists

- [ ] **Step 2: Re-test WT06 manually on the fresh `ref_id`**

Use the same request shape documented in `/Users/andreahn/globos_pos_system/docs/runtime_vendor_validation_plan_2026-04-15.md`.

Expected:

- HTTP success
- returned row for the same `ref_id`
- `sid` and status fields available without server null/NPE behavior

- [ ] **Step 3: Re-test WT05 on the repo-generated payload**

Use the current `request_einvoice_payload` from a real red-invoice request.

Expected:

- no BigDecimal null error
- non-error vendor response

- [ ] **Step 4: Classify historical ref drift explicitly**

Run the documented comparison:

1. compare `einvoice_jobs.ref_id`
2. compare `send_order_payload.ref_id`
3. query WT06 with both values where historical rows are suspicious

Expected:

- each bad historical row is classified as either:
  - real vendor issue
  - historical ref drift
  - operator/data issue

- [ ] **Step 5: Make the polling decision**

Run:

```sql
select key, value
from public.system_config
where key = 'wetax_polling_enabled';
```

Pass rule:

- turn polling on only if fresh WT06 passes, WT05 passes, and historical rows are explicitly dispositioned
- otherwise keep polling off and mark launch as conditional

### Task 4: Run Real Android Device Smoke

**Files:**
- Reference: `/Users/andreahn/globos_pos_system/docs/payment_proof_wt09_smoke_test.md`
- Reference: `/Users/andreahn/globos_pos_system/integration_test/full_multi_account_smoke_test.dart`
- Create: `/Users/andreahn/globos_pos_system/docs/device_smoke_results_2026-05-05.md`

- [ ] **Step 1: Validate waiter order creation on device**

Run on a real Android tablet:

1. log in as waiter
2. create a buffet-capable order
3. add optional extra items
4. confirm table occupancy changes

Expected:

- order creation succeeds without store-boundary errors
- buffet base charge and extra items both appear

- [ ] **Step 2: Validate cashier payment on device**

Run:

1. log in as cashier on the same store
2. open the waiter-created order
3. complete payment

Expected:

- payment succeeds
- invoice job is created in the same flow

- [ ] **Step 3: Validate WT09 and payment proof paths**

Execute the full checklist in `/Users/andreahn/globos_pos_system/docs/payment_proof_wt09_smoke_test.md`.

Expected:

- cache-hit lookup works
- live WT09 fill works
- fallback remains manually submittable
- proof photo upload works
- offline queue recovery works if network is interrupted

- [ ] **Step 4: Validate delivery settlement confirmation**

Run:

1. log in with a role that can confirm settlement
2. confirm an accessible store settlement
3. try an inaccessible store path if available

Expected:

- allowed store succeeds
- blocked store is rejected

- [ ] **Step 5: Save device evidence**

Append to `/Users/andreahn/globos_pos_system/docs/device_smoke_results_2026-05-05.md`:

```md
## Device Smoke Matrix

- Device model:
- Android version:
- Store:
- Waiter order flow: PASS/FAIL
- Cashier payment flow: PASS/FAIL
- WT09 cache hit: PASS/FAIL
- WT09 live hit: PASS/FAIL
- WT09 fallback: PASS/FAIL
- Proof upload: PASS/FAIL
- Offline proof recovery: PASS/FAIL
- Delivery settlement confirm: PASS/FAIL
- Notes:
```

### Task 5: Validate Hardware Support Boundaries

**Files:**
- Reference: `/Users/andreahn/globos_pos_system/lib/core/hardware/wifi_printer_service.dart`
- Reference: `/Users/andreahn/globos_pos_system/lib/core/services/attendance_service.dart`
- Reference: `/Users/andreahn/globos_pos_system/lib/core/hardware/zkteco_fingerprint_service.dart`
- Create: `/Users/andreahn/globos_pos_system/docs/device_smoke_results_2026-05-05.md`

- [ ] **Step 1: Validate live printer behavior**

Run with a real supported printer:

1. test connection
2. print a live receipt
3. reprint the same receipt
4. verify Vietnamese text, totals, and paper width

Expected:

- TCP connection succeeds
- receipt is legible
- no clipped totals or broken glyphs

- [ ] **Step 2: Decide fingerprint support posture**

Current code truth:

- `upsertFingerprintTemplate` is disabled in `/Users/andreahn/globos_pos_system/lib/core/services/attendance_service.dart`
- `ZKTecoFingerprintService` exists only as device integration scaffolding

Decision rule:

- if fingerprint attendance is not being launched, mark it `OUT OF SCOPE FOR LAUNCH`
- if it is required for launch, the current product is `NO-GO` until end-to-end enrollment and matching are re-enabled

- [ ] **Step 3: Save the support boundary**

Append to `/Users/andreahn/globos_pos_system/docs/launch_go_no_go_2026-05-05.md`:

```md
## Hardware Support

- Wi-Fi printer support: PASS/FAIL
- Fingerprint attendance launch scope: INCLUDED/EXCLUDED
- Fingerprint launch verdict: GO/NO-GO
```

### Task 6: Finish Release Automation

**Files:**
- Reference: `/Users/andreahn/globos_pos_system/scripts/build_android.sh`
- Reference: `/Users/andreahn/globos_pos_system/scripts/build_web.sh`
- Modify: `/Users/andreahn/globos_pos_system/.github/workflows/` by adding a Flutter validation workflow

- [ ] **Step 1: Add a Flutter CI workflow**

Create a workflow that runs on pull requests and pushes to the main delivery branch with:

1. Flutter setup
2. dependency install
3. `flutter analyze`
4. `flutter test`
5. optional `flutter build apk --debug` or `flutter build web --release`

Expected:

- the app has at least one automated quality gate beyond the Photo Objet sales job

- [ ] **Step 2: Verify build scripts on a clean machine or CI runner**

Run:

```bash
./scripts/build_android.sh
./scripts/build_web.sh
```

Expected:

- Android APK artifact is produced
- web bundle is produced

- [ ] **Step 3: Define release artifacts**

Record in `/Users/andreahn/globos_pos_system/docs/launch_go_no_go_2026-05-05.md`:

```md
## Release Artifacts

- Android APK path:
- Web build path:
- Required secrets validated:
- Rollback owner:
```

### Task 7: Make the Go/No-Go Call

**Files:**
- Reference: `/Users/andreahn/globos_pos_system/docs/runtime_vendor_validation_results_2026-05-05.md`
- Reference: `/Users/andreahn/globos_pos_system/docs/device_smoke_results_2026-05-05.md`
- Modify: `/Users/andreahn/globos_pos_system/docs/launch_go_no_go_2026-05-05.md`

- [ ] **Step 1: Aggregate all pass/fail signals**

The final decision must include:

1. baseline repo health
2. WeTax onboarding closure
3. WT06 fresh-path result
4. WT05 fresh-path result
5. polling decision
6. Android device smoke
7. printer smoke
8. fingerprint scope decision
9. release automation state

- [ ] **Step 2: Use this decision table**

```md
## Final Verdict

- GO:
  - all P0 items pass
  - no launch-target store remains on placeholder tax setup
  - no legal reporting blocker remains

- CONDITIONAL GO:
  - core payment and reporting path passes
  - polling remains intentionally off
  - operating team accepts manual follow-up burden in writing

- NO-GO:
  - any launch-target store lacks real tax onboarding
  - fresh WT06 or WT05 fails
  - cashier payment flow fails on device
  - printer is required but unreadable in production conditions
```

- [ ] **Step 3: Publish the final note**

Fill the final section in `/Users/andreahn/globos_pos_system/docs/launch_go_no_go_2026-05-05.md`:

```md
## Final Verdict

- Verdict:
- Date:
- Decision owner:
- Blocking items:
- Accepted launch limitations:
- Next review date:
```

## Self-Review

- Spec coverage: this plan covers onboarding, vendor runtime, device smoke, hardware boundaries, release automation, and final decisioning
- Placeholder scan: no `TODO`, `TBD`, or deferred implementation placeholders remain in the plan steps
- Type consistency: file names, function names, and validation artifacts match the current repository references
