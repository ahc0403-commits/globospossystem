# Fresh POS migration replay

The input snapshot contained 609 SQL migrations. This branch preserves their
original bytes and names in the prior candidate commit and external snapshot.
Latest main contains two of the previously untracked October 23 migrations at
canonical new timestamps with identical SQL bytes; this candidate keeps those
canonical names, avoiding a duplicate version and duplicate execution. The third
is retained with upstream additional guards and read fixes. Two migrations
restore the real stores prerequisite and close the legacy Office Auth tail.

Historical data cutovers now distinguish an empty fresh installation from the
specific populated installation they originally targeted. Non-empty shape,
identity, collision, hash, snapshot, privilege and final-state checks remain.
No operating rows, dummy tables, forged migration records, or CLI skip flags are
used. The real Supabase CLI applies all 616 records to a new isolated database.

The legacy numbered tail remains in source; its historical Office identity tables
are private evidence. Migration 302 removes only its cross-project Auth trigger,
revokes Office identity access and restores POS public-only API exposure. Native
POS Auth protections and all business rows remain untouched.

This is a candidate history repair, not approval to mutate linked projects.
Production history reconciliation, clean exact-main verification and the official
release gate still require a separate review and explicit deployment approval.
The source migration fingerprint and full replay logs are stored outside Git in
the Office follow-up evidence directory, bound to the final branch SHA.
