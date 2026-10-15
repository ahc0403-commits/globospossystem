import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:globos_pos_system/features/procurement/procurement_workspace.dart';
import 'package:globos_pos_system/features/procurement/procurement_process_labels.dart';

void main() {
  for (final locale in ['ko', 'en', 'vi']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets(
        'manager approval layout $locale at $width, stock is read on demand',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          await tester.binding.setSurfaceSize(Size(width, 1000));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final queries = <Map<String, dynamic>>[];
          String copy(String key) => procurementProcessLabel(key, locale);
          await tester.pumpWidget(
            MaterialApp(
              locale: Locale(locale),
              supportedLocales: [Locale(locale)],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 1000),
                  textScaler: TextScaler.linear(width < 600 ? 1.5 : 1),
                ),
                child: ProcurementWorkspacePage(
                  approvalView: true,
                  load: () async => {},
                  loadPage: (q) async {
                    queries.add({...q});
                    if (q['catalog_only'] == true) {
                      return {
                        'products': [
                          {
                            'id': 'product',
                            'name': 'Rice / Gạo',
                            'product_code': 'RAW-001',
                            'current_stock': 5,
                            'base_unit': 'kg',
                            'stock_updated_at': '2026-10-15T01:00:00Z',
                          },
                        ],
                        'catalog_has_more': false,
                      };
                    }
                    return {
                      'contract_version': 2,
                      'store_id': 'store',
                      'enabled': true,
                      'actor': {
                        'system': 'pos',
                        'subject_id': 'manager',
                        'can_store_approve': true,
                        'can_create': true,
                        'can_view_prices': true,
                      },
                      'request_counts': {
                        'pending': 1,
                        'approved': 3,
                        'returned': 1,
                        'cancelled': 1,
                      },
                      'requests': [
                        {
                          'id': 'pr',
                          'request_no': 'PR-LATEST',
                          'status': 'submitted',
                          'requester_name': 'Registered PR team',
                          'requester_role': 'inventory_orderer',
                          'reason': 'Weekly operating stock request',
                          'line_count': 22,
                          'created_at': '2026-10-15',
                          'requested_delivery_date': '2026-10-16',
                          'allowed_actions': [],
                        },
                      ],
                      'products': [],
                      'supplier_items': [],
                      'orders': [],
                    };
                  },
                  execute: (a, b, c, d, e) async =>
                      throw StateError('Read-only test'),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(queries.length, 1);
          expect(queries.single['request_sort'], 'created');
          expect(queries.single['request_summary_only'], true);
          expect(find.text('${copy('approval_pending')} (1)'), findsOneWidget);
          expect(find.text('${copy('approval_approved')} (3)'), findsOneWidget);
          expect(find.text('${copy('approval_returned')} (1)'), findsOneWidget);
          expect(find.text(copy('operatingMetrics')), findsNothing);
          expect(find.text(copy('legacyReview')), findsNothing);
          expect(find.text('My approvals'), findsNothing);
          expect(find.text('내 결재 대기'), findsNothing);
          await tester.scrollUntilVisible(
            find.text('PR-LATEST'),
            250,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.textContaining('Registered PR team'), findsOneWidget);
          expect(
            find.textContaining('Weekly operating stock request'),
            findsOneWidget,
          );
          expect(
            find.widgetWithText(OutlinedButton, copy('viewDetails')),
            findsOneWidget,
          );
          final stock = find.byKey(const Key('procurement_stock_lookup'));
          await tester.ensureVisible(stock);
          if (width >= 1100) {
            final create = find.byKey(const Key('procurement_create_request'));
            expect(
              tester.getTopLeft(stock).dx,
              lessThan(tester.getTopLeft(create).dx),
            );
            expect(
              (tester.getTopLeft(stock).dy - tester.getTopLeft(create).dy)
                  .abs(),
              lessThan(5),
            );
          }
          await tester.tap(stock);
          await tester.pumpAndSettle();
          expect(queries.length, 2);
          expect(queries.last['catalog_only'], true);
          expect(find.textContaining('RAW-001'), findsOneWidget);
          expect(find.textContaining('5 kg'), findsOneWidget);
          await tester.tap(find.text(copy('close')));
          await tester.pumpAndSettle();
          expect(
            queries.length,
            2,
            reason: 'Closing stock does not reload the PR list',
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
