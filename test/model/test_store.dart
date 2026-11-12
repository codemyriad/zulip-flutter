import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:zulip/api/model/events.dart';
import 'package:zulip/api/model/initial_snapshot.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/api/route/events.dart';
import 'package:zulip/api/route/realm.dart';
import 'package:zulip/model/binding.dart';
import 'package:zulip/model/database.dart';
import 'package:zulip/model/settings.dart';
import 'package:zulip/model/store.dart';
import 'package:zulip/notifications/receive.dart';
import 'package:zulip/widgets/store.dart';

import '../api/fake_api.dart';
import '../example_data.dart' as eg;

mixin _ApiConnectionsMixin on GlobalStore {
  final Map<
    ({Uri realmUrl, int? zulipFeatureLevel, String? email, String? apiKey}),
    FakeApiConnection
  > _apiConnections = {};

  /// Whether [apiConnection] should return a cached connection.
  ///
  /// If true, [apiConnection] will return a cached [FakeApiConnection]
  /// from a previous call, if it is still open ([FakeApiConnection.isOpen]).
  /// If there is a cached connection but it has been closed
  /// with [ApiConnection.close], that connection will be ignored in favor
  /// of returning (and saving for next time) a fresh connection after all.
  ///
  /// If false (the default), returns a fresh connection each time.
  ///
  /// Setting this to true is useful if a test needs to access the same
  /// [FakeApiConnection] that the code under test will get, so as to use
  /// [FakeApiConnection.prepare] or [FakeApiConnection.lastRequest].
  /// The behavior with `true` breaches the base method's contract slightly --
  /// the base method would return a fresh connection each time --
  /// but that breach is sometimes convenient for tests.
  bool useCachedApiConnections = false;

  void clearCachedApiConnections() {
    _apiConnections.clear();
  }

  /// Get or construct a [FakeApiConnection] with the given arguments.
  ///
  /// To access the same [FakeApiConnection] that the code under test will get,
  /// so as to use [FakeApiConnection.prepare] or [FakeApiConnection.lastRequest],
  /// see [useCachedApiConnections].
  @override
  FakeApiConnection apiConnection({
      required Uri realmUrl, required int? zulipFeatureLevel,
      String? email, String? apiKey}) {
    final key = (realmUrl: realmUrl, zulipFeatureLevel: zulipFeatureLevel,
      email: email, apiKey: apiKey);
    if (useCachedApiConnections) {
      final connection = _apiConnections[key];
      if (connection != null && connection.isOpen) {
        return connection;
      }
    }
    return (_apiConnections[key] = FakeApiConnection(
      realmUrl: realmUrl, zulipFeatureLevel: zulipFeatureLevel,
      email: email, apiKey: apiKey));
  }
}

/// A Drift database instance that knows our schema,
/// but doesn't connect to any actual database, even fake or temporary.
///
/// This is useful because it enables the use of the `mapFromCompanion`
/// methods.  See upstream discussion:
///   https://github.com/simolus3/drift/issues/3761
final _bogusDb = AppDatabase(LazyDatabase(() => throw 'used bogus DB'));

/// A [GlobalStoreBackend] for tests, which keeps data in memory.
///
/// Most data isn't kept here at all;
/// the global store has it, and the methods for it do nothing.
/// The server data, though, is kept here,
/// with the same semantics as [LiveGlobalStoreBackend] has,
/// so that it can be inspected with [serverSnapshotOf]
/// and [serverEventBatchesOf],
/// and so that the same backend can be passed to a second [TestGlobalStore]
/// or [UpdateMachineTestGlobalStore],
/// simulating a restart of the app.
///
/// The global stores using this backend keep it informed
/// of which accounts exist,
/// standing in for the foreign-key constraints on the server-data tables.
class TestGlobalStoreBackend implements GlobalStoreBackend {
  @override
  Future<void> doUpdateGlobalSettings(GlobalSettingsCompanion data) async {
    // Nothing to do.
  }

