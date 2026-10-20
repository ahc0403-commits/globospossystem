import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late String authProviderContent;

  setUpAll(() {
    authProviderContent = File(
      'lib/features/auth/auth_provider.dart',
    ).readAsStringSync();
  });

  group('logout state reset', () {
    test('logout method calls onLogout callback', () {
      expect(
        authProviderContent,
        contains('onLogout?.call()'),
        reason: 'logout() must invoke onLogout callback to reset providers',
      );
    });

    test('AuthNotifier accepts onLogout callback', () {
      expect(
        authProviderContent,
        contains('this.onLogout'),
        reason: 'AuthNotifier constructor must accept onLogout',
      );
    });

    const sessionProviders = [
      'orderProvider',
      'paymentProvider',
      'kitchenProvider',
      'waiterTableProvider',
      'staffProvider',
      'attendanceProvider',
      'settingsProvider',
      'recipeProvider',
      'ingredientProvider',
      'qcCheckProvider',
      'qcTemplateProvider',
      'photoOpsProvider',
    ];

    for (final provider in sessionProviders) {
      test('invalidates $provider on logout', () {
        expect(
          authProviderContent,
          contains('ref.invalidate($provider)'),
          reason: '$provider must be invalidated on logout',
        );
      });
    }
  });
}
