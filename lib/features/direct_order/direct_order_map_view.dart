import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

abstract interface class DirectOrderMapCamera {
  Future<void> moveTo(LatLng target);
  void dispose();
}

class DirectOrderMapConfiguration {
  const DirectOrderMapConfiguration({
    required this.initialPosition,
    required this.markerPosition,
    required this.semanticLabel,
    required this.onTap,
    required this.onCameraReady,
  });

  final LatLng initialPosition;
  final LatLng? markerPosition;
  final String semanticLabel;
  final ValueChanged<LatLng> onTap;
  final ValueChanged<DirectOrderMapCamera> onCameraReady;
}

typedef DirectOrderMapBuilder =
    Widget Function(
      BuildContext context,
      DirectOrderMapConfiguration configuration,
    );

class _GoogleDirectOrderMapCamera implements DirectOrderMapCamera {
  const _GoogleDirectOrderMapCamera(this.controller);

  final GoogleMapController controller;

  @override
  Future<void> moveTo(LatLng target) => controller.animateCamera(
    CameraUpdate.newCameraPosition(CameraPosition(target: target, zoom: 16)),
  );

  @override
  void dispose() => controller.dispose();
}

Widget buildDirectOrderGoogleMap(
  BuildContext context,
  DirectOrderMapConfiguration configuration,
) => Semantics(
  label: configuration.semanticLabel,
  child: GoogleMap(
    key: const Key('direct_delivery_google_map'),
    initialCameraPosition: CameraPosition(
      target: configuration.initialPosition,
      zoom: 16,
    ),
    onMapCreated: (controller) =>
        configuration.onCameraReady(_GoogleDirectOrderMapCamera(controller)),
    onTap: configuration.onTap,
    markers: configuration.markerPosition == null
        ? const {}
        : {
            Marker(
              markerId: const MarkerId('delivery'),
              position: configuration.markerPosition!,
            ),
          },
    myLocationButtonEnabled: false,
    zoomControlsEnabled: true,
    mapToolbarEnabled: false,
  ),
);
