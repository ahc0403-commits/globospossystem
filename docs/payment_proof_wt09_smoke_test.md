# Payment Proof + WT09 Smoke Test

Updated: 2026-04-14

This checklist is scoped to the new cashier-side proof photo flow and WT09 buyer auto-fill flow.

## Target Change Set

Review and stage only these files for this feature slice:

- `/Users/andreahn/globos_pos_system/lib/core/services/einvoice_service.dart`
- `/Users/andreahn/globos_pos_system/lib/core/services/payment_proof_service.dart`
- `/Users/andreahn/globos_pos_system/lib/features/cashier/payment_proof_modal.dart`
- `/Users/andreahn/globos_pos_system/lib/features/cashier/red_invoice_modal.dart`
- `/Users/andreahn/globos_pos_system/lib/features/cashier/cashier_screen.dart`
- `/Users/andreahn/globos_pos_system/lib/features/payment/payment_provider.dart`
- `/Users/andreahn/globos_pos_system/supabase/functions/wetax-onboarding/index.ts`
- `/Users/andreahn/globos_pos_system/supabase/migrations/20260414000012_payment_proof_and_wt09_access.sql`
- `/Users/andreahn/globos_pos_system/docs/audit_execution_checklist.md`

## Preconditions

- Use an Android cashier device if available.
- Log in with a cashier-capable account that has access to one active store.
- Confirm the device can reach Supabase.
- Confirm one payable order exists in the cashier queue.
- Confirm the target store has a non-null `tax_entity_id`.

## 1. WT09 Auto-Fill

### 1A. Cache hit

1. Open cashier.
2. Process a normal payment.
3. In the red invoice modal, enter a known buyer tax code already present in `b2b_buyer_cache`.
4. Tap `Lookup`.

Expected:

- Lookup status shows `Cache Match`.
- Company name, address, and known email fields fill in.
- Submission still works.

### 1B. WT09 hit

1. Repeat with a tax code that is not in local cache.
2. Tap `Lookup`.

Expected:

- Lookup status changes to `WT09 Auto-Fill` if vendor responds successfully.
- Company name and address are filled from vendor response.
- If vendor email exists and email field is empty, email is filled.

### 1C. WT09 fallback

1. Repeat with a tax code that is expected to fail on vendor side, or temporarily use a known bad apitest case.
2. Tap `Lookup`.

Expected:

- Lookup status changes to `Manual Entry`.
- Form remains editable.
- User can submit a red invoice manually without app crash or blocked UI.

## 2. Payment Proof Happy Path

1. In cashier, choose a payable order.
2. Pay with `card`.
3. Confirm receipt printing if available.
4. When the proof modal opens, capture or pick an image.
5. Save proof.

Expected:

- Proof modal appears only for `card` or `pay`.
- Successful save shows confirmation toast.
- Payment completes without losing the red invoice modal step afterward.
- In DB, the latest `payments` row for that order has:
  - `proof_required = true`
  - `proof_photo_url IS NOT NULL`
  - `proof_photo_taken_at IS NOT NULL`
  - `proof_photo_by IS NOT NULL`

Suggested SQL:

```sql
select id, order_id, method, proof_required, proof_photo_url, proof_photo_taken_at, proof_photo_by
from public.payments
order by created_at desc
limit 5;
```

## 3. Payment Proof Offline Queue

1. Start a `card` or `pay` payment until the proof modal appears.
2. Disable network before saving the captured photo.
3. Save proof.
4. Reopen cashier after network returns.

Expected:

- Save path does not crash.
- User sees a queued/local retry message.
- On next cashier session with network restored, queued proof upload retries automatically.
- If retry succeeds, a toast reports queued uploads were flushed.
- DB row eventually receives `proof_photo_url`.

## 4. Non-Proof Payment Regression

1. Process a `cash` payment.

Expected:

- No proof modal appears.
- Payment still completes normally.
- Red invoice modal still appears afterward for non-service payments.

## 5. Permission Boundary Check

1. Log in as cashier for Store A.
2. Complete payment on Store A and save proof.
3. Attempt to access or upload proof for Store B using the same account, if a multi-store scenario exists.

Expected:

- Store A succeeds.
- Cross-store proof mutation is blocked by RPC or storage policy.

## 6. Remote Verification

Run these spot checks after one successful proof upload:

```sql
select version
from supabase_migrations.schema_migrations
where version = '20260414000012';
```

```sql
select proname
from pg_proc
join pg_namespace n on n.oid = pg_proc.pronamespace
where n.nspname = 'public'
  and proname in ('mark_payment_proof_required', 'attach_payment_proof')
order by proname;
```

```sql
select id
from storage.buckets
where id = 'payment-proofs';
```

Expected:

- Migration version exists.
- Both RPCs exist.
- `payment-proofs` bucket exists.

## Pass / Fail Rule

Pass this slice only if:

- WT09 path succeeds when vendor responds and falls back cleanly when vendor fails.
- Card/pay proof capture works end-to-end.
- Offline retry eventually heals.
- Cash flow is unaffected.
- No cross-store write is possible.

If any one of these fails, fix that path before bundling this slice into a commit.
