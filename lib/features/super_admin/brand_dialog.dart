import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../l10n/app_localizations.dart';
import 'brand_service.dart';
import 'super_admin_provider.dart';

String _brandError(AppLocalizations l10n, Object error) {
  final message = error.toString();
  if (message.contains('ABBREVIATION')) return l10n.abbreviationError;
  if (message.contains('BRAND_CODE_EXISTS')) return l10n.brandCodeExists;
  if (message.contains('BRAND_ADMIN_FORBIDDEN')) return l10n.brandForbidden;
  if (message.contains('BRAND_REQUEST_CONFLICT')) {
    return l10n.brandRequestConflict;
  }
  if (message.contains('BRAND_GROUP_REQUIRED')) return l10n.brandGroupRequired;
  if (message.contains('BRAND_LEGAL_ENTITY_INVALID')) {
    return l10n.brandEntityInvalid;
  }
  return l10n.brandOperationFailed;
}

Future<Map<String, dynamic>?> showBrandEditor(
  BuildContext context, {
  Map<String, dynamic>? brand,
  String? taxEntityId,
}) => showDialog<Map<String, dynamic>>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _BrandEditor(brand: brand, taxEntityId: taxEntityId),
);

class BrandManagementDialog extends ConsumerStatefulWidget {
  const BrandManagementDialog({super.key});
  @override
  ConsumerState<BrandManagementDialog> createState() => _BrandManagementState();
}

