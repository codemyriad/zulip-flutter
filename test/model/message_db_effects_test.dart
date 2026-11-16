import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
import 'package:drift/native.dart';
import 'package:test/scaffolding.dart';
import 'package:zulip/api/model/events.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/api/model/submessage.dart';
import 'package:zulip/model/message_database.dart';
import 'package:zulip/model/message_db_effects.dart';
import 'package:zulip/model/message_effect.dart';
import 'package:zulip/model/stored_message_codec.dart';

import '../api/model/model_checks.dart';
import '../example_data.dart' as eg;

void main() {
  Future<(MessageDatabase, int)> openWithAccount() async {
    final db = MessageDatabase(NativeDatabase.memory(setup: configureMessageDbPragmas));
    addTearDown(db.close);
    await db.into(db.messageDbAccounts).insert(MessageDbAccountsCompanion.insert(
      accountId: const Value(1),
      realmUrl: 'https://chat.example.org',
      userId: 100,
      formatVersion: MessageDatabase.currentFormatVersion,
      epoch: 1,
      appliedThroughEventId: const Value(1),
      eventHighWater: 100,
    ));
    return (db, 1);
  }

  Future<Message?> loadMessage(MessageDatabase db, int accountId, int id) async {
    final row = await (db.select(db.storedMessages)
      ..where((m) => m.accountId.equals(accountId) & m.id.equals(id))).getSingleOrNull();
    if (row == null) return null;
    final body = await (db.select(db.storedMessageBodies)
      ..where((b) => b.accountId.equals(accountId) & b.messageId.equals(id))).getSingle();
    final reactions = await (db.select(db.storedReactions)
      ..where((r) => r.accountId.equals(accountId) & r.messageId.equals(id))).get();
    final submessages = await (db.select(db.storedSubmessages)
      ..where((s) => s.accountId.equals(accountId) & s.messageId.equals(id))).get();
    return StoredMessageCodec.decode(
      row: row,
      body: body,
      reactions: reactions,
      submessages: submessages,
    );
  }

  Future<int> totalBodyBytes(MessageDatabase db, int accountId) async {
    final row = await (db.select(db.messageDbAccounts)
      ..where((a) => a.accountId.equals(accountId))).getSingle();
    return row.totalBodyBytes;
  }

  group('applyMessageEffectToDb', () {
    test('Insert, Content, EditTime, Move, Flag, FlagAllRead, Reaction, Submessage match in-memory', () async {
      final (db, accountId) = await openWithAccount();

      final stream1 = eg.stream(streamId: 1, name: 'one');
      final msg1 = eg.streamMessage(
        id: 10,
        stream: stream1,
        topic: 'alpha',
        content: '<p>old</p>',
        flags: [],
      );
      final raw1 = msg1.toJson();
      raw1['submessages'] = [
        {
          'id': 500,
          'sender_id': msg1.senderId,
          'msg_type': 'widget',
          'content': jsonEncode({
            'widget_type': 'poll',
            'extra_data': {'question': 'Q?', 'options': ['A', 'B']},
          }),
        },
      ];
      final mem1 = Message.fromJson(raw1) as StreamMessage;

      await db.transaction(() => applyMessageEffectToDb(
        db,
        accountId: accountId,
        epoch: 1,
        effect: InsertEffect(message: mem1, tracked: true),
        rawMessage: raw1,
      ));
      check(await totalBodyBytes(db, accountId)).isGreaterThan(0);

      final effects = <MessageEffect>[
        ContentEffect(
          messageId: 10,
          flags: [MessageFlag.read, MessageFlag.mentioned],
          editState: MessageEditState.edited,
          renderedContent: '<p>new much longer content</p>',
          isMeMessage: true,
        ),
        const EditTimeEffect(messageIds: [10], editTimestamp: 1700001234),
        MoveEffect(
          messageIds: const [10],
          origChannelId: 1,
          newChannelId: 2,
          origTopic: eg.t('alpha'),
          newTopic: eg.t('Beta'),
          untrack: true,
          markMoved: false,
        ),
        const FlagEffect(messageIds: [10], flag: MessageFlag.starred, add: true),
        const FlagEffect(messageIds: [10], flag: MessageFlag.mentioned, add: false),
        const ReactionEffect(
          messageId: 10,
          op: ReactionOp.add,
          emojiName: '+1',
          emojiCode: '1f44d',
          reactionType: ReactionType.unicodeEmoji,
          userId: 100,
        ),
        SubmessageEffect(event: SubmessageEvent(
          id: 9,
          msgType: SubmessageType.widget,
          content: jsonEncode({'type': 'vote', 'key': 'canned,0', 'vote': 1}),
          messageId: 10,
          senderId: 100,
          submessageId: 501,
        )),
      ];

      await db.transaction(() async {
        for (final effect in effects) {
          effect.applyToMessage(mem1);
          await applyMessageEffectToDb(db, accountId: accountId, epoch: 1, effect: effect);
        }
      });

      final db1 = await loadMessage(db, accountId, 10) as StreamMessage;
      check(db1.content).equals(mem1.content);
      check(db1.isMeMessage).equals(mem1.isMeMessage);
      check(db1.editState).equals(mem1.editState);
      check(db1.lastEditTimestamp).equals(mem1.lastEditTimestamp);
      check(db1.streamId).equals(mem1.streamId);
      check(db1.topic).equals(mem1.topic);
      check(db1.displayRecipient).isNull();
      check(db1.flags.toSet()).deepEquals(mem1.flags.toSet());
      check(db1.reactions).isNotNull().has((r) => r.total, 'total').equals(1);
      check(db1.poll).isNotNull()
        ..has((p) => p.options.length, 'options').equals(2)
        ..has((p) => p.options.first.voters, 'voters').deepEquals({100});

      final row1 = await (db.select(db.storedMessages)
        ..where((m) => m.accountId.equals(accountId) & m.id.equals(10))).getSingle();
      check(row1.tracked).isFalse();
      check(row1.topicKey).equals('BETA');
      check(await totalBodyBytes(db, accountId)).equals(row1.bodyBytes);

      // FlagAllReadEffect sets read bit across all messages.
      await db.transaction(() => applyMessageEffectToDb(
        db,
        accountId: accountId,
        epoch: 1,
        effect: const FlagAllReadEffect(),
      ));
      final afterAllRead = await loadMessage(db, accountId, 10);
      check(afterAllRead!.flags).contains(MessageFlag.read);
    });

    test('Delete, Forget, ChannelUntrack, ChannelPurge, and removalOnly mode', () async {
      final (db, accountId) = await openWithAccount();

      final s1 = eg.stream(streamId: 1);
      final s2 = eg.stream(streamId: 2);
      final m1 = eg.streamMessage(id: 1, stream: s1, topic: 't');
      final m2 = eg.streamMessage(id: 2, stream: s1, topic: 't');
      final m3 = eg.streamMessage(id: 3, stream: s2, topic: 't');

      await db.transaction(() async {
        for (final m in [m1, m2, m3]) {
          await applyMessageEffectToDb(
            db,
            accountId: accountId,
            epoch: 1,
            effect: InsertEffect(message: m, tracked: true),
            rawMessage: m.toJson(),
          );
        }
      });

      // removalOnly ignores ForgetEffect, FlagEffect, ChannelUntrackEffect, InsertEffect;
      // applies only DeleteEffect and ChannelPurgeEffect.
      final m4 = eg.streamMessage(id: 4, stream: s2, topic: 't');
      await db.transaction(() async {
        await applyMessageEffectToDb(db, accountId: accountId, epoch: 1,
          effect: InsertEffect(message: m4, tracked: true), rawMessage: m4.toJson(), removalOnly: true);
        await applyMessageEffectToDb(db, accountId: accountId, epoch: 1,
          effect: const ForgetEffect(messageIds: [1]), removalOnly: true);
        await applyMessageEffectToDb(db, accountId: accountId, epoch: 1,
          effect: const FlagEffect(messageIds: [1], flag: MessageFlag.starred, add: true), removalOnly: true);
        await applyMessageEffectToDb(db, accountId: accountId, epoch: 1,
          effect: const DeleteEffect(messageIds: [2]), removalOnly: true);
        await applyMessageEffectToDb(db, accountId: accountId, epoch: 1,
          effect: const ChannelPurgeEffect(channelId: 2), removalOnly: true);
      });

      check(await loadMessage(db, accountId, 1)).isNotNull()
        .has((m) => m.flags.contains(MessageFlag.starred), 'starred').isFalse();
      check(await loadMessage(db, accountId, 2)).isNull();
      check(await loadMessage(db, accountId, 3)).isNull();
      check(await loadMessage(db, accountId, 4)).isNull();

      // Normal ForgetEffect deletes row 1 and zeros totalBodyBytes.
      await db.transaction(() => applyMessageEffectToDb(
        db, accountId: accountId, epoch: 1, effect: const ForgetEffect(messageIds: [1])));
      check(await loadMessage(db, accountId, 1)).isNull();
      check(await totalBodyBytes(db, accountId)).equals(0);
    });

    test('FTS5 index tracks ContentEffect, MoveEffect, and poll SubmessageEffect', () async {
      final (db, accountId) = await openWithAccount();
      final stream = eg.stream(streamId: 1, name: 'one');
      final msg = eg.streamMessage(
        id: 10,
        stream: stream,
        topic: 'initial topic',
        content: '<p>alpha</p><p>beta</p>',
      );
      final raw = msg.toJson();
      raw['submessages'] = [
        {
          'id': 500,
          'sender_id': msg.senderId,
          'msg_type': 'widget',
          'content': jsonEncode({
            'widget_type': 'poll',
            'extra_data': {'question': 'First Q?', 'options': ['Apple']},
          }),
        },
      ];
      final mem = Message.fromJson(raw) as StreamMessage;
      await db.transaction(() => applyMessageEffectToDb(
        db,
        accountId: accountId,
        epoch: 1,
        effect: InsertEffect(message: mem, tracked: true),
        rawMessage: raw,
      ));

      check((await db.searchStoredMessages(
        accountId,
        spec: const StoredMessageSearchSpec(positiveFtsMatch: '"alpha" AND "apple"'),
        limit: 10,
      )).length).equals(1);

      // Edit content: old word removed, new word indexed.
      await db.transaction(() => applyMessageEffectToDb(
        db,
        accountId: accountId,
        epoch: 1,
        effect: ContentEffect(
          messageId: 10,
          flags: const [MessageFlag.read],
          editState: MessageEditState.edited,
          renderedContent: '<p>gamma</p>',
          isMeMessage: false,
        ),
      ));
      check(await db.searchStoredMessages(
        accountId,
        spec: const StoredMessageSearchSpec(positiveFtsMatch: '"alpha"'),
        limit: 10,
      )).isEmpty();
      check((await db.searchStoredMessages(
        accountId,
        spec: const StoredMessageSearchSpec(positiveFtsMatch: '"gamma"'),
        limit: 10,
      )).length).equals(1);

      // Move topic: old topic no longer matches, new topic matches.
      await db.transaction(() => applyMessageEffectToDb(
        db,
        accountId: accountId,
        epoch: 1,
        effect: MoveEffect(
          messageIds: const [10],
          origChannelId: 1,
          newChannelId: 1,
          origTopic: eg.t('initial topic'),
          newTopic: eg.t('relocated'),
          untrack: false,
          markMoved: true,
        ),
      ));
      check(await db.searchStoredMessages(
        accountId,
        spec: const StoredMessageSearchSpec(positiveFtsMatch: '"initial"'),
        limit: 10,
      )).isEmpty();
      check((await db.searchStoredMessages(
        accountId,
        spec: const StoredMessageSearchSpec(positiveFtsMatch: '"relocated"'),
        limit: 10,
      )).length).equals(1);

      // SubmessageEffect adding an option & editing question updates body_text.
      await db.transaction(() async {
        await applyMessageEffectToDb(
          db,
          accountId: accountId,
          epoch: 1,
          effect: SubmessageEffect(event: SubmessageEvent(
            id: 2,
            msgType: SubmessageType.widget,
            content: jsonEncode({'type': 'new_option', 'option': 'Banana', 'idx': 0}),
            messageId: 10,
            senderId: msg.senderId,
            submessageId: 501,
          )),
        );
        await applyMessageEffectToDb(
          db,
          accountId: accountId,
          epoch: 1,
          effect: SubmessageEffect(event: SubmessageEvent(
            id: 3,
            msgType: SubmessageType.widget,
            content: jsonEncode({'type': 'question', 'question': 'Second Q?'}),
            messageId: 10,
            senderId: msg.senderId,
            submessageId: 502,
          )),
        );
      });
      check((await db.searchStoredMessages(
        accountId,
        spec: const StoredMessageSearchSpec(positiveFtsMatch: '"banana" AND "second"'),
        limit: 10,
      )).length).equals(1);
    });

    test('MoveEffect ignores DM rows where channel_id IS NULL', () async {
      final (db, accountId) = await openWithAccount();
      final dm = eg.dmMessage(
        id: 21,
        from: eg.otherUser,
        to: [eg.selfUser],
        content: '<p>private note</p>',
      );
      await db.transaction(() => applyMessageEffectToDb(
        db,
        accountId: accountId,
        epoch: 1,
        effect: InsertEffect(message: dm, tracked: true),
        rawMessage: dm.toJson(),
      ));

      await db.transaction(() => applyMessageEffectToDb(
        db,
        accountId: accountId,
        epoch: 1,
        effect: MoveEffect(
          messageIds: const [21],
          origChannelId: 1,
          newChannelId: 2,
          origTopic: eg.t('old'),
          newTopic: eg.t('hijacked'),
          untrack: true,
          markMoved: true,
        ),
      ));

      final row = await (db.select(db.storedMessages)
        ..where((m) => m.accountId.equals(accountId) & m.id.equals(21))).getSingle();
      check(row.channelId).isNull();
      check(row.topic).isNull();
      check(row.topicKey).isNull();
      check(row.tracked).isTrue();
      check(await db.searchStoredMessages(
        accountId,
        spec: const StoredMessageSearchSpec(positiveFtsMatch: '"hijacked"'),
        limit: 10,
      )).isEmpty();
      final decoded = await loadMessage(db, accountId, 21);
      check(decoded).isA<DmMessage>();
    });

    test('MoveEffect applies only at matching origin and preserves topic case on channel-only move', () async {
      final (db, accountId) = await openWithAccount();
      final s1 = eg.stream(streamId: 1, name: 'one');
      final s2 = eg.stream(streamId: 2, name: 'two');
      final mUpper = eg.streamMessage(id: 31, stream: s1, topic: 'Alpha', content: '<p>u</p>');
      final mAlreadyMoved = eg.streamMessage(id: 32, stream: s2, topic: 'Other', content: '<p>o</p>');

      await db.transaction(() async {
        for (final m in [mUpper, mAlreadyMoved]) {
          await applyMessageEffectToDb(
            db,
            accountId: accountId,
            epoch: 1,
            effect: InsertEffect(message: m, tracked: true),
            rawMessage: m.toJson(),
          );
        }
      });

      // Channel-only move with origTopic == newTopic == 'alpha' moves 31 to channel 2
      // while keeping its 'Alpha' spelling, and ignores 32 (not at channel 1 / 'alpha').
      await db.transaction(() => applyMessageEffectToDb(
        db,
        accountId: accountId,
        epoch: 1,
        effect: MoveEffect(
          messageIds: const [31, 32],
          origChannelId: 1,
          newChannelId: 2,
          origTopic: eg.t('alpha'),
          newTopic: eg.t('alpha'),
          untrack: false,
          markMoved: false,
        ),
      ));

      final loaded31 = await loadMessage(db, accountId, 31) as StreamMessage;
      check(loaded31)
        ..streamId.equals(2)
        ..topic.equals(eg.t('Alpha'));
      final loaded32 = await loadMessage(db, accountId, 32) as StreamMessage;
      check(loaded32)
        ..streamId.equals(2)
        ..topic.equals(eg.t('Other'));
    });
  });
}
