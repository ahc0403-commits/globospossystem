# Owner-controlled sales reporting

Completed revenue receipts must remain downloadable regardless of payment time.
The legacy 22:20 scheduler classified receipts after 21:45 as integrity failures;
the grouped automation export and paginated POS export then blocked all sales
for the day. This was not an owner-approved reporting policy.

`20261021230000_owner_sales_reporting.sql` removes that legacy status gate from
the two active report paths, disables only the automatic Restaurant sales
finalization job, and retires its application-role execution permissions.
Downloadable reports return `ready`; they do not assert owner confirmation.
Historical finalization rows remain unchanged as audit evidence.

This DB-only fix preserves actual receipt aggregation, VAT, approved mappings,
issued snapshots, sample/non-revenue exclusions, date and authorization guards,
100-row cursors, source revision checks, and the all-store summary functions.
Ordering, payment processing, cash closing, and other store-opening work are
outside this change. No new report query or per-store request is introduced.

The existing corporate export SQL suite reproduces the blocking failure,
applies the real migration twice, and verifies identical financial payloads
including a 23:32 receipt, unchanged history and source definitions, scheduler
scope, authorization and future-date guards. Production deployment and actual
download verification are recorded separately in local release evidence.
