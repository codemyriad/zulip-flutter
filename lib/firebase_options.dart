import 'package:firebase_core/firebase_core.dart';

/// Configuration used for receiving notifications on Android.
///
/// This set of options is used for receiving notifications
/// through the Zulip notification bouncer service:
///   https://zulip.readthedocs.io/en/latest/production/mobile-push-notifications.html
///
/// These values represent public identifiers for that service
/// as an application registered with the relevant Google service:
/// we deliver Android notifications through Firebase Cloud Messaging (FCM).
/// The values are derived from a `google-services.json` file.
/// For details, see:
///   https://developers.google.com/android/guides/google-services-plugin#processing_the_json_file
const kFirebaseOptionsAndroid = FirebaseOptions(
  appId: '1:${_ZulipFirebaseOptions.projectNumber}:android:6311caf81ef205da77cd88',
  messagingSenderId: _ZulipFirebaseOptions.projectNumber,
  projectId: _ZulipFirebaseOptions.projectId,
  apiKey: _ZulipFirebaseOptions.androidApiKey,
);

/// Configuration used for finding the notification token on iOS.
///
/// On iOS, we don't use Firebase to actually deliver notifications;
/// rather the server communicates with the Apple Push Notification service
/// (APNs) directly.
///
/// But we do use the Firebase library as a convenient binding to the
/// platform API for the setup steps of requesting the user's permission
/// to show notifications, and getting the token that the service uses
/// to represent that permission.
/// These values are similar to [kFirebaseOptionsAndroid] but are for iOS,
/// and they let us initialize the Firebase library so that we can do that.
///
/// TODO: Cut out Firebase for APNs and use a thinner platform-API binding.
const kFirebaseOptionsIos = FirebaseOptions(
  appId: '1:${_ZulipFirebaseOptions.projectNumber}:ios:3bf169acddd993f677cd88',
  messagingSenderId: _ZulipFirebaseOptions.projectNumber,
  projectId: _ZulipFirebaseOptions.projectId,
  apiKey: _ZulipFirebaseOptions.iosApiKey,
);

abstract class _ZulipFirebaseOptions {
  static const projectNumber = '872478906649';

  // Despite its value, this name applies across Android and iOS.
  static const projectId = 'codemyriad-chat';

  // Despite the name, this Google Cloud "API key" is a very different kind
  // of thing from a Zulip "API key".  In particular, it's designed to be
  // included in published builds of client applications, and therefore
  // fundamentally public.  See docs:
  //   https://cloud.google.com/docs/authentication/api-keys
  static const androidApiKey = 'AIzaSyDriYiWg8MJpgmDLo2vPAgZTkBSDeTgBhA';
  static const iosApiKey = 'AIzaSyD-sVKnzWWjShM2qh9Kk59TR_RhygPvVtk';
}
