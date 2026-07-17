import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_localization.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

void main() {
  test('new wizard keys exist in EN KO VI and are consumed by UI', () {
    final resources = [
      for (final locale in ['en', 'ko', 'vi'])
        jsonDecode(File('lib/l10n/app_$locale.arb').readAsStringSync())
            as Map<String, dynamic>,
    ];
    final keys = resources.first.keys
        .where((key) => key.startsWith('storeSetup') && !key.startsWith('@'))
        .toSet();
    expect(keys.length, greaterThanOrEqualTo(50));
    for (final resource in resources.skip(1)) {
      expect(resource.keys.where((key) => keys.contains(key)).toSet(), keys);
    }

    final consumed = [
      File('lib/features/store_setup/store_setup_screen.dart'),
      ...Directory(
        'lib/features/store_setup/widgets',
      ).listSync().whereType<File>(),
      File('lib/features/admin/tabs/settings_tab.dart'),
      File('lib/features/super_admin/super_admin_screen.dart'),
      File('lib/features/onboarding/onboarding_screen.dart'),
      File('lib/features/store_setup/store_setup_localization.dart'),
      File('lib/features/print_station/print_station_screen.dart'),
    ].map((file) => file.readAsStringSync()).join('\n');
    for (final key in keys) {
      expect(consumed, contains('l10n.$key'), reason: '$key is not consumed');
    }
  });

  test(
    'every supported locale maps every runtime code without echoing it',
    () async {
      for (final locale in AppLocalizations.supportedLocales) {
        final l10n = await AppLocalizations.delegate.load(locale);
        void expectMapped(
          Iterable<String> codes,
          String Function(String code) mapper,
        ) {
          for (final code in codes) {
            final message = mapper(code);
            expect(message.trim(), isNotEmpty, reason: '$locale / $code');
            expect(message, isNot(code), reason: '$locale echoed $code');
            expect(
              message,
              isNot(matches(RegExp(r'^[A-Z0-9_]+$'))),
              reason: '$locale exposed raw code $code',
            );
          }
        }

        expectMapped(
          StoreSetupCodeCatalog.validation,
          (code) => localizeStoreSetupValidation(l10n, code),
        );
        expectMapped(
          StoreSetupCodeCatalog.flowErrors,
          (code) => localizeStoreSetupFlowError(l10n, code),
        );
        expectMapped(
          StoreSetupCodeCatalog.printJobStatuses,
          (code) => localizePrintJobStatus(l10n, code),
        );
        expectMapped(
          StoreSetupCodeCatalog.printJobErrors,
          (code) => localizePrintJobError(l10n, code),
        );
        expectMapped(
          StoreSetupCodeCatalog.readinessChecks,
          (code) => localizeReadinessCheck(l10n, code),
        );
        expectMapped(
          StoreSetupCodeCatalog.recovery,
          (code) => localizeStoreSetupRecovery(l10n, code),
        );

        const unknown = 'STORE_SETUP_FUTURE_UNKNOWN_CODE';
        expect(
          localizeStoreSetupValidation(l10n, unknown),
          isNot(contains(unknown)),
        );
        expect(
          localizeStoreSetupFlowError(l10n, unknown),
          isNot(contains(unknown)),
        );
        expect(localizePrintJobStatus(l10n, unknown), isNot(contains(unknown)));
        expect(localizePrintJobError(l10n, unknown), isNot(contains(unknown)));
        expect(localizeReadinessCheck(l10n, unknown), isNot(contains(unknown)));
        expect(
          localizeStoreSetupRecovery(l10n, unknown),
          isNot(contains(unknown)),
        );
      }
    },
  );

  test(
    'producer catalogs are covered and user surfaces reject raw rendering',
    () {
      final migration = File(
        'supabase/migrations/20260717090000_store_opening_setup_wizard.sql',
      ).readAsStringSync();
      final provider = File(
        'lib/features/store_setup/store_setup_provider.dart',
      ).readAsStringSync();
      final coordinator = File(
        'lib/core/hardware/print_agent_coordinator.dart',
      ).readAsStringSync();
      final sqlMessages = RegExp(
        r"jsonb_build_array\('(STORE_SETUP_[A-Z0-9_]+)'\)",
      ).allMatches(migration).map((match) => match.group(1)!).toSet();
      expect(
        StoreSetupCodeCatalog.validation.union(StoreSetupCodeCatalog.recovery),
        containsAll(sqlMessages),
      );

      final flowProducers = RegExp(
        r"'(STORE_SETUP_(?:LOAD|VALIDATE|APPLY|DESTINATION|TEST|READINESS)[A-Z0-9_]*_FAILED|STORE_SETUP_DESTINATION_NOT_APPLIED|STORE_SETUP_TEST_JOB_ID_MISSING)'",
      ).allMatches(provider).map((match) => match.group(1)!).toSet();
      final agentProducers = RegExp(
        r"'(PRINT_AGENT_[A-Z0-9_]+)'",
      ).allMatches(coordinator).map((match) => match.group(1)!).toSet();
      expect(StoreSetupCodeCatalog.flowErrors, containsAll(flowProducers));
      expect(StoreSetupCodeCatalog.flowErrors, containsAll(agentProducers));

      final readinessCodes = RegExp(
        r"jsonb_build_object\('code', '([A-Z0-9_]+)'",
      ).allMatches(migration).map((match) => match.group(1)!).toSet();
      expect(StoreSetupCodeCatalog.readinessChecks, readinessCodes);

      final surfaces = [
        File('lib/features/store_setup/store_setup_screen.dart'),
        File('lib/features/store_setup/widgets/print_test_checklist.dart'),
        File('lib/features/store_setup/widgets/readiness_summary.dart'),
        File('lib/features/print_station/print_station_screen.dart'),
      ].map((file) => file.readAsStringSync()).join('\n');
      for (final forbidden in [
        'subtitle: Text(error)',
        'subtitle: Text(warning)',
        'Text(entry.value.error!)',
        "Text(check['code']?.toString()",
        'Text(job.lastError!)',
        'label: job.status',
        "detail: '\$error'",
      ]) {
        expect(
          surfaces,
          isNot(contains(forbidden)),
          reason: 'raw user-visible rendering: $forbidden',
        );
      }
      expect(surfaces, contains('localizeStoreSetupValidation('));
      expect(surfaces, contains('localizePrintJobStatus('));
      expect(surfaces, contains('localizePrintJobError('));
      expect(surfaces, contains('localizeReadinessCheck('));
    },
  );
}
