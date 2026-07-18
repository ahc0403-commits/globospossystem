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
  const RestaurantSalesExportScreen({super.key, this.loader});

  /// Optional deterministic loader for operational-state widget tests.
  /// Production continues to use [restaurantSalesExportService].
  final Future<RestaurantSalesExport> Function(String businessDate)? loader;

  @override
  State<RestaurantSalesExportScreen> createState() =>
      _RestaurantSalesExportScreenState();
}

class _RestaurantSalesExportScreenState
    extends State<RestaurantSalesExportScreen> {
  late String _businessDate;
  bool _isDownloading = false;
  String? _statusMessage;
  bool _statusIsError = false;

  @override
  void initState() {
    super.initState();
    _businessDate = restaurantHcmBusinessDate(DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('restaurant_sales_export_screen'),
      backgroundColor: ToastColorTokens.canvas,
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Align(
                  alignment: Alignment.centerLeft,
                  child: AppNavBar(),
                ),
                const SizedBox(height: ToastSpacingTokens.xxl),
                ToastWorkSurface(
                  padding: const EdgeInsets.all(ToastSpacingTokens.xl),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          context.l10n.restaurantSalesExportTitle,
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
                        context.l10n.restaurantSalesExportSubtitle,
                        style: AppFonts.system(
                          color: ToastColorTokens.textSecondary,
                          fontSize: 14,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: ToastSpacingTokens.xl),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final date = Semantics(
                            selected: true,
                            label: context.l10n.restaurantSalesExportDate(
                              _businessDate,
                            ),
                            child: Text(
                              context.l10n.restaurantSalesExportDate(
                                _businessDate,
                              ),
                              key: const Key(
                                'restaurant_sales_export_business_date',
                              ),
                              style: AppFonts.system(
                                color: ToastColorTokens.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          );
                          final choose = OutlinedButton.icon(
                            onPressed: _isDownloading ? null : _chooseDate,
                            icon: const Icon(Icons.calendar_month_outlined),
                            label: Text(
                              context.l10n.restaurantSalesExportChooseDate,
                            ),
                          );
                          if (constraints.maxWidth < 520) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                date,
                                const SizedBox(height: ToastSpacingTokens.sm),
                                choose,
                              ],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(child: date),
                              const SizedBox(width: ToastSpacingTokens.lg),
                              choose,
                            ],
                          );
                        },
                      ),
                      if (_statusMessage != null) ...[
                        const SizedBox(height: ToastSpacingTokens.lg),
                        Semantics(
                          key: const Key('restaurant_sales_export_status'),
                          liveRegion: true,
                          container: true,
                          child: Container(
                            padding: const EdgeInsets.all(
                              ToastSpacingTokens.md,
                            ),
                            decoration: BoxDecoration(
                              color: _statusIsError
                                  ? ToastColorTokens.dangerMuted
                                  : ToastColorTokens.successMuted,
                              borderRadius: ToastRadiusTokens.sm,
                              border: Border.all(
                                color: _statusIsError
                                    ? ToastColorTokens.danger
                                    : ToastColorTokens.success,
                              ),
                            ),
                            child: Text(
                              _statusMessage!,
                              style: AppFonts.system(
                                color: ToastColorTokens.textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: ToastSpacingTokens.lg),
                      Semantics(
                        button: true,
                        enabled: !_isDownloading,
                        child: FilledButton.icon(
                          key: const Key('restaurant_sales_export_button'),
                          onPressed: _isDownloading ? null : _download,
                          icon: _isDownloading
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.download_outlined),
                          label: Text(
                            context.l10n.restaurantSalesExportDownload,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
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
    });
  }

  Future<void> _download() async {
    setState(() {
      _isDownloading = true;
      _statusMessage = null;
      _statusIsError = false;
    });
    try {
      final export =
          await (widget.loader?.call(_businessDate) ??
              restaurantSalesExportService.load(_businessDate));
      final bytes = buildRestaurantSalesWorkbook(export);
      await FileSaver.instance.saveFile(
        name: 'restaurant_sales_${_businessDate.replaceAll('-', '')}',
        bytes: Uint8List.fromList(bytes),
        ext: 'xlsx',
        mimeType: MimeType.microsoftExcel,
      );
      if (!mounted) return;
      final amount = NumberFormat(
        '#,##0.##',
        'vi_VN',
      ).format(export.grossSales);
      final message = context.l10n.restaurantSalesExportSaved(
        export.receiptCount,
        amount,
      );
      setState(() {
        _statusMessage = message;
        _statusIsError = false;
      });
      _showMessage(message);
    } catch (error) {
      if (!mounted) return;
      final message = _localizedError(error);
      setState(() {
        _statusMessage = message;
        _statusIsError = true;
      });
      _showMessage(message);
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

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