  @override
  Future<void> doSetBoolGlobalSetting(BoolGlobalSetting setting, bool? value) async {
    // Nothing to do.
  }

  @override
  Future<void> doSetIntGlobalSetting(IntGlobalSetting setting, int? value) async {
    // Nothing to do.
  }

  @override
  Future<PushKey> doInsertPushKey(PushKeysCompanion data) async {
    // TODO detect duplicate push keys here?
    return await _bogusDb.pushKeys.mapFromCompanion(data, _bogusDb);
  }

  @override
  Future<void> doUpdatePushKey(int pushKeyId, PushKeysCompanion data) async {
    // Nothing to do.
  }

  @override
  Future<void> doRemovePushKey(int pushKeyId) async {
    // Nothing to do.
  }

  final Set<int> _accountIds = {};
  final Map<int, ServerSnapshot> _serverSnapshots = {};
  final Map<int, List<ServerEventBatch>> _serverEventBatches = {};
  int _nextServerEventBatchId = 1;

  void _addAccount(int accountId) {
    _accountIds.add(accountId);
  }

  void _removeAccount(int accountId) {
    _accountIds.remove(accountId);
    _serverSnapshots.remove(accountId);
    _serverEventBatches.remove(accountId);
  }

  /// The account's stored [ServerSnapshot], if any.
  ServerSnapshot? serverSnapshotOf(int accountId) => _serverSnapshots[accountId];

  /// The account's stored [ServerEventBatch]es, in order.
  List<ServerEventBatch> serverEventBatchesOf(int accountId) =>
    List.unmodifiable(_serverEventBatches[accountId] ?? const <ServerEventBatch>[]);

  /// Store server data for the account, as if stored by an earlier run of the app.
  ///
  /// The snapshot's queue ID is [queueId] if non-null,
  /// else taken from [snapshotJson], as is its last event ID;
  /// each batch's last event ID is the ID of its last event.
  /// The stored [ServerSnapshot.lastEventId] is [lastEventId] if non-null,
  /// else that of the last batch, if any, else that of the snapshot.
  ///
  /// The [appVersion] defaults to that of the default [eg.packageInfo],
  /// and [timestamp] to the current time.
  void seedServerData(int accountId, {
    required Map<String, dynamic> snapshotJson,
    List<List<Map<String, dynamic>>> eventBatches = const [],
    String? queueId,
    int? lastEventId,
    String? appVersion,
    int? timestamp,
  }) {
    queueId ??= snapshotJson['queue_id'] as String;
    final batches = [
      for (final events in eventBatches)
        ServerEventBatch(
          id: _nextServerEventBatchId++,
          accountId: accountId,
          queueId: queueId,
          lastEventId: events.last['id'] as int,
          data: utf8.encode(jsonEncode(events))),
    ];
    final packageInfo = eg.packageInfo();
    _serverSnapshots[accountId] = ServerSnapshot(
      accountId: accountId,
      queueId: queueId,
      lastEventId: lastEventId
        ?? batches.lastOrNull?.lastEventId
        ?? snapshotJson['last_event_id'] as int,
      appVersion: appVersion
        ?? '${packageInfo.version}+${packageInfo.buildNumber}',
      timestamp: timestamp
        ?? ZulipBinding.instance.utcNow().millisecondsSinceEpoch ~/ 1000,
      data: utf8.encode(jsonEncode(snapshotJson)));
    _serverEventBatches[accountId] = batches;
  }

  /// If non-null, the next call to [doStoreServerSnapshot] throws this
  /// and resets it to null.
  Object? storeServerSnapshotError;

  /// If non-null, the next call to [doAppendServerEvents] throws this
  /// and resets it to null.
  Object? appendServerEventsError;

  /// If non-null, each call to [doAppendServerEvents] first waits for this.
  Future<void>? appendServerEventsGate;

  /// If non-null, the next call to [doLoadServerSnapshotInfo] throws this
  /// and resets it to null.
  Object? loadServerSnapshotInfoError;

