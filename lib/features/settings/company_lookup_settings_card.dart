import 'package:flutter/material.dart';
import '../../core/services/company_tax_lookup_service.dart';
import '../red_invoice_intake/company_lookup_copy.dart';

/// Shared by store settings and the opening checklist; the RPC enforces access.
class CompanyLookupSettingsCard extends StatefulWidget {
  const CompanyLookupSettingsCard({
    super.key,
    required this.storeId,
    this.service,
  });
  final String storeId;
  final CompanyTaxLookupService? service;
  @override
  State<CompanyLookupSettingsCard> createState() =>
      _CompanyLookupSettingsCardState();
}

class _CompanyLookupSettingsCardState extends State<CompanyLookupSettingsCard> {
  CompanyTaxLookupService get _service =>
      widget.service ?? companyTaxLookupService;
  late Future<CompanyLookupSetting> _future = _service.status(widget.storeId);
  bool _saving = false;
  String? _error;
  int _revision = 0;

  @override
  void didUpdateWidget(CompanyLookupSettingsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storeId != widget.storeId ||
        oldWidget.service != widget.service) {
      _revision++;
      _saving = false;
      _error = null;
      _future = _service.status(widget.storeId);
    }
  }

  Future<void> _save(bool enabled, CompanyLookupCopy copy) async {
    final revision = ++_revision;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await _service.setEnabled(widget.storeId, enabled);
      if (!mounted || revision != _revision) return;
      setState(() {
        _future = Future.value(result);
      });
    } catch (_) {
      if (!mounted || revision != _revision) return;
      setState(() {
        _error = copy.saveFailed;
        _future = _service.status(widget.storeId);
      });
    } finally {
      if (mounted && revision == _revision) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = CompanyLookupCopy(
      Localizations.localeOf(context).languageCode,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              copy.settingTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(copy.nameOnly),
            FutureBuilder<CompanyLookupSetting>(
              future: _future,
              builder: (context, snapshot) {
                final setting = snapshot.data;
                if (setting == null) return Text(copy.checking);
                final available = {
                  CompanyLookupAvailability.enabled,
                  CompanyLookupAvailability.disabled,
                }.contains(setting.availability);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (available) ...[
                      SwitchListTile.adaptive(
                        key: const Key('company_lookup_setting_switch'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(copy.enabled),
                        value:
                            setting.availability ==
                            CompanyLookupAvailability.enabled,
                        onChanged: setting.canManage && !_saving
                            ? (value) => _save(value, copy)
                            : null,
                      ),
                      if (!setting.configured) ...[
                        Text(copy.missing),
                        if (setting.canManage)
                          TextButton(
                            onPressed: _saving
                                ? null
                                : () => _save(false, copy),
                            child: Text(copy.manualOnly),
                          ),
                      ],
                      if (!setting.canManage) Text(copy.managed),
                    ] else
                      Text(
                        copy.failure(
                          setting.availability ==
                                  CompanyLookupAvailability.forbidden
                              ? CompanyLookupOutcome.forbidden
                              : CompanyLookupOutcome.unavailable,
                        ),
                      ),
                    if (_error != null)
                      Text(
                        _error!,
                        key: const Key('company_lookup_setting_error'),
                      ),
                    TextButton(
                      onPressed: _saving
                          ? null
                          : () => setState(() {
                              _error = null;
                              _future = _service.status(widget.storeId);
                            }),
                      child: Text(copy.refresh),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
