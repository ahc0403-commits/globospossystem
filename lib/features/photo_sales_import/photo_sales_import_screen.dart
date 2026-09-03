import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/ui/app_fonts.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import 'photo_sales_import.dart';
import 'photo_sales_import_service.dart';

typedef PhotoSalesImportFilePicker = Future<XFile?> Function();
typedef PhotoSalesRegistrar =
    Future<PhotoSalesRegistrationResult> Function({
      required PhotoSalesImportWorkbook workbook,
      required DateTime saleDate,
      required String sourceFileName,
    });

class PhotoSalesImportScreen extends StatefulWidget {
  const PhotoSalesImportScreen({
    super.key,
    this.pickFile,
    this.registerSales,
    this.todayOverride,
  });

  final PhotoSalesImportFilePicker? pickFile;
  final PhotoSalesRegistrar? registerSales;
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
  bool _isRegistering = false;
  PhotoSalesRegistrationResult? _registrationResult;

  bool get _isBusy => _isReading || _isRegistering;

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
                    ko: '포토 매출 신고하기',
                    en: 'Report Photo sales',
                    vi: 'Khai báo doanh thu Photo',
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
                  ko: 'Moers 매출 Excel을 선택하면 검증 후 지점별 POS 매출로 자동 저장합니다. 원본 파일은 저장하지 않고 검증된 매출 행만 저장합니다.',
                  en: 'Choosing a Moers workbook validates and automatically saves its rows as branch-level POS sales. The source file is not stored.',
                  vi: 'Khi chọn Excel Moers, hệ thống xác thực và tự động lưu doanh thu POS theo chi nhánh. Tệp gốc không được lưu.',
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
                  onPressed: _isBusy ? null : _chooseDate,
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
                        ko: '필수 열: Branch, 기기명, 시간, 금액 · 지원 파일: .xlsx, Moers .xls',
                        en: 'Required columns: Branch, Device Name, Time, Amount · Files: .xlsx, Moers .xls',
                        vi: 'Cột bắt buộc: Branch, Device Name, Time, Amount · Tệp: .xlsx, .xls từ Moers',
                      ),
                      style: AppFonts.system(
                        color: ToastColorTokens.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: ToastSpacingTokens.sm),
                    OutlinedButton.icon(
                      key: const Key('photo_sales_import_file_picker'),
                      onPressed: _isBusy ? null : _pickWorkbook,
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
                const SizedBox(height: ToastSpacingTokens.lg),
                _registrationPanel(context),
              ],
              if (_statusMessage != null) ...[
                const SizedBox(height: ToastSpacingTokens.lg),
                _messagePanel(_statusMessage!, isError: _statusIsError),
              ],
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
          const Divider(color: ToastColorTokens.border),
          const SizedBox(height: ToastSpacingTokens.sm),
          Text(
            _text(
              context,
              ko: '지점별 적용 내역',
              en: 'Branch allocation',
              vi: 'Phân bổ theo chi nhánh',
            ),
            style: AppFonts.system(
              color: ToastColorTokens.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: ToastSpacingTokens.xs),
          for (final branch in workbook.branchSummaries)
            Padding(
              padding: const EdgeInsets.only(top: ToastSpacingTokens.xs),
              child: Row(
                key: Key('photo_sales_branch_${branch.branchCode}'),
                children: [
                  SizedBox(
                    width: 36,
                    child: Text(
                      branch.branchCode,
                      style: AppFonts.system(
                        color: ToastColorTokens.info,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      branch.storeName,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.system(
                        color: ToastColorTokens.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    '${branch.receiptCount}건 · ${currency.format(branch.totalAmount)} ₫',
                    style: AppFonts.system(
                      color: ToastColorTokens.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: ToastSpacingTokens.sm),
          Text(
            _text(
              context,
              ko: 'Branch를 POS 지점 코드로 확인한 뒤 등록합니다. 같은 원천 거래를 다시 등록해도 중복 합산되지 않습니다.',
              en: 'Branch is matched to the POS store code before registration. Re-registering the same source transaction does not double-count sales.',
              vi: 'Branch được đối chiếu với mã cửa hàng POS trước khi ghi nhận. Ghi nhận lại cùng giao dịch nguồn sẽ không cộng trùng doanh thu.',
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

  Widget _registrationPanel(BuildContext context) {
    final result = _registrationResult;
    return Container(
      padding: const EdgeInsets.all(ToastSpacingTokens.md),
      decoration: BoxDecoration(
        color: ToastColorTokens.infoMuted,
        borderRadius: ToastRadiusTokens.sm,
        border: Border.all(color: ToastColorTokens.info),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _text(
              context,
              ko: '지점 매출 자동 저장',
              en: 'Automatic branch sales save',
              vi: 'Tự động lưu doanh thu chi nhánh',
            ),
            style: AppFonts.system(
              color: ToastColorTokens.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: ToastSpacingTokens.xs),
          Text(
            _text(
              context,
              ko: '파일 검증이 끝나면 별도 버튼 없이 자동 저장되어 각 지점의 포토 매출에 반영됩니다. 같은 파일은 다시 선택해도 중복 합산되지 않습니다.',
              en: 'After validation, rows are saved automatically and update each branch’s Photo sales. Selecting the same file again does not double-count it.',
              vi: 'Sau khi xác thực, dữ liệu được tự động lưu vào doanh thu Photo của từng chi nhánh. Chọn lại cùng tệp sẽ không cộng trùng.',
            ),
            style: AppFonts.system(
              color: ToastColorTokens.textSecondary,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          const SizedBox(height: ToastSpacingTokens.md),
          if (_isRegistering)
            Row(
              key: const Key('photo_sales_auto_saving'),
              children: [
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: ToastSpacingTokens.sm),
                Text(
                  _text(
                    context,
                    ko: '지점별 매출을 자동 저장하는 중...',
                    en: 'Automatically saving branch sales...',
                    vi: 'Đang tự động lưu doanh thu chi nhánh...',
                  ),
                ),
              ],
            ),
          if (result != null) ...[
            Text(
              _text(
                context,
                ko: '${result.branches.length}개 지점 · 신규 ${result.insertedRows}건 · 중복 ${result.duplicateRows}건',
                en: '${result.branches.length} branches · ${result.insertedRows} new · ${result.duplicateRows} duplicates',
                vi: '${result.branches.length} chi nhánh · ${result.insertedRows} mới · ${result.duplicateRows} trùng',
              ),
              key: const Key('photo_sales_registration_result'),
              style: AppFonts.system(
                color: ToastColorTokens.success,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
          if (!_isRegistering && result == null)
            Text(
              _text(
                context,
                ko: '자동 저장이 완료되지 않았습니다. 오류를 확인한 뒤 파일을 다시 선택하세요.',
                en: 'Automatic save is incomplete. Check the error and choose the file again.',
                vi: 'Tự động lưu chưa hoàn tất. Hãy kiểm tra lỗi và chọn lại tệp.',
              ),
              style: AppFonts.system(
                color: ToastColorTokens.danger,
                fontSize: 13,
                fontWeight: FontWeight.w700,
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
      _workbook = null;
      _sourceFileName = null;
      _registrationResult = null;
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
        _registrationResult = null;
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
      final fileDate = _saleDateFromFileName(sourceName);
      final today = widget.todayOverride ?? DateTime.now();
      if (fileDate != null &&
          fileDate.isAfter(DateTime(today.year, today.month, today.day))) {
        throw const PhotoSalesImportValidationException([
          '파일명의 매출일이 오늘보다 미래입니다.',
        ]);
      }
      setState(() {
        if (fileDate != null) _saleDate = fileDate;
        _workbook = workbook;
        _registrationResult = null;
        _sourceFileName = sourceName.isEmpty ? 'Moers Excel' : sourceName;
        _statusMessage = null;
      });
      await _registerWorkbook(
        workbook,
        sourceName.isEmpty ? 'Moers Excel' : sourceName,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _workbook = null;
        _registrationResult = null;
        _sourceFileName = sourceName.isEmpty ? 'Moers Excel' : sourceName;
        _statusMessage = error.toString();
        _statusIsError = true;
      });
    } finally {
      if (mounted) setState(() => _isReading = false);
    }
  }

  Future<void> _registerWorkbook(
    PhotoSalesImportWorkbook workbook,
    String sourceFileName,
  ) async {
    setState(() {
      _isRegistering = true;
      _statusMessage = null;
      _statusIsError = false;
    });
    try {
      final result = widget.registerSales != null
          ? await widget.registerSales!(
              workbook: workbook,
              saleDate: _saleDate,
              sourceFileName: sourceFileName,
            )
          : await photoSalesImportService.register(
              workbook: workbook,
              saleDate: _saleDate,
              sourceFileName: sourceFileName,
            );
      if (!mounted) return;
      final message = _text(
        context,
        ko: '지점 매출 등록 완료: 신규 ${result.insertedRows}건, 중복 ${result.duplicateRows}건',
        en: 'Branch sales registered: ${result.insertedRows} new, ${result.duplicateRows} duplicates',
        vi: 'Đã ghi nhận doanh thu: ${result.insertedRows} mới, ${result.duplicateRows} trùng',
      );
      setState(() {
        _registrationResult = result;
        _statusMessage = message;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _statusMessage = _registrationError(context, error);
        _statusIsError = true;
      });
    } finally {
      if (mounted) setState(() => _isRegistering = false);
    }
  }
}

DateTime? _saleDateFromFileName(String fileName) {
  final match = RegExp(r'(20\d{2})[-_](\d{2})[-_](\d{2})').firstMatch(fileName);
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final parsed = DateTime(year, month, day);
  if (parsed.year != year || parsed.month != month || parsed.day != day) {
    throw const PhotoSalesImportValidationException([
      '파일명의 매출일 형식이 올바르지 않습니다.',
    ]);
  }
  return parsed;
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

String _registrationError(BuildContext context, Object error) {
  final message = error.toString();
  if (message.contains('PHOTO_SALES_IMPORT_FORBIDDEN')) {
    return _text(
      context,
      ko: '시스템 관리자만 포토 매출을 등록할 수 있습니다.',
      en: 'Only a system administrator can register Photo sales.',
      vi: 'Chỉ quản trị viên hệ thống mới có thể ghi nhận doanh thu Photo.',
    );
  }
  if (message.contains('PHOTO_SALES_IMPORT_BRANCH_STORE_NOT_FOUND')) {
    return _text(
      context,
      ko: 'Branch와 연결된 활성 POS 지점을 찾을 수 없습니다. 지점 코드를 확인하세요.',
      en: 'No active POS store matches a Branch value. Check the branch codes.',
      vi: 'Không tìm thấy cửa hàng POS đang hoạt động cho Branch. Hãy kiểm tra mã chi nhánh.',
    );
  }
  if (message.contains('PHOTO_SALES_IMPORT_')) {
    return _text(
      context,
      ko: '매출 등록 검증에 실패했습니다. 날짜와 Excel 내용을 다시 확인하세요.',
      en: 'Sales registration validation failed. Check the date and workbook.',
      vi: 'Xác thực ghi nhận doanh thu thất bại. Hãy kiểm tra ngày và tệp Excel.',
    );
  }
  return _text(
    context,
    ko: '지점 매출을 등록하지 못했습니다: $message',
    en: 'Could not register branch sales: $message',
    vi: 'Không thể ghi nhận doanh thu chi nhánh: $message',
  );
}
