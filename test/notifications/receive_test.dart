import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:checks/checks.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:zulip/api/backoff.dart';
import 'package:zulip/api/model/initial_snapshot.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/api/notifications.dart';
import 'package:zulip/model/message.dart';
import 'package:zulip/model/message_coverage.dart';
import 'package:zulip/model/message_list.dart';
import 'package:zulip/model/narrow.dart';
import 'package:zulip/model/presence.dart';
import 'package:zulip/model/push_device.dart';
import 'package:zulip/model/settings.dart';
import 'package:zulip/model/store.dart';
import 'package:zulip/notifications/receive.dart';

import '../api/fake_api.dart';
import '../example_data.dart' as eg;
import '../fake_async.dart';
import '../model/binding.dart';
import '../model/test_store.dart';
import '../test_images.dart';
import 'android_display_test.dart'
  show encryptNotification, legacyMessageFcmMessage, notifPayloadNewMessage;

Map<String, dynamic> _snapshotToJson(InitialSnapshot snap) {
  final json = jsonDecode(jsonEncode(snap)) as Map<String, dynamic>;
  final subs = json['subscriptions'];
  if (subs is List) {
    for (final sub in subs) {
      if (sub is Map<String, dynamic> && sub['color'] is int) {
        final color = sub['color'] as int;
        sub['color'] = '#${(color & 0xffffff).toRadixString(16).padLeft(6, '0')}';
      }
    }
  }
  return json;
}

Future<RemoteMessage> _encodeFcmForStore(
  GlobalStore globalStore,
  NotifPayloadWithIdentity data,
) async {
  if (data is LegacyFcmMessageWithIdentity) {
    return RemoteMessage(data: data.toJson());
  }
  final account = globalStore.accounts.singleWhere((a) =>
    a.realmUrl.origin == data.realmUrl.origin && a.userId == data.userId);
  final pushKey = globalStore.pushKeys.perAccount(account.id).latestPushKey!;
  final encrypted = await encryptNotification(
    pushKey.pushKey,
    utf8.encode(jsonEncode(data)),
  );
  return RemoteMessage(data: {
    'push_key_id': pushKey.pushKeyId.toString(),
    'encrypted_data': base64Encode(encrypted),
  });
}