  /// If non-null, the next call to [doLoadServerData] throws this
  /// and resets it to null.
  Object? loadServerDataError;

  /// If non-null, each call to [doLoadServerData] first waits for this.
  Future<void>? loadServerDataGate;

  @override
  Future<bool> doStoreServerSnapshot(ServerSnapshot snapshot) async {
    if (storeServerSnapshotError case final error?) {
      storeServerSnapshotError = null;
      throw error;
    }
    if (!_accountIds.contains(snapshot.accountId)) return false;
    _serverEventBatches.remove(snapshot.accountId);
    _serverSnapshots[snapshot.accountId] = snapshot;
    return true;
  }

  @override
  Future<bool> doAppendServerEvents(int accountId, {
    required String queueId,
    required int lastEventId,
    required Uint8List? data,
  }) async {
    if (appendServerEventsGate case final gate?) {
      await gate;
    }
    if (appendServerEventsError case final error?) {
      appendServerEventsError = null;
      throw error;
    }
    final snapshot = _serverSnapshots[accountId];
    if (snapshot == null || snapshot.queueId != queueId) return false;
    _serverSnapshots[accountId] = snapshot.copyWith(lastEventId: lastEventId);
    if (data != null) {
      (_serverEventBatches[accountId] ??= []).add(ServerEventBatch(
        id: _nextServerEventBatchId++,
        accountId: accountId,
        queueId: queueId,
        lastEventId: lastEventId,
        data: data));
    }
    return true;
  }

  Iterable<ServerEventBatch> _serverEventBatchesOnQueue(ServerSnapshot snapshot) {
    return (_serverEventBatches[snapshot.accountId] ?? [])
      .where((batch) => batch.queueId == snapshot.queueId);
  }

  @override
  Future<ServerSnapshotInfo?> doLoadServerSnapshotInfo(int accountId) async {
    if (loadServerSnapshotInfoError case final error?) {
      loadServerSnapshotInfoError = null;
      throw error;
    }
    final snapshot = _serverSnapshots[accountId];
    if (snapshot == null) return null;
    return (
      queueId: snapshot.queueId,
      lastEventId: snapshot.lastEventId,
      appVersion: snapshot.appVersion,
      timestamp: snapshot.timestamp,
      snapshotSize: snapshot.data.length,
      eventBatchesSize: _serverEventBatchesOnQueue(snapshot)
        .fold(0, (sum, batch) => sum + batch.data.length),
    );
  }

  @override
  Future<ServerData?> doLoadServerData(int accountId, {
    bool includeEventBatches = true,
  }) async {
    if (loadServerDataGate case final gate?) {
      await gate;
    }
    if (loadServerDataError case final error?) {
      loadServerDataError = null;
      throw error;
    }
    final snapshot = _serverSnapshots[accountId];
    if (snapshot == null) return null;
    return (
      snapshot: snapshot,
      eventBatches: includeEventBatches
        ? _serverEventBatchesOnQueue(snapshot).toList()
        : <ServerEventBatch>[],
    );
  }

  @override
  Future<void> doClearServerData(int accountId) async {
    _serverSnapshots.remove(accountId);
    _serverEventBatches.remove(accountId);
  }
}

mixin _DatabaseMixin on GlobalStore {
  TestGlobalStoreBackend get backend;

  int _nextAccountId = 1;

  @override
  Future<Account> doInsertAccount(AccountsCompanion data) async {
    // Check for duplication is typically handled by the database but since
    // we're not using a real database, this needs to be handled here.
    // See [AppDatabase.createAccount].
    // TODO: Ensure that parallel account insertions do not bypass this check.
    if (accounts.any((account) =>
          data.realmUrl.value == account.realmUrl
          && (data.userId.value == account.userId
              || data.email.value == account.email))) {
      throw AccountAlreadyExistsException();
    }

    if (!data.id.present) {
      data = data.copyWith(id: Value(_nextAccountId++));
    }

    final account = await _bogusDb.accounts.mapFromCompanion(data, _bogusDb);
    backend._addAccount(account.id);
    return account;
  }

  @override
  Future<void> doUpdateAccount(int accountId, AccountsCompanion data) async {
    // Nothing to do.
  }

  /// Consume the log of calls made to [doRemoveAccount].
  List<int> takeDoRemoveAccountCalls() {
    final result = _doRemoveAccountCalls;
    _doRemoveAccountCalls = null;
    return result ?? [];
  }
  List<int>? _doRemoveAccountCalls;

  @override
  Future<void> doRemoveAccount(int accountId) async {
    (_doRemoveAccountCalls ??= []).add(accountId);
    await Future<void>.delayed(TestGlobalStore.removeAccountDuration);
    backend._removeAccount(accountId);
  }
}

