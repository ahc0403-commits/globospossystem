# meInvoice Integration Plan v2 — MISA Developer Portal (OpenAPI)

Date: 2026-07-11
Source: https://developer.misa.vn/products-openapi/MEINVOICE (read in full,
including Authentication, "Lưu ý khi bắt đầu", publish use case, and the
/invoice/token, /invoice/templates, /invoice/publishing references).
Supersedes the "AppID blocked, contact MISA support" conclusion in
`MEINVOICE_IMPLEMENTATION_HANDOFF_2026_06_30.md`.

## 1. What changed: the blocker is now a portal signup, not a support ticket

The old integration path (doc.meinvoice.vn/itg, `api.meinvoice.vn/api/integration`,
`appid` in the token body) is what our deployed `meinvoice-dispatcher` v1
implements. MISA's current documented path is the **Developer Portal OpenAPI**:

| | Old (built) | New (portal) |
|---|---|---|
| Credential | `appid` (MISA support issues) | **ClientID + ClientSecret** (portal issues) |
| Registration | Contact MISA support/hotline | Self-service: MISA ID login → create app → send integration request → receive ClientID/Secret |
| Base URL | `https://api.meinvoice.vn/api/integration` | `https://developer.misa.vn/apis/itg/meinvoice/` |
| Token | POST `{base}/auth/token`, body `{appid, taxcode, username, password}` | POST `{base}/invoice/token`, headers `ClientID`+`ClientSecret`, body `{taxcode, username, password}` |
| Business calls | `Authorization: Bearer` only | `Authorization: Bearer` **+ `ClientID` header** |
| Publish | POST `{base}/invoice` | POST `{base}/invoice/publishing` |
| Templates | GET `{base}/invoice/templates?...` | identical (same params) |
| Status/Download | POST `{base}/invoice/status`, `/invoice/Download` | identical names |
| Payload | `{SignType: 5, InvoiceData: [...]}` | **identical shape** (field-for-field match with our builder) |

Verified against our deployed source (`_shared/meinvoice.ts`): the
InvoiceData spec on the portal matches our payload builder — RefID (guid,
dedup key), InvSeries, InvDate `yyyy-MM-dd`, PaymentMethodName, Buyer*,
Total* (all required ones present), OriginalInvoiceDetail
(ItemType/SortOrder/LineNumber/VATRateName...), TaxRateInfo,
OptionUserDefined. **No payload rewrite is needed** — only auth + URLs.

## 2. New operational rules learned from the portal docs

- **SignType**: 5 = MTT (cash-register) invoice, sign-after, no visible CKS —
  our case; 2 = HSM; 1 = USB token (NOT supported by `/invoice/publishing`;
  error `APINotSupportTypeInvoice`).
- **Series semantics** (`1C25MYY`): char1 `1`=GTGT, char2 `C`=with CQT code,
  char5 `M`=cash-register invoice. Year segment auto-rolls by `InvDate`
  (MISA handles 1C24→1C25).
- **Sequential dispatch is mandatory per invoice series**: send → response →
  persist → next. No parallel publishing within one series.
- **Retryable vendor errors**: `InvoiceNumberNotCotinuous` (number being
  allocated to a concurrent request — retry with backoff),
  `InvoiceDuplicated` (RefID or number already used — for our stable
  RefID=job.id this can mean "already issued": query status, don't blind-fail).
- Limits: ≤30 invoices/request, ≤400 lines/invoice, RefID unique.
- Token valid 14 days; reuse (our token cache already does this).
- Templates call returns `InvSeries`/`InvTemplateNo`/`Inactive` — must
  validate series before publish (`TemplateNotExist` otherwise).
- `/invoice/unpublishview` = server-side preview of the exact payload
  (link lives 5 min) — a true vendor-side dry-run **before** any issuance.
- Rounding: round per line, then sum (MISA recommendation); decimal digit
  counts must match `OptionUserDefined`.

## 3. Phase plan

### Phase 0 — Portal registration (Hyochang, no code)

1. Verify the credential owner's legal name and tax code against the POS
   `tax_entity` record, then log in at developer.misa.vn with that entity's
   **MISA ID**. Never infer the entity from a brand or a previously used tax
   code.
2. Create an app (name: `GLOBOS POS`, contact info), send integration
   request selecting **meInvoice**.
3. Capture **ClientID** (non-secret config) and **ClientSecret** (secret).
4. In the request/chat with MISA, ask two things only:
   a) Is there a sandbox/test tenant for the portal API path, or is
      first-issuance validation done via `unpublishview` + a controlled
      live invoice?
   b) Confirm the MTT invoice series for the tenant (5th char `M`) is
      registered and active (visible in `GET /invoice/templates`).

