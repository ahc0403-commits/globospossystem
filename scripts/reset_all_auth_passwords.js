#!/usr/bin/env node
// scripts/reset_all_auth_passwords.js
// Usage:
//   export SUPABASE_URL="https://YOUR_PROJECT_REF.supabase.co"
//   export SUPABASE_SERVICE_ROLE_KEY="YOUR_SERVICE_ROLE_KEY"
//   node scripts/reset_all_auth_passwords.js

const { createClient } = require('@supabase/supabase-js');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const NEW_PASSWORD = '1234!@#$';
const DELAY_MS = 150;

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error('ERROR: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set.');
  process.exit(1);
}

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function fetchAllUsers() {
  const users = [];
  let page = 1;
  const perPage = 1000;

  while (true) {
    const { data, error } = await supabase.auth.admin.listUsers({ page, perPage });
    if (error) throw new Error(`listUsers page ${page}: ${error.message}`);
    if (!data.users || data.users.length === 0) break;
    users.push(...data.users);
    if (data.users.length < perPage) break;
    page++;
  }

  return users;
}

async function main() {
  console.log('Fetching all auth users...');
  const users = await fetchAllUsers();
  console.log(`Total users found: ${users.length}\n`);
  console.log('id | email | result');
  console.log('-'.repeat(72));

  const failed = [];

  for (const user of users) {
    const { error } = await supabase.auth.admin.updateUserById(user.id, {
      password: NEW_PASSWORD,
    });

    if (error) {
      console.log(`${user.id} | ${user.email} | FAILED: ${error.message}`);
      failed.push({ id: user.id, email: user.email, reason: error.message });
    } else {
      console.log(`${user.id} | ${user.email} | OK`);
    }

    await sleep(DELAY_MS);
  }

  console.log('\n' + '='.repeat(72));
  console.log('SUMMARY');
  console.log(`  total  : ${users.length}`);
  console.log(`  success: ${users.length - failed.length}`);
  console.log(`  failed : ${failed.length}`);

  if (failed.length > 0) {
    console.log('\nFailed users:');
    for (const f of failed) {
      console.log(`  ${f.id} | ${f.email} | ${f.reason}`);
    }
    process.exit(1);
  }
}

main().catch((err) => {
  console.error('Fatal error:', err.message);
  process.exit(1);
});
