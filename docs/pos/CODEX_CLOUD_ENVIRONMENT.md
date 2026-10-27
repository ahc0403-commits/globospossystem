# GLOBOS POS: Codex Cloud preparation

This document prepares the environment. It does not itself change production,
replace the current GitHub release gate, or prove any check passed.

1. In Codex Cloud create a private environment for
   `ahc0403-commits/globospossystem`. Publish it only after setup and checks are
   reviewed. Use a separate test database and fixture data; do not put production
   credentials or data into the reusable environment.
2. The Linux release-contract workflow pins Flutter 3.41.6, Node 22 and Deno
   2.7.13. It also needs Python, PostgreSQL client, ripgrep, Chrome, and a working
   Docker daemon capable of pulling and running the fixture PostgreSQL and
   PostgREST images. Configure those dependencies and permitted download hosts.
   `bash scripts/prepare_codex_cloud.sh` verifies prerequisites and installs the
   SHA-256-pinned Linux x86_64 Flutter SDK into the user's home, then installs
   locked Flutter and Node dependencies. It does not install Docker or Chrome.
3. In a new cloud task, check tool versions, Docker and Chrome, then run
   `bash scripts/check_repo.sh` and
   `flutter test --no-pub --platform chrome test/terminal_auth_browser_test.dart`.
   Record failures and skipped tests, and do not report missing prerequisites as
   passing. The optional current-schema upgrade check needs a separately reviewed
   schema-only fixture and is not automatically established by these commands.
4. Release preparation must use a separate clean checkout at a freshly fetched
   exact `origin/main`. `python3 scripts/run_exact_main_cloud_verification.py`
   fetches main, refuses a dirty or different checkout, runs the repository and
   browser contract checks directly, and writes a private SHA-bound manifest and
   logs outside the checkout. Inspect them for secrets and skipped tests before
   copying or sharing. The manifest reports command-level counts; it does not
   infer individual test counts. Retain the manifest, logs and their hashes.
5. The production deployment script **still requires** the exact-SHA GitHub
   `POS release contract` check. The new verifier is a candidate, not yet a gate:
   exercise it against the real cloud setup, review equivalence and negative
   tests, and implement and verify the integration before replacing that check.
   Keep all exact-main, pinned target, migration, Auth and operational gates.
6. Windows x64 print station builds require an appropriate Windows environment;
   physical printer and operational login checks require the corresponding
   approved devices and access. Record unavailable items as unverified.
