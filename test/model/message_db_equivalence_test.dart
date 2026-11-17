import 'dart:convert';
import 'dart:math' as math;

import 'package:checks/checks.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:test/scaffolding.dart';
import 'package:zulip/api/model/events.dart';
import 'package:zulip/api/model/initial_snapshot.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/api/model/submessage.dart';
import 'package:zulip/model/message_database.dart';
import 'package:zulip/model/message_effect.dart';
import 'package:zulip/model/message_search_text.dart';
import 'package:zulip/model/presence.dart';
import 'package:zulip/model/settings.dart';
import 'package:zulip/model/store.dart';
import 'package:zulip/model/stored_message_codec.dart';

import '../api/fake_api.dart';
import '../example_data.dart' as eg;
import '../fake_async.dart';
import 'binding.dart';

/// Tracks state needed by the PRNG event generator to produce valid sequences
/// across all [MessageEffectKind] values.
class _SimState {
  _SimState.seeded(this.seed, this.channels) : rng = math.Random(seed) {
    subscribedChannels.addAll([for (final c in channels) c.streamId]);
  }

  final int seed;
  final math.Random rng;
  final List<ZulipStream> channels;

  int nextEventId = 100;
  int nextMessageId = 100;
  int nextSubmessageId = 1;
  int nextTimestamp = 1_700_000_000;

  final Set<int> subscribedChannels = {};
  final Set<int> purgedChannels = {};
  final List<_TrackedGenMessage> existingMessages = [];

  List<int> activeChannelIds() => [
    for (final c in channels)
      if (!purgedChannels.contains(c.streamId)) c.streamId,
  ];
}

class _TrackedGenMessage {
  _TrackedGenMessage({
    required this.id,
    required this.senderId,
    required this.isStream,
    required this.channelId,
    required this.topic,
    required this.hasPoll,
  });

  final int id;
  final int senderId;
  final bool isStream;
  final bool hasPoll;
  int nextPollOptionIdx = 0;
  int? channelId;
  String? topic;
}

const _topics = ['alpha', 'Beta', 'gamma', 'resolved'];
const _contents = ['hello', 'updated text', 'more content', 'poll question'];
const _emojis = [
  ('tada', '1f389', ReactionType.unicodeEmoji),
  ('smile', '1f604', ReactionType.unicodeEmoji),
  ('zulip', 'zulip', ReactionType.zulipExtraEmoji),
];

