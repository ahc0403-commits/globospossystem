# Attendance Payroll Second Slice — 2026-05-12

## Verdict

The attendance payroll first slice is sufficient to expose a tracked, read-only
preview and export surface. A second slice is allowed only if it stays focused
on operator confidence and access control, not payroll workflow expansion.

## Current shipped baseline

The tracked first slice already provides:

- attendance log query by date range
- read-only payroll preview for the selected period
- payroll export to Excel

It does **not** yet provide:

- payroll PIN-gated reveal flow
- per-staff daily breakdown expansion in the attendance UI
- payroll approval or payroll mutation
- payroll closeout workflow
- device or kiosk extensions

## Second-slice question

If attendance operators need one more tracked improvement, the narrow question
for the second slice is:

> How can the payroll preview become safer to open and easier to inspect
> without turning Attendance into a payroll management workflow?

## Allowed scope

The second slice may include only the following:

1. A payroll PIN gate before revealing the preview/export surface, reusing the
   existing tracked payroll PIN settings contract.
2. A compact per-staff detail expansion under the preview rows so operators can
   inspect daily record counts, paired/unpaired shifts, and amount drivers.
3. Small read-only copy improvements that clarify estimate status and boundary.

## Explicitly out of scope

The second slice must continue to exclude:

- payroll edits
- wage configuration editing
- payroll approval / settlement workflow
- background payroll caching orchestration changes
- attendance device extensions
- new SQL migrations
- new RPCs
- standalone payroll screen or route

## Data contract boundary

The second slice should continue using existing tracked services only:

- `attendanceService.fetchLogs(...)`
- `attendanceService.fetchWageConfig(...)`
- `payrollService.calculatePayroll(...)`
- `payrollService.exportToExcel(...)`
- existing payroll PIN settings surface in `settings_tab.dart`

No new database contract is required for the second slice.

## UX boundary

Attendance remains the shell.

- logs stay primary
- payroll preview remains a secondary read-only surface
- the operator should never lose the attendance query context
- the screen should not become a payroll dashboard

## Recommended implementation order

1. Add optional payroll PIN reveal gate.
2. Add compact breakdown detail beneath each payroll row.
3. Add small contract coverage for the new read-only boundary.

## Stop conditions

Stop and redesign instead of extending this slice if:

- the team asks for payroll correction or approval actions
- payroll requires a new route or separate workspace
- SQL or RPC changes become necessary
- attendance operators need payroll as the primary workflow rather than a
  secondary estimate

## Decision

Proceed only with a read-only second slice.

If the product needs payroll workflow ownership instead of payroll preview
inspection, that should become a separate future feature rather than an
extension of Attendance.
