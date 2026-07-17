import '../../l10n/app_localizations.dart';
import 'store_setup_models.dart';

/// Server and queue codes that can reach a store-opening user surface.
///
/// The UI never renders these values directly. Keeping the catalog beside the
/// exhaustive switches lets contract tests compare backend producers with the
/// localized runtime boundary.
abstract final class StoreSetupCodeCatalog {
  static const validation = <String>{
    'STORE_SETUP_TABLES_ARRAY_REQUIRED',
    'STORE_SETUP_TABLES_REQUIRED',
    'STORE_SETUP_TABLE_LIMIT',
    'STORE_SETUP_DESTINATIONS_ARRAY_REQUIRED',
    'STORE_SETUP_DESTINATIONS_REQUIRED',
    'STORE_SETUP_DESTINATION_LIMIT',
    'STORE_SETUP_TABLE_NUMBER_INVALID',
    'STORE_SETUP_SEAT_COUNT_INVALID',
    'STORE_SETUP_FLOOR_LABEL_INVALID',
    'STORE_SETUP_DUPLICATE_TABLE_NUMBER',
    'STORE_SETUP_EXISTING_TABLE_IDENTITY_AMBIGUOUS',
    'STORE_SETUP_OCCUPIED_TABLE_CHANGE',
    'STORE_SETUP_DESTINATION_NAME_INVALID',
    'STORE_SETUP_PURPOSE_INVALID',
    'STORE_SETUP_IP_INVALID',
    'STORE_SETUP_PORT_INVALID',
    'STORE_SETUP_DESTINATION_FLOOR_INVALID',
    'STORE_SETUP_DUPLICATE_ROUTE',
    'STORE_SETUP_RECEIPT_ROUTE_REQUIRED',
    'STORE_SETUP_KITCHEN_ROUTE_REQUIRED',
    'STORE_SETUP_FLOOR_ROUTE_REQUIRED',
    'STORE_SETUP_MULTIPLE_INACTIVE_ROUTE_MATCHES',
    'STORE_SETUP_EXISTING_TABLES_UNTOUCHED',
    'STORE_SETUP_EXISTING_ROUTES_UNTOUCHED',
  };

  static const flowErrors = <String>{
    'STORE_SETUP_STORE_REQUIRED',
    'STORE_SETUP_STORE_NOT_FOUND',
    'STORE_SETUP_CONFIG_INVALID',
    'STORE_SETUP_LOAD_FAILED',
    'STORE_SETUP_VALIDATE_FAILED',
    'STORE_SETUP_APPLY_FAILED',
    'STORE_SETUP_DESTINATION_NOT_APPLIED',
    'STORE_SETUP_TEST_ENQUEUE_FAILED',
    'STORE_SETUP_TEST_JOB_ID_MISSING',
    'STORE_SETUP_TEST_TIMEOUT',
    'STORE_SETUP_TEST_POLL_FAILED',
    'STORE_SETUP_READINESS_FAILED',
    'STORE_SETUP_WORKFORCE_READINESS_FAILED',
    'STORE_SETUP_WORKFORCE_SAVE_FAILED',
    'STORE_SETUP_FIXED_ACCOUNT_PROVISION_FAILED',
    'PRINT_AGENT_PREFERENCE_READ_FAILED',
    'PRINT_AGENT_START_FAILED',
    'PRINT_AGENT_PROCESS_FAILED',
  };

  static const printJobStatuses = <String>{
    'pending',
    'printing',
    'done',
    'failed',
    'cancelled',
  };

  static const routePurposes = <String>{'receipt', 'kitchen', 'floor', 'tray'};

  static const printCopyTypes = <String>{
    'receipt',
    'kitchen',
    'floor',
    'tray',
    'confirmation',
  };

  static const testLabels = <String>{
    'TEST-RECEIPT',
    'TEST-KITCHEN',
    'TEST-1F',
    'TEST-2F',
    'TEST-3F',
  };

  static const printJobErrors = <String>{
    'NO_DESTINATION',
    'DESTINATION_NOT_FOUND',
    'connectionFailed',
    'printFailed',
    'notSupported',
    'PRINT_FAILED',
  };

  static const readinessChecks = <String>{
    'TABLES_CONFIGURED',
    'TABLE_FLOORS_VALID',
    'REQUIRED_ROUTES_CONFIGURED',
    'ACTIVE_ROUTES_UNIQUE',
    'NO_DESTINATION_CLEAR',
    'TEST_JOBS_DONE',
  };

  static const recovery = <String>{
    'STORE_SETUP_FIX_CONFIGURATION',
    'STORE_SETUP_RUN_OR_RETRY_TESTS',
    'STORE_SETUP_REVIEW_FAILED_JOBS',
  };
}

