import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../api/model/model.dart';
import '../api/model/submessage.dart';
import 'channel.dart';
import 'message_coverage.dart';
import 'message_database.dart';
import 'message_effect.dart';
import 'narrow.dart';
import 'stored_message_codec.dart';

/// Convert [message] and an optional raw server JSON map into a mutable JSON map
/// suitable for [StoredMessageCodec.encode].
Map<String, dynamic> rawMapOfMessage(
  Message message,
  Map<String, Object?>? rawMessageMap,
) {
  if (rawMessageMap != null) return rawMessageMap.cast<String, dynamic>();
  return jsonDecode(jsonEncode(message)) as Map<String, dynamic>;
}

/// Extract scope filter values `(channelId, topicKey, dmKey)` for a coverage [narrow].
(int? channelId, String? topicKey, String? dmKey) scopeFiltersForNarrow(Narrow narrow) {
  return switch (narrow) {
    ChannelNarrow(:final channelId) => (channelId, null, null),
    TopicNarrow(:final channelId, :final topic) =>
      (channelId, serverTopicFold(topic.apiName), null),
    DmNarrow(:final allRecipientIds) =>
      (null, null, StoredMessageCodec.dmKeyFromRecipientIds(allRecipientIds)),
    _ => throw ArgumentError('Unexpected coverage narrow: $narrow'),
  };
}

/// Whether [effect] may mutate or remove [messageId] (in [channelId], if a channel message).
bool effectTargetsMessage(MessageEffect effect, int messageId, int? channelId) {
  return switch (effect) {
    InsertEffect(:final message) => message.id == messageId,
    ContentEffect(messageId: final id) => id == messageId,
    EditTimeEffect(:final messageIds) => messageIds.contains(messageId),
    MoveEffect(:final messageIds) => messageIds.contains(messageId),
    DeleteEffect(:final messageIds) || ForgetEffect(:final messageIds) =>
      messageIds.contains(messageId),
    FlagEffect(:final messageIds) => messageIds.contains(messageId),
    FlagAllReadEffect() => true,
    ReactionEffect(messageId: final id) => id == messageId,
    SubmessageEffect(:final event) => event.messageId == messageId,
    ChannelUntrackEffect(channelId: final cid) || ChannelPurgeEffect(channelId: final cid) =>
      channelId != null && cid == channelId,
  };
}

/// Reconstruct the raw flag strings for [message], preserving any unknown flags
/// carried in [rawMap].
List<String> effectiveRawFlags(
  Message message,
  Map<String, Object?>? rawMap,
) {
  final result = <String>[
    for (final f in message.flags)
      if (f != MessageFlag.unknown) f.toJson(),
  ];
  if (message.flags.contains(MessageFlag.unknown) && rawMap != null) {
    final rawFlags = rawMap['flags'];
    if (rawFlags is List) {
      for (final entry in rawFlags) {
        final name = entry.toString();
        if (!StoredMessageFlags.bitByName.containsKey(name) && !result.contains(name)) {
          result.add(name);
        }
      }
    }
  }
  return result;
}

/// Whether [a] and [b] encode to identical persisted message rows and bodies.
bool hasSamePersistedMessageData(Message a, Message b) {
  if (identical(a, b)) return true;
  if (a.id != b.id
      || a.senderId != b.senderId
      || a.timestamp != b.timestamp
      || a.content != b.content
      || a.isMeMessage != b.isMeMessage
      || a.editState != b.editState
      || a.lastEditTimestamp != b.lastEditTimestamp
      || a.senderFullName != b.senderFullName
      || a.senderEmail != b.senderEmail
      || a.senderRealmStr != b.senderRealmStr) {
    return false;
  }
  if (a is StreamMessage && b is StreamMessage) {
    if (a.streamId != b.streamId
        || a.topic.apiName != b.topic.apiName
        || (a.conversation.displayRecipient == null)
            != (b.conversation.displayRecipient == null)) {
      return false;
    }
  } else if (a is DmMessage && b is DmMessage) {
    if (!listEquals(a.allRecipientIds, b.allRecipientIds)) {
      return false;
    }
  } else {
    return false;
  }
  if (!setEquals(a.flags.toSet(), b.flags.toSet())) {
    return false;
  }
  if (!_hasSameReactions(a.reactions, b.reactions)) {
    return false;
  }
  if (!_hasSamePolls(a.poll, b.poll)) {
    return false;
  }
  return true;
}

