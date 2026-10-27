# Full menu invoice mapping implementation

> Current owner policy (2026-10-27): automated verification runs in Codex Cloud or a suitable isolated cloud executor under root `CLAUDE.md`. Preserve complete final-SHA evidence, exact-main, official deployment and operational gates. Historical results below do not certify this candidate.

The catalog reads menu masters, including hidden, archived and never-sold menus,
instead of deriving approval candidates from recent sales. Each keyset page and
approval RPC accepts at most 100 rows. The client reads pages and writes batches
sequentially; it validates every JSON import scope before its first write and
skips already mapped rows when resuming policy application.

Super Admin approves a store/legal-entity policy with explicit category units,
combo units and evidence. The server records the authenticated approver, actual
time and real policy ID. Statement triggers map create, copy, import, name/unit
changes and reactivation through the same set-based approval writer. Missing
Vietnamese names or actual unit rules roll back menu registration. An optional
actual sales unit can be entered for a new category or an individual item.
Existing individually approved units survive repeated name edits. Display fields
are synchronized from the genuine profile; repairing them creates no approval.

Manual approval continues through `approve_invoice_mapping_batch`. Automatic
profiles reference their real approved policy and separately record the actor
who registered/applied the menu. Indexed period exclusion constraints reject
overlap and treat a NULL end as indefinite. No applied historical migration is
edited, and approval IDs or identities are never supplied by the client.

Both deployed additive Excel import and repository replacement import histories
are supported. Actual Vietnamese names/optional invoice units are staged once;
round-trip localization and beverage tax updates use set-based relations while
retaining the outer archive/photo contract. Old workbooks can omit the new
optional unit column; new imported items require an actual Vietnamese name.

Missing snapshot mapping appears in the async invoice queue. This trigger makes
no MISA request and does not block payment. Revalidation uses the existing RPC
only for eligible unissued receipts. Issued, sent, attempted, claimed and external
reporting protections remain authoritative. The owner-provided correction
declaration protects 2026-10-13 conservatively, without claiming provider-issued
status or hashing an unavailable Excel file. Its known correction scope is five
receipts; the whole business day is protected from reprocessing.

Validation reports every affected line, unique menu and receipt, with the
within-receipt position displayed separately. The existing common MISA workbook
writer already has the required row-8 A:Q contract, repeated A sequence,
physically empty B:J continuation cells, discounted supply/quantity unit price,
audit sheets and contact preservation. Its contract tests remain release checks.
TM/CK, ledger amounts/quantities, beverage/combo VAT, Photo 8% manual upload and
`Dịch vụ chụp ảnh / Lần` are unchanged. No delivery fee or Photo collection is
introduced, and external MISA acceptance testing remains excluded.

Verification includes authenticated-role SQL fixtures, 205 never-sold menus
mapped in exactly three policy batches, genuine first-sale profile resolution
and eight required fields, indefinite periods, scope failures, duplicate retries,
display repair, repeated individual-unit edits, 150-row import/round-trip paths,
aggregate error reporting and all new dialog entrypoints. Synthetic identities
exist only in the disposable test database. Production data application,
deployment SHA and actual sales/performance results must be recorded separately
after the exact-head local verification gate and official deployment script succeed.
