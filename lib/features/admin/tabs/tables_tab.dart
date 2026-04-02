import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../main.dart';
import '../../auth/auth_provider.dart';
import '../providers/tables_provider.dart';

class TablesTab extends ConsumerWidget {
  const TablesTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final restaurantId = ref.watch(authProvider).restaurantId;

    if (restaurantId == null) {
      return const _RestaurantMissingView();
    }

    final tablesState = ref.watch(tablesProvider(restaurantId));
    final tablesNotifier = ref.read(tablesProvider(restaurantId).notifier);

    return Scaffold(
      backgroundColor: AppColors.surface0,
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.amber500,
        onPressed: () => _showAddTableDialog(context, tablesNotifier),
        child: const Icon(Icons.add, color: AppColors.surface0),
      ),
      body: tablesState.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: AppColors.amber500),
        ),
        error: (error, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Failed to load tables.',
                style: GoogleFonts.notoSansKr(
                  color: AppColors.statusCancelled,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: tablesNotifier.fetchTables,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.amber500,
                  foregroundColor: AppColors.surface0,
                ),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (tables) {
          if (tables.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.table_restaurant,
                    size: 48,
                    color: AppColors.textSecondary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'No tables yet. Add your first table.',
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            );
          }

          return GridView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: tables.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.25,
            ),
            itemBuilder: (context, index) {
              final table = tables[index];
              final tableId = table['id']?.toString() ?? '';
              final tableNumber = table['table_number']?.toString() ?? '-';
              final seatCount = table['seat_count']?.toString() ?? '0';
              final occupied = _isOccupied(table);

              return Container(
                decoration: BoxDecoration(
                  color: AppColors.surface1,
                  borderRadius: BorderRadius.circular(16),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.topRight,
                      child: InkWell(
                        onTap: tableId.isEmpty
                            ? null
                            : () => tablesNotifier.deleteTable(tableId),
                        child: const Icon(
                          Icons.delete_outline,
                          color: AppColors.textSecondary,
                          size: 18,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      tableNumber,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.bebasNeue(
                        color: AppColors.amber500,
                        fontSize: 32,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$seatCount seats',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: occupied
                                ? AppColors.statusOccupied
                                : AppColors.statusAvailable,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          occupied ? 'Occupied' : 'Available',
                          style: GoogleFonts.notoSansKr(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _showAddTableDialog(
    BuildContext context,
    TablesNotifier tablesNotifier,
  ) async {
    final tableController = TextEditingController();
    final seatController = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface1,
          title: Text(
            'Add Table',
            style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: tableController,
                style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                decoration: const InputDecoration(labelText: 'Table number'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: seatController,
                keyboardType: TextInputType.number,
                style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                decoration: const InputDecoration(labelText: 'Seat count'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              onPressed: () async {
                final tableNumber = tableController.text.trim();
                final seatCount = int.tryParse(seatController.text.trim());
                if (tableNumber.isEmpty || seatCount == null || seatCount <= 0) {
                  return;
                }

                await tablesNotifier.addTable(tableNumber, seatCount);
                if (context.mounted) {
                  Navigator.of(context).pop();
                }
              },
              child: const Text('Add'),
            ),
          ],
        );
      },
    );

    tableController.dispose();
    seatController.dispose();
  }

  bool _isOccupied(Map<String, dynamic> table) {
    final status = table['status']?.toString().toLowerCase();
    final isOccupied = table['is_occupied'];

    if (isOccupied is bool) {
      return isOccupied;
    }

    return status == 'occupied';
  }
}

class _RestaurantMissingView extends StatelessWidget {
  const _RestaurantMissingView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: Center(
        child: Text(
          'Restaurant not found for this account.',
          style: GoogleFonts.notoSansKr(
            color: AppColors.statusCancelled,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}
