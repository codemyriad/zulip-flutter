import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/api/model/submessage.dart';
import 'package:zulip/model/cached_messages.dart';

import '../api/model/model_checks.dart';
import '../api/model/submessage_checks.dart';
import '../example_data.dart' as eg;
import '../stdlib_checks.dart';

void main() {
  /// The message's API JSON, but without the poll,
  /// which [Message.toJson] encodes only in debug mode, and partially;
  /// see [checkRoundTrip].
  Map<String, dynamic> toJsonSansPoll(Message message) =>
    deepToJson(message) as Map<String, dynamic>..remove('submessages');

  /// Check that [message] comes back equal from [encodeCachedMessages]
  /// and [decodeCachedMessages].
  Message checkRoundTrip(Message message) {
    final data = encodeCachedMessages([message]);
    final decoded = decodeCachedMessages(data).single;
    check(decoded).not((it) => it.identicalTo(message));
    check(decoded.runtimeType).equals(message.runtimeType);
    check(toJsonSansPoll(decoded)).deepEquals(toJsonSansPoll(message));
    check(decoded)
      ..editState.equals(message.editState)
      ..lastEditTimestamp.equals(message.lastEditTimestamp)
      ..flags.deepEquals(message.flags);
    switch (message) {
      case StreamMessage():
        check(decoded).isA<StreamMessage>().conversation
          ..streamId.equals(message.conversation.streamId)
          ..topic.equals(message.conversation.topic)
          ..displayRecipient.equals(message.conversation.displayRecipient);
      case DmMessage():
        check(decoded).isA<DmMessage>().conversation
          .allRecipientIds.deepEquals(message.conversation.allRecipientIds);
    }
    if (message.reactions case final reactions?) {
      check(decoded.reactions).isNotNull()
        ..total.equals(reactions.total)
        ..aggregated.deepEquals(reactions.aggregated.map((r) =>
          (Subject<Object?> it) => it.isA<ReactionWithVotes>()
            ..reactionType.equals(r.reactionType)
            ..emojiCode.equals(r.emojiCode)
            ..emojiName.equals(r.emojiName)
            ..userIds.deepEquals(r.userIds)));
    } else {
      check(decoded.reactions).isNull();
    }
    if (message.poll case final poll?) {
      check(decoded.poll).isNotNull()
        ..not((it) => it.identicalTo(poll))
        ..messageSenderId.equals(poll.messageSenderId)
        ..question.equals(poll.question)
        ..options.deepEquals(poll.options.map((option) =>
          (Subject<Object?> it) => it.isA<PollOption>()
            ..key.equals(option.key)
            ..text.equals(option.text)
            ..voters.deepEquals(option.voters)));
    } else {
      check(decoded.poll).isNull();
    }
    // Encoding again gives the same data.
    check(encodeCachedMessages([decoded])).deepEquals(data);
    return decoded;
  }

  group('round trip', () {
    test('stream message', () {
      checkRoundTrip(eg.streamMessage());
    });

    test('stream message, empty topic', () {
      checkRoundTrip(eg.streamMessage(topic: ''));
    });

    test('stream message, resolved topic', () {
      checkRoundTrip(eg.streamMessage(topic: '✔ some topic'));
    });

    test('stream message with no display recipient, as after a move', () {
      final message = eg.streamMessage();
      message.conversation.displayRecipient = null;
      checkRoundTrip(message);
    });

    test('DM, 1:1', () {
      checkRoundTrip(eg.dmMessage(from: eg.otherUser, to: [eg.selfUser]));
    });

    test('DM, group', () {
      checkRoundTrip(eg.dmMessage(from: eg.thirdUser,
        to: [eg.selfUser, eg.otherUser]));
    });

    test('DM, self-1:1', () {
      checkRoundTrip(eg.dmMessage(from: eg.selfUser, to: []));
    });

    test('edited', () {
      final message = eg.streamMessage(lastEditTimestamp: 1678139700);
      check(message).editState.equals(MessageEditState.edited);
      checkRoundTrip(message);
    });

    test('moved, as from an event', () {
      // [Message.fromJson] would compute "edited" from this data alone.
      final message = eg.streamMessage(lastEditTimestamp: 1678139700);
      message.editState = MessageEditState.moved;
      checkRoundTrip(message);
    });

    test('moved, from edit history', () {
      final message = StreamMessage.fromJson({
        ...deepToJson(eg.streamMessage()) as Map<String, dynamic>,
        'last_edit_timestamp': 1678139700,
        'edit_history': [{'prev_topic': 'old topic', 'topic': 'new topic',
          'timestamp': 1678139700, 'user_id': eg.otherUser.userId}],
      });
      check(message).editState.equals(MessageEditState.moved);
      checkRoundTrip(message);
    });

    test('resolved but not otherwise edited', () {
      final message = StreamMessage.fromJson({
        ...deepToJson(eg.streamMessage(topic: '✔ topic')) as Map<String, dynamic>,
        'last_edit_timestamp': 1678139700,
        'edit_history': [{'prev_topic': 'topic', 'topic': '✔ topic',
          'timestamp': 1678139700, 'user_id': eg.otherUser.userId}],
      });
      check(message).editState.equals(MessageEditState.none);
      checkRoundTrip(message);
    });

    test('with reactions', () {
      checkRoundTrip(eg.streamMessage(reactions: [
        eg.unicodeEmojiReaction,
        eg.realmEmojiReaction,
        eg.zulipExtraEmojiReaction,
        Reaction(emojiName: 'thumbs_up', emojiCode: '1f44d',
          reactionType: ReactionType.unicodeEmoji, userId: eg.otherUser.userId),
        Reaction(emojiName: 'thumbs_up', emojiCode: '1f44d',
          reactionType: ReactionType.unicodeEmoji, userId: eg.thirdUser.userId),
      ]));
    });

    test('with many reactions, tied in votes', () {
      checkRoundTrip(eg.streamMessage(reactions: [
        for (int i = 0; i < 40; i++)
          Reaction(emojiName: 'emoji$i', emojiCode: '$i',
            reactionType: ReactionType.realmEmoji, userId: eg.selfUser.userId),
      ]));
    });

    test('with reactions changed by events', () {
      final message = eg.streamMessage(reactions: [eg.unicodeEmojiReaction]);
      message.reactions!.add(eg.realmEmojiReaction);
      message.reactions!.remove(
        reactionType: eg.unicodeEmojiReaction.reactionType,
        emojiCode: eg.unicodeEmojiReaction.emojiCode,
        userId: eg.unicodeEmojiReaction.userId);
      checkRoundTrip(message);
    });

    test('with flags, including unknown', () {
      final message = StreamMessage.fromJson({
        ...deepToJson(eg.streamMessage()) as Map<String, dynamic>,
        'flags': ['read', 'starred', 'mentioned', 'has_alert_word',
          'some_future_flag'],
      });
      check(message).flags.deepEquals([MessageFlag.read, MessageFlag.starred,
        MessageFlag.mentioned, MessageFlag.hasAlertWord, MessageFlag.unknown]);
      checkRoundTrip(message);
    });

    test('with match fields', () {
      checkRoundTrip(eg.streamMessage(
        matchContent: '<p><span class="highlight">hello</span></p>',
        matchTopic: '<span class="highlight">hello</span> world'));
    });

    test('/me message', () {
      checkRoundTrip(StreamMessage.fromJson({
        ...deepToJson(eg.streamMessage()) as Map<String, dynamic>,
        'is_me_message': true,
      }));
    });

    group('poll', () {
      StreamMessage pollMessage({List<Submessage> events = const []}) {
        return eg.streamMessage(sender: eg.selfUser, submessages: [
          eg.submessage(senderId: eg.selfUser.userId,
            content: eg.pollWidgetData(question: 'Question?',
              // The duplicate is dropped, leaving a gap in the indexes.
              options: ['a', 'b', 'a', 'c'])),
          ...events,
        ]);
      }

      Submessage vote(int voterId, PollOptionKey key, PollVoteOp op) =>
        eg.submessage(senderId: voterId,
          content: PollVoteEventSubmessage(key: key, op: op));

      test('without votes', () {
        checkRoundTrip(pollMessage());
      });

      test('with votes, added options, and an edited question', () {
        final message = pollMessage(events: [
          eg.submessage(senderId: eg.otherUser.userId,
            content: PollNewOptionEventSubmessage(option: 'd', idx: 1)),
          eg.submessage(senderId: eg.selfUser.userId,
            content: PollQuestionEventSubmessage(question: 'New question?')),
          vote(eg.otherUser.userId, 'canned,0', PollVoteOp.add),
          vote(eg.thirdUser.userId, 'canned,0', PollVoteOp.add),
          vote(eg.selfUser.userId, '${eg.otherUser.userId},1', PollVoteOp.add),
          vote(eg.thirdUser.userId, 'canned,3', PollVoteOp.add),
          vote(eg.thirdUser.userId, 'canned,3', PollVoteOp.remove),
        ]);
        check(message.poll).isNotNull()
          ..question.equals('New question?')
          ..options.length.equals(4);
        checkRoundTrip(message);
      });

      test('with votes from events after parsing', () {
        final message = pollMessage();
        message.poll!.handleSubmessageEvent(eg.submessageEvent(
          message.id, eg.otherUser.userId,
          content: PollVoteEventSubmessage(key: 'canned,1', op: PollVoteOp.add)));
        checkRoundTrip(message);
      });

      test('restored poll handles later events', () {
        final decoded = checkRoundTrip(pollMessage());
        final poll = decoded.poll!;

        poll.handleSubmessageEvent(eg.submessageEvent(
          decoded.id, eg.otherUser.userId,
          content: PollVoteEventSubmessage(key: 'canned,3', op: PollVoteOp.add)));
        // An option whose text is already taken is ignored.
        poll.handleSubmessageEvent(eg.submessageEvent(
          decoded.id, eg.otherUser.userId,
          content: PollNewOptionEventSubmessage(option: 'b', idx: 1)));
        poll.handleSubmessageEvent(eg.submessageEvent(
          decoded.id, eg.otherUser.userId,
          content: PollNewOptionEventSubmessage(option: 'e', idx: 2)));
        check(poll.options).deepEquals(<Condition<Object?>>[
          (it) => it.isA<PollOption>()..key.equals('canned,0')..voters.isEmpty(),
          (it) => it.isA<PollOption>()..key.equals('canned,1')..voters.isEmpty(),
          (it) => it.isA<PollOption>()..key.equals('canned,3')
                                      ..voters.deepEquals([eg.otherUser.userId]),
          (it) => it.isA<PollOption>()..key.equals('${eg.otherUser.userId},2')
                                      ..text.equals('e'),
        ]);
      });
    });

    test('several messages, in order', () {
      final messages = <Message>[
        eg.streamMessage(),
        eg.dmMessage(from: eg.otherUser, to: [eg.selfUser]),
        eg.streamMessage(topic: '', lastEditTimestamp: 1678139700),
      ];
      final decoded = decodeCachedMessages(encodeCachedMessages(messages));
      check(decoded.map(toJsonSansPoll))
        .deepEquals(messages.map(toJsonSansPoll));
    });

    test('no messages', () {
      check(decodeCachedMessages(encodeCachedMessages([]))).isEmpty();
    });
  });

  group('decode bad data', () {
    test('a getMessages response, as stored by earlier versions', () {
      final data = utf8.encode(jsonEncode(eg.newestGetMessagesResult(
        foundOldest: true, messages: [eg.streamMessage()]).toJson()));
      check(() => decodeCachedMessages(data)).throws<FormatException>();
    });

    test('unknown version', () {
      final data = utf8.encode(jsonEncode({
        'version': kCachedMessagesFormatVersion + 1,
        'messages': <Object?>[],
      }));
      check(() => decodeCachedMessages(data)).throws<FormatException>();
    });

    test('not an object', () {
      check(() => decodeCachedMessages(utf8.encode('[]')))
        .throws<FormatException>();
    });

    test('not JSON', () {
      check(() => decodeCachedMessages(utf8.encode('{')))
        .throws<FormatException>();
    });
  });
}
