import 'dart:async';
import 'package:flutter/material.dart';

typedef ProcurementCatalogLoader =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> query);

class ProcurementProductPicker extends StatefulWidget {
  const ProcurementProductPicker({
    super.key,
    required this.products,
    this.loadCatalog,
  });
  final List<Map<String, dynamic>> products;
  final ProcurementCatalogLoader? loadCatalog;

  @override
  State<ProcurementProductPicker> createState() => _PickerState();
}

class _PickerState extends State<ProcurementProductPicker> {
  final _search = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>> _rows = [];
  List<Map<String, dynamic>> _supplierItems = [];
  bool _loading = false, _more = false, _failed = false;
  String? _after;
  final _history = <String?>[];
  int _generation = 0;
  Map<String, dynamic>? _queued;

  String t(String ko, String en, String vi) =>
      switch (Localizations.localeOf(context).languageCode) {
        'ko' => ko,
        'vi' => vi,
        _ => en,
      };

  @override
  void initState() {
    super.initState();
    _rows = widget.products;
    if (widget.loadCatalog != null) _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final query = <String, dynamic>{
      'catalog_only': true,
      'catalog_search': _search.text.trim(),
      if (_after != null) 'catalog_after': _after,
    };
    final generation = ++_generation;
    if (_loading) {
      _queued = query;
      return;
    }
    if (widget.loadCatalog == null) {
      final search = _search.text.trim().toLowerCase();
      setState(
        () => _rows = widget.products.where((p) {
          return '${p['name']} ${p['product_code'] ?? ''}'
              .toLowerCase()
              .contains(search);
        }).toList(),
      );
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final result = await widget.loadCatalog!(query);
      if (!mounted || generation != _generation) return;
      setState(() {
        _rows = (result['products'] as List? ?? [])
            .map((p) => Map<String, dynamic>.from(p as Map))
            .toList();
        _supplierItems = (result['supplier_items'] as List? ?? [])
            .map((p) => Map<String, dynamic>.from(p as Map))
            .toList();
        _more = result['catalog_has_more'] == true;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _failed = true);
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        if (_queued != null) {
          _queued = null;
          _load();
        }
      }
    }
  }

  void _changed(String _) {
    // Invalidate the in-flight result immediately, before the debounce expires.
    _generation++;
    _debounce?.cancel();
    _after = null;
    _history.clear();
    _debounce = Timer(const Duration(milliseconds: 300), _load);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t('원료 선택', 'Choose material', 'Chọn nguyên liệu')),
    content: SizedBox(
      width: 650,
      height:
          ((MediaQuery.sizeOf(context).height -
                      MediaQuery.viewInsetsOf(context).bottom) *
                  .55)
              .clamp(100.0, 600.0)
              .toDouble(),
      child: Column(
        children: [
          TextField(
            key: const Key('procurement_product_search'),
            controller: _search,
            autofocus: true,
            decoration: InputDecoration(
              labelText: t(
                '원료명·원료코드 검색',
                'Material name or code',
                'Tên hoặc mã nguyên liệu',
              ),
              prefixIcon: const Icon(Icons.search),
            ),
            onChanged: _changed,
            onSubmitted: (_) {
              _debounce?.cancel();
              _load();
            },
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_failed)
            TextButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: Text(
                t(
                  '조회 실패 · 재시도',
                  'Search failed · retry',
                  'Tìm kiếm lỗi · thử lại',
                ),
              ),
            ),
          Expanded(
            child: _rows.isEmpty && !_loading
                ? Center(
                    child: Text(
                      t('검색 결과 없음', 'No results', 'Không có kết quả'),
                    ),
                  )
                : ListView.builder(
                    itemCount: _rows.length,
                    itemBuilder: (context, index) {
                      final p = _rows[index];
                      return ListTile(
                        title: Text(p['name']?.toString() ?? ''),
                        subtitle: Text(
                          '${p['product_code'] ?? '—'} · ${t('현재고', 'Stock', 'Tồn kho')}: ${p['current_stock'] ?? '—'} ${p['base_unit'] ?? ''}',
                        ),
                        onTap: _loading || _failed
                            ? null
                            : () => Navigator.pop(context, {
                                'product': p,
                                'supplier_items': _supplierItems
                                    .where((i) => i['product_id'] == p['id'])
                                    .toList(),
                              }),
                      );
                    },
                  ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (_history.isNotEmpty)
                TextButton(
                  onPressed: _loading
                      ? null
                      : () {
                          _after = _history.removeLast();
                          _load();
                        },
                  child: Text(t('이전', 'Previous', 'Trước')),
                ),
              if (_more)
                TextButton(
                  onPressed: _loading
                      ? null
                      : () {
                          _history.add(_after);
                          _after = _rows.last['id'].toString();
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
        child: Text(t('취소', 'Cancel', 'Hủy')),
      ),
    ],
  );
}
