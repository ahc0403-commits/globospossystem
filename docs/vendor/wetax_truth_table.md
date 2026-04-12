---
title: "WeTax Vendor Truth Table — Phase -1"
version: "1.0"
date: "2026-04-12"
source_primary: "wetax_openapi.json (OpenAPI v1.4.0, extracted from apidev.wetax.com.vn)"
source_secondary: "[EN] POS - WeTax API Development Guide v1.0 (2026-04-10)"
scope_basis: "stage1_scope_v1.md Section 2 — In Scope endpoints only"
status: "complete"
---

# WeTax Vendor Truth Table — Phase -1

## CRITICAL WARNINGS

> **W1.** The OpenAPI spec was extracted from `https://apidev.wetax.com.vn` (development server).
> Behavior on `apitest.wetax.com.vn` and `api.wetax.com.vn` **may differ**.
>
> **W2.** Phase 2 MUST validate all field names, required flags, and type expectations
> against `apitest.wetax.com.vn` before committing to any schema design.
>
> **W3.** The OpenAPI spec (v1.4.0, 2024-09-06) and the PDF guide (v1.0, 2026-04-10)
> document **different endpoint sets**. The PDF covers legacy WT03/WT04/WT05;
> the OpenAPI adds `sendOrderInfo` and `requestEinvoiceInfo` which **supersede** WT03/WT05.
> Per scope doc Section 0: "When PDF and OpenAPI disagree, OpenAPI is authoritative."
>
> **W4.** The OpenAPI spec contains structural anomalies (duplicate schemas, inconsistent
> types for the same conceptual field, schema naming mismatches). All are documented below.

---

## Table of Contents