String localizeStoreSetupValidation(
  AppLocalizations l10n,
  String code,
) => switch (code) {
  'STORE_SETUP_TABLES_ARRAY_REQUIRED' =>
    l10n.storeSetupValidationTablesArrayRequired,
  'STORE_SETUP_TABLES_REQUIRED' => l10n.storeSetupValidationTablesRequired,
  'STORE_SETUP_TABLE_LIMIT' => l10n.storeSetupValidationTableLimit,
  'STORE_SETUP_DESTINATIONS_ARRAY_REQUIRED' =>
    l10n.storeSetupValidationDestinationsArrayRequired,
  'STORE_SETUP_DESTINATIONS_REQUIRED' =>
    l10n.storeSetupValidationDestinationsRequired,
  'STORE_SETUP_DESTINATION_LIMIT' => l10n.storeSetupValidationDestinationLimit,
  'STORE_SETUP_TABLE_NUMBER_INVALID' =>
    l10n.storeSetupValidationTableNumberInvalid,
  'STORE_SETUP_SEAT_COUNT_INVALID' => l10n.storeSetupValidationSeatCountInvalid,
  'STORE_SETUP_FLOOR_LABEL_INVALID' =>
    l10n.storeSetupValidationFloorLabelInvalid,
  'STORE_SETUP_DUPLICATE_TABLE_NUMBER' =>
    l10n.storeSetupValidationDuplicateTableNumber,
  'STORE_SETUP_EXISTING_TABLE_IDENTITY_AMBIGUOUS' =>
    l10n.storeSetupValidationExistingTableIdentityAmbiguous,
  'STORE_SETUP_OCCUPIED_TABLE_CHANGE' =>
    l10n.storeSetupValidationOccupiedTableChange,
  'STORE_SETUP_DESTINATION_NAME_INVALID' =>
    l10n.storeSetupValidationDestinationNameInvalid,
  'STORE_SETUP_PURPOSE_INVALID' => l10n.storeSetupValidationPurposeInvalid,
  'STORE_SETUP_IP_INVALID' => l10n.storeSetupValidationIpInvalid,
  'STORE_SETUP_PORT_INVALID' => l10n.storeSetupValidationPortInvalid,
  'STORE_SETUP_DESTINATION_FLOOR_INVALID' =>
    l10n.storeSetupValidationDestinationFloorInvalid,
  'STORE_SETUP_DUPLICATE_ROUTE' => l10n.storeSetupValidationDuplicateRoute,
  'STORE_SETUP_RECEIPT_ROUTE_REQUIRED' =>
    l10n.storeSetupValidationReceiptRouteRequired,
  'STORE_SETUP_KITCHEN_ROUTE_REQUIRED' =>
    l10n.storeSetupValidationKitchenRouteRequired,
  'STORE_SETUP_FLOOR_ROUTE_REQUIRED' =>
    l10n.storeSetupValidationFloorRouteRequired,
  'STORE_SETUP_MULTIPLE_INACTIVE_ROUTE_MATCHES' =>
    l10n.storeSetupValidationMultipleInactiveRouteMatches,
  'STORE_SETUP_EXISTING_TABLES_UNTOUCHED' =>
    l10n.storeSetupWarningExistingTablesUntouched,
  'STORE_SETUP_EXISTING_ROUTES_UNTOUCHED' =>
    l10n.storeSetupWarningExistingRoutesUntouched,
  _ => l10n.storeSetupUnknownDiagnostic,
};

String localizeStoreSetupFlowError(AppLocalizations l10n, String code) =>
    switch (code) {
      'STORE_SETUP_STORE_REQUIRED' => l10n.storeSetupErrorStoreRequired,
      'STORE_SETUP_STORE_NOT_FOUND' => l10n.storeSetupErrorStoreNotFound,
      'STORE_SETUP_CONFIG_INVALID' => l10n.storeSetupErrorInvalid,
      'STORE_SETUP_LOAD_FAILED' => l10n.storeSetupErrorLoad,
      'STORE_SETUP_VALIDATE_FAILED' => l10n.storeSetupErrorValidate,
      'STORE_SETUP_APPLY_FAILED' => l10n.storeSetupErrorApply,
      'STORE_SETUP_DESTINATION_NOT_APPLIED' =>
        l10n.storeSetupErrorDestinationNotApplied,
      'STORE_SETUP_TEST_ENQUEUE_FAILED' => l10n.storeSetupErrorTest,
      'STORE_SETUP_TEST_JOB_ID_MISSING' => l10n.storeSetupErrorTestJobIdMissing,
      'STORE_SETUP_TEST_TIMEOUT' => l10n.storeSetupErrorTestTimeout,
      'STORE_SETUP_TEST_POLL_FAILED' => l10n.storeSetupErrorTestPoll,
      'STORE_SETUP_READINESS_FAILED' => l10n.storeSetupErrorReadiness,
      'STORE_SETUP_WORKFORCE_READINESS_FAILED' =>
        l10n.storeSetupErrorWorkforceReadiness,
      'STORE_SETUP_WORKFORCE_SAVE_FAILED' => l10n.storeSetupErrorWorkforceSave,
      'STORE_SETUP_FIXED_ACCOUNT_PROVISION_FAILED' =>
        l10n.storeSetupErrorAccountProvision,
      'PRINT_AGENT_PREFERENCE_READ_FAILED' =>
        l10n.storeSetupErrorAgentPreferenceRead,
      'PRINT_AGENT_START_FAILED' => l10n.storeSetupErrorAgentStart,
      'PRINT_AGENT_PROCESS_FAILED' => l10n.storeSetupErrorAgentProcess,
      _ => l10n.storeSetupUnknownDiagnostic,
    };

