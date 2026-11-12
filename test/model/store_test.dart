import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart' show WidgetTester, testWidgets;
import 'package:http/http.dart' as http;
import 'package:test/scaffolding.dart';
import 'package:zulip/api/backoff.dart';
import 'package:zulip/api/core.dart';
import 'package:zulip/api/exception.dart';
import 'package:zulip/api/model/events.dart';
import 'package:zulip/api/model/initial_snapshot.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/api/route/events.dart';
import 'package:zulip/api/route/messages.dart';
import 'package:zulip/api/route/realm.dart';
import 'package:zulip/log.dart';
import 'package:zulip/model/actions.dart';
import 'package:zulip/model/connectivity.dart';
import 'package:zulip/model/database.dart';
import 'package:zulip/model/narrow.dart';
import 'package:zulip/model/presence.dart';
import 'package:zulip/model/server_support.dart';
import 'package:zulip/model/store.dart';

import '../api/fake_api.dart';
import '../api/model/model_checks.dart';
import '../example_data.dart' as eg;
import '../fake_async.dart';
import '../stdlib_checks.dart';
import 'binding.dart';
import 'store_checks.dart';
import 'test_store.dart';

void main() {
  TestZulipBinding.ensureInitialized();
  Presence.debugEnable = false;

  final account1 = eg.selfAccount.copyWith(id: 1);
  final account2 = eg.otherAccount.copyWith(id: 2);

  test('GlobalStore.perAccount sequential case', () async {
    final accounts = [account1, account2];
    final globalStore = LoadingTestGlobalStore(accounts: accounts);
    List<Completer<PerAccountStore>> completers(int accountId) =>
      globalStore.completers[accountId]!;

    final future1 = globalStore.perAccount(1);
    final store1 = PerAccountStore.fromInitialSnapshot(
      globalStore: globalStore,
      accountId: 1,
      initialSnapshot: eg.initialSnapshot(realmUsers: [eg.selfUser]),
    );
    completers(1).single.complete(store1);
    check(await future1).identicalTo(store1);
    check(await globalStore.perAccount(1)).identicalTo(store1);
    check(completers(1)).length.equals(1);

    final future2 = globalStore.perAccount(2);
    final store2 = PerAccountStore.fromInitialSnapshot(
      globalStore: globalStore,
      accountId: 2,
      initialSnapshot: eg.initialSnapshot(realmUsers: [eg.otherUser]),
    );
    completers(2).single.complete(store2);
    check(await future2).identicalTo(store2);
    check(await globalStore.perAccount(2)).identicalTo(store2);
    check(await globalStore.perAccount(1)).identicalTo(store1);

    // Only one loadPerAccount call was made per account.
    check(completers(1)).length.equals(1);
    check(completers(2)).length.equals(1);
  });

  test('GlobalStore.perAccount concurrent case', () async {
    final accounts = [account1, account2];
    final globalStore = LoadingTestGlobalStore(accounts: accounts);
    List<Completer<PerAccountStore>> completers(int accountId) =>
      globalStore.completers[accountId]!;

    final future1a = globalStore.perAccount(1);
    final future1b = globalStore.perAccount(1);
    // These should produce just one loadPerAccount call.
    check(completers(1)).length.equals(1);

    final future2 = globalStore.perAccount(2);
    final store1 = PerAccountStore.fromInitialSnapshot(
      globalStore: globalStore,
      accountId: 1,
      initialSnapshot: eg.initialSnapshot(realmUsers: [eg.selfUser]),
    );
    final store2 = PerAccountStore.fromInitialSnapshot(
      globalStore: globalStore,
      accountId: 2,
      initialSnapshot: eg.initialSnapshot(realmUsers: [eg.otherUser]),
    );
    completers(1).single.complete(store1);
    completers(2).single.complete(store2);
    check(await future1a).identicalTo(store1);
    check(await future1b).identicalTo(store1);
    check(await future2).identicalTo(store2);
    check(await globalStore.perAccount(1)).identicalTo(store1);
    check(await globalStore.perAccount(2)).identicalTo(store2);
    check(completers(1)).length.equals(1);
    check(completers(2)).length.equals(1);
  });

  test('GlobalStore.perAccountSync', () async {
    final accounts = [account1, account2];
    final globalStore = LoadingTestGlobalStore(accounts: accounts);
    List<Completer<PerAccountStore>> completers(int accountId) =>
      globalStore.completers[accountId]!;

    check(globalStore.perAccountSync(1)).isNull();
    final future1 = globalStore.perAccount(1);
    check(globalStore.perAccountSync(1)).isNull();
    final store1 = PerAccountStore.fromInitialSnapshot(
      globalStore: globalStore,
      accountId: 1,
      initialSnapshot: eg.initialSnapshot(),
    );
    completers(1).single.complete(store1);
    await pumpEventQueue();
    check(globalStore.perAccountSync(1)).identicalTo(store1);
    check(await future1).identicalTo(store1);
    check(globalStore.perAccountSync(1)).identicalTo(store1);
    check(await globalStore.perAccount(1)).identicalTo(store1);
    check(completers(1)).length.equals(1);
  });

  test('GlobalStore get/setServerCompatBannerDismissed', () async {
    final globalStore = eg.globalStore(accounts: [account1]);

    check(globalStore.getServerCompatBannerDismissed(account1.id)).isFalse();
    globalStore.setServerCompatBannerDismissed(account1.id);
    check(globalStore.getServerCompatBannerDismissed(account1.id)).isTrue();
  });

  test('GlobalStore.perAccount loading fails with HTTP status code 401', () => awaitFakeAsync((async) async {
    final globalStore = LoadingTestGlobalStore(accounts: [eg.selfAccount]);
    final future = globalStore.perAccount(eg.selfAccount.id);

    globalStore.completers[eg.selfAccount.id]!
      .single.completeError(eg.apiExceptionUnauthorized());
    await check(future).throws<AccountNotFoundException>();
  }));

  test('GlobalStore.perAccount loading succeeds', () => awaitFakeAsync((async) async {
    final globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);
    final connection = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
    final future = globalStore.perAccount(eg.selfAccount.id);
    async.flushMicrotasks();
    check(connection.takeRequests()).length.equals(1); // register request

    await future;
    // poll and server-emoji-data requests
    check(connection.takeRequests()).length.equals(2);
    check(connection).isOpen.isTrue();
  }));

  test('GlobalStore.perAccount loading succeeds; InitialSnapshot has ancient server version', () => awaitFakeAsync((async) async {
    final globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);
    final json = eg.initialSnapshot(zulipFeatureLevel: eg.ancientZulipFeatureLevel).toJson();
    globalStore.prepareRegisterQueueResponse = (connection) {
      connection.prepare(json: json);
    };
    final connection = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
    final future = globalStore.perAccount(eg.selfAccount.id);
    async.flushMicrotasks();
    check(connection.takeRequests()).length.equals(1); // register request

    await check(future).throws<AccountNotFoundException>();
    check(globalStore.takeDoRemoveAccountCalls()).single.equals(eg.selfAccount.id);
    // no poll or other follow-up requests
    check(connection.takeRequests()).isEmpty();
    check(connection).isOpen.isFalse();
  }));

  test('GlobalStore.perAccount loading fails; malformed response with ancient server version', () => awaitFakeAsync((async) async {
    final globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);
    final json = eg.initialSnapshot(zulipFeatureLevel: eg.ancientZulipFeatureLevel).toJson();
    json['realm_emoji'] = 123;
    check(() => InitialSnapshot.fromJson(json)).throws<void>();
    globalStore.prepareRegisterQueueResponse = (connection) {
      connection.prepare(json: json);
    };
    final connection = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
    final future = globalStore.perAccount(eg.selfAccount.id);
    async.flushMicrotasks();
    check(connection.takeRequests()).length.equals(1); // register request

    await check(future).throws<AccountNotFoundException>();
    check(globalStore.takeDoRemoveAccountCalls()).single.equals(eg.selfAccount.id);
    // no poll or other follow-up requests
    check(connection.takeRequests()).isEmpty();
    check(connection).isOpen.isFalse();
  }));

  test('GlobalStore.perAccount account is logged out while loading; then succeeds', () => awaitFakeAsync((async) async {
    final globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);
    globalStore.prepareRegisterQueueResponse = (connection) =>
      connection.prepare(
        delay: TestGlobalStore.removeAccountDuration + Duration(seconds: 1),
        json: eg.initialSnapshot().toJson());
    final connection = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
    final future = globalStore.perAccount(eg.selfAccount.id);
    async.flushMicrotasks();
    check(connection.takeRequests()).length.equals(1); // register request

    globalStore.clearCachedApiConnections();
    await logOutAccount(globalStore, eg.selfAccount.id);
    check(globalStore.takeDoRemoveAccountCalls())
      .single.equals(eg.selfAccount.id);

    await check(future).throws<AccountNotFoundException>();
    check(globalStore.takeDoRemoveAccountCalls()).isEmpty();
    // no poll or other follow-up requests
    check(connection.takeRequests()).isEmpty();
    check(connection).isOpen.isFalse();
  }));

  test('GlobalStore.perAccount account is logged out while loading; then fails with HTTP status code 401', () => awaitFakeAsync((async) async {
    final globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);
    globalStore.prepareRegisterQueueResponse = (connection) =>
      connection.prepare(
        delay: TestGlobalStore.removeAccountDuration + Duration(seconds: 1),
        apiException: eg.apiExceptionUnauthorized());
    final connection = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
    final future = globalStore.perAccount(eg.selfAccount.id);
    async.flushMicrotasks();
    check(connection.takeRequests()).length.equals(1); // register request

    globalStore.clearCachedApiConnections();
    await logOutAccount(globalStore, eg.selfAccount.id);
    check(globalStore.takeDoRemoveAccountCalls())
      .single.equals(eg.selfAccount.id);

    await check(future).throws<AccountNotFoundException>();
    check(globalStore.takeDoRemoveAccountCalls()).isEmpty();
    // no poll or other follow-up requests
    check(connection.takeRequests()).isEmpty();
    check(connection).isOpen.isFalse();
  }));

  test('GlobalStore.perAccount account is logged out while loading; then succeeds; InitialSnapshot has ancient server version', () => awaitFakeAsync((async) async {
    final globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);
    final json = eg.initialSnapshot(zulipFeatureLevel: eg.ancientZulipFeatureLevel).toJson();
    globalStore.prepareRegisterQueueResponse = (connection) {
      connection.prepare(
        delay: TestGlobalStore.removeAccountDuration + Duration(seconds: 1),
        json: json);
    };
    final connection = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
    final future = globalStore.perAccount(eg.selfAccount.id);
    async.flushMicrotasks();
    check(connection.takeRequests()).length.equals(1); // register request

    globalStore.clearCachedApiConnections();
    await logOutAccount(globalStore, eg.selfAccount.id);
    check(globalStore.takeDoRemoveAccountCalls()).single.equals(eg.selfAccount.id);

    await check(future).throws<AccountNotFoundException>();
    check(globalStore.takeDoRemoveAccountCalls()).isEmpty();
    // no poll or other follow-up requests
    check(connection.takeRequests()).isEmpty();
    check(connection).isOpen.isFalse();
  }));

  test('GlobalStore.perAccount account is logged out while loading; then fails; malformed response with ancient server version', () => awaitFakeAsync((async) async {
    final globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);
    final json = eg.initialSnapshot(zulipFeatureLevel: eg.ancientZulipFeatureLevel).toJson();
    json['realm_emoji'] = 123;
    check(() => InitialSnapshot.fromJson(json)).throws<void>();
    globalStore.prepareRegisterQueueResponse = (connection) {
      connection.prepare(
        delay: TestGlobalStore.removeAccountDuration + Duration(seconds: 1),
        json: json);
    };
    final connection = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
    final future = globalStore.perAccount(eg.selfAccount.id);
    async.flushMicrotasks();
    check(connection.takeRequests()).length.equals(1); // register request

    globalStore.clearCachedApiConnections();
    await logOutAccount(globalStore, eg.selfAccount.id);
    check(globalStore.takeDoRemoveAccountCalls()).single.equals(eg.selfAccount.id);

    await check(future).throws<AccountNotFoundException>();
    check(globalStore.takeDoRemoveAccountCalls()).isEmpty();
    // no poll or other follow-up requests
    check(connection.takeRequests()).isEmpty();
    check(connection).isOpen.isFalse();
  }));

  test('GlobalStore.perAccount account is logged out during transient-error backoff', () => awaitFakeAsync((async) async {
    final globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);
    globalStore.prepareRegisterQueueResponse = (connection) =>
      connection.prepare(
        delay: Duration(seconds: 1),
        httpException: http.ClientException('Oops'));
    final connection = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
    final future = globalStore.perAccount(eg.selfAccount.id);
    BackoffMachine.debugDuration = Duration(seconds: 1);
    async.elapse(Duration(milliseconds: 1500));
    check(connection.takeRequests()).length.equals(1); // register request

    assert(TestGlobalStore.removeAccountDuration < Duration(milliseconds: 500));
    globalStore.clearCachedApiConnections();
    await logOutAccount(globalStore, eg.selfAccount.id);
    check(globalStore.takeDoRemoveAccountCalls())
      .single.equals(eg.selfAccount.id);

    await check(future).throws<AccountNotFoundException>();
    check(globalStore.takeDoRemoveAccountCalls()).isEmpty();
    // no retry-register, poll, or other follow-up requests
    check(connection.takeRequests()).isEmpty();
    check(connection).isOpen.isFalse();
  }));

  test('GlobalStore.perAccount throws if missing queueId', () async {
    final globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);
    globalStore.prepareRegisterQueueResponse = (connection) {
      connection.prepare(json:
        deepToJson(eg.initialSnapshot()) as Map<String, dynamic>
          ..['queue_id'] = null);
    };
    await check(globalStore.perAccount(eg.selfAccount.id)).throws();
    await pumpEventQueue();
    check(globalStore.backend.serverSnapshotOf(eg.selfAccount.id)).isNull();
  });

  // TODO test insertAccount

  group('GlobalStore.updateAccount', () {
    test('basic', () async {
      // Update a nullable field, and a non-nullable one.
      final account = eg.selfAccount.copyWith(
        zulipFeatureLevel: 123,
        deviceId: const Value(3456),
      );
      final globalStore = eg.globalStore(accounts: [account]);
      final updated = await globalStore.updateAccount(account.id,
        const AccountsCompanion(
          zulipFeatureLevel: Value(234),
          deviceId: Value(null),
        ));
      check(globalStore.getAccount(account.id)).identicalTo(updated);
      check(updated).equals(account.copyWith(
        zulipFeatureLevel: 234,
        deviceId: const Value(null),
      ));
    });

    test('notifyListeners called', () async {
      final globalStore = eg.globalStore(accounts: [eg.selfAccount]);
      int updateCount = 0;
      globalStore.addListener(() => updateCount++);
      check(updateCount).equals(0);

      await globalStore.updateAccount(eg.selfAccount.id, const AccountsCompanion(
        zulipFeatureLevel: Value(234),
      ));
      check(updateCount).equals(1);
    });

    test('reject changing id, realmUrl, or userId', () async {
      final globalStore = eg.globalStore(accounts: [eg.selfAccount]);
      await check(globalStore.updateAccount(eg.selfAccount.id, const AccountsCompanion(
        id: Value(1234)))).throws();
      await check(globalStore.updateAccount(eg.selfAccount.id, AccountsCompanion(
        realmUrl: Value(Uri.parse('https://other.example'))))).throws();
      await check(globalStore.updateAccount(eg.selfAccount.id, const AccountsCompanion(
        userId: Value(1234)))).throws();
    });

    // TODO test database gets updated correctly (an integration test with sqlite?)
  });

  test('GlobalStore.updateZulipVersionData', () async {
    final [currentZulipVersion,          newZulipVersion             ]
        = ['10.0-beta2-302-gf5b08b11f4', '10.0-beta2-351-g75ac8fe961'];
    final [currentZulipMergeBase,        newZulipMergeBase           ]
        = ['10.0-beta2-291-g33ffd8c040', '10.0-beta2-349-g463dc632b3'];
    final [currentZulipFeatureLevel,     newZulipFeatureLevel        ]
        = [368,                          370                         ];

    final selfAccount = eg.selfAccount.copyWith(
      zulipVersion: currentZulipVersion,
      zulipMergeBase: Value(currentZulipMergeBase),
      zulipFeatureLevel: currentZulipFeatureLevel);
    final globalStore = eg.globalStore(accounts: [selfAccount]);
    final updated = await globalStore.updateZulipVersionData(selfAccount.id,
      ZulipVersionData(
        zulipVersion: newZulipVersion,
        zulipMergeBase: newZulipMergeBase,
        zulipFeatureLevel: newZulipFeatureLevel));
    check(globalStore.getAccount(selfAccount.id)).identicalTo(updated);
    check(updated).equals(selfAccount.copyWith(
      zulipVersion: newZulipVersion,
      zulipMergeBase: Value(newZulipMergeBase),
      zulipFeatureLevel: newZulipFeatureLevel));
  });

  test('GlobalStore.updateRealmData', () async {
    final selfAccount = eg.selfAccount.copyWith(
      realmName: Value('Organization A'),
      realmIcon: Value(Uri.parse('/image-a.png')));
    final globalStore = eg.globalStore(accounts: [selfAccount]);
    final updated = await globalStore.updateRealmData(selfAccount.id,
      realmName: 'Organization B',
      realmIcon: Uri.parse('/image-b.png'));
    check(globalStore.getAccount(selfAccount.id))
      ..identicalTo(updated)
      ..equals(selfAccount.copyWith(
        realmName: Value('Organization B'),
        realmIcon: Value(Uri.parse('/image-b.png'))));
  });

  group('GlobalStore.refreshRealmMetadata', () {
    test('smoke; populates/updates realm data', () => awaitFakeAsync((async) async {
      final account1 = eg.selfAccount.copyWith(
        realmUrl: Uri.parse('https://realm1.example.com'),
        realmName: const Value.absent(), // account without realm metadata
        realmIcon: const Value.absent());
      final account2 = eg.otherAccount.copyWith(
        realmUrl: Uri.parse('https://realm2.example.com'),
        realmName: Value('Old realm 2 name'), // account with old realm metadata
        realmIcon: Value(Uri.parse('/old-realm-2-image.png')));

      final globalStore = eg.globalStore(accounts: [account1, account2]);
      globalStore.useCachedApiConnections = true;

      final connection1 = globalStore.apiConnection(
        realmUrl: account1.realmUrl, zulipFeatureLevel: null);
      final serverSettings1 = eg.serverSettings(
        realmUrl: account1.realmUrl,
        realmName: 'Realm 1 name',
        realmIcon: Uri.parse('/realm-1-image.png'));
      connection1.prepare(json: serverSettings1.toJson());

      final connection2 = globalStore.apiConnection(
        realmUrl: account2.realmUrl, zulipFeatureLevel: null);
      final serverSettings2 = eg.serverSettings(
        realmUrl: account2.realmUrl,
        realmName: 'New realm 2 name',
        realmIcon: Uri.parse('/new-realm-2-image.png'));
      connection2.prepare(json: serverSettings2.toJson());

      globalStore.refreshRealmMetadata();
      async.elapse(Duration.zero);

      check(globalStore.getAccount(account1.id)).isNotNull()
        ..realmName.equals('Realm 1 name')
        ..realmIcon.equals(Uri.parse('/realm-1-image.png'));
      check(globalStore.getAccount(account2.id)).isNotNull()
        ..realmName.equals('New realm 2 name')
        ..realmIcon.equals(Uri.parse('/new-realm-2-image.png'));
    }));

    test('ignores per account store loaded account', () => awaitFakeAsync((async) async {
      final account1 = eg.selfAccount.copyWith(
        realmUrl: Uri.parse('https://realm1.example.com'),
        realmName: Value('Old realm 1 name'),
        realmIcon: Value(Uri.parse('/old-realm-1-image.png')));
      final account2 = eg.otherAccount.copyWith(
        realmUrl: Uri.parse('https://realm2.example.com'),
        realmName: Value('Old realm 2 name'),
        realmIcon: Value(Uri.parse('/old-realm-2-image.png')));

      final globalStore = eg.globalStore();
      await globalStore.add(account1, eg.initialSnapshot(
        realmName: account1.realmName,
        realmIconUrl: account1.realmIcon,
        realmUsers: [eg.selfUser]));
      await globalStore.add(account2, eg.initialSnapshot(
        realmName: account2.realmName,
        realmIconUrl: account2.realmIcon,
        realmUsers: [eg.otherUser]));
      globalStore.useCachedApiConnections = true;

      final connection1 = globalStore.apiConnection(
        realmUrl: account1.realmUrl, zulipFeatureLevel: null);
      final serverSettings1 = eg.serverSettings(
        realmUrl: account1.realmUrl,
        realmName: 'New realm 1 name',
        realmIcon: Uri.parse('/new-realm-1-image.png'));
      connection1.prepare(json: serverSettings1.toJson());

      await globalStore.perAccount(account2.id);

      globalStore.refreshRealmMetadata();
      async.elapse(Duration.zero);

      check(globalStore.getAccount(account1.id)).isNotNull()
        ..realmName.equals('New realm 1 name')
        ..realmIcon.equals(Uri.parse('/new-realm-1-image.png'));
      check(globalStore.getAccount(account2.id)).isNotNull()
        ..realmName.equals('Old realm 2 name')
        ..realmIcon.equals(Uri.parse('/old-realm-2-image.png'));
    }));
  });

  group('GlobalStore.removeAccount', () {
    void checkGlobalStore(GlobalStore store, int accountId, {
      required bool expectAccount,
      required bool expectStore,
    }) {
      expectAccount
        ? check(store.getAccount(accountId)).isNotNull()
        : check(store.getAccount(accountId)).isNull();
      expectStore
        ? check(store.perAccountSync(accountId)).isNotNull()
        : check(store.perAccountSync(accountId)).isNull();
    }

    test('when store loaded', () async {
      final globalStore = eg.globalStore();
      await globalStore.add(eg.selfAccount, eg.initialSnapshot());
      await globalStore.perAccount(eg.selfAccount.id);

      checkGlobalStore(globalStore, eg.selfAccount.id,
        expectAccount: true, expectStore: true);
      int notifyCount = 0;
      globalStore.addListener(() => notifyCount++);

      await globalStore.removeAccount(eg.selfAccount.id);

      // TODO test that the removed store got disposed and its connection closed
      checkGlobalStore(globalStore, eg.selfAccount.id,
        expectAccount: false, expectStore: false);
      check(notifyCount).equals(1);
    });

    test('when store not loaded', () async {
      final globalStore = eg.globalStore();
      await globalStore.add(eg.selfAccount, eg.initialSnapshot());

      checkGlobalStore(globalStore, eg.selfAccount.id,
        expectAccount: true, expectStore: false);
      int notifyCount = 0;
      globalStore.addListener(() => notifyCount++);

      await globalStore.removeAccount(eg.selfAccount.id);

      checkGlobalStore(globalStore, eg.selfAccount.id,
        expectAccount: false, expectStore: false);
      check(notifyCount).equals(1);
    });

    test('when store loading', () async {
      final globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);
      checkGlobalStore(globalStore, eg.selfAccount.id,
        expectAccount: true, expectStore: false);

      assert(globalStore.useCachedApiConnections);
      // Cache a connection and get this reference to it,
      // so we can check later that it gets closed.
      final connection = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;

      globalStore.prepareRegisterQueueResponse = (connection) {
        connection.prepare(
          delay: TestGlobalStore.removeAccountDuration + Duration(seconds: 1),
          json: eg.initialSnapshot().toJson());
      };
      final loadingFuture = globalStore.perAccount(eg.selfAccount.id);

      checkGlobalStore(globalStore, eg.selfAccount.id,
        expectAccount: true, expectStore: false);
      int notifyCount = 0;
      globalStore.addListener(() => notifyCount++);

      await globalStore.removeAccount(eg.selfAccount.id);

      checkGlobalStore(globalStore, eg.selfAccount.id,
        expectAccount: false, expectStore: false);
      check(notifyCount).equals(1);

      await check(loadingFuture).throws<AccountNotFoundException>();
      checkGlobalStore(globalStore, eg.selfAccount.id,
        expectAccount: false, expectStore: false);
      check(notifyCount).equals(1); // no extra notify
      check(connection).isOpen.isFalse();

      check(globalStore.debugNumPerAccountStoresLoading).equals(0);
    });
  });

  test('dispose connectivityMonitor with the GlobalStore', () => awaitFakeAsync((async) async {
    addTearDown(testBinding.reset);
    final globalStore = eg.globalStore();
    final monitor = globalStore.connectivityMonitor;
    async.flushMicrotasks();
    final countBefore = monitor.updateCount;

    globalStore.dispose();
    testBinding.notifyConnectivityChanged([.mobile]);
    async.flushMicrotasks();
    check(monitor.updateCount).equals(countBefore);
  }));

  test('PerAccountStore.disposed', () {
    final store = eg.store();
    check(store).disposed.isFalse();
    store.dispose();
    check(store).disposed.isTrue();
  });

  group('PerAccountStore cached message fetches', () {
    late TestGlobalStoreBackend backend;
    late PerAccountStore store;

    void prepare() {
      final globalStore = eg.globalStore(accounts: [eg.selfAccount]);
      backend = globalStore.backend;
      store = eg.store(globalStore: globalStore);
    }

    test('store, then load', () => awaitFakeAsync((async) async {
      prepare();
      final data = utf8.encode('{"a":1}');
      await store.storeCachedMessageFetch('channel:1', data);
      check(backend.cachedMessageFetchOf(eg.selfAccount.id, 'channel:1')).isNotNull()
        ..lastWritten.equals(testBinding.utcNow().millisecondsSinceEpoch)
        ..data.deepEquals(data);
      check(await store.loadCachedMessageFetch('channel:1')).isNotNull()
        .deepEquals(data);
      check(await store.loadCachedMessageFetch('channel:2')).isNull();
    }));

    test('delete', () async {
      prepare();
      await store.storeCachedMessageFetch('channel:1', utf8.encode('{}'));
      await store.deleteCachedMessageFetch('channel:1');
      check(backend.cachedMessageFetchKeysOf(eg.selfAccount.id)).isEmpty();
    });

    test('errors are not thrown', () async {
      prepare();
      backend.storeCachedMessageFetchError = Exception('oops');
      await store.storeCachedMessageFetch('channel:1', utf8.encode('{}'));
      check(backend.cachedMessageFetchKeysOf(eg.selfAccount.id)).isEmpty();

      await store.storeCachedMessageFetch('channel:1', utf8.encode('{}'));
      backend.loadCachedMessageFetchError = Exception('oops');
      check(await store.loadCachedMessageFetch('channel:1')).isNull();

      backend.deleteCachedMessageFetchError = Exception('oops');
      await store.deleteCachedMessageFetch('channel:1');
      check(backend.cachedMessageFetchKeysOf(eg.selfAccount.id))
        .deepEquals(['channel:1']);
    });
  });

  group('PerAccountStore.handleEvent', () {
    // Mostly this method just dispatches to ChannelStore and MessageStore etc.,
    // and so its tests generally live in the test files for those
    // (but they call the handleEvent method because it's the entry point).
  });

  group('UpdateMachine.load', () {
    late TestGlobalStore globalStore;
    late FakeApiConnection connection;

    Future<void> prepareStore({Account? account}) async {
      globalStore = eg.globalStore();
      account ??= eg.selfAccount;
      await globalStore.insertAccount(account.toCompanion(false));
      connection = (globalStore.apiConnectionFromAccount(account)
        as FakeApiConnection);
      UpdateMachine.debugEnableFetchEmojiData = false;
      addTearDown(() => UpdateMachine.debugEnableFetchEmojiData = true);
    }

    void checkLastRequest() {
      check(connection.takeRequests()).single.isA<http.Request>()
        ..method.equals('POST')
        ..url.path.equals('/api/v1/register')
        ..bodyFields['idle_queue_timeout'].equals(jsonEncode('mobile'));
    }

    test('smoke', () => awaitFakeAsync((async) async {
      await prepareStore();
      final users = [eg.selfUser, eg.otherUser];

      globalStore.useCachedApiConnections = true;
      connection.prepare(json: eg.initialSnapshot(realmUsers: users).toJson());
      final updateMachine = await UpdateMachine.load(
        globalStore, eg.selfAccount.id, allowPersisted: true);
      updateMachine.debugPauseLoop();

      // TODO UpdateMachine.debugPauseLoop is too late to prevent first poll attempt;
      //    the polling retry catches the resulting NetworkException from lack of
      //    `connection.prepare`, so that doesn't fail the test, but it does
      //    clobber the recorded registerQueue request so we can't check it.
      // checkLastRequest();

      check(updateMachine.store.allUsers).unorderedMatches(
        users.map((expected) => (it) => it.fullName.equals(expected.fullName)));
    }));

    test('updates account from snapshot', () => awaitFakeAsync((async) async {
      final account = eg.account(user: eg.selfUser,
        realmName: 'Organization A',
        realmIcon: Uri.parse('/image-a.png'),
        zulipVersion: '9.0+gabcd',
        zulipMergeBase: '9.0',
        zulipFeatureLevel: 277,
      );
      await prepareStore(account: account);
      check(globalStore.getAccount(account.id)).isNotNull()
        ..realmName.equals('Organization A')
        ..realmIcon.equals(Uri.parse('/image-a.png'))
        ..zulipVersion.equals('9.0+gabcd')
        ..zulipMergeBase.equals('9.0')
        ..zulipFeatureLevel.equals(277);

      globalStore.useCachedApiConnections = true;
      connection.prepare(json: eg.initialSnapshot(
        realmName: 'Organization B',
        realmIconUrl: Uri.parse('/image-b.png'),
        zulipVersion: '10.0+g9876',
        zulipMergeBase: '10.0',
        zulipFeatureLevel: 371,
      ).toJson());
      final updateMachine = await UpdateMachine.load(globalStore, account.id,
        allowPersisted: true);
      updateMachine.debugPauseLoop();
      check(globalStore.getAccount(account.id)).isNotNull()
        ..identicalTo(updateMachine.store.account)
        ..realmName.equals('Organization B')
        ..realmIcon.equals(Uri.parse('/image-b.png'))
        ..zulipVersion.equals('10.0+g9876')
        ..zulipMergeBase.equals('10.0')
        ..zulipFeatureLevel.equals(371);
    }));

    test('retries registerQueue on NetworkError', () => awaitFakeAsync((async) async {
      await prepareStore();

      // Try to load, inducing an error in the request.
      globalStore.useCachedApiConnections = true;
      connection.prepare(httpException: Exception('failed'));
      final future = UpdateMachine.load(globalStore, eg.selfAccount.id,
        allowPersisted: true);
      bool complete = false;
      unawaited(future.whenComplete(() => complete = true));
      async.flushMicrotasks();
      checkLastRequest();
      check(complete).isFalse();

      // The retry doesn't happen immediately; there's a timer.
      check(async.pendingTimers).length.equals(1);
      async.elapse(Duration.zero);
      check(connection.lastRequest).isNull();
      check(async.pendingTimers).length.equals(1);

      // After a timer, we retry.
      final users = [eg.selfUser, eg.otherUser];
      connection.prepare(json: eg.initialSnapshot(realmUsers: users).toJson());
      final updateMachine = await future;
      updateMachine.debugPauseLoop();
      check(complete).isTrue();
      // checkLastRequest(); TODO UpdateMachine.debugPauseLoop was too late; see comment above
      check(updateMachine.store.allUsers).unorderedMatches(
        users.map((expected) => (it) => it.fullName.equals(expected.fullName)));
    }));

    group('registerQueue error reporting', () {
      String? lastReportedError;

      Future<void> prepare() async {
        lastReportedError = null;
        reportErrorToUserBriefly = (message, {details}) async {
          if (message == null) return;
          lastReportedError = message;
        };
        addTearDown(() =>
          reportErrorToUserBriefly = defaultReportErrorToUserBriefly);
        await prepareStore();
        globalStore.useCachedApiConnections = true;
      }

      /// Load, with the first registerQueue attempt failing with [exception]
      /// and the retry succeeding.
      Future<void> loadWithFirstAttemptFailing(Object exception) async {
        connection.prepare(httpException: exception);
        connection.prepare(json: eg.initialSnapshot().toJson());
        final updateMachine = await UpdateMachine.load(
          globalStore, eg.selfAccount.id, allowPersisted: true);
        updateMachine.debugPauseLoop();
      }

      test('no report on failed connection', () => awaitFakeAsync((async) async {
        await prepare();
        await loadWithFirstAttemptFailing(const SocketException('failed'));
        check(lastReportedError).isNull();
      }));

      test('report other network error', () => awaitFakeAsync((async) async {
        await prepare();
        await loadWithFirstAttemptFailing(Exception('failed'));
        check(lastReportedError).isNotNull();
      }));
    });

    // TODO test UpdateMachine.load starts polling loop
  });

  group('UpdateMachine.fetchEmojiData', () {
    late UpdateMachine updateMachine;
    late PerAccountStore store;
    late FakeApiConnection connection;

    void prepareStore() {
      updateMachine = eg.updateMachine();
      store = updateMachine.store;
      connection = store.connection as FakeApiConnection;
    }

    final emojiDataUrl = Uri.parse('https://cdn.example/emoji.json');
    final data = {
      '1f642': ['slight_smile'],
      '1f34a': ['orange', 'tangerine', 'mandarin'],
    };

    void checkLastRequest() {
      check(connection.takeRequests()).single.isA<http.Request>()
        ..method.equals('GET')
        ..url.equals(emojiDataUrl)
        ..headers.deepEquals(kFallbackUserAgentHeader);
    }

    test('happy case', () => awaitFakeAsync((async) async {
      prepareStore();
      check(store.debugServerEmojiData).isNull();

      connection.prepare(json: ServerEmojiData(codeToNames: data).toJson());
      await updateMachine.fetchEmojiData(emojiDataUrl);
      checkLastRequest();
      check(store.debugServerEmojiData).deepEquals(data);
    }));

    test('retries on failure', () => awaitFakeAsync((async) async {
      prepareStore();
      check(store.debugServerEmojiData).isNull();

      // Try to fetch, inducing an error in the request.
      connection.prepare(httpException: Exception('failed'));
      final future = updateMachine.fetchEmojiData(emojiDataUrl);
      bool complete = false;
      unawaited(future.whenComplete(() => complete = true));
      async.flushMicrotasks();
      checkLastRequest();
      check(complete).isFalse();
      check(store.debugServerEmojiData).isNull();

      // The retry doesn't happen immediately; there's a timer.
      check(async.pendingTimers).length.equals(1);
      async.elapse(Duration.zero);
      check(connection.lastRequest).isNull();
      check(async.pendingTimers).length.equals(1);

      // After a timer, we retry.
      connection.prepare(json: ServerEmojiData(codeToNames: data).toJson());
      await future;
      check(complete).isTrue();
      checkLastRequest();
      check(store.debugServerEmojiData).deepEquals(data);
    }));

    test('stop when disposed during fetch', () => awaitFakeAsync((async) async {
      prepareStore();

      connection.prepare(delay: const Duration(seconds: 1),
        json: ServerEmojiData(codeToNames: data).toJson());
      final future = updateMachine.fetchEmojiData(emojiDataUrl);
      bool complete = false;
      unawaited(future.whenComplete(() => complete = true));
      async.flushMicrotasks();
      checkLastRequest();

      store.dispose();
      async.elapse(const Duration(seconds: 1));
      check(complete).isTrue();
      check(store.debugServerEmojiData).isNull();
    }));

    test('stop when disposed during backoff', () => awaitFakeAsync((async) async {
      prepareStore();

      connection.prepare(httpException: Exception('failed'));
      final future = updateMachine.fetchEmojiData(emojiDataUrl);
      bool complete = false;
      unawaited(future.whenComplete(() => complete = true));
      async.flushMicrotasks();
      checkLastRequest();
      check(complete).isFalse();

      store.dispose();
      async.elapse(const Duration(minutes: 5));
      check(complete).isTrue();
      check(connection.takeRequests()).isEmpty();
    }));
  });

  group('UpdateMachine.poll', () {
    late TestGlobalStore globalStore;
    late PerAccountStore store;
    late UpdateMachine updateMachine;
    late FakeApiConnection connection;

    void updateFromGlobalStore() {
      store = globalStore.perAccountSync(eg.selfAccount.id)!;
      updateMachine = store.updateMachine!;
      connection = store.connection as FakeApiConnection;
    }

    Future<void> preparePoll({
      int? lastEventId,
      int? eventQueueLongpollTimeoutSeconds,
    }) async {
      // The poll loop subscribes to testBinding.appLifecycleStateChanges.
      addTearDown(testBinding.reset);
      globalStore = eg.globalStore();
      await globalStore.add(eg.selfAccount, eg.initialSnapshot(
        lastEventId: lastEventId,
        eventQueueLongpollTimeoutSeconds: eventQueueLongpollTimeoutSeconds));
      await globalStore.perAccount(eg.selfAccount.id);
      updateFromGlobalStore();
      updateMachine.debugPauseLoop();
      updateMachine.poll();
    }

    void checkLastRequest({required int lastEventId, bool expectDontBlock = false}) {
      check(connection.takeRequests()).single.isA<http.Request>()
        ..method.equals('GET')
        ..url.path.equals('/api/v1/events')
        ..url.queryParameters.deepEquals({
          'queue_id': store.queueId,
          'last_event_id': lastEventId.toString(),
          if (expectDontBlock) 'dont_block': 'true',
        });
    }

    void prepareHeartbeat(int eventId, {Duration delay = Duration.zero}) {
      connection.prepare(delay: delay, json: GetEventsResult(events: [
        HeartbeatEvent(id: eventId),
      ], queueId: null).toJson());
    }

    /// Prepare a response delayed past the poll request's timeout,
    /// as if the connection had died silently (see #514).
    void prepareStuckPollResponse() {
      connection.prepare(delay: const Duration(seconds: 300),
        json: GetEventsResult(events: [], queueId: null).toJson());
    }

    test('loops on success', () => awaitFakeAsync((async) async {
      await preparePoll(lastEventId: 1);
      check(updateMachine.lastEventId).equals(1);

      // Loop makes first request, and processes result.
      prepareHeartbeat(2);
      updateMachine.debugAdvanceLoop();
      async.flushMicrotasks();
      checkLastRequest(lastEventId: 1);
      async.elapse(Duration.zero);
      check(updateMachine.lastEventId).equals(2);

      // Loop makes second request, and processes result.
      prepareHeartbeat(3);
      updateMachine.debugAdvanceLoop();
      async.flushMicrotasks();
      checkLastRequest(lastEventId: 2);
      async.elapse(Duration.zero);
      check(updateMachine.lastEventId).equals(3);
    }));

    test('handles events', () => awaitFakeAsync((async) async {
      await preparePoll();

      // Pick some arbitrary event and check it gets processed on the store.
      check(store.userSettings.twentyFourHourTime)
        .equals(TwentyFourHourTimeMode.twelveHour);
      connection.prepare(json: GetEventsResult(events: [
        UserSettingsUpdateEvent(id: 2,
          property: UserSettingName.twentyFourHourTime, value: true),
      ], queueId: null).toJson());
      updateMachine.debugAdvanceLoop();
      async.elapse(Duration.zero);
      check(store.userSettings.twentyFourHourTime)
        .equals(TwentyFourHourTimeMode.twentyFourHour);
    }));

    void checkReload(FutureOr<void> Function() prepareError, {
      bool expectBackoff = true,
    }) {
      awaitFakeAsync((async) async {
        await preparePoll();
        check(globalStore.perAccountSync(store.accountId)).identicalTo(store);

        await prepareError();
        updateMachine.debugAdvanceLoop();
        async.elapse(Duration.zero);
        check(store).isRecoveringEventStream.isTrue();

        if (expectBackoff) {
          // The reload doesn't happen immediately; there's a timer.
          check(globalStore.perAccountSync(store.accountId)).identicalTo(store);
          check(async.pendingTimers).length.equals(1);
          async.flushTimers();
        }

        // The global store has a new store.
        check(globalStore.perAccountSync(store.accountId)).not((it) => it.identicalTo(store));
        updateFromGlobalStore();
        check(store).isRecoveringEventStream.isFalse();

        // The new UpdateMachine updates the new store.
        updateMachine.debugPauseLoop();
        updateMachine.poll();
        check(store.userSettings.twentyFourHourTime)
          .equals(TwentyFourHourTimeMode.twelveHour);
        connection.prepare(json: GetEventsResult(events: [
          UserSettingsUpdateEvent(id: 2,
            property: UserSettingName.twentyFourHourTime, value: true),
        ], queueId: null).toJson());
        updateMachine.debugAdvanceLoop();
        async.elapse(Duration.zero);
        check(store.userSettings.twentyFourHourTime)
          .equals(TwentyFourHourTimeMode.twentyFourHour);
      });
    }

    /// Check the poll loop quietly retries when [prepareError]
    /// causes the request to fail.
    ///
    /// [elapse] is how long the request takes to fail:
    /// zero for an immediate error,
    /// or the poll timeout for a request that times out.
    void checkRetry(void Function() prepareError, {
      Duration elapse = Duration.zero,
      int? eventQueueLongpollTimeoutSeconds,
    }) {
      awaitFakeAsync((async) async {
        await preparePoll(lastEventId: 1,
          eventQueueLongpollTimeoutSeconds: eventQueueLongpollTimeoutSeconds);
        check(async.pendingTimers).length.equals(0);

        // Make the request, inducing an error in it.
        prepareError();
        updateMachine.debugAdvanceLoop();
        async.elapse(elapse);
        checkLastRequest(lastEventId: 1, expectDontBlock: false);
        check(store).isRecoveringEventStream.isTrue();

        // Polling doesn't resume immediately; there's a timer.
        // (On a timed-out request, the fake's timer for the response
        // that never arrived is also still pending.)
        final pendingTimers = elapse == Duration.zero ? 1 : 2;
        check(async.pendingTimers).length.equals(pendingTimers);
        updateMachine.debugAdvanceLoop();
        async.flushMicrotasks();
        check(connection.lastRequest).isNull();
        check(async.pendingTimers).length.equals(pendingTimers);

        // Polling continues after a timer.
        prepareHeartbeat(2);
        async.flushTimers();
        checkLastRequest(lastEventId: 1, expectDontBlock: true);
        check(updateMachine.lastEventId).equals(2);
        check(store).isRecoveringEventStream.isFalse();
      });
    }

    // These cases are ordered by how far the request got before it failed.

    void prepareUnexpectedLoopError() {
      updateMachine.debugPrepareLoopError(eg.nullCheckError());
    }

    /// Prepare an exception that [ApiConnection] will classify
    /// as [NetworkExceptionKind.connectionFailed].
    ///
    /// See also [prepareNetworkExceptionOther].
    void prepareNetworkExceptionConnectionFailed() {
      connection.prepare(httpException: const SocketException('failed'));
    }

    /// Prepare an exception that [ApiConnection] will classify
    /// as [NetworkExceptionKind.other].
    ///
    /// See also [prepareNetworkExceptionConnectionFailed].
    void prepareNetworkExceptionOther() {
      connection.prepare(httpException: const HandshakeException('handshake failed'));
    }

    void prepareServer5xxException() {
      connection.prepare(httpStatus: 500, body: 'splat');
    }

    void prepareMalformedServerResponseException() {
      connection.prepare(httpStatus: 200, body: 'nonsense');
    }

    void prepareRateLimitExceptionCode() {
      // Example from the Zulip API docs:
      //   https://zulip.com/api/rest-error-handling#rate-limit-exceeded
      // (The actual HTTP status should be 429, but that seems undocumented.)
      connection.prepare(httpStatus: 400, json: {
        'result': 'error', 'code': 'RATE_LIMIT_HIT',
        'msg': 'API usage exceeded rate limit',
        'retry-after': 28.706807374954224});
    }

    void prepareRateLimitExceptionStatus() {
      // The HTTP status code for hitting a rate limit,
      // but for some reason a boring BAD_REQUEST error body.
      connection.prepare(httpStatus: 429, json: {
        'result': 'error', 'code': 'BAD_REQUEST', 'msg': 'Bad request'});
    }

    void prepareRateLimitExceptionMalformed() {
      // The HTTP status code for hitting a rate limit,
      // but for some reason a non-JSON body.
      connection.prepare(httpStatus: 429,
        body: '<html><body>An error occurred.</body></html>');
    }

    void prepareZulipApiExceptionBadRequest() {
      connection.prepare(httpStatus: 400, json: {
        'result': 'error', 'code': 'BAD_REQUEST', 'msg': 'Bad request'});
    }

    void prepareExpiredEventQueue() {
      connection.prepare(apiException: eg.apiExceptionBadEventQueueId(
        queueId: store.queueId));
    }

    Future<void> prepareHandleEventError() async {
      final stream = eg.stream();
      await store.addStream(stream);
      // Set up a situation that breaks our data structures' invariants:
      // a stream/channel found in the by-ID map is missing in the by-name map.
      store.streamsByName.remove(stream.name);
      // Then prepare an event on which handleEvent will throw
      // because it hits that broken invariant.
      connection.prepare(json: GetEventsResult(events: [
        ChannelDeleteEvent(id: 1, channelIds: [stream.streamId]),
      ], queueId: null).toJson());
    }

    test('reloads on unexpected error within loop', () {
      checkReload(prepareUnexpectedLoopError);
    });

    test('retries on NetworkException from failed connection', () {
      // We skip reporting errors on these; check we retry them all the same.
      checkRetry(prepareNetworkExceptionConnectionFailed);
    });

    test('retries when request outlives the server-recommended timeout', () {
      // In the wild, this is a connection that died without erroring; see #514.
      checkRetry(
        eventQueueLongpollTimeoutSeconds: 85,
        elapse: const Duration(seconds: 85),
        prepareStuckPollResponse);
    });

    test('retries on NetworkException with NetworkExceptionKind.other', () {
      checkRetry(prepareNetworkExceptionOther);
    });

    test('retries on Server5xxException', () {
      checkRetry(prepareServer5xxException);
    });

    test('reloads on MalformedServerResponseException', () {
      checkReload(prepareMalformedServerResponseException);
    });

    test('retries on rate limit: code RATE_LIMIT_HIT', () {
      checkRetry(prepareRateLimitExceptionCode);
    });

    test('retries on rate limit: status 429 ZulipApiException', () {
      checkRetry(prepareRateLimitExceptionStatus);
    });

    test('retries on rate limit: status 429 MalformedServerResponseException', () {
      checkRetry(prepareRateLimitExceptionMalformed);
    });

    test('reloads on generic ZulipApiException', () {
      checkReload(prepareZulipApiExceptionBadRequest);
    });

    test('reloads immediately on expired queue', () {
      checkReload(expectBackoff: false, prepareExpiredEventQueue);
    });

    test('reloads on handleEvent error', () {
      checkReload(prepareHandleEventError);
    });

    group('abort backoff on app wake', () {
      test('abort wait in progress', () => awaitFakeAsync((async) async {
        // Regression test for: https://github.com/zulip/zulip-flutter/issues/1884
        BackoffMachine.debugDuration = const Duration(seconds: 10);
        addTearDown(() => BackoffMachine.debugDuration = null);
        await preparePoll(lastEventId: 1);

        // Make the request, inducing a network failure in it.
        prepareNetworkExceptionConnectionFailed();
        updateMachine.debugAdvanceLoop();
        async.elapse(Duration.zero);
        checkLastRequest(lastEventId: 1);
        check(store).isRecoveringEventStream.isTrue();
        check(async.pendingTimers).length.equals(1);

        // On coming to the foreground, polling resumes immediately,
        // well before the backoff duration has elapsed.
        // (The second, redundant resume event checks that
        // a duplicate doesn't complete the abort trigger twice.)
        prepareHeartbeat(2);
        updateMachine.debugAdvanceLoop();
        testBinding.notifyAppLifecycleStateChanged(.resumed);
        testBinding.notifyAppLifecycleStateChanged(.resumed);
        async.flushMicrotasks();
        checkLastRequest(lastEventId: 1, expectDontBlock: true);
        // The wake also discarded the accumulated backoff state.
        check(updateMachine.debugPollBackoffMachine).isNull();
        async.elapse(Duration.zero);
        check(updateMachine.lastEventId).equals(2);
        check(store).isRecoveringEventStream.isFalse();
      }));

      test('reset backoff state on resume with no wait in progress', () => awaitFakeAsync((async) async {
        // A resume means the preceding connection failures were probably
        // sleep-induced, so the grown backoff state is discarded even when
        // there's no wait in progress to abort: if polling fails again
        // after the wake (the network can take a moment to come back),
        // backoff should start over small.
        BackoffMachine.debugDuration = const Duration(seconds: 10);
        addTearDown(() => BackoffMachine.debugDuration = null);
        await preparePoll(lastEventId: 1);

        // Fail, and wait out the backoff normally.
        prepareNetworkExceptionConnectionFailed();
        updateMachine.debugAdvanceLoop();
        async.elapse(Duration.zero);
        async.flushTimers();
        check(updateMachine.debugPollBackoffMachine).isNotNull();

        testBinding.notifyAppLifecycleStateChanged(.resumed);
        async.flushMicrotasks();
        check(updateMachine.debugPollBackoffMachine).isNull();
      }));

      test('no abort when backoff is from non-network error', () => awaitFakeAsync((async) async {
        BackoffMachine.debugDuration = const Duration(seconds: 10);
        addTearDown(() => BackoffMachine.debugDuration = null);
        await preparePoll(lastEventId: 1);

        prepareServer5xxException();
        updateMachine.debugAdvanceLoop();
        async.elapse(Duration.zero);
        checkLastRequest(lastEventId: 1);
        check(async.pendingTimers).length.equals(1);

        // Coming to the foreground doesn't cut the backoff short,
        // and doesn't discard the accumulated backoff state either.
        updateMachine.debugAdvanceLoop();
        testBinding.notifyAppLifecycleStateChanged(.resumed);
        async.flushMicrotasks();
        check(connection.lastRequest).isNull();
        check(async.pendingTimers).length.equals(1);
        check(updateMachine.debugPollBackoffMachine).isNotNull();

        // Polling continues after the backoff.
        prepareHeartbeat(2);
        async.flushTimers();
        checkLastRequest(lastEventId: 1, expectDontBlock: true);
        check(updateMachine.lastEventId).equals(2);
      }));

      test('no abort when backoff is from a non-connectionFailed network error', () => awaitFakeAsync((async) async {
        BackoffMachine.debugDuration = const Duration(seconds: 10);
        addTearDown(() => BackoffMachine.debugDuration = null);
        await preparePoll(lastEventId: 1);

        // Fail with a transport error that isn't a failed connection:
        // a TLS failure, as from an expired server certificate.
        // See #1884 for why an app resume should cut short only
        // failed-connection backoffs.
        prepareNetworkExceptionOther();
        updateMachine.debugAdvanceLoop();
        async.elapse(Duration.zero);
        checkLastRequest(lastEventId: 1);
        final machineBefore = updateMachine.debugPollBackoffMachine;
        check(machineBefore).isNotNull();

        // The app resuming doesn't cut the backoff short,
        // and doesn't discard the accumulated backoff state either.
        updateMachine.debugAdvanceLoop();
        testBinding.notifyAppLifecycleStateChanged(.resumed);
        async.flushMicrotasks();
        check(connection.lastRequest).isNull();
        check(updateMachine.debugPollBackoffMachine).identicalTo(machineBefore);

        // Polling continues after the backoff.
        prepareHeartbeat(2);
        async.flushTimers();
        checkLastRequest(lastEventId: 1, expectDontBlock: true);
        check(updateMachine.lastEventId).equals(2);
      }));

      test('no effect when no backoff in progress', () => awaitFakeAsync((async) async {
        await preparePoll(lastEventId: 1);

        testBinding.notifyAppLifecycleStateChanged(.resumed);
        async.flushMicrotasks();
        check(connection.lastRequest).isNull();
        check(async.pendingTimers).isEmpty();
      }));

      test('no effect after dispose', () => awaitFakeAsync((async) async {
        await preparePoll(lastEventId: 1);

        updateMachine.dispose();
        testBinding.notifyAppLifecycleStateChanged(.resumed);
        async.flushMicrotasks();
      }));
    });

    group('abort stalled poll on connectivity change', () {
      /// Start a poll request that gets stuck
      /// (see [prepareStuckPollResponse]).
      void startStuckPoll(FakeAsync async) {
        prepareStuckPollResponse();
        updateMachine.debugAdvanceLoop();
        async.flushMicrotasks();
        checkLastRequest(lastEventId: 1);
      }

      test('abort request stuck awaiting response', () => awaitFakeAsync((async) async {
        // Regression test for: https://github.com/zulip/zulip-flutter/issues/2415
        BackoffMachine.debugDuration = const Duration(seconds: 1);
        addTearDown(() => BackoffMachine.debugDuration = null);
        await preparePoll(lastEventId: 1);

        startStuckPoll(async);
        async.elapse(const Duration(seconds: 30));

        // On a connectivity change, the stuck request is aborted.
        // It fails like any failed request -- the recovering state
        // shows -- but with the backoff state discarded, so the retry
        // goes out after just the initial backoff.
        prepareHeartbeat(2);
        updateMachine.debugAdvanceLoop();
        testBinding.notifyConnectivityChanged([.mobile]);
        async.flushMicrotasks();
        check(store).isRecoveringEventStream.isTrue();
        async.elapse(const Duration(seconds: 1));
        checkLastRequest(lastEventId: 1, expectDontBlock: true);
        check(updateMachine.lastEventId).equals(2);
        check(store).isRecoveringEventStream.isFalse();
      }));

      test('discard accumulated backoff state on abort', () => awaitFakeAsync((async) async {
        BackoffMachine.debugDuration = const Duration(seconds: 1);
        addTearDown(() => BackoffMachine.debugDuration = null);
        await preparePoll(lastEventId: 1);

        // Fail once, so that backoff state accumulates.
        prepareServer5xxException();
        updateMachine.debugAdvanceLoop();
        async.elapse(Duration.zero);
        checkLastRequest(lastEventId: 1);

        // The retry gets stuck.
        prepareStuckPollResponse();
        updateMachine.debugAdvanceLoop();
        async.elapse(const Duration(seconds: 1));
        checkLastRequest(lastEventId: 1, expectDontBlock: true);
        final machineBefore = updateMachine.debugPollBackoffMachine;
        check(machineBefore).isNotNull();

        // The abort discards the accumulated backoff state: after the
        // failed request, error handling creates a fresh backoff machine.
        updateMachine.debugAdvanceLoop();
        testBinding.notifyConnectivityChanged([.mobile]);
        async.flushMicrotasks();
        check(updateMachine.debugPollBackoffMachine)
          ..isNotNull()
          ..not((it) => it.identicalTo(machineBefore));
      }));

      test('abort backoff wait from a failed connection', () => awaitFakeAsync((async) async {
        BackoffMachine.debugDuration = const Duration(seconds: 10);
        addTearDown(() => BackoffMachine.debugDuration = null);
        await preparePoll(lastEventId: 1);

        // Fail to connect, entering a backoff wait.
        prepareNetworkExceptionConnectionFailed();
        updateMachine.debugAdvanceLoop();
        async.elapse(Duration.zero);
        checkLastRequest(lastEventId: 1);
        check(async.pendingTimers).length.equals(1);

        // A connectivity change cuts the wait short: the network
        // the request failed on may be gone, so retry on the new one.
        prepareHeartbeat(2);
        updateMachine.debugAdvanceLoop();
        testBinding.notifyConnectivityChanged([.mobile]);
        async.flushMicrotasks();
        checkLastRequest(lastEventId: 1, expectDontBlock: true);
        // The change also discarded the accumulated backoff state.
        check(updateMachine.debugPollBackoffMachine).isNull();
        async.elapse(Duration.zero);
        check(updateMachine.lastEventId).equals(2);
      }));

      void checkNoAbortOfBackoffWait(void Function() prepareError) {
        awaitFakeAsync((async) async {
          BackoffMachine.debugDuration = const Duration(seconds: 10);
          addTearDown(() => BackoffMachine.debugDuration = null);
          await preparePoll(lastEventId: 1);

          // Make the request, inducing an error in it,
          // and entering a backoff wait.
          prepareError();
          updateMachine.debugAdvanceLoop();
          async.elapse(Duration.zero);
          checkLastRequest(lastEventId: 1);
          check(async.pendingTimers).length.equals(1);
          final machineBefore = updateMachine.debugPollBackoffMachine;
          check(machineBefore).isNotNull();

          // A connectivity change neither cuts the wait short
          // nor discards the accumulated backoff state.
          updateMachine.debugAdvanceLoop();
          testBinding.notifyConnectivityChanged([.mobile]);
          async.flushMicrotasks();
          check(connection.lastRequest).isNull();
          check(updateMachine.debugPollBackoffMachine).identicalTo(machineBefore);

          // Polling continues after the backoff.
          prepareHeartbeat(2);
          async.flushTimers();
          checkLastRequest(lastEventId: 1, expectDontBlock: true);
          check(updateMachine.lastEventId).equals(2);
        });
      }

      test('no abort of backoff wait from a non-connectionFailed transport failure', () {
        // A transport error that isn't a failed connection
        // (a TLS failure, of kind [NetworkExceptionKind.other]).
        // As on app resume, a connectivity change leaves its wait alone.
        checkNoAbortOfBackoffWait(prepareNetworkExceptionOther);
      });

      test('no abort of backoff wait from a server error', () {
        // The server itself failed: the network demonstrably worked,
        // so a connectivity change is no reason to retry sooner.
        checkNoAbortOfBackoffWait(prepareServer5xxException);
      });

      test('deferred retry signal: abort a retry that predates the change', () => awaitFakeAsync((async) async {
        BackoffMachine.debugDuration = const Duration(seconds: 1);
        addTearDown(() => BackoffMachine.debugDuration = null);
        await preparePoll(lastEventId: 1);

        startStuckPoll(async);

        // The first change aborts the poll…
        prepareStuckPollResponse();
        updateMachine.debugAdvanceLoop();
        testBinding.notifyConnectivityChanged([.mobile]);
        async.elapse(const Duration(seconds: 1));
        checkLastRequest(lastEventId: 1, expectDontBlock: true);

        // …but another change soon after doesn't abort the retry
        // immediately…
        // (Let the loop run, so that an abort would show up as a retry.)
        prepareHeartbeat(2);
        updateMachine.debugAdvanceLoop();
        async.elapse(const Duration(seconds: 4));
        testBinding.notifyConnectivityChanged([.wifi]);
        async.elapse(const Duration(seconds: 4));
        check(connection.lastRequest).isNull();

        // …only when the deferred signal comes at the cooldown's end:
        // the retry predates that change, so its connection is suspect too.
        async.elapse(const Duration(seconds: 2));
        checkLastRequest(lastEventId: 1, expectDontBlock: true);
        check(updateMachine.lastEventId).equals(2);
      }));

      test('deferred retry signal: no abort once a fresh request has started', () => awaitFakeAsync((async) async {
        BackoffMachine.debugDuration = const Duration(seconds: 1);
        addTearDown(() => BackoffMachine.debugDuration = null);
        await preparePoll(lastEventId: 1);

        startStuckPoll(async);

        // A change aborts the poll; the retry is slow but healthy.
        prepareHeartbeat(2, delay: const Duration(seconds: 5));
        updateMachine.debugAdvanceLoop();
        testBinding.notifyConnectivityChanged([.mobile]);
        final cooldownEnd = async.elapsed + ConnectivityMonitor.retrySignalCooldown;
        async.elapse(const Duration(seconds: 1));
        checkLastRequest(lastEventId: 1, expectDontBlock: true);

        // Another change lands during the cooldown, deferred.
        async.elapse(const Duration(seconds: 2));
        testBinding.notifyConnectivityChanged([.wifi]);
        async.flushMicrotasks();
        check(connection.lastRequest).isNull();

        // The retry completes, and the next poll goes out --
        // a request made after the change, on the current network.
        prepareStuckPollResponse();
        updateMachine.debugAdvanceLoop();
        async.elapse(const Duration(seconds: 3));
        checkLastRequest(lastEventId: 2);
        check(updateMachine.lastEventId).equals(2);

        // So when the cooldown ends, the deferred change is moot:
        // the poll is left alone.
        async.elapse(cooldownEnd - async.elapsed);
        check(connection.lastRequest).isNull();
        check(store).isRecoveringEventStream.isFalse();
      }));

      test('no effect after dispose', () => awaitFakeAsync((async) async {
        await preparePoll(lastEventId: 1);

        updateMachine.dispose();
        testBinding.notifyConnectivityChanged([.mobile]);
        async.flushMicrotasks();
      }));
    });

    group('report error', () {
      String? lastReportedError;
      String? takeLastReportedError() {
        final result = lastReportedError;
        lastReportedError = null;
        return result;
      }

      Future<void> logReportedError(String? message, {String? details}) async {
        if (message == null) return;
        lastReportedError = '$message\n$details';
      }

      Future<void> prepare() async {
        reportErrorToUserBriefly = logReportedError;
        addTearDown(() => reportErrorToUserBriefly = defaultReportErrorToUserBriefly);
        await preparePoll(lastEventId: 1);
      }

      void pollAndFail(FakeAsync async, {bool shouldCheckRequest = true, bool expectDontBlock = false}) {
        updateMachine.debugAdvanceLoop();
        async.elapse(Duration.zero);
        if (shouldCheckRequest) {
          checkLastRequest(lastEventId: 1, expectDontBlock: expectDontBlock);
        }
        check(store).isRecoveringEventStream.isTrue();
      }

      Subject<String> checkReported(void Function() prepareError) {
        return awaitFakeAsync((async) async {
          await prepare();
          prepareError();
          // No need to check on the request; there's no later step of this test
          // for it to be needed as setup for.
          pollAndFail(async, shouldCheckRequest: false);
          return check(takeLastReportedError()).isNotNull();
        });
      }

      Subject<String> checkLateReported(void Function() prepareError) {
        return awaitFakeAsync((async) async {
          await prepare();

          bool expectDontBlock = false;
          for (int i = 0; i < UpdateMachine.transientFailureCountNotifyThreshold; i++) {
            prepareError();
            pollAndFail(async, expectDontBlock: expectDontBlock);
            expectDontBlock = true;
            check(takeLastReportedError()).isNull();
            async.flushTimers();
            if (!identical(store, globalStore.perAccountSync(store.accountId))) {
              // Store was reloaded.
              updateFromGlobalStore();
              updateMachine.debugPauseLoop();
              updateMachine.poll();
              // Loading indicator is cleared on successful /register;
              // we don't need dont_block for the new queue's first poll.
              expectDontBlock = false;
            }
          }

          prepareError();
          pollAndFail(async, expectDontBlock: expectDontBlock);
          return check(takeLastReportedError()).isNotNull();
        });
      }

      void checkNotReported(void Function() prepareError) {
        return awaitFakeAsync((async) async {
          await prepare();

          bool expectDontBlock = false;
          for (int i = 0; i < UpdateMachine.transientFailureCountNotifyThreshold; i++) {
            prepareError();
            pollAndFail(async, expectDontBlock: expectDontBlock);
            expectDontBlock = true;
            check(takeLastReportedError()).isNull();
            async.flushTimers();
            if (!identical(store, globalStore.perAccountSync(store.accountId))) {
              // Store was reloaded.
              updateFromGlobalStore();
              updateMachine.debugPauseLoop();
              updateMachine.poll();
              // Loading indicator is cleared on successful /register;
              // we don't need dont_block for the new queue's first poll.
              expectDontBlock = false;
            }
          }

          prepareError();
          pollAndFail(async, expectDontBlock: expectDontBlock);
          // Still no error reported, even after the same number of iterations
          // where other errors get reported (as [checkLateReported] checks).
          check(takeLastReportedError()).isNull();
        });
      }

      test('report unexpected error within loop', () {
        checkReported(prepareUnexpectedLoopError);
      });

      test('ignore NetworkException from failed connection', () {
        checkNotReported(prepareNetworkExceptionConnectionFailed);
      });

      test('eventually report NetworkException with NetworkExceptionKind.other', () {
        checkLateReported(prepareNetworkExceptionOther).startsWith(
          "Error connecting to Zulip. Retrying…\n"
          "Error connecting to Zulip at");
      });

      test('eventually report Server5xxException', () {
        checkLateReported(prepareServer5xxException).startsWith(
          "Error connecting to Zulip. Retrying…\n"
          "Error connecting to Zulip at");
      });

      test('report MalformedServerResponseException', () {
        checkReported(prepareMalformedServerResponseException).startsWith(
          "Error connecting to Zulip. Retrying…\n"
          "Error connecting to Zulip at");
      });

      test('report rate limit: code RATE_LIMIT_HIT', () {
        checkLateReported(prepareRateLimitExceptionCode).startsWith(
          "Error connecting to Zulip. Retrying…\n"
          "Error connecting to Zulip at");
      });

      test('report rate limit: status 429 ZulipApiException', () {
        checkLateReported(prepareRateLimitExceptionStatus).startsWith(
          "Error connecting to Zulip. Retrying…\n"
          "Error connecting to Zulip at");
      });

      test('report rate limit: status 429 MalformedServerResponseException', () {
        checkLateReported(prepareRateLimitExceptionMalformed).startsWith(
          "Error connecting to Zulip. Retrying…\n"
          "Error connecting to Zulip at");
      });

      test('report generic ZulipApiException', () {
        checkReported(prepareZulipApiExceptionBadRequest).startsWith(
          "Error connecting to Zulip. Retrying…\n"
          "Error connecting to Zulip at");
      });

      test('ignore expired queue', () {
        checkNotReported(prepareExpiredEventQueue);
      });

      test('nicely report handleEvent error', () {
        checkReported(prepareHandleEventError).matchesPattern(RegExp(
          r"Error handling a Zulip event\. Retrying connection…\n"
          r"Error handling a Zulip event from \S+; will retry\.\n"
          r"\n"
          r"Error: .*channel\.dart.. Failed assertion.*"
        ));
      });
    });
  });

  group('UpdateMachine.poll reload failure', () {
    late UpdateMachineTestGlobalStore globalStore;

    Future<void> prepareReload(FakeAsync async, {
      required void Function(FakeApiConnection) prepareRegisterQueueResponse,
    }) async {
      globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);

      final store = await globalStore.perAccount(eg.selfAccount.id);
      final updateMachine = store.updateMachine!;

      final connection = store.connection as FakeApiConnection;
      connection.prepare(
        apiException: eg.apiExceptionBadEventQueueId());
      globalStore.prepareRegisterQueueResponse = prepareRegisterQueueResponse;
      // When we reload, we should get a new connection,
      // just like when the app runs live. This is more realistic,
      // and we don't want a glitch where we try to double-close a connection
      // just because of the test infrastructure. (One of the tests
      // logs out the account, and the connection shouldn't be used after that.)
      globalStore.clearCachedApiConnections();
      updateMachine.debugAdvanceLoop();
      async.elapse(Duration.zero); // the bad-event-queue error arrives
      check(store).isRecoveringEventStream.isTrue();
    }

    test('user logged out before new store is loaded', () => awaitFakeAsync((async) async {
      await prepareReload(async, prepareRegisterQueueResponse: (connection) {
        connection.prepare(
          delay: TestGlobalStore.removeAccountDuration + Duration(seconds: 1),
          json: eg.initialSnapshot().toJson());
      });

      globalStore.clearCachedApiConnections();
      await logOutAccount(globalStore, eg.selfAccount.id);
      check(globalStore.takeDoRemoveAccountCalls()).single.equals(eg.selfAccount.id);

      async.elapse(TestGlobalStore.removeAccountDuration);
      check(globalStore.perAccountSync(eg.selfAccount.id)).isNull();

      async.flushTimers();
      // Reload never succeeds and there are no unhandled errors.
      check(globalStore.perAccountSync(eg.selfAccount.id)).isNull();
    }));

    test('new store is not loaded, gets HTTP 401 error instead', () => awaitFakeAsync((async) async {
      await prepareReload(async, prepareRegisterQueueResponse: (connection) {
        connection.prepare(
          delay: Duration(seconds: 1),
          apiException: eg.apiExceptionUnauthorized());
      });

      async.elapse(const Duration(seconds: 1));
      check(globalStore.takeDoRemoveAccountCalls()).single.equals(eg.selfAccount.id);

      async.elapse(TestGlobalStore.removeAccountDuration);
      check(globalStore.perAccountSync(eg.selfAccount.id)).isNull();

      async.flushTimers();
      // Reload never succeeds and there are no unhandled errors.
      check(globalStore.perAccountSync(eg.selfAccount.id)).isNull();
    }));

    test('new store is not loaded, gets InitialSnapshot with ancient server version', () => awaitFakeAsync((async) async {
      final json = eg.initialSnapshot(zulipFeatureLevel: eg.ancientZulipFeatureLevel).toJson();
      await prepareReload(async, prepareRegisterQueueResponse: (connection) {
        connection.prepare(
          delay: Duration(seconds: 1),
          json: json);
      });

      async.elapse(const Duration(seconds: 1));
      check(globalStore.takeDoRemoveAccountCalls()).single.equals(eg.selfAccount.id);

      async.elapse(TestGlobalStore.removeAccountDuration);
      check(globalStore.perAccountSync(eg.selfAccount.id)).isNull();

      async.flushTimers();
      // Reload never succeeds and there are no unhandled errors.
      check(globalStore.perAccountSync(eg.selfAccount.id)).isNull();
    }));

    test('new store is not loaded, gets malformed response with ancient server version', () => awaitFakeAsync((async) async {
      final json = eg.initialSnapshot(zulipFeatureLevel: eg.ancientZulipFeatureLevel).toJson();
      json['realm_emoji'] = 123;
      check(() => InitialSnapshot.fromJson(json)).throws<void>();
      await prepareReload(async, prepareRegisterQueueResponse: (connection) {
        connection.prepare(
          delay: Duration(seconds: 1),
          json: json);
      });

      async.elapse(const Duration(seconds: 1));
      check(globalStore.takeDoRemoveAccountCalls()).single.equals(eg.selfAccount.id);

      async.elapse(TestGlobalStore.removeAccountDuration);
      check(globalStore.perAccountSync(eg.selfAccount.id)).isNull();

      async.flushTimers();
      // Reload never succeeds and there are no unhandled errors.
      check(globalStore.perAccountSync(eg.selfAccount.id)).isNull();
    }));
  });

  group('UpdateMachine stores server data', () {
    late UpdateMachineTestGlobalStore globalStore;
    late PerAccountStore store;
    late UpdateMachine updateMachine;
    late FakeApiConnection connection;
    String? lastReportedError;

    ServerSnapshot? storedSnapshot() =>
      globalStore.backend.serverSnapshotOf(eg.selfAccount.id);
    List<ServerEventBatch> storedEventBatches() =>
      globalStore.backend.serverEventBatchesOf(eg.selfAccount.id);

    String registerQueueBody({required String queueId}) =>
      jsonEncode(eg.initialSnapshot(queueId: queueId, lastEventId: 1));

    /// Load the store, with an event queue 'queue1' at last event ID 1.
    ///
    /// The first poll request gets a heartbeat event with ID 2;
    /// unless [handleFirstPoll] is false, that's handled before this returns.
    Future<void> prepare(FakeAsync async, {
      void Function(FakeApiConnection)? prepareRegisterQueueResponse,
      Object? storeServerSnapshotError,
      bool handleFirstPoll = true,
    }) async {
      addTearDown(testBinding.reset);
      lastReportedError = null;
      reportErrorToUserBriefly = (message, {details}) async {
        if (message == null) return;
        lastReportedError = message;
      };
      addTearDown(() => reportErrorToUserBriefly = defaultReportErrorToUserBriefly);

      globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);
      globalStore.backend.storeServerSnapshotError = storeServerSnapshotError;
      globalStore.prepareRegisterQueueResponse = prepareRegisterQueueResponse
        ?? (connection) => connection.prepare(body: registerQueueBody(queueId: 'queue1'));
      store = await globalStore.perAccount(eg.selfAccount.id);
      updateMachine = store.updateMachine!;
      connection = store.connection as FakeApiConnection;
      connection.takeRequests();
      async.flushMicrotasks();
      if (handleFirstPoll) {
        async.elapse(Duration.zero);
        check(updateMachine.lastEventId).equals(2);
      }
    }

    Map<String, dynamic> rawEvent(Event event) =>
      jsonDecode(jsonEncode(event)) as Map<String, dynamic>;

    List<Object?> decodeEvents(ServerEventBatch batch) =>
      jsonDecode(utf8.decode(batch.data)) as List<Object?>;

    void preparePollResponse(List<Map<String, dynamic>> rawEvents) {
      connection.prepare(json: {'events': rawEvents, 'queue_id': 'queue1'});
    }

    /// Let the poll loop make a request, and handle the response.
    void advancePoll(FakeAsync async) {
      updateMachine.debugAdvanceLoop();
      async.elapse(Duration.zero);
    }

    void checkPollRequest({required int lastEventId}) {
      check(connection.takeRequests()).single.isA<http.Request>()
        ..method.equals('GET')
        ..url.path.equals('/api/v1/events')
        ..url.queryParameters['last_event_id'].equals(lastEventId.toString());
    }

    void checkPollingContinues(FakeAsync async, {required int lastEventId}) {
      preparePollResponse([rawEvent(HeartbeatEvent(id: lastEventId + 1))]);
      advancePoll(async);
      checkPollRequest(lastEventId: lastEventId);
      check(updateMachine.lastEventId).equals(lastEventId + 1);
      check(globalStore.perAccountSync(eg.selfAccount.id)).identicalTo(store);
      check(store).isRecoveringEventStream.isFalse();
      check(lastReportedError).isNull();
    }

    final messageEvent = {
      ...rawEvent(eg.messageEvent(eg.dmMessage(id: 1003,
        from: eg.otherUser, to: [eg.selfUser]))),
      'id': 3,
      'some_unknown_field': [1, 2],
    };

    final now = DateTime.utc(2026, 11, 12, 10, 30);

    test('store register response', () => awaitFakeAsync(initialTime: now, (async) async {
      testBinding.packageInfoResult = eg.packageInfo(
        version: '2.3.4', buildNumber: '567');
      final body = jsonEncode({
        ...eg.initialSnapshot(queueId: 'queue1', lastEventId: 1).toJson(),
        'some_unknown_field': [1, 2],
      });
      await prepare(async, handleFirstPoll: false,
        prepareRegisterQueueResponse: (connection) => connection.prepare(body: body));
      check(storedSnapshot()).isNotNull()
        ..accountId.equals(eg.selfAccount.id)
        ..queueId.equals('queue1')
        ..lastEventId.equals(1)
        ..appVersion.equals('2.3.4+567')
        ..timestamp.equals(now.millisecondsSinceEpoch ~/ 1000);
      check(globalStore.backend.serverSnapshotDataOf(eg.selfAccount.id))
        .isNotNull().deepEquals(utf8.encode(body));
      check(storedEventBatches()).isEmpty();
    }));

    test('store response of successful register attempt only', () => awaitFakeAsync((async) async {
      final body = registerQueueBody(queueId: 'queue1');
      await prepare(async, handleFirstPoll: false,
        prepareRegisterQueueResponse: (connection) => connection
          ..prepare(body: body.substring(0, 100),
            bodyException: http.ClientException('connection reset'))
          ..prepare(body: body));
      check(globalStore.backend.serverSnapshotDataOf(eg.selfAccount.id))
        .isNotNull().deepEquals(utf8.encode(body));
    }));

    test('nothing stored when app version unknown', () => awaitFakeAsync((async) async {
      testBinding.packageInfoResult = null;
      await prepare(async);
      check(storedSnapshot()).isNull();

      preparePollResponse([messageEvent]);
      advancePoll(async);
      checkPollRequest(lastEventId: 2);
      check(storedSnapshot()).isNull();
      check(storedEventBatches()).isEmpty();
      checkPollingContinues(async, lastEventId: 3);
    }));

    test('heartbeat advances ack point, without storing batch', () => awaitFakeAsync((async) async {
      await prepare(async, handleFirstPoll: false);
      check(storedSnapshot()!).lastEventId.equals(1);

      async.elapse(Duration.zero);
      check(updateMachine.lastEventId).equals(2);
      check(storedSnapshot()!).lastEventId.equals(2);
      check(storedEventBatches()).isEmpty();
    }));

    test('append each batch, without ephemeral events', () => awaitFakeAsync((async) async {
      await prepare(async);

      preparePollResponse([
        messageEvent,
        {'id': 4, 'type': 'typing', 'op': 'start', 'message_type': 'direct',
          'sender': {'user_id': eg.otherUser.userId, 'email': eg.otherUser.email},
          'recipients': [eg.selfUser, eg.otherUser].map((user) =>
            {'user_id': user.userId, 'email': user.email}).toList()},
        rawEvent(PresenceEvent(id: 5, userId: eg.otherUser.userId,
          serverTimestamp: 1000,
          presence: {'website': PerClientPresence(client: 'website',
            status: PresenceStatus.active, timestamp: 1000, pushable: false)})),
      ]);
      advancePoll(async);
      checkPollRequest(lastEventId: 2);
      check(storedEventBatches()).single
        ..queueId.equals('queue1')
        ..lastEventId.equals(5)
        ..has(decodeEvents, 'events').deepEquals([messageEvent]);
      check(storedSnapshot()!).lastEventId.equals(5);

      final settingsEvent = rawEvent(UserSettingsUpdateEvent(id: 6,
        property: UserSettingName.twentyFourHourTime, value: true));
      preparePollResponse([settingsEvent]);
      advancePoll(async);
      checkPollRequest(lastEventId: 5);
      check(storedEventBatches()).deepEquals(<Condition<Object?>>[
        (it) => it.isA<ServerEventBatch>().lastEventId.equals(5),
        (it) => it.isA<ServerEventBatch>()
          ..lastEventId.equals(6)
          ..has(decodeEvents, 'events').deepEquals([settingsEvent]),
      ]);
      check(storedSnapshot()!).lastEventId.equals(6);
    }));

    test('append completes before next poll request', () => awaitFakeAsync((async) async {
      await prepare(async);
      final gate = Completer<void>();
      globalStore.backend.appendServerEventsGate = gate.future;

      preparePollResponse([messageEvent]);
      advancePoll(async);
      checkPollRequest(lastEventId: 2);
      updateMachine.debugAdvanceLoop();
      async.elapse(Duration.zero);
      check(connection.takeRequests()).isEmpty();
      check(updateMachine.lastEventId).equals(2);
      check(storedEventBatches()).isEmpty();

      preparePollResponse([rawEvent(HeartbeatEvent(id: 4))]);
      gate.complete();
      async.flushMicrotasks();
      check(storedEventBatches()).single.lastEventId.equals(3);
      checkPollRequest(lastEventId: 3);
    }));

    test('nothing appended when handling event fails', () => awaitFakeAsync((async) async {
      await prepare(async);
      final channel = eg.stream();
      await store.addStream(channel);
      // Break an invariant, so that handling the event throws;
      // compare `prepareHandleEventError` above.
      store.streamsByName.remove(channel.name);
      globalStore.clearCachedApiConnections();

      preparePollResponse([
        messageEvent,
        rawEvent(ChannelDeleteEvent(id: 4, channelIds: [channel.streamId])),
      ]);
      advancePoll(async);
      check(store).isRecoveringEventStream.isTrue();
      check(storedEventBatches()).isEmpty();
      check(storedSnapshot()!)
        ..queueId.equals('queue1')
        ..lastEventId.equals(2);
    }));

    test('reload replaces snapshot and drops batches', () => awaitFakeAsync((async) async {
      await prepare(async);
      preparePollResponse([messageEvent]);
      advancePoll(async);
      check(storedEventBatches()).length.equals(1);

      connection.prepare(apiException: eg.apiExceptionBadEventQueueId(
        queueId: store.queueId));
      globalStore.prepareRegisterQueueResponse = (connection) {
        connection.prepare(body: registerQueueBody(queueId: 'queue2'));
      };
      globalStore.clearCachedApiConnections();
      advancePoll(async);
      async.flushMicrotasks();
      check(globalStore.perAccountSync(eg.selfAccount.id))
        .isNotNull().not((it) => it.identicalTo(store));
      check(storedSnapshot()).isNotNull().queueId.equals('queue2');
      check(storedEventBatches()).isEmpty();
    }));

    test('snapshot not stored; load succeeds, nothing appended', () => awaitFakeAsync((async) async {
      await prepare(async, storeServerSnapshotError: Exception('disk full'));
      check(storedSnapshot()).isNull();

      preparePollResponse([messageEvent]);
      advancePoll(async);
      checkPollRequest(lastEventId: 2);
      check(storedSnapshot()).isNull();
      check(storedEventBatches()).isEmpty();
      checkPollingContinues(async, lastEventId: 3);
    }));

    test('append fails; data cleared, polling continues', () => awaitFakeAsync((async) async {
      await prepare(async);
      check(storedSnapshot()).isNotNull();

      globalStore.backend.appendServerEventsError = Exception('disk full');
      preparePollResponse([messageEvent]);
      advancePoll(async);
      checkPollRequest(lastEventId: 2);
      check(storedSnapshot()).isNull();
      check(storedEventBatches()).isEmpty();
      check(updateMachine.lastEventId).equals(3);
      checkPollingContinues(async, lastEventId: 3);
    }));

    Map<String, dynamic> settingsEvent(int id) => rawEvent(
      UserSettingsUpdateEvent(id: id,
        property: UserSettingName.twentyFourHourTime, value: true));

    test('stop storing event log once too long', () => awaitFakeAsync((async) async {
      UpdateMachine.debugMaxStoredEventCount = 3;
      addTearDown(() => UpdateMachine.debugMaxStoredEventCount = null);
      await prepare(async); // snapshot at event 1; heartbeat 2
      preparePollResponse([messageEvent]); // event 3
      advancePoll(async);
      checkPollRequest(lastEventId: 2);
      preparePollResponse([settingsEvent(4)]);
      advancePoll(async);
      checkPollRequest(lastEventId: 3);
      check(storedEventBatches()).length.equals(2);
      check(storedSnapshot()!)
        ..lastEventId.equals(4)
        ..eventLogTruncated.isFalse();

      preparePollResponse([settingsEvent(5)]);
      advancePoll(async);
      checkPollRequest(lastEventId: 4);
      check(storedEventBatches()).isEmpty();
      check(storedSnapshot()!)
        ..lastEventId.equals(5)
        ..eventLogTruncated.isTrue();

      preparePollResponse([settingsEvent(6)]);
      advancePoll(async);
      checkPollRequest(lastEventId: 5);
      check(storedEventBatches()).isEmpty();
      check(storedSnapshot()!).lastEventId.equals(6);
      checkPollingContinues(async, lastEventId: 6);
    }));

    test('stop storing event log once too big, and bigger than snapshot', () => awaitFakeAsync((async) async {
      UpdateMachine.debugMaxStoredEventBatchesSize = 10;
      addTearDown(() => UpdateMachine.debugMaxStoredEventBatchesSize = null);
      final snapshotSize = utf8.encode(registerQueueBody(queueId: 'queue1')).length;
      // Each of these is a bit more than half the size of the snapshot.
      Map<String, dynamic> bigEvent(int id) =>
        rawEvent(AlertWordsEvent(id: id, alertWords: ['x' * (snapshotSize ~/ 2)]));
      await prepare(async);
      // Bigger than the limit, but not the snapshot.
      preparePollResponse([bigEvent(3)]);
      advancePoll(async);
      checkPollRequest(lastEventId: 2);
      check(storedEventBatches()).single.lastEventId.equals(3);
      check(storedSnapshot()!).eventLogTruncated.isFalse();

      preparePollResponse([bigEvent(4)]);
      advancePoll(async);
      checkPollRequest(lastEventId: 3);
      check(storedEventBatches()).isEmpty();
      check(storedSnapshot()!)
        ..lastEventId.equals(4)
        ..eventLogTruncated.isTrue();

      preparePollResponse([{...messageEvent, 'id': 5}]);
      advancePoll(async);
      check(storedEventBatches()).isEmpty();
      check(storedSnapshot()!).lastEventId.equals(5);
    }));

    test('fresh register stores event log again', () => awaitFakeAsync((async) async {
      UpdateMachine.debugMaxStoredEventCount = 2;
      addTearDown(() => UpdateMachine.debugMaxStoredEventCount = null);
      await prepare(async); // snapshot at event 1; heartbeat 2
      preparePollResponse([messageEvent]); // event 3
      advancePoll(async);
      preparePollResponse([settingsEvent(4)]);
      advancePoll(async);
      check(storedSnapshot()!).eventLogTruncated.isTrue();

      connection.prepare(apiException: eg.apiExceptionBadEventQueueId(
        queueId: store.queueId));
      globalStore.prepareRegisterQueueResponse = (connection) {
        connection.prepare(body: registerQueueBody(queueId: 'queue2'));
      };
      globalStore.clearCachedApiConnections();
      advancePoll(async);
      async.elapse(Duration.zero);
      final newStore = globalStore.perAccountSync(eg.selfAccount.id)!;
      check(newStore).queueId.equals('queue2');
      check(newStore.updateMachine!.lastEventId).equals(2);
      check(storedSnapshot()!)
        ..queueId.equals('queue2')
        ..eventLogTruncated.isFalse();

      (newStore.connection as FakeApiConnection).prepare(json: {
        'events': [messageEvent], 'queue_id': 'queue2'});
      newStore.updateMachine!.debugAdvanceLoop();
      async.elapse(Duration.zero);
      check(storedEventBatches()).single
        ..queueId.equals('queue2')
        ..lastEventId.equals(3);
    }));

    test('append rejected; stop storing, polling continues', () => awaitFakeAsync((async) async {
      await prepare(async);
      // As if another load stored a snapshot for another queue.
      await globalStore.backend.doStoreServerSnapshot(
        eg.serverSnapshot(account: eg.selfAccount, queueId: 'queue2'),
        data: utf8.encode(registerQueueBody(queueId: 'queue2')));

      preparePollResponse([messageEvent]);
      advancePoll(async);
      checkPollRequest(lastEventId: 2);
      check(updateMachine.lastEventId).equals(3);
      check(storedSnapshot()!).queueId.equals('queue2');
      check(storedEventBatches()).isEmpty();

      // Even if this queue's snapshot is somehow back,
      // nothing more gets appended for it.
      await globalStore.backend.doStoreServerSnapshot(
        eg.serverSnapshot(account: eg.selfAccount,
          queueId: 'queue1', lastEventId: 1),
        data: utf8.encode(registerQueueBody(queueId: 'queue1')));
      preparePollResponse([settingsEvent(4)]);
      advancePoll(async);
      checkPollRequest(lastEventId: 3);
      check(storedSnapshot()!).lastEventId.equals(1);
      check(storedEventBatches()).isEmpty();
      checkPollingContinues(async, lastEventId: 4);
    }));

    test('append fails, then clearing fails; polling continues', () => awaitFakeAsync((async) async {
      await prepare(async);
      globalStore.backend.appendServerEventsError = Exception('disk full');
      globalStore.backend.clearServerDataError = Exception('disk I/O error');
      preparePollResponse([messageEvent]);
      advancePoll(async);
      checkPollRequest(lastEventId: 2);
      check(updateMachine.lastEventId).equals(3);
      check(store.messages[1003]).isNotNull();
      checkPollingContinues(async, lastEventId: 3);
      // Nothing more was appended.
      check(storedSnapshot()!).lastEventId.equals(2);
    }));

    test('logout while append pending', () => awaitFakeAsync((async) async {
      await prepare(async);
      final gate = Completer<void>();
      globalStore.backend.appendServerEventsGate = gate.future;

      preparePollResponse([messageEvent]);
      advancePoll(async);
      checkPollRequest(lastEventId: 2);
      updateMachine.debugAdvanceLoop();

      globalStore.clearCachedApiConnections();
      await logOutAccount(globalStore, eg.selfAccount.id);
      async.elapse(TestGlobalStore.removeAccountDuration);
      check(globalStore.perAccountSync(eg.selfAccount.id)).isNull();

      gate.complete();
      async.flushMicrotasks();
      check(updateMachine.lastEventId).equals(2);
      check(connection.takeRequests()).isEmpty();
      check(storedSnapshot()).isNull();
      check(storedEventBatches()).isEmpty();
    }));
  });

  group('UpdateMachine loads stored server data', () {
    late UpdateMachineTestGlobalStore globalStore;
    late FakeApiConnection connection;
    late PerAccountStore store;
    late UpdateMachine updateMachine;
    String? lastReportedError;
    String? lastReportedModalError;

    const queueId = 'stored-queue';
    final channel = eg.stream();

    Map<String, dynamic> rawJson(Object? object) =>
      jsonDecode(jsonEncode(object)) as Map<String, dynamic>;

    /// The JSON of an initial snapshot as stored, at last event ID 10.
    Map<String, dynamic> snapshotJson({
      List<ZulipStream>? streams,
      List<User>? realmUsers,
      int? zulipFeatureLevel,
      String? realmName,
      Uri? realmIconUrl,
    }) => rawJson(eg.initialSnapshot(queueId: queueId, lastEventId: 10,
      streams: streams, realmUsers: realmUsers,
      zulipFeatureLevel: zulipFeatureLevel,
      realmName: realmName, realmIconUrl: realmIconUrl));

    void prepare({required ExpectedLoad expectedLoad}) {
      addTearDown(testBinding.reset);
      lastReportedError = null;
      reportErrorToUserBriefly = (message, {details}) async {
        if (message == null) return;
        lastReportedError = message;
      };
      addTearDown(() => reportErrorToUserBriefly = defaultReportErrorToUserBriefly);
      lastReportedModalError = null;
      reportErrorToUserModally = (title, {message, learnMoreButtonUrl}) {
        lastReportedModalError = title;
      };
      addTearDown(() => reportErrorToUserModally = defaultReportErrorToUserModally);

      globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount]);
      globalStore.expectedLoad = expectedLoad;
      globalStore.prepareRegisterQueueResponse = (connection) =>
        connection.prepare(json: rawJson(
          eg.initialSnapshot(queueId: 'fresh-queue', lastEventId: 1)));
      connection = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
    }

    void seed({
      Map<String, dynamic>? snapshot,
      List<List<Event>> eventBatches = const [],
      int? lastEventId,
      String? appVersion,
      int? timestamp,
      bool eventLogTruncated = false,
    }) {
      globalStore.backend.seedServerData(eg.selfAccount.id,
        snapshotJson: snapshot ?? snapshotJson(),
        eventBatches: [for (final batch in eventBatches) batch.map(rawJson).toList()],
        lastEventId: lastEventId,
        appVersion: appVersion,
        timestamp: timestamp,
        eventLogTruncated: eventLogTruncated);
    }

    void seedRaw(List<List<Map<String, dynamic>>> eventBatches) {
      globalStore.backend.seedServerData(eg.selfAccount.id,
        snapshotJson: snapshotJson(), eventBatches: eventBatches);
    }

    Future<void> load() async {
      store = await globalStore.perAccount(eg.selfAccount.id);
      updateMachine = store.updateMachine!;
    }

    Condition<Object?> isResumedPollRequest({required int lastEventId}) {
      return (it) => it.isA<http.Request>()
        ..method.equals('GET')
        ..url.path.equals('/api/v1/events')
        ..url.queryParameters.deepEquals({
          'queue_id': queueId,
          'last_event_id': lastEventId.toString(),
          'dont_block': 'true',
        });
    }

    Condition<Object?> isEmojiDataRequest() {
      return (it) => it.isA<http.Request>()
        ..method.equals('GET')
        ..url.equals(eg.initialSnapshot().serverEmojiDataUrl);
    }

    Condition<Object?> isRegisterRequest() {
      return (it) => it.isA<http.Request>()
        ..method.equals('POST')
        ..url.path.equals('/api/v1/register');
    }

    UserSettingsUpdateEvent settingsEvent(int id) => UserSettingsUpdateEvent(id: id,
      property: UserSettingName.twentyFourHourTime, value: true);

    void checkNoErrorReported() {
      check(lastReportedError).isNull();
      check(lastReportedModalError).isNull();
    }

    test('load from stored data, replaying events; no register', () => awaitFakeAsync((async) async {
      prepare(expectedLoad: ExpectedLoad.persisted);
      seed(eventBatches: [
        [ChannelCreateEvent(id: 11, streams: [channel])],
        [settingsEvent(12)],
      ]);
      await load();
      check(store)
        ..queueId.equals(queueId)
        ..isRecoveringEventStream.isTrue();
      check(store.streams[channel.streamId]).isNotNull();
      check(store.userSettings.twentyFourHourTime)
        .equals(TwentyFourHourTimeMode.twentyFourHour);
      check(updateMachine.lastEventId).equals(12);
      check(connection.takeRequests()).deepEquals([
        isResumedPollRequest(lastEventId: 12),
        isEmojiDataRequest(),
      ]);

      async.elapse(Duration.zero);
      check(store).isRecoveringEventStream.isFalse();
      check(globalStore.perAccountSync(eg.selfAccount.id)).identicalTo(store);
      checkNoErrorReported();
    }));

    test('resume at stored ack point, past last stored event', () => awaitFakeAsync((async) async {
      prepare(expectedLoad: ExpectedLoad.persisted);
      seed(eventBatches: [[settingsEvent(11)]], lastEventId: 15);
      await load();
      check(updateMachine.lastEventId).equals(15);
      check(connection.takeRequests()).first
        .which(isResumedPollRequest(lastEventId: 15));
    }));

    test('recovering until first poll succeeds; then start push devices', () => awaitFakeAsync((async) async {
      prepare(expectedLoad: ExpectedLoad.persisted);
      globalStore.prepareResumedPollResponse = (connection) =>
        connection.prepare(httpException: const SocketException('failed'));
      seed();
      await load();
      async.elapse(Duration.zero);
      check(store).isRecoveringEventStream.isTrue();
      check(globalStore.perAccountSync(eg.selfAccount.id)).identicalTo(store);
      check(store.pushKeys.latestPushKey).isNull();
      check(connection.takeRequests()).length.equals(2); // poll, emoji

      connection.prepare(json: GetEventsResult(
        events: [HeartbeatEvent(id: 11)], queueId: null).toJson());
      updateMachine.debugAdvanceLoop();
      async.flushTimers();
      check(connection.takeRequests()).single
        .which(isResumedPollRequest(lastEventId: 10));
      check(updateMachine.lastEventId).equals(11);
      check(store).isRecoveringEventStream.isFalse();
      check(store.pushKeys.latestPushKey).isNotNull();
      checkNoErrorReported();
    }));

    test('handle and store events from resumed queue', () => awaitFakeAsync((async) async {
      prepare(expectedLoad: ExpectedLoad.persisted);
      globalStore.prepareResumedPollResponse = (connection) =>
        connection.prepare(json: {
          'events': [rawJson(settingsEvent(11))], 'queue_id': queueId});
      seed();
      await load();
      async.elapse(Duration.zero);
      check(store.userSettings.twentyFourHourTime)
        .equals(TwentyFourHourTimeMode.twentyFourHour);
      check(updateMachine.lastEventId).equals(11);
      check(globalStore.backend.serverSnapshotOf(eg.selfAccount.id)!)
        .lastEventId.equals(11);
      check(globalStore.backend.serverEventBatchesOf(eg.selfAccount.id))
        .single.lastEventId.equals(11);
    }));

    /// Check that when the first poll goes as prepared by [preparePoll],
    /// the store gets quietly replaced by one from a fresh register,
    /// and the stored data along with it.
    void checkReplacedAfterPoll(void Function(FakeApiConnection) preparePoll) {
      awaitFakeAsync((async) async {
        prepare(expectedLoad: ExpectedLoad.persisted);
        globalStore.prepareResumedPollResponse = preparePoll;
        seed(eventBatches: [[settingsEvent(11)]]);
        await load();
        check(connection.takeRequests()).first
          .which(isResumedPollRequest(lastEventId: 11));

        async.elapse(Duration.zero);
        final newStore = globalStore.perAccountSync(eg.selfAccount.id)!;
        check(newStore).not((it) => it.identicalTo(store));
        check(newStore).queueId.equals('fresh-queue');
        check(newStore.connection as FakeApiConnection).isOpen.isTrue();
        check(globalStore.backend.serverSnapshotOf(eg.selfAccount.id)!)
          .queueId.equals('fresh-queue');
        check(globalStore.backend.serverEventBatchesOf(eg.selfAccount.id)).isEmpty();
        checkNoErrorReported();
      });
    }

    test('expired queue: replace quietly', () {
      checkReplacedAfterPoll((connection) => connection.prepare(
        apiException: eg.apiExceptionBadEventQueueId(queueId: queueId)));
    });

    test('resume rejected with BAD_REQUEST: replace quietly', () {
      checkReplacedAfterPoll((connection) => connection.prepare(
        httpStatus: 400, json: {'result': 'error', 'code': 'BAD_REQUEST',
          'msg': 'An event newer than 11 has already been pruned!'}));
    });

    Map<String, dynamic> restartEvent(int id, {
      required String? zulipVersion,
      required int? zulipFeatureLevel,
    }) => {
      'id': id, 'type': 'restart', 'server_generation': 1234,
      'zulip_version': ?zulipVersion,
      'zulip_merge_base': ?zulipVersion,
      'zulip_feature_level': ?zulipFeatureLevel,
    };

    void prepareCatchUpEvents(FakeApiConnection connection,
        List<Map<String, dynamic>> rawEvents) {
      connection.prepare(json: {'events': rawEvents, 'queue_id': queueId});
    }

    test('realm event on resumed queue: replace quietly', () {
      checkReplacedAfterPoll((connection) => prepareCatchUpEvents(connection, [
        rawJson(settingsEvent(12)),
        {'id': 13, 'type': 'realm', 'op': 'update',
          'property': 'name', 'value': 'New name'},
      ]));
    });

    test('restart event with new server version on resumed queue: replace quietly', () {
      checkReplacedAfterPoll((connection) => prepareCatchUpEvents(connection, [
        restartEvent(12, zulipVersion: eg.recentZulipVersion,
          zulipFeatureLevel: eg.recentZulipFeatureLevel + 1),
      ]));
    });

    test('restart event without server version on resumed queue: replace quietly', () {
      checkReplacedAfterPoll((connection) => prepareCatchUpEvents(connection, [
        restartEvent(12, zulipVersion: null, zulipFeatureLevel: null),
      ]));
    });

    test('replace after storing the events that call for it', () => awaitFakeAsync((async) async {
      prepare(expectedLoad: ExpectedLoad.persisted);
      final realmEvent = {'id': 11, 'type': 'realm', 'op': 'update',
        'property': 'name', 'value': 'New name'};
      globalStore.prepareResumedPollResponse = (connection) =>
        prepareCatchUpEvents(connection, [realmEvent]);
      globalStore.prepareRegisterQueueResponse = (connection) =>
        connection.prepare(delay: const Duration(seconds: 1), json: rawJson(
          eg.initialSnapshot(queueId: 'fresh-queue', lastEventId: 1)));
      seed();
      await load();
      async.elapse(Duration.zero);
      check(updateMachine.lastEventId).equals(11);
      check(globalStore.backend.serverSnapshotOf(eg.selfAccount.id)!)
        ..queueId.equals(queueId)
        ..lastEventId.equals(11);
      check(globalStore.backend.serverEventBatchesOf(eg.selfAccount.id))
        .single.lastEventId.equals(11);
      check(store.pushKeys.latestPushKey).isNull();
      final newConnection =
        globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
      check(newConnection.takeRequests()).single.which(isRegisterRequest());

      async.elapse(const Duration(seconds: 1));
      check(globalStore.perAccountSync(eg.selfAccount.id)).isNotNull()
        .queueId.equals('fresh-queue');
      checkNoErrorReported();
    }));

    test('restart event with same server version on resumed queue: keep store', () => awaitFakeAsync((async) async {
      prepare(expectedLoad: ExpectedLoad.persisted);
      globalStore.prepareResumedPollResponse = (connection) =>
        prepareCatchUpEvents(connection, [
          restartEvent(11, zulipVersion: eg.recentZulipVersion,
            zulipFeatureLevel: eg.recentZulipFeatureLevel),
        ]);
      seed();
      await load();
      async.elapse(Duration.zero);
      check(updateMachine.lastEventId).equals(11);
      check(globalStore.perAccountSync(eg.selfAccount.id)).identicalTo(store);
      check(store.pushKeys.latestPushKey).isNotNull();
      check(connection.takeRequests().whereType<http.Request>()
        .where((request) => request.url.path == '/api/v1/register')).isEmpty();
      checkNoErrorReported();
    }));

    test('skip typing events from resumed queue\'s catch-up', () => awaitFakeAsync((async) async {
      prepare(expectedLoad: ExpectedLoad.persisted);
      final narrow = DmNarrow.withUser(eg.otherUser.userId,
        selfUserId: eg.selfUser.userId);
      Map<String, dynamic> typingStartEvent(int id) => {
        'id': id, 'type': 'typing', 'op': 'start', 'message_type': 'direct',
        'sender': {'user_id': eg.otherUser.userId, 'email': eg.otherUser.email},
        'recipients': [eg.selfUser, eg.otherUser].map((user) =>
          {'user_id': user.userId, 'email': user.email}).toList()};
      globalStore.prepareResumedPollResponse = (connection) =>
        prepareCatchUpEvents(connection, [
          typingStartEvent(11),
          rawJson(settingsEvent(12)),
        ]);
      seed();
      await load();
      async.elapse(Duration.zero);
      check(store.typingStatus.typistIdsInNarrow(narrow)).isEmpty();
      check(store.userSettings.twentyFourHourTime)
        .equals(TwentyFourHourTimeMode.twentyFourHour);
      check(updateMachine.lastEventId).equals(12);
      check(globalStore.backend.serverSnapshotOf(eg.selfAccount.id)!)
        .lastEventId.equals(12);

      // Later typing events are current, and get handled.
      prepareCatchUpEvents(connection, [typingStartEvent(13)]);
      updateMachine.debugAdvanceLoop();
      async.elapse(Duration.zero);
      check(store.typingStatus.typistIdsInNarrow(narrow))
        .single.equals(eg.otherUser.userId);
    }));

    test('auth failure on resumed queue: reload quietly, then log out', () => awaitFakeAsync((async) async {
      prepare(expectedLoad: ExpectedLoad.persisted);
      globalStore.prepareResumedPollResponse = (connection) =>
        connection.prepare(apiException: eg.apiExceptionUnauthorized());
      globalStore.prepareRegisterQueueResponse = (connection) =>
        connection.prepare(apiException: eg.apiExceptionUnauthorized());
      seed();
      await load();
      async.elapse(Duration.zero);
      // The reload's register request failed too, and that led to this.
      check(lastReportedModalError).equals('Could not connect');
      check(lastReportedError).isNull();
      check(globalStore.takeDoRemoveAccountCalls()).single.equals(eg.selfAccount.id);

      async.elapse(TestGlobalStore.removeAccountDuration);
      check(globalStore.perAccountSync(eg.selfAccount.id)).isNull();
      check(lastReportedError).isNull();
    }));

    test('BAD_REQUEST after a first successful poll is unexpected', () => awaitFakeAsync((async) async {
      prepare(expectedLoad: ExpectedLoad.persisted);
      seed();
      await load();
      async.elapse(Duration.zero);
      check(store).isRecoveringEventStream.isFalse();

      connection.prepare(httpStatus: 400, json: {
        'result': 'error', 'code': 'BAD_REQUEST', 'msg': 'Bad request'});
      updateMachine.debugAdvanceLoop();
      async.elapse(Duration.zero);
      check(lastReportedError).isNotNull();
    }));

    /// Check that the stored data, as prepared by [seedData], gets discarded,
    /// and the store loaded from the server instead,
    /// all without bothering the user.
    void checkDiscarded(FutureOr<void> Function() seedData) {
      awaitFakeAsync((async) async {
        prepare(expectedLoad: ExpectedLoad.network);
        globalStore.prepareRegisterQueueResponse = (connection) =>
          connection.prepare(delay: const Duration(seconds: 1), json: rawJson(
            eg.initialSnapshot(queueId: 'fresh-queue', lastEventId: 1)));
        await seedData();
        final future = globalStore.perAccount(eg.selfAccount.id);
        async.elapse(Duration.zero);
        check(globalStore.backend.serverSnapshotOf(eg.selfAccount.id)).isNull();
        final networkConnection =
          globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
        check(networkConnection).isOpen.isTrue();
        check(networkConnection.takeRequests()).single.which(isRegisterRequest());

        async.elapse(const Duration(seconds: 1));
        store = await future;
        check(store).queueId.equals('fresh-queue');
        check(store.connection).identicalTo(networkConnection);
        checkNoErrorReported();
      });
    }

    test('discard data stored by other app version', () {
      checkDiscarded(() => seed(appVersion: '0.9.0+1'));
    });

    test('discard undecodable data', () {
      checkDiscarded(() async {
        await globalStore.backend.doStoreServerSnapshot(
          eg.serverSnapshot(account: eg.selfAccount),
          data: utf8.encode('{"queue_id":'));
      });
    });

    test('discard snapshot that fails to parse', () {
      checkDiscarded(() => seed(snapshot: snapshotJson()..['realm_emoji'] = 123));
    });

    test('discard snapshot without queue ID', () {
      checkDiscarded(() => globalStore.backend.seedServerData(eg.selfAccount.id,
        snapshotJson: snapshotJson()..['queue_id'] = null, queueId: queueId));
    });

    test('discard snapshot without self-user, without modal', () {
      checkDiscarded(() => seed(snapshot: snapshotJson(realmUsers: [eg.otherUser])));
    });

    test('discard snapshot with server version unlike account', () {
      checkDiscarded(() => seed(snapshot: snapshotJson(
        zulipFeatureLevel: eg.recentZulipFeatureLevel - 1)));
    });

    test('discard data with event that fails to parse', () {
      checkDiscarded(() => seedRaw([
        [{'id': 11, 'type': 'stream', 'op': 'create', 'streams': 123}],
      ]));
    });

    test('discard data with event that fails to replay', () {
      // The channel already exists, so handling the event throws (in debug).
      checkDiscarded(() => seed(snapshot: snapshotJson(streams: [channel]),
        eventBatches: [[ChannelCreateEvent(id: 11, streams: [channel])]]));
    });

    test('discard data on error reading it', () {
      checkDiscarded(() {
        seed();
        globalStore.backend.loadServerDataError = Exception('disk I/O error');
      });
    });

    test('discard data, failing to clear it; load from server', () => awaitFakeAsync((async) async {
      prepare(expectedLoad: ExpectedLoad.network);
      seed(appVersion: '0.9.0+1');
      globalStore.backend.clearServerDataError = Exception('disk I/O error');
      await load();
      check(store).queueId.equals('fresh-queue');
      checkNoErrorReported();
    }));

    test('tolerate realm name and icon unlike account; keep account\'s', () => awaitFakeAsync((async) async {
      prepare(expectedLoad: ExpectedLoad.persisted);
      seed(snapshot: snapshotJson(realmName: 'Old name',
        realmIconUrl: Uri.parse('/old-icon.png')));
      await load();
      check(store).queueId.equals(queueId);
      check(globalStore.getAccount(eg.selfAccount.id)).isNotNull()
        ..realmName.equals(eg.selfAccount.realmName)
        ..realmIcon.equals(eg.selfAccount.realmIcon);
    }));

    group('presence', () {
      Future<void> prepareWithPresence(WidgetTester tester, {
        required ExpectedLoad expectedLoad,
      }) async {
        Presence.debugEnable = true;
        addTearDown(() => Presence.debugEnable = false);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        prepare(expectedLoad: expectedLoad);
      }

      /// Dispose the store, and let pending timers finish.
      Future<void> finish(WidgetTester tester) async {
        globalStore.perAccountSync(eg.selfAccount.id)!.dispose();
        await tester.pump(const Duration(minutes: 5));
      }

      testWidgets('ping right away', (tester) async {
        await prepareWithPresence(tester, expectedLoad: ExpectedLoad.persisted);
        seed();
        await load();
        await tester.pump();
        check(connection.takeRequests()).any((it) => it.isA<http.Request>()
          ..url.path.equals('/api/v1/users/me/presence')
          ..bodyFields['ping_only'].equals('false'));
        await finish(tester);
      });

      testWidgets('no ping when replacing right away', (tester) async {
        await prepareWithPresence(tester,
          expectedLoad: ExpectedLoad.persistedReplaced);
        seed(timestamp: testBinding.utcNow()
          .subtract(const Duration(hours: 25)).millisecondsSinceEpoch ~/ 1000);
        await load();
        await tester.pump();
        check(connection.takeRequests()).isEmpty();
        await finish(tester);
      });
    });

    final now = DateTime.utc(2026, 11, 12, 10, 30);

    test('outbox local IDs start from current time', () => awaitFakeAsync(initialTime: now, (async) async {
      prepare(expectedLoad: ExpectedLoad.persisted);
      seed();
      await load();
      async.elapse(Duration.zero);

      connection.prepare(json: SendMessageResult(id: 1).toJson());
      await store.sendMessage(
        destination: DmDestination(userIds: [eg.selfUser.userId]),
        content: 'hello');
      check(store.outboxMessages.keys).single
        .equals(now.millisecondsSinceEpoch);
    }));

    test('reload never loads stored data', () => awaitFakeAsync((async) async {
      prepare(expectedLoad: ExpectedLoad.persisted);
      seed();
      await load();
      async.elapse(Duration.zero);
      check(globalStore.backend.serverSnapshotOf(eg.selfAccount.id)).isNotNull();

      // Make the event queue go bad some other way than expiring.
      updateMachine.debugPrepareLoopError(eg.nullCheckError());
      updateMachine.debugAdvanceLoop();
      async.flushTimers();
      final newStore = globalStore.perAccountSync(eg.selfAccount.id)!;
      check(newStore).queueId.equals('fresh-queue');
      check((newStore.connection as FakeApiConnection).takeRequests())
        .first.which(isRegisterRequest());
    }));

    test('logout while reading stored data', () => awaitFakeAsync((async) async {
      prepare(expectedLoad: ExpectedLoad.persisted);
      seed();
      final gate = Completer<void>();
      globalStore.backend.loadServerDataGate = gate.future;
      final future = globalStore.perAccount(eg.selfAccount.id);
      async.flushMicrotasks();

      globalStore.clearCachedApiConnections();
      await logOutAccount(globalStore, eg.selfAccount.id);
      async.elapse(TestGlobalStore.removeAccountDuration);
      gate.complete();
      await check(future).throws<AccountNotFoundException>();
      check(connection.takeRequests()).isEmpty();
    }));

    test('logout while replaying stored events', () => awaitFakeAsync((async) async {
      prepare(expectedLoad: ExpectedLoad.persisted);
      seed(eventBatches: [[ChannelCreateEvent(id: 11, streams: [channel])]]);
      // Finish reading just before the logout finishes, so that it
      // finishes while replaying.  (Timers due at the same time
      // fire in the order they were created.)
      globalStore.backend.loadServerDataGate =
        Future<void>.delayed(TestGlobalStore.removeAccountDuration);
      final future = globalStore.perAccount(eg.selfAccount.id);
      async.flushMicrotasks();

      globalStore.clearCachedApiConnections();
      unawaited(logOutAccount(globalStore, eg.selfAccount.id));
      Object? error;
      unawaited(future.then((_) {}, onError: (Object e) { error = e; }));
      async.elapse(TestGlobalStore.removeAccountDuration);
      check(error).isA<AccountNotFoundException>();
      check(connection.takeRequests()).isEmpty();
    }));

    test('stored events over size limit but not bigger than snapshot: resume', () => awaitFakeAsync((async) async {
      UpdateMachine.debugMaxStoredEventBatchesSize = 10;
      addTearDown(() => UpdateMachine.debugMaxStoredEventBatchesSize = null);
      prepare(expectedLoad: ExpectedLoad.persisted);
      seed(eventBatches: [[ChannelCreateEvent(id: 11, streams: [channel])]]);
      await load();
      check(store.streams[channel.streamId]).isNotNull();
      check(connection.takeRequests()).first
        .which(isResumedPollRequest(lastEventId: 11));
      async.elapse(Duration.zero);
      check(globalStore.perAccountSync(eg.selfAccount.id)).identicalTo(store);
      checkNoErrorReported();
    }));

    group('replace immediately', () {
      /// Check that a store gets loaded from the stored data
      /// as prepared by [seedData], and then is replaced right away
      /// by one from a fresh register,
      /// without polling the stored event queue.
      ///
      /// The [expectReplayed] says whether the store should reflect
      /// the stored events.
      void checkReplacedImmediately(void Function() seedData, {
        required bool expectReplayed,
      }) {
        awaitFakeAsync((async) async {
          prepare(expectedLoad: ExpectedLoad.persistedReplaced);
          globalStore.prepareRegisterQueueResponse = (connection) =>
            connection.prepare(delay: const Duration(seconds: 1), json: rawJson(
              eg.initialSnapshot(queueId: 'fresh-queue', lastEventId: 1)));
          seedData();
          await load();
          check(store)
            ..queueId.equals(queueId)
            ..isRecoveringEventStream.isTrue();
          expectReplayed
            ? check(store.streams[channel.streamId]).isNotNull()
            : check(store.streams[channel.streamId]).isNull();
          check(connection.takeRequests()).isEmpty();

          async.elapse(Duration.zero);
          check(connection.takeRequests()).isEmpty();
          final newConnection =
            globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
          check(newConnection.takeRequests()).single.which(isRegisterRequest());
          check(globalStore.perAccountSync(eg.selfAccount.id)).identicalTo(store);
          check(store.pushKeys.latestPushKey).isNull();

          async.elapse(const Duration(seconds: 1));
          check(globalStore.perAccountSync(eg.selfAccount.id)).isNotNull()
            .queueId.equals('fresh-queue');
          checkNoErrorReported();
        });
      }

      final channelCreateEvent = ChannelCreateEvent(id: 11, streams: [channel]);

      test('too many stored events', () {
        UpdateMachine.debugMaxStoredEventCount = 1;
        addTearDown(() => UpdateMachine.debugMaxStoredEventCount = null);
        checkReplacedImmediately(expectReplayed: false, () =>
          seed(eventBatches: [[channelCreateEvent], [settingsEvent(12)]]));
      });

      test('stored events too big', () {
        UpdateMachine.debugMaxStoredEventBatchesSize = 100;
        addTearDown(() => UpdateMachine.debugMaxStoredEventBatchesSize = null);
        final snapshotSize = utf8.encode(jsonEncode(snapshotJson())).length;
        checkReplacedImmediately(expectReplayed: false, () =>
          seed(eventBatches: [
            [channelCreateEvent],
            // Bigger than both the limit and the snapshot.
            [AlertWordsEvent(id: 12, alertWords: ['x' * snapshotSize])],
          ]));
      });

      test('stored event log truncated', () {
        // A truncated log has no batches; but if it did, they'd be skipped.
        checkReplacedImmediately(expectReplayed: false, () =>
          seed(eventBatches: [[channelCreateEvent]], lastEventId: 20,
            eventLogTruncated: true));
      });

      test('stored snapshot too old', () {
        checkReplacedImmediately(expectReplayed: true, () {
          final now = testBinding.utcNow();
          seed(eventBatches: [[channelCreateEvent]],
            timestamp: now.subtract(const Duration(hours: 25))
              .millisecondsSinceEpoch ~/ 1000);
        });
      });

      test('realm event in stored events', () {
        checkReplacedImmediately(expectReplayed: true, () => seedRaw([
          [rawJson(channelCreateEvent)],
          [{'id': 12, 'type': 'realm', 'op': 'update',
            'property': 'name', 'value': 'New name'}],
        ]));
      });

      test('restart event with new server version in stored events', () {
        checkReplacedImmediately(expectReplayed: true, () => seedRaw([
          [rawJson(channelCreateEvent)],
          [restartEvent(12, zulipVersion: eg.recentZulipVersion,
            zulipFeatureLevel: eg.recentZulipFeatureLevel + 1)],
        ]));
      });

      test('restart event without server version in stored events', () {
        checkReplacedImmediately(expectReplayed: true, () => seedRaw([
          [rawJson(channelCreateEvent)],
          [restartEvent(12, zulipVersion: null, zulipFeatureLevel: null)],
        ]));
      });
    });

    test('restart event with same server version in stored events: resume', () => awaitFakeAsync((async) async {
      prepare(expectedLoad: ExpectedLoad.persisted);
      seedRaw([
        [restartEvent(11, zulipVersion: eg.recentZulipVersion,
          zulipFeatureLevel: eg.recentZulipFeatureLevel)],
      ]);
      await load();
      check(connection.takeRequests()).first
        .which(isResumedPollRequest(lastEventId: 11));
      async.elapse(Duration.zero);
      check(globalStore.perAccountSync(eg.selfAccount.id)).identicalTo(store);
      checkNoErrorReported();
    }));

    group('bound stored event log, continuing from stored data', () {
      test('by length', () => awaitFakeAsync((async) async {
        UpdateMachine.debugMaxStoredEventCount = 3;
        addTearDown(() => UpdateMachine.debugMaxStoredEventCount = null);
        prepare(expectedLoad: ExpectedLoad.persisted);
        globalStore.prepareResumedPollResponse = (connection) =>
          prepareCatchUpEvents(connection, [rawJson(settingsEvent(13))]);
        seed(eventBatches: [[settingsEvent(11)], [settingsEvent(12)]]);
        await load();
        async.elapse(Duration.zero);
        final backend = globalStore.backend;
        check(backend.serverEventBatchesOf(eg.selfAccount.id)).length.equals(3);
        check(backend.serverSnapshotOf(eg.selfAccount.id)!)
          .eventLogTruncated.isFalse();

        connection.prepare(json: {
          'events': [rawJson(settingsEvent(14))], 'queue_id': queueId});
        updateMachine.debugAdvanceLoop();
        async.elapse(Duration.zero);
        check(backend.serverEventBatchesOf(eg.selfAccount.id)).isEmpty();
        check(backend.serverSnapshotOf(eg.selfAccount.id)!)
          ..lastEventId.equals(14)
          ..eventLogTruncated.isTrue();
      }));

      test('by size', () => awaitFakeAsync((async) async {
        final snapshotSize = utf8.encode(jsonEncode(snapshotJson())).length;
        UpdateMachine.debugMaxStoredEventBatchesSize = 2 * snapshotSize;
        addTearDown(() => UpdateMachine.debugMaxStoredEventBatchesSize = null);
        // Each of these is a bit bigger than the snapshot.
        AlertWordsEvent bigEvent(int id) =>
          AlertWordsEvent(id: id, alertWords: ['x' * snapshotSize]);
        prepare(expectedLoad: ExpectedLoad.persisted);
        globalStore.prepareResumedPollResponse = (connection) =>
          prepareCatchUpEvents(connection, [rawJson(bigEvent(12))]);
        seed(eventBatches: [[bigEvent(11)]]);
        await load();
        check(updateMachine.lastEventId).equals(11);
        async.elapse(Duration.zero);
        final backend = globalStore.backend;
        check(backend.serverEventBatchesOf(eg.selfAccount.id)).isEmpty();
        check(backend.serverSnapshotOf(eg.selfAccount.id)!)
          ..lastEventId.equals(12)
          ..eventLogTruncated.isTrue();
      }));

      test('by size, but not while smaller than snapshot', () => awaitFakeAsync((async) async {
        UpdateMachine.debugMaxStoredEventBatchesSize = 10;
        addTearDown(() => UpdateMachine.debugMaxStoredEventBatchesSize = null);
        prepare(expectedLoad: ExpectedLoad.persisted);
        globalStore.prepareResumedPollResponse = (connection) =>
          prepareCatchUpEvents(connection, [rawJson(settingsEvent(12))]);
        seed(eventBatches: [[settingsEvent(11)]]);
        await load();
        async.elapse(Duration.zero);
        check(globalStore.backend.serverEventBatchesOf(eg.selfAccount.id))
          .length.equals(2);
        check(globalStore.backend.serverSnapshotOf(eg.selfAccount.id)!)
          .eventLogTruncated.isFalse();
      }));
    });

    test('round trip: load from network, then from stored data', () => awaitFakeAsync((async) async {
      prepare(expectedLoad: ExpectedLoad.network);
      globalStore.prepareRegisterQueueResponse = (connection) =>
        connection.prepare(json: rawJson(eg.initialSnapshot(
          queueId: 'queue1', lastEventId: 1,
          realmUsers: [eg.selfUser, eg.otherUser])));
      await load();
      async.elapse(Duration.zero); // first poll gets a heartbeat
      final message = eg.dmMessage(id: 1001, from: eg.otherUser, to: [eg.selfUser]);
      connection.prepare(json: GetEventsResult(events: [
        ChannelCreateEvent(id: 3, streams: [channel]),
        MessageEvent(id: 4, message: message, localMessageId: null),
        settingsEvent(5),
      ], queueId: null).toJson());
      updateMachine.debugAdvanceLoop();
      async.elapse(Duration.zero);
      check(updateMachine.lastEventId).equals(5);
      final storeA = store;

      // Restart the app.
      globalStore = UpdateMachineTestGlobalStore(accounts: [eg.selfAccount],
        backend: globalStore.backend);
      globalStore.expectedLoad = ExpectedLoad.persisted;
      connection = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
      await load();
      check(store).queueId.equals('queue1');
      check(updateMachine.lastEventId).equals(5);
      check(connection.takeRequests()).first.isA<http.Request>()
        .url.queryParameters.deepEquals({
          'queue_id': 'queue1', 'last_event_id': '5', 'dont_block': 'true'});
      check(store.streams.keys).deepEquals(storeA.streams.keys);
      check(store.messages.keys).deepEquals(storeA.messages.keys);
      check(store.unreads.dms).deepEquals(storeA.unreads.dms);
      check(store.recentDmConversationsView.sorted)
        .deepEquals(storeA.recentDmConversationsView.sorted);
      check(store.userSettings.twentyFourHourTime)
        .equals(storeA.userSettings.twentyFourHourTime);
    }));
  });

  group('ZulipVersionData', () {
    group('fromMalformedServerResponseException', () {
      test('replace missing feature level with 0', () async {
        final connection = testBinding.globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;

        final json = eg.initialSnapshot().toJson()
          ..['zulip_version'] = '2.0.0'
          ..remove('zulip_feature_level') // malformed in current schema
          ..remove('zulip_merge_base');

        Object? error;
        connection.prepare(json: json);
        try {
          await registerQueue(connection);
        } catch (e) {
          error = e;
        }

        check(error).isNotNull().isA<MalformedServerResponseException>();
        final zulipVersionData = ZulipVersionData.fromMalformedServerResponseException(
          error as MalformedServerResponseException);
        check(zulipVersionData).isNotNull()
          ..zulipVersion.equals('2.0.0')
          ..zulipMergeBase.isNull()
          ..zulipFeatureLevel.equals(0);
      });
    });
  });
}

class LoadingTestGlobalStore extends TestGlobalStore {
  LoadingTestGlobalStore({required super.accounts});

  Map<int, List<Completer<PerAccountStore>>> completers = {};

  @override
  Future<PerAccountStore> doLoadPerAccount(int accountId, {
    required bool allowPersisted,
  }) {
    final completer = Completer<PerAccountStore>();
    (completers[accountId] ??= []).add(completer);
    return completer.future;
  }
}

void testAndroidIos(String description, FutureOr<void> Function() body) {
  test('$description (Android)', body);
  test('$description (iOS)', () async {
    final origTargetPlatform = debugDefaultTargetPlatformOverride;
    addTearDown(() => debugDefaultTargetPlatformOverride = origTargetPlatform);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await body();
  });
}
