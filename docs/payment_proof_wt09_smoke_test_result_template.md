# Payment Proof + WT09 Smoke Test Result Template

Date:
Tester:
Device:
App build:
Store:
Environment:

## Overall Verdict

- Overall: PASS / FAIL / PARTIAL
- Blocking issue summary:

## Environment Check

- Android device connected: PASS / FAIL
- Network available at start: PASS / FAIL
- Cashier account login: PASS / FAIL
- Active store correct: PASS / FAIL
- Test payable order prepared: PASS / FAIL
- Store has non-null `tax_entity_id`: PASS / FAIL

Notes:

## 1. WT09 Auto-Fill

### 1A. Cache Hit

- Tax code used:
- Expected cache record existed: YES / NO
- Lookup status showed `Cache Match`: PASS / FAIL
- Company auto-filled: PASS / FAIL
- Address auto-filled: PASS / FAIL
- Email auto-filled when expected: PASS / FAIL
- Red invoice submission still worked: PASS / FAIL

Notes:

### 1B. WT09 Live Hit

- Tax code used:
- Not present in local cache first: YES / NO
- Lookup status showed `WT09 Auto-Fill`: PASS / FAIL
- Company auto-filled from WT09: PASS / FAIL
- Address auto-filled from WT09: PASS / FAIL
- Email auto-filled when available: PASS / FAIL

Notes:

### 1C. WT09 Manual Fallback

- Tax code used:
- Lookup status showed `Manual Entry`: PASS / FAIL
- Form stayed editable: PASS / FAIL
- Red invoice could still be submitted manually: PASS / FAIL
- App remained stable with no crash: PASS / FAIL

Notes:

## 2. Payment Proof Happy Path

- Payment method tested: `card` / `pay`
- Proof modal opened after payment: PASS / FAIL
- Camera or picker opened: PASS / FAIL
- Image captured/selected successfully: PASS / FAIL
- Save completed: PASS / FAIL
- Success toast shown: PASS / FAIL
- Red invoice modal still appeared after proof flow: PASS / FAIL

DB verification:

- `proof_required = true`: PASS / FAIL
- `proof_photo_url IS NOT NULL`: PASS / FAIL
- `proof_photo_taken_at IS NOT NULL`: PASS / FAIL
- `proof_photo_by IS NOT NULL`: PASS / FAIL

Payment row checked:

```sql
select id, order_id, method, proof_required, proof_photo_url, proof_photo_taken_at, proof_photo_by
from public.payments
where id = '<payment_id>'
limit 1;
```

Notes:

## 3. Offline Queue Recovery

- Network disabled before save: YES / NO
- Save path avoided crash: PASS / FAIL
- Queued/local retry message shown: PASS / FAIL
- App reopened after network restore: PASS / FAIL
- Queued upload flushed automatically: PASS / FAIL
- Flush toast shown: PASS / FAIL
- DB row eventually got `proof_photo_url`: PASS / FAIL

Notes:

## 4. Cash Regression

- `cash` payment completed: PASS / FAIL
- Proof modal did not open: PASS / FAIL
- Red invoice modal still opened: PASS / FAIL
- No unexpected error toast: PASS / FAIL

Notes:

## 5. Cross-Store Boundary

- Test scenario available: YES / NO
- Store A proof write succeeded: PASS / FAIL
- Cross-store proof write was blocked: PASS / FAIL
- Cross-store retry/resolve was blocked if tested: PASS / FAIL

Notes:

## 6. Remote Verification

```sql
select version
from supabase_migrations.schema_migrations
where version in ('20260414000011', '20260414000012')
order by version;
```

```sql
select id
from storage.buckets
where id = 'payment-proofs';
```

```sql
select proname
from pg_proc
join pg_namespace n on n.oid = pg_proc.pronamespace
where n.nspname = 'public'
  and proname in (
    'admin_mark_resolved_einvoice_job',
    'admin_retry_einvoice_job',
    'mark_payment_proof_required',
    'attach_payment_proof'
  )
order by proname;
```

- Migration rows present: PASS / FAIL
- `payment-proofs` bucket present: PASS / FAIL
- RPC set present: PASS / FAIL

Notes:

## Failure Log

| Step | Error | Reproducible | Severity | Notes |
|------|-------|--------------|----------|-------|
|      |       | YES / NO     | LOW / MEDIUM / HIGH |       |

## Final Decision

- Ready to merge this slice: YES / NO
- If no, must-fix items:
- Follow-up owner:
- Follow-up date:
