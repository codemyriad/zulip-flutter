import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:zulip/api/model/initial_snapshot.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/api/route/messages.dart';
import 'package:zulip/model/message.dart';
import 'package:zulip/model/message_coverage.dart';
import 'package:zulip/model/message_list.dart';
import 'package:zulip/model/narrow.dart';
import 'package:zulip/model/presence.dart';
import 'package:zulip/model/settings.dart';
import 'package:zulip/model/store.dart';

import '../api/fake_api.dart';
import '../example_data.dart' as eg;
import '../fake_async.dart';
import 'binding.dart';
import 'test_store.dart';

void main() {
  TestZulipBinding.ensureInitialized();
  Presence.debugEnable = false;

  Map<String, dynamic> snapshotToJson(InitialSnapshot snap) {
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

  Future<({TestGlobalStore global, UpdateMachine um, FakeApiConnection conn})>
      startDbStore({
    TestGlobalStore? existingGlobal,
    InitialSnapshot? snap,
    bool allowPersisted = false,
    Duration? pollDelay,
  }) async {
    final global = existingGlobal ?? eg.globalStore();
    if (existingGlobal == null) {
      await global.settings.setBool(BoolGlobalSetting.messageDatabase, true);
      await global.insertAccount(eg.selfAccount.toCompanion(false));
      global.useCachedApiConnections = true;
    } else {
      global.clearCachedApiConnections();
    }
    final conn = global.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
    final effectiveSnap = snap ?? eg.initialSnapshot();
    if (!allowPersisted) {
      conn.prepare(json: snapshotToJson(effectiveSnap));
    } else {
      global.backend.seedServerData(
        eg.selfAccount.id,
        snapshotJson: snapshotToJson(effectiveSnap),
        lastEventId: effectiveSnap.lastEventId,
      );
    }
    conn.prepare(
      delay: pollDelay ?? Duration.zero,
      json: {
        'result': 'success',
        'msg': '',
        'events': <Object>[],
        'queue_id': effectiveSnap.queueId ?? 'q1',
      },
    );
    final um = await UpdateMachine.load(
      global,
      eg.selfAccount.id,
      allowPersisted: allowPersisted,
    );
    um.debugPauseLoop();
    return (global: global, um: um, conn: conn);
  }

  void seedTopic(
    PerAccountStore store,
    ZulipStream stream,
    String topicName,
    List<StreamMessage> msgs, {
    required bool foundOldest,
    required bool foundNewest,
    int? resolvedAnchor,
    int numBefore = 100,
    int numAfter = 100,
  }) {
    final ticket = store.openFetchTicket(channelId: stream.streamId);
    try {
      store.reconcileMessages(
        msgs,
        rawMessages: [
          for (final m in msgs) jsonDecode(jsonEncode(m)) as Map<String, dynamic>,
        ],
        ticket: ticket,
        coverageRequest: FetchCoverageRequest(
          narrow: TopicNarrow(stream.streamId, eg.t(topicName)),
          numBefore: numBefore,
          numAfter: numAfter,
          includeAnchor: true,
          foundOldest: foundOldest,
          foundNewest: foundNewest,
          historyLimited: false,
          resolvedAnchor: resolvedAnchor ?? msgs.last.id,
        ),
      );
    } finally {
      store.closeFetchTicket(ticket);
    }
  }

  test('live and unconfirmed persisted chains display at 0ms and merge on network response', () => awaitFakeAsync((async) async {
    UpdateMachine.debugEnableFetchEmojiData = false;
    final stream = eg.stream(streamId: 10, name: 'General');
    final sub = eg.subscription(stream);
    final snap = eg.initialSnapshot(
      queueId: 'q1',
      lastEventId: 10,
      maxMessageId: 30,
      realmUsers: [eg.selfUser],
      streams: [stream],
      subscriptions: [sub],
    );
    final setup1 = await startDbStore(snap: snap);
    async.elapse(Duration.zero);

    final m1 = eg.streamMessage(id: 10, stream: stream, topic: 't1', sender: eg.selfUser, content: '<p>one</p>');
    final m2 = eg.streamMessage(id: 20, stream: stream, topic: 't1', sender: eg.selfUser, content: '<p>two</p>');
    seedTopic(setup1.um.store, stream, 't1', [m1, m2],
      foundOldest: true, foundNewest: true, resolvedAnchor: 20);
    await setup1.global.backend
      .messageDbWriterForAccount(eg.selfAccount.id)
      .drainForTesting();

    // Live chain in current epoch: 0ms display + revalidation inFlight -> none.
    setup1.conn.prepare(
      delay: const Duration(milliseconds: 200),
      json: GetMessagesResult(
        anchor: 20,
        foundAnchor: true,
        foundOldest: true,
        foundNewest: true,
        historyLimited: false,
        messages: [m1, m2],
      ).toJson(),
    );
    final liveView = MessageListView.init(
      store: setup1.um.store,
      narrow: TopicNarrow.ofMessage(m1),
      anchor: AnchorCode.newest,
    );
    unawaited(liveView.fetchInitial());
    async.elapse(Duration.zero);
    check(liveView.fetched).isTrue();
    check(liveView.revalidation).equals(RevalidationState.inFlight);
    check(liveView.messages.map((m) => m.id).toList()).deepEquals([10, 20]);

    async.elapse(const Duration(milliseconds: 200));
    check(liveView.revalidation).equals(RevalidationState.none);
    check(liveView.messages.map((m) => m.id).toList()).deepEquals([10, 20]);
    liveView.dispose();
    await setup1.global.backend
      .messageDbWriterForAccount(eg.selfAccount.id)
      .drainForTesting();
    setup1.um.store.dispose();

    // Unconfirmed persisted chain (allowPersisted: true, before first poll):
    // empty RAM, 0ms local display from DB, then merges when network responds.
    final setup2 = await startDbStore(
      existingGlobal: setup1.global,
      snap: snap,
      allowPersisted: true,
      pollDelay: const Duration(milliseconds: 400),
    );
    final store2 = setup2.um.store;
    try {
      check(store2.messages).isEmpty();
      final m3 = eg.streamMessage(id: 30, stream: stream, topic: 't1', sender: eg.selfUser, content: '<p>three</p>');
      final m4 = eg.streamMessage(id: 40, stream: stream, topic: 't1', sender: eg.selfUser, content: '<p>four</p>');
      setup2.conn.prepare(
        delay: const Duration(milliseconds: 200),
        json: GetMessagesResult(
          anchor: 40,
          foundAnchor: true,
          foundOldest: true,
          foundNewest: true,
          historyLimited: false,
          messages: [m1, m2, m3, m4],
        ).toJson(),
      );
      final unconfirmedView = MessageListView.init(
        store: store2,
        narrow: TopicNarrow.ofMessage(m1),
        anchor: AnchorCode.newest,
      );
      unawaited(unconfirmedView.fetchInitial());
      async.elapse(Duration.zero);
      check(unconfirmedView.fetched).isTrue();
      check(unconfirmedView.revalidation).equals(RevalidationState.inFlight);
      check(unconfirmedView.messages.map((m) => m.id).toList()).deepEquals([10, 20]);

      async.elapse(const Duration(milliseconds: 400));
      check(unconfirmedView.revalidation).equals(RevalidationState.none);
      check(unconfirmedView.messages.map((m) => m.id).toList()).deepEquals([10, 20, 30, 40]);
      unconfirmedView.dispose();
      store2.dispose();
    } finally {
      await setup1.global.backend.closeMessageDb();
      setup1.global.dispose();
      UpdateMachine.debugEnableFetchEmojiData = true;
    }
  }));

  test('O12 stale chain 500ms threshold: fast network skips; slow network displays at 500ms then splices/replaces on disjoint', () => awaitFakeAsync((async) async {
    UpdateMachine.debugEnableFetchEmojiData = false;
    final stream = eg.stream(streamId: 10, name: 'General');
    final sub = eg.subscription(stream);
    final snap1 = eg.initialSnapshot(
      queueId: 'q1',
      lastEventId: 10,
      maxMessageId: 100,
      realmUsers: [eg.selfUser],
      streams: [stream],
      subscriptions: [sub],
    );
    final setup1 = await startDbStore(snap: snap1);
    async.elapse(Duration.zero);

    final m1 = eg.streamMessage(id: 10, stream: stream, topic: 't1', sender: eg.selfUser, content: '<p>10</p>');
    final m2 = eg.streamMessage(id: 20, stream: stream, topic: 't1', sender: eg.selfUser, content: '<p>20</p>');
    final mSlow1 = eg.streamMessage(id: 11, stream: stream, topic: 'tSlow', sender: eg.selfUser, content: '<p>11</p>');
    final mSlow2 = eg.streamMessage(id: 21, stream: stream, topic: 'tSlow', sender: eg.selfUser, content: '<p>21</p>');
    final mOldA = eg.streamMessage(id: 5, stream: stream, topic: 'tDisjoint', sender: eg.selfUser, content: '<p>5</p>');
    seedTopic(setup1.um.store, stream, 't1', [m1, m2],
      foundOldest: true, foundNewest: true, resolvedAnchor: 20);
    seedTopic(setup1.um.store, stream, 'tSlow', [mSlow1, mSlow2],
      foundOldest: true, foundNewest: true, resolvedAnchor: 21);
    seedTopic(setup1.um.store, stream, 'tDisjoint', [mOldA],
      foundOldest: true, foundNewest: true, resolvedAnchor: 5);
    await setup1.global.backend
      .messageDbWriterForAccount(eg.selfAccount.id)
      .drainForTesting();
    setup1.um.store.dispose();

    // Fresh register creates a new epoch -> prior intervals are stale.
    final setup2 = await startDbStore(
      existingGlobal: setup1.global,
      snap: snap1,
    );
    async.elapse(Duration.zero);
    final store2 = setup2.um.store;
    final conn2 = setup2.conn;
    try {
      // Case A: fast network (200ms < 500ms) -> never shows stale window.
      final m3 = eg.streamMessage(id: 30, stream: stream, topic: 't1', sender: eg.selfUser, content: '<p>30</p>');
      conn2.prepare(
        delay: const Duration(milliseconds: 200),
        json: GetMessagesResult(
          anchor: 30,
          foundAnchor: true,
          foundOldest: true,
          foundNewest: true,
          historyLimited: false,
          messages: [m1, m2, m3],
        ).toJson(),
      );
      final fastView = MessageListView.init(
        store: store2,
        narrow: TopicNarrow.ofMessage(m1),
        anchor: AnchorCode.newest,
      );
      unawaited(fastView.fetchInitial());
      async.elapse(const Duration(milliseconds: 199));
      check(fastView.fetched).isFalse();
      async.elapse(const Duration(milliseconds: 1));
      check(fastView.fetched).isTrue();
      check(fastView.revalidation).equals(RevalidationState.none);
      check(fastView.messages.map((m) => m.id).toList()).deepEquals([10, 20, 30]);
      fastView.dispose();

      // Case B: slow network (800ms > 500ms) -> shows stale at 500ms, splices overlap at 800ms.
      final m4 = eg.streamMessage(id: 40, stream: stream, topic: 'tSlow', sender: eg.selfUser, content: '<p>40</p>');
      conn2.prepare(
        delay: const Duration(milliseconds: 800),
        json: GetMessagesResult(
          anchor: 40,
          foundAnchor: false,
          foundOldest: false,
          foundNewest: true,
          historyLimited: false,
          messages: [mSlow2, m4],
        ).toJson(),
      );
      final slowSpliceView = MessageListView.init(
        store: store2,
        narrow: TopicNarrow.ofMessage(mSlow1),
        anchor: AnchorCode.newest,
      );
      unawaited(slowSpliceView.fetchInitial());
      async.elapse(const Duration(milliseconds: 499));
      check(slowSpliceView.fetched).isFalse();
      async.elapse(const Duration(milliseconds: 1));
      check(slowSpliceView.fetched).isTrue();
      check(slowSpliceView.revalidation).equals(RevalidationState.inFlight);
      check(slowSpliceView.messages.map((m) => m.id).toList()).deepEquals([11, 21]);

      async.elapse(const Duration(milliseconds: 300));
      check(slowSpliceView.revalidation).equals(RevalidationState.none);
      check(slowSpliceView.messages.map((m) => m.id).toList()).deepEquals([11, 21, 40]);
      slowSpliceView.dispose();

      // Case C: slow network (800ms) -> shows stale at 500ms, replaces on disjoint result.
      final mNewB = eg.streamMessage(id: 90, stream: stream, topic: 'tDisjoint', sender: eg.selfUser, content: '<p>90</p>');
      conn2.prepare(
        delay: const Duration(milliseconds: 800),
        json: GetMessagesResult(
          anchor: kNewestMessageId,
          foundAnchor: false,
          foundOldest: false,
          foundNewest: true,
          historyLimited: false,
          messages: [mNewB],
        ).toJson(),
      );
      final disjointView = MessageListView.init(
        store: store2,
        narrow: TopicNarrow.ofMessage(mOldA),
        anchor: AnchorCode.newest,
      );
      unawaited(disjointView.fetchInitial());
      async.elapse(const Duration(milliseconds: 500));
      check(disjointView.fetched).isTrue();
      check(disjointView.messages.map((m) => m.id).toList()).deepEquals([5]);

      async.elapse(const Duration(milliseconds: 300));
      check(disjointView.revalidation).equals(RevalidationState.none);
      check(disjointView.haveOldest).isFalse();
      check(disjointView.messages.map((m) => m.id).toList()).deepEquals([90]);
      disjointView.dispose();
      store2.dispose();
    } finally {
      await setup1.global.backend.closeMessageDb();
      setup1.global.dispose();
      UpdateMachine.debugEnableFetchEmojiData = true;
    }
  }));

  test('online DB pagination in both completion orders (local-before-network and network-before-local)', () => awaitFakeAsync((async) async {
    UpdateMachine.debugEnableFetchEmojiData = false;
    final stream = eg.stream(streamId: 10, name: 'General');
    final sub = eg.subscription(stream);
    final snap = eg.initialSnapshot(
      queueId: 'q1',
      lastEventId: 10,
      maxMessageId: 200,
      realmUsers: [eg.selfUser],
      streams: [stream],
      subscriptions: [sub],
    );
    final setup1 = await startDbStore(snap: snap);
    async.elapse(Duration.zero);

    // Seed messages 1..150 as covered older-to-newer, but partially stale after restart.
    final olderMsgs = [
      for (int i = 1; i <= 150; i++)
        eg.streamMessage(id: i, stream: stream, topic: 'pag', sender: eg.selfUser, content: '<p>$i</p>'),
    ];
    final order2Msgs = [
      for (int i = 2001; i <= 2150; i++)
        eg.streamMessage(id: i, stream: stream, topic: 'pag2', sender: eg.selfUser, content: '<p>$i</p>'),
    ];
    seedTopic(setup1.um.store, stream, 'pag', olderMsgs,
      foundOldest: false, foundNewest: true, resolvedAnchor: 150, numBefore: 149, numAfter: 0);
    seedTopic(setup1.um.store, stream, 'pag2', order2Msgs,
      foundOldest: false, foundNewest: true, resolvedAnchor: 2150, numBefore: 149, numAfter: 0);
    await setup1.global.backend
      .messageDbWriterForAccount(eg.selfAccount.id)
      .drainForTesting();
    setup1.um.store.dispose();

    // Order 1: local read completes before slow network refresh.
    final setup2 = await startDbStore(existingGlobal: setup1.global, snap: snap);
    async.elapse(Duration.zero);
    final store2 = setup2.um.store;
    final conn2 = setup2.conn;
    try {
      conn2.prepare(
        json: GetMessagesResult(
          anchor: 150,
          foundAnchor: true,
          foundOldest: false,
          foundNewest: true,
          historyLimited: false,
          messages: olderMsgs.sublist(100, 150), // 101..150
        ).toJson(),
      );
      final view1 = MessageListView.init(
        store: store2,
        narrow: TopicNarrow(stream.streamId, eg.t('pag')),
        anchor: AnchorCode.newest,
      );
      await view1.fetchInitial();
      check(view1.messages.length).equals(50);
      check(view1.messages.first.id).equals(101);
      check(view1.haveOldest).isFalse();

      // Network fetchOlder takes 300ms; local DB read returns 1..100 right away.
      conn2.prepare(
        delay: const Duration(milliseconds: 300),
        json: GetMessagesResult(
          anchor: 101,
          foundAnchor: true,
          foundOldest: true,
          foundNewest: false,
          historyLimited: false,
          messages: olderMsgs.sublist(0, 100), // 1..100
        ).toJson(),
      );
      final olderFuture = view1.fetchOlder();
      async.elapse(Duration.zero);
      check(view1.messages.length).equals(150);
      check(view1.messages.first.id).equals(1);
      check(view1.haveOldest).isFalse(); // stale chain had foundOldest=false

      async.elapse(const Duration(milliseconds: 300));
      await olderFuture;
      check(view1.messages.length).equals(150);
      check(view1.messages.first.id).equals(1);
      check(view1.haveOldest).isTrue();
      view1.dispose();

      // Live reachesOldest DB pagination avoids network altogether.
      final setup2LiveMsgs = [
        for (int i = 1001; i <= 1150; i++)
          eg.streamMessage(id: i, stream: stream, topic: 'livePag', sender: eg.selfUser, content: '<p>$i</p>'),
      ];
      seedTopic(store2, stream, 'livePag', setup2LiveMsgs,
        foundOldest: true, foundNewest: true, resolvedAnchor: 1150, numBefore: 149, numAfter: 0);
      await setup1.global.backend
        .messageDbWriterForAccount(eg.selfAccount.id)
        .drainForTesting();
      conn2.prepare(
        json: GetMessagesResult(
          anchor: 1150,
          foundAnchor: true,
          foundOldest: false,
          foundNewest: true,
          historyLimited: false,
          messages: setup2LiveMsgs.sublist(50, 150),
        ).toJson(),
      );
      final liveView = MessageListView.init(
        store: store2,
        narrow: TopicNarrow(stream.streamId, eg.t('livePag')),
        anchor: AnchorCode.newest,
      );
      await liveView.fetchInitial();
      check(liveView.messages.first.id).equals(1051);
      // Prepare NO network response for fetchOlder: live reachesOldest loads purely from DB.
      await liveView.fetchOlder();
      check(liveView.messages.length).equals(150);
      check(liveView.messages.first.id).equals(1001);
      check(liveView.haveOldest).isTrue();
      liveView.dispose();

      // Order 2: network completes BEFORE DB read -> late DB read is discarded cleanly.
      final writer2 = setup1.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      conn2.prepare(
        json: GetMessagesResult(
          anchor: 2150,
          foundAnchor: true,
          foundOldest: false,
          foundNewest: true,
          historyLimited: false,
          messages: order2Msgs.sublist(100, 150), // 2101..2150
        ).toJson(),
      );
      final view2 = MessageListView.init(
        store: store2,
        narrow: TopicNarrow(stream.streamId, eg.t('pag2')),
        anchor: AnchorCode.newest,
      );
      await view2.fetchInitial();
      check(view2.messages.first.id).equals(2101);

      final readGate = Completer<void>();
      writer2.debugBeforeRead = () => readGate.future;
      final editedOlder = [
        for (final m in order2Msgs.sublist(50, 100)) // 2051..2100
          eg.streamMessage(
            id: m.id,
            stream: stream,
            topic: 'pag2',
            sender: eg.selfUser,
            content: '<p>fresh ${m.id}</p>',
          ),
      ];
      conn2.prepare(
        json: GetMessagesResult(
          anchor: 2101,
          foundAnchor: true,
          foundOldest: true,
          foundNewest: false,
          historyLimited: false,
          messages: editedOlder,
        ).toJson(),
      );
      final older2Future = view2.fetchOlder();
      async.elapse(Duration.zero);
      await older2Future;
      check(view2.messages.first.id).equals(2051);
      check(view2.messages.first.content).equals('<p>fresh 2051</p>');
      check(view2.haveOldest).isTrue();

      // Release gated late DB read: must not prepend 2001..2050 or overwrite fresh 2051..2100.
      writer2.debugBeforeRead = null;
      readGate.complete();
      async.elapse(Duration.zero);
      await writer2.drainForTesting();
      check(view2.messages.first.id).equals(2051);
      check(view2.messages.first.content).equals('<p>fresh 2051</p>');

      // Also check concurrent fetchNewer when anchored mid-history.
      conn2.prepare(
        json: GetMessagesResult(
          anchor: 50,
          foundAnchor: true,
          foundOldest: false,
          foundNewest: false,
          historyLimited: false,
          messages: olderMsgs.sublist(40, 60), // 41..60
        ).toJson(),
      );
      final newerView = MessageListView.init(
        store: store2,
        narrow: TopicNarrow(stream.streamId, eg.t('pag')),
        anchor: const NumericAnchor(50),
      );
      await newerView.fetchInitial();
      conn2.prepare(
        delay: const Duration(milliseconds: 200),
        json: GetMessagesResult(
          anchor: 60,
          foundAnchor: true,
          foundOldest: false,
          foundNewest: true,
          historyLimited: false,
          messages: olderMsgs.sublist(60, 150), // 61..150
        ).toJson(),
      );
      final newerFuture = newerView.fetchNewer();
      async.elapse(Duration.zero);
      // Local DB read returned 61..150 immediately before 200ms network response.
      check(newerView.messages.last.id).equals(150);
      async.elapse(const Duration(milliseconds: 200));
      await newerFuture;
      check(newerView.haveNewest).isTrue();
      check(newerView.messages.last.id).equals(150);
      newerView.dispose();
      view2.dispose();
      store2.dispose();
    } finally {
      await setup1.global.backend.closeMessageDb();
      setup1.global.dispose();
      UpdateMachine.debugEnableFetchEmojiData = true;
    }
  }));
}
