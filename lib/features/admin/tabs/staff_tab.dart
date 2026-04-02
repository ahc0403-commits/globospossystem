import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../main.dart';
import '../../../widgets/error_toast.dart';
import '../../attendance/fingerprint_provider.dart';
import '../../auth/auth_provider.dart';
import '../providers/staff_provider.dart';

class StaffTab extends ConsumerStatefulWidget {
  const StaffTab({super.key});

  @override
  ConsumerState<StaffTab> createState() => _StaffTabState();
}

class _StaffTabState extends ConsumerState<StaffTab> {
  String? _initializedRestaurantId;

  @override
  Widget build(BuildContext context) {
    final restaurantId = ref.watch(authProvider).restaurantId;
    final staffState = ref.watch(staffProvider);
    final notifier = ref.read(staffProvider.notifier);

    if (restaurantId != null && _initializedRestaurantId != restaurantId) {
      _initializedRestaurantId = restaurantId;
      Future.microtask(() => notifier.loadStaff(restaurantId));
    }

    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Text(
                  'Staff',
                  style: GoogleFonts.bebasNeue(
                    color: AppColors.textPrimary,
                    fontSize: 34,
                    letterSpacing: 1.0,
                  ),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: restaurantId == null
                      ? null
                      : () => _showAddStaffSheet(context, restaurantId),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.amber500,
                    foregroundColor: AppColors.surface0,
                  ),
                  icon: const Icon(Icons.person_add),
                  label: const Text('Add Staff'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (staffState.error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  staffState.error!,
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.statusCancelled,
                    fontSize: 13,
                  ),
                ),
              ),
            Expanded(
              child: staffState.isLoading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.amber500,
                      ),
                    )
                  : staffState.staff.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.people_outline,
                            color: AppColors.textSecondary,
                            size: 48,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'No staff members yet',
                            style: GoogleFonts.notoSansKr(
                              color: AppColors.textSecondary,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      itemCount: staffState.staff.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final member = staffState.staff[index];
                        return Opacity(
                          opacity: member.isActive ? 1 : 0.5,
                          child: Container(
                            decoration: BoxDecoration(
                              color: AppColors.surface1,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                            child: Row(
                              children: [
                                _RoleBadge(role: member.role),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        member.fullName,
                                        style: GoogleFonts.notoSansKr(
                                          color: AppColors.textPrimary,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        member.email != null &&
                                                member.email!.isNotEmpty
                                            ? member.email!
                                            : member.role,
                                        style: GoogleFonts.notoSansKr(
                                          color: AppColors.textSecondary,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Consumer(
                                  builder: (context, ref, child) {
                                    final countAsync = ref.watch(
                                      staffFingerprintCountProvider(member.id),
                                    );
                                    return countAsync.maybeWhen(
                                      data: (count) {
                                        if (count <= 0) {
                                          return const SizedBox.shrink();
                                        }
                                        return Container(
                                          margin: const EdgeInsets.only(
                                            right: 8,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: AppColors.statusAvailable
                                                .withValues(alpha: 0.2),
                                            borderRadius: BorderRadius.circular(
                                              20,
                                            ),
                                            border: Border.all(
                                              color: AppColors.statusAvailable,
                                            ),
                                          ),
                                          child: Text(
                                            'FP $count',
                                            style: GoogleFonts.notoSansKr(
                                              color: AppColors.statusAvailable,
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        );
                                      },
                                      orElse: () => const SizedBox.shrink(),
                                    );
                                  },
                                ),
                                IconButton(
                                  tooltip: '지문 등록',
                                  onPressed: restaurantId == null
                                      ? null
                                      : () => _showEnrollFingerprintSheet(
                                          context: context,
                                          restaurantId: restaurantId,
                                          member: member,
                                        ),
                                  icon: const Icon(
                                    Icons.fingerprint,
                                    color: AppColors.amber500,
                                  ),
                                ),
                                Switch(
                                  value: member.isActive,
                                  activeThumbColor: AppColors.amber500,
                                  onChanged: restaurantId == null
                                      ? null
                                      : (value) => notifier.toggleActive(
                                          member.id,
                                          value,
                                          restaurantId,
                                        ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAddStaffSheet(
    BuildContext context,
    String restaurantId,
  ) async {
    final fullNameController = TextEditingController();
    final emailController = TextEditingController();
    final passwordController = TextEditingController();
    String role = 'waiter';
    final notifier = ref.read(staffProvider.notifier);

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface1,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: StatefulBuilder(
            builder: (context, setModalState) {
              final isCreating = ref.watch(staffProvider).isCreating;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Add Staff',
                    style: GoogleFonts.bebasNeue(
                      color: AppColors.textPrimary,
                      fontSize: 32,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: fullNameController,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: const InputDecoration(labelText: 'Full Name'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: emailController,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      hintText: 'Minimum 8 characters',
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: role,
                    dropdownColor: AppColors.surface1,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    items: const [
                      DropdownMenuItem(value: 'waiter', child: Text('Waiter')),
                      DropdownMenuItem(
                        value: 'kitchen',
                        child: Text('Kitchen'),
                      ),
                      DropdownMenuItem(
                        value: 'cashier',
                        child: Text('Cashier'),
                      ),
                      DropdownMenuItem(value: 'admin', child: Text('Admin')),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setModalState(() => role = value);
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: isCreating
                          ? null
                          : () async {
                              final fullName = fullNameController.text.trim();
                              final email = emailController.text.trim();
                              final password = passwordController.text.trim();
                              if (fullName.isEmpty ||
                                  email.isEmpty ||
                                  password.isEmpty) {
                                return;
                              }

                              await notifier.createStaff(
                                restaurantId: restaurantId,
                                email: email,
                                password: password,
                                fullName: fullName,
                                role: role,
                              );

                              if (!context.mounted) {
                                return;
                              }
                              final nextState = ref.read(staffProvider);
                              if (nextState.error != null) {
                                return;
                              }
                              Navigator.of(context).pop();
                              showSuccessToast(
                                context,
                                'Staff account created. They can now log in with their email and password.',
                              );
                            },
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.amber500,
                        foregroundColor: AppColors.surface0,
                      ),
                      child: isCreating
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Add Staff'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );

    fullNameController.dispose();
    emailController.dispose();
    passwordController.dispose();
  }

  Future<void> _showEnrollFingerprintSheet({
    required BuildContext context,
    required String restaurantId,
    required StaffMember member,
  }) async {
    final fpNotifier = ref.read(fingerprintProvider.notifier);
    Future.microtask(fpNotifier.initialize);

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface1,
      isScrollControlled: true,
      builder: (context) {
        return Consumer(
          builder: (context, ref, child) {
            final fpState = ref.watch(fingerprintProvider);
            final enrolling = fpState.isEnrolling || fpState.isCapturing;

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '지문 등록 - ${member.fullName}',
                    style: GoogleFonts.bebasNeue(
                      color: AppColors.textPrimary,
                      fontSize: 30,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'ZK9500 스캐너에 손가락을 올려주세요',
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: _PulsingFingerprintIcon(isAnimating: enrolling),
                  ),
                  const SizedBox(height: 16),
                  if (fpState.error != null)
                    Text(
                      fpState.error!,
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.statusCancelled,
                        fontSize: 13,
                      ),
                    ),
                  if (fpState.successMessage != null)
                    Row(
                      children: [
                        const Icon(
                          Icons.check_circle,
                          color: AppColors.statusAvailable,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '등록 완료',
                          style: GoogleFonts.notoSansKr(
                            color: AppColors.statusAvailable,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: enrolling
                          ? null
                          : () async {
                              final success = await fpNotifier
                                  .enrollFingerprint(
                                    userId: member.id,
                                    restaurantId: restaurantId,
                                    fingerIndex: 0,
                                  );
                              if (!context.mounted) {
                                return;
                              }
                              if (success) {
                                ref.invalidate(
                                  staffFingerprintCountProvider(member.id),
                                );
                                showSuccessToast(context, '지문 등록 완료');
                              } else {
                                final error =
                                    ref.read(fingerprintProvider).error ??
                                    '지문 등록 실패';
                                showErrorToast(context, error);
                              }
                            },
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.amber500,
                        foregroundColor: AppColors.surface0,
                      ),
                      icon: const Icon(Icons.fingerprint),
                      label: enrolling
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('등록 시작'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () {
                        fpNotifier.clearResult();
                        Navigator.of(context).pop();
                      },
                      child: const Text('닫기'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    ref.read(fingerprintProvider.notifier).clearResult();
  }
}

class _PulsingFingerprintIcon extends StatefulWidget {
  const _PulsingFingerprintIcon({required this.isAnimating});

  final bool isAnimating;

  @override
  State<_PulsingFingerprintIcon> createState() =>
      _PulsingFingerprintIconState();
}

class _PulsingFingerprintIconState extends State<_PulsingFingerprintIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void didUpdateWidget(covariant _PulsingFingerprintIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isAnimating) {
      _controller.repeat(reverse: true);
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final scale = widget.isAnimating
            ? (1 + (_controller.value * 0.08))
            : 1.0;
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surface2,
              border: Border.all(color: AppColors.amber500),
            ),
            alignment: Alignment.center,
            child: const Icon(
              Icons.fingerprint,
              size: 64,
              color: AppColors.amber500,
            ),
          ),
        );
      },
    );
  }
}

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.role});

  final String role;

  @override
  Widget build(BuildContext context) {
    final normalized = role.toLowerCase();
    final color = switch (normalized) {
      'waiter' => const Color(0xFF3A7BD5),
      'kitchen' => AppColors.statusOccupied,
      'cashier' => AppColors.statusAvailable,
      'admin' => AppColors.amber500,
      _ => AppColors.surface2,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color),
      ),
      child: Text(
        normalized.toUpperCase(),
        style: GoogleFonts.notoSansKr(
          color: AppColors.textPrimary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
