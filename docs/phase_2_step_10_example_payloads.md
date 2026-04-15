---
title: "Phase 2 Step 10 — Example Payloads"
date: "2026-04-13"
scope: "stage1_scope_v1.3.md Section 12 Step 10"
status: "COMPLETE"
---

# Phase 2 Step 10 — Example Payloads

## sendOrderInfo — canonical DB payload

Built from test fixtures in `docs/vendor/samples/09_send_order_info.json`
and `13_sendorderinfo_uuidv7.json`. This is the canonical JSON stored in
`einvoice_jobs.send_order_payload` by `process_payment`.

```json
{
  "ref_id":         "019d826b-5e95-7b41-81ca-2c18b29ad278",
  "store_code":     "0319388179",
  "store_name":     "K-Noodle District 3",
  "order_date":     "20260413",
  "order_time":     "20260413120000",
  "pos_number":     1,
  "order_id":       123456,
  "trans_type":     1,
  "payment_method": "CASH",
  "list_product": [
    {
      "item_name":     "Pho Bo",
      "unit_price":    80000,
      "quantity":      2,
      "uom":           "EA",
      "total_amount":  160000,
      "vat_rate":      8,
      "vat_amount":    12800,
      "paying_amount": 172800
    },
    {
      "item_name":     "Bia Saigon",
      "unit_price":    50000,
      "quantity":      1,
      "uom":           "EA",
      "total_amount":  50000,
      "vat_rate":      10,
      "vat_amount":    5000,
      "paying_amount": 55000
    }
  ]
}
```

**Confirmed from Phase 2 Step 1 audit:**
- `data` response is `""` (empty string), no `sid` returned (AP1)
- `pos_number` and `order_id` accepted as number type
- `vat_rate` accepted as number (not string like `"8%"`)

## sendOrderInfo — dispatcher outbound request body

The edge function wraps the stored `einvoice_jobs.send_order_payload` into the
actual WT03 request body sent to WeTax.

```json
{
  "invoices": [{
    "ref_id":         "019d826b-5e95-7b41-81ca-2c18b29ad278",
    "store_code":     "0319388179",
    "store_name":     "K-Noodle District 3",
    "order_date":     "20260413",
    "order_time":     "20260413120000",
    "pos_number":     1,
    "order_id":       123456,
    "trans_type":     1,
    "payment_method": "CASH",
    "list_product": [
      {
        "item_name":     "Pho Bo",
        "unit_price":    80000,
        "quantity":      2,
        "uom":           "EA",
        "total_amount":  160000,
        "vat_rate":      8,
        "vat_amount":    12800,
        "paying_amount": 172800
      }
    ]
  }]
}
```

---

## invoices-issue — dispatcher outbound request body

Built from the current `request_red_invoice` payload builder and dispatcher send path.
This section shows the actual WT05 request body posted to WeTax. The nested
invoice document is also stored in `einvoice_jobs.request_einvoice_payload` for
retry/admin flows.

```json
{
  "seller": {
    "tax_code": "0319388179",
    "store_code": "0319388179",
    "store_name": "K-Noodle District 3"
  },
  "invoices": [{
    "ref_id": "019d826b-5e95-7b41-81ca-2c18b29ad278",
    "order_date": "20260413",
    "order_time": "20260413120000",
    "pos_number": 1,
    "order_id": 123456,
    "trans_type": 1,
    "payment_method": "CASH",
    "invoice_type": "0",
    "form_no": "1",
    "serial_no": "C26MTT",
    "cqt_code": "",
    "buyer_comp_name": "GLOBOSVN Co., Ltd.",
    "buyer_tax_code": "0319388179",
    "buyer_address": "Ho Chi Minh City, Vietnam",
    "buyer_tel": "",
    "buyer_email": "buyer@example.com",
    "buyer_email_cc": "",
    "tot_amount": 210000,
    "tot_vat_amount": 17800,
    "tot_dc_amount": 0,
    "tot_pay_amount": 227800,
    "list_product": [
      {
        "item_name": "Pho Bo",
        "unit_price": 80000,
        "quantity": 2,
        "uom": "EA",
        "total_amount": 160000,
        "vat_rate": 8,
        "vat_amount": 12800,
        "paying_amount": 172800
      }
    ]
  }]
}
```

**Current implementation notes:**
- The dispatcher calls `POST /api/wtx/pa/v1/pos/invoices-issue`, not `requestEinvoiceInfo`.
- The payload is stored in `einvoice_jobs.request_einvoice_payload` for retry/admin flows even though the field name still uses the older internal `request_einvoice_*` vocabulary.
- Latest apitest retest is blocked by a vendor-side server error in `/pos/invoices-issue`, so the payload shape here reflects the current client implementation rather than a successful end-to-end issuance response.

---

## Payload storage locations

| Payload | Stored in |
|---------|-----------|
| `sendOrderInfo` | `einvoice_jobs.send_order_payload` (JSONB, immutable) |
| `invoices-issue` | `einvoice_jobs.request_einvoice_payload` (JSONB, NULL until red invoice requested) |
| Live API samples | `docs/vendor/samples/09_*` through `15_*` |
