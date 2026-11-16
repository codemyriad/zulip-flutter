import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/scaffolding.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/model/database.dart';
import 'package:zulip/model/message_database.dart';
import 'package:zulip/model/message_db_effects.dart';
import 'package:zulip/model/message_search_text.dart';
import 'package:zulip/model/store.dart';
import 'package:zulip/model/stored_message_codec.dart';

import '../example_data.dart' as eg;
import 'store_checks.dart';

void main() {
  group('MessageDatabase pragmas and accounts', () {
    test('configures auto_vacuum=INCREMENTAL before WAL on a file database', () async {
      final dir = await Directory.systemTemp.createTemp('message_db_test_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(p.join(dir.path, 'zulip-messages.db'));

      final db = MessageDatabase.openFile(file);
      addTearDown(db.close);

      // Force opening the file and running setup pragmas + migration.
      await db.select(db.messageDbAccounts).get();

      final autoVacuum = await db.customSelect('PRAGMA auto_vacuum').getSingle();
      // SQLite PRAGMA auto_vacuum: 0 = NONE, 1 = FULL, 2 = INCREMENTAL.
      check(autoVacuum.read<int>('auto_vacuum')).equals(2);

      final journalMode = await db.customSelect('PRAGMA journal_mode').getSingle();
      check(journalMode.read<String>('journal_mode')).equals('wal');

      final foreignKeys = await db.customSelect('PRAGMA foreign_keys').getSingle();
      check(foreignKeys.read<int>('foreign_keys')).equals(1);
    });

    test('ensureAccount checks identity, formatVersion, and poisoned watermark', () async {
      final db = MessageDatabase(NativeDatabase.memory(setup: configureMessageDbPragmas));
      addTearDown(db.close);

      final realm = Uri.parse('https://chat.example.org');
      await db.into(db.messageDbAccounts).insert(MessageDbAccountsCompanion.insert(
        accountId: const Value(1),
        realmUrl: realm.toString(),
        userId: 100,
        formatVersion: MessageDatabase.currentFormatVersion,
        epoch: 1,
        appliedThroughEventId: const Value(50),
        eventHighWater: 500,
      ));

      // Matching identity and valid watermark -> returns row.
      final ok = await db.ensureAccount(accountId: 1, realmUrl: realm, userId: 100);
      check(ok).isNotNull().has((a) => a.epoch, 'epoch').equals(1);

      // Mismatched userId -> wipes row and returns null.
      final wrongUser = await db.ensureAccount(accountId: 1, realmUrl: realm, userId: 101);
      check(wrongUser).isNull();
      check(await db.select(db.messageDbAccounts).get()).isEmpty();

      // Re-insert with mismatched realmUrl -> wipes row and returns null.
      await db.into(db.messageDbAccounts).insert(MessageDbAccountsCompanion.insert(
        accountId: const Value(2),
        realmUrl: 'https://other.example.org',
        userId: 100,
        formatVersion: MessageDatabase.currentFormatVersion,
        epoch: 1,
        appliedThroughEventId: const Value(50),
        eventHighWater: 500,
      ));
      check(await db.ensureAccount(accountId: 2, realmUrl: realm, userId: 100)).isNull();
      check(await db.select(db.messageDbAccounts).get()).isEmpty();

      // Re-insert with poisoned watermark (appliedThroughEventId == null) -> wipes.
      await db.into(db.messageDbAccounts).insert(MessageDbAccountsCompanion.insert(
        accountId: const Value(3),
        realmUrl: realm.toString(),
        userId: 100,
        formatVersion: MessageDatabase.currentFormatVersion,
        epoch: 2,
        appliedThroughEventId: const Value(null),
        eventHighWater: 500,
      ));
      check(await db.ensureAccount(accountId: 3, realmUrl: realm, userId: 100)).isNull();
      check(await db.select(db.messageDbAccounts).get()).isEmpty();

      // Re-insert with old formatVersion -> wipes.
      await db.into(db.messageDbAccounts).insert(MessageDbAccountsCompanion.insert(
        accountId: const Value(4),
        realmUrl: realm.toString(),
        userId: 100,
        formatVersion: MessageDatabase.currentFormatVersion + 1,
        epoch: 1,
        appliedThroughEventId: const Value(10),
        eventHighWater: 500,
      ));
      check(await db.ensureAccount(accountId: 4, realmUrl: realm, userId: 100)).isNull();
      check(await db.select(db.messageDbAccounts).get()).isEmpty();
    });

    test('sweepOrphanAccounts and wipeAccount remove only targeted accounts', () async {
      final db = MessageDatabase(NativeDatabase.memory(setup: configureMessageDbPragmas));
      addTearDown(db.close);

      for (final id in [1, 2, 3]) {
        await db.into(db.messageDbAccounts).insert(MessageDbAccountsCompanion.insert(
          accountId: Value(id),
          realmUrl: 'https://chat.example.org',
          userId: 100 + id,
          formatVersion: MessageDatabase.currentFormatVersion,
          epoch: 1,
          appliedThroughEventId: const Value(10),
          eventHighWater: 100,
        ));
      }

      await db.sweepOrphanAccounts({1, 3});
      var remaining = await db.select(db.messageDbAccounts).get();
      check(remaining.map((a) => a.accountId).toList()).deepEquals([1, 3]);

      await db.wipeAccount(1);
      remaining = await db.select(db.messageDbAccounts).get();
      check(remaining.map((a) => a.accountId).toList()).deepEquals([3]);

      await db.sweepOrphanAccounts({});
      check(await db.select(db.messageDbAccounts).get()).isEmpty();
    });

    test('creates all 10 tables, indexes, WITHOUT ROWID, and cascades deletes', () async {
      final db = MessageDatabase(NativeDatabase.memory(setup: configureMessageDbPragmas));
      addTearDown(db.close);

      final tables = (await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
      ).get()).map((r) => r.read<String>('name')).toSet();
      for (final table in [
        'message_db_accounts',
        'stored_messages',
        'stored_message_bodies',
        'stored_reactions',
        'stored_submessages',
        'coverage_intervals',
        'message_db_channels',
        'server_snapshots',
        'server_snapshot_blobs',
        'server_event_batches',
      ]) {
        check(tables).contains(table);
      }

      final indexes = (await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_%'",
      ).get()).map((r) => r.read<String>('name')).toSet();
      check(indexes).deepEquals({
        'idx_sm_topic',
        'idx_sm_channel',
        'idx_sm_dm',
        'idx_sr_message',
        'idx_ss_message',
        'idx_server_event_batches_account_id',
      });

      final smSql = (await db.customSelect(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'stored_messages'",
      ).getSingle()).read<String>('sql');
      check(smSql.toUpperCase()).contains('WITHOUT ROWID');

      // Insert an account, a message, body, reaction, submessage, coverage, channel.
      await db.into(db.messageDbAccounts).insert(MessageDbAccountsCompanion.insert(
        accountId: const Value(1),
        realmUrl: 'https://chat.example.org',
        userId: 100,
        formatVersion: MessageDatabase.currentFormatVersion,
        epoch: 1,
        appliedThroughEventId: const Value(1),
        eventHighWater: 10,
      ));
      await db.into(db.storedMessages).insert(StoredMessagesCompanion.insert(
        accountId: 1,
        id: 10,
        channelId: const Value(5),
        topic: const Value('topic'),
        topicKey: const Value('topic'),
        senderId: 100,
        timestamp: 1000,
        flags: 0,
        isMeMessage: false,
        editState: 0,
        displayRecipientCleared: false,
        epoch: 1,
        tracked: true,
        bodyBytes: 5,
      ));
      await db.into(db.storedMessageBodies).insert(StoredMessageBodiesCompanion.insert(
        accountId: 1,
        messageId: 10,
        content: '<p>hi</p>',
        json: Uint8List.fromList(utf8.encode('{}')),
      ));
      await db.into(db.storedReactions).insert(StoredReactionsCompanion.insert(
        accountId: 1,
        messageId: 10,
        seq: 0,
        userId: 100,
        reactionType: 'unicode_emoji',
        emojiCode: '1f44d',
        emojiName: '+1',
      ));
      await db.into(db.storedSubmessages).insert(StoredSubmessagesCompanion.insert(
        accountId: 1,
        submessageId: 99,
        messageId: 10,
        senderId: 100,
        msgType: 'widget',
        content: '{}',
      ));
      await db.into(db.coverageIntervals).insert(CoverageIntervalsCompanion.insert(
        accountId: 1,
        narrowKey: 'c:5',
        lo: 0,
        hi: const Value(10),
        epoch: 1,
        tracked: true,
        verifiedAt: 1000,
      ));
      await db.into(db.messageDbChannels).insert(MessageDbChannelsCompanion.insert(
        accountId: 1,
        channelId: 5,
        historyPublicToSubscribers: true,
      ));

      // Deleting the stored message cascades to bodies, reactions, submessages.
      await (db.delete(db.storedMessages)
        ..where((m) => m.accountId.equals(1) & m.id.equals(10))).go();
      check(await db.select(db.storedMessageBodies).get()).isEmpty();
      check(await db.select(db.storedReactions).get()).isEmpty();
      check(await db.select(db.storedSubmessages).get()).isEmpty();

      // Deleting the account cascades to coverage_intervals and message_db_channels.
      await db.wipeAccount(1);
      check(await db.select(db.coverageIntervals).get()).isEmpty();
      check(await db.select(db.messageDbChannels).get()).isEmpty();
    });
  });

  group('server data', () {
    late MessageDatabase db;

    setUp(() {
      db = MessageDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    Future<bool> append(Account account, int lastEventId, String? data, {
      String queueId = 'queue1',
    }) {
      return db.appendServerEvents(account.id,
        queueId: queueId, lastEventId: lastEventId,
        data: data == null ? null : utf8.encode(data));
    }

    Future<bool> storeSnapshot(ServerSnapshot snapshot, {String data = '{}'}) {
      return db.storeServerSnapshot(snapshot, data: utf8.encode(data));
    }

    Future<ServerData?> load(Account account) => db.loadServerData(account.id);

    Condition<Object?> isBatch(int lastEventId, String data) {
      return (it) => it.isA<ServerEventBatch>()
        ..accountId.equals(eg.selfAccount.id)
        ..queueId.equals('queue1')
        ..lastEventId.equals(lastEventId)
        ..data.deepEquals(utf8.encode(data));
    }

    test('store snapshot, then load', () async {
      final snapshot = eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue1', lastEventId: 10);
      check(await storeSnapshot(snapshot, data: '{"a":1}')).isTrue();
      check(await load(eg.selfAccount)).isNotNull()
        ..snapshot.equals(snapshot)
        ..snapshotData.deepEquals(utf8.encode('{"a":1}'))
        ..eventBatches.isEmpty();
      check(await load(eg.otherAccount)).isNull();
    });

    test('LiveGlobalStoreBackend.doStoreServerSnapshot returns false when account missing in AppDatabase', () async {
      final appDb = AppDatabase(NativeDatabase.memory());
      addTearDown(appDb.close);
      await appDb.createAccount(eg.otherAccount.toCompanion(false));
      final backend = LiveGlobalStoreBackend.forTesting(
        db: appDb,
        openMessageDb: () async => db,
      );
      check(await backend.doStoreServerSnapshot(
        eg.serverSnapshot(account: eg.selfAccount),
        data: Uint8List(0),
      )).isFalse();
      check(await db.select(db.serverSnapshots).get()).isEmpty();
      check(await db.select(db.serverSnapshotBlobs).get()).isEmpty();
    });

    test('store snapshot replaces snapshot and its batches', () async {
      await storeSnapshot(eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue1', lastEventId: 10), data: '{"a":1}');
      await append(eg.selfAccount, 11, '[{"id":11}]');
      await storeSnapshot(eg.serverSnapshot(account: eg.otherAccount,
        queueId: 'queue1', lastEventId: 10));
      await append(eg.otherAccount, 11, '[{"id":11}]');

      final newSnapshot = eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue2', lastEventId: 20);
      check(await storeSnapshot(newSnapshot, data: '{"b":2}')).isTrue();
      check(await load(eg.selfAccount)).isNotNull()
        ..snapshot.equals(newSnapshot)
        ..snapshotData.deepEquals(utf8.encode('{"b":2}'))
        ..eventBatches.isEmpty();
      check(await db.select(db.serverSnapshots).get()).length.equals(2);
      check(await db.select(db.serverSnapshotBlobs).get()).length.equals(2);
      check(await db.select(db.serverEventBatches).get())
        .single.accountId.equals(eg.otherAccount.id);
    });

    test('append events with data', () async {
      await storeSnapshot(eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue1', lastEventId: 10));
      check(await append(eg.selfAccount, 12, '[{"id":11},{"id":12}]')).isTrue();
      check(await load(eg.selfAccount)).isNotNull()
        ..snapshot.lastEventId.equals(12)
        ..eventBatches.deepEquals([isBatch(12, '[{"id":11},{"id":12}]')]);
    });

    test('append events with data rejects non-advancing lastEventId', () async {
      await storeSnapshot(eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue1', lastEventId: 10));
      check(await append(eg.selfAccount, 10, '[{"id":10}]')).isFalse();
      check(await append(eg.selfAccount, 8, '[{"id":8}]')).isFalse();
      check(await load(eg.selfAccount)).isNotNull()
        ..snapshot.lastEventId.equals(10)
        ..eventBatches.isEmpty();
      check(await db.select(db.serverEventBatches).get()).isEmpty();
    });

    test('append events without data advances lastEventId only', () async {
      await storeSnapshot(eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue1', lastEventId: 10));
      check(await append(eg.selfAccount, 12, null)).isTrue();
      check(await load(eg.selfAccount)).isNotNull()
        ..snapshot.lastEventId.equals(12)
        ..eventBatches.isEmpty();
      check(await db.select(db.serverEventBatches).get()).isEmpty();
    });

    test('no append events for another queue', () async {
      final snapshot = eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue1', lastEventId: 10);
      await storeSnapshot(snapshot);
      await append(eg.selfAccount, 11, '[{"id":11}]');

      check(await append(eg.selfAccount, 12, '[{"id":12}]', queueId: 'queue0'))
        .isFalse();
      check(await append(eg.selfAccount, 13, null, queueId: 'queue0'))
        .isFalse();
      check(await load(eg.selfAccount)).isNotNull()
        ..snapshot.lastEventId.equals(11)
        ..eventBatches.deepEquals([isBatch(11, '[{"id":11}]')]);
      check(await db.select(db.serverEventBatches).get()).length.equals(1);
    });

    test('no append events without snapshot', () async {
      check(await append(eg.selfAccount, 11, '[{"id":11}]')).isFalse();
      check(await db.select(db.serverEventBatches).get()).isEmpty();
    });

    test('truncate event log', () async {
      final snapshot = eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue1', lastEventId: 10);
      await storeSnapshot(snapshot);
      await append(eg.selfAccount, 11, '[{"id":11}]');
      await storeSnapshot(eg.serverSnapshot(account: eg.otherAccount,
        queueId: 'queue1', lastEventId: 10));
      await append(eg.otherAccount, 11, '[{"id":11}]');

      check(await db.truncateServerEventLog(eg.selfAccount.id,
        queueId: 'queue1', lastEventId: 12)).isTrue();
      check(await load(eg.selfAccount)).isNotNull()
        ..snapshot.equals(snapshot.copyWith(
            lastEventId: 12, eventLogTruncated: true))
        ..eventBatches.isEmpty();
      check(await db.select(db.serverEventBatches).get())
        .single.accountId.equals(eg.otherAccount.id);

      // Appending then just advances lastEventId.
      check(await append(eg.selfAccount, 13, null)).isTrue();
      check(await load(eg.selfAccount)).isNotNull().snapshot
        ..lastEventId.equals(13)
        ..eventLogTruncated.isTrue();

      // A fresh snapshot starts with a fresh event log.
      final newSnapshot = eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue2', lastEventId: 20, eventLogTruncated: false);
      await storeSnapshot(newSnapshot);
      check(await load(eg.selfAccount)).isNotNull()
        .snapshot.equals(newSnapshot);
    });

    test('no truncate event log for another queue', () async {
      final snapshot = eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue1', lastEventId: 10);
      await storeSnapshot(snapshot);
      await append(eg.selfAccount, 11, '[{"id":11}]');

      check(await db.truncateServerEventLog(eg.selfAccount.id,
        queueId: 'queue0', lastEventId: 12)).isFalse();
      check(await load(eg.selfAccount)).isNotNull()
        ..snapshot.equals(snapshot.copyWith(lastEventId: 11))
        ..eventBatches.deepEquals([isBatch(11, '[{"id":11}]')]);
    });

    test('no truncate event log without snapshot', () async {
      check(await db.truncateServerEventLog(eg.selfAccount.id,
        queueId: 'queue1', lastEventId: 12)).isFalse();
      check(await db.select(db.serverSnapshots).get()).isEmpty();
    });

    test('load data gives event batches in order', () async {
      await storeSnapshot(eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue1', lastEventId: 10));
      await storeSnapshot(eg.serverSnapshot(account: eg.otherAccount,
        queueId: 'queue1', lastEventId: 10));
      await append(eg.selfAccount, 11, '[{"id":11}]');
      await append(eg.otherAccount, 11, '[{"id":11}]');
      await append(eg.selfAccount, 12, null);
      await append(eg.selfAccount, 14, '[{"id":13},{"id":14}]');
      await append(eg.selfAccount, 15, '[{"id":15}]');
      check(await load(eg.selfAccount)).isNotNull()
        ..snapshot.lastEventId.equals(15)
        ..eventBatches.deepEquals([
          isBatch(11, '[{"id":11}]'),
          isBatch(14, '[{"id":13},{"id":14}]'),
          isBatch(15, '[{"id":15}]'),
        ]);
    });

    test('load data without event batches', () async {
      final snapshot = eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue1', lastEventId: 10);
      await storeSnapshot(snapshot);
      await append(eg.selfAccount, 11, '[{"id":11}]');
      check(await db.loadServerData(eg.selfAccount.id, includeEventBatches: false))
        .isNotNull()
        ..snapshot.equals(snapshot.copyWith(lastEventId: 11))
        ..eventBatches.isEmpty();
    });

    test('load ignores event batches of other queues', () async {
      await storeSnapshot(eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue1', lastEventId: 10));
      await append(eg.selfAccount, 11, '[{"id":11}]');
      await db.into(db.serverEventBatches).insert(ServerEventBatchesCompanion.insert(
        accountId: eg.selfAccount.id, queueId: 'queue0', lastEventId: 9,
        data: utf8.encode('[{"id":9}]')));
      check(await load(eg.selfAccount)).isNotNull()
        .eventBatches.deepEquals([isBatch(11, '[{"id":11}]')]);
      check(await db.loadServerSnapshotInfo(eg.selfAccount.id)).isNotNull()
        .has((x) => x.eventBatchesSize, 'eventBatchesSize')
        .equals(utf8.encode('[{"id":11}]').length);
    });

    test('load snapshot info', () async {
      await storeSnapshot(eg.serverSnapshot(account: eg.selfAccount,
          queueId: 'queue1', lastEventId: 10,
          appVersion: '2.0.0+3', timestamp: 1771389742),
        data: '{"queue_id":"queue1","last_event_id":10}');
      check(await db.loadServerSnapshotInfo(eg.selfAccount.id)).equals((
        realmUrl: eg.selfAccount.realmUrl.toString(),
        userId: eg.selfAccount.userId,
        queueId: 'queue1', lastEventId: 10,
        appVersion: '2.0.0+3', timestamp: 1771389742,
        eventLogTruncated: false,
        snapshotSize: 40, eventBatchesSize: 0,
      ));

      await append(eg.selfAccount, 11, '[{"id":11}]');
      await append(eg.selfAccount, 12, null);
      await append(eg.selfAccount, 14, '[{"id":13},{"id":14}]');
      check(await db.loadServerSnapshotInfo(eg.selfAccount.id)).equals((
        realmUrl: eg.selfAccount.realmUrl.toString(),
        userId: eg.selfAccount.userId,
        queueId: 'queue1', lastEventId: 14,
        appVersion: '2.0.0+3', timestamp: 1771389742,
        eventLogTruncated: false,
        snapshotSize: 40, eventBatchesSize: 11 + 21,
      ));

      await db.truncateServerEventLog(eg.selfAccount.id,
        queueId: 'queue1', lastEventId: 15);
      check(await db.loadServerSnapshotInfo(eg.selfAccount.id)).equals((
        realmUrl: eg.selfAccount.realmUrl.toString(),
        userId: eg.selfAccount.userId,
        queueId: 'queue1', lastEventId: 15,
        appVersion: '2.0.0+3', timestamp: 1771389742,
        eventLogTruncated: true,
        snapshotSize: 40, eventBatchesSize: 0,
      ));
    });

    test('load snapshot info, no snapshot', () async {
      check(await db.loadServerSnapshotInfo(eg.selfAccount.id)).isNull();
    });

    test('clear server data', () async {
      await storeSnapshot(eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue1', lastEventId: 10));
      await append(eg.selfAccount, 11, '[{"id":11}]');
      final otherSnapshot = eg.serverSnapshot(account: eg.otherAccount,
        queueId: 'queue1', lastEventId: 10);
      await storeSnapshot(otherSnapshot);
      await append(eg.otherAccount, 11, '[{"id":11}]');

      await db.clearServerData(eg.selfAccount.id);
      check(await load(eg.selfAccount)).isNull();
      check(await db.select(db.serverSnapshotBlobs).get())
        .single.accountId.equals(eg.otherAccount.id);
      check(await db.loadServerSnapshotInfo(eg.selfAccount.id)).isNull();
      check(await load(eg.otherAccount)).isNotNull()
        ..snapshot.equals(otherSnapshot.copyWith(lastEventId: 11))
        ..eventBatches.length.equals(1);
      check(await db.select(db.serverEventBatches).get())
        .single.accountId.equals(eg.otherAccount.id);

      await db.clearServerData(eg.selfAccount.id);
      check(await load(eg.otherAccount)).isNotNull();
    });

    test('wipeAccount preserves server data while purgeAccount and sweepOrphanAccounts remove both', () async {
      await db.into(db.messageDbAccounts).insert(MessageDbAccountsCompanion.insert(
        accountId: Value(eg.selfAccount.id),
        realmUrl: eg.selfAccount.realmUrl.toString(),
        userId: eg.selfAccount.userId,
        formatVersion: MessageDatabase.currentFormatVersion,
        epoch: 1,
        appliedThroughEventId: const Value(10),
        eventHighWater: 100,
      ));
      await storeSnapshot(eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue1', lastEventId: 10));
      await append(eg.selfAccount, 11, '[{"id":11}]');

      await db.into(db.messageDbAccounts).insert(MessageDbAccountsCompanion.insert(
        accountId: Value(eg.otherAccount.id),
        realmUrl: eg.otherAccount.realmUrl.toString(),
        userId: eg.otherAccount.userId,
        formatVersion: MessageDatabase.currentFormatVersion,
        epoch: 1,
        appliedThroughEventId: const Value(10),
        eventHighWater: 100,
      ));
      await storeSnapshot(eg.serverSnapshot(account: eg.otherAccount,
        queueId: 'queue2', lastEventId: 20));
      await append(eg.otherAccount, 21, '[{"id":21}]');

      // wipeAccount wipes only message cache, preserving server snapshot data.
      await db.wipeAccount(eg.selfAccount.id);
      check(await db.select(db.messageDbAccounts).get())
        .single.has((x) => x.accountId, 'accountId').equals(eg.otherAccount.id);
      check(await load(eg.selfAccount)).isNotNull();

      // Re-insert messageDbAccount for selfAccount and test purgeAccount.
      await db.into(db.messageDbAccounts).insert(MessageDbAccountsCompanion.insert(
        accountId: Value(eg.selfAccount.id),
        realmUrl: eg.selfAccount.realmUrl.toString(),
        userId: eg.selfAccount.userId,
        formatVersion: MessageDatabase.currentFormatVersion,
        epoch: 2,
        appliedThroughEventId: const Value(11),
        eventHighWater: 100,
      ));
      await db.purgeAccount(eg.selfAccount.id);
      check(await db.select(db.messageDbAccounts).get())
        .single.has((x) => x.accountId, 'accountId').equals(eg.otherAccount.id);
      check(await load(eg.selfAccount)).isNull();
      check(await load(eg.otherAccount)).isNotNull();

      // sweepOrphanAccounts removes both message cache and server data for non-live ids.
      await db.sweepOrphanAccounts({});
      check(await db.select(db.messageDbAccounts).get()).isEmpty();
      check(await db.select(db.serverSnapshots).get()).isEmpty();
      check(await db.select(db.serverSnapshotBlobs).get()).isEmpty();
      check(await db.select(db.serverEventBatches).get()).isEmpty();
    });
  });

  group('MessageDatabase.openFile', () {
    test('pragmas, persistence across close/reopen, purgeAccount, and incremental vacuum', () async {
      final dir = await Directory.systemTemp.createTemp('zulip_msg_db_openfile_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(p.join(dir.path, 'zulip-messages.db'));

      final db1 = MessageDatabase.openFile(file);
      // Force DB open and pragma/migration execution.
      await db1.select(db1.messageDbAccounts).get();

      final autoVacuum = await db1.customSelect('PRAGMA auto_vacuum').getSingle();
      check(autoVacuum.read<int>('auto_vacuum')).equals(2);
      final journalMode = await db1.customSelect('PRAGMA journal_mode').getSingle();
      check(journalMode.read<String>('journal_mode')).equals('wal');
      final synchronous = await db1.customSelect('PRAGMA synchronous').getSingle();
      check(synchronous.read<int>('synchronous')).equals(1);
      final foreignKeys = await db1.customSelect('PRAGMA foreign_keys').getSingle();
      check(foreignKeys.read<int>('foreign_keys')).equals(1);

      await db1.transaction(() async {
        await db1.upsertAccountInTxn(
          accountId: eg.selfAccount.id,
          realmUrl: eg.selfAccount.realmUrl,
          userId: eg.selfAccount.userId,
          epoch: 1,
          queueId: 'q1',
          appliedThroughEventId: 10,
          eventHighWater: 50,
          lastLiveAt: 1000,
        );
        await db1.into(db1.storedMessages).insert(StoredMessagesCompanion.insert(
          accountId: eg.selfAccount.id,
          id: 42,
          senderId: eg.selfUser.userId,
          timestamp: 1000,
          flags: 1,
          isMeMessage: false,
          editState: 0,
          displayRecipientCleared: false,
          epoch: 1,
          tracked: true,
          bodyBytes: 12,
          channelId: const Value(5),
          topic: const Value('openFile'),
          topicKey: const Value('openfile'),
        ));
        await db1.into(db1.storedMessageBodies).insert(StoredMessageBodiesCompanion.insert(
          accountId: eg.selfAccount.id,
          messageId: 42,
          content: '<p>persisted</p>',
          json: Uint8List.fromList([1, 2, 3, 4]),
        ));
      });
      await db1.storeServerSnapshot(
        eg.serverSnapshot(account: eg.selfAccount, queueId: 'q1', lastEventId: 10),
        data: Uint8List.fromList(utf8.encode('{"queue_id":"q1"}')),
      );
      await db1.close();

      // Reopen on disk and confirm all rows and Stage-1 snapshot persisted.
      final db2 = MessageDatabase.openFile(file);
      addTearDown(db2.close);
      final acct = await db2.ensureAccount(
        accountId: eg.selfAccount.id,
        realmUrl: eg.selfAccount.realmUrl,
        userId: eg.selfAccount.userId,
      );
      check(acct).isNotNull().has((a) => a.epoch, 'epoch').equals(1);
      final rows = await (db2.select(db2.storedMessages)
        ..where((m) => m.accountId.equals(eg.selfAccount.id))).get();
      check(rows).single.has((r) => r.id, 'id').equals(42);
      final serverData = await db2.loadServerData(eg.selfAccount.id);
      check(serverData).isNotNull().has((d) => d.snapshot.queueId, 'queueId').equals('q1');

      // purgeAccount removes both message cache and server snapshot tables.
      await db2.purgeAccount(eg.selfAccount.id);
      check(await db2.select(db2.messageDbAccounts).get()).isEmpty();
      check(await db2.select(db2.storedMessages).get()).isEmpty();
      check(await db2.select(db2.storedMessageBodies).get()).isEmpty();
      check(await db2.loadServerData(eg.selfAccount.id)).isNull();

      // Incremental vacuum succeeds outside any transaction.
      await db2.runIncrementalVacuum(10);
      check(db2.debugIncrementalVacuumCalls).equals(2);
    });
  });

  group('FTS5 search index and v1 -> v2 migration', () {
    test('extractPlainTextFromHtml separates block elements and decodes entities', () {
      check(extractPlainTextFromHtml('')).equals('');
      check(extractPlainTextFromHtml('<p>foo</p><p>bar</p>')).equals('foo bar');
      check(extractPlainTextFromHtml('<p>line1<br>line2<br/>line3</p>'))
        .equals('line1 line2 line3');
      check(extractPlainTextFromHtml('<p>A &amp; B &lt;tag&gt; &#39;quoted&#39;</p>'))
        .equals("A & B <tag> 'quoted'");
      check(extractPlainTextFromHtml('<ul><li>one</li><li>two</li></ul>'))
        .equals('one two');
      check(extractPlainTextFromHtml('<p><b>hel</b>lo</p>')).equals('hello');
    });

    test('searchStoredMessages, FTS5 sync on edits/moves/submessages, and cascade cleanup', () async {
      final db = MessageDatabase(NativeDatabase.memory(setup: configureMessageDbPragmas));
      addTearDown(db.close);

      Future<int> ftsCount() async {
        final row = await db.customSelect('SELECT COUNT(*) AS c FROM stored_message_fts').getSingle();
        return row.read<int>('c');
      }

      await db.transaction(() async {
        await db.upsertAccountInTxn(
          accountId: 1,
          realmUrl: eg.selfAccount.realmUrl,
          userId: eg.selfUser.userId,
          epoch: 1,
          queueId: 'q1',
          appliedThroughEventId: 1,
          eventHighWater: 100,
          lastLiveAt: 1000,
        );
        await db.upsertAccountInTxn(
          accountId: 2,
          realmUrl: eg.otherAccount.realmUrl,
          userId: eg.otherUser.userId,
          epoch: 1,
          queueId: 'q2',
          appliedThroughEventId: 1,
          eventHighWater: 100,
          lastLiveAt: 1000,
        );
      });

      final s1 = eg.stream(streamId: 10, name: 'General');
      final s2 = eg.stream(streamId: 20, name: 'Design');
      final m1 = eg.streamMessage(
        id: 10, stream: s1, topic: 'Café notes', timestamp: 100,
        content: '<p>espresso</p><p>croissant</p>',
      );
      final m2 = eg.streamMessage(
        id: 20, stream: s2, topic: 'Icons', timestamp: 200,
        content: '<p>Check offline search synchronization</p>',
      );
      final m3 = eg.dmMessage(
        id: 30, from: eg.selfUser, to: [eg.otherUser], timestamp: 300,
        content: '<p>Secret secret roadmap</p>',
      );
      final m4 = eg.streamMessage(
        id: 40, stream: s1, topic: 'Other', timestamp: 400,
        content: '<p>café latte</p>',
      );

      await db.transaction(() async {
        for (final m in <Message>[m1, m2, m3, m4]) {
          await upsertStoredMessageRecordInDb(
            db,
            accountId: 1,
            record: StoredMessageCodec.encode(
              accountId: 1,
              message: m,
              rawMap: m.toJson(),
              epoch: 1,
              tracked: true,
            ),
          );
        }
        // Account 2 row should remain isolated from Account 1 queries.
        await upsertStoredMessageRecordInDb(
          db,
          accountId: 2,
          record: StoredMessageCodec.encode(
            accountId: 2,
            message: m1,
            rawMap: m1.toJson(),
            epoch: 1,
            tracked: true,
          ),
        );
      });
      check(await ftsCount()).equals(5);

      // Diacritic-insensitive + block separation.
      var hits = await db.searchStoredMessages(
        1,
        spec: const StoredMessageSearchSpec(positiveFtsMatch: '"cafe"'),
        limit: 20,
      );
      check(hits.map((r) => r.row.id).toList()).deepEquals([40, 10]);

      hits = await db.searchStoredMessages(
        1,
        spec: const StoredMessageSearchSpec(positiveFtsMatch: '"espresso" AND "croissant"'),
        limit: 20,
      );
      check(hits.map((r) => r.row.id).toList()).deepEquals([10]);

      // Prefix search & pagination beforeMessageId.
      hits = await db.searchStoredMessages(
        1,
        spec: const StoredMessageSearchSpec(positiveFtsMatch: '"synch"*'),
        limit: 20,
      );
      check(hits.map((r) => r.row.id).toList()).deepEquals([20]);

      hits = await db.searchStoredMessages(
        1,
        spec: const StoredMessageSearchSpec(positiveFtsMatch: '"cafe"'),
        beforeMessageId: 40,
        limit: 20,
      );
      check(hits.map((r) => r.row.id).toList()).deepEquals([10]);

      // Replacing a message via upsert replaces FTS row without leaking old rowid.
      final m4Updated = eg.streamMessage(
        id: 40, stream: s1, topic: 'Other', timestamp: 400,
        content: '<p>matcha tea</p>',
      );
      await db.transaction(() => upsertStoredMessageRecordInDb(
        db,
        accountId: 1,
        record: StoredMessageCodec.encode(
          accountId: 1,
          message: m4Updated,
          rawMap: m4Updated.toJson(),
          epoch: 1,
          tracked: true,
        ),
      ));
      check(await ftsCount()).equals(5);
      hits = await db.searchStoredMessages(
        1,
        spec: const StoredMessageSearchSpec(positiveFtsMatch: '"cafe"'),
        limit: 20,
      );
      check(hits.map((r) => r.row.id).toList()).deepEquals([10]);

      // Purge channel 20 -> m2 deleted from FTS via cascade trigger.
      await db.transaction(() => db.purgeChannelDataInTxn(1, 20));
      check(await ftsCount()).equals(4);
      hits = await db.searchStoredMessages(
        1,
        spec: const StoredMessageSearchSpec(positiveFtsMatch: '"offline"'),
        limit: 20,
      );
      check(hits).isEmpty();

      // Retention purge below timestamp 150 -> m1 deleted from FTS.
      await db.transaction(() => db.purgeExpiredRetentionRowsInTxn(
        1,
        channelCutoffTimestamps: {10: 150},
      ));
      check(await ftsCount()).equals(3);

      // Eviction below 35 -> m3 deleted from FTS.
      await db.transaction(() => db.deleteEvictedChunkInTxn(1, cutoffId: 35));
      check(await ftsCount()).equals(2);

      // wipeAccount(1) deletes remaining m4 in account 1, keeping account 2's row.
      await db.wipeAccount(1);
      check(await ftsCount()).equals(1);

      // sweepOrphanAccounts cleans up account 2's FTS row too.
      await db.sweepOrphanAccounts({});
      check(await ftsCount()).equals(0);
    });

    test('schema v1 -> v2 upgrade preserves snapshots/messages and backfills FTS5', () async {
      final dir = await Directory.systemTemp.createTemp('zulip_msg_db_migrate_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(p.join(dir.path, 'zulip-messages.db'));

      // Build a real v1 schema file directly with sqlite3 (without FTS5 table).
      final raw = sqlite.sqlite3.open(file.path);
      try {
        raw.execute('PRAGMA auto_vacuum = INCREMENTAL;');
        raw.execute('PRAGMA journal_mode = WAL;');
        raw.execute('PRAGMA foreign_keys = ON;');
        raw.execute('''
          CREATE TABLE message_db_accounts (
            account_id INTEGER NOT NULL PRIMARY KEY,
            realm_url TEXT NOT NULL,
            user_id INTEGER NOT NULL,
            format_version INTEGER NOT NULL,
            epoch INTEGER NOT NULL,
            queue_id TEXT NULL,
            applied_through_event_id INTEGER NULL,
            event_high_water INTEGER NOT NULL,
            last_live_at INTEGER NULL,
            evicted_below_message_id INTEGER NOT NULL DEFAULT 0,
            total_body_bytes INTEGER NOT NULL DEFAULT 0
          );
          CREATE TABLE stored_messages (
            account_id INTEGER NOT NULL REFERENCES message_db_accounts (account_id) ON DELETE CASCADE,
            id INTEGER NOT NULL,
            channel_id INTEGER NULL,
            topic TEXT NULL,
            topic_key TEXT NULL,
            dm_key TEXT NULL,
            sender_id INTEGER NOT NULL,
            timestamp INTEGER NOT NULL,
            flags INTEGER NOT NULL,
            is_me_message INTEGER NOT NULL,
            edit_state INTEGER NOT NULL,
            last_edit_timestamp INTEGER NULL,
            display_recipient_cleared INTEGER NOT NULL,
            epoch INTEGER NOT NULL,
            tracked INTEGER NOT NULL,
            body_bytes INTEGER NOT NULL,
            unknown_flags TEXT NULL,
            PRIMARY KEY (account_id, id)
          ) WITHOUT ROWID;
          CREATE TABLE stored_message_bodies (
            account_id INTEGER NOT NULL,
            message_id INTEGER NOT NULL,
            content TEXT NOT NULL,
            json BLOB NOT NULL,
            PRIMARY KEY (account_id, message_id),
            FOREIGN KEY (account_id, message_id) REFERENCES stored_messages (account_id, id) ON DELETE CASCADE
          );
          CREATE TABLE stored_reactions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_id INTEGER NOT NULL,
            message_id INTEGER NOT NULL,
            seq INTEGER NOT NULL,
            user_id INTEGER NOT NULL,
            reaction_type TEXT NOT NULL,
            emoji_code TEXT NOT NULL,
            emoji_name TEXT NOT NULL,
            FOREIGN KEY (account_id, message_id) REFERENCES stored_messages (account_id, id) ON DELETE CASCADE,
            UNIQUE (account_id, message_id, user_id, reaction_type, emoji_code)
          );
          CREATE TABLE stored_submessages (
            account_id INTEGER NOT NULL,
            submessage_id INTEGER NOT NULL,
            message_id INTEGER NOT NULL,
            sender_id INTEGER NOT NULL,
            msg_type TEXT NOT NULL,
            content TEXT NOT NULL,
            PRIMARY KEY (account_id, submessage_id),
            FOREIGN KEY (account_id, message_id) REFERENCES stored_messages (account_id, id) ON DELETE CASCADE
          );
          CREATE TABLE coverage_intervals (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_id INTEGER NOT NULL REFERENCES message_db_accounts (account_id) ON DELETE CASCADE,
            narrow_key TEXT NOT NULL,
            lo INTEGER NOT NULL,
            hi INTEGER NULL,
            epoch INTEGER NOT NULL,
            tracked INTEGER NOT NULL,
            verified_at INTEGER NOT NULL
          );
          CREATE TABLE message_db_channels (
            account_id INTEGER NOT NULL REFERENCES message_db_accounts (account_id) ON DELETE CASCADE,
            channel_id INTEGER NOT NULL,
            history_public_to_subscribers INTEGER NOT NULL,
            PRIMARY KEY (account_id, channel_id)
          );
          CREATE TABLE server_snapshots (
            account_id INTEGER NOT NULL PRIMARY KEY,
            queue_id TEXT NOT NULL,
            last_event_id INTEGER NOT NULL,
            app_version TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            event_log_truncated INTEGER NOT NULL DEFAULT 0
          );
          CREATE TABLE server_snapshot_blobs (
            account_id INTEGER NOT NULL PRIMARY KEY,
            data BLOB NOT NULL
          );
          CREATE TABLE server_event_batches (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_id INTEGER NOT NULL,
            queue_id TEXT NOT NULL,
            last_event_id INTEGER NOT NULL,
            data BLOB NOT NULL
          );
        ''');

        raw.execute(
          'INSERT INTO server_snapshots VALUES (?, ?, ?, ?, ?, ?)',
          [eg.selfAccount.id, 'q-v1', 55, '1.0.0+1', 1770000000, 0],
        );
        raw.execute(
          'INSERT INTO server_snapshot_blobs VALUES (?, ?)',
          [eg.selfAccount.id, utf8.encode('{"queue_id":"q-v1"}')],
        );
        raw.execute(
          'INSERT INTO server_event_batches (account_id, queue_id, last_event_id, data) VALUES (?, ?, ?, ?)',
          [eg.selfAccount.id, 'q-v1', 56, utf8.encode('[{"id":56}]')],
        );

        raw.execute(
          'INSERT INTO message_db_accounts '
          '(account_id, realm_url, user_id, format_version, epoch, queue_id, applied_through_event_id, event_high_water, last_live_at, evicted_below_message_id, total_body_bytes) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [eg.selfAccount.id, eg.selfAccount.realmUrl.toString(), eg.selfUser.userId, 1, 1, 'q-v1', 56, 100, 1770000000, 0, 200],
        );

        final msg1 = eg.streamMessage(
          id: 91,
          stream: eg.stream(streamId: 5, name: 'General'),
          topic: 'Migration Topic',
          content: '<p>Legacy &amp; cached</p>',
        );
        final msg2 = eg.streamMessage(
          id: 92,
          stream: eg.stream(streamId: 5, name: 'General'),
          topic: 'Poll Topic',
          sender: eg.selfUser,
          content: '<p>/poll Best editor?</p>',
        );
        for (final m in [msg1, msg2]) {
          raw.execute(
            'INSERT INTO stored_messages '
            '(account_id, id, channel_id, topic, topic_key, dm_key, sender_id, timestamp, flags, is_me_message, edit_state, last_edit_timestamp, display_recipient_cleared, epoch, tracked, body_bytes, unknown_flags) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [
              eg.selfAccount.id, m.id, 5, m.topic.apiName, m.topic.apiName.toUpperCase(),
              null, m.senderId, m.timestamp, 1, 0, 0, null, 0, 1, 1, 100, null,
            ],
          );
          raw.execute(
            'INSERT INTO stored_message_bodies (account_id, message_id, content, json) VALUES (?, ?, ?, ?)',
            [eg.selfAccount.id, m.id, m.content, utf8.encode(jsonEncode(m.toJson()))],
          );
        }
        raw.execute(
          'INSERT INTO stored_submessages (account_id, submessage_id, message_id, sender_id, msg_type, content) '
          'VALUES (?, ?, ?, ?, ?, ?)',
          [
            eg.selfAccount.id,
            1,
            92,
            eg.selfUser.userId,
            'widget',
            jsonEncode({
              'widget_type': 'poll',
              'extra_data': {'question': 'Favorite fruit?', 'options': ['Mango', 'Kiwi']},
            }),
          ],
        );
        raw.execute('PRAGMA user_version = 1;');
      } finally {
        raw.close();
      }

      // Opening with schemaVersion == 2 must upgrade in-place without dropping anything.
      final db = MessageDatabase.openFile(file);
      addTearDown(db.close);

      final acct = await db.ensureAccount(
        accountId: eg.selfAccount.id,
        realmUrl: eg.selfAccount.realmUrl,
        userId: eg.selfUser.userId,
      );
      check(acct).isNotNull().has((a) => a.epoch, 'epoch').equals(1);

      final serverData = await db.loadServerData(eg.selfAccount.id);
      check(serverData).isNotNull()
        ..snapshot.queueId.equals('q-v1')
        ..snapshot.lastEventId.equals(55)
        ..eventBatches.length.equals(1);

      final bodyHits = await db.searchStoredMessages(
        eg.selfAccount.id,
        spec: const StoredMessageSearchSpec(positiveFtsMatch: '"legacy"'),
        limit: 10,
      );
      check(bodyHits.map((r) => r.row.id).toList()).deepEquals([91]);

      final topicHits = await db.searchStoredMessages(
        eg.selfAccount.id,
        spec: const StoredMessageSearchSpec(positiveFtsMatch: '"migration"'),
        limit: 10,
      );
      check(topicHits.map((r) => r.row.id).toList()).deepEquals([91]);

      final pollHits = await db.searchStoredMessages(
        eg.selfAccount.id,
        spec: const StoredMessageSearchSpec(positiveFtsMatch: '"mango"'),
        limit: 10,
      );
      check(pollHits.map((r) => r.row.id).toList()).deepEquals([92]);

      // Trigger cleans up FTS row on delete after migration.
      await db.transaction(() => deleteMessagesFromDb(db, accountId: eg.selfAccount.id, messageIds: [91]));
      final ftsCountRow = await db.customSelect('SELECT COUNT(*) AS c FROM stored_message_fts').getSingle();
      check(ftsCountRow.read<int>('c')).equals(1);
    });
  });
}
