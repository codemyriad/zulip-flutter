import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:test/scaffolding.dart';
import 'package:zulip/api/model/events.dart';
import 'package:zulip/api/model/initial_snapshot.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/model/message.dart';
import 'package:zulip/model/message_coverage.dart';
import 'package:zulip/model/message_database.dart';
import 'package:zulip/model/message_list.dart';
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
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

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
    TestGlobalStore? existingGlobal,
    List<ZulipStream> streams = const [],
    List<Subscription> subscriptions = const [],
    List<UserGroup> userGroups = const [],
    List<User>? realmUsers,
    int? realmMessageRetentionDays = -1,
    int maxMessageId = 0,
    int lastEventId = 10,
    String queueId = 'q1',
    bool allowPersisted = false,
  }) async {
    final global = existingGlobal ?? eg.globalStore();
    if (existingGlobal == null) {
      addTearDown(() async {
        await global.backend.closeMessageDb();
        global.dispose();
      });
      await global.settings.setBool(BoolGlobalSetting.messageDatabase, true);
      await global.insertAccount(eg.selfAccount.toCompanion(false));
    }
    global.useCachedApiConnections = true;
    final conn = global.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
    final snap = eg.initialSnapshot(
      queueId: queueId,
      lastEventId: lastEventId,
      maxMessageId: maxMessageId,
      realmUsers: realmUsers ?? [eg.selfUser, eg.otherUser],
      streams: streams,
      subscriptions: subscriptions,
      realmUserGroups: userGroups,
      realmMessageRetentionDays: realmMessageRetentionDays,
    );
    conn.prepare(json: snapshotToJson(snap));
    conn.prepare(
      delay: Duration.zero,
      json: {
        'result': 'success',
        'msg': '',
        'events': <Object>[],
        'queue_id': queueId,
      },
    );
    final um = await UpdateMachine.load(
      global,
      eg.selfAccount.id,
      allowPersisted: allowPersisted,
    );
    um.debugPauseLoop();
    return (global: global, um: um, conn: conn);
  }

  Future<void> seedChannelFetch(
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

  Future<void> seedDmFetch(
    PerAccountStore store,
    DmNarrow narrow,
    List<DmMessage> msgs, {
    bool foundOldest = true,
    bool foundNewest = true,
  }) async {
    final ticket = store.openFetchTicket();
    try {
      store.reconcileMessages(
        msgs,
        rawMessages: [
          for (final m in msgs) jsonDecode(jsonEncode(m)) as Map<String, dynamic>,
        ],
        ticket: ticket,
        coverageRequest: FetchCoverageRequest(
          narrow: narrow,
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

  Future<MessageListView> openView(
    FakeApiConnection conn,
    PerAccountStore store,
    Narrow narrow,
    List<Message> serverMsgs,
  ) async {
    conn.prepare(
      json: eg.newestGetMessagesResult(
        messages: serverMsgs,
        foundOldest: true,
        historyLimited: false,
      ).toJson(),
    );
    final view = MessageListView.init(
      store: store,
      narrow: narrow,
      anchor: AnchorCode.newest,
    );
    await view.fetchInitial();
    return view;
  }

  Future<void> checkChannelPurgedEverywhere(
    TestGlobalStore global,
    PerAccountStore store,
    int channelId,
  ) async {
    final db = global.backend.debugMessageDatabase!;
    final dbMsgs = await (db.select(db.storedMessages)
          ..where((m) => m.accountId.equals(eg.selfAccount.id) & m.channelId.equals(channelId)))
        .get();
    check(dbMsgs).isEmpty();
    final intervals = await (db.select(db.coverageIntervals)
          ..where((i) => i.accountId.equals(eg.selfAccount.id)))
        .get();
    check(intervals.where((i) => CoverageKeys.channelIdOf(i.narrowKey) == channelId)).isEmpty();
    check(store.messages.values.where((m) => m is StreamMessage && m.streamId == channelId)).isEmpty();
    final inMemChannelKeys = [
      for (final String k in store.debugCoverage.keys)
        if (CoverageKeys.channelIdOf(k) == channelId) k,
    ];
    check(inMemChannelKeys).isEmpty();
    final remaining = await (db.select(db.storedMessages)
          ..where((m) => m.accountId.equals(eg.selfAccount.id)))
        .get();
    final acct = await (db.select(db.messageDbAccounts)
          ..where((a) => a.accountId.equals(eg.selfAccount.id)))
        .getSingle();
    check(acct.totalBodyBytes).equals(remaining.fold<int>(0, (s, r) => s + r.bodyBytes));
  }

  group('access loss purges (events)', () {
    test('SubscriptionRemoveEvent on private channel without group access purges DB, coverage, and view', () => awaitFakeAsync((async) async {
      UpdateMachine.debugEnableFetchEmojiData = false;
      final stream = eg.stream(streamId: 10, name: 'Secret', inviteOnly: true);
      final setup = await startDbStore(
        streams: [stream],
        subscriptions: [eg.subscription(stream)],
      );
      async.elapse(Duration.zero);
      final store = setup.um.store;
      final writer = setup.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer.drainForTesting();

      final msg1 = eg.streamMessage(id: 100, stream: stream, topic: 't1', sender: eg.selfUser);
      final view = await openView(setup.conn, store, TopicNarrow(stream.streamId, eg.t('t1')), [msg1]);
      await writer.drainForTesting();
      check(view.messages).length.equals(1);

      await store.handleEvent(SubscriptionRemoveEvent(id: 11, channelIds: [stream.streamId]));
      await writer.drainForTesting();

      check(view.messages).isEmpty();
      await checkChannelPurgedEverywhere(setup.global, store, stream.streamId);
      view.dispose();
      setup.um.dispose();
    }));

    test('ChannelDeleteEvent purges DB, coverage, memory, and view', () => awaitFakeAsync((async) async {
      UpdateMachine.debugEnableFetchEmojiData = false;
      final stream = eg.stream(streamId: 10, name: 'General');
      final setup = await startDbStore(
        streams: [stream],
        subscriptions: [eg.subscription(stream)],
      );
      async.elapse(Duration.zero);
      final store = setup.um.store;
      final writer = setup.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer.drainForTesting();

      final msg1 = eg.streamMessage(id: 100, stream: stream, topic: 't1', sender: eg.selfUser);
      final view = await openView(setup.conn, store, TopicNarrow(stream.streamId, eg.t('t1')), [msg1]);
      await writer.drainForTesting();

      await store.handleEvent(ChannelDeleteEvent(id: 11, channelIds: [stream.streamId]));
      await writer.drainForTesting();

      check(view.messages).isEmpty();
      await checkChannelPurgedEverywhere(setup.global, store, stream.streamId);
      view.dispose();
      setup.um.dispose();
    }));

    test('ChannelUpdateEvent toggling history_public_to_subscribers -> false purges DB and drops coverage', () => awaitFakeAsync((async) async {
      UpdateMachine.debugEnableFetchEmojiData = false;
      final stream = eg.stream(
        streamId: 10,
        name: 'PrivateHistory',
        inviteOnly: true,
        historyPublicToSubscribers: true,
      );
      final setup = await startDbStore(
        streams: [stream],
        subscriptions: [eg.subscription(stream)],
      );
      async.elapse(Duration.zero);
      final store = setup.um.store;
      final writer = setup.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer.drainForTesting();

      final msg1 = eg.streamMessage(id: 100, stream: stream, topic: 't1', sender: eg.selfUser);
      await seedChannelFetch(store, stream, 't1', [msg1]);
      await writer.drainForTesting();

      await store.handleEvent(ChannelUpdateEvent(
        id: 11,
        streamId: stream.streamId,
        name: stream.name,
        property: ChannelPropertyName.inviteOnly,
        value: true,
        historyPublicToSubscribers: false,
      ));
      await writer.drainForTesting();

      await checkChannelPurgedEverywhere(setup.global, store, stream.streamId);
      setup.um.dispose();
    }));

    test('UserGroupRemoveMembersEvent revoking channel content access purges channel', () => awaitFakeAsync((async) async {
      UpdateMachine.debugEnableFetchEmojiData = false;
      final group = eg.userGroup(id: 50, members: [eg.selfUser.userId]);
      final stream = eg.stream(
        streamId: 10,
        name: 'GroupChannel',
        inviteOnly: true,
        canSubscribeGroup: GroupSettingValueNamed(group.id),
      );
      final setup = await startDbStore(
        streams: [stream],
        subscriptions: [],
        userGroups: [group],
      );
      async.elapse(Duration.zero);
      final store = setup.um.store;
      final writer = setup.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer.drainForTesting();

      final msg1 = eg.streamMessage(id: 100, stream: stream, topic: 't1', sender: eg.selfUser);
      await seedChannelFetch(store, stream, 't1', [msg1]);
      await writer.drainForTesting();

      await store.handleEvent(UserGroupRemoveMembersEvent(
        id: 11,
        groupId: group.id,
        userIds: [eg.selfUser.userId],
      ));
      await writer.drainForTesting();

      await checkChannelPurgedEverywhere(setup.global, store, stream.streamId);
      setup.um.dispose();
    }));

    test('RealmUserUpdateEvent changing self role to guest purges unsubscribed public channel', () => awaitFakeAsync((async) async {
      UpdateMachine.debugEnableFetchEmojiData = false;
      final stream = eg.stream(streamId: 10, name: 'Public', inviteOnly: false);
      final setup = await startDbStore(
        streams: [stream],
        subscriptions: [],
        realmUsers: [eg.selfUser, eg.otherUser],
      );
      async.elapse(Duration.zero);
      final store = setup.um.store;
      final writer = setup.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer.drainForTesting();

      final msg1 = eg.streamMessage(id: 100, stream: stream, topic: 't1', sender: eg.selfUser);
      await seedChannelFetch(store, stream, 't1', [msg1]);
      await writer.drainForTesting();

      await store.handleEvent(RealmUserUpdateEvent(
        id: 11,
        userId: eg.selfUser.userId,
        role: UserRole.guest,
      ));
      await writer.drainForTesting();

      await checkChannelPurgedEverywhere(setup.global, store, stream.streamId);
      setup.um.dispose();
    }));
  });

  group('epoch-start access & display filter', () {
    test('fresh /register epoch start purges lost channel and drops coverage on protected-history toggle', () => awaitFakeAsync((async) async {
      UpdateMachine.debugEnableFetchEmojiData = false;
      final lost = eg.stream(streamId: 10, name: 'Lost', inviteOnly: true);
      final toggled = eg.stream(
        streamId: 11,
        name: 'Toggled',
        inviteOnly: true,
        historyPublicToSubscribers: true,
      );
      final kept = eg.stream(streamId: 12, name: 'Kept', inviteOnly: false);
      final setup1 = await startDbStore(
        streams: [lost, toggled, kept],
        subscriptions: [eg.subscription(lost), eg.subscription(toggled), eg.subscription(kept)],
      );
      async.elapse(Duration.zero);
      final store1 = setup1.um.store;
      final writer1 = setup1.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer1.drainForTesting();

      await seedChannelFetch(store1, lost, 't1', [
        eg.streamMessage(id: 100, stream: lost, topic: 't1', sender: eg.selfUser),
      ]);
      await seedChannelFetch(store1, toggled, 't1', [
        eg.streamMessage(id: 101, stream: toggled, topic: 't1', sender: eg.selfUser),
      ]);
      await seedChannelFetch(store1, kept, 't1', [
        eg.streamMessage(id: 102, stream: kept, topic: 't1', sender: eg.selfUser),
      ]);
      await writer1.drainForTesting();
      setup1.um.dispose();

      // Restart with fresh snapshot where `lost` was unsubscribed (no access),
      // `toggled` became protected-history, and `kept` stayed accessible.
      final toggledNow = eg.stream(
        streamId: 11,
        name: 'Toggled',
        inviteOnly: true,
        historyPublicToSubscribers: false,
      );
      final setup2 = await startDbStore(
        existingGlobal: setup1.global,
        queueId: 'q2',
        lastEventId: 20,
        streams: [lost, toggledNow, kept],
        subscriptions: [eg.subscription(toggledNow), eg.subscription(kept)],
        allowPersisted: false,
      );
      async.elapse(Duration.zero);
      final store2 = setup2.um.store;
      final writer2 = setup2.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer2.drainForTesting();

      await checkChannelPurgedEverywhere(setup2.global, store2, lost.streamId);
      await checkChannelPurgedEverywhere(setup2.global, store2, toggled.streamId);

      final db = setup2.global.backend.debugMessageDatabase!;
      final keptRows = await (db.select(db.storedMessages)
            ..where((m) => m.accountId.equals(eg.selfAccount.id) & m.channelId.equals(kept.streamId)))
          .get();
      check(keptRows.map((r) => r.id)).deepEquals([102]);
      setup2.um.dispose();
    }));

    test('persisted restart (continue path after Stage-1 replay) purges lost channel and checks display filter', () => awaitFakeAsync((async) async {
      UpdateMachine.debugEnableFetchEmojiData = false;
      final secret = eg.stream(streamId: 10, name: 'Secret', inviteOnly: true);
      final kept = eg.stream(streamId: 12, name: 'Kept', inviteOnly: false);
      final setup1 = await startDbStore(
        streams: [secret, kept],
        subscriptions: [eg.subscription(secret), eg.subscription(kept)],
        lastEventId: 10,
      );
      async.elapse(Duration.zero);
      final store1 = setup1.um.store;
      final writer1 = setup1.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer1.drainForTesting();

      await seedChannelFetch(store1, secret, 't1', [
        eg.streamMessage(id: 100, stream: secret, topic: 't1', sender: eg.selfUser),
      ]);
      await seedChannelFetch(store1, kept, 't1', [
        eg.streamMessage(id: 101, stream: kept, topic: 't1', sender: eg.selfUser),
      ]);
      await writer1.drainForTesting();
      setup1.um.dispose();

      // Persist an older Stage-1 snapshot and replay an access-revoking event.
      final persistedSnap = eg.initialSnapshot(
        queueId: 'q1',
        lastEventId: 10,
        maxMessageId: 0,
        realmUsers: [eg.selfUser, eg.otherUser],
        streams: [secret, kept],
        subscriptions: [eg.subscription(secret), eg.subscription(kept)],
      );
      setup1.global.backend.seedServerData(
        eg.selfAccount.id,
        snapshotJson: snapshotToJson(persistedSnap),
        lastEventId: 10,
        eventBatches: [
          [
            {
              'id': 11,
              'type': 'subscription',
              'op': 'remove',
              'subscriptions': [
                {'stream_id': secret.streamId, 'name': secret.name},
              ],
            },
          ],
        ],
      );
      // Mark DB applied through event 12 so the continue branch (`appliedThroughEventId >= ackEventId`) runs.
      final db = setup1.global.backend.debugMessageDatabase!;
      await (db.update(db.messageDbAccounts)
            ..where((a) => a.accountId.equals(eg.selfAccount.id)))
          .write(const MessageDbAccountsCompanion(appliedThroughEventId: Value(12)));

      setup1.conn.prepare(
        delay: Duration.zero,
        json: {
          'result': 'success',
          'msg': '',
          'events': <Object>[],
          'queue_id': 'q1',
        },
      );
      final um2 = await UpdateMachine.load(
        setup1.global,
        eg.selfAccount.id,
        allowPersisted: true,
      );
      um2.debugPauseLoop();
      async.elapse(Duration.zero);
      final store2 = um2.store;
      final writer2 = setup1.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer2.drainForTesting();

      await checkChannelPurgedEverywhere(setup1.global, store2, secret.streamId);
      check(await store2.localWindowAsync(
        TopicNarrow(secret.streamId, eg.t('t1')),
        AnchorCode.newest,
        50,
        50,
        afterFailure: true,
      )).isNull();
      check(store2.localWindow(
        TopicNarrow(secret.streamId, eg.t('t1')),
        AnchorCode.newest,
        50,
        50,
        afterFailure: true,
      )).isNull();
      check(await store2.localWindowAsync(
        TopicNarrow(kept.streamId, eg.t('t1')),
        AnchorCode.newest,
        50,
        50,
        afterFailure: true,
      )).isNotNull();

      um2.dispose();
    }));

    test('display filter blocks localWindow even if DB/coverage state was not purged yet', () => awaitFakeAsync((async) async {
      UpdateMachine.debugEnableFetchEmojiData = false;
      final stream = eg.stream(streamId: 10, name: 'General', inviteOnly: true);
      final setup = await startDbStore(
        streams: [stream],
        subscriptions: [eg.subscription(stream)],
      );
      async.elapse(Duration.zero);
      final store = setup.um.store;
      final writer = setup.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer.drainForTesting();

      final msg1 = eg.streamMessage(id: 100, stream: stream, topic: 't1', sender: eg.selfUser);
      await seedChannelFetch(store, stream, 't1', [msg1]);
      await writer.drainForTesting();

      // Revoke subscription directly in ChannelStore without firing message purge event:
      // display filter still refuses to expose the channel locally and purges it.
      store.subscriptions.remove(stream.streamId);
      store.streams[stream.streamId] = stream;
      // Note `store.handleSubscriptionEvent` bypassed `MessageStore.handleSubscriptionRemoveEvent`.
      check(await store.localWindowAsync(
        TopicNarrow(stream.streamId, eg.t('t1')),
        AnchorCode.newest,
        50,
        50,
        afterFailure: true,
      )).isNull();
      await writer.drainForTesting();
      await checkChannelPurgedEverywhere(setup.global, store, stream.streamId);
      setup.um.dispose();
    }));
  });

  group('retention policy with coverage clipping', () {
    test('epoch start and daily sweep purge expired rows, clip families, and respect channel -1 exemption', () => awaitFakeAsync((async) async {
      UpdateMachine.debugEnableFetchEmojiData = false;
      final nowSec = testBinding.utcNow().millisecondsSinceEpoch ~/ 1000;
      const day = 86400;

      final inheritedChannel = eg.stream(streamId: 10, name: 'Inherited', messageRetentionDays: null);
      final exemptChannel = eg.stream(streamId: 11, name: 'Exempt', messageRetentionDays: -1);
      final customChannel = eg.stream(streamId: 12, name: 'CustomShort', messageRetentionDays: 2);

      // Start with unlimited retention so we can populate old & recent messages.
      final setup1 = await startDbStore(
        streams: [inheritedChannel, exemptChannel, customChannel],
        subscriptions: [
          eg.subscription(inheritedChannel),
          eg.subscription(exemptChannel),
          eg.subscription(customChannel),
        ],
        maxMessageId: 70,
        realmMessageRetentionDays: -1,
      );
      async.elapse(Duration.zero);
      final store1 = setup1.um.store;
      final writer1 = setup1.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer1.drainForTesting();

      final dmNarrow = DmNarrow.withUser(eg.otherUser.userId, selfUserId: eg.selfUser.userId);
      await seedDmFetch(store1, dmNarrow, [
        eg.dmMessage(id: 10, from: eg.selfUser, to: [eg.otherUser], timestamp: nowSec - 15 * day),
        eg.dmMessage(id: 20, from: eg.selfUser, to: [eg.otherUser], timestamp: nowSec - 3 * day),
      ]);
      await seedChannelFetch(store1, inheritedChannel, 't1', [
        eg.streamMessage(id: 30, stream: inheritedChannel, topic: 't1', sender: eg.selfUser, timestamp: nowSec - 12 * day),
        eg.streamMessage(id: 40, stream: inheritedChannel, topic: 't1', sender: eg.selfUser, timestamp: nowSec - 4 * day),
      ]);
      await seedChannelFetch(store1, exemptChannel, 't1', [
        eg.streamMessage(id: 50, stream: exemptChannel, topic: 't1', sender: eg.selfUser, timestamp: nowSec - 20 * day),
      ]);
      await seedChannelFetch(store1, customChannel, 't1', [
        eg.streamMessage(id: 60, stream: customChannel, topic: 't1', sender: eg.selfUser, timestamp: nowSec - 3 * day),
        eg.streamMessage(id: 70, stream: customChannel, topic: 't1', sender: eg.selfUser, timestamp: nowSec - 1 * day),
      ]);
      await writer1.drainForTesting();
      setup1.um.dispose();

      // Restart with realm retention = 7 days: epoch start must purge ids 10, 30, 60,
      // preserve exempt id 50, and clip DM/inherited/custom coverage at 11, 31, 61.
      final setup2 = await startDbStore(
        existingGlobal: setup1.global,
        queueId: 'q2',
        lastEventId: 20,
        maxMessageId: 70,
        streams: [inheritedChannel, exemptChannel, customChannel],
        subscriptions: [
          eg.subscription(inheritedChannel),
          eg.subscription(exemptChannel),
          eg.subscription(customChannel),
        ],
        realmMessageRetentionDays: 7,
      );
      async.elapse(Duration.zero);
      final store2 = setup2.um.store;
      final writer2 = setup2.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer2.drainForTesting();

      final db = setup2.global.backend.debugMessageDatabase!;
      final rowsAfterStart = await (db.select(db.storedMessages)
            ..where((m) => m.accountId.equals(eg.selfAccount.id))
            ..orderBy([(m) => OrderingTerm.asc(m.id)]))
          .get();
      check(rowsAfterStart.map((r) => r.id)).deepEquals([20, 40, 50, 70]);

      check(store2.debugCoverage.chains(CoverageKeys.dm(dmNarrow.allRecipientIds)).single.pieces.first.lo).equals(11);
      check(store2.debugCoverage.chains(CoverageKeys.topic(inheritedChannel.streamId, 't1')).single.pieces.single.lo).equals(31);
      check(store2.debugCoverage.chains(CoverageKeys.topic(exemptChannel.streamId, 't1')).single.pieces.single.lo).equals(0);
      check(store2.debugCoverage.chains(CoverageKeys.topic(customChannel.streamId, 't1')).single.pieces.single.lo).equals(61);

      // Open a view showing id 20 & id 40 and advance virtual time by 5 days so
      // id 40 (4+5=9d > 7d) and id 20 (3+5=8d > 7d) expire on daily sweep.
      final view = await openView(setup2.conn, store2, TopicNarrow(inheritedChannel.streamId, eg.t('t1')), [
        eg.streamMessage(id: 40, stream: inheritedChannel, topic: 't1', sender: eg.selfUser, timestamp: nowSec - 4 * day),
      ]);
      await writer2.drainForTesting();
      check(view.messages.map((m) => m.id)).deepEquals([40]);

      async.elapse(const Duration(days: 5));
      // Trigger an event after 5 days elapsed: daily retention sweep runs and drops id 40 & 20 & 70.
      await store2.handleEvent(MessageEvent(
        id: 21,
        localMessageId: null,
        message: eg.streamMessage(
          id: 80,
          stream: inheritedChannel,
          topic: 't1',
          sender: eg.selfUser,
          timestamp: nowSec + 5 * day,
        ),
      ));
      await writer2.drainForTesting();

      check(view.messages.where((m) => m.id == 40)).isEmpty();
      final rowsAfterDaily = await (db.select(db.storedMessages)
            ..where((m) => m.accountId.equals(eg.selfAccount.id))
            ..orderBy([(m) => OrderingTerm.asc(m.id)]))
          .get();
      check(rowsAfterDaily.map((r) => r.id)).deepEquals([50, 80]);
      check(store2.debugCoverage.chains(CoverageKeys.topic(inheritedChannel.streamId, 't1')).single.pieces.first.lo).equals(41);

      // Updating exemptChannel retention via ChannelUpdateEvent purges id 50 immediately.
      await store2.handleEvent(ChannelUpdateEvent(
        id: 22,
        streamId: exemptChannel.streamId,
        name: exemptChannel.name,
        property: ChannelPropertyName.messageRetentionDays,
        value: 1,
      ));
      await writer2.drainForTesting();

      final rowsAfterChannelUpdate = await (db.select(db.storedMessages)
            ..where((m) => m.accountId.equals(eg.selfAccount.id))
            ..orderBy([(m) => OrderingTerm.asc(m.id)]))
          .get();
      check(rowsAfterChannelUpdate.map((r) => r.id)).deepEquals([80]);
      check(store2.debugCoverage.chains(CoverageKeys.topic(exemptChannel.streamId, 't1')).single.pieces.single.lo).equals(51);

      final acct = await (db.select(db.messageDbAccounts)
            ..where((a) => a.accountId.equals(eg.selfAccount.id)))
          .getSingle();
      check(acct.totalBodyBytes).equals(rowsAfterChannelUpdate.single.bodyBytes);

      view.dispose();
      setup2.um.dispose();
    }));
  });
}
