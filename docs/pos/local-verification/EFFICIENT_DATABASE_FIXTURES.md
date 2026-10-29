# Database fixtures on VFS cloud engines

The POS checkout is approximately 273 MiB. The previous storage failure was a
test dependency packaging problem: 27 shell/Python fixture call sites request
`public.ecr.aws/supabase/postgres:17.6.1.104`, whose amd64 manifest has 29 layers.
VFS deep-copies the parent filesystem for each layer. A streamed inventory of
the pinned image found 1,232,748,208 bytes of final regular-file content and
32,092,480,202 bytes across its cumulative VFS layer contents. These are file
payload measurements/model values, not a direct physical `du` or full gate peak.

`CLAUDE.md` preserves the complete verification scope, isolation and exact-SHA
evidence. It does not mandate a particular DB image representation. The Ubuntu
24.04 tool image and Flutter/Dart/Node/Deno/Chrome versions remain unchanged.

## Explicit, verified representation

On an existing Linux amd64 VFS engine, the runner prepares a separate,
single-layer image from the **entire pinned upstream filesystem**. It never
pulls the original 29 layers into VFS first, changes the daemon, or replaces the
upstream tag. The test Docker wrapper maps four individually audited references:
Supabase PG17.6.1.104, stock PG15, stock PG17.6 and stock PG17 Alpine. Each keeps
its own complete upstream filesystem and configuration; versions are never
merged. Native SDK PG16 and PostgREST v14.5 retain their existing paths.

Policy: `scripts/local_verification/fixture_postgres_policy.json`.

| Identity | Pinned value |
| --- | --- |
| Source manifest | `sha256:3b8aa41d85a00ae6fe8ad8199645e3c5951ce456f659bf07569dab7830fd03af` |
| Source config | `sha256:d469ea2b78bc7dfabf656ef6a46752569bda59b73d37612bcddaad4fc313b7ce` |
| Exported rootfs tar | `sha256:64ec26992718471c847f51a2e076ffb42f8fb6bbdde917789a0aed8330b8f0b6` |
| Derived image | `sha256:c82818a0208bea6901f27021fb40da83cca609170b77258fca2b71559db49af9` |

The initial audit compared 33,551 source/merged archive nodes: regular-file
hashes and sizes, owners, groups, permissions, symbolic/hard links, devices and
xattrs (including capabilities) all matched. Its canonical inventory hash is
`49fecb08d7738bf420663f0d5269d7f976901e7de2e98a677cb7067f4a8a722a`.
The export tar is 1,259,289,600 bytes. Fixed tar and image digests make subsequent
cache reuse an immutable artifact check, not acceptance of a prior test PASS.

The first candidate using only the Supabase projection reached the stock
`postgres:17.6` company-tax fixture, where another VFS layer expansion exhausted
disk. Its FAIL is retained; it is not release evidence. The policy therefore
also records separate immutable source/config/rootfs/derived identities for
each stock fixture in `additionalImages`. The independent source/export node
comparisons cover 9,438 PG15 nodes, 9,557 PG17.6 nodes and 3,891 Alpine nodes.
Every source runtime-config key and archive node matched before adoption.
Only redundant public layered image caches may be removed after the equivalent
distinct runtime is verified and no container references the original image;
database volumes and all source/evidence remain protected.

The checksum-verified official `crane` export reads the pinned registry source.
Docker's supported image-load API receives a standard archive containing that
tar. The original config object is retained, including ENV, ENTRYPOINT, CMD,
USER/default root behavior, WORKDIR, ports, stop signal, HEALTHCHECK, OnBuild and
ArgsEscaped. Only rootfs/history representation changes; the new image ID and
source provenance are explicit. No host Docker data directory is inspected.
The original registry digest is never assigned as a derived RepoDigest.

Before every run, the factory checks the exact derived image ID, sole rootfs
layer address, platform and full upstream runtime-config hash. A cache miss
exports/checks the tar and config before loading it. A foreign cache tag,
different source bytes, runtime config or image ID fails closed. Temporary
download/export archives are removed after preparation. Source, evidence,
credentials, databases, volumes and unrelated images are preserved.

## Semantic coverage retained

| Requirement | Existing checks retained |
| --- | --- |
| PostgreSQL 17.6 + Supabase bootstrap | Same binaries, libraries, entrypoint and initialization SQL; `postgres` remains non-superuser (BYPASSRLS=true baseline), `supabase_admin` superuser; anon/authenticated/authenticator flags unchanged; auth.uid()/auth.users remain present |
| pgcrypto | Menu, inventory, order and corporate fixtures execute their original SQL |
| uuid-ossp | Original bootstrap parity; not claimed to be a newly proven direct application dependency |
| btree_gist | Required corporate invoice mapping plus schema-upgrade fixtures |
| pg_stat_statements | Bounded reads, row/call counts and measured index fixtures |
| pg_cron | Actual promotion/corporate extension and grants; existing structural cron stubs retain their limited meaning |
| safeupdate | Actual LOAD and before/after table-move assertions retained |
| Security and atomicity | Original roles, RLS, tenant/store filters, triggers, RPCs, transaction rollback/retry, monetary invariants and two-session lock/concurrency tests |
| PostgREST v14.5 | Payroll/attendance and financial-input suites retain their real API process and same test names |
| pg_net / Vault | Original runtime files retained; actual production preflight remains separate and is not replaced by fixture stubs |

The development bootstrap probe confirmed PostgreSQL 17.6, all six expected
role flags, auth schema/helpers, loadable pgcrypto/uuid-ossp/btree_gist/
pg_stat_statements/pg_cron, real safeupdate enforcement and rollback. That probe
does not replace final-SHA verification.

## Gate and evidence

All 13 current candidate recipe steps and all mandatory repository stages
remain. Flutter's initial SQL-dependent skips must still pass under exactly the
same names in the two later real SQL/API suites. Missing, skipped or failed
mandatory checks remain failures. Chrome terminal authentication, Deno, Node,
web build and the separate exact-main invocation remain required. Native
Windows exclusions remain unverified native checks, never Linux passes.

Each invocation writes run/SHA-bound fixture provenance and records actual
used image IDs, requested source references and physical representation. The
verifier rejects missing/stale/substituted provenance or altered rootfs/config
evidence, including cross-version substitutions and missing preparation logs.
One-second filesystem samples record the **observed** disk peak and
sampling interval; they do not promise an unsampled instantaneous maximum.

The official production entry point, Auth readiness, migration version/hash/
atomic history, required Edge verification, fixed POS account login and actual
affected-feature checks are unchanged. Production data is never used as a
fixture. A login failure is a separate operational blocker.

Rollback the representation change through its code commit if necessary.
The upstream registry references and all existing DB/volume data remain untouched.
Do not change the storage driver, flatten operating data, publish a registry
image, or delete source/evidence to apply this procedure.

References: [Docker VFS](https://docs.docker.com/engine/storage/drivers/vfs-driver/),
[Docker image load](https://docs.docker.com/reference/cli/docker/image/load/),
[official crane export source](https://github.com/google/go-containerregistry/blob/v0.22.1/cmd/crane/cmd/export.go).
