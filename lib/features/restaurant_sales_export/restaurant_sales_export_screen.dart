import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/ui/app_fonts.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import '../../widgets/app_nav_bar.dart';
import 'restaurant_sales_export.dart';
import 'restaurant_sales_export_service.dart';

class RestaurantSalesExportScreen extends StatefulWidget {
  const RestaurantSalesExportScreen({
    super.key,
    this.loader,
    this.embedded = false,
  });

  /// Optional deterministic loader for operational-state widget tests.
  /// Production continues to use [restaurantSalesExportService].
  final Future<RestaurantSalesExport> Function(String businessDate)? loader;
  final bool embedded;

  @override
  State<RestaurantSalesExportScreen> createState() =>
      _RestaurantSalesExportScreenState();
}

class _RestaurantSalesExportScreenState
    extends State<RestaurantSalesExportScreen> {
  late String _businessDate;
  RestaurantSalesExport? _export;
  bool _isLoading = false;
  bool _isDownloading = false;
  String? _statusMessage;
  bool _statusIsError = false;

  @override
  void initState() {
    super.initState();
    _businessDate = restaurantHcmBusinessDate(DateTime.now());
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
              if (_export case final export?) ...[
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
                        _export?.isReadyForDownload != true
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
    final date = Semantics(
      selected: true,
      label: context.l10n.restaurantSalesExportDate(_businessDate),
      child: Text(
        context.l10n.restaurantSalesExportDate(_businessDate),
        key: const Key('restaurant_sales_export_business_date'),
        style: AppFonts.system(
          color: ToastColorTokens.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
    final choose = OutlinedButton.icon(
      onPressed: _isLoading || _isDownloading ? null : _chooseDate,
      icon: const Icon(Icons.calendar_month_outlined),
      label: Text(context.l10n.restaurantSalesExportChooseDate),
    );
    final refresh = IconButton.outlined(
      key: const Key('restaurant_sales_export_refresh'),
      tooltip: context.l10n.refresh,
      onPressed: _isLoading || _isDownloading ? null : _load,
      icon: const Icon(Icons.refresh),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 600) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              date,
              const SizedBox(height: ToastSpacingTokens.sm),
              choose,
              const SizedBox(height: ToastSpacingTokens.sm),
              refresh,
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: date),
            choose,
            const SizedBox(width: ToastSpacingTokens.sm),
            refresh,
          ],
        );
      },
    );
  }

  Widget _metrics(BuildContext context, RestaurantSalesExport export) {
    final currency = NumberFormat('#,##0', 'vi_VN');
    return Wrap(
      key: const Key('restaurant_sales_export_preview'),
      spacing: ToastSpacingTokens.sm,
      runSpacing: ToastSpacingTokens.sm,
      children: [
        _metric(_receiptLabel(context), '${export.receiptCount}'),
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

  Widget _metric(String label, String value) {
    return Container(
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
    final hcmToday = DateTime.parse(restaurantHcmBusinessDate(DateTime.now()));
    final selected = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2020),
      lastDate: hcmToday,
    );
    if (selected == null) return;
    setState(() {
      _businessDate = DateFormat('yyyy-MM-dd').format(selected);
      _export = null;
    });
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _statusMessage = null;
      _statusIsError = false;
    });
    try {
      final export =
          await (widget.loader?.call(_businessDate) ??
              restaurantSalesExportService.load(_businessDate));
      if (!mounted) return;
      setState(() => _export = export);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _export = null;
        _statusMessage = _localizedError(error);
        _statusIsError = true;
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _download() async {
    final export = _export;
    if (export == null || !export.isReadyForDownload) return;
    setState(() {
      _isDownloading = true;
      _statusMessage = null;
      _statusIsError = false;
    });
    try {
      final bytes = buildRestaurantSalesWorkbook(export);
      await FileSaver.instance.saveFile(
        name: 'MISA_restaurant_sales_${_businessDate.replaceAll('-', '')}',
        bytes: Uint8List.fromList(bytes),
        ext: 'xlsx',
        mimeType: MimeType.microsoftExcel,
      );
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
    'Tạo một file MISA từ toàn bộ biên lai Restaurant, gồm hóa đơn thường và hóa đơn đỏ. Không bao gồm Photo.',
  'en' =>
    'Create one MISA file from every Restaurant receipt, including general and Red Invoices. Photo is excluded.',
  _ => 'Restaurant의 일반 영수증과 레드인보이스를 한 MISA 엑셀로 생성합니다. 포토 매출은 제외됩니다.',
};

String _downloadLabel(BuildContext context) =>
    switch (Localizations.localeOf(context).languageCode) {
      'vi' => 'Tải một file MISA',
      'en' => 'Download one MISA file',
      _ => 'MISA 엑셀 한 번에 다운로드',
    };

String _receiptLabel(BuildContext context) =>
    switch (Localizations.localeOf(context).languageCode) {
      'vi' => 'Tổng biên lai',
      'en' => 'All receipts',
      _ => '전체 영수증',
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
  RestaurantSalesExport export,
) => switch (Localizations.localeOf(context).languageCode) {
  'vi' =>
    '${export.blockingIssueCount} lỗi dữ liệu cần xử lý trước khi tải file.',
  'en' =>
    '${export.blockingIssueCount} data issue(s) must be resolved before download.',
  _ => '다운로드 전에 데이터 오류 ${export.blockingIssueCount}건을 처리해야 합니다.',
};
