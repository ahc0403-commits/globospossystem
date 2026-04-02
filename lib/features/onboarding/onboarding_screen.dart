import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../main.dart';
import 'onboarding_provider.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _restaurantNameController = TextEditingController();
  final _addressController = TextEditingController();
  final _perPersonController = TextEditingController();
  final _fullNameController = TextEditingController();
  String _operationMode = 'standard';

  @override
  void dispose() {
    _restaurantNameController.dispose();
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
      backgroundColor: AppColors.surface0,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ProgressDots(step: state.step),
                  const SizedBox(height: 26),
                  if (state.error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        state.error!,
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.statusCancelled,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  Expanded(
                    child: switch (state.step) {
                      0 => _restaurantStep(notifier, state.isLoading),
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

  Widget _restaurantStep(OnboardingNotifier notifier, bool isLoading) {
    final needsPerPerson = _operationMode == 'buffet' || _operationMode == 'hybrid';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'CREATE YOUR RESTAURANT',
            style: GoogleFonts.bebasNeue(
              color: AppColors.amber500,
              fontSize: 36,
              letterSpacing: 1.1,
            ),
          ),
          Text(
            'Set up your first location',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _restaurantNameController,
            style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
            decoration: const InputDecoration(labelText: 'Restaurant Name'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _addressController,
            style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
            decoration: const InputDecoration(labelText: 'Address'),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _operationMode,
            dropdownColor: AppColors.surface1,
            style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
            decoration: const InputDecoration(labelText: 'Operation Mode'),
            items: const [
              DropdownMenuItem(value: 'standard', child: Text('Standard')),
              DropdownMenuItem(value: 'buffet', child: Text('Buffet')),
              DropdownMenuItem(value: 'hybrid', child: Text('Hybrid')),
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
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
              decoration: const InputDecoration(labelText: 'Per Person Charge'),
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
                      final name = _restaurantNameController.text.trim();
                      if (name.isEmpty) {
                        return;
                      }
                      final perPerson = needsPerPerson
                          ? double.tryParse(_perPersonController.text.trim())
                          : null;
                      await notifier.createRestaurant(
                        name,
                        _addressController.text.trim(),
                        _operationMode,
                        perPerson,
                      );
                    },
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: AppColors.surface0,
                      ),
                    )
                  : Text(
                      'NEXT',
                      style: GoogleFonts.bebasNeue(fontSize: 24, letterSpacing: 1.0),
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
            'YOUR PROFILE',
            style: GoogleFonts.bebasNeue(
              color: AppColors.amber500,
              fontSize: 36,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _fullNameController,
            style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
            decoration: const InputDecoration(labelText: 'Full Name'),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.surface1,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.surface2),
            ),
            child: Text(
              'super_admin',
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
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
                      await notifier.createAdminAccount(fullName, 'super_admin');
                    },
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: AppColors.surface0,
                      ),
                    )
                  : Text(
                      'COMPLETE SETUP',
                      style: GoogleFonts.bebasNeue(fontSize: 24, letterSpacing: 1.0),
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
          const Icon(
            Icons.check_circle,
            color: AppColors.statusAvailable,
            size: 86,
          ),
          const SizedBox(height: 10),
          Text(
            "YOU'RE ALL SET!",
            style: GoogleFonts.bebasNeue(
              color: AppColors.amber500,
              fontSize: 48,
              letterSpacing: 1.2,
            ),
          ),
          if (state.createdRestaurantName != null)
            Text(
              state.createdRestaurantName!,
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
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
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: state.isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: AppColors.surface0,
                      ),
                    )
                  : Text(
                      'GO TO DASHBOARD',
                      style: GoogleFonts.bebasNeue(fontSize: 24, letterSpacing: 1.0),
                    ),
            ),
          ),
        ],
      ),
    );
  }
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
            color: active ? AppColors.amber500 : AppColors.surface2,
            borderRadius: BorderRadius.circular(20),
          ),
        );
      }),
    );
  }
}
