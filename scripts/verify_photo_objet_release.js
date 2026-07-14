const fs = require('fs');

const EXPECTED_REPOSITORY = Object.freeze({
  org: 'ahc0403-commits',
  repo: 'globospossystem',
  ref: 'main',
});

function parseArgs(argv) {
  const options = { checkOnly: false, checkValidationOnly: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--check-only') {
      options.checkOnly = true;
      continue;
    }
    if (arg === '--check-validation-only') {
      options.checkValidationOnly = true;
      continue;
    }
    if (![
      '--validation', '--deployment', '--health', '--sha', '--validation-state',
      '--deployment-state', '--output',
    ].includes(arg)) {
      throw new Error(`Unknown argument: ${arg}`);
    }
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) throw new Error(`${arg} requires a value`);
    options[arg.slice(2).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())] = value;
    index += 1;
  }
  if (!/^[0-9a-f]{40}$/.test(options.sha || '')) {
    throw new Error('a full --sha is required');
  }
  if (options.checkValidationOnly) {
    if (!options.validation) throw new Error('--validation is required');
  } else if (!options.deployment) {
    throw new Error('--deployment is required');
  }
  return options;
}

function validationRuns(validation) {
  if (Array.isArray(validation?.workflow_runs)) return validation.workflow_runs;
  return validation ? [validation] : [];
}

function verifyCodeValidation(validation, sha) {
  const matchingSha = validationRuns(validation).filter(run => (
    run.head_sha === sha
    && run.head_branch === EXPECTED_REPOSITORY.ref
    && run.event === 'push'
    && (run.name === 'Photo Objet Sales Contract'
      || run.path === '.github/workflows/photo_objet_sales_contract.yml')
  ));
  if (matchingSha.length === 0) {
    const error = new Error('CODE_VALIDATED evidence is absent for the exact main SHA');
    error.failureClass = 'RELEASE_SHA_DRIFT';
    throw error;
  }
  const successful = matchingSha.find(run => (
    run.status === 'completed' && run.conclusion === 'success'
  ));
  if (!successful) {
    const error = new Error('CODE_VALIDATED did not complete successfully');
    error.failureClass = 'AUDIT_INFRA_FAILED';
    throw error;
  }
  return {
    state: 'SUCCESS',
    sha,
    run_id: successful.id || null,
    run_url: successful.html_url || null,
  };
}

function verifyDeployment(deployment, sha) {
  const meta = deployment.meta || {};
  const errors = [];
  if (deployment.target !== 'production') errors.push('target');
  if (deployment.readyState !== 'READY') errors.push('readyState');
  if (meta.githubCommitSha !== sha) errors.push('githubCommitSha');
  if (meta.githubCommitRef !== EXPECTED_REPOSITORY.ref) errors.push('githubCommitRef');
  if (meta.githubCommitOrg !== EXPECTED_REPOSITORY.org) errors.push('githubCommitOrg');
  if (meta.githubCommitRepo !== EXPECTED_REPOSITORY.repo) errors.push('githubCommitRepo');
  if (errors.length > 0) {
    const error = new Error(`Production deployment proof mismatch: ${errors.join(',')}`);
    error.failureClass = 'RELEASE_SHA_DRIFT';
    throw error;
  }
  return true;
}

function buildEvidence(
  options,
  validation,
  deployment,
  health,
  observedAt = new Date().toISOString(),
) {
  const codeValidation = verifyCodeValidation(validation, options.sha);
  verifyDeployment(deployment, options.sha);
  if (!health || health.audit_result !== 'PASS') {
    throw new Error('MAIN_AUDIT_PASS evidence is absent or unhealthy');
  }
  return {
    state: 'PRODUCTION_OBSERVED',
    main_sha: options.sha,
    code_validation_state: codeValidation.state,
    validated_sha: codeValidation.sha,
    validation_run_id: codeValidation.run_id,
    validation_run_url: codeValidation.run_url,
    deployment_sha: deployment.meta.githubCommitSha,
    deployment_state: options.deploymentState || deployment.readyState,
    deployment_target: deployment.target,
    audit_result: health.audit_result,
    latest_due_slot: health.latest_due_slot || null,
    production_http_status: 200,
    observed_at: observedAt,
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.checkValidationOnly) {
    const validation = JSON.parse(fs.readFileSync(options.validation, 'utf8'));
    verifyCodeValidation(validation, options.sha);
    return;
  }
  const deployment = JSON.parse(fs.readFileSync(options.deployment, 'utf8'));
  verifyDeployment(deployment, options.sha);
  if (options.checkOnly) return;
  const validation = JSON.parse(fs.readFileSync(options.validation, 'utf8'));
  const health = JSON.parse(fs.readFileSync(options.health, 'utf8'));
  const evidence = buildEvidence(options, validation, deployment, health);
  fs.writeFileSync(options.output, `${JSON.stringify(evidence, null, 2)}\n`);
  console.log(`PHOTO_RELEASE_EVIDENCE=${JSON.stringify(evidence)}`);
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(`PHOTO_FAILURE_CLASS=${error.failureClass || 'AUDIT_INFRA_FAILED'}`);
    console.error(`PHOTO_RELEASE_PROOF_FAILED ${error.message}`);
    process.exit(6);
  }
}

module.exports = {
  buildEvidence,
  parseArgs,
  verifyCodeValidation,
  verifyDeployment,
};
