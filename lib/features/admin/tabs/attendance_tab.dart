import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../../main.dart';
import '../../auth/auth_provider.dart';
import '../providers/staff_provider.dart';

class AttendanceTab extends ConsumerStatefulWidget {
  const AttendanceTab({super.key});

  @override
  ConsumerState<AttendanceTab> createState() => _AttendanceTabState();
}

class _AttendanceTabState extends ConsumerState<AttendanceTab> {
  String? _initializedRestaurantId;

  @override
  Widget build(BuildContext context) {
    final restaurantId = ref.watch(authProvider).restaurantId;
    final attendanceState = ref.watch(attendanceProvider);
    final notifier = ref.read(attendanceProvider.notifier);
    final currentDate = attendanceState.selectedDate ?? DateTime.now();

    if (restaurantId != null && _initializedRestaurantId != restaurantId) {
      _initializedRestaurantId = restaurantId;
      Future.microtask(() => notifier.loadLogs(restaurantId));
    }

    final grouped = <String, List<AttendanceRecord>>{};
    for (final log in attendanceState.logs) {
      final key = '${log.userName}|${log.userRole ?? ''}';
      grouped.putIfAbsent(key, () => <AttendanceRecord>[]).add(log);
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
                  'Attendance',
                  style: GoogleFonts.bebasNeue(
                    color: AppColors.textPrimary,
                    fontSize: 34,
                    letterSpacing: 1.0,
                  ),
                ),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: currentDate,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now(),
                    );
                    if (picked != null && restaurantId != null) {
                      notifier.loadLogs(restaurantId, date: picked);
                    }
                  },
                  icon: const Icon(Icons.event),
                  label: Text(DateFormat('dd/MM/yyyy').format(currentDate)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (attendanceState.error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  attendanceState.error!,
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.statusCancelled,
                    fontSize: 13,
                  ),
                ),
              ),
            Expanded(
              child: attendanceState.isLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: AppColors.amber500),
                    )
                  : attendanceState.logs.isEmpty
                  ? Center(
                      child: Text(
                        'No attendance logs for selected date',
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                    )
                  : ListView(
                      children: grouped.entries.map((entry) {
                        final parts = entry.key.split('|');
                        final userName = parts.first;
                        final role = parts.length > 1 ? parts.last : '';
                        final logs = entry.value;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          decoration: BoxDecoration(
                            color: AppColors.surface1,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  userName,
                                  style: GoogleFonts.notoSansKr(
                                    color: AppColors.textPrimary,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (role.isNotEmpty)
                                  Text(
                                    role,
                                    style: GoogleFonts.notoSansKr(
                                      color: AppColors.textSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                const SizedBox(height: 8),
                                ...logs.map((log) {
                                  final isClockIn =
                                      log.type.toLowerCase() == 'clock_in';
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Row(
                                      children: [
                                        Icon(
                                          isClockIn
                                              ? Icons.arrow_upward
                                              : Icons.arrow_downward,
                                          color: isClockIn
                                              ? AppColors.statusAvailable
                                              : AppColors.statusCancelled,
                                          size: 18,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            isClockIn ? 'Clock in' : 'Clock out',
                                            style: GoogleFonts.notoSansKr(
                                              color: AppColors.textPrimary,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          DateFormat('HH:mm').format(log.loggedAt),
                                          style: GoogleFonts.notoSansKr(
                                            color: AppColors.textSecondary,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
