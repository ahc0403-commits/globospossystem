#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const args = process.argv.slice(2);
const markdownIndex = args.indexOf('--markdown');
const markdownPath =
  markdownIndex >= 0 && args[markdownIndex + 1]
    ? path.resolve(root, args[markdownIndex + 1])
    : null;

const severities = ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW', 'CONFIRMED'];

function read(relativePath) {
  const absolutePath = path.join(root, relativePath);
  if (!fs.existsSync(absolutePath)) return null;
  return fs.readFileSync(absolutePath, 'utf8');
}

function exists(relativePath) {
  return fs.existsSync(path.join(root, relativePath));
}

function listFiles(dir, predicate = () => true) {
  const absoluteDir = path.join(root, dir);
  if (!fs.existsSync(absoluteDir)) return [];
  const out = [];
  const stack = [absoluteDir];
  while (stack.length) {
    const current = stack.pop();
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const absolute = path.join(current, entry.name);
      if (entry.isDirectory()) {
        if (entry.name === 'build' || entry.name === '.dart_tool') continue;
        out.push(...[]);
        stack.push(absolute);
      } else {
        const relative = path.relative(root, absolute);
        if (predicate(relative)) out.push(relative);
      }
    }
  }
  return out.sort();
}

function lineNumber(source, needle) {
  const index = source.indexOf(needle);
  if (index < 0) return null;
  return source.slice(0, index).split('\n').length;
}

const results = [];

function addResult({ id, severity, category, status, file, message, evidence }) {
  results.push({
    id,
    severity,
    category,
    status,
    file,
    message,
    evidence,
  });
}

function pass(id, category, file, message, evidence = '') {
  addResult({
    id,
    severity: 'CONFIRMED',
    category,
    status: 'PASS',
    file,
    message,
    evidence,
  });
}

function fail(id, severity, category, file, message, evidence = '') {
  addResult({
    id,
    severity,
    category,
    status: 'FAIL',
    file,
    message,
    evidence,
  });
}

function expectContains({
  id,
  severity,
  category,
  file,
  needle,
  message,
}) {
  const source = read(file);
  if (!source) {
    fail(id, severity, category, file, `Missing file: ${file}`);
    return;
  }
  if (!source.includes(needle)) {
    fail(id, severity, category, file, message, `Missing marker: ${needle}`);
    return;
  }
  const line = lineNumber(source, needle);
  pass(id, category, file, message, line ? `${file}:${line}` : needle);
}

function expectNotContains({
  id,
  severity,
  category,
  file,
  needle,
  message,
}) {
  const source = read(file);
  if (!source) {
    fail(id, severity, category, file, `Missing file: ${file}`);
    return;
  }
  if (source.includes(needle)) {
    const line = lineNumber(source, needle);
    fail(
      id,
      severity,
      category,
      file,
      message,
      line ? `${file}:${line}` : `Forbidden marker: ${needle}`,
    );
    return;
  }
  pass(id, category, file, message, `Forbidden marker absent: ${needle}`);
}

function collectArbKeys(file) {
  const source = read(file);
  if (!source) return null;
  const keys = [];
  for (const line of source.split('\n')) {
    const match = line.match(/^  "([^"@][^"]*)":/);
    if (match) keys.push(match[1]);
  }
  return keys;
}

function auditRequiredFiles() {
  const required = [
    'CLAUDE.md',
    'docs/pos/ONE_WORKFLOW_PER_SCREEN_POS_PRIMARY_JOB_CONTRACT.md',
    'docs/manual_test/GLOBOS_POS_manual_verification_checklist_2026-05-19.md',
    'integration_test/full_multi_account_smoke_test.dart',
  ];

  for (const file of required) {
    if (exists(file)) {
      pass('MQA-00', 'audit inputs', file, 'Required audit input exists');
    } else {
      fail('MQA-00', 'HIGH', 'audit inputs', file, 'Required audit input missing');
    }
  }
}

