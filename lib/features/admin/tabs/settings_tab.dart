import 'package:flutter/material.dart';
import '../../../core/layout/platform_info.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/hardware/printer_service.dart';
import '../../../core/hardware/receipt_builder.dart';
import '../../../core/services/pin_service.dart';
import '../../../main.dart';
import '../../../widgets/error_toast.dart';
import '../../../widgets/pin_dialog.dart';
import '../../auth/auth_provider.dart';
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
                'Set Payroll PIN',
                style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: pinController,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'New PIN (4 digits)',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: confirmController,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Confirm PIN'),
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
                  child: const Text('Cancel'),
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
                              () => validationMessage = 'PIN must be 4 digits.',
                            );
                            return;
                          }
                          if (pin != confirm) {
                            setModalState(
                              () => validationMessage = 'PIN confirmation does not match.',
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
                            showSuccessToast(pageContext, 'Payroll PIN saved.');
                          } catch (e) {
                            if (pageContext.mounted) {
                              showErrorToast(pageContext, 'Failed to save PIN: $e');
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
                      : const Text('Save'),
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
    final entered = await showPinDialog(context, title: 'Enter current PIN');
    if (entered == null) return;

    try {
      final ok = await pinService.verifyPin(storeId, entered);
      if (!ok) {
        if (mounted) {
          showErrorToast(context, 'Incorrect PIN.');
        }
        return;
      }
      await pinService.clearPin(storeId);
      await _loadPayrollPinStatus(storeId);
      if (mounted) {
        showSuccessToast(context, 'Payroll PIN deleted.');
      }
    } catch (e) {
      if (mounted) {
        showErrorToast(context, 'Failed to delete PIN: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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

    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: settingsState.isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.amber500),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _sectionTitle('Store Info'),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _restaurantNameController,
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.textPrimary,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Store Name',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _addressController,
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.textPrimary,
                        ),
                        decoration: const InputDecoration(labelText: 'Address'),
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        initialValue: _operationMode,
                        dropdownColor: AppColors.surface1,
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.textPrimary,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Operation Mode',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'standard',
                            child: Text('Standard'),
                          ),
                          DropdownMenuItem(
                            value: 'buffet',
                            child: Text('Buffet'),
                          ),
                          DropdownMenuItem(
                            value: 'hybrid',
                            child: Text('Hybrid'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _operationMode = value);
                          }
                        },
                      ),
                      if (_operationMode == 'buffet' ||
                          _operationMode == 'hybrid') ...[
                        const SizedBox(height: 10),
                        TextField(
                          controller: _perPersonController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          style: GoogleFonts.notoSansKr(
                            color: AppColors.textPrimary,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Per Person Charge',
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: FilledButton(
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
                                  if (!context.mounted) {
                                    return;
                                  }
                                  if (success) {
                                    showSuccessToast(
                                      context,
                                      'Store settings saved.',
                                    );
                                  }
                                },
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.amber500,
                            foregroundColor: AppColors.surface0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: settingsState.isSavingRestaurant
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(
                                  'SAVE CHANGES',
                                  style: GoogleFonts.bebasNeue(
                                    fontSize: 24,
                                    letterSpacing: 1.0,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      _sectionTitle('Account Info'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _infoChip('Name: ${settingsState.fullName}'),
                          _infoChip(
                            'Role: ${settingsState.role.isEmpty ? (authState.role ?? '-') : settingsState.role}',
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _fullNameController,
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.textPrimary,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Edit Full Name',
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed:
                              settingsState.isSavingProfile || authUid == null
                              ? null
                              : () async {
                                  final success = await notifier.updateFullName(
                                    _fullNameController.text.trim(),
                                  );
                                  if (!context.mounted) {
                                    return;
                                  }
                                  if (success) {
                                    showSuccessToast(context, 'Name saved.');
                                  }
                                },
                          child: settingsState.isSavingProfile
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Update'),
                        ),
                      ),
                      const SizedBox(height: 28),
                      _sectionTitle('Recent Admin Changes'),
                      const SizedBox(height: 8),
                      AdminAuditTracePanel(
                        auditTraceAsync: auditTraceAsync,
                        storeId: storeId,
                        showRetry: true,
                      ),
                      const SizedBox(height: 28),
                      _sectionTitle('Printer Settings (Receipt Printer)'),
                      const SizedBox(height: 8),
                      Text(
                        'Xprinter XP-K200W WiFi Connection',
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'The printer and the tablet must be on the same WiFi network.',
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _printerIpController,
                        keyboardType: TextInputType.number,
                        onChanged: (value) => printerNotifier.setIp(value),
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.textPrimary,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Printer IP Address',
                          hintText: 'e.g. 192.168.1.100',
                        ),
                      ),
                      const SizedBox(height: 10),
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
                                          'Printer is only supported on the app.',
                                        );
                                        return;
                                      }
                                      await printerNotifier.testConnection();
                                    },
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(
                                  color: AppColors.amber500,
                                ),
                                foregroundColor: AppColors.amber500,
                              ),
                              child: printerState.isTesting
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text('Connection Test'),
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
                                          'Printer is only supported on the app.',
                                        );
                                        return;
                                      }
                                      if (printerState.printerIp.isEmpty) {
                                        showErrorToast(
                                          context,
                                          'Enter the IP address first.',
                                        );
                                        return;
                                      }
                                      final bytes =
                                          await ReceiptBuilder.buildPaymentReceipt(
                                            restaurantName:
                                                settingsState
                                                    .restaurantName
                                                    .isEmpty
                                                ? 'GLOBOS POS'
                                                : settingsState.restaurantName,
                                            tableNumber: 'TEST',
                                            items: const [
                                              ReceiptItem(
                                                name: 'Printer Test Item',
                                                quantity: 1,
                                                unitPrice: 10000,
                                              ),
                                            ],
                                            totalAmount: 10000,
                                            paymentMethod: 'cash',
                                            paidAt: DateTime.now(),
                                          );
                                      final result = await printerNotifier
                                          .print(bytes);
                                      if (!context.mounted) {
                                        return;
                                      }
                                      if (result == PrintResult.success) {
                                        showSuccessToast(context, 'Test print complete');
                                      } else {
                                        showErrorToast(context, 'Test print failed');
                                      }
                                    },
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.amber500,
                                foregroundColor: AppColors.surface0,
                              ),
                              child: printerState.isPrinting
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text('Test Print'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _printerStatusRow(printerState.lastTestResult),
                      const SizedBox(height: 28),
                      _sectionTitle('Set Payroll PIN'),
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.surface1,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.surface2),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _infoChip(
                                  _hasPayrollPin == true
                                      ? 'Current status: Set ✅'
                                      : _hasPayrollPin == false
                                      ? 'Current status: Not set'
                                      : 'Current status: Checking...',
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: FilledButton(
                                    onPressed: storeId == null
                                        ? null
                                        : () => _showSetPayrollPinDialog(
                                            storeId,
                                          ),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: AppColors.amber500,
                                      foregroundColor: AppColors.surface0,
                                    ),
                                    child: const Text('Change PIN'),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed:
                                        storeId == null ||
                                            _hasPayrollPin != true
                                        ? null
                                        : () => _clearPayrollPin(storeId),
                                    style: OutlinedButton.styleFrom(
                                      side: const BorderSide(
                                        color: AppColors.statusCancelled,
                                      ),
                                      foregroundColor:
                                          AppColors.statusCancelled,
                                    ),
                                    child: const Text('Delete PIN'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 28),
                      _sectionTitle('Danger Zone'),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: () =>
                              ref.read(authProvider.notifier).logout(),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(
                              color: AppColors.statusCancelled,
                            ),
                            foregroundColor: AppColors.statusCancelled,
                          ),
                          child: const Text('Sign Out'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _sectionTitle(String title) {
    return Text(
      title,
      style: GoogleFonts.bebasNeue(
        color: AppColors.amber500,
        fontSize: 30,
        letterSpacing: 1.0,
      ),
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
      true => 'Connected',
      false => 'Connection failed',
      null => 'Unverified',
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
}
