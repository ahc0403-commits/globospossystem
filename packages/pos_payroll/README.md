# POS payroll calculation

The existing `PayrollService` models and calculation methods were moved here
without changing the arithmetic, pairing, time conversion, defaults or rounding.
`PayrollDataSource` is the read boundary. POS `AttendanceService` implements it;
POS keeps Excel export and cache writes in its original service.

Office vendors this package as an immutable source artifact, since the apps are
separate repositories. Update rules here and run the POS payroll tests first.
Then import this package into Office with its `scripts/sync_pos_payroll.py`.
Office's normal build/test wrapper verifies the pinned source hashes. The sync
check with `--source` additionally verifies byte-for-byte equality across apps.
There is no Office-specific arithmetic implementation.
