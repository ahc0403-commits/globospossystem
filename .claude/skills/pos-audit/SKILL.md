---
name: pos-audit
description: Audit the GLOBOSVN POS architecture, security, RLS, payments, database migrations, Office coupling, integrations, release readiness, or implementation quality. Use for audits, design-vs-code reviews, invariant checks, and prioritized remediation reports.
---

# POS Audit

## Load evidence

1. Read `CLAUDE.md`, inspect `git status`, and define the requested audit boundary.
2. Read the authoritative scope v1.4, current code, migrations, functions, tests, and relevant ADRs. If an external source is unavailable, report the evidence gap.
3. Treat dated files under `docs/` as historical evidence unless current code or the authoritative scope confirms them.
4. Cite exact file paths and line numbers for every finding.

## Audit categories

- Tenant and store scope enforcement in RLS, RPCs, Edge Functions, and Flutter services.
- Atomic payment completion, asynchronous e-invoice dispatch, UUIDv7 references, daily close behavior, and settlement domain separation.
- Office coupling to `restaurants` and required columns, views, and naming compatibility.
- Migration lineage, applied-state assumptions, SECURITY DEFINER safety, secrets, cron jobs, and vendor boundaries.
- Flutter architecture, state ownership, permissions, error handling, and regression coverage.
- Release proof, cross-platform fixtures, GitHub Actions checks, and exact-head-SHA evidence.

## Validate findings

- Audit without editing unless the user explicitly requests fixes.
- Trace runtime paths and database definitions far enough to distinguish defects from stale documents or unused code.
- Run focused checks or tests when they materially increase confidence.
- Do not mark missing evidence as a confirmed defect; label it as an evidence gap.

## Report

1. Summarize scope, sources, and checks run.
2. List findings in severity order: `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`, then `CONFIRMED` safeguards.
3. Include impact, evidence, failed safeguard, and smallest safe remediation for every finding.
4. End with a numbered Priority Fix List and exact verification commands.