/// A [GlobalStore] containing data provided by callers,
/// and that causes no database queries or network requests.
///
/// Tests can provide data to the store by calling [add]
/// or [addInitialSnapshot].
///
/// The per-account stores will use [FakeApiConnection].
///
/// Unlike with [LiveGlobalStore] and the associated [UpdateMachine.load],
/// there is no automatic event-polling loop or other automated requests.
/// Tests can use [PerAccountStore.updateMachine] in order to invoke that logic
/// explicitly when desired.
///
/// See also:
///   * [TestZulipBinding.globalStore], which provides one of these.
///   * [UpdateMachineTestGlobalStore], which prepares per-account data
///     using [UpdateMachine.load] (like [LiveGlobalStore] does).
class TestGlobalStore extends GlobalStore with _ApiConnectionsMixin, _DatabaseMixin {
  TestGlobalStore({
    TestGlobalStoreBackend? backend,
    GlobalSettingsData? globalSettings,
    Map<BoolGlobalSetting, bool>? boolGlobalSettings,
    Map<IntGlobalSetting, int>? intGlobalSettings,
    required super.accounts,
    Iterable<PushKey>? pushKeys,
  }) : backend = backend ??= TestGlobalStoreBackend(),
       super(backend: backend,
         globalSettings: globalSettings ?? GlobalSettingsData(),
         boolGlobalSettings: boolGlobalSettings ?? {},
         intGlobalSettings: intGlobalSettings ?? {},
         pushKeys: pushKeys ?? [],
       ) {
    accountIds.forEach(this.backend._addAccount);
  }

  /// The backend of this store.
  ///
  /// To simulate a restart of the app, pass this as the `backend`
  /// of a new global store.
  @override
  final TestGlobalStoreBackend backend;

  final Map<int, InitialSnapshot> _initialSnapshots = {};

  static const Duration removeAccountDuration = Duration(milliseconds: 1);

  /// Add an account and corresponding server data to the test data.
  ///
  /// The given account will be added to the store.
  /// The given initial snapshot will be used to initialize a corresponding
  /// [PerAccountStore] when [perAccount] is subsequently called for this
  /// account, in particular when a [PerAccountStoreWidget] is mounted.
  ///
  /// The account's [Account.zulipFeatureLevel] will be updated to match
  /// that of the initial snapshot.
  ///
  /// By default, [setLastVisitedAccount] is called for the account.
  /// Pass false for [markLastVisited] to skip that.
  ///
  /// See also:
  ///  * [addInitialSnapshot]
  Future<void> add(
    Account account,
    InitialSnapshot initialSnapshot, {
    bool markLastVisited = true,
  }) async {
    assert(initialSnapshot.zulipVersion == account.zulipVersion);
    assert(initialSnapshot.zulipMergeBase == account.zulipMergeBase);
    if (initialSnapshot.zulipFeatureLevel != account.zulipFeatureLevel) {
      account = account.copyWith(zulipFeatureLevel: initialSnapshot.zulipFeatureLevel);
    }
    await insertAccount(account.toCompanion(false));
    assert(!_initialSnapshots.containsKey(account.id));
    _initialSnapshots[account.id] = initialSnapshot;

    if (markLastVisited) {
      await setLastVisitedAccount(account.id);
    }
  }

