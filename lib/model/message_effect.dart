import '../api/model/events.dart';
import '../api/model/model.dart';
import '../log.dart';
import 'narrow.dart' show serverTopicFold;

/// Classification of every [Event] subtype for message-effect handling.
///
/// Exhaustive over [Event], so adding a new [Event] subtype does not compile
/// until it is classified here.
enum MessageEffectKind {
  none,
  insert,
  updateMessage,
  delete,
  flag,
  flagAllRead,
  reaction,
  submessage,
  channelUntrack,
  channelPurge,
  channelAccessCheck,
}

MessageEffectKind messageEffectKindOf(Event event) {
  return switch (event) {
    MessageEvent() => MessageEffectKind.insert,
    UpdateMessageEvent() => MessageEffectKind.updateMessage,
    DeleteMessageEvent() => MessageEffectKind.delete,
    UpdateMessageFlagsAddEvent(all: true) => MessageEffectKind.flagAllRead,
    UpdateMessageFlagsAddEvent() ||
    UpdateMessageFlagsRemoveEvent() => MessageEffectKind.flag,
    ReactionEvent() => MessageEffectKind.reaction,
    SubmessageEvent() => MessageEffectKind.submessage,
    SubscriptionRemoveEvent() => MessageEffectKind.channelUntrack,
    SubscriptionAddEvent() ||
    SubscriptionUpdateEvent() ||
    SubscriptionPeerAddEvent() ||
    SubscriptionPeerRemoveEvent() => MessageEffectKind.none,
    ChannelDeleteEvent() => MessageEffectKind.channelPurge,
    ChannelUpdateEvent() => MessageEffectKind.channelAccessCheck,
    ChannelCreateEvent() => MessageEffectKind.none,
    UserGroupEvent() => MessageEffectKind.channelAccessCheck,
    RealmUserUpdateEvent() => MessageEffectKind.channelAccessCheck,
    RealmUserAddEvent() ||
    RealmUserRemoveEvent() => MessageEffectKind.none,
    HeartbeatEvent() ||
    TypingEvent() ||
    PresenceEvent() ||
    UserTopicEvent() ||
    MutedUsersEvent() ||
    UserStatusEvent() ||
    RealmEmojiEvent() ||
    AlertWordsEvent() ||
    UserSettingsUpdateEvent() ||
    DeviceEvent() ||
    CustomProfileFieldsEvent() ||
    SavedSnippetsEvent() ||
    ChannelFolderEvent() ||
    UnexpectedEvent() => MessageEffectKind.none,
  };
}

/// An idempotent change to message state produced by an event.
sealed class MessageEffect {
  const MessageEffect();

  /// Applies this effect to [message] in memory, if applicable.
  ///
  /// Idempotent: applying the same effect twice to the same [Message]
  /// produces the same state as applying it once.
  void applyToMessage(Message message);
}

final class InsertEffect extends MessageEffect {
  const InsertEffect({required this.message, required this.tracked});

  final Message message;
  final bool tracked;

  @override
  void applyToMessage(Message message) {
    // Insertion is a store-level operation, not an in-place mutation.
  }
}

final class ContentEffect extends MessageEffect {
  const ContentEffect({
    required this.messageId,
    required this.flags,
    this.editState,
    this.renderedContent,
    this.isMeMessage,
  });

  final int messageId;
  final List<MessageFlag> flags;
  final MessageEditState? editState;
  final String? renderedContent;
  final bool? isMeMessage;

  @override
  void applyToMessage(Message message) {
    if (message.id != messageId) return;
    message.flags = flags;
    if (editState != null) {
      message.editState = editState!;
    }
    if (renderedContent != null) {
      assert(message.contentType == 'text/html',
        'Message contentType was ${message.contentType}; expected text/html.');
      message.content = renderedContent!;
    }
    if (isMeMessage != null) {
      message.isMeMessage = isMeMessage!;
    }
  }
}

final class EditTimeEffect extends MessageEffect {
  const EditTimeEffect({
    required this.messageIds,
    required this.editTimestamp,
  });

  final List<int> messageIds;
  final int editTimestamp;

  @override
  void applyToMessage(Message message) {
    if (!messageIds.contains(message.id)) return;
    message.lastEditTimestamp = editTimestamp;
  }
}

final class MoveEffect extends MessageEffect {
  const MoveEffect({
    required this.messageIds,
    required this.origChannelId,
    required this.newChannelId,
    required this.origTopic,
    required this.newTopic,
    required this.untrack,
    required this.markMoved,
  });

