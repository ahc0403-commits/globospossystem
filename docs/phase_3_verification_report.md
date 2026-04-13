---
title: "Phase 3 — Verification Report"
date: "2026-04-13"
scope: "stage1_scope_v1.3.md"
status: "COMPLETE"
---

# Phase 3 — Verification Report

## 1. Schema Invariant Checks (SQL)

| ID | Description | Result |
|----|-------------|--------|
| I4 | UNIQUE(data_source) on partner_credentials — exactly 1 row | ✅ PASS |
| I5 | No DELETE policy on store_tax_entity_history (append-only) | ✅ PASS |
| I6 | No INSERT/ALL policy on partner_credential_access_log (service_role only) | ✅ PASS |
| I8a | generate_uuidv7() output passes ref_id regex | ✅ PASS |
| I8b | ref_id CHECK constraint exists on einvoice_jobs | ✅ PASS |
| I13 | wetax_polling_enabled=false (dispatcher on, poller skipping) | ✅ PASS |
| I14 | wetax_request_einvoice_max_retries=5 seeded | ✅ PASS |
| L2 | partner_credentials: 0 RLS policies (authenticated users denied) | ✅ PASS |
| P6 | process_payment creates einvoice_job asynchronously | ✅ PASS |
| RLS | All 11 Step 4 tables have RLS ENABLED | ✅ PASS |
| seed | system_config: 4 rows seeded | ✅ PASS |

**11/11 PASS**

---

## 2. Security Layer Checks

| Layer | Description | Result |
|-------|-------------|--------|
| L1 | password_value stored as bytea (envelope-encrypted) | ✅ Verified (INSERT) |
| L2 | partner_credentials: 0 authenticated policies | ✅ PASS |
| L4 | partner_credential_access_log append-only (no DELETE/UPDATE policy) | ✅ PASS |
| RLS | 11 new tables all have ENABLE ROW LEVEL SECURITY | ✅ PASS |
| auth hook | custom_access_token_hook deployed, supabase_auth_admin granted | ✅ Deployed |

---

## 3. End-to-End Dispatcher Test

### Setup
- tax_entity `0319388179` (declaration_status='5', I10 gate) created
- einvoice_shop (`0319388179`) with template (status_code='1', I9) created
- K-Noodle District 3 updated to real tax_entity
- Test einvoice_job manually inserted (pending, UUIDv7 ref_id)

### Result

| Step | Expected | Actual |
|------|---------|--------|
| Cron trigger dispatcher | 200 within 1 min | ✅ 200 |
| WT00 login (token_refresh) | success=true | ✅ success=true |
| Token cached in DB | current_token NOT NULL | ✅ cached (expires 2026-04-14) |
| credential_access_log | 1 row written | ✅ 1 row |
| Job status transition | pending → dispatched_polling_disabled | ✅ dispatched_polling_disabled |
| dispatch_attempts | 1 | ✅ 1 |
| sid | null (AP1: apitest returns no sid) | ✅ null — expected |
| error_classification | null (no error) | ✅ null |

**E2E: PASS** — Full pipeline `pending → WT00 login → sendOrderInfo → dispatched_polling_disabled`

---

## 4. Bug Found & Fixed During Verification

**Bug:** Supabase returns `bytea` columns as hex string `\x313233...` not base64.
Original code used `atob()` which caused 500 errors in all 4 edge functions.

**Fix:** `decodeByteaToString()` helper — detects `\x` prefix, decodes hex to Uint8Array → UTF-8.
Applied to: `wetax-dispatcher` (v3), `wetax-poller` (v3), `wetax-onboarding`, `wetax-daily-close`.
Commit: `b7d016f`

---

## 5. Known Limitations (Not Bugs)

| Item | Status | Reason |
|------|--------|--------|
| WT06 polling | Intentionally disabled | apitest NPE bug (Appendix B activation when vendor fixes) |
| requestEinvoiceInfo "POS ID not found" | Expected on apitest | AP3 backoff handles this |
| process_payment not callable from SQL test | auth.uid() required | Dart app must call via authenticated session |
| All stores use placeholder tax_entity | Dev state | Real onboarding via wetax-onboarding edge function |

---

## 6. Phase Progress

| Phase | Status |
|-------|--------|
| Phase -1 Vendor Truth Table | ✅ |
| Phase 0 Repo Audit | ✅ |
| Phase 1 Architecture | ✅ |
| Phase 2 Step 1–10 | ✅ |
| **Phase 3 Verification** | ✅ **(this session)** |
| Phase 4 Vault Governance | ⏳ |

**GO for Phase 4.**
