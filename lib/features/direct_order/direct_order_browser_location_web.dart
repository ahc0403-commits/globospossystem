import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'direct_order_browser_location_types.dart';

class PlatformDirectOrderBrowserLocationAdapter
    implements DirectOrderBrowserLocationAdapter {
  const PlatformDirectOrderBrowserLocationAdapter();

  @override
  Future<DirectOrderBrowserLocationResult> currentPosition({
    Duration timeout = const Duration(seconds: 10),
  }) {
    final completer = Completer<DirectOrderBrowserLocationResult>();
    void complete(DirectOrderBrowserLocationResult result) {
      if (!completer.isCompleted) completer.complete(result);
    }

    try {
      web.window.navigator.geolocation.getCurrentPosition(
        ((web.GeolocationPosition position) {
          final coordinates = position.coords;
          final latitude = coordinates.latitude;
          final longitude = coordinates.longitude;
          if (!latitude.isFinite ||
              latitude < -90 ||
              latitude > 90 ||
              !longitude.isFinite ||
              longitude < -180 ||
              longitude > 180) {
            complete(
              const DirectOrderBrowserLocationResult.failure(
                DirectOrderLocationFailure.unavailable,
              ),
            );
            return;
          }
          complete(
            DirectOrderBrowserLocationResult.success(
              latitude: latitude,
              longitude: longitude,
              accuracyMeters: coordinates.accuracy,
            ),
          );
        }).toJS,
        ((web.GeolocationPositionError error) {
          final failure = switch (error.code) {
            web.GeolocationPositionError.PERMISSION_DENIED =>
              DirectOrderLocationFailure.permissionDenied,
            web.GeolocationPositionError.TIMEOUT =>
              DirectOrderLocationFailure.timeout,
            _ => DirectOrderLocationFailure.unavailable,
          };
          complete(DirectOrderBrowserLocationResult.failure(failure));
        }).toJS,
        web.PositionOptions(
          enableHighAccuracy: true,
          timeout: timeout.inMilliseconds,
          maximumAge: 0,
        ),
      );
    } catch (_) {
      complete(
        const DirectOrderBrowserLocationResult.failure(
          DirectOrderLocationFailure.unsupported,
        ),
      );
    }

    return completer.future.timeout(
      timeout + const Duration(seconds: 1),
      onTimeout: () => const DirectOrderBrowserLocationResult.failure(
        DirectOrderLocationFailure.timeout,
      ),
    );
  }
}
