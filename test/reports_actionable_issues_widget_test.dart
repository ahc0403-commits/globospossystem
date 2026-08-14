import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/admin/tabs/reports_tab.dart';
import 'package:globos_pos_system/features/report/report_provider.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

ReportSummary _summary() => ReportSummary(
  dineInRevenue: 1200000,
  deliveryRevenue: 0,
  serviceTotal: 0,
  totalRevenue: 1200000,
  totalOrders: 7,
  completedOrders: 7,
  paidOrders: 7,
  openOrders: 0,
  dailyBreakdown: const [],
  missingProofPhotosCount: 1,
  failedEinvoiceJobsCount: 1,
  proofCompletePercent: 80,
  missingProofIssues: [
    MissingProofIssue(
      paymentId: 'payment-1',
      orderId: 'order-1',
      amount: 100000,
      method: 'BANK_TRANSFER',
      createdAt: DateTime(2026, 8, 14, 12),
    ),
  ],
  einvoiceReviewIssues: [
    EinvoiceReviewIssue(
      jobId: 'job-1',
      orderId: 'order-1',
      paymentId: 'payment-1',
      status: 'failed',
      detail: 'buyer tax code invalid',
      createdAt: DateTime(2026, 8, 14, 12),
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final size in const [Size(390, 844), Size(1200, 900)]) {
    testWidgets('actionable report issues are clear and clickable at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var missingClicks = 0;
      var invoiceClicks = 0;

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ko'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: size.width > 700 ? 520 : size.width - 24,
                child: ReportsIssuePanel(
                  summary: _summary(),
                  startDate: DateTime(2026, 8, 8),
                  endDate: DateTime(2026, 8, 14),
                  onMissingProofPressed: () => missingClicks += 1,
                  onEinvoicePressed: () => invoiceClicks += 1,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('적용 기간 08/08/2026 – 14/08/2026'), findsOneWidget);
      expect(find.textContaining('1건 누락'), findsOneWidget);
      expect(find.textContaining('완료율 80%'), findsOneWidget);
      expect(find.text('MISA 전자세금계산서 확인 필요'), findsOneWidget);

      await tester.tap(find.byKey(const Key('reports_missing_proof_issue')));
      await tester.tap(find.byKey(const Key('reports_einvoice_issue')));
      expect(missingClicks, 1);
      expect(invoiceClicks, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
