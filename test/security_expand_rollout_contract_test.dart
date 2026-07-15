import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String path) => File(path).readAsStringSync();

void main() {
  const expand =
      'supabase/migrations/20260715020000_security_expand_compat.sql';

  test('Expand keeps both legacy and v2 RPC boundaries callable', () {
    final sql = read(expand);
    expect(sql, contains('CREATE OR REPLACE FUNCTION public.process_payment('));
    expect(sql, contains('p_payment_attempt_id uuid'));
    expect(
      sql,
      contains(
        'GRANT EXECUTE ON FUNCTION public.process_payment(uuid, uuid, numeric, text) TO authenticated, service_role;',
      ),
    );
    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.attach_payment_proof_v2('),
    );
    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.set_payroll_pin_v2('),
    );
    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.clear_payroll_pin_v2('),
    );
    expect(
      sql,
      isNot(contains('DROP FUNCTION IF EXISTS public.attach_payment_proof(')),
    );
    expect(
      sql,
      isNot(
        contains(
          'REVOKE EXECUTE ON FUNCTION public.process_payment(uuid, uuid, numeric, text) FROM PUBLIC, anon, authenticated',
        ),
      ),
    );
    expect(sql, isNot(contains('NULL::text AS payroll_pin')));
  });

  test('Contract and emergency regrant drafts cannot be normal migrations', () {
    final contract = read(
      'docs/security_rollout/sql/security_contract_draft.sql',
    );
    final regrant = read(
      'docs/security_rollout/sql/security_contract_emergency_regrant.sql',
    );
    final deploy = read('scripts/deploy_pos_production.sh');

    expect(contract, contains('SECURITY_CONTRACT_APPROVAL_REQUIRED'));
    expect(
      contract,
      contains('REVOKE EXECUTE ON FUNCTION public.process_payment'),
    );
    expect(
      regrant,
      contains('GRANT EXECUTE ON FUNCTION public.process_payment'),
    );
    expect(deploy, contains('Contract draft is never deployable'));
    final migrationPaths = Directory(
      'supabase/migrations',
    ).listSync().whereType<File>().map((file) => file.path);
    expect(
      migrationPaths.any((path) => path.contains('contract_draft')),
      isFalse,
    );
  });

  test(
    'new staff creation never offers legacy admin while display stays compatible',
    () {
      final roles = read('lib/core/utils/staff_role_utils.dart');
      final staffTab = read('lib/features/admin/tabs/staff_tab.dart');
      final staffService = read('lib/core/services/staff_service.dart');
      final assignable = roles.substring(
        roles.indexOf('List<String> assignableRolesForViewer'),
        roles.indexOf('bool canMutateStaffAccount'),
      );
      final options = staffTab.substring(
        staffTab.indexOf(
          'List<DropdownMenuItem<String>> _availableRoleOptions',
        ),
      );

      expect(assignable, isNot(contains("      'admin',")));
      expect(assignable, isNot(contains("...baseRoles, 'admin'")));
      expect(options, isNot(contains("value: 'admin'")));
      expect(roles, contains("'admin' => 'Admin'"));
      expect(staffTab, contains("'admin' => 'Admin'"));
      expect(staffService, contains("if (!_newStaffRoles.contains(role))"));
      final creationRoleSet = staffService.substring(
        staffService.indexOf('static const _newStaffRoles'),
        staffService.indexOf('Future<Map<String, dynamic>> createStaffUser'),
      );
      expect(creationRoleSet, isNot(contains("'admin'")));
    },
  );

  test('Vercel revalidates only Flutter shell files', () {
    final config = jsonDecode(read('vercel.json')) as Map<String, dynamic>;
    final headers = (config['headers'] as List).cast<Map<String, dynamic>>();
    final sources = headers.map((entry) => entry['source']).toSet();
    expect(
      sources,
      containsAll(<String>{
        '/',
        '/index.html',
        '/flutter_bootstrap.js',
        '/flutter_service_worker.js',
        '/main.dart.js',
      }),
    );
    expect(read('vercel.json'), isNot(contains('/assets/(.*)')));
  });

  test('legacy cleanup remains read-only and bounded at 10x batch volume', () {
    const batchSize = 25;
    final candidates = List<int>.generate(batchSize * 10, (index) => index);
    final batches = <List<int>>[];
    for (var offset = 0; offset < candidates.length; offset += batchSize) {
      final end = (offset + batchSize).clamp(0, candidates.length);
      batches.add(candidates.sublist(offset, end));
    }

    expect(batches, hasLength(10));
    expect(batches.every((batch) => batch.length <= batchSize), isTrue);
    expect(batches.expand((batch) => batch), orderedEquals(candidates));

    final runbook = read(
      'docs/security_rollout/LEGACY_PAYMENT_PROOF_URL_CLEANUP_RUNBOOK.md',
    );
    final inventory = read('scripts/inventory_legacy_payment_proofs.sql');
    expect(runbook, contains('maximum of 25 objects per batch'));
    expect(inventory, contains('BEGIN TRANSACTION READ ONLY'));
    expect(inventory.toUpperCase(), isNot(contains('UPDATE PUBLIC.')));
    expect(inventory.toUpperCase(), isNot(contains('DELETE FROM')));
  });

  test(
    'deployment harness has explicit audit and Expand preflight verification',
    () {
      final deploy = read('scripts/deploy_pos_production.sh');
      for (final name in <String>[
        'preflight_security_audit_hardening.sql',
        'verify_security_audit_hardening.sql',
        'preflight_security_expand_compat.sql',
        'verify_security_expand_compat.sql',
      ]) {
        expect(deploy, contains(name));
        expect(File('scripts/$name').existsSync(), isTrue);
      }
      expect(deploy, isNot(contains('supabase db push')));
    },
  );
}
