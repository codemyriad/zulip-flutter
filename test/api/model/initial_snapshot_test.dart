import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:zulip/api/model/initial_snapshot.dart';
import 'package:zulip/api/model/model.dart';

import '../../example_data.dart' as eg;
import '../../stdlib_checks.dart';

void main() {
  test('UnreadMessagesSnapshot from json recognizes channels as streams', () {
    final snapshot = UnreadMessagesSnapshot.fromJson({
      'count': 1,
      'pms': <dynamic>[],
      'huddles': <dynamic>[],
      'mentions': <dynamic>[],
      'old_unreads_missing': false,
      'streams': [{
        'stream_id': 1,
        'topic': 'topic name',
        'unread_message_ids': [1, 2]}]
    });

    check(snapshot.channels).single.jsonEquals(
      UnreadChannelSnapshot(
        topic: const TopicName('topic name'), streamId: 1,
        unreadMessageIds: [1, 2]));
  });

  test('UnreadDmSnapshot: require sorted unreadMessageIds', () {
    check(() => UnreadDmSnapshot.fromJson({
      'other_user_id': 1,
      'unread_message_ids': [1, 2, 3],
    })).returnsNormally();

    check(() => UnreadDmSnapshot.fromJson({
      'other_user_id': 1,
      'unread_message_ids': [11, 2, 3],
    })).throws<AssertionError>();
  });

  test('UnreadChannelSnapshot: require sorted unreadMessageIds', () {
    check(() => UnreadChannelSnapshot.fromJson({
      'topic': 'a',
      'stream_id': 1,
      'unread_message_ids': [1, 2, 3],
    })).returnsNormally();

    check(() => UnreadChannelSnapshot.fromJson({
      'topic': 'a',
      'stream_id': 1,
      'unread_message_ids': [11, 2, 3],
    })).throws<AssertionError>();
  });

  test('UnreadHuddleSnapshot: require sorted unreadMessageIds', () {
    check(() => UnreadHuddleSnapshot.fromJson({
      'user_ids_string': '1,2',
      'unread_message_ids': [1, 2, 3],
    })).returnsNormally();

    check(() => UnreadHuddleSnapshot.fromJson({
      'user_ids_string': '1,2',
      'unread_message_ids': [11, 2, 3],
    })).throws<AssertionError>();
  });

  test('UserSettings.emojiset handles various unknown values', () {
    final unknownValues = ['apple', ''];
    for (final unknownValue in unknownValues) {
      final json = eg.userSettings().toJson()..['emojiset'] = unknownValue;
      final settings = UserSettings.fromJson(json);
      check(settings.emojiset).equals(Emojiset.unknown);
    }
  });

  test('InitialSnapshot.maxMessageId', () {
    final baseJson =
        jsonDecode(jsonEncode(eg.initialSnapshot())) as Map<String, dynamic>;

    final withId = InitialSnapshot.fromJson({...baseJson, 'max_message_id': 42});
    check(withId.maxMessageId).equals(42);

    final withNegOne = InitialSnapshot.fromJson({...baseJson, 'max_message_id': -1});
    check(withNegOne.maxMessageId).equals(-1);

    final absent = InitialSnapshot.fromJson(Map.of(baseJson)..remove('max_message_id'));
    check(absent.maxMessageId).isNull();
  });

  test('InitialSnapshot.realmMessageRetentionDays', () {
    final baseJson =
        jsonDecode(jsonEncode(eg.initialSnapshot())) as Map<String, dynamic>;

    final finite = InitialSnapshot.fromJson({
      ...baseJson,
      'realm_message_retention_days': 30,
    });
    check(finite.realmMessageRetentionDays).equals(30);

    final unlimited = InitialSnapshot.fromJson({
      ...baseJson,
      'realm_message_retention_days': -1,
    });
    check(unlimited.realmMessageRetentionDays).equals(-1);

    final absent = InitialSnapshot.fromJson(
      Map.of(baseJson)..remove('realm_message_retention_days'));
    check(absent.realmMessageRetentionDays).isNull();
  });
}
