---
title: "Phase 2 Step 1 — API Validation Audit Report"
date: "2026-04-12"
target: "https://apitest.wetax.com.vn"
credentials: "webcashvietnam_test_api@gmail.com"
tax_code: "0319388179"
status: "complete"
---

# Phase 2 Step 1 — API Validation Audit Report

> **Target:** apitest.wetax.com.vn | **Date:** 2026-04-12
> **Total endpoints tested:** 12 calls across 6 categories
> **Samples saved to:** `docs/vendor/samples/01_*.json` through `12_*.json`

---

## CRITICAL — Spec/Runtime Violations Blocking Phase 2 Step 4+

### C1. sendOrderInfo returns no `sid` (UR-21)

- **UR-21 reference**
- **Expected:** Per Phase -1 truth table (DISC-14), PDF WT03 returns `{ref_id, sid, status}` in an array. OpenAPI documents `data: null`.
- **Actual:** `{"status": {"success": true, "message": "Success"}, "data": ""}` — data is **empty string**, not null, and contains no `sid`, no `ref_id` echo, no structured data whatsoever.
- **Impact on Stage 1 design:** The dispatcher (scope v1.2 Section 6.3 Step 5) assumes it can extract `sid` from the sendOrderInfo response and store it on `einvoice_jobs.sid`. This is impossible — `sid` is only obtainable from WT06 (invoices-status) polling.
- **Fix:** Amend dispatcher design: after sendOrderInfo 200, set `status = 'dispatched'` and `sid = NULL`. The polling worker (WT06) must populate `sid` from the first successful invoices-status response. `einvoice_jobs.sid` must be nullable and populated asynchronously. This is a design adjustment, not a blocker.

### C2. WT09 company/{tax_code} server-side NPE (UR-05)

- **UR-05 reference**
- **Expected:** 200 response with company data including `tax_id` (OpenAPI) or `tax_code` (PDF) field.
- **Actual:** `{"status": {"success": false, "message": "Cannot invoke \"String.isEmpty()\" because the return value of \"com.kosign.wetax.service.cooconapi.payload.RegistrationDetail.getCloseDate()\" is null"}, "data": ""}` — HTTP 400 with Java NPE.
- **Impact on Stage 1 design:** WT09 auto-fill in B2B buyer onboarding (scope Section 7.4 Step 2) and new customer onboarding (Section 7.1 Step 2) cannot function if the company endpoint is broken. Cannot determine whether field is `tax_id` or `tax_code`.
- **Fix:** Test against `apidev.wetax.com.vn` to confirm whether this is apitest-specific. If broken on both, file vendor bug report. For Phase 2 implementation: make WT09 auto-fill a graceful degradation feature — if the call fails, cashier enters data manually. Default to `tax_id` as field name (OpenAPI is authoritative).

### C3. invoices-status NPE on ref_id lookup (UR-09 partial)

- **UR-09 reference**
- **Expected:** Response with status of dispatched invoices, including `error_message` field per PDF.
- **Actual:** `{"status": {"success": false, "message": "Cannot invoke \"java.util.UUID.toString()\" because ... getGuid() is null"}, "data": ""}` — NPE when looking up our ref_id.
- **Impact on Stage 1 design:** The NPE reveals the server expects an internal GUID format for ref_id, not arbitrary strings. Our test ref_id `GLOBOS-TEST-20260412110521-001` was accepted by sendOrderInfo but cannot be found by invoices-status. This may mean: (a) sendOrderInfo assigns its own GUID internally and ignores our ref_id for lookup purposes, or (b) our ref_id format breaks the UUID parser.
- **Fix:** Phase 2 must use proper UUIDv4/v7 format for ref_id values (not arbitrary strings). Amend scope v1.2: ref_id must be valid UUID format. Re-test invoices-status after sending an order with UUID ref_id to confirm. If still broken, the polling lookup key may be different from ref_id.

---

## HIGH — Mismatches Resolvable by Adjustment

### H1. seller-info: `pos_key` absent from response (UD-05)

