---
title: "Phase 2 WT06 Re-test — Audit Report"
date: "2026-04-12"
target: "https://apitest.wetax.com.vn"
classification: "STILL_NPE"
status: "complete"
---

# Phase 2 WT06 Re-test — Audit Report

> **Purpose:** Re-test CRITICAL 3 from phase_2_step_1_audit.md
> **Hypothesis:** invoices-status NPE caused by non-UUID ref_id format
> **Result:** **STILL_NPE** — hypothesis disproven

---

## Test Execution Summary

| Step | Action | Result |
|------|--------|--------|
| A1 | Generate UUIDv7 | `019d7fed-d105-7089-9650-5aa2f2799c74` |
| A2 | Validate UUID | Version=7, Variant=9 (10xx) — valid |
| B1 | sendOrderInfo with UUIDv7 ref_id | **200 OK** — accepted |
| C2 | invoices-status after 5s delay (OpenAPI shape) | **400 NPE** — same error |
| C5 | invoices-status (PDF shape fallback) | **400 "must not be empty"** — rejected |

---

## CRITICAL — Unresolved

### CRITICAL 3 (revised): invoices-status server-side NPE is NOT caused by ref_id format

- **Original hypothesis:** The NPE `Cannot invoke "java.util.UUID.toString()" because ... getGuid() is null` was caused by the server trying to parse a non-UUID ref_id string.
- **Test:** Sent a valid UUIDv7 (`019d7fed-d105-7089-9650-5aa2f2799c74`) via sendOrderInfo (200 OK), waited 5 seconds, then polled invoices-status with the same UUIDv7.
- **Result:** Identical NPE. `POSSaleMaster.getGuid()` still returns null.
- **Revised analysis:** The NPE occurs because the server's internal `POSSaleMaster` entity does not have a populated `guid` field for the order we submitted. Three possible explanations:

  1. **Async processing pipeline:** sendOrderInfo acceptance (200 OK) does not mean the order is immediately queryable. The server may have an internal queue or batch process that populates `POSSaleMaster.guid` asynchronously. 5 seconds may be insufficient.

  2. **ref_id is not the lookup key for invoices-status:** The server may use a different internal identifier (possibly the `sid` that the PDF says is returned by WT03 but that sendOrderInfo does NOT return). If so, invoices-status cannot be used until we obtain the sid through another mechanism.

  3. **apitest server bug:** The `sendOrderInfo` endpoint on apitest may not fully process orders (it accepts them but does not complete the pipeline that would populate `POSSaleMaster.guid`). This would be an environment-specific limitation.

- **Impact on Stage 1:** The WT06 polling worker (scope v1.2 Section 6.5) cannot function on apitest as currently configured. This blocks validation of: `sid` retrieval, `cqt_report_status`, `issuance_status`, `lookup_url`, `email_status`, and the full job lifecycle from `dispatched` → `reported` / `issued_by_portal`.

- **Fix:** This requires vendor interaction. Draft a vendor bug report / inquiry to the WeTax partnership team:
  > "We are calling POST /pos/sendOrderInfo (200 OK accepted), then POST /pos/invoices-status with the same ref_id. The server returns 400 with `POSSaleMaster.getGuid() is null`. Does invoices-status require a different lookup key (e.g., sid)? Is there a processing delay we should wait for? Is there an apitest environment limitation?"

---

## HIGH — Adjustments Required

### H1. Dispatcher must be designed to tolerate invoices-status failures

Since WT06 polling cannot be validated on apitest, the dispatcher design must:
- Treat invoices-status as a best-effort status enrichment, not a critical path
- Default `einvoice_jobs` to `dispatched` after sendOrderInfo 200 with `sid = NULL`
- Surface a "polling unavailable" indicator in the admin dashboard rather than blocking
- The `lookup_url` for "Open in WeTax Portal" must have a fallback: construct a manual URL from `end_point` ("webcashvn") + `ref_id`, or disable the button until polling succeeds

### H2. ref_id format decision stands: use UUIDv7

Even though UUIDv7 did not fix the NPE, the scope v1.2 decision to use UUIDv7 for `einvoice_jobs.ref_id` remains correct:
- sendOrderInfo accepts it (confirmed)
- It provides sortable, unique identifiers as specified in scope Section 3.1
- Invariant I8 (ref_id immutability) is satisfied
- When invoices-status eventually works (production or after vendor fix), UUIDv7 will be the format already in use

---

## RESOLVED

### CRITICAL 3 classification: **STILL_NPE**

WT06 invoices-status returns the same `POSSaleMaster.getGuid() is null` NullPointerException regardless of whether ref_id is:
- An arbitrary string (`GLOBOS-TEST-20260412110521-001`) — initial audit
- A valid UUIDv7 (`019d7fed-d105-7089-9650-5aa2f2799c74`) — this re-test

The root cause is **server-side**, not client-side. The `guid` field on `POSSaleMaster` is not populated for orders submitted via `sendOrderInfo` on apitest. This requires a **vendor bug report or inquiry**.

### Confirmed in this re-test

| Finding | Status |
|---------|--------|
| sendOrderInfo accepts UUIDv7 ref_id | **Confirmed** (200 OK) |
| invoices-status `invoices` key is correct | **Confirmed** (server processes it, NPE is during lookup not key parsing) |
| invoices-status `data` key is incorrect | **Confirmed** ("must not be empty") |
| invoices-status response uses `{success, message}` | **Confirmed** (not `{code, message}`) |
| NPE is reproducible and consistent | **Confirmed** (same error across two sessions, two ref_id formats) |

---

## Priority Next Action

**Draft vendor bug report and stop re-test sequence.** Invoices-status polling cannot be validated until the vendor confirms the expected behavior for `POSSaleMaster.guid` population on apitest. Phase 2 Steps 2-6 (schema, rename, tables, RLS) can proceed in parallel — they do not depend on WT06 polling validation. Step 7 (edge functions) should implement the polling worker with the `invoices` key and UUIDv7 ref_id, but mark the polling integration test as blocked pending vendor response.
