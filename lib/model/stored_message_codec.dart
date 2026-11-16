import 'dart:convert';

import 'package:drift/drift.dart';

import '../api/model/model.dart';
import 'message_database.dart';
import 'narrow.dart' show serverTopicFold;

/// Encoded row companions for a full message write.
class StoredMessageRecord {
  const StoredMessageRecord({
    required this.message,
    required this.body,
    required this.reactions,
    required this.submessages,
    required this.bodyBytes,
  });

  final StoredMessagesCompanion message;
  final StoredMessageBodiesCompanion body;
  final List<StoredReactionsCompanion> reactions;
  final List<StoredSubmessagesCompanion> submessages;
  final int bodyBytes;
}

/// Bitmask constants for [StoredMessages.flags].
abstract final class StoredMessageFlags {
  static const int read = 1 << 0;
  static const int starred = 1 << 1;
  static const int collapsed = 1 << 2;
  static const int hideLinkPreviews = 1 << 3;
  static const int mentioned = 1 << 4;
  static const int streamWildcardMentioned = 1 << 5;
  static const int topicWildcardMentioned = 1 << 6;
  static const int hasAlertWord = 1 << 7;
  static const int historical = 1 << 8;

  static const Map<String, int> bitByName = {
    'read': read,
    'starred': starred,
    'collapsed': collapsed,
    'hide_link_previews': hideLinkPreviews,
    'mentioned': mentioned,
    'stream_wildcard_mentioned': streamWildcardMentioned,
    'topic_wildcard_mentioned': topicWildcardMentioned,
    'has_alert_word': hasAlertWord,
    'historical': historical,
  };

  static const List<(int, String)> orderedBits = [
    (read, 'read'),
    (starred, 'starred'),
    (collapsed, 'collapsed'),
    (hideLinkPreviews, 'hide_link_previews'),
    (mentioned, 'mentioned'),
    (streamWildcardMentioned, 'stream_wildcard_mentioned'),
    (topicWildcardMentioned, 'topic_wildcard_mentioned'),
    (hasAlertWord, 'has_alert_word'),
    (historical, 'historical'),
  ];

  static (int bitmask, String? unknownJson) encode(List<String> rawFlags) {
    int mask = 0;
    List<String>? unknown;
    for (final raw in rawFlags) {
      final bit = bitByName[raw];
      if (bit != null) {
        mask |= bit;
      } else {
        (unknown ??= []).add(raw);
      }
    }
    return (mask, unknown == null ? null : jsonEncode(unknown));
  }

  static List<String> decode(int bitmask, String? unknownJson) {
    final result = <String>[
      for (final (bit, name) in orderedBits)
        if ((bitmask & bit) != 0) name,
    ];
    if (unknownJson != null) {
      final unknown = jsonDecode(unknownJson) as List<dynamic>;
      for (final u in unknown) {
        result.add(u as String);
      }
    }
    return result;
  }
}

/// Encodes and decodes [Message]s to/from [MessageDatabase] rows without
/// going through `Message.toJson`.
abstract final class StoredMessageCodec {
  static const Set<String> _strippedKeys = {
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
  };

  /// Canonical DM key for a recipient set: sorted recipient IDs, comma-joined.
  static String dmKeyFromRecipientIds(Iterable<int> allRecipientIds) {
    final ids = allRecipientIds.toList()..sort();
    return ids.join(',');
  }

  /// Canonical DM key for a [DmMessage]: sorted `allRecipientIds`, comma-joined.
  static String dmKey(DmMessage message) =>
    dmKeyFromRecipientIds(message.allRecipientIds);

