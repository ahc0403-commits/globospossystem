# POS Operational Premium V2 Implementation Plan

Date: 2026-06-11
Status: Planned (not started)
Predecessor: `docs/pos/POS_TERMINAL_REFERENCE_REDESIGN_IMPLEMENTATION_PLAN_2026_06_11.md` (completed, see closure doc)
Scope: Frontend UI only. This plan does not authorize backend, Supabase schema, RLS, auth, payment RPC, WeTax, settlement, or Office coupling changes.

## Binding Constraints (inherited, restated)

- Preserve all provider/service/RPC contracts, payment flow semantics, WeTax async dispatch, RLS, and auth behavior.
- Payment completion must never depend on WeTax availability.
- VND only. No KRW symbols.
- Fixed system labels resolve through l10n (`app_en.arb` / `app_ko.arb` / `app_vi.arb`). Registered menu/product/supplier/table names remain data-driven, rendered as stored.
- No negative letterSpacing in final styling.
- Office app coupling (`restaurants` table, `id/name/address/is_active` columns) untouched.
- Token changes must be additive; existing `AppColors`, `Toast*Tokens`, `PosColors` aliases must keep compiling.

---

## 1. Executive Diagnosis

The 2026-06-11 redesign fixed structure: every screen now has a role header, a KPI strip, and a workspace split that matches the operator's primary job. The remaining gap — verified against the real after-screenshots — is not "styling" in the decorative sense. It is four specific deficits:

### 1.1 Information weight is flat

Every screen renders the same pattern: white card, 1px `#E5E7EB` border, identical radius, identical low shadow. In the waiter screenshot, the KPI strip ("전체 7 / 사용 중 3 / 비어 있음 4"), the table grid, and the empty inspector all carry the same visual weight. In cashier, the amount-due region — the single most important number in the building — sits in the same white-card treatment as the network status chip. Nothing tells the eye "this is the thing you act on." A field terminal inverts this: one dominant anchor per screen, everything else recedes.

### 1.2 Surface hierarchy is one level deep

