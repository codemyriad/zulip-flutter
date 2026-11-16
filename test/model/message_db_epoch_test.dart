import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:drift/drift.dart' as drift;
import 'package:test/scaffolding.dart';
import 'package:zulip/api/model/initial_snapshot.dart';
import 'package:zulip/model/message_coverage.dart';
import 'package:zulip/model/message_database.dart';
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
      um.store.dispose();
    }
    await globalStore.backend.closeMessageDb();
    globalStore.dispose();
    UpdateMachine.debugEnableFetchEmojiData = true;
  }

  Future<void> insertDummyMessage(
    MessageDatabase db, {
    required int accountId,
    required int id,
    int? channelId,
    String? dmKey,
    int bodyBytes = 42,
  }) async {
    await db.into(db.storedMessages).insert(StoredMessagesCompanion.insert(
      accountId: accountId,
      id: id,
      channelId: drift.Value(channelId),
      topic: drift.Value(channelId != null ? 't' : null),
      topicKey: drift.Value(channelId != null ? 't' : null),
      dmKey: drift.Value(dmKey),
      senderId: eg.selfUser.userId,
      timestamp: 1000,
      flags: 0,
      isMeMessage: false,
      editState: 0,
      displayRecipientCleared: false,
      epoch: 1,
      tracked: true,
      bodyBytes: bodyBytes,
    ));
    await db.into(db.storedMessageBodies).insert(StoredMessageBodiesCompanion.insert(
      accountId: accountId,
      messageId: id,
      content: '<p>hello $id</p>',
      json: utf8.encode('{}'),
    ));
    final acct = await (db.select(db.messageDbAccounts)
      ..where((a) => a.accountId.equals(accountId))).getSingle();
    await (db.update(db.messageDbAccounts)
      ..where((a) => a.accountId.equals(accountId)))
      .write(MessageDbAccountsCompanion(
        totalBodyBytes: drift.Value(acct.totalBodyBytes + bodyBytes),
      ));
  }

  group('initMessageDbFromRegister / bounded start', () {
    test('fresh register begins epoch 1 and opens dms [maxMessageId + 1, ∞)', () => awaitFakeAsync((async) async {
      final (:globalStore, :connection) = await prepareStore();
      final machines = <UpdateMachine>[];
      try {
        connection.prepare(json: eg.initialSnapshot(
          queueId: 'q1',
          lastEventId: 10,
          maxMessageId: 50,
        ).toJson());
        final um = await UpdateMachine.load(globalStore, eg.selfAccount.id, allowPersisted: false);
        machines.add(um);
        um.debugPauseLoop();

        check(um.store.dbActive).isTrue();
        check(um.store.confirmed).isTrue();
        check(um.store.debugCoverage.epoch).equals(1);
        check(um.store.debugCoverage.confirmed).isTrue();
        check(um.store.debugCoverage.eventHighWater).equals(50);
        final dmInterval = um.store.debugCoverage.intervalsOf('dms').single;
        check(dmInterval.lo).equals(51);
        check(dmInterval.hi).isNull();
        check(dmInterval.epoch).equals(1);
        check(dmInterval.tracked).isTrue();

        final db = globalStore.backend.debugMessageDatabase!;
        final acct = await (db.select(db.messageDbAccounts)
          ..where((a) => a.accountId.equals(eg.selfAccount.id))).getSingle();
        check(acct.epoch).equals(1);
        check(acct.queueId).equals('q1');
        check(acct.appliedThroughEventId).equals(10);
        check(acct.eventHighWater).equals(50);
      } finally {
        await cleanupStore(globalStore, machines);
        async.elapse(const Duration(seconds: 5));
      }
    }));

    test('fresh register handles null maxMessageId without opening dms interval', () => awaitFakeAsync((async) async {
      final (:globalStore, :connection) = await prepareStore();
      final machines = <UpdateMachine>[];
      try {
        final json = jsonDecode(jsonEncode(eg.initialSnapshot(
          queueId: 'q1',
          lastEventId: 10,
        ))) as Map<String, dynamic>;
        json.remove('max_message_id');
        connection.prepare(json: json);
        final um = await UpdateMachine.load(globalStore, eg.selfAccount.id, allowPersisted: false);
        machines.add(um);
        um.debugPauseLoop();

        check(um.store.dbActive).isTrue();
        check(um.store.debugCoverage.epoch).equals(1);
        check(um.store.debugCoverage.eventHighWater).equals(-1);
        check(um.store.debugCoverage.intervalsOf('dms')).isEmpty();
      } finally {
        await cleanupStore(globalStore, machines);
        async.elapse(const Duration(seconds: 5));
      }
    }));

    test('3s timeout falls back to DB-inactive and poisons writer; next start wipes', () => awaitFakeAsync((async) async {
      final (:globalStore, :connection) = await prepareStore();
      final machines = <UpdateMachine>[];
      try {
        final openGate = Completer<void>();
        globalStore.backend.messageDbOpenGate = openGate.future;

        connection.prepare(json: eg.initialSnapshot(
          queueId: 'q1',
          lastEventId: 10,
          maxMessageId: 50,
        ).toJson());

        UpdateMachine? um;
        unawaited(UpdateMachine.load(globalStore, eg.selfAccount.id, allowPersisted: false)
          .then((value) {
            um = value;
            machines.add(value);
          }));
        async.elapse(const Duration(milliseconds: 100));
        check(um).isNull();

        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();

        check(um).isNotNull();
        um!.debugPauseLoop();
        check(um!.store.dbActive).isFalse();
        check(um!.store.debugCoverageEnabled).isTrue();
        check(um!.store.debugCoverage.intervalsOf('dms')).isEmpty();
        final writer = globalStore.backend.messageDbWriterForAccount(eg.selfAccount.id);
        check(writer.isPoisoned).isTrue();

        // Release open gate; subsequent clean register wipes and begins epoch 1.
        globalStore.backend.messageDbOpenGate = null;
        openGate.complete();
        await writer.drainForTesting();
        check(writer.isPoisoned).isTrue();

        globalStore.clearCachedApiConnections();
        final connection2 = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
        connection2.prepare(json: eg.initialSnapshot(
          queueId: 'q2',
          lastEventId: 1,
          maxMessageId: 60,
        ).toJson());
        final um2 = await UpdateMachine.load(globalStore, eg.selfAccount.id, allowPersisted: false);
        machines.add(um2);
        um2.debugPauseLoop();
        check(um2.store.dbActive).isTrue();
        check(writer.isPoisoned).isFalse();
        check(um2.store.debugCoverage.epoch).equals(1);
      } finally {
        await cleanupStore(globalStore, machines);
        async.elapse(const Duration(seconds: 5));
      }
    }));

    test('DB write error on persisted start keeps Stage-1 snapshot and falls back cleanly', () => awaitFakeAsync((async) async {
      final (:globalStore, :connection) = await prepareStore();
      final machines = <UpdateMachine>[];
      try {
        final stream = eg.stream(streamId: 1, name: 'General');
        final snap = eg.initialSnapshot(
          queueId: 'q1',
          lastEventId: 10,
          maxMessageId: 50,
          streams: [stream],
          subscriptions: [eg.subscription(stream)],
        );
        globalStore.backend.seedServerData(
          eg.selfAccount.id,
          snapshotJson: snapshotToJson(snap),
        );
        globalStore.backend.nextMessageDbWriteError = StateError('disk full');

        final um = await UpdateMachine.load(globalStore, eg.selfAccount.id, allowPersisted: true);
        machines.add(um);
        um.debugPauseLoop();

        // Stage-1 data loaded normally, queue unconfirmed, DB inactive & writer poisoned.
        check(um.store.streams[1]?.name).equals('General');
        check(um.store.confirmed).isFalse();
        check(um.store.dbActive).isFalse();
        check(um.store.debugCoverage.epoch).equals(0);
        check(um.store.debugCoverage.intervalsOf('dms')).isEmpty();
        check(globalStore.backend.messageDbWriterForAccount(eg.selfAccount.id).isPoisoned).isTrue();
      } finally {
        await cleanupStore(globalStore, machines);
        async.elapse(const Duration(seconds: 5));
      }
    }));

    test('mid-transaction failure after beginEpoch leaves _coverage unmutated', () => awaitFakeAsync((async) async {
      final (:globalStore, :connection) = await prepareStore();
      final machines = <UpdateMachine>[];
      try {
        await globalStore.backend.messageDbWriterForAccount(eg.selfAccount.id).runRead((db) async {
          await db.upsertAccountInTxn(
            accountId: eg.selfAccount.id,
            realmUrl: eg.selfAccount.realmUrl,
            userId: eg.selfUser.userId,
            epoch: 5,
            queueId: 'prev-q',
            appliedThroughEventId: 1,
            eventHighWater: 40,
            lastLiveAt: 1000,
          );
          await db.customStatement(
            'CREATE TRIGGER fail_epoch_channels '
            'AFTER INSERT ON message_db_channels '
            'BEGIN SELECT RAISE(ABORT, \'forced failure\'); END',
          );
        });
        final stream = eg.stream(streamId: 1, name: 'General');
        connection.prepare(json: snapshotToJson(eg.initialSnapshot(
          queueId: 'q1',
          lastEventId: 10,
          maxMessageId: 50,
          streams: [stream],
          subscriptions: [eg.subscription(stream)],
        )));

        final um = await UpdateMachine.load(globalStore, eg.selfAccount.id, allowPersisted: false);
        machines.add(um);
        um.debugPauseLoop();

        check(um.store.dbActive).isFalse();
        // Constructor _ensureCoverageBegun() initializes epoch 1 for RAM coverage;
        // the rolled-back DB transaction must not leak DB epoch 5->6 onto _coverage.
        check(um.store.debugCoverage.epoch).equals(1);
        check(um.store.debugCoverage.intervalsOf('dms')).isEmpty();
      } finally {
        await cleanupStore(globalStore, machines);
        async.elapse(const Duration(seconds: 5));
      }
    }));
  });

  group('continue, bump, C3 DM trim, and epoch-start access check', () {
    test('persisted start continues matching epoch unconfirmed, then poll confirms', () => awaitFakeAsync((async) async {
      final (:globalStore, :connection) = await prepareStore();
      final machines = <UpdateMachine>[];
      try {
        final snap = eg.initialSnapshot(
          queueId: 'q1',
          lastEventId: 10,
          maxMessageId: 50,
        );
        connection.prepare(json: snap.toJson());
        final um1 = await UpdateMachine.load(globalStore, eg.selfAccount.id, allowPersisted: false);
        um1.debugPauseLoop();
        um1.store.dispose();

        // Restart from persisted data with matching queueId and appliedThrough >= ack.
        globalStore.clearCachedApiConnections();
        final connection2 = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
        connection2.prepare(
          delay: const Duration(seconds: 1),
          json: {
            'result': 'success',
            'msg': '',
            'events': [
              {'type': 'heartbeat', 'id': 11},
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
        check(um2.store.confirmed).isFalse();
        check(um2.store.debugCoverage.epoch).equals(1);
        check(um2.store.debugCoverage.confirmed).isFalse();
        check(um2.store.debugCoverage.eventHighWater).equals(50);

        // Advance past the delayed first poll response so poll confirms.
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        check(um2.store.confirmed).isTrue();
        check(um2.store.debugCoverage.confirmed).isTrue();
      } finally {
        await cleanupStore(globalStore, machines);
        async.elapse(const Duration(seconds: 5));
      }
    }));

    test('bump closes open intervals at eventHighWater, trims C3 DMs, and checks channel access', () => awaitFakeAsync((async) async {
      final (:globalStore, :connection) = await prepareStore();
      final machines = <UpdateMachine>[];
      try {
        final sLost = eg.stream(streamId: 1, inviteOnly: true);
        final sFlippedProtected = eg.stream(streamId: 2, historyPublicToSubscribers: true);
        final sFlippedPublic = eg.stream(streamId: 3, historyPublicToSubscribers: false);
        final sKept = eg.stream(streamId: 4, historyPublicToSubscribers: true);

        connection.prepare(json: snapshotToJson(eg.initialSnapshot(
          queueId: 'q1',
          lastEventId: 10,
          maxMessageId: 100,
          streams: [sLost, sFlippedProtected, sFlippedPublic, sKept],
          subscriptions: [
            eg.subscription(sLost),
            eg.subscription(sFlippedProtected),
            eg.subscription(sFlippedPublic),
            eg.subscription(sKept),
          ],
        )));
        final um1 = await UpdateMachine.load(globalStore, eg.selfAccount.id, allowPersisted: false);
        machines.add(um1);
        um1.debugPauseLoop();
        check(um1.store.dbActive).isTrue();

        final db = globalStore.backend.debugMessageDatabase!;
        final dmKeyListed = StoredMessageCodec.dmKeyFromRecipientIds(
          [eg.selfUser.userId, eg.otherUser.userId]);
        final dmKeyUnlisted = StoredMessageCodec.dmKeyFromRecipientIds(
          [eg.selfUser.userId, 999]);
        await insertDummyMessage(db, accountId: eg.selfAccount.id, id: 10, channelId: 1);
        await insertDummyMessage(db, accountId: eg.selfAccount.id, id: 20, channelId: 2);
        await insertDummyMessage(db, accountId: eg.selfAccount.id, id: 30, channelId: 3);
        await insertDummyMessage(db, accountId: eg.selfAccount.id, id: 40, channelId: 4);
        // C3 DM rows: id 80 > listed latest 70; id 105 > new maxMessageId 90.
        await insertDummyMessage(db, accountId: eg.selfAccount.id, id: 60, dmKey: dmKeyListed);
        await insertDummyMessage(db, accountId: eg.selfAccount.id, id: 80, dmKey: dmKeyListed);
        await insertDummyMessage(db, accountId: eg.selfAccount.id, id: 105, dmKey: dmKeyUnlisted);

        // Seed coverage for channels 2, 3, 4 before reload.
        await db.replaceCoverageKeysInTxn(eg.selfAccount.id, {
          'channel:2': [CoverageInterval(20, null, epoch: 1, tracked: true, verifiedAt: 500)],
          'channel:3': [CoverageInterval(30, null, epoch: 1, tracked: true, verifiedAt: 500)],
          'channel:4': [CoverageInterval(40, null, epoch: 1, tracked: true, verifiedAt: 500)],
        });
        machines.remove(um1);
        um1.store.dispose();

        // Fresh register with:
        // - sLost absent (lost access -> purge)
        // - sFlippedProtected now historyPublicToSubscribers: false -> purge + drop
        // - sFlippedPublic now historyPublicToSubscribers: true -> keep row, drop coverage
        // - sKept unchanged -> close open interval at eventHighWater=100, keep row
        // - maxMessageId = 90, listed DM max = 70
        globalStore.clearCachedApiConnections();
        final connection2 = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
        connection2.prepare(json: snapshotToJson(eg.initialSnapshot(
          queueId: 'q2',
          lastEventId: 20,
          maxMessageId: 90,
          streams: [
            eg.stream(streamId: 2, historyPublicToSubscribers: false),
            eg.stream(streamId: 3, historyPublicToSubscribers: true),
            sKept,
          ],
          subscriptions: [
            eg.subscription(eg.stream(streamId: 2, historyPublicToSubscribers: false)),
            eg.subscription(eg.stream(streamId: 3, historyPublicToSubscribers: true)),
            eg.subscription(sKept),
          ],
          recentPrivateConversations: [
            RecentDmConversation(userIds: [eg.otherUser.userId], maxMessageId: 70),
          ],
        )));

        final um2 = await UpdateMachine.load(globalStore, eg.selfAccount.id, allowPersisted: false);
        machines.add(um2);
        um2.debugPauseLoop();

        check(um2.store.dbActive).isTrue();
        check(um2.store.debugCoverage.epoch).equals(2);
        // Epoch 1's open channel:4 interval closed at previous eventHighWater (100).
        check(um2.store.debugCoverage.intervalsOf('channel:4').map((r) => '${r.lo}..${r.hi}@e${r.epoch}'))
          .deepEquals(['40..100@e1']);
        // channel:1 and channel:2 purged, channel:3 coverage dropped.
        check(um2.store.debugCoverage.intervalsOf('channel:1')).isEmpty();
        check(um2.store.debugCoverage.intervalsOf('channel:2')).isEmpty();
        check(um2.store.debugCoverage.intervalsOf('channel:3')).isEmpty();
        // dms has epoch 1 [101, 100] dropped (lo > H), plus new epoch 2 [91, ∞).
        check(um2.store.debugCoverage.intervalsOf('dms').map((r) => '${r.lo}..${r.hi}@e${r.epoch}'))
          .deepEquals(['91..null@e2']);

        final remainingIds = (await (db.select(db.storedMessages)
          ..where((m) => m.accountId.equals(eg.selfAccount.id))
          ..orderBy([(m) => drift.OrderingTerm.asc(m.id)]))
          .get()).map((r) => r.id).toList();
        check(remainingIds).deepEquals([30, 40, 60]);
      } finally {
        await cleanupStore(globalStore, machines);
        async.elapse(const Duration(seconds: 5));
      }
    }));

    test('persisted load with skipped event log bumps epoch without purging post-snapshot channels', () => awaitFakeAsync((async) async {
      final (:globalStore, :connection) = await prepareStore();
      final machines = <UpdateMachine>[];
      try {
        final sInitial = eg.stream(streamId: 1, name: 'initial');
        final sPostSnap = eg.stream(streamId: 2, name: 'post-snap', inviteOnly: true);
        final snap = eg.initialSnapshot(
          queueId: 'q1',
          lastEventId: 10,
          maxMessageId: 100,
          streams: [sInitial, sPostSnap],
          subscriptions: [eg.subscription(sInitial), eg.subscription(sPostSnap)],
        );
        connection.prepare(json: snapshotToJson(snap));
        final um1 = await UpdateMachine.load(globalStore, eg.selfAccount.id, allowPersisted: false);
        machines.add(um1);
        um1.debugPauseLoop();

        final db = globalStore.backend.debugMessageDatabase!;
        await insertDummyMessage(db, accountId: eg.selfAccount.id, id: 55, channelId: 2);
        await (db.update(db.messageDbAccounts)
              ..where((a) => a.accountId.equals(eg.selfAccount.id)))
            .write(const MessageDbAccountsCompanion(appliedThroughEventId: drift.Value(25)));
        machines.remove(um1);
        um1.store.dispose();

        // Seed truncated event log from an earlier snapshot that lacked sPostSnap.
        final olderSnap = eg.initialSnapshot(
          queueId: 'q1',
          lastEventId: 10,
          maxMessageId: 100,
          streams: [sInitial],
          subscriptions: [eg.subscription(sInitial)],
        );
        globalStore.backend.seedServerData(
          eg.selfAccount.id,
          snapshotJson: snapshotToJson(olderSnap),
          lastEventId: 25,
          eventLogTruncated: true,
        );
        globalStore.clearCachedApiConnections();
        final conn2 = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
        conn2.prepare(delay: const Duration(seconds: 5), json: snapshotToJson(snap));

        final um2 = await UpdateMachine.load(globalStore, eg.selfAccount.id, allowPersisted: true);
        machines.add(um2);
        um2.debugPauseLoop();

        // Row 55 in post-snapshot channel 2 must NOT be purged before replacement /register arrives.
        final rows = await (db.select(db.storedMessages)
          ..where((m) => m.accountId.equals(eg.selfAccount.id))).get();
        check(rows.map((r) => r.id)).deepEquals([55]);
      } finally {
        await cleanupStore(globalStore, machines);
        async.elapse(const Duration(seconds: 6));
      }
    }));

    test('persisted load discards snapshot stored under mismatched userId or realmUrl', () => awaitFakeAsync((async) async {
      final (:globalStore, :connection) = await prepareStore();
      final machines = <UpdateMachine>[];
      try {
        final snap = eg.initialSnapshot(queueId: 'q-fresh', lastEventId: 20, maxMessageId: 50);
        globalStore.backend.seedServerData(
          eg.selfAccount.id,
          userId: eg.otherUser.userId,
          snapshotJson: snapshotToJson(eg.initialSnapshot(queueId: 'q-wrong-user', lastEventId: 10)),
        );
        connection.prepare(json: snapshotToJson(snap));
        final um = await UpdateMachine.load(globalStore, eg.selfAccount.id, allowPersisted: true);
        machines.add(um);
        um.debugPauseLoop();
        check(um.store.queueId).equals('q-fresh');
      } finally {
        await cleanupStore(globalStore, machines);
        async.elapse(const Duration(seconds: 5));
      }
    }));

    test('runtime BoolGlobalSetting.messageDatabase toggle disables/wipes and re-enables DB', () => awaitFakeAsync((async) async {
      final stream = eg.stream(streamId: 1, name: 'general');
      final globalStore = UpdateMachineTestGlobalStore(
        accounts: [eg.selfAccount],
        boolGlobalSettings: {BoolGlobalSetting.messageDatabase: true},
      );
      globalStore.prepareRegisterQueueResponse = (conn) => conn.prepare(
        json: snapshotToJson(eg.initialSnapshot(
          queueId: 'q1',
          lastEventId: 10,
          maxMessageId: 50,
          streams: [stream],
          subscriptions: [eg.subscription(stream)],
        )),
      );
      try {
        final store = await globalStore.perAccount(eg.selfAccount.id);
        check(store.dbActive).isTrue();

        final db = globalStore.backend.debugMessageDatabase!;
        await insertDummyMessage(db, accountId: eg.selfAccount.id, id: 42, channelId: 1);

        // Toggle true -> false: disables live store DB and wipes stored message cache.
        await globalStore.settings.setBool(BoolGlobalSetting.messageDatabase, false);
        async.flushMicrotasks();
        await globalStore.backend.messageDbWriterForAccount(eg.selfAccount.id).drainForTesting();
        check(store.dbActive).isFalse();
        check(await db.select(db.storedMessages).get()).isEmpty();

        // Toggle false -> true: initializes DB again on live store.
        await globalStore.settings.setBool(BoolGlobalSetting.messageDatabase, true);
        async.flushMicrotasks();
        await globalStore.backend.messageDbWriterForAccount(eg.selfAccount.id).drainForTesting();
        check(store.dbActive).isTrue();
      } finally {
        await globalStore.backend.closeMessageDb();
        globalStore.dispose();
        async.elapse(const Duration(seconds: 5));
      }
    }));
  });
}
