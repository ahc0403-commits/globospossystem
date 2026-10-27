# Payment QR and deposit production integration

> Current owner policy (2026-10-27): automated verification runs in Codex Cloud or a suitable isolated cloud executor under root `CLAUDE.md`. Preserve complete final-SHA evidence, exact-main, official deployment and operational gates. Historical results below do not certify this candidate.

The owner authorized production release on 2026-10-13. This branch starts from
exact main `e831ba7d1ec3cf5c3af49963751a77261a3f49f8` in a newly created clean
worktree. The original working directory remains untouched.

Receipt QR rendering uses the queued legal entity beneficiary instead of a
personal account image. Receipt profile enrichment joins the store's legal
entity collection account in its existing query and derives seller name/TIN
from that same entity. Existing queued bank snapshots and historical jobs remain
unchanged. Direct-order packing headers, driver payment-mode handling and
`claim_print_jobs_v3` predecessor compatibility remain intact.

The sales and closing screens distinguish customer bank transfers from Photo
and manually counted Bunsik cash for D+1 deposits. Bank detail pages are bounded
to 100 records with stable keysets and store authorization. Routine summaries
defer export fingerprints, share in-flight requests per session/day, use a
30-second cache and stop refreshing hidden screens. Export still loads and
validates complete revision metadata before creating XLSX.

The new deposit migration accepts both reviewed predecessor shapes: original
summary or the already deployed delivery-fee exclusion. It moves item counts
into the shared tax aggregate without removing the fee exclusion. The two
corporate SQL modes rehearse both migration orders and repeat the new migration.
Previously applied migrations and approved mapping rows are not edited.

`--web-only` retains exact-main local verification, Auth, analysis, tests, build and login gates;
it rejects skip options, migrations and rollback. The default deployment flow
including Edge, translation schedule secrets and existing metadata checks is
unchanged. The wrapper runs the two DB-only gates followed by web/mobile web.
Android configuration already matches main; native Android/iOS installation is
outside this release. Windows printing uses the exact main SHA workflow package.

Production verification must compare the fixed 2026-10-12 ledger before/after,
check both summary overloads and closing/bank detail RPCs, validate perpetual
invoice mappings and the fee-free XLSX, and record deployment provenance.
No MISA issuance, transmission or external reporting is authorized by this task.
Windows station installation and physical printing require access to the actual
station; a successful Windows build alone is not evidence of installation.