  /// Encode a [Message] and its raw server JSON map into database companions.
  static StoredMessageRecord encode({
    required int accountId,
    required Message message,
    required Map<String, dynamic> rawMap,
    required int epoch,
    required bool tracked,
    List<String>? rawFlagsOverride,
  }) {
    final rawFlags = rawFlagsOverride
      ?? (rawMap['flags'] as List<dynamic>? ?? const []).cast<String>();
    final (flagsMask, unknownFlagsJson) = StoredMessageFlags.encode(rawFlags);

    final bool displayRecipientCleared =
      message is StreamMessage && message.conversation.displayRecipient == null;
    final stripped = <String, dynamic>{};
    rawMap.forEach((key, value) {
      if (!_strippedKeys.contains(key)) {
        stripped[key] = value;
      }
    });
    if (displayRecipientCleared) {
      // Never write JSON null for display_recipient so StreamConversation.fromJson
      // won't throw disallowNullValue on decode.
      stripped['display_recipient'] = '';
    }

    final jsonBytes = Uint8List.fromList(utf8.encode(jsonEncode(stripped)));
    final bodyBytes = utf8.encode(message.content).length + jsonBytes.length;

    final int? channelId;
    final String? topic;
    final String? topicKey;
    final String? dmKeyValue;
    switch (message) {
      case StreamMessage():
        channelId = message.streamId;
        topic = message.topic.apiName;
        topicKey = serverTopicFold(message.topic.apiName);
        dmKeyValue = null;
      case DmMessage():
        channelId = null;
        topic = null;
        topicKey = null;
        dmKeyValue = dmKey(message);
    }

    final reactionsList = rawMap['reactions'] as List<dynamic>? ?? const [];
    final reactions = <StoredReactionsCompanion>[];
    for (int i = 0; i < reactionsList.length; i++) {
      final r = reactionsList[i] as Map<String, dynamic>;
      final userId = (r['user_id'] as int?)
        ?? ((r['user'] as Map<String, dynamic>)['id'] as int);
      reactions.add(StoredReactionsCompanion.insert(
        accountId: accountId,
        messageId: message.id,
        seq: i,
        userId: userId,
        reactionType: r['reaction_type'] as String,
        emojiCode: r['emoji_code'] as String,
        emojiName: r['emoji_name'] as String,
      ));
    }

    final submessagesList = rawMap['submessages'] as List<dynamic>? ?? const [];
    final submessages = <StoredSubmessagesCompanion>[];
    for (final rawSub in submessagesList) {
      final s = rawSub as Map<String, dynamic>;
      submessages.add(StoredSubmessagesCompanion.insert(
        accountId: accountId,
        submessageId: s['id'] as int,
        messageId: message.id,
        senderId: s['sender_id'] as int,
        msgType: s['msg_type'] as String,
        content: s['content'] as String,
      ));
    }

    return StoredMessageRecord(
      bodyBytes: bodyBytes,
      message: StoredMessagesCompanion.insert(
        accountId: accountId,
        id: message.id,
        channelId: Value(channelId),
        topic: Value(topic),
        topicKey: Value(topicKey),
        dmKey: Value(dmKeyValue),
        senderId: message.senderId,
        timestamp: message.timestamp,
        flags: flagsMask,
        unknownFlags: Value(unknownFlagsJson),
        isMeMessage: message.isMeMessage,
        editState: message.editState.index,
        lastEditTimestamp: Value(message.lastEditTimestamp),
        displayRecipientCleared: displayRecipientCleared,
        epoch: epoch,
        tracked: tracked,
        bodyBytes: bodyBytes,
      ),
      body: StoredMessageBodiesCompanion.insert(
        accountId: accountId,
        messageId: message.id,
        content: message.content,
        json: jsonBytes,
      ),
      reactions: reactions,
      submessages: submessages,
    );
  }

  /// Decode a [Message] from its stored rows, optionally overlaying [readOverride]
  /// and [starredOverride] from in-memory `Unreads` / `starredMessages`.
  static Message decode({
    required StoredMessage row,
    required StoredMessageBody body,
    required List<StoredReaction> reactions,
    required List<StoredSubmessage> submessages,
    bool? readOverride,
    bool? starredOverride,
  }) {
    final map = jsonDecode(utf8.decode(body.json)) as Map<String, dynamic>;
    map['id'] = row.id;
    map['type'] = row.channelId != null ? 'stream' : 'private';
    if (row.channelId != null) {
      map['stream_id'] = row.channelId;
      map['subject'] = row.topic ?? '';
    }
    map['content'] = body.content;
    map['sender_id'] = row.senderId;
    map['timestamp'] = row.timestamp;
    map['is_me_message'] = row.isMeMessage;
    if (row.lastEditTimestamp != null) {
      map['last_edit_timestamp'] = row.lastEditTimestamp;
    } else {
      map.remove('last_edit_timestamp');
    }

    int effectiveFlags = row.flags;
    if (readOverride != null) {
      effectiveFlags = readOverride
        ? (effectiveFlags | StoredMessageFlags.read)
        : (effectiveFlags & ~StoredMessageFlags.read);
    }
    if (starredOverride != null) {
      effectiveFlags = starredOverride
        ? (effectiveFlags | StoredMessageFlags.starred)
        : (effectiveFlags & ~StoredMessageFlags.starred);
    }
    map['flags'] = StoredMessageFlags.decode(effectiveFlags, row.unknownFlags);

    final sortedReactions = reactions.toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    map['reactions'] = [
      for (final r in sortedReactions)
        {
          'user_id': r.userId,
          'reaction_type': r.reactionType,
          'emoji_code': r.emojiCode,
          'emoji_name': r.emojiName,
        },
    ];

    final sortedSubmessages = submessages.toList()
      ..sort((a, b) => a.submessageId.compareTo(b.submessageId));
    map['submessages'] = [
      for (final s in sortedSubmessages)
        {
          'id': s.submessageId,
          'sender_id': s.senderId,
          'msg_type': s.msgType,
          'content': s.content,
        },
    ];

    final message = Message.fromJson(map);
    message.editState = MessageEditState.values[row.editState];
    if (row.displayRecipientCleared && message is StreamMessage) {
      message.conversation = StreamConversation(
        message.streamId,
        message.topic,
        displayRecipient: null,
      );
    }
    return message;
  }
}
