# Security Expand → Migrate → Contract runbook

This repository pass prepares source only. It does not authorize a production query or deployment.

## Required release order

1. Apply only `20260715000000_security_audit_hardening.sql`; run its preflight and post-apply verification.
2. Apply only `20260715020000_security_expand_compat.sql`; run its preflight and post-apply verification.
3. Smoke an old client against Expand: four-argument payment, legacy proof attach, legacy SHA PIN read/set, existing `admin` routing, and the complete restaurant business cycle.
4. Deploy the compatible Flutter build. Do not deploy WeTax Functions. The strict `create_staff_user` Function remains a later, explicitly coordinated step.
5. Fully refresh every terminal. Confirm the shell revalidation headers and the Flutter 3.41.6 unregistering service-worker output, then observe one complete business cycle.
6. Deploy the strict `create_staff_user` Function only after all creation UIs no longer submit `admin`.
7. In a separate later release, satisfy `SECURITY_CONTRACT_PREFLIGHT.md`, promote the guarded Contract draft under a new migration timestamp, and apply only that migration.
8. Perform legacy payment-proof URL cleanup as a later, separately authorized operation using the canary/batch runbook.

## Rollback and fix-forward

- Before Contract: keep both old and v2 RPCs. Roll back the app to the last compatible build without reverting Expand data.
- After Contract: if a supported old client was missed, stop the rollout and apply the guarded emergency regrant draft. Do not delete `payment_attempts`, `proof_object_path`, or bcrypt verifier data.
- A failed proof-queue migration keeps the queue record and file. Operators must not manually delete them before authenticated read verification succeeds.
- Payment vendor/invoice failures never roll back a confirmed POS payment; asynchronous invoice processing remains isolated.

## Terminal refresh

Close every POS tab/window, reopen the production URL, and verify the newly deployed release in a fresh session. If a terminal remains stale, clear that site's cached application data or use a managed hard refresh, then authenticate again. Do not proceed to Contract while any supported terminal still runs the legacy client.
