# POS language audit — 2026-09-15

## Finding

The English interface in the reported BM staff-meal detail was using Korean
menu data. Flutter's locale controller and localization delegates work; the
menu-data path did not consistently use them.

Interface labels come from ARB resources. Menu names are database values with
separate `name_ko`, `name_en`, and `name_vi` fields. Translating a label such as
“Item” does not translate the value next to it. Several read functions returned
only the original name, and several widgets read `name`/`label` directly.

The BM staff-meal function also concatenated original names into a single
string, losing the per-item translations before Flutter received the result.

## Production evidence (read-only)

Active, unarchived menu records were inspected in POS project
`ynriuoomotxuwhuxxmhj`. No production rows were changed.

| Store | Active menus | Missing English | Missing Vietnamese | English containing Hangul |
| --- | ---: | ---: | ---: | ---: |
| BunsikClub Binh Thanh | 80 | 0 | 0 | 0 |
| BunsikClub SAMPLE | 78 | 0 | 0 | 0 |

The screenshot's translations already exist:

| Original | English | Vietnamese |
| --- | --- | --- |
| 돌솥 불고기 비빔밥 | Stone Pot Bulgogi Bibimbap | Cơm Trộn Nồi Đá Bulgogi |
| 밥 | Steamed Rice | Cơm Trắng |
| 생수 | Dasani Water | Nước Suối |

This count covers those two stores' active menus, not every historical record
or every category, ingredient, and user-entered note.

## Findings by severity

| Severity | Finding | Result |
| --- | --- | --- |
| HIGH | BM service, cancellation, and staff-meal reads omitted menu translations; grouped staff meals returned one original-language string. | Fixed in source and migration; production application pending. |
| HIGH | Menu browser/cart, menu administration, sold-out controls, staff-meal selection, recipe selectors, combo components, menu analytics, and receipt ledger had paths that ignored translated names. | Fixed at data selection/model/render boundaries. |
| MEDIUM | BM copy was a separate inline three-language dictionary; cashier search, paper-print label, and imported-receipt count bypassed ARB. | Moved affected copy to ARB, including persistent search feedback. |
| MEDIUM | Long translated text and 200% text scaling overflowed cashier, Photo Ops, store setup, and offline attendance layouts. | Fixed and checked in the expanded viewport/locale matrix. |
| MEDIUM | Inventory's expanded purchase/recommendation/runtime detail still contains English-only copy and provider-generated English summaries. | Confirmed remaining localization debt; not converted in this menu-data repair. |
| MEDIUM | Administrator audit trace has English-only actor/action/field labels, retry, and error copy. | Confirmed remaining localization debt; not converted in this menu-data repair. |
| CONFIRMED | Locale persistence, main app localization delegates, and ARB key parity. | Tests pass. |

The remaining inventory and audit findings mean that **the entire app is not
yet uniformly localized**. Passing the route matrix does not prove every
expanded detail or every possible data state is translated.

### Remaining copy locations

- `lib/features/admin/tabs/inventory_tab.dart`: expanded recommendation,
  purchase-order, receiving, runtime, and supplier-history sections; English
  `Text` literals and interpolated operator summaries.
- `lib/features/inventory/inventory_provider.dart`: display-oriented English
  inventory summaries used by those detail sections.
- `lib/features/admin/widgets/admin_audit_trace_panel.dart`: default empty
  state, retry, actor, actions, entity names, and changed-field names.
- `lib/features/admin/providers/admin_audit_provider.dart`: English error
  messages supplied to the audit panel.

## Changes

- Added one menu-name resolver. It chooses the selected language when
  rendering, so an open cart or sheet can update without fetching again.
- Kept original names and all available translations in models. Missing or
  deleted historical menu translations retain the original item identity.
- Added translation fields to four existing read functions:
  `get_bm_menu_exception_history`, `get_bm_order_history_detail`,
  `get_store_menu_sales_analytics`, and `get_receipt_ledger`.
- Preserved ordering, grouping, quantities, money, historical identity, store
  authorization, pagination, and combined-payment table prefixes. The new
  migration does not update business records.
