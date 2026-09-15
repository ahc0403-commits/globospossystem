const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.join(__dirname, '../..');
const workflows = path.join(root, '.github/workflows');

test('POS release contract runs the complete repository check', () => {
  const workflow = fs.readFileSync(
    path.join(workflows, 'pos_release_contract.yml'),
    'utf8',
  );

  assert.match(workflow, /^name: POS Release Contract$/m);
  assert.match(workflow, /^\s+name: POS release contract$/m);
  assert.match(workflow, /pull_request:/);
  assert.match(workflow, /push:[\s\S]*branches: \[main\]/);
  assert.match(workflow, /run: bash scripts\/check_repo\.sh/);
  assert.doesNotMatch(workflow, /secrets\./);
  assert.doesNotMatch(workflow, /Photo Objet|photo_objet/);
});

test('all active external GitHub Actions are pinned to full commits', () => {
  const workflowNames = fs.readdirSync(workflows)
    .filter(name => name.endsWith('.yml'));
  let externalActionCount = 0;

  for (const workflowName of workflowNames) {
    const workflow = fs.readFileSync(path.join(workflows, workflowName), 'utf8');
    for (const [lineIndex, line] of workflow.split('\n').entries()) {
      const use = line.match(
        /^\s*(?:-\s*)?uses:\s+([^@\s]+)@([^\s#]+)(?:\s+#\s*(.+))?$/,
      );
      if (!use || use[1].startsWith('./')) continue;
      externalActionCount += 1;
      assert.match(
        use[2],
        /^[0-9a-f]{40}$/,
        `${workflowName}:${lineIndex + 1} must pin a full commit SHA`,
      );
      assert.match(
        use[3] ?? '',
        /^v\d+(?:\.\d+){1,2}$/,
        `${workflowName}:${lineIndex + 1} must retain a release label`,
      );
    }
  }

  assert.ok(externalActionCount > 0, 'active workflows must use pinned Actions');
});

test('Flutter SDK archives are official and checksum verified', () => {
  const linux = fs.readFileSync(
    path.join(workflows, 'pos_release_contract.yml'),
    'utf8',
  );
  const windows = fs.readFileSync(
    path.join(workflows, 'windows_print_station_build.yml'),
    'utf8',
  );

  assert.doesNotMatch(`${linux}\n${windows}`, /subosito\/flutter-action/);
  assert.match(linux, /storage\.googleapis\.com\/flutter_infra_release\/releases\/stable\/linux/);
  assert.match(linux, /sha256sum --check/);
  assert.match(windows, /storage\.googleapis\.com\/flutter_infra_release\/releases\/stable\/windows/);
  assert.match(windows, /Get-FileHash -Algorithm SHA256/);
});
