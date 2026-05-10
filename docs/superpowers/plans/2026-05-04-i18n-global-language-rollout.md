# Global I18n Language Rollout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> [NEW UI SOURCE OF TRUTH]
> The current UI source of truth is the Toast-style operating platform standard.
> Toast-style is not limited to OrderWorkspace.
> All Office, POS, and Admin operational surfaces must follow one light-first Toast-style operations shell.
> Legacy dark/admin-template visual language, tablet-first/kiosk POS visual language, card-heavy dashboards, panel-heavy layouts, browser-like POS navigation, and old menu grouping are deprecated.
> Preserve business logic, permissions, auth, route paths where possible, i18n, and data contracts.
> Redesign UX, menu IA, shell, navigation, visual system, and shared components according to the Toast-style operating platform standard.

**Goal:** Rebuild the POS UI so every user-facing screen supports English, Korean, and Vietnamese, and allow language switching from anywhere in the app with immediate UI updates.

**Architecture:** Introduce Flutter's generated localization layer as the single source of truth for copy, add a Riverpod-backed locale controller persisted with `SharedPreferences`, and expose language switching through the current or redesigned Toast-style operations shell. Then migrate hard-coded strings screen-by-screen, starting with shared navigation and auth flows, followed by each operational feature area.

**UI Boundary:** This i18n plan preserves copy behavior, route continuity where possible, permissions, auth, data contracts, and business logic. It does not require preserving existing shared chrome, menu grouping, sidebar layout, topbar layout, or visual hierarchy. UI copy must remain localized, but shell, navigation, visual system, and menu IA may be redesigned under the Toast-style operating platform standard.

**Tech Stack:** Flutter `gen_l10n`, `flutter_localizations`, `intl`, `flutter_riverpod`, `shared_preferences`, `go_router`

---

## Current-State Notes

- `MaterialApp.router` in [lib/main.dart](/Users/andreahn/globos_pos_system/lib/main.dart) has no `locale`, `supportedLocales`, or localization delegates yet.
- Shared chrome currently exists in [lib/widgets/app_nav_bar.dart](/Users/andreahn/globos_pos_system/lib/widgets/app_nav_bar.dart) and [lib/core/layout/web_sidebar_layout.dart](/Users/andreahn/globos_pos_system/lib/core/layout/web_sidebar_layout.dart), but those widgets are not mandatory visual structures. A redesigned Toast-style shell may replace them as long as language switching remains globally available and route/session state is preserved where possible.
- There are many hard-coded English strings across core screens such as [lib/features/auth/login_screen.dart](/Users/andreahn/globos_pos_system/lib/features/auth/login_screen.dart), [lib/features/admin/admin_screen.dart](/Users/andreahn/globos_pos_system/lib/features/admin/admin_screen.dart), [lib/features/waiter/waiter_screen.dart](/Users/andreahn/globos_pos_system/lib/features/waiter/waiter_screen.dart), [lib/features/kitchen/kitchen_screen.dart](/Users/andreahn/globos_pos_system/lib/features/kitchen/kitchen_screen.dart), and [lib/widgets/order_workspace.dart](/Users/andreahn/globos_pos_system/lib/widgets/order_workspace.dart).
- `SharedPreferences` is already used in providers such as [lib/features/auth/auth_provider.dart](/Users/andreahn/globos_pos_system/lib/features/auth/auth_provider.dart) and [lib/features/settings/printer_provider.dart](/Users/andreahn/globos_pos_system/lib/features/settings/printer_provider.dart), so locale persistence should follow the same pattern.

## Assumptions

- Language preference is device/session scoped first, not synced to Supabase user profile.
- All UI copy must move into localization resources, but business identifiers like store names, table numbers, and staff-entered notes remain raw data.
- Date/time/currency formatting should follow the selected locale where safe, but VND symbol and business calculations remain unchanged.

## File Map

