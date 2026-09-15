import 'dart:io';
import 'dart:ui';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/inventory/inventory_runtime_localization.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

void main() {
  test('provider-owned inventory workflow copy has a selected-locale path', () {
    final source = File(
      'lib/features/inventory/inventory_provider.dart',
    ).readAsStringSync();
    final start = source.indexOf('enum InventoryPurchaseRuntimeResultKind');
    final end = source.indexOf(
      'final inventoryPurchaseReceivingRuntimeProvider',
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));

    final collector = _RuntimeStringCollector(start, end);
    parseString(content: source).unit.accept(collector);
    expect(collector.values, isNotEmpty);

    for (final locale in const [Locale('ko'), Locale('vi')]) {
      final l10n = lookupAppLocalizations(locale);
      final missing = <String>[];
      for (final raw in collector.values) {
        final localized = localizeInventoryRuntimeText(l10n, raw);
        expect(localized, isNot(raw), reason: '${locale.languageCode}: $raw');
        if (localized == l10n.inventoryRuntimeTranslationMissing) {
          missing.add(raw);
        }
      }
      expect(missing, isEmpty, reason: locale.languageCode);
    }
  });

  test('server status codes are readable in every supported language', () {
    const statuses = [
      'submitted',
      'office_returned',
      'office_approved',
      'ordered',
      'partially_received',
      'received',
      'office_rejected',
      'cancelled',
      'draft',
      'confirmed',
    ];

    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      for (final status in statuses) {
        final localized = localizeInventoryRuntimeText(l10n, status);
        expect(
          localized,
          isNot(status),
          reason: '${locale.languageCode}: $status',
        );
      }
    }
  });
}

class _RuntimeStringCollector extends RecursiveAstVisitor<void> {
  _RuntimeStringCollector(this.start, this.end);

  final int start;
  final int end;
  final Set<String> values = {};

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    if (node.offset < start || node.end > end) return;
    final value = node.value.trim();
    if (value.contains(' ') && RegExp(r'[A-Za-z]{2}').hasMatch(value)) {
      values.add(value);
    }
    super.visitSimpleStringLiteral(node);
  }
}
