import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:checks/checks.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:fake_async/fake_async.dart';
import 'package:test/scaffolding.dart';
import 'package:zulip/api/model/events.dart';
import 'package:zulip/api/model/initial_snapshot.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/api/route/messages.dart';
import 'package:zulip/model/message.dart';
import 'package:zulip/model/message_coverage.dart';
import 'package:zulip/model/message_database.dart';
import 'package:zulip/model/message_db_effects.dart';
import 'package:zulip/model/message_effect.dart';
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

class _TruthMsg {
  _TruthMsg({
    required this.id,
    required this.isDm,
    this.streamId,
    this.topic,
    this.dmRecipientIds,
  });

  final int id;
  final bool isDm;
  int? streamId;
  String? topic;
  final List<int>? dmRecipientIds;
  bool deleted = false;

  Message toModelMessage(Map<int, ZulipStream> streams) {
    if (isDm) {
      final others = dmRecipientIds!
        .where((uid) => uid != eg.selfUser.userId)
        .map((uid) => uid == eg.otherUser.userId ? eg.otherUser : eg.thirdUser)
        .toList();
      return eg.dmMessage(
        id: id,
        from: eg.selfUser,
        to: others.isEmpty ? [eg.otherUser] : others,
      );
    }
    return eg.streamMessage(
      id: id,
      stream: streams[streamId!]!,
      topic: topic!,
    );
  }
}

class _TruthWorld {
  _TruthWorld(this.seed) : rng = Random(seed);

  final int seed;
  final Random rng;
  int nextMsgId = 1;
  int nextEventId = 1;
  final List<_TruthMsg> messages = [];
  final Map<int, ZulipStream> streams = {};
  final Set<int> subscribed = {};
  final Set<int> deletedChannels = {};

  bool hasAccess(int streamId) {
    if (deletedChannels.contains(streamId)) return false;
    final s = streams[streamId];
    if (s == null) return false;
    if (subscribed.contains(streamId)) return true;
    return !s.inviteOnly;
  }

  bool matchesNarrow(_TruthMsg m, Narrow narrow) {
    if (m.deleted) return false;
    if (!m.isDm && !hasAccess(m.streamId!)) return false;
    return switch (narrow) {
      ChannelNarrow(:final channelId) => !m.isDm && m.streamId == channelId,
      TopicNarrow(:final channelId, :final topic) =>
        !m.isDm
        && m.streamId == channelId
        && serverTopicFold(m.topic!) == serverTopicFold(topic.apiName),
      DmNarrow(:final allRecipientIds) =>
        m.isDm && _listEq(m.dmRecipientIds!, allRecipientIds),
      _ => false,
    };
  }

  static bool _listEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  GetMessagesResult computeFetch({
    required Narrow narrow,
    required Anchor anchor,
    required int numBefore,
    required int numAfter,
    required bool includeAnchor,
  }) {
    final matching = messages.where((m) => matchesNarrow(m, narrow)).toList()
      ..sort((a, b) => a.id.compareTo(b.id));

    final int anchorId = switch (anchor) {
      AnchorCode.newest => kNewestMessageId,
      AnchorCode.oldest => 0,
      AnchorCode.firstUnread => 0,
      NumericAnchor(:final messageId) => messageId,
    };

    final before = <_TruthMsg>[];
    _TruthMsg? atAnchor;
    final after = <_TruthMsg>[];
    for (final m in matching) {
      if (m.id < anchorId) {
        before.add(m);
      } else if (m.id == anchorId) {
        atAnchor = m;
      } else {
        after.add(m);
      }
    }

    final takeBefore = before.length > numBefore
      ? before.sublist(before.length - numBefore)
      : before;
    final foundOldest = takeBefore.length == before.length;

    final takeAfter = after.length > numAfter
      ? after.sublist(0, numAfter)
      : after;
    final foundNewest = takeAfter.length == after.length;

    final resultMsgs = [
      ...takeBefore,
      if (includeAnchor && atAnchor != null) atAnchor,
      ...takeAfter,
    ].map((m) => m.toModelMessage(streams)).toList();

    final resolvedAnchor = switch (anchor) {
      AnchorCode.newest => kNewestMessageId,
      AnchorCode.oldest => 0,
      AnchorCode.firstUnread => 0,
      NumericAnchor(:final messageId) => messageId,
    };

    return GetMessagesResult(
      anchor: resolvedAnchor,
      foundNewest: foundNewest,
      foundOldest: foundOldest,
      foundAnchor: atAnchor != null,
      historyLimited: false,
      messages: resultMsgs,
    );
  }
}

