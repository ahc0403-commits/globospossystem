import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('Office QSC issue queue contract stays service/provider only', () {
    final service = readRepoFile('lib/core/services/qc_service.dart');
    final provider = readRepoFile('lib/features/qc/qc_provider.dart');
    final screen = readRepoFile('lib/features/qc/qc_review_screen.dart');
    final views = readRepoFile(
      'supabase/migrations/20260507000006_qsc_v2_office_read_model_views.sql',
    );

    expect(service, contains("from('v_office_qsc_issue_queue')"));
    expect(service, contains(".eq('store_id', storeId)"));
    expect(service, contains("order('check_date', ascending: false)"));

    expect(provider, contains('class QcIssueQueueState'));
    expect(provider, contains('class QcIssueQueueNotifier'));
    expect(provider, contains('qcIssueQueueProvider'));
    expect(
      views,
      contains('CREATE OR REPLACE VIEW public.v_office_qsc_issue_queue'),
    );

    expect(screen, isNot(contains('Issue Queue')));
    expect(screen, isNot(contains('Queue Detail')));
    expect(screen, isNot(contains('Refresh Issue Queue')));
    expect(screen, isNot(contains('qcIssueQueueProvider')));
    expect(screen, isNot(contains('_queueMetricCard(')));
    expect(screen, isNot(contains('_issueSeverityFilter')));
    expect(screen, isNot(contains("path: '/qsc-issues'")));
  });

  test('mobile QSC review uses SV review flow and separated permission', () {
    final service = readRepoFile('lib/core/services/qc_service.dart');
    final screen = readRepoFile('lib/features/qc/qc_review_screen.dart');
    final checkScreen = readRepoFile('lib/features/qc/qc_check_screen.dart');
    final router = readRepoFile('lib/core/router/app_router.dart');
    final permission = readRepoFile('lib/core/utils/permission_utils.dart');
    final migration = readRepoFile(
      'supabase/migrations/20260516000000_qsc_mobile_role_split.sql',
    );

    expect(screen, contains('class QcReviewScreen'));
    expect(screen, contains('submitVisitReview'));
    expect(screen, contains('qscMarkReviewed'));
    expect(screen, contains('qscNeedsFollowUp'));
    expect(screen, contains('fetchCheckPhotos'));

    expect(checkScreen, contains('entry.value.hasInput'));
    expect(checkScreen, contains("result: entry.value.result ?? 'na'"));
    expect(checkScreen, contains('qscInputComplete'));
    expect(checkScreen, contains('isInitialTemplateLoad'));
    expect(checkScreen, contains('templateState.templates.isEmpty'));
    expect(
      checkScreen,
      isNot(contains('templateState.isLoading || checkState.isLoading')),
    );
    expect(checkScreen, isNot(contains('_resultButton(')));

    expect(router, contains("path: '/qc-review'"));
    expect(router, contains('canDoQcVisitReview'));
    expect(
      permission,
      contains("extraPermissions.contains('qc_visit_review')"),
    );

    expect(service, contains("'submitted_at': map['submitted_at']"));
    expect(service, contains("'template_qsc_domain'"));
    expect(service, contains("'template_is_sv_required'"));
    expect(migration, contains("ARRAY['qc_check']"));
    expect(migration, contains("ARRAY['qc_visit_review']"));
    expect(
      migration,
      contains('CREATE OR REPLACE FUNCTION public.submit_qc_visit_review'),
    );
    final reviewFunction = migration.substring(
      migration.indexOf(
        'CREATE OR REPLACE FUNCTION public.submit_qc_visit_review',
      ),
    );
    expect(reviewFunction, contains("ARRAY['qc_visit_review']"));
    expect(reviewFunction, isNot(contains("ARRAY['qc_check']")));
  });
}
