#!/usr/bin/env node

console.error(
  "ERROR: Broad Auth password resets are forbidden. " +
    "Use scripts/reset_production_operational_passwords.sh, which is limited " +
    "to the approved production operational account list.",
);
process.exit(1);
