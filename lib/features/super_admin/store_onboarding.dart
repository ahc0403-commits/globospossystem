import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../main.dart';
import 'brand_dialog.dart';
import 'super_admin_provider.dart';

String _loginEmail(Map<dynamic, dynamic> item) =>
    '${item['account_code']}@globos.world';

class StoreOnboardingService {
  StoreOnboardingService(this.client);
  final SupabaseClient client;

  Future<List<Map<String, dynamic>>> preview(
    String brand,
    String code,
    List<String> floors,
  ) async =>
      (await client.rpc(
                'admin_preview_store_accounts_v1',
                params: {
                  'p_brand_id': brand,
                  'p_code': code,
                  'p_floors': floors,
                },
              )
              as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();

  Future<String> create(Map<String, dynamic> input) async => (await client.rpc(
    'admin_create_store_onboarding_v1',
    params: input,
  )).toString();

  Future<Map<String, dynamic>?> forStore(String store) async {
    final data = await client.rpc(
      'admin_store_onboarding_for_store_v1',
      params: {'p_store_id': store},
    );
    return data == null ? null : Map<String, dynamic>.from(data as Map);
  }

  Future<Map<String, dynamic>> status(String job) async =>
      Map<String, dynamic>.from(
        await client.rpc(
              'admin_store_onboarding_status_v1',
              params: {'p_job_id': job},
            )
            as Map,
      );

  Future<Map<String, dynamic>> run(String job) async {
    await client.functions.invoke(
      'store-account-onboarding',
      body: {'job_id': job, 'retry': true},
    );
    return Map<String, dynamic>.from(
      await client.rpc(
            'admin_store_onboarding_status_v1',
            params: {'p_job_id': job},
          )
          as Map,
    );
  }
}

final storeOnboardingServiceProvider = Provider(
  (ref) => StoreOnboardingService(supabase),
);

class StoreOnboardingDialog extends ConsumerStatefulWidget {
  const StoreOnboardingDialog({super.key, this.storeId});
  final String? storeId;
  @override
  ConsumerState<StoreOnboardingDialog> createState() => _StoreOnboardingState();
}

class _StoreOnboardingState extends ConsumerState<StoreOnboardingDialog> {
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _code = TextEditingController();
  final _charge = TextEditingController();
  final _request = const Uuid().v4();
  final _form = GlobalKey<FormState>();
  final _floors = <String>{'1F', '2F', '3F'};
  String? _entity;
  String? _brand;
  String _mode = 'standard';
  List<Map<String, dynamic>>? _preview;
  Map<String, dynamic>? _result;
  bool _busy = false;
  bool _created = false;
  bool _failed = false;
  bool _none = false;