1. [WT00 — auth/login](#1-wt00--authlogin)
2. [sendOrderInfo](#2-sendorderinfo)
3. [requestEinvoiceInfo](#3-requesteinvoiceinfo)
4. [WT06 — invoices-status](#4-wt06--invoices-status)
5. [WT07 — resend-email](#5-wt07--resend-email)
6. [WT08 — inform-closing-store](#6-wt08--inform-closing-store)
7. [WT01 — seller-info](#7-wt01--seller-info)
8. [WT09 — company/{tax_code}](#8-wt09--companytax_code)
9. [commons/payment-methods](#9-commonspayment-methods)
10. [commons/tax-rates](#10-commonstax-rates)
11. [commons/currency](#11-commonscurrency)
12. [agency/sellers](#12-agencysellers)
13. [agency/seller-shops](#13-agencyseller-shops)
14. [WT02 — pos/shops (POST)](#14-wt02--posshops-post)
15. [pos/shops (GET)](#15-posshops-get)
16. [Discrepancy Register](#discrepancy-register)
17. [UNDESCRIBED Fields](#undescribed-fields)
18. [UNRESOLVED Items](#unresolved-items)

---

## 1. WT00 — auth/login

| Property | Value |
|----------|-------|
| **Method** | `POST` |
| **URL** | `/api/wtx/pa/v1/auth/login` |
| **Security** | None (this endpoint issues the token) |
| **Tags** | Authentication |

### Request — `UserModelRequest`

| Field | Type | Required | maxLength | Description | Example |
|-------|------|----------|-----------|-------------|---------|
| `user_id` | string | **UNRESOLVED** (not in `required` array, but PDF says Yes) | 100 (PDF) | User's login ID | `webcashvietnam_test_api@gmail.com` |
| `password` | string | **UNRESOLVED** (same) | 100 (PDF) | User's login password (AES256 Encryption) | `12345679Aa` |

> **Note:** OpenAPI defines NO `required` array on `UserModelRequest`. PDF marks both fields as Required=Yes.

### Response 200 — `UserModelResponse200`

| Field | Type | Required | Description | Example |
|-------|------|----------|-------------|---------|
| `status.success` | boolean | — | — | `true` |
| `status.message` | string | — | — | `"success"` |
| `data.access_token` | string | Yes (in `required` array) | Access token | (JWT string) |
| `data.token_type` | string | Yes | Token type | `"Bearer"` |
| `data.expires_in` | number | Yes | Token expiration in seconds | `7200` |

### Error Responses

| Code | Schema | Message Pattern |
|------|--------|-----------------|
| 400 | `ApiResponse400` | `"Invalid: parameter"` |
| 401 | `ApiResponse400` (**NOT** ApiResponse401 — see DISC-01) | `"API key or partnership wrong!"` |
| 409 | `ApiResponse409` | `"This response is sent when a request conflicts with the current state of the server."` |

### PDF Discrepancies

- **DISC-01:** OpenAPI 401 response references `ApiResponse400`, not `ApiResponse401`. Likely spec error.
- **DISC-02:** PDF says `expires_in` default is 86400 (24h). OpenAPI example shows 7200 (2h). Actual value is runtime-dependent — **must validate in Phase 2**.
- **DISC-03:** PDF says `expires_in` type is `String(10)`. OpenAPI says `number`. **Must validate in Phase 2.**
- **DISC-04:** PDF documents `maxLength` for `user_id` (100) and `password` (100). OpenAPI specifies no maxLength.
- **DISC-05:** PDF states password requires AES256 encryption. OpenAPI description confirms this. Whether `apitest` enforces encryption is **UNRESOLVED** — Phase 2 validation step will test plaintext.

---

## 2. sendOrderInfo

| Property | Value |
|----------|-------|
| **Method** | `POST` |
| **URL** | `/api/wtx/pa/v1/pos/sendOrderInfo` |
| **Security** | Bearer JWT (`Authorization` header) |
| **Tags** | POS Invoice |
| **Summary** | "Send the bill information." |

### Request — `SendBillInfoModelRequest`

Top-level wrapper:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `bills` | array of objects | — | Array of bill objects |

#### `bills[]` item fields

| Field | Type | Required | maxLength | Description | Example |
|-------|------|----------|-----------|-------------|---------|
| `ref_id` | string | No | — | Invoice ID | `"163003230305273"` |
| `store_code` | string | **Yes** | — | Store Code | `"111103"` |
| `store_name` | string | No | — | Store Name | `"DUONG BA TRAC"` |
| `order_date` | string | **Yes** | — | Order created date | `"20230731"` |
| `order_time` | string | No | — | Order created time | `"202307310830"` |
| `pos_number` | **number** | No | — | POS Number | `3` |
| `order_id` | **number** | No | — | Order id (Bill number) | `3` |
| `trans_type` | number | No | — | 1: Order, 2: Return | `1` |
| `payment_method` | string | No | — | VNPAY, SHOPEEPAY, MOMO, ZALOPAY, CASH, VOUCHER, CREDITSALE, ATM, CREDITCARD | `"CASH"` |
| `list_product` | array | No | — | Product line items | — |

**`required` array (exact):** `["order_date", "store_code", "pos_number", "order_id"]`

> **CRITICAL NOTE:** `pos_number` and `order_id` are in the `required` array but their types are `number`, not `string`. See DISC-08/DISC-09 for type conflicts with `requestEinvoiceInfo`.

#### `bills[].list_product[]` item fields

| Field | Type | Required | maxLength | Description | Example | Notes |
|-------|------|----------|-----------|-------------|---------|-------|
| `item_code` | string | No | — | Product Code | `"228785"` | |
| `item_name` | string | **Yes** | — | Product Name | `"GA RAN PHAN"` | |
| `unit_price` | number | **Yes** | — | Unit Price | `67000` | |
| `quantity` | number | **Yes** | — | Quantity | `2` | |
| `sale_price` | number | No | — | SALE PRICE (include VAT) | — | **UNDESCRIBED** — no further detail in spec |
| `uom` | string | **Yes** | — | Unit of measure | `"EA"` | |
| `total_amount` | number | **Yes** | — | Total amount excluding tax | `197222` | |
| `vat_rate` | number | No | — | Tax rate (percentage) | `8` | |
| `vat_amount` | number | No | — | Tax amount | `15778` | |
| `paying_amount` | number | **Yes** | — | Total amount including tax | `213000` | |

**`required` array (exact):** `["item_name", "unit_price", "quantity", "uom", "total_amount", "paying_amount"]`

### Response 200 — `ApiResponse200`

| Field | Type | Example |
|-------|------|---------|
| `status.success` | boolean | `true` |
| `status.message` | string | `"success"` |
| `data` | object | `null` |

### Error Responses

| Code | Schema | Message Pattern |
|------|--------|-----------------|
| 400 | `ApiResponse400` | `"Invalid: parameter"` |
| 401 | `ApiResponse401` | `"E_INVALID_JWT_TOKEN: jwt must be provided"` |
| 409 | `ApiResponse409` | `"This response is sent when a request conflicts..."` |

### PDF Discrepancies

- **DISC-06:** PDF documents WT03 (`/pos/invoices`) with `invoices[]` wrapper and `invoice_details[]`/`products[]` for line items. OpenAPI `sendOrderInfo` uses `bills[]` wrapper and `list_product[]`. These are **different endpoints** — sendOrderInfo supersedes WT03. Field sets differ significantly.
- **DISC-07:** PDF WT03 includes buyer fields (`buyer_comp_name`, `buyer_comp_tax_code`, etc.), `currency_code`, `exchange_rate`, `bill_no`, `cqt_code`. OpenAPI `sendOrderInfo` has **none of these**. This confirms scope doc principle: "sendOrderInfo does NOT contain any buyer fields."
- **DISC-08:** `pos_number` type is `number` in sendOrderInfo but `string` in requestEinvoiceInfo. **UNRESOLVED** — Phase 2 must test which type the server actually accepts.
- **DISC-09:** `order_id` type is `number` in sendOrderInfo but `string` in requestEinvoiceInfo. **UNRESOLVED** — same.
- **DISC-10:** OpenAPI specifies NO `maxLength` on any sendOrderInfo field. PDF WT03 specifies maxLength on all fields (e.g., ref_id: 100, store_code: 50, item_name: 500). Since these are different endpoints, PDF maxLength values may or may not apply. **UNRESOLVED.**
- **DISC-11:** PDF WT03 line items have `dc_rate`, `dc_amt`, `feature`, `seq` fields. OpenAPI `list_product` has `sale_price` instead. Different field sets.
- **DISC-12:** PDF WT03 `payment_method` default is `"TM/CK"`. OpenAPI `sendOrderInfo` lists enum: VNPAY, SHOPEEPAY, MOMO, ZALOPAY, CASH, VOUCHER, CREDITSALE, ATM, CREDITCARD. No overlap with `TM/CK`. **UNRESOLVED** — does sendOrderInfo accept `TM/CK` as well?
- **DISC-13:** PDF WT03 `vat_rate` is type `String(11)` with values like `"10%"`, `"KCT"`. OpenAPI `sendOrderInfo.list_product.vat_rate` is type `number` with example `8`. **UNRESOLVED** — critical difference.
- **DISC-14:** OpenAPI `sendOrderInfo` response is generic `ApiResponse200` (`data: null`). PDF WT03 response returns array with `ref_id`, `sid`, `status.code`, `status.message`. **UNRESOLVED** — actual sendOrderInfo response shape unknown until Phase 2.

---

## 3. requestEinvoiceInfo

| Property | Value |
|----------|-------|
| **Method** | `POST` |
| **URL** | `/api/wtx/pa/v1/pos/requestEinvoiceInfo` |
| **Security** | Bearer JWT (`Authorization` header) |
| **Tags** | POS Invoice |
| **Summary** | "Request e-invoice information when Customers request to issue invoice and input invoice information in the bill." |

### Request — `GetEinvoiceInfoModelRequest`

Top-level wrapper:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `bills` | array of objects | — | Array of bill objects |

#### `bills[]` item fields

| Field | Type | Required | maxLength | Description | Example | Notes |
|-------|------|----------|-----------|-------------|---------|-------|
| `ref_id` | string | No | — | Invoice ID | `"1111032023073131769"` | |
| `tax_id` | string | No | — | Tax Code | `"309682527"` | |
| `tax_company_name` | string | No | — | Company name registered with Tax | `"Webcash Vietnam"` | |
| `tax_address` | string | No | — | Company address | (long address string) | |
| `tax_buyer_name` | string | No | — | Buyer name | `""` | |
| `receiver_email` | string | **Yes** | — | Email to receive e-invoice | `"ngocthai@lotte.vn"` | |
| `receiver_email_cc` | string | No | — | Email CC to receive e-invoice | `"nuri@wetax.vn"` | |
| `order_date` | string | **Yes** | — | Order Date | `"20230731"` | |
| `store_code` | string | **Yes** | — | Store Code | `"111103"` | |
| `store_name` | string | No | — | Store Name | `"Duong Ba Trac"` | |
| `pos_number` | **string** | No | — | POS Number | `3` (example is number despite string type) | **UNDESCRIBED** — example conflicts with declared type |
| `order_id` | **string** | No | — | Order ID | `1769` (example is number despite string type) | **UNDESCRIBED** — example conflicts with declared type |

**`required` array (exact):** `["receiver_email", "order_date", "store_code", "pos_number", "order_id"]`

> **NOTE:** `pos_number` and `order_id` are required, but their types (`string`) conflict with sendOrderInfo (`number`). See DISC-08/DISC-09.

### Response 200 — `ApiResponse200`

Same generic response as sendOrderInfo.

| Field | Type | Example |
|-------|------|---------|
| `status.success` | boolean | `true` |
| `status.message` | string | `"success"` |
| `data` | object | `null` |

### Error Responses

| Code | Schema | Message Pattern |
|------|--------|-----------------|
| 400 | `ApiResponse400` | `"Invalid: parameter"` |
| 401 | `ApiResponse401` | `"E_INVALID_JWT_TOKEN: jwt must be provided"` |
| 409 | `ApiResponse409` | Conflict |

### PDF Discrepancies

- **DISC-15:** No direct PDF equivalent exists. WT05 (`/pos/invoices-publish`) is the closest, but it is a full invoice creation+issuance endpoint with line items, totals, and `seller` wrapper. `requestEinvoiceInfo` is a lightweight request that references an already-sent order by `store_code + pos_number + order_id + order_date`. Completely different schemas.
- **DISC-16:** OpenAPI specifies NO `maxLength` on any requestEinvoiceInfo field.

---

## 4. WT06 — invoices-status

| Property | Value |
|----------|-------|
| **Method** | `POST` |
| **URL** | `/api/wtx/pa/v1/pos/invoices-status` |
| **Security** | Bearer JWT |
| **Tags** | POS Invoice |
| **Summary** | "Get status of invoices" |

### Request — `GetStatusInvoicesModelRequest`

| Field | Type | Required | Description | Example |
|-------|------|----------|-------------|---------|
| `invoices` | array of strings | — | Array of ref_id strings | `["ref_id"]` |

> **Note:** OpenAPI schema says `invoices` is an array of strings. PDF says `data` array with `ref_id` objects. The request sample in PDF also uses `invoices` key with string array. **UNRESOLVED** — is wrapper key `invoices` or `data`?

### Response 200 — `GetStatusInvoicesModelResponse200`

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `status.code` | string | — | `"200"` |
| `status.message` | string | — | `"success"` |
| `data[]` | array of objects | — | — |
| `data[].sid` | string | WeTax internal ID | `"175398"` |
| `data[].ref_id` | string | POS ref_id | `"936324"` |
| `data[].symbol` | string | Form no + Serial no | `"1C24MKT"` |
| `data[].invoice_no` | string | Invoice number | `"56"` |
| `data[].invoice_type` | string | Invoice type | `"Original"` |
| `data[].cqt_report_status` | string | Tax authority report status | `"Reported"` |
| `data[].issuance_status` | string | Invoice issuance status | `"Issued"` |
| `data[].email_status` | string | Email delivery status | `"Sent"` |
| `data[].lookup_code` | string | Lookup code | `"JGSJIAIQ"` |
| `data[].lookup_url` | string | Public lookup URL | — |
| `data[].cqt_code` | string | Tax authority code | `""` |
| `data[].seller_signature_time` | string | Seller signature time | `""` |
| `data[].tax_signature_time` | string | CQT signature time | `""` |

> **Note:** Response uses `{code, message}` pattern, not `{success, message}`. See DISC-17.

### Error Responses

| Code | Schema | Message Pattern |
|------|--------|-----------------|
| 400 | `ApiResponse400` | `"Invalid: parameter"` |
| 401 | `ApiResponse401` | `"E_INVALID_JWT_TOKEN: jwt must be provided"` |
| 409 | `ApiResponse409` | Conflict |

### PDF Discrepancies

- **DISC-17:** Response status uses `{code, message}` (OpenAPI) vs `{success, message}` (PDF sample). **UNRESOLVED** — which does the actual API return?
- **DISC-18:** PDF says WT06 method is `GET`. OpenAPI says `POST`. OpenAPI is authoritative.
- **DISC-19:** PDF response includes `error_message` field (maxLength 1000). OpenAPI response schema does NOT include `error_message`. **UNRESOLVED.**
- **DISC-20:** PDF describes input schema as `data` array with `ref_id` objects. OpenAPI uses `invoices` array of plain strings. PDF request sample also uses `invoices` array of strings, contradicting its own schema table. Likely `invoices` is correct.

---

## 5. WT07 — resend-email

| Property | Value |
|----------|-------|
| **Method** | `POST` |
| **URL** | `/api/wtx/pa/v1/resend-email` |
| **Security** | Bearer JWT |
| **Tags** | Sender |

### Request — `ResendEmailModelRequest`

| Field | Type | Required | maxLength | Description | Example |
|-------|------|----------|-----------|-------------|---------|
| `data` | array of objects | — | — | — | — |
| `data[].ref_id` | string | **UNRESOLVED** (PDF says Yes, OpenAPI has no required) | 100 (PDF) | Reference ID (GUID) | `""` |
| `data[].email` | string | **UNRESOLVED** (PDF says Yes, OpenAPI has no required) | 100 (PDF) | Resend email | `""` |

### Response 200 — `ApiResponse200`

Generic success response (`data: null`).

### Error Responses

Standard set (400, 401, 409).

### PDF Discrepancies

- **DISC-21:** PDF marks both `ref_id` and `email` as Required=Yes. OpenAPI has no `required` array. **UNRESOLVED.**
- **DISC-22:** PDF specifies `maxLength` (ref_id: 100, email: 100). OpenAPI does not.

---

## 6. WT08 — inform-closing-store

| Property | Value |
|----------|-------|
| **Method** | `POST` |
| **URL** | `/api/wtx/pa/v1/pos/shops/inform-closing-store` |
| **Security** | Bearer JWT |
| **Tags** | Shop |
| **Summary** | "Inform closing shop when end day" |

### Request — `InformClosingStoreModelRequest`

| Field | Type | Required | maxLength | Description | Example |
|-------|------|----------|-----------|-------------|---------|
| `closing_date` | string | **Yes** | — | Closing Date (format: yyyymmdd) | `"20230731"` |
| `closing_time` | string | No | — | Actual closed time | `"20230731"` |
| `store_code` | string | **Yes** | — | Store Code | `"111103"` |
| `store_name` | string | **Yes** | — | Store Name | `"DUONG BA TRAC"` |
| `total_order_count` | string | **Yes** | — | Total order count | `"1230"` |

**`required` array (exact):** `["closing_date", "store_code", "store_name", "total_order_count"]`

### Response 200 — `ApiResponse200`

Generic success response (`data: null`).

### Error Responses

Standard set (400, 401, 409).

### PDF Discrepancies

- **DISC-23:** PDF says `total_order_count` type is `Number`. OpenAPI says `string`. Example value `"1230"` is a string in both. **UNRESOLVED** — does the API accept both?
- **DISC-24:** PDF says `closing_time` format is 14 chars (`yyyymmddhhmmss`). OpenAPI example is `"20230731"` (8 chars, same as date). **UNRESOLVED** — what is the correct format?
- **DISC-25:** PDF specifies maxLength values (closing_date: 8, closing_time: 14, store_code: 50, store_name: 400). OpenAPI does not.

---

## 7. WT01 — seller-info

| Property | Value |
|----------|-------|
| **Method** | `GET` |
| **URL** | `/api/wtx/pa/v1/seller-info` |
| **Security** | Bearer JWT |
| **Tags** | Seller |

### Request

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| (none in OpenAPI) | — | — | OpenAPI defines NO parameters |

> **DISC-26:** PDF says `tax_code` (String, maxLength 14, Required) is an input parameter. OpenAPI has no parameters at all. The token itself may identify the seller. **UNRESOLVED** — is `tax_code` a query param, body field, or derived from the JWT?

### Response 200 — `SellerResponse200`

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `status.success` | boolean | — | `true` |
| `status.message` | string | — | `"success"` |
| `data.declaration.register_date` | string | Declaration registration date | `""` |
| `data.declaration.status_code` | string | 5: Accepted / 6: Rejected / 3: In Progress | `""` |
| `data.declaration.status_name` | string | Status label | `""` |
| `data.declaration.pos_key` | string | POS Key (for Cash Register invoice form) | `""` |
| `data.shops[]` | array | Shop list | — |
| `data.shops[].shop_code` | string | Shop code | `""` |
| `data.shops[].shop_name` | string | Shop name | `""` |
| `data.shops[].templates[]` | array | Templates for this shop | — |
| `data.shops[].templates[].symbol` | string | Symbol (serial_no) | `""` |
| `data.shops[].templates[].start_date` | string | Template start date | `""` |
| `data.shops[].templates[].status_code` | string | 0: Ready / 1: Using / 2: Closed | `""` |
| `data.shops[].templates[].status_name` | string | Status label | `""` |
| `data.template[]` | array | Top-level template list | — |
| `data.template[].form_no` | string | Form number | `""` |
| `data.template[].serial_no` | string | Serial number | `""` |
| `data.template[].start_date` | string | Start date | `""` |
| `data.template[].status_code` | string | Status code | `""` |
| `data.template[].status_name` | string | Status label | `""` |
| `data.end_point` | string | Self-issuance endpoint | `"webcashvn"` |

> **Note:** OpenAPI has both `data.shops[].templates[]` (per-shop) and `data.template[]` (top-level). PDF response sample only shows `data.shops[].templates[]`. **DISC-27.**

### Error Responses

Standard set (400, 401, 409).

### PDF Discrepancies

- **DISC-26:** (see Request section above)
- **DISC-27:** OpenAPI has a top-level `data.template[]` array alongside `data.shops[].templates[]`. PDF only shows shop-level templates. **UNRESOLVED** — does the API return both?
- **DISC-28:** OpenAPI `shops[].templates[]` uses `symbol` as the serial field. PDF uses `serial_no` + `form_no` as separate fields. **UNRESOLVED** — OpenAPI shop-level templates may be a different structure than top-level templates.

---

## 8. WT09 — company/{tax_code}

| Property | Value |
|----------|-------|
| **Method** | `GET` |
| **URL** | `/api/wtx/pa/v1/company/{tax_code}` |
| **Security** | Bearer JWT |
| **Tags** | Company |
| **Summary** | "Get Company info by tax code" |

### Request

| Parameter | In | Type | Required | Description |
|-----------|----|------|----------|-------------|
| `tax_code` | path | string | Yes | Tax Code |

### Response 200 — `GetCompanyModelResponse200`

| Field | Type | Description |
|-------|------|-------------|
| `status.code` | string | `"200"` |
| `status.message` | string | `"success"` |
| `data.tax_id` | string | Tax code |
| `data.vietnam_name` | string | Official Vietnamese name |
| `data.english_name` | string | Official English name |
| `data.address` | string | Registered address |
| `data.representative_name` | string | Legal representative |
| `data.phonenumber` | string | Phone |
| `data.email` | string | Email |
| `data.fax` | string | Fax |
| `data.status` | string | GDT registration status |

> **Note:** Uses `{code, message}` response pattern (not `{success, message}`).

### Error Responses

Standard set (400, 401, 409).

### PDF Discrepancies

- **DISC-29:** PDF response field is `tax_code`. OpenAPI response field is `tax_id`. **UNRESOLVED** — which does the API actually return?
- **DISC-30:** PDF specifies maxLength for all fields (e.g., vietnam_name: 400, address: 400, representative_name: 50). OpenAPI does not.

---

## 9. commons/payment-methods

| Property | Value |
|----------|-------|
| **Method** | `GET` |
| **URL** | `/api/wtx/pa/v1/commons/payment-methods` |
| **Security** | Bearer JWT |
| **Tags** | Common |

### Request

No parameters.

### Response 200 — `PaymentMethodModelResponse200`

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `status.code` | string | — | `"200"` |
| `status.message` | string | — | `"success"` |
| `data[]` | array | — | — |
| `data[].code` | string | Payment method code | `"TM/CK"` |
| `data[].description` | string | Vietnamese label | `"Tien mat/chuyen khoan"` |

### Error Responses

Standard set (400, 401, 409).

### PDF Notes

PDF Section 3.1 lists: Cash (Tiền mặt), Transfer (Chuyển khoản), Cash/Transfer (TM/CK), Reconciliation (Đối trừ công nợ), No payment (Không thu tiền), plus "Etc" — not a closed enum.

> **Note:** The `sendOrderInfo.payment_method` enum (CASH, CREDITCARD, etc.) does NOT match the `commons/payment-methods` values (TM/CK, etc.). **DISC-31** — these appear to be two separate classification systems.

---

## 10. commons/tax-rates

| Property | Value |
|----------|-------|
| **Method** | `GET` |
| **URL** | `/api/wtx/pa/v1/commons/tax-rates` |
| **Security** | Bearer JWT |
| **Tags** | Common |

### Request

No parameters.

### Response 200 — `TaxRateModelResponse200`

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `status.code` | string | — | `"200"` |
| `status.message` | string | — | `"success"` |
| `data[]` | array | — | — |
| `data[].code` | string | Tax rate code | `"5%"` |
| `data[].description` | string | Vietnamese label | `"Thue suat 5%"` |

### Error Responses

Standard set (400, 401, 409).

### PDF Notes

PDF Section 3.3 lists: 0%, 5%, 8%, 10%, KCT (Not VAT), KKKNT (Not declaring VAT).

---

## 11. commons/currency

| Property | Value |
|----------|-------|
| **Method** | `GET` |
| **URL** | `/api/wtx/pa/v1/commons/currency` |
| **Security** | Bearer JWT |
| **Tags** | Common |

### Request

No parameters.

### Response 200 — `CurrencyModelResponse200`

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `status.code` | string | — | `"200"` |
| `status.message` | string | — | `"success"` |
| `data[]` | array | — | — |
| `data[].code` | string | Currency code | `"VND"` |
| `data[].description` | string | Currency label | `"VND"` |

### Error Responses

Standard set (400, 401, 409).

---

## 12. agency/sellers

| Property | Value |
|----------|-------|
| **Method** | `POST` |
| **URL** | `/api/wtx/pa/v1/agency/sellers` |
| **Security** | Bearer JWT |
| **Tags** | Agency |
| **Summary** | "Create agency seller" |

### Request — `AgencySellerModelRequest`

**Top-level `required`:** `["data_source", "company", "user_account"]`

#### Top-level fields

| Field | Type | Required | maxLength | Description | Example |
|-------|------|----------|-----------|-------------|---------|
| `data_source` | string | **Yes** | 400 | Source system (Default = VNPT_EPAY) | `"VNPT_EPAY"` |

#### `company` object — **`required`: `["tax_code", "vietnam_name", "address", "phone_number", "email"]`**

| Field | Type | Required | maxLength | Description | Example |
|-------|------|----------|-----------|-------------|---------|
| `tax_code` | string | **Yes** | 14 | Tax Identification Number | `"0312345678"` |
| `vietnam_name` | string | **Yes** | 400 | Legal name (Vietnamese) | `"CONG TY TNHH ABC"` |
| `english_name` | string | No | 400 | Legal name (English) | `"ABC COMPANY LIMITED"` |
| `address` | string | **Yes** | 400 | Registered address | `"123 Nguyen Trai, HCM"` |
| `phone_number` | string | **Yes** | 20 | Company phone | `"0281234567"` |
| `fax` | string | No | 20 | Fax number | `""` |
| `email` | string | **Yes** | 50 | Company email | `"abc@company.com"` |
| `website` | string | No | 100 | Website | `""` |
| `city_code` | string | No | 4 | Province/City code | `""` |
| `tax_office_name` | string | No | 100 | Managing tax authority name | `""` |
| `tax_office_id` | string | No | 5 | Managing tax authority ID | `""` |
| `bank_name` | string | No | 400 | Bank name | `""` |
| `account_no` | string | No | 30 | Bank account number | `""` |

#### `representative` object (no required array)

| Field | Type | Required | maxLength | Description | Example |
|-------|------|----------|-----------|-------------|---------|
| `full_name` | string | No | 50 | Representative full name | `"Nguyen Van A"` |
| `phone` | string | No | 20 | Representative phone | `"0901234567"` |
| `cid` | string | No | 12 | Citizen ID | `"079123456789"` |
| `passport` | string | No | 20 | Passport number | `""` |
| `dob` | string | No | 10 | Date of birth (YYYY-MM-DD) | `"1990-01-01"` |
| `gender` | string | No | 1 | 0: Female, 1: Male | `"1"` |
| `nationality` | string | No | 50 | Nationality | `"Vietnam"` |

#### `user_account` object — **`required`: `["full_name", "email", "phone_number", "user_id", "password", "created_by_agent_id"]`**

| Field | Type | Required | maxLength | Description | Example |
|-------|------|----------|-----------|-------------|---------|
| `full_name` | string | **Yes** | 100 | Account owner name | `"Nguyen Van A"` |
| `email` | string | **Yes** | 50 | Login email | `"admin@company.com"` |
| `phone_number` | string | **Yes** | 20 | Login phone (OTP verification) | `"0901234567"` |
| `user_id` | string | **Yes** | 50 | Login ID | `"admin@company.com"` |
| `password` | string | **Yes** | 100 | Login password | `"Secure@123"` |
| `created_by_agent_id` | string | **Yes** | 100 | Created by agent ID | `"VNPT_AGENT_01"` |

### Response 200 — `AgencySellerResponse200`

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `status.success` | boolean | — | `true` |
| `status.message` | string | — | `"success"` |
| `data.res_key` | number | SID of seller_comp_info | `568465` |

### Error Responses

Standard set (400, 401, 409).

### PDF Discrepancies

- **DISC-32:** No PDF documentation exists for Agency endpoints. Agency is OpenAPI-only.

---

## 13. agency/seller-shops

| Property | Value |
|----------|-------|
| **Method** | `POST` |
| **URL** | `/api/wtx/pa/v1/agency/seller-shops` |
| **Security** | Bearer JWT |
| **Tags** | Agency |
| **Summary** | "Create seller shops" |

### Request — `CreateSellerShopsPaModelRequest`

**Top-level `required`:** `["tax_code", "shops"]`

| Field | Type | Required | maxLength | Description | Example |
|-------|------|----------|-----------|-------------|---------|
| `tax_code` | string | **Yes** | 14 | Tax Identification Number | `"1201496252"` |
| `shops` | array | **Yes** | — | Shop array | — |

#### `shops[]` item fields — **`required`: `["shop_code", "shop_name", "pos_no"]`**

| Field | Type | Required | maxLength | Description | Example |
|-------|------|----------|-----------|-------------|---------|
| `shop_code` | string | **Yes** | 50 | Shop unique code | `"SHOP_02"` |
| `shop_name` | string | **Yes** | 400 | Shop name | `"ABC Branch District 1"` |
| `address` | string | No | 400 | Shop address | `"456 Le Loi, HCM"` |
| `phone_number` | string | No | 20 | Shop phone | `"0281234567"` |
| `fax_no` | string | No | 20 | Shop fax | `""` |
| `email` | string | No | 50 | Shop email | `"branch1@abc.com"` |
| `logo` | string | No | 500 | Logo URL | `""` |
| `pos_no` | string | **Yes** | 50 | POS machine code | `"POS_001"` |

### Response 200 — `ApiResponse200`

Generic success response (`data: null`).

### Error Responses

Standard set (400, 401, 409).

### PDF Discrepancies

- **DISC-32:** (same as above — no PDF documentation for Agency endpoints)

### OpenAPI Anomaly

- **ANOM-01:** A duplicate schema `AgencySellerShopsModelRequest` exists with identical structure to `CreateSellerShopsPaModelRequest`. Not referenced by any Stage 1 endpoint.

---

## 14. WT02 — pos/shops (POST)

| Property | Value |
|----------|-------|
| **Method** | `POST` |
| **URL** | `/api/wtx/pa/v1/pos/shops` |
| **Security** | Bearer JWT |
| **Tags** | Shop |
| **Summary** | "Create shop" |

### Request — `CreateShopsModelRequest`

| Field | Type | Required | maxLength | Description | Example |
|-------|------|----------|-----------|-------------|---------|
| `tax_code` | string | No | 14 | Tax code of company | `"1201496252"` |
| `data_source` | string | No | 400 | Data source (Default = 'ERPWEBCASH') | `"ERPWEBCASH"` |
| `customers` | array | No | — | **ANOMALY** — array of customer objects, not shops | — |

#### `customers[]` item fields — **`required`: `["cus_legal_name", "cus_tax_code", "cus_address"]`**

| Field | Type | Required | maxLength | Description | Example |
|-------|------|----------|-----------|-------------|---------|
| `cus_id` | string | No | 14 | Customer ID | — |
| `cus_legal_name` | string | **Yes** | 400 | Customer Legal Name | — |
| `cus_internal_name` | string | No | 400 | Customer Internal Name | — |
| `cus_tax_code` | string | **Yes** | 14 | Customer Tax Code | — |
| `cus_address` | string | **Yes** | 400 | Address | — |
| `cus_tel` | string | No | 20 | Customer Telephone | — |
| `cus_buyer_nm:` | string | No | 400 | Customer Buyer Name | **ANOM-02: trailing colon in key** |
| `cus_email` | string | No | 50 | Email | — |
| `cus_email_cc` | string | No | 100 | Customer Email CC | — |
| `cus_nation` | string | No | 150 | Customer Nation | — |
| `location` | string | No | 150 | Customer Location | — |

> **DISC-33:** OpenAPI schema `CreateShopsModelRequest` contains a `customers` array (B2B customer master data), NOT a `shops` array. PDF WT02 shows a `shops` array with `shop_code`, `shop_name`, `pos_no`, etc. The OpenAPI schema appears to be the **wrong schema** assigned to this endpoint. PDF is likely correct for WT02 functionality. The correct shop-creation schema is in `agency/seller-shops` (`CreateSellerShopsPaModelRequest`).
>
> **ANOM-02:** The property key `cus_buyer_nm:` has a trailing colon — likely a typo in the OpenAPI spec.

### Response 200 — `ApiResponse200`

Generic success response.

### Error Responses

Standard set (400, 401, 409).

---

## 15. pos/shops (GET)

| Property | Value |
|----------|-------|
| **Method** | `GET` |
| **URL** | `/api/wtx/pa/v1/pos/shops` |
| **Security** | Bearer JWT |
| **Tags** | Shop |

### Request

No parameters.

### Response 200 — `GetShopResponse200`

| Field | Type | Description |
|-------|------|-------------|
| `data[]` | array | Shop list |
| `data[].shop_code` | string | Shop Code |
| `data[].shop_name` | string | Shop Name |
| `data[].address` | string | Address |
| `data[].fax_no` | string | Fax No |
| `data[].tel_no` | string | Telephone |
| `data[].email` | string | Email |
| `data[].logo` | string | Logo URL |

> **ANOM-03:** `GetShopResponse200` has NO `status` wrapper — only `data[]` at top level. All other Response200 schemas have a `status` object.

### Error Responses

Standard set (400, 401, 409).

---

## Shared Error Response Schemas

### ApiResponse400

```json
{ "status": { "success": false, "message": "Invalid: parameter" }, "data": null }
```

### ApiResponse401

```json
{ "status": { "success": false, "message": "E_INVALID_JWT_TOKEN: jwt must be provided" }, "data": null }
```

### ApiResponse409

```json
{ "status": { "success": false, "message": "This response is sent when a request conflicts with the current state of the server." }, "data": null }
```

### PDF Error Patterns (Section 3.16)

| Pattern | Example |
|---------|---------|
| Success | `success` |
| Invalid JWT | `E_INVALID_JWT_TOKEN: jwt must be provided` |
| Field incorrect | `{field} is incorrect` |
| Field null | `{field} can not be null` |
| Not found | `{field} not found` |
| Blank | `{field} must not be blank` |
| Invalid number | `{field} invalid number` |
| Already issued | `ERROR: {field} has issued the invoice serial no – invoice no` |
| Missing serial | `{field} Missing Serial No` |
| Duplicate | `{field} Duplicate order number` |

### Two Response Status Patterns

| Pattern | Used By |
|---------|---------|
| `{ success: bool, message: string }` | auth/login 200, sendOrderInfo 200, requestEinvoiceInfo 200, resend-email 200, inform-closing-store 200, seller-info 200, agency/sellers 200, agency/seller-shops 200, pos/shops POST 200, ApiResponse400, ApiResponse401, ApiResponse409 |
| `{ code: string, message: string }` | invoices-status 200, company 200, payment-methods 200, tax-rates 200, currency 200 |

---

## Security Scheme

```json
{
  "Authorization": { "type": "http", "scheme": "bearer", "bearerFormat": "JWT" },
  "api_key": { "type": "apiKey", "in": "header", "name": "access_token" }
}
```

All Stage 1 endpoints (except `auth/login`) use Bearer JWT. The `api_key` scheme is defined but not referenced by any Stage 1 endpoint.

---

## Discrepancy Register

| ID | Severity | Endpoint | Summary |
|----|----------|----------|---------|
| DISC-01 | Low | auth/login | 401 response references ApiResponse400 instead of ApiResponse401 |
| DISC-02 | **High** | auth/login | expires_in: PDF=86400 (24h) vs OpenAPI example=7200 (2h) |
| DISC-03 | Medium | auth/login | expires_in type: PDF=String vs OpenAPI=number |
| DISC-04 | Low | auth/login | PDF has maxLength, OpenAPI does not |
| DISC-05 | **High** | auth/login | AES256 password encryption — enforced on apitest? |
| DISC-06 | Info | sendOrderInfo | Different endpoint from PDF WT03 (expected — sendOrderInfo supersedes) |
| DISC-07 | Info | sendOrderInfo | No buyer fields (expected per scope doc) |
| DISC-08 | **High** | sendOrderInfo vs requestEinvoiceInfo | pos_number: number vs string |
| DISC-09 | **High** | sendOrderInfo vs requestEinvoiceInfo | order_id: number vs string |
| DISC-10 | Medium | sendOrderInfo | No maxLength in OpenAPI, PDF WT03 maxLength may not apply |
| DISC-11 | Info | sendOrderInfo | list_product fields differ from PDF invoice_details fields |
| DISC-12 | **High** | sendOrderInfo | payment_method enum (CASH, etc.) vs commons TM/CK system |
| DISC-13 | **High** | sendOrderInfo | vat_rate: OpenAPI=number (8) vs PDF=string ("10%", "KCT") |
| DISC-14 | **High** | sendOrderInfo | Response shape unknown — ApiResponse200 is generic |
| DISC-15 | Info | requestEinvoiceInfo | No direct PDF equivalent (WT05 is different) |
| DISC-16 | Low | requestEinvoiceInfo | No maxLength in OpenAPI |
| DISC-17 | Medium | invoices-status | Response status pattern: {code,message} vs {success,message} |
| DISC-18 | Medium | invoices-status | Method: PDF=GET vs OpenAPI=POST |
| DISC-19 | Medium | invoices-status | PDF has error_message field, OpenAPI does not |
| DISC-20 | Medium | invoices-status | Request wrapper: invoices[] strings vs data[] objects |
| DISC-21 | Medium | resend-email | Required flags: PDF=Yes, OpenAPI=none |
| DISC-22 | Low | resend-email | maxLength: PDF has values, OpenAPI does not |
| DISC-23 | Medium | inform-closing-store | total_order_count: PDF=Number, OpenAPI=string |
| DISC-24 | Medium | inform-closing-store | closing_time format: 14 chars vs 8 chars in example |
| DISC-25 | Low | inform-closing-store | maxLength: PDF has values, OpenAPI does not |
| DISC-26 | **High** | seller-info | tax_code input: PDF=required param, OpenAPI=none |
| DISC-27 | Medium | seller-info | Top-level template[] array in OpenAPI, not in PDF |
| DISC-28 | Medium | seller-info | Shop templates use `symbol` (OpenAPI) vs `serial_no`+`form_no` (PDF) |
| DISC-29 | Medium | company | Response field: OpenAPI=`tax_id` vs PDF=`tax_code` |
| DISC-30 | Low | company | maxLength: PDF has values, OpenAPI does not |
| DISC-31 | **High** | payment-methods vs sendOrderInfo | Two different payment method systems (TM/CK vs CASH/CREDITCARD) |
| DISC-32 | Info | agency/* | No PDF documentation for Agency endpoints |
| DISC-33 | **Critical** | pos/shops POST | OpenAPI schema has `customers` array, PDF has `shops` array — likely wrong schema in OpenAPI |

---

## UNDESCRIBED Fields

Fields that exist in the schema but have no description or have unclear semantics.

| # | Endpoint | Field | Issue |
|---|----------|-------|-------|
| U-01 | sendOrderInfo | `bills[].list_product[].sale_price` | Description says "SALE PRICE (include VAT)" but relationship to `paying_amount` and `total_amount` is unclear |
| U-02 | requestEinvoiceInfo | `bills[].pos_number` | Example value (3) conflicts with declared type (string) |
| U-03 | requestEinvoiceInfo | `bills[].order_id` | Example value (1769) conflicts with declared type (string) |
| U-04 | seller-info | `data.declaration.pos_key` | Description says "Invoice Form = Cash Register then POS Key" — unclear when this is populated |
| U-05 | seller-info | `data.end_point` | Description says "using self-issuance" — unclear purpose |
| U-06 | pos/shops GET | All fields | No examples provided for any field |
| U-07 | agency/sellers | `data.res_key` | Description has typo: "sid of sller_comp_info" — meaning of this ID unclear |

**Total UNDESCRIBED: 7**

---

## UNRESOLVED Items

Items that cannot be determined from available documentation alone. All require Phase 2 validation.

| # | Category | Question | Resolution Path |
|---|----------|----------|-----------------|
| R-01 | Auth | Does `apitest` enforce AES256 password encryption? | Phase 2: test plaintext login |
| R-02 | Auth | What is the actual `expires_in` value? (7200 vs 86400) | Phase 2: check login response |
| R-03 | Auth | What is the actual type of `expires_in`? (number vs string) | Phase 2: check login response |
| R-04 | Auth | Are `user_id` and `password` truly required? (no required array in OpenAPI) | Phase 2: test with missing fields |
| R-05 | sendOrderInfo | Does `pos_number` accept string or number? | Phase 2: test call |
| R-06 | sendOrderInfo | Does `order_id` accept string or number? | Phase 2: test call |
| R-07 | sendOrderInfo | What is the actual response shape? (generic ApiResponse200 or detailed?) | Phase 2: test call |
| R-08 | sendOrderInfo | Does `payment_method` accept `TM/CK` format or only CASH/CREDITCARD enum? | Phase 2: test call |
| R-09 | sendOrderInfo | Is `vat_rate` a number (8) or string ("8%", "KCT")? | Phase 2: test call |
| R-10 | sendOrderInfo | Do maxLength constraints from PDF WT03 apply? | Phase 2: test with long values |
| R-11 | requestEinvoiceInfo | Same type questions as sendOrderInfo for `pos_number`, `order_id` | Phase 2: test call |
| R-12 | invoices-status | Is the request wrapper key `invoices` or `data`? | Phase 2: test both |
| R-13 | invoices-status | Does response include `error_message` field? | Phase 2: check response |
| R-14 | invoices-status | Which status pattern does response use? | Phase 2: check response |
| R-15 | resend-email | Are `ref_id` and `email` required? | Phase 2: test with missing fields |
| R-16 | inform-closing-store | Does `total_order_count` accept number or only string? | Phase 2: test call |
| R-17 | inform-closing-store | What is the correct `closing_time` format? | Phase 2: test call |
| R-18 | seller-info | Is `tax_code` required as input? How is it passed? | Phase 2: test GET with and without param |
| R-19 | company | Is the response field `tax_id` or `tax_code`? | Phase 2: test call |
| R-20 | pos/shops POST | Is the correct request schema `shops[]` (PDF) or `customers[]` (OpenAPI)? | Phase 2: test call — likely use `agency/seller-shops` instead |
| R-21 | payment-methods | Which payment method system does `sendOrderInfo` actually use? | Phase 2: test call with CASH vs TM/CK |

**Total UNRESOLVED: 21**

---

*Generated: 2026-04-12 | Phase -1 complete. Awaiting confirmation to proceed to Phase 0.*