function auditRoutingAndSurfaces() {
  expectContains({
    id: 'MQA-01',
    severity: 'CRITICAL',
    category: 'role routing',
    file: 'lib/core/utils/role_routes.dart',
    needle: 'final path = Uri.parse(location).path;',
    message: 'Route access checks normalize query-string deep links',
  });
  expectContains({
    id: 'MQA-01',
    severity: 'CRITICAL',
    category: 'role routing',
    file: 'lib/core/router/app_router.dart',
    needle: "path.startsWith('/payments/')",
    message: 'Payment detail deep links are routed through shared role guard',
  });

  const routedSurfaces = [
    ['lib/features/waiter/waiter_screen.dart', "Key('dashboard_root')"],
    ['lib/features/kitchen/kitchen_screen.dart', "Key('kitchen_root')"],
    ['lib/features/cashier/cashier_screen.dart', "Key('cashier_root')"],
    ['lib/features/admin/admin_screen.dart', "Key('admin_root')"],
    ['lib/features/payment/payment_detail_screen.dart', "Key('payment_detail_root')"],
    ['lib/features/qc/qc_check_screen.dart', "Key('qc_check_root')"],
    ['lib/features/qc/qc_review_screen.dart', "Key('qc_review_root')"],
    ['lib/features/photo_ops/photo_ops_screen.dart', "Key('photo_ops_root')"],
  ];

  for (const [file, key] of routedSurfaces) {
    expectContains({
      id: 'MQA-10',
      severity: 'MEDIUM',
      category: 'testable surfaces',
      file,
      needle: key,
      message: `${file} exposes a stable root key`,
    });
  }
}

function auditViewportAndScroll() {
  const expectations = [
    [
      'lib/main.dart',
      'scrollBehavior: const GlobosScrollBehavior()',
      'App installs shared desktop/mobile scroll behavior',
    ],
    [
      'lib/main.dart',
      'PointerDeviceKind.trackpad',
      'Trackpad drag scrolling is enabled',
    ],
    [
      'lib/core/ui/toast/toast_primitives_extended.dart',
      'ToastViewportScroll(padding: resolvedPadding',
      'Toast responsive body can scroll on short viewports',
    ],
    [
      'lib/core/ui/toast/toast_primitives_extended.dart',
      'fitToViewportWhenNarrow',
      'Toast responsive bodies keep an explicit override for viewport-fitted task screens',
    ],
    [
      'lib/core/ui/toast/toast_primitives_extended.dart',
      '_toastCompactPageMinHeight = 1600',
      'Narrow Toast responsive bodies reserve enough page height for touch scrolling',
    ],
    [
      'lib/features/photo_ops/photo_ops_screen.dart',
      'constraints.maxWidth < 1120',
      'Photo Ops compact dashboard removes the inner vertical ListView and uses the page scroll',
    ],
    [
      'lib/features/photo_ops/photo_ops_screen.dart',
      'ToastResponsiveScrollBody',
      'Photo Ops compact dashboard participates in the shared compact page scroll contract',
    ],
    [
      'lib/core/ui/toast/toast_primitives_extended.dart',
      'ToastResponsiveScrollBody',
      'Compact operational surfaces can promote the whole page to one scroll owner',
    ],
    [
      'lib/features/kitchen/kitchen_screen.dart',
      'scrollable: false',
      'Kitchen compact lanes delegate vertical scrolling to the parent lane stack',
    ],
    [
      'lib/features/admin/tabs/menu_tab.dart',
      'scrollable: false',
      'Menu compact category/item panels delegate vertical scrolling to the parent stack',
    ],
    [
      'lib/features/admin/tabs/staff_tab.dart',
      'final compact = viewport.maxWidth < 1120',
      'Staff compact directory moves the header and list under one page scroll',
    ],
    [
      'lib/features/admin/tabs/settings_tab.dart',
      'settingsPanel(scrollable: false)',
      'Settings compact panels do not create an inner vertical scroller',
    ],
    [
      'lib/features/admin/tabs/einvoice_tab.dart',
      'viewport.maxWidth < 1120',
      'E-invoice compact queue/detail stack uses one page scroll owner',
    ],
    [
      'lib/features/admin/tabs/reports_tab.dart',
      "Key('reports_compact_scroll')",
      'Reports compact analysis uses a parent scroll instead of overflowing',
    ],
    [
      'lib/features/admin/tabs/attendance_tab.dart',
      'compactAttendanceList',
      'Attendance compact rows render as page-owned cards instead of an inner table scroller',
    ],
    [
      'lib/features/inventory_purchase/inventory_purchase_screen.dart',
      'constraints.hasBoundedHeight',
      'Inventory page shell disables its inner viewport scroll when nested in the compact page scroll',
    ],
    [
      'lib/features/admin/tabs/reports_tab.dart',
      'compactSecondaryHeight: 520',
      'Reports compact secondary pane has enough height for operational signals',
    ],
    [
      'lib/core/ui/toast/toast_sidebar.dart',
      'viewport.shortestSide < 600',
      'Sidebar avoids desktop chrome on phone landscape',
    ],
    [
      'lib/features/admin/admin_screen.dart',
      'viewport.shortestSide >= 600',
      'Admin shell avoids desktop chrome on phone landscape',
    ],
  ];

  for (const [file, needle, message] of expectations) {
    expectContains({
      id: 'MQA-02',
      severity: 'HIGH',
      category: 'viewport usability',
      file,
      needle,
      message,
    });
  }
}

