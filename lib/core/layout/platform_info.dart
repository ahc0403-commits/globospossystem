import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';

/// RULES.md: 플랫폼 분기 코드는 core/에서만 허용. feature 레이어 직접 사용 금지.
///
/// feature 레이어에서는 이 클래스만 사용할 것:
///   import '../../core/layout/platform_info.dart';
///   if (PlatformInfo.isAndroid) { ... }
class PlatformInfo {
  PlatformInfo._();

  /// Web 환경 여부
  static bool get isWeb => kIsWeb;

  /// Android 네이티브 환경 여부 (Web 제외)
  static bool get isAndroid {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  /// macOS 네이티브 환경 여부
  static bool get isMacOS {
    if (kIsWeb) return false;
    try {
      return Platform.isMacOS;
    } catch (_) {
      return false;
    }
  }

  /// Web 또는 데스크탑 (admin/super_admin 대상 플랫폼)
  static bool get isWebOrDesktop {
    if (kIsWeb) return true;
    try {
      return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
    } catch (_) {
      return false;
    }
  }

  /// 프린터 하드웨어 지원 여부 (Web 불가)
  static bool get isPrinterSupported => !kIsWeb;

  /// 지문 인식기 하드웨어 지원 여부 (Android만 가능)
  static bool get isFingerprintSupported => isAndroid;

  /// Kiosk 모드 지원 여부 (Android만)
  static bool get isKioskSupported => isAndroid;
}
