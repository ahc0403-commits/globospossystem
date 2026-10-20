# Pinned GoTrue 2.19.0

Source: https://pub.dev/packages/gotrue/versions/2.19.0
Upstream: https://github.com/supabase/supabase-flutter/tree/main/packages/gotrue
MIT license retained in LICENSE. All lib files are copied verbatim except:

- `GotrueAsyncStorage.authBroadcastChannelKey`: optional nullable getter.
- `GoTrueClient._mayStartBroadcastChannel`: uses that namespace when supplied.

The public Supabase options do not expose a browser auth channel namespace.
POS supplies one alongside terminal-specific persistence and PKCE storage.
Unscoped clients retain the original SDK behavior. No server, token refresh,
JWT, logout scope, or authentication permission behavior is changed.

When upgrading the SDK, rebase these two changes and run
`flutter test --platform chrome test/terminal_auth_browser_test.dart` plus
`flutter test test/terminal_auth_storage_test.dart test/auth_initialization_test.dart`.
