import '../../widgets/error_toast.dart';
import 'daily_deposit_panel.dart';
import '../report/cash_deposit_qr_dialog.dart';
import '../../core/payments/cash_deposit_transfer.dart';
import '../photo_sales_import/photo_sales_import_screen.dart';
import '../admin/tabs/reports_tab.dart' show DailyClosingScreen;
import '../../widgets/bank_transfer_ledger_dialog.dart';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:async';
import '../admin/einvoice_misa_workbook.dart';
import '../admin/widgets/invoice_mapping_import_dialog.dart';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/ui/app_fonts.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import '../../widgets/app_nav_bar.dart';
import '../photo_sales_import/photo_sales_import_service.dart';
import '../photo_sales_import/photo_sales_registered_export.dart';
import 'combined_sales_export.dart';
import 'daily_sales_summary.dart';
import 'daily_sales_report_service.dart';
import '../../core/payments/collection_bank.dart';
import '../../main.dart';
import 'pos_receipt_ledger.dart';
import 'pos_receipt_ledger_service.dart';
import 'restaurant_sales_export.dart';
import 'restaurant_sales_export_service.dart';

typedef PhotoSalesExportLoader =
    Future<List<PhotoSalesRegisteredExport>> Function(String businessDate);
typedef CombinedMisaFileSaver =
    Future<void> Function(String fileName, Uint8List bytes);

class RestaurantSalesExportScreen extends StatefulWidget {
  const RestaurantSalesExportScreen({
    super.key,
    this.loader,
    this.photoLoader,
    this.saveFile,
    this.embedded = false,
    this.todayOverride,
    this.ledgerService,
    this.reportService,
    this.saveCollectionBank,
    this.initialBusinessDate,
    this.summaryRefreshInterval,
  });

  /// Optional deterministic loader for operational-state widget tests.
  /// Production continues to use [restaurantSalesExportService].
  final Future<List<RestaurantSalesExport>> Function(String businessDate)?
  loader;
  final PhotoSalesExportLoader? photoLoader;
  final CombinedMisaFileSaver? saveFile;
  final bool embedded;
  final DateTime? todayOverride;
  final PosReceiptLedgerService? ledgerService;
  final DailySalesReportService? reportService;
  final Future<void> Function(Map<String, dynamic>)? saveCollectionBank;
  final String? initialBusinessDate;

  /// Injected test loaders do not poll unless an interval is supplied.
  final Duration? summaryRefreshInterval;

  @override
  State<RestaurantSalesExportScreen> createState() =>
      _RestaurantSalesExportScreenState();
}

