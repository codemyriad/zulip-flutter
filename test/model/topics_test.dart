import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zulip/api/backoff.dart';
import 'package:zulip/api/exception.dart';
import 'package:zulip/api/model/events.dart';
import 'package:zulip/api/model/initial_snapshot.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/api/route/channels.dart';
import 'package:zulip/model/binding.dart';
import 'package:zulip/model/message.dart';
import 'package:zulip/model/message_coverage.dart';
import 'package:zulip/model/narrow.dart';
import 'package:zulip/model/presence.dart';
import 'package:zulip/model/settings.dart';
import 'package:zulip/model/store.dart';
import 'package:zulip/model/topics.dart';

import '../api/fake_api.dart';
import '../api/route/route_checks.dart';
import '../example_data.dart' as eg;
import '../fake_async.dart';
import '../stdlib_checks.dart';
import 'binding.dart';
import 'test_store.dart';

void main() {
  TestZulipBinding.ensureInitialized();

  late PerAccountStore store;
  late Topics model;
  late FakeApiConnection connection;
  late int notifiedCount;

  void checkNotified({required int count}) {
    check(notifiedCount).equals(count);
    notifiedCount = 0;
  }
  void checkNotNotified()  => checkNotified(count: 0);
  void checkNotifiedOnce() => checkNotified(count: 1);

  Condition<Object?> isChannelTopicsRequest(int channelId) {
    return (it) => it.isA<http.Request>()
      ..method.equals('GET')
      ..url.path.equals('/api/v1/users/me/$channelId/topics')
      ..url.queryParameters['allow_empty_topic_name'].equals('true');
  }

  Condition<Object?> isChannelTopicsEntry(String topic, int maxId) {
    return (it) => it.isA<GetChannelTopicsEntry>()
      ..maxId.equals(maxId)
      ..name.equals(eg.t(topic));
  }

  final channel = eg.stream();
  final otherChannel = eg.stream();

  Future<void> prepare({
    List<GetChannelTopicsEntry>? topics,
  }) async {
    store = eg.store();

    notifiedCount = 0;
    model = store.topics..addListener(() => notifiedCount++);

    connection = store.connection as FakeApiConnection;
    if (topics != null) {
      connection.prepare(json: GetChannelTopicsResult(topics: topics).toJson());
      await model.getChannelTopics(channel.streamId);
      check(connection.takeRequests()).single.which(isChannelTopicsRequest(channel.streamId));
      checkNotifiedOnce();
    }
  }

  test('fetch topics -> update data, try fetching again -> no request sent', () async {
    await prepare(topics: [
      eg.getChannelTopicsEntry(name: 'foo', maxId: 100),
    ]);
    check(model).channelTopics(channel.streamId).isNotNull()
      .single.which(isChannelTopicsEntry('foo', 100));

    // No need to prepare a response as there will be no request made.
    await model.getChannelTopics(channel.streamId);
    check(connection.takeRequests()).isEmpty();
    check(model).channelTopics(channel.streamId).isNotNull()
      .single.which(isChannelTopicsEntry('foo', 100));
    checkNotNotified();
  });

  test('getChannelTopics prevents concurrent requests for the same channel', () => awaitFakeAsync((async) async {
    await prepare();

    connection.prepare(delay: Duration(seconds: 3),
      json: GetChannelTopicsResult(topics: [
        eg.getChannelTopicsEntry(name: 'foo', maxId: 100),
      ]).toJson());
    final future1 = model.getChannelTopics(channel.streamId);
    check(connection.takeRequests()).single.which(isChannelTopicsRequest(channel.streamId));
    check(model).channelTopics(channel.streamId).isNull();

    // No need to prepare a response as there will be no request made.
    final future2 = model.getChannelTopics(channel.streamId);
    check(connection.takeRequests()).isEmpty();
    check(model).channelTopics(channel.streamId).isNull();

    async.elapse(Duration(seconds: 3));
    await future2;
    check(model).channelTopics(channel.streamId).isNotNull()
      .single.which(isChannelTopicsEntry('foo', 100));
    await future1;
    check(model).channelTopics(channel.streamId).isNotNull()
      .single.which(isChannelTopicsEntry('foo', 100));
    checkNotifiedOnce();
  }));

  test('channelTopics sorts descending by maxId', () async {
    await prepare(topics: [
      eg.getChannelTopicsEntry(name: 'bar', maxId: 200),
      eg.getChannelTopicsEntry(name: 'foo', maxId: 100),
      eg.getChannelTopicsEntry(name: 'baz', maxId: 300),
    ]);
    check(model).channelTopics(channel.streamId).isNotNull().deepEquals([
      isChannelTopicsEntry('baz', 300),
      isChannelTopicsEntry('bar', 200),
      isChannelTopicsEntry('foo', 100),
    ]);

    await store.addMessage(eg.streamMessage(
      id: 301, stream: channel, topic: 'foo'));
    check(model).channelTopics(channel.streamId).isNotNull().deepEquals([
      isChannelTopicsEntry('foo', 301),
      isChannelTopicsEntry('baz', 300),
      isChannelTopicsEntry('bar', 200),
    ]);
  });

  group('handleMessageEvent', () {
    test('new message in fetched channel', () async {
      await prepare(topics: [
        eg.getChannelTopicsEntry(name: 'old topic', maxId: 1),
      ]);
      check(model).channelTopics(channel.streamId).isNotNull().deepEquals([
        isChannelTopicsEntry('old topic', 1),
      ]);

      await store.addMessage(eg.streamMessage(id: 2, stream: channel, topic: 'new topic'));
      check(model).channelTopics(channel.streamId).isNotNull().deepEquals([
        isChannelTopicsEntry('new topic', 2),
        isChannelTopicsEntry('old topic', 1),
      ]);
      checkNotifiedOnce();

      await store.addMessage(eg.streamMessage(id: 3, stream: channel, topic: 'old topic'));
      check(model).channelTopics(channel.streamId).isNotNull().deepEquals([
        isChannelTopicsEntry('old topic', 3),
        isChannelTopicsEntry('new topic', 2),
      ]);
      checkNotifiedOnce();
    });

    test('new message in channel not fetched before', () async {
      await prepare(topics: []);
      check(model).channelTopics(otherChannel.streamId).isNull();

      await store.addMessage(
        eg.streamMessage(id: 2, stream: otherChannel, topic: 'new topic'));
      check(model).channelTopics(otherChannel.streamId).isNull();
      checkNotNotified();
    });

    test('new message with equal or lower message ID', () async {
      await prepare(topics: [
        eg.getChannelTopicsEntry(name: 'topic', maxId: 2),
      ]);

      await store.addMessage(
        eg.streamMessage(id: 2, stream: channel, topic: 'topic'));
      check(model).channelTopics(channel.streamId).isNotNull()
        .single.which(isChannelTopicsEntry('topic', 2));
      checkNotNotified();

      await store.addMessage(
        eg.streamMessage(id: 1, stream: channel, topic: 'topic'));
      check(model).channelTopics(channel.streamId).isNotNull()
        .single.which(isChannelTopicsEntry('topic', 2));
      checkNotNotified();
    });

    test('ignore DM messages', () async {
      await prepare(topics: []);

      await store.addMessage(eg.dmMessage(from: eg.selfUser, to: [eg.otherUser]));
      checkNotNotified();
    });
  });

  group('handleUpdateMessageEvent', () {
    Future<void> prepareWithMessages(List<StreamMessage> messages) async {
      await prepare(topics: []);
      assert(messages.isNotEmpty);
      assert(messages.every((m) => m.streamId == channel.streamId));
      await store.addMessages(messages);
      checkNotified(count: messages.length);
    }

    test('ignore content-only update', () async {
      final message = eg.streamMessage(id: 123, stream: channel, topic: 'foo');
      await prepareWithMessages([message]);
      check(model).channelTopics(channel.streamId).isNotNull()
        .single.which(isChannelTopicsEntry('foo', 123));

      await store.handleEvent(eg.updateMessageEditEvent(message));
      checkNotNotified();
    });

    group('PropagateMode.changeAll', () {
      test('topic moved to another channel with no previously fetched topics', () async {
        final messagesToMove = List.generate(10, (i) =>
          eg.streamMessage(id: 100 + i, stream: channel, topic: 'foo'));
        await prepareWithMessages(messagesToMove);
        check(model).channelTopics(channel.streamId).isNotNull()
          .single.which(isChannelTopicsEntry('foo', 109));

        await store.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: messagesToMove,
          newStreamId: otherChannel.streamId,
          propagateMode: .changeAll));
        check(model).channelTopics(channel.streamId).isNotNull().isEmpty();
        check(model).channelTopics(otherChannel.streamId).isNull();
        checkNotifiedOnce();
      });

      test('topic moved to new topic in another channel', () async {
        final messagesToMove = List.generate(10, (i) =>
          eg.streamMessage(id: 100 + i, stream: channel, topic: 'foo'));
        await prepareWithMessages(messagesToMove);
        check(model).channelTopics(channel.streamId).isNotNull()
          .single.which(isChannelTopicsEntry('foo', 109));

        // Make sure that topics in otherChannel have been fetched.
        connection.prepare(json: GetChannelTopicsResult(topics: [
          eg.getChannelTopicsEntry(name: 'foo', maxId: 1),
        ]).toJson());
        await model.getChannelTopics(otherChannel.streamId);
        check(model).channelTopics(otherChannel.streamId).isNotNull()
          .single.which(isChannelTopicsEntry('foo', 1));
        checkNotifiedOnce();

        await store.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: messagesToMove,
          newStreamId: otherChannel.streamId,
          newTopicStr: 'bar',
          propagateMode: .changeAll));
        check(model).channelTopics(channel.streamId).isNotNull().isEmpty();
        check(model).channelTopics(otherChannel.streamId).isNotNull().deepEquals([
          isChannelTopicsEntry('bar', 109),
          isChannelTopicsEntry('foo', 1),
        ]);
        checkNotifiedOnce();
      });

      test('topic moved to existing topic in another channel', () async {
        final messagesToMove = List.generate(10, (i) =>
          eg.streamMessage(id: 100 + i, stream: channel, topic: 'foo'));
        await prepareWithMessages(messagesToMove);
        check(model).channelTopics(channel.streamId).isNotNull()
          .single.which(isChannelTopicsEntry('foo', 109));

        // Make sure that topics in otherChannel have been fetched.
        connection.prepare(json: GetChannelTopicsResult(topics: [
          eg.getChannelTopicsEntry(name: 'foo', maxId: 1),
        ]).toJson());
        await model.getChannelTopics(otherChannel.streamId);
        check(model).channelTopics(otherChannel.streamId).isNotNull()
          .single.which(isChannelTopicsEntry('foo', 1));
        checkNotifiedOnce();

        await store.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: messagesToMove,
          newStreamId: otherChannel.streamId,
          propagateMode: .changeAll));
        check(model).channelTopics(channel.streamId).isNotNull().isEmpty();
        check(model).channelTopics(otherChannel.streamId).isNotNull()
          .single.which(isChannelTopicsEntry('foo', 109));
        checkNotifiedOnce();
      });

      test('topic moved to new topic in the same channel', () async {
        final messagesToMove = List.generate(10, (i) =>
          eg.streamMessage(id: 100 + i, stream: channel, topic: 'foo'));
        await prepareWithMessages(messagesToMove);
        check(model).channelTopics(channel.streamId).isNotNull()
          .single.which(isChannelTopicsEntry('foo', 109));

        await store.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: messagesToMove,
          newTopicStr: 'bar',
          propagateMode: .changeAll));
        check(model).channelTopics(channel.streamId).isNotNull()
          .single.which(isChannelTopicsEntry('bar', 109));
        checkNotifiedOnce();
      });

      test('topic moved to existing topic in the same channel', () async {
        final messagesToMove = List.generate(10, (i) =>
          eg.streamMessage(id: 100 + i, stream: channel, topic: 'foo'));
        await prepareWithMessages([
          ...messagesToMove,
          eg.streamMessage(id: 1, stream: channel, topic: 'bar'),
        ]);
        check(model).channelTopics(channel.streamId).isNotNull().deepEquals([
          isChannelTopicsEntry('foo', 109),
          isChannelTopicsEntry('bar', 1),
        ]);

        await store.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: messagesToMove,
          newTopicStr: 'bar',
          propagateMode: .changeAll));
        check(model).channelTopics(channel.streamId).isNotNull()
          .single.which(isChannelTopicsEntry('bar', 109));
        checkNotifiedOnce();
      });
    });

    group('PropagateMode.changeOne', () {
      test('message moved to new topic', () async {
        final messageToMove =
          eg.streamMessage(id: 101, stream: channel, topic: 'foo');
        await prepareWithMessages([messageToMove]);
        check(model).channelTopics(channel.streamId).isNotNull()
          .single.which(isChannelTopicsEntry('foo', 101));

        await store.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: [messageToMove],
          newTopicStr: 'bar',
          propagateMode: .changeOne));
        check(model).channelTopics(channel.streamId).isNotNull().deepEquals([
          isChannelTopicsEntry('foo', 101),
          isChannelTopicsEntry('bar', 101),
        ]);
        checkNotifiedOnce();
      });

      test('message moved to existing topic; moved message ID < maxId', () async {
        final messageToMove =
          eg.streamMessage(id: 100, stream: channel, topic: 'foo');
        await prepareWithMessages([
          messageToMove,
          eg.streamMessage(id: 999, stream: channel, topic: 'bar'),
        ]);
        check(model).channelTopics(channel.streamId).isNotNull().deepEquals([
          isChannelTopicsEntry('bar', 999),
          isChannelTopicsEntry('foo', 100),
        ]);

        // Message with ID 100 moved from "foo" to "bar", whose maxId was 999.
        // We expect no updates to "bar"'s maxId, since the moved message
        // has a lower ID.
        await store.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: [messageToMove],
          newTopicStr: 'bar',
          propagateMode: .changeOne));
        check(model).channelTopics(channel.streamId).isNotNull().deepEquals([
          isChannelTopicsEntry('bar', 999),
          isChannelTopicsEntry('foo', 100),
        ]);
        checkNotNotified();
      });

      test('message moved to existing topic; moved message ID > maxId', () async {
        final messageToMove =
          eg.streamMessage(id: 999, stream: channel, topic: 'foo');
        await prepareWithMessages([
          messageToMove,
          eg.streamMessage(id: 100, stream: channel, topic: 'bar'),
        ]);
        check(model).channelTopics(channel.streamId).isNotNull().deepEquals([
          isChannelTopicsEntry('foo', 999),
          isChannelTopicsEntry('bar', 100),
        ]);

        // Message with ID 999 moved from "foo" to "bar", whose maxId was 100.
        // We expect an update to "bar"'s maxId, since the moved message has
        // a higher ID.
        await store.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: [messageToMove],
          newTopicStr: 'bar',
          propagateMode: .changeOne));
        check(model).channelTopics(channel.streamId).isNotNull().deepEquals([
          isChannelTopicsEntry('foo', 999),
          isChannelTopicsEntry('bar', 999),
        ]);
        checkNotifiedOnce();
      });
    });

    group('PropagateMode.changeLater', () {
      test('messages moved to new topic', () async {
        final messagesToMove = [
          eg.streamMessage(id: 99,  stream: channel, topic: 'foo'),
          eg.streamMessage(id: 100, stream: channel, topic: 'foo'),
        ];
        await prepareWithMessages(messagesToMove);
        check(model).channelTopics(channel.streamId).isNotNull()
          .single.which(isChannelTopicsEntry('foo', 100));

        await store.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: messagesToMove,
          newTopicStr: 'bar',
          propagateMode: .changeLater));
        check(model).channelTopics(channel.streamId).isNotNull().deepEquals([
          isChannelTopicsEntry('foo', 100),
          isChannelTopicsEntry('bar', 100),
        ]);
        checkNotifiedOnce();
      });

      // Other test cases are also similar to the "PropagateMode.changeOne" group above.
    });
  });

  group('TopicListView', () {
    late TopicListView view;
    late int viewNotifiedCount;

    void checkViewNotified({required int count}) {
      check(viewNotifiedCount).equals(count);
      viewNotifiedCount = 0;
    }
    void checkViewNotNotified() => checkViewNotified(count: 0);
    void checkViewNotifiedOnce() => checkViewNotified(count: 1);

    /// Initialize [view] and the rest of the test state.
    ///
    /// If [fetchedTopics] is non-null, the store fetches those for [channel]
    /// before the view is created.
    Future<void> prepareView({
      List<GetChannelTopicsEntry>? fetchedTopics,
    }) async {
      store = eg.store();
      connection = store.connection as FakeApiConnection;
      if (fetchedTopics != null) {
        connection.prepare(
          json: GetChannelTopicsResult(topics: fetchedTopics).toJson());
        await store.topics.getChannelTopics(channel.streamId);
        check(connection.takeRequests()).single;
      }
      viewNotifiedCount = 0;
      view = TopicListView.init(store: store, channelId: channel.streamId)
        ..addListener(() => viewNotifiedCount++);
    }

    void prepareNetworkException() {
      connection.prepare(httpException: const SocketException('failed'));
    }

    void prepareSuccess(List<GetChannelTopicsEntry> topics, {
      Duration delay = Duration.zero,
    }) {
      connection.prepare(delay: delay,
        json: GetChannelTopicsResult(topics: topics).toJson());
    }

    test('fetch', () => awaitFakeAsync((async) async {
      await prepareView();
      check(view).topics.isNull();
      prepareSuccess([eg.getChannelTopicsEntry(name: 'foo', maxId: 100)]);
      await view.fetch();
      check(connection.takeRequests()).single.which(isChannelTopicsRequest(channel.streamId));
      checkViewNotifiedOnce();
      check(view)
        ..fetchFailing.isFalse()
        ..topics.isNotNull().single.which(isChannelTopicsEntry('foo', 100));
      check(async.pendingTimers).isEmpty();
    }));

    test('topics already fetched: no request', () => awaitFakeAsync((async) async {
      await prepareView(
        fetchedTopics: [eg.getChannelTopicsEntry(name: 'foo', maxId: 100)]);
      await view.fetch();
      check(connection.takeRequests()).isEmpty();
      checkViewNotNotified();
      check(view).topics.isNotNull().single.which(isChannelTopicsEntry('foo', 100));
    }));

    test('notify on events changing the topics', () => awaitFakeAsync((async) async {
      await prepareView();
      prepareSuccess([eg.getChannelTopicsEntry(name: 'foo', maxId: 100)]);
      await view.fetch();
      checkViewNotifiedOnce();

      await store.addMessage(eg.streamMessage(id: 101, stream: channel, topic: 'bar'));
      checkViewNotifiedOnce();
      check(view).topics.isNotNull().deepEquals([
        isChannelTopicsEntry('bar', 101),
        isChannelTopicsEntry('foo', 100),
      ]);
    }));

    group('retry', () {
      test('retry after failure, then succeed', () => awaitFakeAsync((async) async {
        await prepareView();
        prepareNetworkException();
        prepareNetworkException();
        prepareSuccess([eg.getChannelTopicsEntry(name: 'foo', maxId: 100)]);
        final fetchFuture = view.fetch();
        async.elapse(Duration.zero);
        check(connection.takeRequests()).single;
        checkViewNotifiedOnce();
        check(view)
          ..topics.isNull()
          ..fetchFailing.isTrue();

        // Wait out the first and second backoffs, at most 100ms and 200ms.
        async.elapse(const Duration(milliseconds: 300));
        check(connection.takeRequests()).length.equals(2);
        checkViewNotifiedOnce();
        check(view)
          ..fetchFailing.isFalse()
          ..topics.isNotNull().single.which(isChannelTopicsEntry('foo', 100));
        await fetchFuture;
        check(async.pendingTimers).isEmpty();
      }));

      test('no retry on generic ZulipApiException', () => awaitFakeAsync((async) async {
        await prepareView();
        connection.prepare(apiException: eg.apiBadRequest());
        await check(view.fetch()).throws<ZulipApiException>();
        check(connection.takeRequests()).single;
        checkViewNotNotified();
        check(view)
          ..topics.isNull()
          ..fetchFailing.isFalse();
        check(async.pendingTimers).isEmpty();
      }));

      test('fetchFailing cleared on error not to retry', () => awaitFakeAsync((async) async {
        await prepareView();
        prepareNetworkException();
        final throwsCheck = check(view.fetch()).throws<ZulipApiException>();
        async.elapse(Duration.zero);
        checkViewNotifiedOnce();
        check(view).fetchFailing.isTrue();

        connection.prepare(apiException: eg.apiBadRequest());
        async.elapse(const Duration(milliseconds: 100)); // max first backoff
        await throwsCheck;
        checkViewNotifiedOnce();
        check(view)
          ..topics.isNull()
          ..fetchFailing.isFalse();
        check(async.pendingTimers).isEmpty();
      }));

      test('no retry when a test forgot to prepare a response', () => awaitFakeAsync((async) async {
        await prepareView();
        await check(view.fetch()).throws<AssertionError>();
        check(connection.takeRequests()).single;
        check(async.pendingTimers).isEmpty();
      }));

      test('disposed during backoff: no retry, no timer left', () => awaitFakeAsync((async) async {
        await prepareView();
        prepareNetworkException();
        final fetchFuture = view.fetch();
        async.elapse(Duration.zero);
        check(connection.takeRequests()).single;
        check(async.pendingTimers).single; // the backoff

        view.dispose();
        async.flushMicrotasks();
        check(async.pendingTimers).isEmpty();
        await fetchFuture;
        check(connection.takeRequests()).isEmpty();
      }));

      test('store disposed during backoff: no retry', () => awaitFakeAsync((async) async {
        await prepareView();
        prepareNetworkException();
        final fetchFuture = view.fetch();
        async.elapse(Duration.zero);
        check(connection.takeRequests()).single;
        checkViewNotifiedOnce(); // fetchFailing

        store.dispose();
        async.elapse(const Duration(seconds: 1));
        await fetchFuture;
        check(connection.takeRequests()).isEmpty();
        checkViewNotNotified();
        view.dispose();
      }));

      test('retry promptly when the event stream recovers', () => awaitFakeAsync((async) async {
        BackoffMachine.debugDuration = const Duration(seconds: 10);
        addTearDown(() => BackoffMachine.debugDuration = null);
        await prepareView();
        prepareNetworkException();
        final fetchFuture = view.fetch();
        async.elapse(Duration.zero);
        check(connection.takeRequests()).single;
        check(view).fetchFailing.isTrue();

        store.isRecoveringEventStream = true;
        async.elapse(const Duration(seconds: 1));
        check(connection.takeRequests()).isEmpty();

        prepareSuccess([eg.getChannelTopicsEntry(name: 'foo', maxId: 100)]);
        store.isRecoveringEventStream = false;
        async.elapse(Duration.zero);
        check(connection.takeRequests()).single;
        check(view).topics.isNotNull().single.which(isChannelTopicsEntry('foo', 100));
        await fetchFuture;
        check(async.pendingTimers).isEmpty();
      }));

      test('retry at once if the event stream recovers during a request', () => awaitFakeAsync((async) async {
        BackoffMachine.debugDuration = const Duration(seconds: 10);
        addTearDown(() => BackoffMachine.debugDuration = null);
        await prepareView();
        store.isRecoveringEventStream = true;
        connection.prepare(httpException: const SocketException('failed'),
          delay: const Duration(seconds: 1));
        final fetchFuture = view.fetch();
        async.elapse(Duration.zero);
        check(connection.takeRequests()).single;

        store.isRecoveringEventStream = false;
        prepareSuccess([eg.getChannelTopicsEntry(name: 'foo', maxId: 100)]);
        async.elapse(const Duration(seconds: 1));
        check(connection.takeRequests()).single;
        check(view).topics.isNotNull().single.which(isChannelTopicsEntry('foo', 100));
        await fetchFuture;
      }));
    });

    group('saved topics fallback', () {
      Future<({TestGlobalStore global, UpdateMachine um, FakeApiConnection conn})>
          startDbStore({
        TestGlobalStore? existingGlobal,
        bool allowPersisted = false,
        bool autoDispose = true,
        required List<ZulipStream> streams,
        List<Subscription> subscriptions = const [],
        List<UnreadChannelSnapshot> unreadChannels = const [],
      }) async {
        driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
        Presence.debugEnable = false;
        UpdateMachine.debugEnableFetchEmojiData = false;
        final global = existingGlobal ?? eg.globalStore();
        if (existingGlobal == null) {
          await global.settings.setBool(BoolGlobalSetting.messageDatabase, true);
          await global.insertAccount(eg.selfAccount.toCompanion(false));
          global.useCachedApiConnections = true;
          addTearDown(() async {
            await global.backend.closeMessageDb();
          });
        } else {
          global.clearCachedApiConnections();
        }
        final conn = global.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
        final snap = eg.initialSnapshot(
          queueId: 'q1',
          lastEventId: 10,
          maxMessageId: 0,
          realmUsers: [eg.selfUser],
          streams: streams,
          subscriptions: subscriptions,
          unreadMsgs: eg.unreadMsgs(channels: unreadChannels),
        );
        if (!allowPersisted) {
          final snapJson = jsonDecode(jsonEncode(snap)) as Map<String, dynamic>;
          final subs = snapJson['subscriptions'];
          if (subs is List) {
            for (final sub in subs) {
              if (sub is Map<String, dynamic> && sub['color'] is int) {
                final color = sub['color'] as int;
                sub['color'] = '#${(color & 0xffffff).toRadixString(16).padLeft(6, '0')}';
              }
            }
          }
          conn.prepare(json: snapJson);
        }
        conn.prepare(
          delay: Duration.zero,
          json: {
            'result': 'success',
            'msg': '',
            'events': <Object>[],
            'queue_id': 'q1',
          },
        );
        final um = await UpdateMachine.load(global, eg.selfAccount.id, allowPersisted: allowPersisted);
        um.debugPauseLoop();
        if (autoDispose) {
          addTearDown(um.dispose);
        }
        return (global: global, um: um, conn: conn);
      }

      test('merges DB rows, in-memory messages, and unreads with newest casing and maxId', () => awaitFakeAsync((async) async {
        final setup = await startDbStore(
          streams: [channel],
          subscriptions: [eg.subscription(channel)],
          unreadChannels: [
            UnreadChannelSnapshot(
              streamId: channel.streamId,
              topic: eg.t('UnreadOnly'),
              unreadMessageIds: [20],
            ),
          ],
        );
        async.elapse(Duration.zero);
        final dbStore = setup.um.store;
        final conn = setup.conn;
        final writer = setup.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
        await writer.drainForTesting();

        // Seed Alpha (10) and Beta (12) into SQLite via fetch reconcile,
        // then newer casing 'alpha' (15) via MessageEvent.
        final msg10 = eg.streamMessage(id: 10, stream: channel, topic: 'Alpha', sender: eg.selfUser);
        final msg12 = eg.streamMessage(id: 12, stream: channel, topic: 'Beta', sender: eg.selfUser);
        final ticket = dbStore.openFetchTicket(channelId: channel.streamId);
        try {
          dbStore.reconcileMessages(
            [msg10, msg12],
            rawMessages: [
              jsonDecode(jsonEncode(msg10)) as Map<String, dynamic>,
              jsonDecode(jsonEncode(msg12)) as Map<String, dynamic>,
            ],
            ticket: ticket,
            coverageRequest: FetchCoverageRequest(
              narrow: ChannelNarrow(channel.streamId),
              numBefore: 2,
              numAfter: 0,
              includeAnchor: true,
              foundOldest: false,
              foundNewest: true,
              historyLimited: false,
              resolvedAnchor: 12,
            ),
          );
        } finally {
          dbStore.closeFetchTicket(ticket);
        }
        await writer.drainForTesting();

        await dbStore.handleEvent(MessageEvent(
          id: 11,
          localMessageId: null,
          message: eg.streamMessage(
            id: 15,
            stream: channel,
            topic: 'alpha',
            sender: eg.selfUser,
            flags: [MessageFlag.read],
          ),
        ));
        await writer.drainForTesting();

        conn.prepare(httpException: const SocketException('offline'));
        final dbView = TopicListView.init(store: dbStore, channelId: channel.streamId);
        final fetchFuture = dbView.fetch();
        async.elapse(Duration.zero);
        await writer.drainForTesting();
        async.elapse(Duration.zero);

        check(dbView)
          ..showingSavedTopics.isTrue()
          ..fetchFailing.isFalse()
          ..topics.isNotNull().deepEquals([
            isChannelTopicsEntry('UnreadOnly', 20),
            isChannelTopicsEntry('alpha', 15),
            isChannelTopicsEntry('Beta', 12),
          ]);

        // Live fetch succeeds and clears showingSavedTopics.
        conn.prepare(json: GetChannelTopicsResult(topics: [
          eg.getChannelTopicsEntry(name: 'server-topic', maxId: 30),
        ]).toJson());
        async.elapse(const Duration(milliseconds: 200));
        await fetchFuture;
        check(dbView)
          ..showingSavedTopics.isFalse()
          ..fetchFailing.isFalse()
          ..topics.isNotNull().single.which(isChannelTopicsEntry('server-topic', 30));
        dbView.dispose();
      }));

      test('shows saved topics after kShowSavedTopicsDelay when initial request is slow', () => awaitFakeAsync((async) async {
        final setup = await startDbStore(
          streams: [channel],
          subscriptions: [eg.subscription(channel)],
        );
        async.elapse(Duration.zero);
        final dbStore = setup.um.store;
        final conn = setup.conn;
        final writer = setup.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
        await dbStore.handleEvent(MessageEvent(
          id: 11,
          localMessageId: null,
          message: eg.streamMessage(id: 25, stream: channel, topic: 'slow topic', sender: eg.selfUser),
        ));
        await writer.drainForTesting();

        conn.prepare(
          delay: const Duration(seconds: 2),
          json: GetChannelTopicsResult(topics: [
            eg.getChannelTopicsEntry(name: 'live topic', maxId: 30),
          ]).toJson(),
        );
        final dbView = TopicListView.init(store: dbStore, channelId: channel.streamId);
        final fetchFuture = dbView.fetch();
        async.elapse(const Duration(milliseconds: 500));
        await writer.drainForTesting();
        check(dbView)
          ..showingSavedTopics.isFalse()
          ..topics.isNull();

        async.elapse(const Duration(milliseconds: 500));
        check(dbView)
          ..showingSavedTopics.isTrue()
          ..fetchFailing.isFalse()
          ..topics.isNotNull().single.which(isChannelTopicsEntry('slow topic', 25));

        async.elapse(const Duration(seconds: 1));
        await fetchFuture;
        check(dbView)
          ..showingSavedTopics.isFalse()
          ..topics.isNotNull().single.which(isChannelTopicsEntry('live topic', 30));
        dbView.dispose();
      }));

      test('empty saved topics returned iff channel:c has non-stale complete [0, ∞) interval', () => awaitFakeAsync((async) async {
        final emptyComplete = eg.stream(streamId: 50, name: 'EmptyComplete');
        final emptyPartial = eg.stream(streamId: 51, name: 'EmptyPartial');
        final setup = await startDbStore(
          streams: [emptyComplete, emptyPartial],
          subscriptions: [eg.subscription(emptyComplete), eg.subscription(emptyPartial)],
        );
        async.elapse(Duration.zero);
        final dbStore = setup.um.store;
        final conn = setup.conn;

        // Complete [0, ∞) live coverage on emptyComplete.
        final ticket = dbStore.openFetchTicket(channelId: emptyComplete.streamId);
        try {
          dbStore.reconcileMessages(
            [],
            rawMessages: const [],
            ticket: ticket,
            coverageRequest: FetchCoverageRequest(
              narrow: ChannelNarrow(emptyComplete.streamId),
              numBefore: 20,
              numAfter: 0,
              includeAnchor: true,
              foundOldest: true,
              foundNewest: true,
              historyLimited: false,
              resolvedAnchor: kNewestMessageId,
            ),
          );
        } finally {
          dbStore.closeFetchTicket(ticket);
        }

        // Complete case shows empty list under saved banner (not fetchFailing).
        conn.prepare(httpException: const SocketException('offline'));
        final viewComplete = TopicListView.init(store: dbStore, channelId: emptyComplete.streamId);
        final f1 = viewComplete.fetch();
        async.elapse(Duration.zero);
        check(viewComplete)
          ..showingSavedTopics.isTrue()
          ..fetchFailing.isFalse()
          ..topics.isNotNull().isEmpty();
        conn.prepare(json: GetChannelTopicsResult(topics: []).toJson());
        async.elapse(const Duration(milliseconds: 200));
        await f1;
        viewComplete.dispose();

        // Incomplete case returns null and sets fetchFailing = true.
        conn.prepare(httpException: const SocketException('offline'));
        final viewPartial = TopicListView.init(store: dbStore, channelId: emptyPartial.streamId);
        final f2 = viewPartial.fetch();
        async.elapse(Duration.zero);
        check(viewPartial)
          ..showingSavedTopics.isFalse()
          ..fetchFailing.isTrue()
          ..topics.isNull();
        conn.prepare(json: GetChannelTopicsResult(topics: []).toJson());
        async.elapse(const Duration(milliseconds: 200));
        await f2;
        viewPartial.dispose();
      }));

      test('lacking content access or non-retryable API error hides saved topics', () => awaitFakeAsync((async) async {
        final priv = eg.stream(streamId: 60, name: 'Private', inviteOnly: true);
        final setup = await startDbStore(
          streams: [priv, channel],
          subscriptions: [eg.subscription(channel)],
        );
        async.elapse(Duration.zero);
        final dbStore = setup.um.store;
        final conn = setup.conn;
        final writer = setup.global.backend.messageDbWriterForAccount(eg.selfAccount.id);

        // Private unsubscribed channel returns null from loadSavedTopics and ignores previousTopics.
        check(await dbStore.loadSavedTopics(priv.streamId)).isNull();
        conn.prepare(apiException: eg.apiBadRequest());
        final privView = TopicListView.init(store: dbStore, channelId: priv.streamId);
        await check(privView.fetch(previousTopics: [eg.getChannelTopicsEntry(name: 'stale')]))
          .throws<ZulipApiException>();
        check(privView)
          ..showingSavedTopics.isFalse()
          ..topics.isNull();
        privView.dispose();

        // Subscribed public channel with previousTopics shows immediately, then clears on non-retryable error.
        await dbStore.handleEvent(MessageEvent(
          id: 11,
          localMessageId: null,
          message: eg.streamMessage(id: 30, stream: channel, topic: 'saved', sender: eg.selfUser),
        ));
        await writer.drainForTesting();
        conn.prepare(apiException: eg.apiBadRequest());
        final pubView = TopicListView.init(store: dbStore, channelId: channel.streamId);
        await check(pubView.fetch(previousTopics: [eg.getChannelTopicsEntry(name: 'prev')]))
          .throws<ZulipApiException>();
        check(pubView)
          ..showingSavedTopics.isFalse()
          ..topics.isNull();
        pubView.dispose();

        // Without coverageEnabled, previousTopics is ignored.
        await prepareView();
        prepareSuccess([eg.getChannelTopicsEntry(name: 'live', maxId: 1)]);
        final f = view.fetch(previousTopics: [eg.getChannelTopicsEntry(name: 'prev')]);
        check(view)
          ..showingSavedTopics.isFalse()
          ..topics.isNull();
        await f;
        view.dispose();
      }));

      test('loadSavedTopics excludes more than 500 excluded IDs via json_each', () => awaitFakeAsync((async) async {
        final setup = await startDbStore(
          streams: [channel],
          subscriptions: [eg.subscription(channel)],
        );
        async.elapse(Duration.zero);
        final dbStore = setup.um.store;
        final writer = setup.global.backend.messageDbWriterForAccount(eg.selfAccount.id);

        for (var i = 1; i <= 505; i++) {
          await dbStore.handleEvent(MessageEvent(
            id: i,
            localMessageId: null,
            message: eg.streamMessage(
              id: i,
              stream: channel,
              topic: 'ExcludedTopic',
              sender: eg.selfUser,
              flags: [MessageFlag.read],
            ),
          ));
        }
        await dbStore.handleEvent(MessageEvent(
          id: 506,
          localMessageId: null,
          message: eg.streamMessage(
            id: 506,
            stream: channel,
            topic: 'KeptTopic',
            sender: eg.selfUser,
            flags: [MessageFlag.read],
          ),
        ));
        await writer.drainForTesting();
        dbStore.messages.clear();
        dbStore.debugLocationUnknown.addAll([for (var i = 1; i <= 505; i++) i]);

        final topics = await dbStore.loadSavedTopics(channel.streamId);
        check(topics).isNotNull().single.which(isChannelTopicsEntry('KeptTopic', 506));
      }));

      test('persist fetched topics across restart, rename, and access purge', () => awaitFakeAsync((async) async {
        final priv = eg.stream(streamId: 70, name: 'Priv', inviteOnly: true);
        final setup1 = await startDbStore(
          autoDispose: false,
          streams: [channel, priv],
          subscriptions: [eg.subscription(channel), eg.subscription(priv)],
        );
        async.elapse(Duration.zero);
        final writer = setup1.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
        await writer.drainForTesting();

        setup1.conn.prepare(json: GetChannelTopicsResult(topics: [
          eg.getChannelTopicsEntry(name: 'Alpha', maxId: 100),
          eg.getChannelTopicsEntry(name: 'Beta', maxId: 90),
        ]).toJson());
        await setup1.um.store.topics.getChannelTopics(channel.streamId);
        setup1.conn.prepare(json: GetChannelTopicsResult(topics: [
          eg.getChannelTopicsEntry(name: 'SecretTopic', maxId: 200),
        ]).toJson());
        await setup1.um.store.topics.getChannelTopics(priv.streamId);
        await writer.drainForTesting();

        // Simulate app restart while offline: stored_channel_topics survives even
        // though stored_messages has zero rows for `channel`, and rename updates it.
        setup1.um.dispose();
        final setup2 = await startDbStore(
          existingGlobal: setup1.global,
          allowPersisted: true,
          autoDispose: false,
          streams: [channel, priv],
          subscriptions: [eg.subscription(channel), eg.subscription(priv)],
        );
        async.elapse(Duration.zero);
        await writer.drainForTesting();

        final store2 = setup2.um.store;
        check(await store2.loadSavedTopics(channel.streamId))
          .isNotNull()
          .deepEquals([
            isChannelTopicsEntry('Alpha', 100),
            isChannelTopicsEntry('Beta', 90),
          ]);

        // Topic rename via PropagateMode.changeAll replaces 'Alpha' with 'Renamed'.
        await store2.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: [eg.streamMessage(id: 100, stream: channel, topic: 'Alpha')],
          newTopicStr: 'Renamed',
          propagateMode: PropagateMode.changeAll,
        ));
        await writer.drainForTesting();
        check(await store2.loadSavedTopics(channel.streamId))
          .isNotNull()
          .deepEquals([
            isChannelTopicsEntry('Renamed', 100),
            isChannelTopicsEntry('Beta', 90),
          ]);

        // Unsubscribing from private channel purges persisted topics on restart.
        setup2.um.dispose();
        final setup3 = await startDbStore(
          existingGlobal: setup1.global,
          allowPersisted: false,
          streams: [channel, priv],
          subscriptions: [eg.subscription(channel)],
        );
        async.elapse(Duration.zero);
        await writer.drainForTesting();
        check(await setup3.um.store.loadSavedTopics(priv.streamId)).isNull();
        // Verify raw table row for priv was purged too.
        final db = setup1.global.backend.debugMessageDatabase!;
        final remaining = await db.queryStoredChannelTopics(eg.selfAccount.id, priv.streamId);
        check(remaining.isEmpty).isTrue();
      }));

      test('keep persisted topic when its latest message is deleted or moved alone', () => awaitFakeAsync((async) async {
        final setup1 = await startDbStore(
          autoDispose: false,
          streams: [channel],
          subscriptions: [eg.subscription(channel)],
        );
        async.elapse(Duration.zero);
        final writer = setup1.global.backend.messageDbWriterForAccount(eg.selfAccount.id);
        await writer.drainForTesting();

        setup1.conn.prepare(json: GetChannelTopicsResult(topics: [
          eg.getChannelTopicsEntry(name: 'Alpha', maxId: 100),
          eg.getChannelTopicsEntry(name: 'Beta', maxId: 90),
        ]).toJson());
        final store1 = setup1.um.store;
        await store1.topics.getChannelTopics(channel.streamId);
        await store1.handleEvent(eg.deleteMessageEvent([
          eg.streamMessage(id: 100, stream: channel, topic: 'Alpha'),
        ]));
        await store1.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: [eg.streamMessage(id: 90, stream: channel, topic: 'Beta')],
          newTopicStr: 'Gamma',
          propagateMode: PropagateMode.changeOne,
        ));
        await writer.drainForTesting();

        setup1.um.dispose();
        final setup2 = await startDbStore(
          existingGlobal: setup1.global,
          allowPersisted: true,
          streams: [channel],
          subscriptions: [eg.subscription(channel)],
        );
        async.elapse(Duration.zero);
        await writer.drainForTesting();
        check(await setup2.um.store.loadSavedTopics(channel.streamId))
          .isNotNull()
          .unorderedMatches([
            isChannelTopicsEntry('Alpha', 100),
            isChannelTopicsEntry('Beta', 90),
            isChannelTopicsEntry('Gamma', 90),
          ]);
      }));

      test('show saved topics immediately when offline', () => awaitFakeAsync((async) async {
        TestZulipBinding.instance.connectivityResult = const [ConnectivityResult.none];
        addTearDown(TestZulipBinding.instance.reset);

        final setup = await startDbStore(
          streams: [channel],
          subscriptions: [eg.subscription(channel)],
        );
        async.elapse(Duration.zero);
        final dbStore = setup.um.store;
        final conn = setup.conn;
        final writer = setup.global.backend.messageDbWriterForAccount(eg.selfAccount.id);

        await dbStore.handleEvent(MessageEvent(
          id: 11,
          localMessageId: null,
          message: eg.streamMessage(id: 25, stream: channel, topic: 'instant topic', sender: eg.selfUser),
        ));
        await writer.drainForTesting();

        // Request still in flight (delayed), but hasConnectivity == false shows saved topics immediately.
        conn.prepare(
          delay: const Duration(seconds: 2),
          json: GetChannelTopicsResult(topics: [
            eg.getChannelTopicsEntry(name: 'live topic', maxId: 30),
          ]).toJson(),
        );
        final dbView = TopicListView.init(store: dbStore, channelId: channel.streamId);
        final fetchFuture = dbView.fetch();
        async.flushMicrotasks();

        check(dbView)
          ..showingSavedTopics.isTrue()
          ..fetchFailing.isFalse()
          ..topics.isNotNull().single.which(isChannelTopicsEntry('instant topic', 25));

        async.elapse(const Duration(seconds: 2));
        await fetchFuture;
        check(dbView)
          ..showingSavedTopics.isFalse()
          ..topics.isNotNull().single.which(isChannelTopicsEntry('live topic', 30));
        dbView.dispose();
      }));
    });
  });
}

extension TopicListViewChecks on Subject<TopicListView> {
  Subject<List<GetChannelTopicsEntry>?> get topics => has((x) => x.topics, 'topics');
  Subject<bool> get showingSavedTopics => has((x) => x.showingSavedTopics, 'showingSavedTopics');
  Subject<bool> get fetchFailing => has((x) => x.fetchFailing, 'fetchFailing');
}

extension TopicsChecks on Subject<Topics> {
  Subject<List<GetChannelTopicsEntry>?> channelTopics(int channelId) => has((x) => x.channelTopics(channelId), 'channelTopics');
}