function auditPrimaryJobBoundaries() {
  const contract = read('docs/pos/ONE_WORKFLOW_PER_SCREEN_POS_PRIMARY_JOB_CONTRACT.md');
  if (!contract) {
    fail(
      'MQA-03',
      'HIGH',
      'primary job',
      'docs/pos/ONE_WORKFLOW_PER_SCREEN_POS_PRIMARY_JOB_CONTRACT.md',
      'Primary-job contract is missing',
    );
  } else {
    const gates = [
      'Primary Job Gate',
      'Supporting Actions Gate',
      'Separate Workflow Gate',
      'Secondary Detail Gate',
      'Role Boundary Gate',
      '3-Second Operator Gate',
      'Action Hierarchy Gate',
      'Workflow Safety Gate',
    ];
    for (const gate of gates) {
      if (contract.includes(gate)) {
        pass('MQA-03', 'primary job', 'docs/pos/ONE_WORKFLOW_PER_SCREEN_POS_PRIMARY_JOB_CONTRACT.md', `Gate documented: ${gate}`);
      } else {
        fail('MQA-03', 'HIGH', 'primary job', 'docs/pos/ONE_WORKFLOW_PER_SCREEN_POS_PRIMARY_JOB_CONTRACT.md', `Gate missing: ${gate}`);
      }
    }
  }

  const forbiddenAdminTableMarkers = [
    'OrderWorkspace(',
    'onProcessPayment:',
    'onCycleSentItemStatus:',
  ];
  for (const needle of forbiddenAdminTableMarkers) {
    expectNotContains({
      id: 'MQA-03',
      severity: 'HIGH',
      category: 'primary job',
      file: 'lib/features/admin/tabs/tables_tab.dart',
      needle,
      message: `Admin Tables must not expose operator workflow marker ${needle}`,
    });
  }

  expectContains({
    id: 'MQA-03',
    severity: 'HIGH',
    category: 'primary job',
    file: 'lib/features/payment/payment_detail_screen.dart',
    needle: 'class _SecondaryInfoPanel',
    message: 'Payment raw/secondary detail is hidden behind a secondary panel',
  });
}

