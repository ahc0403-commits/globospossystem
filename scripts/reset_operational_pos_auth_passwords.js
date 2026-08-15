#!/usr/bin/env node
/*
 * Reset only the approved fixed operational POS accounts.
 *
 * Required environment variables:
 *   SUPABASE_URL
 *   SUPABASE_SERVICE_ROLE_KEY
 *   POS_INITIAL_PASSWORD
 *
 * The password must be supplied only through the environment at execution
 * time. It is never logged or stored in this file.
 */

const { createClient } = require('@supabase/supabase-js');

const targetEmails = [
  'photo_bm1@globos.world',
  'photo_bm2@globos.world',
  'bh_ops1@globos.world',
  'da_ops1@globos.world',
  'lt_ops1@globos.world',
  'nz_ops1@globos.world',
  'qt_ops1@globos.world',
  'td_ops1@globos.world',
  'bunsik_bm1@globos.world',
  'bunsik_sm1@globos.world',
  'bt_pos1@globos.world',
  'bt_tab1@globos.world',
  'bt_kit@globos.world',
];
const excludedEmails = new Set(['andre@globos.world']);
const required = ['SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'POS_INITIAL_PASSWORD'];

function fail(message) {
  console.error(`ERROR: ${message}`);
  process.exit(1);
}

async function listAllUsers(client) {
  const users = [];
  for (let page = 1; ; page += 1) {
    const { data, error } = await client.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) fail(`Unable to list Auth users: ${error.message}`);
    users.push(...(data.users || []));
    if (!data.users || data.users.length < 1000) return users;
  }
}

async function main() {
  const dryRun = process.argv.includes('--dry-run');
  for (const name of required) {
    if (!process.env[name]) fail(`${name} must be set.`);
  }
  if (process.env.POS_INITIAL_PASSWORD.length < 12) {
    fail('POS_INITIAL_PASSWORD must be at least 12 characters.');
  }

  const client = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const users = await listAllUsers(client);
  const byEmail = new Map();
  for (const user of users) {
    const email = (user.email || '').toLowerCase();
    if (!email) continue;
    const matches = byEmail.get(email) || [];
    matches.push(user);
    byEmail.set(email, matches);
  }

  const missing = targetEmails.filter((email) => !byEmail.has(email));
  const duplicate = targetEmails.filter((email) => (byEmail.get(email) || []).length !== 1);
  const forbiddenTarget = targetEmails.filter((email) => excludedEmails.has(email));
  if (missing.length || duplicate.length || forbiddenTarget.length) {
    fail(`Preflight failed (missing=${missing.length}, duplicate=${duplicate.length}, excluded=${forbiddenTarget.length}). No password was changed.`);
  }

  if (dryRun) {
    console.log(`PASS: preflight found exactly ${targetEmails.length} approved operational POS accounts; super admin excluded.`);
    console.log(`ACCOUNTS: ${targetEmails.join(', ')}`);
    return;
  }

  const results = [];
  for (const email of targetEmails) {
    const user = byEmail.get(email)[0];
    const { error } = await client.auth.admin.updateUserById(user.id, {
      password: process.env.POS_INITIAL_PASSWORD,
    });
    if (error) {
      console.error(`FAILED: ${email} (${error.message})`);
      process.exit(1);
    }
    results.push(email);
  }
  console.log(`PASS: reset ${results.length} approved operational POS accounts; super admin excluded.`);
  console.log(`ACCOUNTS: ${results.join(', ')}`);
}

main().catch((error) => fail(error.message));
