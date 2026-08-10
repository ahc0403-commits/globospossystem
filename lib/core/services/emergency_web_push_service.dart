import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../../main.dart';
import 'emergency_web_bridge.dart';
import 'sepay_push_notification_service.dart';

enum EmergencyPushReadiness {
  unsupported,
  notConfigured,
  permissionDenied,
  ready,
  error,
}

class EmergencyWebPushService {
  EmergencyWebPushService._();

  static final instance = EmergencyWebPushService._();

  final ValueNotifier<EmergencyPushReadiness> readiness = ValueNotifier(
    EmergencyPushReadiness.unsupported,
  );
  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _foregroundSubscription;
  final StreamController<String> _eventController =
      StreamController<String>.broadcast();

  Stream<String> get foregroundEventIds => _eventController.stream;

  Future<bool> enable({required String storeId}) async {
    if (!kIsWeb) {
      readiness.value = EmergencyPushReadiness.unsupported;
      return false;
    }
    const vapidKey = String.fromEnvironment('FIREBASE_WEB_VAPID_KEY');
    final options = SePayFirebaseConfiguration.current;
    if (options == null || vapidKey.isEmpty) {
      readiness.value = EmergencyPushReadiness.notConfigured;
      return false;
    }

    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: options);
      }
      await EmergencyWebBridge.configurePushWorker(
        jsonEncode({
          'apiKey': options.apiKey,
          'appId': options.appId,
          'messagingSenderId': options.messagingSenderId,
          'projectId': options.projectId,
        }),
      );
      final permission = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (permission.authorizationStatus == AuthorizationStatus.denied) {
        readiness.value = EmergencyPushReadiness.permissionDenied;
        return false;
      }

      final token = await FirebaseMessaging.instance.getToken(
        vapidKey: vapidKey,
      );
      if (token == null || token.length < 16) {
        readiness.value = EmergencyPushReadiness.error;
        return false;
      }
      await _register(storeId, token);
      _tokenRefreshSubscription ??= FirebaseMessaging.instance.onTokenRefresh
          .listen((newToken) => unawaited(_register(storeId, newToken)));
      _foregroundSubscription ??= FirebaseMessaging.onMessage.listen((message) {
        if (message.data['type'] != 'emergency_fulfillment') return;
        final eventId = message.data['event_id']?.trim() ?? '';
        if (eventId.isNotEmpty) _eventController.add(eventId);
      });
      readiness.value = EmergencyPushReadiness.ready;
      return true;
    } catch (_) {
      readiness.value = EmergencyPushReadiness.error;
      return false;
    }
  }

  Future<void> _register(String storeId, String token) async {
    if (token.length < 16) return;
    await supabase.rpc(
      'register_emergency_web_push_device',
      params: {'p_token': token, 'p_browser_label': 'Flutter Web · $storeId'},
    );
    readiness.value = EmergencyPushReadiness.ready;
  }
}
