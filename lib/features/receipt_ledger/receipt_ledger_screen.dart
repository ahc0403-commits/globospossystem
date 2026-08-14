import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/payments/payment_method_contract.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/error_toast.dart';
import '../auth/auth_provider.dart';
import 'receipt_ledger_model.dart';
import 'receipt_ledger_service.dart';

class ReceiptLedgerScreen extends ConsumerStatefulWidget {
  const ReceiptLedgerScreen({super.key, this.overrideStoreId});

  final String? overrideStoreId;

  @override
  ConsumerState<ReceiptLedgerScreen> createState() =>
      _ReceiptLedgerScreenState();
}

class _ReceiptLedgerScreenState extends ConsumerState<ReceiptLedgerScreen> {
  static const _pageSize = 100;
  final _searchController = TextEditingController();
  ReceiptLedgerPage? _page;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String? _status;
  String? _printingOrderId;

  @override
  void initState() {
    super.initState();
    Future.microtask(_reload);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String? get _storeId {
    if (widget.overrideStoreId != null) return widget.overrideStoreId;
    final auth = ref.read(authProvider);
    return auth.role == 'super_admin' ? null : auth.storeId;
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await receiptLedgerService.loadToday(
        storeId: _storeId,
        query: _searchController.text.trim(),
        status: _status,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() => _page = page);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    final current = _page;
    if (current == null || !current.hasMore || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final next = await receiptLedgerService.loadToday(
        storeId: _storeId,
        query: _searchController.text.trim(),
        status: _status,
        limit: _pageSize,
        offset: current.receipts.length,
      );
      if (!mounted) return;
      setState(() {
        _page = ReceiptLedgerPage(
          businessDate: next.businessDate,
          generatedAt: next.generatedAt,
          summary: next.summary,
          receipts: [...current.receipts, ...next.receipts],
          hasMore: next.hasMore,
        );
      });
    } catch (error) {
      if (mounted) showErrorToast(context, error.toString());
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _reprint(ReceiptLedgerEntry entry) async {
    final copy = _ReceiptLedgerCopy(context);
    if (!entry.printable || entry.orderId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(copy.reprintTitle),
        content: Text(copy.reprintConfirm(entry.receiptNumber)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton.icon(
            key: const Key('receipt_ledger_reprint_confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.print_rounded),
            label: Text(copy.reprint),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _printingOrderId = entry.orderId);
    try {
      final job = await receiptLedgerService.reprint(entry.orderId!);
      if (!mounted) return;
      final status = job['status']?.toString();
      if (status == 'pending' || status == 'printing' || status == 'done') {
        showSuccessToast(context, copy.reprintQueued);
      } else {
        showErrorToast(context, copy.reprintFailed);
      }
    } catch (_) {
      if (mounted) showErrorToast(context, copy.reprintFailed);
    } finally {
      if (mounted) setState(() => _printingOrderId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = _ReceiptLedgerCopy(context);
    final page = _page;
    return Scaffold(
      key: const Key('receipt_ledger_root'),
      backgroundColor: ToastColorTokens.canvas,
      body: ToastShell(
        contentPadding: EdgeInsets.zero,
        topbar: ToastTopbar(
          title: copy.title,
          actions: [
            IconButton(
              key: const Key('receipt_ledger_refresh'),
              onPressed: _loading ? null : _reload,
              tooltip: context.l10n.refresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
          trailing: const AppNavBar(),
        ),
        child: ToastResponsiveScrollBody(
          maxWidth: 1480,
          children: [
            _header(copy, page),
            const SizedBox(height: 12),
            _filters(copy),
            const SizedBox(height: 12),
            if (_loading && page == null)
              SizedBox(
                height: 360,
                child: ToastOperationalLoadingState(label: copy.loading),
              )
            else if (_error != null && page == null)
              _errorPanel(copy)
            else
              _ledgerPanel(copy, page),
          ],
        ),
      ),
    );
  }

  Widget _header(_ReceiptLedgerCopy copy, ReceiptLedgerPage? page) {
    final currency = NumberFormat('#,###', 'vi_VN');
    final summary = page?.summary;
    return ToastWorkSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                copy.title,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              ToastStatusBadge(
                label: page == null
                    ? copy.today
                    : copy.businessDate(page.businessDate),
                color: PosColors.accent,
                compact: true,
              ),
              if (widget.overrideStoreId == null &&
                  ref.watch(authProvider).role == 'super_admin')
                ToastStatusBadge(
                  label: copy.allStores,
                  color: PosColors.info,
                  compact: true,
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(copy.subtitle, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          ToastMetricStrip(
            metrics: [
              ToastMetric(
                label: copy.receiptCount,
                value: summary == null ? '—' : '${summary.receiptCount}',
                tone: PosColors.info,
              ),
              ToastMetric(
                label: copy.grossSales,
                value: summary == null
                    ? '—'
                    : '${currency.format(summary.grossAmount)} VND',
                tone: PosColors.success,
              ),
              ToastMetric(
                label: copy.adjustments,
                value: summary == null
                    ? '—'
                    : '${currency.format(summary.adjustedAmount)} VND',
                tone: summary == null || summary.adjustedAmount == 0
                    ? PosColors.textSecondary
                    : PosColors.warning,
              ),
              ToastMetric(
                label: copy.netSales,
                value: summary == null
                    ? '—'
                    : '${currency.format(summary.netAmount)} VND',
                tone: PosColors.success,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _filters(_ReceiptLedgerCopy copy) => ToastWorkSurface(
    padding: const EdgeInsets.all(12),
    child: Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 340,
          child: TextField(
            key: const Key('receipt_ledger_search'),
            controller: _searchController,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _reload(),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: copy.searchHint,
              isDense: true,
            ),
          ),
        ),
        DropdownButton<String?>(
          key: const Key('receipt_ledger_status_filter'),
          value: _status,
          items: [
            DropdownMenuItem(value: null, child: Text(copy.allStatuses)),
            DropdownMenuItem(value: 'paid', child: Text(copy.paid)),
            DropdownMenuItem(
              value: 'partially_refunded',
              child: Text(copy.partiallyRefunded),
            ),
            DropdownMenuItem(value: 'refunded', child: Text(copy.refunded)),
          ],
          onChanged: (value) {
            setState(() => _status = value);
            _reload();
          },
        ),
        FilledButton.icon(
          key: const Key('receipt_ledger_search_action'),
          onPressed: _loading ? null : _reload,
          icon: const Icon(Icons.search_rounded),
          label: Text(copy.search),
        ),
      ],
    ),
  );

  Widget _errorPanel(_ReceiptLedgerCopy copy) => ToastWorkSurface(
    child: Column(
      children: [
        Text(copy.loadFailed),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _reload,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(context.l10n.retry),
        ),
      ],
    ),
  );

  Widget _ledgerPanel(_ReceiptLedgerCopy copy, ReceiptLedgerPage? page) {
    final receipts = page?.receipts ?? const <ReceiptLedgerEntry>[];
    return PosDataPanel(
      title: copy.ledger,
      subtitle: copy.ledgerSubtitle,
      trailing: page == null
          ? null
          : Text(
              copy.lastUpdated(
                DateFormat('HH:mm:ss').format(page.generatedAt.toLocal()),
              ),
            ),
      child: receipts.isEmpty
          ? SizedBox(
              height: 260,
              child: ToastOperationalEmptyState(
                headline: copy.empty,
                helper: copy.emptyHelp,
                icon: Icons.receipt_long_outlined,
              ),
            )
          : Column(
              children: [
                for (final entry in receipts) ...[
                  _ReceiptLedgerRow(
                    entry: entry,
                    copy: copy,
                    printing: _printingOrderId == entry.orderId,
                    onOpen: () => _showDetail(entry, copy),
                    onReprint: () => _reprint(entry),
                  ),
                  const Divider(height: 1),
                ],
                if (page?.hasMore == true)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: OutlinedButton.icon(
                      key: const Key('receipt_ledger_load_more'),
                      onPressed: _loadingMore ? null : _loadMore,
                      icon: _loadingMore
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.expand_more_rounded),
                      label: Text(copy.loadMore),
                    ),
                  ),
              ],
            ),
    );
  }

  Future<void> _showDetail(ReceiptLedgerEntry entry, _ReceiptLedgerCopy copy) =>
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: const Key('receipt_ledger_detail_dialog'),
          title: Text(entry.receiptNumber),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _detail(copy.store, entry.storeName),
                  _detail(
                    copy.paidAt,
                    DateFormat(
                      'dd/MM/yyyy HH:mm:ss',
                    ).format(entry.soldAt.toLocal()),
                  ),
                  _detail(copy.table, entry.tableNumber),
                  _detail(copy.channel, entry.salesChannel),
                  _detail(copy.cashier, entry.cashierName),
                  _detail(copy.status, copy.statusLabel(entry.status)),
                  _detail(copy.paymentMethod, _paymentLabel(entry)),
                  _detail(copy.grossSales, _money(entry.grossAmount)),
                  if (entry.adjustedAmount > 0)
                    _detail(copy.adjustments, _money(entry.adjustedAmount)),
                  _detail(copy.netSales, _money(entry.netAmount)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.l10n.close),
            ),
            if (entry.printable)
              FilledButton.icon(
                key: const Key('receipt_ledger_detail_reprint'),
                onPressed: () {
                  Navigator.pop(dialogContext);
                  _reprint(entry);
                },
                icon: const Icon(Icons.print_rounded),
                label: Text(copy.reprint),
              ),
          ],
        ),
      );

  Widget _detail(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          child: Text(
            label,
            style: const TextStyle(color: PosColors.textSecondary),
          ),
        ),
        Expanded(child: Text(value, textAlign: TextAlign.right)),
      ],
    ),
  );
}

class _ReceiptLedgerRow extends StatelessWidget {
  const _ReceiptLedgerRow({
    required this.entry,
    required this.copy,
    required this.printing,
    required this.onOpen,
    required this.onReprint,
  });

  final ReceiptLedgerEntry entry;
  final _ReceiptLedgerCopy copy;
  final bool printing;
  final VoidCallback onOpen;
  final VoidCallback onReprint;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: ValueKey('receipt_ledger_row_${entry.receiptId}'),
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 760;
            final status = ToastStatusBadge(
              label: copy.statusLabel(entry.status),
              color: entry.status == 'paid'
                  ? PosColors.success
                  : PosColors.warning,
              compact: true,
            );
            final action = entry.printable
                ? OutlinedButton.icon(
                    key: ValueKey('receipt_ledger_reprint_${entry.orderId}'),
                    onPressed: printing ? null : onReprint,
                    icon: printing
                        ? const SizedBox.square(
                            dimension: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.print_rounded, size: 18),
                    label: Text(copy.reprint),
                  )
                : Tooltip(
                    message: copy.externalNotPrintable,
                    child: const Icon(
                      Icons.cloud_outlined,
                      color: PosColors.textMuted,
                    ),
                  );
            if (compact) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry.receiptNumber,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      status,
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${entry.storeName} · ${entry.tableNumber} · ${entry.cashierName}',
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${DateFormat('HH:mm:ss').format(entry.soldAt.toLocal())} · ${_paymentLabel(entry)} · ${_money(entry.netAmount)}',
                    style: const TextStyle(color: PosColors.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerRight, child: action),
                ],
              );
            }
            return Row(
              children: [
                SizedBox(
                  width: 84,
                  child: Text(
                    DateFormat('HH:mm:ss').format(entry.soldAt.toLocal()),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.receiptNumber,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        '${entry.storeName} · ${entry.salesChannel}',
                        style: const TextStyle(color: PosColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                Expanded(child: Text(entry.tableNumber)),
                Expanded(flex: 2, child: Text(entry.cashierName)),
                Expanded(flex: 2, child: Text(_paymentLabel(entry))),
                Expanded(
                  flex: 2,
                  child: Text(
                    _money(entry.netAmount),
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(width: 14),
                status,
                const SizedBox(width: 14),
                action,
              ],
            );
          },
        ),
      ),
    );
  }
}

