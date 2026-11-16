import 'dart:convert';

import 'package:drift/drift.dart';

import '../api/model/events.dart';
import '../api/model/model.dart';
import '../api/model/submessage.dart';
import 'message_database.dart';
import 'message_effect.dart';
import 'message_search_text.dart';
import 'narrow.dart' show serverTopicFold;
import 'stored_message_codec.dart';

/// SQL appliers for [MessageEffect]s against [MessageDatabase].
///
/// Must be called inside a database transaction.
Future<void> applyMessageEffectToDb(
  MessageDatabase db, {
  required int accountId,
  required MessageEffect effect,
  required int epoch,
  StoredMessageRecord? preEncodedRecord,
  Map<String, dynamic>? rawMessage,
  List<String>? rawFlags,
  bool removalOnly = false,
}) async {
  if (removalOnly) {
    switch (effect) {
      case DeleteEffect(:final messageIds):
        await deleteMessagesFromDb(db, accountId: accountId, messageIds: messageIds);
      case ChannelPurgeEffect(:final channelId):
        await _purgeChannel(db, accountId: accountId, channelId: channelId);
      case InsertEffect():
      case ContentEffect():
      case EditTimeEffect():
      case MoveEffect():
      case ForgetEffect():
      case FlagEffect():
      case FlagAllReadEffect():
      case ReactionEffect():
      case SubmessageEffect():
      case ChannelUntrackEffect():
        return;
    }
    return;
  }

  switch (effect) {
    case InsertEffect(:final message, :final tracked):
      final StoredMessageRecord? record;
      if (preEncodedRecord != null) {
        record = preEncodedRecord;
      } else if (rawMessage != null) {
        record = StoredMessageCodec.encode(
          accountId: accountId,
          message: message,
          rawMap: rawMessage,
          epoch: epoch,
          tracked: tracked,
          rawFlagsOverride: rawFlags,
        );
      } else {
        return;
      }
      await upsertStoredMessageRecordInDb(db, accountId: accountId, record: record);

    case ContentEffect(
      :final messageId,
      :final flags,
      :final editState,
      :final renderedContent,
      :final isMeMessage,
    ):
      await _applyContentEffect(
        db,
        accountId: accountId,
        messageId: messageId,
        flags: flags,
        editState: editState,
        renderedContent: renderedContent,
        isMeMessage: isMeMessage,
      );

    case EditTimeEffect(:final messageIds, :final editTimestamp):
      if (messageIds.isEmpty) return;
      await db.customUpdate(
        'UPDATE stored_messages SET last_edit_timestamp = ? '
        'WHERE account_id = ? AND id IN (SELECT value FROM json_each(?))',
        variables: [
          Variable.withInt(editTimestamp),
          Variable.withInt(accountId),
          Variable.withString(jsonEncode(messageIds)),
        ],
        updates: {db.storedMessages},
      );

    case MoveEffect(
      :final messageIds,
      :final origChannelId,
      :final newChannelId,
      :final origTopic,
      :final newTopic,
      :final untrack,
      :final markMoved,
    ):
      if (messageIds.isEmpty) return;
      final origTopicKey = serverTopicFold(origTopic.apiName);
      final matchedRows = await db.customSelect(
        'SELECT id FROM stored_messages '
        'WHERE account_id = ? AND channel_id = ? AND topic_key = ? '
        '  AND id IN (SELECT value FROM json_each(?))',
        variables: [
          Variable.withInt(accountId),
          Variable.withInt(origChannelId),
          Variable.withString(origTopicKey),
          Variable.withString(jsonEncode(messageIds)),
        ],
      ).get();
      if (matchedRows.isEmpty) return;
      final matchedIdsJson = jsonEncode([
        for (final row in matchedRows) row.read<int>('id'),
      ]);
      final topicChanged = newTopic != origTopic;
      final topicName = newTopic.apiName;
      final topicKey = serverTopicFold(topicName);
      final crossChannel = newChannelId != origChannelId;
      final movedIdx = MessageEditState.moved.index;
      final noneIdx = MessageEditState.none.index;
      await db.customUpdate(
        'UPDATE stored_messages SET '
        'channel_id = ?, '
        '${topicChanged ? 'topic = ?, topic_key = ?, ' : ''}'
        'display_recipient_cleared = CASE WHEN ? THEN 1 ELSE display_recipient_cleared END, '
        'tracked = CASE WHEN ? THEN 0 ELSE tracked END, '
        'edit_state = CASE WHEN ? AND edit_state = ? THEN ? ELSE edit_state END '
        'WHERE account_id = ? AND id IN (SELECT value FROM json_each(?))',
        variables: [
          Variable.withInt(newChannelId),
          if (topicChanged) ...[
            Variable.withString(topicName),
            Variable.withString(topicKey),
          ],
          Variable.withBool(crossChannel),
          Variable.withBool(untrack),
          Variable.withBool(markMoved),
          Variable.withInt(noneIdx),
          Variable.withInt(movedIdx),
          Variable.withInt(accountId),
          Variable.withString(matchedIdsJson),
        ],
        updates: {db.storedMessages},
      );
      if (topicChanged) {
        await db.customUpdate(
          'UPDATE stored_message_fts SET topic_text = ? '
          'WHERE rowid IN ('
          '  SELECT b.rowid FROM stored_message_bodies AS b '
          '  WHERE b.account_id = ? '
          '    AND b.message_id IN (SELECT value FROM json_each(?))'
          ')',
          variables: [
            Variable.withString(topicName),
            Variable.withInt(accountId),
            Variable.withString(matchedIdsJson),
          ],
        );
      }

    case DeleteEffect(:final messageIds):
    case ForgetEffect(:final messageIds):
      await deleteMessagesFromDb(db, accountId: accountId, messageIds: messageIds);

    case FlagEffect(:final messageIds, :final flag, :final add):
      if (messageIds.isEmpty) return;
      final bit = StoredMessageFlags.bitByName[flag.toJson()];
      if (bit == null) return;
      final expr = add ? 'flags | ?' : 'flags & ~?';
      await db.customUpdate(
        'UPDATE stored_messages SET flags = $expr '
        'WHERE account_id = ? AND id IN (SELECT value FROM json_each(?))',
        variables: [
          Variable.withInt(bit),
          Variable.withInt(accountId),
          Variable.withString(jsonEncode(messageIds)),
        ],
        updates: {db.storedMessages},
      );

    case FlagAllReadEffect():
      await db.customUpdate(
        'UPDATE stored_messages SET flags = flags | ? WHERE account_id = ?',
        variables: [
          Variable.withInt(StoredMessageFlags.read),
          Variable.withInt(accountId),
        ],
        updates: {db.storedMessages},
      );

    case ReactionEffect(
      :final messageId,
      :final op,
      :final emojiName,
      :final emojiCode,
      :final reactionType,
      :final userId,
    ):
      switch (op) {
        case ReactionOp.add:
          final exists = await _messageExists(db, accountId: accountId, messageId: messageId);
          if (!exists) return;
          await db.customInsert(
            'INSERT OR IGNORE INTO stored_reactions '
            '(account_id, message_id, seq, user_id, reaction_type, emoji_code, emoji_name) '
            'VALUES (?, ?, COALESCE((SELECT MAX(seq) + 1 FROM stored_reactions WHERE account_id = ? AND message_id = ?), 0), ?, ?, ?, ?)',
            variables: [
              Variable.withInt(accountId),
              Variable.withInt(messageId),
              Variable.withInt(accountId),
              Variable.withInt(messageId),
              Variable.withInt(userId),
              Variable.withString(reactionType.toJson()),
              Variable.withString(emojiCode),
              Variable.withString(emojiName),
            ],
            updates: {db.storedReactions},
          );
        case ReactionOp.remove:
          await db.customUpdate(
            'DELETE FROM stored_reactions '
            'WHERE account_id = ? AND message_id = ? AND user_id = ? AND reaction_type = ? AND emoji_code = ?',
            variables: [
              Variable.withInt(accountId),
              Variable.withInt(messageId),
              Variable.withInt(userId),
              Variable.withString(reactionType.toJson()),
              Variable.withString(emojiCode),
            ],
            updates: {db.storedReactions},
          );
      }

    case SubmessageEffect(:final event):
      final exists = await _messageExists(db, accountId: accountId, messageId: event.messageId);
      if (!exists) return;
      final hasInitialSubmessage = await db.customSelect(
        'SELECT 1 FROM stored_submessages '
        'WHERE account_id = ? AND message_id = ? LIMIT 1',
        variables: [
          Variable.withInt(accountId),
          Variable.withInt(event.messageId),
        ],
      ).get();
      if (hasInitialSubmessage.isEmpty) return;
      final PollEventSubmessage pollEvent;
      try {
        pollEvent = PollEventSubmessage.fromJson(
          jsonDecode(event.content) as Map<String, Object?>,
        );
      } catch (_) {
        return;
      }
      await db.customInsert(
        'INSERT OR IGNORE INTO stored_submessages '
        '(account_id, submessage_id, message_id, sender_id, msg_type, content) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withInt(accountId),
          Variable.withInt(event.submessageId),
          Variable.withInt(event.messageId),
          Variable.withInt(event.senderId),
          Variable.withString(event.msgType.toJson()),
          Variable.withString(event.content),
        ],
        updates: {db.storedSubmessages},
      );
      if (pollEvent is PollNewOptionEventSubmessage
          || pollEvent is PollQuestionEventSubmessage) {
        await _refreshMessageFtsBodyText(
          db,
          accountId: accountId,
          messageId: event.messageId,
        );
      }

    case ChannelUntrackEffect(:final channelId):
      await db.customUpdate(
        'UPDATE stored_messages SET tracked = 0 WHERE account_id = ? AND channel_id = ?',
        variables: [
          Variable.withInt(accountId),
          Variable.withInt(channelId),
        ],
        updates: {db.storedMessages},
      );

    case ChannelPurgeEffect(:final channelId):
      await _purgeChannel(db, accountId: accountId, channelId: channelId);
  }
}

