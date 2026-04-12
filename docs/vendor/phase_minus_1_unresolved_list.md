---
title: "Phase -1 — UNRESOLVED & UNDESCRIBED Extract"
date: "2026-04-12"
source: "phase_minus_1_vendor_truth_table.md"
---

# UNRESOLVED Items (21)

[UNRESOLVED-01] auth/login / password (AES256 encryption)
Summary: Unknown whether apitest.wetax.com.vn enforces AES256 encryption or accepts plaintext.
Impact: Determines whether the dispatcher can authenticate at all without the vendor encryption guide.
Phase 2 testable: YES

[UNRESOLVED-02] auth/login / expires_in (value)
Summary: OpenAPI example says 7200 (2h), PDF says 86400 (24h) — actual token lifetime unknown.
Impact: Token refresh scheduling logic depends on the real value.
Phase 2 testable: YES

[UNRESOLVED-03] auth/login / expires_in (type)
Summary: OpenAPI declares number, PDF declares String(10) — actual type returned is unknown.
Impact: Token refresh parser must handle the correct type; wrong assumption causes silent failure.
Phase 2 testable: YES

[UNRESOLVED-04] auth/login / user_id, password (required flag)
Summary: OpenAPI has no `required` array on UserModelRequest; PDF marks both as Required=Yes.
Impact: Edge function error handling must know whether the server validates presence.
Phase 2 testable: YES

[UNRESOLVED-05] company/{tax_code} / response field name
Summary: OpenAPI response uses `tax_id`, PDF uses `tax_code` — actual field name unknown.
Impact: WT09 auto-fill mapping in b2b_buyer_cache depends on the correct field name.
Phase 2 testable: YES

[UNRESOLVED-06] inform-closing-store / closing_time (format)
Summary: OpenAPI example is 8 chars ("20230731"), PDF says 14 chars (yyyymmddhhmmss).
Impact: Daily close edge function must send the correct format or risk 400 rejection.
Phase 2 testable: YES

[UNRESOLVED-07] inform-closing-store / total_order_count (type)
Summary: OpenAPI declares string, PDF declares Number — actual accepted type unknown.
Impact: Payload builder must serialize this field correctly.
Phase 2 testable: YES

[UNRESOLVED-08] invoices-status / request wrapper key
Summary: OpenAPI schema says `invoices` (array of strings), PDF schema table says `data` (array of objects).
Impact: WT06 polling edge function must use the correct wrapper key.
Phase 2 testable: YES

[UNRESOLVED-09] invoices-status / response error_message field
Summary: PDF includes `error_message` (maxLength 1000) in response; OpenAPI schema omits it.
Impact: Error handling and failed-job alerting depend on whether this field exists.
Phase 2 testable: YES

[UNRESOLVED-10] invoices-status / response status pattern
Summary: OpenAPI uses `{code, message}`, PDF sample uses `{success, message}` — actual unknown.
Impact: Response parser must handle the correct shape; wrong assumption breaks status polling.
Phase 2 testable: YES

[UNRESOLVED-11] payment-methods / relationship to sendOrderInfo enum
Summary: commons/payment-methods returns codes like "TM/CK"; sendOrderInfo uses CASH, CREDITCARD, etc.
Impact: POS payment method mapping must know which system sendOrderInfo actually accepts.
Phase 2 testable: YES — referenced in: sendOrderInfo (DISC-12), commons/payment-methods (DISC-31)

[UNRESOLVED-12] pos/shops POST / request schema
Summary: OpenAPI assigns `CreateShopsModelRequest` with `customers[]` array; PDF shows `shops[]` array.
Impact: Shop creation flow must use the correct schema — likely `agency/seller-shops` is the real path.
Phase 2 testable: YES

[UNRESOLVED-13] requestEinvoiceInfo / order_id (type)
Summary: Declared as string but example value is number (1769); sendOrderInfo declares it as number.
Impact: Payload builder must serialize order_id correctly for red invoice requests.
Phase 2 testable: YES — referenced in: requestEinvoiceInfo (R-11), sendOrderInfo (DISC-09)

[UNRESOLVED-14] requestEinvoiceInfo / pos_number (type)
Summary: Declared as string but example value is number (3); sendOrderInfo declares it as number.
Impact: Payload builder must serialize pos_number correctly for red invoice requests.
Phase 2 testable: YES — referenced in: requestEinvoiceInfo (R-11), sendOrderInfo (DISC-08)

[UNRESOLVED-15] resend-email / ref_id, email (required flag)
Summary: PDF marks both as Required=Yes; OpenAPI has no `required` array.
Impact: Edge function must know whether server validates presence or silently ignores.
Phase 2 testable: YES

[UNRESOLVED-16] seller-info / tax_code input parameter
Summary: PDF says tax_code (String, maxLength 14) is a required input; OpenAPI defines no parameters.
Impact: Onboarding flow must know whether to pass tax_code as query param, body, or rely on JWT.
Phase 2 testable: YES

[UNRESOLVED-17] sendOrderInfo / maxLength constraints
Summary: OpenAPI specifies no maxLength on any field; PDF WT03 has maxLength but is a different endpoint.
Impact: Schema column sizing and input validation depend on actual server limits.
Phase 2 testable: PARTIAL — can test with oversized values but may not cover all fields

[UNRESOLVED-18] sendOrderInfo / order_id (type)
Summary: OpenAPI declares number; requestEinvoiceInfo declares string for the same conceptual field.
Impact: Payload builder and DB column type for order_id depend on the actual accepted type.
Phase 2 testable: YES — referenced in: sendOrderInfo (DISC-09), requestEinvoiceInfo (R-11)

[UNRESOLVED-19] sendOrderInfo / payment_method (accepted values)
Summary: OpenAPI enum lists CASH, CREDITCARD, etc.; commons endpoint returns TM/CK codes.
Impact: Payment method mapping table design depends on which value set the server accepts.
Phase 2 testable: YES — referenced in: sendOrderInfo (DISC-12), commons/payment-methods (DISC-31)

[UNRESOLVED-20] sendOrderInfo / pos_number (type)
Summary: OpenAPI declares number; requestEinvoiceInfo declares string for the same conceptual field.
Impact: Payload builder and DB column type for pos_number depend on the actual accepted type.
Phase 2 testable: YES — referenced in: sendOrderInfo (DISC-08), requestEinvoiceInfo (R-11)

[UNRESOLVED-21] sendOrderInfo / response shape
Summary: OpenAPI returns generic ApiResponse200 (data: null); PDF WT03 returns array with ref_id, sid, status.
Impact: Dispatcher must know response shape to confirm successful submission and extract sid.
Phase 2 testable: YES

[UNRESOLVED-22] sendOrderInfo / vat_rate (type and format)
Summary: OpenAPI declares number with example 8; PDF declares String(11) with values like "10%", "KCT".
Impact: Tax calculation logic and list_product payload builder depend on the correct type.
Phase 2 testable: YES

---

# UNDESCRIBED Fields (7)

[UNDESCRIBED-01] agency/sellers / data.res_key
[UNDESCRIBED-02] pos/shops GET / all response fields (no examples provided)
[UNDESCRIBED-03] requestEinvoiceInfo / bills[].order_id (example conflicts with type)
[UNDESCRIBED-04] requestEinvoiceInfo / bills[].pos_number (example conflicts with type)
[UNDESCRIBED-05] seller-info / data.declaration.pos_key
[UNDESCRIBED-06] seller-info / data.end_point
[UNDESCRIBED-07] sendOrderInfo / bills[].list_product[].sale_price
