import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:zulip/model/cached_messages.dart';
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

    Future<bool> storeSnapshot(ServerSnapshot snapshot, {String data = '{}'}) {
      return backend.doStoreServerSnapshot(snapshot, data: utf8.encode(data));
    }

    Future<bool> append(int lastEventId, String? data, {String queueId = 'queue1'}) {
      return backend.doAppendServerEvents(eg.selfAccount.id,
        queueId: queueId, lastEventId: lastEventId,
        data: data == null ? null : utf8.encode(data));
    }

    test('store snapshot replaces snapshot and its batches', () async {
      prepare();
      await storeSnapshot(eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue1', lastEventId: 10));
      await append(11, '[{"id":11}]');

      final newSnapshot = eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue2', lastEventId: 20);
      check(await storeSnapshot(newSnapshot, data: '{"b":2}')).isTrue();
      check(backend.serverSnapshotOf(eg.selfAccount.id)).equals(newSnapshot);
      check(backend.serverSnapshotDataOf(eg.selfAccount.id)).isNotNull()
        .deepEquals(utf8.encode('{"b":2}'));
      check(backend.serverEventBatchesOf(eg.selfAccount.id)).isEmpty();
    });

    test('no store snapshot when account missing', () async {
      prepare();
      final account = eg.account(user: eg.thirdUser);
      check(await storeSnapshot(
        eg.serverSnapshot(account: account))).isFalse();
      check(backend.serverSnapshotOf(account.id)).isNull();
    });

    test('append events', () async {
      prepare();
      await storeSnapshot(eg.serverSnapshot(account: eg.selfAccount,
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

    test('truncate event log', () async {
      prepare();
      final snapshot = eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue1', lastEventId: 10);
      await storeSnapshot(snapshot);
      await append(11, '[{"id":11}]');

      check(await backend.doTruncateServerEventLog(eg.selfAccount.id,
        queueId: 'queue0', lastEventId: 12)).isFalse();
      check(backend.serverSnapshotOf(eg.selfAccount.id)!).lastEventId.equals(11);
      check(backend.serverEventBatchesOf(eg.selfAccount.id)).length.equals(1);

      check(await backend.doTruncateServerEventLog(eg.selfAccount.id,
        queueId: 'queue1', lastEventId: 12)).isTrue();
      check(backend.serverSnapshotOf(eg.selfAccount.id)).equals(
        snapshot.copyWith(lastEventId: 12, eventLogTruncated: true));
      check(backend.serverEventBatchesOf(eg.selfAccount.id)).isEmpty();
      check(await backend.doLoadServerSnapshotInfo(eg.selfAccount.id)).isNotNull()
        .has((x) => x.eventLogTruncated, 'eventLogTruncated').isTrue();

      await storeSnapshot(eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue2', lastEventId: 20));
      check(backend.serverSnapshotOf(eg.selfAccount.id)!)
        .eventLogTruncated.isFalse();
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
        appVersion: '2.0.0+3', timestamp: 1771389742);
      await storeSnapshot(snapshot,
        data: '{"queue_id":"queue1","last_event_id":10}');
      await append(11, '[{"id":11}]');
      await append(12, null);
      await append(14, '[{"id":13},{"id":14}]');

      check(await backend.doLoadServerSnapshotInfo(eg.selfAccount.id)).equals((
        queueId: 'queue1', lastEventId: 14,
        appVersion: '2.0.0+3', timestamp: 1771389742,
        eventLogTruncated: false,
        snapshotSize: 40, eventBatchesSize: 11 + 21,
      ));
      check(await backend.doLoadServerData(eg.selfAccount.id)).isNotNull()
        ..snapshot.equals(snapshot.copyWith(lastEventId: 14))
        ..snapshotData.deepEquals(
            utf8.encode('{"queue_id":"queue1","last_event_id":10}'))
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
      await storeSnapshot(eg.serverSnapshot(account: eg.selfAccount));
      await storeSnapshot(eg.serverSnapshot(account: eg.otherAccount));
      await backend.doClearServerData(eg.selfAccount.id);
      check(backend.serverSnapshotOf(eg.selfAccount.id)).isNull();
      check(backend.serverSnapshotDataOf(eg.selfAccount.id)).isNull();
      check(backend.serverSnapshotOf(eg.otherAccount.id)).isNotNull();
      check(backend.serverSnapshotDataOf(eg.otherAccount.id)).isNotNull();
    });

    test('remove account clears server data', () async {
      prepare();
      await storeSnapshot(eg.serverSnapshot(account: eg.selfAccount,
        queueId: 'queue1'));
      await append(11, '[{"id":11}]');
      await globalStore.removeAccount(eg.selfAccount.id);
      check(backend.serverSnapshotOf(eg.selfAccount.id)).isNull();
      check(backend.serverSnapshotDataOf(eg.selfAccount.id)).isNull();
      check(backend.serverEventBatchesOf(eg.selfAccount.id)).isEmpty();
      check(await storeSnapshot(
        eg.serverSnapshot(account: eg.selfAccount))).isFalse();
    });

    test('store snapshot for account added later', () async {
      globalStore = TestGlobalStore(accounts: []);
      backend = globalStore.backend;
      await globalStore.add(eg.selfAccount, eg.initialSnapshot());
      check(await storeSnapshot(
        eg.serverSnapshot(account: eg.selfAccount))).isTrue();
    });

    test('errors are thrown once', () async {
      prepare();
      final error = Exception('oops');
      backend.storeServerSnapshotError = error;
      await check(storeSnapshot(
        eg.serverSnapshot(account: eg.selfAccount))).throws<Exception>();
      check(await storeSnapshot(
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

      backend.clearServerDataError = error;
      await check(backend.doClearServerData(eg.selfAccount.id)).throws<Exception>();
      check(backend.serverSnapshotOf(eg.selfAccount.id)).isNotNull();
      await backend.doClearServerData(eg.selfAccount.id);
      check(backend.serverSnapshotOf(eg.selfAccount.id)).isNull();
    });

    test('append waits for gate', () => awaitFakeAsync((async) async {
      prepare();
      await storeSnapshot(eg.serverSnapshot(account: eg.selfAccount,
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
      await storeSnapshot(eg.serverSnapshot(account: eg.selfAccount,
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
          ..appVersion.equals('1.0.0+1'))
        ..snapshotData.deepEquals(utf8.encode(jsonEncode(snapshotJson)))
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
      await storeSnapshot(snapshot);

      final newGlobalStore = TestGlobalStore(backend: backend,
        accounts: [eg.selfAccount, eg.otherAccount]);
      check(newGlobalStore.backend).identicalTo(backend);
      check(await backend.doLoadServerData(eg.selfAccount.id)).isNotNull()
        .snapshot.equals(snapshot);
    });
  });

  // These mirror tests of [AppDatabase] in database_test.dart,
  // to check that the fake has the same semantics as the real backend.
  group('TestGlobalStoreBackend cached message fetches', () {
    late TestGlobalStore globalStore;
    late TestGlobalStoreBackend backend;

    void prepare() {
      globalStore = TestGlobalStore(accounts: [eg.selfAccount, eg.otherAccount]);
      backend = globalStore.backend;
    }

    Future<bool> store(String narrowKey, int lastWritten, {
      Account? account,
      String? data,
      int? size,
    }) {
      assert(data == null || size == null);
      return backend.doStoreCachedMessageFetch(
        (account ?? eg.selfAccount).id, narrowKey,
        lastWritten: lastWritten,
        data: size != null ? Uint8List(size) : utf8.encode(data ?? '{}'));
    }

    Set<String> keys({Account? account}) {
      return backend.cachedMessageFetchKeysOf((account ?? eg.selfAccount).id)
        .toSet();
    }

    const maxSize = AppDatabase.maxCachedMessageFetchSize;

    test('store, then load', () async {
      prepare();
      check(await store('channel:1', 1000, data: '{"a":1}')).isTrue();
      check(await backend.doLoadCachedMessageFetch(eg.selfAccount.id, 'channel:1'))
        .isNotNull().deepEquals(utf8.encode('{"a":1}'));
      check(await backend.doLoadCachedMessageFetch(eg.selfAccount.id, 'channel:2'))
        .isNull();
      check(await backend.doLoadCachedMessageFetch(eg.otherAccount.id, 'channel:1'))
        .isNull();
      check(backend.cachedMessageFetchOf(eg.selfAccount.id, 'channel:1')).isNotNull()
        ..lastWritten.equals(1000)
        ..data.deepEquals(utf8.encode('{"a":1}'));
    });

    test('store replaces', () async {
      prepare();
      await store('channel:1', 1000, data: '{"a":1}');
      check(await store('channel:1', 2000, data: '{"a":2}')).isTrue();
      check(backend.cachedMessageFetchOf(eg.selfAccount.id, 'channel:1')).isNotNull()
        ..lastWritten.equals(2000)
        ..data.deepEquals(utf8.encode('{"a":2}'));
    });

    test('no store when account missing', () async {
      globalStore = TestGlobalStore(accounts: [eg.otherAccount]);
      backend = globalStore.backend;
      check(await store('channel:1', 1000)).isFalse();
      check(keys()).isEmpty();
    });

    test('no store when too big, and delete previous', () async {
      prepare();
      check(await store('channel:1', 1000, size: maxSize)).isTrue();
      check(await store('channel:2', 1000, size: maxSize)).isTrue();
      check(await store('channel:1', 2000, size: maxSize + 1)).isFalse();
      check(keys()).deepEquals({'channel:2'});
    });

    test('delete', () async {
      prepare();
      await store('channel:1', 1000);
      await store('channel:2', 1000);
      await store('channel:1', 1000, account: eg.otherAccount);
      await backend.doDeleteCachedMessageFetch(eg.selfAccount.id, 'channel:1');
      check(keys()).deepEquals({'channel:2'});
      check(keys(account: eg.otherAccount)).deepEquals({'channel:1'});
    });

    test('evict least recently written, when too many', () async {
      prepare();
      const maxRows = AppDatabase.maxCachedMessageFetchesPerAccount;
      for (int i = 0; i < maxRows; i++) {
        await store('channel:$i', 1000 + i);
      }
      await store('channel:0', 1000 + maxRows); // rewrite the oldest
      check(keys()).length.equals(maxRows);

      await store('channel:new', 1000 + maxRows + 1);
      check(keys())
        ..length.equals(maxRows)
        ..contains('channel:0')
        ..contains('channel:new')
        ..not((it) => it.contains('channel:1'));
    });

    test('evict least recently written, when too big', () async {
      prepare();
      const halfSize = maxSize ~/ 2;
      const n = AppDatabase.maxCachedMessageFetchesTotalSize ~/ halfSize;
      for (int i = 0; i < n; i++) {
        await store('channel:$i', 1000 + i, size: halfSize);
      }
      check(keys()).length.equals(n);

      await store('channel:1', 1000 + n, size: 10);
      await store('channel:new', 1000 + n + 1, size: maxSize);
      check(keys())
        ..length.equals(n - 1)
        ..not((it) => it.contains('channel:0'))
        ..contains('channel:1')
        ..not((it) => it.contains('channel:2'))
        ..contains('channel:3')
        ..contains('channel:new');
    });

    test('evict by lastWritten, not order of storing', () async {
      prepare();
      const maxRows = AppDatabase.maxCachedMessageFetchesPerAccount;
      for (int i = 0; i < maxRows; i++) {
        await store('channel:$i', 2000 - i);
      }
      await store('channel:new', 3000);
      check(keys())
        ..contains('channel:0')
        ..not((it) => it.contains('channel:${maxRows - 1}'));
    });

    test('eviction is per account', () async {
      prepare();
      const maxRows = AppDatabase.maxCachedMessageFetchesPerAccount;
      for (int i = 0; i < maxRows; i++) {
        await store('channel:$i', 1000 + i, account: eg.otherAccount);
      }
      await store('channel:new', 2000);
      check(keys(account: eg.otherAccount)).length.equals(maxRows);
    });

    test('remove account deletes cached message fetches', () async {
      prepare();
      await store('channel:1', 1000);
      await store('channel:1', 1000, account: eg.otherAccount);
      await globalStore.removeAccount(eg.selfAccount.id);
      check(keys()).isEmpty();
      check(keys(account: eg.otherAccount)).deepEquals({'channel:1'});
      check(await store('channel:1', 2000)).isFalse();
    });

    test('errors are thrown once', () async {
      prepare();
      final error = Exception('oops');
      backend.storeCachedMessageFetchError = error;
      await check(store('channel:1', 1000)).throws<Exception>();
      check(keys()).isEmpty();
      check(await store('channel:1', 1000)).isTrue();

      backend.loadCachedMessageFetchError = error;
      await check(backend.doLoadCachedMessageFetch(eg.selfAccount.id, 'channel:1'))
        .throws<Exception>();
      check(await backend.doLoadCachedMessageFetch(eg.selfAccount.id, 'channel:1'))
        .isNotNull();

      backend.deleteCachedMessageFetchError = error;
      await check(backend.doDeleteCachedMessageFetch(eg.selfAccount.id, 'channel:1'))
        .throws<Exception>();
      check(keys()).deepEquals({'channel:1'});
      await backend.doDeleteCachedMessageFetch(eg.selfAccount.id, 'channel:1');
      check(keys()).isEmpty();
    });

    test('load waits for gate', () => awaitFakeAsync((async) async {
      prepare();
      await store('channel:1', 1000, data: '{"a":1}');
      final gate = Completer<void>();
      backend.loadCachedMessageFetchGate = gate.future;
      Uint8List? result;
      unawaited(backend.doLoadCachedMessageFetch(eg.selfAccount.id, 'channel:1')
        .then((r) => result = r));
      async.flushMicrotasks();
      check(result).isNull();

      gate.complete();
      async.flushMicrotasks();
      check(result).isNotNull().deepEquals(utf8.encode('{"a":1}'));
    }));

    test('seed cached message fetch', () async {
      prepare();
      final messages = [eg.streamMessage()];
      backend.seedCachedMessageFetch(eg.selfAccount.id, 'channel:1',
        messages: messages);
      backend.seedCachedMessageFetch(eg.selfAccount.id, 'channel:2',
        data: utf8.encode('not JSON'));
      check(await backend.doLoadCachedMessageFetch(eg.selfAccount.id, 'channel:1'))
        .isNotNull().deepEquals(encodeCachedMessages(messages));
      check(await backend.doLoadCachedMessageFetch(eg.selfAccount.id, 'channel:2'))
        .isNotNull().deepEquals(utf8.encode('not JSON'));
    });
  });
}
