import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('super admin quality tabs keep scrollable bottom content reachable', () {
    final source = readRepoFile(
      'lib/features/super_admin/super_admin_screen.dart',
    );

    expect(source, contains('const _superAdminScrollPadding'));
    expect(source, contains('const _superAdminScrollPhysics'));
    expect(source, contains("Key('super_admin_qc_templates_scroll')"));
    expect(source, contains("Key('super_admin_qc_overview_scroll')"));

    final qualityTemplatesScroll = RegExp(
      r"Key\('super_admin_qc_templates_scroll'\)[\s\S]*?"
      r'padding: _superAdminScrollPadding',
    );
    final qualityOverviewScroll = RegExp(
      r"Key\('super_admin_qc_overview_scroll'\)[\s\S]*?"
      r'padding: _superAdminScrollPadding',
    );

    expect(source, matches(qualityTemplatesScroll));
    expect(source, matches(qualityOverviewScroll));
  });

  test('super admin sibling tabs use the same bounded scroll behavior', () {
    final source = readRepoFile(
      'lib/features/super_admin/super_admin_screen.dart',
    );

    expect(
      RegExp(r'primary: false').allMatches(source).length,
      greaterThanOrEqualTo(6),
    );
    expect(
      RegExp(r'physics: _superAdminScrollPhysics').allMatches(source).length,
      greaterThanOrEqualTo(6),
    );
    expect(
      RegExp(r'padding: _superAdminScrollPadding').allMatches(source).length,
      greaterThanOrEqualTo(6),
    );
  });

  test('super admin all reports chart keeps axis labels readable', () {
    final source = readRepoFile(
      'lib/features/super_admin/super_admin_screen.dart',
    );

    expect(source, contains("Key('super_admin_reports_scroll')"));
    expect(source, contains("Key('super_admin_reports_table_region')"));
    expect(source, contains('final tableHeight = rawTableHeight.clamp'));
    expect(source, contains('String _formatAxisCurrency(double value)'));
    expect(source, contains('String _shortAxisLabel(String value)'));
    expect(source, contains('reservedSize: 62'));
    expect(source, contains('reservedSize: 42'));
    expect(source, contains('drawVerticalLine: false'));
    expect(source, contains('horizontalInterval: interval'));
    expect(source, contains('_formatAxisCurrency(value)'));
    expect(source, contains('_shortAxisLabel(rows[index].name)'));
    expect(source, contains('maxLines: 2'));
    expect(source, contains('overflow: TextOverflow.ellipsis'));
  });

  test('super admin action headers avoid narrow Row overflow', () {
    final source = readRepoFile(
      'lib/features/super_admin/super_admin_screen.dart',
    );

    expect(source, contains('constraints.maxWidth < 520'));
    expect(source, contains('constraints.maxWidth < 560'));
    expect(source, contains('Wrap('));
    expect(source, contains('alignment: WrapAlignment.end'));
    expect(source, contains('SingleChildScrollView('));
    expect(source, contains('scrollDirection: Axis.horizontal'));
    expect(source, contains('overflow: TextOverflow.ellipsis'));
  });
}
