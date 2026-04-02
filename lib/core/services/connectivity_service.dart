import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<bool> _checkConnectivity() async {
  try {
    final result = await InternetAddress.lookup('supabase.co');
    return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
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
