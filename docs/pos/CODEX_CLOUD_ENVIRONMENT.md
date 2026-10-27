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

When the managed environment supplies `CODEX_PROXY_CERT`, the verifier requires
that single public certificate to be present in the existing host CA bundle. It
records both hashes and passes the host bundle to networked image-build steps as
a BuildKit secret and to the runtime container as read-only mounts. The runtime
container updates its disposable system trust store for Dart; no certificate is
added to the saved image. TLS and hostname verification remain enabled. If the
platform CA or bundle is unavailable or untrusted, verification fails closed.

## Larger isolated cloud verifier

If the managed Codex Docker daemon cannot fit the pinned fixture images, run
the same committed gate in a dedicated cloud Linux VM instead. A disposable
Vercel Sandbox with 4 vCPUs, 8 GiB memory, 64 GB ephemeral disk, an x86-64
image and an `overlay2` Docker daemon was used for this project. Confirm actual
free space, execution time, account usage and image/runtime support on each run;
the size is not a guarantee that future builds will fit. This is a separate
verification executor, not a production deployment or a replacement for Codex
Cloud's project workspace.

Install Docker Engine and its Buildx plugin from the VM's trusted package
source. The verifier must run as a non-root UID with permission to use the
VM's private Docker socket; fixture containers must also be able to access that
socket as the same UID/GID. Limit any socket permission change to the disposable
VM and never expose the socket on a network port. Verify the image build and a
container with the recipe's CPU and memory limits before starting the gate.

On a fresh, dedicated Vercel Sandbox, cgroup v2 controllers may not initially
be delegated because the sandbox's own processes occupy the root cgroup. Before
starting Docker, an administrator can move only this disposable sandbox's
processes to a dedicated child cgroup, then delegate `cpu`, `memory`, `pids`,
`io` and `cpuset` to children. Verify that the root cgroup has no processes,
the required controllers are enabled, and a Docker build followed by a
resource-limited container both succeed. Do not apply this to a shared host,
move other workloads, remove resource limits, or silently ignore an error.
If the platform does not permit safe delegation, use another compatible
isolated VM and report this executor as unavailable.

Where the platform intercepts HTTPS, pass its single public CA through
`CODEX_PROXY_CERT` only after checking that it is present in the host trust
bundle. For Vercel Sandbox, the documented certificate location is
`/etc/pki/ca-trust/source/anchors/vercel-proxy-ca.pem`; confirm it and the host
bundle at runtime. Never disable certificate or hostname checks. Use no
production credentials or published ports. Before the ephemeral VM expires,
preserve the complete SHA-bound receipt, logs and build artifacts outside the
VM and verify their hashes; stop only resources created for this run. Account
credits and usage-based charges apply according to the selected cloud service.

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
