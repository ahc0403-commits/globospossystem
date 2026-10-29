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
test('reviewed Edge bytes and existing public JWT mode reach the connected tool once', async () => {
  const item = {...request(), operation: 'deploy-function', arguments: {
    name: 'direct-order-public', verify_jwt: false,
    entrypoint_path: 'direct-order-public/index.ts',
    files: [{name: 'direct-order-public/index.ts', content: '// data: `code` $(text)\n'}],
  }};
  const context = runtime(item);
  context.tools.mcp__codex_apps__supabase_deploy_edge_function = async args => {
    context.calls.push({remote: args}); return {structuredContent: {version: 60}};
  };
  assert.equal((await run(context)).completed.length, 1);
  assert.deepEqual(context.calls.filter(x => x.remote), [{remote: {
    ...item.arguments, project_id: project}}]);
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
test('large source payload uses bounded chunks and never becomes a shell instruction', async () => {
  const item = {...request(), requestHash: 'bound-hash', arguments: {
    name: 'fixture', query: '-- 한국어 📍 $(data)\n'.repeat(10000)}};
  const serialized = JSON.stringify(item);
  const context = runtime(item);
  const original = context.tools.exec_command;
  context.tools.exec_command = async args => {
    if (args.cmd.includes("'next'")) {
      if (context.sent) return {exit_code: 0, output: '{"waiting":true}'};
      context.sent = true;
      return {exit_code: 0, output: JSON.stringify({requestDescriptor: {
        requestId: item.requestId, length: serialized.length, requestHash: item.requestHash}})};
    }
    if (args.cmd.includes("'read-request'")) {
      const offset = Number(args.cmd.match(/'--offset' '(\d+)'/)[1]);
      return {exit_code: 0, output: JSON.stringify({chunk: serialized.slice(offset, offset + 12000),
        length: serialized.length, requestHash: item.requestHash})};
    }
    return original(args);
  };
  assert.equal((await run(context)).completed.length, 1);
  assert.equal(context.calls.filter(x => x.remote)[0].remote.query, item.arguments.query);
});
