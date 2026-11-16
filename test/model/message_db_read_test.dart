import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:zulip/api/model/events.dart';
import 'package:zulip/api/model/initial_snapshot.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/api/route/messages.dart';
import 'package:zulip/model/message.dart';
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
    }
    conn.prepare(json: {
      'result': 'success',
      'msg': '',
      'events': <Object>[],
      'queue_id': effectiveSnap.queueId ?? 'q1',
    });
    final um = await UpdateMachine.load(
      global,
      eg.selfAccount.id,
      allowPersisted: allowPersisted,
    );
    um.debugPauseLoop();
    return (global: global, um: um, conn: conn);
  }

  test('M1 fallback-only: cold restart shows DB window only after fetch failure, then merges on recovery', () => awaitFakeAsync((async) async {
    UpdateMachine.debugEnableFetchEmojiData = false;
    final stream = eg.stream(streamId: 10, name: 'General');
    final sub = eg.subscription(stream);
    final snap1 = eg.initialSnapshot(
      queueId: 'q1',
      lastEventId: 10,
      maxMessageId: 20,
      realmUsers: [eg.selfUser, eg.otherUser],
      streams: [stream],
      subscriptions: [sub],
    );
    final setup1 = await startDbStore(snap: snap1);
    async.elapse(Duration.zero);
    final m1 = eg.streamMessage(id: 10, stream: stream, topic: 't1', sender: eg.selfUser, content: '<p>one</p>');
    final m2 = eg.streamMessage(id: 20, stream: stream, topic: 't1', sender: eg.selfUser, content: '<p>two</p>');
    final t1 = setup1.um.store.openFetchTicket(channelId: stream.streamId);
    try {
      setup1.um.store.reconcileMessages(
        [m1, m2],
        rawMessages: [
          jsonDecode(jsonEncode(m1)) as Map<String, dynamic>,
          jsonDecode(jsonEncode(m2)) as Map<String, dynamic>,
        ],
        ticket: t1,
        coverageRequest: FetchCoverageRequest(
          narrow: TopicNarrow.ofMessage(m2),
          numBefore: 100,
          numAfter: 100,
          includeAnchor: true,
          foundOldest: true,
          foundNewest: true,
          historyLimited: false,
          resolvedAnchor: 20,
        ),
      );
    } finally {
      setup1.um.store.closeFetchTicket(t1);
    }
    await setup1.global.backend
      .messageDbWriterForAccount(eg.selfAccount.id)
      .drainForTesting();
    setup1.um.store.dispose();

    final setup2 = await startDbStore(
      existingGlobal: setup1.global,
      snap: eg.initialSnapshot(
        queueId: 'q2',
        lastEventId: 10,
        maxMessageId: 30,
        realmUsers: [eg.selfUser, eg.otherUser],
        streams: [stream],
        subscriptions: [sub],
      ),
    );
    async.elapse(Duration.zero);
    final store2 = setup2.um.store;
    final conn2 = setup2.conn;
    try {
      // M1 online: view stays in fetchInitial until network responds (no local-first display).
      final m3 = eg.streamMessage(id: 30, stream: stream, topic: 't1', sender: eg.selfUser, content: '<p>three</p>');
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
      final onlineView = MessageListView.init(
        store: store2,
        narrow: TopicNarrow.ofMessage(m1),
        anchor: AnchorCode.newest,
      );
      unawaited(onlineView.fetchInitial());
      async.flushMicrotasks();
      check(onlineView.fetched).isFalse();
      async.elapse(const Duration(milliseconds: 200));
      check(onlineView.fetched).isTrue();
      check(onlineView.messages.map((m) => m.id).toList()).deepEquals([10, 20, 30]);
      onlineView.dispose();
      await setup2.global.backend
        .messageDbWriterForAccount(eg.selfAccount.id)
        .drainForTesting();

      // Open offline on cold restart (empty RAM) -> failure -> shows DB window, then merges.
      store2.dispose();
      final setup3 = await startDbStore(
        existingGlobal: setup1.global,
        snap: eg.initialSnapshot(
          queueId: 'q3',
          lastEventId: 10,
          maxMessageId: 30,
          realmUsers: [eg.selfUser, eg.otherUser],
          streams: [stream],
          subscriptions: [sub],
        ),
      );
      async.elapse(Duration.zero);
      final store3 = setup3.um.store;
      final conn3 = setup3.conn;
      check(store3.messages).isEmpty();

      conn3.prepare(httpException: const SocketException('offline'));
      final offlineView = MessageListView.init(
        store: store3,
        narrow: TopicNarrow.ofMessage(m1),
        anchor: AnchorCode.newest,
      );
      unawaited(offlineView.fetchInitial());
      async.elapse(Duration.zero);
      check(offlineView.fetched).isTrue();
      check(offlineView.revalidation).equals(RevalidationState.failing);
      check(offlineView.messages.map((m) => m.id).toList()).deepEquals([10, 20, 30]);

      // Network recovers -> retry merges m4 cleanly.
      final m4 = eg.streamMessage(id: 40, stream: stream, topic: 't1', sender: eg.selfUser, content: '<p>four</p>');
      conn3.prepare(
        json: GetMessagesResult(
          anchor: 40,
          foundAnchor: true,
          foundOldest: true,
          foundNewest: true,
          historyLimited: false,
          messages: [m1, m2, m3, m4],
        ).toJson(),
      );
      async.elapse(const Duration(seconds: 5));
      check(offlineView.revalidation).equals(RevalidationState.none);
      check(offlineView.messages.map((m) => m.id).toList()).deepEquals([10, 20, 30, 40]);
      offlineView.dispose();
      store3.dispose();
    } finally {
      await setup1.global.backend.closeMessageDb();
      setup1.global.dispose();
      UpdateMachine.debugEnableFetchEmojiData = true;
    }
  }));

  test('anchor fallback offline and pagination over stored DB rows', () => awaitFakeAsync((async) async {
    UpdateMachine.debugEnableFetchEmojiData = false;
    final stream = eg.stream(streamId: 10, name: 'General');
    final sub = eg.subscription(stream);
    final snap = eg.initialSnapshot(
      queueId: 'q1',
      lastEventId: 10,
      maxMessageId: 250,
      realmUsers: [eg.selfUser],
      streams: [stream],
      subscriptions: [sub],
    );
    final setup1 = await startDbStore(snap: snap);
    async.elapse(Duration.zero);
    final topic = TopicNarrow(stream.streamId, eg.t('long'));
    final msgs = [
      for (int i = 1; i <= 150; i++)
        eg.streamMessage(id: i, stream: stream, topic: 'long', sender: eg.selfUser, content: '<p>$i</p>'),
    ];
    final t1 = setup1.um.store.openFetchTicket(channelId: stream.streamId);
    try {
      setup1.um.store.reconcileMessages(
        msgs,
        rawMessages: [
          for (final m in msgs) jsonDecode(jsonEncode(m)) as Map<String, dynamic>,
        ],
        ticket: t1,
        coverageRequest: FetchCoverageRequest(
          narrow: topic,
          numBefore: 150,
          numAfter: 0,
          includeAnchor: true,
          foundOldest: true,
          foundNewest: true,
          historyLimited: false,
          resolvedAnchor: 150,
        ),
      );
    } finally {
      setup1.um.store.closeFetchTicket(t1);
    }
    await setup1.global.backend
      .messageDbWriterForAccount(eg.selfAccount.id)
      .drainForTesting();
    setup1.um.store.dispose();

    final setup2 = await startDbStore(
      existingGlobal: setup1.global,
      snap: snap,
    );
    async.elapse(Duration.zero);
    final store2 = setup2.um.store;
    final conn2 = setup2.conn;
    try {
      conn2.prepare(httpException: const SocketException('offline'));
      final view = MessageListView.init(
        store: store2,
        narrow: topic,
        anchor: const NumericAnchor(999999),
      );
      unawaited(view.fetchInitial());
      async.elapse(Duration.zero);
      check(view.fetched).isTrue();
      check(view.haveOldest).isFalse();
      check(view.messages.length).equals(100);
      check(view.messages.first.id).equals(51);
      check(view.messages.last.id).equals(150);

      await view.fetchOlder();
      check(view.haveOldest).isTrue();
      check(view.messages.length).equals(150);
      check(view.messages.first.id).equals(1);
      view.dispose();
      store2.dispose();
    } finally {
      await setup1.global.backend.closeMessageDb();
      setup1.global.dispose();
      UpdateMachine.debugEnableFetchEmojiData = true;
    }
  }));

  test('read race rule: delete, edit, move-in, move-out of row-only messages (including uncommitted batch)', () => awaitFakeAsync((async) async {
    UpdateMachine.debugEnableFetchEmojiData = false;
    final stream = eg.stream(streamId: 10, name: 'General');
    final sub = eg.subscription(stream);
    final snap = eg.initialSnapshot(
      queueId: 'q1',
      lastEventId: 10,
      maxMessageId: 100,
      realmUsers: [eg.selfUser],
      streams: [stream],
      subscriptions: [sub],
    );
    final setup1 = await startDbStore(snap: snap);
    async.elapse(Duration.zero);
    final mDel = eg.streamMessage(id: 10, stream: stream, topic: 'tA', sender: eg.selfUser, content: '<p>del</p>');
    final mEdit = eg.streamMessage(id: 20, stream: stream, topic: 'tA', sender: eg.selfUser, content: '<p>old</p>');
    final mMoveOut = eg.streamMessage(id: 30, stream: stream, topic: 'tA', sender: eg.selfUser, content: '<p>out</p>');
    final mMoveIn = eg.streamMessage(id: 25, stream: stream, topic: 'tB', sender: eg.selfUser, content: '<p>in</p>');
    final t1 = setup1.um.store.openFetchTicket(channelId: stream.streamId);
    try {
      setup1.um.store.reconcileMessages(
        [mDel, mEdit, mMoveOut],
        rawMessages: [
          for (final m in [mDel, mEdit, mMoveOut])
            jsonDecode(jsonEncode(m)) as Map<String, dynamic>,
        ],
        ticket: t1,
        coverageRequest: FetchCoverageRequest(
          narrow: TopicNarrow.ofMessage(mDel),
          numBefore: 100,
          numAfter: 100,
          includeAnchor: true,
          foundOldest: true,
          foundNewest: true,
          historyLimited: false,
          resolvedAnchor: 20,
        ),
      );
      setup1.um.store.reconcileMessages(
        [mMoveIn],
        rawMessages: [jsonDecode(jsonEncode(mMoveIn)) as Map<String, dynamic>],
        ticket: t1,
        coverageRequest: FetchCoverageRequest(
          narrow: TopicNarrow.ofMessage(mMoveIn),
          numBefore: 100,
          numAfter: 100,
          includeAnchor: true,
          foundOldest: true,
          foundNewest: true,
          historyLimited: false,
          resolvedAnchor: 25,
        ),
      );
    } finally {
      setup1.um.store.closeFetchTicket(t1);
    }
    final writer = setup1.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
    await writer.drainForTesting();
    setup1.um.store.dispose();

    final setup2 = await startDbStore(
      existingGlobal: setup1.global,
      snap: snap,
    );
    async.elapse(Duration.zero);
    final store2 = setup2.um.store;
    final writer2 = setup1.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
    try {
      final writeGate = Completer<void>();
      writer2.debugBeforeWrite = () => writeGate.future;
      final batchFuture = store2.handleEventBatch([
        DeleteMessageEvent(
          id: 11,
          messageIds: [10],
          messageType: MessageType.stream,
          streamId: stream.streamId,
          topic: eg.t('tA'),
        ),
        eg.updateMessageEditEvent(
          mEdit,
          renderedContent: '<p>new edited</p>',
          editTimestamp: 999,
        ),
        eg.updateMessageEventMoveFrom(
          origMessages: [mMoveOut],
          newTopicStr: 'tOther',
        ),
        eg.updateMessageEventMoveFrom(
          origMessages: [mMoveIn],
          newTopicStr: 'tA',
        ),
      ], lastEventId: null);

      final window = await store2.localWindowAsync(
        TopicNarrow(stream.streamId, eg.t('tA')),
        AnchorCode.newest,
        100,
        100,
        afterFailure: true,
      );
      check(window).isNotNull();
      check(window!.messages.map((m) => m.id).toList()).deepEquals([20, 25]);
      check(window.messages.first.content).equals('<p>new edited</p>');

      writeGate.complete();
      writer2.debugBeforeWrite = null;
      await batchFuture;
      store2.dispose();
    } finally {
      writer2.debugBeforeWrite = null;
      await setup1.global.backend.closeMessageDb();
      setup1.global.dispose();
      UpdateMachine.debugEnableFetchEmojiData = true;
    }
  }));

  test('section 5.5 read/starred overlays (including oldUnreadsMissing & 10k starred cap)', () => awaitFakeAsync((async) async {
    UpdateMachine.debugEnableFetchEmojiData = false;
    final stream = eg.stream(streamId: 10, name: 'General');

    final snap1 = eg.initialSnapshot(
      queueId: 'q1',
      lastEventId: 10,
      maxMessageId: 25000,
      realmUsers: [eg.selfUser, eg.otherUser, eg.thirdUser],
      streams: [stream],
      subscriptions: [eg.subscription(stream)],
    );
    final setup1 = await startDbStore(snap: snap1);
    async.elapse(Duration.zero);

    final mStreamOld = eg.streamMessage(
      id: 10,
      stream: stream,
      topic: 't1',
      sender: eg.selfUser,
      flags: const [],
    );
    final mStreamAboveCap = eg.streamMessage(
      id: 20000,
      stream: stream,
      topic: 't1',
      sender: eg.selfUser,
      flags: const [MessageFlag.read, MessageFlag.starred],
    );

    final tStream = setup1.um.store.openFetchTicket(channelId: stream.streamId);
    try {
      setup1.um.store.reconcileMessages(
        [mStreamOld, mStreamAboveCap],
        rawMessages: [
          for (final m in [mStreamOld, mStreamAboveCap])
            jsonDecode(jsonEncode(m)) as Map<String, dynamic>,
        ],
        ticket: tStream,
        coverageRequest: FetchCoverageRequest(
          narrow: TopicNarrow.ofMessage(mStreamOld),
          numBefore: 100,
          numAfter: 100,
          includeAnchor: true,
          foundOldest: true,
          foundNewest: true,
          historyLimited: false,
          resolvedAnchor: 10,
        ),
      );
    } finally {
      setup1.um.store.closeFetchTicket(tStream);
    }
    await setup1.global.backend
      .messageDbWriterForAccount(eg.selfAccount.id)
      .drainForTesting();
    setup1.um.store.dispose();

    final cappedStarred = [for (int i = 5001; i <= 15000; i++) i];
    final snap2 = eg.initialSnapshot(
      queueId: 'q2',
      lastEventId: 10,
      maxMessageId: 25000,
      realmUsers: [eg.selfUser, eg.otherUser, eg.thirdUser],
      streams: [stream],
      subscriptions: [eg.subscription(stream)],
      starredMessages: cappedStarred,
      unreadMsgs: UnreadMessagesSnapshot(
        count: 0,
        channels: const [],
        dms: const [],
        huddles: const [],
        mentions: const [],
        oldUnreadsMissing: false,
      ),
    );
    final setup2 = await startDbStore(
      existingGlobal: setup1.global,
      snap: snap2,
    );
    async.elapse(Duration.zero);
    final store2 = setup2.um.store;
    try {
      final streamWin = await store2.localWindowAsync(
        TopicNarrow.ofMessage(mStreamOld),
        AnchorCode.newest,
        100,
        100,
        afterFailure: true,
      );
      check(streamWin).isNotNull();
      final loadedOld = streamWin!.messages.first;
      final loadedAboveCap = streamWin.messages.last;
      check(loadedOld.flags).contains(MessageFlag.read);
      check(loadedAboveCap.flags).contains(MessageFlag.starred);

      store2.dispose();
    } finally {
      await setup1.global.backend.closeMessageDb();
      setup1.global.dispose();
      UpdateMachine.debugEnableFetchEmojiData = true;
    }
  }));

  test('C13 DM gap bridge: listed DM conversation bridges to epoch dms; unlisted does not', () => awaitFakeAsync((async) async {
    UpdateMachine.debugEnableFetchEmojiData = false;
    final dmListed = DmNarrow(
      allRecipientIds: [eg.selfUser.userId, eg.otherUser.userId],
      selfUserId: eg.selfUser.userId,
    );
    final dmUnlisted = DmNarrow(
      allRecipientIds: [eg.selfUser.userId, eg.thirdUser.userId],
      selfUserId: eg.selfUser.userId,
    );

    final snap1 = eg.initialSnapshot(
      queueId: 'q1',
      lastEventId: 10,
      maxMessageId: 100,
      realmUsers: [eg.selfUser, eg.otherUser, eg.thirdUser],
    );
    final setup1 = await startDbStore(snap: snap1);
    async.elapse(Duration.zero);

    final mListedDm = eg.dmMessage(id: 50, from: eg.otherUser, to: [eg.selfUser]);
    final mUnlistedDm = eg.dmMessage(id: 60, from: eg.thirdUser, to: [eg.selfUser]);

    final tDm = setup1.um.store.openFetchTicket(channelId: null);
    try {
      setup1.um.store.reconcileMessages(
        [mListedDm],
        rawMessages: [jsonDecode(jsonEncode(mListedDm)) as Map<String, dynamic>],
        ticket: tDm,
        coverageRequest: FetchCoverageRequest(
          narrow: dmListed,
          numBefore: 100,
          numAfter: 100,
          includeAnchor: true,
          foundOldest: true,
          foundNewest: true,
          historyLimited: false,
          resolvedAnchor: 50,
        ),
      );
      setup1.um.store.reconcileMessages(
        [mUnlistedDm],
        rawMessages: [jsonDecode(jsonEncode(mUnlistedDm)) as Map<String, dynamic>],
        ticket: tDm,
        coverageRequest: FetchCoverageRequest(
          narrow: dmUnlisted,
          numBefore: 100,
          numAfter: 100,
          includeAnchor: true,
          foundOldest: true,
          foundNewest: true,
          historyLimited: false,
          resolvedAnchor: 60,
        ),
      );
    } finally {
      setup1.um.store.closeFetchTicket(tDm);
    }
    await setup1.global.backend
      .messageDbWriterForAccount(eg.selfAccount.id)
      .drainForTesting();
    setup1.um.store.dispose();

    final snap2 = eg.initialSnapshot(
      queueId: 'q2',
      lastEventId: 10,
      maxMessageId: 200,
      realmUsers: [eg.selfUser, eg.otherUser, eg.thirdUser],
      recentPrivateConversations: [
        RecentDmConversation(userIds: [eg.otherUser.userId], maxMessageId: 50),
      ],
    );
    final setup2 = await startDbStore(
      existingGlobal: setup1.global,
      snap: snap2,
    );
    async.elapse(Duration.zero);
    final store2 = setup2.um.store;
    try {
      final listedWin = await store2.localWindowAsync(
        dmListed,
        AnchorCode.newest,
        100,
        100,
        afterFailure: true,
      );
      check(listedWin).isNotNull();
      check(listedWin!.haveNewest).isTrue();

      final unlistedWin = await store2.localWindowAsync(
        dmUnlisted,
        AnchorCode.newest,
        100,
        100,
        afterFailure: true,
      );
      check(unlistedWin).isNotNull();
      check(unlistedWin!.haveNewest).isFalse();

      store2.dispose();
    } finally {
      await setup1.global.backend.closeMessageDb();
      setup1.global.dispose();
      UpdateMachine.debugEnableFetchEmojiData = true;
    }
  }));
}
