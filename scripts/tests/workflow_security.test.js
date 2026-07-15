const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const workflowDirectory = path.join(__dirname, '../../.github/workflows');

function workflowSources() {
  return fs.readdirSync(workflowDirectory)
    .filter(name => /\.ya?ml$/.test(name))
    .map(name => ({
      name,
      source: fs.readFileSync(path.join(workflowDirectory, name), 'utf8'),
    }));
}

function broadEnvBlocks(source) {
  const lines = source.split('\n');
  const blocks = [];
  for (let index = 0; index < lines.length; index += 1) {
    const match = /^(\s*)env:\s*(?:&\S+)?\s*$/.exec(lines[index]);
    if (!match || match[1].length > 4) continue;
    const indent = match[1].length;
    const block = [];
    for (let cursor = index + 1; cursor < lines.length; cursor += 1) {
      const next = lines[cursor];
      if (next.trim() && next.length - next.trimStart().length <= indent) break;
      block.push(next);
    }
    blocks.push(block.join('\n'));
  }
  return blocks;
}

test('every workflow action is pinned to a full commit SHA with a version comment', () => {
  for (const { name, source } of workflowSources()) {
    const uses = [...source.matchAll(/^\s*-\s+uses:\s+([^\s#]+)(?:\s+#\s+(v\S+))?\s*$/gm)];
    assert.equal(
      uses.length,
      [...source.matchAll(/^\s*-\s+uses:/gm)].length,
      `${name} has an unrecognized action declaration`,
    );
    for (const match of uses) {
      assert.match(
        match[1],
        /^[^@\s]+@[0-9a-f]{40}$/,
        `${name} has a mutable action reference: ${match[1]}`,
      );
      assert.match(match[2] || '', /^v\d/, `${name} action is missing a version comment`);
    }
  }
});

test('workflow and job-wide environment blocks never contain repository secrets', () => {
  for (const { name, source } of workflowSources()) {
    for (const block of broadEnvBlocks(source)) {
      assert.doesNotMatch(
        block,
        /\$\{\{\s*secrets\./,
        `${name} exposes a secret through a workflow or job-wide environment`,
      );
    }
  }
});
