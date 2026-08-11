import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../auth/auth_provider.dart';
import 'customer_display_provider.dart';

class CustomerDisplayScreen extends ConsumerStatefulWidget {
  const CustomerDisplayScreen({super.key});

  @override
  ConsumerState<CustomerDisplayScreen> createState() =>
      _CustomerDisplayScreenState();
}

class _CustomerDisplayScreenState extends ConsumerState<CustomerDisplayScreen> {
  String? _startedStoreId;

  void _ensureStarted(String? storeId) {
    if (storeId == null || storeId == _startedStoreId) return;
    _startedStoreId = storeId;
    Future.microtask(
      () => ref.read(customerDisplayProvider.notifier).start(storeId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final display = ref.watch(customerDisplayProvider);
    _ensureStarted(auth.storeId);

    if (display.isLoading && display.snapshot == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (display.error != null && display.snapshot == null) {
      return Localizations.override(
        context: context,
        locale: const Locale('vi'),
        child: Scaffold(
          body: _CustomerDisplayError(
            onRetry: () => ref.read(customerDisplayProvider.notifier).retry(),
          ),
        ),
      );
    }

    final snapshot = display.snapshot;
    return Localizations.override(
      context: context,
      locale: const Locale('vi'),
      child: Scaffold(
        key: const Key('customer_display_root'),
        backgroundColor: const Color(0xFFF4F6F8),
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 120),
            child: snapshot == null
                ? _CustomerDisplayIdle(
                    key: const Key('customer_display_idle'),
                    onLogout: () => ref.read(authProvider.notifier).logout(),
                  )
                : snapshot.isReceipt
                ? CustomerReceiptContent(
                    key: ValueKey('receipt_${snapshot.displayRevision}'),
                    snapshot: snapshot,
                  )
                : CustomerPaymentContent(
                    key: ValueKey(snapshot.orderId),
                    snapshot: snapshot,
                  ),
          ),
        ),
      ),
    );
  }
}

class CustomerReceiptContent extends StatelessWidget {
  const CustomerReceiptContent({super.key, required this.snapshot});

  final CustomerDisplaySnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat('#,###', 'vi_VN');
    final url = snapshot.receiptUrl;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Container(
            key: const Key('customer_display_receipt_qr'),
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: PosColors.surface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: PosColors.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.receipt_long_rounded,
                  size: 44,
                  color: PosColors.accent,
                ),
                const SizedBox(height: 12),
                Text(
                  'Thanh toán thành công',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: PosColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '₫${currency.format(snapshot.total)}',
                  key: const Key('customer_display_receipt_total'),
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: PosColors.accent,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox.square(
                  dimension: 280,
                  child: url == null
                      ? const Center(child: CircularProgressIndicator())
                      : url.isEmpty
                      ? const Center(
                          child: Icon(
                            Icons.qr_code_2_rounded,
                            size: 88,
                            color: PosColors.textSecondary,
                          ),
                        )
                      : QrImageView(
                          data: url,
                          version: QrVersions.auto,
                          backgroundColor: Colors.white,
                          semanticsLabel: 'Mã QR biên lai điện tử',
                        ),
                ),
                const SizedBox(height: 16),
                Text(
                  url == null
                      ? 'Đang chuẩn bị mã QR biên lai…'
                      : url.isEmpty
                      ? 'Không thể tạo mã QR. Vui lòng yêu cầu biên lai giấy.'
                      : 'Quét mã QR để xem, lưu PDF hoặc tự in biên lai',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Nếu cần biên lai giấy, vui lòng báo nhân viên.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: PosColors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CustomerDisplayIdle extends StatelessWidget {
  const _CustomerDisplayIdle({super.key, required this.onLogout});

  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 96,
                height: 96,
                decoration: const BoxDecoration(
                  color: PosColors.surface,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.point_of_sale_rounded,
                  size: 48,
                  color: PosColors.accent,
                ),
              ),
              const SizedBox(height: 28),
              Text(
                context.l10n.customerDisplayWaitingTitle,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: PosColors.textPrimary,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                context.l10n.customerDisplayWaitingMessage,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: PosColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        Positioned(
          top: 8,
          right: 8,
          child: IconButton(
            key: const Key('customer_display_logout'),
            tooltip: context.l10n.logout,
            color: PosColors.textSecondary,
            onPressed: onLogout,
            icon: const Icon(Icons.logout_rounded),
          ),
        ),
      ],
    );
  }
}

