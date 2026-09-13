# C1 — Integration and release handoff

Development validation covers POS PR/revision/approval/PO/receiving and Office scope/line-matching/proposal contracts in disposable databases and local Flutter/Deno tests. New contract CI jobs are included. No production migration, deployment, supplier message, purchase or payment was executed.

Apply additive POS migrations in filename order, then Office migrations. Deploy the Office bridge, then Office/POS clients through each established release script. Check required CI on the exact pushed head. Enable one mapped BUNSIK CLUB store only after staging checks and business configuration of amount/price/quantity thresholds, inventory freshness, suppliers/units, cold-chain practices and replenishment policies. The scheduled proposal environment flag and item policies default off.

Before enabling: exercise real scoped Office/POS users, missing migration UI, purchase request edits and cross-store rejection, comparison quotes and separate senior approval, multi-supplier issuance, supplier-confirmed terms, partial/excess/failed QC with photo and expiry/temperature evidence, signed URL access, invoice line matching and evidence/Finance gates, physical returns/credit adjustments, interrupted proposal confirmation/retry, and a stale-stock schedule. Validate existing live workflow regressions in the full deployed schema; local fixtures alone are not an operational PASS.

Legacy orders retain their original workflow. Missing historical conversion/VAT can be supplemented only by an authorized senior reviewer using source-document evidence; existing known commercial terms and confirmed receipts are not rewritten. Unreceived v2 POs can be cancelled and replaced by a fresh draft requiring approvals. Received orders use Finance's credit/adjustment path.

The original project contains pre-existing uncommitted work. Only the procurement diff from the isolated baseline is eligible for application; do not publish or merge the captured baseline as an unrelated release.

Accounting uses a refreshed, versioned POS snapshot with a ten-minute freshness limit. The two independent databases do not provide a distributed payment lock. A return after invoice approval must follow the existing Finance credit/adjustment workflow; this feature does not rewrite approved invoices or execute payments. First-purchase items require comparison quotes even when a supplier master price already exists.
