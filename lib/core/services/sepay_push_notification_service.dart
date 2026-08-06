import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:sepay_android_audio/sepay_android_audio.dart';

import '../layout/platform_info.dart';
import 'bank_transfer_alert_service.dart';
import 'bank_transfer_alert_sound.dart';

const _pushType = 'sepay_bank_transfer';
const _androidChannelId = 'sepay_bank_transfer';

enum SePayPushReadiness {
  unsupported,
  notConfigured,
  registering,
  permissionDenied,
  ready,
  error,
}

@pragma('vm:entry-point')
Future<void> sepayFirebaseBackgroundMessage(RemoteMessage message) async {
  if (message.data['type'] != _pushType) return;
  final options = SePayFirebaseConfiguration.current;
  if (options == null) return;

  final amount = int.tryParse(message.data['amount'] ?? '');
  if (amount == null || amount <= 0 || amount > 999999999) return;
  if (PlatformInfo.isAndroid) {
    await SePayPushNotificationService.showAndroidReceipt(amount);
    await _playAndroidAnnouncement(amount);
  } else if (PlatformInfo.isMacOS) {
    await bankTransferAlertSoundService.play(amount: amount);
  }
}

class SePayFirebaseConfiguration {
  SePayFirebaseConfiguration._();

  static FirebaseOptions? get current {
    const apiKey = String.fromEnvironment('FIREBASE_API_KEY');
    const appId = String.fromEnvironment('FIREBASE_APP_ID');
    const senderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
    const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
    const appleBundleId = String.fromEnvironment('FIREBASE_IOS_BUNDLE_ID');
    if ([apiKey, appId, senderId, projectId].any((value) => value.isEmpty)) {
      return null;
    }
    return FirebaseOptions(
      apiKey: apiKey,
      appId: appId,
      messagingSenderId: senderId,
      projectId: projectId,
      iosBundleId: appleBundleId.isEmpty ? null : appleBundleId,
    );
  }
}

class SePayPushNotificationService {
  SePayPushNotificationService._();

  static final instance = SePayPushNotificationService._();
  static final _notifications = FlutterLocalNotificationsPlugin();
  static Future<bool>? _initialization;
  static final readiness = ValueNotifier<SePayPushReadiness>(
    SePayPushReadiness.unsupported,
  );

  // Bank-transfer alerts are Windows-only. Firebase push registration remains
  // disabled so Android, iOS, and macOS devices cannot receive or announce one.
  static bool get isNativePushPlatform => false;

  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _foregroundMessageSubscription;
  String? _storeId;

  static Future<bool> initialize() {
    return _initialization ??= _initializeOnce();
  }

  static Future<bool> _initializeOnce() async {
    if (!isNativePushPlatform) {
      readiness.value = SePayPushReadiness.unsupported;
      return false;
    }
    final options = SePayFirebaseConfiguration.current;
    if (options == null) {
      readiness.value = SePayPushReadiness.notConfigured;
      return false;
    }

    readiness.value = SePayPushReadiness.registering;
    await Firebase.initializeApp(options: options);
    FirebaseMessaging.onBackgroundMessage(sepayFirebaseBackgroundMessage);
    await _notifications.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
        macOS: DarwinInitializationSettings(),
      ),
    );
    if (PlatformInfo.isAndroid) {
      await _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _androidChannelId,
              'Bank transfer receipts',
              description: 'Vietnamese bank transfer amount announcements',
              importance: Importance.max,
              playSound: false,
            ),
          );
    }
    if (PlatformInfo.isIOS || PlatformInfo.isMacOS) {
      await FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
            alert: true,
            badge: true,
            sound: true,
          );
    }
    return true;
  }

  Future<void> syncStore(String? storeId) async {
    _storeId = storeId;
    if (!await initialize()) return;
    if (storeId == null) {
      await _tokenRefreshSubscription?.cancel();
      _tokenRefreshSubscription = null;
      await _foregroundMessageSubscription?.cancel();
      _foregroundMessageSubscription = null;
      try {
        await FirebaseMessaging.instance.deleteToken();
      } catch (_) {
        // A missing network must not block logout or role changes.
      }
      readiness.value = SePayPushReadiness.unsupported;
      return;
    }
    readiness.value = SePayPushReadiness.registering;

    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      readiness.value = SePayPushReadiness.permissionDenied;
      return;
    }

    _tokenRefreshSubscription ??= FirebaseMessaging.instance.onTokenRefresh
        .listen((refreshedToken) async {
          final currentStoreId = _storeId;
          if (currentStoreId == null || refreshedToken.length < 16) return;
          try {
            await bankTransferAlertService.registerPushDevice(
              currentStoreId,
              refreshedToken,
            );
            readiness.value = SePayPushReadiness.ready;
          } catch (_) {
            readiness.value = SePayPushReadiness.error;
            // The next token refresh or app/store refresh retries registration.
          }
        });
    _foregroundMessageSubscription ??= FirebaseMessaging.onMessage.listen((
      message,
    ) async {
      if (message.data['type'] != _pushType) return;
      final amount = int.tryParse(message.data['amount'] ?? '');
      if (amount == null || amount <= 0 || amount > 999999999) return;
      if (PlatformInfo.isAndroid) {
        await showAndroidReceipt(amount);
      }
      if (PlatformInfo.isAndroid) {
        await _playAndroidAnnouncement(amount);
      } else if (!PlatformInfo.isIOS) {
        await bankTransferAlertSoundService.play(amount: amount);
      }
    });

    String? token;
    for (var attempt = 0; attempt < 3 && token == null; attempt += 1) {
      try {
        token = await FirebaseMessaging.instance.getToken();
      } catch (_) {
        if (attempt < 2) await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    if (token != null && token.length >= 16) {
      await bankTransferAlertService.registerPushDevice(storeId, token);
      readiness.value = SePayPushReadiness.ready;
    } else {
      readiness.value = SePayPushReadiness.error;
    }
  }

  static Future<void> showAndroidReceipt(int amount) async {
    final initialized = await initialize();
    if (!initialized || !PlatformInfo.isAndroid) return;
    await _notifications.show(
      id: amount.hashCode,
      title: 'Đã nhận chuyển khoản',
      body: vietnameseBankTransferMessage(amount),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _androidChannelId,
          'Bank transfer receipts',
          channelDescription: 'Vietnamese bank transfer amount announcements',
          importance: Importance.max,
          priority: Priority.max,
          playSound: false,
        ),
      ),
    );
  }
}

Future<void> _playAndroidAnnouncement(int amount) async {
  final started = await SePayAndroidAudio.announce(
    vietnameseBankTransferAudioTokens(amount),
  );
  if (!started) {
    await bankTransferAlertSoundService.play(amount: amount);
  }
}
