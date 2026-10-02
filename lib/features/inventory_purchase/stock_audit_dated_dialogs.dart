import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/services/inventory_service.dart';
import '../../core/ui/app_fonts.dart';
import 'stock_audit_excel_import.dart';

// ISO entry formats are identical in all supported languages.
const _dateHint = 'YYYY-MM-DD';
const _timeHint = 'YYYY-MM-DDTHH:mm:ss+07:00';

String auditText(BuildContext context, String ko, String en, String vi) =>
    switch (Localizations.localeOf(context).languageCode) {
      'ko' => ko,
      'vi' => vi,
      _ => en,
    };

class StockAuditDateSelection {
  const StockAuditDateSelection(this.businessDate, this.effectiveAt);
  final String businessDate;
  final DateTime effectiveAt;
}

Future<StockAuditDateSelection?> selectStockAuditDate(BuildContext context) =>
    showDialog<StockAuditDateSelection>(
      context: context,
      builder: (_) => const _StockAuditDateDialog(),
    );

class _StockAuditDateDialog extends StatefulWidget {
  const _StockAuditDateDialog();
  @override
  State<_StockAuditDateDialog> createState() => _StockAuditDateDialogState();
}

class _StockAuditDateDialogState extends State<_StockAuditDateDialog> {
  final hcm = DateTime.now().toUtc().add(const Duration(hours: 7));
  late final business = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(hcm),
  );
  late final reference = TextEditingController(
    text: '${DateFormat('yyyy-MM-ddTHH:mm:ss').format(hcm)}+07:00',
  );
  String? error;
  @override
  void dispose() {
    business.dispose();
    reference.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('stocktake_reference_date_dialog'),
    title: Text(
      auditText(
        context,
        '실사 기준일·시각',
        'Count reference date & time',
        'Ngày và thời điểm kiểm kê',
      ),
    ),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            auditText(
              context,
              '수량이 존재한 시각을 입력하세요. 다음날 업로드해도 이 날짜를 유지합니다. 자정 이후 마감은 업무일과 기준시각 날짜가 다를 수 있습니다.',
              'Enter the time the stock was counted. Uploading tomorrow keeps this date. A close after midnight may belong to the previous business date.',
              'Nhập thời điểm tồn kho được kiểm đếm. Tải lên ngày hôm sau vẫn giữ ngày này. Chốt sau nửa đêm có thể thuộc ngày kinh doanh trước.',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('stocktake_business_date'),
            controller: business,
            decoration: InputDecoration(
              labelText: auditText(
                context,
                '실사 업무일',
                'Business date',
                'Ngày kinh doanh',
              ),
              hintText: _dateHint,
            ),
          ),
          TextField(
            key: const Key('stocktake_effective_at'),
            controller: reference,
            decoration: InputDecoration(
              labelText: auditText(
                context,
                '재고 기준시각 (베트남 +07:00)',
                'Stock reference time (Vietnam +07:00)',
                'Thời điểm tồn kho (Việt Nam +07:00)',
              ),
              hintText: _timeHint,
            ),
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(auditText(context, '취소', 'Cancel', 'Hủy')),
      ),
      FilledButton(
        onPressed: () {
          final date = business.text.trim();
          final time = reference.text.trim();
          final day = DateTime.tryParse(date);
          final at = DateTime.tryParse(time);
          if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
              day == null ||
              DateFormat('yyyy-MM-dd').format(day) != date ||
              !RegExp(
                r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+07:00$',
              ).hasMatch(time) ||
              at == null ||
              stockAuditHcm(
                    at.toIso8601String(),
                  ).substring(0, 19).replaceFirst(' ', 'T') !=
                  time.substring(0, 19)) {
            setState(
              () => error = auditText(
                context,
                '날짜 형식과 베트남 시간(+07:00)을 확인하세요.',
                'Check the date and Vietnam timezone (+07:00).',
                'Kiểm tra ngày và múi giờ Việt Nam (+07:00).',
              ),
            );
            return;
          }
          Navigator.pop(context, StockAuditDateSelection(date, at));
        },
        child: Text(
          auditText(context, '양식 준비', 'Prepare template', 'Chuẩn bị mẫu'),
        ),
      ),
    ],
  );
}