  @override
  void initState() {
    super.initState();
    final state = ref.read(superAdminProvider);
    _entity =
        state.selectedTaxEntityId ??
        (state.taxEntities.length == 1 ? state.taxEntities.single.id : null);
    final brands = _entity == null
        ? <Map<String, dynamic>>[]
        : state.brandsForTaxEntity(_entity!);
    _brand = brands.length == 1 ? brands.single['id'].toString() : null;
    if (widget.storeId != null) _load();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(storeOnboardingServiceProvider)
          .forStore(widget.storeId!);
      if (!mounted) return;
      setState(() {
        _result = result;
        _created = result != null;
        _none = result == null;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _previewIds() async {
    if (!_form.currentState!.validate() ||
        _brand == null ||
        _entity == null ||
        _floors.isEmpty) {
      return;
    }
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final rows = await ref
          .read(storeOnboardingServiceProvider)
          .preview(
            _brand!,
            _code.text.trim().toUpperCase(),
            _floors.toList()..sort(),
          );
      if (mounted) setState(() => _preview = rows);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    if (!_created && (!_form.currentState!.validate() || _preview == null)) {
      return;
    }
    setState(() {
      _busy = true;
      _failed = false;
    });
    final service = ref.read(storeOnboardingServiceProvider);
    try {
      if (!_created) {
        await service.create({
          'p_request_id': _request,
          'p_name': _name.text.trim(),
          'p_address': _address.text.trim(),
          'p_code': _code.text.trim().toUpperCase(),
          'p_brand_id': _brand,
          'p_tax_entity_id': _entity,
          'p_floors': _floors.toList()..sort(),
          'p_operation_mode': _mode,
          'p_per_person_charge': _mode == 'standard'
              ? null
              : num.tryParse(_charge.text),
        });
        _created = true;
        await ref
            .read(superAdminProvider.notifier)
            .loadAllRestaurants(force: true);
      }
      final result = await service.run(
        _result?['job_id']?.toString() ?? _request,
      );
      if (mounted) setState(() => _result = result);
    } catch (_) {
      // A lost response can follow a committed store creation. Recover its
      // durable job before allowing another edit or retry.
      try {
        final recovered = await service.status(
          _result?['job_id']?.toString() ?? _request,
        );
        if (!_created) {
          _created = true;
          await ref
              .read(superAdminProvider.notifier)
              .loadAllRestaurants(force: true);
        }
        if (mounted) setState(() => _result = recovered);
      } catch (_) {
        /* The create transaction may not have committed. */
      }
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _code.dispose();
    _charge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(superAdminProvider);
    final brands = _entity == null
        ? <Map<String, dynamic>>[]
        : state.brandsForTaxEntity(_entity!);
    final selected = brands.where((b) => b['id'] == _brand).firstOrNull;
    final items = (_result?['items'] as List?) ?? _preview ?? [];
    final complete = _result?['status'] == 'complete';
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        key: const Key('store_onboarding_dialog'),
        title: Text(
          widget.storeId == null && !_created
              ? l10n.superAdminAddStore
              : l10n.onboardingAccounts,
        ),
        content: SizedBox(
          width: 680,
          child: SingleChildScrollView(
            child: Form(
              key: _form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!_created && widget.storeId == null) ...[
                    TextFormField(
                      key: const Key('store_name'),
                      controller: _name,
                      enabled: !_busy,
                      decoration: InputDecoration(
                        labelText: l10n.superAdminStoreName,
                      ),
                      maxLength: 120,
                      validator: (v) => (v ?? '').trim().isEmpty
                          ? l10n.superAdminStoreName
                          : null,
                    ),
                    TextFormField(
                      key: const Key('store_address'),
                      controller: _address,
                      enabled: !_busy,
                      decoration: InputDecoration(
                        labelText: l10n.superAdminStoreAddress,
                      ),
                      maxLength: 500,
                    ),
                    TextFormField(
                      key: const Key('store_abbreviation'),
                      controller: _code,
                      enabled: !_busy,
                      maxLength: 6,
                      textCapitalization: TextCapitalization.characters,
                      decoration: InputDecoration(
                        labelText: l10n.storeAbbreviation,
                        helperText: l10n.abbreviationHint,
                        helperMaxLines: 3,
                      ),
                      validator: (v) =>
                          RegExp(
                            r'^[A-Z][A-Z0-9]{1,5}$',
                          ).hasMatch((v ?? '').trim().toUpperCase())
                          ? null
                          : l10n.abbreviationError,
                      onChanged: (_) => setState(() => _preview = null),
                    ),
                    DropdownButtonFormField<String>(
                      key: const Key('onboarding_entity'),
                      initialValue: _entity,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: l10n.superAdminLegalEntity,
                      ),
                      items: state.taxEntities
                          .map(
                            (e) => DropdownMenuItem(
                              value: e.id,
                              child: Text(e.name),
                            ),
                          )
                          .toList(),
                      onChanged: _busy
                          ? null
                          : (v) => setState(() {
                              _entity = v;
                              _brand = null;
                              _preview = null;
                            }),
                      validator: (v) => v == null
                          ? l10n.superAdminLegalEntityRequiredBeforeStore
                          : null,
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      key: ValueKey('onboarding_brand_$_entity-$_brand'),
                      initialValue: _brand,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: l10n.superAdminBrand,
                      ),
                      items: brands
                          .map(
                            (b) => DropdownMenuItem(
                              value: b['id'].toString(),
                              child: Text(
                                '${b['name']} (${b['short_code'] ?? '-'})',
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: _busy
                          ? null
                          : (v) => setState(() {
                              _brand = v;
                              _preview = null;
                            }),
                      validator: (v) =>
                          v == null ? l10n.superAdminBrandRequired : null,
                    ),
                    if (selected != null)
                      Text(
                        '${l10n.brandAbbreviation}: ${selected['short_code'] ?? '-'}',
                      ),
                    TextButton(
                      key: const Key('store_add_brand'),
                      onPressed: _busy
                          ? null
                          : () async {
                              final result = await showBrandEditor(
                                context,
                                brand: selected,
                                taxEntityId: _entity,
                              );
                              if (!mounted || result == null) return;
                              setState(() {
                                if ((result['tax_entity_ids'] as List).contains(
                                  _entity,
                                )) {
                                  _brand = result['id'].toString();
                                }
                                _preview = null;
                              });
                            },
                      child: Text(
                        selected == null ? l10n.brandAdd : l10n.brandManagement,
                      ),
                    ),
                    if (selected != null && selected['short_code'] == null)
                      Text(l10n.onboardingBrandCodeRequired),
                    DropdownButtonFormField<String>(
                      initialValue: _mode,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: l10n.superAdminOperationMode,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'standard',
                          child: Text(l10n.superAdminOperationModeStandard),
                        ),
                        DropdownMenuItem(
                          value: 'buffet',
                          child: Text(l10n.superAdminOperationModeBuffet),
                        ),
                        DropdownMenuItem(
                          value: 'hybrid',
                          child: Text(l10n.superAdminOperationModeHybrid),
                        ),
                      ],
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _mode = v!),
                    ),
                    if (_mode != 'standard')
                      TextFormField(
                        controller: _charge,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: l10n.superAdminPerPersonCharge,
                        ),
                        validator: (v) => (num.tryParse(v ?? '') ?? 0) > 0
                            ? null
                            : l10n.superAdminPerPersonCharge,
                      ),
                    const SizedBox(height: 12),
                    Text(l10n.onboardingFloors),
                    Wrap(
                      spacing: 8,
                      children: ['1F', '2F', '3F']
                          .map(
                            (floor) => FilterChip(
                              label: Text(floor),
                              selected: _floors.contains(floor),
                              onSelected: _busy
                                  ? null
                                  : (v) => setState(() {
                                      v
                                          ? _floors.add(floor)
                                          : _floors.remove(floor);
                                      _preview = null;
                                    }),
                            ),
                          )
                          .toList(),
                    ),
                    OutlinedButton(
                      key: const Key('onboarding_preview'),
                      onPressed: _busy ? null : _previewIds,
                      child: Text(l10n.onboardingPreview),
                    ),
                  ],
                  Text(l10n.onboardingPasswordHint),
                  const SizedBox(height: 8),
                  Text(l10n.onboardingSharedHint),
                  if (_busy) const LinearProgressIndicator(),
                  if (_none) Text(l10n.onboardingNone),
                  if (_failed || (_created && !complete && !_busy))
                    Text(
                      _created ? l10n.onboardingFailed : l10n.abbreviationError,
                      key: const Key('onboarding_error'),
                    ),
                  if (_result != null) ...[
                    Text(l10n.onboardingProcurement),
                    Text(
                      '${l10n.onboardingAccounting}: ${(_result!['procurement_readiness'] as Map?)?['accounting'] == true ? l10n.onboardingReady : l10n.onboardingNeedsSetup}',
                    ),
                    Text(
                      '${l10n.onboardingBuyer}: ${(_result!['procurement_readiness'] as Map?)?['office_connected'] == true ? l10n.onboardingReady : l10n.onboardingNeedsSetup}',
                    ),
                  ],
                  for (final item in items)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: SelectableText(_loginEmail(item as Map)),
                      subtitle: Text(
                        '${item['display_name'] ?? item['role']} · ${_created ? (item['ready'] == true ? l10n.onboardingReady : l10n.onboardingPending) : item['scope']}',
                      ),
                    ),
                  if (items.isNotEmpty)
                    TextButton.icon(
                      onPressed: () => Clipboard.setData(
                        ClipboardData(
                          text: items
                              .map((i) => _loginEmail(i as Map))
                              .join('\n'),
                        ),
                      ),
                      icon: const Icon(Icons.copy),
                      label: Text(l10n.onboardingCopyIds),
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(l10n.close),
          ),
          if (complete)
            TextButton(
              key: const Key('super_admin_continue_store_setup'),
              onPressed: () {
                final router = GoRouter.of(context);
                Navigator.pop(context);
                router.go('/store-setup/${_result!['store_id']}');
              },
              child: Text(l10n.storeSetupNext),
            ),
          if (!_none && !complete)
            FilledButton(
              key: const Key('onboarding_save'),
              onPressed:
                  _busy ||
                      (!_created && _preview == null && widget.storeId == null)
                  ? null
                  : (widget.storeId != null && !_created ? _load : _save),
              child: Text(_created ? l10n.retry : l10n.save),
            ),
        ],
      ),
    );
  }
}
