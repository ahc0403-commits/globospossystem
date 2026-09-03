import 'dart:typed_data';

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
  });

  /// Optional deterministic loader for operational-state widget tests.
  /// Production continues to use [restaurantSalesExportService].
  final Future<List<RestaurantSalesExport>> Function(String businessDate)?
  loader;
  final PhotoSalesExportLoader? photoLoader;
  final CombinedMisaFileSaver? saveFile;
  final bool embedded;
  final DateTime? todayOverride;

  @override
  State<RestaurantSalesExportScreen> createState() =>
      _RestaurantSalesExportScreenState();
}

class _RestaurantSalesExportScreenState
    extends State<RestaurantSalesExportScreen> {
  late String _businessDate;
  List<CombinedSalesExport> _exports = const [];
  String? _selectedTaxEntityId;
  bool _isLoading = false;
  bool _isDownloading = false;
  String? _statusMessage;
  bool _statusIsError = false;

  CombinedSalesExport? get _selectedExport {
    for (final export in _exports) {
      if (export.taxEntityId == _selectedTaxEntityId) return export;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _businessDate = restaurantHcmBusinessDate(
      widget.todayOverride ?? DateTime.now(),
    );
    Future.microtask(_load);
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
              const SizedBox(height: ToastSpacingTokens.lg),
              FilledButton.icon(
                key: const Key('restaurant_sales_export_button'),
                onPressed:
                    _isLoading ||
                        _isDownloading ||
                        _selectedExport?.isReadyForDownload != true
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
        _metric(_generalLabel(context), '${export.generalReceiptCount}'),
        _metric(_redLabel(context), '${export.redInvoiceCount}'),
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

  Widget _metric(String label, String value, {Key? key}) {
    return Container(
      key: key,
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
      _selectedTaxEntityId = null;
      _statusMessage = null;
    });
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _statusMessage = null;
      _statusIsError = false;
    });
    try {
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
      if (!mounted) return;
      setState(() {
        _exports = const [];
        _selectedTaxEntityId = null;
        _statusMessage = _localizedError(error);
        _statusIsError = true;
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _download() async {
    final export = _selectedExport;
    if (export == null || !export.isReadyForDownload) return;
    setState(() {
      _isDownloading = true;
      _statusMessage = null;
      _statusIsError = false;
    });
    try {
      final bytes = Uint8List.fromList(buildCombinedSalesWorkbook(export));
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
      final amount = NumberFormat('#,##0', 'vi_VN').format(export.grossSales);
      final message = context.l10n.restaurantSalesExportSaved(
        export.receiptCount,
        amount,
      );
      setState(() => _statusMessage = message);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _statusMessage = _localizedError(error);
        _statusIsError = true;
      });
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  String _localizedError(Object error) {
    final code = error is FormatException ? error.message.toString() : '';
    return switch (code) {
      'RESTAURANT_EXPORT_NOT_READY' =>
        context.l10n.restaurantSalesExportNotReady,
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
    'Gộp doanh thu Restaurant và Photo cùng pháp nhân vào một file MISA. Các mã số thuế và cửa hàng SAMPLE vẫn được tách riêng.',
  'en' =>
    'Combine Restaurant and Photo sales for the same legal entity into one MISA file. Seller tax codes and SAMPLE sales remain separate.',
  _ => '같은 법인의 Restaurant와 Photo 매출을 하나의 MISA 엑셀로 합칩니다. 다른 세금코드와 샘플 매출은 분리됩니다.',
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
    'Nguyên tắc là khai báo trong ngày. Có thể tra cứu và tải lại file Excel của ngày trước khi cần kiểm tra bổ sung.',
  'en' =>
    'Reports should be filed the same day. Past dates remain searchable and downloadable for later checks.',
  _ => '당일 신고가 원칙입니다. 추가 확인이 필요하면 지난 날짜를 조회해 엑셀을 다시 다운로드할 수 있습니다.',
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
