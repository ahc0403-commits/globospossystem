import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/ui/app_fonts.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import 'photo_sales_import.dart';

typedef PhotoSalesImportFilePicker = Future<XFile?> Function();
typedef PhotoSalesMisaFileSaver =
    Future<void> Function(String fileName, Uint8List bytes);

class PhotoSalesImportScreen extends StatefulWidget {
  const PhotoSalesImportScreen({
    super.key,
    this.pickFile,
    this.saveFile,
    this.todayOverride,
  });

  final PhotoSalesImportFilePicker? pickFile;
  final PhotoSalesMisaFileSaver? saveFile;
  final DateTime? todayOverride;

  @override
  State<PhotoSalesImportScreen> createState() => _PhotoSalesImportScreenState();
}

class _PhotoSalesImportScreenState extends State<PhotoSalesImportScreen> {
  late DateTime _saleDate;
  PhotoSalesImportWorkbook? _workbook;
  String? _sourceFileName;
  String? _statusMessage;
  bool _statusIsError = false;
  bool _isReading = false;
  bool _isDownloading = false;

  @override
  void initState() {
    super.initState();
    final today = widget.todayOverride ?? DateTime.now();
    _saleDate = DateTime(today.year, today.month, today.day);
  }

  @override
  Widget build(BuildContext context) {
    final workbook = _workbook;
    return ListView(
      key: const Key('photo_sales_import_screen'),
      padding: EdgeInsets.zero,
      children: [
        ToastWorkSurface(
          padding: const EdgeInsets.all(ToastSpacingTokens.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(
                  _text(
                    context,
                    ko: '포토 매출 입력하기',
                    en: 'Import Photo sales',
                    vi: 'Nhập doanh thu Photo',
                  ),
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
                _text(
                  context,
                  ko: 'Moers 매출 Excel을 확인한 뒤 MISA 업로드용 Excel로 변환합니다. 파일 내용은 서버에 저장되지 않습니다.',
                  en: 'Review a Moers sales workbook and convert it to the MISA upload format. The file is not stored on the server.',
                  vi: 'Kiểm tra Excel doanh thu Moers rồi chuyển sang định dạng tải lên MISA. Tệp không được lưu trên máy chủ.',
                ),
                style: AppFonts.system(
                  color: ToastColorTokens.textSecondary,
                  fontSize: 14,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: ToastSpacingTokens.xl),
              _stepCard(
                context,
                number: '1',
                title: _text(
                  context,
                  ko: '매출일 선택',
                  en: 'Select sales date',
                  vi: 'Chọn ngày doanh thu',
                ),
                child: OutlinedButton.icon(
                  key: const Key('photo_sales_import_date_picker'),
                  onPressed: _isReading || _isDownloading ? null : _chooseDate,
                  icon: const Icon(Icons.calendar_month_outlined),
                  label: Text(
                    DateFormat('yyyy-MM-dd').format(_saleDate),
                    key: const Key('photo_sales_import_date'),
                    style: AppFonts.system(
                      color: ToastColorTokens.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: ToastSpacingTokens.md),
              _stepCard(
                context,
                number: '2',
                title: _text(
                  context,
                  ko: 'Moers Excel 업로드',
                  en: 'Upload Moers Excel',
                  vi: 'Tải Excel Moers lên',
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _text(
                        context,
                        ko: '필수 열: 기기명, 시간, 금액 · 지원 파일: .xlsx, Moers .xls',
                        en: 'Required columns: Device Name, Time, Amount · Files: .xlsx, Moers .xls',
                        vi: 'Cột bắt buộc: Device Name, Time, Amount · Tệp: .xlsx, .xls từ Moers',
                      ),
                      style: AppFonts.system(
                        color: ToastColorTokens.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: ToastSpacingTokens.sm),
                    OutlinedButton.icon(
                      key: const Key('photo_sales_import_file_picker'),
                      onPressed: _isReading || _isDownloading
                          ? null
                          : _pickWorkbook,
                      icon: _isReading
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.upload_file_outlined),
                      label: Text(
                        _isReading
                            ? _text(
                                context,
                                ko: '파일 확인 중...',
                                en: 'Reading file...',
                                vi: 'Đang đọc tệp...',
                              )
                            : _text(
                                context,
                                ko: 'Excel 파일 선택',
                                en: 'Choose Excel file',
                                vi: 'Chọn tệp Excel',
                              ),
                      ),
                    ),
                    if (_sourceFileName != null) ...[
                      const SizedBox(height: ToastSpacingTokens.sm),
                      Row(
                        children: [
                          const Icon(
                            Icons.description_outlined,
                            size: 18,
                            color: ToastColorTokens.textSecondary,
                          ),
                          const SizedBox(width: ToastSpacingTokens.xs),
                          Expanded(
                            child: Text(
                              _sourceFileName!,
                              key: const Key('photo_sales_import_file_name'),
                              overflow: TextOverflow.ellipsis,
                              style: AppFonts.system(
                                color: ToastColorTokens.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (workbook != null) ...[
                const SizedBox(height: ToastSpacingTokens.lg),
                _preview(context, workbook),
              ],
              if (_statusMessage != null) ...[
                const SizedBox(height: ToastSpacingTokens.lg),
                _messagePanel(_statusMessage!, isError: _statusIsError),
              ],
              const SizedBox(height: ToastSpacingTokens.lg),
              FilledButton.icon(
                key: const Key('photo_sales_misa_download'),
                onPressed: workbook == null || _isReading || _isDownloading
                    ? null
                    : _downloadMisaWorkbook,
                icon: _isDownloading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_outlined),
                label: Text(
                  _text(
                    context,
                    ko: 'MISA Excel 다운로드',
                    en: 'Download MISA Excel',
                    vi: 'Tải Excel MISA',
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _stepCard(
    BuildContext context, {
    required String number,
    required String title,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(ToastSpacingTokens.md),
      decoration: BoxDecoration(
        color: ToastColorTokens.mutedSurface,
        borderRadius: ToastRadiusTokens.sm,
        border: Border.all(color: ToastColorTokens.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 13,
                backgroundColor: ToastColorTokens.infoMuted,
                child: Text(
                  number,
                  style: AppFonts.system(
                    color: ToastColorTokens.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: ToastSpacingTokens.sm),
              Expanded(
                child: Text(
                  title,
                  style: AppFonts.system(
                    color: ToastColorTokens.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: ToastSpacingTokens.md),
          child,
        ],
      ),
    );
  }

  Widget _preview(BuildContext context, PhotoSalesImportWorkbook workbook) {
    final currency = NumberFormat('#,##0', 'vi_VN');
    return Container(
      key: const Key('photo_sales_import_preview'),
      padding: const EdgeInsets.all(ToastSpacingTokens.md),
      decoration: BoxDecoration(
        color: ToastColorTokens.successMuted,
        borderRadius: ToastRadiusTokens.sm,
        border: Border.all(color: ToastColorTokens.success),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _text(
              context,
              ko: '변환 전 확인',
              en: 'Conversion preview',
              vi: 'Xem trước chuyển đổi',
            ),
            style: AppFonts.system(
              color: ToastColorTokens.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: ToastSpacingTokens.md),
          Wrap(
            spacing: ToastSpacingTokens.sm,
            runSpacing: ToastSpacingTokens.sm,
            children: [
              _metric(
                _text(context, ko: '영수증', en: 'Receipts', vi: 'Biên lai'),
                '${workbook.receiptCount}',
              ),
              _metric(
                _text(context, ko: '매장', en: 'Stores', vi: 'Cửa hàng'),
                workbook.storeCount == 0 ? '-' : '${workbook.storeCount}',
              ),
              _metric(
                _text(
                  context,
                  ko: '총 매출',
                  en: 'Gross sales',
                  vi: 'Tổng doanh thu',
                ),
                '${currency.format(workbook.totalAmount)} ₫',
              ),
              _metric(
                _text(
                  context,
                  ko: '0원 제외',
                  en: 'Zero rows skipped',
                  vi: 'Dòng 0₫ bỏ qua',
                ),
                '${workbook.skippedZeroAmountCount}',
              ),
            ],
          ),
          const SizedBox(height: ToastSpacingTokens.sm),
          Text(
            _text(
              context,
              ko: '각 매출 행은 현금 결제 1건으로 변환되며, VAT 포함 금액에서 공급가액과 8% VAT를 계산합니다.',
              en: 'Each sales row becomes one cash receipt. Supply amount and 8% VAT are derived from the VAT-inclusive amount.',
              vi: 'Mỗi dòng doanh thu trở thành một biên lai tiền mặt. Tiền trước thuế và VAT 8% được tính từ tổng đã gồm VAT.',
            ),
            style: AppFonts.system(
              color: ToastColorTokens.textSecondary,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _metric(String label, String value) {
    return Container(
      constraints: const BoxConstraints(minWidth: 140),
      padding: const EdgeInsets.all(ToastSpacingTokens.sm),
      decoration: BoxDecoration(
        color: ToastColorTokens.surface,
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
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _messagePanel(String message, {required bool isError}) {
    return Semantics(
      key: const Key('photo_sales_import_status'),
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
    final today = widget.todayOverride ?? DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: _saleDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(today.year, today.month, today.day),
    );
    if (selected == null) return;
    setState(() {
      _saleDate = DateTime(selected.year, selected.month, selected.day);
      _statusMessage = null;
    });
  }

  Future<void> _pickWorkbook() async {
    const typeGroup = XTypeGroup(
      label: 'Excel (.xlsx, .xls)',
      extensions: <String>['xlsx', 'xls'],
    );
    final file =
        await widget.pickFile?.call() ??
        await openFile(acceptedTypeGroups: const [typeGroup]);
    if (file == null || !mounted) return;

    final sourceName = file.name.trim().isNotEmpty
        ? file.name.trim()
        : file.path.split(RegExp(r'[/\\]')).last.trim();
    final lowerName = sourceName.toLowerCase();
    if (sourceName.isNotEmpty &&
        !lowerName.endsWith('.xlsx') &&
        !lowerName.endsWith('.xls')) {
      setState(() {
        _workbook = null;
        _sourceFileName = sourceName;
        _statusMessage = _text(
          context,
          ko: '.xlsx 또는 Moers .xls 파일만 선택할 수 있습니다.',
          en: 'Choose an .xlsx file or a Moers .xls file.',
          vi: 'Chỉ chọn tệp .xlsx hoặc .xls từ Moers.',
        );
        _statusIsError = true;
      });
      return;
    }

    setState(() {
      _isReading = true;
      _statusMessage = null;
      _statusIsError = false;
    });
    try {
      final workbook = parsePhotoSalesImportWorkbook(await file.readAsBytes());
      if (!mounted) return;
      setState(() {
        _workbook = workbook;
        _sourceFileName = sourceName.isEmpty ? 'Moers Excel' : sourceName;
        _statusMessage = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _workbook = null;
        _sourceFileName = sourceName.isEmpty ? 'Moers Excel' : sourceName;
        _statusMessage = error.toString();
        _statusIsError = true;
      });
    } finally {
      if (mounted) setState(() => _isReading = false);
    }
  }

  Future<void> _downloadMisaWorkbook() async {
    final workbook = _workbook;
    if (workbook == null) return;
    setState(() {
      _isDownloading = true;
      _statusMessage = null;
      _statusIsError = false;
    });

    try {
      final bytes = Uint8List.fromList(
        buildPhotoSalesMisaWorkbook(source: workbook, saleDate: _saleDate),
      );
      final stamp = DateFormat('yyyyMMdd').format(_saleDate);
      final name = 'MISA_photo_sales_$stamp';
      if (widget.saveFile != null) {
        await widget.saveFile!('$name.xlsx', bytes);
      } else {
        await FileSaver.instance.saveFile(
          name: name,
          bytes: bytes,
          ext: 'xlsx',
          mimeType: MimeType.microsoftExcel,
        );
      }
      if (!mounted) return;
      final amount = NumberFormat(
        '#,##0',
        'vi_VN',
      ).format(workbook.totalAmount);
      final message = _text(
        context,
        ko: 'MISA Excel 저장 완료: 영수증 ${workbook.receiptCount}건, $amount VND',
        en: 'MISA Excel saved: ${workbook.receiptCount} receipts, $amount VND',
        vi: 'Đã lưu Excel MISA: ${workbook.receiptCount} biên lai, $amount VND',
      );
      setState(() => _statusMessage = message);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _statusMessage = error.toString();
        _statusIsError = true;
      });
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }
}

String _text(
  BuildContext context, {
  required String ko,
  required String en,
  required String vi,
}) => switch (Localizations.localeOf(context).languageCode) {
  'en' => en,
  'vi' => vi,
  _ => ko,
};