/// Exhaustively generates an [Event] for every [MessageEffectKind].
Event _generateEventForKind(
  MessageEffectKind kind,
  _SimState s,
) {
  final rng = s.rng;
  final eid = s.nextEventId++;
  final activeChannels = s.activeChannelIds();
  final streamMessages = [for (final m in s.existingMessages) if (m.isStream) m];

  switch (kind) {
    case MessageEffectKind.insert:
      final msgId = s.nextMessageId++;
      final ts = s.nextTimestamp += 5;
      final bool isDm = activeChannels.isEmpty || rng.nextInt(4) == 0;
      final bool makePoll = rng.nextInt(3) == 0;
      final Message msg;
      if (isDm) {
        final selfOnly = rng.nextBool();
        final fromUser = selfOnly ? eg.selfUser : (rng.nextBool() ? eg.selfUser : eg.otherUser);
        final toUsers = selfOnly
          ? <User>[]
          : [fromUser.userId == eg.selfUser.userId ? eg.otherUser : eg.selfUser];
        msg = eg.dmMessage(
          id: msgId,
          from: fromUser,
          to: toUsers,
          timestamp: ts,
          content: '<p>${_contents[rng.nextInt(_contents.length)]} $msgId</p>',
          flags: rng.nextBool() ? [MessageFlag.read] : [],
          submessages: makePoll
            ? [
                Submessage(
                  id: s.nextSubmessageId++,
                  senderId: fromUser.userId,
                  msgType: SubmessageType.widget,
                  content: jsonEncode(PollWidgetData(
                    extraData: PollWidgetExtraData(
                      question: 'Poll $msgId?',
                      options: ['Opt A', 'Opt B'],
                    ),
                  ).toJson()),
                ),
              ]
            : const [],
        );
        s.existingMessages.add(_TrackedGenMessage(
          id: msgId,
          senderId: fromUser.userId,
          isStream: false,
          channelId: null,
          topic: null,
          hasPoll: makePoll,
        ));
      } else {
        final cid = activeChannels[rng.nextInt(activeChannels.length)];
        final channel = s.channels.firstWhere((c) => c.streamId == cid);
        final topic = _topics[rng.nextInt(_topics.length)];
        final sender = rng.nextBool() ? eg.selfUser : eg.otherUser;
        msg = eg.streamMessage(
          id: msgId,
          stream: channel,
          topic: topic,
          sender: sender,
          timestamp: ts,
          content: '<p>${_contents[rng.nextInt(_contents.length)]} $msgId</p>',
          flags: rng.nextBool() ? [MessageFlag.read, MessageFlag.starred] : [MessageFlag.read],
          submessages: makePoll
            ? [
                Submessage(
                  id: s.nextSubmessageId++,
                  senderId: sender.userId,
                  msgType: SubmessageType.widget,
                  content: jsonEncode(PollWidgetData(
                    extraData: PollWidgetExtraData(
                      question: 'Poll $msgId?',
                      options: ['Opt A', 'Opt B'],
                    ),
                  ).toJson()),
                ),
              ]
            : const [],
        );
        s.existingMessages.add(_TrackedGenMessage(
          id: msgId,
          senderId: sender.userId,
          isStream: true,
          channelId: cid,
          topic: topic,
          hasPoll: makePoll,
        ));
      }
      return MessageEvent(id: eid, message: msg, localMessageId: null);

    case MessageEffectKind.updateMessage:
      if (s.existingMessages.isEmpty) {
        return _generateEventForKind(MessageEffectKind.insert, s);
      }
      if (rng.nextInt(3) == 0 && streamMessages.isNotEmpty && activeChannels.length >= 2) {
        // Message move (same-channel or cross-channel).
        final target = streamMessages[rng.nextInt(streamMessages.length)];
        final origCid = target.channelId!;
        final origTopic = target.topic!;
        final newCid = rng.nextBool()
          ? origCid
          : activeChannels[rng.nextInt(activeChannels.length)];
        String newTopic = _topics[rng.nextInt(_topics.length)];
        if (newCid == origCid && newTopic == origTopic) {
          newTopic = '$origTopic-moved';
        }
        // Pick messages matching (origCid, origTopic) to satisfy C14 consistency.
        final matchingIds = [
          for (final m in streamMessages)
            if (m.channelId == origCid && m.topic == origTopic) m.id,
        ];
        final picked = [target.id];
        if (matchingIds.length > 1 && rng.nextBool()) {
          for (final id in matchingIds) {
            if (id != target.id && rng.nextBool()) picked.add(id);
          }
          picked.sort();
        }
        for (final m in streamMessages) {
          if (picked.contains(m.id)) {
            m.channelId = newCid;
            m.topic = newTopic;
          }
        }
        return UpdateMessageEvent(
          id: eid,
          userId: eg.selfUser.userId,
          renderingOnly: false,
          messageId: picked.first,
          messageIds: picked,
          flags: const [],
          editTimestamp: s.nextTimestamp += 5,
          moveData: UpdateMessageMoveData(
            origStreamId: origCid,
            newStreamId: newCid,
            origTopic: eg.t(origTopic),
            newTopic: eg.t(newTopic),
            propagateMode: PropagateMode.changeLater,
          ),
          origContent: null,
          origRenderedContent: null,
          content: null,
          renderedContent: null,
          isMeMessage: null,
        );
      } else {
        // Content or rendering-only update.
        final target = s.existingMessages[rng.nextInt(s.existingMessages.length)];
        final renderingOnly = rng.nextBool();
        final flagList = <MessageFlag>[
          if (rng.nextBool()) MessageFlag.read,
          if (rng.nextBool()) MessageFlag.starred,
          if (rng.nextBool()) MessageFlag.mentioned,
        ];
        return UpdateMessageEvent(
          id: eid,
          userId: renderingOnly ? null : eg.selfUser.userId,
          renderingOnly: renderingOnly,
          messageId: target.id,
          messageIds: [target.id],
          flags: flagList,
          editTimestamp: s.nextTimestamp += 5,
          moveData: null,
          origContent: renderingOnly ? null : 'old',
          origRenderedContent: '<p>old</p>',
          content: renderingOnly ? null : 'edited ${s.nextTimestamp}',
          renderedContent: '<p>edited ${s.nextTimestamp}</p>',
          isMeMessage: renderingOnly ? null : rng.nextBool(),
        );
      }

    case MessageEffectKind.delete:
      if (s.existingMessages.isEmpty) {
        return DeleteMessageEvent(
          id: eid,
          messageIds: [999999],
          messageType: MessageType.direct,
          streamId: null,
          topic: null,
        );
      }
      final idx = rng.nextInt(s.existingMessages.length);
      final removed = s.existingMessages.removeAt(idx);
      return DeleteMessageEvent(
        id: eid,
        messageIds: [removed.id],
        messageType: removed.isStream ? MessageType.stream : MessageType.direct,
        streamId: removed.channelId,
        topic: removed.isStream ? eg.t(removed.topic!) : null,
      );

    case MessageEffectKind.flag:
      final targets = <int>[
        if (s.existingMessages.isNotEmpty)
          s.existingMessages[rng.nextInt(s.existingMessages.length)].id,
      ];
      final flag = rng.nextBool() ? MessageFlag.read : MessageFlag.starred;
      if (rng.nextBool()) {
        return UpdateMessageFlagsAddEvent(
          id: eid,
          flag: flag,
          messages: targets,
          all: false,
        );
      } else {
        return UpdateMessageFlagsRemoveEvent(
          id: eid,
          flag: flag,
          messages: targets,
          messageDetails: flag == MessageFlag.read ? const {} : null,
        );
      }

    case MessageEffectKind.flagAllRead:
      return UpdateMessageFlagsAddEvent(
        id: eid,
        flag: MessageFlag.read,
        messages: const [],
        all: true,
      );

    case MessageEffectKind.reaction:
      if (s.existingMessages.isEmpty) {
        return _generateEventForKind(MessageEffectKind.insert, s);
      }
      final target = s.existingMessages[rng.nextInt(s.existingMessages.length)];
      final (name, code, rtype) = _emojis[rng.nextInt(_emojis.length)];
      return ReactionEvent(
        id: eid,
        op: rng.nextBool() ? ReactionOp.add : ReactionOp.remove,
        messageId: target.id,
        emojiName: name,
        emojiCode: code,
        reactionType: rtype,
        userId: rng.nextBool() ? eg.selfUser.userId : eg.otherUser.userId,
      );

    case MessageEffectKind.submessage:
      if (s.existingMessages.isEmpty) {
        return _generateEventForKind(MessageEffectKind.insert, s);
      }
      final pollTargets = [for (final m in s.existingMessages) if (m.hasPoll) m];
      final target = (pollTargets.isNotEmpty && rng.nextInt(5) != 0)
        ? pollTargets[rng.nextInt(pollTargets.length)]
        : s.existingMessages[rng.nextInt(s.existingMessages.length)];
      final subId = s.nextSubmessageId++;
      final int subSenderId;
      final PollEventSubmessage payload;
      switch (rng.nextInt(3)) {
        case 0:
          subSenderId = rng.nextBool() ? eg.selfUser.userId : eg.otherUser.userId;
          payload = PollVoteEventSubmessage(
            key: rng.nextBool() ? 'canned,0' : 'canned,1',
            op: rng.nextBool() ? PollVoteOp.add : PollVoteOp.remove,
          );
        case 1:
          subSenderId = rng.nextBool() ? eg.selfUser.userId : eg.otherUser.userId;
          payload = PollNewOptionEventSubmessage(
            option: 'Opt $subId',
            idx: target.nextPollOptionIdx++,
          );
        default:
          subSenderId = target.senderId;
          payload = PollQuestionEventSubmessage(question: 'Q$subId');
      }
      return SubmessageEvent(
        id: eid,
        submessageId: subId,
        messageId: target.id,
        senderId: subSenderId,
        msgType: SubmessageType.widget,
        content: jsonEncode(payload.toJson()),
      );

    case MessageEffectKind.channelUntrack:
      final candidateCids = [
        for (final c in s.channels)
          if (!s.purgedChannels.contains(c.streamId) && s.subscribedChannels.contains(c.streamId))
            c.streamId,
      ];
      if (candidateCids.isEmpty) {
        return HeartbeatEvent(id: eid);
      }
      final cid = candidateCids[rng.nextInt(candidateCids.length)];
      s.subscribedChannels.remove(cid);
      return SubscriptionRemoveEvent(
        id: eid,
        channelIds: [cid],
      );

    case MessageEffectKind.channelPurge:
      // Keep at least one public active channel so subsequent stream inserts succeed.
      final candidateCids = [
        for (final c in s.channels)
          if (!s.purgedChannels.contains(c.streamId)) c.streamId,
      ];
      if (candidateCids.length <= 1) {
        return HeartbeatEvent(id: eid);
      }
      final cid = candidateCids.last;
      s.purgedChannels.add(cid);
      s.subscribedChannels.remove(cid);
      s.existingMessages.removeWhere((m) => m.channelId == cid);
      return ChannelDeleteEvent(id: eid, channelIds: [cid]);

    case MessageEffectKind.channelAccessCheck:
      if (activeChannels.isEmpty) return HeartbeatEvent(id: eid);
      final cid = activeChannels[rng.nextInt(activeChannels.length)];
      return ChannelUpdateEvent(
        id: eid,
        streamId: cid,
        name: s.channels.firstWhere((c) => c.streamId == cid).name,
        property: ChannelPropertyName.description,
        value: 'updated description $eid',
      );

    case MessageEffectKind.none:
      return HeartbeatEvent(id: eid);
  }
}

