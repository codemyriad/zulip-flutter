import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_checks/flutter_checks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zulip/api/backoff.dart';
import 'package:zulip/api/model/events.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/api/route/messages.dart';
import 'package:zulip/model/message.dart';
import 'package:zulip/model/message_coverage.dart';
import 'package:zulip/model/message_list.dart';
import 'package:zulip/model/narrow.dart';
import 'package:zulip/model/settings.dart';
import 'package:zulip/model/store.dart';
import 'package:zulip/widgets/banner.dart';
import 'package:zulip/widgets/message_list.dart';

import '../api/fake_api.dart';
import '../example_data.dart' as eg;
import '../model/binding.dart';
import '../model/test_store.dart';
import 'test_app.dart';

void main() {
  TestZulipBinding.ensureInitialized();

  Future<PerAccountStore> seedSavedTopic(
    WidgetTester tester, {
    required ZulipStream stream,
    required String topic,
    required List<Message> messages,
    required bool foundOldest,
    required bool foundNewest,
    required int resolvedAnchor,
    int? numBefore,
    int numAfter = 0,
    bool restartFresh = true,
    int lastEventId = 10,
    int? maxMessageId,
  }) async {
    UpdateMachine.debugEnableFetchEmojiData = false;
    final snap = eg.initialSnapshot(
      zulipFeatureLevel: eg.recentZulipFeatureLevel,
      queueId: 'q-seed',
      lastEventId: lastEventId,
      maxMessageId: maxMessageId ?? (messages.isEmpty ? 50 : resolvedAnchor),
      realmUsers: [eg.selfUser],
      streams: [stream],
      subscriptions: [eg.subscription(stream)],
    );

    final backend = testBinding.globalStore.backend;
    final seedGlobal = TestGlobalStore(backend: backend, accounts: []);
    await seedGlobal.settings.setBool(BoolGlobalSetting.messageDatabase, true);
    await seedGlobal.add(eg.selfAccount, snap);
    final seedStore = await seedGlobal.perAccount(eg.selfAccount.id);
    await seedStore.initMessageDbFromRegister(lastEventId: lastEventId);
    final ticket = seedStore.openFetchTicket(channelId: stream.streamId);
    try {
      seedStore.reconcileMessages(
        List<Message>.from(messages),
        rawMessages: [
          for (final m in messages)
            jsonDecode(jsonEncode(m)) as Map<String, dynamic>,
        ],
        ticket: ticket,
        coverageRequest: FetchCoverageRequest(
          narrow: TopicNarrow(stream.streamId, eg.t(topic)),
          numBefore: numBefore ?? (messages.isEmpty ? 100 : messages.length),
          numAfter: messages.isEmpty ? 100 : numAfter,
          includeAnchor: true,
          foundOldest: foundOldest,
          foundNewest: foundNewest,
          historyLimited: false,
          resolvedAnchor: resolvedAnchor,
        ),
      );
    } finally {
      seedStore.closeFetchTicket(ticket);
    }
    await backend.messageDbWriterForAccount(eg.selfAccount.id).drainForTesting();
    seedGlobal.dispose();
    await tester.pump();

    await testBinding.globalStore.settings.setBool(
      BoolGlobalSetting.messageDatabase,
      true,
    );
    if (restartFresh) {
      final freshSnap = eg.initialSnapshot(
        zulipFeatureLevel: eg.recentZulipFeatureLevel,
        queueId: 'q-fresh',
        lastEventId: lastEventId + 1,
        maxMessageId: (maxMessageId ?? resolvedAnchor) + 10,
        realmUsers: [eg.selfUser],
        streams: [stream],
        subscriptions: [eg.subscription(stream)],
      );
      await testBinding.globalStore.add(eg.selfAccount, freshSnap);
      final store = await testBinding.globalStore.perAccount(eg.selfAccount.id);
      await store.initMessageDbFromRegister(lastEventId: lastEventId + 1);
      return store;
    } else {
      await testBinding.globalStore.add(eg.selfAccount, snap);
      final store = await testBinding.globalStore.perAccount(eg.selfAccount.id);
      await store.initMessageDbFromPersisted(ackEventId: lastEventId);
      return store;
    }
  }

  Future<void> pumpMessageListForNarrow(
    WidgetTester tester, {
    required Narrow narrow,
    int? initAnchorMessageId,
  }) async {
    await tester.pumpWidget(TestZulipApp(
      accountId: eg.selfAccount.id,
      child: MessageListPage(
        initNarrow: narrow,
        initAnchorMessageId: initAnchorMessageId,
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  Future<void> unmountApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('banner timing: none under 3s while updating, Updating at 3s, cleared on merge', (tester) async {
    addTearDown(testBinding.reset);
    addTearDown(() => UpdateMachine.debugEnableFetchEmojiData = true);
    final stream = eg.stream(streamId: 10, name: 'General');
    final m1 = eg.streamMessage(
      id: 10, stream: stream, topic: 't1', sender: eg.selfUser,
      content: '<p>saved one</p>', flags: [MessageFlag.read]);
    final m2 = eg.streamMessage(
      id: 20, stream: stream, topic: 't1', sender: eg.selfUser,
      content: '<p>saved two</p>', flags: [MessageFlag.read]);
    final store = await seedSavedTopic(
      tester,
      stream: stream,
      topic: 't1',
      messages: [m1, m2],
      foundOldest: true,
      foundNewest: true,
      resolvedAnchor: 20,
    );

    final conn = store.connection as FakeApiConnection;
    conn.prepare(
      delay: const Duration(seconds: 5),
      json: GetMessagesResult(
        anchor: 20,
        foundAnchor: true,
        foundOldest: true,
        foundNewest: true,
        historyLimited: false,
        messages: [m1, m2],
      ).toJson(),
    );

    await pumpMessageListForNarrow(tester, narrow: TopicNarrow.ofMessage(m1));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    check(find.text('saved one')).findsOne();
    check(find.byType(ZulipBanner)).findsNothing();

    await tester.pump(const Duration(milliseconds: 2999));
    check(find.byType(ZulipBanner)).findsNothing();

    await tester.pump(const Duration(milliseconds: 1));
    check(find.byType(ZulipBanner)).findsOne();
    check(find.textContaining('Updating… Showing messages saved')).findsOne();

    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();
    check(find.byType(ZulipBanner)).findsNothing();

    await unmountApp(tester);
  });

  testWidgets('offline banner appears immediately when unsubscribed stale revalidation fails', (tester) async {
    addTearDown(testBinding.reset);
    addTearDown(() => UpdateMachine.debugEnableFetchEmojiData = true);
    final stream = eg.stream(streamId: 10, name: 'General');
    final mFail = eg.streamMessage(
      id: 30, stream: stream, topic: 'tFail', sender: eg.selfUser,
      content: '<p>offline msg</p>', flags: [MessageFlag.read]);
    final store = await seedSavedTopic(
      tester,
      stream: stream,
      topic: 'tFail',
      messages: [mFail],
      foundOldest: true,
      foundNewest: true,
      resolvedAnchor: 30,
    );
    await store.handleEvent(SubscriptionRemoveEvent(id: 1, channelIds: [stream.streamId]));
    await testBinding.globalStore.backend
      .messageDbWriterForAccount(eg.selfAccount.id)
      .drainForTesting();

    final conn = store.connection as FakeApiConnection;
    for (int i = 0; i < 6; i++) {
      conn.prepare(httpStatus: 500, body: 'server error');
    }
    await pumpMessageListForNarrow(tester, narrow: TopicNarrow.ofMessage(mFail));
    await tester.pump(const Duration(milliseconds: 50));

    check(find.text('offline msg')).findsOne();
    check(find.byType(ZulipBanner)).findsOne();
    check(find.textContaining('Offline. Showing messages saved on this device, last updated')).findsOne();

    await unmountApp(tester);
  });

  testWidgets('unconfirmed persisted window shows banner after 3s and clears when confirmed', (tester) async {
    addTearDown(testBinding.reset);
    addTearDown(() => UpdateMachine.debugEnableFetchEmojiData = true);
    final stream = eg.stream(streamId: 10, name: 'General');
    final m1 = eg.streamMessage(
      id: 10, stream: stream, topic: 'tUnconf', sender: eg.selfUser,
      content: '<p>unconfirmed one</p>', flags: [MessageFlag.read]);
    final store = await seedSavedTopic(
      tester,
      stream: stream,
      topic: 'tUnconf',
      messages: [m1],
      foundOldest: true,
      foundNewest: true,
      resolvedAnchor: 10,
      restartFresh: false,
    );
    check(store.confirmed).isFalse();

    final conn = store.connection as FakeApiConnection;
    conn.prepare(
      delay: const Duration(seconds: 6),
      json: GetMessagesResult(
        anchor: 10,
        foundAnchor: true,
        foundOldest: true,
        foundNewest: true,
        historyLimited: false,
        messages: [m1],
      ).toJson(),
    );

    await pumpMessageListForNarrow(tester, narrow: TopicNarrow.ofMessage(m1));
    await tester.pump(const Duration(milliseconds: 50));
    check(find.text('unconfirmed one')).findsOne();
    final pageState = tester.state<MessageListPageState>(find.byType(MessageListPage));
    check(pageState.model!.contentState).equals(ContentState.unconfirmed);
    check(find.byType(ZulipBanner)).findsNothing();

    await tester.pump(const Duration(milliseconds: 3000));
    check(find.byType(ZulipBanner)).findsOne();
    check(find.textContaining('Updating… Showing messages saved')).findsOne();

    store.debugSetConfirmed(true);
    await tester.pump();
    check(pageState.model!.contentState).equals(ContentState.current);
    check(find.byType(ZulipBanner)).findsNothing();

    await tester.pump(const Duration(seconds: 4));
    await unmountApp(tester);
  });

  testWidgets('offline edge notices: anchor fallback shows anchor fallback and older unavailable', (tester) async {
    addTearDown(testBinding.reset);
    addTearDown(() => UpdateMachine.debugEnableFetchEmojiData = true);
    final stream = eg.stream(streamId: 10, name: 'General');
    final partialMsgs = [
      for (int id = 54; id <= 56; id++)
        eg.streamMessage(
          id: id, stream: stream, topic: 'mid', sender: eg.selfUser,
          content: '<p>msg $id</p>', flags: [MessageFlag.read]),
    ];
    final store = await seedSavedTopic(
      tester,
      stream: stream,
      topic: 'mid',
      messages: partialMsgs,
      foundOldest: false,
      foundNewest: false,
      resolvedAnchor: 55,
      numBefore: 1,
      numAfter: 1,
    );

    final conn = store.connection as FakeApiConnection;
    for (int i = 0; i < 6; i++) {
      conn.prepare(httpStatus: 500, body: 'offline');
    }
    await pumpMessageListForNarrow(
      tester,
      narrow: TopicNarrow(stream.streamId, eg.t('mid')),
      initAnchorMessageId: 999,
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    check(find.text('Newer messages, including the one you opened, aren’t available offline')).findsOne();
    check(find.text('Can’t load older messages offline')).findsOne();

    await unmountApp(tester);
  });

  testWidgets('offline edge notices: mid-history window shows older and newer unavailable', (tester) async {
    addTearDown(testBinding.reset);
    addTearDown(() => UpdateMachine.debugEnableFetchEmojiData = true);
    final stream = eg.stream(streamId: 10, name: 'General');
    final partialMsgs = [
      for (int id = 54; id <= 56; id++)
        eg.streamMessage(
          id: id, stream: stream, topic: 'mid', sender: eg.selfUser,
          content: '<p>msg $id</p>', flags: [MessageFlag.read]),
    ];
    final store = await seedSavedTopic(
      tester,
      stream: stream,
      topic: 'mid',
      messages: partialMsgs,
      foundOldest: false,
      foundNewest: false,
      resolvedAnchor: 55,
      numBefore: 1,
      numAfter: 1,
    );

    final conn = store.connection as FakeApiConnection;
    for (int i = 0; i < 6; i++) {
      conn.prepare(httpStatus: 500, body: 'offline');
    }
    await pumpMessageListForNarrow(
      tester,
      narrow: TopicNarrow(stream.streamId, eg.t('mid')),
      initAnchorMessageId: 55,
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    check(find.text('Can’t load older messages offline')).findsOne();
    check(find.text('Can’t load newer messages offline')).findsOne();

    await unmountApp(tester);
  });

  testWidgets('empty-conversation autofocus waits until confirmed current, not stale', (tester) async {
    addTearDown(testBinding.reset);
    addTearDown(() => UpdateMachine.debugEnableFetchEmojiData = true);
    final stream = eg.stream(streamId: 10, name: 'General');
    final store = await seedSavedTopic(
      tester,
      stream: stream,
      topic: 'emptyTopic',
      messages: const [],
      foundOldest: true,
      foundNewest: true,
      resolvedAnchor: 1,
      restartFresh: true,
    );
    final conn = store.connection as FakeApiConnection;
    conn.prepare(
      delay: const Duration(seconds: 2),
      json: GetMessagesResult(
        anchor: 1,
        foundAnchor: false,
        foundOldest: true,
        foundNewest: true,
        historyLimited: false,
        messages: const [],
      ).toJson(),
    );

    await pumpMessageListForNarrow(
      tester,
      narrow: TopicNarrow(stream.streamId, eg.t('emptyTopic')),
      initAnchorMessageId: 1,
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    final pageState = tester.state<MessageListPageState>(find.byType(MessageListPage));
    check(pageState.model!.fetched).isFalse();
    check(pageState.composeBoxState!.controller.contentFocusNode.hasFocus).isFalse();

    await tester.pump(const Duration(milliseconds: 1600));
    await tester.pump();
    check(pageState.model!.fetched).isTrue();
    check(pageState.model!.contentState).equals(ContentState.current);
    check(pageState.composeBoxState!.controller.contentFocusNode.hasFocus).isTrue();

    await unmountApp(tester);
  });

  testWidgets('empty-conversation autofocus waits until confirmed, not unconfirmed', (tester) async {
    addTearDown(testBinding.reset);
    addTearDown(() => UpdateMachine.debugEnableFetchEmojiData = true);
    final stream = eg.stream(streamId: 10, name: 'General');
    final store = await seedSavedTopic(
      tester,
      stream: stream,
      topic: 'emptyUnconf',
      messages: const [],
      foundOldest: true,
      foundNewest: true,
      resolvedAnchor: kNewestMessageId,
      numBefore: 100,
      numAfter: 0,
      maxMessageId: 50,
      restartFresh: false,
    );
    check(store.confirmed).isFalse();
    final conn = store.connection as FakeApiConnection;
    conn.prepare(
      delay: const Duration(seconds: 5),
      json: GetMessagesResult(
        anchor: 1,
        foundAnchor: false,
        foundOldest: true,
        foundNewest: true,
        historyLimited: false,
        messages: const [],
      ).toJson(),
    );

    await pumpMessageListForNarrow(
      tester,
      narrow: TopicNarrow(stream.streamId, eg.t('emptyUnconf')),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final pageState = tester.state<MessageListPageState>(find.byType(MessageListPage));
    check(pageState.model!.fetched).isTrue();
    check(pageState.model!.canDecideEmptyAutofocus).isFalse();
    check(pageState.composeBoxState!.controller.contentFocusNode.hasFocus).isFalse();

    store.debugSetConfirmed(true);
    await tester.pump();
    check(pageState.model!.canDecideEmptyAutofocus).isTrue();
    check(pageState.composeBoxState!.controller.contentFocusNode.hasFocus).isTrue();

    await tester.pump(const Duration(seconds: 6));
    await unmountApp(tester);
  });

  testWidgets('DB-loaded message supports poll voting interactively', (tester) async {
    addTearDown(testBinding.reset);
    addTearDown(() => UpdateMachine.debugEnableFetchEmojiData = true);
    final stream = eg.stream(streamId: 10, name: 'General');
    final pollMsg = eg.streamMessage(
      id: 70,
      stream: stream,
      topic: 'pollTopic',
      sender: eg.selfUser,
      content: '',
      flags: [MessageFlag.read],
      submessages: [
        eg.submessage(
          content: eg.pollWidgetData(question: 'Lunch?', options: ['Pizza']),
        ),
      ],
    );
    final store = await seedSavedTopic(
      tester,
      stream: stream,
      topic: 'pollTopic',
      messages: [pollMsg],
      foundOldest: true,
      foundNewest: true,
      resolvedAnchor: 70,
    );

    final conn = store.connection as FakeApiConnection;
    conn.prepare(
      delay: const Duration(seconds: 5),
      json: GetMessagesResult(
        anchor: 70,
        foundAnchor: true,
        foundOldest: true,
        foundNewest: true,
        historyLimited: false,
        messages: [pollMsg],
      ).toJson(),
    );
    await pumpMessageListForNarrow(tester, narrow: TopicNarrow.ofMessage(pollMsg));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    check(find.text('Lunch?')).findsOne();
    check(find.text('Pizza')).findsOne();
    final voteButtonFinder = find.text('0');
    check(voteButtonFinder).findsOne();
    conn.prepare(json: {});
    await tester.tap(voteButtonFinder);
    await tester.pump();
    final reqs = conn.takeRequests();
    check(reqs.any((r) => r.url.path == '/api/v1/submessage')).isTrue();

    await tester.pump(const Duration(seconds: 5));
    await unmountApp(tester);
  });

  testWidgets('offline banner and edge notices do not flicker across delayed retry attempts', (tester) async {
    addTearDown(testBinding.reset);
    addTearDown(() => UpdateMachine.debugEnableFetchEmojiData = true);
    BackoffMachine.debugDuration = const Duration(seconds: 5);
    addTearDown(() => BackoffMachine.debugDuration = null);
    final stream = eg.stream(streamId: 10, name: 'General');
    final partialMsgs = [
      for (int id = 54; id <= 56; id++)
        eg.streamMessage(
          id: id, stream: stream, topic: 'mid', sender: eg.selfUser,
          content: '<p>msg $id</p>', flags: [MessageFlag.read]),
    ];
    final store = await seedSavedTopic(
      tester,
      stream: stream,
      topic: 'mid',
      messages: partialMsgs,
      foundOldest: false,
      foundNewest: false,
      resolvedAnchor: 55,
      numBefore: 1,
      numAfter: 1,
    );

    final conn = store.connection as FakeApiConnection;
    conn.prepare(httpStatus: 500, body: 'offline');
    await pumpMessageListForNarrow(
      tester,
      narrow: TopicNarrow(stream.streamId, eg.t('mid')),
      initAnchorMessageId: 999,
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    void checkOfflineUiPresent() {
      check(find.byType(ZulipBanner)).findsOne();
      check(find.textContaining('Offline. Showing messages saved on this device, last updated')).findsOne();
      check(find.textContaining('Updating…')).findsNothing();
      check(find.text('Newer messages, including the one you opened, aren’t available offline')).findsOne();
      check(find.text('Can’t load older messages offline')).findsOne();
    }

    checkOfflineUiPresent();
    check(conn.takeRequests()).length.equals(1);

    // Next retry attempt starts after backoff (4.5s remaining) and stays in flight for 4s.
    conn.prepare(delay: const Duration(seconds: 4), httpStatus: 500, body: 'offline');
    await tester.pump(const Duration(milliseconds: 4500));
    await tester.pump();
    check(conn.takeRequests()).length.equals(1);
    checkOfflineUiPresent();

    // Past the 3s stale-banner threshold while retry is still in flight.
    await tester.pump(const Duration(seconds: 3));
    checkOfflineUiPresent();

    // Retry fails at +1s; prepare a succeeding next retry so backoff drains cleanly.
    conn.prepare(
      json: GetMessagesResult(
        anchor: 999,
        foundAnchor: false,
        foundOldest: true,
        foundNewest: true,
        historyLimited: false,
        messages: partialMsgs,
      ).toJson(),
    );
    await tester.pump(const Duration(seconds: 1));
    checkOfflineUiPresent();

    await tester.pump(const Duration(seconds: 5));
    await unmountApp(tester);
  });

  testWidgets('stale local pagination shows offline banner when refresh fails and clears on recovery', (tester) async {
    addTearDown(testBinding.reset);
    addTearDown(() => UpdateMachine.debugEnableFetchEmojiData = true);
    BackoffMachine.debugDuration = const Duration(seconds: 5);
    addTearDown(() => BackoffMachine.debugDuration = null);
    final stream = eg.stream(streamId: 10, name: 'General');
    final savedMsgs = [
      for (int id = 1; id <= 10; id++)
        eg.streamMessage(
          id: id, stream: stream, topic: 'pagStale', sender: eg.selfUser,
          content: '<p>msg $id</p>', flags: [MessageFlag.read]),
    ];
    final store = await seedSavedTopic(
      tester,
      stream: stream,
      topic: 'pagStale',
      messages: savedMsgs.sublist(1, 6), // IDs 2..6 saved as stale
      foundOldest: false,
      foundNewest: false,
      resolvedAnchor: 6,
      numBefore: 5,
    );

    // Reconcile IDs 6..10 as live in the new epoch so initial load is live
    // (haveOldest: false) and older pagination reads 2..5 from stale DB coverage.
    final liveTicket = store.openFetchTicket(channelId: stream.streamId);
    try {
      store.reconcileMessages(
        List<Message>.from(savedMsgs.sublist(5)),
        rawMessages: [
          for (final m in savedMsgs.sublist(5))
            jsonDecode(jsonEncode(m)) as Map<String, dynamic>,
        ],
        ticket: liveTicket,
        coverageRequest: FetchCoverageRequest(
          narrow: TopicNarrow(stream.streamId, eg.t('pagStale')),
          numBefore: 5,
          numAfter: 0,
          includeAnchor: true,
          foundOldest: false,
          foundNewest: true,
          historyLimited: false,
          resolvedAnchor: 10,
        ),
      );
    } finally {
      store.closeFetchTicket(liveTicket);
    }
    await testBinding.globalStore.backend
      .messageDbWriterForAccount(eg.selfAccount.id).drainForTesting();

    final conn = store.connection as FakeApiConnection;
    conn.prepare(
      delay: const Duration(milliseconds: 50),
      httpStatus: 500,
      body: 'offline',
    );
    await pumpMessageListForNarrow(tester, narrow: TopicNarrow.ofMessage(savedMsgs.first));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump();

    final pageState = tester.state<MessageListPageState>(find.byType(MessageListPage));
    check(pageState.model!.messages.first.id).equals(2);
    check(find.byType(ZulipBanner)).findsOne();
    check(find.textContaining('Offline. Showing messages saved on this device')).findsOne();

    conn.prepare(
      json: GetMessagesResult(
        anchor: 6,
        foundAnchor: true,
        foundOldest: true,
        foundNewest: false,
        historyLimited: false,
        messages: savedMsgs.sublist(0, 6),
      ).toJson(),
    );
    await tester.pump(const Duration(seconds: 5));
    await pageState.model!.fetchOlder();
    await tester.pump();
    check(find.byType(ZulipBanner)).findsNothing();
    check(pageState.model!.messages.first.id).equals(1);

    await unmountApp(tester);
  });
}
