import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:drift/drift.dart' as drift;
import 'package:test/scaffolding.dart';
import 'package:zulip/api/model/events.dart';
import 'package:zulip/api/model/initial_snapshot.dart';
import 'package:zulip/model/message_coverage.dart';
import 'package:zulip/model/message_database.dart';
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

  Future<({TestGlobalStore globalStore, FakeApiConnection connection})> prepareStore({
    Account? account,
  }) async {
    final globalStore = eg.globalStore();
    await globalStore.settings.setBool(BoolGlobalSetting.messageDatabase, true);
    account ??= eg.selfAccount;
    await globalStore.insertAccount(account.toCompanion(false));
    final connection = globalStore.apiConnectionFromAccount(account) as FakeApiConnection;
    globalStore.useCachedApiConnections = true;
    UpdateMachine.debugEnableFetchEmojiData = false;
    return (globalStore: globalStore, connection: connection);
  }

  Future<void> cleanupStore(TestGlobalStore globalStore, List<UpdateMachine> machines) async {
    for (final um in machines) {
      if (!um.store.disposed) {
        um.store.dispose();
      }
    }
    await globalStore.backend.closeMessageDb();
    globalStore.dispose();
    UpdateMachine.debugEnableFetchEmojiData = true;
  }

  Future<StoredMessage?> loadStoredRow(MessageDatabase db, int accountId, int id) {
    return (db.select(db.storedMessages)
          ..where((r) => r.accountId.equals(accountId) & r.id.equals(id)))
        .getSingleOrNull();
  }

  group('event batch atomic commit and fallback', () {
    test('poll commits inserts, updates, reactions, flags, deletes, watermark, coverage, and stage 1', () => awaitFakeAsync((async) async {
      final (:globalStore, :connection) = await prepareStore();
      final machines = <UpdateMachine>[];
      try {
        final stream = eg.stream(streamId: 10);
        final sub = eg.subscription(stream);
        final snap = eg.initialSnapshot(
          queueId: 'q1',
          lastEventId: 10,
          maxMessageId: 50,
          streams: [stream],
          subscriptions: [sub],
        );
        connection.prepare(json: snapshotToJson(snap));
        connection.prepare(json: {'result': 'success', 'msg': '', 'events': <Object>[], 'queue_id': 'q1'});
        final um = await UpdateMachine.load(globalStore, eg.selfAccount.id, allowPersisted: false);
        machines.add(um);
        um.debugPauseLoop();
        async.elapse(Duration.zero);
        check(um.store.dbActive).isTrue();

        final msg101 = eg.streamMessage(id: 101, stream: stream, topic: 'alpha', content: '<p>one</p>');
        final rawMsg101 = msg101.toJson()..remove('flags');
        final msg102 = eg.streamMessage(id: 102, stream: stream, topic: 'alpha', content: '<p>two</p>');
        final rawMsg102 = msg102.toJson()..remove('flags');
        final msg103 = eg.streamMessage(id: 103, stream: stream, topic: 'alpha', content: '<p>three</p>');
        final rawMsg103 = msg103.toJson()..remove('flags');

        connection.prepare(json: {
          'result': 'success',
          'msg': '',
          'events': [
            {
              'id': 11,
              'type': 'message',
              'message': rawMsg101,
              'flags': ['read'],
            },
            {
              'id': 12,
              'type': 'message',
              'message': rawMsg102,
              'flags': <String>[],
            },
            {
              'id': 13,
              'type': 'update_message',
              'message_id': 101,
              'message_ids': [101],
              'edit_timestamp': 2000,
              'rendered_content': '<p>one edited</p>',
              'orig_content': 'one',
              'orig_rendered_content': '<p>one</p>',
              'content': 'one edited',
              'flags': ['read'],
              'rendering_only': false,
              'is_me_message': false,
            },
            {
              'id': 14,
              'type': 'reaction',
              'op': 'add',
              'message_id': 101,
              'emoji_name': 'tada',
              'emoji_code': '1f389',
              'reaction_type': 'unicode_emoji',
              'user_id': eg.selfUser.userId,
            },
            {
              'id': 15,
              'type': 'update_message_flags',
              'op': 'add',
              'flag': 'starred',
              'messages': [101],
              'all': false,
            },
            {
              'id': 16,
              'type': 'delete_message',
              'message_ids': [102],
              'message_type': 'stream',
              'stream_id': stream.streamId,
              'topic': 'alpha',
            },
            {
              'id': 17,
              'type': 'message',
              'message': rawMsg103,
              'flags': ['future_custom_flag'],
            },
          ],
        });
        um.debugAdvanceLoop();
        async.elapse(Duration.zero);

        check(um.lastEventId).equals(17);
        check(um.store.debugCoverageThroughEventId).equals(17);

        final db = globalStore.backend.debugMessageDatabase!;
        final accountRow = await (db.select(db.messageDbAccounts)
              ..where((a) => a.accountId.equals(eg.selfAccount.id)))
            .getSingle();
        check(accountRow.appliedThroughEventId).equals(17);
        check(accountRow.eventHighWater).equals(103);

        final row101 = await loadStoredRow(db, eg.selfAccount.id, 101);
        check(row101).isNotNull();
        check(row101!.flags & StoredMessageFlags.starred).not((v) => v.equals(0));

        final row103 = await loadStoredRow(db, eg.selfAccount.id, 103);
        check(row103).isNotNull();
        check(row103!.unknownFlags).isNotNull();
        check(jsonDecode(row103.unknownFlags!) as List<dynamic>).deepEquals(['future_custom_flag']);

        final body101 = await (db.select(db.storedMessageBodies)
              ..where((b) => b.accountId.equals(eg.selfAccount.id) & b.messageId.equals(101)))
            .getSingle();
        check(body101.content).equals('<p>one edited</p>');

        final reactions101 = await (db.select(db.storedReactions)
              ..where((r) => r.accountId.equals(eg.selfAccount.id) & r.messageId.equals(101)))
            .get();
        check(reactions101).length.equals(1);

        // Deleted message 102 is gone from SQLite.
        check(await loadStoredRow(db, eg.selfAccount.id, 102)).isNull();
        check(accountRow.totalBodyBytes).equals(row101.bodyBytes + row103.bodyBytes);

        // Stage-1 snapshot + batch committed cleanly on the same poll.
        check(globalStore.backend.serverSnapshotOf(eg.selfAccount.id)?.lastEventId).equals(17);
        check(globalStore.backend.serverEventBatchesOf(eg.selfAccount.id)).length.equals(1);

        // Heartbeat-only batch advances appliedThroughEventId cleanly.
        connection.prepare(json: {
          'result': 'success',
          'msg': '',
          'events': [
            {'type': 'heartbeat', 'id': 18},
          ],
        });
        um.debugAdvanceLoop();
        async.elapse(Duration.zero);

        final updatedAccount = await (db.select(db.messageDbAccounts)
              ..where((a) => a.accountId.equals(eg.selfAccount.id)))
            .getSingle();
        check(updatedAccount.appliedThroughEventId).equals(18);
        check(globalStore.backend.serverSnapshotOf(eg.selfAccount.id)?.lastEventId).equals(18);
      } finally {
        await cleanupStore(globalStore, machines);
      }
    }));

    test('persisted replay and poll redelivery suppress duplicate DB/coverage mutations', () => awaitFakeAsync((async) async {
      final (:globalStore, :connection) = await prepareStore();
      final machines = <UpdateMachine>[];
      try {
        final stream = eg.stream(streamId: 10);
        final sub = eg.subscription(stream);
        final snap = eg.initialSnapshot(
          queueId: 'q1',
          lastEventId: 10,
          maxMessageId: 50,
          streams: [stream],
          subscriptions: [sub],
        );
        connection.prepare(json: snapshotToJson(snap));
        connection.prepare(json: {'result': 'success', 'msg': '', 'events': <Object>[], 'queue_id': 'q1'});
        final um1 = await UpdateMachine.load(globalStore, eg.selfAccount.id, allowPersisted: false);
        machines.add(um1);
        um1.debugPauseLoop();
        async.elapse(Duration.zero);

        final msg101 = eg.streamMessage(id: 101, stream: stream, topic: 'alpha', content: '<p>msg 101</p>');
        final rawMsg101 = msg101.toJson()..remove('flags');
        final msg102 = eg.streamMessage(id: 102, stream: stream, topic: 'alpha', content: '<p>msg 102</p>');
        final rawMsg102 = msg102.toJson()..remove('flags');
        connection.prepare(json: {
          'result': 'success',
          'msg': '',
          'events': [
            {'id': 11, 'type': 'message', 'message': rawMsg101, 'flags': <String>[]},
            {'id': 12, 'type': 'message', 'message': rawMsg102, 'flags': <String>[]},
          ],
        });
        um1.debugAdvanceLoop();
        async.elapse(Duration.zero);

        final db = globalStore.backend.debugMessageDatabase!;
        final accountBefore = await (db.select(db.messageDbAccounts)
              ..where((a) => a.accountId.equals(eg.selfAccount.id)))
            .getSingle();
        final totalBytesBefore = accountBefore.totalBodyBytes;
        check(accountBefore.appliedThroughEventId).equals(12);
        um1.store.dispose();

        // Seed Stage-1 behind MessageDatabase (only snapshot at ackEventId = 10),
        // so catchup poll redelivers events 11 and 12 alongside new event 13.
        globalStore.clearCachedApiConnections();
        final connection2 = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
        final msg103 = eg.streamMessage(id: 103, stream: stream, topic: 'alpha', content: '<p>msg 103</p>');
        final rawMsg103 = msg103.toJson()..remove('flags');
        connection2.prepare(
          delay: const Duration(milliseconds: 500),
          json: {
            'result': 'success',
            'msg': '',
            'events': [
              {'id': 11, 'type': 'message', 'message': rawMsg101, 'flags': <String>[]},
              {'id': 12, 'type': 'message', 'message': rawMsg102, 'flags': <String>[]},
              {'id': 13, 'type': 'message', 'message': rawMsg103, 'flags': <String>[]},
            ],
          },
        );
        globalStore.backend.seedServerData(
          eg.selfAccount.id,
          snapshotJson: snapshotToJson(snap),
        );

        final um2 = await UpdateMachine.load(globalStore, eg.selfAccount.id, allowPersisted: true);
        machines.add(um2);
        um2.debugPauseLoop();
        check(um2.store.dbActive).isTrue();
        check(um2.store.messages.containsKey(101)).isFalse();

        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();

        // In memory, all three events were applied.
        check(um2.store.messages.keys).deepEquals([101, 102, 103]);
        check(um2.store.confirmed).isTrue();
        check(um2.store.debugCoverageThroughEventId).equals(13);

        // In SQLite, 101 and 102 were NOT duplicated in totalBodyBytes, and 103 was added once.
        final row103 = await loadStoredRow(db, eg.selfAccount.id, 103);
        check(row103).isNotNull();
        final accountAfter = await (db.select(db.messageDbAccounts)
              ..where((a) => a.accountId.equals(eg.selfAccount.id)))
            .getSingle();
        check(accountAfter.appliedThroughEventId).equals(13);
        check(accountAfter.totalBodyBytes).equals(totalBytesBefore + row103!.bodyBytes);
      } finally {
        await cleanupStore(globalStore, machines);
      }
    }));

    test('C14 check validates DB-only rows before applying moves', () => awaitFakeAsync((async) async {
      final (:globalStore, :connection) = await prepareStore();
      final machines = <UpdateMachine>[];
      try {
        final streamA = eg.stream(streamId: 10);
        final streamB = eg.stream(streamId: 20);
        final subA = eg.subscription(streamA);
        final subB = eg.subscription(streamB);
        final snap = eg.initialSnapshot(
          queueId: 'q1',
          lastEventId: 10,
          maxMessageId: 50,
          streams: [streamA, streamB],
          subscriptions: [subA, subB],
        );
        connection.prepare(json: snapshotToJson(snap));
        connection.prepare(json: {'result': 'success', 'msg': '', 'events': <Object>[], 'queue_id': 'q1'});
        final um1 = await UpdateMachine.load(globalStore, eg.selfAccount.id, allowPersisted: false);
        machines.add(um1);
        um1.debugPauseLoop();
        async.elapse(Duration.zero);

        final msgGood = eg.streamMessage(id: 101, stream: streamA, topic: 'origin');
        final msgBad = eg.streamMessage(id: 102, stream: streamA, topic: 'actual-other');
        connection.prepare(json: {
          'result': 'success',
          'msg': '',
          'events': [
            {'id': 11, 'type': 'message', 'message': msgGood.toJson()..remove('flags'), 'flags': <String>[]},
            {'id': 12, 'type': 'message', 'message': msgBad.toJson()..remove('flags'), 'flags': <String>[]},
          ],
        });
        um1.debugAdvanceLoop();
        async.elapse(Duration.zero);
        um1.store.dispose();

        // Restart from persisted snapshot at 12: RAM `messages` is empty; 101 & 102 are DB-only.
        globalStore.clearCachedApiConnections();
        final connection2 = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
        connection2.prepare(
          delay: const Duration(milliseconds: 500),
          json: {
            'result': 'success',
            'msg': '',
            'events': [
              {
                'id': 13,
                'type': 'update_message',
                'message_id': 101,
                'message_ids': [101, 102],
                'edit_timestamp': 2000,
                'stream_id': streamA.streamId,
                'new_stream_id': streamB.streamId,
                'orig_subject': 'origin',
                'subject': 'dest',
                'propagate_mode': 'change_all',
                'flags': <String>[],
                'rendering_only': false,
              },
            ],
          },
        );
        globalStore.backend.seedServerData(
          eg.selfAccount.id,
          snapshotJson: snapshotToJson(snap),
          lastEventId: 12,
        );
        final um2 = await UpdateMachine.load(globalStore, eg.selfAccount.id, allowPersisted: true);
        machines.add(um2);
        um2.debugPauseLoop();
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();

        final db = globalStore.backend.debugMessageDatabase!;
        // 101 matched origin (streamA, 'origin') -> relocated to (streamB, 'dest').
        final row101 = await loadStoredRow(db, eg.selfAccount.id, 101);
        check(row101).isNotNull();
        check(row101!.channelId).equals(streamB.streamId);
        check(row101.topic).equals('dest');
        check(row101.topicKey).equals('DEST');

        // 102 disagreed with origin -> C14 forgot it from DB and punctured destination coverage.
        check(await loadStoredRow(db, eg.selfAccount.id, 102)).isNull();
        final destIntervals = um2.store.debugCoverage.intervalsOf(
          CoverageKeys.topic(streamB.streamId, 'dest'));
        check(destIntervals.any((i) => i.lo <= 102 && i.top >= 102)).isFalse();
      } finally {
        await cleanupStore(globalStore, machines);
      }
    }));

    test('DB write failure poisons writer, falls back to stage 1, and still executes removalOnly deletes', () => awaitFakeAsync((async) async {
      final (:globalStore, :connection) = await prepareStore();
      final machines = <UpdateMachine>[];
      try {
        final stream = eg.stream(streamId: 10);
        final sub = eg.subscription(stream);
        final snap = eg.initialSnapshot(
          queueId: 'q1',
          lastEventId: 10,
          maxMessageId: 50,
          streams: [stream],
          subscriptions: [sub],
        );
        connection.prepare(json: snapshotToJson(snap));
        connection.prepare(json: {'result': 'success', 'msg': '', 'events': <Object>[], 'queue_id': 'q1'});
        final um = await UpdateMachine.load(globalStore, eg.selfAccount.id, allowPersisted: false);
        machines.add(um);
        um.debugPauseLoop();
        async.elapse(Duration.zero);

        final msg101 = eg.streamMessage(id: 101, stream: stream, topic: 'alpha');
        connection.prepare(json: {
          'result': 'success',
          'msg': '',
          'events': [
            {'id': 11, 'type': 'message', 'message': msg101.toJson()..remove('flags'), 'flags': <String>[]},
          ],
        });
        um.debugAdvanceLoop();
        async.elapse(Duration.zero);

        final db = globalStore.backend.debugMessageDatabase!;
        check(await loadStoredRow(db, eg.selfAccount.id, 101)).isNotNull();

        // Inject DB write failure on next batch.
        globalStore.backend.nextMessageDbWriteError = StateError('disk full');
        final msg102 = eg.streamMessage(id: 102, stream: stream, topic: 'alpha');
        connection.prepare(json: {
          'result': 'success',
          'msg': '',
          'events': [
            {'id': 12, 'type': 'message', 'message': msg102.toJson()..remove('flags'), 'flags': <String>[]},
          ],
        });
        um.debugAdvanceLoop();
        async.elapse(Duration.zero);

        // Writer poisoned, dbActive false, Stage-1 still appended cleanly, non-view coverage dropped!
        check(um.store.dbActive).isFalse();
        check(um.store.debugCoverage.intervalsOf(CoverageKeys.channel(stream.streamId))).isEmpty();
        check(globalStore.backend.messageDbWriterForAccount(eg.selfAccount.id).isPoisoned).isTrue();
        check(um.lastEventId).equals(12);
        check(globalStore.backend.serverSnapshotOf(eg.selfAccount.id)?.lastEventId).equals(12);
        check(globalStore.backend.serverEventBatchesOf(eg.selfAccount.id)).length.equals(2);
        check(await loadStoredRow(db, eg.selfAccount.id, 102)).isNull();

        // Subsequent poisoned batch deletes 101 via removalOnly while ignoring inserts.
        final msg103 = eg.streamMessage(id: 103, stream: stream, topic: 'alpha');
        connection.prepare(json: {
          'result': 'success',
          'msg': '',
          'events': [
            {'id': 13, 'type': 'message', 'message': msg103.toJson()..remove('flags'), 'flags': <String>[]},
            {
              'id': 14,
              'type': 'delete_message',
              'message_ids': [101],
              'message_type': 'stream',
              'stream_id': stream.streamId,
              'topic': 'alpha',
            },
          ],
        });
        um.debugAdvanceLoop();
        async.elapse(Duration.zero);

        check(await loadStoredRow(db, eg.selfAccount.id, 101)).isNull();
        check(await loadStoredRow(db, eg.selfAccount.id, 103)).isNull();
        check(globalStore.backend.serverSnapshotOf(eg.selfAccount.id)?.lastEventId).equals(14);
      } finally {
        await cleanupStore(globalStore, machines);
      }
    }));

    test('2-second timeout on DB write poisons writer and falls back to stage 1', () => awaitFakeAsync((async) async {
      final (:globalStore, :connection) = await prepareStore();
      final machines = <UpdateMachine>[];
      try {
        final stream = eg.stream(streamId: 10);
        final sub = eg.subscription(stream);
        final snap = eg.initialSnapshot(
          queueId: 'q1',
          lastEventId: 10,
          maxMessageId: 50,
          streams: [stream],
          subscriptions: [sub],
        );
        connection.prepare(json: snapshotToJson(snap));
        connection.prepare(json: {'result': 'success', 'msg': '', 'events': <Object>[], 'queue_id': 'q1'});
        final um = await UpdateMachine.load(globalStore, eg.selfAccount.id, allowPersisted: false);
        machines.add(um);
        um.debugPauseLoop();
        async.elapse(Duration.zero);

        final gate = Completer<void>();
        globalStore.backend.messageDbWriteGate = gate.future;
        final msg101 = eg.streamMessage(id: 101, stream: stream, topic: 'alpha');
        connection.prepare(json: {
          'result': 'success',
          'msg': '',
          'events': [
            {'id': 11, 'type': 'message', 'message': msg101.toJson()..remove('flags'), 'flags': <String>[]},
          ],
        });
        um.debugAdvanceLoop();
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();

        check(um.store.dbActive).isFalse();
        check(globalStore.backend.messageDbWriterForAccount(eg.selfAccount.id).isPoisoned).isTrue();
        check(um.lastEventId).equals(11);
        check(globalStore.backend.serverSnapshotOf(eg.selfAccount.id)?.lastEventId).equals(11);

        // Release gate: late timed-out job must NOT insert 101 or undo poisoning.
        globalStore.backend.messageDbWriteGate = null;
        gate.complete();
        await globalStore.backend.messageDbWriterForAccount(eg.selfAccount.id).drainForTesting();

        final db = globalStore.backend.debugMessageDatabase!;
        check(await loadStoredRow(db, eg.selfAccount.id, 101)).isNull();
      } finally {
        await cleanupStore(globalStore, machines);
      }
    }));

    test('mid-session poison drops SQLite-only coverage while preserving open views', () => awaitFakeAsync((async) async {
      final (:globalStore, :connection) = await prepareStore();
      final machines = <UpdateMachine>[];
      try {
        final stream = eg.stream(streamId: 10, name: 'General');
        final sub = eg.subscription(stream);
        final snap = eg.initialSnapshot(
          queueId: 'q1',
          lastEventId: 10,
          maxMessageId: 50,
          streams: [stream],
          subscriptions: [sub],
        );
        connection.prepare(json: snapshotToJson(snap));
        connection.prepare(json: {'result': 'success', 'msg': '', 'events': <Object>[], 'queue_id': 'q1'});
        final um = await UpdateMachine.load(globalStore, eg.selfAccount.id, allowPersisted: false);
        machines.add(um);
        um.debugPauseLoop();
        async.elapse(Duration.zero);

        final msg60 = eg.streamMessage(id: 60, stream: stream, topic: 'open');
        final dm70 = eg.dmMessage(id: 70, from: eg.selfUser, to: [eg.otherUser]);
        connection.prepare(json: eg.newestGetMessagesResult(foundOldest: true, messages: [msg60]).toJson());
        final view = MessageListView.init(
          store: um.store,
          narrow: TopicNarrow(stream.streamId, eg.t('open')),
          anchor: AnchorCode.newest,
        );
        await view.fetchInitial();

        await um.store.handleEventBatch([
          MessageEvent(id: 11, localMessageId: null, message: dm70),
        ], lastEventId: 11);
        await globalStore.backend.messageDbWriterForAccount(eg.selfAccount.id).drainForTesting();
        check(um.store.debugCoverage.intervalsOf(CoverageKeys.dms)).isNotEmpty();

        // Trigger poison on the next poll batch.
        globalStore.backend.nextMessageDbWriteError = StateError('disk full');
        final msg80 = eg.streamMessage(id: 80, stream: stream, topic: 'other');
        connection.prepare(json: {
          'result': 'success',
          'msg': '',
          'events': [
            {'id': 12, 'type': 'message', 'message': msg80.toJson()..remove('flags'), 'flags': <String>[]},
          ],
        });
        um.debugAdvanceLoop();
        async.elapse(Duration.zero);

        check(um.store.dbActive).isFalse();
        check(um.store.debugCoverage.intervalsOf(CoverageKeys.dms)).isEmpty();
        check(um.store.debugCoverage.intervalsOf(CoverageKeys.channel(stream.streamId))).isEmpty();
        final retained = um.store.debugCoverage.intervalsOf(CoverageKeys.topic(stream.streamId, 'open'));
        check(retained).single
          ..has((r) => r.contains(60), 'contains open view message 60').isTrue()
          ..has((r) => r.isOpen, 'remains open').isTrue();

        view.dispose();
      } finally {
        await cleanupStore(globalStore, machines);
      }
    }));
  });
}