Future<Map<int, Message>> _decodeAllStoredMessages(
  MessageDatabase db, {
  required int accountId,
}) async {
  final rows = await (db.select(db.storedMessages)
        ..where((m) => m.accountId.equals(accountId)))
      .get();
  final bodies = await (db.select(db.storedMessageBodies)
        ..where((b) => b.accountId.equals(accountId)))
      .get();
  final reactions = await (db.select(db.storedReactions)
        ..where((r) => r.accountId.equals(accountId)))
      .get();
  final submessages = await (db.select(db.storedSubmessages)
        ..where((s) => s.accountId.equals(accountId)))
      .get();

  final bodyByMsg = {for (final b in bodies) b.messageId: b};
  final reactionsByMsg = <int, List<StoredReaction>>{};
  for (final r in reactions) {
    reactionsByMsg.putIfAbsent(r.messageId, () => []).add(r);
  }
  final submessagesByMsg = <int, List<StoredSubmessage>>{};
  for (final s in submessages) {
    submessagesByMsg.putIfAbsent(s.messageId, () => []).add(s);
  }

  return {
    for (final row in rows)
      row.id: StoredMessageCodec.decode(
        row: row,
        body: bodyByMsg[row.id]!,
        reactions: reactionsByMsg[row.id] ?? const [],
        submessages: submessagesByMsg[row.id] ?? const [],
      ),
  };
}

