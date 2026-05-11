import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/ui/app_primitives.dart';
import '../../core/ui/app_theme.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast_primitives_extended.dart';
import '../../main.dart';
import 'onboarding_provider.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _storeNameController = TextEditingController();
  final _addressController = TextEditingController();
  final _perPersonController = TextEditingController();
  final _fullNameController = TextEditingController();
  String _operationMode = 'standard';

  @override
  void dispose() {
    _storeNameController.dispose();
    _addressController.dispose();
    _perPersonController.dispose();
    _fullNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(onboardingProvider);
    final notifier = ref.read(onboardingProvider.notifier);

    return Scaffold(
      backgroundColor: PosColors.canvas,
      body: ToastShell(
        contentPadding: const EdgeInsets.all(AppSpacing.xl),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ToastWorkSurface(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppSectionHeader(
                    title: context.l10n.onboardingSectionTitle,
                    subtitle: context.l10n.onboardingSectionSubtitle,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _ProgressDots(step: state.step),
                  const SizedBox(height: AppSpacing.xl),
                  if (state.error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.md),
                      child: Text(
                        _localizedOnboardingError(context, state.error!),
                        style: GoogleFonts.notoSansKr(
                          color: PosColors.danger,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  Expanded(
                    child: switch (state.step) {
                      0 => _storeStep(notifier, state.isLoading),
                      1 => _profileStep(notifier, state.isLoading),
                      _ => _doneStep(notifier, state),
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _storeStep(OnboardingNotifier notifier, bool isLoading) {
    final needsPerPerson =
        _operationMode == 'buffet' || _operationMode == 'hybrid';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.onboardingCreateStoreTitle,
            style: AppTextStyles.operationalTitle(size: 36),
          ),
          Text(
            context.l10n.onboardingCreateStoreSubtitle,
            style: GoogleFonts.notoSansKr(
              color: PosColors.textSecondary,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _storeNameController,
            style: GoogleFonts.notoSansKr(color: PosColors.textPrimary),
            decoration: InputDecoration(
              labelText: context.l10n.onboardingStoreName,
              prefixIcon: Icon(Icons.storefront_outlined),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _addressController,
            style: GoogleFonts.notoSansKr(color: PosColors.textPrimary),
            decoration: InputDecoration(
              labelText: context.l10n.address,
              prefixIcon: Icon(Icons.location_on_outlined),
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _operationMode,
            dropdownColor: PosColors.surface,
            style: GoogleFonts.notoSansKr(color: PosColors.textPrimary),
            decoration: InputDecoration(
              labelText: context.l10n.superAdminOperationMode,
              prefixIcon: Icon(Icons.tune),
            ),
            items: [
              DropdownMenuItem(
                value: 'standard',
                child: Text(context.l10n.superAdminOperationModeStandard),
              ),
              DropdownMenuItem(
                value: 'buffet',
                child: Text(context.l10n.superAdminOperationModeBuffet),
              ),
              DropdownMenuItem(
                value: 'hybrid',
                child: Text(context.l10n.superAdminOperationModeHybrid),
              ),
            ],
            onChanged: (value) {
              if (value != null) {
                setState(() => _operationMode = value);
              }
            },
          ),
          if (needsPerPerson) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _perPersonController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              style: GoogleFonts.notoSansKr(color: PosColors.textPrimary),
              decoration: InputDecoration(
                labelText: context.l10n.superAdminPerPersonCharge,
                prefixIcon: Icon(Icons.payments_outlined),
              ),
            ),
          ],
          const SizedBox(height: 24),
          SizedBox(
            height: 56,
            width: double.infinity,
            child: FilledButton(
              onPressed: isLoading
                  ? null
                  : () async {
                      final name = _storeNameController.text.trim();
                      if (name.isEmpty) {
                        return;
                      }
                      final perPerson = needsPerPerson
                          ? double.tryParse(_perPersonController.text.trim())
                          : null;
                      await notifier.createStore(
                        name,
                        _addressController.text.trim(),
                        _operationMode,
                        perPerson,
                      );
                    },
              child: isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: PosColors.canvas,
                      ),
                    )
                  : Text(
                      context.l10n.onboardingNext,
                      style: GoogleFonts.notoSansKr(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _profileStep(OnboardingNotifier notifier, bool isLoading) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.onboardingProfileTitle,
            style: AppTextStyles.operationalTitle(size: 36),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _fullNameController,
            style: GoogleFonts.notoSansKr(color: PosColors.textPrimary),
            decoration: InputDecoration(
              labelText: context.l10n.onboardingFullName,
              prefixIcon: Icon(Icons.badge_outlined),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: PosColors.surface,
              borderRadius: ToastRadiusTokens.xs,
              border: Border.all(color: PosColors.panelMuted),
            ),
            child: Text(
              context.l10n.roleSuperAdminDisplay,
              style: GoogleFonts.notoSansKr(
                color: PosColors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 56,
            width: double.infinity,
            child: FilledButton(
              onPressed: isLoading
                  ? null
                  : () async {
                      final fullName = _fullNameController.text.trim();
                      if (fullName.isEmpty) {
                        return;
                      }
                      await notifier.createAdminAccount(
                        fullName,
                        'super_admin',
                      );
                    },
              child: isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: PosColors.canvas,
                      ),
                    )
                  : Text(
                      context.l10n.onboardingCompleteSetup,
                      style: GoogleFonts.notoSansKr(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _doneStep(OnboardingNotifier notifier, OnboardingState state) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, color: PosColors.success, size: 86),
          const SizedBox(height: 10),
          Text(
            context.l10n.onboardingDoneTitle,
            style: GoogleFonts.notoSansKr(
              color: PosColors.accent,
              fontSize: 28,
              fontWeight: FontWeight.w900,
            ),
          ),
          if (state.createdStoreName != null)
            Text(
              state.createdStoreName!,
              style: GoogleFonts.notoSansKr(
                color: PosColors.textSecondary,
                fontSize: 16,
              ),
            ),
          const SizedBox(height: 18),
          SizedBox(
            height: 56,
            width: double.infinity,
            child: FilledButton(
              onPressed: state.isLoading
                  ? null
                  : () async {
                      await notifier.finish();
                      if (!mounted) {
                        return;
                      }
                      context.go('/admin');
                    },
              style: FilledButton.styleFrom(
                backgroundColor: PosColors.accent,
                foregroundColor: PosColors.canvas,
                shape: RoundedRectangleBorder(
                  borderRadius: ToastRadiusTokens.xs,
                ),
              ),
              child: state.isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: PosColors.canvas,
                      ),
                    )
                  : Text(
                      context.l10n.onboardingGoToDashboard,
                      style: GoogleFonts.notoSansKr(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

String _localizedOnboardingError(BuildContext context, String error) {
  if (error == onboardingOnlySuperAdminErrorCode) {
    return context.l10n.onboardingOnlySuperAdminError;
  }
  if (error == onboardingMissingSetupInfoErrorCode) {
    return context.l10n.onboardingMissingSetupInfo;
  }
  if (error.startsWith('$onboardingFailedCreateStoreErrorCode:')) {
    return context.l10n.onboardingFailedCreateStore(
      error.substring(onboardingFailedCreateStoreErrorCode.length + 1),
    );
  }
  if (error.startsWith('$onboardingFailedUpdateProfileErrorCode:')) {
    return context.l10n.onboardingFailedUpdateProfile(
      error.substring(onboardingFailedUpdateProfileErrorCode.length + 1),
    );
  }
  if (error.startsWith('$onboardingFailedFinalizeErrorCode:')) {
    return context.l10n.onboardingFailedFinalize(
      error.substring(onboardingFailedFinalizeErrorCode.length + 1),
    );
  }
  return error;
}

class _ProgressDots extends StatelessWidget {
  const _ProgressDots({required this.step});

  final int step;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(3, (index) {
        final active = index == step;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: const EdgeInsets.symmetric(horizontal: 5),
          width: active ? 24 : 10,
          height: 10,
          decoration: BoxDecoration(
            color: active ? PosColors.accent : PosColors.panelMuted,
            borderRadius: AppRadius.pill,
          ),
        );
      }),
    );
  }
}
