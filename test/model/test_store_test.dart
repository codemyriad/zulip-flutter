import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:zulip/model/database.dart';

import '../example_data.dart' as eg;
import '../fake_async.dart';
import 'binding.dart';
import 'store_checks.dart';
import 'test_store.dart';

void main() {
  TestZulipBinding.ensureInitialized();

  // These mirror tests of [AppDatabase] in database_test.dart,
  // to check that the fake has the same semantics as the real backend.
  group('TestGlobalStoreBackend server data', () {
    late TestGlobalStore globalStore;
    late TestGlobalStoreBackend backend;

    void prepare() {
      globalStore = TestGlobalStore(accounts: [eg.selfAccount, eg.otherAccount]);
      backend = globalStore.backend;
    }

    Future<bool> append(int lastEventId, String? data, {String queueId = 'queue1'}) {
      return backend.doAppendServerEvents(eg.selfAccount.id,
        queueId: queueId, lastEventId: lastEventId,
        data: data == null ? null : utf8.encode(data));
    }

    test('store snapshot replaces snapshot and its batches', () async {
      prepare();
      await backend.doStoreServerSnapshot(eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue1', lastEventId: 10));
      await append(11, '[{"id":11}]');

      final newSnapshot = eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue2', lastEventId: 20);
      check(await backend.doStoreServerSnapshot(newSnapshot)).isTrue();
      check(backend.serverSnapshotOf(eg.selfAccount.id)).equals(newSnapshot);
      check(backend.serverEventBatchesOf(eg.selfAccount.id)).isEmpty();
    });

    test('no store snapshot when account missing', () async {
      prepare();
      final account = eg.account(user: eg.thirdUser);
      check(await backend.doStoreServerSnapshot(
        eg.serverSnapshot(account: account))).isFalse();
      check(backend.serverSnapshotOf(account.id)).isNull();
    });

    test('append events', () async {
      prepare();
      await backend.doStoreServerSnapshot(eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue1', lastEventId: 10));
      check(await append(11, '[{"id":11}]')).isTrue();
      check(await append(12, null)).isTrue();
      check(backend.serverSnapshotOf(eg.selfAccount.id)!).lastEventId.equals(12);

      check(await append(13, '[{"id":13}]', queueId: 'queue0')).isFalse();
      check(await append(14, null, queueId: 'queue0')).isFalse();
      check(backend.serverSnapshotOf(eg.selfAccount.id)!).lastEventId.equals(12);
      check(backend.serverEventBatchesOf(eg.selfAccount.id)).single
        ..queueId.equals('queue1')
        ..lastEventId.equals(11)
        ..data.deepEquals(utf8.encode('[{"id":11}]'));
    });

    test('no append events without snapshot', () async {
      prepare();
      check(await append(11, '[{"id":11}]')).isFalse();
      check(backend.serverEventBatchesOf(eg.selfAccount.id)).isEmpty();
    });

    test('load', () async {
      prepare();
      final snapshot = eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue1', lastEventId: 10,
        appVersion: '2.0.0+3', timestamp: 1771389742,
        data: utf8.encode('{"queue_id":"queue1","last_event_id":10}'));
      await backend.doStoreServerSnapshot(snapshot);
      await append(11, '[{"id":11}]');
      await append(12, null);
      await append(14, '[{"id":13},{"id":14}]');

      check(await backend.doLoadServerSnapshotInfo(eg.selfAccount.id)).equals((
        queueId: 'queue1', lastEventId: 14,
        appVersion: '2.0.0+3', timestamp: 1771389742,
        snapshotSize: 40, eventBatchesSize: 11 + 21,
      ));
      check(await backend.doLoadServerData(eg.selfAccount.id)).isNotNull()
        ..snapshot.equals(snapshot.copyWith(lastEventId: 14))
        ..eventBatches.deepEquals(<Condition<Object?>>[
          (it) => it.isA<ServerEventBatch>().lastEventId.equals(11),
          (it) => it.isA<ServerEventBatch>().lastEventId.equals(14),
        ]);
      check(await backend.doLoadServerData(eg.selfAccount.id,
          includeEventBatches: false)).isNotNull()
        .eventBatches.isEmpty();

      check(await backend.doLoadServerSnapshotInfo(eg.otherAccount.id)).isNull();
      check(await backend.doLoadServerData(eg.otherAccount.id)).isNull();
    });

    test('clear server data', () async {
      prepare();
      await backend.doStoreServerSnapshot(eg.serverSnapshot(account: eg.selfAccount));
      await backend.doStoreServerSnapshot(eg.serverSnapshot(account: eg.otherAccount));
      await backend.doClearServerData(eg.selfAccount.id);
      check(backend.serverSnapshotOf(eg.selfAccount.id)).isNull();
      check(backend.serverSnapshotOf(eg.otherAccount.id)).isNotNull();
    });

    test('remove account clears server data', () async {
      prepare();
      await backend.doStoreServerSnapshot(eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue1'));
      await append(11, '[{"id":11}]');
      await globalStore.removeAccount(eg.selfAccount.id);
      check(backend.serverSnapshotOf(eg.selfAccount.id)).isNull();
      check(backend.serverEventBatchesOf(eg.selfAccount.id)).isEmpty();
      check(await backend.doStoreServerSnapshot(
        eg.serverSnapshot(account: eg.selfAccount))).isFalse();
    });

    test('store snapshot for account added later', () async {
      globalStore = TestGlobalStore(accounts: []);
      backend = globalStore.backend;
      await globalStore.add(eg.selfAccount, eg.initialSnapshot());
      check(await backend.doStoreServerSnapshot(
        eg.serverSnapshot(account: eg.selfAccount))).isTrue();
    });

    test('errors are thrown once', () async {
      prepare();
      final error = Exception('oops');
      backend.storeServerSnapshotError = error;
      await check(backend.doStoreServerSnapshot(
        eg.serverSnapshot(account: eg.selfAccount))).throws<Exception>();
      check(await backend.doStoreServerSnapshot(
        eg.serverSnapshot(account: eg.selfAccount, queueId: 'queue1'))).isTrue();

      backend.appendServerEventsError = error;
      await check(append(11, null)).throws<Exception>();
      check(await append(11, null)).isTrue();

      backend.loadServerSnapshotInfoError = error;
      await check(backend.doLoadServerSnapshotInfo(eg.selfAccount.id))
        .throws<Exception>();
      check(await backend.doLoadServerSnapshotInfo(eg.selfAccount.id)).isNotNull();

      backend.loadServerDataError = error;
      await check(backend.doLoadServerData(eg.selfAccount.id)).throws<Exception>();
      check(await backend.doLoadServerData(eg.selfAccount.id)).isNotNull();
    });

    test('append waits for gate', () => awaitFakeAsync((async) async {
      prepare();
      await backend.doStoreServerSnapshot(eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue1', lastEventId: 10));
      final gate = Completer<void>();
      backend.appendServerEventsGate = gate.future;
      bool? result;
      unawaited(append(11, '[{"id":11}]').then((r) => result = r));
      async.flushMicrotasks();
      check(result).isNull();
      check(backend.serverEventBatchesOf(eg.selfAccount.id)).isEmpty();

      gate.complete();
      async.flushMicrotasks();
      check(result).equals(true);
      check(backend.serverEventBatchesOf(eg.selfAccount.id)).single
        .lastEventId.equals(11);
    }));

    test('load waits for gate', () => awaitFakeAsync((async) async {
      prepare();
      await backend.doStoreServerSnapshot(eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue1', lastEventId: 10));
      final gate = Completer<void>();
      backend.loadServerDataGate = gate.future;
      ServerData? result;
      unawaited(backend.doLoadServerData(eg.selfAccount.id)
        .then((r) => result = r));
      async.flushMicrotasks();
      check(result).isNull();

      gate.complete();
      async.flushMicrotasks();
      check(result).isNotNull().snapshot.queueId.equals('queue1');
    }));

    test('seed server data', () async {
      prepare();
      final snapshotJson = eg.initialSnapshot(queueId: 'queue1', lastEventId: 10)
        .toJson();
      backend.seedServerData(eg.selfAccount.id,
        snapshotJson: snapshotJson,
        eventBatches: [
          [{'id': 11, 'type': 'heartbeat'}],
          [{'id': 12, 'type': 'heartbeat'}, {'id': 13, 'type': 'heartbeat'}],
        ]);
      check(await backend.doLoadServerData(eg.selfAccount.id)).isNotNull()
        ..snapshot.which((it) => it
          ..queueId.equals('queue1')
          ..lastEventId.equals(13)
          ..appVersion.equals('1.0.0+1')
          ..data.deepEquals(utf8.encode(jsonEncode(snapshotJson))))
        ..eventBatches.deepEquals(<Condition<Object?>>[
          (it) => it.isA<ServerEventBatch>()
            ..lastEventId.equals(11)
            ..data.deepEquals(utf8.encode('[{"id":11,"type":"heartbeat"}]')),
          (it) => it.isA<ServerEventBatch>().lastEventId.equals(13),
        ]);

      // Appending works the same on seeded data.
      check(await append(14, null)).isTrue();
      check(backend.serverSnapshotOf(eg.selfAccount.id)!).lastEventId.equals(14);
    });

    test('new global store with same backend', () async {
      prepare();
      final snapshot = eg.serverSnapshot(account: eg.selfAccount);
      await backend.doStoreServerSnapshot(snapshot);

      final newGlobalStore = TestGlobalStore(backend: backend,
        accounts: [eg.selfAccount, eg.otherAccount]);
      check(newGlobalStore.backend).identicalTo(backend);
      check(await backend.doLoadServerData(eg.selfAccount.id)).isNotNull()
        .snapshot.equals(snapshot);
    });
  });
}