  /// Add server data to the test data, for an account already present.
  ///
  /// The given initial snapshot will be used to initialize a corresponding
  /// [PerAccountStore] when [perAccount] is subsequently called for this
  /// account, in particular when a [PerAccountStoreWidget] is mounted.
  ///
  /// See also:
  ///  * [add], for adding the account as well as the server data.
  void addInitialSnapshot(int accountId, InitialSnapshot initialSnapshot) {
    assert(accountIds.contains(accountId));
    assert(!_initialSnapshots.containsKey(accountId));
    _initialSnapshots[accountId] = initialSnapshot;
  }

  Duration? loadPerAccountDuration;
  Object? loadPerAccountException;

  @override
  Future<PerAccountStore> doLoadPerAccount(int accountId) async {
    if (loadPerAccountDuration != null) {
      await Future<void>.delayed(loadPerAccountDuration!);
    }
    if (loadPerAccountException != null) {
      throw loadPerAccountException!;
    }
    final initialSnapshot = _initialSnapshots[accountId]!;
    final store = PerAccountStore.fromInitialSnapshot(
      globalStore: this,
      accountId: accountId,
      initialSnapshot: initialSnapshot,
    );
    UpdateMachine.fromInitialSnapshot(
      store: store, initialSnapshot: initialSnapshot);
    return Future.value(store);
  }
}

/// A [GlobalStore] that causes no database queries,
/// and loads per-account data from API responses prepared by callers.
///
/// The per-account stores will use [FakeApiConnection].
///
/// Like [LiveGlobalStore] and unlike [TestGlobalStore],
/// account data is loaded via [UpdateMachine.load].
/// Callers can set [prepareRegisterQueueResponse]
/// to prepare a register-queue payload or an exception.
/// The implementation pauses the event-polling loop
/// to avoid being a nuisance and does a boring
/// [FakeApiConnection.prepare] for the register-token request.
///
/// See also:
///   * [TestGlobalStore], which prepares per-account data
///     without using [UpdateMachine.load].
class UpdateMachineTestGlobalStore extends GlobalStore with _ApiConnectionsMixin, _DatabaseMixin {
  UpdateMachineTestGlobalStore({
    TestGlobalStoreBackend? backend,
    GlobalSettingsData? globalSettings,
    Map<BoolGlobalSetting, bool>? boolGlobalSettings,
    Map<IntGlobalSetting, int>? intGlobalSettings,
    required super.accounts,
    Iterable<PushKey>? pushKeys,
  }) : backend = backend ??= TestGlobalStoreBackend(),
       super(backend: backend,
         globalSettings: globalSettings ?? GlobalSettingsData(),
         boolGlobalSettings: boolGlobalSettings ?? {},
         intGlobalSettings: intGlobalSettings ?? {},
         pushKeys: pushKeys ?? [],
       ) {
    accountIds.forEach(this.backend._addAccount);
  }

  /// The backend of this store.
  ///
  /// To simulate a restart of the app, pass this as the `backend`
  /// of a new global store.
  @override
  final TestGlobalStoreBackend backend;

  // [doLoadPerAccount] depends on the cache to prepare the API responses.
  // Calling [clearCachedApiConnections] is permitted, though.
  @override bool get useCachedApiConnections => true;
  @override set useCachedApiConnections(bool value) =>
    throw UnsupportedError(
      'Setting UpdateMachineTestGlobalStore.useCachedApiConnections '
      'is not supported.');

  void Function(FakeApiConnection)? prepareRegisterQueueResponse;

  void _prepareRegisterQueueSuccess(FakeApiConnection connection) {
    connection.prepare(json: eg.initialSnapshot().toJson());
  }

