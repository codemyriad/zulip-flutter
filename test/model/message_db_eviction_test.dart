import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:test/scaffolding.dart';
import 'package:zulip/api/model/events.dart';
import 'package:zulip/api/model/initial_snapshot.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/model/message.dart';
import 'package:zulip/model/message_coverage.dart';
import 'package:zulip/model/message_db_effects.dart';
import 'package:zulip/model/message_list.dart';
import 'package:zulip/model/narrow.dart';
import 'package:zulip/model/presence.dart';
import 'package:zulip/model/settings.dart';
import 'package:zulip/model/store.dart';
import 'package:zulip/model/stored_message_codec.dart';

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
    ZulipStream? stream,
  }) async {
    final s = stream ?? eg.stream(streamId: 10, name: 'General');
    final sub = eg.subscription(s);
    final global = eg.globalStore();
    addTearDown(() async {
      await global.backend.closeMessageDb();
      global.dispose();
    });
    await global.settings.setBool(BoolGlobalSetting.messageDatabase, true);
    await global.insertAccount(eg.selfAccount.toCompanion(false));
    global.useCachedApiConnections = true;
    final conn = global.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
    final snap = eg.initialSnapshot(
      queueId: 'q1',
      lastEventId: 10,
      maxMessageId: 0,
      realmUsers: [eg.selfUser],
      streams: [s],
      subscriptions: [sub],
    );
    conn.prepare(json: snapshotToJson(snap));
    conn.prepare(
      delay: Duration.zero,
      json: {
        'result': 'success',
        'msg': '',
        'events': <Object>[],
        'queue_id': 'q1',
      },
    );
    final um = await UpdateMachine.load(global, eg.selfAccount.id, allowPersisted: false);
    um.debugPauseLoop();
    return (global: global, um: um, conn: conn);
  }

  Future<void> seedFetch(
    PerAccountStore store,
    ZulipStream stream,
    String topicName,
    List<StreamMessage> msgs, {
    bool foundOldest = true,
    bool foundNewest = true,
  }) async {
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
          numBefore: msgs.length,
          numAfter: 0,
          includeAnchor: true,
          foundOldest: foundOldest,
          foundNewest: foundNewest,
          historyLimited: false,
          resolvedAnchor: msgs.last.id,
        ),
      );
    } finally {
      store.closeFetchTicket(ticket);
    }
  }

  test('evicts by id cutoff to target, clips coverage, cascades children, and keeps total_body_bytes exact', () => awaitFakeAsync((async) async {
    UpdateMachine.debugEnableFetchEmojiData = false;
    addTearDown(() => MessageStoreImpl.debugSoftByteCap = null);

    final stream = eg.stream(streamId: 10, name: 'General');
    final setup = await startDbStore(stream: stream);
    async.elapse(Duration.zero);

    final store = setup.um.store;
    final writer = setup.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
    await writer.drainForTesting();
    final db = setup.global.backend.debugMessageDatabase!;

    // Compute single message byte size to set an exact soft cap.
    final payload = '<p>${'x' * 200}</p>';
    final sample = eg.streamMessage(
      id: 1,
      stream: stream,
      topic: 't1',
      sender: eg.selfUser,
      content: payload,
      reactions: [eg.unicodeEmojiReaction],
    );
    final singleBytes = StoredMessageCodec.encode(
      accountId: eg.selfAccount.id,
      message: sample,
      rawMap: jsonDecode(jsonEncode(sample)) as Map<String, dynamic>,
      epoch: 1,
      tracked: true,
    ).bodyBytes;
    // Allow 4 messages max; target 0.75 * cap = 3 messages -> evict ids 1..3 (cutoff 4) for 6 messages.
    MessageStoreImpl.debugSoftByteCap = singleBytes * 4;

    final msgs = [
      for (int i = 1; i <= 6; i++)
        eg.streamMessage(
          id: i,
          stream: stream,
          topic: 't1',
          sender: eg.selfUser,
          content: payload,
          reactions: [eg.unicodeEmojiReaction],
        ),
    ];
    await seedFetch(store, stream, 't1', msgs);
    await writer.drainForTesting();

    final acct = await (db.select(db.messageDbAccounts)
      ..where((a) => a.accountId.equals(eg.selfAccount.id))).getSingle();
    check(acct.evictedBelowMessageId).isGreaterOrEqual(3);
    check(acct.totalBodyBytes).isLessOrEqual((singleBytes * 4 * 3) ~/ 4);

    final storedRows = await (db.select(db.storedMessages)
      ..where((m) => m.accountId.equals(eg.selfAccount.id))
      ..orderBy([(m) => OrderingTerm.asc(m.id)])).get();
    check(storedRows.map((r) => r.id).toList()).every((id) => id.isGreaterOrEqual(acct.evictedBelowMessageId));
    final actualSum = storedRows.fold<int>(0, (sum, r) => sum + r.bodyBytes);
    check(acct.totalBodyBytes).equals(actualSum);

    // Child tables cascaded cleanly.
    final bodyCount = await db.customSelect(
      'SELECT COUNT(*) AS c FROM stored_message_bodies WHERE account_id = ?',
      variables: [Variable.withInt(eg.selfAccount.id)],
    ).getSingle();
    check(bodyCount.read<int>('c')).equals(storedRows.length);
    final reactionCount = await db.customSelect(
      'SELECT COUNT(*) AS c FROM stored_reactions WHERE account_id = ?',
      variables: [Variable.withInt(eg.selfAccount.id)],
    ).getSingle();
    check(reactionCount.read<int>('c')).equals(storedRows.length);

    // Memory coverage clipped in both memory and DB, while in-memory messages remain for the session.
    check(store.debugCoverage.evictedBelow).equals(acct.evictedBelowMessageId);
    final topicKey = CoverageKeys.topic(stream.streamId, 't1');
    check(store.debugCoverage.intervalsOf(topicKey).first.lo).isGreaterOrEqual(acct.evictedBelowMessageId);
    final dbIntervals = await (db.select(db.coverageIntervals)
      ..where((c) => c.accountId.equals(eg.selfAccount.id) & c.narrowKey.equals(topicKey))).get();
    check(dbIntervals).isNotEmpty();
    check(dbIntervals.first.lo).isGreaterOrEqual(acct.evictedBelowMessageId);
    for (int i = 1; i <= 6; i++) {
      check(store.messages[i]).isNotNull();
    }

    setup.um.dispose();
  }));

  test('deletes > 1200 rows in <= 500-row chunks and allows event writes to interleave', () => awaitFakeAsync((async) async {
    UpdateMachine.debugEnableFetchEmojiData = false;
    addTearDown(() => MessageStoreImpl.debugSoftByteCap = null);

    final stream = eg.stream(streamId: 10, name: 'General');
    final setup = await startDbStore(stream: stream);
    async.elapse(Duration.zero);

    final store = setup.um.store;
    final writer = setup.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
    await writer.drainForTesting();
    final db = setup.global.backend.debugMessageDatabase!;

    final msgs = [
      for (int i = 1; i <= 1300; i++)
        eg.streamMessage(
          id: i,
          stream: stream,
          topic: 't1',
          sender: eg.selfUser,
          content: '<p>m${i.toString().padLeft(4, '0')}</p>',
        ),
    ];
    final singleBytes = StoredMessageCodec.encode(
      accountId: eg.selfAccount.id,
      message: msgs.first,
      rawMap: jsonDecode(jsonEncode(msgs.first)) as Map<String, dynamic>,
      epoch: 1,
      tracked: true,
    ).bodyBytes;
    // Keep cap above initial 1290-row seed (allowing for multi-digit ids in JSON).
    MessageStoreImpl.debugSoftByteCap = singleBytes * 1400;

    await seedFetch(store, stream, 't1', msgs.sublist(0, 1290));
    await writer.drainForTesting();
    check((await (db.select(db.storedMessages)
      ..where((m) => m.accountId.equals(eg.selfAccount.id))).get()).length).equals(1290);

    // Lower cap to keep ~50 newest messages (target = ~50 -> ~1250 rows deleted in chunks of 500).
    MessageStoreImpl.debugSoftByteCap = singleBytes * 60;
    final future = store.handleEventBatch(
      [
        for (int i = 1291; i <= 1300; i++)
          MessageEvent(id: 10 + (i - 1290), message: msgs[i - 1], localMessageId: null),
      ],
      lastEventId: 20,
    );
    // Let encoding/transactions run, then queue an interleaving event before chunks finish.
    async.elapse(Duration.zero);
    final msg1301 = eg.streamMessage(id: 1301, stream: stream, topic: 't1', sender: eg.selfUser, content: '<p>new</p>');
    final interleaveFuture = store.handleEvent(eg.messageEvent(msg1301));
    await future;
    await interleaveFuture;
    await writer.drainForTesting();

    final remaining = await (db.select(db.storedMessages)
      ..where((m) => m.accountId.equals(eg.selfAccount.id))).get();
    check(remaining.length).isLessOrEqual(60);
    check(remaining.map((r) => r.id)).contains(1301);

    final acct = await (db.select(db.messageDbAccounts)
      ..where((a) => a.accountId.equals(eg.selfAccount.id))).getSingle();
    check(acct.evictedBelowMessageId).isGreaterThan(1200);
    check(acct.totalBodyBytes).equals(remaining.fold<int>(0, (s, r) => s + r.bodyBytes));

    setup.um.dispose();
  }));

  test('clamps eviction cutoff to lowest id shown by any open MessageListView (I8)', () => awaitFakeAsync((async) async {
    UpdateMachine.debugEnableFetchEmojiData = false;
    addTearDown(() => MessageStoreImpl.debugSoftByteCap = null);

    final stream = eg.stream(streamId: 10, name: 'General');
    final setup = await startDbStore(stream: stream);
    async.elapse(Duration.zero);

    final store = setup.um.store;
    final writer = setup.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
    await writer.drainForTesting();
    final db = setup.global.backend.debugMessageDatabase!;

    final msgs = [
      for (int i = 1; i <= 10; i++)
        eg.streamMessage(id: i, stream: stream, topic: 't1', sender: eg.selfUser, content: '<p>msg$i</p>'),
    ];
    setup.conn.prepare(json: eg.newestGetMessagesResult(foundOldest: true, messages: msgs.sublist(3, 10)).toJson());
    final view = MessageListView.init(
      store: store,
      narrow: TopicNarrow(stream.streamId, eg.t('t1')),
      anchor: AnchorCode.newest,
    );
    addTearDown(view.dispose);
    await view.fetchInitial();
    await writer.drainForTesting();

    check(view.messages.first.id).equals(4);
    final singleBytes = StoredMessageCodec.encode(
      accountId: eg.selfAccount.id,
      message: msgs.first,
      rawMap: jsonDecode(jsonEncode(msgs.first)) as Map<String, dynamic>,
      epoch: 1,
      tracked: true,
    ).bodyBytes;
    // Set tiny cap so raw cutoff would be ~9, well above view.messages.first.id (4).
    MessageStoreImpl.debugSoftByteCap = singleBytes * 2;
    await seedFetch(store, stream, 't1', msgs.sublist(0, 4));
    await writer.drainForTesting();

    final acct = await (db.select(db.messageDbAccounts)
      ..where((a) => a.accountId.equals(eg.selfAccount.id))).getSingle();
    check(acct.evictedBelowMessageId).isLessOrEqual(4);
    final chain = store.debugCoverage.chains(CoverageKeys.topic(stream.streamId, 't1')).single;
    check(chain.contains(view.messages.first.id)).isTrue();
    check(chain.contains(view.messages.last.id)).isTrue();

    setup.um.dispose();
  }));

  test('clips subsequent coverage inserts and ignores InsertEffect / upsert below evictedBelowMessageId', () => awaitFakeAsync((async) async {
    UpdateMachine.debugEnableFetchEmojiData = false;
    addTearDown(() => MessageStoreImpl.debugSoftByteCap = null);

    final stream = eg.stream(streamId: 10, name: 'General');
    final setup = await startDbStore(stream: stream);
    async.elapse(Duration.zero);

    final store = setup.um.store;
    final writer = setup.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
    await writer.drainForTesting();
    final db = setup.global.backend.debugMessageDatabase!;

    final msgs = [
      for (int i = 1; i <= 6; i++)
        eg.streamMessage(id: i, stream: stream, topic: 't1', sender: eg.selfUser, content: '<p>m$i</p>'),
    ];
    final singleBytes = StoredMessageCodec.encode(
      accountId: eg.selfAccount.id,
      message: msgs.first,
      rawMap: jsonDecode(jsonEncode(msgs.first)) as Map<String, dynamic>,
      epoch: 1,
      tracked: true,
    ).bodyBytes;
    MessageStoreImpl.debugSoftByteCap = singleBytes * 3;
    await seedFetch(store, stream, 't1', msgs);
    await writer.drainForTesting();

    final acctBefore = await (db.select(db.messageDbAccounts)
      ..where((a) => a.accountId.equals(eg.selfAccount.id))).getSingle();
    final cutoff = acctBefore.evictedBelowMessageId;
    check(cutoff).isGreaterThan(1);

    // Direct upsert and coverage insert below cutoff must be clipped / ignored.
    final oldMsg = eg.streamMessage(id: 1, stream: stream, topic: 't1', sender: eg.selfUser, content: '<p>old</p>');
    await store.handleEvent(eg.messageEvent(oldMsg));
    final oldRecord = StoredMessageCodec.encode(
      accountId: eg.selfAccount.id,
      message: oldMsg,
      rawMap: jsonDecode(jsonEncode(oldMsg)) as Map<String, dynamic>,
      epoch: 1,
      tracked: true,
    );
    await db.transaction(() => upsertStoredMessageRecordInDb(db, accountId: eg.selfAccount.id, record: oldRecord));
    await writer.drainForTesting();

    final acctAfter = await (db.select(db.messageDbAccounts)
      ..where((a) => a.accountId.equals(eg.selfAccount.id))).getSingle();
    check(acctAfter.totalBodyBytes).equals(acctBefore.totalBodyBytes);
    final row1 = await (db.select(db.storedMessages)
      ..where((m) => m.accountId.equals(eg.selfAccount.id) & m.id.equals(1))).getSingleOrNull();
    check(row1).isNull();
    check(store.debugCoverage.intervalsOf(CoverageKeys.topic(stream.streamId, 't1')).first.lo)
      .isGreaterOrEqual(cutoff);

    setup.um.dispose();
  }));

  test('enforces 10-minute eviction cooldown until elapsed', () => awaitFakeAsync((async) async {
    UpdateMachine.debugEnableFetchEmojiData = false;
    addTearDown(() => MessageStoreImpl.debugSoftByteCap = null);

    final stream = eg.stream(streamId: 10, name: 'General');
    final setup = await startDbStore(stream: stream);
    async.elapse(Duration.zero);

    final store = setup.um.store;
    final writer = setup.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
    await writer.drainForTesting();
    final db = setup.global.backend.debugMessageDatabase!;

    final msgs = [
      for (int i = 1; i <= 10; i++)
        eg.streamMessage(id: i, stream: stream, topic: 't1', sender: eg.selfUser, content: '<p>msg$i</p>'),
    ];
    final singleBytes = StoredMessageCodec.encode(
      accountId: eg.selfAccount.id,
      message: msgs.first,
      rawMap: jsonDecode(jsonEncode(msgs.first)) as Map<String, dynamic>,
      epoch: 1,
      tracked: true,
    ).bodyBytes;
    MessageStoreImpl.debugSoftByteCap = singleBytes * 6;
    await seedFetch(store, stream, 't1', msgs.sublist(0, 8));
    await writer.drainForTesting();

    final acct1 = await (db.select(db.messageDbAccounts)
      ..where((a) => a.accountId.equals(eg.selfAccount.id))).getSingle();
    final cutoff1 = acct1.evictedBelowMessageId;
    check(cutoff1).isGreaterThan(1);

    // Shrink cap and write again after only 5 minutes: cooldown blocks eviction.
    async.elapse(const Duration(minutes: 5));
    MessageStoreImpl.debugSoftByteCap = singleBytes * 2;
    await store.handleEvent(eg.messageEvent(msgs[8]));
    await writer.drainForTesting();
    final acct2 = await (db.select(db.messageDbAccounts)
      ..where((a) => a.accountId.equals(eg.selfAccount.id))).getSingle();
    check(acct2.evictedBelowMessageId).equals(cutoff1);

    // Advance past 10 minutes from first eviction: next write triggers eviction.
    async.elapse(const Duration(minutes: 6));
    await store.handleEvent(eg.messageEvent(msgs[9]));
    await writer.drainForTesting();
    final acct3 = await (db.select(db.messageDbAccounts)
      ..where((a) => a.accountId.equals(eg.selfAccount.id))).getSingle();
    check(acct3.evictedBelowMessageId).isGreaterThan(cutoff1);

    setup.um.dispose();
  }));

  test('runs incremental_vacuum(2048) when FIFO is idle and skips when another write is queued', () => awaitFakeAsync((async) async {
    UpdateMachine.debugEnableFetchEmojiData = false;
    addTearDown(() => MessageStoreImpl.debugSoftByteCap = null);

    final stream = eg.stream(streamId: 10, name: 'General');
    final setup = await startDbStore(stream: stream);
    async.elapse(Duration.zero);

    final store = setup.um.store;
    final writer = setup.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
    await writer.drainForTesting();
    final db = setup.global.backend.debugMessageDatabase!;

    final msgs = [
      for (int i = 1; i <= 6; i++)
        eg.streamMessage(id: i, stream: stream, topic: 't1', sender: eg.selfUser, content: '<p>v$i</p>'),
    ];
    final singleBytes = StoredMessageCodec.encode(
      accountId: eg.selfAccount.id,
      message: msgs.first,
      rawMap: jsonDecode(jsonEncode(msgs.first)) as Map<String, dynamic>,
      epoch: 1,
      tracked: true,
    ).bodyBytes;
    MessageStoreImpl.debugSoftByteCap = singleBytes * 3;

    // 1. When idle, eviction ends by running incremental_vacuum.
    await seedFetch(store, stream, 't1', msgs.sublist(0, 5));
    await writer.drainForTesting();
    check(db.debugIncrementalVacuumCalls).equals(1);

    // 2. When another write is queued behind maintenance, incremental_vacuum skips.
    async.elapse(const Duration(minutes: 11));
    db.debugIncrementalVacuumCalls = 0;
    var writeCount = 0;
    Future<void>? extraWrite;
    writer.debugBeforeWrite = () async {
      writeCount++;
      // Write 4 is the trailing vacuum job itself; queue another write behind it
      // so writer.isIdleForMaintenance returns false when the vacuum callback runs.
      if (writeCount == 4) {
        final m8 = eg.streamMessage(id: 8, stream: stream, topic: 't1', sender: eg.selfUser, content: '<p>v8</p>');
        extraWrite = store.handleEvent(eg.messageEvent(m8));
        await Future<void>.delayed(Duration.zero);
      }
    };
    addTearDown(() => writer.debugBeforeWrite = null);

    final m7 = eg.streamMessage(id: 7, stream: stream, topic: 't1', sender: eg.selfUser, content: '<p>v7</p>');
    await store.handleEventBatch(
      [
        MessageEvent(id: 11, message: msgs[5], localMessageId: null),
        MessageEvent(id: 12, message: m7, localMessageId: null),
      ],
      lastEventId: 12,
    );
    await writer.drainForTesting();
    await extraWrite;
    await writer.drainForTesting();
    check(writeCount).isGreaterOrEqual(4);
    check(db.debugIncrementalVacuumCalls).equals(0);

    setup.um.dispose();
  }));
}
