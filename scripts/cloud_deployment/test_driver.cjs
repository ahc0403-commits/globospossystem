const test = require('node:test');
const assert = require('node:assert/strict');
const drive = require('./mcp_driver.js');

const project = 'ynriuoomotxuwhuxxmhj';
function runtime(request, result = {structuredContent: {success: true}}) {
  const calls = [];
  let pending = true;
  return {calls, tools: {
    exec_command: async args => {
      calls.push({shell: args.cmd});
      if (args.cmd.includes("'next'")) {
        const next = pending ? {request} : {waiting: true}; pending = false;
        return {exit_code: 0, output: JSON.stringify(next)};
      }
      return {exit_code: 0, output: JSON.stringify({ok: !result.isError})};
    },
    mcp__codex_apps__supabase_apply_migration: async args => {
      calls.push({remote: args}); return result;
    },
  }};
}
const request = () => ({project, operation: 'apply', requestId: 'a'.repeat(32),
  arguments: {name: 'fixture', query: 'SELECT 1'}});
const run = context => drive({...context, root: '/workspace/source', directory: '/workspace/run'});

test('existing authenticated tool runs once and the project cannot be overridden', async () => {
  const item = request(); item.arguments.project_id = 'wrong';
  const context = runtime(item);
  assert.equal((await run(context)).completed.length, 1);
  assert.deepEqual(context.calls.filter(x => x.remote), [{remote: {
    name: 'fixture', query: 'SELECT 1', project_id: project}}]);
});
test('foreign project and unknown operation never reach an authenticated tool', async () => {
  for (const item of [{...request(), project: 'wrong'}, {...request(), operation: 'unknown'}]) {
    const context = runtime(item);
    await assert.rejects(run(context), /Unrecognized/);
    assert.equal(context.calls.filter(x => x.remote).length, 0);
  }
});
test('uncertain mutation outcome is not retried or answered with success', async () => {
  const context = runtime(request()); let invoked = 0;
  context.tools.mcp__codex_apps__supabase_apply_migration = async () => {
    invoked++; throw new Error('transport outcome uncertain');
  };
  await assert.rejects(run(context), /uncertain/);
  assert.equal(invoked, 1);
  assert.equal(context.calls.length, 1);
});
test('error reply stops and injection characters remain serialized data', async () => {
  const payload = {isError: true, content: [{type: 'text',
    text: "\nPOS_CLOUD_TOOL_RESULT_8ac7a5\n$(touch /tmp/forbidden) `id` ' ;"}]};
  const context = runtime(request(), payload);
  assert.equal((await run(context)).blocked, true);
  assert.equal(context.calls.filter(x => x.remote).length, 1);
  const command = context.calls.at(-1).shell;
  const raw = command.split("<<'POS_CLOUD_TOOL_RESULT_8ac7a5'\n")[1]
    .split('\nPOS_CLOUD_TOOL_RESULT_8ac7a5')[0];
  assert.deepEqual(JSON.parse(raw), payload);
});