Future<void> _runModelSeed(int seed, {int steps = 60}) async {
  final world = _TruthWorld(seed);
  final s1 = eg.stream(streamId: 1, name: 'pub', inviteOnly: false);
  final s2 = eg.stream(streamId: 2, name: 'priv', inviteOnly: true);
  final s3 = eg.stream(streamId: 3, name: 'pub2', inviteOnly: false);
  for (final s in [s1, s2, s3]) {
    world.streams[s.streamId] = s;
  }
  world.subscribed.addAll([1, 2]);

  final store = eg.store()..debugSetCoverageEnabled(true);
  await store.addStreams([s1, s2, s3]);
  await store.addSubscriptions([eg.subscription(s1), eg.subscription(s2)]);
  final connection = store.connection as FakeApiConnection;

  final views = <MessageListView>[];
  const topics = ['alpha', 'Beta', 'ALPHA'];
  final dmNarrow = DmNarrow.withUsers([eg.otherUser.userId], selfUserId: eg.selfUser.userId);

  Narrow pickNarrow() {
    final choice = world.rng.nextInt(5);
    if (choice == 0) return dmNarrow;
    final streamId = 1 + world.rng.nextInt(3);
    if (choice == 1) return ChannelNarrow(streamId);
    return TopicNarrow(streamId, eg.t(topics[world.rng.nextInt(topics.length)]));
  }

  void verifyInvariants() {
    // 1. Live tracked intervals in current epoch never miss any accessible truth message.
    final cov = store.debugCoverage;
    for (final key in cov.keys) {
      for (final interval in cov.intervalsOf(key)) {
        if (!interval.tracked || interval.epoch != cov.epoch || !interval.isOpen) {
          continue;
        }
        for (final m in world.messages) {
          if (m.deleted) continue;
          if (m.id < interval.lo || m.id > interval.top) continue;
          final bool matchesKey;
          if (key == CoverageKeys.dms) {
            matchesKey = m.isDm;
          } else if (key.startsWith('dm:')) {
            matchesKey = m.isDm && CoverageKeys.dm(m.dmRecipientIds!) == key;
          } else if (key.startsWith('channel:')) {
            final cid = CoverageKeys.channelIdOf(key)!;
            matchesKey = !m.isDm && m.streamId == cid && world.hasAccess(cid);
          } else if (key.startsWith('topic:')) {
            final cid = CoverageKeys.channelIdOf(key)!;
            matchesKey = !m.isDm
              && m.streamId == cid
              && world.hasAccess(cid)
              && CoverageKeys.topic(cid, m.topic!) == key;
          } else {
            matchesKey = false;
          }
          if (matchesKey) {
            check(store.messages[m.id],
              because: 'seed $seed: key $key open interval $interval missing msg ${m.id}',
            ).isNotNull();
          }
        }
      }
    }

    // 2. Deleted or inaccessible messages are not stored as location-reliable.
    for (final m in world.messages) {
      final stored = store.messages[m.id];
      if (stored == null) continue;
      if (m.deleted || (!m.isDm && !world.hasAccess(m.streamId!))) {
        check(store.isLocationReliable(m.id),
          because: 'seed $seed: deleted/inaccessible msg ${m.id} still reliable',
        ).isFalse();
      }
    }

    // 3. I8 on all fetched keyed views (exempting unexpected events above a closed
    // hi on unsubscribed channels).
    for (final view in views) {
      final key = coverageKey(view.narrow);
      if (!view.fetched || key == null || view.messages.isEmpty) continue;
      final chains = cov.chains(key);
      final cid = CoverageKeys.channelIdOf(key);
      final isUnsubscribed = cid != null && !world.subscribed.contains(cid);
      final first = view.messages.first.id;
      final last = view.messages.last.id;
      check(
        chains.any((c) =>
          (c.contains(first) || (isUnsubscribed && !c.isOpen && first > c.top))
          && (c.contains(last) || (isUnsubscribed && !c.isOpen)))
        || (isUnsubscribed && chains.isEmpty && cov.evictedBelow > 0 && first >= cov.evictedBelow),
        because: 'seed $seed: I8 violated on $key [$first..$last] vs $chains',
      ).isTrue();
    }
  }

  for (int step = 0; step < steps; step++) {
    final op = world.rng.nextInt(10);
    if (op < 3) {
      // Send message event.
      final id = world.nextMsgId++;
      final isDm = world.rng.nextInt(4) == 0;
      if (isDm) {
        final msg = _TruthMsg(
          id: id,
          isDm: true,
          dmRecipientIds: dmNarrow.allRecipientIds,
        );
        world.messages.add(msg);
        await store.handleEvent(eg.messageEvent(
          msg.toModelMessage(world.streams),
        ));
      } else {
        final streamId = 1 + world.rng.nextInt(3);
        final topic = topics[world.rng.nextInt(topics.length)];
        final msg = _TruthMsg(id: id, isDm: false, streamId: streamId, topic: topic);
        world.messages.add(msg);
        if (world.hasAccess(streamId)) {
          await store.handleEvent(eg.messageEvent(
            msg.toModelMessage(world.streams),
          ));
        }
      }
    } else if (op < 6) {
      // Open & fetch a new MessageListView.
      final narrow = pickNarrow();
      final result = world.computeFetch(
        narrow: narrow,
        anchor: AnchorCode.newest,
        numBefore: 20,
        numAfter: 0,
        includeAnchor: true,
      );
      connection.prepare(json: result.toJson());
      final view = MessageListView.init(
        store: store,
        narrow: narrow,
        anchor: AnchorCode.newest,
      );
      views.add(view);
      await view.fetchInitial();
      verifyInvariants();
      if (view.messages.isEmpty) {
        views.remove(view);
        view.dispose();
      }
      continue;
    } else if (op == 6 && views.isNotEmpty) {
      // Paginate fetchOlder on a view that doesn't have oldest.
      final view = views[world.rng.nextInt(views.length)];
      if (view.fetched && !view.haveOldest && view.messages.isNotEmpty) {
        final anchorId = view.messages.first.id;
        final result = world.computeFetch(
          narrow: view.narrow,
          anchor: NumericAnchor(anchorId),
          numBefore: 10,
          numAfter: 0,
          includeAnchor: false,
        );
        connection.prepare(json: result.toJson());
        await view.fetchOlder();
      }
    } else if (op == 7) {
      // Delete a random non-deleted message.
      final live = world.messages.where((m) => !m.deleted).toList();
      if (live.isNotEmpty) {
        final target = live[world.rng.nextInt(live.length)];
        target.deleted = true;
        if (target.isDm) {
          await store.handleEvent(DeleteMessageEvent(
            id: world.nextEventId++,
            messageType: MessageType.direct,
            streamId: null,
            topic: null,
            messageIds: [target.id],
          ));
        } else if (world.hasAccess(target.streamId!)) {
          await store.handleEvent(eg.deleteMessageEvent([
            target.toModelMessage(world.streams) as StreamMessage,
          ]));
        }
      }
    } else if (op == 8) {
      // Move a stream message to another topic/channel.
      final liveStream = world.messages
        .where((m) => !m.deleted && !m.isDm && world.hasAccess(m.streamId!))
        .toList();
      if (liveStream.isNotEmpty) {
        final target = liveStream[world.rng.nextInt(liveStream.length)];
        final origStreamId = target.streamId!;
        final origTopic = target.topic!;
        final newStreamId = 1 + world.rng.nextInt(3);
        final newTopic = topics[world.rng.nextInt(topics.length)];
        if (origStreamId != newStreamId || origTopic != newTopic) {
          final origMsg = target.toModelMessage(world.streams) as StreamMessage;
          target.streamId = newStreamId;
          target.topic = newTopic;
          // Prepare fetch responses for any open views on destination that will reset.
          for (final v in views) {
            if (v.narrow case TopicNarrow(:final channelId, :final topic)) {
              final oldMatch = origStreamId == channelId
                && serverTopicFold(origTopic) == serverTopicFold(topic.apiName);
              final newMatch = newStreamId == channelId
                && serverTopicFold(newTopic) == serverTopicFold(topic.apiName);
              if (!oldMatch && newMatch) {
                connection.prepare(json: world.computeFetch(
                  narrow: v.narrow,
                  anchor: AnchorCode.newest,
                  numBefore: 20,
                  numAfter: 0,
                  includeAnchor: true,
                ).toJson());
              }
            } else if (v.narrow case ChannelNarrow(:final channelId)
                when channelId == newStreamId && origStreamId != newStreamId) {
              connection.prepare(json: world.computeFetch(
                narrow: v.narrow,
                anchor: AnchorCode.newest,
                numBefore: 20,
                numAfter: 0,
                includeAnchor: true,
              ).toJson());
            }
          }
          await store.handleEvent(eg.updateMessageEventMoveFrom(
            origMessages: [origMsg],
            newStreamId: newStreamId,
            newTopicStr: newTopic,
          ));
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }
    } else if (op == 9) {
      // Toggle subscription on channel 1 or 2.
      final cid = 1 + world.rng.nextInt(2);
      if (world.subscribed.contains(cid)) {
        world.subscribed.remove(cid);
        await store.handleEvent(SubscriptionRemoveEvent(
          id: world.nextEventId++,
          channelIds: [cid],
        ));
      } else {
        world.subscribed.add(cid);
        for (final v in views) {
          final vCid = switch (v.narrow) {
            ChannelNarrow(:final channelId) || TopicNarrow(:final channelId) => channelId,
            _ => null,
          };
          if (vCid == cid) {
            connection.prepare(json: world.computeFetch(
              narrow: v.narrow,
              anchor: AnchorCode.newest,
              numBefore: 20,
              numAfter: 0,
              includeAnchor: true,
            ).toJson());
          }
        }
        await store.addSubscription(eg.subscription(world.streams[cid]!));
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }

    verifyInvariants();
  }

  for (final v in views) {
    v.dispose();
  }
}

void main() {
  TestZulipBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  Presence.debugEnable = false;
  UpdateMachine.debugEnableFetchEmojiData = false;

  test('truth-server randomized model test (memory only, 30 seeds x 60 steps)', () async {
    for (int seed = 1; seed <= 30; seed++) {
      await _runModelSeed(seed);
    }
  });

  group('message DB lifecycle scenarios (fixed)', () {
    test('1. writer poison triggers removalOnly deletes/purges, then restart wipes and heals', () => awaitFakeAsync((async) async {
      final global = eg.globalStore();
      await global.settings.setBool(BoolGlobalSetting.messageDatabase, true);
      await global.insertAccount(eg.selfAccount.toCompanion(false));
      global.useCachedApiConnections = true;
      addTearDown(() async => global.backend.debugMessageDatabase?.close());

      final pub = eg.stream(streamId: 1, name: 'pub', inviteOnly: false);
      final priv = eg.stream(streamId: 2, name: 'priv', inviteOnly: true);

      final um1 = await _loadFreshDbStore(
        global: global,
        queueId: 'q1',
        lastEventId: 10,
        maxMessageId: 0,
        streams: [pub, priv],
        subscriptions: [eg.subscription(pub), eg.subscription(priv)],
      );
      async.elapse(Duration.zero);
      final store1 = um1.store;
      final conn1 = um1.conn;
      final writer1 = global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer1.drainForTesting();
      final db = global.backend.debugMessageDatabase!;

      final m1 = eg.streamMessage(id: 1, stream: pub, topic: 't1', sender: eg.selfUser);
      final m2 = eg.streamMessage(id: 2, stream: pub, topic: 't1', sender: eg.selfUser);
      final m3 = eg.streamMessage(id: 3, stream: priv, topic: 't1', sender: eg.selfUser);
      await store1.handleEventBatch([
        MessageEvent(id: 11, localMessageId: null, message: m1),
        MessageEvent(id: 12, localMessageId: null, message: m2),
        MessageEvent(id: 13, localMessageId: null, message: m3),
      ], lastEventId: 13);
      await writer1.drainForTesting();

      // Inject DB write failure to poison writer1.
      writer1.debugBeforeWrite = () async {
        throw StateError('injected disk write failure');
      };
      final m4 = eg.streamMessage(id: 4, stream: pub, topic: 't1', sender: eg.selfUser);
      await store1.handleEventBatch([
        MessageEvent(id: 14, localMessageId: null, message: m4),
      ], lastEventId: 14);
      await writer1.drainForTesting();

      check(writer1.isPoisoned).isTrue();
      check(store1.dbActive).isFalse();
      final acctPoisoned = await (db.select(db.messageDbAccounts)
        ..where((a) => a.accountId.equals(eg.selfAccount.id))).getSingle();
      check(acctPoisoned.appliedThroughEventId).isNull();

      // Allow removalOnly writes (deletes & access-loss purges) even while poisoned.
      writer1.debugBeforeWrite = null;
      await store1.handleEventBatch([
        DeleteMessageEvent(
          id: 15,
          messageIds: [1],
          messageType: MessageType.stream,
          streamId: pub.streamId,
          topic: eg.t('t1'),
        ),
        SubscriptionRemoveEvent(id: 16, channelIds: [priv.streamId]),
      ], lastEventId: 16);
      await writer1.drainForTesting();

      final rowsDuringPoison = await (db.select(db.storedMessages)
        ..where((m) => m.accountId.equals(eg.selfAccount.id))
        ..orderBy([(m) => OrderingTerm.asc(m.id)])).get();
      check(rowsDuringPoison.map((r) => r.id)).deepEquals([2]);

      // Restart via /register: ensureAccount sees appliedThroughEventId==null, wipes, heals.
      conn1.takeRequests();
      um1.um.dispose();
      final um2 = await _loadFreshDbStore(
        global: global,
        queueId: 'q2',
        lastEventId: 20,
        maxMessageId: 4,
        streams: [pub, priv],
        subscriptions: [eg.subscription(pub)],
      );
      async.elapse(Duration.zero);
      final store2 = um2.store;
      final writer2 = global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer2.drainForTesting();

      check(store2.dbActive).isTrue();
      check(writer2.isPoisoned).isFalse();
      final acctHealed = await (db.select(db.messageDbAccounts)
        ..where((a) => a.accountId.equals(eg.selfAccount.id))).getSingle();
      check(acctHealed.epoch).equals(1);
      check(acctHealed.appliedThroughEventId).equals(20);
      check(await (db.select(db.storedMessages)
        ..where((m) => m.accountId.equals(eg.selfAccount.id))).get()).isEmpty();
      um2.um.dispose();
    }));

    test('2. persisted continue preserves epoch, then BAD_EVENT_QUEUE_ID + offline DM delete + move reconciles cleanly', () => awaitFakeAsync((async) async {
      final global = eg.globalStore();
      await global.settings.setBool(BoolGlobalSetting.messageDatabase, true);
      await global.insertAccount(eg.selfAccount.toCompanion(false));
      global.useCachedApiConnections = true;
      addTearDown(() async => global.backend.debugMessageDatabase?.close());

      final channel = eg.stream(streamId: 10, name: 'General');
      final dmNarrow = DmNarrow.withUser(eg.otherUser.userId, selfUserId: eg.selfUser.userId);
      final nowSec = testBinding.utcNow().millisecondsSinceEpoch ~/ 1000;
      final dm1 = eg.dmMessage(id: 5, from: eg.selfUser, to: [eg.otherUser], timestamp: nowSec - 100);
      final dm2 = eg.dmMessage(id: 6, from: eg.selfUser, to: [eg.otherUser], timestamp: nowSec - 90);
      final sm1 = eg.streamMessage(id: 7, stream: channel, topic: 'alpha', sender: eg.selfUser, timestamp: nowSec - 80);

      // Seed Stage-1 server snapshot + initial DB epoch via real poll batch so continue path activates.
      final snap = eg.initialSnapshot(
        queueId: 'q1',
        lastEventId: 10,
        maxMessageId: 4,
        realmUsers: [eg.selfUser, eg.otherUser],
        streams: [channel],
        subscriptions: [eg.subscription(channel)],
        recentPrivateConversations: [
          RecentDmConversation(maxMessageId: 6, userIds: [eg.otherUser.userId]),
        ],
      );
      final um1 = await _loadFreshDbStore(
        global: global,
        customSnapshot: snap,
      );
      async.elapse(Duration.zero);
      final writer1 = global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer1.drainForTesting();

      // Deliver events through UpdateMachine.poll() so Stage-1 & message DB stay synchronized.
      um1.conn.prepare(delay: Duration.zero, json: {
        'result': 'success',
        'msg': '',
        'queue_id': 'q1',
        'events': [
          {'id': 11, 'type': 'message', 'message': jsonDecode(jsonEncode(dm1)), 'flags': <String>[]},
          {'id': 12, 'type': 'message', 'message': jsonDecode(jsonEncode(dm2)), 'flags': <String>[]},
          {'id': 13, 'type': 'message', 'message': jsonDecode(jsonEncode(sm1)), 'flags': <String>[]},
        ],
      });
      um1.um.debugAdvanceLoop();
      async.elapse(Duration.zero);
      await writer1.drainForTesting();
      async.elapse(Duration.zero);
      final db = global.backend.debugMessageDatabase!;
      final acctBefore = await (db.select(db.messageDbAccounts)
        ..where((a) => a.accountId.equals(eg.selfAccount.id))).getSingle();
      check(acctBefore.appliedThroughEventId).equals(13);
      um1.um.dispose();

      // Persisted restart (continue path in q1): epoch stays 1 and all 3 rows survive.
      final connPersisted = global.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
      connPersisted.prepare(delay: Duration.zero, json: {
        'result': 'success',
        'msg': '',
        'queue_id': 'q1',
        'events': <Object>[],
      });
      final um2 = await UpdateMachine.load(global, eg.selfAccount.id, allowPersisted: true);
      um2.debugPauseLoop();
      async.elapse(Duration.zero);
      final writer2 = global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer2.drainForTesting();
      final acctContinue = await (db.select(db.messageDbAccounts)
        ..where((a) => a.accountId.equals(eg.selfAccount.id))).getSingle();
      check(acctContinue.epoch).equals(1);
      final rowsContinue = await (db.select(db.storedMessages)
        ..where((m) => m.accountId.equals(eg.selfAccount.id))
        ..orderBy([(m) => OrderingTerm.asc(m.id)])).get();
      check(rowsContinue.map((r) => r.id)).deepEquals([5, 6, 7]);
      um2.dispose();

      // BAD_EVENT_QUEUE_ID / fresh register in q2 where dm2 (id 6) was deleted offline
      // and sm1 moved from 'alpha' -> 'beta'.
      final um3 = await _loadFreshDbStore(
        global: global,
        customSnapshot: eg.initialSnapshot(
          queueId: 'q2',
          lastEventId: 20,
          maxMessageId: 7,
          realmUsers: [eg.selfUser, eg.otherUser],
          streams: [channel],
          subscriptions: [eg.subscription(channel)],
          recentPrivateConversations: [
            RecentDmConversation(maxMessageId: 5, userIds: [eg.otherUser.userId]),
          ],
        ),
      );
      async.elapse(Duration.zero);
      final writer3 = global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer3.drainForTesting();

      final rowsAfterBump = await (db.select(db.storedMessages)
        ..where((m) => m.accountId.equals(eg.selfAccount.id))
        ..orderBy([(m) => OrderingTerm.asc(m.id)])).get();
      // C3 dropped deleted dm2 (id 6 > listedDmLatestId 5), kept dm1 (5) and sm1 (7).
      check(rowsAfterBump.map((r) => r.id)).deepEquals([5, 7]);

      // Open DM narrow offline -> falls back to stale DM row (5), then reconciles cleanly.
      um3.conn.prepare(httpException: const SocketException('offline'));
      final dmView = MessageListView.init(
        store: um3.store,
        narrow: dmNarrow,
        anchor: AnchorCode.newest,
      );
      final fetchFuture = dmView.fetchInitial();
      async.elapse(Duration.zero);
      await writer3.drainForTesting();
      async.elapse(Duration.zero);
      check(dmView.showStaleOfflineBanner).isTrue();
      check(dmView.messages.map((m) => m.id)).deepEquals([5]);

      um3.conn.prepare(json: eg.newestGetMessagesResult(foundOldest: true, messages: [dm1]).toJson());
      async.elapse(const Duration(seconds: 2));
      await fetchFuture;
      check(dmView.showStaleOfflineBanner).isFalse();
      check(dmView.messages.map((m) => m.id)).deepEquals([5]);
      dmView.dispose();
      um3.um.dispose();
    }));

    test('3. offline access loss & historyPublicToSubscribers flip purge at epoch start', () => awaitFakeAsync((async) async {
      final global = eg.globalStore();
      await global.settings.setBool(BoolGlobalSetting.messageDatabase, true);
      await global.insertAccount(eg.selfAccount.toCompanion(false));
      global.useCachedApiConnections = true;
      addTearDown(() async => global.backend.debugMessageDatabase?.close());

      final lostChannel = eg.stream(streamId: 1, name: 'Lost', inviteOnly: true, historyPublicToSubscribers: false);
      final flipChannel = eg.stream(streamId: 2, name: 'Flip', inviteOnly: false, historyPublicToSubscribers: true);
      final keptChannel = eg.stream(streamId: 3, name: 'Kept', inviteOnly: false, historyPublicToSubscribers: true);

      final um1 = await _loadFreshDbStore(
        global: global,
        queueId: 'q1',
        lastEventId: 10,
        maxMessageId: 3,
        streams: [lostChannel, flipChannel, keptChannel],
        subscriptions: [
          eg.subscription(lostChannel),
          eg.subscription(flipChannel),
          eg.subscription(keptChannel),
        ],
      );
      async.elapse(Duration.zero);
      final writer1 = global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer1.drainForTesting();

      await um1.store.handleEventBatch([
        MessageEvent(id: 11, localMessageId: null, message: eg.streamMessage(id: 11, stream: lostChannel, topic: 't1', sender: eg.selfUser)),
        MessageEvent(id: 12, localMessageId: null, message: eg.streamMessage(id: 12, stream: flipChannel, topic: 't1', sender: eg.selfUser)),
        MessageEvent(id: 13, localMessageId: null, message: eg.streamMessage(id: 13, stream: keptChannel, topic: 't1', sender: eg.selfUser)),
      ], lastEventId: 13);
      await writer1.drainForTesting();
      um1.um.dispose();

      final flippedPriv = eg.stream(streamId: 2, name: 'Flip', inviteOnly: false, historyPublicToSubscribers: false);
      final um2 = await _loadFreshDbStore(
        global: global,
        queueId: 'q2',
        lastEventId: 20,
        maxMessageId: 13,
        streams: [lostChannel, flippedPriv, keptChannel],
        subscriptions: [
          // lostChannel unsubscribed -> no content access
          eg.subscription(flippedPriv),
          eg.subscription(keptChannel),
        ],
      );
      async.elapse(Duration.zero);
      final writer2 = global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer2.drainForTesting();

      final db = global.backend.debugMessageDatabase!;
      final rows = await (db.select(db.storedMessages)
        ..where((m) => m.accountId.equals(eg.selfAccount.id))).get();
      check(rows).single.has((r) => r.streamIdOrNull, 'channelId').equals(keptChannel.streamId);
      check(um2.store.debugCoverage.chains(CoverageKeys.topic(lostChannel.streamId, 't1'))).isEmpty();
      check(um2.store.debugCoverage.chains(CoverageKeys.topic(flipChannel.streamId, 't1'))).isEmpty();
      check(um2.store.debugCoverage.chains(CoverageKeys.topic(keptChannel.streamId, 't1'))).isNotEmpty();
      um2.um.dispose();
    }));

    test('4. open-view size-cap eviction clamp (I8) and restart watermark (I12)', () => awaitFakeAsync((async) async {
      addTearDown(() => MessageStoreImpl.debugSoftByteCap = null);
      final global = eg.globalStore();
      await global.settings.setBool(BoolGlobalSetting.messageDatabase, true);
      await global.insertAccount(eg.selfAccount.toCompanion(false));
      global.useCachedApiConnections = true;
      addTearDown(() async => global.backend.debugMessageDatabase?.close());

      final channel = eg.stream(streamId: 10, name: 'Evict');
      final um1 = await _loadFreshDbStore(
        global: global,
        queueId: 'q1',
        lastEventId: 10,
        maxMessageId: 0,
        streams: [channel],
        subscriptions: [eg.subscription(channel)],
      );
      async.elapse(Duration.zero);
      final store1 = um1.store;
      final writer1 = global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer1.drainForTesting();

      final payload = '<p>${'x' * 200}</p>';
      final msgs = [
        for (int i = 1; i <= 3; i++)
          eg.streamMessage(id: i, stream: channel, topic: 't0', sender: eg.selfUser, content: payload),
        for (int i = 4; i <= 6; i++)
          eg.streamMessage(id: i, stream: channel, topic: 't1', sender: eg.selfUser, content: payload),
      ];
      await store1.handleEventBatch([
        for (var i = 0; i < msgs.length; i++)
          MessageEvent(id: 11 + i, localMessageId: null, message: msgs[i]),
      ], lastEventId: 16);
      await writer1.drainForTesting();

      um1.conn.prepare(json: eg.newestGetMessagesResult(foundOldest: true, messages: msgs.sublist(3)).toJson());
      final view = MessageListView.init(
        store: store1,
        narrow: TopicNarrow(channel.streamId, eg.t('t1')),
        anchor: AnchorCode.newest,
      );
      await view.fetchInitial();
      await writer1.drainForTesting();
      check(view.messages.map((m) => m.id)).deepEquals([4, 5, 6]);

      MessageStoreImpl.debugSoftByteCap = 400;
      await store1.handleEventBatch([
        MessageEvent(
          id: 17,
          localMessageId: null,
          message: eg.streamMessage(id: 7, stream: channel, topic: 't1', sender: eg.selfUser, content: payload),
        ),
      ], lastEventId: 17);
      await writer1.drainForTesting();
      async.elapse(Duration.zero);
      await writer1.drainForTesting();

      final evictedBelow = store1.debugCoverage.evictedBelow;
      check(evictedBelow).equals(4);
      check(view.messages).isNotEmpty();
      // I8: open view clamped below evictedBelow.
      check(view.messages.first.id).isGreaterOrEqual(evictedBelow);
      final chain = store1.debugCoverage.chains(CoverageKeys.topic(channel.streamId, 't1')).single;
      check(chain.contains(view.messages.first.id)).isTrue();
      check(chain.contains(view.messages.last.id)).isTrue();
      view.dispose();
      um1.um.dispose();

      // I12 after restart: all stored rows & coverage lo >= evictedBelowMessageId.
      final um2 = await _loadFreshDbStore(
        global: global,
        queueId: 'q2',
        lastEventId: 30,
        maxMessageId: 7,
        streams: [channel],
        subscriptions: [eg.subscription(channel)],
      );
      async.elapse(Duration.zero);
      final writer2 = global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer2.drainForTesting();
      final db = global.backend.debugMessageDatabase!;
      final acct = await (db.select(db.messageDbAccounts)
        ..where((a) => a.accountId.equals(eg.selfAccount.id))).getSingle();
      final rows2 = await (db.select(db.storedMessages)
        ..where((m) => m.accountId.equals(eg.selfAccount.id))).get();
      check(rows2.every((r) => r.id >= acct.evictedBelowMessageId)).isTrue();
      for (final key in um2.store.debugCoverage.keys) {
        for (final iv in um2.store.debugCoverage.intervalsOf(key)) {
          check(iv.lo).isGreaterOrEqual(acct.evictedBelowMessageId);
        }
      }
      um2.um.dispose();
    }));

    test('5. retention clipping + channel -1 exemption across restart and daily sweep', () => awaitFakeAsync((async) async {
      final global = eg.globalStore();
      await global.settings.setBool(BoolGlobalSetting.messageDatabase, true);
      await global.insertAccount(eg.selfAccount.toCompanion(false));
      global.useCachedApiConnections = true;
      addTearDown(() async => global.backend.debugMessageDatabase?.close());

      final nowSec = testBinding.utcNow().millisecondsSinceEpoch ~/ 1000;
      const day = 86400;
      final inherited = eg.stream(streamId: 1, name: 'Inherited', messageRetentionDays: null);
      final exempt = eg.stream(streamId: 2, name: 'Exempt', messageRetentionDays: -1);

      final um1 = await _loadFreshDbStore(
        global: global,
        queueId: 'q1',
        lastEventId: 10,
        maxMessageId: 40,
        streams: [inherited, exempt],
        subscriptions: [eg.subscription(inherited), eg.subscription(exempt)],
        realmMessageRetentionDays: -1,
      );
      async.elapse(Duration.zero);
      final writer1 = global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer1.drainForTesting();

      final msg20 = eg.streamMessage(id: 20, stream: inherited, topic: 't1', sender: eg.selfUser, timestamp: nowSec - 10 * day);
      final msg30 = eg.streamMessage(id: 30, stream: inherited, topic: 't1', sender: eg.selfUser, timestamp: nowSec - 3 * day);
      final msg40 = eg.streamMessage(id: 40, stream: exempt, topic: 't1', sender: eg.selfUser, timestamp: nowSec - 20 * day);
      await um1.store.handleEventBatch([
        MessageEvent(id: 11, localMessageId: null, message: eg.dmMessage(id: 10, from: eg.selfUser, to: [eg.otherUser], timestamp: nowSec - 10 * day)),
        MessageEvent(id: 12, localMessageId: null, message: msg20),
        MessageEvent(id: 13, localMessageId: null, message: msg30),
        MessageEvent(id: 14, localMessageId: null, message: msg40),
      ], lastEventId: 14);
      um1.conn.prepare(json: eg.newestGetMessagesResult(foundOldest: true, messages: [msg20, msg30]).toJson());
      final vInherited = MessageListView.init(
        store: um1.store,
        narrow: TopicNarrow(inherited.streamId, eg.t('t1')),
        anchor: AnchorCode.newest,
      );
      await vInherited.fetchInitial();
      vInherited.dispose();

      um1.conn.prepare(json: eg.newestGetMessagesResult(foundOldest: true, messages: [msg40]).toJson());
      final vExempt = MessageListView.init(
        store: um1.store,
        narrow: TopicNarrow(exempt.streamId, eg.t('t1')),
        anchor: AnchorCode.newest,
      );
      await vExempt.fetchInitial();
      vExempt.dispose();

      await writer1.drainForTesting();
      um1.um.dispose();

      // Restart with realmMessageRetentionDays = 7 -> epoch start purges 10 & 20, keeps 30 & exempt 40.
      final um2 = await _loadFreshDbStore(
        global: global,
        queueId: 'q2',
        lastEventId: 20,
        maxMessageId: 40,
        streams: [inherited, exempt],
        subscriptions: [eg.subscription(inherited), eg.subscription(exempt)],
        realmMessageRetentionDays: 7,
      );
      async.elapse(Duration.zero);
      final writer2 = global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer2.drainForTesting();
      final db = global.backend.debugMessageDatabase!;

      final rowsAfterRestart = await (db.select(db.storedMessages)
        ..where((m) => m.accountId.equals(eg.selfAccount.id))
        ..orderBy([(m) => OrderingTerm.asc(m.id)])).get();
      check(rowsAfterRestart.map((r) => r.id)).deepEquals([30, 40]);
      check(um2.store.debugCoverage.chains(CoverageKeys.topic(inherited.streamId, 't1')).single.pieces.single.lo).equals(21);
      check(um2.store.debugCoverage.chains(CoverageKeys.topic(exempt.streamId, 't1')).single.pieces.single.lo).equals(0);

      // Advance clock 5 days so msg 30 becomes 8 days old -> daily sweep on event purges 30, preserves 40.
      async.elapse(const Duration(days: 5));
      await um2.store.handleEventBatch([
        MessageEvent(
          id: 21,
          localMessageId: null,
          message: eg.streamMessage(id: 50, stream: inherited, topic: 't1', sender: eg.selfUser, timestamp: nowSec + 5 * day),
        ),
      ], lastEventId: 21);
      await writer2.drainForTesting();
      final rowsAfterSweep = await (db.select(db.storedMessages)
        ..where((m) => m.accountId.equals(eg.selfAccount.id))
        ..orderBy([(m) => OrderingTerm.asc(m.id)])).get();
      check(rowsAfterSweep.map((r) => r.id)).deepEquals([40, 50]);
      um2.um.dispose();
    }));

    test('6. crash between files: DB ahead continues epoch; lost DB write (appliedThrough < ack) wipes deleted row', () => awaitFakeAsync((async) async {
      final global = eg.globalStore();
      await global.settings.setBool(BoolGlobalSetting.messageDatabase, true);
      await global.insertAccount(eg.selfAccount.toCompanion(false));
      global.useCachedApiConnections = true;
      addTearDown(() async => global.backend.debugMessageDatabase?.close());

      final channel = eg.stream(streamId: 10, name: 'General');
      final nowSec = testBinding.utcNow().millisecondsSinceEpoch ~/ 1000;
      final m1 = eg.streamMessage(id: 1, stream: channel, topic: 'alpha', sender: eg.selfUser, timestamp: nowSec - 100);
      final m2 = eg.streamMessage(id: 2, stream: channel, topic: 'alpha', sender: eg.selfUser, timestamp: nowSec - 90);
      final m3 = eg.streamMessage(id: 3, stream: channel, topic: 'alpha', sender: eg.selfUser, timestamp: nowSec - 80);

      final snap = eg.initialSnapshot(
        queueId: 'q1',
        lastEventId: 10,
        maxMessageId: 0,
        realmUsers: [eg.selfUser, eg.otherUser],
        streams: [channel],
        subscriptions: [eg.subscription(channel)],
      );
      final um1 = await _loadFreshDbStore(global: global, customSnapshot: snap);
      async.elapse(Duration.zero);
      final writer1 = global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer1.drainForTesting();

      // Deliver events 11 and 12 through poll so stage-1 ack is 12.
      um1.conn.prepare(delay: Duration.zero, json: {
        'result': 'success',
        'msg': '',
        'queue_id': 'q1',
        'events': [
          {'id': 11, 'type': 'message', 'message': jsonDecode(jsonEncode(m1)), 'flags': <String>[]},
          {'id': 12, 'type': 'message', 'message': jsonDecode(jsonEncode(m2)), 'flags': <String>[]},
        ],
      });
      um1.um.debugAdvanceLoop();
      async.elapse(Duration.zero);
      await writer1.drainForTesting();
      async.elapse(Duration.zero);

      final db = global.backend.debugMessageDatabase!;
      final acct1 = await (db.select(db.messageDbAccounts)
        ..where((a) => a.accountId.equals(eg.selfAccount.id))).getSingle();
      check(acct1.appliedThroughEventId).equals(12);

      // Simulate crash between files with DB ahead of stage-1 ack (appliedThrough=13 > ack=12).
      await um1.store.handleEventBatch([
        MessageEvent(id: 13, localMessageId: null, message: m3),
      ], lastEventId: 13);
      await writer1.drainForTesting();
      um1.um.dispose();

      // Restart persisted: DB ahead continues epoch 1 and keeps all 3 rows; redelivered 13 + delete 14 commit cleanly.
      final conn2 = global.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
      conn2.prepare(delay: Duration.zero, json: {
        'result': 'success',
        'msg': '',
        'queue_id': 'q1',
        'events': <Object>[],
      });
      final um2 = await UpdateMachine.load(global, eg.selfAccount.id, allowPersisted: true);
      um2.debugPauseLoop();
      async.elapse(Duration.zero);
      final writer2 = global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer2.drainForTesting();

      check(um2.store.dbActive).isTrue();
      final acct2 = await (db.select(db.messageDbAccounts)
        ..where((a) => a.accountId.equals(eg.selfAccount.id))).getSingle();
      check(acct2.epoch).equals(1);
      final rowsAfterContinue = await (db.select(db.storedMessages)
        ..where((m) => m.accountId.equals(eg.selfAccount.id))
        ..orderBy([(m) => OrderingTerm.asc(m.id)])).get();
      check(rowsAfterContinue.map((r) => r.id)).deepEquals([1, 2, 3]);

      // Advance poll loop to deliver redelivered 13 + delete 14; check ack=14 and row 1 deleted.
      conn2.prepare(delay: Duration.zero, json: {
        'result': 'success',
        'msg': '',
        'queue_id': 'q1',
        'events': [
          {'id': 13, 'type': 'message', 'message': jsonDecode(jsonEncode(m3)), 'flags': <String>[]},
          {
            'id': 14,
            'type': 'delete_message',
            'message_ids': [1],
            'message_type': 'stream',
            'stream_id': channel.streamId,
            'topic': 'alpha',
          },
        ],
      });
      um2.debugAdvanceLoop();
      async.elapse(Duration.zero);
      await writer2.drainForTesting();
      async.elapse(Duration.zero);

      final acct2AfterPoll = await (db.select(db.messageDbAccounts)
        ..where((a) => a.accountId.equals(eg.selfAccount.id))).getSingle();
      check(acct2AfterPoll.appliedThroughEventId).equals(14);
      final rowsAfterDelete = await (db.select(db.storedMessages)
        ..where((m) => m.accountId.equals(eg.selfAccount.id))
        ..orderBy([(m) => OrderingTerm.asc(m.id)])).get();
      check(rowsAfterDelete.map((r) => r.id)).deepEquals([2, 3]);

      // Simulate crash with stage-1 ahead of DB (lost DB commit of batch 14 containing delete of m1).
      await db.transaction(() async {
        await applyMessageEffectToDb(
          db,
          accountId: eg.selfAccount.id,
          epoch: 1,
          effect: InsertEffect(message: m1, tracked: true),
          rawMessage: m1.toJson(),
        );
        await (db.update(db.messageDbAccounts)
          ..where((a) => a.accountId.equals(eg.selfAccount.id)))
          .write(const MessageDbAccountsCompanion(appliedThroughEventId: Value(12)));
      });
      um2.dispose();

      // Restart persisted: appliedThrough (12) < ack (14) wipes stale DB rows (I4: deleted m1 not resurrected).
      final conn3 = global.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
      conn3.prepare(delay: Duration.zero, json: {
        'result': 'success',
        'msg': '',
        'queue_id': 'q1',
        'events': <Object>[],
      });
      final um3 = await UpdateMachine.load(global, eg.selfAccount.id, allowPersisted: true);
      um3.debugPauseLoop();
      async.elapse(Duration.zero);
      final writer3 = global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      await writer3.drainForTesting();

      check(um3.store.dbActive).isTrue();
      final acct3 = await (db.select(db.messageDbAccounts)
        ..where((a) => a.accountId.equals(eg.selfAccount.id))).getSingle();
      check(acct3.appliedThroughEventId).equals(14);
      check(await (db.select(db.storedMessages)
        ..where((m) => m.accountId.equals(eg.selfAccount.id))).get()).isEmpty();
      check(um3.store.messages[1]).isNull();
      um3.dispose();
    }));
  });

  test('truth-server randomized model test with DB (200 seeds x 60 ops)', () {
    for (int seed = 1; seed <= 200; seed++) {
      awaitFakeAsync(
        (async) => _runDbModelSeed(async, seed, steps: 60),
        flushTimeout: const Duration(days: 365),
      );
    }
  });
}

extension on StoredMessage {
  int? get streamIdOrNull => channelId;
}

Map<String, dynamic> _snapshotToJson(InitialSnapshot snap) {
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

Future<({UpdateMachine um, PerAccountStore store, FakeApiConnection conn})>
    _loadFreshDbStore({
  required TestGlobalStore global,
  String queueId = 'q1',
  int lastEventId = 10,
  int maxMessageId = 0,
  List<ZulipStream> streams = const [],
  List<Subscription> subscriptions = const [],
  int? realmMessageRetentionDays = -1,
  InitialSnapshot? customSnapshot,
}) async {
  final conn = global.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
  final snap = customSnapshot ?? eg.initialSnapshot(
    queueId: queueId,
    lastEventId: lastEventId,
    maxMessageId: maxMessageId,
    realmUsers: [eg.selfUser, eg.otherUser],
    streams: streams,
    subscriptions: subscriptions,
    realmMessageRetentionDays: realmMessageRetentionDays,
  );
  conn.prepare(json: _snapshotToJson(snap));
  conn.prepare(
    delay: Duration.zero,
    json: {
      'result': 'success',
      'msg': '',
      'events': <Object>[],
      'queue_id': snap.queueId,
    },
  );
  final um = await UpdateMachine.load(global, eg.selfAccount.id, allowPersisted: false);
  um.debugPauseLoop();
  return (um: um, store: um.store, conn: conn);
}

class _DbTruthMsg {
  _DbTruthMsg({
    required this.id,
    required this.isDm,
    required this.timestamp,
    this.streamId,
    this.topic,
    this.dmRecipientIds,
  });

  final int id;
  final bool isDm;
  final int timestamp;
  int? streamId;
  String? topic;
  final List<int>? dmRecipientIds;
  bool deleted = false;

  Message toModelMessage(Map<int, ZulipStream> streams) {
    const content = '<p>msg payload text</p>';
    if (isDm) {
      return eg.dmMessage(
        id: id,
        from: eg.selfUser,
        to: [eg.otherUser],
        timestamp: timestamp,
        content: content,
      );
    }
    return eg.streamMessage(
      id: id,
      stream: streams[streamId!]!,
      topic: topic!,
      sender: eg.selfUser,
      timestamp: timestamp,
      content: content,
    );
  }
}

class _DbTruthWorld {
  _DbTruthWorld(this.seed, this.realmRetentionDays) : rng = Random(seed);

  final int seed;
  final Random rng;
  int? realmRetentionDays;
  int nextMsgId = 1;
  int nextEventId = 1;
  int maxKnownMsgId = 0;
  final List<_DbTruthMsg> messages = [];
  final Map<int, ZulipStream> streams = {};
  final Set<int> subscribed = {};

  bool hasAccess(int streamId) {
    final s = streams[streamId];
    if (s == null) return false;
    if (subscribed.contains(streamId)) return true;
    return !s.inviteOnly;
  }

  bool isExpired(_DbTruthMsg m, int nowSec) {
    if (m.isDm) {
      final days = realmRetentionDays;
      return days != null && days > 0 && m.timestamp < nowSec - days * 86400;
    }
    final s = streams[m.streamId!];
    if (s == null) return false;
    final int? effectiveDays;
    if (s.messageRetentionDays == -1) {
      effectiveDays = null;
    } else {
      effectiveDays = s.messageRetentionDays ?? realmRetentionDays;
    }
    return effectiveDays != null
      && effectiveDays > 0
      && m.timestamp < nowSec - effectiveDays * 86400;
  }

  bool matchesNarrow(_DbTruthMsg m, Narrow narrow, int nowSec) {
    if (m.deleted || isExpired(m, nowSec)) return false;
    if (!m.isDm && !hasAccess(m.streamId!)) return false;
    return switch (narrow) {
      ChannelNarrow(:final channelId) => !m.isDm && m.streamId == channelId,
      TopicNarrow(:final channelId, :final topic) =>
        !m.isDm
        && m.streamId == channelId
        && serverTopicFold(m.topic!) == serverTopicFold(topic.apiName),
      DmNarrow(:final allRecipientIds) =>
        m.isDm && _DbTruthWorld._listEq(m.dmRecipientIds!, allRecipientIds),
      _ => false,
    };
  }

  static bool _listEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  GetMessagesResult computeFetch({
    required Narrow narrow,
    required Anchor anchor,
    required int numBefore,
    required int numAfter,
    required bool includeAnchor,
    required int nowSec,
  }) {
    final matching = messages.where((m) => matchesNarrow(m, narrow, nowSec)).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    final int anchorId = switch (anchor) {
      AnchorCode.newest => kNewestMessageId,
      AnchorCode.oldest => 0,
      AnchorCode.firstUnread => 0,
      NumericAnchor(:final messageId) => messageId,
    };
    final before = <_DbTruthMsg>[];
    _DbTruthMsg? atAnchor;
    final after = <_DbTruthMsg>[];
    for (final m in matching) {
      if (m.id < anchorId) {
        before.add(m);
      } else if (m.id == anchorId) {
        atAnchor = m;
      } else {
        after.add(m);
      }
    }
    final takeBefore = before.length > numBefore
      ? before.sublist(before.length - numBefore)
      : before;
    final takeAfter = after.length > numAfter
      ? after.sublist(0, numAfter)
      : after;
    return GetMessagesResult(
      anchor: anchorId,
      foundNewest: takeAfter.length == after.length,
      foundOldest: takeBefore.length == before.length,
      foundAnchor: atAnchor != null,
      historyLimited: false,
      messages: [
        ...takeBefore,
        if (includeAnchor && atAnchor != null) atAnchor,
        ...takeAfter,
      ].map((m) => m.toModelMessage(streams)).toList(),
    );
  }
}

Future<void> _runDbModelSeed(FakeAsync async, int seed, {required int steps}) async {
  final world = _DbTruthWorld(seed, seed % 4 == 0 ? 3 : -1);
  final s1 = eg.stream(streamId: 1, name: 'pub', inviteOnly: false);
  final s2 = eg.stream(streamId: 2, name: 'priv', inviteOnly: true);
  final s3 = eg.stream(streamId: 3, name: 'exempt', inviteOnly: false, messageRetentionDays: -1);
  for (final s in [s1, s2, s3]) {
    world.streams[s.streamId] = s;
  }
  world.subscribed.addAll([1, 2]);

  final global = eg.globalStore();
  await global.settings.setBool(BoolGlobalSetting.messageDatabase, true);
  await global.insertAccount(eg.selfAccount.toCompanion(false));
  global.useCachedApiConnections = true;

  if (seed.isOdd) {
    MessageStoreImpl.debugSoftByteCap = 1200;
  }

  UpdateMachine? um;
  late FakeApiConnection currentConn;
  final views = <MessageListView>[];
  final viewFloorAtFetch = <MessageListView, int>{};
  const topics = ['alpha', 'Beta', 'ALPHA'];
  final dmNarrow = DmNarrow.withUsers([eg.otherUser.userId], selfUserId: eg.selfUser.userId);
  var queueSeq = 1;
  var poisonedByTest = false;
  final handledDeletedIds = <int>{};

  Future<void> startFresh() async {
    for (final v in views) {
      v.dispose();
    }
    views.clear();
    viewFloorAtFetch.clear();
    um?.dispose();
    final dmMsgs = [
      for (final m in world.messages)
        if (m.isDm && !m.deleted) m.id,
    ];
    final snap = eg.initialSnapshot(
      queueId: 'q${queueSeq++}',
      lastEventId: world.nextEventId++,
      maxMessageId: world.maxKnownMsgId,
      realmUsers: [eg.selfUser, eg.otherUser],
      streams: [s1, s2, s3],
      subscriptions: [
        for (final cid in world.subscribed) eg.subscription(world.streams[cid]!),
      ],
      realmMessageRetentionDays: world.realmRetentionDays,
      recentPrivateConversations: dmMsgs.isEmpty
        ? const []
        : [RecentDmConversation(maxMessageId: dmMsgs.reduce(max), userIds: [eg.otherUser.userId])],
    );
    final loaded = await _loadFreshDbStore(global: global, customSnapshot: snap);
    um = loaded.um;
    currentConn = loaded.conn;
    async.elapse(Duration.zero);
    final writer = global.backend.messageDbWriterForAccount(eg.selfAccount.id);
    await writer.drainForTesting();
    poisonedByTest = false;
  }

  Narrow pickNarrow() {
    final choice = world.rng.nextInt(5);
    if (choice == 0) return dmNarrow;
    final streamId = 1 + world.rng.nextInt(3);
    if (choice == 1) return ChannelNarrow(streamId);
    return TopicNarrow(streamId, eg.t(topics[world.rng.nextInt(topics.length)]));
  }

  Future<void> verifyInvariants({required bool checkDb}) async {
    final store = um!.store;
    final writer = global.backend.messageDbWriterForAccount(eg.selfAccount.id);
    final cov = store.debugCoverage;
    final nowSec = testBinding.utcNow().millisecondsSinceEpoch ~/ 1000;

    // 1a. When DB is inactive (memory-only mode), live open intervals never miss in RAM.
    if (!store.dbActive) {
      for (final key in cov.keys) {
        for (final interval in cov.intervalsOf(key)) {
          if (!interval.tracked || interval.epoch != cov.epoch || !interval.isOpen) continue;
          for (final m in world.messages) {
            if (m.deleted || world.isExpired(m, nowSec)) continue;
            if (m.id < interval.lo || m.id > interval.top || m.id < cov.evictedBelow) continue;
            final bool matchesKey;
            if (key == CoverageKeys.dms) {
              matchesKey = m.isDm;
            } else if (key.startsWith('dm:')) {
              matchesKey = m.isDm && CoverageKeys.dm(m.dmRecipientIds!) == key;
            } else if (key.startsWith('channel:')) {
              final cid = CoverageKeys.channelIdOf(key)!;
              matchesKey = !m.isDm && m.streamId == cid && world.hasAccess(cid);
            } else if (key.startsWith('topic:')) {
              final cid = CoverageKeys.channelIdOf(key)!;
              matchesKey = !m.isDm
                && m.streamId == cid
                && world.hasAccess(cid)
                && CoverageKeys.topic(cid, m.topic!) == key;
            } else {
              matchesKey = false;
            }
            if (matchesKey) {
              check(store.messages[m.id],
                because: 'seed $seed: key $key open interval $interval missing msg ${m.id}',
              ).isNotNull();
            }
          }
        }
      }
    }

    // 2. I3 / I14 in memory: deleted/inaccessible messages not reliable, no view exposes inaccessible.
    for (final m in world.messages) {
      if (store.messages[m.id] != null && (m.deleted || (!m.isDm && !world.hasAccess(m.streamId!)))) {
        check(store.isLocationReliable(m.id),
          because: 'seed $seed: deleted/inaccessible msg ${m.id} still reliable',
        ).isFalse();
      }
    }

    // 3. I8 on all fetched keyed views (accounting for network spans below pre-existing eviction cutoff).
    for (final view in views) {
      final key = coverageKey(view.narrow);
      if (!view.fetched || key == null || view.messages.isEmpty) continue;
      final chains = cov.chains(key);
      final cid = CoverageKeys.channelIdOf(key);
      final isUnsubscribed = cid != null && !world.subscribed.contains(cid);
      final first = view.messages.first.id;
      final last = view.messages.last.id;
      final floor = viewFloorAtFetch[view] ?? 0;
      check(
        cov.evictedBelow <= max(first, floor),
        because: 'seed $seed: eviction jumped past open view $key first=$first (floor=$floor, evictedBelow=${cov.evictedBelow})',
      ).isTrue();
      final effectiveFloor = max(cov.evictedBelow, floor);
      if (last >= effectiveFloor) {
        final coveredFirst = max(first, effectiveFloor);
        check(
          chains.any((c) =>
            (c.contains(coveredFirst) || (isUnsubscribed && !c.isOpen && coveredFirst > c.top))
            && (c.contains(last) || (isUnsubscribed && !c.isOpen)))
          || (isUnsubscribed && chains.isEmpty && effectiveFloor > 0 && coveredFirst >= effectiveFloor),
          because: 'seed $seed: I8 violated on $key [$first..$last] (evictedBelow=${cov.evictedBelow}, floor=$floor) vs $chains',
        ).isTrue();
      }
    }

    if (!checkDb) return;
    await writer.drainForTesting();
    async.elapse(Duration.zero);
    final db = global.backend.debugMessageDatabase;
    if (db == null) return;
    final acct = await (db.select(db.messageDbAccounts)
      ..where((a) => a.accountId.equals(eg.selfAccount.id))).getSingleOrNull();
    final dbRows = await (db.select(db.storedMessages)
      ..where((m) => m.accountId.equals(eg.selfAccount.id))).get();

    // Poisoned writer leaves dbActive == false and appliedThroughEventId == null.
    if (writer.isPoisoned || poisonedByTest) {
      check(store.dbActive, because: 'seed $seed: dbActive while poisoned').isFalse();
      if (acct != null) {
        check(acct.appliedThroughEventId, because: 'seed $seed: watermark non-null while poisoned').isNull();
      }
    } else if (store.dbActive && acct != null) {
      // I12: no row below evictedBelowMessageId; coverage lo >= evictedBelowMessageId.
      check(cov.evictedBelow).equals(acct.evictedBelowMessageId);
      for (final row in dbRows) {
        check(row.id, because: 'seed $seed: I12 row ${row.id} < ${acct.evictedBelowMessageId}')
          .isGreaterOrEqual(acct.evictedBelowMessageId);
      }
      for (final key in cov.keys) {
        for (final iv in cov.intervalsOf(key)) {
          check(iv.lo, because: 'seed $seed: I12 coverage $key lo=${iv.lo} < ${acct.evictedBelowMessageId}')
            .isGreaterOrEqual(acct.evictedBelowMessageId);
        }
      }
      // I16: running total_body_bytes matches SUM(body_bytes).
      final sumBytes = dbRows.fold<int>(0, (s, r) => s + r.bodyBytes);
      check(acct.totalBodyBytes, because: 'seed $seed: I16 totalBodyBytes mismatch').equals(sumBytes);

      // 1b. I5 / I6 when DB is active: live open intervals never miss across RAM U SQLite.
      final dbRowById = {for (final r in dbRows) r.id: r};
      for (final key in cov.keys) {
        for (final interval in cov.intervalsOf(key)) {
          if (!interval.tracked || interval.epoch != cov.epoch || !interval.isOpen) continue;
          for (final m in world.messages) {
            if (m.deleted || world.isExpired(m, nowSec)) continue;
            if (m.id < interval.lo || m.id > interval.top || m.id < cov.evictedBelow) continue;
            final bool matchesKey;
            if (key == CoverageKeys.dms) {
              matchesKey = m.isDm;
            } else if (key.startsWith('dm:')) {
              matchesKey = m.isDm && CoverageKeys.dm(m.dmRecipientIds!) == key;
            } else if (key.startsWith('channel:')) {
              final cid = CoverageKeys.channelIdOf(key)!;
              matchesKey = !m.isDm && m.streamId == cid && world.hasAccess(cid);
            } else if (key.startsWith('topic:')) {
              final cid = CoverageKeys.channelIdOf(key)!;
              matchesKey = !m.isDm
                && m.streamId == cid
                && world.hasAccess(cid)
                && CoverageKeys.topic(cid, m.topic!) == key;
            } else {
              matchesKey = false;
            }
            if (!matchesKey) continue;
            if (store.messages[m.id] != null) continue;
            final row = dbRowById[m.id];
            check(
              row,
              because: 'seed $seed: key $key open interval $interval missing msg ${m.id} in both RAM and DB',
            ).isNotNull();
            final bool rowMatches = switch (key) {
              CoverageKeys.dms => row!.dmKey != null,
              _ when key.startsWith('dm:') => row!.dmKey == key,
              _ when key.startsWith('channel:') => row!.channelId == CoverageKeys.channelIdOf(key),
              _ when key.startsWith('topic:') =>
                row!.channelId == CoverageKeys.channelIdOf(key)
                && row.topicKey == serverTopicFold(m.topic!),
              _ => false,
            };
            check(
              rowMatches,
              because: 'seed $seed: I5/I6 DB row ${m.id} location mismatch for $key',
            ).isTrue();
          }
        }
      }
    }

    // I4 & I14 in SQLite (even under removalOnly!):
    // - handled deletes removed their rows;
    // - purged inaccessible channel rows (by SQLite channelId) are absent.
    // When DB is active, DB rows match world deletion and channel access.
    final deletedIds = {for (final m in world.messages) if (m.deleted) m.id};
    final truthById = {for (final m in world.messages) m.id: m};
    for (final row in dbRows) {
      check(
        handledDeletedIds.contains(row.id),
        because: 'seed $seed: I4 handled deleted msg ${row.id} still in DB',
      ).isFalse();
      if (row.channelId case final cid?) {
        check(
          world.hasAccess(cid),
          because: 'seed $seed: I14 inaccessible channel $cid msg ${row.id} in DB',
        ).isTrue();
      }
      if (store.dbActive && !writer.isPoisoned && !poisonedByTest) {
        check(
          deletedIds.contains(row.id),
          because: 'seed $seed: I4 deleted msg ${row.id} still in active DB',
        ).isFalse();
        final m = truthById[row.id];
        if (m != null && !m.isDm) {
          check(
            world.hasAccess(m.streamId!),
            because: 'seed $seed: I14 moved-inaccessible msg ${row.id} still in active DB',
          ).isTrue();
        }
      }
    }
  }

  try {
    await startFresh();
    for (int step = 0; step < steps; step++) {
      final store = um!.store;
      final conn = currentConn;
      final writer = global.backend.messageDbWriterForAccount(eg.selfAccount.id);
      final nowSec = testBinding.utcNow().millisecondsSinceEpoch ~/ 1000;

      if (step == 25 && seed % 5 == 0 && !poisonedByTest) {
        writer.debugBeforeWrite = () async {
          throw StateError('injected seed failure');
        };
        final id = world.nextMsgId++;
        world.maxKnownMsgId = max(world.maxKnownMsgId, id);
        final eid = world.nextEventId++;
        final msg = _DbTruthMsg(id: id, isDm: false, timestamp: nowSec, streamId: 1, topic: 'alpha');
        world.messages.add(msg);
        await store.handleEventBatch([
          MessageEvent(id: eid, localMessageId: null, message: msg.toModelMessage(world.streams)),
        ], lastEventId: eid);
        await writer.drainForTesting();
        writer.debugBeforeWrite = null;
        poisonedByTest = true;
        await verifyInvariants(checkDb: true);
        continue;
      }
      if (step == 40 && poisonedByTest) {
        await writer.drainForTesting();
        await startFresh();
        await verifyInvariants(checkDb: true);
        continue;
      }

      final op = world.rng.nextInt(11);

      if (op < 4) {
        // Send sequential MessageEvent (for accessible messages).
        final id = world.nextMsgId++;
        world.maxKnownMsgId = max(world.maxKnownMsgId, id);
        final eid = world.nextEventId++;
        final isDm = world.rng.nextInt(4) == 0;
        final _DbTruthMsg msg;
        if (isDm) {
          msg = _DbTruthMsg(
            id: id,
            isDm: true,
            timestamp: nowSec,
            dmRecipientIds: dmNarrow.allRecipientIds,
          );
        } else {
          final streamId = 1 + world.rng.nextInt(3);
          final topic = topics[world.rng.nextInt(topics.length)];
          msg = _DbTruthMsg(
            id: id,
            isDm: false,
            timestamp: nowSec,
            streamId: streamId,
            topic: topic,
          );
        }
        world.messages.add(msg);
        if (isDm || world.hasAccess(msg.streamId!)) {
          await store.handleEventBatch([
            MessageEvent(
              id: eid,
              localMessageId: null,
              message: msg.toModelMessage(world.streams),
            ),
          ], lastEventId: eid);
        }
      } else if (op < 6 && views.length < 3) {
        // Open a MessageListView (online or offline).
        final narrow = pickNarrow();
        final view = MessageListView.init(
          store: store,
          narrow: narrow,
          anchor: AnchorCode.newest,
        );
        views.add(view);
        final failOffline = world.rng.nextBool();
        if (failOffline) {
          conn.prepare(httpException: const SocketException('offline'));
          final fetchFuture = view.fetchInitial();
          async.elapse(Duration.zero);
          await writer.drainForTesting();
          async.elapse(Duration.zero);
          viewFloorAtFetch[view] = store.debugCoverage.evictedBelow;
          await verifyInvariants(checkDb: false);
          if (world.rng.nextBool()) {
            viewFloorAtFetch.remove(view);
            views.remove(view);
            view.dispose();
          } else {
            conn.prepare(json: world.computeFetch(
              narrow: narrow,
              anchor: AnchorCode.newest,
              numBefore: 20,
              numAfter: 0,
              includeAnchor: true,
              nowSec: nowSec,
            ).toJson());
            async.elapse(const Duration(seconds: 2));
            await fetchFuture;
            viewFloorAtFetch[view] = store.debugCoverage.evictedBelow;
            if (view.messages.isEmpty) {
              views.remove(view);
              viewFloorAtFetch.remove(view);
              view.dispose();
            }
          }
        } else {
          conn.prepare(json: world.computeFetch(
            narrow: narrow,
            anchor: AnchorCode.newest,
            numBefore: 20,
            numAfter: 0,
            includeAnchor: true,
            nowSec: nowSec,
          ).toJson());
          await view.fetchInitial();
          viewFloorAtFetch[view] = store.debugCoverage.evictedBelow;
          if (view.messages.isEmpty) {
            views.remove(view);
            viewFloorAtFetch.remove(view);
            view.dispose();
          }
        }
      } else if (op == 6 && views.isNotEmpty) {
        // Paginate older or dispose a view.
        final idx = world.rng.nextInt(views.length);
        final view = views[idx];
        if (view.fetched && !view.haveOldest && view.messages.isNotEmpty && world.rng.nextBool()) {
          conn.prepare(json: world.computeFetch(
            narrow: view.narrow,
            anchor: NumericAnchor(view.messages.first.id),
            numBefore: 10,
            numAfter: 0,
            includeAnchor: false,
            nowSec: nowSec,
          ).toJson());
          await view.fetchOlder();
          viewFloorAtFetch[view] = store.debugCoverage.evictedBelow;
        } else {
          viewFloorAtFetch.remove(view);
          views.removeAt(idx).dispose();
        }
      } else if (op == 7) {
        // Delete a random message (stream or DM).
        final candidates = [for (final m in world.messages) if (!m.deleted) m];
        if (candidates.isNotEmpty) {
          final target = candidates[world.rng.nextInt(candidates.length)];
          target.deleted = true;
          if (target.isDm || world.hasAccess(target.streamId!)) {
            handledDeletedIds.add(target.id);
            final eid = world.nextEventId++;
            await store.handleEventBatch([
              DeleteMessageEvent(
                id: eid,
                messageIds: [target.id],
                messageType: target.isDm ? MessageType.direct : MessageType.stream,
                streamId: target.streamId,
                topic: target.topic != null ? eg.t(target.topic!) : null,
              ),
            ], lastEventId: eid);
          }
        }
      } else if (op == 8) {
        // Move a stream message.
        final candidates = [
          for (final m in world.messages)
            if (!m.deleted && !m.isDm && world.hasAccess(m.streamId!)) m,
        ];
        if (candidates.isNotEmpty) {
          final target = candidates[world.rng.nextInt(candidates.length)];
          final origStreamId = target.streamId!;
          final origTopic = target.topic!;
          final newStreamId = 1 + world.rng.nextInt(3);
          final newTopic = topics[world.rng.nextInt(topics.length)];
          if (origStreamId != newStreamId || origTopic != newTopic) {
            final origMsg = target.toModelMessage(world.streams) as StreamMessage;
            target.streamId = newStreamId;
            target.topic = newTopic;
            final eid = world.nextEventId++;
            if (!world.hasAccess(newStreamId)) {
              await store.handleEventBatch([
                DeleteMessageEvent(
                  id: eid,
                  messageIds: [origMsg.id],
                  messageType: MessageType.stream,
                  streamId: origStreamId,
                  topic: origMsg.topic,
                ),
              ], lastEventId: eid);
            } else {
              final refetchedViews = <MessageListView>[];
              for (final v in views) {
                if (v.narrow case TopicNarrow(:final channelId, :final topic)) {
                  final oldMatch = origStreamId == channelId
                    && serverTopicFold(origTopic) == serverTopicFold(topic.apiName);
                  final newMatch = newStreamId == channelId
                    && serverTopicFold(newTopic) == serverTopicFold(topic.apiName);
                  if (!oldMatch && newMatch) {
                    refetchedViews.add(v);
                    conn.prepare(json: world.computeFetch(
                      narrow: v.narrow,
                      anchor: AnchorCode.newest,
                      numBefore: 20,
                      numAfter: 0,
                      includeAnchor: true,
                      nowSec: nowSec,
                    ).toJson());
                  }
                } else if (v.narrow case ChannelNarrow(:final channelId)
                    when channelId == newStreamId && origStreamId != newStreamId) {
                  refetchedViews.add(v);
                  conn.prepare(json: world.computeFetch(
                    narrow: v.narrow,
                    anchor: AnchorCode.newest,
                    numBefore: 20,
                    numAfter: 0,
                    includeAnchor: true,
                    nowSec: nowSec,
                  ).toJson());
                }
              }
              await store.handleEventBatch([
                UpdateMessageEvent(
                  id: eid,
                  userId: eg.selfUser.userId,
                  renderingOnly: false,
                  messageId: origMsg.id,
                  messageIds: [origMsg.id],
                  flags: origMsg.flags,
                  editTimestamp: nowSec,
                  moveData: UpdateMessageMoveData(
                    origStreamId: origStreamId,
                    newStreamId: newStreamId,
                    origTopic: origMsg.topic,
                    newTopic: eg.t(newTopic),
                    propagateMode: PropagateMode.changeOne,
                  ),
                  origContent: null,
                  origRenderedContent: null,
                  content: null,
                  renderedContent: null,
                  isMeMessage: null,
                ),
              ], lastEventId: eid);
              async.elapse(Duration.zero);
              for (final v in refetchedViews) {
                viewFloorAtFetch[v] = store.debugCoverage.evictedBelow;
              }
            }
          }
        }
      } else if (op == 9) {
        // Toggle subscription on channel 1 or 2.
        final cid = 1 + world.rng.nextInt(2);
        final eid = world.nextEventId++;
        if (world.subscribed.contains(cid)) {
          world.subscribed.remove(cid);
          await store.handleEventBatch([
            SubscriptionRemoveEvent(id: eid, channelIds: [cid]),
          ], lastEventId: eid);
        } else {
          world.subscribed.add(cid);
          final refetchedViews = <MessageListView>[];
          for (final v in views) {
            final vCid = switch (v.narrow) {
              ChannelNarrow(:final channelId) || TopicNarrow(:final channelId) => channelId,
              _ => null,
            };
            if (vCid == cid) {
              refetchedViews.add(v);
              conn.prepare(json: world.computeFetch(
                narrow: v.narrow,
                anchor: AnchorCode.newest,
                numBefore: 20,
                numAfter: 0,
                includeAnchor: true,
                nowSec: nowSec,
              ).toJson());
            }
          }
          await store.handleEventBatch([
            SubscriptionAddEvent(id: eid, subscriptions: [eg.subscription(world.streams[cid]!)]),
          ], lastEventId: eid);
          async.elapse(Duration.zero);
          for (final v in refetchedViews) {
            viewFloorAtFetch[v] = store.debugCoverage.evictedBelow;
          }
        }
      } else if (op == 10) {
        // Advance virtual clock (triggers daily retention on next write if >= 1d) or restart store.
        if (world.rng.nextInt(3) == 0) {
          async.elapse(const Duration(days: 1, minutes: 5));
        } else {
          await writer.drainForTesting();
          await startFresh();
        }
      }

      await verifyInvariants(checkDb: step % 5 == 0 || step == steps - 1 || op >= 8);
    }
  } finally {
    MessageStoreImpl.debugSoftByteCap = null;
    for (final v in views) {
      v.dispose();
    }
    um?.dispose();
    await global.backend.debugMessageDatabase?.close();
  }
}
