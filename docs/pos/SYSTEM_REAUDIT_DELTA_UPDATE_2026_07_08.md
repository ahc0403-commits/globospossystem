# System Re-Audit Delta Update — 2026-07-08

Scope: update to the 2026-07-08 re-audit after applying
`20260708000000_recalc_order_status_acl_closure` to production.

## Summary

The previously open M-1' item is now closed. The repository migration and
production migration history are aligned for `20260708000000`, and live
`recalc_order_status(uuid)` ACLs no longer allow direct execution by `anon` or
`authenticated`.

## Delta From Previous Re-Audit

| Previous finding | Current status |
|---|---|
| H-1 uncommitted production code | Resolved. Worktree remains clean. |
| M-1 `recalc_order_status` public execute | Resolved. `20260708000000` is applied in production and migration history. |
| M-2 printer destinations 0 + failed print jobs | Unchanged. Operational setup still required before pilot. |
| M-3 pilot test menu residue 7 records | Unchanged. Destructive cleanup still requires approval. |
| Gate 3 stale | Unchanged. Service-item client deployment and smoke remain pending. |

## Live Evidence

| Check | Result |
|---|---|
| Migration history | `20260708000000` appears in both Local and Remote columns. |
| `recalc_order_status(uuid)` ACL | `anon_execute=false`, `authenticated_execute=false`, `service_role_execute=true`. |
| `proacl` | `postgres=X/postgres,service_role=X/postgres`. |
| Static analysis | `flutter analyze` exit 0. |
| Contract tests | `flutter test test/security_remediation_contract_test.dart test/print_routing_contract_test.dart` exit 0. |
| Worktree | Clean. |

## Open Items

### Medium

1. Service-item client Vercel deployment + Gate 3 re-run.
2. Printer destination registration + native print agent installation.
3. Pilot test menu residue cleanup: `auto_pilot_*` 5 + `Dung` 2, pending deletion approval.

## Confirmed Closed

- M-1/F-1 final closure: direct public/client execution of
  `public.recalc_order_status(uuid)` is removed in production.
- The remaining `service_role` execute grant preserves operational/admin
  maintenance access.
- Existing print-routing/security contract tests still pass after the ACL
  closure.

## Recommendation

GO AFTER CLEANUP + GATE 3.

There are no open Critical or High findings in this delta. The remaining work is
deployment, smoke evidence, printer setup, and approved data cleanup.