class StockAuditDatedDecision {
  const StockAuditDatedDecision(
    this.complete,
    this.token,
    this.initializeMissing,
    this.acknowledgeLegacy,
  );
  final bool complete;
  final String? token;
  final bool initializeMissing;
  final bool acknowledgeLegacy;
}

Future<StockAuditDatedDecision?> reviewDatedStockAudit(
  BuildContext context, {
  required String storeId,
  required Map<String, dynamic> session,
  required List<Map<String, dynamic>> lines,
  required int blankCount,
}) => showDialog<StockAuditDatedDecision>(
  context: context,
  builder: (_) => _DatedPreview(
    storeId: storeId,
    session: session,
    lines: lines,
    blankCount: blankCount,
  ),
);

class _DatedPreview extends StatefulWidget {
  const _DatedPreview({
    required this.storeId,
    required this.session,
    required this.lines,
    required this.blankCount,
  });
  final String storeId;
  final Map<String, dynamic> session;
  final List<Map<String, dynamic>> lines;
  final int blankCount;
  @override
  State<_DatedPreview> createState() => _DatedPreviewState();
}

class _DatedPreviewState extends State<_DatedPreview> {
  Map<String, dynamic>? preview;
  bool busy = false;
  bool initialize = false;
  bool legacy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (widget.lines.isEmpty) {
        setState(() {
          preview = {'rows': <dynamic>[], 'can_complete': false};
          busy = false;
        });
        return;
      }
      final data = await inventoryService.previewInventoryStockAudit(
        storeId: widget.storeId,
        sessionId: widget.session['id'].toString(),
        lines: widget.lines,
        initializeMissing: initialize,
        acknowledgeLegacy: legacy,
      );
      if (mounted) {
        setState(() {
          preview = data;
          busy = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = auditText(
            context,
            '데이터 검증 실패. 날짜·코드·단위·수량을 확인하세요.',
            'Validation failed. Check dates, codes, units and quantities.',
            'Xác thực thất bại. Kiểm tra ngày, mã, đơn vị và số lượng.',
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _maps(preview?['rows']);
    final hasLegacy = rows.any(
      (r) => r['baseline_source'] == 'legacy_reconstructed',
    );
    final hasMissing = rows.any(
      (r) =>
          r['baseline_quantity_base'] == null &&
          r['observed_quantity_base'] != null,
    );
    return AlertDialog(
      key: const Key('inventory_stock_audit_excel_preview_dialog'),
      title: Text(
        auditText(
          context,
          '날짜 기준 실사 미리보기',
          'Dated stocktake preview',
          'Xem trước kiểm kê theo ngày',
        ),
      ),
      content: SizedBox(
        width: 1100,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.session['business_date']} · ${stockAuditHcm(widget.session['effective_at'])}',
              ),
              Text(
                auditText(
                  context,
                  '미입력 ${widget.blankCount}개 · 임시저장은 재고를 변경하지 않습니다. 이후 거래의 +/−를 보존합니다.',
                  '${widget.blankCount} uncounted · Drafts do not change stock. Subsequent +/− movements are preserved.',
                  '${widget.blankCount} chưa đếm · Lưu nháp không đổi tồn kho. Giữ biến động +/− sau kiểm kê.',
                ),
              ),
              if (busy) const LinearProgressIndicator(),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (hasLegacy)
                CheckboxListTile(
                  key: const Key('stocktake_acknowledge_legacy'),
                  value: legacy,
                  onChanged: busy
                      ? null
                      : (v) {
                          legacy = v ?? false;
                          load();
                        },
                  title: Text(
                    auditText(
                      context,
                      '과거 POS 재고는 결제 기록에서 재구성한 값입니다. 별도 미기록 조정이 없는지 확인했습니다.',
                      'Historical POS stock is reconstructed from payment records. I checked for unrecorded adjustments.',
                      'Tồn POS quá khứ được tái dựng từ thanh toán. Đã kiểm tra điều chỉnh chưa ghi nhận.',
                    ),
                  ),
                ),
              if (hasMissing)
                CheckboxListTile(
                  key: const Key('stocktake_initialize_missing'),
                  value: initialize,
                  onChanged: busy
                      ? null
                      : (v) {
                          initialize = v ?? false;
                          load();
                        },
                  title: Text(
                    auditText(
                      context,
                      '기준시점 POS 재고가 없는 품목을 기초재고로 등록합니다. 차이는 비교 불가로 남깁니다.',
                      'Initialize items with no historical POS baseline. Their variance remains unavailable.',
                      'Khởi tạo hàng không có tồn POS gốc. Chênh lệch vẫn không so sánh được.',
                    ),
                  ),
                ),
              if (rows.isNotEmpty)
                _table(
                  [
                    auditText(context, '코드·품목', 'Code · Item', 'Mã · Hàng'),
                    'POS',
                    auditText(context, '실측', 'Counted', 'Thực tế'),
                    auditText(context, '차이', 'Variance', 'Chênh lệch'),
                    auditText(context, '이후 +', 'Later +', 'Sau đó +'),
                    auditText(context, '이후 −', 'Later −', 'Sau đó −'),
                    auditText(
                      context,
                      '현재 반영',
                      'Resulting stock',
                      'Tồn sau ghi nhận',
                    ),
                    auditText(context, '확인', 'Check', 'Kiểm tra'),
                  ],
                  rows
                      .map(
                        (r) => [
                          '${r['product_code']} · ${r['product_name']} (${r['base_unit']})',
                          _q(r['baseline_quantity_base']),
                          r['actual_quantity_base'] == null
                              ? '${r['excluded_reason'] ?? '-'}'
                              : _q(r['actual_quantity_base']),
                          _q(r['variance_quantity_base']),
                          _signed(r['after_increase_base']),
                          _signed(r['after_decrease_base']),
                          _q(r['current_after_base']),
                          _issue(context, r['issue']),
                        ],
                      )
                      .toList(),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(auditText(context, '취소', 'Cancel', 'Hủy')),
        ),
        TextButton(
          onPressed: busy || widget.lines.isEmpty || error != null
              ? null
              : () => Navigator.pop(
                  context,
                  StockAuditDatedDecision(
                    false,
                    preview?['token']?.toString(),
                    initialize,
                    legacy,
                  ),
                ),
          child: Text(auditText(context, '임시 저장', 'Save draft', 'Lưu nháp')),
        ),
        OutlinedButton(
          onPressed: busy ? null : load,
          child: Text(
            auditText(
              context,
              '증감 새로고침',
              'Refresh movements',
              'Làm mới biến động',
            ),
          ),
        ),
        FilledButton(
          onPressed:
              busy || widget.blankCount > 0 || preview?['can_complete'] != true
              ? null
              : () => Navigator.pop(
                  context,
                  StockAuditDatedDecision(
                    true,
                    preview?['token']?.toString(),
                    initialize,
                    legacy,
                  ),
                ),
          child: Text(auditText(context, '확정', 'Complete', 'Hoàn tất')),
        ),
      ],
    );
  }
}

String _issue(BuildContext context, dynamic issue) => switch (issue) {
  'BASELINE_MISSING' => auditText(
    context,
    '기초재고 확인',
    'Confirm initial stock',
    'Xác nhận tồn đầu',
  ),
  'LEGACY_RECONCILIATION_REQUIRED' => auditText(
    context,
    '과거 기록 확인',
    'Check history',
    'Kiểm tra lịch sử',
  ),
  'REFERENCE_TIME_NOT_REACHED' => auditText(
    context,
    '기준시각 전',
    'Before reference time',
    'Chưa đến thời điểm',
  ),
  'NEWER_COUNT_EXISTS' => auditText(
    context,
    '최근 실사 충돌',
    'Newer count exists',
    'Có kiểm kê mới hơn',
  ),
  'HISTORY_UNVERIFIED' => auditText(
    context,
    '과거 증감 시각 확인 필요',
    'Historical movement time unknown',
    'Chưa rõ thời điểm biến động',
  ),
  'RESULT_QUANTITY_INVALID' => auditText(
    context,
    '환산 수량 범위 오류',
    'Normalized quantity out of range',
    'Số lượng quy đổi ngoài giới hạn',
  ),
  'OBSERVATION_HISTORY_MISSING' => auditText(
    context,
    '관찰 시각 이력 확인 필요',
    'Observation history unavailable',
    'Thiếu lịch sử lúc đếm',
  ),
  'LEDGER_MISMATCH' => auditText(
    context,
    '거래 이력 불일치',
    'Ledger mismatch',
    'Sổ không khớp',
  ),
  'INITIAL_COUNT_TIME_MUST_MATCH' => auditText(
    context,
    '기초재고 시각 불일치',
    'Initial stock time differs',
    'Sai thời điểm tồn đầu',
  ),
  null => '-',
  _ => issue.toString(),
};

class StockAuditReportPanel extends StatefulWidget {
  const StockAuditReportPanel({
    super.key,
    required this.storeId,
    this.refreshVersion,
  });
  final String storeId;
  final Object? refreshVersion;
  @override
  State<StockAuditReportPanel> createState() => _StockAuditReportPanelState();
}

class _StockAuditReportPanelState extends State<StockAuditReportPanel> {
  final date = TextEditingController();
  List<Map<String, dynamic>> sessions = [];
  Map<String, dynamic>? balances;
  int loadGeneration = 0;
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant StockAuditReportPanel old) {
    super.didUpdateWidget(old);
    if (old.storeId != widget.storeId ||
        old.refreshVersion != widget.refreshVersion) {
      load();
    }
  }

