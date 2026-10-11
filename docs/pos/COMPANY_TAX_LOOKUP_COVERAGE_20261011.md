# Company-name lookup coverage correction — 2026-10-11

The SAMPLE store was enabled, but `0318453298` still returned `unavailable`.
ESGOO returns HTTP 200 with `error: 1` and no company for that code. A successful
lookup of a different code did not establish coverage for the reported case.

[VietQR.io's documented business lookup](https://www.vietqr.io/business/:taxCode/)
returns `code: "00"`, matching `data.id`, and
`CÔNG TY TNHH AKJ INTERNATIONAL` for `0318453298`. This is reference company-name
data, not verification of current registration, taxpayer status, or an invoice.
VietQR's response can contain dated data. The POS forwards only the company name,
matching tax code, actual provider, and retrieval time; no address or status.

## Changed behavior

- Keep ESGOO as the primary source. If its response is missing, invalid, rejected,
  or timed out, try VietQR.io once. No retries, parallel fan-out, or scraping.
- One shared 5-second provider deadline: the primary gets at most 2.5 seconds,
  reserving time for fallback. Fallback gets only the remaining total budget.
- Fixed HTTPS hosts, reject redirects, max 64 KiB streamed response per provider,
  exact tax-code match (including branch suffix), strict success codes, nonempty
  name of at most 300 codepoints without control characters.
- At most two sequential upstream GETs per admitted lookup. Existing Auth check,
  one claim RPC, one release RPC, global two leases, caller quota, tenant boundaries,
  and disabled-store gate remain unchanged. This release needs no DB migration.
- The client accepts only `esgoo` and `vietqr` sources, displays the actual source,
  and retains the existing 5-minute/50-entry scoped cache and in-flight dedupe.
  Cache keys include the provider-policy version. No per-list-item lookups.
- Existing stale-result and manual-edit protection and explicit buyer-save behavior
  remain. No payment, invoice submission, or MISA dispatch is performed by lookup.
- Old native clients only accept ESGOO responses. Publish the corresponding new
  Windows package; installation and physical receipt checks remain store work.
  Web users need the new deployed app loaded to accept VietQR fallback results.

## Verification before production release

- Nine Deno handler tests passed: reported-code fallback and provenance, strict
  secondary-provider validation, shared deadline, bounded requests, Auth/ACL/quota
  gating, lease release, and existing ESGOO success without extra calls.
- Twenty-one focused Flutter tests passed, including AKJ auto-fill with VietQR.io
  source label, manual fields preserved, cache sharing, and late-result protection.
- Actual low-volume provider smoke through the changed server function:
  `0318453298`: success via VietQR, 2 GETs, 762 upstream bytes, 814 ms;
  `0316956049`: success via ESGOO, 1 GET, 581 bytes, 40 ms;
  `0316794479-001`: success via ESGOO, 1 GET, 398 bytes, 58 ms.
  These samples measure this path, not p95, total registry coverage, or availability.

Production release and actual SAMPLE form verification are separate evidence and
must be recorded after the exact-main CI gate and official deployment complete.
