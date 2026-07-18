import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/printer_destination_service.dart';

class PrinterDestinationErrorCodes {
  const PrinterDestinationErrorCodes._();

  static const nameRequired = 'PRINTER_NAME_REQUIRED';
  static const ipRequired = 'PRINTER_IP_REQUIRED';
  static const portInvalid = 'PRINTER_PORT_INVALID';
  static const purposeInvalid = 'PRINTER_PURPOSE_INVALID';
  static const floorRequired = 'PRINTER_FLOOR_LABEL_REQUIRED';
  static const permissionDenied = 'ADMIN_MUTATION_FORBIDDEN';
  static const loadFailed = 'PRINTER_ROUTING_LOAD_FAILED';
  static const saveFailed = 'PRINTER_ROUTING_SAVE_FAILED';
  static const removeFailed = 'PRINTER_ROUTING_REMOVE_FAILED';
  static const testFailed = 'PRINTER_ROUTING_TEST_FAILED';
}

class PrinterDestinationsState {
  const PrinterDestinationsState({
    this.destinations = const <PrinterDestinationConfig>[],
    this.isLoading = false,
    this.isSaving = false,
    this.error,
  });

  final List<PrinterDestinationConfig> destinations;
  final bool isLoading;
  final bool isSaving;
  final String? error;

  PrinterDestinationsState copyWith({
    List<PrinterDestinationConfig>? destinations,
    bool? isLoading,
    bool? isSaving,
    String? error,
    bool clearError = false,
  }) {
    return PrinterDestinationsState(
      destinations: destinations ?? this.destinations,
      isLoading: isLoading ?? this.isLoading,
      isSaving: isSaving ?? this.isSaving,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class PrinterDestinationsNotifier
    extends StateNotifier<PrinterDestinationsState> {
  PrinterDestinationsNotifier(this.storeId, {bool autoLoad = true})
    : super(const PrinterDestinationsState()) {
    if (autoLoad) {
      fetchDestinations();
    }
  }

  final String storeId;

  String _mapPrinterDestinationError(Object error, String fallbackCode) {
    if (error is! PostgrestException) {
      return fallbackCode;
    }

    final message = error.message;
    if (message.contains(PrinterDestinationErrorCodes.nameRequired)) {
      return PrinterDestinationErrorCodes.nameRequired;
    }
    if (message.contains(PrinterDestinationErrorCodes.ipRequired)) {
      return PrinterDestinationErrorCodes.ipRequired;
    }
    if (message.contains(PrinterDestinationErrorCodes.portInvalid)) {
      return PrinterDestinationErrorCodes.portInvalid;
    }
    if (message.contains(PrinterDestinationErrorCodes.purposeInvalid)) {
      return PrinterDestinationErrorCodes.purposeInvalid;
    }
    if (message.contains(PrinterDestinationErrorCodes.floorRequired)) {
      return PrinterDestinationErrorCodes.floorRequired;
    }
    if (message.contains(PrinterDestinationErrorCodes.permissionDenied)) {
      return PrinterDestinationErrorCodes.permissionDenied;
    }

    return fallbackCode;
  }

  Future<void> fetchDestinations({bool showLoading = true}) async {
    if (showLoading) {
      state = state.copyWith(isLoading: true, clearError: true);
    }

    try {
      final destinations = await printerDestinationService.fetchDestinations(
        storeId,
      );
      state = state.copyWith(
        destinations: destinations,
        isLoading: false,
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: _mapPrinterDestinationError(
          error,
          PrinterDestinationErrorCodes.loadFailed,
        ),
      );
    }
  }

  Future<bool> upsertDestination(PrinterDestinationDraft draft) async {
    state = state.copyWith(isSaving: true, clearError: true);
    try {
      await printerDestinationService.upsertDestination(
        storeId: storeId,
        draft: draft,
      );
      await fetchDestinations(showLoading: false);
      state = state.copyWith(isSaving: false, clearError: true);
      return true;
    } catch (error) {
      state = state.copyWith(
        isSaving: false,
        error: _mapPrinterDestinationError(
          error,
          PrinterDestinationErrorCodes.saveFailed,
        ),
      );
      return false;
    }
  }

  Future<bool> deleteDestination(String destinationId) async {
    state = state.copyWith(isSaving: true, clearError: true);
    try {
      await printerDestinationService.deleteDestination(
        storeId: storeId,
        destinationId: destinationId,
      );
      await fetchDestinations(showLoading: false);
      state = state.copyWith(isSaving: false, clearError: true);
      return true;
    } catch (error) {
      state = state.copyWith(
        isSaving: false,
        error: _mapPrinterDestinationError(
          error,
          PrinterDestinationErrorCodes.removeFailed,
        ),
      );
      return false;
    }
  }

  Future<bool> enqueueTestPrintJob(String destinationId) async {
    state = state.copyWith(clearError: true);
    try {
      await printerDestinationService.enqueueTestPrintJob(
        storeId: storeId,
        destinationId: destinationId,
      );
      state = state.copyWith(clearError: true);
      return true;
    } catch (error) {
      state = state.copyWith(
        error: _mapPrinterDestinationError(
          error,
          PrinterDestinationErrorCodes.testFailed,
        ),
      );
      return false;
    }
  }
}

final printerDestinationsProvider = StateNotifierProvider.autoDispose
    .family<PrinterDestinationsNotifier, PrinterDestinationsState, String>(
      (ref, storeId) => PrinterDestinationsNotifier(storeId),
    );