function auditCrossAccountAndPaymentSafety() {
  const smokeExpectations = [
    ['waiter@globos.test', 'Waiter account is included in smoke chain'],
    ['kitchen@globos.test', 'Kitchen account is included in smoke chain'],
    ['cashier@globos.test', 'Cashier account is included in smoke chain'],
    ['office.store@globos.vn', 'Office boundary account is included in smoke chain'],
    ['EXPECTED_OUT_OF_SCOPE', 'Office boundary can be recorded without failing POS smoke'],
    ['String? capturedOrderId;', 'Smoke captures full waiter order id for kitchen/cashier handoff'],
  ];

  for (const [needle, message] of smokeExpectations) {
    expectContains({
      id: 'MQA-04',
      severity: 'CRITICAL',
      category: 'cross-account chain',
      file: 'integration_test/full_multi_account_smoke_test.dart',
      needle,
      message,
    });
  }

  const cashierMarkers = [
    'final method = await showDialog<String>(',
    '_CashierPaymentMethodDialog',
    'if (selectedMethod == null)',
    'await onProcess(selectedMethod!)',
    'PaymentProofModal(',
    'RedInvoiceModal(',
    "context.go('/payments/$paymentId')",
  ];
  for (const needle of cashierMarkers) {
    expectContains({
      id: 'MQA-05',
      severity: 'CRITICAL',
      category: 'payment safety',
      file: 'lib/features/cashier/cashier_screen.dart',
      needle,
      message: `Cashier payment flow keeps required marker: ${needle}`,
    });
  }

  const provider = read('lib/features/payment/payment_provider.dart');
  if (!provider) {
    fail('MQA-05', 'CRITICAL', 'payment safety', 'lib/features/payment/payment_provider.dart', 'Payment provider missing');
    return;
  }
  const selectOrderMatch = provider.match(/void selectOrder\(CashierOrder order\) \{([\s\S]*?)\n  \}/);
  if (!selectOrderMatch) {
    fail('MQA-05', 'CRITICAL', 'payment safety', 'lib/features/payment/payment_provider.dart', 'selectOrder body not found');
  } else if (selectOrderMatch[1].includes('processPayment') || selectOrderMatch[1].includes('paymentSuccess: true')) {
    fail('MQA-05', 'CRITICAL', 'payment safety', 'lib/features/payment/payment_provider.dart', 'Selecting a cashier order must not complete payment');
  } else {
    pass('MQA-05', 'payment safety', 'lib/features/payment/payment_provider.dart', 'Selecting a cashier order does not complete payment');
  }
}

function auditLiveSync() {
  const providerFiles = [
    'lib/features/kitchen/kitchen_provider.dart',
    'lib/features/payment/payment_provider.dart',
    'lib/features/table/table_provider.dart',
    'lib/features/order/order_provider.dart',
  ];
  for (const file of providerFiles) {
    expectContains({
      id: 'MQA-06',
      severity: 'HIGH',
      category: 'live sync scope',
      file,
      needle: 'LiveSyncScope.storeFilter(storeId)',
      message: `${file} uses active-store realtime filter`,
    });
  }

  expectContains({
    id: 'MQA-06',
    severity: 'HIGH',
    category: 'live sync scope',
    file: 'lib/features/payment/payment_detail_screen.dart',
    needle: "LiveSyncScope.entityFilter('id', widget.paymentId)",
    message: 'Payment detail realtime sync is entity scoped',
  });
}

function auditI18n() {
  const arbFiles = [
    'lib/l10n/app_en.arb',
    'lib/l10n/app_ko.arb',
    'lib/l10n/app_vi.arb',
  ];
  const keySets = new Map();

  for (const file of arbFiles) {
    const keys = collectArbKeys(file);
    if (!keys) {
      fail('MQA-07', 'MEDIUM', 'i18n', file, 'ARB file missing');
      continue;
    }
    const counts = new Map();
    for (const key of keys) counts.set(key, (counts.get(key) || 0) + 1);
    const duplicates = [...counts.entries()].filter(([, count]) => count > 1);
    if (duplicates.length) {
      fail('MQA-07', 'MEDIUM', 'i18n', file, `Duplicate ARB keys: ${duplicates.map(([key]) => key).join(', ')}`);
    } else {
      pass('MQA-07', 'i18n', file, 'ARB file has no duplicate top-level keys');
    }
    keySets.set(file, new Set(keys));
  }

  const english = keySets.get('lib/l10n/app_en.arb');
  if (english) {
    for (const file of arbFiles.slice(1)) {
      const keys = keySets.get(file);
      if (!keys) continue;
      const missing = [...english].filter((key) => !keys.has(key)).sort();
      const extra = [...keys].filter((key) => !english.has(key)).sort();
      if (missing.length || extra.length) {
        fail('MQA-07', 'MEDIUM', 'i18n', file, `ARB key mismatch. Missing=${missing.length}, extra=${extra.length}`);
      } else {
        pass('MQA-07', 'i18n', file, 'ARB key set matches English baseline');
      }
    }
  }

  expectContains({
    id: 'MQA-07',
    severity: 'MEDIUM',
    category: 'i18n',
    file: 'lib/main.dart',
    needle: 'await _warmUpWebKoreanFonts();',
    message: 'Web app warms Korean fonts before showing Flutter UI',
  });
}

