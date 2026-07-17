import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/auth_provider.dart';
import 'print_agent_coordinator.dart';
import 'print_job_agent_service.dart';

final printAgentDriverProvider = Provider<PrintAgentDriver>(
  (_) => PrintJobAgentService(),
);

final printAgentPreferenceStoreProvider = Provider<PrintAgentPreferenceStore>(
  (_) => SharedPreferencesPrintAgentPreferenceStore(),
);

final printAgentCoordinatorProvider =
    StateNotifierProvider<PrintAgentCoordinator, PrintAgentState>((ref) {
      final coordinator = PrintAgentCoordinator(
        agent: ref.watch(printAgentDriverProvider),
        preferenceStore: ref.watch(printAgentPreferenceStoreProvider),
      );
      ref.listen(authProvider, (_, next) {
        unawaited(
          coordinator.syncSession(
            authenticated: next.user != null,
            role: next.role,
            storeId: next.storeId,
          ),
        );
      }, fireImmediately: true);
      return coordinator;
    });
