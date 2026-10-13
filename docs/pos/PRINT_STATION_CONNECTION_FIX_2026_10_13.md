# Cashier print-station connection correction — 2026-10-13

The owner reported `Connection failed` and no physical test output on the
cashier PC after installing the 25d4a600 Windows package. The PC is operated by
the owner; there is no remote Windows session or PC-side network trace available
in this task. Therefore a physical power, addressing or firewall fault has not
been established or ruled out.

## Evidence and corrected behavior

Production read-only configuration has an active Bunsik `Cashier` receipt route
at `192.168.1.251:9100`. The older `192.168.68.251:9100` receipt route is inactive.
The owner has not supplied the PC's locally saved IP. Neither address was
changed in the production DB.

The original Settings > Receipt connection check and receipt test read the
PC's `printer_ip` preference, independently of the store's registered receipt
route. Consequently that check can fail against an old or unrelated address
while normal queued receipts target a different printer. The settings panel
now uses the selected store's active receipt route for its primary connection
and print tests. A single receipt route is selected automatically; multiple
routes require explicit selection. The old local-IP probe is retained in an
explicitly labelled, collapsed section. Other stores, inactive routes and
kitchen/floor routes cannot become the primary receipt test target.

Late loading of preferences could overwrite a newly entered local IP. A
revision guard now prevents that race and stale connection results. Tests
reproduce the old-address/new-input timing without changing any real settings.

Previously the socket layer tried every enumerated local interface before the
OS-selected route. It now tries the OS route first, then at most three distinct
local IPv4 sources after failure. Adapter discovery is bounded to one second;
source connection attempts are bounded to two seconds each. The normal route
uses the existing three-second connection probe/five-second print connect
limits. Tests establish call order and the four-attempt bound, rather than
claiming measured performance on the cashier network.

Previously test printing discarded endpoint errors and reported a generic
`connectionFailed`. Tests now retain endpoint, IP:port/Windows printer name,
refusal, timeout, unreachable-route and Windows spooler error codes. Korean,
Vietnamese and English instructions identify the relevant settings. A
connection probe sends no ticket bytes. Windows printer probes open the actual
configured spooler name and read its reported status without starting a print
document. A socket/spooler success is not proof of physical paper output.

When bytes may have already been sent, automatic fallback stops to avoid a
second physical copy. Existing two-copy floor behavior and multi-copy partial
failure protection are retained.

## Access and workload

The panel reuses the existing store-scoped destination provider: one bounded
store destination query and one endpoint batch query shared with the routing
section. A manual test reloads its selected destination and endpoint batch;
no per-menu or per-destination polling was added. Reading printer capability
does not initialize the coordinator or start background queue polling; existing
application session lifecycle continues to control the agent. Existing queue claim/batch
loading, role/RLS checks and session lifecycle are preserved. Diagnostics do
not create sales, claim production jobs or enqueue extra test jobs.

## Verification and delivery

Meaningful regressions cover real loopback TCP connections, zero-byte probes
on the configured non-default port, connection-error preservation, bounded
routing fallbacks, uncertain-send duplicate prevention, delayed preferences,
registered receipt selection, explicit multiple-printer selection and localized
390px/2x-text layouts. The Windows workflow also runs the Windows method-channel
probe and compiles/packages the runner on Windows x64.

Use only the full package built by `windows_print_station_build.yml` at the
final reviewed main SHA, after required `POS release contract` success. The ZIP
includes the executable, DLLs, data folder and `INSTALL.txt` with its exact SHA.
The owner installs it in a fresh folder with the previous application closed
and verifies physical output on the cashier PC. Final check-run IDs, package
hash and local-check results are recorded in the task's output report.

No database migration, MISA issuance/transmission or Vercel publication is
needed for this Windows package correction. Existing perpetual mappings,
fee-free sales, legal-entity QR, D+1 deposits and unrelated user changes are
preserved.
