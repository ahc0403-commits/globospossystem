import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/services/qr_order_service.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';

class QrPaymentSummaryCard extends StatelessWidget {
  const QrPaymentSummaryCard({
    super.key,
    required this.summary,
    required this.languageCode,
    required this.isStale,
    required this.isLoading,
    required this.onRefresh,
  });

  final QrPaymentSummary? summary;
  final String languageCode;
  final bool isStale;
  final bool isLoading;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final index = switch (languageCode) {
      'ko' => 0,
      'vi' => 1,
      _ => 2,
    };
    String copy(List<String> values) => values[index];
    String money(double value) =>
        '${NumberFormat('#,###', 'vi_VN').format(value)} ₫';
    final title = copy([
      '현재 결제할 금액',
      'Số tiền cần thanh toán',
      'Amount due now',
    ]);
    return ToastWorkSurface(
      key: const Key('qr_payment_summary'),
      padding: const EdgeInsets.all(ToastSpacingTokens.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              summary == null ? '—' : money(summary!.remainingDue),
              key: const Key('qr_remaining_due'),
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                color: ToastColorTokens.accentStrong,
              ),
            ),
          ),
          if (summary != null && summary!.paidTotal > 0) ...[
            const SizedBox(height: 8),
            Text(
              '${copy(['주문 총액', 'Tổng đơn', 'Order total'])}: ${money(summary!.totalAmount)}',
            ),
            Text(
              '${copy(['기결제 금액', 'Đã thanh toán', 'Already paid'])}: ${money(summary!.paidTotal)}',
            ),
          ],
          const SizedBox(height: 8),
          Text(
            summary == null && isStale
                ? copy([
                    '금액을 불러오지 못했습니다. 다시 확인해 주세요.',
                    'Không tải được số tiền. Vui lòng cập nhật lại.',
                    'Unable to load the amount. Please refresh.',
                  ])
                : summary == null
                ? copy([
                    '결제 금액을 확인하고 있습니다.',
                    'Đang kiểm tra số tiền thanh toán.',
                    'Checking the amount due.',
                  ])
                : isStale
                ? copy([
                    '마지막 확인 금액입니다. 최신 금액을 다시 확인해 주세요.',
                    'Số tiền được xác nhận gần nhất. Vui lòng cập nhật.',
                    'Last confirmed amount. Refresh for the latest amount.',
                  ])
                : copy([
                    '접수된 전체 주문 기준 · 적용 세금 및 서비스료 포함',
                    'Toàn bộ món đã nhận · Gồm thuế và phí phục vụ áp dụng',
                    'All accepted orders · Includes applicable tax and service charge',
                  ]),
            key: const Key('qr_payment_summary_status'),
            style: const TextStyle(
              fontSize: 12,
              color: ToastColorTokens.textSecondary,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const Key('qr_payment_summary_refresh'),
              onPressed: isLoading ? null : onRefresh,
              icon: isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh, size: 18),
              label: Text(
                copy(['금액 새로고침', 'Cập nhật số tiền', 'Refresh amount']),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