- Added translated search for BM history and localized menu values in the
  menu-sales workbook. Existing workbook column headers remain unchanged.
- Added migration preflight, verification, rollback, and an isolated SQL
  regression runner to the repository check command.

## Verification scope

Source review covered 42 `screen.dart`/`tab.dart` files, related widgets,
models, menu queries, and effective read-function definitions. This is a
source audit, not a claim of manually visiting every production screen.

### Automated route checks

18 route fixtures × 3 languages × 3 viewports × online/offline = 324 route
cases, all at 200% text scale. They check selected interface labels, rendering,
48dp touch targets, and online keyboard focus. Data services use test fixtures.

Routes: QR order, login, privacy consent, onboarding, waiter, kitchen,
print station, cashier, attendance kiosk, QC check/review, Photo Ops,
payment detail, super admin, restaurant sales export, store setup, and
the two administrator route variants.

5 modal types × 3 languages × 3 viewports = 45 modal cases: discount,
payment proof, red invoice, PIN, and confirmation.

Viewports: 390×844, 1024×768, and 1440×900. Languages: KO, EN, VI.

### Data and language-switch regression checks

- The screenshot's names in BM service/cancellation/staff-meal lists, open
  detail sheets, and original-order detail; switch EN → VI → KO without
  another list fetch on phone and desktop.
- Sold-out list and menu selection/cart retain translated names across locale
  changes; quantities and copied cart lines remain intact.
- Combo component, receipt ledger, and analytics models retain names and money;
  analytics ranking/chart widgets display EN/VI translations.
- Locale controller saves and restores selection. ARB keys match; EN/VI
  resources contain no Hangul.
- Real PostgreSQL 15 fixture: previous functions fail the translation
  regression; corrected functions pass. Includes grouped staff meals,
  cancellation/restoration, translated search, original-order details,
  analytics totals/hour rows, receipts, combined prefixes, deleted catalog
  fallback, grants, repeated application, rollback, and reapplication.
- Existing BM SQL tests run alongside the new SQL tests. Identity/access
  helpers are fixture implementations; production auth/RLS operation is not
  claimed from the fixture alone.

## Language policies and data boundaries

Customer-display and public/digital receipt paths intentionally use Vietnamese
under existing contracts. Printed operational receipts and bilingual/trilingual
procurement documents also have existing language policies. This repair does
not change those policies to follow the staff terminal's locale.

Store/person names, free-text reasons, notes, and untranslated historical menu
snapshots are business data. They are not machine-translated during rendering.
Language-selector autonyms such as “한국어” remain intentional.

## Delivery state

Local results recorded during this audit:

- `dart analyze --fatal-infos`: no issues.
- Full Flutter suite: **1,460 passed, 94 skipped, 0 failed**. The skipped
  integration checks have separate environment requirements; this count alone
  does not prove those integrations.
- Menu-localization SQL regression, baseline failure, rollback, and repeated
  application: **PASS** in disposable PostgreSQL 15.
- Full `bash scripts/check_repo.sh`: **PASS (exit 0)**, including SQL/API,
  Deno/Node contracts, security checks, deployment-shell fixtures, web release
  build, and whitespace checks. This is local validation, not a production
  release gate.

| State | Status |
| --- | --- |
| Source implemented | Yes, on `codex/fix-app-menu-localization-20260915` in an isolated worktree. |
| Local verification | Full repository check passed; detailed counts and scope above. |
| Production migration applied | No. |
| Production web deployed | No. |
| Production behavior verified after release | No; requires both migration and web release. |

Production release must use `scripts/deploy_pos_production.sh` with
`supabase/migrations/20260915200000_menu_display_localization.sql` after the
repository's exact-head GitHub and release gates. No release PASS is claimed.

## Priority follow-up

1. Review and release the menu-data fix and its migration together.
2. Verify the original BM history detail in production in EN, VI, and KO.
3. Move the remaining inventory detail and audit-trace English copy into ARB,
   and add populated expanded-detail tests for those sections.
