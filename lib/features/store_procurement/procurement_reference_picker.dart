import 'package:flutter/material.dart';

typedef ProcurementReferenceLoad =
    Future<Map<String, dynamic>> Function(String? after, String search);

class ProcurementReferencePicker extends StatefulWidget {
  const ProcurementReferencePicker({
    super.key,
    required this.load,
    required this.title,
    this.unit,
  });
  final ProcurementReferenceLoad load;
  final String title;
  final String? unit;
  @override
  State<ProcurementReferencePicker> createState() =>
      _ProcurementReferencePickerState();
}

class _ProcurementReferencePickerState
    extends State<ProcurementReferencePicker> {
  final _search = TextEditingController();
  final _pages = <String?>[null];
  Map<String, dynamic> _data = {};
  bool _busy = true;
  bool _error = false;
  String t(String ko, String en, String vi) =>
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

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = false;
    });
    try {
      final result = await widget.load(_pages.last, _search.text.trim());
      if (mounted) setState(() => _data = result);
    } catch (_) {
      if (mounted) setState(() => _error = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 600,
      height: 400,
      child: Column(
        children: [
          TextField(
            controller: _search,
            decoration: InputDecoration(
              labelText: t('이름·코드 검색', 'Search name/code', 'Tìm tên/mã'),
              suffixIcon: IconButton(
                onPressed: _busy
                    ? null
                    : () {
                        _pages
                          ..clear()
                          ..add(null);
                        _load();
                      },
                icon: const Icon(Icons.search),
              ),
            ),
            onSubmitted: _busy
                ? null
                : (_) {
                    _pages
                      ..clear()
                      ..add(null);
                    _load();
                  },
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error)
            Text(
              t(
                '조회 실패. 다시 검색하세요.',
                'Load failed. Search again.',
                'Tải thất bại. Tìm lại.',
              ),
            ),
          Expanded(
            child: ListView(
              children: [
                for (final row in (_data['rows'] as List? ?? []).cast<Map>())
                  if (widget.unit == null || row['base_unit'] == widget.unit)
                    ListTile(
                      title: Text(
                        '${row['code'] ?? row['name']} v${row['revision']}',
                      ),
                      subtitle: Text(
                        '${row['name']} ${row['specification'] ?? ''}',
                      ),
                      onTap: _busy ? null : () => Navigator.pop(context, row),
                    ),
              ],
            ),
          ),
          Row(
            children: [
              if (_pages.length > 1)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () {
                          _pages.removeLast();
                          _load();
                        },
                  child: Text(t('이전', 'Previous', 'Trước')),
                ),
              if (_data['next_cursor'] != null)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () {
                          _pages.add(_data['next_cursor'].toString());
                          _load();
                        },
                  child: Text(t('다음', 'Next', 'Tiếp')),
                ),
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(t('닫기', 'Close', 'Đóng')),
      ),
    ],
  );
}
