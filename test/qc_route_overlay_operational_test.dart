import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/qc_service.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/qc/qc_check_screen.dart';
import 'package:globos_pos_system/features/qc/qc_provider.dart';
import 'package:globos_pos_system/features/qc/qc_review_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _storeId = '7f6c9d22-6d84-4c7f-b923-79c81c4015d1';
const _templateId = 'qc-template-cleanliness';
const _checkId = 'qc-check-20260718';

const _template = <String, dynamic>{
  'id': _templateId,
  'category': 'Vệ sinh',
  'criteria_text': 'Khu vực phục vụ sạch và khô ráo',
  'criteria_photo_url': 'https://invalid.test/reference.jpg',
  'qsc_domain': 'cleanliness',
  'requires_photo': true,
  'required_photo_count': 1,
  'is_sv_required': true,
  'is_active': true,
};

const _check = <String, dynamic>{
  'id': _checkId,
  'template_id': _templateId,
  'check_date': '2026-07-18',
  'result': 'pass',
  'note': 'Đã kiểm tra',
  'evidence_photo_url': 'https://invalid.test/evidence.jpg',
  'submission_status': 'submitted',
  'photo_uploaded_count': 1,
  'photo_required_count': 1,
  'sv_review_status': 'pending',
  'qc_templates': _template,
};

class _AuthNotifier extends AuthNotifier {
  _AuthNotifier() : super() {
    state = const PosAuthState(
      role: 'store_admin',
      storeId: _storeId,
      primaryStoreId: _storeId,
      accessibleStores: [
        AccessibleStore(id: _storeId, name: 'GLOBOS Nguyễn Huệ'),
      ],
      extraPermissions: ['qc_check', 'qc_visit_review'],
    );
  }
}

class _TemplateNotifier extends QcTemplateNotifier {
  _TemplateNotifier() {
    state = const QcTemplateState(templates: [_template]);
  }

  @override
  Future<void> loadTemplates(String storeId) async {}
}

class _CheckNotifier extends QcCheckNotifier {
  _CheckNotifier() {
    state = const QcCheckState(checks: [_check]);
  }

  @override
  Future<void> loadWeek({
    required String storeId,
    required DateTime weekStart,
  }) async {}
}

class _QcService extends QcService {
  @override
  Future<List<Map<String, dynamic>>> fetchCheckPhotos({
    required String checkId,
    String? fallbackPhotoUrl,
  }) async => [
    {
      'id': 'qc-photo-1',
      'check_id': checkId,
      'photo_url': 'https://invalid.test/gallery.jpg',
      'is_primary': true,
    },
  ];
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://localhost:54321',
      anonKey: 'test-anon-key',
    );
  });

  testWidgets('QC check executes network and picked-image dialogs', (
    tester,
  ) async {
    await _pumpRoute(
      tester,
      initialLocation: '/qc',
      qcBuilder: () => QcCheckScreen(
        pickEvidencePhotoOverride: () async => XFile.fromData(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z1ZcAAAAASUVORK5CYII=',
          ),
          mimeType: 'image/png',
          name: 'qc-proof.png',
        ),
      ),
    );

    await _openAndDismiss(
      tester,
      const Key('qc_check_reference_photo_$_templateId'),
      const Key('qc_check_network_image_dialog'),
    );

    final attach = find.byKey(const Key('qc_check_attach_photo_$_templateId'));
    await tester.ensureVisible(attach);
    await tester.tap(attach);
    await tester.pumpAndSettle();
    final pickedPhoto = find.byKey(
      const Key('qc_check_picked_photo_${_templateId}_0'),
    );
    await tester.ensureVisible(pickedPhoto);
    await tester.tapAt(
      tester.getBottomLeft(pickedPhoto) + const Offset(10, -8),
    );
    await tester.pumpAndSettle();
    final pickedDialog = find.byKey(const Key('qc_check_picked_image_dialog'));
    expect(pickedDialog, findsOneWidget);
    Navigator.of(tester.element(pickedDialog)).pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('QC review executes review sheet and photo gallery', (
    tester,
  ) async {
    await _pumpRoute(
      tester,
      initialLocation: '/qc-review',
      qcBuilder: () => const QcCheckScreen(),
      reviewBuilder: () => QcReviewScreen(qcServiceOverride: _QcService()),
    );

    await _openAndDismiss(
      tester,
      const Key('qc_review_approve_$_checkId'),
      const Key('qc_review_sheet'),
    );
    await _openAndDismiss(
      tester,
      const Key('qc_review_photo_$_checkId'),
      const Key('qc_review_photo_gallery_dialog'),
    );
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpRoute(
  WidgetTester tester, {
  required String initialLocation,
  required Widget Function() qcBuilder,
  Widget Function()? reviewBuilder,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1024, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(path: '/qc', builder: (_, __) => qcBuilder()),
      GoRoute(
        path: '/qc-review',
        builder: (_, __) => reviewBuilder?.call() ?? const QcReviewScreen(),
      ),
      GoRoute(
        path: '/admin',
        builder: (_, __) => const Scaffold(body: SizedBox.shrink()),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _AuthNotifier()),
        qcTemplateProvider.overrideWith((ref) => _TemplateNotifier()),
        qcCheckProvider.overrideWith((ref) => _CheckNotifier()),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(),
        locale: const Locale('vi'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openAndDismiss(
  WidgetTester tester,
  Key actionKey,
  Key overlayKey,
) async {
  final action = find.byKey(actionKey);
  await tester.ensureVisible(action);
  await tester.tap(action);
  await tester.pumpAndSettle();
  final overlay = find.byKey(overlayKey);
  expect(
    overlay,
    findsOneWidget,
    reason: '$actionKey did not open $overlayKey',
  );
  Navigator.of(tester.element(overlay)).pop();
  await tester.pumpAndSettle();
}