String localizePrintJobStatus(AppLocalizations l10n, String status) =>
    switch (status) {
      'pending' => l10n.storeSetupPrintStatusPending,
      'printing' => l10n.storeSetupPrintStatusPrinting,
      'done' => l10n.storeSetupPrintStatusDone,
      'failed' => l10n.storeSetupPrintStatusFailed,
      'cancelled' => l10n.storeSetupPrintStatusCancelled,
      _ => l10n.storeSetupPrintStatusUnknown,
    };

String localizeStoreSetupRoutePurpose(AppLocalizations l10n, String purpose) =>
    switch (purpose) {
      'receipt' => l10n.storeSetupPurposeReceipt,
      'kitchen' => l10n.storeSetupPurposeKitchen,
      'floor' => l10n.storeSetupPurposeFloor,
      'tray' => l10n.storeSetupPurposeTray,
      _ => l10n.storeSetupPurposeUnknown,
    };

String localizePhysicalPrinterSlot(
  AppLocalizations l10n,
  PhysicalPrinterSlot slot,
) => switch (slot) {
  PhysicalPrinterSlot.cashier => l10n.storeSetupCashierPrinter,
  PhysicalPrinterSlot.kitchen => l10n.storeSetupKitchenPrinter,
  PhysicalPrinterSlot.floor2 => l10n.storeSetupFloor2Printer,
  PhysicalPrinterSlot.floor3 => l10n.storeSetupFloor3Printer,
};

String localizeStoreSetupTestLabel(AppLocalizations l10n, String label) =>
    switch (label) {
      'TEST-RECEIPT' => l10n.storeSetupTestLabelReceipt,
      'TEST-KITCHEN' => l10n.storeSetupTestLabelKitchen,
      'TEST-1F' => l10n.storeSetupTestLabelFloor1,
      'TEST-2F' => l10n.storeSetupTestLabelFloor2,
      'TEST-3F' => l10n.storeSetupTestLabelFloor3,
      _ => l10n.storeSetupTestLabelUnknown,
    };

String localizePrintCopyType(AppLocalizations l10n, String copyType) =>
    switch (copyType) {
      'receipt' ||
      'kitchen' ||
      'floor' ||
      'tray' => localizeStoreSetupRoutePurpose(l10n, copyType),
      'confirmation' => l10n.storeSetupPrintCopyConfirmation,
      _ => l10n.storeSetupPrintCopyUnknown,
    };

String localizePrintJobError(AppLocalizations l10n, String error) =>
    switch (error) {
      'NO_DESTINATION' => l10n.storeSetupPrintErrorNoDestination,
      'DESTINATION_NOT_FOUND' => l10n.storeSetupPrintErrorDestinationNotFound,
      'connectionFailed' => l10n.storeSetupPrintErrorConnectionFailed,
      'printFailed' || 'PRINT_FAILED' => l10n.storeSetupPrintErrorPrintFailed,
      'notSupported' => l10n.storeSetupPrintErrorNotSupported,
      _ => l10n.storeSetupPrintErrorUnknown,
    };

String localizeReadinessCheck(AppLocalizations l10n, String code) =>
    switch (code) {
      'TABLES_CONFIGURED' => l10n.storeSetupCheckTablesConfigured,
      'TABLE_FLOORS_VALID' => l10n.storeSetupCheckTableFloorsValid,
      'REQUIRED_ROUTES_CONFIGURED' =>
        l10n.storeSetupCheckRequiredRoutesConfigured,
      'ACTIVE_ROUTES_UNIQUE' => l10n.storeSetupCheckActiveRoutesUnique,
      'NO_DESTINATION_CLEAR' => l10n.storeSetupCheckNoDestinationClear,
      'TEST_JOBS_DONE' => l10n.storeSetupCheckTestJobsDone,
      _ => l10n.storeSetupCheckUnknown,
    };

String localizeStoreSetupRecovery(AppLocalizations l10n, String code) =>
    switch (code) {
      'STORE_SETUP_FIX_CONFIGURATION' => l10n.storeSetupRecoveryConfiguration,
      'STORE_SETUP_RUN_OR_RETRY_TESTS' => l10n.storeSetupRecoveryTests,
      'STORE_SETUP_REVIEW_FAILED_JOBS' => l10n.storeSetupRecoveryFailedJobs,
      _ => l10n.storeSetupUnknownDiagnostic,
    };
