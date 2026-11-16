import 'package:flutter/foundation.dart';

/// The name this build of the app shows for itself.
const kAppName = 'CodeMyriad Chat';

/// The Zulip server this build of the app is hardcoded to connect to.
///
/// The add-account flow skips asking the user for a server URL,
/// and goes straight to logging in to this server.
const kFixedRealmUrl = 'https://chat.codemyriad.io';

/// The Zulip server the add-account flow logs in to,
/// or null if the user should enter a server URL.
///
/// This is [kFixedRealmUrl],
/// unless a test has set [debugFixedRealmUrlEnabled] to false.
Uri? get fixedRealmUrl {
  bool enabled = true;
  assert(() {
    enabled = debugFixedRealmUrlEnabled;
    return true;
  }());
  return enabled ? Uri.parse(kFixedRealmUrl) : null;
}

/// In debug mode, controls whether [fixedRealmUrl] is used.
///
/// The test binding sets this to false,
/// so that tests get the usual flow where the user enters a server URL;
/// tests of the fixed-server flow set it to true.
/// Outside of debug mode, this has no effect.
@visibleForTesting
bool debugFixedRealmUrlEnabled = true;

/// Whether push notifications are sent directly from the Zulip server to
/// APNs and FCM rather than through Zulip's push notification bouncer.
///
/// When true, the client registers tokens directly via `/users/me/apns_device_token`
/// and `/users/me/android_gcm_reg_id` and accepts direct FCM payloads even on
/// servers at feature level 468+.
bool get useDirectPushNotifications {
  bool enabled = true;
  assert(() {
    enabled = debugDirectPushNotificationsEnabled;
    return true;
  }());
  return enabled;
}

/// In debug mode, controls whether [useDirectPushNotifications] is active.
///
/// The test binding sets this to false so existing bouncer/E2EE push tests run
/// unchanged; tests of direct push set it to true.
/// Outside of debug mode, this has no effect.
@visibleForTesting
bool debugDirectPushNotificationsEnabled = true;
