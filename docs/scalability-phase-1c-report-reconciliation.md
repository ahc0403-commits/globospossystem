# Scalability plan — phase 1C: reconcile report sales

This client-only change closes the two specific report discrepancies recorded in
[phase 1B](scalability-phase-1b-financial-inputs.md). It starts from
`71e10b6abd091ce2b495f2b45537c63cd3593af4` (draft PR #451) in an isolated worktree.
The original workspace's uncommitted files are preserved.

## Confirmed issues and authority

**HIGH — POS delivery omitted from headline sales.**
`ReportNotifier.loadReport` added POS delivery payments to daily/hourly details,
but initialized the headline delivery accumulator only before reading external
delivery sales. Thus a POS-only delivery period displayed zero headline revenue.
The direct delivery approval implementation actually creates `orders` with
`sales_channel = 'delivery'` and settles through `process_payment`; this is an
implemented path, not a hypothetical input. It does not mirror those payments
into `external_sales`.

**HIGH — global revenue used received money instead of allocated sales.**
`SuperAdminNotifier.loadAllReports` summed `payments.amount`. Store reports used
`amount_portion`, falling back to `amount` only for legacy null allocations.
The global screen labels the value Total Revenue / 총매출. The existing guarded
correction script `scripts/data_corrections/20260808_binh_thanh_payment_report.sql`
and `test/report_payment_aggregation_test.dart` explicitly distinguish received
money from the preserved order sales allocation. Aligning revenue therefore
follows the implemented payment contract, without changing receipt/settlement
amounts or historical payment records.

## Change and reproduction

The store report now includes POS delivery in its headline delivery total as well
as its daily details. Existing external delivery amounts remain additive.
Both providers use `revenuePaymentSalesAmount` for revenue. The former private
helper is shared without changing its logic: a null allocation falls back to
received amount; an explicit zero stays zero. Cash/card/bank/payment totals and
payment variance retain their received-money basis.

The real PostgreSQL/PostgREST test suite failed at exactly these assertions before
the implementation change and passed afterward:

| Synthetic fixture | Before | Expected / after |
| --- | ---: | ---: |
| 501 POS delivery sales of 100 each: headline delivery | 0 | 50,100 |
| 501 allocated sales plus external/Photo inputs and a second store: global total | 84,233 | 79,223 |
| Mixed POS and external delivery: headline delivery | 30 | 305 |

These are fixture units, not measured production amounts or infrastructure costs.
The mixed fixture independently expects total sales 523, received payments 485,
payment variance 40 and separate service total 11. Store/global totals and the
decoded Excel summary/totals agree. It covers dine-in, takeaway, POS delivery,
external delivery, Photo Objet, split payments, null and zero allocations,
legacy payments without an order, and excluded non-revenue/pending inputs.
Hourly totals still exclude Photo Objet's daily-only data, as before.

## Validation and release state

- Implemented in source: yes; only the two report providers change behavior.
- Targeted real SQL/API tests: 29 passed with the 100-row PostgREST cap.
- Full repository checks: `bash scripts/check_repo.sh` passed: static analysis,
  1,279 Flutter tests, 19 payroll and 29 financial-input SQL/API tests, 22 Deno
  tests, 60 Node tests, dependency audit/secret scan, deployment/SQL shell
  fixtures and the release web build. The ordinary Flutter run reported 50 skips,
  including the two SQL/API groups subsequently executed by the harnesses.
  Existing optional Wasm dry-run and Cupertino font warnings remain; the standard
  web release build succeeded.
- GitHub checks: must pass on the exact pushed head; consult the stacked PR.
- New database migration: none. Phase 1A/1B migrations remain prerequisites for
  their inherited client code; this change does not apply them.
- Production deployed / operationally verified: no / no.

The existing report-only frozen hash is renewed alongside the behavior tests.
Other frozen QR, cashier, payment, KDS, print and SQL domain hashes remain intact.
The payment anchor, both settlement functions, MISA flow, Office coupling and
daily closing schedules are unchanged.

## Rollout and remaining work

After review and exact-head checks, any authorized rollout must use the production
release wrapper and satisfy the earlier phases' database prerequisites. Reconcile
a closed period containing POS delivery and an allocation/receipt difference
against the underlying complete ledger. Compare store/global totals and Excel;
verify cash settlement and service totals remain unchanged. A client rollback
reintroduces these report discrepancies but does not modify business data.

This adds no API/DB requests, polling, subscriptions or new data projections.
It does not resolve the prior full-input memory/read cost, per-store/per-employee
queries, transaction-snapshot limitations, or every other report/export's
accounting semantics. Capacity and savings remain measurement required.

The next implementation step is phase 2: remove promotion writes from the read
path, and verify that unchanged refreshes produce no database mutation or realtime
feedback. KDS/polling, server aggregation/batching, realtime consolidation,
measured indexes and fleet load tests follow as planned.