- **Expected:** OpenAPI documents `data.declaration.pos_key` — "POS Key (for Cash Register invoice form)".
- **Actual:** `declaration` contains only `{register_date, status, name}`. No `pos_key` field.
- **Impact:** `tax_entity.pos_key` column in scope v1.2 Section 3.1 cannot be populated from WT01. If `pos_key` is needed for CQT code composition, it must come from another source.
- **Fix:** Make `tax_entity.pos_key` nullable. It may be populated by a different endpoint or may be unnecessary for the POS use case (CQT code may be composed server-side by WeTax). Verify with vendor if needed.

### H2. seller-info: declaration uses `status` not `status_code` 

- **Expected:** OpenAPI documents `data.declaration.status_code` with values 3/5/6.
- **Actual:** Field is named `status` (string "5"), with a separate `name` field ("Accepted") instead of `status_name`.
- **Impact:** Dispatch gate check (scope Section 6.3 Step 2) compares `declaration_status != '5'`. Field name in code must reference `status`, not `status_code`.
- **Fix:** In `tax_entity` schema and onboarding code, use field name `status` from the API response. Minor naming adjustment.

### H3. seller-info: no top-level `data.template[]` array (DISC-27)

- **Expected:** OpenAPI has both `data.shops[].templates[]` (per-shop) and `data.template[]` (top-level).
- **Actual:** Only `data.shops[].templates[]` exists. Top-level keys are `[declaration, shops, end_point]`.
- **Impact:** Template data is only available at the shop level. The onboarding code must iterate `shops[].templates[]` to populate `einvoice_shop.templates`.
- **Fix:** Remove any reference to top-level `data.template[]` in the implementation. Use only `shops[].templates[]`.

### H4. commons/payment-methods are a separate system from sendOrderInfo enum (UR-11, UR-19)

- **Expected:** Potential overlap between commons/payment-methods codes and sendOrderInfo `payment_method` enum.
- **Actual:** Commons returns Vietnamese accounting codes: `TM`, `CK`, `TM/CK`, `CC`, `BT`, etc. sendOrderInfo accepted `CASH` directly. These are **two completely separate classification systems**.
- **Impact:** The `wetax_reference_values` table will store commons codes (for invoice display/accounting), while the dispatcher uses the sendOrderInfo enum (CASH, CREDITCARD, etc.) for dispatch. The mapping table in scope Section 9 must clarify this distinction.
- **Fix:** Add a comment to `wetax_reference_values` schema: commons/payment-methods codes are for einvoice display, NOT for sendOrderInfo dispatch. The POS payment_method enum (scope Section 3.1 payments) maps directly to sendOrderInfo enum values.

### H5. requestEinvoiceInfo: "POS ID not found" for recently-sent order

- **Expected:** After sendOrderInfo 200, requestEinvoiceInfo should find the order by `store_code + pos_number + order_id + order_date`.
- **Actual:** Both string and number types for pos_number/order_id returned `"POS ID not found."` (HTTP 400).
- **Impact:** There may be a processing delay between sendOrderInfo acceptance and requestEinvoiceInfo availability. Or the matching logic requires exact field type/format consistency.
- **Fix:** In the dispatcher, add a configurable delay (e.g., 5 seconds) between sendOrderInfo and requestEinvoiceInfo calls. If still failing, investigate whether a different lookup key is needed. This is a Phase 2 Step 7 concern.

---

## MEDIUM — Field Name or Type Confirmations

### M1. `expires_in` = 86400 (24 hours), type number (UR-02, UR-03)

- **Expected (OpenAPI):** 7200 (2h), type number. **Expected (PDF):** 86400 (24h), type String(10).
- **Actual:** `86400` as JavaScript number.
- **Resolution:** PDF value (86400) was correct. OpenAPI type (number) was correct. Token refresh at `86400 - 900 = 85500` seconds (23h 45m).

### M2. `invoices-status` wrapper key is `invoices` (UR-08)

- **Expected (OpenAPI):** `invoices` (array of strings). **Expected (PDF):** `data` (array of objects).
- **Actual:** `invoices` key accepted (server processed the request, hit NPE on lookup). `data` key returned "must not be empty" (server ignored it).
- **Resolution:** OpenAPI was correct. Use `invoices` as array of ref_id strings.

### M3. `invoices-status` response uses `{success, message}` pattern (UR-10)

- **Expected (OpenAPI):** `{code, message}`. **Expected (PDF):** `{success, message}`.
- **Actual:** `{"success": false, "message": "..."}` — boolean `success` + string `message`.
- **Resolution:** PDF pattern was correct. Dispatcher response parser should check `status.success` (boolean), not `status.code` (string).

