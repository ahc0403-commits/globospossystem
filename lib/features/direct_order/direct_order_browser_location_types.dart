enum DirectOrderLocationFailure {
  unsupported,
  permissionDenied,
  timeout,
  unavailable,
}

class DirectOrderBrowserLocationResult {
  const DirectOrderBrowserLocationResult._({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.failure,
  });

  const DirectOrderBrowserLocationResult.success({
    required double latitude,
    required double longitude,
    required double accuracyMeters,
  }) : this._(
         latitude: latitude,
         longitude: longitude,
         accuracyMeters: accuracyMeters,
         failure: null,
       );

  const DirectOrderBrowserLocationResult.failure(
    DirectOrderLocationFailure failure,
  ) : this._(
        latitude: null,
        longitude: null,
        accuracyMeters: null,
        failure: failure,
      );

  final double? latitude;
  final double? longitude;
  final double? accuracyMeters;
  final DirectOrderLocationFailure? failure;

  bool get isSuccess =>
      failure == null && latitude != null && longitude != null;
}

abstract interface class DirectOrderBrowserLocationAdapter {
  Future<DirectOrderBrowserLocationResult> currentPosition({
    Duration timeout = const Duration(seconds: 10),
  });
}
