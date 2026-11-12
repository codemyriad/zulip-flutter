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
