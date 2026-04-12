# Phase 2 Step 1 — Expected Behavior Baseline

> Generated 2026-04-12 from stage1_scope_v1.2.md, phase_minus_1_vendor_truth_table.md,
> phase_minus_1_unresolved_list.md, phase_1_architecture.md, wetax_openapi.json

Target: `https://apitest.wetax.com.vn`
Credentials: `webcashvietnam_test_api@gmail.com` / `12345679Aa`
Tax code: `0319388179` (GLOBOSVN)

---

## Category A: Authentication

### A1 — POST /api/wtx/pa/v1/auth/login (plaintext password)

**Expected per v1.2 Section 5.2:** Plaintext-first strategy. Send password as-is.
- If 200 OK: plaintext accepted, UR-01 resolved as NO_ENFORCEMENT
- If 401/400 with format error: plaintext rejected, UR-01 = CRITICAL blocker

**Expected response shape (OpenAPI):**
```json
{
  "status": { "success": true, "message": "success" },
  "data": {
    "access_token": "<JWT string>",
    "token_type": "Bearer",
    "expires_in": 7200  // OpenAPI example; PDF says 86400
  }
}
```

**Resolves:** UR-01 (AES256 enforcement), UR-02 (expires_in value), UR-03 (expires_in type)

### A4 — POST /auth/login with missing password

**Expected:** 400 with field validation error
**Resolves:** UR-04 (required flag enforcement)

---

## Category B: sendOrderInfo Shape

### B1 — POST /api/wtx/pa/v1/pos/sendOrderInfo

**Expected per OpenAPI:** Wrapper is `bills[]` containing `list_product[]` for line items.
- `pos_number`: number type (OpenAPI)
- `order_id`: number type (OpenAPI)
- `vat_rate`: number type, values 8 and 10 (OpenAPI, per DD-07)
- `payment_method`: "CASH" string from sendOrderInfo enum
- Prices are VAT-exclusive per v1.2

**Expected response (OpenAPI generic):**
```json
{
  "status": { "success": true, "message": "success" },
  "data": null
}
```
**PDF WT03 alternative:** Response may return `ref_id`, `sid`, `status` per DISC-14.

**Resolves:** UR-17 (maxLength), UR-18 (order_id type), UR-20 (pos_number type),
UR-21 (response shape), UR-22 (vat_rate type/format), UD-07 (sale_price)

### B4 — POST /api/wtx/pa/v1/pos/requestEinvoiceInfo

**Expected:** `order_id` and `pos_number` as strings (OpenAPI declares string).
**Resolves:** UR-13 (order_id type), UR-14 (pos_number type)

---

## Category C: Seller and Company Info

### C1/C2 — GET /api/wtx/pa/v1/seller-info

**Expected (OpenAPI):** No parameters. Token identifies seller.
**Expected (PDF):** `tax_code` as query param, required.
**Resolves:** UR-16 (tax_code input method), UD-05 (pos_key), UD-06 (end_point)

### C4 — GET /api/wtx/pa/v1/company/0319388179

**Expected (OpenAPI):** Response field is `data.tax_id`.
**Expected (PDF):** Response field is `data.tax_code`.
**Resolves:** UR-05 (tax_id vs tax_code field name)

---

## Category D: Commons Cache

### D1-D3 — GET commons/payment-methods, tax-rates, currency

**Expected:** All return `{ status: { code, message }, data: [...] }`
- payment-methods: codes like "TM/CK" (Vietnamese labels)
- tax-rates: codes like "5%", "8%", "10%", "KCT", "KKKNT"
- currency: codes like "VND"

**Resolves:** UR-11 (payment-methods relationship), UR-19 (accepted values — partial)

---

## Category E: Closing Store Format

### E1/E2 — POST /api/wtx/pa/v1/pos/shops/inform-closing-store

**Expected (OpenAPI):** `closing_time` as 8-char "yyyymmdd"
**Expected (PDF):** `closing_time` as 14-char "yyyymmddhhmmss"
**Expected (OpenAPI):** `total_order_count` as string
**Expected (PDF):** `total_order_count` as Number

**Resolves:** UR-06 (closing_time format), UR-07 (total_order_count type)

---

## Category F: Status Polling Shape

### F1 — POST /api/wtx/pa/v1/pos/invoices-status

**Expected (OpenAPI):** Request wrapper key `invoices` (array of strings)
**Expected (PDF):** Request wrapper key `data` (array of objects)
**Expected response status (OpenAPI):** `{ code, message }` pattern
**Expected response status (PDF):** `{ success, message }` pattern

**Resolves:** UR-08 (wrapper key), UR-09 (error_message field), UR-10 (status pattern)