  @override
  void dispose() {
    date.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final store = widget.storeId;
    final generation = ++loadGeneration;
    final businessDate = date.text.trim().isEmpty ? null : date.text.trim();
    setState(() {
      busy = true;
      error = null;
      sessions = [];
      balances = null;
    });
    try {
      final results = await Future.wait<Object>([
        inventoryService.listInventoryStockAudits(
          store,
          businessDate: businessDate,
        ),
        inventoryService.getInventoryStockAuditBalances(
          store,
          businessDate: businessDate,
        ),
      ]);
      if (mounted && widget.storeId == store && generation == loadGeneration) {
        setState(() {
          sessions = results[0] as List<Map<String, dynamic>>;
          balances = results[1] as Map<String, dynamic>;
          busy = false;
        });
      }
    } catch (_) {
      if (mounted && widget.storeId == store && generation == loadGeneration) {
        setState(() {
          busy = false;
          error = auditText(
            context,
            '실사 이력·기준일 재고 조회 실패',
            'Could not load count history and dated stock',
            'Không tải được lịch sử và tồn kho theo ngày',
          );
        });
      }
    }
  }

  Future<void> open(String id) async {
    setState(() => busy = true);
    try {
      final store = widget.storeId;
      final report = await inventoryService.getInventoryStockAuditReport(
        store,
        id,
      );
      if (mounted && store == widget.storeId) {
        setState(() => busy = false);
        await showDialog<void>(
          context: context,
          builder: (_) => _AuditReportDialog(report: report),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = auditText(
            context,
            '리포트 조회 실패',
            'Could not load report',
            'Không tải được báo cáo',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> download(String id) async {
    setState(() => busy = true);
    try {
      final store = widget.storeId;
      final session = await inventoryService.prepareInventoryStockAudit(
        storeId: store,
        sessionId: id,
      );
      if (!mounted || widget.storeId != store) return;
      await FileSaver.instance.saveFile(
        name: stockAuditFileName(session),
        bytes: Uint8List.fromList(buildStockAuditTemplate(session)),
        ext: 'xlsx',
        mimeType: MimeType.microsoftExcel,
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => error = auditText(
            context,
            '양식 재다운로드 실패',
            'Template download failed',
            'Không tải được mẫu',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            auditText(
              context,
              '실사 이력·차이 리포트',
              'Count history & variance reports',
              'Lịch sử và báo cáo chênh lệch',
            ),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('stocktake_report_date_filter'),
                  controller: date,
                  decoration: InputDecoration(
                    labelText: auditText(
                      context,
                      '실사 업무일 (빈칸: 최근 완료일)',
                      'Business date (blank: latest completed date)',
                      'Ngày kiểm kê (trống: ngày hoàn tất gần nhất)',
                    ),
                    hintText: _dateHint,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: busy ? null : load,
                child: Text(auditText(context, '조회', 'Search', 'Tra cứu')),
              ),
            ],
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null) Text(error!),
          for (final s in sessions)
            ListTile(
              dense: true,
              key: Key('stocktake_report_${s['id']}'),
              title: Text(
                '${s['business_date'] ?? '-'} · ${stockAuditHcm(s['effective_at'])}',
              ),
              subtitle: Text('${s['audit_no']} · ${s['status']}'),
              trailing: s['status'] == 'planned' || s['status'] == 'in_progress'
                  ? IconButton(
                      tooltip: auditText(
                        context,
                        '같은 날짜 양식 다시 다운로드',
                        'Download same reference template',
                        'Tải lại mẫu cùng ngày',
                      ),
                      onPressed: busy
                          ? null
                          : () => download(s['id'].toString()),
                      icon: const Icon(Icons.download_outlined),
                    )
                  : const Icon(Icons.assessment_outlined),
              onTap: busy ? null : () => open(s['id'].toString()),
            ),
          if (balances != null) ...[
            const SizedBox(height: 16),
            Text(
              '${balances!['business_date']} · ${stockAuditHcm(balances!['effective_at'])}',
              key: const Key('stocktake_balance_reference'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              auditText(
                context,
                '실사 반영 ${_maps(balances!['rows']).where((r) => r['actual_quantity_base'] != null).length} / 전체 ${_maps(balances!['rows']).length}',
                'Counted ${_maps(balances!['rows']).where((r) => r['actual_quantity_base'] != null).length} / total ${_maps(balances!['rows']).length}',
                'Đã kiểm ${_maps(balances!['rows']).where((r) => r['actual_quantity_base'] != null).length} / tổng ${_maps(balances!['rows']).length}',
              ),
              key: const Key('stocktake_balance_summary'),
            ),
            const SizedBox(height: 8),
            _table(
              [
                auditText(context, '품목', 'Item', 'Mặt hàng'),
                auditText(
                  context,
                  '기준일 시스템 재고',
                  'System stock at reference',
                  'Tồn kho tại thời điểm',
                ),
                auditText(
                  context,
                  '실사 수량',
                  'Counted quantity',
                  'Số lượng kiểm đếm',
                ),
                auditText(context, '차이', 'Difference', 'Chênh lệch'),
                auditText(context, '상태', 'Status', 'Trạng thái'),
              ],
              _maps(balances!['rows'])
                  .map(
                    (r) => [
                      '${r['product_code']} ${r['product_name']}',
                      _baseStock(r['system_quantity_base'], r['base_unit']),
                      _baseStock(r['actual_quantity_base'], r['base_unit']),
                      _baseStock(r['variance_quantity_base'], r['base_unit']),
                      r['actual_quantity_base'] == null
                          ? auditText(
                              context,
                              '미실사',
                              'Not counted',
                              'Chưa kiểm',
                            )
                          : auditText(
                              context,
                              '반영 완료',
                              'Applied',
                              'Đã cập nhật',
                            ),
                    ],
                  )
                  .toList(),
            ),
          ],
          if (!busy && sessions.isEmpty)
            Text(
              auditText(
                context,
                '실사 이력이 없습니다.',
                'No stocktakes found.',
                'Chưa có kiểm kê.',
              ),
            ),
        ],
      ),
    ),
  );
}

class _AuditReportDialog extends StatefulWidget {
  const _AuditReportDialog({required this.report});
  final Map<String, dynamic> report;
  @override
  State<_AuditReportDialog> createState() => _AuditReportDialogState();
}

class _AuditReportDialogState extends State<_AuditReportDialog> {
  bool busy = false;
  String? error;
  Future<void> export(bool print) async {
    final title = auditText(context, '재고실사', 'Stocktake', 'Kiểm kê');
    final reference = auditText(context, '기준시각', 'Reference', 'Thời điểm');
    final completed = auditText(context, '확정시각', 'Completed', 'Hoàn tất');
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (print) {
        final data = await rootBundle.load(AppFonts.assetPath);
        final font = pw.Font.ttf(data);
        final doc = pw.Document(
          theme: pw.ThemeData.withFont(base: font, bold: font),
        );
        final rows = _maps(widget.report['rows']);
        doc.addPage(
          pw.MultiPage(
            pageFormat: PdfPageFormat.a4.landscape,
            maxPages: 100,
            build: (_) => [
              pw.Text(
                '${widget.report['store_name']} · $title ${widget.report['business_date']}',
              ),
              pw.Text(
                '$reference: ${stockAuditHcm(widget.report['effective_at'])} / $completed: ${stockAuditHcm(widget.report['completed_at'])}',
              ),
              pw.TableHelper.fromTextArray(
                headers: [
                  'Code',
                  'Item',
                  'Unit',
                  'POS',
                  'Actual @ reference',
                  'Observed quantity',
                  'Variance',
                  'Amount',
                ],
                data: rows
                    .map(
                      (r) => [
                        r['product_code'],
                        r['product_name'],
                        r['base_unit'],
                        _q(r['baseline_quantity_base']),
                        _q(r['actual_quantity_base']),
                        _q(
                          r['observed_quantity_base'] ??
                              r['actual_quantity_base'],
                        ),
                        _signed(r['variance_quantity_base']),
                        _q(r['variance_amount']),
                      ],
                    )
                    .toList(),
                cellStyle: const pw.TextStyle(fontSize: 8),
              ),
            ],
          ),
        );
        final bytes = await doc.save();
        await Printing.layoutPdf(
          name: '${stockAuditFileName(widget.report, report: true)}.pdf',
          onLayout: (_) async => bytes,
        );
      } else {
        await FileSaver.instance.saveFile(
          name: stockAuditFileName(widget.report, report: true),
          bytes: Uint8List.fromList(buildStockAuditReport(widget.report)),
          ext: 'xlsx',
          mimeType: MimeType.microsoftExcel,
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = auditText(
            context,
            '리포트 내보내기 실패',
            'Report export failed',
            'Xuất báo cáo thất bại',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final rows = _maps(report['rows']);
    final moves = _maps(report['movements']);
    final target = _maps(report['snapshot']).length;
    final blank = target - rows.length;
    final excluded = rows.where((r) => r['excluded_reason'] != null).length;
    final counted = rows.where((r) => r['actual_quantity_base'] != null).length;
    final shortage = rows
        .where((r) => (r['variance_quantity_base'] as num? ?? 0) < 0)
        .length;
    final surplus = rows
        .where((r) => (r['variance_quantity_base'] as num? ?? 0) > 0)
        .length;
    final missingCost = rows
        .where(
          (r) => r['actual_quantity_base'] != null && r['unit_cost'] == null,
        )
        .length;
    final loss = rows.fold<num>(
      0,
      (v, r) =>
          v +
          ((r['variance_amount'] as num? ?? 0) < 0
              ? (r['variance_amount'] as num).abs()
              : 0),
    );
    final gain = rows.fold<num>(
      0,
      (v, r) =>
          v +
          ((r['variance_amount'] as num? ?? 0) > 0
              ? r['variance_amount'] as num
              : 0),
    );
    final daily = <String, Map<String, dynamic>>{};
    for (final m in moves) {
      final k = '${m['business_date']}/${m['ingredient_id']}';
      final row = daily.putIfAbsent(
        k,
        () => {...m, 'increase': 0.0, 'decrease': 0.0, 'net': 0.0},
      );
      final quantity = (m['quantity_base'] as num).toDouble();
      row['net'] = (row['net'] as double) + quantity;
      final sign = quantity >= 0 ? 'increase' : 'decrease';
      row[sign] = (row[sign] as double) + quantity;
    }
    final balances = {
      for (final r in rows)
        r['inventory_item_id']: (r['actual_quantity_base'] as num?)?.toDouble(),
    };
    final dailyRows = <List<String>>[];
    final ordered = daily.values.toList()
      ..sort(
        (a, b) => '${a['business_date']}/${a['product_code']}'.compareTo(
          '${b['business_date']}/${b['product_code']}',
        ),
      );
    for (final d in ordered) {
      final item = d['ingredient_id'];
      final before = balances[item];
      final after = before == null ? null : before + (d['net'] as double);
      balances[item] = after;
      dailyRows.add([
        '${d['business_date']}',
        '${d['product_code']} · ${d['product_name']}',
        '${d['base_unit']}',
        _q(before),
        _signed(d['increase']),
        _signed(d['decrease']),
        _q(after),
      ]);
    }
    return AlertDialog(
      key: const Key('stocktake_report_dialog'),
      title: Text(
        auditText(
          context,
          '재고실사 차이 리포트',
          'Stocktake variance report',
          'Báo cáo chênh lệch kiểm kê',
        ),
      ),
      content: SizedBox(
        width: 1200,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${report['store_name']} · ${report['business_date']} · ${report['status']}',
              ),
              Text(
                '${auditText(context, '실사 기준', 'Count reference', 'Thời điểm kiểm kê')}: ${stockAuditHcm(report['effective_at'])}',
              ),
              Text(
                '${auditText(context, '확정 / 조회', 'Completed / Viewed', 'Hoàn tất / Tra cứu')}: ${stockAuditHcm(report['completed_at'])} / ${stockAuditHcm(report['as_of'])}',
              ),
              Text(
                auditText(
                  context,
                  '대상 $target개 · 실사 $counted개 · 미입력 $blank개 · 제외 $excluded개 · 부족 $shortage개 · 초과 $surplus개 · 단가 미등록 $missingCost개',
                  'Targets $target · Counted $counted · Blank $blank · Excluded $excluded · Short $shortage · Surplus $surplus · No cost $missingCost',
                  'Tổng $target · Đã đếm $counted · Trống $blank · Loại trừ $excluded · Thiếu $shortage · Thừa $surplus · Chưa có giá $missingCost',
                ),
              ),
              Text(
                auditText(
                  context,
                  '부족 ${_q(loss)} VND · 초과 ${_q(gain)} VND · 순차이 ${_signed(gain - loss)} VND (단가 없는 품목 제외)',
                  'Shortage ${_q(loss)} VND · Surplus ${_q(gain)} VND · Net ${_signed(gain - loss)} VND (excludes missing costs)',
                  'Thiếu ${_q(loss)} VND · Thừa ${_q(gain)} VND · Ròng ${_signed(gain - loss)} VND (không gồm hàng chưa có giá)',
                ),
              ),
              if (error != null) Text(error!),
              if (busy) const LinearProgressIndicator(),
              const SizedBox(height: 12),
              _table(
                [
                  auditText(context, '코드·품목', 'Code · Item', 'Mã · Hàng'),
                  auditText(context, '공급처', 'Supplier', 'Nhà cung cấp'),
                  'POS',
                  auditText(
                    context,
                    '실측(기준시각)',
                    'Actual @ reference',
                    'Thực tế tại mốc',
                  ),
                  auditText(
                    context,
                    '관찰 수량',
                    'Observed quantity',
                    'Số lượng đã đếm',
                  ),
                  auditText(context, '차이', 'Variance', 'Chênh lệch'),
                  auditText(context, '차이금액', 'Amount', 'Giá trị'),
                  auditText(context, '관찰시각', 'Observed', 'Đã đếm lúc'),
                  auditText(context, '상태', 'Status', 'Trạng thái'),
                ],
                rows
                    .map(
                      (r) => [
                        '${r['product_code']} · ${r['product_name']} (${r['base_unit']})',
                        '${r['supplier_name'] ?? '-'}',
                        _q(r['baseline_quantity_base']),
                        _q(r['actual_quantity_base']),
                        _q(
                          r['observed_quantity_base'] ??
                              r['actual_quantity_base'],
                        ),
                        _signed(r['variance_quantity_base']),
                        _q(r['variance_amount']),
                        stockAuditHcm(r['counted_at']),
                        r['excluded_reason']?.toString() ??
                            (r['baseline_quantity_base'] == null
                                ? auditText(
                                    context,
                                    '비교 불가',
                                    'Unavailable',
                                    'Không so sánh',
                                  )
                                : report['status'].toString()),
                      ],
                    )
                    .toList(),
              ),
              const SizedBox(height: 16),
              Text(
                auditText(
                  context,
                  '기준일 이후 날짜별 증감과 계산 재고 (이후 실측값이 아님)',
                  'Daily movements and calculated stock after reference (not a later physical count)',
                  'Biến động theo ngày và tồn tính toán sau kiểm kê (không phải đếm thực tế mới)',
                ),
              ),
              _table([
                auditText(context, '날짜', 'Date', 'Ngày'),
                auditText(context, '품목', 'Item', 'Hàng'),
                auditText(context, '단위', 'Unit', 'Đơn vị'),
                auditText(context, '전 재고', 'Opening', 'Đầu kỳ'),
                '+',
                '−',
                auditText(context, '계산 재고', 'Calculated', 'Tồn tính'),
              ], dailyRows),
            ],
          ),
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: busy ? null : () => export(false),
          child: Text(
            auditText(context, 'Excel 다운로드', 'Download Excel', 'Tải Excel'),
          ),
        ),
        OutlinedButton(
          onPressed: busy ? null : () => export(true),
          child: Text(auditText(context, '인쇄', 'Print', 'In')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(auditText(context, '닫기', 'Close', 'Đóng')),
        ),
      ],
    );
  }
}

Widget _table(List<String> headers, List<List<String>> rows) =>
    SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: headers.map((h) => DataColumn(label: Text(h))).toList(),
        rows: rows
            .map(
              (r) => DataRow(cells: r.map((v) => DataCell(Text(v))).toList()),
            )
            .toList(),
      ),
    );
List<Map<String, dynamic>> _maps(dynamic v) =>
    (v as List? ?? []).map((r) => Map<String, dynamic>.from(r as Map)).toList();
String _q(dynamic v) => v is num ? NumberFormat('#,##0.###').format(v) : '-';
String _signed(dynamic v) => v is num && v > 0 ? '+${_q(v)}' : _q(v);

String _baseStock(dynamic quantity, dynamic unit) {
  if (quantity is! num) return '-';
  final factor = unit == 'g' || unit == 'ml' ? 1000 : 1;
  final label = unit == 'g'
      ? 'kg'
      : unit == 'ml'
      ? 'L'
      : unit.toString();
  return '${NumberFormat('#,##0.######').format(quantity / factor)} $label';
}
