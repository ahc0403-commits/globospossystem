# Direct delivery hardening baseline

Captured: 2026-08-21 21:00:00 +07
Working branch: `codex/inventory-excel-supplier-create-navigation`
Exact Git HEAD: `fcd12e4d34317d2fb2717d2a94c60bc513590592`

## Scope and ownership boundary

This baseline was captured immediately before the direct-delivery hardening
gates started. Every modified or untracked path listed below already existed in
the worktree at capture time. They are user-owned work and must not be reverted,
overwritten, or represented as having been created by the hardening work.

The direct-delivery source was present but untracked. This baseline proves only
the local source state. It does not prove that a migration was applied, an Edge
Function was deployed, a production release occurred, or a store pilot was
operationally verified.

Production migration, Edge deployment, storefront enablement, Google Business
Profile publication, and a live-store pilot remain explicitly outside the
authorized hardening scope.

## Worktree status at capture

```text
 M CLAUDE.md
 M lib/core/router/app_router.dart
 M lib/core/utils/role_routes.dart
 M pubspec.lock
 M pubspec.yaml
 M supabase/config.toml
 M web/index.html
?? .design/2026-08-direct-delivery-ordering/
?? lib/features/direct_order/
?? supabase/functions/direct-order-public/
?? supabase/migrations/20260821130000_direct_delivery_ordering.sql
?? supabase/tests/direct_delivery_ordering_contract_test.sql
?? test/direct_delivery_regression_isolation_test.dart
?? test/direct_delivery_storefront_widget_test.dart
?? test/direct_delivery_ui_contract_test.dart
```

## Direct-delivery source fingerprints

```text
d51878cc1f997870bdf6c00b0f9c306773e1752122fb0d5a147880b4c9780088  supabase/migrations/20260821130000_direct_delivery_ordering.sql
690a2a85b46b1e54b40deafb210995fd374263bcf1975558e50a4ab479f6f5f8  supabase/functions/direct-order-public/deno.json
bfbcbc439cb734e5d4d03f9a894c8a43495a13b0faefecccd3936206ec36d24e  supabase/functions/direct-order-public/deno.lock
31813db86c7b3d2ba4d6d6ff8bca04e74425627611d5b43eea6f16e8fae92152  supabase/functions/direct-order-public/index.ts
72caa91a807039e06f89928a685fcf84fec3f8b9a6890be0d060d4b7827790a3  supabase/functions/direct-order-public/index_test.ts
```

## Frozen legacy POS fingerprints

These files and effective migrations are outside the direct-delivery change
surface. Any hash mismatch is a stop condition until the cause is proven to be
unrelated user work.

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

## Frozen existing-alert fingerprints

The direct-order arrival alert must be implemented in new direct-only files. It
must not import, refactor, share cursor/ack state with, or otherwise modify these
existing alert implementations.

```text
c2be5ad39d75cd26df46682bed90423d39fc147b0841fe140d0beacc9a628d71  lib/core/services/bank_transfer_alert_coordinator.dart
05a1dbf45971c9c28437f52e970ce1ab6dfbec29f291188648cf50e708028dff  lib/core/services/bank_transfer_alert_service.dart
a3de8b7c4da0280e89678ffbdd9e129d010803e8c06eac56b430b641b33d23e9  lib/core/services/bank_transfer_alert_sound.dart
6f833898be76ef2dcbfe589aa209ff1233fa1c36e24915ede1e6db813a1b5f8c  lib/core/services/bank_transfer_alert_sound_io.dart
bdfb5a24dabd6ec2c3b28ac9923a6d3d3b1866e15c731cb7762b962377fcae2d  lib/core/services/bank_transfer_alert_sound_web.dart
29cd654015c80ce8124710eb2bd25661587f835a7e50c885cca13cb18cc3752c  lib/core/services/sepay_push_notification_service.dart
c2dfb84820152026b0089086238268a19aa87280a5a1c24aa3bf4df40bb4789a  lib/core/services/emergency_order_voice_message.dart
```

## Reproduction commands

Run from the repository root:

```sh
git branch --show-current
git rev-parse HEAD
git status --short
shasum -a 256 <each-path-listed-above>
```

The earlier `BASELINE.md` records the pre-hardening regression run at its own
captured commit. This document is the authoritative starting fingerprint for
the subsequent H0-H5 hardening changes in this worktree.
