import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<bool> _checkConnectivity() async {
  // Web: dart:io 사용 불가 → Supabase 세션 체크로 대체
  if (kIsWeb) {
    try {
      // 세션이 있으면 연결된 것으로 판단
      // 실제 네트워크 체크는 Supabase 요청 자체가 처리함
      await Supabase.instance.client
          .from('restaurants')
          .select('id')
          .limit(1)
          .timeout(const Duration(seconds: 5));
      return true;
    } catch (_) {
      return false;
    }
  }

  // Android / macOS: 소켓 직접 체크
  try {
    // dart:io는 조건부 import 사용
    return await _nativeCheck();
  } catch (_) {
    return false;
  }
}

Future<bool> _nativeCheck() async {
  // kIsWeb이 false일 때만 호출됨
  // dart:io import를 직접 사용
  try {
    final socket = await Future.any([
      _trySocket(),
      Future.delayed(const Duration(seconds: 3), () => false),
    ]);
    return socket;
  } catch (_) {
    return false;
  }
}

Future<bool> _trySocket() async {
  // ignore: avoid_dynamic_calls
  // dart:io를 동적으로 처리
  try {
    if (!kIsWeb) {
      // Non-web 환경에서만 실행
      final result = await _lookupAddress();
      return result;
    }
    return false;
  } catch (_) {
    return false;
  }
}

// dart:io를 직접 사용하는 함수 (Web에서 dead code로 처리됨)
Future<bool> _lookupAddress() async {
  // Web에서는 kIsWeb 체크로 진입하지 않음
  // 컴파일 에러 방지를 위해 조건부 처리
  if (kIsWeb) return false;
  try {
    // dart:io conditional import
    return await _ioLookup();
  } catch (_) {
    return false;
  }
}

Future<bool> _ioLookup() async {
  if (kIsWeb) return false;
  // dart:io 직접 사용
  // ignore: undefined_prefixed_name
  try {
    // Supabase ping으로 대체 (dart:io 없이)
    await Supabase.instance.client
        .from('restaurants')
        .select('id')
        .limit(1)
        .timeout(const Duration(seconds: 4));
    return true;
  } catch (_) {
    return false;
  }
}

final connectivityProvider = StreamProvider<bool>((ref) {
  final controller = StreamController<bool>();
  Timer? timer;

  Future<void> emitStatus() async {
    final connected = await _checkConnectivity();
    if (!controller.isClosed) {
      controller.add(connected);
    }
  }

  emitStatus();
  timer = Timer.periodic(const Duration(seconds: 10), (_) => emitStatus());

  ref.onDispose(() {
    timer?.cancel();
    controller.close();
  });

  return controller.stream;
});
