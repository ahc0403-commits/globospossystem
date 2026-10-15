import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'procurement_process_labels.dart';
import 'procurement_presentation.dart';

class ProcurementStockDialog extends StatefulWidget {
  const ProcurementStockDialog({super.key, required this.load});
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) load;
  @override
  State<ProcurementStockDialog> createState() => _ProcurementStockDialogState();
}

class _ProcurementStockDialogState extends State<ProcurementStockDialog> {
  final _search = TextEditingController();
  List<Map<String, dynamic>> _products = [];
  bool _loading = false, _hasMore = false;
  String? _cursor;
  bool _failed = false;
  String _term = '';
  String copy(String key) => procurementProcessLabel(
    key,
    Localizations.localeOf(context).languageCode,
  );
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

  Future<void> _load({bool next = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _failed = false;
      _products = [];
    });
    try {
      final page = await widget.load({
        'catalog_only': true,
        'catalog_search': _term,
        if (next && _cursor != null) 'catalog_after': _cursor,
      });
      final products = (page['products'] as List? ?? [])
          .whereType<Map>()
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
      if (!mounted) return;
      setState(() {
        _products = products;
        _hasMore = page['catalog_has_more'] == true;
        _cursor = products.lastOrNull?['id']?.toString();
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _find() {
    _term = _search.text.trim();
    _cursor = null;
    _load();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(copy('stockLookup')),
    content: SizedBox(
      width: 760,
      height: math.min(560, MediaQuery.sizeOf(context).height * .62),
      child: Column(
        children: [
          TextField(
            controller: _search,
            enabled: !_loading,
            onSubmitted: (_) => _find(),
            decoration: InputDecoration(
              labelText: copy('searchProducts'),
              suffixIcon: IconButton(
                onPressed: _loading ? null : _find,
                icon: const Icon(Icons.search),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_loading) const LinearProgressIndicator(),
          if (_failed) Text(copy('stockLoadFailed')),
          Expanded(
            child: ListView(
              children: [
                if (!_loading && !_failed && _products.isEmpty)
                  Text(copy('noProducts')),
                for (final product in _products)
                  ListTile(
                    title: Text('${product['name'] ?? '—'}'),
                    subtitle: Text(
                      '${product['product_code'] ?? '—'} · ${procurementNumber(product['current_stock'], decimals: 3)} ${product['base_unit'] ?? ''}\n${copy('lastStockUpdate')}: ${procurementDate(product['stock_updated_at'], includeTime: true)}',
                    ),
                    isThreeLine: true,
                  ),
              ],
            ),
          ),
          if (_hasMore)
            TextButton(
              onPressed: _loading ? null : () => _load(next: true),
              child: Text(copy('nextProducts')),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(copy('close')),
      ),
    ],
  );
}
