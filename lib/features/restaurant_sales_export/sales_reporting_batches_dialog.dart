import 'package:flutter/material.dart';
import 'sales_reporting_batch_service.dart';

class SalesReportingBatchesDialog extends StatefulWidget {
  const SalesReportingBatchesDialog({
    super.key,
    required this.date,
    required this.entity,
    required this.service,
  });
  final String date, entity;
  final SalesReportingBatchService service;
  @override
  State<SalesReportingBatchesDialog> createState() =>
      _SalesReportingBatchesDialogState();
}

class _SalesReportingBatchesDialogState
    extends State<SalesReportingBatchesDialog> {
  List<Map<String, dynamic>> _rows = [];
  bool _busy = true, _more = false;
  String? _error;
  String t(String ko, String vi, String en) =>
      switch (Localizations.localeOf(context).languageCode) {
        'ko' => ko,
        'vi' => vi,
        _ => en,
      };
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final rows = await widget.service.list(
        widget.date,
        widget.entity,
        beforeId: more && _rows.isNotEmpty ? _rows.last['id'].toString() : null,
        before: more && _rows.isNotEmpty
            ? _rows.last['created_at'].toString()
            : null,
      );
      if (mounted) {
        setState(() {
          _rows = [...(more ? _rows : <Map<String, dynamic>>[]), ...rows];
          _more = rows.length == 20;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = t(
            '배치를 불러오지 못했습니다.',
            'Không tải được lô báo cáo.',
            'Could not load reporting batches.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _act(Map<String, dynamic> row, String action) async {
    var channel = '', recipient = '', reference = '', reason = '';
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(
            action == 'confirm'
                ? t(
                    '대표 매출 확인',
                    'Chủ doanh nghiệp xác nhận doanh thu',
                    'Owner sales confirmation',
                  )
                : action == 'reported'
                ? t(
                    '외부 신고 증거 기록',
                    'Ghi nhận bằng chứng nộp báo cáo',
                    'Record external reporting evidence',
                  )
                : t('미신고 배치 취소', 'Hủy lô chưa nộp', 'Void unreported batch'),
          ),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${widget.date} · ${row['receipt_count']} · ${row['gross']} VND',
                  ),
                  SelectableText(
                    '${row['id']}\n${t('파일 해시 (SHA-256)', 'Mã băm tệp (SHA-256)', 'File hash (SHA-256)')}: ${row['file_sha256'] ?? '—'}',
                  ),
                  if (action == 'confirm')
                    Text(
                      t(
                        '다운로드한 파일의 내역과 합계를 확인한 후 확정하십시오. 외부 신고는 별도로 기록합니다.',
                        'Kiểm tra nội dung và tổng tiền trong file đã tải trước khi xác nhận. Việc nộp báo cáo được ghi nhận riêng.',
                        'Review the downloaded file and totals before confirming. External reporting is recorded separately.',
                      ),
                    ),
                  if (action == 'reported') ...[
                    TextField(
                      decoration: InputDecoration(
                        labelText: t('신고 채널', 'Kênh nộp', 'Reporting channel'),
                      ),
                      maxLength: 80,
                      onChanged: (v) => update(() => channel = v),
                    ),
                    TextField(
                      decoration: InputDecoration(
                        labelText: t(
                          '수신 기관·담당자',
                          'Nơi/người nhận',
                          'Recipient',
                        ),
                      ),
                      maxLength: 200,
                      onChanged: (v) => update(() => recipient = v),
                    ),
                    TextField(
                      decoration: InputDecoration(
                        labelText: t(
                          '접수 번호·증거 참조',
                          'Mã tiếp nhận/bằng chứng',
                          'Receipt/evidence reference',
                        ),
                      ),
                      maxLength: 1000,
                      onChanged: (v) => update(() => reference = v),
                    ),
                  ],
                  if (action == 'void')
                    TextField(
                      decoration: InputDecoration(
                        labelText: t('취소 사유', 'Lý do hủy', 'Reason'),
                      ),
                      maxLength: 1000,
                      onChanged: (v) => update(() => reason = v),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('돌아가기', 'Quay lại', 'Back')),
            ),
            FilledButton(
              onPressed:
                  (action == 'reported' &&
                          [
                            channel,
                            recipient,
                            reference,
                          ].any((v) => v.trim().isEmpty)) ||
                      (action == 'void' && reason.trim().length < 5)
                  ? null
                  : () => Navigator.pop(context, true),
              child: Text(t('기록', 'Ghi nhận', 'Record')),
            ),
          ],
        ),
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.update(row['id'].toString(), action, {
        if (action != 'void') 'sha256': row['file_sha256'],
        if (action == 'reported') ...{
          'channel': channel.trim(),
          'recipient': recipient.trim(),
          'reference': reference.trim(),
        },
        if (action == 'void') 'reason': reason.trim(),
      });
      await _load();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = t(
            '상태가 변경되었거나 이미 확인된 영수증이 있습니다. 새로 조회해 대사한 후 진행하십시오.',
            'Dữ liệu đã đổi hoặc hóa đơn đã được xác nhận. Tải lại và đối chiếu trước khi tiếp tục.',
            'Data changed or receipts were already confirmed. Refresh and reconcile before continuing.',
          );
        });
      }
    }
  }

  String status(String s) => switch (s) {
    'draft' => t('파일 생성 전', 'Chưa tạo file', 'Draft'),
    'generated' => t('파일 생성됨', 'Đã tạo file', 'File generated'),
    'confirmed' => t(
      '대표 확인됨',
      'Chủ doanh nghiệp đã xác nhận',
      'Owner confirmed',
    ),
    'reported' => t(
      '외부 신고 증거 기록됨',
      'Đã ghi nhận bằng chứng nộp',
      'External evidence recorded',
    ),
    _ => t('취소됨', 'Đã hủy', 'Voided'),
  };
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      t(
        '신고 배치·대표 확인',
        'Lô báo cáo và xác nhận',
        'Reporting batches and confirmation',
      ),
    ),
    content: SizedBox(
      width: 760,
      height: 520,
      child: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Text(_error!),
          Expanded(
            child: ListView(
              children: [
                if (!_busy && _rows.isEmpty)
                  Text(
                    t(
                      '생성된 배치가 없습니다.',
                      'Chưa có lô báo cáo.',
                      'No reporting batches yet.',
                    ),
                  ),
                for (final row in _rows)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${status(row['status'].toString())} · ${row['receipt_count']} · ${row['gross']} VND',
                          ),
                          SelectableText(
                            '${row['id']}\n${t('파일 해시 (SHA-256)', 'Mã băm tệp (SHA-256)', 'File hash (SHA-256)')}: ${row['file_sha256'] ?? '—'}',
                          ),
                          if (row['confirmed_at'] != null)
                            Text(
                              '${row['confirmed_at']} · ${row['confirmed_by']}',
                            ),
                          if (row['external_evidence'] is Map)
                            Text('${row['external_evidence']}'),
                          Wrap(
                            spacing: 8,
                            children: [
                              if (row['status'] == 'generated')
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _act(row, 'confirm'),
                                  child: Text(
                                    t(
                                      '대표 확인',
                                      'Chủ doanh nghiệp xác nhận',
                                      'Owner confirm',
                                    ),
                                  ),
                                ),
                              if (row['status'] == 'confirmed')
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _act(row, 'reported'),
                                  child: Text(
                                    t(
                                      '외부 신고 증거',
                                      'Bằng chứng nộp báo cáo',
                                      'External evidence',
                                    ),
                                  ),
                                ),
                              if ([
                                'draft',
                                'generated',
                                'confirmed',
                              ].contains(row['status']))
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _act(row, 'void'),
                                  child: Text(
                                    t(
                                      '미신고 배치 취소',
                                      'Hủy lô chưa nộp',
                                      'Void unreported batch',
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                if (_more)
                  TextButton(
                    onPressed: _busy ? null : () => _load(more: true),
                    child: Text(t('더 보기', 'Xem thêm', 'More')),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : _load,
        child: Text(t('새로고침', 'Tải lại', 'Refresh')),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(t('닫기', 'Đóng', 'Close')),
      ),
    ],
  );
}
