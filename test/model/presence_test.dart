import 'package:checks/checks.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zulip/api/model/model.dart';
import 'package:zulip/api/route/users.dart';
import 'package:zulip/model/store.dart';

import '../api/fake_api.dart';
import '../example_data.dart' as eg;
import '../stdlib_checks.dart';
import 'binding.dart';

void main() {
  TestZulipBinding.ensureInitialized();

  group('poll', () {
    const pingInterval = Duration(seconds: 60);

    late PerAccountStore store;
    late FakeApiConnection connection;

    void prepare(WidgetTester tester) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      store = eg.store(initialSnapshot: eg.initialSnapshot(
        serverPresencePingIntervalSeconds: pingInterval.inSeconds));
      connection = store.connection as FakeApiConnection;
    }

    /// Dispose the store, and let the poll loop's pending timer finish.
    Future<void> finish(WidgetTester tester) async {
      store.dispose();
      await tester.pump(pingInterval);
    }

    void prepareResponse(int userId, int timestamp) {
      connection.prepare(json: UpdatePresenceResult(
        presenceLastUpdateId: null,
        serverTimestamp: null,
        presences: {
          userId: PerUserPresence(
            activeTimestamp: timestamp, idleTimestamp: timestamp),
        },
      ).toJson());
    }

    void checkPingRequest({required bool pingOnly}) {
      check(connection.takeRequests()).single.isA<http.Request>()
        ..method.equals('POST')
        ..url.path.equals('/api/v1/users/me/presence')
        ..bodyFields['ping_only'].equals(pingOnly.toString());
    }

    testWidgets('first ping after interval', (tester) async {
      prepare(tester);
      store.presence.start();
      await tester.pump(pingInterval - const Duration(seconds: 1));
      check(connection.takeRequests()).isEmpty();

      prepareResponse(eg.otherUser.userId, 1000);
      await tester.pump(const Duration(seconds: 1));
      checkPingRequest(pingOnly: false);
      check(store.presence.userLastActive(eg.otherUser.userId)).equals(1000);

      await finish(tester);
    });

    testWidgets('first ping immediately with pingImmediately', (tester) async {
      prepare(tester);
      prepareResponse(eg.otherUser.userId, 1000);
      store.presence.start(pingImmediately: true);
      await tester.pump();
      checkPingRequest(pingOnly: false);
      await tester.pump(Duration.zero);
      check(store.presence.userLastActive(eg.otherUser.userId)).equals(1000);

      prepareResponse(eg.otherUser.userId, 1060);
      await tester.pump(pingInterval);
      checkPingRequest(pingOnly: false);
      check(store.presence.userLastActive(eg.otherUser.userId)).equals(1060);

      await finish(tester);
    });

    testWidgets('keep polling after a failed ping', (tester) async {
      prepare(tester);
      connection.prepare(httpException: Exception('failed'));
      store.presence.start(pingImmediately: true);
      await tester.pump();
      checkPingRequest(pingOnly: false);
      await tester.pump(Duration.zero);
      check(store.presence.userLastActive(eg.otherUser.userId)).isNull();

      prepareResponse(eg.otherUser.userId, 1060);
      await tester.pump(pingInterval);
      checkPingRequest(pingOnly: false);
      check(store.presence.userLastActive(eg.otherUser.userId)).equals(1060);

      await finish(tester);
    });

    testWidgets('no uncaught error from failed ping on lifecycle change', (tester) async {
      prepare(tester);
      store.presence.start();
      connection.prepare(httpException: Exception('failed'));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      checkPingRequest(pingOnly: true);
      await tester.pump(Duration.zero);

      await finish(tester);
    });
  });
}
