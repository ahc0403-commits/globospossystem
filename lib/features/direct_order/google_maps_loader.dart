import 'google_maps_loader_stub.dart'
    if (dart.library.js_interop) 'google_maps_loader_web.dart'
    as platform;

Future<bool> loadDirectOrderGoogleMaps(String apiKey) =>
    platform.loadDirectOrderGoogleMaps(apiKey);
