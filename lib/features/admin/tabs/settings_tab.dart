import 'package:flutter/material.dart';
import '../../../core/layout/platform_info.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/hardware/printer_service.dart';
import '../../../core/hardware/receipt_builder.dart';
import '../../../main.dart';
import '../../../widgets/error_toast.dart';
import '../../auth/auth_provider.dart';
import '../../settings/printer_provider.dart';
import '../providers/settings_provider.dart';

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

  @override
  void dispose() {
    _restaurantNameController.dispose();
    _addressController.dispose();
    _perPersonController.dispose();
    _fullNameController.dispose();
    _printerIpController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final authUid = authState.user?.id;
    final restaurantId = authState.restaurantId;
    final settingsState = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final printerState = ref.watch(printerProvider);
    final printerNotifier = ref.read(printerProvider.notifier);

    if (restaurantId != null &&
        authUid != null &&
        restaurantId != _initializedRestaurantId) {
      _initializedRestaurantId = restaurantId;
      Future.microtask(() => notifier.loadSettings(restaurantId, authUid));
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
                      _sectionTitle('Restaurant Info'),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _restaurantNameController,
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.textPrimary,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Restaurant Name',
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
                                      'Restaurant updated successfully',
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
                                    authUid,
                                    _fullNameController.text.trim(),
                                  );
                                  if (!context.mounted) {
                                    return;
                                  }
                                  if (success) {
                                    showSuccessToast(
                                      context,
                                      'Profile updated',
                                    );
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
                      _sectionTitle('프린터 설정 (영수증 프린터)'),
                      const SizedBox(height: 8),
                      Text(
                        'Xprinter XP-K200W WiFi 연결',
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '프린터와 태블릿이 같은 WiFi 네트워크에 있어야 합니다.',
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
                          labelText: '프린터 IP 주소',
                          hintText: '예: 192.168.1.100',
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
                                          '프린터는 앱에서만 지원됩니다.',
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
                                  : const Text('연결 테스트'),
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
                                          '프린터는 앱에서만 지원됩니다.',
                                        );
                                        return;
                                      }
                                      if (printerState.printerIp.isEmpty) {
                                        showErrorToast(
                                          context,
                                          'IP 주소를 먼저 입력해주세요.',
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
                                        showSuccessToast(context, '테스트 출력 완료');
                                      } else {
                                        showErrorToast(context, '테스트 출력 실패');
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
                                  : const Text('테스트 출력'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _printerStatusRow(printerState.lastTestResult),
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
      true => '연결됨',
      false => '연결 실패',
      null => '미확인',
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
