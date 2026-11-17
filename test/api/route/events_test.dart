import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:http/http.dart' as http;
import 'package:test_api/scaffolding.dart';
import 'package:zulip/api/model/events.dart';
import 'package:zulip/api/model/initial_snapshot.dart';
import 'package:zulip/api/route/events.dart';

import '../../example_data.dart' as eg;
import '../../stdlib_checks.dart';
import '../fake_api.dart';

void main() {
  group('registerQueue', () {
    Future<InitialSnapshot> checkRegisterQueue(FakeApiConnection connection, {
      IdleQueueTimeout? idleQueueTimeout,
    }) async {
      final result = await registerQueue(connection,
        idleQueueTimeout: idleQueueTimeout);
      check(connection.lastRequest).isA<http.Request>()
        ..method.equals('POST')
        ..url.path.equals('/api/v1/register')
        ..bodyFields.deepEquals({
          if (idleQueueTimeout != null)
            'idle_queue_timeout': jsonEncode(idleQueueTimeout),

          'apply_markdown': jsonEncode(true),
          'client_gravatar': jsonEncode(false),
          'slim_presence': jsonEncode(true),

          'client_capabilities': jsonEncode({
            'notification_settings_null': true,
            'bulk_message_deletion': true,
            'user_avatar_url_field_optional': true,
            'stream_typing_notifications': true,
            'user_settings_object': true,
            'include_deactivated_groups': true,
            'empty_topic_name': true,
            'individual_emoji_changes': true,
          }),
        });
      return result;
    }

    test('smoke', () => FakeApiConnection.with_((connection) async {
      connection.prepare(json: eg.initialSnapshot().toJson());
      await checkRegisterQueue(connection);
    }));

    test('idleQueueTimeout absent', () => FakeApiConnection.with_((connection) async {
      connection.prepare(json: eg.initialSnapshot().toJson());
      await checkRegisterQueue(connection, idleQueueTimeout: null);
    }));

    test('idleQueueTimeout numeric', () => FakeApiConnection.with_((connection) async {
      connection.prepare(json: eg.initialSnapshot().toJson());
      await checkRegisterQueue(connection, idleQueueTimeout: .numeric(3600));
    }));

    test('idleQueueTimeout mobile', () => FakeApiConnection.with_((connection) async {
      connection.prepare(json: eg.initialSnapshot().toJson());
      await checkRegisterQueue(connection, idleQueueTimeout: .mobile);
    }));

    test('rawBody', () => FakeApiConnection.with_((connection) async {
      final body = jsonEncode({
        ...eg.initialSnapshot(queueId: 'queue1').toJson(),
        'some_unknown_field': [1, 2],
      });
      connection.prepare(body: body);
      final rawBody = BytesBuilder();
      final result = await registerQueue(connection, rawBody: rawBody);
      check(result.queueId).equals('queue1');
      check(rawBody.takeBytes()).deepEquals(utf8.encode(body));
    }));
  });

  group('getEvents', () {
    test('rawEvents', () => FakeApiConnection.with_((connection) async {
      final rawEvents = [
        {
          ...jsonDecode(jsonEncode(eg.messageEvent(eg.streamMessage())))
            as Map<String, dynamic>,
          'some_unknown_field': [1, 2],
        },
        {'id': 3, 'type': 'heartbeat'},
      ];
      connection.prepare(json: {
        'result': 'success', 'msg': '',
        'events': rawEvents,
        'queue_id': 'queue1',
      });
      final result = await getEvents(connection, queueId: 'queue1');
      check(result.events).deepEquals(<Condition<Object?>>[
        (it) => it.isA<MessageEvent>(),
        (it) => it.isA<HeartbeatEvent>(),
      ]);
      check(result.rawEvents).isNotNull().deepEquals(rawEvents);
      check(result.toJson()).not((it) => it.containsKey('raw_events'));
    }));

    test('no rawEvents when constructed directly', () {
      check(GetEventsResult(events: [HeartbeatEvent(id: 3)], queueId: null))
        .has((x) => x.rawEvents, 'rawEvents').isNull();
    });
  });
}