void _checkMessagesEquivalent(Message dbMsg, Message memMsg) {
  check(dbMsg.id).equals(memMsg.id);
  check(dbMsg.senderId).equals(memMsg.senderId);
  check(dbMsg.timestamp).equals(memMsg.timestamp);
  check(dbMsg.content).equals(memMsg.content);
  check(dbMsg.isMeMessage).equals(memMsg.isMeMessage);
  check(dbMsg.editState).equals(memMsg.editState);
  check(dbMsg.lastEditTimestamp).equals(memMsg.lastEditTimestamp);
  check(dbMsg.flags.toSet()).deepEquals(memMsg.flags.toSet());

  switch (memMsg) {
    case StreamMessage():
      final dbStream = dbMsg as StreamMessage;
      check(dbStream.streamId).equals(memMsg.streamId);
      check(dbStream.topic).equals(memMsg.topic);
    case DmMessage():
      final dbDm = dbMsg as DmMessage;
      check(dbDm.allRecipientIds).deepEquals(memMsg.allRecipientIds);
  }

  final dbAgg = dbMsg.reactions?.aggregated ?? const [];
  final memAgg = memMsg.reactions?.aggregated ?? const [];
  check(dbAgg.length).equals(memAgg.length);
  for (int i = 0; i < dbAgg.length; i++) {
    check(dbAgg[i].reactionType).equals(memAgg[i].reactionType);
    check(dbAgg[i].emojiCode).equals(memAgg[i].emojiCode);
    check(dbAgg[i].emojiName).equals(memAgg[i].emojiName);
    check(dbAgg[i].userIds).deepEquals(memAgg[i].userIds);
  }

  final dbPoll = dbMsg.poll;
  final memPoll = memMsg.poll;
  if (memPoll == null) {
    check(dbPoll).isNull();
  } else {
    check(dbPoll).isNotNull();
    check(dbPoll!.question).equals(memPoll.question);
    final dbOpts = dbPoll.options.toList();
    final memOpts = memPoll.options.toList();
    check(dbOpts.length).equals(memOpts.length);
    for (int i = 0; i < dbOpts.length; i++) {
      check(dbOpts[i].text).equals(memOpts[i].text);
      check(dbOpts[i].voters).deepEquals(memOpts[i].voters);
    }
    check([for (final s in Poll.toJson(dbPoll)) s.toJson()])
      .deepEquals([for (final s in Poll.toJson(memPoll)) s.toJson()]);
  }
}

