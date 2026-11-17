import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:zulip/api/model/events.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/api/model/submessage.dart';
import 'package:zulip/model/message_effect.dart';

import '../api/model/model_checks.dart';
import '../example_data.dart' as eg;

void main() {
  group('messageEffectKindOf', () {
    test('classify representative events', () {
      check(messageEffectKindOf(eg.messageEvent(eg.streamMessage())))
        .equals(MessageEffectKind.insert);
      check(messageEffectKindOf(eg.updateMessageEditEvent(eg.streamMessage())))
        .equals(MessageEffectKind.updateMessage);
      check(messageEffectKindOf(eg.deleteMessageEvent([eg.streamMessage()])))
        .equals(MessageEffectKind.delete);
      check(messageEffectKindOf(UpdateMessageFlagsAddEvent(
        id: 1, flag: MessageFlag.read, messages: const [], all: true)))
        .equals(MessageEffectKind.flagAllRead);
      check(messageEffectKindOf(UpdateMessageFlagsAddEvent(
        id: 1, flag: MessageFlag.starred, messages: const [1], all: false)))
        .equals(MessageEffectKind.flag);
      check(messageEffectKindOf(UpdateMessageFlagsRemoveEvent(
        id: 1, flag: MessageFlag.starred, messages: const [1], messageDetails: null)))
        .equals(MessageEffectKind.flag);
      check(messageEffectKindOf(eg.reactionEvent(
        eg.unicodeEmojiReaction, ReactionOp.add, 1)))
        .equals(MessageEffectKind.reaction);
      check(messageEffectKindOf(eg.submessageEvent(
        1, eg.selfUser.userId, content: PollQuestionEventSubmessage(question: 'Q'))))
        .equals(MessageEffectKind.submessage);
      check(messageEffectKindOf(SubscriptionRemoveEvent(id: 1, channelIds: const [])))
        .equals(MessageEffectKind.channelUntrack);
      check(messageEffectKindOf(ChannelDeleteEvent(id: 1, channelIds: const [])))
        .equals(MessageEffectKind.channelPurge);
      check(messageEffectKindOf(HeartbeatEvent(id: 1)))
        .equals(MessageEffectKind.none);
    });
  });

  group('MessageEffect.applyToMessage idempotence', () {
    test('ContentEffect', () {
      final message = eg.streamMessage(id: 10, flags: []);
      const effect = ContentEffect(
        messageId: 10,
        flags: [MessageFlag.read, MessageFlag.starred],
        editState: MessageEditState.edited,
        renderedContent: '<p>updated</p>',
        isMeMessage: true,
      );
      effect.applyToMessage(message);
      effect.applyToMessage(message);
      check(message)
        ..flags.deepEquals([MessageFlag.read, MessageFlag.starred])
        ..editState.equals(MessageEditState.edited)
        ..content.equals('<p>updated</p>')
        ..isMeMessage.isTrue();
    });

    test('EditTimeEffect', () {
      final message = eg.streamMessage(id: 10, lastEditTimestamp: null);
      const effect = EditTimeEffect(messageIds: [10], editTimestamp: 123456);
      effect.applyToMessage(message);
      effect.applyToMessage(message);
      check(message.lastEditTimestamp).equals(123456);
    });

    test('MoveEffect', () {
      final stream1 = eg.stream(streamId: 1);
      final stream2 = eg.stream(streamId: 2);
      final message = eg.streamMessage(id: 10, stream: stream1, topic: 'old');
      final effect = MoveEffect(
        messageIds: const [10],
        origChannelId: stream1.streamId,
        newChannelId: stream2.streamId,
        origTopic: TopicName('old'),
        newTopic: TopicName('new'),
        untrack: false,
        markMoved: true,
      );
      effect.applyToMessage(message);
      effect.applyToMessage(message);
      check(message)
        ..streamId.equals(stream2.streamId)
        ..topic.equals(TopicName('new'))
        ..editState.equals(MessageEditState.moved);

      // A stale move naming a different origin leaves the message untouched.
      final staleMove = MoveEffect(
        messageIds: const [10],
        origChannelId: stream1.streamId,
        newChannelId: stream1.streamId,
        origTopic: TopicName('old'),
        newTopic: TopicName('reverted'),
        untrack: false,
        markMoved: true,
      );
      staleMove.applyToMessage(message);
      check(message)
        ..streamId.equals(stream2.streamId)
        ..topic.equals(TopicName('new'));
    });

    test('FlagEffect and FlagAllReadEffect', () {
      final message = eg.streamMessage(id: 10, flags: []);
      const addStar = FlagEffect(messageIds: [10], flag: MessageFlag.starred, add: true);
      addStar.applyToMessage(message);
      addStar.applyToMessage(message);
      check(message.flags).deepEquals([MessageFlag.starred]);

      const allRead = FlagAllReadEffect();
      allRead.applyToMessage(message);
      allRead.applyToMessage(message);
      check(message.flags).deepEquals([MessageFlag.starred, MessageFlag.read]);

      const removeStar = FlagEffect(messageIds: [10], flag: MessageFlag.starred, add: false);
      removeStar.applyToMessage(message);
      removeStar.applyToMessage(message);
      check(message.flags).deepEquals([MessageFlag.read]);
    });

    test('ReactionEffect', () {
      final message = eg.streamMessage(id: 10, reactions: []);
      final add = ReactionEffect(
        messageId: 10,
        op: ReactionOp.add,
        emojiName: 'thumbs_up',
        emojiCode: '1f44d',
        reactionType: ReactionType.unicodeEmoji,
        userId: eg.selfUser.userId,
      );
      add.applyToMessage(message);
      add.applyToMessage(message);
      check(message.reactions).isNotNull().total.equals(1);

      final remove = ReactionEffect(
        messageId: 10,
        op: ReactionOp.remove,
        emojiName: 'thumbs_up',
        emojiCode: '1f44d',
        reactionType: ReactionType.unicodeEmoji,
        userId: eg.selfUser.userId,
      );
      remove.applyToMessage(message);
      remove.applyToMessage(message);
      check(message.reactions).isNotNull().total.equals(0);
    });

    test('SubmessageEffect', () {
      final message = eg.streamMessage(
        id: 10,
        sender: eg.otherUser,
        submessages: [
          eg.submessage(
            senderId: eg.otherUser.userId,
            content: eg.pollWidgetData(question: 'Q', options: ['A', 'B']),
          ),
        ],
      );
      final event = eg.submessageEvent(
        10,
        eg.selfUser.userId,
        submessageId: 500,
        content: PollVoteEventSubmessage(
          key: PollEventSubmessage.optionKey(senderId: null, idx: 0),
          op: PollVoteOp.add,
        ),
      );
      final effect = SubmessageEffect(event: event);
      effect.applyToMessage(message);
      effect.applyToMessage(message);
      check(message.poll).isNotNull();
      check(message.poll!.options.first.voters).deepEquals({eg.selfUser.userId});
      // Also verify raw submessages were recorded once.
      check(jsonDecode(jsonEncode(Poll.toJson(message.poll))) as List<Object?>).length.equals(2);
    });
  });
}
