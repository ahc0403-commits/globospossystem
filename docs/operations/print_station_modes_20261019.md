# Print station printer modes — 2026-10-19

> Current owner policy (2026-10-27): automated verification runs in Codex Cloud or a suitable isolated cloud executor under root `CLAUDE.md`. Preserve complete final-SHA evidence, exact-main, official deployment and operational gates. Historical results below do not certify this candidate.

The Windows station now asks the operator to choose **Paperless** or **Printer output** before automatic printing. The choice is saved on this PC. Paperless exposes only cashier (`receipt` purpose) printers for setup, tests and automatic output. Printer output retains all configured destinations. Existing printer settings and queued jobs are preserved when switching.

This choice controls this PC's physical printers. It does not change the store fulfillment mode or transfer existing printed orders into KDS. Store KDS routing continues to use the existing fulfillment-mode controls and immutable order snapshots.

## Server prerequisite

Apply `20261019100000_print_station_receipt_only.sql` through `scripts/deploy_pos_production.sh --db-only --migration ...` with the exact-main local verification gates before using Paperless. The migration adds a cashier-only claim RPC, preserving the effective v3 payload/retry/hold rules and store authorization. It filters before LIMIT and row locking, including cashier request-update memos. It does not alter the old claim functions or update existing jobs. A zero-limit authorized call validates capability without claiming work. The new station refuses to start paperless polling if the server capability is missing; it never falls back to claiming kitchen jobs.

## Validation

- Focused Flutter coverage: coordinator first selection/persistence/switching; mocked HTTP receipt-only claim without fallback; actual driver cashier-only dispatch and blocked kitchen diagnostics; three-language station setup and phone layout; existing receipt/routing/network/configuration regressions.
- Disposable PostgreSQL fixture: 1,000 older kitchen jobs and 25 cashier jobs including a request-update memo. Two receipt claims return 10 then 15 jobs, preserving kitchen attempts/status and excluding held, future-retry, exhausted, inactive, incompatible-payload and cross-store destinations. Zero-limit readiness and unauthorized store access are checked; the additive migration is applied twice.
- Per polling batch: one claim RPC, one batched destination query and at most one batched endpoint query, with sequential per-job printing and acknowledgment. Default batch 10; server cap 50. Polling remains one subscription plus 15-second reconciliation. Fixture/mock counts verify one claim per batch and one destination batch; production response timing and physical Windows printing are not measured here.

## Installation

Close the old station and extract the whole Windows ZIP into a new folder. Run `globos_print_station.exe` with the included DLLs and `data/`. Select a mode. In Paperless, configure/test only the cashier printer; confirm a real cashier bill/receipt before enabling the station for service. Physical Windows printing remains a field verification step.