The token file (`lib/core/ui/pos_design_tokens.dart`) defines surfaces (`canvas`, `surface`, `mutedSurface`) but the screens use effectively two: light-gray canvas and white card. There is no systematic distinction between **passive background**, **operating surface** (where work lives), **input/action surface** (what you press), and **selected/armed surface** (what you've committed to). `PosTerminalColors` already contains a dark shell palette and `ticketPaper`/`floorCanvas` tones, but only the cashier payment pad uses any of it, hard-coded. The hierarchy exists in tokens embryonically; it is not yet a contract the screens obey.

### 1.3 Empty states are inert

The cashier screenshot shows the problem exactly: with zero payable orders, ~85% of the screen is blank white space with a centered icon. Kitchen lanes show "조리중 대기 중" placeholder boxes that occupy a full column to say nothing. A real terminal's idle screen still works: it shows network state, last completed action, what's oldest elsewhere in the system, and the fastest path back to work. Empty ≠ useless.

### 1.4 Interaction response is undefined

There is no token-level definition of pressed, processing, destructive-arm, or offline-blocked states. The screens rely on default Material ink ripple, which reads as web-app, not terminal. The premium feel of Toast/Square hardware is substantially the *response*: an immediate pressed-state change, a hard lock during payment processing, an explicit two-step destructive confirm. None of this is currently specifiable because the tokens don't exist; each screen would improvise it differently.

**Conclusion:** V2 must start at the token and interaction layer (Phase 0), because all four deficits are cross-cutting. Per-screen redesign first would mean re-touching all five screens again when the foundation lands.

---

## 2. Phase 0 — Token and Interaction Foundation

Primary files:

- `lib/core/ui/pos_design_tokens.dart` (extend)
- `lib/core/ui/pos_terminal_primitives.dart` (extend; do not break the 8 existing primitives)
- `lib/core/ui/app_theme.dart` (read-mostly; no global palette shift)

All additions are **additive namespaces**. No existing constant is renamed, removed, or re-valued. Existing screens compile unchanged until their Phase 1 slice.

### 2.1 Surface hierarchy tokens — `PosSurfaceRole`

Seven named roles, each with background, border, and text-emphasis values, defined for the light shell (and a scoped dark variant only where Phase 1 Kitchen Option A is approved):

| Role | Purpose | Direction (light shell) |
|---|---|---|
| `background` | Passive canvas behind everything | Slightly deeper than current `#F5F7FA`; recedes |
| `operating` | Where live work renders (queue, board, map) | Near-white but distinct from action surfaces; minimal shadow |
| `action` | Pressable inputs: tiles, pads, buttons | Crisp border, stronger contrast, visible affordance at arm's length |
| `selected` | Committed selection (table, order, method) | Accent-filled or accent-bordered; unmistakably different from hover |
| `danger` | Destructive/warning zones (void, cancel, delayed) | Reserved red family; never used decoratively |
| `disabled` | Unavailable actions | Reduced contrast but still legible labels (not 40% opacity mush) |
| `processing` | Locked mid-transaction (payment in flight) | Distinct "armed/busy" tone + mandatory progress affordance |

Rule: a widget may use exactly one role; mixing roles inside one container is a review-rejection criterion in Phase 1.

### 2.2 Typography tokens — extend `PosMoneyText` → `PosNumericText`

- **VND amount scale**: `amountDue` (dominant anchor, ≥ existing 32 w900), `amountLarge`, `amountLine`, `amountCompact` — kept, plus `amountHero` for the cashier due block sized to be the largest text on screen. All amounts render with a single VND presentation (one formatter, one symbol position) — audit the existing `'₫'` formatter usage in `order_workspace.dart` and cashier for consistency.
- **Tabular numerics**: all amount/quantity/timer styles set `fontFeatures: [FontFeature.tabularFigures()]` so columns and live timers don't jitter. (Verify Noto Sans KR honors `tnum` on web; if not, fall back to fixed-width digit container and record as known limitation.)
- **Identifiers**: `tableId` / `orderId` styles — large, w800, never truncated; identifiers are scanned from 1–2 m away.
- **Kitchen elapsed time**: `elapsedPrimary` (largest non-identifier element on a ticket) + `elapsedOverdue` variant that changes weight/size, not only color.
- **Inventory hierarchy**: `qtyUnit` (quantity + unit always one unbreakable unit, e.g. "12 pack"), `unitPrice`, `lineAmount` — sized so a row reads qty × price = amount before the product name.

### 2.3 Touch state tokens — `PosTouchStates`

Token-level definitions (color/elevation/scale deltas + minimum durations) for:

| State | Contract |
|---|---|
| `pressed` | Immediate (<50 ms perceived) surface darkening or inset; no reliance on Material ripple alone |
| `selected` | Persistent; visually distinct from pressed and hover |
| `disabled` | Legible label + explicit reason affordance where applicable (e.g. offline) |
| `processing` | Locks the action surface; spinner/progress + label change ("Processing…", localized); blocks double-tap |
| `destructiveConfirm` | Two-step: arm (danger surface) → confirm; auto-disarm timeout token |
| `offlineBlocked` | Distinct from disabled: shows offline cause, pairs with existing connectivity_provider state |

### 2.4 Density tokens — extend `PosDensity`

- `touchTargetMin`: raise from 44 → 48 logical px for live-operator surfaces (waiter/cashier/kitchen); admin surfaces may stay 44. Applied as minimum, not uniform inflation.
- Stable dimensions: order row, menu tile, KDS ticket, payment method tile, floor table tile, inventory row keep **fixed heights that do not shift on hover/selection/content-length** (selection changes surface, never geometry).
- Quick-tender pad sizing for cashier (Phase 1 consumer).

### 2.5 Phase 0 deliverables and acceptance

1. Extended token file with the four namespaces above, documented in-file.
2. Extended primitives: `PosActionTile` (action surface + full touch-state cycle), `PosAmountAnchor` (hero VND block), `PosDestructiveButton` (two-step confirm) — presentation-only, no provider imports, labels passed in by callers.
3. Widget tests for the new primitives: state cycle (pressed/disabled/processing), overflow with long KO/VI/EN labels, tabular numeric rendering.
4. `flutter analyze` clean; `flutter test` green; zero changes to existing screen files in this phase.

```sh
flutter analyze
flutter test test/pos_terminal_primitives_test.dart
flutter test
```

---

## 3. Phase 1 — Screen Identity Refactors

One implementation slice (one PR) per screen, in the order given in Section 9. Each slice consumes Phase 0 tokens; no slice introduces new token values inline.

### 3.1 Waiter — hall order terminal

- **Primary job**: select table → add items → send to kitchen.
- **Visual archetype**: touch order terminal — table strip + menu grid + persistent check rail.
- **Information hierarchy**: selected table identity > current check (items, qty, total) > menu grid > KPI strip (demote to a slim status line).
- **Next action**: Send order — always visible, `action` surface, `processing` lock on submit, offline-queue state surfaced via `offlineBlocked` styling.
- **Risk**: Medium. Large file (`order_workspace.dart`, ~1,840 lines) shared by waiter/admin entry points; cart/send/offline-queue callbacks must be preserved verbatim.
- **Files**: `lib/widgets/order_workspace.dart`, `lib/features/table/floor_layout.dart` (table strip styling only).
- **Tests**: `test/waiter_floor_layout_contract_test.dart`, `test/order_panel_close_session_contract_test.dart`, `test/cashier_waiter_workspace_i18n_contract_test.dart`.
- **Screenshot target**: `screenshots/pos-premium-v2-01-waiter-<date>.png`.

### 3.2 Cashier — payment terminal

- **Primary job**: select payable order → choose method → confirm payment.
- **Visual archetype**: payment terminal — queue rail + order summary + payment pad with `PosAmountAnchor` due block as the dominant element.
- **Information hierarchy**: amount due > payment methods + confirm > order line items > queue > everything else.
- **Next action**: Confirm payment — disabled until method/requirements met, `processing` lock during `processPayment`, double-tap blocked at the widget level.
- **Risk**: High (payment flow adjacency). UI-only: `processPayment`, paymentProofService, receipt printing, red invoice modal, admin cancellation checks, offline payment restrictions are untouched.
- **Files**: `lib/features/cashier/cashier_screen.dart`. The hard-coded dark payment pad migrates onto `PosSurfaceRole`/`PosTerminalColors` tokens (same look, tokenized).
- **Tests**: `test/payment_method_contract_test.dart`, `test/payment_total_calculator_test.dart`, `test/cashier_receipt_print_contract_test.dart`, `test/payment_split_contract_test.dart`, `test/pilot_red_invoice_smoke_contract_test.dart`.
- **Screenshot target**: `screenshots/pos-premium-v2-02-cashier-<date>.png`.

### 3.3 Kitchen — ticket rail (dark mode is risky and optional)

- **Primary job**: scan ticket age → progress item status.
- **Visual archetype**: ticket rail / production board, not a card dashboard.

Two options compared:

| | **A. Scoped dark KDS board** | **B. Bright high-contrast ticket rail** |
|---|---|---|
| Readability in bright kitchens | Risky — glare can wash out dark surfaces | Strong — matches existing lighting |
| Token blast radius | Needs a full scoped dark surface set + per-widget dark variants | Reuses light-shell tokens with stronger status contrast |
| Test impact | `kitchen_operational_attention_contract_test.dart` and shared primitives may need dark-mode branches | Minimal — same structure, stronger weights |
| Regression risk | Medium-high (theme leakage into shared widgets) | Low |
| Rollback | Whole-screen revert only | Per-element revert possible |

**Decision: implement Option B first.** Option A is deferred and requires separate explicit approval; if approved later, it ships as its own PR with a kitchen-scoped token namespace (`PosKdsDark*`), never via global theme changes.

- **Information hierarchy (Option B)**: elapsed time (size/weight escalation per `elapsedOverdue`) > ticket identity (table/order) > item quantities > status action. Status must be distinguishable by shape/weight/badge text, not color alone.
- **Next action**: per-item status advance (`pending → preparing → ready → served`) on `action` surfaces.
- **Risk**: Medium. Kitchen currently uses legacy `AppColors` + explicit `GoogleFonts.notoSansKr` — migrating to `PosColors`/Phase 0 tokens is part of this slice and is the main churn source. Preserve alert sound, flashing new-order, completion animation, polling behavior.
- **Files**: `lib/features/kitchen/kitchen_screen.dart`.
- **Tests**: `test/kitchen_operational_attention_contract_test.dart`, `test/provider_poll_guard_test.dart`.
- **Screenshot target**: `screenshots/pos-premium-v2-03-kitchen-<date>.png`.

### 3.4 Admin Tables — floor map workstation

- **Primary job**: monitor floor state; edit layout deliberately.
- **Visual archetype**: floor map is the primary object on `floorCanvas` surface; controls and inspector are secondary chrome.
- **Information hierarchy**: floor map (occupied/selected/warning states readable at a glance, status by fill + badge, not dot only) > selected-table inspector > counts/filters > edit mode.
- **Next action**: in live mode, select table → inspector; in edit mode, move/save. Live vs. edit must be visually unmistakable (edit mode shifts the canvas treatment, shows save on `action` surface only when dirty).
- **Risk**: Low-medium. Preserve `_draftLayoutByTableId`, layout save flow, selection, admin audit trace.
- **Files**: `lib/features/admin/tabs/tables_tab.dart`, `lib/features/table/floor_layout.dart`.
- **Tests**: `test/admin_table_layout_editor_contract_test.dart`, `test/admin_table_selection_contract_test.dart`, `test/table_layout_model_contract_test.dart`, `test/table_reservation_contract_test.dart`.
- **Screenshot target**: `screenshots/pos-premium-v2-04-admin-tables-<date>.png`.

### 3.5 Inventory — purchase workstation

- **Primary job**: review recommendations → adjust quantities → create purchase order.
- **Visual archetype**: order-sheet workstation. Each recommendation row is a calculation line, not a description card.
- **Information hierarchy**: per row, left-to-right: product (truncatable) → current stock + unit → recommended qty × order unit → unit price → **estimated amount (`lineAmount`, never truncated)** → supplier → risk badge. Supplier-grouped totals and grand total use `amountLarge`.
- **Next action**: create purchase order — visible whenever a draft has lines, with line count + total on the button region.
- **Risk**: Medium (file size: `inventory_purchase_screen.dart` ~6,600 lines, 11 sub-sections). Scope V2 to the purchase-management and dashboard sections; other sections only inherit tokens passively. Office-approval boundary ("Office 승인은 Office 전용") stays read-only.
- **Files**: `lib/features/inventory_purchase/inventory_purchase_screen.dart`, `lib/features/admin/tabs/inventory_tab.dart` (entry only).
- **Tests**: `test/inventory_admin_ui_contract_test.dart`, `test/inventory_purchase_office_contract_test.dart`, `test/inventory_purchase_readonly_overview_contract_test.dart`.
- **Screenshot target**: `screenshots/pos-premium-v2-05-inventory-<date>.png`.

---

## 4. Phase 2 — Empty-State and Data-Dependent States

Rule: **frontend-only**. An empty state may consume only data already present in the screen's existing provider state. No new Supabase queries, no schema work, no provider contract changes. Anything requiring new data is logged as a product/backend follow-up, not built.

| Screen | Buildable now (existing provider data) | Requires new data → follow-up only |
|---|---|---|
| Waiter | Selected-table empty inspector shows occupied-table list with elapsed indicators (tables + active order state already in `order_provider`/table strip data); offline queue count (`offlineQueueCount`) | Per-table "oldest open since" if open-timestamp is not already in loaded table/order data |
| Cashier | "No payable orders" panel shows: network status (connectivity_provider — already rendered in header), queue-refresh affordance using the existing load path, and guidance derived from current `orders` list state | "Last completed payment" — `PaymentState` does not retain completed payments after processing; needs provider/history work → follow-up |
| Kitchen | Empty lanes collapse to slim rails instead of full-height placeholder boxes; attention rail already computes oldest wait / counts from `KitchenState.orders` — reuse in empty layout | Historical throughput ("today served N tickets") — not in `KitchenState` → follow-up |
| Tables | No-selection inspector shows status counts and a tappable list of occupied tables (all in `TablesState.tables`) | Per-table revenue/last-order summary beyond what `order_provider` already loads → follow-up |
| Inventory | "0 recommendations" panel explains the recommendation precondition (snapshot date + target stock days are already on screen) and routes to direct/supplier order creation (existing actions); pending Office-approval count from existing order summary state | "Why zero" diagnostic (consumption coverage, missing recipe links) — needs analysis queries → follow-up |

Empty-state copy is localized (new l10n keys in all three ARB files). No fixed English strings.

Deliverable: `docs/pos/POS_OPERATIONAL_PREMIUM_V2_DATA_FOLLOWUPS.md` listing every deferred data-dependent item with the provider/query it would require. This document authorizes nothing; it is input for product/backend planning.

---

## 5. "3-Second Judgement" Measurable Criteria

Each criterion is checked on the real app at 1366×768 with seeded data, in all three locales, and recorded in the closure doc as PASS/FAIL.

**Cashier**
- [ ] Amount due is the single largest text element on screen when an order is selected.
- [ ] Payment method tiles and the confirm action are visible without scrolling or searching at 1366×768.
- [ ] Confirm is visibly disabled (with reason) until method/requirements are satisfied; processing state locks it.

**Kitchen**
- [ ] The oldest/most-delayed ticket is visible without scrolling at 10x seeded ticket volume (delayed tickets pinned or lanes ordered oldest-first).
- [ ] New / preparing / ready / delayed are distinguishable with color removed (grayscale screenshot check): shape, badge text, or weight must differ.
- [ ] Elapsed time on each ticket is readable at arm's length (≥ the `elapsedPrimary` size).

**Waiter**
- [ ] One scan captures: selected table, active check item count + total, and the send action — all simultaneously visible, no scroll.
- [ ] Quantity steppers meet `touchTargetMin` and never overlap menu names or prices with long VI/KO names.
- [ ] Send action shows distinct idle / processing / offline-queued states.

**Tables**
- [ ] The floor map occupies the dominant screen region; KPI/filters are chrome, not peers.
- [ ] Live mode and edit mode are distinguishable within 3 seconds (canvas treatment + action set change).
- [ ] Table status is readable per tile (fill + badge), not dot-only.

**Inventory**
- [ ] Each recommendation row reads left-to-right as qty/order-unit × unit price = estimated amount; amount is never truncated.
- [ ] Supplier and risk status are visible on the row without expanding.
- [ ] Draft total + line count are visible wherever the create-order action is.

---

## 6. Validation Plan

Per-slice (every PR):

```sh
flutter analyze
flutter test <targeted tests listed in the slice>   # see Sections 2.5 and 3.x
```

Before closure (after the last slice):

```sh
flutter analyze
flutter test
rg "₩" lib --glob '!lib/l10n/*.arb'
rg "Ingredient Management|Recipe Management|Physical Count|Inventory Report|PROCESS PAYMENT|Nothing selected|No payable orders|Start Prep|Add Table" lib --glob '!lib/l10n/*.arb'
rg "letterSpacing:\s*-" lib/core lib/features lib/widgets
flutter gen-l10n   # after any ARB additions (empty-state keys)
```

All four greps must return zero matches; both flutter commands must pass.

Screenshot requirements:

- Real authenticated local Flutter web session (same method as 2026-06-11 closure), seeded data including 10x kitchen queue and long KO/VI names.
- Five "after" screenshots at the targets named in Section 3, plus one grayscale kitchen capture for the color-independence check.
- Real before/after board regenerated at `design_artifacts/pos_operational_premium_v2_<date>/00_real_before_after_contact_sheet.png` plus per-screen boards, using the 2026-06-11 after-screenshots as the new "before".

Closure doc: `docs/pos/POS_OPERATIONAL_PREMIUM_V2_CLOSURE_<date>.md` with the Section 5 checklist results recorded item by item.

---

## 7. Risk Register

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | Kitchen dark mode readability in bright kitchens; theme leakage into shared widgets | HIGH | Option B (bright high-contrast) ships first; dark board deferred behind separate approval, kitchen-scoped namespace only |
| R2 | Empty-state ideas silently pulling in new provider queries / data work | HIGH | Phase 2 table is the allowlist; anything not in the "buildable now" column goes to the follow-ups doc, not code |
| R3 | Over-tokenization / visual churn — new tokens drifting unrelated admin screens | MEDIUM | Additive namespaces only; non-target screens must be pixel-stable (spot-check einvoice/reports tabs after Phase 0); one-surface-role-per-widget rule |
| R4 | Regression in payment, Office coupling, WeTax, RLS via adjacent edits | HIGH | UI-only diffs; the contract tests in Sections 3.2/3.5 run per slice; no provider/service/RPC file edits; Office-approval UI stays read-only |
| R5 | Long KO/VI/EN label overflow breaking fixed-height rows/tiles | MEDIUM | Fixed geometry + defined truncation order (name truncates, amount/unit/identifier never); primitive overflow tests with long-string fixtures in all three locales |
| R6 | VND amount readability — long amounts (e.g. ₫12.345.000) wrapping or jittering | MEDIUM | Tabular figures, minimum-width amount containers, hero block sized against the longest seeded amount; web `tnum` support verified in Phase 0 |
| R7 | Large-file churn in `order_workspace.dart` / `inventory_purchase_screen.dart` causing unreviewable diffs | MEDIUM | Inventory scoped to purchase/dashboard sections; waiter slice limited to layout/styling, callbacks untouched; PR-per-screen keeps diffs bounded |

---

## 8. Rollback Strategy

1. **Token layer**: Phase 0 is additive, so rollback = reverting the Phase 0 commit(s); since no screen consumes new tokens until its own slice, token rollback before Phase 1 is zero-impact. After Phase 1 slices land, token rollback requires reverting dependent slices first (revert in reverse merge order).
2. **Per-screen**: each screen slice is one PR and reverts independently. Reverting one screen must not affect another (enforced by no cross-screen file edits within a slice).
3. **Localization**: new l10n keys and ARB entries are kept on rollback unless they break compilation (`flutter gen-l10n` failure) — unused keys are harmless.
4. **Never** roll back via DB migrations, provider contract changes, or service edits. If a UI slice appears to require any of those to revert cleanly, the slice was mis-scoped: stop and re-plan.

---

## 9. Implementation Order

1. **Phase 0** — token + interaction contract (`PosSurfaceRole`, `PosNumericText`, `PosTouchStates`, `PosDensity` extensions, new primitives + tests).
2. **Waiter** order terminal slice.
3. **Cashier** payment terminal slice.
4. **Kitchen** — bright high-contrast ticket rail (Option B). Dark KDS board only if separately approved afterward, as its own PR.
5. **Admin Tables** floor map slice.
6. **Inventory** purchase workstation slice.
7. **Empty-state enhancement** (Phase 2, frontend-only allowlist + follow-ups doc).
8. **Real screenshot closure** — full `flutter test`, greps, five after-screenshots + grayscale kitchen check, before/after board, closure doc with Section 5 checklist results.

## Open Questions (answer before the relevant slice)

- Should the cashier quick-tender pad values be computed from amount due (round-up denominations) or fixed per store? (Before slice 3.)
- Does Noto Sans KR render `tnum` correctly on Flutter web? (Verify in Phase 0; affects R6 mitigation.)
- For the kitchen grayscale check, is 10x seeded volume achievable with the existing smoke-account seeding path, or does QA need a seeding script (frontend/test tooling only)?