### Phase 1 — Adapter migration (code; small, no payload changes)

`supabase/functions/_shared/meinvoice.ts`:

1. New defaults:
   `MEINVOICE_DEFAULT_AUTH_BASE_URL = https://developer.misa.vn/apis/itg/meinvoice/invoice`
   `MEINVOICE_DEFAULT_API_BASE_URL  = https://developer.misa.vn/apis/itg/meinvoice/invoice`
   (per-entity overrides via `meinvoice_tax_entity_config.auth_base_url /
   api_base_url` already exist — keep).
2. `getMeInvoiceToken`: POST `${authBaseUrl}/token` with headers
   `ClientID` / `ClientSecret`; body `{taxcode, username, password}` (drop
   `appid` from body).
3. All business calls add the `ClientID` header
   (publish/templates/status/Download).
4. `publishCashRegisterInvoice`: POST `${apiBaseUrl}/publishing` (was
   posting to the base URL itself).
5. Error-class upgrade in the dispatcher:
   - `InvoiceNumberNotCotinuous` → transient: release claim, keep
     `pending` (retry next run with backoff via `dispatch_attempts`).
   - `InvoiceDuplicated` → call `getCashRegisterInvoiceStatus` by RefID;
     if found issued → `markSuccess` from status data; else `failed`.
   - Everything else unchanged (`dispatch_paused` for config, `failed` for
     vendor rejects).
6. Credential naming: ClientID lives in
   `meinvoice_tax_entity_config.app_id` (semantic renamed — see Phase 2).
   **Per-legal-entity secrets are mandatory** — each tax entity uses
   `MISA_MEINVOICE_USERNAME_<TAX_CODE>`, `MISA_MEINVOICE_PASSWORD_<TAX_CODE>`,
   `MISA_MEINVOICE_CLIENT_SECRET_<TAX_CODE>`. The unsuffixed shared fallback
   only works while `MISA_MEINVOICE_ALLOW_SHARED_SECRETS=true` is set
   explicitly (single-entity transition window; remove once a second
   entity onboards).

Payload hardening (two real risks found while re-reading our builder
against the stricter portal validation):

7. **VND integer rounding**: `roundMoney` rounds to 2dp but
   `OptionUserDefined` declares 0 decimal digits for amounts. For VND,
   round all amount fields to 0dp so declared digits match data.
8. **`AmountOC == Quantity × UnitPrice` consistency**: builder currently
   derives `UnitPrice = AmountWithoutVAT / Quantity` (rounded), which can
   break the product identity for quantity > 1. Use the snapshot's ex-tax
   `unit_price` and derive amounts per MISA rule (round per line, then
   sum), keeping `TaxRateInfo` equal to the line sums.

### Phase 2 — DB/config + repo hygiene

1. Commit the dispatcher source to the repo:
   `supabase/functions/meinvoice-dispatcher/` and
   `supabase/functions/_shared/meinvoice.ts` currently exist **only as the
   deployed artifact** (deployed from a /tmp path; not in git).
2. Migration: comment/relabel `meinvoice_tax_entity_config.app_id` as
   "MISA Developer Portal ClientID" (no physical rename needed), and update
   the admin e-invoice readiness UI label AppID → ClientID.
3. Resolve the verified tax code to exactly one `tax_entity.id`, confirm that
   every target store's `tax_entity_id` points to it, and insert the config row
   by that verified ID: ClientID, `invoice_series` (from templates call), portal
   base URLs, `integration_status = 'configured'`. Do not hardcode or bind a
   credential to an entity based on brand membership.
