# POS Codex Cloud verification

The owner authorized Codex Cloud as a primary development and verification
location. Preserve the exact same release checks and production safeguards.
The private cloud environment `globospossystem` is connected only to the POS
repository. Publishing an environment does not establish a passing release.

The environment setup uses checksum-verified Flutter 3.41.6 and Node 22.22.0
and locked dependencies. Confirm actual tool versions and installation results
in a new task. The current recipe also requires a usable Unix-socket Docker
engine, outbound access for its pinned image and dependencies, adequate disk,
CPU and memory, and isolated test fixtures. The recipe builds its own pinned
Ubuntu tool image with Deno, Chrome, Flutter and PostgreSQL tools; do not replace
it with partial tests or an untrusted supplied PASS receipt. See
[the full verification contract](local-verification/LOCAL_VERIFICATION.md).

For a clean committed candidate checkout, execute:

```bash
python3 -B scripts/pos_local_release_gate.py run \
  --kind candidate --output /absolute/new/private/candidate-evidence
python3 -B scripts/pos_local_release_gate.py verify \
  --kind candidate --evidence /absolute/new/private/candidate-evidence
```

The official production deployer independently reruns the fixed recipe on a
clean, freshly fetched exact `origin/main` and checks it again after execution.
Keep receipts, complete logs, run/pass/fail/skip counts, versions, timestamps,
and artifact hashes together, review them for sensitive content before sharing,
and verify the pushed SHA. Candidate evidence does not certify main. Record
missing tools, network, OS, devices, skipped checks or incomplete work as not
verified. A Windows x64 build and physical printer/operational checks still
require suitable separate systems and approved access.

Do not put production credentials or business data in the reusable environment.
Live deployments, migration, production Auth and operational checks retain the
pinned targets and the official script; environment setup itself does not grant
approval for production mutations. Review current GitHub protection and rules
before any merge, and do not bypass or silently weaken them.
