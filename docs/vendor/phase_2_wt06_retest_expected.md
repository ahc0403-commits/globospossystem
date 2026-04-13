# Phase 2 WT06 Re-test — Expected Behavior Baseline

> Generated 2026-04-12 | Re-test of CRITICAL 3 from phase_2_step_1_audit.md
> Hypothesis: invoices-status NPE caused by non-UUID ref_id format

## Background

CRITICAL 3 from the initial audit:
- **Actual:** `Cannot invoke "java.util.UUID.toString()" because the return value of "...getGuid()" is null`
- **Hypothesis:** The server calls `UUID.toString()` on an internal GUID looked up by ref_id. Our ref_id `GLOBOS-TEST-20260412110521-001` is not a valid UUID, so the server either: (a) could not find it, returning null GUID, or (b) tried to parse it as UUID and failed silently.
- **Test:** Send a new order with proper UUIDv7 ref_id, then poll invoices-status.

## UUIDv7 Format Specification

A valid UUIDv7 (RFC 9562) has this structure:
```
xxxxxxxx-xxxx-7xxx-yxxx-xxxxxxxxxxxx
                ^    ^
                |    variant: y = 8, 9, a, or b (top two bits = 10)
                version: always 7
```
- First 48 bits: Unix timestamp in milliseconds
- Bits 49-52: version (0111 = 7)
- Bits 53-64: random
- Bits 65-66: variant (10)
- Bits 67-128: random

Example: `0195c8a4-9b5e-7c3d-a1b2-0123456789ab`

## Expected Behavior: sendOrderInfo with UUIDv7 ref_id

Per initial audit sample 09: sendOrderInfo accepted arbitrary string ref_id. UUIDv7 should also be accepted. Expected response:
```json
{"status": {"success": true, "message": "Success"}, "data": ""}
```

## Expected Behavior: invoices-status with UUIDv7 ref_id

### Wrapper shape (OpenAPI — confirmed correct in initial audit):
```json
{"invoices": ["<uuidv7-string>"]}
```

### Expected successful response (OpenAPI GetStatusInvoicesModelResponse200):
```json
{
  "status": {"code": "200", "message": "success"},
  "data": [{
    "sid": "...",
    "ref_id": "<our-uuidv7>",
    "symbol": "1C26TKT",
    "invoice_no": "...",
    "invoice_type": "Original",
    "cqt_report_status": "...",
    "issuance_status": "...",
    "email_status": "...",
    "lookup_code": "...",
    "lookup_url": "...",
    "cqt_code": "...",
    "seller_signature_time": "...",
    "tax_signature_time": "..."
  }]
}
```

Note: Initial audit found response uses `{success, message}` not `{code, message}`. Expect `{success: true/false, message: "..."}`.

### Alternative wrapper shape (PDF — rejected in initial audit):
```json
{"data": [{"ref_id": "<uuidv7-string>"}]}
```
Initial audit confirmed this returns "must not be empty". Included only as fallback.

## Possible Outcomes

1. **UUID_FIX_WORKS** — 200 with data array containing sid, statuses. CRITICAL 3 resolved.
2. **PARTIAL_FIX** — One shape works, other doesn't.
3. **STILL_NPE** — Same NPE with valid UUID. Root cause is not format.
4. **DIFFERENT_ERROR** — New error suggesting different root cause.
