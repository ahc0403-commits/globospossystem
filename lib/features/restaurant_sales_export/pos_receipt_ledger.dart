import 'dart:async';
import '../../core/services/company_tax_lookup_service.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/i18n/locale_extensions.dart';
import '../red_invoice_intake/buyer_information_form.dart';
import '../red_invoice_intake/buyer_number.dart';
import 'restaurant_sales_export.dart';
import 'pos_receipt_ledger_service.dart';

Future<void> showPosReceiptLedger(
  BuildContext context, {
  required RestaurantSalesExport export,
  required bool red,
  PosReceiptLedgerService? service,
  CompanyTaxLookupService? lookupService,
}) => showDialog<void>(
  context: context,
  builder: (_) => PosReceiptLedger(
    export: export,
    red: red,
    service: service,
    lookupService: lookupService,
  ),
);

class PosReceiptLedger extends StatefulWidget {
  const PosReceiptLedger({
    super.key,
    required this.export,
    required this.red,
    this.service,
    this.lookupService,
  });
  final RestaurantSalesExport export;
  final bool red;
  final PosReceiptLedgerService? service;
  final CompanyTaxLookupService? lookupService;
  @override
  State<PosReceiptLedger> createState() => _PosReceiptLedgerState();
}

class _PosReceiptLedgerState extends State<PosReceiptLedger> {
  late final service = widget.service ?? PosReceiptLedgerService();
  late final inventory = widget.export.receipts
      .where((r) => r.isRedInvoice == widget.red)
      .toList();
  Timer? _debounce;
  late final String openingSession;
  final _search = TextEditingController();
  List<RestaurantSalesReceipt> visible = [];
  Map<String, Map<String, dynamic>> details = {};
  String sort = 'time';
  int page = 0;
  int generation = 0;
  bool loading = false;
  String? error;
  BuyerNumberCopy get copy =>
      BuyerNumberCopy(Localizations.localeOf(context).languageCode);
  String text(String ko, String vi, String en) => copy.pick(ko, vi, en);
  String money(num n) => '${NumberFormat('#,##0.##', 'vi_VN').format(n)} ₫';
  List<RestaurantSalesReceipt> get pageRows =>
      visible.skip(page * 50).take(50).toList();
  @override
  void initState() {
    super.initState();
    openingSession = service.sessionScope;
    _filter();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _filter() {
    final query = _search.text.trim().toLowerCase();
    visible = inventory
        .where(
          (r) => [
            r.receiptId,
            r.displayReceiptNumber,
            r.storeName,
            r.paymentMethod,
            r.buyerTaxCode,
            r.buyerLegalName,
            DateFormat('yyyy-MM-dd HH:mm').format(r.soldAtHcm),
          ].join(' ').toLowerCase().contains(query),
        )
        .toList();
    visible.sort((a, b) {
      final order = switch (sort) {
        'amount' => b.grossSales.compareTo(a.grossSales),
        'number' => a.displayReceiptNumber.compareTo(b.displayReceiptNumber),
        _ => b.soldAt.compareTo(a.soldAt),
      };
      return order == 0 ? a.receiptId.compareTo(b.receiptId) : order;
    });
    page = 0;
    _load();
  }

  Future<void> _load({bool refresh = false}) async {
    final token = ++generation;
    setState(() {
      loading = true;
      error = null;
      details = {};
    });
    try {
      final rows = await service.page(
        day: widget.export.businessDate,
        entity: widget.export.taxEntityId,
        red: widget.red,
        orderIds: pageRows.map((r) => r.receiptId).toList(),
        refresh: refresh,
      );
      if (mounted && token == generation) {
        setState(
          () => details = {
            for (final row in rows) row['order_id'].toString(): row,
          },
        );
      }
    } catch (_) {
      if (mounted && token == generation) {
        setState(
          () => error = text(
            '원장을 불러오지 못했습니다. 선택한 날짜를 다시 조회해 주세요.',
            'Không tải được sổ. Vui lòng truy vấn lại ngày đã chọn.',
            'Could not load the ledger. Query the selected day again.',
          ),
        );
      }
    } finally {
      if (mounted && token == generation) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scopeLabel = text('음식점', 'Nhà hàng', 'Restaurant');
    final body = Column(
      children: [
        Text(
          '${widget.export.businessDate} · ${widget.export.sellerLegalName} · $scopeLabel',
          key: const Key('pos_ledger_scope'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('pos_ledger_search'),
                  controller: _search,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    labelText: text(
                      '주문번호·매장·결제수단·구매자 검색',
                      'Tìm đơn, cửa hàng, thanh toán, người mua',
                      'Search order, store, payment or buyer',
                    ),
                  ),
                  onChanged: (_) {
                    _debounce?.cancel();
                    _debounce = Timer(const Duration(milliseconds: 250), () {
                      if (mounted) setState(_filter);
                    });
                  },
                ),
              ),
              const SizedBox(width: 12),
              DropdownButton<String>(
                value: sort,
                items: [
                  DropdownMenuItem(
                    value: 'time',
                    child: Text(text('시간', 'Thời gian', 'Time')),
                  ),
                  DropdownMenuItem(
                    value: 'amount',
                    child: Text(text('결제액', 'Số tiền', 'Amount')),
                  ),
                  DropdownMenuItem(
                    value: 'number',
                    child: Text(text('주문번호', 'Mã đơn', 'Order ID')),
                  ),
                ],
                onChanged: (value) => setState(() {
                  sort = value!;
                  _filter();
                }),
              ),
            ],
          ),
        ),
        if (loading) const LinearProgressIndicator(),
        if (error != null)
          Row(
            children: [
              Expanded(child: Text(error!)),
              TextButton(
                onPressed: () => _load(refresh: true),
                child: Text(l10n.retry),
              ),
            ],
          ),
        Expanded(
          child: pageRows.isEmpty
              ? Center(
                  child: Text(
                    text(
                      '해당 영수증이 없습니다.',
                      'Không có biên nhận.',
                      'No receipts.',
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: pageRows.length,
                  itemBuilder: (_, index) {
                    final row = pageRows[index];
                    return ListTile(
                      key: Key('pos_ledger_${row.receiptId}'),
                      isThreeLine: true,
                      title: Text(
                        '${row.storeName} · ${row.displayReceiptNumber}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${DateFormat('HH:mm:ss').format(row.soldAtHcm)} · ${row.paymentMethod}\n'
                        '${text('공급가', 'Trước thuế', 'Supply')} ${money(row.supplyAmount)} · VAT ${money(row.vatAmount)} · ${money(row.grossSales)}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: details.containsKey(row.receiptId)
                          ? () => _detail(row)
                          : null,
                    );
                  },
                ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${visible.length} / ${inventory.length} · ${page + 1} / ${math.max(1, (visible.length / 50).ceil())}',
            ),
            Row(
              children: [
                IconButton(
                  key: const Key('pos_ledger_previous'),
                  onPressed: page == 0 || loading
                      ? null
                      : () {
                          page--;
                          _load();
                        },
                  icon: const Icon(Icons.chevron_left),
                ),
                IconButton(
                  key: const Key('pos_ledger_next'),
                  onPressed: loading || (page + 1) * 50 >= visible.length
                      ? null
                      : () {
                          page++;
                          _load();
                        },
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ],
        ),
      ],
    );
    return _ResponsiveLedgerDialog(
      title: widget.red
          ? l10n.redInvoiceTitle
          : text('일반 영수증 원장', 'Sổ biên nhận thường', 'General receipt ledger'),
      child: body,
    );
  }

  Future<void> _detail(RestaurantSalesReceipt receipt) async {
    if (service.sessionScope != openingSession) {
      setState(() {
        details = {};
        error = text(
          '로그인이 변경되었습니다. 원장을 다시 열어 주세요.',
          'Phiên đăng nhập đã thay đổi. Mở lại sổ.',
          'Login changed. Reopen the ledger.',
        );
      });
      return;
    }
    final orderLabel = text('주문 ID', 'ID đơn hàng', 'Order ID');
    final row = details[receipt.receiptId]!;
    await showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, update) {
          final buyer = row['buyer'] is Map
              ? Map<String, dynamic>.from(row['buyer'] as Map)
              : <String, dynamic>{};
          final kind = BuyerNumberType.parse(
            buyer['buyer_number_type']?.toString(),
          );
          final rawNumber =
              buyer['buyer_number_value']?.toString() ??
              buyer['buyer_tax_code']?.toString() ??
              '';
          final issue = buyer.isEmpty
              ? null
              : validateBuyerNumber(kind, rawNumber);
          return _ResponsiveLedgerDialog(
            title: text('영수증 상세', 'Chi tiết biên nhận', 'Receipt details'),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SelectableText(
                    '${receipt.displayReceiptNumber}\n$orderLabel: ${receipt.receiptId}\n${receipt.storeName} · ${DateFormat('yyyy-MM-dd HH:mm:ss').format(receipt.soldAtHcm)}\n'
                    '${receipt.paymentMethod} · ${money(receipt.grossSales)}',
                  ),
                  const Divider(),
                  for (final item in receipt.lineItems)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(item.name),
                      subtitle: Text(
                        '${item.quantity} × ${money(item.unitPrice)} · VAT ${item.vatRate}% (${money(item.vatAmount)})',
                      ),
                      trailing: Text(money(item.grossAmount)),
                    ),
                  const Divider(),
                  Text(
                    text(
                      '결제 내역 (결제 ID)',
                      'Thanh toán (ID thanh toán)',
                      'Payments (payment IDs)',
                    ),
                  ),
                  for (final payment
                      in (row['payments'] as List? ?? []).whereType<Map>())
                    SelectableText(
                      '${payment['payment_id']}\n${payment['method']} · ${money(num.tryParse('${payment['amount']}') ?? 0)} · ${payment['paid_at']}',
                    ),
                  const Divider(),
                  if (buyer.isEmpty)
                    Text(
                      text(
                        '등록된 구매자 정보가 없습니다.',
                        'Chưa đăng ký người mua.',
                        'No registered buyer information.',
                      ),
                    )
                  else ...[
                    SelectableText(
                      '${copy.type}: ${copy.label(kind)}\n${copy.label(kind)}: $rawNumber',
                    ),
                    if (issue != null)
                      Text(
                        copy.error(issue),
                        key: const Key('pos_legacy_number_error'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    for (final entry in {
                      'buyer_legal_name': context.l10n.redInvoiceCompanyName,
                      'buyer_full_name': text(
                        '구매자명',
                        'Tên người mua',
                        'Buyer name',
                      ),
                      'buyer_tax_code': text(
                        '원본 세금/사업자 번호',
                        'Mã thuế gốc',
                        'Raw tax/business number',
                      ),
                      'buyer_id': 'CCCD / ID',
                      'buyer_address': context.l10n.address,
                      'buyer_phone': context.l10n.redInvoicePhone,
                      'buyer_email': 'Email',
                      'buyer_email_cc': 'Email CC',
                      'buyer_unit_code': text('단위코드', 'Mã đơn vị', 'Unit code'),
                      'source_note': context.l10n.redInvoiceSourceNote,
                    }.entries)
                      SelectableText(
                        '${entry.value}: ${buyer[entry.key] ?? ''}',
                      ),
                    for (final url
                        in (buyer['attachment_urls'] as List? ?? [])
                            .cast<String>())
                      TextButton.icon(
                        onPressed: () => launchUrl(
                          Uri.parse(url),
                          mode: LaunchMode.externalApplication,
                        ),
                        icon: const Icon(Icons.attachment),
                        label: Text(context.l10n.redInvoiceOpenAttachment(1)),
                      ),
                    FilledButton.icon(
                      key: const Key('pos_ledger_edit_buyer'),
                      onPressed: () async {
                        final saved = await showBuyerInformationDialog(
                          context,
                          storeId: receipt.storeId,
                          lookupService: widget.lookupService,
                          initial: buyer,
                          confirm: true,
                          onSave: (patch) => service.saveBuyer(
                            storeId: receipt.storeId,
                            orderId: receipt.receiptId,
                            version:
                                (buyer['buyer_version'] as num?)?.toInt() ?? 1,
                            patch: patch,
                            confirm: true,
                          ),
                        );
                        if (saved != null && context.mounted) {
                          update(() => row['buyer'] = saved);
                          if (mounted) setState(() {});
                        }
                      },
                      icon: const Icon(Icons.edit_outlined),
                      label: Text(context.l10n.redInvoiceEditTitle),
                    ),
                    Text(
                      text(
                        'POS 구매자 정보만 저장합니다. 발행된 외부 세금계산서의 정정과는 별개입니다.',
                        'Chỉ lưu thông tin người mua tại POS. Không sửa hóa đơn đã phát hành.',
                        'Saves POS buyer information. Issued external invoices are corrected separately.',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ResponsiveLedgerDialog extends StatelessWidget {
  const _ResponsiveLedgerDialog({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final small = MediaQuery.sizeOf(context).width < 700;
    final content = Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(title, style: Theme.of(context).textTheme.titleLarge),
            ),
            IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        Expanded(child: child),
      ],
    );
    return small
        ? Dialog.fullscreen(
            child: SafeArea(
              child: Padding(padding: const EdgeInsets.all(16), child: content),
            ),
          )
        : Dialog(
            child: SizedBox(
              width: 1100,
              height: math.min(800, MediaQuery.sizeOf(context).height - 64),
              child: Padding(padding: const EdgeInsets.all(20), child: content),
            ),
          );
  }
}
