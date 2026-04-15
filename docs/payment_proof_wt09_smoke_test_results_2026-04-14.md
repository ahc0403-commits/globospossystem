# Payment Proof + WT09 Smoke Test Results

Date: 2026-04-14
Executor: Codex
Scope: cashier WT09 lookup, payment proof ops, admin ops guardrails

## Summary

- Remote migration checks: PASS
- Remote function/RPC checks: PASS
- Flutter analyzer on touched files: PASS
- Basic Flutter test suite: PASS
- Chrome boot smoke: BLOCKED by missing web `--dart-define` runtime config
- Android device smoke: BLOCKED by no Android device connected in this session

## PASS

### 1. Remote DB verification

Confirmed on remote database:

- migration `20260414000011` exists
- migration `20260414000012` exists
- bucket `payment-proofs` exists
- storage policy `storage_payment_proofs_scoped` exists
- RPCs exist:
  - `admin_mark_resolved_einvoice_job`
  - `admin_retry_einvoice_job`
  - `mark_payment_proof_required`
  - `attach_payment_proof`

### 2. Runtime flags

Confirmed current values:

- `wetax_dispatch_enabled = true`
- `wetax_polling_enabled = false`

This matches the expected temporary operating mode.

### 3. Static verification

Passed:

- `flutter analyze` on the new WT09/proof/admin ops files
- `flutter test` current suite (`test/widget_test.dart`)

## BLOCKED

### 4. Chrome boot smoke

Initial blocker:

- web startup crashed with `flutter_dotenv` `NotInitializedError`

Action taken:

- patched `AppConstants` so web no longer reads `dotenv.env` directly

Current blocker after patch:

- app now fails later with `Bad state: SUPABASE_URL not configured. Set via --dart-define or .env`

Interpretation:

- the original web initialization bug is fixed
- remaining issue is environment configuration for web boot, not the WT09/proof feature logic itself

Required to continue web smoke:

```bash
flutter run -d chrome \
  --web-port 4040 \
  --dart-define=SUPABASE_URL=<url> \
  --dart-define=SUPABASE_ANON_KEY=<anon_key>
```

### 5. Android cashier smoke

Not executed in this session.

Reason:

- no Android device or emulator was connected

Connected devices seen:

- macOS desktop
- Chrome web

Still required on Android:

- WT09 cache hit
- WT09 live hit
- WT09 manual fallback
- card/pay proof capture
- offline queue recovery
- cash regression
- cross-store mutation boundary

## Conclusion

Server-side verification and code-level checks passed.

End-to-end runtime smoke validation remains blocked in this session:

1. run web with explicit Supabase `--dart-define` values if web support matters
2. run the cashier smoke checklist on a real Android device using `/Users/andreahn/globos_pos_system/docs/payment_proof_wt09_smoke_test.md`
