import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/role_routes.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_models.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('Auth-less employee CRUD uses only workforce RPC contracts', () {
    final service = readRepoFile('lib/core/services/staff_service.dart');
    final provider = readRepoFile(
      'lib/features/admin/providers/staff_provider.dart',
    );
    final screen = readRepoFile('lib/features/admin/tabs/staff_tab.dart');

    expect(service, contains(".from('store_employees')"));
    expect(service, contains("'create_store_employee'"));
    expect(service, contains("'update_store_employee'"));
    expect(service, contains("'deactivate_store_employee'"));
    expect(service, isNot(contains("'create_staff_user'")));
    expect(service, isNot(contains("'p_employee_number'")));
    expect(provider, contains("json['employee_number']"));
    expect(provider, contains("json['employment_role']"));
    expect(screen, contains('staffEmployeeNumberGeneratedHint'));
    expect(screen, contains('staffEmployeeNumberReadOnly'));
    expect(screen, isNot(contains('passwordController')));
    expect(screen, isNot(contains('emailController')));
  });

  test('attendance kiosk combines employee number with a required photo', () {
    final attendanceService = readRepoFile(
      'lib/core/services/attendance_service.dart',
    );
    final kiosk = readRepoFile(
      'lib/features/attendance/attendance_kiosk_screen.dart',
    );
    final photo = readRepoFile('lib/features/photo_ops/photo_ops_screen.dart');

    expect(attendanceService, contains("'record_employee_attendance'"));
    expect(
      attendanceService,
      contains("'record_employee_attendance_with_photo'"),
    );
    expect(attendanceService, contains("'p_employee_number'"));
    expect(kiosk, contains("Key('attendance_employee_number_field')"));
    expect(kiosk, contains('ImageSource.camera'));
    expect(kiosk, contains("Key('attendance_photo_preview')"));
    expect(kiosk, isNot(contains('fingerprint')));
    expect(kiosk, isNot(contains('PIN')));
    expect(photo, contains("Key('photo_ops_employee_number_field')"));
    expect(photo, contains('photoOpsAttendanceNumberOnlySubtitle'));
    expect(photo, isNot(contains('photo-backed attendance')));
  });

  test('workforce presets pin owner, Photo, and Bunsik metadata', () {
    expect(WorkforcePresetCatalog.andreEmail, 'andre@globos.world');
    expect(WorkforcePresetCatalog.andreRole, 'super_admin');

    final photo = WorkforcePresetCatalog.photo('D7');
    expect(photo.map((row) => row.accountCode), [
      'photo_bm1',
      'photo_bm2',
      'd7_ops1',
    ]);
    expect(photo.where((row) => row.accountType == 'store_manager'), isEmpty);
    expect(photo.last.role, 'photo_objet_store_operator');

    final bunsik = WorkforcePresetCatalog.bunsik('BT');
    expect(bunsik.map((row) => row.accountCode), [
      'bunsik_bm1',
      'bunsik_sm1',
      'bt_pos1',
      'bt_tab1',
      'bt_kit1',
    ]);
  });

  test('setup and Photo inventory consume additive RPC contracts', () {
    final setupService = readRepoFile(
      'lib/features/store_setup/store_setup_service.dart',
    );
    final setupUi = readRepoFile(
      'lib/features/store_setup/widgets/workforce_setup_card.dart',
    );
    final setupProvider = readRepoFile(
      'lib/features/store_setup/store_setup_provider.dart',
    );
    final setupModels = readRepoFile(
      'lib/features/store_setup/store_setup_models.dart',
    );
    final inventory = readRepoFile('lib/core/services/inventory_service.dart');
    final photo = readRepoFile('lib/features/photo_ops/photo_ops_screen.dart');

    expect(setupService, contains("'admin_configure_store_workforce'"));
    expect(setupService, contains("'admin_get_store_workforce_readiness'"));
    expect(setupService, contains("'provision-fixed-pos-account'"));
    expect(setupService, contains("'requirement_id': requirementId"));
    expect(setupService, contains("'rotate_password': false"));
    expect(setupUi, contains("Key('store_setup_add_account_template')"));
    expect(setupUi, contains("RegExp(r'^[A-Z0-9]{2,6}\$')"));
    expect(setupUi, contains("Key('store_setup_provision_password')"));
    expect(
      setupUi,
      contains("Key('store_setup_provision_password_confirmation')"),
    );
    expect(setupProvider, isNot(contains('final String? password')));
    expect(setupModels, isNot(contains('final String? password')));
    expect(setupUi, contains('WorkforcePresetCatalog.photo'));
    expect(setupUi, contains('WorkforcePresetCatalog.bunsik'));
    expect(inventory, contains("'record_employee_inventory_adjustment'"));
    expect(inventory, contains("'p_employee_number'"));
    expect(photo, contains("'restock'"));
    expect(photo, contains("'adjust'"));
    expect(photo, contains("'waste'"));
    expect(photo, contains("Key('photo_ops_inventory_adjustment_save')"));
  });

  test(
    'new workforce copy has complete EN KO VI resources and is consumed',
    () {
      const keys = {
        'attendanceEmployeeNumber',
        'attendanceEmployeeNumberOnlyHint',
        'staffEmployeeNumberGeneratedHint',
        'staffEmploymentRolePartTimer',
        'storeSetupWorkforceTitle',
        'storeSetupConfigureWorkforce',
        'storeSetupProvisionAccount',
        'storeSetupConfirmPassword',
        'photoOpsPartTimerAttendanceTitle',
        'photoOpsInventoryAdjustmentType',
      };
      final resources = {
        for (final locale in ['en', 'ko', 'vi'])
          locale:
              jsonDecode(readRepoFile('lib/l10n/app_$locale.arb'))
                  as Map<String, dynamic>,
      };
      for (final entry in resources.entries) {
        for (final key in keys) {
          expect(
            entry.value[key]?.toString().trim(),
            isNotEmpty,
            reason: '${entry.key} missing $key',
          );
        }
      }
      final surfaces = [
        readRepoFile('lib/features/attendance/attendance_kiosk_screen.dart'),
        readRepoFile('lib/features/admin/tabs/staff_tab.dart'),
        readRepoFile(
          'lib/features/store_setup/widgets/workforce_setup_card.dart',
        ),
        readRepoFile('lib/features/photo_ops/photo_ops_screen.dart'),
      ].join('\n');
      for (final key in keys) {
        expect(surfaces, contains('l10n.$key'), reason: '$key is not consumed');
      }
    },
  );

  test('Photo store operator is constrained to two routes', () {
    expect(homeRouteForRole('photo_objet_store_operator'), '/photo-ops');
    expect(
      canAccessRouteForRole('photo_objet_store_operator', '/photo-ops'),
      isTrue,
    );
    expect(
      canAccessRouteForRole('photo_objet_store_operator', '/attendance-kiosk'),
      isTrue,
    );
    for (final forbidden in ['/admin', '/cashier', '/waiter', '/kitchen']) {
      expect(
        canAccessRouteForRole('photo_objet_store_operator', forbidden),
        isFalse,
      );
    }
    expect(homeRouteForRole('photo_objet_store_admin'), '/login');
    expect(
      canAccessRouteForRole('photo_objet_store_admin', '/photo-ops'),
      isFalse,
    );
  });

  test('Photo master can open manager workforce surfaces', () {
    expect(canAccessRouteForRole('photo_objet_master', '/admin'), isTrue);
    expect(
      canAccessRouteForRole('photo_objet_master', '/store-setup/store-1'),
      isTrue,
    );
  });
}