**Create**
- `l10n.yaml`
- `lib/l10n/app_en.arb`
- `lib/l10n/app_ko.arb`
- `lib/l10n/app_vi.arb`
- `lib/core/i18n/locale_state.dart`
- `lib/core/i18n/locale_controller.dart`
- `lib/core/i18n/locale_extensions.dart`
- `lib/widgets/language_switcher.dart`
- `test/core/i18n/locale_controller_test.dart`
- `test/widgets/language_switcher_test.dart`
- `test/app/i18n_smoke_test.dart`

**Modify**
- `pubspec.yaml`
- `lib/main.dart`
- `lib/widgets/app_nav_bar.dart`
- `lib/core/layout/web_sidebar_layout.dart`
- `lib/features/auth/login_screen.dart`
- `lib/features/admin/admin_screen.dart`
- `lib/features/onboarding/onboarding_screen.dart`
- `lib/features/waiter/waiter_screen.dart`
- `lib/features/kitchen/kitchen_screen.dart`
- `lib/features/cashier/cashier_screen.dart`
- `lib/features/payment/payment_detail_screen.dart`
- `lib/features/attendance/attendance_kiosk_screen.dart`
- `lib/features/qc/qc_check_screen.dart`
- `lib/features/photo_ops/photo_ops_screen.dart`
- `lib/features/super_admin/super_admin_screen.dart`
- `lib/widgets/order_workspace.dart`
- `lib/widgets/offline_banner.dart`
- `lib/widgets/pin_dialog.dart`
- `lib/widgets/error_toast.dart`
- Feature providers/services that currently emit user-facing English strings

---

### Task 1: Establish Flutter Localization Foundation

**Files:**
- Create: `l10n.yaml`, `lib/l10n/app_en.arb`, `lib/l10n/app_ko.arb`, `lib/l10n/app_vi.arb`
- Modify: `pubspec.yaml`, `lib/main.dart`

- [ ] Add `flutter_localizations` to `pubspec.yaml` and confirm `intl` stays aligned with the Flutter SDK version already in use.
- [ ] Add `generate: true` under the Flutter section if it is not already enabled.
- [ ] Create `l10n.yaml` so generated localization output is deterministic and committed through the normal Flutter `gen_l10n` flow.
- [ ] Seed the three ARB files with the first shared keys:
  - app title
  - common buttons like confirm, cancel, close, retry, logout
  - navigation labels like back, forward, home, settings
  - auth strings for login
- [ ] Update `MaterialApp.router` in [lib/main.dart](/Users/andreahn/globos_pos_system/lib/main.dart) to include:
  - `locale`
  - `supportedLocales`
  - `localizationsDelegates`
  - `localeResolutionCallback` only if needed after testing
- [ ] Run `flutter gen-l10n` and ensure generated localizations are available app-wide.

### Task 2: Add Global Locale State and Persistence

**Files:**
- Create: `lib/core/i18n/locale_state.dart`, `lib/core/i18n/locale_controller.dart`, `lib/core/i18n/locale_extensions.dart`
- Modify: `lib/main.dart`
- Reference: `lib/features/auth/auth_provider.dart`, `lib/features/settings/printer_provider.dart`

- [ ] Create a locale model/state that supports exactly three choices: `en`, `ko`, `vi`.
- [ ] Implement a Riverpod controller that:
  - loads persisted locale from `SharedPreferences`
  - falls back to Korean or English using one explicit rule
  - exposes `setLocale`, `cycleLocale` if useful, and `currentLocale`
- [ ] Keep the persistence key isolated, for example `app_locale`.
- [ ] Add a small extension/helper so widgets can call a short accessor instead of repeatedly importing generated localization classes.
- [ ] Wire the provider into `GlobosPosApp` so locale changes rebuild the entire app immediately without re-login or full restart.

### Task 3: Define the Global Language-Switch UX

**Files:**
- Create: `lib/widgets/language_switcher.dart`
- Modify: `lib/widgets/app_nav_bar.dart`, `lib/core/layout/web_sidebar_layout.dart`, `lib/features/auth/login_screen.dart`, `lib/features/admin/admin_screen.dart`

