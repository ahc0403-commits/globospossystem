import 'package:flutter/material.dart';
import '../../../core/layout/platform_info.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/hardware/printer_service.dart';
import '../../../core/hardware/receipt_builder.dart';
import '../../../core/i18n/locale_extensions.dart';
import '../../../core/services/pin_service.dart';
import '../../../core/ui/pos_design_tokens.dart';
import '../../../core/ui/toast/toast.dart';
import '../../../main.dart';
import '../../../widgets/error_toast.dart';
import '../../../widgets/pin_dialog.dart';
import '../../auth/auth_provider.dart';
import '../../auth/auth_state.dart';
import '../../settings/printer_provider.dart';
import '../providers/admin_audit_provider.dart';
import '../providers/settings_provider.dart';
import '../widgets/admin_audit_trace_panel.dart';

class SettingsTab extends ConsumerStatefulWidget {
  const SettingsTab({super.key});

  @override
  ConsumerState<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends ConsumerState<SettingsTab> {
  final _restaurantNameController = TextEditingController();
  final _addressController = TextEditingController();
  final _perPersonController = TextEditingController();
  final _fullNameController = TextEditingController();
  final _printerIpController = TextEditingController();
  String _operationMode = 'standard';
  String? _initializedRestaurantId;
  String? _lastError;
  String? _lastPrinterError;
  bool? _hasPayrollPin;
  bool _isSavingPayrollPin = false;
  String _selectedCategory = 'store';

  @override
  void dispose() {
    _restaurantNameController.dispose();
    _addressController.dispose();
    _perPersonController.dispose();
    _fullNameController.dispose();
    _printerIpController.dispose();
    super.dispose();
  }

  Future<void> _loadPayrollPinStatus(String storeId) async {
    try {
      final hash = await pinService.fetchPinHash(storeId);
      if (!mounted) return;
      setState(() => _hasPayrollPin = hash != null && hash.isNotEmpty);
    } catch (_) {
      if (!mounted) return;
      setState(() => _hasPayrollPin = false);
    }
  }

  Future<void> _showSetPayrollPinDialog(String storeId) async {
    final pageContext = context;
    final l10n = context.l10n;
    final pinController = TextEditingController();
    final confirmController = TextEditingController();
    String? validationMessage;

    await showDialog<void>(
      context: context,
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              backgroundColor: AppColors.surface1,
              title: Text(
                l10n.settingsPayrollPinTitle,
                style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: pinController,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: l10n.settingsPayrollPinNew,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: confirmController,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: l10n.settingsPayrollPinConfirm,
                    ),
                  ),
                  if (validationMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      validationMessage!,
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.statusCancelled,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.cancel),
                ),
                FilledButton(
                  onPressed: _isSavingPayrollPin
                      ? null
                      : () async {
                          final pin = pinController.text.trim();
                          final confirm = confirmController.text.trim();
                          final validPin = RegExp(r'^\d{4}$').hasMatch(pin);
                          if (!validPin) {
                            setModalState(
                              () => validationMessage =
                                  l10n.settingsPayrollPinMustBe4Digits,
                            );
                            return;
                          }
                          if (pin != confirm) {
                            setModalState(
                              () => validationMessage =
                                  l10n.settingsPayrollPinConfirmMismatch,
                            );
                            return;
                          }

                          setState(() => _isSavingPayrollPin = true);
                          try {
                            await pinService.setPin(storeId, pin);
                            if (!pageContext.mounted) return;
                            Navigator.of(pageContext).pop();
                            await _loadPayrollPinStatus(storeId);
                            if (!pageContext.mounted) return;
                            showSuccessToast(
                              pageContext,
                              l10n.settingsPayrollPinSaved,
                            );
                          } catch (e) {
                            if (pageContext.mounted) {
                              showErrorToast(
                                pageContext,
                                l10n.settingsPayrollPinSaveFailed('$e'),
                              );
                            }
                          } finally {
                            if (mounted) {
                              setState(() => _isSavingPayrollPin = false);
                            }
                          }
                        },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.amber500,
                    foregroundColor: AppColors.surface0,
                  ),
                  child: _isSavingPayrollPin
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.save),
                ),
              ],
            );
          },
        );
      },
    );

    pinController.dispose();
    confirmController.dispose();
  }

  Future<void> _clearPayrollPin(String storeId) async {
    final entered = await showPinDialog(
      context,
      title: context.l10n.settingsPayrollPinEnterCurrent,
    );
    if (entered == null) return;

    try {
      final ok = await pinService.verifyPin(storeId, entered);
      if (!ok) {
        if (mounted) {
          showErrorToast(context, context.l10n.settingsPayrollPinIncorrect);
        }
        return;
      }
      await pinService.clearPin(storeId);
      await _loadPayrollPinStatus(storeId);
      if (mounted) {
        showSuccessToast(context, context.l10n.settingsPayrollPinDeleted);
      }
    } catch (e) {
      if (mounted) {
        showErrorToast(
          context,
          context.l10n.settingsPayrollPinDeleteFailed('$e'),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final authState = ref.watch(authProvider);
    final authUid = authState.user?.id;
    final storeId = authState.storeId;
    final settingsState = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final printerState = ref.watch(printerProvider);
    final printerNotifier = ref.read(printerProvider.notifier);
    final auditTraceAsync = storeId == null
        ? const AsyncValue<List<Map<String, dynamic>>>.data([])
        : ref.watch(adminAuditTraceProvider(storeId));

    if (storeId != null &&
        authUid != null &&
        storeId != _initializedRestaurantId) {
      _initializedRestaurantId = storeId;
      Future.microtask(() async {
        await notifier.loadSettings(storeId, authUid);
        await _loadPayrollPinStatus(storeId);
      });
    }

    if (!settingsState.isLoading && settingsState.restaurantName.isNotEmpty) {
      if (_restaurantNameController.text != settingsState.restaurantName) {
        _restaurantNameController.text = settingsState.restaurantName;
      }
      if (_addressController.text != settingsState.address) {
        _addressController.text = settingsState.address;
      }
      if (settingsState.perPersonCharge != null &&
          _perPersonController.text !=
              settingsState.perPersonCharge!.toString()) {
        _perPersonController.text = settingsState.perPersonCharge!.toString();
      }
      if (_fullNameController.text != settingsState.fullName) {
        _fullNameController.text = settingsState.fullName;
      }
      _operationMode = settingsState.operationMode;
    }

    if (settingsState.error != null &&
        settingsState.error!.isNotEmpty &&
        settingsState.error != _lastError) {
      _lastError = settingsState.error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showErrorToast(context, settingsState.error!);
        }
      });
    }

    if (_printerIpController.text != printerState.printerIp) {
      _printerIpController.text = printerState.printerIp;
      _printerIpController.selection = TextSelection.fromPosition(
        TextPosition(offset: _printerIpController.text.length),
      );
    }

    if (printerState.error != null &&
        printerState.error!.isNotEmpty &&
        printerState.error != _lastPrinterError) {
      _lastPrinterError = printerState.error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showErrorToast(context, printerState.error!);
        }
      });
    }

    final categories = [
      _SettingsCategory(
        'store',
        l10n.settingsCategoryStore,
        l10n.settingsCategoryStoreSummary,
      ),
      _SettingsCategory(
        'permissions',
        l10n.settingsCategoryPermission,
        l10n.settingsCategoryPermissionSummary,
      ),
      _SettingsCategory(
        'payment',
        l10n.settingsCategoryPayment,
        l10n.settingsCategoryPaymentSummary,
      ),
      _SettingsCategory(
        'receipt',
        l10n.settingsCategoryReceipt,
        l10n.settingsCategoryReceiptSummary,
      ),
      _SettingsCategory(
        'system',
        l10n.settingsCategorySystem,
        l10n.settingsCategorySystemSummary,
      ),
    ];
    final selectedCategory = categories.firstWhere(
      (category) => category.id == _selectedCategory,
      orElse: () => categories.first,
    );
    final printerSyncLabel = switch (printerState.lastTestResult) {
      true => l10n.settingsSyncHealthy,
      false => l10n.settingsSyncNeedsReview,
      null => l10n.settingsSyncUnknown,
    };

    return Scaffold(
      key: const Key('settings_root'),
      backgroundColor: AppColors.surface0,
      body: ToastResponsiveBody(
        maxWidth: 1480,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSettingsConfigurationHeader(
              selectedCategory: selectedCategory,
              settingsState: settingsState,
              authState: authState,
              printerState: printerState,
              printerSyncLabel: printerSyncLabel,
              storeId: storeId,
            ),
            const SizedBox(height: 16),
            Expanded(
              child: settingsState.isLoading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.amber500,
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final categoryPane = _buildCategoryPane(categories);
                        final panel = _buildSettingsPanel(
                          context: context,
                          authState: authState,
                          authUid: authUid,
                          storeId: storeId,
                          settingsState: settingsState,
                          notifier: notifier,
                          printerState: printerState,
                          printerNotifier: printerNotifier,
                          auditTraceAsync: auditTraceAsync,
                        );

                        if (constraints.maxWidth < 1120) {
                          return ListView(
                            children: [
                              categoryPane,
                              const SizedBox(height: 16),
                              panel,
                            ],
                          );
                        }

                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(width: 240, child: categoryPane),
                            const SizedBox(width: 16),
                            Expanded(child: panel),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  int _permissionGroupCount(String? role) {
    if (role == 'super_admin') return 8;
    if (role == 'brand_admin') return 6;
    return 4;
  }

  Widget _buildSettingsConfigurationHeader({
    required _SettingsCategory selectedCategory,
    required SettingsState settingsState,
    required PosAuthState authState,
    required PrinterState printerState,
    required String printerSyncLabel,
    required String? storeId,
  }) {
    final activeRole = settingsState.role.isEmpty
        ? authState.role
        : settingsState.role;
    final printerTone = printerState.lastTestResult == true
        ? PosColors.success
        : printerState.lastTestResult == false
        ? PosColors.warning
        : PosColors.textPrimary;

    return ToastWorkSurface(
      key: const Key('settings_configuration_header'),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.settings,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.l10n.settingsScreenSubtitle,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: PosColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ToastStatusBadge(
                label: selectedCategory.label,
                color: PosColors.accent,
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: 14),
          ToastMetricStrip(
            metrics: [
              ToastMetric(
                label: context.l10n.settingsActiveStores,
                value: storeId == null ? '0' : '1',
                tone: storeId == null ? PosColors.warning : PosColors.success,
              ),
              ToastMetric(
                label: context.l10n.settingsPermissionGroups,
                value: context.l10n.settingsPermissionGroupCount(
                  _permissionGroupCount(activeRole),
                ),
                tone: PosColors.accent,
              ),
              ToastMetric(
                label: context.l10n.settingsPaymentConfig,
                value: _hasPayrollPin == true
                    ? context.l10n.settingsProtected
                    : _hasPayrollPin == false
                    ? context.l10n.settingsNotSet
                    : context.l10n.settingsChecking,
                tone: _hasPayrollPin == true
                    ? PosColors.success
                    : PosColors.warning,
              ),
              ToastMetric(
                label: context.l10n.settingsSyncStatus,
                value: printerSyncLabel,
                tone: printerTone,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              ToastStatusBadge(
                label: selectedCategory.label,
                color: PosColors.textSecondary,
                compact: true,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  selectedCategory.summary,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PosColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryPane(List<_SettingsCategory> categories) {
    return ToastWorkSurface(
      padding: const EdgeInsets.all(12),
      child: Column(
        key: const Key('settings_configuration_queue'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final category in categories) ...[
            Builder(
              builder: (context) {
                final selected = _selectedCategory == category.id;
                return InkWell(
                  onTap: () => setState(() => _selectedCategory = category.id),
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: selected
                          ? PosColors.accentMuted
                          : PosColors.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: selected ? PosColors.accent : PosColors.border,
                        width: selected ? 1.5 : 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          category.label,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: selected
                                    ? PosColors.accent
                                    : PosColors.textPrimary,
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          category.summary,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: PosColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            if (category != categories.last) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildSettingsPanel({
    required BuildContext context,
    required PosAuthState authState,
    required String? authUid,
    required String? storeId,
    required SettingsState settingsState,
    required SettingsNotifier notifier,
    required PrinterState printerState,
    required PrinterNotifier printerNotifier,
    required AsyncValue<List<Map<String, dynamic>>> auditTraceAsync,
  }) {
    switch (_selectedCategory) {
      case 'permissions':
        return _buildPermissionsPanel(
          context: context,
          authState: authState,
          authUid: authUid,
          settingsState: settingsState,
          notifier: notifier,
        );
      case 'payment':
        return _buildPaymentPanel(storeId: storeId);
      case 'receipt':
        return _buildReceiptPanel(
          context: context,
          printerState: printerState,
          printerNotifier: printerNotifier,
          settingsState: settingsState,
        );
      case 'system':
        return _buildSystemPanel(
          storeId: storeId,
          auditTraceAsync: auditTraceAsync,
        );
      case 'store':
      default:
        return _buildStorePanel(
          context: context,
          settingsState: settingsState,
          notifier: notifier,
        );
    }
  }

  Widget _buildStorePanel({
    required BuildContext context,
    required SettingsState settingsState,
    required SettingsNotifier notifier,
  }) {
    return ToastWorkSurface(
      padding: const EdgeInsets.all(18),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _panelHeader(
              title: context.l10n.settingsStorePanelTitle,
              summary: context.l10n.settingsStorePanelSummary,
              badge: ToastStatusBadge(
                label: _operationMode == 'buffet'
                    ? context.l10n.settingsModeBuffet
                    : _operationMode == 'hybrid'
                    ? context.l10n.settingsModeHybrid
                    : context.l10n.settingsModeStandard,
                color: PosColors.accent,
                compact: true,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _restaurantNameController,
              style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
              decoration: InputDecoration(labelText: context.l10n.storeName),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _addressController,
              style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
              decoration: InputDecoration(labelText: context.l10n.address),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _operationMode,
              dropdownColor: AppColors.surface1,
              style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
              decoration: InputDecoration(
                labelText: context.l10n.settingsOperationMode,
              ),
              items: [
                DropdownMenuItem(
                  value: 'standard',
                  child: Text(context.l10n.settingsModeStandard),
                ),
                DropdownMenuItem(
                  value: 'buffet',
                  child: Text(context.l10n.settingsModeBuffet),
                ),
                DropdownMenuItem(
                  value: 'hybrid',
                  child: Text(context.l10n.settingsModeHybrid),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _operationMode = value);
                }
              },
            ),
            if (_operationMode == 'buffet' || _operationMode == 'hybrid') ...[
              const SizedBox(height: 10),
              TextField(
                controller: _perPersonController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  labelText: context.l10n.settingsPerPersonCharge,
                ),
              ),
            ],
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () {
                    setState(() {
                      _restaurantNameController.text =
                          settingsState.restaurantName;
                      _addressController.text = settingsState.address;
                      _perPersonController.text =
                          settingsState.perPersonCharge?.toString() ?? '';
                      _operationMode = settingsState.operationMode;
                    });
                  },
                  child: Text(context.l10n.reset),
                ),
                FilledButton.icon(
                  onPressed: settingsState.isSavingRestaurant
                      ? null
                      : () async {
                          final success = await notifier.saveRestaurant(
                            name: _restaurantNameController.text.trim(),
                            address: _addressController.text.trim(),
                            operationMode: _operationMode,
                            perPersonCharge:
                                (_operationMode == 'buffet' ||
                                    _operationMode == 'hybrid')
                                ? double.tryParse(
                                    _perPersonController.text.trim(),
                                  )
                                : null,
                          );
                          if (!context.mounted) return;
                          if (success) {
                            showSuccessToast(
                              context,
                              context.l10n.settingsStoreSaved,
                            );
                          }
                        },
                  icon: settingsState.isSavingRestaurant
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(context.l10n.save),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionsPanel({
    required BuildContext context,
    required PosAuthState authState,
    required String? authUid,
    required SettingsState settingsState,
    required SettingsNotifier notifier,
  }) {
    return ToastWorkSurface(
      padding: const EdgeInsets.all(18),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _panelHeader(
              title: context.l10n.settingsProfileAndPermission,
              summary: context.l10n.settingsProfileAndPermissionSummary,
              badge: ToastStatusBadge(
                label: settingsState.role.isEmpty
                    ? _settingsRoleLabel(authState.role)
                    : _settingsRoleLabel(settingsState.role),
                color: PosColors.info,
                compact: true,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _infoChip(
                  context.l10n.settingsNameChip(settingsState.fullName),
                ),
                _infoChip(
                  context.l10n.settingsRoleChip(
                    settingsState.role.isEmpty
                        ? _settingsRoleLabel(authState.role)
                        : _settingsRoleLabel(settingsState.role),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _fullNameController,
              style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
              decoration: InputDecoration(
                labelText: context.l10n.settingsOperatorName,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => setState(() => _selectedCategory = 'system'),
                  icon: const Icon(Icons.history_outlined, size: 16),
                  label: Text(context.l10n.changeHistory),
                ),
                FilledButton.icon(
                  onPressed: settingsState.isSavingProfile || authUid == null
                      ? null
                      : () async {
                          final success = await notifier.updateFullName(
                            _fullNameController.text.trim(),
                          );
                          if (!context.mounted) return;
                          if (success) {
                            showSuccessToast(
                              context,
                              context.l10n.settingsNameSaved,
                            );
                          }
                        },
                  icon: settingsState.isSavingProfile
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(context.l10n.save),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPaymentPanel({required String? storeId}) {
    final pinLabel = _hasPayrollPin == true
        ? context.l10n.settingsProtected
        : _hasPayrollPin == false
        ? context.l10n.settingsNotSet
        : context.l10n.settingsChecking;
    return ToastWorkSurface(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _panelHeader(
            title: context.l10n.settingsPaymentProtection,
            summary: context.l10n.settingsPaymentProtectionSummary,
            badge: ToastStatusBadge(
              label: pinLabel,
              color: _hasPayrollPin == true
                  ? PosColors.success
                  : _hasPayrollPin == false
                  ? PosColors.warning
                  : PosColors.textSecondary,
              compact: true,
            ),
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: PosColors.panelMuted,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: PosColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.settingsCurrentStatus,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: PosColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _hasPayrollPin == true
                      ? context.l10n.settingsPayrollPinSetMessage
                      : _hasPayrollPin == false
                      ? context.l10n.settingsPayrollPinUnsetMessage
                      : context.l10n.settingsPayrollPinCheckingMessage,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: storeId == null
                            ? null
                            : () => _showSetPayrollPinDialog(storeId),
                        child: Text(context.l10n.settingsChangePin),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: storeId == null || _hasPayrollPin != true
                            ? null
                            : () => _clearPayrollPin(storeId),
                        child: Text(context.l10n.settingsDeletePin),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReceiptPanel({
    required BuildContext context,
    required PrinterState printerState,
    required PrinterNotifier printerNotifier,
    required SettingsState settingsState,
  }) {
    return ToastWorkSurface(
      padding: const EdgeInsets.all(18),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _panelHeader(
              title: context.l10n.settingsReceiptPrinter,
              summary: context.l10n.settingsReceiptPrinterSummary,
              badge: ToastStatusBadge(
                label: switch (printerState.lastTestResult) {
                  true => context.l10n.settingsPrinterConnectedGood,
                  false => context.l10n.settingsPrinterConnectionFailedBad,
                  null => context.l10n.settingsPrinterUnchecked,
                },
                color: switch (printerState.lastTestResult) {
                  true => PosColors.success,
                  false => PosColors.danger,
                  null => PosColors.textSecondary,
                },
                compact: true,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              context.l10n.settingsPrinterWifiHint,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _printerIpController,
              keyboardType: TextInputType.number,
              onChanged: (value) => printerNotifier.setIp(value),
              style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
              decoration: InputDecoration(
                labelText: context.l10n.settingsPrinterIpAddress,
                hintText: context.l10n.settingsPrinterIpExample,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: printerState.isTesting
                        ? null
                        : () async {
                            if (!PlatformInfo.isPrinterSupported) {
                              showErrorToast(
                                context,
                                context.l10n.settingsPrinterAppOnly,
                              );
                              return;
                            }
                            await printerNotifier.testConnection();
                          },
                    child: printerState.isTesting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(context.l10n.settingsConnectionTest),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: printerState.isPrinting
                        ? null
                        : () async {
                            if (!PlatformInfo.isPrinterSupported) {
                              showErrorToast(
                                context,
                                context.l10n.settingsPrinterAppOnly,
                              );
                              return;
                            }
                            if (printerState.printerIp.isEmpty) {
                              showErrorToast(
                                context,
                                context.l10n.settingsEnterIpFirst,
                              );
                              return;
                            }
                            final bytes =
                                await ReceiptBuilder.buildPaymentReceipt(
                                  restaurantName:
                                      settingsState.restaurantName.isEmpty
                                      ? context
                                            .l10n
                                            .settingsPrinterFallbackStore
                                      : settingsState.restaurantName,
                                  tableNumber:
                                      context.l10n.settingsPrinterTestTable,
                                  items: [
                                    ReceiptItem(
                                      name:
                                          context.l10n.settingsPrinterTestItem,
                                      quantity: 1,
                                      unitPrice: 10000,
                                    ),
                                  ],
                                  totalAmount: 10000,
                                  paymentMethod: context.l10n.cash,
                                  paidAt: DateTime.now(),
                                );
                            final result = await printerNotifier.print(bytes);
                            if (!context.mounted) return;
                            if (result == PrintResult.success) {
                              showSuccessToast(
                                context,
                                context.l10n.settingsTestPrintComplete,
                              );
                            } else {
                              showErrorToast(
                                context,
                                context.l10n.settingsTestPrintFailed,
                              );
                            }
                          },
                    child: printerState.isPrinting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(context.l10n.settingsTestPrint),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _printerStatusRow(printerState.lastTestResult),
          ],
        ),
      ),
    );
  }

  Widget _buildSystemPanel({
    required String? storeId,
    required AsyncValue<List<Map<String, dynamic>>> auditTraceAsync,
  }) {
    return ToastWorkSurface(
      padding: const EdgeInsets.all(18),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _panelHeader(
              title: context.l10n.system,
              summary: context.l10n.settingsCategorySystemSummary,
              badge: ToastStatusBadge(
                label: storeId == null
                    ? context.l10n.settingsNoStore
                    : context.l10n.settingsSystemLogs,
                color: PosColors.textSecondary,
                compact: true,
              ),
            ),
            const SizedBox(height: 14),
            ExpansionTile(
              key: const Key('settings_audit_trace_secondary_detail'),
              initiallyExpanded: false,
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: Text(
                context.l10n.settingsRecentAdminChangesTitle,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: PosColors.textPrimary,
                ),
              ),
              subtitle: Text(
                context.l10n.settingsRecentAdminChangesSubtitle,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
              ),
              children: [
                const SizedBox(height: 12),
                AdminAuditTracePanel(
                  auditTraceAsync: auditTraceAsync,
                  storeId: storeId,
                  showRetry: true,
                ),
              ],
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: () => ref.read(authProvider.notifier).logout(),
              icon: const Icon(Icons.logout),
              label: Text(context.l10n.logout),
            ),
          ],
        ),
      ),
    );
  }

  Widget _panelHeader({
    required String title,
    required String summary,
    required Widget badge,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(
                summary,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        badge,
      ],
    );
  }

  Widget _infoChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Text(
        label,
        style: GoogleFonts.notoSansKr(
          color: AppColors.textPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _printerStatusRow(bool? lastTestResult) {
    final color = switch (lastTestResult) {
      true => AppColors.statusAvailable,
      false => AppColors.statusCancelled,
      null => AppColors.textSecondary,
    };
    final label = switch (lastTestResult) {
      true => context.l10n.settingsPrinterConnectedGood,
      false => context.l10n.settingsPrinterConnectionFailedBad,
      null => context.l10n.settingsPrinterUnchecked,
    };

    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: GoogleFonts.notoSansKr(
            color: AppColors.textSecondary,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  String _settingsRoleLabel(String? role) {
    switch (role) {
      case 'waiter':
        return context.l10n.staffRoleWaiter;
      case 'kitchen':
        return context.l10n.staffRoleKitchen;
      case 'cashier':
        return context.l10n.staffRoleCashier;
      case 'admin':
        return context.l10n.staffRoleAdmin;
      case 'store_admin':
        return context.l10n.staffRoleStoreAdmin;
      case 'brand_admin':
        return context.l10n.staffRoleBrandAdmin;
      case 'photo_objet_master':
        return context.l10n.staffRolePhotoMaster;
      case 'photo_objet_store_admin':
        return context.l10n.staffRolePhotoStoreAdmin;
      case 'super_admin':
        return context.l10n.staffRoleSuperAdmin;
      case null:
      case '':
        return '-';
      default:
        return role;
    }
  }
}

class _SettingsCategory {
  const _SettingsCategory(this.id, this.label, this.summary);

  final String id;
  final String label;
  final String summary;
}
