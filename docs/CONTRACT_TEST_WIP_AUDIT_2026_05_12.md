# Contract Test WIP Audit — 2026-05-12

## Baseline
- branch: audit/next-quarantined-wip-slice
- restore performed: no
- target group: quarantined test/*contract_test.dart only
- excluded: Flutter runtime, SQL migrations, SQL snippets, fonts, duplicate .vercelignore

## Contract Test Inventory
- test/admin_table_layout_editor_contract_test.dart
- test/admin_tables_order_workspace_contract_test.dart
- test/admin_tables_payment_amount_contract_test.dart
- test/app_nav_scope_contract_test.dart
- test/audit_findings_contract_test.dart
- test/cashier_receipt_contract_test.dart
- test/daily_closing_role_contract_test.dart
- test/delivery_scope_reload_contract_test.dart
- test/einvoice_scope_contract_test.dart
- test/inventory_purchase_flutter_contract_test.dart
- test/inventory_scope_contract_test.dart
- test/kitchen_cashier_i18n_contract_test.dart
- test/kitchen_realtime_contract_test.dart
- test/operational_offline_contract_test.dart
- test/order_mutation_role_contract_test.dart
- test/order_total_contract_test.dart
- test/order_workspace_realtime_contract_test.dart
- test/payment_detail_contract_test.dart
- test/photo_ops_role_contract_test.dart
- test/qc_role_contract_test.dart
- test/remaining_i18n_contract_test.dart
- test/report_summary_contract_test.dart
- test/staff_account_role_guard_contract_test.dart
- test/table_layout_model_contract_test.dart
- test/waiter_buffet_guest_count_contract_test.dart
- test/waiter_floor_layout_contract_test.dart
- test/waiter_i18n_contract_test.dart
- test/waiter_table_realtime_contract_test.dart
- test/wt08_reconciliation_contract_test.dart

## Import / Dependency Scan

### test/admin_table_layout_editor_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: not detected by keyword scan

### test/admin_tables_order_workspace_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: not detected by keyword scan

### test/admin_tables_payment_amount_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: not detected by keyword scan

### test/app_nav_scope_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: not detected by keyword scan

### test/audit_findings_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: possible

### test/cashier_receipt_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: not detected by keyword scan

### test/daily_closing_role_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: possible

### test/delivery_scope_reload_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: not detected by keyword scan

### test/einvoice_scope_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: not detected by keyword scan

### test/inventory_purchase_flutter_contract_test.dart
```dart
import 'dart:io';
import 'package:globos_pos_system/features/inventory_purchase/inventory_purchase_provider.dart';
import 'package:globos_pos_system/features/inventory_purchase/inventory_purchase_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
```
- runtime dependency: yes
- backend/security dependency: not detected by keyword scan

### test/inventory_scope_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: possible

### test/kitchen_cashier_i18n_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: not detected by keyword scan

### test/kitchen_realtime_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: not detected by keyword scan

### test/operational_offline_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: not detected by keyword scan

### test/order_mutation_role_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: possible

### test/order_total_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: not detected by keyword scan

### test/order_workspace_realtime_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: not detected by keyword scan

### test/payment_detail_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: yes
- backend/security dependency: not detected by keyword scan

### test/photo_ops_role_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: possible

### test/qc_role_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: possible

### test/remaining_i18n_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: yes
- backend/security dependency: not detected by keyword scan

### test/report_summary_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: not detected by keyword scan

### test/staff_account_role_guard_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: possible

### test/table_layout_model_contract_test.dart
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/models/pos_table.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: possible

### test/waiter_buffet_guest_count_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: not detected by keyword scan

### test/waiter_floor_layout_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: not detected by keyword scan

### test/waiter_i18n_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: not detected by keyword scan

### test/waiter_table_realtime_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: not detected by keyword scan

### test/wt08_reconciliation_contract_test.dart
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
```
- runtime dependency: not detected by keyword scan
- backend/security dependency: possible

## Preliminary Verdict
- Do not restore all contract tests as one PR.
- Next safe step is to split tests by dependency class after reviewing this audit file.
- Any test importing quarantined Flutter runtime files must wait for the matching runtime slice.
- Any test asserting SQL/RLS/RPC behavior must wait for SQL provenance audit.