- [ ] Standardize one reusable switcher widget with visible labels for:
  - `EN`
  - `KO`
  - `VI`
- [ ] Place the switcher in every persistent/shared shell so language can be changed from anywhere. If the legacy chrome is replaced, place the switcher in the redesigned Toast-style shell instead:
  - top navigation area via [lib/widgets/app_nav_bar.dart](/Users/andreahn/globos_pos_system/lib/widgets/app_nav_bar.dart)
  - web/desktop sidebar top bar via [lib/core/layout/web_sidebar_layout.dart](/Users/andreahn/globos_pos_system/lib/core/layout/web_sidebar_layout.dart)
  - login screen header/panel because unauthenticated users need access too
  - admin mobile app bar because `AppNavBar` is not always enough on small screens
- [ ] Decide one mobile behavior and keep it consistent:
  - segmented control if width allows
  - compact popup menu if header space is tight
- [ ] Make the switcher update copy instantly while keeping the current route and current screen state intact.

### Task 4: Convert Shared UI Copy First

**Files:**
- Modify: `lib/widgets/app_nav_bar.dart`, `lib/core/layout/web_sidebar_layout.dart`, `lib/widgets/offline_banner.dart`, `lib/widgets/pin_dialog.dart`, `lib/widgets/error_toast.dart`

- [ ] Replace all shared shell labels, tooltips, and status pills with localization keys first.
- [ ] Keep iconography and layout unchanged unless a translated label causes clipping.
- [ ] Add keys for compact/common UI phrases:
  - offline
  - loading
  - no data
  - required
  - success
  - failed
  - retry
- [ ] Validate that the shared widgets still render correctly for the longest expected Vietnamese and Korean labels.

### Task 5: Migrate Screens in Execution Order

**Files:**
- Modify:
  - `lib/features/auth/login_screen.dart`
  - `lib/features/onboarding/onboarding_screen.dart`
  - `lib/features/admin/admin_screen.dart`
  - `lib/features/waiter/waiter_screen.dart`
  - `lib/features/kitchen/kitchen_screen.dart`
  - `lib/features/cashier/cashier_screen.dart`
  - `lib/features/payment/payment_detail_screen.dart`
  - `lib/features/attendance/attendance_kiosk_screen.dart`
  - `lib/features/qc/qc_check_screen.dart`
  - `lib/features/photo_ops/photo_ops_screen.dart`
  - `lib/features/super_admin/super_admin_screen.dart`
  - `lib/widgets/order_workspace.dart`

- [ ] Migrate in this order so the app becomes progressively usable:
  1. auth and onboarding
  2. shared admin chrome and navigation tabs
  3. waiter and order workspace
  4. kitchen and cashier
  5. payment, attendance, QC, photo ops
  6. super admin
- [ ] For each screen, split strings into three buckets:
  - static labels and button text
  - interpolated messages such as guest counts and table-specific confirmations
  - feature-state messages such as loading, empty, and error text
- [ ] Use parameterized localization messages for dynamic content instead of string concatenation, especially in:
  - guest count prompts
  - order cancellation confirmations
  - move-table messages
  - menu empty states
  - kitchen order state labels
- [ ] Keep domain terms consistent across the app by defining canonical keys once:
  - store
  - table
  - kitchen
  - cashier
  - e-invoice
  - attendance
  - settlement

### Task 6: Move Provider and Service Error Strings Into I18n-Friendly Form

**Files:**
- Modify providers/services that surface user-facing text, including:
  - `lib/features/onboarding/onboarding_provider.dart`
  - `lib/features/auth/auth_provider.dart`
  - `lib/features/kitchen/kitchen_provider.dart`
  - `lib/features/admin/providers/tables_provider.dart`
  - other providers found by string audit

- [ ] Audit every provider/service that currently stores English error text directly in state.
- [ ] Decide one safe pattern and use it consistently:
  - preferred: store error codes/enum values and translate in the UI
  - fallback: store localization keys plus interpolation payload