void main() {
  TestZulipBinding.ensureInitialized();

  Future<void> init() async {
    addTearDown(testBinding.reset);
    testBinding.firebaseMessagingInitialToken = '012abc';
    addTearDown(NotificationService.debugReset);
    NotificationService.debugBackgroundIsolateIsLive = false;
    await NotificationService.instance.start();
  }

  T runWithAvatarHttp<T>(T Function() body) {
    final client = http_testing.MockClient((_) async =>
      http.Response.bytes(kSolidBlueAvatar, HttpStatus.ok));
    return http.runWithClient(body, () => client);
  }

  // The calls to firebaseMessagingOnMessage and firebaseMessagingOnBackgroundMessage
  // for notification display are also tested in `android_display_test.dart`.
  // The token logic is tested end-to-end in `test/model/push_device_test.dart`.

  group('permissions', () {
    testWidgets('request permission', (tester) async {
      await init();
      check(testBinding.firebaseMessaging.takeRequestPermissionCalls())
        .length.equals(1);
    }, variant: const TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}));
  });

  group('notification message prefetching', () {
    final baseTime = DateTime.utc(2026, 11, 16, 9, 0);

    Future<UpdateMachineTestGlobalStore> createConfiguredStore({
      TestGlobalStoreBackend? backend,
      required bool messageDatabase,
      Account? account,
    }) async {
      final acct = account ?? eg.selfAccount;
      final store = UpdateMachineTestGlobalStore(
        backend: backend,
        accounts: [acct],
        boolGlobalSettings: {BoolGlobalSetting.messageDatabase: messageDatabase},
      );
      await store.pushKeys.perAccount(acct.id).insertPushKey(
        eg.pushKey(account: acct).toCompanion(false));
      return store;
    }

    void setupNotifTestEnvironment() {
      addTearDown(testBinding.reset);
      BackoffMachine.debugDuration = const Duration(seconds: 1);
      addTearDown(() => BackoffMachine.debugDuration = null);
      Presence.debugEnable = false;
      addTearDown(() => Presence.debugEnable = true);
      PushDeviceManager.debugAutoPause = true;
      addTearDown(() => PushDeviceManager.debugAutoPause = false);
      testBinding.packageInfoResult = eg.packageInfo();
      testBinding.firebaseMessagingInitialToken = '012abc';
      addTearDown(NotificationService.debugReset);
      NotificationService.debugBackgroundIsolateIsLive = false;
    }

    test('does not prefetch when BoolGlobalSetting.messageDatabase is false', () =>
      runWithAvatarHttp(() => awaitFakeAsync(initialTime: baseTime, (async) async {
        setupNotifTestEnvironment();
        final stream = eg.stream(streamId: 10, name: 'general');
        final globalStore = await createConfiguredStore(messageDatabase: false);
        testBinding.customGlobalStore = globalStore;
        globalStore.prepareRegisterQueueResponse = (conn) => conn.prepare(
          json: _snapshotToJson(eg.initialSnapshot(
            queueId: 'q1',
            lastEventId: 1,
            maxMessageId: 100,
            streams: [stream],
            subscriptions: [eg.subscription(stream)],
          )),
        );
        final store = await globalStore.perAccount(eg.selfAccount.id);
        final connection = store.connection as FakeApiConnection;
        async.elapse(Duration.zero);
        connection.takeRequests();

        await NotificationService.instance.start();
        final notifiedMsg = eg.streamMessage(
          id: 105,
          stream: stream,
          topic: 'deploy',
          content: '<p>Ship it</p>',
        );
        final fcm = await _encodeFcmForStore(
          globalStore,
          notifPayloadNewMessage(notifiedMsg, streamName: stream.name),
        );
        testBinding.firebaseMessaging.onMessage.add(fcm);
        async.flushMicrotasks();

        // Notification displayed, zero API requests made.
        check(testBinding.androidNotificationHost.takeNotifyCalls()).isNotEmpty();
        check(connection.takeRequests()).isEmpty();
        check(globalStore.backend.debugMessageDatabase).isNull();
      })));

    test('foreground notification prefetches messages without delaying display, enabling offline open', () =>
      runWithAvatarHttp(() => awaitFakeAsync(initialTime: baseTime, (async) async {
        setupNotifTestEnvironment();
        final stream = eg.stream(streamId: 10, name: 'general');
        final globalStore = await createConfiguredStore(messageDatabase: true);
        testBinding.customGlobalStore = globalStore;
        globalStore.prepareRegisterQueueResponse = (conn) => conn.prepare(
          json: _snapshotToJson(eg.initialSnapshot(
            queueId: 'q1',
            lastEventId: 1,
            maxMessageId: 100,
            streams: [stream],
            subscriptions: [eg.subscription(stream)],
          )),
        );
        final store = await globalStore.perAccount(eg.selfAccount.id);
        final connection = store.connection as FakeApiConnection;
        async.elapse(Duration.zero);
        connection.takeRequests();

        await NotificationService.instance.start();

        final m1 = eg.streamMessage(id: 101, stream: stream, topic: 'deploy', content: '<p>Context 1</p>');
        final m2 = eg.streamMessage(id: 102, stream: stream, topic: 'deploy', content: '<p>Context 2</p>');
        final m3 = eg.streamMessage(id: 105, stream: stream, topic: 'deploy', content: '<p>Ping!</p>');

        // Delay getMessages by 2 seconds to verify OS notification posts immediately.
        connection.prepare(
          delay: const Duration(seconds: 2),
          json: eg.newestGetMessagesResult(
            foundOldest: true,
            messages: [m1, m2, m3],
          ).toJson()..['anchor'] = 105,
        );

        final fcm = await _encodeFcmForStore(
          globalStore,
          notifPayloadNewMessage(m3, streamName: stream.name),
        );
        testBinding.firebaseMessaging.onMessage.add(fcm);
        async.flushMicrotasks();

        // Notification is shown immediately before the 2s getMessages response arrives.
        check(testBinding.androidNotificationHost.takeNotifyCalls()).length.equals(2);
        final req = connection.takeRequests().single as http.Request;
        check(req.url.path).equals('/api/v1/messages');
        check(req.url.queryParameters['anchor']).equals('105');
        check(req.url.queryParameters['num_before'])
          .equals(kNotificationPrefetchBefore.toString());
        check(req.url.queryParameters['num_after'])
          .equals(kNotificationPrefetchAfter.toString());

        // Let the prefetch complete and commit to SQLite.
        async.elapse(const Duration(seconds: 2));
        await globalStore.backend.messageDbWriterForAccount(eg.selfAccount.id).drainForTesting();
        async.flushMicrotasks();

        // Now go offline and open the notified conversation anchored at 105.
        connection.clearPreparedResponses();
        connection.prepare(httpException: const SocketException('offline'));
        final view = MessageListView.init(
          store: store,
          narrow: TopicNarrow(stream.streamId, TopicName('deploy')),
          anchor: const NumericAnchor(105),
        );
        unawaited(view.fetchInitial());
        async.elapse(Duration.zero);

        check(view.fetched).isTrue();
        check(view.messages.map((m) => m.id)).deepEquals([101, 102, 105]);
        view.dispose();
      })));

    test('prefetches preceding context when MessageEvent arrived first, then skips once covered', () =>
      runWithAvatarHttp(() => awaitFakeAsync(initialTime: baseTime, (async) async {
        setupNotifTestEnvironment();
        final stream = eg.stream(streamId: 10, name: 'general');
        final globalStore = await createConfiguredStore(messageDatabase: true);
        testBinding.customGlobalStore = globalStore;
        globalStore.prepareRegisterQueueResponse = (conn) => conn.prepare(
          json: _snapshotToJson(eg.initialSnapshot(
            queueId: 'q1',
            lastEventId: 1,
            maxMessageId: 100,
            streams: [stream],
            subscriptions: [eg.subscription(stream)],
          )),
        );
        final store = await globalStore.perAccount(eg.selfAccount.id);
        final connection = store.connection as FakeApiConnection;
        async.elapse(Duration.zero);
        connection.takeRequests();

        await NotificationService.instance.start();

        final mOld = eg.streamMessage(id: 90, stream: stream, topic: 'deploy', content: '<p>Earlier</p>');
        final m105 = eg.streamMessage(id: 105, stream: stream, topic: 'deploy', content: '<p>Mention</p>');

        // MessageEvent(105) arrives first on the event queue (opening only [105, ∞)).
        await store.handleEvent(eg.messageEvent(m105));
        await globalStore.backend.messageDbWriterForAccount(eg.selfAccount.id).drainForTesting();

        // Notification for 105 arrives: because preceding context (< 105) is not covered,
        // it still prefetches and learns mOld (90) + foundOldest.
        connection.prepare(
          json: eg.newestGetMessagesResult(
            foundOldest: true,
            messages: [mOld, m105],
          ).toJson()..['anchor'] = 105,
        );
        testBinding.firebaseMessaging.onMessage.add(await _encodeFcmForStore(
          globalStore,
          notifPayloadNewMessage(m105, streamName: stream.name),
        ));
        async.elapse(Duration.zero);
        await globalStore.backend.messageDbWriterForAccount(eg.selfAccount.id).drainForTesting();
        check(connection.takeRequests()).length.equals(1);
        check(store.messages.keys).contains(90);

        // Now m106 arrives via MessageEvent in the same fully-covered topic;
        // a notification for 106 needs zero network requests.
        final m106 = eg.streamMessage(id: 106, stream: stream, topic: 'deploy', content: '<p>Followup</p>');
        await store.handleEvent(eg.messageEvent(m106));
        await globalStore.backend.messageDbWriterForAccount(eg.selfAccount.id).drainForTesting();

        testBinding.firebaseMessaging.onMessage.add(await _encodeFcmForStore(
          globalStore,
          notifPayloadNewMessage(m106, streamName: stream.name),
        ));
        async.elapse(Duration.zero);
        check(connection.takeRequests()).isEmpty();
      })));

    test('background notification when store unloaded persists to DB for offline cold start', () =>
      runWithAvatarHttp(() => awaitFakeAsync(initialTime: baseTime, (async) async {
        setupNotifTestEnvironment();
        final backend = TestGlobalStoreBackend();
        addTearDown(backend.closeMessageDb);
        final stream = eg.stream(streamId: 10, name: 'general');

        // Session 1: User opens app online; snapshot + MessageDatabase epoch 1 are saved.
        final session1Global = await createConfiguredStore(
          backend: backend,
          messageDatabase: true,
        );
        final mEarly = eg.streamMessage(id: 95, stream: stream, topic: 'other', content: '<p>Other</p>');
        session1Global.prepareRegisterQueueResponse = (conn) => conn.prepare(
          json: _snapshotToJson(eg.initialSnapshot(
            queueId: 'q1',
            lastEventId: 1,
            maxMessageId: 100,
            streams: [stream],
            subscriptions: [eg.subscription(stream)],
          )),
        );
        final session1Store = await session1Global.perAccount(eg.selfAccount.id);
        async.elapse(Duration.zero);
        // Open channel:10 interval [101, ∞) in epoch 1 via an event at id 101,
        // to also verify that post-watermark background prefetch closes it on cold start!
        final m101 = eg.streamMessage(id: 101, stream: stream, topic: 'other', content: '<p>At 101</p>');
        final raw101 = jsonDecode(jsonEncode(eg.messageEvent(m101))) as Map<String, dynamic>;
        raw101['id'] = 3;
        (session1Store.connection as FakeApiConnection).prepare(
          json: {'events': [raw101], 'queue_id': 'q1'},
        );
        session1Store.updateMachine!.debugAdvanceLoop();
        async.elapse(Duration.zero);
        await backend.messageDbWriterForAccount(eg.selfAccount.id).drainForTesting();
        check(mEarly.id).equals(95);
        session1Global.dispose();

        // Session 2: App is terminated (no PerAccountStore loaded). Background FCM arrives
        // for message 150 in #general > deploy (while e.g. message 120 in #general > other
        // happened on the server without being fetched).
        final bgGlobal = await createConfiguredStore(
          backend: backend,
          messageDatabase: true,
        );
        testBinding.customGlobalStore = bgGlobal;
        check(bgGlobal.perAccountSync(eg.selfAccount.id)).isNull();

        await NotificationService.instance.start();

        final m148 = eg.streamMessage(id: 148, stream: stream, topic: 'deploy', content: '<p>Step 1</p>');
        final m149 = eg.streamMessage(id: 149, stream: stream, topic: 'deploy', content: '<p>Step 2</p>');
        final m150 = eg.streamMessage(
          id: 150,
          stream: stream,
          topic: 'deploy',
          content: '<p>UniqueOfflineToken42</p>',
        );

        final bgConn = bgGlobal.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
        bgConn.prepare(
          json: eg.newestGetMessagesResult(
            foundOldest: true,
            messages: [m148, m149, m150],
          ).toJson()..['anchor'] = 150,
        );

        final fcm = await _encodeFcmForStore(
          bgGlobal,
          notifPayloadNewMessage(m150, streamName: stream.name),
        );
        testBinding.firebaseMessaging.onBackgroundMessage.add(fcm);
        async.elapse(Duration.zero);
        await backend.messageDbWriterForAccount(eg.selfAccount.id).drainForTesting();
        check(testBinding.androidNotificationHost.takeNotifyCalls()).length.equals(2);
        check(bgConn.takeRequests()).length.equals(1);

        // Duplicate background notification for 150 skips network (already covered in DB!).
        testBinding.firebaseMessaging.onBackgroundMessage.add(fcm);
        async.elapse(Duration.zero);
        await backend.messageDbWriterForAccount(eg.selfAccount.id).drainForTesting();
        check(bgConn.takeRequests()).isEmpty();

        testBinding.customGlobalStore = null;
        bgGlobal.dispose();

        // Session 3: User goes OFFLINE in the subway and cold-starts the app by tapping
        // the notification!
        final coldOfflineGlobal = await createConfiguredStore(
          backend: backend,
          messageDatabase: true,
        );
        testBinding.customGlobalStore = coldOfflineGlobal;
        coldOfflineGlobal.expectedLoad = ExpectedLoad.persisted;
        coldOfflineGlobal.prepareResumedPollResponse = (conn) =>
          conn.prepare(httpException: const SocketException('offline'));

        final offlineStore = await coldOfflineGlobal.perAccount(eg.selfAccount.id);
        final offlineConn = offlineStore.connection as FakeApiConnection;
        async.elapse(Duration.zero);
        offlineConn.takeRequests();

        // Verify channel:10's old open interval [101, ∞) was closed at highWater (101)
        // rather than falsely claiming [101, 150] (which would miss message 120 in 'other')!
        final channelChains = offlineStore.debugCoverage.chains(
          CoverageKeys.channel(stream.streamId));
        check(channelChains.single.isOpen).isFalse();
        check(channelChains.single.hi).equals(101);

        // Open MessageListView for #general > deploy anchored at 150 while completely offline!
        offlineConn.clearPreparedResponses();
        offlineConn.prepare(httpException: const SocketException('offline'));
        final view = MessageListView.init(
          store: offlineStore,
          narrow: TopicNarrow(stream.streamId, TopicName('deploy')),
          anchor: const NumericAnchor(150),
        );
        unawaited(view.fetchInitial());
        async.elapse(Duration.zero);

        check(view.fetched).isTrue();
        check(view.messages.map((m) => m.id)).deepEquals([148, 149, 150]);

        // Offline FTS search also finds the background-prefetched notification message!
        final searchRes = await offlineStore.searchSavedMessages(
          query: 'UniqueOfflineToken42',
          limit: 20,
        );
        check(searchRes).isNotNull();
        check(searchRes!.messages.map((m) => m.id)).deepEquals([150]);
        view.dispose();
      })));

    test('background DM notification and legacy plaintext notification prefetch for offline cold start', () =>
      runWithAvatarHttp(() => awaitFakeAsync(initialTime: baseTime, (async) async {
        setupNotifTestEnvironment();
        final backend = TestGlobalStoreBackend();
        addTearDown(backend.closeMessageDb);
        final legacyAccount = eg.selfAccount.copyWith(zulipFeatureLevel: 467);

        // Session 1: Initialize account in MessageDatabase.
        final session1Global = await createConfiguredStore(
          backend: backend,
          messageDatabase: true,
          account: legacyAccount,
        );
        session1Global.prepareRegisterQueueResponse = (conn) => conn.prepare(
          json: _snapshotToJson(eg.initialSnapshot(
            zulipFeatureLevel: 467,
            queueId: 'q1',
            lastEventId: 1,
            maxMessageId: 200,
            realmUsers: [eg.selfUser, eg.otherUser],
          )),
        );
        await session1Global.perAccount(legacyAccount.id);
        async.elapse(Duration.zero);
        await backend.messageDbWriterForAccount(legacyAccount.id).drainForTesting();
        session1Global.dispose();

        // Session 2: Unloaded background legacy plaintext DM notification arrives.
        final bgGlobal = await createConfiguredStore(
          backend: backend,
          messageDatabase: true,
          account: legacyAccount,
        );
        testBinding.customGlobalStore = bgGlobal;
        await NotificationService.instance.start();

        final dm1 = eg.dmMessage(id: 210, from: eg.otherUser, to: [eg.selfUser], content: '<p>Hey</p>');
        final dm2 = eg.dmMessage(id: 211, from: eg.otherUser, to: [eg.selfUser], content: '<p>Are you offline?</p>');
        final bgConn = bgGlobal.apiConnectionFromAccount(legacyAccount) as FakeApiConnection;
        bgConn.prepare(
          json: eg.newestGetMessagesResult(
            foundOldest: true,
            messages: [dm1, dm2],
          ).toJson()..['anchor'] = 211,
        );

        final legacyFcm = await _encodeFcmForStore(
          bgGlobal,
          legacyMessageFcmMessage(dm2, account: legacyAccount),
        );
        testBinding.firebaseMessaging.onBackgroundMessage.add(legacyFcm);
        async.elapse(Duration.zero);
        await backend.messageDbWriterForAccount(legacyAccount.id).drainForTesting();
        check(bgConn.takeRequests()).length.equals(1);

        testBinding.customGlobalStore = null;
        bgGlobal.dispose();

        // Session 3: Offline cold start opens the DM conversation from cache.
        final coldGlobal = await createConfiguredStore(
          backend: backend,
          messageDatabase: true,
          account: legacyAccount,
        );
        testBinding.customGlobalStore = coldGlobal;
        coldGlobal.expectedLoad = ExpectedLoad.persisted;
        coldGlobal.prepareResumedPollResponse = (conn) =>
          conn.prepare(httpException: const SocketException('offline'));

        final offlineStore = await coldGlobal.perAccount(legacyAccount.id);
        final offlineConn = offlineStore.connection as FakeApiConnection;
        async.elapse(Duration.zero);
        offlineConn.takeRequests();

        offlineConn.clearPreparedResponses();
        offlineConn.prepare(httpException: const SocketException('offline'));
        final view = MessageListView.init(
          store: offlineStore,
          narrow: DmNarrow.withUser(eg.otherUser.userId, selfUserId: legacyAccount.userId),
          anchor: const NumericAnchor(211),
        );
        unawaited(view.fetchInitial());
        async.elapse(Duration.zero);

        check(view.fetched).isTrue();
        check(view.messages.map((m) => m.id)).deepEquals([210, 211]);
        view.dispose();
      })));

    test('coalesces burst notifications in same conversation and tolerates network failure', () =>
      runWithAvatarHttp(() => awaitFakeAsync(initialTime: baseTime, (async) async {
        setupNotifTestEnvironment();
        final stream = eg.stream(streamId: 10, name: 'general');
        final globalStore = await createConfiguredStore(messageDatabase: true);
        testBinding.customGlobalStore = globalStore;
        globalStore.prepareRegisterQueueResponse = (conn) => conn.prepare(
          json: _snapshotToJson(eg.initialSnapshot(
            queueId: 'q1',
            lastEventId: 1,
            maxMessageId: 100,
            streams: [stream],
            subscriptions: [eg.subscription(stream)],
          )),
        );
        final store = await globalStore.perAccount(eg.selfAccount.id);
        final connection = store.connection as FakeApiConnection;
        async.elapse(Duration.zero);
        connection.takeRequests();

        await NotificationService.instance.start();

        final m150 = eg.streamMessage(id: 150, stream: stream, topic: 'burst', content: '<p>First</p>');
        final m151 = eg.streamMessage(id: 151, stream: stream, topic: 'burst', content: '<p>Second</p>');

        // First response takes 500ms and already includes both 150 and 151 (via numAfter: 20).
        connection.prepare(
          delay: const Duration(milliseconds: 500),
          json: eg.newestGetMessagesResult(
            foundOldest: true,
            messages: [m150, m151],
          ).toJson()..['anchor'] = 150,
        );

        // Both notifications arrive while the first fetch is in flight.
        testBinding.firebaseMessaging.onMessage.add(await _encodeFcmForStore(
          globalStore,
          notifPayloadNewMessage(m150, streamName: stream.name),
        ));
        testBinding.firebaseMessaging.onMessage.add(await _encodeFcmForStore(
          globalStore,
          notifPayloadNewMessage(m151, streamName: stream.name),
        ));
        async.elapse(const Duration(milliseconds: 600));
        await globalStore.backend.messageDbWriterForAccount(eg.selfAccount.id).drainForTesting();

        // Coalesced into a single getMessages request; both messages stored!
        check(connection.takeRequests()).length.equals(1);
        check(store.messages.keys).contains(150);
        check(store.messages.keys).contains(151);

        // Now test a network failure on another topic: notification displays, DB stays active.
        final mFail = eg.streamMessage(id: 160, stream: stream, topic: 'offline-topic', content: '<p>Fail</p>');
        connection.prepare(httpException: const SocketException('network down'));
        testBinding.androidNotificationHost.takeNotifyCalls();
        testBinding.firebaseMessaging.onMessage.add(await _encodeFcmForStore(
          globalStore,
          notifPayloadNewMessage(mFail, streamName: stream.name),
        ));
        async.elapse(Duration.zero);
        check(testBinding.androidNotificationHost.takeNotifyCalls()).length.equals(2);
        check(store.dbActive).isTrue();
      })));

    test('IsolateNameServer port forwarding delegates prefetch and falls back on dead port', () async {
      setupNotifTestEnvironment();
      final stream = eg.stream(streamId: 10, name: 'general');
      final globalStore = await createConfiguredStore(messageDatabase: true);
      addTearDown(globalStore.backend.closeMessageDb);
      testBinding.customGlobalStore = globalStore;
      globalStore.prepareRegisterQueueResponse = (conn) => conn.prepare(
        json: _snapshotToJson(eg.initialSnapshot(
          queueId: 'q1',
          lastEventId: 1,
          maxMessageId: 100,
          streams: [stream],
          subscriptions: [eg.subscription(stream)],
        )),
      );
      final store = await globalStore.perAccount(eg.selfAccount.id);
      final connection = store.connection as FakeApiConnection;
      await Future<void>.delayed(Duration.zero);
      connection.takeRequests();

      NotificationService.registerMainIsolatePrefetchPort();
      final port = IsolateNameServer.lookupPortByName('zulip_notification_prefetch_main_v1');
      check(port).isNotNull();

      final m110 = eg.streamMessage(id: 110, stream: stream, topic: 'ipc', content: '<p>Via port</p>');
      connection.prepare(
        json: eg.newestGetMessagesResult(
          foundOldest: true,
          messages: [m110],
        ).toJson()..['anchor'] = 110,
      );

      final handled = await NotificationService.forwardPrefetchToPort(
        port!,
        notifPayloadNewMessage(m110, streamName: stream.name),
        eg.selfAccount,
      );
      check(handled).isTrue();
      check(store.messages.keys).contains(110);

      // Dead/closed port returns false after ack timeout.
      final deadPort = ReceivePort();
      final deadSendPort = deadPort.sendPort;
      deadPort.close();
      final deadHandled = await NotificationService.forwardPrefetchToPort(
        deadSendPort,
        notifPayloadNewMessage(m110, streamName: stream.name),
        eg.selfAccount,
        ackTimeout: const Duration(milliseconds: 50),
      );
      check(deadHandled).isFalse();

      // Port that acks promptly returns true even if 'done' never arrives,
      // preventing a duplicate unloaded prefetch on slow main-isolate fetches.
      final ackOnlyPort = ReceivePort();
      addTearDown(ackOnlyPort.close);
      ackOnlyPort.listen((raw) {
        final replyPort = (raw as Map<Object?, Object?>)['replyPort'] as SendPort;
        replyPort.send('ack');
      });
      final ackHandled = await NotificationService.forwardPrefetchToPort(
        ackOnlyPort.sendPort,
        notifPayloadNewMessage(m110, streamName: stream.name),
        eg.selfAccount,
        doneTimeout: const Duration(milliseconds: 50),
      );
      check(ackHandled).isTrue();
    });
  });
}