String _money(double amount) =>
    '${NumberFormat('#,###', 'vi_VN').format(amount)} VND';

String _paymentLabel(ReceiptLedgerEntry entry) => entry.payments
    .map((payment) => paymentMethodDisplayLabel(payment.method))
    .toSet()
    .join(' + ');

class _ReceiptLedgerCopy {
  _ReceiptLedgerCopy(BuildContext context)
    : _language = Localizations.localeOf(context).languageCode;

  final String _language;
  String _pick(String ko, String vi, String en) => switch (_language) {
    'vi' => vi,
    'en' => en,
    _ => ko,
  };

  String get title =>
      _pick('오늘의 영수증 원장', 'Sổ biên lai hôm nay', "Today's receipt ledger");
  String get subtitle => _pick(
    '오늘 결제된 전체 매출 영수증과 조정 내역을 확인합니다.',
    'Xem toàn bộ biên lai bán hàng và điều chỉnh đã thanh toán hôm nay.',
    'Review all sales receipts and adjustments paid today.',
  );
  String get today => _pick('오늘', 'Hôm nay', 'Today');
  String businessDate(String date) =>
      _pick('영업일 $date', 'Ngày kinh doanh $date', 'Business date $date');
  String get allStores => _pick('전체 매장', 'Tất cả cửa hàng', 'All stores');
  String get receiptCount => _pick('영수증', 'Biên lai', 'Receipts');
  String get grossSales => _pick('총매출', 'Doanh thu gộp', 'Gross sales');
  String get adjustments =>
      _pick('취소·환불', 'Hủy · hoàn tiền', 'Voids & refunds');
  String get netSales => _pick('실매출', 'Doanh thu thuần', 'Net sales');
  String get searchHint => _pick(
    '영수증 번호, 주문, 테이블, 매장 검색',
    'Tìm số biên lai, đơn, bàn, cửa hàng',
    'Search receipt, order, table, or store',
  );
  String get allStatuses => _pick('전체 상태', 'Tất cả trạng thái', 'All statuses');
  String get paid => _pick('정상 결제', 'Đã thanh toán', 'Paid');
  String get partiallyRefunded =>
      _pick('부분 환불', 'Hoàn tiền một phần', 'Partially refunded');
  String get refunded => _pick('환불 완료', 'Đã hoàn tiền', 'Refunded');
  String get search => _pick('조회', 'Tìm kiếm', 'Search');
  String get loading => _pick(
    '오늘 영수증 원장을 불러오는 중',
    'Đang tải sổ biên lai hôm nay',
    "Loading today's receipt ledger",
  );
  String get loadFailed => _pick(
    '영수증 원장을 불러오지 못했습니다.',
    'Không thể tải sổ biên lai.',
    'Could not load the receipt ledger.',
  );
  String get ledger => _pick('전체 영수증', 'Tất cả biên lai', 'All receipts');
  String get ledgerSubtitle => _pick(
    '행을 누르면 영수증 상세와 결제 내역을 확인할 수 있습니다.',
    'Chọn một dòng để xem chi tiết biên lai và thanh toán.',
    'Select a row to review receipt and payment details.',
  );
  String lastUpdated(String time) =>
      _pick('갱신 $time', 'Cập nhật $time', 'Updated $time');
  String get empty => _pick(
    '오늘 발행된 영수증이 없습니다.',
    'Chưa có biên lai hôm nay.',
    'No receipts have been issued today.',
  );
  String get emptyHelp => _pick(
    '결제가 완료되면 이 원장에 자동으로 표시됩니다.',
    'Biên lai sẽ tự động xuất hiện sau khi thanh toán.',
    'Completed payments appear here automatically.',
  );
  String get loadMore => _pick('더 보기', 'Xem thêm', 'Load more');
  String get reprint => _pick('재출력', 'In lại', 'Reprint');
  String get reprintTitle =>
      _pick('영수증 재출력', 'In lại biên lai', 'Reprint receipt');
  String reprintConfirm(String number) => _pick(
    '$number 영수증을 다시 출력하시겠습니까?',
    'In lại biên lai $number?',
    'Reprint receipt $number?',
  );
  String get reprintQueued => _pick(
    '영수증 재출력을 요청했습니다.',
    'Đã xếp hàng in lại biên lai.',
    'Receipt reprint queued.',
  );
  String get reprintFailed => _pick(
    '영수증 재출력에 실패했습니다.',
    'Không thể in lại biên lai.',
    'Receipt reprint failed.',
  );
  String get externalNotPrintable => _pick(
    '외부 배달 영수증은 POS에서 재출력할 수 없습니다.',
    'Không thể in lại biên lai giao hàng ngoài từ POS.',
    'External delivery receipts cannot be reprinted from POS.',
  );
  String get store => _pick('매장', 'Cửa hàng', 'Store');
  String get paidAt => _pick('결제 시각', 'Thời gian thanh toán', 'Paid at');
  String get table => _pick('테이블', 'Bàn', 'Table');
  String get channel => _pick('판매 채널', 'Kênh bán hàng', 'Sales channel');
  String get cashier => _pick('캐셔', 'Thu ngân', 'Cashier');
  String get status => _pick('상태', 'Trạng thái', 'Status');
  String get paymentMethod =>
      _pick('결제수단', 'Phương thức thanh toán', 'Payment method');
  String statusLabel(String status) => switch (status) {
    'paid' || 'completed' => paid,
    'partially_refunded' => partiallyRefunded,
    'refunded' || 'cancelled' => refunded,
    _ => status,
  };
}
