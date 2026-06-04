import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('web-facing photo pickers avoid dart:io File previews', () {
    final paymentProofModal = readRepoFile(
      'lib/features/cashier/payment_proof_modal.dart',
    );
    final qcTab = readRepoFile('lib/features/admin/tabs/qc_tab.dart');
    final superAdmin = readRepoFile(
      'lib/features/super_admin/super_admin_screen.dart',
    );

    for (final source in [paymentProofModal, qcTab, superAdmin]) {
      expect(source, isNot(contains("import 'dart:io';")));
      expect(source, isNot(contains('Image.file(')));
      expect(source, isNot(contains('File(picked.path)')));
    }

    expect(paymentProofModal, contains('XFile? _selectedFile'));
    expect(paymentProofModal, contains('Image.memory('));
    expect(qcTab, contains('XFile? selectedFile'));
    expect(qcTab, contains('Image.memory('));
    expect(superAdmin, contains('XFile? selectedFile'));
    expect(superAdmin, contains('Image.memory('));
  });

  test('photo upload services read cross-platform XFile bytes', () {
    final paymentProofService = readRepoFile(
      'lib/core/services/payment_proof_service.dart',
    );
    final qcService = readRepoFile('lib/core/services/qc_service.dart');
    final qcProvider = readRepoFile('lib/features/qc/qc_provider.dart');

    expect(paymentProofService, contains('required XFile originalFile'));
    expect(paymentProofService, contains('await originalFile.readAsBytes()'));
    expect(paymentProofService, contains('image_bytes_base64'));
    expect(paymentProofService, contains('kIsWeb'));

    expect(qcService, contains('required XFile file'));
    expect(qcService, contains('_prepareQcPhotoUpload(file)'));
    expect(qcProvider, contains('XFile file'));
    expect(qcProvider, isNot(contains("import 'dart:io';")));
  });
}