Future<bool> _messageExists(
  MessageDatabase db, {
  required int accountId,
  required int messageId,
}) async {
  final row = await db.customSelect(
    'SELECT 1 FROM stored_messages WHERE account_id = ? AND id = ? LIMIT 1',
    variables: [Variable.withInt(accountId), Variable.withInt(messageId)],
  ).getSingleOrNull();
  return row != null;
}

Future<void> upsertStoredMessageRecordInDb(
  MessageDatabase db, {
  required int accountId,
  required StoredMessageRecord record,
}) async {
  final messageId = record.message.id.value;
  final acct = await db.customSelect(
    'SELECT evicted_below_message_id FROM message_db_accounts WHERE account_id = ?',
    variables: [Variable.withInt(accountId)],
  ).getSingleOrNull();
  final existing = await db.customSelect(
    'SELECT body_bytes FROM stored_messages WHERE account_id = ? AND id = ?',
    variables: [Variable.withInt(accountId), Variable.withInt(messageId)],
  ).getSingleOrNull();
  final oldBytes = existing?.read<int>('body_bytes') ?? 0;
  if (acct != null && messageId < acct.read<int>('evicted_below_message_id')) {
    if (existing != null) {
      await (db.delete(db.storedMessages)
        ..where((m) => m.accountId.equals(accountId) & m.id.equals(messageId))).go();
      if (oldBytes != 0) {
        await _adjustTotalBodyBytes(db, accountId: accountId, delta: -oldBytes);
      }
    }
    return;
  }
  if (existing != null) {
    // Delete old row so ON DELETE CASCADE cleans bodies, reactions, submessages.
    await (db.delete(db.storedMessages)
      ..where((m) => m.accountId.equals(accountId) & m.id.equals(messageId))).go();
  }
  await db.into(db.storedMessages).insert(record.message);
  final bodyRowId = await db.into(db.storedMessageBodies).insert(record.body);
  for (final r in record.reactions) {
    await db.into(db.storedReactions).insert(r, mode: InsertMode.insertOrIgnore);
  }
  for (final s in record.submessages) {
    await db.into(db.storedSubmessages).insert(s, mode: InsertMode.insertOrIgnore);
  }
  final sortedSubmessages = record.submessages.toList()
    ..sort((a, b) => a.submessageId.value.compareTo(b.submessageId.value));
  final topicText = record.message.topic.value ?? '';
  final bodyText = extractMessageSearchBodyText(
    htmlContent: record.body.content.value,
    messageSenderId: record.message.senderId.value,
    submessages: [
      for (final s in sortedSubmessages)
        (senderId: s.senderId.value, content: s.content.value),
    ],
  );
  await db.customUpdate(
    'DELETE FROM stored_message_fts WHERE rowid = ?',
    variables: [Variable.withInt(bodyRowId)],
  );
  await db.customInsert(
    'INSERT INTO stored_message_fts '
    '(rowid, account_id, message_id, topic_text, body_text) '
    'VALUES (?, ?, ?, ?, ?)',
    variables: [
      Variable.withInt(bodyRowId),
      Variable.withInt(accountId),
      Variable.withInt(messageId),
      Variable.withString(topicText),
      Variable.withString(bodyText),
    ],
  );
  final delta = record.bodyBytes - oldBytes;
  if (delta != 0) {
    await _adjustTotalBodyBytes(db, accountId: accountId, delta: delta);
  }
}