- [ ] Avoid passing `BuildContext` into providers just for translation.
- [ ] Prioritize user-visible operational failures first:
  - login failures
  - onboarding failures
  - kitchen load/update failures
  - printer/payment/order failures

### Task 7: Add Locale-Aware Formatting Rules

**Files:**
- Modify likely formatting helpers and affected widgets:
  - `lib/core/utils/time_utils.dart`
  - `lib/widgets/order_workspace.dart`
  - feature screens that display dates/times/counts

- [ ] Audit any manual formatting that should respect locale, especially dates and relative time-like phrases.
- [ ] Keep monetary formatting business-safe:
  - continue using VND values and calculations
  - localize surrounding labels and separators only where safe
- [ ] Ensure Vietnamese and Korean text renders well with existing font choices, and note if fallback fonts are needed later.

### Task 8: Add Regression Tests Before Full Rollout

**Files:**
- Create: `test/core/i18n/locale_controller_test.dart`, `test/widgets/language_switcher_test.dart`, `test/app/i18n_smoke_test.dart`
- Modify: existing widget/integration tests that assert hard-coded English copy

- [ ] Add a provider test that verifies:
  - default locale selection
  - persistence and reload
  - switching between `en`, `ko`, and `vi`
- [ ] Add widget tests for the global language switcher:
  - current selection highlighted
  - tap changes locale
  - current route stays unchanged
- [ ] Add an app smoke test that verifies:
  - login screen copy changes when locale changes
  - admin navigation labels change when locale changes
  - a representative operational screen like waiter or kitchen updates without restart
- [ ] Update or relax old tests that currently assert literal English strings.

### Task 9: Run a Full String Audit and Close Gaps

**Files:**
- Modify: all touched UI files as needed

- [ ] Run a repository audit for remaining user-facing hard-coded strings under `lib/`.
- [ ] Ignore:
  - SQL field names
  - API payload keys
  - route paths
  - stable enum/internal identifiers
- [ ] Fix leftover literals in dialogs, toasts, tooltips, badges, and empty states.
- [ ] Repeat the audit until remaining literals are clearly non-UI or intentionally untranslated brand/domain names.

### Task 10: Verification and Release Readiness

**Files:**
- No new code required unless issues are found during verification

- [ ] Run:
  - `flutter gen-l10n`
  - `flutter analyze`
  - targeted widget tests
  - key integration/smoke flows for login, waiter, kitchen, cashier, admin
- [ ] Manually verify the following in all three languages:
  - app starts with persisted language
  - login screen can switch language before auth
  - switching language from a deep screen does not navigate away
  - tab labels and app bars update immediately
  - dialogs and toasts use the new language
  - no text overflow in sidebar, buttons, and mobile app bars
- [ ] Capture a short release checklist in the PR description:
  - screens covered
  - known untranslated areas if any
  - whether provider error code migration is complete

---

## Recommended Execution Sequence

1. Foundation and locale state
2. Global switcher and app-shell placement
3. Shared UI strings
4. Auth and onboarding
5. Admin navigation and tabs
6. Waiter and order workspace
7. Remaining operational screens
8. Provider/service error migration
9. Tests and string audit
10. Full verification

## Risks To Watch

- Existing tests may be tightly coupled to English literals and fail in large batches once localization lands.
- Providers currently mix transport/business errors with user-facing text, so migrating those safely may take longer than widget copy replacement.
- Some layouts, especially sidebar items and compact mobile headers, may need spacing adjustments once Korean and Vietnamese labels are introduced.
- The worktree is already dirty in many files, so implementation should be staged carefully to avoid colliding with unrelated in-flight changes.

## Done Criteria

- Every user-facing screen can render in English, Korean, and Vietnamese.
- Language can be changed from login and from authenticated screens without route reset.
- The selected language persists across app restart.
- Shared UI, dialogs, toasts, and major operational flows no longer depend on hard-coded English strings.
- Localization tests and audit checks pass.