class CustomerPaymentContent extends StatelessWidget {
  const CustomerPaymentContent({super.key, required this.snapshot});

  final CustomerDisplaySnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return Localizations.override(
      context: context,
      locale: const Locale('vi'),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final landscape = constraints.maxWidth >= 760;
          final orderPanel = _CustomerOrderPanel(snapshot: snapshot);
          const qrPanel = _CustomerQrPanel();

          return Padding(
            padding: EdgeInsets.all(landscape ? 18 : 12),
            child: landscape
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 3, child: orderPanel),
                      const SizedBox(width: 14),
                      const Expanded(flex: 2, child: qrPanel),
                    ],
                  )
                : Column(
                    children: [
                      Expanded(flex: 3, child: orderPanel),
                      const SizedBox(height: 12),
                      const Expanded(flex: 2, child: qrPanel),
                    ],
                  ),
          );
        },
      ),
    );
  }
}

class _CustomerOrderPanel extends StatelessWidget {
  const _CustomerOrderPanel({required this.snapshot});

  final CustomerDisplaySnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat('#,###', 'vi_VN');
    return Container(
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: PosColors.border),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.customerDisplayOrderTitle,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: PosColors.textPrimary,
                  ),
                ),
              ),
              Text(
                context.l10n.cashierTableLabel(snapshot.tableNumber),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: PosColors.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: snapshot.items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = snapshot.items[index];
                return Padding(
                  key: ValueKey('customer_display_item_$index'),
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontSize: 11.2,
                                fontWeight: FontWeight.w700,
                                color: PosColors.textPrimary,
                                height: 1.15,
                              ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '× ${item.quantity}',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontSize: 11.2,
                              color: PosColors.textSecondary,
                            ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 94,
                        child: Text(
                          '₫${currency.format(item.amount)}',
                          textAlign: TextAlign.right,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontSize: 11.2,
                                fontWeight: FontWeight.w800,
                                color: PosColors.textPrimary,
                              ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const Divider(height: 1),
          if (snapshot.discount > 0 ||
              snapshot.serviceCharge > 0 ||
              snapshot.vat > 0) ...[
            const SizedBox(height: 8),
            if (snapshot.serviceCharge > 0)
              _AmountRow(
                label: context.l10n.cashierServiceCharge,
                amount: snapshot.serviceCharge,
              ),
            if (snapshot.vat > 0)
              _AmountRow(
                key: const Key('customer_display_vat'),
                label: context.l10n.einvoiceVat,
                amount: snapshot.vat,
              ),
            if (snapshot.discount > 0)
              _AmountRow(
                label: context.l10n.cashierDiscountSummary,
                amount: -snapshot.discount,
              ),
          ],
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: PosColors.accent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    context.l10n.customerDisplayTotal,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(
                  '₫${currency.format(snapshot.total)}',
                  key: const Key('customer_display_total'),
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AmountRow extends StatelessWidget {
  const _AmountRow({super.key, required this.label, required this.amount});

  final String label;
  final double amount;

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat('#,###', 'vi_VN');
    final prefix = amount < 0 ? '-₫' : '₫';
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: PosColors.textSecondary),
            ),
          ),
          Text(
            '$prefix${currency.format(amount.abs())}',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: PosColors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _CustomerQrPanel extends StatelessWidget {
  const _CustomerQrPanel();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('customer_display_fixed_qr'),
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: PosColors.border),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            context.l10n.customerDisplayScanQr,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: PosColors.textPrimary,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: AspectRatio(
              aspectRatio: 1,
              child: Image.asset(
                'assets/images/woori_bank_account_qr.jpg',
                fit: BoxFit.contain,
                semanticLabel: context.l10n.customerDisplayQrSemanticLabel,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CustomerDisplayError extends StatelessWidget {
  const _CustomerDisplayError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_rounded, size: 56),
          const SizedBox(height: 16),
          Text(context.l10n.customerDisplayLoadFailed),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: Text(context.l10n.retry)),
        ],
      ),
    );
  }
}