  @override
  Future<PerAccountStore> doLoadPerAccount(int accountId) async {
    final account = getAccount(accountId);

    // UpdateMachine.load should pick up the connection
    // with the network-request responses that we've prepared.
    assert(useCachedApiConnections);

    final connection = apiConnectionFromAccount(account!) as FakeApiConnection;
    (prepareRegisterQueueResponse ?? _prepareRegisterQueueSuccess)(connection);
    connection
      ..prepare(json: GetEventsResult(events: [HeartbeatEvent(id: 2)], queueId: null).toJson())
      ..prepare(json: ServerEmojiData(codeToNames: {}).toJson());
    if (NotificationService.instance.token.value != null) {
      connection.prepare(json: {}); // register-token
    }
    final updateMachine = await UpdateMachine.load(this, accountId);
    updateMachine.debugPauseLoop();
    return updateMachine.store;
  }
}

extension PerAccountStoreTestExtension on PerAccountStore {
  Future<void> addUser(User user) async {
    await handleEvent(RealmUserAddEvent(id: 1, person: user));
  }

  Future<void> addUsers(Iterable<User> users) async {
    for (final user in users) {
      await addUser(user);
    }
  }

  Future<void> addUserGroup(UserGroup userGroup) async {
    await handleEvent(UserGroupAddEvent(id: 1, group: userGroup));
  }

  Future<void> addUserGroups(Iterable<UserGroup> userGroups) async {
    for (final userGroup in userGroups) {
      await addUserGroup(userGroup);
    }
  }

  Future<void> setMutedUsers(List<int> userIds) async {
    await handleEvent(eg.mutedUsersEvent(userIds));
  }

  Future<void> changeUserStatus(int userId, UserStatusChange change) async {
    await handleEvent(UserStatusEvent(id: 1, userId: userId, change: change));
  }

  Future<void> changeUserStatuses(Map<int, UserStatusChange> changes) async {
    for (final MapEntry(key: userId, value: change) in changes.entries) {
      await changeUserStatus(userId, change);
    }
  }

  Future<void> addStream(ZulipStream stream) async {
    await addStreams([stream]);
  }

  Future<void> addStreams(List<ZulipStream> streams) async {
    await handleEvent(ChannelCreateEvent(id: 1, streams: streams));
  }

  Future<void> updateChannel(
    int channelId,
    ChannelPropertyName property,
    Object? value,
  ) async {
    await handleEvent(ChannelUpdateEvent(
      id: 1,
      streamId: channelId,
      name: 'some channel name', // (not true, of course, but that's fine)
      property: property,
      value: value));
  }

  Future<void> addSubscription(Subscription subscription) async {
    await addSubscriptions([subscription]);
  }

  Future<void> addSubscriptions(List<Subscription> subscriptions) async {
    await handleEvent(SubscriptionAddEvent(id: 1, subscriptions: subscriptions));
  }

  Future<void> removeSubscription(int channelId) async {
    await removeSubscriptions([channelId]);
  }

  Future<void> removeSubscriptions(List<int> channelIds) async {
    await handleEvent(SubscriptionRemoveEvent(id: 1, channelIds: channelIds));
  }

  Future<void> updateSubscription(
    int channelId,
    SubscriptionProperty property,
    Object? value,
  ) async {
    await handleEvent(SubscriptionUpdateEvent(
      id: 1,
      channelId: channelId,
      property: property,
      value: value));
  }

  Future<void> addChannelFolder(ChannelFolder channelFolder) async {
    await handleEvent(ChannelFolderAddEvent(id: 1, channelFolder: channelFolder));
  }

  Future<void> addChannelFolders(Iterable<ChannelFolder> channelFolders) async {
    for (final channelFolder in channelFolders) {
      await addChannelFolder(channelFolder);
    }
  }

  Future<void> setUserTopic(ZulipStream stream, String topic, UserTopicVisibilityPolicy visibilityPolicy) async {
    await handleEvent(eg.userTopicEvent(stream.streamId, topic, visibilityPolicy));
  }

  Future<void> addMessage(Message message) async {
    await handleEvent(eg.messageEvent(message));
  }

  Future<void> addMessages(Iterable<Message> messages) async {
    for (final message in messages) {
      await addMessage(message);
    }
  }
}
