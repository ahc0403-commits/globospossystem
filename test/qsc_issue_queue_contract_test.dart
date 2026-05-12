import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('qsc issue queue first slice stays read-only and depends on tracked view', () {
    final service = readRepoFile('lib/core/services/qc_service.dart');
    final provider = readRepoFile('lib/features/qc/qc_provider.dart');
    final screen = readRepoFile('lib/features/qc/qc_review_screen.dart');

    expect(service, contains("from('v_office_qsc_issue_queue')"));
    expect(service, contains(".eq('store_id', storeId)"));
    expect(service, contains("order('check_date', ascending: false)"));

    expect(provider, contains('class QcIssueQueueState'));
    expect(provider, contains('class QcIssueQueueNotifier'));
    expect(provider, contains('qcIssueQueueProvider'));

    expect(screen, contains('Issue Queue'));
    expect(screen, contains('Queue Detail'));
    expect(screen, contains('Refresh Issue Queue'));
    expect(screen, contains('Review Focus'));
    expect(screen, contains('Critical \$criticalIssueCount'));
    expect(screen, contains('Photo gap \$missingPhotoIssueCount'));
    expect(screen, contains('Read-only queue surface only.'));
    expect(screen, contains('qcIssueQueueProvider'));
    expect(screen, contains('_issueSeverityFilter'));
    expect(screen, contains('_issueSubmissionFilter'));
    expect(screen, contains('_formatIssueTimestamp('));

    expect(screen, isNot(contains("path: '/qsc-issues'")));
    expect(screen, isNot(contains('createFollowup(')));
    expect(screen, isNot(contains('updateFollowupStatus(')));
  });
}
