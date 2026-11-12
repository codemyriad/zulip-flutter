import 'dart:convert';
import 'dart:typed_data';

import '../api/core.dart';
import '../api/model/model.dart';
import '../api/model/submessage.dart';

/// The version of the format written by [encodeCachedMessages].
///
/// Data in any other format is rejected by [decodeCachedMessages].
/// Bump this on any change to the format
/// that an older or newer version of the app would misread,
/// including a change to [Message.toJson] or [Message.fromJson]
/// of that kind.
const kCachedMessagesFormatVersion = 1;

/// Encode [messages] for storing on the device,
/// to be read back by [decodeCachedMessages].
///
/// This is how a message list stores the newest messages it showed
/// for a narrow, to show again while the server can't be reached;
/// see `MessageListView.showingCachedMessages`.
///
/// The format is the API's JSON format for messages ([Message.toJson]),
/// in a versioned envelope,
/// with additions for the data that [Message.fromJson]
/// wouldn't otherwise read back as it was:
///  * [Message.editState], which [Message.fromJson] computes from
///    the `edit_history` and `last_edit_timestamp` the server sends,
///    and which events can update without either of those;
///  * [Message.poll], which [Message.toJson] doesn't encode
///    (except in debug mode, and then as the submessages it was parsed from,
///    without later votes);
///  * [StreamConversation.displayRecipient], which can be null
///    (after a move between channels),
///    while [Message.fromJson] requires a string.
Uint8List encodeCachedMessages(Iterable<Message> messages) {
  final bytes = _jsonUtf8Encoder.convert({
    'version': kCachedMessagesFormatVersion,
    'messages': messages.map(_messageToJson).toList(),
  });
  return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
}

final _jsonUtf8Encoder = JsonUtf8Encoder();

/// Decode messages encoded by [encodeCachedMessages].
///
/// The messages are new objects,
/// equal to the encoded ones in all their data.
///
/// Throws if [data] isn't in the format [encodeCachedMessages] writes,
/// as of [kCachedMessagesFormatVersion].
List<Message> decodeCachedMessages(Uint8List data) {
  final json = jsonUtf8Decoder.convert(data);
  if (json is! Map<String, Object?>) {
    throw const FormatException('Cached messages: not a JSON object');
  }
  final version = json['version'];
  if (version != kCachedMessagesFormatVersion) {
    throw FormatException('Cached messages: unknown version $version');
  }
  return (json['messages'] as List<Object?>)
    .map((message) => _messageFromJson(message as Map<String, dynamic>))
    .toList();
}

Map<String, Object?> _messageToJson(Message message) {
  final json = message.toJson();
  json['submessages'] = const <Object?>[];
  if (message.poll case final poll?) {
    json['poll'] = _pollToJson(poll);
  }
  return json;
}

Message _messageFromJson(Map<String, dynamic> json) {
  final noDisplayRecipient =
    json['type'] == 'stream' && json['display_recipient'] == null;
  if (noDisplayRecipient) json['display_recipient'] = '';

  final message = Message.fromJson(json);

  if (noDisplayRecipient) {
    (message as StreamMessage).conversation.displayRecipient = null;
  }
  message.editState = MessageEditState.values.byName(json['edit_state'] as String);
  if (json['poll'] case final Map<String, dynamic> pollJson) {
    message.poll = _pollFromJson(pollJson, messageSenderId: message.senderId);
  }
  return message;
}

Map<String, Object?> _pollToJson(Poll poll) {
  return {
    'question': poll.question,
    'options': [
      for (final option in poll.options)
        {
          'key': option.key,
          'text': option.text,
          'voters': option.voters.toList(),
        },
    ],
  };
}

Poll _pollFromJson(Map<String, dynamic> json, {required int messageSenderId}) {
  return Poll.withState(
    messageSenderId: messageSenderId,
    question: json['question'] as String,
    options: (json['options'] as List<Object?>).map((optionJson) {
      final option = optionJson as Map<String, dynamic>;
      return PollOption(
          key: option['key'] as String,
          text: option['text'] as String)
        ..voters.addAll((option['voters'] as List<Object?>)
          .map((voter) => (voter as num).toInt()));
    }));
}