Future<void> _applyContentEffect(
  MessageDatabase db, {
  required int accountId,
  required int messageId,
  required List<MessageFlag> flags,
  required MessageEditState? editState,
  required String? renderedContent,
  required bool? isMeMessage,
}) async {
  final existing = await db.customSelect(
    'SELECT body_bytes FROM stored_messages WHERE account_id = ? AND id = ?',
    variables: [Variable.withInt(accountId), Variable.withInt(messageId)],
  ).getSingleOrNull();
  if (existing == null) return;

  int knownMask = 0;
  bool keepUnknown = false;
  for (final flag in flags) {
    if (flag == MessageFlag.unknown) {
      keepUnknown = true;
    } else {
      final bit = StoredMessageFlags.bitByName[flag.toJson()];
      if (bit != null) knownMask |= bit;
    }
  }

  await db.customUpdate(
    'UPDATE stored_messages SET '
    'flags = ?, '
    'unknown_flags = CASE WHEN ? THEN unknown_flags ELSE NULL END, '
    'edit_state = COALESCE(?, edit_state), '
    'is_me_message = COALESCE(?, is_me_message) '
    'WHERE account_id = ? AND id = ?',
    variables: [
      Variable.withInt(knownMask),
      Variable.withBool(keepUnknown),
      editState != null ? Variable.withInt(editState.index) : const Variable(null),
      isMeMessage != null ? Variable.withBool(isMeMessage) : const Variable(null),
      Variable.withInt(accountId),
      Variable.withInt(messageId),
    ],
    updates: {db.storedMessages},
  );

  if (renderedContent != null) {
    final oldBody = await db.customSelect(
      'SELECT content FROM stored_message_bodies WHERE account_id = ? AND message_id = ?',
      variables: [Variable.withInt(accountId), Variable.withInt(messageId)],
    ).getSingleOrNull();
    if (oldBody != null) {
      final oldContentBytes = utf8.encode(oldBody.read<String>('content')).length;
      final newContentBytes = utf8.encode(renderedContent).length;
      final delta = newContentBytes - oldContentBytes;
      await db.customUpdate(
        'UPDATE stored_message_bodies SET content = ? WHERE account_id = ? AND message_id = ?',
        variables: [
          Variable.withString(renderedContent),
          Variable.withInt(accountId),
          Variable.withInt(messageId),
        ],
        updates: {db.storedMessageBodies},
      );
      await _refreshMessageFtsBodyText(
        db,
        accountId: accountId,
        messageId: messageId,
        knownHtmlContent: renderedContent,
      );
      if (delta != 0) {
        await db.customUpdate(
          'UPDATE stored_messages SET body_bytes = body_bytes + ? WHERE account_id = ? AND id = ?',
          variables: [
            Variable.withInt(delta),
            Variable.withInt(accountId),
            Variable.withInt(messageId),
          ],
          updates: {db.storedMessages},
        );
        await _adjustTotalBodyBytes(db, accountId: accountId, delta: delta);
      }
    }
  }
}

