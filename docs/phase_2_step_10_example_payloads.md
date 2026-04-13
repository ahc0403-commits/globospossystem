---
title: "Phase 2 Step 10 — Example Payloads"
date: "2026-04-13"
scope: "stage1_scope_v1.3.md Section 12 Step 10"
status: "COMPLETE"
---

# Phase 2 Step 10 — Example Payloads

## sendOrderInfo — complete example

Built from test fixtures in `docs/vendor/samples/09_send_order_info.json`
and `13_sendorderinfo_uuidv7.json`. Reflects actual process_payment RPC output.

```json
{
  "bills": [{
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
  }]
}
```

**Confirmed from Phase 2 Step 1 audit:**
- `data` response is `""` (empty string), no `sid` returned (AP1)
- `pos_number` and `order_id` accepted as number type
- `vat_rate` accepted as number (not string like `"8%"`)

---

## requestEinvoiceInfo — complete example

Built from `docs/vendor/samples/10_request_einvoice_info.json`.
Populated from `b2b_buyer_cache` at checkout.

```json
{
  "bills": [{
    "ref_id":           "019d826b-5e95-7b41-81ca-2c18b29ad278",
    "tax_id":           "0319388179",
    "tax_company_name": "GLOBOSVN Co., Ltd.",
    "tax_address":      "Ho Chi Minh City, Vietnam",
    "tax_buyer_name":   "Nguyen Van A",
    "receiver_email":   "buyer@example.com",
    "receiver_email_cc": "",
    "order_date":       "20260413",
    "store_code":       "0319388179",
    "store_name":       "K-Noodle District 3",
    "pos_number":       "1",
    "order_id":         "123456"
  }]
}
```

**Confirmed from Phase 2 Step 1 audit:**
- Both string and number accepted for `pos_number`, `order_id`
- `receiver_email` is the only truly mandatory field
- Returns 400 "POS ID not found" on apitest (vendor bug; AP3 backoff handles this)

---

## Payload storage locations

| Payload | Stored in |
|---------|-----------|
| `sendOrderInfo` | `einvoice_jobs.send_order_payload` (JSONB, immutable) |
| `requestEinvoiceInfo` | `einvoice_jobs.request_einvoice_payload` (JSONB, NULL until red invoice requested) |
| Live API samples | `docs/vendor/samples/09_*` through `15_*` |