4. Set all three entity-specific secrets using the normalized tax-code suffix:
   `MISA_MEINVOICE_CLIENT_SECRET_<TAX_CODE>`,
   `MISA_MEINVOICE_USERNAME_<TAX_CODE>`, and
   `MISA_MEINVOICE_PASSWORD_<TAX_CODE>`. Unsuffixed secrets are forbidden for
   normal operation; the explicit shared-secret flag is a temporary,
   single-entity migration escape hatch only.
5. **Fix deployment flag**: `meinvoice-dispatcher` is deployed with
   `verify_jwt: true` — the platform will 401 the CRON_SECRET bearer before
   our handler runs (wetax-dispatcher correctly uses `verify_jwt: false`).
   Redeploy with `--no-verify-jwt`.

### Phase 3 — Staged live verification (in order; each step gates the next)

1. **Token smoke**: POST /invoice/token with ClientID/Secret → JWT.
   (Read-only, no invoice side effects.)
2. **Templates smoke**: GET /invoice/templates → confirm the MTT series
   (5th char `M`) exists, active, `InvTemplateNo` captured → write
   `invoice_series` into config.
3. **unpublishview preview**: send one real pending job's payload → human
   checks the rendered invoice preview (5-min link). This replaces the old
   "payload dry-run only" ceiling — vendor-side validation with zero
   issuance.
4. **Controlled first issuance**: one real completed order, dispatcher
   `dry_run:false`, `limit:1`, `tax_entity_id` pinned. Verify
   `publishInvoiceResult`: ErrorCode null, persist TransactionID / InvNo /
   InvCode (CQT code). Check on app3.meinvoice.vn (Báo cáo → Bảng kê hóa
   đơn đã sử dụng) and status API `SendTaxStatus = 2` (accepted).
5. `integration_status = 'active'`, `meinvoice_dispatch_enabled = true`,
   schedule pg_cron (none exists today), monitor first business day.

### Phase 4 — Backlog ties (unchanged)

- Photo Objet jobs flow through the same queue/adapter — no extra work
  beyond series/config for its entity when it gets a real tax entity
  (currently on `PLACEHOLDER_DEV_000`, skipped by trigger).
- Viettel/AKJ plan is unaffected: provider-neutral queue work proceeds
  separately; this phase completes the **meinvoice provider adapter**,
  which stays the provider for the separately verified legal entity.

## 6. Production SQL application contract

Apply `20260711190000_meinvoice_portal_defaults.sql` only through the pinned
POS production deploy script. The script obtains the linked project's
temporary credentials, verifies the project-bound login and activated
`postgres` role before mutation, and executes the file with fail-fast,
single-transaction semantics:

```bash
scripts/deploy_pos_production.sh \
  --migration supabase/migrations/20260711190000_meinvoice_portal_defaults.sql \
  --skip-vercel --yes
```

The underlying invariant is:

```bash
psql -X --no-psqlrc -v ON_ERROR_STOP=1 --single-transaction --file "$SQL_FILE"
```

Never use `supabase db query` to apply this or any other multi-statement
production migration. Run read-only preflight before mutation and record the
successful verify result only after `psql` exits with status 0.

## 4. Constraints re-affirmed

- Payment completion never depends on MISA (trigger catch-all + async queue).
- ClientSecret/username/password: Edge Function env only; never in DB or
  admin UI. ClientID is non-secret config (it is sent as a plain header).
- WeTax remains closed; legacy `einvoice_jobs` untouched.
- `meinvoice_jobs.ref_id` semantics: RefID = job id (uuid) remains the
  vendor-side dedup key; never regenerate on retry.

## 5. Effort estimate

- Phase 1 code: ~1 session (adapter deltas + 2 payload hardening items +
  dispatcher error classes, with unit tests on the builder).
- Phase 2: 1 migration + config row + redeploy.
- Phase 3: blocked only on Phase 0 credentials; steps 1–3 are zero-risk.
