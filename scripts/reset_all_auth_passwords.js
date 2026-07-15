#!/usr/bin/env node

// BULK_AUTH_PASSWORD_RESET_DISABLED
//
// Bulk password mutation is intentionally quarantined. It previously listed
// every Auth user and assigned one shared repository-defined password. Use the
// Supabase dashboard or the approved single-user recovery workflow instead.

console.error(
  'BULK_AUTH_PASSWORD_RESET_DISABLED: use the approved single-user recovery workflow.',
);
process.exitCode = 1;
