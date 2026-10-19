# Print Station: paperless cashier setup

In Store Setup, select the operation mode in the printer step:

- Paperless: one cashier receipt printer. Kitchen and floor orders use the existing KDS workflow. Preview and readiness require only the receipt route and its successful, physically confirmed test.
- Physical printing: four physical printers and five routes (receipt, kitchen, G, 1F, 2F), retaining the existing shared G printer choice.

Each physical printer can use Windows USB, wired LAN or Wi-Fi. For USB, enter the exact Windows printer queue name, such as `XP-80C`; no IP or TCP port is required. Run the native Print Station on the PC connected to that printer. Configuration restores the typed endpoint when reopened. Changing a connection, USB name, mode or tables discards old client test confirmations.

Mode selection follows `restaurant_settings.fulfillment_mode`. A change of mode uses the existing Super Admin RPC, audit log and KDS session/draining rules. Other authorized admins may configure the current mode. Existing printer routes and print history are preserved when switching to paperless.

Opening Store Setup selects its authorized active store for the app-root print agent, including when entering directly from the Super Admin store list. On a native station, queue tests and retries require that device's agent to be running for the selected store. Web setup can still queue tests for a separate native station. The advanced destination test sends directly to the printer; the opening checklist queues jobs so it also verifies the operational agent path. Enable the agent on the connected Windows PC before running the checklist.

For a Super Admin whose login claims omit the target store, setup resolves that single active restaurant through server RLS before selecting it locally. This is an explicit setup-only path; ordinary selection and other roles retain their existing scope rules. The lookup is limited to one requested store, shared while selection is in progress, and skipped after the store is resolved. Account roles and server claims are unchanged. Missing/closed stores, denied/offline reads and session/role changes during the read fail closed.

## Release dependency

The Windows artifact does not apply the server migration. Before installing it for operational use, the release must include `supabase/migrations/20261019160000_store_opening_printer_modes.sql` through `scripts/deploy_pos_production.sh` and the exact-main GitHub release gate. The old setup RPCs remain available to installed clients.

The package is built by `.github/workflows/windows_print_station_build.yml`; its artifact name includes the exact source SHA. Close the old app, extract the entire ZIP into a new folder, and start `globos_print_station.exe` with its bundled DLLs and data folder. Do not replace only the executable. On the store PC select Paperless → Cashier → USB → Windows name `XP-80C`, apply, enable the print agent, run the receipt test, and confirm the actual paper output.

## Verification

- `dart analyze --fatal-infos`.
- Focused Flutter setup, queue, endpoint and Windows build tests; narrow/wide setup widgets.
- `bash test/store_opening_printer_modes_sql_test.sh` runs an isolated PostgreSQL fixture. It covers authorization, tenant isolation, atomic invalid-input rollback, protected tables, typed USB endpoints, idempotent apply, shared physical printers, mode/session transitions, mode-aware readiness and idempotent batch test enqueue.
- Setup loading is four store-scoped requests (concurrency bounded by four), including embedded endpoints. Validate, apply and enqueue-all-tests each use one RPC. Each queue poll reads all returned job IDs in one request. SQL payload limits remain 500 tables and 20 routes; the UI generates one or five routes.
- A local 500-table fixture apply took roughly 15 ms. Table insert and table audit insert are set operations. PostgreSQL still performs indexed foreign-key checks per inserted row; these are measured separately from application statements. This fixture does not establish production latency, printer hardware behavior or installation success.
