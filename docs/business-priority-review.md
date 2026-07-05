# GLOBOSVN POS — Business Priority Review (Audit Re-evaluation)

- **Date:** 2026-06-10
- **Purpose:** re-rank the 2026-06-10 audit findings from the perspective of an operating POS business, not engineering best practice.
- **New context applied:** (1) WeTax accounts are test-only — no real invoices, no customer data, deleted after testing; (2) Photo Objet does not use WeTax in production — no red-invoice/e-invoice operational process today; (3) the account-info xlsx is scheduled for cleanup but its contents were to be verified.
- **New evidence gathered for this review:** the tracked `GLOBOS_POS_화면플로우_계정정보_2026-05-25.xlsx` was extracted and inspected sheet-by-sheet. **Verdict: it contains no API keys, no service_role keys, no connection strings — but it does contain working login credentials** (16 accounts with shared weak passwords — values redacted from this report) **together with the live POS URL** (`https://globospossystem.vercel.app`). If those accounts exist in the production Supabase auth — and the file documents them as the accounts used on the live URL — anyone with repo access can log into the live POS as super admin today.

---

## 1. The WeTax reassessment (applies to ~10 findings at once)

Criteria: production impact / customer impact / revenue impact / security impact / future activation.

| Criterion | Assessment |
|---|---|
| Real production impact | **None today.** No real invoices issue; failures affect a test pipeline only. |
| Real customer impact | None — no customer receives a WeTax e-invoice. |
| Real revenue impact | None directly. (P6 verified: payment completion never depends on WeTax, so even total WeTax failure cannot block sales.) |
| Real security impact | Low. Leaked credentials are test-account; the cross-store `tax_entity` write hole only matters when tax entities are real. |
| Future activation likelihood | **High** — the integration was built deliberately in Phase 2 (scope v1.3) and e-invoicing is a legal requirement for Vietnamese F&B. The work is deferred, not cancelled. |

**Consequence:** all WeTax-internal findings are downgraded out of the now/this-week buckets into a single **"WeTax Activation Gate"** checklist — a hard precondition for flipping WeTax to production, not current operational risk. Two WeTax-adjacent items do NOT get the downgrade:

1. **The pg_cron jobs run in production right now** (dispatcher every 1 min, poller every 2 min) and `process_payment` inserts an `einvoice_jobs` row for every real payment. So the missing `einvoice_jobs` index and the idle-run write churn are small but real production costs — kept at P2.
2. **CRON_SECRET** gates not only WeTax but also `generate-settlement` and `generate_delivery_settlement` — the **Deliberry settlement pipeline is real production money flow**. The secret stays a real finding (see below).

---

## 2. Item-by-item re-evaluation (the seven named + all P0/P1 challenges)

### 2.1 Cross-tenant data leak (views without `security_invoker`)
- **Original → Revised: P0 → P0** (justified, with nuance)
- **Challenge:** today all stores belong to one operator (two brands, Modern K / K-Noodle), so "cross-tenant" is currently "cross-store within one company" — an internal-controls issue, not a customer-data breach. Does it still deserve P0? **Yes**, for three business reasons: (a) any waiter can read **every store's full payment feed, refund reasons, and all staff attendance/payroll-adjacent data** — that is internal-fraud reconnaissance material in an industry where shrinkage is the #1 loss vector; (b) the moment an additional store is franchised or a partner brand onboards, this becomes a contractual/legal data exposure — and the stated plan is to open more stores; (c) the fix is one short migration using a pattern already proven in migration 299.
- **Operational impact:** internal information control. **Revenue impact:** indirect (fraud enablement). **Incident impact:** severe if discovered by a franchisee. **Difficulty:** S. **Effort:** ~half a day incl. dashboard verification. **Timeline: this week — and a hard blocker for opening any store not owned by the current operator.** Also: fix the uncommitted `20260609000000` migration **before it is ever applied** (today, 10 minutes).

