import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class NetworkCapabilities {
  const NetworkCapabilities({
    required this.wiredConnected,
    required this.wirelessConnected,
  });

  final bool wiredConnected;
  final bool wirelessConnected;

  bool get hasNetwork => wiredConnected || wirelessConnected;
}

abstract class NetworkCapabilityService {
  Future<NetworkCapabilities> loadCapabilities();
}

class NativeNetworkCapabilityService implements NetworkCapabilityService {
  const NativeNetworkCapabilityService();

  static const _channel = MethodChannel('globos/network_capabilities');

  @override
  Future<NetworkCapabilities> loadCapabilities() async {
    if (!Platform.isWindows) {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      return NetworkCapabilities(
        wiredConnected: interfaces.isNotEmpty,
        wirelessConnected: false,
      );
    }

    final result = await _channel.invokeMapMethod<String, dynamic>(
      'getNetworkCapabilities',
    );
    if (result == null) {
      throw PlatformException(code: 'NETWORK_CAPABILITIES_UNAVAILABLE');
    }
    return NetworkCapabilities(
      wiredConnected: result['wiredConnected'] == true,
      wirelessConnected: result['wirelessConnected'] == true,
    );
  }
}

final networkCapabilitiesProvider = FutureProvider<NetworkCapabilities>(
  (_) => const NativeNetworkCapabilityService().loadCapabilities(),
);
