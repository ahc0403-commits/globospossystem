import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../store_setup_models.dart';

class WorkforceSetupCard extends StatelessWidget {
  const WorkforceSetupCard({
    super.key,
    required this.store,
    required this.readiness,
    required this.isSaving,
    required this.onSave,
    required this.onRefresh,
    required this.onProvision,
  });

  final Map<String, dynamic> store;
  final Map<String, dynamic>? readiness;
  final bool isSaving;
  final Future<bool> Function({
    required String shortCode,
    required String managementModel,
    required int brandManagerSlots,
    required List<WorkforceAccountTemplate> accountTemplates,
  })
  onSave;
  final Future<void> Function() onRefresh;
  final Future<bool> Function({
    required String requirementId,
    required String password,
  })
  onProvision;

  @override
  Widget build(BuildContext context) {
    final accountsReady = readiness?['accounts_ready'] == true;
    final templatesReady = readiness?['account_templates_configured'] == true;
    final employees = (readiness?['employees_active'] as num?)?.toInt() ?? 0;
    final missing = (readiness?['missing_accounts'] as List? ?? const [])
        .whereType<Map>()
        .map((value) => Map<String, dynamic>.from(value))
        .toList(growable: false);
    final shortCode =
        readiness?['short_code']?.toString().trim().isNotEmpty == true
        ? readiness!['short_code'].toString()
        : store['short_code']?.toString() ?? '-';
    final managementModel = readiness?['management_model']?.toString();

    return Card(
      key: const Key('store_setup_workforce_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    context.l10n.storeSetupWorkforceTitle,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Chip(
                  avatar: Icon(
                    accountsReady ? Icons.check_circle : Icons.warning_amber,
                    size: 18,
                  ),
                  label: Text(
                    accountsReady
                        ? context.l10n.storeSetupAccountsReady
                        : context.l10n.storeSetupAccountsNotReady,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(context.l10n.storeSetupWorkforceSubtitle),
            const SizedBox(height: 12),
            Text(
              context.l10n.storeSetupOwnerReference(
                WorkforcePresetCatalog.andreEmail,
                context.l10n.storeSetupSuperAdminRole,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 18,
              runSpacing: 8,
              children: [
                Text(context.l10n.storeSetupShortCodeValue(shortCode)),
                Text(
                  context.l10n.storeSetupManagementModelValue(
                    _managementModelLabel(context, managementModel),
                  ),
                ),
                Text(context.l10n.storeSetupActiveEmployeeCount(employees)),
                Text(
                  templatesReady
                      ? context.l10n.storeSetupTemplatesConfigured
                      : context.l10n.storeSetupTemplatesNotConfigured,
                ),
              ],
            ),
            if (missing.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(context.l10n.storeSetupMissingAccountsTitle),
              for (final account in missing)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(account['email']?.toString() ?? '-'),
                  subtitle: Text(
                    context.l10n.storeSetupAccountCodeValue(
                      account['account_code']?.toString() ?? '-',
                    ),
                  ),
                  trailing: FilledButton(
                    key: ValueKey(
                      'store_setup_provision_${account['requirement_id']}',
                    ),
                    onPressed: () => _openProvisionDialog(context, account),
                    child: Text(context.l10n.storeSetupProvisionAccount),
                  ),
                ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.icon(
                  key: const Key('store_setup_configure_workforce'),
                  onPressed: isSaving ? null : () => _openEditor(context),
                  icon: const Icon(Icons.manage_accounts_outlined),
                  label: Text(context.l10n.storeSetupConfigureWorkforce),
                ),
                OutlinedButton.icon(
                  onPressed: isSaving ? null : onRefresh,
                  icon: const Icon(Icons.refresh),
                  label: Text(context.l10n.storeSetupRefreshWorkforce),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openEditor(BuildContext outerContext) async {
    final shortCodeController = TextEditingController(
      text:
          readiness?['short_code']?.toString() ??
          store['short_code']?.toString() ??
          '',
    );
    final slotsController = TextEditingController(
      text:
          (readiness?['brand_manager_slots'] as num?)?.toInt().toString() ??
          '0',
    );
    var managementModel =
        readiness?['management_model']?.toString() ?? 'store_managed';
    var templates = _templatesFromReadiness(readiness);
    String? validation;

    await showDialog<void>(
      context: outerContext,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(context.l10n.storeSetupConfigureWorkforce),
          content: SizedBox(
            width: 860,
            height: MediaQuery.sizeOf(context).height * 0.68,
            child: ListView(
              children: [
                TextField(
                  key: const Key('store_setup_short_code_field'),
                  controller: shortCodeController,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
                    LengthLimitingTextInputFormatter(6),
                  ],
                  decoration: InputDecoration(
                    labelText: context.l10n.storeSetupShortCode,
                    helperText: context.l10n.storeSetupShortCodeHint,
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: managementModel,
                  decoration: InputDecoration(
                    labelText: context.l10n.storeSetupManagementModel,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'store_managed',
                      child: Text(context.l10n.storeSetupStoreManaged),
                    ),
                    DropdownMenuItem(
                      value: 'brand_centralized',
                      child: Text(context.l10n.storeSetupBrandCentralized),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => managementModel = value);
                    }
                  },
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: slotsController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: context.l10n.storeSetupBrandManagerSlots,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      key: const Key('store_setup_photo_workforce_preset'),
                      onPressed: () => setDialogState(() {
                        managementModel = 'brand_centralized';
                        slotsController.text = '2';
                        templates = WorkforcePresetCatalog.photo(
                          shortCodeController.text,
                        );
                      }),
                      child: Text(context.l10n.storeSetupPhotoPreset),
                    ),
                    OutlinedButton(
                      key: const Key('store_setup_bunsik_workforce_preset'),
                      onPressed: () => setDialogState(() {
                        managementModel = 'store_managed';
                        slotsController.text = '1';
                        templates = WorkforcePresetCatalog.bunsik(
                          shortCodeController.text,
                        );
                      }),
                      child: Text(context.l10n.storeSetupBunsikPreset),
                    ),
                    OutlinedButton.icon(
                      key: const Key('store_setup_add_account_template'),
                      onPressed: () => setDialogState(() {
                        templates = [
                          ...templates,
                          const WorkforceAccountTemplate(
                            accountCode: '',
                            accountType: 'store_operator',
                            role: 'photo_objet_store_operator',
                            displayName: '',
                            scope: 'store',
                          ),
                        ];
                      }),
                      icon: const Icon(Icons.add),
                      label: Text(context.l10n.storeSetupAddAccountTemplate),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                for (var index = 0; index < templates.length; index++)
                  _TemplateEditor(
                    key: ValueKey('$index-${templates[index].accountCode}'),
                    index: index,
                    template: templates[index],
                    onChanged: (value) => templates[index] = value,
                    onRemove: () => setDialogState(() {
                      templates = [...templates]..removeAt(index);
                    }),
                  ),
                if (validation != null)
                  Text(
                    validation!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              key: const Key('store_setup_save_workforce'),
              onPressed: () async {
                final shortCode = shortCodeController.text.trim().toUpperCase();
                final invalidTemplate = templates.any(
                  (template) =>
                      !RegExp(
                        r'^[a-z0-9_]+$',
                      ).hasMatch(template.accountCode.trim().toLowerCase()) ||
                      template.displayName.trim().isEmpty ||
                      !const ['brand', 'store'].contains(template.scope),
                );
                if (!RegExp(r'^[A-Z0-9]{2,6}$').hasMatch(shortCode) ||
                    templates.isEmpty ||
                    invalidTemplate) {
                  setDialogState(
                    () => validation = context.l10n.storeSetupWorkforceInvalid,
                  );
                  return;
                }
                final saved = await onSave(
                  shortCode: shortCode,
                  managementModel: managementModel,
                  brandManagerSlots: int.tryParse(slotsController.text) ?? 0,
                  accountTemplates: templates,
                );
                if (!dialogContext.mounted) return;
                if (saved) Navigator.of(dialogContext).pop();
              },
              child: Text(context.l10n.save),
            ),
          ],
        ),
      ),
    );

    await Future<void>.delayed(kThemeAnimationDuration);
    shortCodeController.dispose();
    slotsController.dispose();
  }

  Future<void> _openProvisionDialog(
    BuildContext outerContext,
    Map<String, dynamic> account,
  ) async {
    final requirementId = account['requirement_id']?.toString() ?? '';
    final email = account['email']?.toString() ?? '-';
    final passwordController = TextEditingController();
    final confirmationController = TextEditingController();
    String? validation;
    var isSubmitting = false;

    await showDialog<void>(
      context: outerContext,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          key: const Key('store_setup_provision_account_dialog'),
          title: Text(context.l10n.storeSetupProvisionAccountTitle(email)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(context.l10n.storeSetupProvisionPasswordHint),
              const SizedBox(height: 12),
              TextField(
                key: const Key('store_setup_provision_password'),
                controller: passwordController,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(labelText: context.l10n.password),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('store_setup_provision_password_confirmation'),
                controller: confirmationController,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: context.l10n.storeSetupConfirmPassword,
                ),
              ),
              if (validation != null) ...[
                const SizedBox(height: 8),
                Text(
                  validation!,
                  key: const Key('store_setup_provision_error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: isSubmitting
                  ? null
                  : () => Navigator.of(dialogContext).pop(),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              key: const Key('store_setup_provision_submit'),
              onPressed: isSubmitting
                  ? null
                  : () async {
                      final password = passwordController.text;
                      if (requirementId.isEmpty || password.length < 12) {
                        setDialogState(
                          () => validation =
                              context.l10n.storeSetupPasswordMinimum,
                        );
                        return;
                      }
                      if (password != confirmationController.text) {
                        setDialogState(
                          () => validation =
                              context.l10n.storeSetupPasswordMismatch,
                        );
                        return;
                      }
                      setDialogState(() {
                        isSubmitting = true;
                        validation = null;
                      });
                      final provisioned = await onProvision(
                        requirementId: requirementId,
                        password: password,
                      );
                      if (!dialogContext.mounted) return;
                      if (provisioned) {
                        passwordController.clear();
                        confirmationController.clear();
                        Navigator.of(dialogContext).pop();
                        return;
                      }
                      setDialogState(() {
                        isSubmitting = false;
                        validation =
                            context.l10n.storeSetupProvisionAccountFailed;
                      });
                    },
              child: isSubmitting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(context.l10n.storeSetupProvisionAccount),
            ),
          ],
        ),
      ),
    );

    passwordController.clear();
    confirmationController.clear();
    await Future<void>.delayed(kThemeAnimationDuration);
    passwordController.dispose();
    confirmationController.dispose();
  }
}

class _TemplateEditor extends StatefulWidget {
  const _TemplateEditor({
    super.key,
    required this.index,
    required this.template,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final WorkforceAccountTemplate template;
  final ValueChanged<WorkforceAccountTemplate> onChanged;
  final VoidCallback onRemove;

  @override
  State<_TemplateEditor> createState() => _TemplateEditorState();
}

class _TemplateEditorState extends State<_TemplateEditor> {
  late final TextEditingController _code;
  late final TextEditingController _name;
  late String _accountType;
  late String _role;
  late String _scope;

  @override
  void initState() {
    super.initState();
    _code = TextEditingController(text: widget.template.accountCode);
    _name = TextEditingController(text: widget.template.displayName);
    _accountType = _accountTypes.contains(widget.template.accountType)
        ? widget.template.accountType
        : 'store_operator';
    final allowedRoles = _rolesForAccountType(_accountType);
    _role = allowedRoles.contains(widget.template.role)
        ? widget.template.role
        : allowedRoles.first;
    _scope = widget.template.scope;
  }

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged(
    WorkforceAccountTemplate(
      accountCode: _code.text,
      accountType: _accountType,
      role: _role,
      displayName: _name.text,
      scope: _scope,
    ),
  );

  @override
  Widget build(BuildContext context) => Card.outlined(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.storeSetupAccountTemplateNumber(
                    widget.index + 1,
                  ),
                ),
              ),
              IconButton(
                onPressed: widget.onRemove,
                icon: const Icon(Icons.delete_outline),
                tooltip: context.l10n.remove,
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _field(context.l10n.storeSetupAccountCode, _code, width: 180),
              SizedBox(
                width: 190,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('store_setup_account_type_${widget.index}'),
                  initialValue: _accountType,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: context.l10n.storeSetupAccountType,
                  ),
                  items: [
                    for (final value in _accountTypes)
                      DropdownMenuItem(
                        value: value,
                        child: Text(_accountTypeLabel(context, value)),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _accountType = value;
                      final roles = _rolesForAccountType(value);
                      if (!roles.contains(_role)) _role = roles.first;
                      _scope = value == 'brand_manager' ? 'brand' : 'store';
                    });
                    _emit();
                  },
                ),
              ),
              SizedBox(
                width: 210,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('store_setup_account_role_${widget.index}'),
                  initialValue: _role,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: context.l10n.storeSetupAccountRole,
                  ),
                  items: [
                    for (final value in _rolesForAccountType(_accountType))
                      DropdownMenuItem(
                        value: value,
                        child: Text(_accountRoleLabel(context, value)),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _role = value);
                    _emit();
                  },
                ),
              ),
              _field(
                context.l10n.storeSetupAccountDisplayName,
                _name,
                width: 220,
              ),
              SizedBox(
                width: 150,
                child: DropdownButtonFormField<String>(
                  initialValue: _scope,
                  decoration: InputDecoration(
                    labelText: context.l10n.storeSetupAccountScope,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'brand',
                      child: Text(context.l10n.storeSetupScopeBrand),
                    ),
                    DropdownMenuItem(
                      value: 'store',
                      child: Text(context.l10n.storeSetupScopeStore),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    _scope = value;
                    _emit();
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _field(
    String label,
    TextEditingController controller, {
    required double width,
  }) => SizedBox(
    width: width,
    child: TextField(
      controller: controller,
      onChanged: (_) => _emit(),
      decoration: InputDecoration(labelText: label),
    ),
  );
}

List<WorkforceAccountTemplate> _templatesFromReadiness(
  Map<String, dynamic>? readiness,
) {
  final raw = readiness?['required_accounts'];
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map(
        (row) =>
            WorkforceAccountTemplate.fromJson(Map<String, dynamic>.from(row)),
      )
      .toList(growable: true);
}

String _managementModelLabel(BuildContext context, String? value) =>
    switch (value) {
      'brand_centralized' => context.l10n.storeSetupBrandCentralized,
      'store_managed' => context.l10n.storeSetupStoreManaged,
      _ => context.l10n.storeSetupNotConfigured,
    };

const _accountTypes = <String>[
  'brand_manager',
  'store_manager',
  'device_pos',
  'device_tablet',
  'device_kitchen',
  'store_operator',
];

List<String> _rolesForAccountType(String accountType) => switch (accountType) {
  'brand_manager' => const ['brand_admin', 'photo_objet_master'],
  'store_manager' => const ['store_admin'],
  'device_pos' || 'device_tablet' => const ['cashier'],
  'device_kitchen' => const ['kitchen'],
  _ => const ['photo_objet_store_operator'],
};

String _accountTypeLabel(BuildContext context, String value) => switch (value) {
  'brand_manager' => context.l10n.storeSetupAccountTypeBrandManager,
  'store_manager' => context.l10n.storeSetupAccountTypeStoreManager,
  'device_pos' => context.l10n.storeSetupAccountTypePosDevice,
  'device_tablet' => context.l10n.storeSetupAccountTypeTabletDevice,
  'device_kitchen' => context.l10n.storeSetupAccountTypeKitchenDevice,
  _ => context.l10n.storeSetupAccountTypeStoreOperator,
};

String _accountRoleLabel(BuildContext context, String value) => switch (value) {
  'brand_admin' => context.l10n.roleBrandAdminMenu,
  'store_admin' => context.l10n.roleStoreAdminMenu,
  'cashier' => context.l10n.roleCashierMenu,
  'kitchen' => context.l10n.roleKitchenMenu,
  'photo_objet_master' => context.l10n.rolePhotoObjetMasterMenu,
  _ => context.l10n.rolePhotoObjetStoreOperatorMenu,
};