  final List<int> messageIds;
  final int origChannelId;
  final int newChannelId;
  final TopicName origTopic;
  final TopicName newTopic;
  final bool untrack;
  final bool markMoved;

  @override
  void applyToMessage(Message message) {
    if (!messageIds.contains(message.id)) return;
    if (message is! StreamMessage) {
      assert(debugLog('Bad UpdateMessageEvent: channel/topic move on a DM')); // TODO(log)
      return;
    }
    if (message.conversation.streamId != origChannelId
        || serverTopicFold(message.conversation.topic.apiName)
            != serverTopicFold(origTopic.apiName)) {
      return;
    }
    if (newChannelId != origChannelId) {
      message.conversation.streamId = newChannelId;
      // See [StreamConversation.displayRecipient] on why the invalidation is needed.
      message.conversation.displayRecipient = null;
    }
    if (newTopic != origTopic) {
      message.conversation.topic = newTopic;
    }
    if (markMoved && message.editState == MessageEditState.none) {
      message.editState = MessageEditState.moved;
    }
  }
}

final class DeleteEffect extends MessageEffect {
  const DeleteEffect({required this.messageIds});

  final List<int> messageIds;

  @override
  void applyToMessage(Message message) {
    // Deletion removes the message from the store, not mutating it in place.
  }
}

/// Local forget of messages omitted from an authoritative fetch range.
final class ForgetEffect extends MessageEffect {
  const ForgetEffect({required this.messageIds});

  final List<int> messageIds;

  @override
  void applyToMessage(Message message) {
    // Forgetting marks location unknown in the store, not mutating [Message].
  }
}

final class FlagEffect extends MessageEffect {
  const FlagEffect({
    required this.messageIds,
    required this.flag,
    required this.add,
  });

  final List<int> messageIds;
  final MessageFlag flag;
  final bool add;

  @override
  void applyToMessage(Message message) {
    if (!messageIds.contains(message.id)) return;
    if (add) {
      if (!message.flags.contains(flag)) {
        message.flags = [...message.flags, flag];
      }
    } else {
      if (message.flags.contains(flag)) {
        message.flags = [for (final f in message.flags) if (f != flag) f];
      }
    }
  }
}

final class FlagAllReadEffect extends MessageEffect {
  const FlagAllReadEffect();

  @override
  void applyToMessage(Message message) {
    if (!message.flags.contains(MessageFlag.read)) {
      message.flags = [...message.flags, MessageFlag.read];
    }
  }
}

final class ReactionEffect extends MessageEffect {
  const ReactionEffect({
    required this.messageId,
    required this.op,
    required this.emojiName,
    required this.emojiCode,
    required this.reactionType,
    required this.userId,
  });

  final int messageId;
  final ReactionOp op;
  final String emojiName;
  final String emojiCode;
  final ReactionType reactionType;
  final int userId;

  @override
  void applyToMessage(Message message) {
    if (message.id != messageId) return;
    switch (op) {
      case ReactionOp.add:
        (message.reactions ??= Reactions([])).add(Reaction(
          emojiName: emojiName,
          emojiCode: emojiCode,
          reactionType: reactionType,
          userId: userId,
        ));
      case ReactionOp.remove:
        if (message.reactions == null) { // TODO(log)
          return;
        }
        message.reactions!.remove(
          reactionType: reactionType,
          emojiCode: emojiCode,
          userId: userId,
        );
    }
  }
}

final class SubmessageEffect extends MessageEffect {
  const SubmessageEffect({required this.event});

  final SubmessageEvent event;

  @override
  void applyToMessage(Message message) {
    if (message.id != event.messageId) return;
    final poll = message.poll;
    if (poll == null) {
      assert(debugLog('Missing poll for submessage event:\n${event.content}')); // TODO(log)
      return;
    }
    poll.handleSubmessageEvent(event);
  }
}

final class ChannelUntrackEffect extends MessageEffect {
  const ChannelUntrackEffect({required this.channelId});

  final int channelId;

  @override
  void applyToMessage(Message message) {
    // Untracking updates store metadata, not the [Message] object.
  }
}

final class ChannelPurgeEffect extends MessageEffect {
  const ChannelPurgeEffect({required this.channelId});

  final int channelId;

  @override
  void applyToMessage(Message message) {
    // Purging removes the channel's messages from the store.
  }
}
