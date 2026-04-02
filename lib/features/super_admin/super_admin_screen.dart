import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../core/constants/app_constants.dart';
import '../../main.dart';
import '../../widgets/error_toast.dart';
import '../auth/auth_provider.dart';
import '../auth/auth_state.dart';
import 'super_admin_provider.dart';

class SuperAdminScreen extends ConsumerStatefulWidget {
  const SuperAdminScreen({super.key});

  @override
  ConsumerState<SuperAdminScreen> createState() => _SuperAdminScreenState();
}

class _SuperAdminScreenState extends ConsumerState<SuperAdminScreen> {
  int _tabIndex = 0;
  bool _initialized = false;
  String? _lastError;

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final state = ref.watch(superAdminProvider);
    final notifier = ref.read(superAdminProvider.notifier);

    if (!_initialized) {
      _initialized = true;
      Future.microtask(() async {
        await notifier.loadAllRestaurants();
        await notifier.loadAllReports();
      });
    }

    if (state.error != null && state.error!.isNotEmpty && state.error != _lastError) {
      _lastError = state.error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          showErrorToast(context, state.error!);
        }
      });
    }

    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: Row(
        children: [
          Container(
            width: 220,
            color: AppColors.surface1,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'SYSTEM ADMIN',
                  style: GoogleFonts.bebasNeue(
                    color: AppColors.amber500,
                    fontSize: 30,
                    letterSpacing: 1.1,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                _navItem(Icons.store, 'Restaurants', 0),
                const SizedBox(height: 8),
                _navItem(Icons.bar_chart, 'All Reports', 1),
                const SizedBox(height: 8),
                _navItem(Icons.settings, 'System Settings', 2),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: () => ref.read(authProvider.notifier).logout(),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.statusCancelled),
                    foregroundColor: AppColors.statusCancelled,
                  ),
                  icon: const Icon(Icons.logout),
                  label: const Text('Logout'),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: switch (_tabIndex) {
                0 => _RestaurantsTab(
                    state: state,
                    notifier: notifier,
                    onGoToAdmin: () => context.go('/admin'),
                  ),
                1 => _AllReportsTab(state: state, notifier: notifier),
                _ => _SystemSettingsTab(authState: authState),
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _navItem(IconData icon, String label, int index) {
    final selected = _tabIndex == index;
    return InkWell(
      onTap: () => setState(() => _tabIndex = index),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.amber500.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.amber500 : AppColors.surface2,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: selected ? AppColors.amber500 : AppColors.textSecondary, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: GoogleFonts.notoSansKr(
                  color: selected ? AppColors.textPrimary : AppColors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RestaurantsTab extends StatelessWidget {
  const _RestaurantsTab({
    required this.state,
    required this.notifier,
    required this.onGoToAdmin,
  });

  final SuperAdminState state;
  final SuperAdminNotifier notifier;
  final VoidCallback onGoToAdmin;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Text(
              'RESTAURANTS',
              style: GoogleFonts.bebasNeue(
                color: AppColors.amber500,
                fontSize: 28,
                letterSpacing: 1.0,
              ),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: () => _showRestaurantSheet(context, notifier: notifier),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              icon: const Icon(Icons.add_business),
              label: const Text('Add Restaurant'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: state.isLoading && state.restaurants.isEmpty
              ? const Center(
                  child: CircularProgressIndicator(color: AppColors.amber500),
                )
              : ListView.separated(
                  itemCount: state.restaurants.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final restaurant = state.restaurants[index];
                    return Container(
                      decoration: BoxDecoration(
                        color: AppColors.surface1,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: restaurant.isActive
                                  ? AppColors.statusAvailable
                                  : AppColors.textSecondary,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  restaurant.name,
                                  style: GoogleFonts.bebasNeue(
                                    color: AppColors.textPrimary,
                                    fontSize: 24,
                                  ),
                                ),
                                Text(
                                  '${restaurant.slug} • ${restaurant.address}',
                                  style: GoogleFonts.notoSansKr(
                                    color: AppColors.textSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          _modeBadge(restaurant.operationMode),
                          const SizedBox(width: 10),
                          OutlinedButton(
                            onPressed: () => _showRestaurantSheet(
                              context,
                              notifier: notifier,
                              initial: restaurant,
                            ),
                            child: const Text('Manage'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () {
                              notifier.selectRestaurant(restaurant);
                              onGoToAdmin();
                            },
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.amber500,
                              foregroundColor: AppColors.surface0,
                            ),
                            child: const Text('Go to Admin'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _modeBadge(String mode) {
    final normalized = mode.toLowerCase();
    final color = switch (normalized) {
      'buffet' => AppColors.amber500,
      'hybrid' => const Color(0xFF3A7BD5),
      _ => AppColors.textSecondary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(14),
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

  Future<void> _showRestaurantSheet(
    BuildContext context, {
    required SuperAdminNotifier notifier,
    SuperRestaurant? initial,
  }) async {
    final isEdit = initial != null;
    final nameController = TextEditingController(text: initial?.name ?? '');
    final addressController = TextEditingController(text: initial?.address ?? '');
    final slugController = TextEditingController(text: initial?.slug ?? '');
    final chargeController = TextEditingController(
      text: initial?.perPersonCharge?.toString() ?? '',
    );
    String operationMode = initial?.operationMode ?? 'standard';

    Future<void> save() async {
      final name = nameController.text.trim();
      final slug = slugController.text.trim();
      final address = addressController.text.trim();
      if (name.isEmpty || slug.isEmpty) {
        return;
      }
      final charge = (operationMode == 'buffet' || operationMode == 'hybrid')
          ? double.tryParse(chargeController.text.trim())
          : null;

      final success = isEdit
          ? await notifier.updateRestaurant(
              id: initial.id,
              name: name,
              address: address,
              slug: slug,
              operationMode: operationMode,
              perPersonCharge: charge,
            )
          : await notifier.addRestaurant(
              name: name,
              address: address,
              slug: slug,
              operationMode: operationMode,
              perPersonCharge: charge,
            );

      if (success && context.mounted) {
        showSuccessToast(
          context,
          isEdit ? 'Restaurant updated' : 'Restaurant created',
        );
        Navigator.of(context).pop();
      }
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface1,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isEdit ? 'Edit Restaurant' : 'Add Restaurant',
                    style: GoogleFonts.bebasNeue(
                      color: AppColors.amber500,
                      fontSize: 30,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameController,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: const InputDecoration(labelText: 'Name'),
                    onChanged: (value) {
                      if (!isEdit && slugController.text.trim().isEmpty) {
                        slugController.text = _slugify(value);
                      }
                    },
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: addressController,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: const InputDecoration(labelText: 'Address'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: slugController,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: const InputDecoration(labelText: 'Slug'),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: operationMode,
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
                        setModalState(() => operationMode = value);
                      }
                    },
                  ),
                  if (operationMode == 'buffet' || operationMode == 'hybrid') ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: chargeController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                      decoration: const InputDecoration(labelText: 'Per Person Charge'),
                    ),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: save,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.amber500,
                        foregroundColor: AppColors.surface0,
                      ),
                      child: const Text('SAVE'),
                    ),
                  ),
                  if (isEdit) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () async {
                          final success = await notifier.deactivateRestaurant(initial.id);
                          if (success && context.mounted) {
                            showSuccessToast(context, 'Restaurant deactivated');
                            Navigator.of(context).pop();
                          }
                        },
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.statusCancelled),
                          foregroundColor: AppColors.statusCancelled,
                        ),
                        child: const Text('DELETE (Deactivate)'),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );

    nameController.dispose();
    addressController.dispose();
    slugController.dispose();
    chargeController.dispose();
  }

  String _slugify(String input) {
    return input
        .toLowerCase()
        .trim()
        .replaceAll(RegExp(r'[^a-z0-9\s-]'), '')
        .replaceAll(RegExp(r'\s+'), '-');
  }
}

class _AllReportsTab extends StatelessWidget {
  const _AllReportsTab({required this.state, required this.notifier});

  final SuperAdminState state;
  final SuperAdminNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final summary = state.reportSummary;
    final currency = NumberFormat('#,###', 'vi_VN');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'ALL REPORTS',
          style: GoogleFonts.bebasNeue(
            color: AppColors.amber500,
            fontSize: 30,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<SuperRestaurant?>(
              value: state.selectedRestaurant,
              dropdownColor: AppColors.surface1,
              hint: Text(
                'All Restaurants',
                style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
              ),
              items: [
                DropdownMenuItem<SuperRestaurant?>(
                  value: null,
                  child: Text(
                    'All Restaurants',
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                  ),
                ),
                ...state.restaurants.map((restaurant) {
                  return DropdownMenuItem<SuperRestaurant?>(
                    value: restaurant,
                    child: Text(
                      restaurant.name,
                      style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    ),
                  );
                }),
              ],
              onChanged: (value) async {
                notifier.selectRestaurant(value);
                await notifier.loadAllReports(selectedRestaurantId: value?.id);
              },
            ),
            OutlinedButton(
              onPressed: () async {
                final picked = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(2020),
                  lastDate: DateTime.now(),
                  initialDateRange: DateTimeRange(
                    start: state.reportStart,
                    end: state.reportEnd,
                  ),
                );
                if (picked != null) {
                  await notifier.setReportRange(picked.start, picked.end);
                }
              },
              child: Text(
                '${DateFormat('dd/MM/yyyy').format(state.reportStart)} - ${DateFormat('dd/MM/yyyy').format(state.reportEnd)}',
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (summary != null)
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _summaryCard('Total Revenue', '₫${currency.format(summary.totalRevenue)}'),
              _summaryCard('Dine-in', '₫${currency.format(summary.dineInRevenue)}'),
              _summaryCard('Delivery', '₫${currency.format(summary.deliveryRevenue)}'),
            ],
          ),
        const SizedBox(height: 16),
        Expanded(
          child: summary == null || summary.rows.isEmpty
              ? Center(
                  child: Text(
                    'No report data',
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                )
              : Container(
                  decoration: BoxDecoration(
                    color: AppColors.surface1,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      _reportHeader(),
                      Expanded(
                        child: ListView.builder(
                          itemCount: summary.rows.length,
                          itemBuilder: (context, index) {
                            final row = summary.rows[index];
                            final bg = index.isEven ? AppColors.surface1 : AppColors.surface0;
                            return Container(
                              color: bg,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              child: Row(
                                children: [
                                  _cell(row.restaurantName, flex: 3),
                                  _cell('₫${currency.format(row.dineIn)}'),
                                  _cell('₫${currency.format(row.delivery)}'),
                                  _cell('₫${currency.format(row.total)}'),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _summaryCard(String title, String value) {
    return Container(
      width: 220,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          Text(
            value,
            style: GoogleFonts.bebasNeue(
              color: AppColors.amber500,
              fontSize: 30,
            ),
          ),
        ],
      ),
    );
  }

  Widget _reportHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.surface2)),
      ),
      child: Row(
        children: [
          _cell('Restaurant', flex: 3, bold: true),
          _cell('Dine-in', bold: true),
          _cell('Delivery', bold: true),
          _cell('Total', bold: true),
        ],
      ),
    );
  }

  Widget _cell(String text, {int flex = 1, bool bold = false}) {
    return Expanded(
      flex: flex,
      child: Text(
        text,
        style: GoogleFonts.notoSansKr(
          color: AppColors.textPrimary,
          fontSize: 12,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }
}

class _SystemSettingsTab extends StatelessWidget {
  const _SystemSettingsTab({required this.authState});

  final PosAuthState authState;

  @override
  Widget build(BuildContext context) {
    final projectRef = Uri.tryParse(AppConstants.supabaseUrl)?.host ?? AppConstants.supabaseUrl;
    final email = authState.user?.email?.toString() ?? '-';
    final role = authState.role?.toString() ?? '-';

    return SingleChildScrollView(
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface1,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'System Settings',
              style: GoogleFonts.bebasNeue(
                color: AppColors.amber500,
                fontSize: 30,
              ),
            ),
            const SizedBox(height: 10),
            _infoRow('Email', email),
            _infoRow('Role', role),
            _infoRow('Version', 'GLOBOS POS v1.0.0'),
            _infoRow('Supabase', projectRef),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: GoogleFonts.notoSansKr(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
