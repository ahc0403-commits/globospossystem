import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/i18n/locale_extensions.dart';
import '../core/utils/time_utils.dart';

typedef BankTransferPageLoader =
    Future<Map<String, dynamic>> Function(String? afterTime, String? afterId);

class BankTransferLedgerDialog extends StatefulWidget {
  const BankTransferLedgerDialog({super.key, required this.loadPage});
  final BankTransferPageLoader loadPage;
  @override
  State<BankTransferLedgerDialog> createState() =>
      _BankTransferLedgerDialogState();
}

class _BankTransferLedgerDialogState extends State<BankTransferLedgerDialog> {
  bool _loading = true, _error = false, _hasMore = false;
  List<Map<String, dynamic>> _rows = const [];
  String? _afterTime, _afterId;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final page = await widget.loadPage(_afterTime, _afterId);
      final raw = page['rows'];
      if (raw is! List || raw.length > 100) {
        throw const FormatException('BANK_TRANSFER_PAGE_INVALID');
      }
      final rows = raw.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _hasMore = page['has_more'] == true;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AlertDialog(
      key: const Key('bank_transfer_ledger_dialog'),
      insetPadding: const EdgeInsets.all(12),
      title: Text(l.salesDepositBankTitle),
      content: SizedBox(
        width: 600,
        height: 360,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error
            ? Column(
                children: [
                  Text(l.salesDepositUnavailable),
                  TextButton(onPressed: _load, child: Text(l.retry)),
                ],
              )
            : _rows.isEmpty
            ? Text(l.reportsNoPaymentMethodData)
            : ListView(
                children: [
                  for (final row in _rows)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '${row['store_name']}${row['receipt_number'] == null ? '' : ' · ${row['receipt_number']}'}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            '${NumberFormat('#,##0', 'vi_VN').format(row['amount'])} VND',
                          ),
                          Text(
                            DateFormat('yyyy-MM-dd HH:mm').format(
                              TimeUtils.toVietnam(
                                DateTime.parse(row['created_at'] as String),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        if (_hasMore && !_loading && !_error)
          TextButton(
            onPressed: () {
              final last = _rows.last;
              _afterTime = last['created_at'] as String;
              _afterId = last['payment_id'] as String;
              _load();
            },
            child: Text(l.salesDepositNextPage),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.close),
        ),
      ],
    );
  }
}
