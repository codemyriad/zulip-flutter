import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:test/scaffolding.dart';
import 'package:zulip/api/model/events.dart';
import 'package:zulip/api/model/initial_snapshot.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/api/model/submessage.dart';
import 'package:zulip/model/message.dart';
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
    required InitialSnapshot snap,
  }) async {
    final global = eg.globalStore();
    await global.settings.setBool(BoolGlobalSetting.messageDatabase, true);
    await global.insertAccount(eg.selfAccount.toCompanion(false));
    final conn = global.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
    global.useCachedApiConnections = true;
    conn.prepare(json: snapshotToJson(snap));
    conn.prepare(json: {
      'result': 'success',
      'msg': '',
      'events': <Object>[],
      'queue_id': snap.queueId ?? 'q1',
    });
    final um = await UpdateMachine.load(global, eg.selfAccount.id, allowPersisted: false);
    um.debugPauseLoop();
    return (global: global, um: um, conn: conn);
  }

  test('fetch writes messages, reactions, polls, coverage, and byte count', () => awaitFakeAsync((async) async {
    UpdateMachine.debugEnableFetchEmojiData = false;
    final stream = eg.stream(streamId: 10, name: 'General');
    final snap = eg.initialSnapshot(
      queueId: 'q1',
      lastEventId: 10,
      maxMessageId: 200,
      realmUsers: [eg.selfUser, eg.otherUser],
      streams: [stream],
      subscriptions: [eg.subscription(stream)],
    );
    final setup = await startDbStore(snap: snap);
    async.elapse(Duration.zero);
    try {
      final store = setup.um.store;
      final writer = setup.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      check(store.dbActive).isTrue();

      final msg1 = eg.streamMessage(
        id: 100,
        stream: stream,
        topic: 'topicA',
        sender: eg.selfUser,
        content: '<p>hello 100</p>',
        reactions: [Reaction(emojiName: 'tada', emojiCode: '1f389', reactionType: ReactionType.unicodeEmoji, userId: eg.selfUser.userId)],
        submessages: [
          Submessage(
            id: 1,
            senderId: eg.selfUser.userId,
            msgType: SubmessageType.widget,
            content: jsonEncode(PollWidgetData(
              extraData: PollWidgetExtraData(question: 'Q?', options: ['A', 'B']),
            ).toJson()),
          ),
        ],
      );
      final msg2 = eg.dmMessage(
        id: 110,
        from: eg.otherUser,
        to: [eg.selfUser],
        content: '<p>dm 110</p>',
      );
      final raw1 = jsonDecode(jsonEncode(msg1)) as Map<String, dynamic>;
      final raw2 = jsonDecode(jsonEncode(msg2)) as Map<String, dynamic>;

      final ticket = store.openFetchTicket(channelId: stream.streamId);
      try {
        store.reconcileMessages(
          [msg1],
          rawMessages: [raw1],
          ticket: ticket,
          coverageRequest: FetchCoverageRequest(
            narrow: TopicNarrow.ofMessage(msg1),
            numBefore: 20,
            numAfter: 20,
            includeAnchor: true,
            foundOldest: true,
            foundNewest: true,
            historyLimited: false,
            resolvedAnchor: 100,
          ),
        );
      } finally {
        store.closeFetchTicket(ticket);
      }
      store.reconcileMessages([msg2], rawMessages: [raw2]);
      await writer.drainForTesting();

      final db = setup.global.backend.debugMessageDatabase!;
      final rows = await (db.select(db.storedMessages)
            ..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .get();
      check(rows.map((r) => r.id).toList()).deepEquals([100, 110]);
      check(rows[0].epoch).equals(1);
      check(rows[0].tracked).isTrue();

      final reactions = await (db.select(db.storedReactions)).get();
      check(reactions.length).equals(1);
      check(reactions.single.messageId).equals(100);

      final subs = await (db.select(db.storedSubmessages)).get();
      check(subs.length).equals(1);
      check(subs.single.messageId).equals(100);

      final acct = await (db.select(db.messageDbAccounts)
            ..where((a) => a.accountId.equals(eg.selfAccount.id)))
          .getSingle();
      final sumBytes = rows.fold<int>(0, (s, r) => s + r.bodyBytes);
      check(acct.totalBodyBytes).equals(sumBytes);

      final loaded = await db.loadAccountStateInTxn(eg.selfAccount.id);
      check(loaded).isNotNull();
      final topicKey = coverageKey(TopicNarrow.ofMessage(msg1))!;
      check(loaded!.intervalsByKey[topicKey]).isNotNull();
      check(loaded.intervalsByKey[topicKey]!.single.lo).equals(0);
      check(loaded.intervalsByKey[topicKey]!.single.hi).isNull();
    } finally {
      setup.um.store.dispose();
      await setup.global.backend.closeMessageDb();
      setup.global.dispose();
      UpdateMachine.debugEnableFetchEmojiData = true;
    }
  }));

  test('absent-in-range DB-only row is forgotten, punctured, and deleted', () => awaitFakeAsync((async) async {
    UpdateMachine.debugEnableFetchEmojiData = false;
    final stream = eg.stream(streamId: 10, name: 'General');
    final snap1 = eg.initialSnapshot(
      queueId: 'q1',
      lastEventId: 10,
      maxMessageId: 200,
      realmUsers: [eg.selfUser, eg.otherUser],
      streams: [stream],
      subscriptions: [eg.subscription(stream)],
    );
    final setup1 = await startDbStore(snap: snap1);
    async.elapse(Duration.zero);
    try {
      // Seed messages 100 and 105 in epoch 1 (105 will later disappear server-side).
      final msg100 = eg.streamMessage(id: 100, stream: stream, topic: 't1', content: '<p>100</p>');
      final msg105 = eg.streamMessage(id: 105, stream: stream, topic: 't1', content: '<p>105</p>');
      final t1 = setup1.um.store.openFetchTicket(channelId: stream.streamId);
      try {
        setup1.um.store.reconcileMessages(
          [msg100, msg105],
          rawMessages: [
            jsonDecode(jsonEncode(msg100)) as Map<String, dynamic>,
            jsonDecode(jsonEncode(msg105)) as Map<String, dynamic>,
          ],
          ticket: t1,
          coverageRequest: FetchCoverageRequest(
            narrow: TopicNarrow.ofMessage(msg100),
            numBefore: 20,
            numAfter: 20,
            includeAnchor: true,
            foundOldest: true,
            foundNewest: true,
            historyLimited: false,
            resolvedAnchor: 105,
          ),
        );
      } finally {
        setup1.um.store.closeFetchTicket(t1);
      }
      final writer = setup1.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer.drainForTesting();
      setup1.um.store.dispose();

      // Restart via persisted state with empty RAM so 100 and 105 are DB-only.
      setup1.global.backend.seedServerData(
        eg.selfAccount.id,
        snapshotJson: snapshotToJson(snap1),
        lastEventId: 10,
      );
      setup1.global.clearCachedApiConnections();
      final conn2 = setup1.global.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
      conn2.prepare(
        delay: const Duration(milliseconds: 50),
        json: {'result': 'success', 'msg': '', 'events': <Object>[], 'queue_id': 'q1'},
      );
      final um2 = await UpdateMachine.load(setup1.global, eg.selfAccount.id, allowPersisted: true);
      um2.debugPauseLoop();
      async.elapse(const Duration(milliseconds: 50));
      async.flushMicrotasks();
      try {
        check(um2.store.messages).isEmpty();
        final msg100b = eg.streamMessage(id: 100, stream: stream, topic: 't1', content: '<p>100</p>');
        final msg110 = eg.streamMessage(id: 110, stream: stream, topic: 't1', content: '<p>110</p>');
        final t2 = um2.store.openFetchTicket(channelId: stream.streamId);
        try {
          um2.store.reconcileMessages(
            [msg100b, msg110],
            rawMessages: [
              jsonDecode(jsonEncode(msg100b)) as Map<String, dynamic>,
              jsonDecode(jsonEncode(msg110)) as Map<String, dynamic>,
            ],
            ticket: t2,
            coverageRequest: FetchCoverageRequest(
              narrow: TopicNarrow.ofMessage(msg100b),
              numBefore: 20,
              numAfter: 20,
              includeAnchor: true,
              foundOldest: true,
              foundNewest: true,
              historyLimited: false,
              resolvedAnchor: 110,
            ),
          );
        } finally {
          um2.store.closeFetchTicket(t2);
        }
        await writer.drainForTesting();

        final db = setup1.global.backend.debugMessageDatabase!;
        final rows = await (db.select(db.storedMessages)
              ..orderBy([(t) => OrderingTerm.asc(t.id)]))
            .get();
        // DB-only absent row 105 was forgotten and deleted.
        check(rows.map((r) => r.id).toList()).deepEquals([100, 110]);
        final acct = await (db.select(db.messageDbAccounts)
              ..where((a) => a.accountId.equals(eg.selfAccount.id)))
            .getSingle();
        check(acct.totalBodyBytes).equals(rows.fold<int>(0, (s, r) => s + r.bodyBytes));
      } finally {
        if (!um2.store.disposed) um2.store.dispose();
      }
    } finally {
      await setup1.global.backend.closeMessageDb();
      setup1.global.dispose();
      UpdateMachine.debugEnableFetchEmojiData = true;
    }
  }));

  test('unchanged clobber skips rewriting bodies while updating epoch and tracked', () => awaitFakeAsync((async) async {
    UpdateMachine.debugEnableFetchEmojiData = false;
    final stream = eg.stream(streamId: 10, name: 'General');
    final snap = eg.initialSnapshot(
      queueId: 'q1',
      lastEventId: 10,
      maxMessageId: 200,
      realmUsers: [eg.selfUser],
      streams: [stream],
      // Unsubscribed initially -> tracked: false and _maybeStaleMessages has msg 100.
      subscriptions: const [],
    );
    final setup = await startDbStore(snap: snap);
    async.elapse(Duration.zero);
    try {
      final store = setup.um.store;
      final writer = setup.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      final msg1 = eg.streamMessage(
        id: 100,
        stream: stream,
        topic: 't1',
        content: '<p>same</p>',
        sender: eg.selfUser,
      );
      final raw1 = jsonDecode(jsonEncode(msg1)) as Map<String, dynamic>;
      store.reconcileMessages([msg1], rawMessages: [raw1]);
      await writer.drainForTesting();

      final db = setup.global.backend.debugMessageDatabase!;
      final beforeRow = await (db.select(db.storedMessages)
            ..where((t) => t.id.equals(100)))
          .getSingle();
      check(beforeRow.tracked).isFalse();

      // Add subscription so the next fetch wants tracked = true, AND install
      // a SQLite trigger asserting stored_message_bodies is NOT re-inserted.
      await db.customStatement(
        "CREATE TRIGGER test_no_body_rewrite "
        "BEFORE INSERT ON stored_message_bodies "
        "WHEN NEW.message_id = 100 "
        "BEGIN SELECT RAISE(ABORT, 'body unexpectedly rewritten'); END;",
      );
      await store.handleEventBatch([
        SubscriptionAddEvent(id: 11, subscriptions: [eg.subscription(stream)]),
      ], lastEventId: null);

      final msg1Again = eg.streamMessage(
        id: 100,
        stream: stream,
        topic: 't1',
        content: '<p>same</p>',
        sender: eg.selfUser,
        timestamp: msg1.timestamp,
      );
      store.reconcileMessages(
        [msg1Again],
        rawMessages: [jsonDecode(jsonEncode(msg1Again)) as Map<String, dynamic>],
      );
      await writer.drainForTesting();

      check(store.dbActive).isTrue();
      final afterRow = await (db.select(db.storedMessages)
            ..where((t) => t.id.equals(100)))
          .getSingle();
      check(afterRow.tracked).isTrue();
    } finally {
      setup.um.store.dispose();
      await setup.global.backend.closeMessageDb();
      setup.global.dispose();
      UpdateMachine.debugEnableFetchEmojiData = true;
    }
  }));

  test('race catchup, evicted floor, epoch mismatch (C5), and ticket overflow', () => awaitFakeAsync((async) async {
    UpdateMachine.debugEnableFetchEmojiData = false;
    final stream = eg.stream(streamId: 10, name: 'General');
    final snap = eg.initialSnapshot(
      queueId: 'q1',
      lastEventId: 10,
      maxMessageId: 200,
      realmUsers: [eg.selfUser, eg.otherUser],
      streams: [stream],
      subscriptions: [eg.subscription(stream)],
    );
    final setup = await startDbStore(snap: snap);
    async.elapse(Duration.zero);
    try {
      final store = setup.um.store;
      final writer = setup.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      final db = setup.global.backend.debugMessageDatabase!;

      // Set eviction floor at 50; msg 40 must NOT be persisted.
      store.debugCoverage.clipBelow(50);

      final ticket = store.openFetchTicket(channelId: stream.streamId);
      // Concurrent delete (of 60) and reaction (on 70) happen while fetch is in flight.
      await store.handleEventBatch([
        DeleteMessageEvent(
          id: 11,
          messageIds: [60],
          messageType: MessageType.stream,
          streamId: stream.streamId,
          topic: eg.t('t1'),
        ),
        ReactionEvent(
          id: 12,
          op: ReactionOp.add,
          messageId: 70,
          emojiName: 'smile',
          emojiCode: '1f604',
          reactionType: ReactionType.unicodeEmoji,
          userId: eg.otherUser.userId,
        ),
      ], lastEventId: null);

      final m40 = eg.streamMessage(id: 40, stream: stream, topic: 't1');
      final m60 = eg.streamMessage(id: 60, stream: stream, topic: 't1');
      final m70 = eg.streamMessage(id: 70, stream: stream, topic: 't1');
      try {
        store.reconcileMessages(
          [m40, m60, m70],
          rawMessages: [
            jsonDecode(jsonEncode(m40)) as Map<String, dynamic>,
            jsonDecode(jsonEncode(m60)) as Map<String, dynamic>,
            jsonDecode(jsonEncode(m70)) as Map<String, dynamic>,
          ],
          ticket: ticket,
          coverageRequest: FetchCoverageRequest(
            narrow: TopicNarrow.ofMessage(m70),
            numBefore: 20,
            numAfter: 20,
            includeAnchor: true,
            foundOldest: true,
            foundNewest: true,
            historyLimited: false,
            resolvedAnchor: 70,
          ),
        );
      } finally {
        store.closeFetchTicket(ticket);
      }
      await writer.drainForTesting();

      final rows = await (db.select(db.storedMessages)).get();
      // Only m70 survived: m40 was below evictedBelow (50), m60 was deleted in flight.
      check(rows.map((r) => r.id).toList()).deepEquals([70]);
      final reactions = await (db.select(db.storedReactions)).get();
      check(reactions.single.messageId).equals(70);
      check(reactions.single.emojiCode).equals('1f604');

      // C5 epoch mismatch: ticket opened in epoch 1, then epoch bumps -> fetch write dropped.
      final staleTicket = store.openFetchTicket(channelId: stream.streamId);
      store.debugCoverage.beginEpoch(maxMessageId: 200, lastLiveAt: 0, now: 100);
      final m80 = eg.streamMessage(id: 80, stream: stream, topic: 't2');
      try {
        store.reconcileMessages(
          [m80],
          rawMessages: [jsonDecode(jsonEncode(m80)) as Map<String, dynamic>],
          ticket: staleTicket,
        );
      } finally {
        store.closeFetchTicket(staleTicket);
      }
      await writer.drainForTesting();
      final afterC5 = await (db.select(db.storedMessages)).get();
      check(afterC5.map((r) => r.id).toList()).deepEquals([70]);
    } finally {
      setup.um.store.dispose();
      await setup.global.backend.closeMessageDb();
      setup.global.dispose();
      UpdateMachine.debugEnableFetchEmojiData = true;
    }
  }));
}
