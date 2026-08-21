import 'direct_order_browser_location_types.dart';

class PlatformDirectOrderBrowserLocationAdapter
    implements DirectOrderBrowserLocationAdapter {
  const PlatformDirectOrderBrowserLocationAdapter();

  @override
  Future<DirectOrderBrowserLocationResult> currentPosition({
    Duration timeout = const Duration(seconds: 10),
  }) async => const DirectOrderBrowserLocationResult.failure(
    DirectOrderLocationFailure.unsupported,
  );
}
