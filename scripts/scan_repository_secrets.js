const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..');
const MAX_FILE_BYTES = 2 * 1024 * 1024;
const BINARY_EXTENSIONS = new Set([
  '.gif', '.ico', '.jpeg', '.jpg', '.otf', '.pdf', '.png', '.tgz', '.ttf',
  '.webp', '.woff', '.woff2', '.xlsx', '.zip',
]);

const HIGH_RISK_PATTERNS = [
  ['database-url', /postgres(?:ql)?:\/\/[^\s"'`]+:[^\s"'`@]+@[^\s"'`]+/gi],
  ['github-token', /(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}/g],
  ['github-fine-grained-token', /github_pat_[A-Za-z0-9_]{20,}/g],
  ['supabase-secret-key', /sb_secret_[A-Za-z0-9_-]{20,}/g],
  ['private-key', /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/g],
];

function scanText(text) {
  const findings = [];
  for (const [rule, pattern] of HIGH_RISK_PATTERNS) {
    pattern.lastIndex = 0;
    for (const match of text.matchAll(pattern)) {
      findings.push({
        rule,
        line: text.slice(0, match.index).split('\n').length,
      });
    }
  }
  return findings;
}

function trackedFiles() {
  return execFileSync('git', ['ls-files', '-z'], { cwd: ROOT })
    .toString()
    .split('\0')
    .filter(Boolean);
}

function scanRepository() {
  const findings = [];
  for (const relativePath of trackedFiles()) {
    const absolutePath = path.join(ROOT, relativePath);
    if (!fs.existsSync(absolutePath)) continue;
    const stat = fs.statSync(absolutePath);
    if (stat.size > MAX_FILE_BYTES || BINARY_EXTENSIONS.has(path.extname(relativePath).toLowerCase())) {
      continue;
    }
    const content = fs.readFileSync(absolutePath);
    if (content.includes(0)) continue;
    for (const finding of scanText(content.toString('utf8'))) {
      findings.push({ path: relativePath, ...finding });
    }
  }
  return findings;
}

if (require.main === module) {
  const findings = scanRepository();
  if (findings.length > 0) {
    for (const finding of findings) {
      console.error(`SECRET_SCAN_FINDING ${finding.rule} ${finding.path}:${finding.line}`);
    }
    process.exitCode = 1;
  } else {
    console.log('REPOSITORY_SECRET_SCAN_PASS');
  }
}

module.exports = { scanRepository, scanText };