function auditWebPhotoCompatibility() {
  const photoSurfaces = [
    'lib/features/cashier/payment_proof_modal.dart',
    'lib/features/admin/tabs/qc_tab.dart',
    'lib/features/super_admin/super_admin_screen.dart',
  ];
  for (const file of photoSurfaces) {
    for (const needle of ["import 'dart:io';", 'Image.file(', 'File(picked.path)']) {
      expectNotContains({
        id: 'MQA-08',
        severity: 'HIGH',
        category: 'web photo compatibility',
        file,
        needle,
        message: `${file} must avoid web-incompatible photo marker ${needle}`,
      });
    }
    expectContains({
      id: 'MQA-08',
      severity: 'HIGH',
      category: 'web photo compatibility',
      file,
      needle: 'Image.memory(',
      message: `${file} uses memory preview for selected photo`,
    });
  }

  expectContains({
    id: 'MQA-08',
    severity: 'HIGH',
    category: 'web photo compatibility',
    file: 'lib/core/services/payment_proof_service.dart',
    needle: 'await originalFile.readAsBytes()',
    message: 'Payment proof upload reads cross-platform XFile bytes',
  });
}

function auditNumericInput() {
  const libDartFiles = listFiles('lib', (file) => file.endsWith('.dart'));
  const forbiddenPatterns = [
    /double\.tryParse\([^)]*Controller\.text\.trim\(\)[^)]*\)/,
    /int\.tryParse\([^)]*Controller\.text\.trim\(\)[^)]*\)/,
  ];
  let forbiddenCount = 0;
  for (const file of libDartFiles) {
    const source = read(file);
    for (const pattern of forbiddenPatterns) {
      const match = source.match(pattern);
      if (match) {
        forbiddenCount += 1;
        fail('MQA-09', 'MEDIUM', 'numeric input', file, 'Controller numeric input should use comma-tolerant parser', match[0]);
      }
    }
  }
  if (forbiddenCount === 0) {
    pass('MQA-09', 'numeric input', 'lib/', 'No direct controller numeric parse patterns found');
  }

  expectContains({
    id: 'MQA-09',
    severity: 'MEDIUM',
    category: 'numeric input',
    file: 'lib/core/utils/number_input_utils.dart',
    needle: ".replaceAll(',', '')",
    message: 'Shared numeric input parser accepts thousands separators',
  });
}

function auditKitchenSignals() {
  const markers = [
    '_hasObservedKitchenSnapshot',
    '_triggerKitchenNewOrderAlert(order)',
    'SystemSound.play(SystemSoundType.alert)',
    'required this.visibleStatuses',
    'onPressed: isProcessing ? null : onItemAction',
  ];
  for (const needle of markers) {
    expectContains({
      id: 'MQA-04',
      severity: 'HIGH',
      category: 'kitchen handoff',
      file: 'lib/features/kitchen/kitchen_screen.dart',
      needle,
      message: `Kitchen handoff/operation marker present: ${needle}`,
    });
  }
}

