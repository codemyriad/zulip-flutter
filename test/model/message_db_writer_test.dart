import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:test/scaffolding.dart';
import 'package:zulip/model/message_database.dart';
import 'package:zulip/model/message_db_writer.dart';

import '../example_data.dart' as eg;
import 'binding.dart';
import 'test_store.dart';

void main() {
  TestZulipBinding.ensureInitialized();

  group('MessageDbWriter', () {
    late MessageDatabase db;
    late MessageDbWriter writer;

    setUp(() async {
      db = MessageDatabase(NativeDatabase.memory(setup: configureMessageDbPragmas));
      await db.into(db.messageDbAccounts).insert(MessageDbAccountsCompanion.insert(
        accountId: const Value(1),
        realmUrl: 'https://chat.example.org',
        userId: 10,
        formatVersion: MessageDatabase.currentFormatVersion,
        epoch: 1,
        appliedThroughEventId: const Value(5),
        eventHighWater: 100,
      ));
      writer = MessageDbWriter(accountId: 1, openDb: () async => db);
    });

    tearDown(() async {
      await db.close();
    });

    test('serializes write jobs in strict FIFO order', () async {
      final order = <String>[];
      final gate = Completer<void>();

      check(writer.isIdle).isTrue();
      final f1 = writer.enqueueWrite((db, {required removalOnly}) async {
        order.add('start-1:$removalOnly');
        await gate.future;
        order.add('end-1');
        return 1;
      });
      check(writer.isIdle).isFalse();
      final f2 = writer.enqueueWrite((db, {required removalOnly}) async {
        order.add('run-2:$removalOnly');
        return 2;
      });

      await Future<void>.delayed(Duration.zero);
      check(order).deepEquals(['start-1:false']);

      gate.complete();
      check(await f1).equals(1);
      check(await f2).equals(2);
      check(writer.isIdle).isTrue();
      check(order).deepEquals(['start-1:false', 'end-1', 'run-2:false']);
    });

    test('read failure returns null and does not poison writer', () async {
      final result = await writer.runRead<int>((db) async {
        throw StateError('read boom');
      });
      check(result).isNull();
      check(writer.isPoisoned).isFalse();

      final acct = await (db.select(db.messageDbAccounts)
        ..where((a) => a.accountId.equals(1))).getSingle();
      check(acct.appliedThroughEventId).equals(5);

      var sawRemovalOnly = true;
      await writer.enqueueWrite((db, {required removalOnly}) async {
        sawRemovalOnly = removalOnly;
      });
      check(sawRemovalOnly).isFalse();
    });

    test('write failure poisons writer, switches queued writes to removal-only, and nulls watermark', () async {
      var poisonedCallbacks = 0;
      writer.onPoisoned = () => poisonedCallbacks++;

      final gate = Completer<void>();
      final queuedModes = <bool>[];

      final f1 = writer.enqueueWrite((db, {required removalOnly}) async {
        await gate.future;
        throw StateError('write boom');
      });
      final f2 = writer.enqueueWrite((db, {required removalOnly}) async {
        queuedModes.add(removalOnly);
      });

      await Future<void>.delayed(Duration.zero);
      gate.complete();
      check(await f1).isNull();
      await f2;

      check(writer.isPoisoned).isTrue();
      check(poisonedCallbacks).equals(1);
      check(queuedModes).deepEquals([true]);

      final acct = await (db.select(db.messageDbAccounts)
        ..where((a) => a.accountId.equals(1))).getSingle();
      check(acct.appliedThroughEventId).isNull();

      // Reads short-circuit to null while poisoned.
      var readCalled = false;
      check(await writer.runRead((db) async {
        readCalled = true;
        return 42;
      })).isNull();
      check(readCalled).isFalse();
    });

    test('enqueueEpochStart wipes and clears poison only on success', () async {
      await writer.enqueueWrite((db, {required removalOnly}) async {
        throw StateError('write boom');
      });
      check(writer.isPoisoned).isTrue();

      var sawWasPoisoned = false;
      final res = await writer.enqueueEpochStart((db, {required wasPoisoned}) async {
        sawWasPoisoned = wasPoisoned;
        await db.wipeAccount(1);
        await db.into(db.messageDbAccounts).insert(MessageDbAccountsCompanion.insert(
          accountId: const Value(1),
          realmUrl: 'https://chat.example.org',
          userId: 10,
          formatVersion: MessageDatabase.currentFormatVersion,
          epoch: 2,
          appliedThroughEventId: const Value(10),
          eventHighWater: 200,
        ));
        return true;
      });
      check(res).equals(true);
      check(sawWasPoisoned).isTrue();
      check(writer.isPoisoned).isFalse();
    });

    test('poisonInMemoryOnly during in-flight enqueueEpochStart keeps writer poisoned', () async {
      final gate = Completer<void>();
      final epochFuture = writer.enqueueEpochStart((db, {required wasPoisoned}) async {
        await gate.future;
        return true;
      });
      await Future<void>.delayed(Duration.zero);

      writer.poisonInMemoryOnly();
      check(writer.isPoisoned).isTrue();

      gate.complete();
      check(await epochFuture).isNull();
      check(writer.isPoisoned).isTrue();
    });

    test('enqueuePurge removes account cache and server data', () async {
      await db.storeServerSnapshot(
        eg.serverSnapshot(account: eg.selfAccount).copyWith(accountId: 1),
        data: Uint8List.fromList([1, 2, 3]),
      );
      await writer.enqueuePurge();
      check(await db.select(db.messageDbAccounts).get()).isEmpty();
      check(await db.select(db.serverSnapshots).get()).isEmpty();
    });

    test('TestGlobalStore.removeAccount purges account data via FIFO writer', () async {
      final globalStore = TestGlobalStore(accounts: [eg.selfAccount]);
      addTearDown(globalStore.backend.closeMessageDb);
      final w = globalStore.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await w.enqueueEpochStart((db, {required wasPoisoned}) async {
        await db.into(db.messageDbAccounts).insert(MessageDbAccountsCompanion.insert(
          accountId: Value(eg.selfAccount.id),
          realmUrl: eg.selfAccount.realmUrl.toString(),
          userId: eg.selfAccount.userId,
          formatVersion: MessageDatabase.currentFormatVersion,
          epoch: 1,
          appliedThroughEventId: const Value(1),
          eventHighWater: 10,
        ));
      });
      check(await globalStore.backend.debugMessageDatabase!
        .select(globalStore.backend.debugMessageDatabase!.messageDbAccounts).get()).length.equals(1);

      await globalStore.removeAccount(eg.selfAccount.id);
      await w.drainForTesting();
      check(await globalStore.backend.debugMessageDatabase!
        .select(globalStore.backend.debugMessageDatabase!.messageDbAccounts).get()).isEmpty();
    });
  });
}