class _RestaurantSalesExportScreenState
    extends State<RestaurantSalesExportScreen>
    with WidgetsBindingObserver {
  late String _businessDate;
  List<CombinedSalesExport> _exports = const [];
  List<DailySalesSummary> _summaries = const [];
  DailySalesReportService get _reportService =>
      widget.reportService ?? dailySalesReportService;
  DailySalesSummary? get _selectedSummary {
    for (final summary in _summaries) {
      if (summary.taxEntityId == _selectedTaxEntityId) return summary;
    }
    return null;
  }

  String? _selectedTaxEntityId;
  bool _isLoading = false;
  bool _isDownloading = false;
  String? _statusMessage;
  SalesExportArtifact? _lastArtifact;
  String? _lastArtifactName;
  bool _statusIsError = false;
  int _loadGeneration = 0;
  Timer? _summaryRefreshTimer;
  bool _foreground = true;

  CombinedSalesExport? get _selectedExport {
    for (final export in _exports) {
      if (export.taxEntityId == _selectedTaxEntityId) return export;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _businessDate =
        widget.initialBusinessDate ??
        restaurantHcmBusinessDate(widget.todayOverride ?? DateTime.now());
    Future.microtask(_load);
    WidgetsBinding.instance.addObserver(this);
    final interval =
        widget.summaryRefreshInterval ??
        (widget.reportService != null || widget.loader != null
            ? Duration.zero
            : const Duration(seconds: 30));
    if (interval > Duration.zero) {
      _summaryRefreshTimer = Timer.periodic(interval, (_) {
        if (mounted &&
            _foreground &&
            !_isLoading &&
            !_isDownloading &&
            TickerMode.valuesOf(context).enabled &&
            ModalRoute.of(context)?.isCurrent != false) {
          unawaited(_load());
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && mounted && !_isLoading && !_isDownloading) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    _summaryRefreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = ListView(
      padding: widget.embedded ? EdgeInsets.zero : const EdgeInsets.all(24),
      children: [
        if (!widget.embedded) ...[
          const Align(alignment: Alignment.centerLeft, child: AppNavBar()),
          const SizedBox(height: ToastSpacingTokens.xxl),
        ],
        ToastWorkSurface(
          key: const Key('restaurant_sales_export_screen'),
          padding: const EdgeInsets.all(ToastSpacingTokens.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(
                  _title(context),
                  style: AppFonts.system(
                    color: ToastColorTokens.textPrimary,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                  ),
                ),
              ),
              const SizedBox(height: ToastSpacingTokens.sm),
              Text(
                _subtitle(context),
                style: AppFonts.system(
                  color: ToastColorTokens.textSecondary,
                  fontSize: 14,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: ToastSpacingTokens.xl),
              _dateControls(context),
              if (_isLoading) ...[
                const SizedBox(height: ToastSpacingTokens.lg),
                const LinearProgressIndicator(
                  key: Key('restaurant_sales_export_loading'),
                ),
              ],
              if (_selectedSummary case final summary?) ...[
                const SizedBox(height: ToastSpacingTokens.lg),
                _summaryPanel(context, summary),
              ],
              if (_selectedExport case final export?) ...[
                const SizedBox(height: ToastSpacingTokens.lg),
                _entitySelector(context, export),
                if (export.isSampleEntity) ...[
                  const SizedBox(height: ToastSpacingTokens.sm),
                  _messagePanel(
                    _sampleEntityMessage(context),
                    isError: false,
                    key: const Key('restaurant_sales_export_sample_notice'),
                  ),
                ],
                const SizedBox(height: ToastSpacingTokens.lg),
                _metrics(context, export),
                if (!export.isReadyForDownload) ...[
                  const SizedBox(height: ToastSpacingTokens.lg),
                  _messagePanel(
                    _blockingMessage(context, export),
                    isError: true,
                    key: const Key('restaurant_sales_export_blocking'),
                  ),
                ],
              ],
              if (_statusMessage != null) ...[
                const SizedBox(height: ToastSpacingTokens.lg),
                _messagePanel(
                  _statusMessage!,
                  isError: _statusIsError,
                  key: const Key('restaurant_sales_export_status'),
                ),
              ],
              if (_lastArtifact != null)
                TextButton(
                  key: const Key('sales_export_manifest_button'),
                  onPressed: () async {
                    final manifestBytes = Uint8List.fromList(
                      utf8.encode(_lastArtifact!.manifestJson),
                    );
                    if (widget.saveFile != null) {
                      await widget.saveFile!(
                        '$_lastArtifactName.manifest.json',
                        manifestBytes,
                      );
                    } else {
                      await FileSaver.instance.saveFile(
                        name: '$_lastArtifactName.manifest',
                        bytes: manifestBytes,
                        ext: 'json',
                        mimeType: MimeType.json,
                      );
                    }
                  },
                  child: Text(
                    _copy(
                      '원장 연결·파일 해시 명세 다운로드',
                      'Tải bản liên kết và mã băm file',
                      'Download ledger linkage and file hash manifest',
                    ),
                  ),
                ),
              const SizedBox(height: ToastSpacingTokens.lg),
              FilledButton.icon(
                key: const Key('restaurant_sales_export_button'),
                onPressed:
                    _isLoading ||
                        _isDownloading ||
                        !(_selectedExport?.isReadyForDownload == true ||
                            (_selectedSummary?.receiptCount ?? 0) > 0)
                    ? null
                    : _download,
                icon: _isDownloading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_outlined),
                label: Text(_downloadLabel(context)),
              ),
            ],
          ),
        ),
      ],
    );

    if (widget.embedded) return content;
    return Scaffold(
      backgroundColor: ToastColorTokens.canvas,
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: content,
          ),
        ),
      ),
    );
  }

  Widget _dateControls(BuildContext context) {
    final choose = OutlinedButton.icon(
      key: const Key('restaurant_sales_export_date_picker'),
      onPressed: _isLoading || _isDownloading ? null : _chooseDate,
      icon: const Icon(Icons.calendar_month_outlined),
      label: Text(
        context.l10n.restaurantSalesExportDate(_businessDate),
        key: const Key('restaurant_sales_export_business_date'),
        style: AppFonts.system(
          color: ToastColorTokens.textPrimary,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
    final search = FilledButton.icon(
      key: const Key('restaurant_sales_export_search'),
      onPressed: _isLoading || _isDownloading ? null : _load,
      icon: const Icon(Icons.search),
      label: Text(_searchLabel(context)),
    );
    return Container(
      key: const Key('restaurant_sales_export_date_search'),
      padding: const EdgeInsets.all(ToastSpacingTokens.md),
      decoration: BoxDecoration(
        color: ToastColorTokens.infoMuted,
        borderRadius: ToastRadiusTokens.sm,
        border: Border.all(color: ToastColorTokens.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _dateSearchTitle(context),
            style: AppFonts.system(
              color: ToastColorTokens.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: ToastSpacingTokens.sm),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 600) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    choose,
                    const SizedBox(height: ToastSpacingTokens.sm),
                    search,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: choose),
                  const SizedBox(width: ToastSpacingTokens.sm),
                  search,
                ],
              );
            },
          ),
          const SizedBox(height: ToastSpacingTokens.sm),
          Text(
            _dateSearchGuidance(context),
            key: const Key('restaurant_sales_export_past_date_guidance'),
            style: AppFonts.system(
              color: ToastColorTokens.textSecondary,
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  String _copy(String ko, String vi, String en) =>
      switch (Localizations.localeOf(context).languageCode) {
        'vi' => vi,
        'en' => en,
        _ => ko,
      };

  Widget _summaryPanel(BuildContext context, DailySalesSummary summary) {
    final currency = NumberFormat('#,##0', 'vi_VN');
    String money(num n) => '${currency.format(n)} ₫';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: const Key('restaurant_sales_export_tax_entity_selector'),
          initialValue: summary.taxEntityId,
          isExpanded: true,
          items: _summaries
              .map(
                (r) => DropdownMenuItem(
                  value: r.taxEntityId,
                  child: Text('${r.sellerLegalName} · ${r.sellerTaxCode}'),
                ),
              )
              .toList(),
          onChanged: _isDownloading
              ? null
              : (id) => setState(() => _selectedTaxEntityId = id),
        ),
        const SizedBox(height: 16),
        DailyDepositPanel(
          summary: summary,
          onBank: _isDownloading
              ? null
              : () => showDialog<void>(
                  context: context,
                  builder: (_) => BankTransferLedgerDialog(
                    loadPage: (time, id) => _reportService.bankTransfers(
                      fromDate: summary.businessDate,
                      toDate: summary.businessDate,
                      taxEntityId: summary.taxEntityId,
                      afterTime: time,
                      afterId: id,
                    ),
                  ),
                ),
          onPhoto: _isDownloading ? null : _openPhotoImport,
          onPhotoQr: _isLoading || _isDownloading
              ? null
              : () => _openPhotoCashQr(summary),
          onClosing: _isDownloading || summary.bunsikStores.isEmpty
              ? null
              : () => _openClosing(summary),
        ),
        const SizedBox(height: 16),
        TextButton(
          onPressed: _isDownloading
              ? null
              : () async {
                  final n = await showDialog<int>(
                    context: context,
                    builder: (context) => InvoiceMappingImportDialog(
                      taxEntityId: summary.taxEntityId,
                    ),
                  );
                  if (n != null && mounted) await _load();
                },
          child: Text(
            _copy(
              '계산서 매핑 일괄 승인',
              'Duyệt ánh xạ hóa đơn',
              'Approve invoice mappings',
            ),
          ),
        ),
        if (summary.exportLineCount != null)
          Text(
            '${_copy('영수증', 'Hóa đơn', 'Receipts')} ${summary.receiptCount} · ${_copy('출력 품목', 'Dòng hàng', 'Export lines')} ${summary.exportLineCount} · ${_copy('원품목', 'Mặt hàng gốc', 'Source items')} ${summary.sourceItemCount}',
          ),
        if (summary.externallyReported)
          Text(
            _localizedError(
              const FormatException('SALES_EXPORT_EXTERNALLY_REPORTED'),
            ),
          ),
        TextButton(
          onPressed:
              _isDownloading ||
                  _isLoading ||
                  summary.restaurantReceiptCount == 0
              ? null
              : () async {
                  setState(() => _isDownloading = true);
                  try {
                    final result = await _reportService
                        .revalidatePendingSnapshots(summary);
                    if (mounted && context.mounted) {
                      showSuccessToast(
                        context,
                        '${_copy('미발행 작업 재검증', 'Kiểm tra lại hóa đơn chưa phát hành', 'Unissued jobs revalidated')}: ${result['updated_count']} · ${_copy('보호', 'Bảo vệ', 'Protected')} ${result['protected_count']} · ${_copy('오류', 'Lỗi', 'Errors')} ${result['error_count']}',
                      );
                    }
                  } catch (_) {
                    if (mounted && context.mounted) {
                      showErrorToast(
                        context,
                        _copy(
                          '재검증하지 못했습니다. 품목 승인과 작업 상태를 확인하세요.',
                          'Không thể kiểm tra lại. Kiểm tra phê duyệt và trạng thái.',
                          'Revalidation failed. Check approvals and job status.',
                        ),
                      );
                    }
                  } finally {
                    if (mounted) setState(() => _isDownloading = false);
                  }
                },
          child: Text(
            _copy(
              '미발행 작업 재검증',
              'Kiểm tra lại hóa đơn chưa phát hành',
              'Revalidate unissued jobs',
            ),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _metric(_receiptLabel(context), '${summary.receiptCount}'),
            _metric(
              _restaurantSalesLabel(context),
              money(summary.restaurantGross),
            ),
            _metric(_photoSalesLabel(context), money(summary.photoGross)),
            _metric(
              _generalLabel(context),
              '${summary.generalCount}',
              onTap: summary.generalCount == 0
                  ? null
                  : () => _openSummaryLedger(summary, false),
            ),
            _metric(
              _redLabel(context),
              '${summary.redCount}',
              onTap: summary.redCount == 0
                  ? null
                  : () => _openSummaryLedger(summary, true),
            ),
            _metric(_supplyLabel(context), money(summary.supply)),
            _metric(_vatLabel(context), money(summary.vat)),
            _metric(_grossLabel(context), money(summary.gross)),
          ],
        ),
        const SizedBox(height: 20),
        TextButton(
          onPressed: _isDownloading ? null : () => _editCollectionBank(summary),
          child: Text(
            _copy(
              '법인 수금 계좌 설정',
              'Thiết lập tài khoản pháp nhân',
              'Collection account settings',
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _openPhotoCashQr(DailySalesSummary summary) async {
    final amount = cashDepositReportAmount(summary.photoDeposit);
    if (amount == null) {
      showErrorToast(
        context,
        summary.photoComplete
            ? context.l10n.cashDepositInvalidAmount
            : context.l10n.salesDepositPhotoMissing,
      );
      return;
    }
    final bank = summary.bank;
    if (bank == null) {
      showErrorToast(context, context.l10n.collectionBankUnavailable);
      return;
    }
    final reportDate = DateTime.parse(summary.businessDate);
    await showDialog<void>(
      context: context,
      builder: (_) => CashDepositQrDialog(
        scopeLabel: 'Photo Objet · ${summary.sellerLegalName}',
        purpose: photoCashDepositPurpose(reportDate),
        reportDate: reportDate,
        amount: amount,
        // The summary already carries the selected entity's scoped account.
        loadBank: () async => bank,
      ),
    );
  }

  Future<void> _openPhotoImport() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            const Scaffold(body: SafeArea(child: PhotoSalesImportScreen())),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openClosing(DailySalesSummary summary) async {
    final store = summary.bunsikStores.length == 1
        ? summary.bunsikStores.single
        : await showDialog<DepositStore>(
            context: context,
            builder: (context) => AlertDialog(
              key: const Key('sales_deposit_store_dialog'),
              title: Text(context.l10n.salesDepositOpenClosing),
              content: SizedBox(
                width: 400,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final store in summary.bunsikStores)
                      ListTile(
                        title: Text(store.name),
                        onTap: () => Navigator.pop(context, store),
                      ),
                  ],
                ),
              ),
            ),
          );
    if (!mounted || store == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DailyClosingScreen(
          storeId: store.id,
          closingDate: summary.businessDate,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _openSummaryLedger(DailySalesSummary summary, bool red) async {
    if (_isLoading || _isDownloading) return;
    setState(() => _isLoading = true);
    try {
      final export = await _reportService.loadExport(summary);
      if (!mounted || export.restaurant == null) return;
      await showPosReceiptLedger(
        context,
        export: export.restaurant!,
        red: red,
        service: widget.ledgerService,
      );
    } catch (error) {
      if (mounted) setState(() => _statusMessage = _localizedError(error));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _editCollectionBank(DailySalesSummary summary) async {
    final bank = summary.bank;
    final bin = TextEditingController(text: bank?.bin),
        label = TextEditingController(text: bank?.label),
        account = TextEditingController(text: bank?.accountNumber),
        holder = TextEditingController(text: bank?.accountHolder);
    String? error;
    bool saving = false;
    Future<dynamic>? closeAnimation;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          closeAnimation = ModalRoute.of<void>(dialogContext)?.completed;
          return StatefulBuilder(
            builder: (context, update) => AlertDialog(
              key: const Key('sales_collection_bank_dialog'),
              title: Text(
                _copy(
                  '법인 수금 계좌',
                  'Tài khoản pháp nhân',
                  'Legal entity collection account',
                ),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(summary.sellerLegalName),
                    for (final entry in [
                      (bin, _copy('은행 코드', 'BIN ngân hàng', 'Bank BIN')),
                      (label, _copy('은행명', 'Tên ngân hàng', 'Bank name')),
                      (
                        account,
                        _copy('계좌번호', 'Số tài khoản', 'Account number'),
                      ),
                      (
                        holder,
                        _copy('예금주', 'Tên chủ tài khoản', 'Account holder'),
                      ),
                    ])
                      TextField(
                        controller: entry.$1,
                        decoration: InputDecoration(labelText: entry.$2),
                      ),
                    if (error != null) Text(error!),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.pop(dialogContext),
                  child: Text(context.l10n.cancel),
                ),
                FilledButton(
                  onPressed: saving
                      ? null
                      : () async {
                          update(() => saving = true);
                          try {
                            CollectionBank.fromJson({
                              'bin': bin.text.trim(),
                              'label': label.text.trim(),
                              'account_number': account.text.trim(),
                              'account_holder': holder.text.trim(),
                            });
                            final params = {
                              'p_tax_entity_id': summary.taxEntityId,
                              'p_bin': bin.text.trim(),
                              'p_label': label.text.trim(),
                              'p_account': account.text.trim(),
                              'p_holder': holder.text.trim(),
                            };
                            if (widget.saveCollectionBank case final save?) {
                              await save(params);
                            } else {
                              await supabase.rpc(
                                'set_tax_entity_collection_bank',
                                params: params,
                              );
                            }
                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext);
                            }
                            await _load();
                          } catch (_) {
                            if (dialogContext.mounted) {
                              update(
                                () => error = _copy(
                                  '계좌 정보를 확인해 주세요.',
                                  'Vui lòng kiểm tra tài khoản.',
                                  'Check the account details.',
                                ),
                              );
                            }
                          } finally {
                            if (dialogContext.mounted) {
                              update(() => saving = false);
                            }
                          }
                        },
                  child: Text(context.l10n.save),
                ),
              ],
            ),
          );
        },
      );
    } finally {
      if (closeAnimation != null) await closeAnimation;
      bin.dispose();
      label.dispose();
      account.dispose();
      holder.dispose();
    }
  }

  Widget _metrics(BuildContext context, CombinedSalesExport export) {
    final currency = NumberFormat('#,##0', 'vi_VN');
    return Wrap(
      key: const Key('restaurant_sales_export_preview'),
      spacing: ToastSpacingTokens.sm,
      runSpacing: ToastSpacingTokens.sm,
      children: [
        _metric(_receiptLabel(context), '${export.receiptCount}'),
        _metric(
          _restaurantSalesLabel(context),
          '${currency.format(export.restaurantGrossSales)} ₫',
          key: const Key('restaurant_sales_export_restaurant_total'),
        ),
        _metric(
          _photoSalesLabel(context),
          '${currency.format(export.photoGrossSales)} ₫',
          key: const Key('restaurant_sales_export_photo_total'),
        ),
        _metric(
          _generalLabel(context),
          '${export.generalReceiptCount}',
          key: const Key('pos_general_ledger_card'),
          onTap: export.restaurant == null
              ? null
              : () => showPosReceiptLedger(
                  context,
                  export: export.restaurant!,
                  red: false,
                  service: widget.ledgerService,
                ),
        ),
        _metric(
          _redLabel(context),
          '${export.redInvoiceCount}',
          key: const Key('pos_red_ledger_card'),
          onTap: export.restaurant == null
              ? null
              : () => showPosReceiptLedger(
                  context,
                  export: export.restaurant!,
                  red: true,
                  service: widget.ledgerService,
                ),
        ),
        _metric(
          _supplyLabel(context),
          '${currency.format(export.supplyAmount)} ₫',
        ),
        _metric(_vatLabel(context), '${currency.format(export.vatAmount)} ₫'),
        _metric(
          _grossLabel(context),
          '${currency.format(export.grossSales)} ₫',
        ),
      ],
    );
  }

  Widget _entitySelector(BuildContext context, CombinedSalesExport selected) {
    return KeyedSubtree(
      key: const Key('restaurant_sales_export_tax_entity_selector'),
      child: DropdownButtonFormField<String>(
        key: ValueKey(selected.taxEntityId),
        initialValue: selected.taxEntityId,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: _entityLabel(context),
          helperText: _entityGuidance(context),
          border: const OutlineInputBorder(),
        ),
        items: _exports
            .map(
              (export) => DropdownMenuItem(
                value: export.taxEntityId,
                child: Text(
                  '${export.sellerLegalName} · ${export.sellerTaxCode}'
                  '${export.isSampleEntity ? _sampleSuffix(context) : ''}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            )
            .toList(growable: false),
        onChanged: _isDownloading
            ? null
            : (taxEntityId) {
                if (taxEntityId == null) return;
                setState(() {
                  _selectedTaxEntityId = taxEntityId;
                  _statusMessage = null;
                });
              },
      ),
    );
  }

  Widget _metric(String label, String value, {Key? key, VoidCallback? onTap}) {
    return InkWell(
      key: key,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: 150),
        padding: const EdgeInsets.all(ToastSpacingTokens.md),
        decoration: BoxDecoration(
          color: ToastColorTokens.mutedSurface,
          borderRadius: ToastRadiusTokens.sm,
          border: Border.all(color: ToastColorTokens.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: AppFonts.system(
                color: ToastColorTokens.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: AppFonts.system(
                color: ToastColorTokens.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _messagePanel(
    String message, {
    required bool isError,
    required Key key,
  }) {
    return Semantics(
      key: key,
      liveRegion: true,
      container: true,
      child: Container(
        padding: const EdgeInsets.all(ToastSpacingTokens.md),
        decoration: BoxDecoration(
          color: isError
              ? ToastColorTokens.dangerMuted
              : ToastColorTokens.successMuted,
          borderRadius: ToastRadiusTokens.sm,
          border: Border.all(
            color: isError ? ToastColorTokens.danger : ToastColorTokens.success,
          ),
        ),
        child: Text(
          message,
          style: AppFonts.system(
            color: ToastColorTokens.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w700,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  Future<void> _chooseDate() async {
    final current = DateTime.parse(_businessDate);
    final hcmToday = DateTime.parse(
      restaurantHcmBusinessDate(widget.todayOverride ?? DateTime.now()),
    );
    final selected = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2020),
      lastDate: hcmToday,
    );
    if (selected == null) return;
    setState(() {
      _businessDate = DateFormat('yyyy-MM-dd').format(selected);
      _exports = const [];
      _summaries = const [];
      _selectedTaxEntityId = null;
      _statusMessage = null;
    });
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final day = _businessDate;
    setState(() {
      _isLoading = true;
      _statusMessage = null;
      _statusIsError = false;
      _summaries = const [];
    });
    try {
      if (widget.loader == null) {
        _reportService.invalidateSummary(day);
        final summaries = await _reportService.summaries(day);
        if (!mounted || generation != _loadGeneration || day != _businessDate) {
          return;
        }
        setState(() {
          _summaries = summaries;
          _exports = const [];
          _selectedTaxEntityId =
              summaries.any((r) => r.taxEntityId == _selectedTaxEntityId)
              ? _selectedTaxEntityId
              : summaries.firstOrNull?.taxEntityId;
          if (summaries.isEmpty) _statusMessage = _noSalesMessage(context);
        });
        return;
      }
      final restaurantFuture =
          widget.loader?.call(_businessDate) ??
          restaurantSalesExportService.load(_businessDate);
      final photoFuture =
          widget.photoLoader?.call(_businessDate) ??
          (widget.loader != null
              ? Future<List<PhotoSalesRegisteredExport>>.value(const [])
              : photoSalesImportService.loadRegistered(_businessDate));
      // Attach error handlers to both requests at once. In offline mode both
      // can fail, and awaiting them sequentially would leave the second error
      // unobserved after the screen has already handled the first one.
      final loaded = await Future.wait<Object>([restaurantFuture, photoFuture]);
      final restaurantExports = loaded[0] as List<RestaurantSalesExport>;
      final photoExports = loaded[1] as List<PhotoSalesRegisteredExport>;
      final exports = combineSalesExportsByTaxEntity(
        restaurantExports: restaurantExports,
        photoExports: photoExports,
      );
      if (!mounted) return;
      String? preferredEntityId;
      for (final export in exports) {
        if (!export.isSampleEntity) {
          preferredEntityId = export.taxEntityId;
          break;
        }
      }
      preferredEntityId ??= exports.isEmpty ? null : exports.first.taxEntityId;
      setState(() {
        _exports = exports;
        _selectedTaxEntityId = preferredEntityId;
        if (exports.isEmpty) {
          _statusMessage = _noSalesMessage(context);
        }
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _exports = const [];
        _selectedTaxEntityId = null;
        _statusMessage = _localizedError(error);
        _statusIsError = true;
      });
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _download() async {
    var export = _selectedExport;
    final summary = _selectedSummary;
    if (export == null && summary == null) return;
    setState(() {
      _isDownloading = true;
      _statusMessage = null;
      _statusIsError = false;
    });
    try {
      if (summary?.externallyReported == true) {
        throw const FormatException('SALES_EXPORT_EXTERNALLY_REPORTED');
      }
      export ??= await _reportService.loadExport(summary!);
      if (!export.isReadyForDownload) {
        if (export.restaurant != null) {
          throw restaurantExportValidationException(export.restaurant!);
        }
        throw const FormatException('RESTAURANT_EXPORT_BLOCKING_ISSUES');
      }
      final artifact = buildCombinedSalesArtifact(export);
      final bytes = Uint8List.fromList(artifact.bytes);
      final taxCode = export.sellerTaxCode.replaceAll(
        RegExp(r'[^A-Za-z0-9_-]'),
        '_',
      );
      final fileName =
          'MISA_sales_${taxCode}_${_businessDate.replaceAll('-', '')}';
      if (widget.saveFile != null) {
        await widget.saveFile!('$fileName.xlsx', bytes);
      } else {
        await FileSaver.instance.saveFile(
          name: fileName,
          bytes: bytes,
          ext: 'xlsx',
          mimeType: MimeType.microsoftExcel,
        );
      }
      if (!mounted) return;
      final amount = NumberFormat(
        '#,##0.00',
        'vi_VN',
      ).format(export.grossSales);
      final message =
          '${context.l10n.restaurantSalesExportSaved(export.receiptCount, amount)} · ${_copy('출력 품목', 'Dòng hàng', 'Export lines')} ${export.lineCount} · ${_copy('원품목', 'Mặt hàng gốc', 'Source items')} ${export.sourceItemCount} · ${_copy('품목별 반올림 예상액', 'Tổng làm tròn từng dòng', 'Line rounding total')} ${export.roundedLineGross} VND · Δ ${export.roundingDifference.toStringAsFixed(2)} VND';
      setState(() {
        _statusMessage = message;
        _lastArtifact = artifact;
        _lastArtifactName = fileName;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _statusMessage = _localizedError(error);
        _statusIsError = true;
        _isDownloading = false;
      });
      if (error is SalesExportValidationException) await _showIssues(error);
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  Future<void> _showIssues(SalesExportValidationException error) async {
    var page = 0;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final rows = error.issues.skip(page * 100).take(100).toList();
          return AlertDialog(
            title: Text(
              '${_copy('오류 영수증', 'Hóa đơn lỗi', 'Receipts with errors')} ${error.receiptCount} / ${_copy('오류 품목', 'Mặt hàng lỗi', 'Items with errors')} ${error.itemCount}',
            ),
            content: SizedBox(
              width: 700,
              height: 420,
              child: ListView(
                children: rows
                    .map(
                      (e) => ListTile(
                        title: Text('${e.receiptNumber} / ${e.itemName}'),
                        subtitle: Text(
                          '${e.itemId.isEmpty && e.lineNumber > 0 ? '#${e.lineNumber}' : e.itemId} · ${e.field}\n${e.code}\n${e.soldAt} · ${e.mappingVersion} · ${e.resolution}',
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
            actions: [
              if (page > 0)
                TextButton(
                  onPressed: () => setDialogState(() => page--),
                  child: const Icon(Icons.chevron_left),
                ),
              Text('${page + 1}/${(error.issues.length / 100).ceil()}'),
              if ((page + 1) * 100 < error.issues.length)
                TextButton(
                  onPressed: () => setDialogState(() => page++),
                  child: const Icon(Icons.chevron_right),
                ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(_copy('닫기', 'Đóng', 'Close')),
              ),
            ],
          );
        },
      ),
    );
  }

  String _localizedError(Object error) {
    final code = error is FormatException ? error.message.toString() : '';
    return switch (code) {
      'SALES_EXPORT_EXTERNALLY_REPORTED' => _copy(
        '이미 외부 신고 완료로 보고된 범위입니다. 재처리에서 보호됩니다.',
        'Phạm vi đã được báo cáo hoàn tất. Không xử lý lại.',
        'This scope was reported as completed and is protected from reprocessing.',
      ),
      'RESTAURANT_EXPORT_NOT_READY' =>
        context.l10n.restaurantSalesExportNotReady,
      'RESTAURANT_EXPORT_BLOCKING_ISSUES' ||
      'MISA_APPROVED_ITEM_METADATA_REQUIRED' => _copy(
        '메뉴 계산서 명칭·단위, 영수증 금액과 고객 정보를 확인해 주세요.',
        'Kiểm tra tên, đơn vị hóa đơn, số tiền và thông tin khách hàng.',
        'Check approved invoice descriptions, units, receipt amounts and buyer information.',
      ),
      'SALES_REPORT_CHANGED_REFRESH_REQUIRED' => _copy(
        '조회 후 매출이 변경되었습니다. 다시 조회해 주세요.',
        'Doanh thu đã thay đổi. Vui lòng tra cứu lại.',
        'Sales changed after the query. Please refresh.',
      ),
      'RESTAURANT_EXPORT_DATA_INTEGRITY_FAILED' =>
        context.l10n.restaurantSalesExportIntegrityFailed,
      _ => context.l10n.restaurantSalesExportFailed('$error'),
    };
  }
}

String _title(BuildContext context) =>
    switch (Localizations.localeOf(context).languageCode) {
      'vi' => 'Khai báo doanh thu',
      'en' => 'Sales tax report',
      _ => '매출신고 하기',
    };

String _subtitle(BuildContext context) => switch (Localizations.localeOf(
  context,
).languageCode) {
  'vi' =>
    'Gộp doanh thu Restaurant và Photo cùng pháp nhân vào một file MISA. Các mã số thuế được tách riêng; doanh thu SAMPLE bị loại khỏi khai thuế.',
  'en' =>
    'Combine Restaurant and Photo sales for the same legal entity into one MISA file. Seller tax codes remain separate; SAMPLE sales are excluded from tax reporting.',
  _ =>
    '같은 법인의 Restaurant와 Photo 매출을 하나의 MISA 엑셀로 합칩니다. 다른 세금코드는 분리하고, 샘플 매출은 신고 대상에서 제외합니다.',
};

String _downloadLabel(BuildContext context) =>
    switch (Localizations.localeOf(context).languageCode) {
      'vi' => 'Tải MISA Restaurant + Photo',
      'en' => 'Download Restaurant + Photo MISA',
      _ => 'Restaurant + Photo 통합 MISA 다운로드',
    };

String _entityLabel(BuildContext context) =>
    switch (Localizations.localeOf(context).languageCode) {
      'vi' => 'Pháp nhân / mã số thuế',
      'en' => 'Legal entity / seller tax code',
      _ => '법인 / 판매자 세금코드',
    };

String _entityGuidance(BuildContext context) =>
    switch (Localizations.localeOf(context).languageCode) {
      'vi' => 'Doanh thu không bao giờ được cộng gộp giữa các mã số thuế.',
      'en' => 'Sales from different seller tax codes are never combined.',
      _ => '서로 다른 판매자 세금코드의 매출은 합산되지 않습니다.',
    };

String _sampleSuffix(BuildContext context) =>
    switch (Localizations.localeOf(context).languageCode) {
      'vi' => ' (MẪU)',
      'en' => ' (SAMPLE)',
      _ => ' (샘플)',
    };

String _sampleEntityMessage(
  BuildContext context,
) => switch (Localizations.localeOf(context).languageCode) {
  'vi' =>
    'Đây là pháp nhân thử nghiệm không dùng để khai thuế. Doanh thu này không nằm trong tổng doanh thu thực.',
  'en' =>
    'This is a non-fiscal test entity. Its sales are excluded from real revenue totals.',
  _ => '세금 신고에 사용하지 않는 샘플 법인입니다. 이 매출은 실매출 합계에 포함되지 않습니다.',
};

String _noSalesMessage(BuildContext context) =>
    switch (Localizations.localeOf(context).languageCode) {
      'vi' => 'Không có doanh thu Restaurant hoặc Photo cho ngày này.',
      'en' => 'There are no Restaurant or Photo sales for this date.',
      _ => '해당 날짜에 Restaurant 또는 Photo 매출이 없습니다.',
    };

String _dateSearchTitle(BuildContext context) =>
    switch (Localizations.localeOf(context).languageCode) {
      'vi' => 'Tra cứu theo ngày',
      'en' => 'Search by business date',
      _ => '날짜별 조회',
    };

String _searchLabel(BuildContext context) =>
    switch (Localizations.localeOf(context).languageCode) {
      'vi' => 'Tra cứu',
      'en' => 'Search',
      _ => '조회',
    };

String _dateSearchGuidance(
  BuildContext context,
) => switch (Localizations.localeOf(context).languageCode) {
  'vi' =>
    'Có thể tra cứu và tải bất cứ lúc nào. Tra cứu lại để cập nhật doanh thu phát sinh thêm. Có thể chọn ngày trước.',
  'en' =>
    'View and download at any time. Search again to include later sales. Past dates are also available.',
  _ =>
    '시간 제한 없이 조회·다운로드할 수 있습니다. 추가 매출이 발생하면 다시 조회한 뒤 다운로드하세요. 지난 날짜도 조회할 수 있습니다.',
};

String _receiptLabel(BuildContext context) =>
    switch (Localizations.localeOf(context).languageCode) {
      'vi' => 'Tổng biên lai',
      'en' => 'All receipts',
      _ => '전체 영수증',
    };

String _restaurantSalesLabel(BuildContext context) =>
    switch (Localizations.localeOf(context).languageCode) {
      'vi' => 'Doanh thu Restaurant',
      'en' => 'Restaurant sales',
      _ => 'Restaurant 매출',
    };

String _photoSalesLabel(BuildContext context) =>
    switch (Localizations.localeOf(context).languageCode) {
      'vi' => 'Doanh thu Photo',
      'en' => 'Photo sales',
      _ => 'Photo 매출',
    };

String _generalLabel(BuildContext context) =>
    switch (Localizations.localeOf(context).languageCode) {
      'vi' => 'Biên lai thường',
      'en' => 'General receipts',
      _ => '일반 영수증',
    };

String _redLabel(BuildContext context) =>
    switch (Localizations.localeOf(context).languageCode) {
      'vi' => 'Hóa đơn đỏ',
      'en' => 'Red Invoices',
      _ => '레드인보이스',
    };

String _supplyLabel(BuildContext context) =>
    switch (Localizations.localeOf(context).languageCode) {
      'vi' => 'Tiền trước thuế',
      'en' => 'Supply amount',
      _ => '공급가액',
    };

String _vatLabel(BuildContext context) =>
    switch (Localizations.localeOf(context).languageCode) {
      'vi' => 'Thuế GTGT',
      'en' => 'VAT',
      _ => '부가세',
    };

String _grossLabel(BuildContext context) =>
    switch (Localizations.localeOf(context).languageCode) {
      'vi' => 'Tổng thanh toán',
      'en' => 'Gross sales',
      _ => '총 결제액',
    };

String _blockingMessage(
  BuildContext context,
  CombinedSalesExport export,
) => switch (Localizations.localeOf(context).languageCode) {
  'vi' =>
    '${export.blockingIssueCount} lỗi dữ liệu cần xử lý trước khi tải file.',
  'en' =>
    '${export.blockingIssueCount} data issue(s) must be resolved before download.',
  _ => '다운로드 전에 데이터 오류 ${export.blockingIssueCount}건을 처리해야 합니다.',
};
