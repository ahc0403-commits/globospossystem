# Store Manager default PR inbox and requester catalog entry

Store managers now open their PR approval inbox inside `/admin` by default on
mobile and desktop. A permanent PR approvals navigation item returns to that
inbox; existing inventory and other tabs remain available. Explicit legacy tab
links retain their indices and clamping. Brand-manager and Photo contexts keep
their existing navigation. Live events preserve the mounted inbox and edits.

The requester catalog migration changes only the catalog read guard. It checks
the active workflow role and actual store access independently of PO creation
and receiver membership. The role is resolved once and reused for all catalog
items instead of querying the profile per supplier item. Requesters retain
price redaction and cannot receive
stock merely by reading the catalog. No identity, password, access grant,
approval or issued document is modified.

Regression coverage starts at the actual `/admin` route for both 390px and
1440px viewports, then opens a submitted PR and checks the approval action.
SQL exercises the actual requester catalog RPC after receiver separation,
plus manager access and inactive/cross-store denial. Existing procurement
workflow, inbox pagination, identity, receiving and concurrency tests remain.

The inbox uses the existing bounded RPC: 20 summaries per page, one selected
PR detail per selection, stable submitted-time cursors and the existing
coalesced refresh path. Catalog bootstrapping remains one read per entry; this
change introduces no item-dependent request loop. Real-account smoke records
HTTP request count, response bytes and elapsed time without credentials,
tokens or line contents. Local SQL EXPLAIN covers 2/20/100 stores and
100/1000/10000 pending PRs; network and application memory are outside that
isolated measurement.

Local static analysis, focused Flutter/navigation tests, procurement SQL and
web build are the preflight checks. The full local repository check also
exposes existing macOS receipt/kitchen golden differences; the unchanged
production source reproduces all eight failing visual tests. Do not replace
those Linux baselines. Production requires the exact pushed SHA's GitHub
`POS release contract`, the official deployment script and real-account login
through catalog/list/detail reads. Deployment and actual-login evidence are
recorded separately after execution.

Operational verification uses `scripts/smoke_procurement_accounts.py` with a
mode-600 credential JSON file outside the repository, containing the two
existing account codes. The script logs in with passwords, verifies the real
Auth/profile mapping, queries the catalog and PR list, checks an actionable
manager detail, and closes only its own sessions. It never executes approval,
PR creation, PO issuance or receiving commands. Browser verification additionally
checks the actual login-to-default-screen route before the web release.