void main() {
  TestZulipBinding.ensureInitialized();
  Presence.debugEnable = false;

  Future<void> checkFtsEquivalence(
    MessageDatabase db, {
    required int accountId,
    required Map<int, Message> expectedMessages,
  }) async {
    final orphanRow = await db.customSelect(
      'SELECT COUNT(*) AS c FROM stored_message_fts '
      'WHERE rowid NOT IN (SELECT rowid FROM stored_message_bodies)',
    ).getSingle();
    check(orphanRow.read<int>('c')).equals(0);

    final ftsRows = await db.customSelect(
      'SELECT f.rowid AS fts_rowid, b.rowid AS body_rowid, '
      'f.message_id, f.topic_text, f.body_text '
      'FROM stored_message_fts f '
      'JOIN stored_message_bodies b '
      '  ON b.account_id = f.account_id AND b.message_id = f.message_id '
      'WHERE f.account_id = ?',
      variables: [Variable.withInt(accountId)],
    ).get();
    final ftsById = {
      for (final r in ftsRows)
        r.read<int>('message_id'): (
          ftsRowId: r.read<int>('fts_rowid'),
          bodyRowId: r.read<int>('body_rowid'),
          topicText: r.read<String>('topic_text'),
          bodyText: r.read<String>('body_text'),
        ),
    };
    check(ftsById.keys.toSet()).deepEquals(expectedMessages.keys.toSet());
    for (final entry in expectedMessages.entries) {
      final fts = ftsById[entry.key]!;
      final msg = entry.value;
      check(fts.ftsRowId).equals(fts.bodyRowId);
      final expectedTopic = msg is StreamMessage ? msg.topic.apiName : '';
      check(fts.topicText).equals(expectedTopic);
      check(fts.bodyText).equals(extractSearchBodyTextFromMessage(msg));
    }
  }

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

  test('generator covers every MessageEffectKind', () {
    final stream1 = eg.stream(streamId: 10);
    final stream2 = eg.stream(streamId: 20);
    final sim = _SimState.seeded(1, [stream1, stream2]);
    _generateEventForKind(MessageEffectKind.insert, sim);
    for (final kind in MessageEffectKind.values) {
      final event = _generateEventForKind(kind, sim);
      check(event.id).isGreaterThan(0);
    }
  });

  test('Mode A: random sequences across all MessageEffectKinds match DB vs RAM', () => awaitFakeAsync((async) async {
    const seeds = 40;
    const opsPerSeed = 35;
    for (int seed = 1; seed <= seeds; seed++) {
      final globalStore = eg.globalStore();
      await globalStore.settings.setBool(BoolGlobalSetting.messageDatabase, true);
      await globalStore.insertAccount(eg.selfAccount.toCompanion(false));
      final connection = globalStore.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
      globalStore.useCachedApiConnections = true;
      UpdateMachine.debugEnableFetchEmojiData = false;
      final machines = <UpdateMachine>[];
      try {
        final s1 = eg.stream(streamId: 10, name: 'S1');
        final s2 = eg.stream(streamId: 20, name: 'S2');
        final s3 = eg.stream(streamId: 30, name: 'S3');
        final snap = eg.initialSnapshot(
          queueId: 'q1',
          lastEventId: 10,
          maxMessageId: 50,
          realmUsers: [eg.selfUser, eg.otherUser],
          streams: [s1, s2, s3],
          subscriptions: [eg.subscription(s1), eg.subscription(s2), eg.subscription(s3)],
        );
        connection.prepare(json: snapshotToJson(snap));
        connection.prepare(json: {'result': 'success', 'msg': '', 'events': <Object>[], 'queue_id': 'q1'});
        final um = await UpdateMachine.load(globalStore, eg.selfAccount.id, allowPersisted: false);
        machines.add(um);
        um.debugPauseLoop();
        async.elapse(Duration.zero);

        final sim = _SimState.seeded(seed, [s1, s2, s3]);
        final allKinds = MessageEffectKind.values;
        final batch = <Event>[];
        for (int i = 0; i < opsPerSeed; i++) {
          final kind = i < 6
            ? MessageEffectKind.insert
            : allKinds[sim.rng.nextInt(allKinds.length)];
          batch.add(_generateEventForKind(kind, sim));
        }

        int cursor = 0;
        while (cursor < batch.length) {
          final chunkLen = math.min(1 + sim.rng.nextInt(5), batch.length - cursor);
          final chunk = batch.sublist(cursor, cursor + chunkLen);
          cursor += chunkLen;
          await um.store.handleEventBatch(chunk, lastEventId: null);
        }
        await globalStore.backend.messageDbWriterForAccount(eg.selfAccount.id).drainForTesting();

        final db = globalStore.backend.debugMessageDatabase!;
        final decoded = await _decodeAllStoredMessages(db, accountId: eg.selfAccount.id);

        check(decoded.keys.toSet()).deepEquals(um.store.messages.keys.toSet());
        for (final id in decoded.keys) {
          _checkMessagesEquivalent(decoded[id]!, um.store.messages[id]!);
        }

        final storedRows = await (db.select(db.storedMessages)
              ..where((m) => m.accountId.equals(eg.selfAccount.id)))
            .get();
        for (final row in storedRows) {
          final expectedTracked = !um.store.debugMaybeStaleMessages.contains(row.id);
          check(row.tracked).equals(expectedTracked);
        }

        final accountRow = await (db.select(db.messageDbAccounts)
              ..where((a) => a.accountId.equals(eg.selfAccount.id)))
            .getSingle();
        final expectedBytes = storedRows.fold<int>(0, (sum, r) => sum + r.bodyBytes);
        check(accountRow.totalBodyBytes).equals(expectedBytes);
        await checkFtsEquivalence(
          db,
          accountId: eg.selfAccount.id,
          expectedMessages: um.store.messages,
        );
      } finally {
        for (final um in machines) {
          if (!um.store.disposed) um.store.dispose();
        }
        await globalStore.backend.closeMessageDb();
        globalStore.dispose();
        UpdateMachine.debugEnableFetchEmojiData = true;
      }
    }
  }));

  test('Mode B: DB-only rows after persisted restart match in-memory oracle store', () => awaitFakeAsync((async) async {
    const seeds = 25;
    const opsPerSeed = 30;
    for (int seed = 101; seed <= 100 + seeds; seed++) {
      final dbGlobal = eg.globalStore();
      await dbGlobal.settings.setBool(BoolGlobalSetting.messageDatabase, true);
      await dbGlobal.insertAccount(eg.selfAccount.toCompanion(false));
      final dbConn1 = dbGlobal.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
      dbGlobal.useCachedApiConnections = true;

      final oracleGlobal = eg.globalStore();
      await oracleGlobal.settings.setBool(BoolGlobalSetting.messageDatabase, false);
      await oracleGlobal.insertAccount(eg.selfAccount.toCompanion(false));
      final oracleConn = oracleGlobal.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
      oracleGlobal.useCachedApiConnections = true;

      UpdateMachine.debugEnableFetchEmojiData = false;
      final machines = <UpdateMachine>[];
      try {
        final s1 = eg.stream(streamId: 10, name: 'S1');
        final s2 = eg.stream(streamId: 20, name: 'S2');
        final snap = eg.initialSnapshot(
          queueId: 'q1',
          lastEventId: 10,
          maxMessageId: 50,
          realmUsers: [eg.selfUser, eg.otherUser],
          streams: [s1, s2],
          subscriptions: [eg.subscription(s1), eg.subscription(s2)],
        );
        dbConn1.prepare(json: snapshotToJson(snap));
        dbConn1.prepare(json: {'result': 'success', 'msg': '', 'events': <Object>[], 'queue_id': 'q1'});
        oracleConn.prepare(json: snapshotToJson(snap));
        oracleConn.prepare(json: {'result': 'success', 'msg': '', 'events': <Object>[], 'queue_id': 'q1'});

        final dbUm1 = await UpdateMachine.load(dbGlobal, eg.selfAccount.id, allowPersisted: false);
        final oracleUm = await UpdateMachine.load(oracleGlobal, eg.selfAccount.id, allowPersisted: false);
        oracleUm.store.debugSetCoverageEnabled(true);
        machines.addAll([dbUm1, oracleUm]);
        dbUm1.debugPauseLoop();
        oracleUm.debugPauseLoop();
        async.elapse(Duration.zero);

        final sim = _SimState.seeded(seed, [s1, s2]);
        final seedEvents = <Event>[
          for (int i = 0; i < 10; i++) _generateEventForKind(MessageEffectKind.insert, sim),
        ];
        await dbUm1.store.handleEventBatch(seedEvents, lastEventId: null);
        await oracleUm.store.handleEventBatch(seedEvents, lastEventId: null);
        await dbGlobal.backend.messageDbWriterForAccount(eg.selfAccount.id).drainForTesting();
        check(dbUm1.store.dbActive).isTrue();
        final seededRows = await (dbGlobal.backend.debugMessageDatabase!.select(
          dbGlobal.backend.debugMessageDatabase!.storedMessages)).get();
        check(seededRows.length).equals(10);
        dbUm1.store.dispose();

        // Restart dbStore from persisted snapshot with empty RAM messages.
        dbGlobal.backend.seedServerData(
          eg.selfAccount.id,
          snapshotJson: snapshotToJson(snap),
          lastEventId: 10,
        );
        dbGlobal.clearCachedApiConnections();
        final dbConn2 = dbGlobal.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
        dbConn2.prepare(
          delay: const Duration(milliseconds: 50),
          json: {'result': 'success', 'msg': '', 'events': <Object>[], 'queue_id': 'q1'},
        );
        final dbUm2 = await UpdateMachine.load(dbGlobal, eg.selfAccount.id, allowPersisted: true);
        machines.add(dbUm2);
        dbUm2.debugPauseLoop();
        async.elapse(const Duration(milliseconds: 50));
        async.flushMicrotasks();
        check(dbUm2.store.dbActive).isTrue();
        final persistedRows = await (dbGlobal.backend.debugMessageDatabase!.select(
          dbGlobal.backend.debugMessageDatabase!.storedMessages)).get();
        check(persistedRows.length).equals(10);
        check(dbUm2.store.messages).isEmpty();

        final mutationKinds = [
          MessageEffectKind.updateMessage,
          MessageEffectKind.delete,
          MessageEffectKind.flag,
          MessageEffectKind.flagAllRead,
          MessageEffectKind.reaction,
          MessageEffectKind.submessage,
          MessageEffectKind.channelUntrack,
          MessageEffectKind.channelPurge,
          MessageEffectKind.channelAccessCheck,
          MessageEffectKind.none,
        ];
        final mutEvents = <Event>[
          for (int i = 0; i < opsPerSeed; i++)
            _generateEventForKind(mutationKinds[sim.rng.nextInt(mutationKinds.length)], sim),
        ];
        for (int i = 0; i < mutEvents.length; i += 4) {
          final chunk = mutEvents.sublist(i, math.min(i + 4, mutEvents.length));
          await dbUm2.store.handleEventBatch(chunk, lastEventId: null);
          await oracleUm.store.handleEventBatch(chunk, lastEventId: null);
        }
        await dbGlobal.backend.messageDbWriterForAccount(eg.selfAccount.id).drainForTesting();

        final db = dbGlobal.backend.debugMessageDatabase!;
        final decoded = await _decodeAllStoredMessages(db, accountId: eg.selfAccount.id);

        check(decoded.keys.toSet()).deepEquals(oracleUm.store.messages.keys.toSet());
        for (final id in decoded.keys) {
          _checkMessagesEquivalent(decoded[id]!, oracleUm.store.messages[id]!);
        }

        final storedRows = await (db.select(db.storedMessages)
              ..where((m) => m.accountId.equals(eg.selfAccount.id)))
            .get();
        final accountRow = await (db.select(db.messageDbAccounts)
              ..where((a) => a.accountId.equals(eg.selfAccount.id)))
            .getSingle();
        final expectedBytes = storedRows.fold<int>(0, (sum, r) => sum + r.bodyBytes);
        check(accountRow.totalBodyBytes).equals(expectedBytes);
        await checkFtsEquivalence(
          db,
          accountId: eg.selfAccount.id,
          expectedMessages: oracleUm.store.messages,
        );
      } finally {
        for (final um in machines) {
          if (!um.store.disposed) um.store.dispose();
        }
        await dbGlobal.backend.closeMessageDb();
        await oracleGlobal.backend.closeMessageDb();
        dbGlobal.dispose();
        oracleGlobal.dispose();
        UpdateMachine.debugEnableFetchEmojiData = true;
      }
    }
  }));
}
