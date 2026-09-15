import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:flutter_test/flutter_test.dart';

const _contractPath = 'docs/app_language_surface_contract_20260915.json';

void main() {
  test('every active route has an assigned language policy', () {
    final contract = jsonDecode(File(_contractPath).readAsStringSync()) as Map;
    final configuredRoutes = (contract['routes'] as List)
        .cast<Map>()
        .map((entry) => entry['path'] as String)
        .toSet();
    final routeSource = File(
      'lib/core/router/app_router.dart',
    ).readAsStringSync();
    final activeRoutes = RegExp(
      r"path:\s*'([^']+)'",
    ).allMatches(routeSource).map((match) => match.group(1)!).toSet();

    expect(configuredRoutes, activeRoutes);
    for (final entry in (contract['routes'] as List).cast<Map>()) {
      expect(entry['policy'], isNot(anyOf(isNull, '', 'unassigned')));
    }
  });

  test('screen text literals require localization or an explicit policy', () {
    final contract = jsonDecode(File(_contractPath).readAsStringSync()) as Map;
    final fixedPolicySources = (contract['fixed_language_policies'] as List)
        .cast<Map>()
        .expand((policy) => (policy['sources'] as List).cast<String>())
        .toSet();
    final findings = <String>[];
    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))
            .where((file) => !file.path.contains('/l10n/app_localizations'))) {
      final path = file.path.replaceFirst('${Directory.current.path}/', '');
      if (fixedPolicySources.contains(path)) continue;
      final parseResult = parseString(
        content: file.readAsStringSync(),
        path: path,
        throwIfDiagnostics: false,
      );
      parseResult.unit.accept(
        _UiLiteralVisitor(path, findings, parseResult.lineInfo),
      );
    }

    expect(
      findings,
      isEmpty,
      reason:
          'Move user-facing copy to AppLocalizations, or document a narrow fixed-language/output policy.\n${findings.join('\n')}',
    );
  });

  test('menu read and edit paths preserve exact registered fields', () {
    final dartSources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .map((file) => file.readAsStringSync())
        .join('\n');

    expect(
      dartSources,
      isNot(contains('menu_items(name, name_vi, name_en')),
      reason: 'Nested menu reads must request name_ko explicitly.',
    );
    expect(
      dartSources,
      isNot(contains("nameVi.isEmpty ? name : nameVi")),
      reason: 'A missing selected-language field must not fall back silently.',
    );
    expect(
      dartSources,
      isNot(contains("nameEn.isEmpty ? name : nameEn")),
      reason: 'A missing selected-language field must not fall back silently.',
    );
    expect(
      dartSources,
      isNot(contains('fallbackKeys')),
      reason:
          'Menu names must use the typed exact-language resolver instead of ordered fallback keys.',
    );
    expect(
      dartSources,
      isNot(contains("nameKo: '메뉴'")),
      reason:
          'Synthetic Korean values must not masquerade as registered names.',
    );
    expect(
      dartSources,
      isNot(contains("nameVi: 'Món'")),
      reason:
          'Synthetic Vietnamese values must not masquerade as registered names.',
    );
    expect(
      dartSources,
      isNot(contains("nameEn: 'Item'")),
      reason:
          'Synthetic English values must not masquerade as registered names.',
    );
    final menuTab = File(
      'lib/features/admin/tabs/menu_tab.dart',
    ).readAsStringSync();
    expect(menuTab, isNot(contains("?? originalNameKo")));
  });
}

class _UiLiteralVisitor extends RecursiveAstVisitor<void> {
  _UiLiteralVisitor(this.path, this.findings, this.lineInfo);

  final String path;
  final List<String> findings;
  final LineInfo lineInfo;

  static const _namedUiArguments = {
    'labelText',
    'hintText',
    'helperText',
    'tooltip',
    'semanticsLabel',
  };

  static const _providerOwnedInventoryCopy = {
    'recommendationRuntimeStateLabel',
    'latestSnapshotStateLabel',
    'purchaseOrderCreationReadinessLabel',
    'approvalHandoffReadinessLabel',
    'receivingReadinessLabel',
    'selectedPurchaseOrderRuntimeLabel',
    'nextOperatorAction',
    'operatingNarrative',
    'handoffTarget',
    'priorityBucket',
    'staleLabel',
    'nextAction',
    'operatorReason',
    'mismatchIndicatorLabel',
    'narrative',
    'blockedReasonCluster',
    'nextFollowUpTarget',
    'lastAttemptLabel',
    'retryDisciplineLabel',
    'unknownOutcomeLabel',
    'followUpGuidanceLabel',
    'operationalPhaseLabel',
    'operationalPhaseNarrative',
    'approvalNarrative',
    'receivingNarrative',
    'receiptVisibilityStatusLabel',
    'receiptVisibilityNarrative',
    'readyStateLabel',
    'blockedStateLabel',
    'staleStateLabel',
    'nextBestOperatorAction',
    'receivedLineSummaryLabel',
    'remainingLineSummaryLabel',
    'statusLabel',
    'riskSummary',
  };

