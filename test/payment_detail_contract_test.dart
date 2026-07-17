import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/role_routes.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('payment detail route is mounted in the tracked app router', () {
    final router = readRepoFile('lib/core/router/app_router.dart');
    final roleRoutes = readRepoFile('lib/core/utils/role_routes.dart');

    expect(
      router,
      contains("import '../../features/payment/payment_detail_screen.dart';"),
    );
    expect(router, contains("path: '/payments/:paymentId'"));
    expect(router, contains('PaymentDetailScreen('));
    expect(router, contains("state.pathParameters['paymentId']"));

    expect(roleRoutes, contains("path.startsWith('/payments/')"));
    expect(canAccessRouteForRole('cashier', '/payments/payment-id'), isTrue);
    expect(canAccessRouteForRole('admin', '/payments/payment-id'), isTrue);
  });

  test(
    'cashier success flow hands off to payment detail after tracked post-payment steps',
    () {
      final cashier = readRepoFile('lib/features/cashier/cashier_screen.dart');

      expect(cashier, contains("final paymentId = payment?['id']"));
      expect(cashier, contains('PaymentProofModal('));
      expect(cashier, contains('RedInvoiceModal('));
      expect(cashier, contains("context.go('/payments/\$paymentId')"));
    },
  );

  test('payment detail screen records append-only refund/void adjustments', () {
    final screen = readRepoFile(
      'lib/features/payment/payment_detail_screen.dart',
    );
    final paymentService = readRepoFile(
      'lib/core/services/payment_service.dart',
    );
    final einvoiceService = readRepoFile(
      'lib/core/services/einvoice_service.dart',
    );

    expect(screen, contains('paymentService.fetchPaymentDetail('));
    expect(screen, contains('paymentService.recordPaymentAdjustment('));
    expect(screen, contains('storeId: storeId'));
    expect(screen, contains('_detailFuture = _loadDetail();'));
    expect(
      screen,
      contains("LiveSyncScope.entityFilter('id', widget.paymentId)"),
    );
    expect(screen, contains("LiveSyncScope.entityFilter('order_id', orderId)"));
    expect(screen, contains('Timer.periodic(_autoRefreshInterval'));
    expect(screen, contains("table: 'payment_adjustments'"));
    expect(screen, contains("table: 'meinvoice_jobs'"));
    expect(
      screen,
      contains("LiveSyncScope.entityFilter('payment_id', widget.paymentId)"),
    );
    expect(screen, contains('Map<String, dynamic>? _lastDetail'));
    expect(screen, contains('bool _refreshInFlight = false'));
    expect(screen, contains('bool _adjustmentInFlight = false'));
    expect(screen, contains('if (detail != null || _lastDetail == null)'));
    expect(screen, contains('Future<void> _refreshDetailSilently() async'));
    expect(screen, contains('unawaited(_refreshDetailSilently())'));
    expect(
      screen,
      contains('final currentDetail = snapshot.data ?? _lastDetail'),
    );
    expect(
      screen,
      contains(
        'snapshot.connectionState == ConnectionState.waiting &&\n'
        '                currentDetail == null',
      ),
    );
    expect(screen, contains('if (_realtimeConnected)'));
    expect(screen, contains('_pollTimer?.cancel()'));
    final realtimeRefreshBody = RegExp(
      r'void _refreshDetailFromRealtime\(\) \{(?<body>[\s\S]*?)\n  \}',
    ).firstMatch(screen)?.namedGroup('body');
    expect(realtimeRefreshBody, isNotNull);
    expect(realtimeRefreshBody, isNot(contains('_detailFuture = future')));
    expect(realtimeRefreshBody, isNot(contains('setState(')));
    expect(
      screen,
      contains("import '../../core/i18n/locale_extensions.dart';"),
    );
    expect(screen, contains('context.l10n'));
    expect(screen, contains('l10n.paymentDetailPaymentSummary'));
    expect(screen, contains('l10n.paymentDetailOrderSummary'));
    expect(screen, contains('l10n.paymentDetailEInvoiceSummary'));
    expect(screen, contains('l10n.paymentDetailProofSummary'));
    expect(screen, contains('l10n.paymentDetailOperationalSnapshot'));
    expect(screen, contains('l10n.paymentDetailFinishPayment'));
    expect(screen, contains('l10n.paymentDetailAdjustmentSignal'));
    expect(screen, contains('l10n.paymentDetailRemainingAmount'));
    expect(screen, contains('l10n.paymentDetailAdjustmentSummary'));
    expect(screen, contains('l10n.paymentDetailAdjustmentRefunded'));
    expect(screen, contains('l10n.paymentDetailAdjustmentVoided'));
    expect(screen, contains('l10n.paymentDetailRemainingAdjustable'));
    expect(screen, contains('l10n.paymentDetailAdjustmentCount'));
    expect(screen, contains('l10n.paymentDetailLastAdjustmentType'));
    expect(screen, contains('l10n.paymentDetailLastAdjustmentReason'));
    expect(screen, contains('l10n.paymentDetailLastAdjustmentRecorded'));
    expect(screen, contains("Key('payment_detail_refund_payment')"));
    expect(screen, contains("Key('payment_detail_void_payment')"));
    expect(screen, contains("Key('payment_adjustment_amount_input')"));
    expect(screen, contains("Key('payment_adjustment_reason_input')"));
    expect(screen, contains("adjustmentType: 'refund'"));
    expect(screen, contains("adjustmentType: 'void'"));
    expect(screen, contains('l10n.paymentDetailRefundPayment'));
    expect(screen, contains('l10n.paymentDetailVoidPayment'));
    expect(screen, contains('l10n.paymentDetailAvailableAmount'));
    expect(screen, contains('l10n.paymentDetailAdjustmentAmount'));
    expect(screen, contains('l10n.paymentDetailAdjustmentReason'));
    expect(screen, contains('l10n.paymentDetailReasonRequired'));
    expect(screen, contains('l10n.paymentDetailAdjustmentAmountLimit'));
    expect(screen, contains('l10n.paymentDetailRefundRecorded'));
    expect(screen, contains('l10n.paymentDetailVoidRecorded'));
    expect(screen, contains('l10n.paymentDetailRefundExceedsRemaining'));
    expect(screen, contains('l10n.paymentDetailVoidMustMatchPayment'));
    expect(screen, contains('l10n.paymentDetailRefundAfterPartial'));
    expect(screen, contains('l10n.paymentDetailServiceAdjustmentNotAllowed'));
    expect(screen, contains('l10n.paymentDetailAdjustmentForbidden'));
    expect(screen, contains('l10n.paymentDetailAdjustmentFailed'));
    expect(screen, contains('l10n.paymentDetailPortalPendingTitle'));
    expect(screen, contains('l10n.paymentDetailPortalPendingBody'));
    expect(screen, contains('l10n.paymentDetailPortalPendingFooter'));
    expect(screen, contains('l10n.paymentDetailPortalPendingFooterWithAge'));
    expect(screen, contains('l10n.paymentDetailOpenPortal'));
    expect(screen, contains('l10n.paymentDetailJobStatus'));
    expect(screen, contains('l10n.paymentDetailRefId'));
    expect(screen, contains('l10n.paymentDetailSid'));
    expect(screen, contains("import 'package:go_router/go_router.dart';"));
    expect(
      screen,
      contains("key: const Key('payment_detail_close_to_cashier')"),
    );
    expect(screen, contains("key: const Key('payment_detail_finish_payment')"));
    expect(screen, contains("context.go('/cashier')"));
    expect(screen, contains('class _SecondaryInfoPanel'));
    expect(screen, contains('initiallyExpanded: false'));
    expect(screen, contains('ExpansionTile('));
    expect(screen, contains("Key('payment_detail_print_receipt')"));
    expect(screen, contains('ReceiptBuilder.buildPaymentReceipt'));
    expect(screen, contains('printerProvider'));
    expect(screen, contains('_receiptItems(order'));

    expect(
      paymentService,
      contains('Future<Map<String, dynamic>?> fetchPaymentDetail('),
    );
    expect(paymentService, contains('String? storeId'));
    expect(paymentService, contains(".eq('restaurant_id', storeId)"));
    expect(paymentService, contains(".from('payment_adjustments')"));
    expect(paymentService, contains(".from('meinvoice_jobs')"));
    expect(paymentService, contains("'adjustments': adjustments"));
    expect(
      paymentService,
      contains('Future<Map<String, dynamic>> recordPaymentAdjustment('),
    );
    expect(paymentService, contains("'record_payment_adjustment'"));
    expect(paymentService, contains("'p_payment_id': paymentId"));
    expect(paymentService, contains("'p_adjustment_type': adjustmentType"));
    expect(paymentService, contains("'p_reason': reason"));
    expect(paymentService, contains('restaurant_name'));
    expect(paymentService, contains('label, unit_price, quantity'));
    expect(einvoiceService, isNot(contains('resendInvoiceEmail')));
    expect(screen, isNot(contains('requestRedInvoice(')));
    expect(screen, isNot(contains('resendInvoiceEmail')));
    expect(screen, isNot(contains('inventory_purchase')));

    final koL10n = readRepoFile('lib/l10n/app_ko.arb');
    expect(koL10n, contains('"paymentDetailFinishPayment": "결제 종료"'));
    expect(koL10n, contains('결제 {paymentId} 감사 상세'));
  });
}
