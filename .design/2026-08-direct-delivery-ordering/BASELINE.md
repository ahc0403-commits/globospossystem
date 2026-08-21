# Direct delivery regression baseline

Captured: 2026-08-21
Git HEAD: `706bad96` (`Merge pull request #403 from ahc0403-commits/codex/combined-table-checkout-fix`)
Working branch at capture: `codex/inventory-excel-supplier-create-navigation`

## User-owned work preserved

The baseline was captured with unrelated existing modifications in `CLAUDE.md`, admin/inventory source and tests, plus `20260821120000_inventory_excel_supplier_creation.sql`. Direct-delivery implementation must not edit or revert those changes.

## Full repository check

Command: `bash scripts/check_repo.sh`

- `flutter analyze`: PASS, no issues
- Flutter tests: PASS, 1,121 passed and 2 skipped
- Node contracts: PASS, 59 passed
- Repository secret scan: PASS
- Deployment shell/history/migration/psql contracts: PASS
- Photo Objet local SQL smoke: PASS
- Flutter web release build: PASS
- Git whitespace contract: PASS

The web build reported only pre-existing dependency warnings for `image` Wasm compatibility and the optional Cupertino icon font.

## Frozen file fingerprints

```text
ff48cb6876c92fee9ae08a45a3425a73a7281c69723ca7c15505e8fd038a9630  lib/features/qr_order/qr_order_screen.dart
bb62d51f93c474461783312d3d0acfbad2a087df122b650bdc3f1637cb447017  lib/features/cashier/cashier_screen.dart
9fc393e5b61e1c370cbf17af31bb3becf6eae1cf87b3f8073164aa00ef345ec5  lib/features/kitchen/kitchen_provider.dart
e3cdc57c2a55ab67d948f7445fe18cac7305957153ef63ffff38b139bc5b5fa6  lib/features/kitchen/kitchen_screen.dart
ceb62497c8f43ed6cd0cd100ad3ac1c2f7ae5a9131184a4a48a7b002236ee28e  lib/core/services/payment_service.dart
52cc2f364ce9f199e8727abf1eec5b43a4f0e2ba1c6821fd712df8122d69f0b8  lib/core/payments/payment_total_calculator.dart
080ef129b8cf9d3b245c9218548ee67ad212e08adb0b0ea6f3a38d8182dbe5c1  lib/features/report/report_provider.dart
5c976d66666e47e3a9a2de7cf7cda39a6c6827792015cb414b118925409b03db  lib/core/hardware/print_job_agent_service.dart
812fdaa3f993520983fc87e4bdb2c1f28c7ccca23f0eb384d69fdf42f4101993  supabase/migrations/20260707010000_service_item_exclusion_v1.sql
41a7dbc9ddb195db909d8578ce9286dc5de411e2ed67a1cfa657f1ea462b4e97  supabase/migrations/20260722050000_kitchen_direct_completion.sql
5b5b441698b0921d837966a1976465650409005a875f0214628939ebc3bcc2e4  supabase/migrations/20260817110000_menu_scoped_promotion_integrity.sql
```

Any fingerprint change requires stopping and proving that it is unrelated to direct delivery before work can continue.
