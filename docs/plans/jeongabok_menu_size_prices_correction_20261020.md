# JeonGabok: one menu with S/L prices

The owner corrected the previous interpretation: operators register one dish
with S and L prices; customers tap the dish and then select S or L. Separate
S/L catalog registrations were wrong. This supersedes the prior separate-menu
interpretation. Only JeonGabok data is converted.

## Implementation

- One parent menu owns `size_prices`. Menu registration/editing saves both prices
  in one transaction. Admin, POS, QR and direct-order catalogs display one dish.
- Preserve the 47 existing sellable IDs as internal price projections so past
  orders, immutable option snapshots, recipes, invoice mappings and accounting
  remain linked. Seven L projections become children of their S parent. Operators
  do not register or edit those projections as separate catalog menus.
- The resulting JeonGabok catalog has 40 dishes in six categories, including
  seven dishes with two prices. Combos remain excluded. Original prices, names,
  spiciness and VAT classifications are preserved, including Coke/Sting at 10%.
- One shared size picker shows registered prices. Selected sizes retain distinct
  cart lines and existing order-time names. Old/offline prices require reselection.
- Excel exports one row per dish with S/L price columns; new imports expand price
  projections in one bounded bulk operation. Existing grouped-menu workbooks can
  update both prices; adding sizes to an existing single-size dish uses its editor.
- Old client/API payloads remain compatible. Size metadata travels in the existing
  opaque option key, so no extra public endpoint/Edge release is required.

## Isolation and scale

Catalog loading still uses its existing bounded menu/active-order reads. Opening
or changing a size adds no API call. Client grouping is one linear pass over the
already fetched catalog. Parent price/name/visibility changes synchronize their
children with one statement-level UPDATE JOIN over the changed batch. Import
uses one bulk RPC; it never performs a remote lookup per menu. One menu save has
at most two fixed S/L price projections; it does not scale with catalog size.

Only explicit JeonGabok size groups use the new selection flow. Other stores'
rows remain ungrouped, with unchanged option keys and existing menu behavior.
The production data correction locks only JeonGabok's registered rows, checks
all seven exact ID/price pairs, verifies source fields and other-store hashes,
and records an audit entry. It never rewrites order history or rotates QR tokens.

## Validation and release

- Real-schema SQL: one registration, S/L creation and edits, correct server order
  prices, immutable history, stale-key rejection, invalid-price rollback, Excel
  import, archived removed size and private-helper ACL.
- Disposable PostgreSQL 17 CI contract runs the actual new migration against
  bounded predecessor fixtures; checks atomic prices, stable parent identity,
  cross-store FK, child price guard and other-store preservation.
- Flutter: one-card selection, S and L simultaneously, KO/VI/EN at 200% text,
  price-change reselection, POS cart, direct cart without extra catalog reads,
  one-row Excel export/import, plus the full existing regression suite.
- Require a clean exact origin/main SHA and successful GitHub POS release
  contract. Use the official production script for a DB-only migration, apply
  the guarded JeonGabok business-data correction, then use official web-only
  deployment. Run operational login and verify the real QR card and size dialog.
- Record actual pass/fail results and release evidence separately. This document
  states acceptance criteria; it does not assert production deployment.