class _BrandManagementState extends ConsumerState<BrandManagementDialog> {
  final _search = TextEditingController();
  Timer? _debounce;
  final _items = <Map<String, dynamic>>[];
  Map<String, dynamic>? _cursor;
  bool _hasMore = false;
  bool _loading = false;
  Object? _error;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref
          .read(brandServiceProvider)
          .list(search: _search.text.trim(), after: more ? _cursor : null);
      if (!mounted || request != _request) return;
      setState(() {
        if (!more) _items.clear();
        final ids = _items.map((row) => row['id']).toSet();
        _items.addAll(page.items.where((row) => ids.add(row['id'])));
        _cursor = page.items.isEmpty ? null : page.items.last;
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _edit([Map<String, dynamic>? brand]) async {
    final result = await showBrandEditor(context, brand: brand);
    if (!mounted || result == null) return;
    final entities = ref.read(superAdminProvider).taxEntities;
    final ids = (result['tax_entity_ids'] as List).map((id) => '$id').toSet();
    final updated = {
      ...?brand,
      ...result,
      'store_count': brand?['store_count'] ?? 0,
      'tax_entity_names': entities
          .where((e) => ids.contains(e.id))
          .map((e) => e.name)
          .toList(),
    };
    final query = _search.text.trim().toLowerCase();
    setState(() {
      _items.removeWhere((row) => row['id'] == updated['id']);
      if ('${updated['name']} ${updated['code']}'.toLowerCase().contains(
        query,
      )) {
        _items.insert(0, updated);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      key: const Key('brand_management_dialog'),
      title: Text(l10n.brandManagement),
      content: SizedBox(
        width: 660,
        height: MediaQuery.sizeOf(context).height * .6,
        child: Column(
          children: [
            TextField(
              key: const Key('brand_search'),
              controller: _search,
              maxLength: 100,
              decoration: InputDecoration(
                labelText: l10n.search,
                prefixIcon: const Icon(Icons.search),
              ),
              onChanged: (_) {
                _debounce?.cancel();
                // Invalidate an older response immediately, before debounce fires.
                _request++;
                setState(() => _loading = true);
                _debounce = Timer(const Duration(milliseconds: 350), _load);
              },
            ),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null) ...[
              Text(
                _brandError(l10n, _error!),
                key: const Key('brand_list_error'),
              ),
              TextButton(onPressed: _load, child: Text(l10n.retry)),
            ],
            Expanded(
              child: _items.isEmpty && !_loading && _error == null
                  ? Center(child: Text(l10n.brandListEmpty))
                  : ListView.builder(
                      itemCount: _items.length,
                      itemBuilder: (_, index) {
                        final row = _items[index];
                        final names = (row['tax_entity_names'] as List).join(
                          ', ',
                        );
                        return ListTile(
                          key: ValueKey('brand_row_${row['id']}'),
                          title: Text(
                            '${row['name']} (${row['short_code'] ?? '-'})',
                          ),
                          subtitle: Text(
                            '${l10n.brandStoreCount(row['store_count'] as int)}\n${names.isEmpty ? l10n.brandUnlinked : names}',
                          ),
                          isThreeLine: true,
                          trailing: IconButton(
                            key: ValueKey('brand_link_${row['id']}'),
                            tooltip: l10n.brandLinkEntities,
                            icon: const Icon(Icons.link),
                            onPressed: _loading ? null : () => _edit(row),
                          ),
                        );
                      },
                    ),
            ),
            if (_hasMore)
              TextButton(
                key: const Key('brand_load_more'),
                onPressed: _loading ? null : () => _load(more: true),
                child: Text(l10n.brandLoadMore),
              ),
          ],
        ),
      ),
      actions: [
        IconButton(
          key: const Key('brand_refresh'),
          tooltip: l10n.refresh,
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.close),
        ),
        FilledButton.icon(
          key: const Key('brand_management_add'),
          onPressed: _loading ? null : () => _edit(),
          icon: const Icon(Icons.add),
          label: Text(l10n.brandAdd),
        ),
      ],
    );
  }
}

class _BrandEditor extends ConsumerStatefulWidget {
  const _BrandEditor({this.brand, this.taxEntityId});
  final Map<String, dynamic>? brand;
  final String? taxEntityId;
  @override
  ConsumerState<_BrandEditor> createState() => _BrandEditorState();
}

class _BrandEditorState extends ConsumerState<_BrandEditor> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _code = TextEditingController();
  final _requestId = const Uuid().v4();
  final _selected = <String>{};
  List<Map<String, dynamic>> _groups = [];
  String? _group;
  bool _loading = false;
  bool _saving = false;
  Object? _error;
  bool get _isLink => widget.brand != null;

  @override
  void initState() {
    super.initState();
    _code.text = widget.brand?['short_code']?.toString() ?? '';
    _selected.addAll(
      (widget.brand?['tax_entity_ids'] as List? ?? []).map((id) => '$id'),
    );
    if (widget.taxEntityId != null) _selected.add(widget.taxEntityId!);
    if (!_isLink) _loadGroups();
  }

  Future<void> _loadGroups() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final groups = await ref.read(brandServiceProvider).groups();
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _group = groups.length == 1 ? groups.single['id'].toString() : null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final service = ref.read(brandServiceProvider);
      final result = _isLink
          ? await service.link(
              brandId: widget.brand!['id'].toString(),
              code: _code.text.trim().toUpperCase(),
              taxEntityIds: _selected.toList(),
            )
          : await service.create(
              id: _requestId,
              name: _name.text.trim(),
              code: _code.text.trim().toUpperCase(),
              groupId: _group!,
              taxEntityIds: _selected.toList(),
            );
      if (!mounted) return;
      ref.read(superAdminProvider.notifier).applyBrandMutation(result);
      setState(() => _saving = false);
      Navigator.pop(context, result);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _saving = false;
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(superAdminProvider);
    final linked = (widget.brand?['tax_entity_ids'] as List? ?? [])
        .map((id) => '$id')
        .toSet();
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        key: const Key('brand_editor_dialog'),
        title: Text(_isLink ? l10n.brandLinkEntities : l10n.brandAdd),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Form(
              key: _form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_isLink)
                    Text('${widget.brand!['name']} (${widget.brand!['code']})')
                  else ...[
                    Text(l10n.brandIndependentHint),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const Key('brand_name'),
                      controller: _name,
                      maxLength: 120,
                      enabled: !_saving,
                      decoration: InputDecoration(labelText: l10n.brandName),
                      validator: (value) => (value ?? '').trim().isEmpty
                          ? l10n.brandNameRequired
                          : null,
                    ),
                    const SizedBox(height: 12),
                    if (_loading) const LinearProgressIndicator(),
                    DropdownButtonFormField<String>(
                      key: ValueKey('brand_group_$_group'),
                      initialValue: _group,
                      isExpanded: true,
                      decoration: InputDecoration(labelText: l10n.brandGroup),
                      items: _groups
                          .map(
                            (g) => DropdownMenuItem(
                              value: '${g['id']}',
                              child: Text(
                                '${g['name']} · ${g['company_name']}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: _saving
                          ? null
                          : (value) => setState(() => _group = value),
                      validator: (value) =>
                          value == null ? l10n.brandGroupRequired : null,
                    ),
                    if (!_loading && _groups.isEmpty) Text(l10n.brandNoGroups),
                  ],
                  TextFormField(
                    key: const Key('brand_code'),
                    controller: _code,
                    maxLength: 6,
                    enabled: !_saving,
                    decoration: InputDecoration(
                      labelText: l10n.brandAbbreviation,
                      helperText: l10n.abbreviationHint,
                      helperMaxLines: 3,
                    ),
                    validator: (value) =>
                        RegExp(
                          r'^[A-Z][A-Z0-9]{1,5}$',
                        ).hasMatch((value ?? '').trim().toUpperCase())
                        ? null
                        : l10n.abbreviationError,
                  ),
                  const SizedBox(height: 12),
                  const SizedBox(height: 16),
                  Text(
                    l10n.brandLinkEntities,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(l10n.brandEntityHint),
                  if (state.taxEntities.isEmpty) Text(l10n.brandNoEntities),
                  for (final entity in state.taxEntities)
                    CheckboxListTile(
                      key: ValueKey('brand_entity_${entity.id}'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(entity.name),
                      value: _selected.contains(entity.id),
                      onChanged: _saving || linked.contains(entity.id)
                          ? null
                          : (value) => setState(() {
                              if (value == true) {
                                _selected.add(entity.id);
                              } else {
                                _selected.remove(entity.id);
                              }
                            }),
                    ),
                  if (_error != null) ...[
                    Text(
                      _brandError(l10n, _error!),
                      key: const Key('brand_editor_error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    if (!_isLink && _groups.isEmpty)
                      TextButton(
                        onPressed: _loading ? null : _loadGroups,
                        child: Text(l10n.retry),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const Key('brand_save'),
            onPressed: _saving || _loading || (!_isLink && _groups.isEmpty)
                ? null
                : _save,
            child: Text(_saving ? l10n.brandSaving : l10n.save),
          ),
        ],
      ),
    );
  }
}
