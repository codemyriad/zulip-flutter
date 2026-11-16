import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
import 'package:drift/native.dart';
import 'package:test/scaffolding.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/model/message_database.dart';
import 'package:zulip/model/message_effect.dart';
import 'package:zulip/model/stored_message_codec.dart';

import '../example_data.dart' as eg;

void main() {
  Future<(MessageDatabase, int)> openWithAccount() async {
    final db = MessageDatabase(NativeDatabase.memory(setup: configureMessageDbPragmas));
    addTearDown(db.close);
    await db.into(db.messageDbAccounts).insert(MessageDbAccountsCompanion.insert(
      realmUrl: 'https://chat.example.org',
      userId: 100,
      formatVersion: MessageDatabase.currentFormatVersion,
      epoch: 1,
      appliedThroughEventId: const Value(1),
      eventHighWater: 100,
    ));
    return (db, 1);
  }

  Future<Message> roundTrip(
    MessageDatabase db,
    int accountId,
    StoredMessageRecord record, {
    bool? readOverride,
    bool? starredOverride,
  }) async {
    await db.into(db.storedMessages).insert(record.message);
    await db.into(db.storedMessageBodies).insert(record.body);
    for (final r in record.reactions) {
      await db.into(db.storedReactions).insert(r);
    }
    for (final s in record.submessages) {
      await db.into(db.storedSubmessages).insert(s);
    }

    final id = record.message.id.value;
    final row = await (db.select(db.storedMessages)
      ..where((m) => m.accountId.equals(accountId) & m.id.equals(id))).getSingle();
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
      readOverride: readOverride,
      starredOverride: starredOverride,
    );
  }

  group('StoredMessageCodec', () {
    test('round-trip stream message with moved editState, unknown flags, reactions, poll, and stripped keys', () async {
      final (db, accountId) = await openWithAccount();

      final rawMap = <String, dynamic>{
        'id': 42,
        'type': 'stream',
        'stream_id': 7,
        'subject': 'Test Topic',
        'display_recipient': 'general',
        'content': '<p>hello</p>',
        'content_type': 'text/html',
        'sender_id': 10,
        'sender_email': 'alice@example.org',
        'sender_full_name': 'Alice',
        'sender_realm_str': 'example',
        'client': 'website',
        'timestamp': 1700000000,
        'is_me_message': true,
        'last_edit_timestamp': 1700000100,
        'edit_history': [
          {'user_id': 10, 'timestamp': 1700000100, 'prev_topic': 'Old', 'topic': 'Test Topic'},
        ],
        'flags': ['read', 'mentioned', 'some_future_flag'],
        'match_content': '<p>match</p>',
        'match_subject': 'match',
        'local_message_id': 'loc-1',
        'future_field': {'nested': 123},
        'reactions': [
          {
            'user_id': 10,
            'reaction_type': 'unicode_emoji',
            'emoji_code': '1f44d',
            'emoji_name': '+1',
          },
          {
            'user_id': 11,
            'reaction_type': 'realm_emoji',
            'emoji_code': '99',
            'emoji_name': 'party',
          },
        ],
        'submessages': [
          {
            'id': 501,
            'sender_id': 10,
            'msg_type': 'widget',
            'content': jsonEncode({
              'widget_type': 'poll',
              'extra_data': {'question': 'Lunch?', 'options': ['Pizza', 'Sushi']},
            }),
          },
          {
            'id': 502,
            'sender_id': 11,
            'msg_type': 'widget',
            'content': jsonEncode({'type': 'vote', 'key': 'canned,0', 'vote': 1}),
          },
        ],
      };

      final parsed = Message.fromJson(rawMap);
      check(parsed.editState).equals(MessageEditState.moved);

      final record = StoredMessageCodec.encode(
        accountId: accountId,
        message: parsed,
        rawMap: rawMap,
        epoch: 1,
        tracked: true,
      );

      // Verify stripped keys are absent from stored JSON blob.
      final storedMap = jsonDecode(utf8.decode(record.body.json.value)) as Map<String, dynamic>;
      for (final stripped in [
        'content',
        'subject',
        'stream_id',
        'flags',
        'reactions',
        'submessages',
        'match_content',
        'match_subject',
        'last_edit_timestamp',
        'is_me_message',
        'edit_history',
        'local_message_id',
      ]) {
        check(storedMap.containsKey(stripped)).isFalse();
      }
      check(storedMap['future_field']).isA<Map<String, dynamic>>().deepEquals({'nested': 123});

      final decoded = await roundTrip(db, accountId, record) as StreamMessage;
      check(decoded.id).equals(42);
      check(decoded.streamId).equals(7);
      check(decoded.topic.apiName).equals('Test Topic');
      check(decoded.displayRecipient).equals('general');
      check(decoded.content).equals('<p>hello</p>');
      check(decoded.isMeMessage).isTrue();
      check(decoded.editState).equals(MessageEditState.moved);
      check(decoded.lastEditTimestamp).equals(1700000100);
      check(decoded.flags).deepEquals([
        MessageFlag.read,
        MessageFlag.mentioned,
        MessageFlag.unknown,
      ]);
      check(decoded.reactions).isNotNull().has((r) => r.total, 'total').equals(2);
      check(decoded.poll).isNotNull()
        ..has((p) => p.question, 'question').equals('Lunch?')
        ..has((p) => p.options.length, 'options.length').equals(2)
        ..has((p) => p.options.first.voters, 'voters').deepEquals({11});
    });

    test('preserve cleared displayRecipient after cross-channel move without disallowNullValue', () async {
      final (db, accountId) = await openWithAccount();

      final msg = eg.streamMessage(id: 50, stream: eg.stream(streamId: 3), topic: 't');
      final rawMap = msg.toJson();
      MoveEffect(
        messageIds: const [50],
        origChannelId: 3,
        newChannelId: 4,
        origTopic: eg.t('t'),
        newTopic: eg.t('t'),
        untrack: false,
        markMoved: false,
      ).applyToMessage(msg);
      check(msg.displayRecipient).isNull();

      final record = StoredMessageCodec.encode(
        accountId: accountId,
        message: msg,
        rawMap: rawMap,
        epoch: 1,
        tracked: false,
      );
      check(record.message.displayRecipientCleared.value).isTrue();

      final decoded = await roundTrip(db, accountId, record) as StreamMessage;
      check(decoded.displayRecipient).isNull();
    });

    test('round-trips DM message with canonical dmKey and overlays read/starred overrides', () async {
      final (db, accountId) = await openWithAccount();

      final selfUser = eg.user(userId: 100);
      final otherUser = eg.user(userId: 50);
      final dm = eg.dmMessage(id: 60, from: otherUser, to: [selfUser]);
      final rawMap = dm.toJson();

      final record = StoredMessageCodec.encode(
        accountId: accountId,
        message: dm,
        rawMap: rawMap,
        epoch: 1,
        tracked: true,
        rawFlagsOverride: const ['mentioned'],
      );
      check(record.message.dmKey.value).equals('50,100');

      final decoded = await roundTrip(
        db,
        accountId,
        record,
        readOverride: true,
        starredOverride: true,
      ) as DmMessage;
      check(decoded.allRecipientIds).deepEquals([50, 100]);
      check(decoded.flags).contains(MessageFlag.read);
      check(decoded.flags).contains(MessageFlag.starred);
      check(decoded.flags).contains(MessageFlag.mentioned);
    });
  });
}