### 2.2 Router role gap (`/cashier` etc. unguarded)
- **Original → Revised: P0 → P1** (downgraded)
- **Challenge:** the original P0 assumed separation-of-duties is load-bearing. In a small operation where the owner knows every staff member, a waiter deep-linking to `/cashier` on a shared tablet is misuse that's socially visible and store-scoped by RLS — not anonymous external attack. It cannot leak money by itself (payments still go through `process_payment` under the user's own identity, fully audited). **But** it stays P1 rather than P2 because POS internal fraud (voids/discounts/refund flows by non-cashiers) is a classic real-world loss pattern, the staff literally have the route list (it's in the xlsx), and the fix is small.
- **Difficulty:** S. **Effort:** half a day incl. a per-role routing test. **Timeline: this week** (bundle with 2.7 logout fix — same fraud-control theme).

### 2.3 Daily closing 07:00 window bug
- **Original → Revised: P1 → P0** (upgraded — this is the single most business-critical finding)
- **Challenge to the original rating:** the engineering audit filed this under "data consistency, P1." From an operator's chair it is worse than every security finding: **every daily close since the feature shipped has excluded sales between 00:00 and 07:00 HCMC.** For an F&B business with late-night service, the close figures used for cash reconciliation, staff accountability, and owner decision-making are systematically understated — silently, every single day, in production, right now. Settlement errors and revenue misstatement are exactly the categories the business ranks highest.
- **Operational impact:** daily cash-up vs system mismatch → staff suspected wrongly or shortages missed. **Revenue impact:** direct misreporting (and a latent VAT/tax-reporting landmine once e-invoicing activates). **Incident impact:** discovered-months-later accounting cleanup. **Difficulty:** S (two-line SQL fix) + M (historical audit/backfill decision). **Effort:** fix in hours; history audit ~1 day. **Timeline: TODAY** — fix the window; this week — quantify historical understatement and decide backfill vs documented cutover.

### 2.4 CRON_SECRET exposure
- **Original → Revised: P0 → P1** (downgraded one notch, not two)
- **Challenge:** the original P0 assumed the worst-case invoker. Reality: the repo is private; the secret's blast radius on the WeTax side is now test-only. **But** the same secret triggers `generate-settlement` and `generate_delivery_settlement` — real Deliberry settlement money — and the function URLs sit in the same file. A disgruntled ex-collaborator could force settlement runs. Rotation is cheap; history scrubbing is the expensive part and can wait (rotation makes history worthless).
- **Difficulty:** S (rotate + vault), M (history scrub — optional after rotation). **Effort:** ~half a day. **Timeline: this week.** Skip the git-history rewrite for now; rotating kills the leaked value.

### 2.5 Polling cost (2-second timers despite realtime)
- **Original → Revised: P0 → P0** (justified, reframed as money)
- **Challenge:** is "performance" really P0 for a business? Here, yes — this is not elegance, it is the **Supabase bill and the scale ceiling**. ~2.1M duplicate requests/day at 10 stores is the difference between staying on a cheap plan and paying for load that delivers zero value, and it is the first thing that will fall over when stores are added (the stated business goal). The fix is copying an 8-line guard that already exists in the same codebase. Highest ROI-per-line in the entire audit.
- **Operational impact:** stability under fleet growth. **Revenue impact:** direct cost line. **Difficulty:** S. **Effort:** ~2 hours + smoke test. **Timeline: this week** (it rides on app release cadence, not server-side).

### 2.6 VND formatter duplication
- **Original → Revised: P1 → P2** (downgraded)
- **Challenge:** the original P1 leaned on "user-visible drift." True, but the amounts themselves are always correct — only grouping separators and the suffix differ (`1.234.567 VND` vs `1,234,567 ₫`). No revenue, no payment, no settlement impact; customers are not confused about what they owe. It's a polish/brand-consistency issue, with one real caveat: the **printed receipt** uses its own hand-rolled formatter, and receipts are the customer-facing artifact. Fix the receipt path first, sweep the rest opportunistically.
- **Difficulty:** M (many call sites, mechanical). **Effort:** ~1 day. **Timeline: this month** (receipt path), gradually (the rest).

### 2.7 WeTax code duplication (`getToken` ×4 etc.)
- **Original → Revised: P0/P1 → P3, moved to the WeTax Activation Gate**
- **Challenge:** the duplication audit rated this P0 because encrypted-credential migration would silently break 3 of 4 functions. With WeTax test-only and the accounts scheduled for deletion, nothing breaks that matters. The drift is real and the `_shared/wetax.ts` extraction is correct — **as the first task of WeTax productionization**, not now. Zero operational urgency today.

### Other original P0/P1 findings — challenged one by one

| Finding | Orig | Revised | Justification under the real operating model |
|---|---|---|---|
| WeTax sample credentials in `docs/vendor/samples/` | P0 | **P3** | Test account, no real data, scheduled deletion. Redact during cleanup; confirmed no production creds anywhere in repo. Not justified as P0 anymore. |
| Account-info xlsx | P1 (audit) | **P0 (action changed)** | Verified contents (see header): working super-admin logins + live URL. The *file cleanup* can wait; **the passwords cannot** — disable or rotate `superadmin@globos.test`, `admin@globos.test`, `super@globos.vn`, `office.super@globos.vn` and the rest, or confirm they don't exist in prod auth. 30-minute task, do today. |
| wetax-onboarding cashier allowlist / no store scoping | P1 | **P3 → Activation Gate** | Tax-entity tampering only matters when tax entities are real. |
| commons_refresh dead cron (401 forever) | P1 | **P3 → Activation Gate** | Stale reference caches in a test pipeline. (Optional: unschedule the job to stop pointless minute-ly failures.) |
| Dispatcher no job claiming / poller poison batch / 409 null-sid / retry TOCTOU | P1–P2 | **P3 → Activation Gate** | Duplicate *test* invoices cost nothing. All four are mandatory before real issuance. |
| `einvoice_jobs` indexes | P1 | **P2** | NOT gated: the table grows with every real payment and the dispatcher scans it every minute in production today. One cheap migration — bundle with 2.1's migration. |
| Migration series interleaving / rebuild fragility | P1 | **P2** | Real risk only at disaster-recovery or new-environment time. No customer impact day-to-day. Do this month as calm hygiene work — but note: if you ever need it, you need it badly. |
| Reports: N+1 + unbounded `audit_logs` query | P1 | **P2** | Today's data volumes make this slow-but-working. Becomes P1 around month 3–6 of data. Fix this month, before history accumulates. |
| `main.dart` hub / DB-in-widgets / triplicated providers / giant inventory files | P1 | **P3** | Pure maintainability. Zero operational impact. Gradually, when each file is touched anyway. |
| TimeUtils vs `.toLocal()` drift | P1 | **P2** | Real only on devices not set to UTC+7. Mitigate operationally TODAY for free: make "device timezone = Asia/Ho_Chi_Minh" a store-setup checklist line. Code fix this month. |
| Daily-closing zero tests + no logging | P1 | **P1** | Justified — directly caused 2.3 to go unnoticed, and "no diagnostics" multiplies the cost of every future incident. Tests for the money path this week (alongside the 2.3 fix); logging wrapper this month. |
| Logout state bleed on shared terminals | P1 | **P1** | Justified — wrong-order payment from a stale cart is a real customer-facing failure at shift change. Small fix; this week with 2.2. |
| process_payment dropped amount-vs-items check | P2 | **P2** | Server trusts client totals — a tampered client could misstate revenue. Low likelihood (closed app), high consequence. This month, in the same migration batch. |
| Storage buckets cross-tenant (qc/attendance photos) | P2 | **P2** | Staff PII imagery, same franchise argument as 2.1 but lower sensitivity. This month. |
| Payroll PIN default-allow + unsalted | P2/P3 | **P2** | Payroll is wage data; default-ALLOW when unset is a real hole the day a store forgets setup. Fail-closed is a 2-line fix: this month. |
| Connectivity probe / QC web photos / kitchen rebuilds / ListViews / dead code / unused deps / lint ratchet / order model unification | P2–P3 | **P3** | Gradually during operations. None can cause an incident. |

---

## 3. Final categorization

### Must Fix Today
1. **Daily-close window fix** (`create_daily_closing` → true 00:00 HCMC) — every day of delay is another wrong close. (S)
2. **Disable/rotate the credentialed test accounts from the xlsx** (POS superadmin/admin + Office super) or confirm they don't exist in production auth. (30 min)
3. **Fix the uncommitted `20260609000000` migration** (add `security_invoker = true`) before it is ever applied. (10 min)

### Fix This Week
4. `security_invoker` migration for the 6 already-live views + dashboard verification (2.1).
5. Poll-timer realtime guard in 5 providers (2.5).
6. Rotate CRON_SECRET → Supabase secrets/Vault; update cron jobs. No history rewrite needed. (2.4)
7. Router role enforcement on all routes + logout provider invalidation (2.2 + state bleed) — the "shared terminal fraud-control" bundle.
8. Daily-close behavioral tests (locks in fix #1) + quantify historical close understatement, decide backfill with the business.

### Fix This Month
9. `einvoice_jobs (status, created_at)` + `(order_id)` indexes; re-add process_payment amount-vs-items check (one DB batch).
10. Report aggregation RPCs + date-bound `audit_logs` query (before data volume makes reports unusable).
11. TimeUtils standardization (+ add device-timezone line to store-setup checklist now, for free).
12. Receipt-path VND formatter; then the shared `formatVnd()` sweep.
13. Logging wrapper + instrument the meaningful silent catches; fail-closed payroll PIN.
14. Store-scope qc/attendance/po storage buckets.
15. Migration directory hygiene (segregate Office series, tombstone 210/211, verify gaps) — DR insurance.

### Fix Gradually During Operations
- Realtime reload debouncing; connectivity probe redesign; QC web photo compression; kitchen clock leaf widget; composite report indexes.
- Order model unification + shared select fragments (tests first); `main.dart` de-hubbing; DB-queries-out-of-widgets; giant inventory file splits; `widgets/`-layer layering.
- Dead-code PR (orphan files, unused deps, `ignore_for_file` removal); lint ratchet (`strict-casts`, `unawaited_futures`); `_startOfWeek`/`_RestaurantMissingView` consolidation; safe mechanical renames.

### Can Be Ignored For Now (revisit only at WeTax activation)
**WeTax Activation Gate checklist** — mandatory before the first real e-invoice, irrelevant until then:
- Extract `functions/_shared/wetax.ts` (getToken encryption-path drift) · dispatcher job claiming (SKIP LOCKED) · retry-RPC conditional updates · poller batch backoff + poison isolation · dispatcher 409/401/5xx caps · drop cashier from onboarding allowlist + store/brand scoping · fix commons_refresh cron auth (or unschedule it now to stop noise) · redact `docs/vendor/samples/` and delete test accounts (already planned) · einvoice state-machine transition guard.
- Also ignorable now: `'cancelled'` status CHECK mismatch; 10-year signed URLs; partial-unique open-order index; `v_brand_kpi` materialization; git-history scrubbing (moot once secrets/passwords rotate).

---

## 4. Executive summary — "If I can only fix 5 things before opening more stores"

**1. Fix the daily close (today, hours).** Your end-of-day numbers — the figures you reconcile cash against and judge stores by — have been silently excluding all sales between midnight and 7am since the feature shipped. Nothing else in this audit is actively corrupting business data every single day. Fix, then quantify how much history is understated.

**2. Kill the duplicate polling (this week, ~2 hours).** Five always-on screens hammer the database every 2 seconds for data they already receive via realtime — about 2.1M pointless requests a day at 10 stores. This is your Supabase bill and your scale ceiling. The corrected code already exists in the app; it just needs copying to five files. Highest ROI per line of anything here.

**3. Close the cross-store data window (this week, half a day).** Right now any logged-in waiter can read every store's payments, refunds, and attendance through seven database views. With one operator it's an internal-controls problem; the day you franchise or partner a store it becomes a breach of someone else's business data. One short migration using a pattern your own migration 299 already proved.

**4. Rotate every leaked credential in one sitting (this week, half a day).** Three leaks, one session: the super-admin test logins documented next to your live URL in the xlsx, the CRON_SECRET that can trigger real Deliberry settlement runs, and (low priority) the WeTax test account. Rotation makes the git history worthless — no expensive history rewrite needed.

**5. Lock the shared-terminal fraud surface (this week, one day).** Enforce the existing role matrix on all routes (today a waiter can deep-link into the cashier payment UI — and the route list is written in the xlsx every staffer can find), and reset app state on logout so the next user never inherits a stale cart. POS shrinkage is an operations problem before it is an engineering one; these two small fixes are your separation-of-duties story.

**Deliberately NOT in the top 5:** everything WeTax-internal (test-only, gated behind a pre-activation checklist), all structural refactoring (giant files, duplicated models, `main.dart` — maintainability, not operations), and the VND formatting (cosmetic; amounts are always correct). The original audit was right about *what* is wrong; operating reality changes *when* it matters.