function auditSmokeActivationCap() {
  expectContains({
    id: 'MQA-10',
    severity: 'MEDIUM',
    category: 'testable surfaces',
    file: 'integration_test/full_multi_account_smoke_test.dart',
    needle: 'const _maxTestDataInputsPerActivatableButton = 3;',
    message: 'Smoke test caps activatable test-data inputs per button',
  });
}

function run() {
  auditRequiredFiles();
  auditRoutingAndSurfaces();
  auditViewportAndScroll();
  auditPrimaryJobBoundaries();
  auditCrossAccountAndPaymentSafety();
  auditLiveSync();
  auditI18n();
  auditWebPhotoCompatibility();
  auditNumericInput();
  auditKitchenSignals();
  auditSmokeActivationCap();
}

function summarize() {
  const summary = {};
  for (const severity of severities) {
    summary[severity] = results.filter((result) => result.severity === severity).length;
  }
  const failCount = results.filter((result) => result.status === 'FAIL').length;
  const criticalHighFailCount = results.filter(
    (result) =>
      result.status === 'FAIL' &&
      (result.severity === 'CRITICAL' || result.severity === 'HIGH'),
  ).length;
  return { summary, failCount, criticalHighFailCount };
}

function printConsole() {
  const { summary, failCount, criticalHighFailCount } = summarize();
  console.log('Manual QA Regression Audit');
  console.log(`Root: ${root}`);
  console.log(`Results: ${results.length}`);
  console.log(
    `Severity totals: ${severities.map((severity) => `${severity}=${summary[severity]}`).join(', ')}`,
  );
  console.log(`Failures: ${failCount}`);
  console.log(`Blocking failures: ${criticalHighFailCount}`);
  console.log('');

  const failures = results.filter((result) => result.status === 'FAIL');
  if (failures.length) {
    console.log('Findings:');
    for (const result of failures) {
      console.log(
        `- [${result.severity}] ${result.id} ${result.category} ${result.file}: ${result.message}`,
      );
      if (result.evidence) console.log(`  evidence: ${result.evidence}`);
    }
  } else {
    console.log('No FAIL findings.');
  }
}

function markdownEscape(value) {
  return String(value || '').replace(/\|/g, '\\|').replace(/\n/g, '<br>');
}

function writeMarkdown() {
  if (!markdownPath) return;
  const { summary, failCount, criticalHighFailCount } = summarize();
  const lines = [
    '# Manual QA Regression Audit Report',
    '',
    'Generated: 2026-05-28',
    '',
    '## Summary',
    '',
    `- Total checks: ${results.length}`,
    `- Failures: ${failCount}`,
    `- Blocking failures: ${criticalHighFailCount}`,
    `- Severity totals: ${severities.map((severity) => `${severity}=${summary[severity]}`).join(', ')}`,
    '',
    '## Findings',
    '',
  ];

  const failures = results.filter((result) => result.status === 'FAIL');
  if (failures.length) {
    lines.push('| Severity | ID | Category | File | Finding | Evidence |');
    lines.push('|---|---|---|---|---|---|');
    for (const result of failures) {
      lines.push(
        `| ${markdownEscape(result.severity)} | ${markdownEscape(result.id)} | ${markdownEscape(result.category)} | ${markdownEscape(result.file)} | ${markdownEscape(result.message)} | ${markdownEscape(result.evidence)} |`,
      );
    }
  } else {
    lines.push('No FAIL findings.');
  }

  lines.push('', '## Confirmed Coverage', '');
  lines.push('| ID | Category | File | Evidence |');
  lines.push('|---|---|---|---|');
  for (const result of results.filter((item) => item.status === 'PASS')) {
    lines.push(
      `| ${markdownEscape(result.id)} | ${markdownEscape(result.category)} | ${markdownEscape(result.file)} | ${markdownEscape(result.evidence || result.message)} |`,
    );
  }

  fs.writeFileSync(markdownPath, `${lines.join('\n')}\n`);
}

run();
printConsole();
writeMarkdown();

const { criticalHighFailCount } = summarize();
process.exitCode = criticalHighFailCount > 0 ? 1 : 0;