  static const _allowed = <String, Set<String>>{
    'lib/core/services/table_qr_export_service.dart': {'TABLE'},
    'lib/features/store_setup/widgets/table_bulk_editor.dart': {'G'},
    'lib/features/photo_inventory/photo_inventory_screen.dart': {
      'ea',
      'box',
      'g',
      'ml',
    },
    'lib/features/inventory_purchase/inventory_purchase_screen.dart': {
      'g',
      'ml',
      'ea',
      'Excel',
    },
    'lib/features/admin/tabs/inventory_tab.dart': {'g', 'ml', 'ea'},
    'lib/features/auth/login_screen.dart': {'G', 'GLOBOS Operations'},
    'lib/features/digital_receipt/digital_receipt_screen.dart': {'MST: '},
    'lib/features/payment/einvoice_status_badge.dart': {'MISA'},
    'lib/features/admin/tabs/menu_tab.dart': {'QR', 'Excel (.xlsx)'},
    'lib/features/cashier/cashier_screen.dart': {
      'QR',
      'WOORI BANK · 100202042976 · AHN HYOCHANG',
    },
    'lib/features/qr_order/qr_order_screen.dart': {
      'Tiếng Việt',
      '한국어',
      'English',
    },
    'lib/features/inventory_purchase/inventory_order_workflow_screen.dart': {
      'PDF: ',
      'Excel',
      'Photos',
      'Statement',
    },
    'lib/features/inventory_purchase/inventory_purchase_document_service.dart':
        {'QSC Manager · '},
    'lib/features/direct_order/direct_order_cashier_screen.dart': {
      'https://...',
    },
  };

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final typeName = node.constructorName.type.toSource();
    if ((typeName == 'Text' ||
            typeName == 'SelectableText' ||
            typeName == 'pw.Text') &&
        node.argumentList.arguments.isNotEmpty) {
      final first = node.argumentList.arguments.first;
      _checkUiExpression(first, node.offset);
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitNamedExpression(NamedExpression node) {
    if (_namedUiArguments.contains(node.name.label.name)) {
      _checkUiExpression(node.expression, node.offset);
    }
    super.visitNamedExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    if ((name == 'Text' || name == 'SelectableText') &&
        node.argumentList.arguments.isNotEmpty) {
      _checkUiExpression(node.argumentList.arguments.first, node.offset);
    }
    if (name == '_buildIngredientMetaChip' ||
        name == 'showErrorToast' ||
        name == 'showSuccessToast' ||
        name == 'showInfoToast' ||
        name == 'showWarningToast') {
      for (final argument
          in node.argumentList.arguments.whereType<Expression>().where(
            (argument) => argument is! NamedExpression,
          )) {
        _checkUiExpression(argument, argument.offset);
      }
    }
    if (name == '_buildInventoryRuntimePathCard' ||
        name == '_buildInventoryMutationReadinessCard') {
      for (final argument
          in node.argumentList.arguments.whereType<NamedExpression>().where(
            (argument) => const {
              'title',
              'statusLabel',
              'narrative',
            }.contains(argument.name.label.name),
          )) {
        _checkUiExpression(argument.expression, argument.offset);
      }
    }
    super.visitMethodInvocation(node);
  }

  void _checkUiExpression(Expression expression, int offset) {
    if (path == 'lib/features/admin/tabs/inventory_tab.dart') {
      final source = expression.toSource();
      final containsProviderCopy = _providerOwnedInventoryCopy.any(
        (member) => source.contains('.$member'),
      );
      if (containsProviderCopy && !source.contains('_inventoryRuntimeText')) {
        final line = lineInfo.getLocation(offset).lineNumber;
        findings.add('$path:$line: $source');
      }
    }
    if (expression is StringLiteral) {
      _check(expression, offset);
    } else if (expression is ConditionalExpression) {
      _checkUiExpression(expression.thenExpression, offset);
      _checkUiExpression(expression.elseExpression, offset);
    } else if (expression is ParenthesizedExpression) {
      _checkUiExpression(expression.expression, offset);
    }
  }

  void _check(StringLiteral literal, int offset) {
    for (final text in _staticSegments(literal)) {
      final normalized = text.trimRight();
      if (!RegExp(r'[A-Za-zÀ-ỹ가-힣]{2}').hasMatch(normalized)) continue;
      if (RegExp(
        r'^[\s·+×#:/().,%\-\d]*(?:VND|VAT|MST|PDF)[\s·+×#:/().,%\-\d]*$',
      ).hasMatch(normalized)) {
        continue;
      }
      if (_allowed[path]?.contains(normalized) ?? false) continue;
      final line = lineInfo.getLocation(offset).lineNumber;
      findings.add('$path:$line: ${literal.toSource()}');
    }
  }

  Iterable<String> _staticSegments(StringLiteral literal) sync* {
    if (literal is SimpleStringLiteral) {
      yield literal.value;
    } else if (literal is StringInterpolation) {
      for (final element in literal.elements.whereType<InterpolationString>()) {
        yield element.value;
      }
    } else if (literal is AdjacentStrings) {
      for (final child in literal.strings) {
        yield* _staticSegments(child);
      }
    }
  }
}
