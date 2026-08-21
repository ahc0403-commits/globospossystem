import 'direct_order_browser_location_stub.dart'
    if (dart.library.js_interop) 'direct_order_browser_location_web.dart'
    as platform;
import 'direct_order_browser_location_types.dart';

export 'direct_order_browser_location_types.dart';

final DirectOrderBrowserLocationAdapter directOrderBrowserLocationAdapter =
    platform.PlatformDirectOrderBrowserLocationAdapter();
