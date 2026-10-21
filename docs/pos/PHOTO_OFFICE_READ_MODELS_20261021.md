# Office Photo read models

Migration `20261021020000_office_photo_operations_read_models.sql` adds three service-only, read-only RPCs for the Office `pos-bridge`:

- `office_photo_inventory_page`: current active POS inventory, 100-item UUID cursor page, original quantity/unit/update time; no Office stock import or addition.
- `office_photo_employee_profile`: one active workforce employee in one verified Photo store; masked contact/bank fields and existing employment dates; no Auth IDs or credentials.
- `office_photo_operations_report`: up to 50 verified Photo stores / 92 ICT dates, independent finance/HR/payroll/inventory scope arrays. Sources are grouped before joining stores. Staff and stock alert lists are capped at 20 per store. A source without records remains null, and confirmed payroll must match the exact period.

Photo sales continue to use the Super Admin Excel source. The retired collector is not changed or reactivated. Cash/transfers come from POS closing snapshots, independently of Photo sales. Voids/refunds use payment adjustments. Open attendance is the last event before the snapshot cutoff. Inventory is current, not reconstructed historical inventory.

Public/anon/authenticated execution is revoked. Office authenticates the employee, resolves explicit Office/POS store mappings and per-domain grants, and validates/allowlists the RPC responses. These RPCs do not grant Office users POS login accounts or direct workforce table access.

Run `bash scripts/test_photo_operations_read_models.sh` for an isolated, Unix-socket-only PostgreSQL fixture. It verifies aggregate fanout, mixed scopes, masks, exact payroll periods, latest attendance, bounds, and ACLs. It reports response sizes/times for 6 and 50 stores. These measurements are synthetic, not production/load evidence. The script is included in `scripts/check_repo.sh`.

Release through `scripts/deploy_pos_production.sh --db-only --migration supabase/migrations/20261021020000_office_photo_operations_read_models.sql`, after exact pushed-main required CI and the production target/history gates. Companion Office UI/bridge and Office contract/inventory RPC changes are in the Office repository. No business data or login permissions are mutated by this migration.
