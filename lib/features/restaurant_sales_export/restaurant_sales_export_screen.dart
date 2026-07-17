import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/ui/app_fonts.dart';
import '../../core/ui/app_theme.dart';
import '../../widgets/app_nav_bar.dart';
import 'restaurant_sales_export.dart';
import 'restaurant_sales_export_service.dart';

class RestaurantSalesExportScreen extends StatefulWidget {
  const RestaurantSalesExportScreen({super.key});

  @override
  State<RestaurantSalesExportScreen> createState() =>
      _RestaurantSalesExportScreenState();
}

class _RestaurantSalesExportScreenState
    extends State<RestaurantSalesExportScreen> {
  late String _businessDate;
  bool _isDownloading = false;

  @override
  void initState() {
    super.initState();
    _businessDate = restaurantHcmBusinessDate(DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Align(alignment: Alignment.centerLeft, child: AppNavBar()),
            const SizedBox(height: 28),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Container(
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: AppColors.surface1,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: AppColors.surface2),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        context.l10n.restaurantSalesExportTitle,
                        style: AppFonts.system(
                          color: AppColors.amber500,
                          fontSize: 34,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        context.l10n.restaurantSalesExportSubtitle,
                        style: AppFonts.system(
                          color: AppColors.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              context.l10n.restaurantSalesExportDate(
                                _businessDate,
                              ),
                              key: const Key(
                                'restaurant_sales_export_business_date',
                              ),
                              style: AppFonts.system(
                                color: AppColors.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: _isDownloading ? null : _chooseDate,
                            icon: const Icon(Icons.calendar_month_outlined),
                            label: Text(
                              context.l10n.restaurantSalesExportChooseDate,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      FilledButton.icon(
                        key: const Key('restaurant_sales_export_button'),
                        onPressed: _isDownloading ? null : _download,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.amber500,
                          foregroundColor: AppColors.surface0,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        icon: _isDownloading
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.download_outlined),
                        label: Text(context.l10n.restaurantSalesExportDownload),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
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
    setState(() => _isDownloading = true);
    try {
      final export = await restaurantSalesExportService.load(_businessDate);
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
      _showMessage(
        context.l10n.restaurantSalesExportSaved(export.receiptCount, amount),
      );
    } catch (error) {
      if (!mounted) return;
      _showMessage(_localizedError(error));
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
