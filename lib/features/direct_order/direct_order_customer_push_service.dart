import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/services/emergency_web_bridge.dart';
import '../../core/services/sepay_push_notification_service.dart';
import 'direct_order_models.dart';
import 'direct_order_service.dart';
import 'direct_order_push_environment_stub.dart'
    if (dart.library.js_interop) 'direct_order_push_environment_web.dart';

enum DirectOrderPushReadiness {
  off,
  ready,
  unsupported,
  notConfigured,
  denied,
  error,
}

class DirectOrderCustomerPushService {
  StreamSubscription<String>? _tokenRefresh;
  StreamSubscription<RemoteMessage>? _foreground;
  bool _disposed = false;
  int _revision = 0;

  Future<String> _deviceId(String slug) async {
    final preferences = await SharedPreferences.getInstance();
    final key = 'direct_order_push_device_$slug';
    final stored = preferences.getString(key);
    if (stored != null) return stored;
    final id = const Uuid().v4();
    if (!await preferences.setString(key, id)) {
      throw StateError('PUSH_CACHE_FAILED');
    }
    return id;
  }

  Future<DirectOrderPushReadiness> enable({
    required String slug,
    required DirectOrderSession session,
    required DirectOrderService service,
    required String locale,
    bool restore = false,
    void Function(String requestId, String kind)? onForeground,
  }) async {
    final revision = ++_revision;
    final preferences = await SharedPreferences.getInstance();
    if (restore &&
        preferences.getBool('direct_order_push_enabled_$slug') != true) {
      return DirectOrderPushReadiness.off;
    }
    if (!kIsWeb || !customerPushEnvironmentSupported) {
      return DirectOrderPushReadiness.unsupported;
    }
    const vapid = String.fromEnvironment('FIREBASE_WEB_VAPID_KEY');
    final options = SePayFirebaseConfiguration.current;
    if (options == null || vapid.isEmpty) {
      return DirectOrderPushReadiness.notConfigured;
    }
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp(options: options);
      final messaging = FirebaseMessaging.instance;
      if (!await messaging.isSupported()) {
        return DirectOrderPushReadiness.unsupported;
      }
      final settings = restore
          ? await messaging.getNotificationSettings()
          : await messaging.requestPermission(
              alert: true,
              badge: true,
              sound: true,
            );
      if (settings.authorizationStatus != AuthorizationStatus.authorized &&
          settings.authorizationStatus != AuthorizationStatus.provisional) {
        return DirectOrderPushReadiness.denied;
      }
      final configured = await EmergencyWebBridge.configurePushWorker(
        jsonEncode({
          'apiKey': options.apiKey,
          'appId': options.appId,
          'messagingSenderId': options.messagingSenderId,
          'projectId': options.projectId,
        }),
      );
      if (!configured) return DirectOrderPushReadiness.error;
      final token = await messaging.getToken(vapidKey: vapid);
      if (token == null || _disposed || revision != _revision) {
        return DirectOrderPushReadiness.error;
      }
      final deviceId = await _deviceId(slug);
      Future<void> register(String token) => service.setPushSubscription(
        session: session,
        deviceId: deviceId,
        token: token,
        locale: locale,
        enabled: true,
      );
      await register(token);
      if (_disposed || revision != _revision) {
        return DirectOrderPushReadiness.error;
      }
      await preferences.setBool('direct_order_push_enabled_$slug', true);
      await _tokenRefresh?.cancel();
      _tokenRefresh = messaging.onTokenRefresh.listen((token) async {
        if (_disposed || revision != _revision) return;
        try {
          await register(token);
        } catch (_) {
          /* Retry on next page resume. */
        }
      });
      await _foreground?.cancel();
      _foreground = FirebaseMessaging.onMessage.listen((message) {
        if (_disposed ||
            revision != _revision ||
            message.data['type'] != 'direct_order_customer') {
          return;
        }
        final requestId = message.data['request_id'];
        final kind = message.data['event_kind'];
        if (requestId != null &&
            const {
              'pickup_ready',
              'driver_handoff',
              'payment_request',
              'cooking_complete',
              'packing_complete',
            }.contains(kind)) {
          onForeground?.call(requestId, kind!);
        }
      });
      return DirectOrderPushReadiness.ready;
    } catch (_) {
      return DirectOrderPushReadiness.error;
    }
  }

  Future<DirectOrderPushReadiness> disable({
    required String slug,
    required DirectOrderSession session,
    required DirectOrderService service,
    required String locale,
  }) async {
    try {
      await service.setPushSubscription(
        session: session,
        deviceId: await _deviceId(slug),
        locale: locale,
        enabled: false,
      );
      ++_revision;
      await _tokenRefresh?.cancel();
      _tokenRefresh = null;
      await _foreground?.cancel();
      _foreground = null;
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool('direct_order_push_enabled_$slug', false);
      // Keep the shared FCM token: other stores and staff alerts may use it.
      return DirectOrderPushReadiness.off;
    } catch (_) {
      return DirectOrderPushReadiness.error;
    }
  }

  void dispose() {
    _disposed = true;
    ++_revision;
    unawaited(_tokenRefresh?.cancel());
    unawaited(_foreground?.cancel());
  }
}