### M4. `inform-closing-store` accepts both time formats (UR-06)

- **Expected (OpenAPI):** 8-char yyyymmdd. **Expected (PDF):** 14-char yyyymmddhhmmss.
- **Actual:** Both formats accepted (200 OK for both).
- **Resolution:** Use 14-char format `yyyymmddhhmmss` for precision (daily close edge function sends `{date}000000` for 00:00).

### M5. `inform-closing-store` accepts both string and number for total_order_count (UR-07)

- **Expected (OpenAPI):** string. **Expected (PDF):** Number.
- **Actual:** Both accepted.
- **Resolution:** Use string for consistency with OpenAPI spec. `String(orderCount)` in the edge function.

### M6. `vat_rate` accepts numbers (UR-22)

- **Expected (OpenAPI):** number, example `8`. **Expected (PDF):** String(11), values like `"10%"`, `"KCT"`.
- **Actual:** Numbers `8` and `10` accepted in sendOrderInfo.
- **Resolution:** OpenAPI was correct. Send `vat_rate` as numeric (8 for food, 10 for alcohol).

### M7. `pos_number` and `order_id` type flexibility (UR-13, UR-14, UR-18, UR-20)

- **sendOrderInfo:** Accepted as numbers (UR-18, UR-20 confirmed).
- **requestEinvoiceInfo:** Both string and number accepted structurally (no type error — "POS ID not found" is a business error, not type rejection).
- **Resolution:** Use number type for sendOrderInfo, string type for requestEinvoiceInfo (matching each endpoint's OpenAPI declaration). Both work, but follow the spec for each endpoint.

---

## LOW — Minor Observations

### L1. seller-info response is very large (37 shops × ~50 templates each)

The test account has 37 shops, each with 47-53 templates. The full response is ~480KB. In production, this should be cached aggressively (scope Section 9 already plans this).

### L2. Commons endpoints use `{success, message}` response pattern (not `{code, message}`)

All three commons endpoints returned `{"success": true, "message": "Success"}`. The OpenAPI documented `{code, message}` for commons but actual server uses the same `{success, message}` pattern as other endpoints. Parser should use `status.success` uniformly.

### L3. All error responses return `data: ""` (empty string)

Across all error responses, `data` is consistently empty string `""`, never `null`, never omitted. Parser should handle both `""` and `null` for robustness.

### L4. JWT structure: RS256, scope=SYS_ADMIN, issuer=PARTNER

The JWT uses RS256 algorithm (RSA). Claims include `sub` (email), `scope` (SYS_ADMIN), `iss` (PARTNER), `name` (email), `exp`, `iat`. No custom claims relevant to POS dispatch.

### L5. seller-info: shop templates use `symbol` not separate `form_no`/`serial_no`

OpenAPI documented `symbol` at shop level; PDF documented separate `form_no`/`serial_no`. Actual: templates have `symbol`, `start_date`, `status_code`, `status_name`. The `symbol` field contains the combined form+serial (e.g., "1C26TKT"). `einvoice_shop.templates` JSONB should store `{symbol, start_date, status_code}`.

### L6. seller-info: `tax_code` param is optional and ignored

Both `GET /seller-info` and `GET /seller-info?tax_code=0319388179` return identical responses. The JWT identifies the seller. No need to send tax_code.

### L7. tax-rates include custom KHAC rates

Beyond standard 0%, 5%, 8%, 10%, KCT, KKKNT, the server also returns `KHAC:X.X%` custom rates (4%, 6%, 7.5%, 8%, 10%). These are for other industries; F&B only needs 8% and 10%.

---

## CONFIRMED WORKING

| ID | Description | Status |
|----|-------------|--------|
| **UR-01** | AES256 password enforcement | **RESOLVED: NOT ENFORCED** — plaintext accepted on apitest |
| **UR-02** | expires_in value | **RESOLVED: 86400** (24h, PDF was correct) |
| **UR-03** | expires_in type | **RESOLVED: number** (OpenAPI was correct) |
| **UR-04** | Required field enforcement | **RESOLVED: YES** — "password can not be null" on missing field |
| **UR-06** | closing_time format | **RESOLVED: BOTH** 8-char and 14-char accepted |
| **UR-07** | total_order_count type | **RESOLVED: BOTH** string and number accepted |
| **UR-08** | invoices-status wrapper key | **RESOLVED: `invoices`** (OpenAPI correct) |
| **UR-10** | invoices-status response pattern | **RESOLVED: `{success, message}`** (PDF correct) |
| **UR-11** | payment-methods relationship | **RESOLVED: SEPARATE SYSTEMS** — commons ≠ sendOrderInfo enum |
| **UR-16** | seller-info tax_code param | **RESOLVED: OPTIONAL** — JWT identifies seller |
| **UR-17** | sendOrderInfo maxLength | **RESOLVED: NO REJECTION** — no length errors observed |
| **UR-18** | sendOrderInfo order_id type | **RESOLVED: number** accepted |
| **UR-19** | sendOrderInfo payment_method values | **RESOLVED: "CASH" accepted** — sendOrderInfo enum works |
| **UR-20** | sendOrderInfo pos_number type | **RESOLVED: number** accepted |
| **UR-21** | sendOrderInfo response shape | **RESOLVED: `{success, message}` + `data: ""`** — no sid |
| **UR-22** | vat_rate type/format | **RESOLVED: number** (8, 10 accepted) |
| **UD-05** | seller-info pos_key | **RESOLVED: NOT PRESENT** in response |
| **UD-06** | seller-info end_point | **RESOLVED: "webcashvn"** at `data.end_point` |
| **UD-07** | sendOrderInfo sale_price | **RESOLVED: OPTIONAL** — not sent, no error |
| **DD-07** | VAT rate as number | **CONFIRMED** — food=8, alcohol=10 as numbers |

## STILL OPEN

| ID | Description | Status | Reason |
|----|-------------|--------|--------|
| **UR-05** | company/{tax_code} field name | **BLOCKED** | Server NPE on apitest — cannot inspect response |
| **UR-09** | invoices-status error_message field | **BLOCKED** | Server NPE on ref_id lookup — cannot get successful response |
| **UR-12** | pos/shops POST request schema | **NOT TESTED** | Out of scope for this audit (shop creation not in test plan) |
| **UR-13** | requestEinvoiceInfo order_id type | **PARTIAL** | Both types accepted structurally, but "POS ID not found" |
| **UR-14** | requestEinvoiceInfo pos_number type | **PARTIAL** | Same as UR-13 |
| **UR-15** | resend-email required flags | **NOT TESTED** | No issued invoice available to test resend |

---

## Priority Fix List

1. **[CRITICAL]** Amend dispatcher design: `einvoice_jobs.sid` must be nullable, populated by WT06 polling — `docs/vendor/phase_2_step_1_expected.md`, `stage1_scope_v1.2.md` Section 6.3 — sendOrderInfo returns no sid
2. **[CRITICAL]** Use UUID format for `ref_id` values — `einvoice_jobs.ref_id` generation — invoices-status NPE suggests UUID parser expectation; re-test with UUIDv4 ref_id
3. **[CRITICAL]** Add graceful degradation for WT09 company endpoint — `stage1_scope_v1.2.md` Section 7.1/7.4 — server NPE blocks auto-fill; manual entry must work as fallback
4. **[HIGH]** Make `tax_entity.pos_key` nullable — `phase_1_architecture.md` ERD — field not returned by seller-info
5. **[HIGH]** Fix declaration field name: `status` not `status_code` — dispatcher gate check, `tax_entity.declaration_status` population code
6. **[HIGH]** Use only `shops[].templates[]` for template data — remove any reference to top-level `data.template[]`
7. **[HIGH]** Add delay between sendOrderInfo and requestEinvoiceInfo in dispatcher — Phase 2 Step 7 edge function
8. **[MEDIUM]** Add comment distinguishing commons payment codes from sendOrderInfo enum — `wetax_reference_values` schema
9. **[MEDIUM]** Use 14-char format for `closing_time` — daily close edge function
10. **[MEDIUM]** Use `status.success` (boolean) uniformly in all response parsers — not `status.code`
11. **[LOW]** Store templates as `{symbol, start_date, status_code}` — `einvoice_shop.templates` JSONB design
12. **[LOW]** Handle `data: ""` (empty string) in all response parsers alongside `data: null`
