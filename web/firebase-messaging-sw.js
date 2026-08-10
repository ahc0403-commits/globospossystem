/* Background emergency alerts for the installed Flutter Web application.
 * Firebase configuration is supplied by the authenticated page at runtime;
 * no environment values or credentials are committed in this worker. */
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-messaging-compat.js');

let messaging = null;
const configCacheName = 'globos-emergency-config-v1';
const configCacheKey = '/__globos_firebase_config__';

function initializeMessaging(config) {
  if (messaging || !config) return;
  if (!firebase.apps.length) firebase.initializeApp(config);
  messaging = firebase.messaging();
  messaging.onBackgroundMessage((payload) => {
    const data = payload.data || {};
    if (data.type !== 'emergency_fulfillment' || payload.notification) return;
    self.registration.showNotification(
      'Đơn hàng khẩn cấp mới',
      {
        body: 'Mở màn hình để kiểm tra đơn hàng.',
        tag: data.event_id || data.order_id || 'globos-emergency',
        renotify: true,
        data: { url: data.url || '/emergency', event_id: data.event_id },
      },
    );
  });
}

(async () => {
  try {
    const cache = await caches.open(configCacheName);
    const stored = await cache.match(configCacheKey);
    if (stored) initializeMessaging(await stored.json());
  } catch (_) {
    // Foreground Realtime and polling remain available without push config.
  }
})();

self.addEventListener('message', (event) => {
  if (event.data?.type !== 'GLOBOS_FIREBASE_CONFIG' || messaging) return;
  event.waitUntil((async () => {
    try {
      const cache = await caches.open(configCacheName);
      await cache.put(
        configCacheKey,
        new Response(JSON.stringify(event.data.config), {
          headers: { 'content-type': 'application/json' },
        }),
      );
      initializeMessaging(event.data.config);
    } catch (_) {
      // Foreground Realtime and polling remain active if web push is unavailable.
    }
  })());
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const targetUrl = event.notification.data?.url || '/emergency';
  event.waitUntil((async () => {
    const windows = await clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of windows) {
      if ('focus' in client) {
        client.navigate(targetUrl);
        return client.focus();
      }
    }
    return clients.openWindow(targetUrl);
  })());
});
