import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('auth state carries the first-login privacy consent gate', () {
    const pending = PosAuthState(
      privacyConsentRequired: true,
      isPrivacyConsentSubmitting: true,
    );

    final accepted = pending.copyWith(
      privacyConsentRequired: false,
      isPrivacyConsentSubmitting: false,
    );

    expect(accepted.privacyConsentRequired, isFalse);
    expect(accepted.isPrivacyConsentSubmitting, isFalse);

    final cleared = pending.copyWith(clearUser: true);
    expect(cleared.privacyConsentRequired, isFalse);
    expect(cleared.isPrivacyConsentSubmitting, isFalse);
  });

  test(
    'database migration stores verifiable Vietnamese-law consent evidence',
    () {
      final sql = readRepoFile(
        'supabase/migrations/20260519000000_first_login_privacy_consent.sql',
      );

      expect(
        sql,
        contains('CREATE TABLE IF NOT EXISTS public.user_privacy_consents'),
      );
      expect(sql, contains('UNIQUE (auth_id, document_version)'));
      expect(sql, contains('consented_at timestamptz NOT NULL DEFAULT now()'));
      expect(sql, contains('consent_locale text NOT NULL'));
      expect(sql, contains('consent_text_hash text NOT NULL'));
      expect(sql, contains('data_categories text[] NOT NULL'));
      expect(sql, contains('processing_purposes text[] NOT NULL'));
      expect(sql, contains('processor_categories text[] NOT NULL'));
      expect(sql, contains('withdrawal_notice_acknowledged boolean NOT NULL'));
      expect(sql, contains('cross_border_acknowledged boolean NOT NULL'));
      expect(
        sql,
        contains(
          'ALTER TABLE public.user_privacy_consents ENABLE ROW LEVEL SECURITY',
        ),
      );
      expect(sql, contains('auth_id = auth.uid()'));
      expect(sql, contains('has_accepted_current_privacy_consent'));
      expect(sql, contains('accept_my_privacy_consent'));
      expect(sql, contains('vn-pdpl-2026-01'));
      expect(sql, contains('accept_privacy_consent'));
      expect(
        sql,
        contains(
          'GRANT EXECUTE ON FUNCTION public.accept_my_privacy_consent(text)',
        ),
      );

      final hardeningSql = readRepoFile(
        'supabase/migrations/20260519001000_harden_privacy_consent_rpc.sql',
      );
      expect(hardeningSql, contains('CREATE OR REPLACE FUNCTION'));
      expect(hardeningSql, contains('EXCEPTION WHEN OTHERS THEN'));
      expect(hardeningSql, contains('privacy consent audit log skipped'));
    },
  );

  test(
    'authenticated routes are blocked until privacy consent is accepted',
    () {
      final router = readRepoFile('lib/core/router/app_router.dart');
      final login = readRepoFile('lib/features/auth/login_screen.dart');
      final provider = readRepoFile('lib/features/auth/auth_provider.dart');

      expect(router, contains("path: '/privacy-consent'"));
      expect(router, contains('PrivacyConsentScreen'));
      expect(router, contains('auth.privacyConsentRequired'));
      expect(router, contains("'/privacy-consent'"));
      expect(login, contains('!next.privacyConsentRequired'));
      expect(provider, contains('has_accepted_current_privacy_consent'));
      expect(provider, contains('accept_my_privacy_consent'));
      expect(provider, contains('authErrorPrivacyConsentFailed'));
      expect(provider, contains('authErrorPrivacyConsentSetupMissing'));
      expect(provider, contains('authErrorPrivacyConsentProfileMissing'));
      expect(provider, contains('authErrorPrivacyConsentPermissionDenied'));
      expect(provider, contains('authErrorPrivacyConsentFailedPrefix'));
    },
  );

  test(
    'consent screen captures explicit affirmative action before continuing',
    () {
      final screen = readRepoFile(
        'lib/features/auth/privacy_consent_screen.dart',
      );

      expect(screen, contains("Key('privacy_consent_checkbox')"));
      expect(screen, contains("Key('privacy_consent_accept_button')"));
      expect(screen, contains('privacyConsentAgreeCheckbox'));
      expect(screen, contains('privacyConsentPledgeBody'));
      expect(screen, contains('privacyConsentCrossBorderBody'));
      expect(screen, contains('privacyConsentSetupMissing'));
      expect(screen, contains('privacyConsentSubmitFailedWithDetail'));
      expect(screen, contains('acceptPrivacyConsent'));
      expect(screen, contains('logout()'));
    },
  );

  test('full smoke accepts first-login consent before landing capture', () {
    final smoke = readRepoFile(
      'integration_test/full_multi_account_smoke_test.dart',
    );

    expect(smoke, contains('_acceptPrivacyConsentIfPresent'));
    expect(smoke, contains('await _acceptPrivacyConsentIfPresent(tester);'));
    expect(smoke, contains('UiKeys.privacyConsentCheckbox'));
    expect(smoke, contains('UiKeys.privacyConsentAcceptButton'));
    expect(
      smoke,
      contains("privacyConsentCheckbox = 'privacy_consent_checkbox'"),
    );
    expect(
      smoke,
      contains("privacyConsentAcceptButton = 'privacy_consent_accept_button'"),
    );
  });
}
