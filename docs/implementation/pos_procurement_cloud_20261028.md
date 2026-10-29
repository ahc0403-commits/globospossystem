# 2026-10-28 POS procurement cloud work

Status: implementation and focused validation; final candidate, fresh exact-main
release and operational acceptance are separate pending stages. This document
does not establish an operational fix.

## Source and attachments

The preserved adjustment commit is `2f575b8b2295448a86cd2d4ac09cd3e5113401a4`,
tree `361c785d8a55c1951848564ad926aa90ff1cb532`. It adds registered items during
the existing manager adjustment command, preserves actor/version/idempotency
boundaries and changes the button to 조정 / Adjust / Điều chỉnh.

The two-slide attachment `261027-POS-improvements.pptx` was downloaded through
Library, hashed and read; SHA256 is
`01cf4d3b6f10a04c970ab1c3683aa6acf6a99bea1d00cd1b1327d227e15b17a4`.
All four supplied PNGs were inspected as pixels and matched the embedded images.
The additional PR PDF changes use stable store IDs for the supplied uppercase
titles and addresses. The requesting-department label is localized. The actual
selected department spelling is preserved, including Bếp Bunsik versus
Bếp BunsikClub. With no department field the registered actor display value is
preserved; no production business/account name is renamed.

The cloud transport is documented in [Cloud release execution](../pos/CLOUD_DEPLOYMENT.md).
It preserves the official entrypoint, fresh full recipe, pinned targets, actual
Auth and login checks, migration source/version/hash/transaction/history checks,
and explicit unsupported Edge scope refusal. A Supabase CLI keyring problem is
not a failure of the separately connected Supabase MCP and does not block
isolated development.

## POS–Office investigation resumed

The owner resumed Office coordination on 2026-10-28. No Office implementation or
deployment is performed from this POS checkout. Existing Office work
`01a1818e-8c0d-774c-a0ac-6676cc3d90bf` owns its existing changes and separate
release conditions. Its handoff files were not present in the inspected remote
branch, so unpublished local work cannot be inferred from that branch.

Read-only source comparison found Office main
`de1b4d8421e14e1fa14824a5b6ac4afc8af151b3` and follow-up branch
`cafa58cb476d2a579d5258e8f9980b36d86ddde9` share the relevant implementations:

- `PurchasePage` recognizes actual V2 purchase approval authority, defaults to
  store PR approvals, and retains a separate Office-document selection.
- `procurementApprovalPageProvider` binds user/grants/legal entity/brand/store,
  reads `procurement_approval_inbox` and refreshes after 30 seconds.
- `pos-bridge` resolves Office grants and mapped POS store scopes, constructs
  the actual Office actor and calls `procurement_approval_inbox_batch` in batches
  of at most 100 scopes, at most two batches concurrently.
- The POS RPC retains policy-3 `office_review` requests. Readiness annotates
  actionable/blocked rows; `approval_ready=false` is not a list-exclusion rule.

These facts do not prove the affected buyer sees
`PR-20261026-E15A090B8F`. The historical three reported PRs and prior deployment
reply are provenance, not current actual-account acceptance evidence. Admin/SQL
success must not replace actual buyer login, exact endpoint/scope/filter/cache
trace and list/detail visibility in the live app.

Office PR #194, merge `ebe221ad1214bc41fc51692cf54390e904f5fd67`, concerns Photo
multi-store/attendance recovery; it is not reimplemented here. Read-only Vercel
inspection found production deployment `dpl_E6fAy2mwXbohCEQcmiL2uzTWJ86F` READY,
but its returned Git SHA metadata was null. Its source identity and the actual
buyer visibility remain unverified. No root cause is inferred from READY alone.

Necessary next Office evidence is the existing task's current unpublished SHA
and handoff, the verified production release/source identity, and a real buyer
session exercising the target PR and scoped inbox. If that trace requires a
code change, coordinate only the specific route/provider/bridge contract with
the existing Office task and validate it there using its fixed recipe and
`scripts/run_office.sh deploy-web` release boundary. Do not mix unrelated
follow-up changes into this pilot or create production test orders.