Future<void> deleteMessagesFromDb(
  MessageDatabase db, {
  required int accountId,
  required List<int> messageIds,
}) async {
  if (messageIds.isEmpty) return;
  final idsJson = jsonEncode(messageIds);
  final sumRow = await db.customSelect(
    'SELECT COALESCE(SUM(body_bytes), 0) AS total FROM stored_messages '
    'WHERE account_id = ? AND id IN (SELECT value FROM json_each(?))',
    variables: [Variable.withInt(accountId), Variable.withString(idsJson)],
  ).getSingle();
  final removedBytes = sumRow.read<int>('total');
  await db.customUpdate(
    'DELETE FROM stored_messages '
    'WHERE account_id = ? AND id IN (SELECT value FROM json_each(?))',
    variables: [Variable.withInt(accountId), Variable.withString(idsJson)],
    updates: {db.storedMessages},
  );
  if (removedBytes != 0) {
    await _adjustTotalBodyBytes(db, accountId: accountId, delta: -removedBytes);
  }
}

Future<void> _purgeChannel(
  MessageDatabase db, {
  required int accountId,
  required int channelId,
}) {
  return db.purgeChannelDataInTxn(accountId, channelId);
}

Future<void> _refreshMessageFtsBodyText(
  MessageDatabase db, {
  required int accountId,
  required int messageId,
  String? knownHtmlContent,
}) async {
  final msgRow = await db.customSelect(
    'SELECT b.rowid AS body_rowid, b.content, m.sender_id '
    'FROM stored_message_bodies b '
    'JOIN stored_messages m ON m.account_id = b.account_id AND m.id = b.message_id '
    'WHERE b.account_id = ? AND b.message_id = ?',
    variables: [Variable.withInt(accountId), Variable.withInt(messageId)],
  ).getSingleOrNull();
  if (msgRow == null) return;

  final bodyRowId = msgRow.read<int>('body_rowid');
  final htmlContent = knownHtmlContent ?? msgRow.read<String>('content');
  final messageSenderId = msgRow.read<int>('sender_id');

  final subRows = await db.customSelect(
    'SELECT sender_id, content FROM stored_submessages '
    'WHERE account_id = ? AND message_id = ? '
    'ORDER BY submessage_id ASC',
    variables: [Variable.withInt(accountId), Variable.withInt(messageId)],
  ).get();
  final bodyText = extractMessageSearchBodyText(
    htmlContent: htmlContent,
    messageSenderId: messageSenderId,
    submessages: [
      for (final row in subRows)
        (senderId: row.read<int>('sender_id'), content: row.read<String>('content')),
    ],
  );
  await db.customUpdate(
    'UPDATE stored_message_fts SET body_text = ? WHERE rowid = ?',
    variables: [Variable.withString(bodyText), Variable.withInt(bodyRowId)],
  );
}

Future<void> _adjustTotalBodyBytes(
  MessageDatabase db, {
  required int accountId,
  required int delta,
}) async {
  await db.customUpdate(
    'UPDATE message_db_accounts SET total_body_bytes = MAX(0, total_body_bytes + ?) '
    'WHERE account_id = ?',
    variables: [Variable.withInt(delta), Variable.withInt(accountId)],
    updates: {db.messageDbAccounts},
  );
}
