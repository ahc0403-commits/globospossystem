# Photo Objet automatic sales collection — permanently retired

Status: **RETIRED**  
Effective date: 2026-09-16

Photo Objet automatic sales collection is not an active POS capability. The
former schedule, collector runner, backup, recovery, backfill, slot-health
monitor, collection alerts, and Photo-specific release proof were removed.
Missing historical collection slots are not operational incidents and must not
block a POS release.

## Supported data path

Existing Photo sales tables and migrations remain only for historical data and
report compatibility. New Photo sales data may enter POS only through the
explicit Super Admin Excel import. The import is a user-initiated operation; it
is not a scheduler or background collector.

Legacy database names such as `photo_objet_sales_pull_runs` remain for schema
compatibility. They do not mean that a pull service still exists. A database
trigger rejects every new run whose `run_source` is not `manual`.

## Enforcement

- `CLAUDE.md` defines retirement as an active repository invariant.
- `20260916060000_retire_photo_objet_automatic_sales_collection.sql` disables
  monitoring policies, blocks their reactivation, rejects non-manual sales
  runs, and revokes collector RPCs and direct inserts from application roles.
- `test/photo_objet_sales_collection_retirement_contract_test.sh` fails when a
  retired workflow or executable collector returns.
- The required repository gate is `POS release contract`. It has no Photo sales
  health dependency.

Reintroduction requires an explicit new user decision, removal of the database
retirement guard in a new migration, and a new ADR. Historical documentation
and old migrations are provenance only and do not authorize reactivation.