bool _hasSameReactions(Reactions? a, Reactions? b) {
  final aggA = a?.aggregated ?? const [];
  final aggB = b?.aggregated ?? const [];
  if (aggA.length != aggB.length) return false;
  for (int i = 0; i < aggA.length; i++) {
    final ra = aggA[i];
    final rb = aggB[i];
    if (ra.reactionType != rb.reactionType
        || ra.emojiCode != rb.emojiCode
        || ra.emojiName != rb.emojiName
        || !setEquals(ra.userIds, rb.userIds)) {
      return false;
    }
  }
  return true;
}

bool _hasSamePolls(Poll? a, Poll? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  final subA = Poll.toJson(a);
  final subB = Poll.toJson(b);
  if (subA.length != subB.length) return false;
  for (int i = 0; i < subA.length; i++) {
    final sa = subA[i];
    final sb = subB[i];
    if (sa.id != sb.id
        || sa.senderId != sb.senderId
        || sa.msgType != sb.msgType
        || sa.content != sb.content) {
      return false;
    }
  }
  return true;
}

/// Reconcile channel access and protected-history transitions at epoch start
/// inside an active [MessageDatabase] transaction.
Future<({Set<int> withData, Set<int> purgedChannels})> runEpochStartAccessCheckInTxn(
  MessageDatabase db, {
  required int accountId,
  required ChannelStore channelStore,
  required Iterable<Message> inMemoryMessages,
  required LoadedMessageDbAccountState? loaded,
  required MessageCoverage coverage,
  required Map<int, bool> channelHistoryPublic,
}) async {
  final channelsToPurge = <int>{};
  final prevChannels = loaded?.channels ?? const <int, bool>{};
  final candidates = <int>{
    ...?loaded?.channelsWithData,
    for (final message in inMemoryMessages)
      if (message is StreamMessage) message.streamId,
    for (final key in coverage.keys)
      ?CoverageKeys.channelIdOf(key),
  };
  for (final channelId in candidates) {
    final channel = channelStore.streams[channelId];
    if (channel == null || !channelStore.selfHasContentAccess(channel)) {
      channelsToPurge.add(channelId);
      coverage.dropChannel(channelId);
      channelHistoryPublic.remove(channelId);
      continue;
    }
    final prevHistoryPublic = prevChannels[channelId];
    final nowHistoryPublic = channel.historyPublicToSubscribers;
    if ((prevHistoryPublic == null && !nowHistoryPublic)
        || (prevHistoryPublic != null && prevHistoryPublic != nowHistoryPublic)) {
      if (!nowHistoryPublic) {
        channelsToPurge.add(channelId);
      }
      coverage.dropChannel(channelId);
    }
    channelHistoryPublic[channelId] = nowHistoryPublic;
  }
  for (final channel in channelStore.streams.values) {
    channelHistoryPublic[channel.streamId] = channel.historyPublicToSubscribers;
  }
  await db.purgeChannelsInTxn(accountId, channelsToPurge);
  await db.upsertChannelsInTxn(
    accountId,
    channelHistoryPublic,
    removeChannelIds: channelsToPurge,
  );
  return (
    withData: candidates.difference(channelsToPurge),
    purgedChannels: channelsToPurge,
  );
}

/// Compute retention cutoff timestamps (Unix seconds) for DMs and candidate channels.
({int? dmCutoffTimestamp, Map<int, int> channelCutoffTimestamps}) computeRetentionCutoffs({
  required int nowSeconds,
  required int? realmMessageRetentionDays,
  required Map<int, ZulipStream> streams,
  required Iterable<int> candidateChannels,
  bool includeDms = true,
}) {
  final int? effectiveRealmDays =
    (realmMessageRetentionDays == null || realmMessageRetentionDays < 0)
      ? null
      : realmMessageRetentionDays;
  final dmCutoff = (includeDms && effectiveRealmDays != null)
    ? nowSeconds - effectiveRealmDays * 86400
    : null;

  final channelCutoffs = <int, int>{};
  for (final channelId in candidateChannels) {
    final channelDays = streams[channelId]?.messageRetentionDays;
    final int? effectiveDays;
    if (channelDays != null) {
      effectiveDays = channelDays < 0 ? null : channelDays;
    } else {
      effectiveDays = effectiveRealmDays;
    }
    if (effectiveDays != null) {
      channelCutoffs[channelId] = nowSeconds - effectiveDays * 86400;
    }
  }
  return (
    dmCutoffTimestamp: dmCutoff,
    channelCutoffTimestamps: channelCutoffs,
  );
}
