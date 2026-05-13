# POS Release Note — pos-v2026.05.13

## Release Summary
- Release tag: `pos-v2026.05.13`
- Commit: `91787df280fa2cb7c08124dc025c03eb6623f621`
- Date (UTC): `2026-05-13T09:13:19Z`
- Branch: `main`

## What Shipped
- POS operational stabilization baseline verified on current `main`.
- Inventory runtime closure baseline maintained (no new scope expansion in this release verification step).

## Validation Evidence
- `flutter analyze`: PASS
- `flutter test`: PASS
- `flutter build macos`: PASS
- `flutter build web`: PASS

## Artifact Retention
- macOS app bundle archived:
  - `/Users/andreahn/globos_pos_releases/pos-v2026.05.13/macos/globos_pos_system.app.zip`
- SHA256:
  - `9ae1ce18af97fea3456c00f0d1bcb81f05bd31fcbcf74b371c25379da7f15d4b`
- Release manifest:
  - `/Users/andreahn/globos_pos_releases/pos-v2026.05.13/release-manifest.json`

## Web Deployment Decision
- Decision: `HOLD` for production deployment.
- Reason:
  - Web build succeeded, but warnings remain in wasm dry run and icon font resolution.
  - Production deployment is deferred until warning triage and staging smoke check are completed.

## What Did Not Ship
- No SQL, RPC, or migration changes.
- No payment/order/table domain changes.
- No new POS approval execution path.

## Rollback Reference
- Roll back to previous production tag/commit in Git if release promotion is later reverted.
- This step produced verification and artifact preservation, not runtime contract expansion.
