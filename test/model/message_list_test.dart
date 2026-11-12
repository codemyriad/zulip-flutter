import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:test/scaffolding.dart';
import 'package:zulip/api/backoff.dart';
import 'package:zulip/api/exception.dart';
import 'package:zulip/api/model/events.dart';
import 'package:zulip/api/model/initial_snapshot.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/api/model/narrow.dart';
import 'package:zulip/api/model/submessage.dart';
import 'package:zulip/api/route/messages.dart';
import 'package:zulip/model/algorithms.dart';
import 'package:zulip/model/binding.dart';
import 'package:zulip/model/cached_messages.dart';
import 'package:zulip/model/connectivity.dart';
import 'package:zulip/model/content.dart';
import 'package:zulip/model/database.dart';
import 'package:zulip/model/message.dart';
import 'package:zulip/model/message_list.dart';
import 'package:zulip/model/narrow.dart';
import 'package:zulip/model/store.dart';

import '../api/fake_api.dart';
import '../api/model/model_checks.dart';
import '../api/model/submessage_checks.dart';
import '../example_data.dart' as eg;
import '../fake_async.dart';
import '../stdlib_checks.dart';
import 'binding.dart';
import 'content_checks.dart';
import 'message_checks.dart';
import 'store_checks.dart';
import 'recent_senders_test.dart' as recent_senders_test;
import 'test_store.dart';

const newestResult = eg.newestGetMessagesResult;
const nearResult = eg.nearGetMessagesResult;
const olderResult = eg.olderGetMessagesResult;
const newerResult = eg.newerGetMessagesResult;

/// The expected effect on a [MessageListView] when messages are moved
/// and the move may change whether they're muted.
enum _VisibilityEffect { unaffected, reprocessed, removed, refetched }

void main() {
  // Arrange for errors caught within the Flutter framework to be printed
  // unconditionally, rather than throttled as they normally are in an app.
  //
  // When using `testWidgets` from flutter_test, this is done automatically;
  // compare the [FlutterError.dumpErrorToConsole] call sites,
  // and [FlutterError.onError=] and [debugPrint=] call sites, in flutter_test.
  //
  // This test file is unusual in needing this manual arrangement; it's needed
  // because these aren't widget tests, and yet do have some failures arise as
  // exceptions that get caught by the framework: namely, when [checkInvariants]
  // throws from within an `addListener` callback.  Those exceptions get caught
  // by [ChangeNotifier.notifyListeners] and reported there through
  // [FlutterError.reportError].
  debugPrint = debugPrintSynchronously;
  FlutterError.onError = (details) {
    FlutterError.dumpErrorToConsole(details, forceReport: true);
  };

  TestZulipBinding.ensureInitialized();

  // These variables are the common state operated on by each test.
  // Each test case calls [prepare] to initialize them.
  late Subscription subscription;
  late TestGlobalStore globalStore;
  late TestGlobalStoreBackend backend;
  late PerAccountStore store;
  late FakeApiConnection connection;
  late MessageListView model;
  late int notifiedCount;

  void checkNotified({required int count}) {
    check(notifiedCount).equals(count);
    notifiedCount = 0;
  }
  void checkNotNotified() {
    checkInvariants(model);
    checkNotified(count: 0);
  }
  void checkNotifiedOnce() => checkNotified(count: 1);

  /// Initialize [model] and the rest of the test state.
  Future<void> prepare({
    Narrow narrow = const CombinedFeedNarrow(),
    Anchor anchor = AnchorCode.newest,
    List<int>? starredMessages,
    UnreadMessagesSnapshot? unreadMsgs,
    ZulipStream? stream,
    List<User>? users,
    List<int>? mutedUserIds,
  }) async {
    stream ??= eg.stream(streamId: eg.defaultStreamMessageStreamId);
    subscription = eg.subscription(stream);
    globalStore = eg.globalStore(accounts: [eg.selfAccount]);
    backend = globalStore.backend;
    store = eg.store(globalStore: globalStore,
      initialSnapshot: eg.initialSnapshot(
        starredMessages: starredMessages, unreadMsgs: unreadMsgs));
    await store.addStream(stream);
    await store.addSubscription(subscription);
    await store.addUsers([...?users, eg.selfUser]);
    if (mutedUserIds != null) {
      await store.setMutedUsers(mutedUserIds);
    }
    connection = store.connection as FakeApiConnection;
    notifiedCount = 0;
    model = MessageListView.init(store: store, narrow: narrow, anchor: anchor)
      ..addListener(() {
        checkInvariants(model);
        notifiedCount++;
      });
    check(model).fetched.isFalse();
    checkNotNotified();
  }

  /// Perform the initial message fetch for [model].
  ///
  /// The test case must have already called [prepare] to initialize the state.
  Future<void> prepareMessages({
    bool? foundOldest,
    bool? foundNewest,
    int? anchorMessageId,
    required List<Message> messages,
  }) async {
    final result = eg.getMessagesResult(
      anchor: model.anchor == AnchorCode.firstUnread
        ? NumericAnchor(anchorMessageId!) : model.anchor,
      foundOldest: foundOldest,
      foundNewest: foundNewest,
      messages: messages);
    connection.prepare(json: result.toJson());
    await model.fetchInitial();
    checkNotifiedOnce();
  }

  Future<void> prepareOutboxMessages({
    required int count,
    required ZulipStream stream,
    String topic = 'some topic',
  }) async {
    for (int i = 0; i < count; i++) {
      // Distinct IDs, as distinct sent messages would have.
      connection.prepare(json: SendMessageResult(id: 123 + i).toJson());
      await store.sendMessage(
        destination: StreamDestination(stream.streamId, eg.t(topic)),
        content: 'content');
    }
  }

  Future<void> prepareOutboxMessagesTo(List<MessageDestination> destinations) async {
    for (final (i, destination) in destinations.indexed) {
      // Distinct IDs, as distinct sent messages would have.
      connection.prepare(json: SendMessageResult(id: 123 + i).toJson());
      await store.sendMessage(destination: destination, content: 'content');
    }
  }

  void checkLastRequest({
    required ApiNarrow narrow,
    required String anchor,
    bool? includeAnchor,
    required int numBefore,
    required int numAfter,
    required bool allowEmptyTopicName,
  }) {
    check(connection.lastRequest).isA<http.Request>()
      ..method.equals('GET')
      ..url.path.equals('/api/v1/messages')
      ..url.queryParameters.deepEquals({
        'narrow': jsonEncode(resolveApiNarrowForServer(narrow, connection.zulipFeatureLevel!)),
        'anchor': anchor,
        if (includeAnchor != null) 'include_anchor': includeAnchor.toString(),
        'num_before': numBefore.toString(),
        'num_after': numAfter.toString(),
        'allow_empty_topic_name': allowEmptyTopicName.toString(),
      });
  }

  void checkHasMessageIds(Iterable<int> messageIds) {
    check(model.messages.map((m) => m.id)).deepEquals(messageIds);
  }

  void checkHasMessages(Iterable<Message> messages) {
    checkHasMessageIds(messages.map((e) => e.id));
  }

  group('fetchInitial', () {
    final someChannel = eg.stream();
    const someTopic = 'some topic';

    final otherChannel = eg.stream();
    const otherTopic = 'other topic';

    group('smoke', () {
      Future<void> smoke(
        Narrow narrow,
        Message Function(int i) generateMessages,
      ) async {
        await prepare(narrow: narrow);
        connection.prepare(json: newestResult(
          foundOldest: false,
          messages: List.generate(kMessageListFetchBatchSize, generateMessages),
        ).toJson());
        final fetchFuture = model.fetchInitial();
        check(model).fetched.isFalse();

        checkNotNotified();
        await fetchFuture;
        checkNotifiedOnce();
        check(model)
          ..messages.length.equals(kMessageListFetchBatchSize)
          ..haveOldest.isFalse()
          ..haveNewest.isTrue();
        checkLastRequest(
          narrow: narrow.apiEncode(),
          anchor: 'newest',
          numBefore: kMessageListFetchBatchSize,
          numAfter: kMessageListFetchBatchSize,
          allowEmptyTopicName: true,
        );
      }

      test('CombinedFeedNarrow', () async {
        await smoke(const CombinedFeedNarrow(), (i) => eg.streamMessage());
      });

      test('TopicNarrow', () async {
        await smoke(TopicNarrow(someChannel.streamId, eg.t(someTopic)),
          (i) => eg.streamMessage(stream: someChannel, topic: someTopic));
      });
    });

    test('disposed before the fetch completes', () async {
      await prepare();
      connection.prepare(json: newestResult(
        foundOldest: true, messages: [eg.streamMessage()]).toJson());
      final fetchFuture = model.fetchInitial();
      model.dispose();

      // If the fetch went on to call notifyListeners on the disposed model,
      // that error would fail this test.
      await fetchFuture;
    });

    test('short history', () async {
      await prepare();
      connection.prepare(json: newestResult(
        foundOldest: true,
        messages: List.generate(30, (i) => eg.streamMessage()),
      ).toJson());
      await model.fetchInitial();
      checkNotifiedOnce();
      check(model)
        ..messages.length.equals(30)
        ..haveOldest.isTrue()
        ..haveNewest.isTrue();
    });

    test('early in history', () async {
      await prepare(anchor: NumericAnchor(1000));
      connection.prepare(json: nearResult(
        anchor: 1000, foundOldest: true, foundNewest: false,
        messages: List.generate(111, (i) => eg.streamMessage(id: 990 + i)),
      ).toJson());
      await model.fetchInitial();
      checkNotifiedOnce();
      check(model)
        ..messages.length.equals(111)
        ..haveOldest.isTrue()
        ..haveNewest.isFalse();
    });

    test('no messages found', () async {
      await prepare();
      connection.prepare(json: newestResult(
        foundOldest: true,
        messages: [],
      ).toJson());
      await model.fetchInitial();
      checkNotifiedOnce();
      check(model)
        ..fetched.isTrue()
        ..messages.isEmpty()
        ..haveOldest.isTrue()
        ..haveNewest.isTrue();
    });

    group('sends proper anchor', () {
      Future<void> checkFetchWithAnchor(Anchor anchor) async {
        await prepare(anchor: anchor);
        // This prepared response isn't entirely realistic, depending on the anchor.
        // That's OK; these particular tests don't use the details of the response.
        connection.prepare(json:
          newestResult(foundOldest: true, messages: []).toJson());
        await model.fetchInitial();
        checkNotifiedOnce();
        check(connection.lastRequest).isA<http.Request>()
          .url.queryParameters['anchor']
            .equals(anchor.toJson());
      }

      test('oldest',      () => checkFetchWithAnchor(AnchorCode.oldest));
      test('firstUnread', () => checkFetchWithAnchor(AnchorCode.firstUnread));
      test('newest',      () => checkFetchWithAnchor(AnchorCode.newest));
      test('numeric',     () => checkFetchWithAnchor(NumericAnchor(12345)));
    });

    test('no messages found in fetch; outbox messages present', () => awaitFakeAsync((async) async {
      final stream = eg.stream();
      await prepare(
        narrow: eg.topicNarrow(stream.streamId, 'topic'), stream: stream);

      await prepareOutboxMessages(count: 1, stream: stream, topic: 'topic');
      async.elapse(kLocalEchoDebounceDuration);
      checkNotNotified();
      check(model)
        ..fetched.isFalse()
        ..outboxMessages.isEmpty();

      connection.prepare(
        json: newestResult(foundOldest: true, messages: []).toJson());
      await model.fetchInitial();
      checkNotifiedOnce();
      check(model)
        ..fetched.isTrue()
        ..outboxMessages.length.equals(1);
    }));

    test('some messages found in fetch; outbox messages present', () => awaitFakeAsync((async) async {
      final stream = eg.stream();
      await prepare(
        narrow: eg.topicNarrow(stream.streamId, 'topic'), stream: stream);

      await prepareOutboxMessages(count: 1, stream: stream, topic: 'topic');
      async.elapse(kLocalEchoDebounceDuration);
      checkNotNotified();
      check(model)
        ..fetched.isFalse()
        ..outboxMessages.isEmpty();

      connection.prepare(json: newestResult(foundOldest: true,
        messages: [eg.streamMessage(stream: stream, topic: 'topic')]).toJson());
      await model.fetchInitial();
      checkNotifiedOnce();
      check(model)
        ..fetched.isTrue()
        ..outboxMessages.length.equals(1);
    }));

    test('sent message found in fetch; outbox message removed', () => awaitFakeAsync((async) async {
      final stream = eg.stream();
      await prepare(
        narrow: eg.topicNarrow(stream.streamId, 'topic'), stream: stream);

      await prepareOutboxMessages(count: 1, stream: stream, topic: 'topic');
      final messageId = store.outboxMessages.values.single.messageId!;
      async.elapse(kLocalEchoDebounceDuration);
      checkNotNotified();
      check(model)
        ..fetched.isFalse()
        ..outboxMessages.isEmpty();

      // The fetch finds the message the outbox message was sent as
      // (see [OutboxMessage.messageId]).  The view must show it just once,
      // with no stale outbox copy.
      connection.prepare(json: newestResult(foundOldest: true, messages: [
        eg.streamMessage(id: messageId, stream: stream, topic: 'topic',
          sender: eg.selfUser)]).toJson());
      await model.fetchInitial();
      checkNotifiedOnce();
      check(store.outboxMessages).isEmpty();
      check(model)
        ..fetched.isTrue()
        ..outboxMessages.isEmpty()
        ..messages.single.id.equals(messageId);
    }));

    test('outbox messages not added until haveNewest', () => awaitFakeAsync((async) async {
      final stream = eg.stream();
      await prepare(
        narrow: eg.topicNarrow(stream.streamId, 'topic'),
        anchor: AnchorCode.firstUnread,
        stream: stream);

      await prepareOutboxMessages(count: 1, stream: stream, topic: 'topic');
      async.elapse(kLocalEchoDebounceDuration);
      checkNotNotified();
      check(model)..fetched.isFalse()..outboxMessages.isEmpty();

      final message = eg.streamMessage(stream: stream, topic: 'topic');
      connection.prepare(json: nearResult(
        anchor: message.id,
        foundOldest: true,
        foundNewest: false,
        messages: [message]).toJson());
      await model.fetchInitial();
      checkNotifiedOnce();
      check(model)..fetched.isTrue()..haveNewest.isFalse()..outboxMessages.isEmpty();

      connection.prepare(json: newerResult(anchor: message.id, foundNewest: true,
        messages: [eg.streamMessage(stream: stream, topic: 'topic')]).toJson());
      final fetchFuture = model.fetchNewer();
      checkNotifiedOnce();
      await fetchFuture;
      checkNotifiedOnce();
      check(model)..haveNewest.isTrue()..outboxMessages.length.equals(1);
    }));

    test('ignore [OutboxMessage]s outside narrow or with `hidden: true`', () => awaitFakeAsync((async) async {
      final stream = eg.stream();
      final otherStream = eg.stream();
      await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
      await store.setUserTopic(stream, 'muted', UserTopicVisibilityPolicy.muted);
      await prepareOutboxMessagesTo([
        StreamDestination(stream.streamId, eg.t('topic')),
        StreamDestination(stream.streamId, eg.t('muted')),
        StreamDestination(otherStream.streamId, eg.t('topic')),
      ]);
      async.elapse(kLocalEchoDebounceDuration);
      checkNotNotified();

      await prepareOutboxMessagesTo(
        [StreamDestination(stream.streamId, eg.t('topic'))]);
      assert(store.outboxMessages.values.last.hidden);

      connection.prepare(json:
        newestResult(foundOldest: true, messages: []).toJson());
      await model.fetchInitial();
      checkNotifiedOnce();
      check(model).outboxMessages.single.isA<StreamOutboxMessage>().conversation
        ..streamId.equals(stream.streamId)
        ..topic.equals(eg.t('topic'));
    }));

    // TODO(#824): move this test
    test('recent senders track all the messages', () async {
      const narrow = CombinedFeedNarrow();
      await prepare(narrow: narrow);
      final messages = [
        eg.streamMessage(),
        // Not subscribed to the stream with id 10.
        eg.streamMessage(stream: eg.stream(streamId: 10)),
      ];
      connection.prepare(json: newestResult(
        foundOldest: false,
        messages: messages,
      ).toJson());
      await model.fetchInitial();

      check(model).messages.length.equals(1);
      recent_senders_test.checkMatchesMessages(store.recentSenders, messages);
    });

    group('topic permalinks', () {
      test('if redirect, we follow it and remove "with" element', () async {
        await prepare(narrow: TopicNarrow(someChannel.streamId, eg.t(someTopic), with_: 1));
        connection.prepare(json: newestResult(
          foundOldest: false,
          messages: [eg.streamMessage(id: 1, stream: otherChannel, topic: otherTopic)],
        ).toJson());
        await model.fetchInitial();
        checkNotifiedOnce();
        check(model).narrow
          .equals(TopicNarrow(otherChannel.streamId, eg.t(otherTopic)));
      });

      test('if no redirect, we still remove "with" element', () async {
        await prepare(narrow: TopicNarrow(someChannel.streamId, eg.t(someTopic), with_: 1));
        connection.prepare(json: newestResult(
          foundOldest: false,
          messages: [eg.streamMessage(id: 1, stream: someChannel, topic: someTopic)],
        ).toJson());
        await model.fetchInitial();
        checkNotifiedOnce();
        check(model).narrow
          .equals(TopicNarrow(someChannel.streamId, eg.t(someTopic)));
      });
    });

    group('retry', () {
      void prepareNetworkException() {
        connection.prepare(httpException: const SocketException('failed'));
      }

      void prepareSuccess(List<Message> messages) {
        connection.prepare(json: newestResult(
          foundOldest: true, messages: messages).toJson());
      }

      test('retry after failure, then succeed', () => awaitFakeAsync((async) async {
        await prepare();
        final message = eg.streamMessage();
        prepareNetworkException();
        prepareNetworkException();
        prepareSuccess([message]);
        final fetchFuture = model.fetchInitial();
        async.elapse(Duration.zero);
        check(connection.takeRequests()).single;
        checkNotifiedOnce();
        check(model)
          ..fetched.isFalse()
          ..fetchInitialFailing.isTrue();
        check(async.pendingTimers).single; // the backoff

        // Wait out the first and second backoffs, at most 100ms and 200ms.
        async.elapse(const Duration(milliseconds: 300));
        check(connection.takeRequests()).length.equals(2);
        checkNotifiedOnce();
        check(model)
          ..fetched.isTrue()
          ..fetchInitialFailing.isFalse()
          ..messages.single.id.equals(message.id);
        await fetchFuture;
        check(async.pendingTimers).isEmpty();
      }));

      void checkRetry(void Function() prepareError) {
        awaitFakeAsync((async) async {
          await prepare();
          prepareError();
          final fetchFuture = model.fetchInitial();
          async.elapse(Duration.zero);
          check(connection.takeRequests()).single;
          checkNotifiedOnce();
          check(model).fetchInitialFailing.isTrue();

          prepareSuccess([eg.streamMessage()]);
          async.elapse(const Duration(milliseconds: 100)); // max first backoff
          check(connection.takeRequests()).single;
          checkNotifiedOnce();
          check(model).fetched.isTrue();
          await fetchFuture;
        });
      }

      test('retry on NetworkException from failed connection', () {
        checkRetry(prepareNetworkException);
      });

      test('retry on NetworkException with NetworkExceptionKind.other', () {
        checkRetry(() => connection.prepare(
          httpException: const HandshakeException('handshake failed')));
      });

      test('retry on Server5xxException', () {
        checkRetry(() => connection.prepare(httpStatus: 500, body: 'splat'));
      });

      test('retry on MalformedServerResponseException', () {
        // As from a captive portal, serving its own page in place of ours.
        checkRetry(() => connection.prepare(httpStatus: 200,
          body: '<html><body>Please log in to this network.</body></html>'));
      });

      test('retry on rate limit: code RATE_LIMIT_HIT', () {
        checkRetry(() => connection.prepare(httpStatus: 400, json: {
          'result': 'error', 'code': 'RATE_LIMIT_HIT',
          'msg': 'API usage exceeded rate limit',
          'retry-after': 28.706807374954224}));
      });

      test('retry on rate limit: status 429 ZulipApiException', () {
        checkRetry(() => connection.prepare(httpStatus: 429, json: {
          'result': 'error', 'code': 'BAD_REQUEST', 'msg': 'Bad request'}));
      });

      test('no retry on generic ZulipApiException', () => awaitFakeAsync((async) async {
        await prepare();
        connection.prepare(apiException: eg.apiBadRequest());
        await check(model.fetchInitial()).throws<ZulipApiException>();
        check(connection.takeRequests()).single;
        checkNotNotified();
        check(model).fetched.isFalse();
        check(async.pendingTimers).isEmpty();
      }));

      test('no retry when a test forgot to prepare a response', () => awaitFakeAsync((async) async {
        await prepare();
        await check(model.fetchInitial()).throws<AssertionError>();
        check(connection.takeRequests()).single;
        check(async.pendingTimers).isEmpty();
      }));

      test('disposed during request: request aborted', () => awaitFakeAsync((async) async {
        await prepare();
        connection.prepare(json: newestResult(foundOldest: true,
          messages: [eg.streamMessage()]).toJson(),
          delay: const Duration(seconds: 60));
        bool done = false;
        unawaited(model.fetchInitial().whenComplete(() => done = true));
        async.flushMicrotasks();
        check(connection.takeRequests()).single;

        model.dispose();
        async.flushMicrotasks();
        check(done).isTrue();
        check(connection.takeRequests()).isEmpty();
      }));

      test('disposed during backoff: no retry, no timer left', () => awaitFakeAsync((async) async {
        await prepare();
        prepareNetworkException();
        final fetchFuture = model.fetchInitial();
        async.elapse(Duration.zero);
        check(connection.takeRequests()).single;
        check(async.pendingTimers).single; // the backoff

        model.dispose();
        async.flushMicrotasks();
        check(async.pendingTimers).isEmpty();
        await fetchFuture;
        check(connection.takeRequests()).isEmpty();
      }));

      test('store disposed during backoff: no retry', () => awaitFakeAsync((async) async {
        await prepare();
        prepareNetworkException();
        final fetchFuture = model.fetchInitial();
        async.elapse(Duration.zero);
        check(connection.takeRequests()).single;
        check(async.pendingTimers).single; // the backoff

        checkNotifiedOnce(); // fetchInitialFailing
        store.dispose();
        async.elapse(const Duration(seconds: 1));
        await fetchFuture;
        check(connection.takeRequests()).isEmpty();
        check(notifiedCount).equals(0);
      }));

      test('retry promptly when the event stream recovers', () => awaitFakeAsync((async) async {
        BackoffMachine.debugDuration = const Duration(seconds: 10);
        addTearDown(() => BackoffMachine.debugDuration = null);
        await prepare();
        prepareNetworkException();
        final fetchFuture = model.fetchInitial();
        async.elapse(Duration.zero);
        check(connection.takeRequests()).single;
        check(async.pendingTimers).single; // the backoff

        checkNotifiedOnce(); // fetchInitialFailing
        store.isRecoveringEventStream = true;
        async.elapse(const Duration(seconds: 1));
        check(connection.takeRequests()).isEmpty();

        prepareSuccess([eg.streamMessage()]);
        store.isRecoveringEventStream = false;
        async.elapse(Duration.zero);
        check(connection.takeRequests()).single;
        checkNotifiedOnce();
        check(model).fetched.isTrue();
        await fetchFuture;
      }));

      test('backoff starts over when the event stream recovers', () => awaitFakeAsync((async) async {
        // Fail enough times that the backoff bound grows to 6.4s.
        BackoffMachine.debugDuration = const Duration(seconds: 1);
        addTearDown(() => BackoffMachine.debugDuration = null);
        await prepare();
        prepareNetworkException();
        final fetchFuture = model.fetchInitial();
        async.elapse(Duration.zero);
        for (int i = 0; i < 5; i++) {
          prepareNetworkException();
          async.elapse(const Duration(seconds: 1));
        }
        check(connection.takeRequests()).length.equals(6);

        BackoffMachine.debugDuration = null;
        prepareNetworkException();
        store.isRecoveringEventStream = true;
        store.isRecoveringEventStream = false;
        async.elapse(Duration.zero);
        check(connection.takeRequests()).single;

        // The next backoff is at most 100ms, as for a first failure.
        prepareSuccess([eg.streamMessage()]);
        async.elapse(const Duration(milliseconds: 100));
        check(connection.takeRequests()).single;
        check(model).fetched.isTrue();
        await fetchFuture;
      }));

      group('request maybe stuck on a dead connection', () {
        // A request that would never complete on its own.
        void prepareStuck() {
          connection.prepare(json: newestResult(foundOldest: true,
            messages: [eg.streamMessage()]).toJson(),
            delay: const Duration(minutes: 15));
        }

        test('sent while event stream recovering: abort on recovery, and retry', () => awaitFakeAsync((async) async {
          await prepare();
          store.isRecoveringEventStream = true;
          prepareStuck();
          final fetchFuture = model.fetchInitial();
          async.elapse(Duration.zero);
          check(connection.takeRequests()).single;

          async.elapse(kShowCachedMessagesDelay);
          check(connection.takeRequests()).isEmpty();

          final message = eg.streamMessage();
          prepareSuccess([message]);
          store.isRecoveringEventStream = false;
          async.elapse(Duration.zero);
          check(connection.takeRequests()).single;
          checkNotifiedOnce();
          check(model).messages.single.id.equals(message.id);
          await fetchFuture;
        }));

        test('sent while event stream recovering, recently: no abort on recovery', () => awaitFakeAsync((async) async {
          // As on startup from stored server data: the event stream is
          // recovering until the first poll succeeds, even when the network
          // is fine, and a request sent meanwhile is likely fine too.
          await prepare();
          store.isRecoveringEventStream = true;
          connection.prepare(json: newestResult(foundOldest: true,
            messages: [eg.streamMessage()]).toJson(),
            delay: kShowCachedMessagesDelay);
          final fetchFuture = model.fetchInitial();
          async.elapse(kShowCachedMessagesDelay - const Duration(milliseconds: 1));
          check(connection.takeRequests()).single;

          store.isRecoveringEventStream = false;
          async.elapse(Duration.zero);
          check(connection.takeRequests()).isEmpty();
          check(model).fetched.isFalse();

          async.elapse(const Duration(milliseconds: 1));
          checkNotifiedOnce();
          check(model).fetched.isTrue();
          check(connection.takeRequests()).isEmpty();
          await fetchFuture;
        }));

        test('sent before network change: abort on retry signal, and retry', () => awaitFakeAsync((async) async {
          addTearDown(testBinding.reset);
          await prepare();
          prepareStuck();
          final fetchFuture = model.fetchInitial();
          async.elapse(Duration.zero);
          check(connection.takeRequests()).single;

          prepareSuccess([eg.streamMessage()]);
          testBinding.notifyConnectivityChanged([ConnectivityResult.mobile]);
          async.elapse(Duration.zero);
          check(connection.takeRequests()).single;
          checkNotifiedOnce();
          check(model).fetched.isTrue();
          await fetchFuture;
        }));

        test('sent after network change: no abort on retry signal', () => awaitFakeAsync((async) async {
          addTearDown(testBinding.reset);
          await prepare();
          async.elapse(Duration.zero); // connectivity baseline
          testBinding.notifyConnectivityChanged([ConnectivityResult.mobile]);
          async.elapse(Duration.zero);
          // A change during the cooldown is signaled when the cooldown ends.
          testBinding.notifyConnectivityChanged([ConnectivityResult.wifi]);
          async.elapse(Duration.zero);
          connection.prepare(json: newestResult(foundOldest: true,
            messages: [eg.streamMessage()]).toJson(),
            delay: ConnectivityMonitor.retrySignalCooldown * 2);
          final fetchFuture = model.fetchInitial();
          async.elapse(Duration.zero);
          check(connection.takeRequests()).single;

          async.elapse(ConnectivityMonitor.retrySignalCooldown);
          check(connection.takeRequests()).isEmpty();
          check(model).fetched.isFalse();

          async.elapse(ConnectivityMonitor.retrySignalCooldown);
          checkNotifiedOnce();
          check(model).fetched.isTrue();
          check(connection.takeRequests()).isEmpty();
          await fetchFuture;
        }));

        test('not sent while recovering: no abort on recovery; if it fails, retry at once', () => awaitFakeAsync((async) async {
          BackoffMachine.debugDuration = const Duration(seconds: 10);
          addTearDown(() => BackoffMachine.debugDuration = null);
          await prepare();
          connection.prepare(httpException: const SocketException('failed'),
            delay: const Duration(seconds: 5));
          final fetchFuture = model.fetchInitial();
          async.elapse(Duration.zero);
          check(connection.takeRequests()).single;

          store.isRecoveringEventStream = true;
          store.isRecoveringEventStream = false;
          async.elapse(Duration.zero);
          check(connection.takeRequests()).isEmpty();

          prepareSuccess([eg.streamMessage()]);
          async.elapse(const Duration(seconds: 5));
          check(connection.takeRequests()).single;
          checkNotified(count: 2); // fetchInitialFailing, then fetched
          check(model).fetched.isTrue();
          await fetchFuture;
        }));
      });

      test('renarrowAndFetch during backoff: old loop stops', () => awaitFakeAsync((async) async {
        final channel = eg.stream();
        await prepare(stream: channel);
        prepareNetworkException();
        final fetchFuture = model.fetchInitial();
        async.elapse(Duration.zero);
        check(connection.takeRequests()).single;
        check(async.pendingTimers).single; // the backoff
        checkNotifiedOnce(); // fetchInitialFailing

        final message = eg.streamMessage(stream: channel);
        prepareSuccess([message]);
        model.renarrowAndFetch(ChannelNarrow(channel.streamId), AnchorCode.newest);
        checkNotifiedOnce();
        async.elapse(Duration.zero);
        await fetchFuture;
        check(connection.takeRequests()).single;
        checkNotifiedOnce();
        check(model)
          ..narrow.equals(ChannelNarrow(channel.streamId))
          ..messages.single.id.equals(message.id);

        // The old loop's backoff was cut short, and it made no request.
        check(async.pendingTimers).isEmpty();
        async.elapse(const Duration(seconds: 10));
        check(connection.takeRequests()).isEmpty();
      }));

      group('fetchInitialFailing', () {
        test('set on first failure; unchanged on more; cleared on success', () => awaitFakeAsync((async) async {
          // A fixed backoff, so that a short first wait and a short second wait
          // don't add up to make the second retry come early.
          BackoffMachine.debugDuration = const Duration(seconds: 1);
          addTearDown(() => BackoffMachine.debugDuration = null);
          await prepare();
          prepareNetworkException();
          final fetchFuture = model.fetchInitial();
          check(model).fetchInitialFailing.isFalse();
          async.elapse(Duration.zero);
          checkNotifiedOnce();
          check(model)
            ..fetched.isFalse()
            ..fetchInitialFailing.isTrue();

          prepareNetworkException();
          async.elapse(const Duration(seconds: 1));
          check(connection.takeRequests()).length.equals(2);
          checkNotNotified();
          check(model).fetchInitialFailing.isTrue();

          prepareSuccess([eg.streamMessage()]);
          async.elapse(const Duration(seconds: 1));
          checkNotifiedOnce();
          check(model)
            ..fetched.isTrue()
            ..fetchInitialFailing.isFalse();
          await fetchFuture;
        }));

        test('not set by aborting our own request', () => awaitFakeAsync((async) async {
          addTearDown(testBinding.reset);
          await prepare();
          async.elapse(Duration.zero); // connectivity baseline
          connection.prepare(json: newestResult(foundOldest: true,
            messages: [eg.streamMessage()]).toJson(),
            delay: const Duration(minutes: 15));
          final fetchFuture = model.fetchInitial();
          async.elapse(Duration.zero);
          check(connection.takeRequests()).single;

          // The network changes, so we abort the request and retry at once.
          prepareSuccess([eg.streamMessage()]);
          testBinding.notifyConnectivityChanged([ConnectivityResult.mobile]);
          async.flushMicrotasks();
          check(connection.takeRequests()).single;
          checkNotNotified();
          check(model).fetchInitialFailing.isFalse();

          async.elapse(Duration.zero);
          checkNotifiedOnce();
          check(model).fetched.isTrue();
          await fetchFuture;
        }));

        test('cleared on renarrowAndFetch', () => awaitFakeAsync((async) async {
          final channel = eg.stream();
          await prepare(stream: channel);
          prepareNetworkException();
          final fetchFuture = model.fetchInitial();
          async.elapse(Duration.zero);
          checkNotifiedOnce();
          check(model).fetchInitialFailing.isTrue();

          connection.prepare(json: newestResult(foundOldest: true,
            messages: [eg.streamMessage(stream: channel)]).toJson(),
            delay: const Duration(seconds: 1));
          model.renarrowAndFetch(ChannelNarrow(channel.streamId), AnchorCode.newest);
          checkNotifiedOnce();
          check(model)
            ..fetched.isFalse()
            ..fetchInitialFailing.isFalse();
          await fetchFuture;

          async.elapse(const Duration(seconds: 1));
          checkNotifiedOnce();
          check(model).fetched.isTrue();
        }));

        test('cleared on error not to retry', () => awaitFakeAsync((async) async {
          await prepare();
          prepareNetworkException();
          final fetchFuture = model.fetchInitial();
          final throwsCheck = check(fetchFuture).throws<ZulipApiException>();
          async.elapse(Duration.zero);
          checkNotifiedOnce();
          check(model).fetchInitialFailing.isTrue();

          connection.prepare(apiException: eg.apiBadRequest());
          async.elapse(const Duration(milliseconds: 100)); // max first backoff
          await throwsCheck;
          checkNotifiedOnce();
          check(model)
            ..fetched.isFalse()
            ..fetchInitialFailing.isFalse();
        }));

        test('not set on error not to retry', () => awaitFakeAsync((async) async {
          await prepare();
          connection.prepare(apiException: eg.apiBadRequest());
          await check(model.fetchInitial()).throws<ZulipApiException>();
          checkNotNotified();
          check(model).fetchInitialFailing.isFalse();
        }));
      });
    });
  });

  group('cached message fetches', () {
    final channel = eg.stream(streamId: eg.defaultStreamMessageStreamId);

    CachedMessageFetch? cachedFetchOf(Narrow narrow) =>
      backend.cachedMessageFetchOf(eg.selfAccount.id, messageFetchCacheKey(narrow)!);

    void seedCachedFetch(Narrow narrow, List<Message> messages) {
      backend.seedCachedMessageFetch(eg.selfAccount.id, messageFetchCacheKey(narrow)!,
        messages: messages);
    }

    /// Check that the messages stored for [narrow] are [expected],
    /// with the same data (except any polls; see cached_messages_test.dart).
    void checkCachedMessages(Narrow narrow, List<Message> expected) {
      Object? toJson(Message message) =>
        deepToJson(message) as Map<String, dynamic>..remove('submessages');
      final data = cachedFetchOf(narrow)?.data;
      check(data).isNotNull();
      check(decodeCachedMessages(data!).map(toJson))
        .deepEquals(expected.map(toJson));
    }

    group('store after fetchInitial', () {
      Future<void> checkStored(Narrow narrow, {
        Anchor anchor = AnchorCode.newest,
        required List<Message> messages,
      }) async {
        await prepare(narrow: narrow, anchor: anchor, stream: channel);
        connection.prepare(json:
          newestResult(foundOldest: true, messages: messages).toJson());
        await model.fetchInitial();
        checkCachedMessages(narrow, messages);
      }

      test('CombinedFeedNarrow', () => checkStored(const CombinedFeedNarrow(),
        messages: [eg.streamMessage(stream: channel), eg.dmMessage(from: eg.otherUser, to: [eg.selfUser])]));

      test('ChannelNarrow', () => checkStored(ChannelNarrow(channel.streamId),
        messages: [eg.streamMessage(stream: channel)]));

      test('TopicNarrow', () => checkStored(eg.topicNarrow(channel.streamId, 'topic'),
        messages: [eg.streamMessage(stream: channel, topic: 'topic')]));

      test('DmNarrow', () => checkStored(
        DmNarrow.withUser(eg.otherUser.userId, selfUserId: eg.selfUser.userId),
        messages: [eg.dmMessage(from: eg.otherUser, to: [eg.selfUser])]));

      test('MentionsNarrow', () => checkStored(const MentionsNarrow(),
        messages: [eg.streamMessage(stream: channel, flags: [MessageFlag.mentioned])]));

      test('StarredMessagesNarrow', () => checkStored(const StarredMessagesNarrow(),
        messages: [eg.streamMessage(stream: channel, flags: [MessageFlag.starred])]));

      test('anchor firstUnread', () => checkStored(const CombinedFeedNarrow(),
        anchor: AnchorCode.firstUnread,
        messages: [eg.streamMessage(stream: channel)]));

      test('anchor oldest, reaching the newest message', () => checkStored(
        const CombinedFeedNarrow(), anchor: AnchorCode.oldest,
        messages: [eg.streamMessage(stream: channel)]));

      test('numeric anchor, reaching the newest message', () => checkStored(
        const CombinedFeedNarrow(), anchor: NumericAnchor(1),
        messages: [eg.streamMessage(stream: channel)]));

      test('only the newest kCachedMessagesMaxCount messages', () async {
        const narrow = CombinedFeedNarrow();
        await prepare(narrow: narrow, anchor: AnchorCode.firstUnread, stream: channel);
        final messages = List.generate(kCachedMessagesMaxCount + 1,
          (_) => eg.streamMessage(stream: channel));
        connection.prepare(json: nearResult(anchor: messages[1].id,
          foundOldest: true, foundNewest: true, messages: messages).toJson());
        await model.fetchInitial();
        checkCachedMessages(narrow, messages.sublist(1));
      });

      test('visible messages only', () async {
        const narrow = CombinedFeedNarrow();
        await prepare(narrow: narrow, stream: channel);
        await store.setUserTopic(channel, 'muted', UserTopicVisibilityPolicy.muted);
        final messages = [
          eg.streamMessage(stream: channel, topic: 'muted'),
          eg.streamMessage(stream: channel, topic: 'visible'),
        ];
        connection.prepare(json:
          newestResult(foundOldest: true, messages: messages).toJson());
        await model.fetchInitial();
        checkCachedMessages(narrow, [messages[1]]);
      });

      test('not for keyword search', () async {
        await prepare(narrow: KeywordSearchNarrow('hello'), stream: channel);
        connection.prepare(json: newestResult(foundOldest: true,
          messages: [eg.streamMessage(stream: channel)]).toJson());
        await model.fetchInitial();
        check(backend.cachedMessageFetchKeysOf(eg.selfAccount.id)).isEmpty();
      });

      test('not when the result stops short of the newest message', () async {
        // As for an old unread in a busy topic.
        final narrow = eg.topicNarrow(channel.streamId, 'topic');
        await prepare(narrow: narrow, anchor: AnchorCode.firstUnread, stream: channel);
        seedCachedFetch(narrow, [eg.streamMessage(stream: channel, topic: 'topic')]);
        final stored = cachedFetchOf(narrow)!.data;
        final messages = [eg.streamMessage(stream: channel, topic: 'topic')];
        connection.prepare(json: nearResult(anchor: messages.single.id,
          foundOldest: true, foundNewest: false, messages: messages).toJson());
        await model.fetchInitial();
        check(cachedFetchOf(narrow)).isNotNull().data.deepEquals(stored);
      });

      test('topic permalink: store under the narrow redirected to', () async {
        final otherChannel = eg.stream();
        final message = eg.streamMessage(stream: otherChannel, topic: 'other');
        final narrow = TopicNarrow(channel.streamId, eg.t('topic'), with_: message.id);
        await prepare(narrow: narrow, stream: channel);
        connection.prepare(json: newestResult(foundOldest: true,
          messages: [message]).toJson());
        await model.fetchInitial();
        check(backend.cachedMessageFetchKeysOf(eg.selfAccount.id)).deepEquals([
          messageFetchCacheKey(TopicNarrow(otherChannel.streamId, eg.t('other')))]);
      });

      test('after a retry', () => awaitFakeAsync((async) async {
        final narrow = ChannelNarrow(channel.streamId);
        await prepare(narrow: narrow, stream: channel);
        connection.prepare(httpException: const SocketException('failed'));
        final messages = [eg.streamMessage(stream: channel)];
        connection.prepare(json:
          newestResult(foundOldest: true, messages: messages).toJson());
        final fetchFuture = model.fetchInitial();
        async.elapse(const Duration(milliseconds: 100)); // max first backoff
        await fetchFuture;
        checkCachedMessages(narrow, messages);
      }));
    });

    group('delete', () {
      test('on success with no messages', () async {
        final narrow = ChannelNarrow(channel.streamId);
        await prepare(narrow: narrow, stream: channel);
        seedCachedFetch(narrow, [eg.streamMessage(stream: channel)]);
        connection.prepare(json: newestResult(foundOldest: true,
          messages: []).toJson());
        await model.fetchInitial();
        check(cachedFetchOf(narrow)).isNull();
      });

      test('on ZulipApiException', () async {
        final narrow = ChannelNarrow(channel.streamId);
        await prepare(narrow: narrow, stream: channel);
        seedCachedFetch(narrow, [eg.streamMessage(stream: channel)]);
        connection.prepare(apiException: eg.apiBadRequest());
        await check(model.fetchInitial()).throws<ZulipApiException>();
        check(cachedFetchOf(narrow)).isNull();
      });

      test('on ZulipApiException, even with numeric anchor', () async {
        final narrow = ChannelNarrow(channel.streamId);
        await prepare(narrow: narrow, anchor: NumericAnchor(1), stream: channel);
        seedCachedFetch(narrow, [eg.streamMessage(stream: channel)]);
        connection.prepare(apiException: eg.apiBadRequest());
        await check(model.fetchInitial()).throws<ZulipApiException>();
        check(cachedFetchOf(narrow)).isNull();
      });

      test('not on retryable error', () => awaitFakeAsync((async) async {
        final narrow = ChannelNarrow(channel.streamId);
        await prepare(narrow: narrow, stream: channel);
        seedCachedFetch(narrow, [eg.streamMessage(stream: channel)]);
        connection.prepare(httpStatus: 500, body: 'splat');
        final fetchFuture = model.fetchInitial();
        async.elapse(Duration.zero);
        check(cachedFetchOf(narrow)).isNotNull();

        model.dispose();
        await fetchFuture;
      }));
    });

    group('show while fetchInitial retries', () {
      void prepareNetworkException() {
        connection.prepare(httpException: const SocketException('failed'));
      }

      void prepareSuccess(List<Message> messages, {Duration delay = Duration.zero}) {
        connection.prepare(delay: delay,
          json: newestResult(foundOldest: true, messages: messages).toJson());
      }

      void checkShowingCached(List<Message> messages) {
        check(model)
          ..showingCachedMessages.isTrue()
          ..fetched.isTrue()
          ..haveOldest.isFalse()
          ..haveNewest.isFalse()
          ..busyFetchingMore.isTrue();
        checkHasMessages(messages);
      }

      void checkWaiting() {
        check(model)
          ..showingCachedMessages.isFalse()
          ..fetched.isFalse();
      }

      /// Set up a [CombinedFeedNarrow] view with stored messages
      /// in [channel], and start [MessageListView.fetchInitial]
      /// with the request failing.
      ///
      /// The cached messages appear once the cache read finishes.
      Future<(Future<void>, List<Message>)> prepareFailingWithCache({
        Future<void>? loadGate,
      }) async {
        const narrow = CombinedFeedNarrow();
        await prepare(narrow: narrow, stream: channel);
        backend.loadCachedMessageFetchGate = loadGate;
        final cached = List.generate(3, (i) => eg.streamMessage(stream: channel));
        seedCachedFetch(narrow, cached);
        prepareNetworkException();
        final fetchFuture = model.fetchInitial();
        return (fetchFuture, cached);
      }

      test('show when request fails; replace when retry succeeds', () => awaitFakeAsync((async) async {
        final (fetchFuture, cached) = await prepareFailingWithCache();
        async.elapse(Duration.zero);
        checkNotifiedOnce();
        checkShowingCached(cached);
        check(model)
          ..oldestFetchedMessageId.isNull()
          ..newestFetchedMessageId.isNull();
        // The store doesn't learn of the cached messages.
        check(store.messages).isEmpty();

        final fresh = [cached.last, eg.streamMessage(stream: channel)];
        prepareSuccess(fresh);
        async.elapse(const Duration(milliseconds: 100)); // max first backoff
        checkNotifiedOnce();
        check(model)
          ..showingCachedMessages.isFalse()
          ..haveOldest.isTrue()
          ..haveNewest.isTrue()
          ..busyFetchingMore.isFalse();
        checkHasMessages(fresh);
        check(store.messages.keys).unorderedEquals(fresh.map((m) => m.id));
        await fetchFuture;
        check(async.pendingTimers).isEmpty();
      }));

      test('fetchOlder and fetchNewer do nothing while showing cached', () => awaitFakeAsync((async) async {
        final (fetchFuture, cached) = await prepareFailingWithCache();
        async.elapse(Duration.zero);
        checkNotifiedOnce();
        checkShowingCached(cached);
        connection.takeRequests();

        await model.fetchOlder();
        await model.fetchNewer();
        checkNotNotified();
        check(connection.takeRequests()).isEmpty();

        model.dispose();
        await fetchFuture;
      }));

      test('show after kShowCachedMessagesDelay while request is pending', () => awaitFakeAsync((async) async {
        const narrow = CombinedFeedNarrow();
        await prepare(narrow: narrow, stream: channel);
        final cached = [eg.streamMessage(stream: channel)];
        seedCachedFetch(narrow, cached);
        final fresh = [eg.streamMessage(stream: channel)];
        prepareSuccess(fresh, delay: kShowCachedMessagesDelay * 2);
        final fetchFuture = model.fetchInitial();

        async.elapse(kShowCachedMessagesDelay - const Duration(milliseconds: 1));
        checkNotNotified();
        checkWaiting();

        async.elapse(const Duration(milliseconds: 1));
        checkNotifiedOnce();
        checkShowingCached(cached);

        async.elapse(kShowCachedMessagesDelay);
        checkNotifiedOnce();
        check(model).showingCachedMessages.isFalse();
        checkHasMessages(fresh);
        await fetchFuture;
      }));

      test('fetchInitialFailing not set when request fails while showing cached', () => awaitFakeAsync((async) async {
        const narrow = CombinedFeedNarrow();
        await prepare(narrow: narrow, stream: channel);
        final cached = [eg.streamMessage(stream: channel)];
        seedCachedFetch(narrow, cached);
        connection.prepare(httpException: const SocketException('failed'),
          delay: kShowCachedMessagesDelay * 2);
        final fetchFuture = model.fetchInitial();
        async.elapse(kShowCachedMessagesDelay);
        checkNotifiedOnce();
        checkShowingCached(cached);

        async.elapse(kShowCachedMessagesDelay);
        check(connection.takeRequests()).single;
        checkNotNotified();
        checkShowingCached(cached);
        check(model).fetchInitialFailing.isFalse();

        model.dispose();
        await fetchFuture;
      }));

      test('not shown when request succeeds sooner', () => awaitFakeAsync((async) async {
        const narrow = CombinedFeedNarrow();
        await prepare(narrow: narrow, stream: channel);
        seedCachedFetch(narrow, [eg.streamMessage(stream: channel)]);
        final fresh = [eg.streamMessage(stream: channel)];
        prepareSuccess(fresh, delay: kShowCachedMessagesDelay ~/ 2);
        final fetchFuture = model.fetchInitial();

        async.elapse(kShowCachedMessagesDelay ~/ 2);
        checkNotifiedOnce();
        checkHasMessages(fresh);
        await fetchFuture;
        check(async.pendingTimers).isEmpty();

        async.elapse(kShowCachedMessagesDelay);
        checkNotNotified();
        check(model).showingCachedMessages.isFalse();
      }));

      test('not shown at once on aborting a request that may be stuck', () => awaitFakeAsync((async) async {
        addTearDown(testBinding.reset);
        const narrow = CombinedFeedNarrow();
        await prepare(narrow: narrow, stream: channel);
        final cached = [eg.streamMessage(stream: channel)];
        seedCachedFetch(narrow, cached);
        async.elapse(Duration.zero); // connectivity baseline
        prepareSuccess([eg.streamMessage(stream: channel)],
          delay: const Duration(minutes: 15));
        final fetchFuture = model.fetchInitial();
        async.elapse(kShowCachedMessagesDelay ~/ 4);
        check(connection.takeRequests()).single;

        final fresh = [eg.streamMessage(stream: channel)];
        prepareSuccess(fresh, delay: kShowCachedMessagesDelay);
        testBinding.notifyConnectivityChanged([ConnectivityResult.mobile]);
        async.elapse(Duration.zero);
        check(connection.takeRequests()).single;
        checkNotNotified();
        checkWaiting();

        // The retry is slow, so the cached messages appear on the usual timer.
        async.elapse(kShowCachedMessagesDelay * 3 ~/ 4);
        checkNotifiedOnce();
        checkShowingCached(cached);

        async.elapse(kShowCachedMessagesDelay ~/ 4);
        checkNotifiedOnce();
        check(model).showingCachedMessages.isFalse();
        checkHasMessages(fresh);
        await fetchFuture;
      }));

      test('not shown at once while event stream is recovering', () => awaitFakeAsync((async) async {
        // On startup from stored server data, the event stream is recovering
        // until the first poll succeeds, even when the network is fine.
        // Showing the cached messages at once would make them flash by.
        const narrow = CombinedFeedNarrow();
        await prepare(narrow: narrow, stream: channel);
        seedCachedFetch(narrow, [eg.streamMessage(stream: channel)]);
        store.isRecoveringEventStream = true;
        final fresh = [eg.streamMessage(stream: channel)];
        prepareSuccess(fresh, delay: kShowCachedMessagesDelay ~/ 2);
        final fetchFuture = model.fetchInitial();

        async.elapse(Duration.zero);
        checkNotNotified();
        checkWaiting();

        async.elapse(kShowCachedMessagesDelay ~/ 2);
        checkNotifiedOnce();
        check(model).showingCachedMessages.isFalse();
        checkHasMessages(fresh);
        await fetchFuture;
      }));

      test('previousMessageIds: show once read, without waiting', () => awaitFakeAsync((async) async {
        const narrow = CombinedFeedNarrow();
        await prepare(narrow: narrow, stream: channel);
        final cached = [eg.streamMessage(stream: channel)];
        seedCachedFetch(narrow, cached);
        final fresh = [eg.streamMessage(stream: channel)];
        prepareSuccess(fresh, delay: kShowCachedMessagesDelay ~/ 2);
        final fetchFuture = model.fetchInitial(
          previousMessageIds: cached.map((m) => m.id).toSet());

        async.elapse(Duration.zero);
        checkNotifiedOnce();
        checkShowingCached(cached);

        async.elapse(kShowCachedMessagesDelay ~/ 2);
        checkNotifiedOnce();
        check(model).showingCachedMessages.isFalse();
        checkHasMessages(fresh);
        await fetchFuture;
        check(async.pendingTimers).isEmpty();
      }));

      test('previousMessageIds: show only those messages', () => awaitFakeAsync((async) async {
        // As when the previous view saw a message deleted,
        // after the fetch was stored, and the store doesn't know that.
        const narrow = CombinedFeedNarrow();
        await prepare(narrow: narrow, stream: channel);
        final cached = List.generate(3, (i) => eg.streamMessage(stream: channel));
        seedCachedFetch(narrow, cached);
        prepareSuccess([cached[0], cached[2]], delay: kShowCachedMessagesDelay ~/ 2);
        final fetchFuture = model.fetchInitial(
          previousMessageIds: {cached[0].id, cached[2].id});

        async.elapse(Duration.zero);
        checkNotifiedOnce();
        checkShowingCached([cached[0], cached[2]]);

        model.dispose();
        await fetchFuture;
      }));

      test('cache read finishes after request fails', () => awaitFakeAsync((async) async {
        final gate = Completer<void>();
        final (fetchFuture, cached) = await prepareFailingWithCache(loadGate: gate.future);
        async.elapse(Duration.zero);
        checkNotifiedOnce();
        checkWaiting();
        check(model).fetchInitialFailing.isTrue();

        gate.complete();
        async.flushMicrotasks();
        checkNotifiedOnce();
        checkShowingCached(cached);
        check(model).fetchInitialFailing.isFalse();

        model.dispose();
        await fetchFuture;
      }));

      test('cache read finishes after request succeeds: not shown', () => awaitFakeAsync((async) async {
        final gate = Completer<void>();
        const narrow = CombinedFeedNarrow();
        await prepare(narrow: narrow, stream: channel);
        backend.loadCachedMessageFetchGate = gate.future;
        seedCachedFetch(narrow, [eg.streamMessage(stream: channel)]);
        final fresh = [eg.streamMessage(stream: channel)];
        prepareSuccess(fresh);
        await model.fetchInitial();
        checkNotifiedOnce();

        gate.complete();
        async.elapse(kShowCachedMessagesDelay);
        checkNotNotified();
        check(model).showingCachedMessages.isFalse();
        checkHasMessages(fresh);
      }));

      test('disposed during cache read', () => awaitFakeAsync((async) async {
        final gate = Completer<void>();
        final (fetchFuture, _) = await prepareFailingWithCache(loadGate: gate.future);
        async.elapse(Duration.zero);
        checkNotifiedOnce(); // fetchInitialFailing

        model.dispose();
        gate.complete();
        async.flushMicrotasks();
        await fetchFuture;
        checkNotNotified();
        check(async.pendingTimers).isEmpty();
      }));

      test('store disposed during cache read', () => awaitFakeAsync((async) async {
        final gate = Completer<void>();
        final (fetchFuture, _) = await prepareFailingWithCache(loadGate: gate.future);
        async.elapse(Duration.zero);
        checkNotifiedOnce(); // fetchInitialFailing

        store.dispose();
        gate.complete();
        async.elapse(kShowCachedMessagesDelay);
        await fetchFuture;
        checkNotNotified();
        checkWaiting();
      }));

      test('renarrowAndFetch during cache read', () => awaitFakeAsync((async) async {
        final gate = Completer<void>();
        final (fetchFuture, _) = await prepareFailingWithCache(loadGate: gate.future);
        async.elapse(Duration.zero);
        checkNotifiedOnce(); // fetchInitialFailing

        final newNarrow = ChannelNarrow(channel.streamId);
        final fresh = [eg.streamMessage(stream: channel)];
        prepareSuccess(fresh);
        model.renarrowAndFetch(newNarrow, AnchorCode.newest);
        checkNotifiedOnce();
        async.elapse(Duration.zero);
        checkNotifiedOnce();
        checkHasMessages(fresh);

        gate.complete();
        async.elapse(kShowCachedMessagesDelay);
        await fetchFuture;
        checkNotNotified();
        check(model).showingCachedMessages.isFalse();
        checkHasMessages(fresh);
      }));

      test('renarrowAndFetch during cache read: new view shows its cache on time', () => awaitFakeAsync((async) async {
        final gate = Completer<void>();
        await prepare(narrow: const CombinedFeedNarrow(), stream: channel);
        backend.loadCachedMessageFetchGate = gate.future;
        connection.prepare(json: newestResult(foundOldest: true, messages: []).toJson(),
          delay: const Duration(minutes: 1));
        final fetchFuture = model.fetchInitial();
        async.elapse(Duration.zero);

        final newNarrow = ChannelNarrow(channel.streamId);
        final cached = [eg.streamMessage(stream: channel)];
        seedCachedFetch(newNarrow, cached);
        prepareSuccess([], delay: const Duration(minutes: 1));
        model.renarrowAndFetch(newNarrow, AnchorCode.newest);
        checkNotifiedOnce();
        await fetchFuture;

        // The old view's read finds nothing; the new view's finds its cache.
        gate.complete();
        async.elapse(kShowCachedMessagesDelay);
        checkNotifiedOnce();
        checkShowingCached(cached);

        model.dispose();
      }));

      test('disposed before kShowCachedMessagesDelay: timer canceled', () => awaitFakeAsync((async) async {
        const narrow = CombinedFeedNarrow();
        await prepare(narrow: narrow, stream: channel);
        seedCachedFetch(narrow, [eg.streamMessage(stream: channel)]);
        prepareSuccess([], delay: const Duration(minutes: 1));
        final fetchFuture = model.fetchInitial();
        async.flushMicrotasks();
        // The fake request's delay, and the timer to show cached messages.
        check(async.pendingTimers).length.equals(2);

        model.dispose();
        async.flushMicrotasks();
        check(async.pendingTimers).single
          .has((timer) => timer.duration, 'duration').equals(const Duration(minutes: 1));
        await fetchFuture;
        checkNotNotified();
      }));

      test('corrupt data: not shown, and deleted', () => awaitFakeAsync((async) async {
        const narrow = CombinedFeedNarrow();
        await prepare(narrow: narrow, stream: channel);
        backend.seedCachedMessageFetch(eg.selfAccount.id, messageFetchCacheKey(narrow)!,
          data: utf8.encode('{"messages": "nonsense"'));
        prepareNetworkException();
        final fetchFuture = model.fetchInitial();
        async.elapse(Duration.zero);
        checkNotifiedOnce();
        checkWaiting();
        check(model).fetchInitialFailing.isTrue();
        check(cachedFetchOf(narrow)).isNull();

        model.dispose();
        await fetchFuture;
      }));

      test('not parsed when request succeeds sooner', () => awaitFakeAsync((async) async {
        const narrow = CombinedFeedNarrow();
        await prepare(narrow: narrow, stream: channel);
        // Corrupt data would be deleted if parsed.
        backend.seedCachedMessageFetch(eg.selfAccount.id, messageFetchCacheKey(narrow)!,
          data: utf8.encode('{"messages": "nonsense"'));
        // Keep the fresh fetch from replacing the stored one.
        backend.storeCachedMessageFetchError = Exception('failed');
        prepareSuccess([eg.streamMessage(stream: channel)],
          delay: kShowCachedMessagesDelay ~/ 2);
        await model.fetchInitial();
        checkNotifiedOnce();
        async.elapse(kShowCachedMessagesDelay);
        check(cachedFetchOf(narrow)).isNotNull();
      }));

      test('not used with numeric anchor', () => awaitFakeAsync((async) async {
        BackoffMachine.debugDuration = const Duration(seconds: 10);
        addTearDown(() => BackoffMachine.debugDuration = null);
        const narrow = CombinedFeedNarrow();
        final cached = [eg.streamMessage(stream: channel)];
        await prepare(narrow: narrow, anchor: NumericAnchor(cached.single.id),
          stream: channel);
        seedCachedFetch(narrow, cached);
        prepareNetworkException();
        final fetchFuture = model.fetchInitial();
        async.elapse(kShowCachedMessagesDelay);
        checkNotifiedOnce();
        checkWaiting();
        check(model).fetchInitialFailing.isTrue();

        model.dispose();
        await fetchFuture;
      }));

      test('error not to retry: clear cached messages', () => awaitFakeAsync((async) async {
        final (fetchFuture, cached) = await prepareFailingWithCache();
        final throwsCheck = check(fetchFuture).throws<ZulipApiException>();
        connection.prepare(apiException: eg.apiBadRequest());
        async.elapse(Duration.zero);
        checkNotifiedOnce();
        checkShowingCached(cached);

        async.elapse(const Duration(milliseconds: 100)); // max first backoff
        await throwsCheck;
        checkNotifiedOnce();
        checkWaiting();
        check(model).messages.isEmpty();
        check(cachedFetchOf(const CombinedFeedNarrow())).isNull();
        check(async.pendingTimers).isEmpty();
      }));

      test('error not to retry, before cache read finishes: not shown', () => awaitFakeAsync((async) async {
        final gate = Completer<void>();
        const narrow = CombinedFeedNarrow();
        await prepare(narrow: narrow, stream: channel);
        backend.loadCachedMessageFetchGate = gate.future;
        seedCachedFetch(narrow, [eg.streamMessage(stream: channel)]);
        // Keep the stored messages, so the read finds them.
        backend.deleteCachedMessageFetchError = Exception('failed');
        connection.prepare(apiException: eg.apiBadRequest());
        await check(model.fetchInitial()).throws<ZulipApiException>();
        check(cachedFetchOf(narrow)).isNotNull();

        gate.complete();
        async.elapse(kShowCachedMessagesDelay);
        checkNotNotified();
        checkWaiting();
      }));

      group('position', () {
        Future<void> checkPosition({
          required Anchor anchor,
          required UnreadMessagesSnapshot unreadMsgs,
          required List<Message> cached,
          required int expectedMiddleMessage,
        }) async {
          const narrow = CombinedFeedNarrow();
          await prepare(narrow: narrow, anchor: anchor, unreadMsgs: unreadMsgs,
            stream: channel);
          seedCachedFetch(narrow, cached);
          prepareNetworkException();
          final fetchFuture = model.fetchInitial();
          await Future<void>.delayed(Duration.zero);
          checkNotifiedOnce();
          checkShowingCached(cached);
          check(model).middleMessage.equals(expectedMiddleMessage);

          model.dispose();
          await fetchFuture;
        }

        UnreadMessagesSnapshot unreadMsgsFor(List<StreamMessage> messages) {
          return eg.unreadMsgs(channels: [eg.unreadChannelMsgs(
            streamId: channel.streamId, topic: messages.first.topic.apiName,
            unreadMessageIds: messages.map((m) => m.id).toList())]);
        }

        test('anchor newest: at end', () => awaitFakeAsync((async) async {
          final cached = List.generate(4, (i) => eg.streamMessage(stream: channel));
          await checkPosition(anchor: AnchorCode.newest,
            unreadMsgs: unreadMsgsFor(cached.sublist(1)),
            cached: cached, expectedMiddleMessage: 3);
        }));

        test('anchor firstUnread: at first message unread now', () => awaitFakeAsync((async) async {
          // As stored, all are unread; now the first two are read.
          final cached = List.generate(4, (i) => eg.streamMessage(stream: channel));
          await checkPosition(anchor: AnchorCode.firstUnread,
            unreadMsgs: unreadMsgsFor(cached.sublist(2)),
            cached: cached, expectedMiddleMessage: 2);
        }));

        test('anchor firstUnread, none unread: at end', () => awaitFakeAsync((async) async {
          final cached = List.generate(4, (i) => eg.streamMessage(stream: channel));
          await checkPosition(anchor: AnchorCode.firstUnread,
            unreadMsgs: eg.unreadMsgs(),
            cached: cached, expectedMiddleMessage: 3);
        }));
      });

      group('flags', () {
        test('read and starred state from store', () => awaitFakeAsync((async) async {
          const narrow = CombinedFeedNarrow();
          final wasUnreadNowRead = eg.streamMessage(stream: channel, flags: []);
          final wasReadNowUnread = eg.streamMessage(stream: channel,
            flags: [MessageFlag.read]);
          final wasStarredNowNot = eg.streamMessage(stream: channel,
            flags: [MessageFlag.read, MessageFlag.starred]);
          final wasNotStarredNowStarred = eg.streamMessage(stream: channel,
            flags: [MessageFlag.read]);
          await prepare(narrow: narrow, stream: channel,
            starredMessages: [wasNotStarredNowStarred.id],
            unreadMsgs: eg.unreadMsgs(channels: [eg.unreadChannelMsgs(
              streamId: channel.streamId, topic: wasReadNowUnread.topic.apiName,
              unreadMessageIds: [wasReadNowUnread.id])]));
          seedCachedFetch(narrow, [wasUnreadNowRead, wasReadNowUnread,
            wasStarredNowNot, wasNotStarredNowStarred]);
          prepareNetworkException();
          final fetchFuture = model.fetchInitial();
          async.elapse(Duration.zero);
          checkNotifiedOnce();
          check(model.messages.map((m) => m.flags)).deepEquals([
            [MessageFlag.read],
            <MessageFlag>[],
            [MessageFlag.read],
            [MessageFlag.read, MessageFlag.starred],
          ]);

          model.dispose();
          await fetchFuture;
        }));

        test('read state unknown: keep stored state', () => awaitFakeAsync((async) async {
          const narrow = CombinedFeedNarrow();
          final storedUnread = eg.streamMessage(stream: channel, flags: []);
          final storedRead = eg.streamMessage(stream: channel, flags: [MessageFlag.read]);
          await prepare(narrow: narrow, stream: channel,
            unreadMsgs: eg.unreadMsgs(oldUnreadsMissing: true));
          seedCachedFetch(narrow, [storedUnread, storedRead]);
          prepareNetworkException();
          final fetchFuture = model.fetchInitial();
          async.elapse(Duration.zero);
          checkNotifiedOnce();
          check(model.messages.map((m) => m.flags)).deepEquals([
            <MessageFlag>[],
            [MessageFlag.read],
          ]);

          model.dispose();
          await fetchFuture;
        }));
      });

      group('filter', () {
        Future<void> prepareCached(Narrow narrow, List<Message> cached, {
          List<int>? starredMessages,
        }) async {
          await prepare(narrow: narrow, stream: channel,
            starredMessages: starredMessages);
          seedCachedFetch(narrow, cached);
          prepareNetworkException();
        }

        test('use the store\'s copy, if any', () => awaitFakeAsync((async) async {
          const narrow = CombinedFeedNarrow();
          final cached = [eg.streamMessage(stream: channel, content: '<p>old</p>'),
                          eg.streamMessage(stream: channel)];
          await prepareCached(narrow, cached);
          final fetchFuture = model.fetchInitial();
          final storeCopy = eg.streamMessage(id: cached.first.id, stream: channel,
            content: '<p>edited</p>');
          await store.addMessage(storeCopy);
          async.elapse(Duration.zero);
          checkNotifiedOnce();
          checkShowingCached(cached);
          check(model.messages.first).identicalTo(storeCopy);
          check(store.messages.keys).deepEquals([storeCopy.id]);

          model.dispose();
          await fetchFuture;
        }));

        test('message deleted', () => awaitFakeAsync((async) async {
          const narrow = CombinedFeedNarrow();
          final cached = [eg.streamMessage(stream: channel),
                          eg.streamMessage(stream: channel)];
          await prepareCached(narrow, cached);
          await store.handleEvent(eg.deleteMessageEvent([cached.first]));
          final fetchFuture = model.fetchInitial();
          async.elapse(Duration.zero);
          checkNotifiedOnce();
          checkShowingCached([cached.last]);

          model.dispose();
          await fetchFuture;
        }));

        test('message moved out of the narrow', () => awaitFakeAsync((async) async {
          final narrow = ChannelNarrow(channel.streamId);
          final otherChannel = eg.stream();
          final cached = [eg.streamMessage(stream: channel),
                          eg.streamMessage(stream: channel)];
          await prepareCached(narrow, cached);
          final fetchFuture = model.fetchInitial();
          await store.addMessage(eg.streamMessage(id: cached.first.id,
            stream: otherChannel));
          async.elapse(Duration.zero);
          checkNotifiedOnce();
          checkShowingCached([cached.last]);

          model.dispose();
          await fetchFuture;
        }));

        test('message in muted topic', () => awaitFakeAsync((async) async {
          const narrow = CombinedFeedNarrow();
          final cached = [eg.streamMessage(stream: channel, topic: 'muted'),
                          eg.streamMessage(stream: channel, topic: 'other')];
          await prepareCached(narrow, cached);
          final fetchFuture = model.fetchInitial();
          await store.setUserTopic(channel, 'muted', UserTopicVisibilityPolicy.muted);
          async.elapse(Duration.zero);
          checkNotifiedOnce();
          checkShowingCached([cached.last]);

          model.dispose();
          await fetchFuture;
        }));

        test('message in unknown channel, or one without content access', () => awaitFakeAsync((async) async {
          const narrow = CombinedFeedNarrow();
          final unknownChannel = eg.stream();
          final privateChannel = eg.stream(inviteOnly: true);
          final cached = [eg.streamMessage(stream: unknownChannel),
                          eg.streamMessage(stream: privateChannel),
                          eg.streamMessage(stream: channel)];
          await prepareCached(narrow, cached);
          final fetchFuture = model.fetchInitial();
          await store.addStream(privateChannel);
          check(store.selfHasContentAccess(privateChannel)).isFalse();
          async.elapse(Duration.zero);
          checkNotifiedOnce();
          checkShowingCached([cached.last]);

          model.dispose();
          await fetchFuture;
        }));

        test('message no longer starred, in starred-messages view', () => awaitFakeAsync((async) async {
          const narrow = StarredMessagesNarrow();
          final cached = [
            eg.streamMessage(stream: channel, flags: [MessageFlag.starred]),
            eg.streamMessage(stream: channel, flags: [MessageFlag.starred]),
          ];
          await prepareCached(narrow, cached,
            starredMessages: [cached.last.id]);
          final fetchFuture = model.fetchInitial();
          async.elapse(Duration.zero);
          checkNotifiedOnce();
          checkShowingCached([cached.last]);

          model.dispose();
          await fetchFuture;
        }));

        test('no messages left: keep waiting', () => awaitFakeAsync((async) async {
          final unknownChannel = eg.stream();
          final narrow = ChannelNarrow(unknownChannel.streamId);
          await prepareCached(narrow,
            [eg.streamMessage(stream: unknownChannel)]);
          final fetchFuture = model.fetchInitial();
          async.elapse(Duration.zero);
          checkNotifiedOnce();
          checkWaiting();
          check(model).fetchInitialFailing.isTrue();

          model.dispose();
          await fetchFuture;
        }));
      });

      test('topic permalink: keep "with" until fetch succeeds', () => awaitFakeAsync((async) async {
        final cached = [eg.streamMessage(stream: channel, topic: 'topic')];
        final narrow = TopicNarrow(channel.streamId, eg.t('topic'),
          with_: cached.single.id);
        await prepare(narrow: narrow, stream: channel);
        seedCachedFetch(narrow, cached);
        prepareNetworkException();
        final fetchFuture = model.fetchInitial();
        async.elapse(Duration.zero);
        checkNotifiedOnce();
        checkShowingCached(cached);
        check(model).narrow.equals(narrow);

        final fresh = [eg.streamMessage(id: cached.single.id,
          stream: channel, topic: 'topic')];
        prepareSuccess(fresh);
        async.elapse(const Duration(milliseconds: 100)); // max first backoff
        checkNotifiedOnce();
        check(model).narrow.equals(narrow.sansWith());
        await fetchFuture;
      }));

      group('events', () {
        test('DeleteMessageEvent removes cached message', () => awaitFakeAsync((async) async {
          final (fetchFuture, cached) = await prepareFailingWithCache();
          async.elapse(Duration.zero);
          checkNotifiedOnce();

          await store.handleEvent(
            eg.deleteMessageEvent([cached.first as StreamMessage]));
          checkNotifiedOnce();
          checkShowingCached(cached.sublist(1));

          model.dispose();
          await fetchFuture;
        }));

        test('messages learned from another fetch: adopt the store\'s copies', () => awaitFakeAsync((async) async {
          final narrow = ChannelNarrow(channel.streamId);
          final otherChannel = eg.stream();
          final cached = List.generate(3, (i) => eg.streamMessage(
            stream: channel, content: '<p>old</p>'));
          await prepare(narrow: narrow, stream: channel);
          seedCachedFetch(narrow, cached);
          prepareNetworkException();
          final fetchFuture = model.fetchInitial();
          async.elapse(Duration.zero);
          checkNotifiedOnce();
          checkShowingCached(cached);

          // Another view's fetch teaches the store about two of the messages:
          // one edited since it was cached, one moved out of this narrow.
          final edited = eg.streamMessage(id: cached[1].id,
            stream: channel, content: '<p>new</p>');
          final moved = eg.streamMessage(id: cached[2].id, stream: otherChannel);
          final otherView = MessageListView.init(store: store,
            narrow: const CombinedFeedNarrow(), anchor: NumericAnchor(edited.id));
          connection.prepare(json: nearResult(anchor: edited.id,
            foundOldest: false, foundNewest: false,
            messages: [edited, moved]).toJson());
          await otherView.fetchInitial();
          checkNotifiedOnce();
          checkShowingCached([cached[0], edited]);
          check(model.messages[1]).identicalTo(store.messages[edited.id]!);
          check(model.contents[1]).isA<ZulipContent>()
            .equalsNode(parseContent('<p>new</p>'));

          // Events on the store's copy reach this view.
          await store.handleEvent(eg.reactionEvent(
            eg.unicodeEmojiReaction, ReactionOp.add, edited.id));
          checkNotifiedOnce();
          check(model.messages[1].reactions).isNotNull()
            .total.equals(1);

          otherView.dispose();
          model.dispose();
          await fetchFuture;
        }));

        test('MessageEvent: new message not added', () => awaitFakeAsync((async) async {
          final (fetchFuture, cached) = await prepareFailingWithCache();
          async.elapse(Duration.zero);
          checkNotifiedOnce();

          await store.addMessage(eg.streamMessage(stream: channel));
          checkNotNotified();
          checkShowingCached(cached);

          model.dispose();
          await fetchFuture;
        }));

        group('channel muting', () {
          final cached = <Message>[eg.streamMessage(stream: channel),
            eg.dmMessage(from: eg.otherUser, to: [eg.selfUser])];

          Future<void> setChannelMuted(bool value) async {
            await store.updateSubscription(channel.streamId,
              SubscriptionProperty.isMuted, value);
          }

          late Future<void> fetchFuture;

          /// Set up a [CombinedFeedNarrow] view with [cached] stored,
          /// and start [MessageListView.fetchInitial] as [fetchFuture]
          /// with the request failing.
          Future<void> prepareShowingCached({bool channelMuted = false}) async {
            const narrow = CombinedFeedNarrow();
            await prepare(narrow: narrow, stream: channel);
            await setChannelMuted(channelMuted);
            seedCachedFetch(narrow, cached);
            prepareNetworkException();
            fetchFuture = model.fetchInitial();
          }

          test('channel muted: remove its cached messages', () => awaitFakeAsync((async) async {
            await prepareShowingCached();
            async.elapse(Duration.zero);
            checkNotifiedOnce();
            checkShowingCached(cached);

            await setChannelMuted(true);
            checkNotifiedOnce();
            checkShowingCached([cached.last]);

            model.dispose();
            await fetchFuture;
          }));

          test('channel unmuted: refetch from scratch', () => awaitFakeAsync((async) async {
            await prepareShowingCached(channelMuted: true);
            async.elapse(Duration.zero);
            checkNotifiedOnce();
            checkShowingCached([cached.last]);

            final fresh = [...cached, eg.streamMessage(stream: channel)];
            prepareSuccess(fresh);
            await setChannelMuted(false);
            checkNotifiedOnce();
            checkWaiting();
            checkHasMessages([]);

            async.elapse(Duration.zero);
            checkNotifiedOnce();
            check(model)
              ..showingCachedMessages.isFalse()
              ..haveNewest.isTrue();
            checkHasMessages(fresh);
            await fetchFuture;
          }));
        });
      });

      group('derive from a containing narrow', () {
        final topicNarrow = eg.topicNarrow(channel.streamId, 'topic');
        final channelNarrow = ChannelNarrow(channel.streamId);
        const combinedNarrow = CombinedFeedNarrow();
        final dmNarrow = DmNarrow.withUser(eg.otherUser.userId,
          selfUserId: eg.selfUser.userId);

        StreamMessage topicMessage() =>
          eg.streamMessage(stream: channel, topic: 'topic');
        StreamMessage otherTopicMessage() =>
          eg.streamMessage(stream: channel, topic: 'other');
        DmMessage dmMessage() =>
          eg.dmMessage(from: eg.otherUser, to: [eg.selfUser]);

        String keyOf(Narrow narrow) => messageFetchCacheKey(narrow)!;

        late Future<void> fetchFuture;

        /// Set up a view of [narrow], with [stored] as the stored messages,
        /// and start [MessageListView.fetchInitial] as [fetchFuture]
        /// with the request failing, letting the stored messages be read.
        ///
        /// Before that, [setUp] runs, as for setting muting state.
        Future<void> prepareDerived(FakeAsync async, Narrow narrow, {
          required Map<Narrow, List<Message>> stored,
          List<int>? mutedUserIds,
          Future<void> Function()? setUp,
        }) async {
          await prepare(narrow: narrow, stream: channel,
            users: [eg.otherUser], mutedUserIds: mutedUserIds);
          await setUp?.call();
          for (final MapEntry(key: narrow, value: messages) in stored.entries) {
            seedCachedFetch(narrow, messages);
          }
          prepareNetworkException();
          fetchFuture = model.fetchInitial();
          async.elapse(Duration.zero);
          notifiedCount = 0;
        }

        /// Check the view of [narrow] shows [expected]
        /// derived from [stored], or waits if [expected] is empty.
        Future<void> checkDerived(FakeAsync async, Narrow narrow, {
          required Map<Narrow, List<Message>> stored,
          required List<Message> expected,
          List<int>? mutedUserIds,
          Future<void> Function()? setUp,
        }) async {
          await prepareDerived(async, narrow,
            stored: stored, mutedUserIds: mutedUserIds, setUp: setUp);
          if (expected.isEmpty) {
            checkWaiting();
            check(model).fetchInitialFailing.isTrue();
          } else {
            checkShowingCached(expected);
            check(model).fetchInitialFailing.isFalse();
          }

          model.dispose();
          await fetchFuture;
        }

        group('show', () {
          test('topic, from its channel', () => awaitFakeAsync((async) async {
            final messages = [topicMessage(), otherTopicMessage(), topicMessage()];
            await checkDerived(async, topicNarrow,
              stored: {channelNarrow: messages},
              expected: [messages[0], messages[2]]);
          }));

          test('topic unmuted in muted channel, from its channel', () => awaitFakeAsync((async) async {
            final messages = [topicMessage(), otherTopicMessage(), topicMessage()];
            await checkDerived(async, topicNarrow,
              setUp: () async {
                await store.updateSubscription(channel.streamId,
                  SubscriptionProperty.isMuted, true);
                await store.setUserTopic(channel, 'topic',
                  UserTopicVisibilityPolicy.unmuted);
              },
              stored: {channelNarrow: messages},
              expected: [messages[0], messages[2]]);
          }));

          test('DM conversation, from the combined feed', () => awaitFakeAsync((async) async {
            final messages = <Message>[dmMessage(), topicMessage(),
              eg.dmMessage(from: eg.selfUser, to: [eg.otherUser]),
              eg.dmMessage(from: eg.selfUser, to: [eg.otherUser, eg.thirdUser])];
            await checkDerived(async, dmNarrow,
              stored: {combinedNarrow: messages},
              expected: [messages[0], messages[2]]);
          }));
        });

        group('show nothing', () {
          test('topic muted, from its channel', () => awaitFakeAsync((async) async {
            // Stored before the topic was muted, the channel's messages
            // would have all of the topic's in their range; but a view
            // of the channel open since then would have stored none.
            await checkDerived(async, topicNarrow,
              setUp: () => store.setUserTopic(channel, 'topic',
                UserTopicVisibilityPolicy.muted),
              stored: {channelNarrow: [topicMessage(), otherTopicMessage()]},
              expected: []);
          }));

          test('topic, from the combined feed', () => awaitFakeAsync((async) async {
            // The combined feed lacks messages sent to the channel
            // while the user was unsubscribed, even in a followed topic.
            await checkDerived(async, topicNarrow,
              setUp: () => store.setUserTopic(channel, 'topic',
                UserTopicVisibilityPolicy.followed),
              stored: {combinedNarrow: [topicMessage(), otherTopicMessage()]},
              expected: []);
            check(backend.cachedMessageFetchLoads)
              .deepEquals([keyOf(topicNarrow), keyOf(channelNarrow)]);
          }));

          test('channel, from the combined feed', () => awaitFakeAsync((async) async {
            // Stored while the user had muted the channel,
            // the combined feed's messages would have
            // only the topics in it the user unmuted or follows.
            await checkDerived(async, channelNarrow,
              stored: {combinedNarrow: [topicMessage(), otherTopicMessage()]},
              expected: []);
            check(backend.cachedMessageFetchLoads)
              .deepEquals([keyOf(channelNarrow)]);
          }));

          test('muted DM conversation, from the combined feed', () => awaitFakeAsync((async) async {
            await checkDerived(async, dmNarrow,
              mutedUserIds: [eg.otherUser.userId],
              stored: {combinedNarrow: [dmMessage(), dmMessage()]},
              expected: []);
          }));

          test('mentions, from the combined feed', () => awaitFakeAsync((async) async {
            await checkDerived(async, const MentionsNarrow(),
              stored: {combinedNarrow: [
                eg.streamMessage(stream: channel, flags: [MessageFlag.mentioned])]},
              expected: []);
          }));
        });

        group('precedence', () {
          test('own stored messages first; others not read', () => awaitFakeAsync((async) async {
            final own = [topicMessage()];
            await checkDerived(async, topicNarrow,
              stored: {topicNarrow: own,
                       channelNarrow: [topicMessage()],
                       combinedNarrow: [topicMessage()]},
              expected: own);
            check(backend.cachedMessageFetchLoads)
              .deepEquals([keyOf(topicNarrow)]);
          }));

          test('then the channel\'s', () => awaitFakeAsync((async) async {
            final fromChannel = [topicMessage()];
            await checkDerived(async, topicNarrow,
              stored: {channelNarrow: fromChannel,
                       combinedNarrow: [topicMessage()]},
              expected: fromChannel);
            check(backend.cachedMessageFetchLoads)
              .deepEquals([keyOf(topicNarrow), keyOf(channelNarrow)]);
          }));

          test('channel\'s giving nothing: combined feed\'s not read', () => awaitFakeAsync((async) async {
            await checkDerived(async, topicNarrow,
              stored: {channelNarrow: [otherTopicMessage()],
                       combinedNarrow: [topicMessage()]},
              expected: []);
            check(backend.cachedMessageFetchLoads)
              .deepEquals([keyOf(topicNarrow), keyOf(channelNarrow)]);
          }));

          test('own stored messages giving nothing: derive', () => awaitFakeAsync((async) async {
            final deleted = topicMessage();
            final fromChannel = [topicMessage()];
            await checkDerived(async, topicNarrow,
              setUp: () => store.handleEvent(eg.deleteMessageEvent([deleted])),
              stored: {topicNarrow: [deleted],
                       channelNarrow: fromChannel},
              expected: fromChannel);
          }));

          test('containing narrow\'s not read while own may give some', () => awaitFakeAsync((async) async {
            await prepare(narrow: topicNarrow, stream: channel);
            seedCachedFetch(topicNarrow, [topicMessage()]);
            seedCachedFetch(channelNarrow, [topicMessage()]);
            final fresh = [topicMessage()];
            prepareSuccess(fresh, delay: kShowCachedMessagesDelay ~/ 2);
            await model.fetchInitial();
            checkNotifiedOnce();
            checkHasMessages(fresh);
            check(backend.cachedMessageFetchLoads)
              .deepEquals([keyOf(topicNarrow)]);
          }));

          test('corrupt containing narrow\'s data: skip, not delete', () => awaitFakeAsync((async) async {
            final corrupt = utf8.encode('{"messages": "nonsense"');
            await checkDerived(async, topicNarrow,
              setUp: () async {
                backend.seedCachedMessageFetch(eg.selfAccount.id,
                  keyOf(channelNarrow), data: corrupt);
              },
              stored: {},
              expected: []);
            check(cachedFetchOf(channelNarrow)).isNotNull()
              .data.deepEquals(corrupt);
          }));
        });

        test('previousMessageIds applies to derived messages', () => awaitFakeAsync((async) async {
          final fromChannel = [topicMessage(), topicMessage()];
          await prepare(narrow: topicNarrow, stream: channel);
          seedCachedFetch(channelNarrow, fromChannel);
          prepareSuccess([fromChannel.last], delay: kShowCachedMessagesDelay ~/ 2);
          final fetchFuture = model.fetchInitial(
            previousMessageIds: {fromChannel.last.id});
          async.flushMicrotasks();
          checkNotifiedOnce();
          checkShowingCached([fromChannel.last]);

          async.elapse(kShowCachedMessagesDelay ~/ 2);
          checkNotifiedOnce();
          check(model).showingCachedMessages.isFalse();
          await fetchFuture;
        }));

        test('derived messages not stored for the narrow', () => awaitFakeAsync((async) async {
          BackoffMachine.debugDuration = const Duration(minutes: 1);
          addTearDown(() => BackoffMachine.debugDuration = null);
          final fromChannel = [topicMessage(), topicMessage(), otherTopicMessage()];
          await prepareDerived(async, topicNarrow,
            stored: {channelNarrow: fromChannel});
          checkShowingCached(fromChannel.sublist(0, 2));

          // A change to the messages would schedule storing them
          // if the view had the newest messages.
          await store.handleEvent(eg.deleteMessageEvent([fromChannel.first]));
          checkNotifiedOnce();
          checkShowingCached([fromChannel[1]]);
          async.elapse(kCachedMessagesWriteDelay * 2);
          model.dispose();
          await fetchFuture;
          async.elapse(kCachedMessagesWriteDelay * 2);
          check(cachedFetchOf(topicNarrow)).isNull();
          checkCachedMessages(channelNarrow, fromChannel);
        }));

        test('fresh fetch replaces derived messages, and is stored', () => awaitFakeAsync((async) async {
          final fromCombined = <Message>[dmMessage(), topicMessage()];
          await prepareDerived(async, dmNarrow,
            stored: {combinedNarrow: fromCombined});
          checkShowingCached([fromCombined.first]);

          final fresh = <Message>[fromCombined.first, dmMessage()];
          prepareSuccess(fresh);
          async.elapse(const Duration(milliseconds: 100)); // max first backoff
          checkNotifiedOnce();
          check(model)
            ..showingCachedMessages.isFalse()
            ..haveNewest.isTrue();
          checkHasMessages(fresh);
          await fetchFuture;
          checkCachedMessages(dmNarrow, fresh);
          checkCachedMessages(combinedNarrow, fromCombined);
        }));
      });
    });

    group('keep stored messages up to date', () {
      /// Set up a view of [narrow] that has the newest messages,
      /// and has stored them.
      Future<void> prepareStored({
        Narrow narrow = const CombinedFeedNarrow(),
        List<Message>? messages,
        bool foundOldest = true,
      }) async {
        await prepare(narrow: narrow, stream: channel);
        messages ??= List.generate(3, (_) =>
          eg.streamMessage(stream: channel, topic: 'topic'));
        await prepareMessages(foundOldest: foundOldest, messages: messages);
        checkCachedMessages(narrow, model.messages);
      }

      /// Check that [narrow]'s stored messages are as [model] has them.
      void checkStoredAsShown([Narrow narrow = const CombinedFeedNarrow()]) {
        checkCachedMessages(narrow, model.messages);
      }

      /// Check that [narrow]'s stored messages are unchanged
      /// since [storedData], and no write is pending.
      void checkStoredUnchanged(Uint8List storedData, {
        Narrow narrow = const CombinedFeedNarrow(),
        required FakeAsync async,
      }) {
        check(cachedFetchOf(narrow)).isNotNull().data.deepEquals(storedData);
        check(async.pendingTimers).isEmpty();
      }

      /// Check that [narrow]'s stored messages are unchanged
      /// until [kCachedMessagesWriteDelay] has passed,
      /// and then are as [model] has them.
      void checkStoredAfterDelay(FakeAsync async, {
        Narrow narrow = const CombinedFeedNarrow(),
      }) {
        final before = cachedFetchOf(narrow)!.data;
        check(async.pendingTimers).single;
        async.elapse(kCachedMessagesWriteDelay - const Duration(milliseconds: 1));
        check(cachedFetchOf(narrow)).isNotNull().data.deepEquals(before);
        async.elapse(const Duration(milliseconds: 1));
        checkStoredAsShown(narrow);
        check(async.pendingTimers).isEmpty();
      }

      test('new message', () => awaitFakeAsync((async) async {
        await prepareStored();
        final newMessage = eg.streamMessage(stream: channel, topic: 'topic');
        await store.addMessage(newMessage);
        checkNotifiedOnce();
        check(model.messages).last.id.equals(newMessage.id);
        checkStoredAfterDelay(async);
        check(decodeCachedMessages(cachedFetchOf(const CombinedFeedNarrow())!.data))
          .last.id.equals(newMessage.id);
      }));

      test('message edited', () => awaitFakeAsync((async) async {
        await prepareStored();
        final message = model.messages[1];
        await store.handleEvent(eg.updateMessageEditEvent(message,
          renderedContent: '<p>edited</p>'));
        checkNotifiedOnce();
        checkStoredAfterDelay(async);
        check(decodeCachedMessages(cachedFetchOf(const CombinedFeedNarrow())!.data)[1])
          ..content.equals('<p>edited</p>')
          ..editState.equals(MessageEditState.edited);
      }));

      test('reaction added', () => awaitFakeAsync((async) async {
        await prepareStored();
        final message = model.messages[1];
        await store.handleEvent(eg.reactionEvent(
          eg.unicodeEmojiReaction, ReactionOp.add, message.id));
        checkNotifiedOnce();
        checkStoredAfterDelay(async);
        check(decodeCachedMessages(cachedFetchOf(const CombinedFeedNarrow())!.data)[1])
          .reactions.isNotNull().total.equals(1);
      }));

      test('flag added', () => awaitFakeAsync((async) async {
        await prepareStored();
        final message = model.messages[1];
        await store.handleEvent(UpdateMessageFlagsAddEvent(id: 1,
          flag: MessageFlag.starred, messages: [message.id], all: false));
        checkNotifiedOnce();
        checkStoredAfterDelay(async);
        check(decodeCachedMessages(cachedFetchOf(const CombinedFeedNarrow())!.data)[1])
          .flags.contains(MessageFlag.starred);
      }));

      test('message deleted', () => awaitFakeAsync((async) async {
        await prepareStored();
        final message = model.messages[1] as StreamMessage;
        await store.handleEvent(eg.deleteMessageEvent([message]));
        checkNotifiedOnce();
        checkStoredAfterDelay(async);
        check(decodeCachedMessages(cachedFetchOf(const CombinedFeedNarrow())!.data))
          .length.equals(2);
      }));

      test('message moved within the narrow', () => awaitFakeAsync((async) async {
        await prepareStored();
        final message = model.messages[1] as StreamMessage;
        await store.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: [message], newTopicStr: 'other topic'));
        check(notifiedCount).isGreaterThan(0);
        checkStoredAfterDelay(async);
        check(decodeCachedMessages(cachedFetchOf(const CombinedFeedNarrow())!.data)[1])
          .isA<StreamMessage>()
            ..topic.equals(eg.t('other topic'))
            ..editState.equals(MessageEditState.moved);
      }));

      test('poll vote', () => awaitFakeAsync((async) async {
        final pollMessage = eg.streamMessage(stream: channel,
          sender: eg.selfUser, submessages: [
            eg.submessage(senderId: eg.selfUser.userId,
              content: eg.pollWidgetData(question: 'Question?',
                options: ['a', 'b'])),
          ]);
        await prepareStored(messages: [pollMessage]);
        await store.handleEvent(eg.submessageEvent(pollMessage.id,
          eg.otherUser.userId,
          content: PollVoteEventSubmessage(key: 'canned,1', op: PollVoteOp.add)));
        checkNotNotified(); // the poll notifies, not the message list
        checkStoredAfterDelay(async);
        check(decodeCachedMessages(cachedFetchOf(const CombinedFeedNarrow())!.data))
          .single.poll.isNotNull().options.last
          .voters.deepEquals([eg.otherUser.userId]);
      }));

      test('burst of events: one write, after the first', () => awaitFakeAsync((async) async {
        await prepareStored();
        final storedData = cachedFetchOf(const CombinedFeedNarrow())!.data;
        await store.addMessage(eg.streamMessage(stream: channel, topic: 'topic'));
        async.elapse(const Duration(seconds: 1));
        await store.addMessage(eg.streamMessage(stream: channel, topic: 'topic'));
        await store.handleEvent(eg.reactionEvent(
          eg.unicodeEmojiReaction, ReactionOp.add, model.messages.first.id));
        check(async.pendingTimers).single;
        check(cachedFetchOf(const CombinedFeedNarrow())).isNotNull()
          .data.deepEquals(storedData);

        async.elapse(kCachedMessagesWriteDelay - const Duration(seconds: 1));
        checkStoredAsShown();
        check(async.pendingTimers).isEmpty();
      }));

      test('dispose: store at once', () => awaitFakeAsync((async) async {
        await prepareStored();
        await store.addMessage(eg.streamMessage(stream: channel, topic: 'topic'));
        final shown = model.messages.toList();
        check(async.pendingTimers).single;
        model.dispose();
        checkCachedMessages(const CombinedFeedNarrow(), shown);
        check(async.pendingTimers).isEmpty();
      }));

      test('dispose with nothing to store: no write', () => awaitFakeAsync((async) async {
        await prepareStored();
        final storedData = cachedFetchOf(const CombinedFeedNarrow())!.data;
        backend.storeCachedMessageFetchError = Exception('unexpected write');
        model.dispose();
        checkStoredUnchanged(storedData, async: async);
        check(backend.storeCachedMessageFetchError).isNotNull();
      }));

      test('renarrowAndFetch: store old narrow at once', () => awaitFakeAsync((async) async {
        await prepareStored();
        await store.addMessage(eg.streamMessage(stream: channel, topic: 'topic'));
        final shown = model.messages.toList();

        final newNarrow = ChannelNarrow(channel.streamId);
        final newMessages = [eg.streamMessage(stream: channel)];
        connection.prepare(json:
          newestResult(foundOldest: true, messages: newMessages).toJson());
        model.renarrowAndFetch(newNarrow, AnchorCode.newest);
        checkCachedMessages(const CombinedFeedNarrow(), shown);
        async.elapse(Duration.zero);
        checkCachedMessages(newNarrow, newMessages);
        check(async.pendingTimers).isEmpty();
      }));

      test('refetch from scratch: store at once', () => awaitFakeAsync((async) async {
        await prepareStored();
        await store.setUserTopic(channel, 'muted', UserTopicVisibilityPolicy.muted);
        await store.addMessage(eg.streamMessage(stream: channel, topic: 'topic'));
        final shown = model.messages.toList();
        check(async.pendingTimers).single;

        // Unmuting a topic makes the view refetch from scratch.
        connection.prepare(httpException: const SocketException('failed'));
        await store.setUserTopic(channel, 'muted', UserTopicVisibilityPolicy.unmuted);
        check(model).fetched.isFalse();
        checkCachedMessages(const CombinedFeedNarrow(), shown);
        check(async.pendingTimers.where(
          (timer) => timer.duration == kCachedMessagesWriteDelay)).isEmpty();

        model.dispose();
      }));

      test('channel muted and unmuted: none missing between stored messages', () => awaitFakeAsync((async) async {
        final channelMessage1 = eg.streamMessage(stream: channel, topic: 'topic');
        final dmMessage = eg.dmMessage(from: eg.otherUser, to: [eg.selfUser]);
        await prepareStored(messages: [channelMessage1, dmMessage]);

        await store.updateSubscription(channel.streamId,
          SubscriptionProperty.isMuted, true);
        checkNotifiedOnce();
        checkHasMessages([dmMessage]);

        // A message arrives while the channel is muted, so isn't shown.
        final channelMessage2 = eg.streamMessage(stream: channel, topic: 'topic');
        await store.addMessage(channelMessage2);
        checkNotNotified();

        connection.prepare(json: newestResult(foundOldest: true,
          messages: [channelMessage1, dmMessage, channelMessage2]).toJson());
        await store.updateSubscription(channel.streamId,
          SubscriptionProperty.isMuted, false);
        checkNotifiedOnce();
        async.elapse(Duration.zero);
        checkNotifiedOnce();

        final channelMessage3 = eg.streamMessage(stream: channel, topic: 'topic');
        await store.addMessage(channelMessage3);
        checkNotifiedOnce();
        checkStoredAfterDelay(async);
        checkCachedMessages(const CombinedFeedNarrow(),
          [channelMessage1, dmMessage, channelMessage2, channelMessage3]);
      }));

      test('channel unsubscribed and resubscribed: none missing between stored messages', () => awaitFakeAsync((async) async {
        final narrow = ChannelNarrow(channel.streamId);
        final message1 = eg.streamMessage(stream: channel);
        await prepareStored(narrow: narrow, messages: [message1]);

        await store.removeSubscription(channel.streamId);
        checkNotNotified();
        // A message is sent while unsubscribed; no event brings it.
        final message2 = eg.streamMessage(stream: channel);

        connection.prepare(json: newestResult(foundOldest: true,
          messages: [message1, message2]).toJson());
        await store.addSubscription(eg.subscription(channel));
        checkNotifiedOnce();
        async.elapse(Duration.zero);
        checkNotifiedOnce();

        final message3 = eg.streamMessage(stream: channel);
        await store.addMessage(message3);
        checkNotifiedOnce();
        checkStoredAfterDelay(async, narrow: narrow);
        checkCachedMessages(narrow, [message1, message2, message3]);
      }));

      test('topic moved away: old topic\'s stored messages deleted', () => awaitFakeAsync((async) async {
        final narrow = eg.topicNarrow(channel.streamId, 'topic');
        await prepareStored(narrow: narrow);
        final messages = model.messages.cast<StreamMessage>().toList();
        final newNarrow = eg.topicNarrow(channel.streamId, 'new topic');
        final movedMessages = [
          for (final message in messages)
            StreamMessage.fromJson(deepToJson(message) as Map<String, dynamic>
              ..['subject'] = 'new topic'),
        ];
        connection.prepare(json:
          newestResult(foundOldest: true, messages: movedMessages).toJson());
        await store.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: messages, newTopicStr: 'new topic',
          propagateMode: PropagateMode.changeAll));
        check(cachedFetchOf(narrow)).isNull();
        async.elapse(Duration.zero);
        check(model).narrow.equals(newNarrow);
        checkCachedMessages(newNarrow, model.messages);
        check(async.pendingTimers).isEmpty();
      }));

      test('no longer having the newest messages: store at once', () => awaitFakeAsync((async) async {
        await prepareStored();
        await store.addMessage(eg.streamMessage(stream: channel, topic: 'topic'));
        final shown = model.messages.toList();
        check(async.pendingTimers).single;

        // Another view's fetch learns of a newer message the event queue missed.
        store.reconcileMessages([eg.streamMessage(stream: channel, topic: 'topic')]);
        check(model).haveNewest.isFalse();
        checkCachedMessages(const CombinedFeedNarrow(), shown);
        check(async.pendingTimers).isEmpty();
      }));

      test('fetchNewer reaching the newest messages: store', () => awaitFakeAsync((async) async {
        const narrow = CombinedFeedNarrow();
        await prepare(narrow: narrow, anchor: NumericAnchor(1), stream: channel);
        final older = [eg.streamMessage(stream: channel)];
        connection.prepare(json: nearResult(anchor: older.single.id,
          foundOldest: true, foundNewest: false, messages: older).toJson());
        await model.fetchInitial();
        check(backend.cachedMessageFetchKeysOf(eg.selfAccount.id)).isEmpty();

        connection.prepare(json: newerResult(anchor: older.single.id,
          foundNewest: true,
          messages: [eg.streamMessage(stream: channel)]).toJson());
        await model.fetchNewer();
        check(model).haveNewest.isTrue();
        check(cachedFetchOf(narrow)).isNull();
        async.elapse(kCachedMessagesWriteDelay);
        checkStoredAsShown(narrow);
        check(model.messages).length.equals(2);
      }));

      test('fetchOlder within the stored messages: store', () => awaitFakeAsync((async) async {
        const narrow = CombinedFeedNarrow();
        await prepareStored(narrow: narrow, foundOldest: false,
          messages: List.generate(kCachedMessagesMaxCount - 1,
            (_) => eg.streamMessage(stream: channel)));
        final olderMessage = eg.streamMessage(id: 1, stream: channel);
        connection.prepare(json: olderResult(anchor: model.oldestFetchedMessageId!,
          foundOldest: true, messages: [olderMessage]).toJson());
        await model.fetchOlder();
        check(model.messages)
          ..length.equals(kCachedMessagesMaxCount)
          ..first.id.equals(olderMessage.id);
        checkStoredAfterDelay(async, narrow: narrow);
      }));

      test('fetchOlder beyond the stored messages: no write', () => awaitFakeAsync((async) async {
        const narrow = CombinedFeedNarrow();
        await prepareStored(narrow: narrow, foundOldest: false,
          messages: List.generate(kCachedMessagesMaxCount,
            (_) => eg.streamMessage(stream: channel)));
        final storedData = cachedFetchOf(narrow)!.data;
        final olderMessage = eg.streamMessage(id: 1, stream: channel);
        connection.prepare(json: olderResult(anchor: model.oldestFetchedMessageId!,
          foundOldest: true, messages: [olderMessage]).toJson());
        await model.fetchOlder();
        check(model.messages)
          ..length.equals(kCachedMessagesMaxCount + 1)
          ..first.id.equals(olderMessage.id);
        checkStoredUnchanged(storedData, async: async);
      }));

      test('no write while not having the newest messages', () => awaitFakeAsync((async) async {
        const narrow = CombinedFeedNarrow();
        await prepare(narrow: narrow, anchor: AnchorCode.firstUnread, stream: channel);
        final stored = [eg.streamMessage(stream: channel)];
        seedCachedFetch(narrow, stored);
        final storedData = cachedFetchOf(narrow)!.data;
        final messages = [eg.streamMessage(stream: channel)];
        connection.prepare(json: nearResult(anchor: messages.single.id,
          foundOldest: true, foundNewest: false, messages: messages).toJson());
        await model.fetchInitial();
        await store.handleEvent(eg.reactionEvent(
          eg.unicodeEmojiReaction, ReactionOp.add, messages.single.id));
        checkNotified(count: 2);
        checkStoredUnchanged(storedData, async: async);
      }));

      test('no write while showing cached messages', () => awaitFakeAsync((async) async {
        const narrow = CombinedFeedNarrow();
        await prepare(narrow: narrow, stream: channel);
        final cached = List.generate(3, (_) => eg.streamMessage(stream: channel));
        seedCachedFetch(narrow, cached);
        final storedData = cachedFetchOf(narrow)!.data;
        connection.prepare(httpException: const SocketException('failed'));
        final fetchFuture = model.fetchInitial();
        async.elapse(Duration.zero);
        check(model).showingCachedMessages.isTrue();
        checkNotifiedOnce();

        await store.handleEvent(eg.deleteMessageEvent([cached[1]]));
        checkNotifiedOnce();
        check(model.messages).length.equals(2);
        check(async.pendingTimers.where(
          (timer) => timer.duration == kCachedMessagesWriteDelay)).isEmpty();

        model.dispose();
        await fetchFuture;
        checkStoredUnchanged(storedData, async: async);
      }));

      test('round trip: a later view offline shows what this one last showed', () => awaitFakeAsync((async) async {
        const narrow = CombinedFeedNarrow();
        await prepareStored(messages: List.generate(3, (_) =>
          eg.streamMessage(stream: channel, topic: 'topic',
            flags: [MessageFlag.read])));
        final storeA = store;
        await storeA.addMessage(eg.streamMessage(stream: channel, topic: 'topic',
          flags: [MessageFlag.read]));
        await storeA.handleEvent(eg.updateMessageEditEvent(model.messages[0],
          renderedContent: '<p>edited</p>'));
        await storeA.handleEvent(eg.reactionEvent(
          eg.unicodeEmojiReaction, ReactionOp.add, model.messages[1].id));
        await storeA.handleEvent(eg.deleteMessageEvent(
          [model.messages[2] as StreamMessage]));
        final shownByA = model.messages.map(deepToJson).toList();
        check(shownByA).length.equals(3);
        model.dispose();

        // A new store, as after the app restarts, without those messages.
        final storeB = eg.store(globalStore: globalStore,
          initialSnapshot: eg.initialSnapshot(
            streams: [channel], subscriptions: [eg.subscription(channel)]));
        final connectionB = storeB.connection as FakeApiConnection;
        final modelB = MessageListView.init(store: storeB,
          narrow: narrow, anchor: AnchorCode.newest);
        connectionB.prepare(httpException: const SocketException('failed'));
        final fetchFuture = modelB.fetchInitial();
        async.elapse(Duration.zero);
        check(modelB).showingCachedMessages.isTrue();
        check(modelB.messages.map(deepToJson)).deepEquals(shownByA);
        check(modelB.messages[0]).editState.equals(MessageEditState.edited);

        modelB.dispose();
        await fetchFuture;
        storeB.dispose();
      }));
    });
  });

  group('renarrowAndFetch', () {
    test('smoke', () => awaitFakeAsync((async) async {
      final channel = eg.stream();

      const narrow = CombinedFeedNarrow();
      await prepare(narrow: narrow, stream: channel);
      final messages = List.generate(100,
        (i) => eg.streamMessage(id: 1000 + i, stream: channel));
      await prepareMessages(foundOldest: false, messages: messages);

      // Start a fetchOlder, so we can check that renarrowAndFetch causes its
      // result to be discarded.
      connection.prepare(
        json: olderResult(
          anchor: 1000, foundOldest: false,
          messages: List.generate(100,
            (i) => eg.streamMessage(id: 900 + i, stream: channel)),
        ).toJson(),
        delay: Duration(milliseconds: 500),
      );
      unawaited(model.fetchOlder());
      checkNotifiedOnce();

      // Start the renarrowAndFetch.
      final newNarrow = ChannelNarrow(channel.streamId);
      final newAnchor = NumericAnchor(messages[3].id);

      final result = eg.getMessagesResult(
        anchor: newAnchor,
        foundOldest: false, foundNewest: false,
        messages: messages.sublist(3, 5));
      connection.prepare(json: result.toJson(), delay: Duration(seconds: 1));
      model.renarrowAndFetch(newNarrow, newAnchor);
      checkNotifiedOnce();
      check(model)
        ..fetched.isFalse()
        ..narrow.equals(newNarrow)
        ..anchor.equals(newAnchor)
        ..messages.isEmpty();

      // Elapse until the fetchOlder is done but renarrowAndFetch is still
      // pending; check that the list is still empty despite the fetchOlder.
      async.elapse(Duration(milliseconds: 750));
      check(model)
        ..fetched.isFalse()
        ..narrow.equals(newNarrow)
        ..messages.isEmpty();

      // Elapse until the renarrowAndFetch completes.
      async.elapse(Duration(seconds: 250));
      check(model)
        ..fetched.isTrue()
        ..narrow.equals(newNarrow)
        ..anchor.equals(newAnchor)
        ..messages.length.equals(2);
    }));
  });

  group('fetching more', () {
    test('fetchOlder smoke', () async {
      const narrow = CombinedFeedNarrow();
      await prepare(narrow: narrow);
      await prepareMessages(foundOldest: false,
        messages: List.generate(100, (i) => eg.streamMessage(id: 1000 + i)));

      connection.prepare(json: olderResult(
        anchor: 1000, foundOldest: false,
        messages: List.generate(100, (i) => eg.streamMessage(id: 900 + i)),
      ).toJson());
      final fetchFuture = model.fetchOlder();
      checkNotifiedOnce();
      check(model).busyFetchingMore.isTrue();

      await fetchFuture;
      checkNotifiedOnce();
      check(model)
        ..busyFetchingMore.isFalse()
        ..messages.length.equals(200);
      checkLastRequest(
        narrow: narrow.apiEncode(),
        anchor: '1000',
        includeAnchor: false,
        numBefore: kMessageListFetchBatchSize,
        numAfter: 0,
        allowEmptyTopicName: true,
      );
    });

    group('fetchOlder disposed', () {
      test('before the fetch completes', () async {
        await prepare();
        await prepareMessages(foundOldest: false, messages: [eg.streamMessage(id: 1000)]);

        connection.prepare(json: olderResult(anchor: 1000, foundOldest: false,
          messages: [eg.streamMessage(id: 999)]).toJson());
        final fetchFuture = model.fetchOlder();
        check(model).busyFetchingMore.isTrue();
        model.dispose();

        // If the fetch went on to call notifyListeners on the disposed model,
        // that error would fail this test.
        await fetchFuture;
      });

      test('before the fetch fails', () async {
        await prepare();
        await prepareMessages(foundOldest: false, messages: [eg.streamMessage(id: 1000)]);

        connection.prepare(apiException: eg.apiBadRequest());
        final fetchFuture = model.fetchOlder();
        check(model).busyFetchingMore.isTrue();
        model.dispose();

        // If the failure went on to call notifyListeners on the disposed model,
        // that error would replace the expected one and fail this test.
        await check(fetchFuture).throws<ZulipApiException>();
      });

      test('during backoff after a failure', () => awaitFakeAsync((async) async {
        addTearDown(() => BackoffMachine.debugDuration = null);
        await prepare();
        await prepareMessages(foundOldest: false, messages: [eg.streamMessage(id: 1000)]);

        connection.prepare(apiException: eg.apiBadRequest());
        BackoffMachine.debugDuration = const Duration(seconds: 1);
        await check(model.fetchOlder()).throws<ZulipApiException>();
        check(model).busyFetchingMore.isTrue();
        model.dispose();

        // If the end of the backoff went on to call notifyListeners on
        // the disposed model, that error would fail this test.
        async.elapse(const Duration(seconds: 1));
        check(async.pendingTimers).isEmpty();
      }));
    });

    test('fetchNewer smoke', () async {
      const narrow = CombinedFeedNarrow();
      await prepare(narrow: narrow, anchor: NumericAnchor(1000));
      await prepareMessages(foundOldest: true, foundNewest: false,
        messages: List.generate(100, (i) => eg.streamMessage(id: 1000 + i)));

      connection.prepare(json: newerResult(
        anchor: 1099, foundNewest: false,
        messages: List.generate(100, (i) => eg.streamMessage(id: 1100 + i)),
      ).toJson());
      final fetchFuture = model.fetchNewer();
      checkNotifiedOnce();
      check(model).busyFetchingMore.isTrue();

      await fetchFuture;
      checkNotifiedOnce();
      check(model)
        ..busyFetchingMore.isFalse()
        ..messages.length.equals(200);
      checkLastRequest(
        narrow: narrow.apiEncode(),
        anchor: '1099',
        includeAnchor: false,
        numBefore: 0,
        numAfter: kMessageListFetchBatchSize,
        allowEmptyTopicName: true,
      );
    });

    test('nop when already fetching older', () async {
      await prepare(anchor: NumericAnchor(1000));
      await prepareMessages(foundOldest: false, foundNewest: false,
        messages: List.generate(201, (i) => eg.streamMessage(id: 900 + i)));

      connection.prepare(json: olderResult(
        anchor: 900, foundOldest: false,
        messages: List.generate(100, (i) => eg.streamMessage(id: 800 + i)),
      ).toJson());
      final fetchFuture = model.fetchOlder();
      checkNotifiedOnce();
      check(model).busyFetchingMore.isTrue();

      // Don't prepare another response.
      final fetchFuture2 = model.fetchOlder();
      checkNotNotified();
      check(model).busyFetchingMore.isTrue();
      final fetchFuture3 = model.fetchNewer();
      checkNotNotified();
      check(model)..busyFetchingMore.isTrue()..messages.length.equals(201);

      await fetchFuture;
      await fetchFuture2;
      await fetchFuture3;
      // We must not have made another request, because we didn't
      // prepare another response and didn't get an exception.
      checkNotifiedOnce();
      check(model)..busyFetchingMore.isFalse()..messages.length.equals(301);
    });

    test('nop when already fetching newer', () async {
      await prepare(anchor: NumericAnchor(1000));
      await prepareMessages(foundOldest: false, foundNewest: false,
        messages: List.generate(201, (i) => eg.streamMessage(id: 900 + i)));

      connection.prepare(json: newerResult(
        anchor: 1100, foundNewest: false,
        messages: List.generate(100, (i) => eg.streamMessage(id: 1101 + i)),
      ).toJson());
      final fetchFuture = model.fetchNewer();
      checkNotifiedOnce();
      check(model).busyFetchingMore.isTrue();

      // Don't prepare another response.
      final fetchFuture2 = model.fetchOlder();
      checkNotNotified();
      check(model).busyFetchingMore.isTrue();
      final fetchFuture3 = model.fetchNewer();
      checkNotNotified();
      check(model)..busyFetchingMore.isTrue()..messages.length.equals(201);

      await fetchFuture;
      await fetchFuture2;
      await fetchFuture3;
      // We must not have made another request, because we didn't
      // prepare another response and didn't get an exception.
      checkNotifiedOnce();
      check(model)..busyFetchingMore.isFalse()..messages.length.equals(301);
    });

    test('fetchOlder nop when already haveOldest true', () async {
      await prepare(anchor: NumericAnchor(1000));
      await prepareMessages(foundOldest: true, foundNewest: false, messages:
        List.generate(151, (i) => eg.streamMessage(id: 950 + i)));
      check(model)
        ..haveOldest.isTrue()
        ..messages.length.equals(151);

      await model.fetchOlder();
      // We must not have made a request, because we didn't
      // prepare a response and didn't get an exception.
      checkNotNotified();
      check(model)
        ..haveOldest.isTrue()
        ..messages.length.equals(151);
    });

    test('fetchNewer nop when already haveNewest true', () async {
      await prepare(anchor: NumericAnchor(1000));
      await prepareMessages(foundOldest: false, foundNewest: true, messages:
        List.generate(151, (i) => eg.streamMessage(id: 950 + i)));
      check(model)
        ..haveNewest.isTrue()
        ..messages.length.equals(151);

      await model.fetchNewer();
      // We must not have made a request, because we didn't
      // prepare a response and didn't get an exception.
      checkNotNotified();
      check(model)
        ..haveNewest.isTrue()
        ..messages.length.equals(151);
    });

    test('nop during backoff', () => awaitFakeAsync((async) async {
      final olderMessages = List.generate(5, (i) => eg.streamMessage());
      final initialMessages = List.generate(5, (i) => eg.streamMessage());
      final newerMessages = List.generate(5, (i) => eg.streamMessage());
      await prepare(anchor: NumericAnchor(initialMessages[2].id));
      await prepareMessages(foundOldest: false, foundNewest: false,
        messages: initialMessages);
      check(connection.takeRequests()).single;

      connection.prepare(apiException: eg.apiBadRequest());
      check(async.pendingTimers).isEmpty();
      await check(model.fetchOlder()).throws<ZulipApiException>();
      checkNotified(count: 2);
      check(model).busyFetchingMore.isTrue();
      check(connection.takeRequests()).single;

      await model.fetchOlder();
      checkNotNotified();
      check(model).busyFetchingMore.isTrue();
      check(connection.lastRequest).isNull();

      await model.fetchNewer();
      checkNotNotified();
      check(model).busyFetchingMore.isTrue();
      check(connection.lastRequest).isNull();

      // Wait long enough that a first backoff is sure to finish.
      async.elapse(const Duration(seconds: 1));
      check(model).busyFetchingMore.isFalse();
      checkNotifiedOnce();
      check(connection.lastRequest).isNull();

      connection.prepare(json: olderResult(anchor: initialMessages.first.id,
        foundOldest: false, messages: olderMessages).toJson());
      await model.fetchOlder();
      checkNotified(count: 2);
      check(connection.takeRequests()).single;

      connection.prepare(json: newerResult(anchor: initialMessages.last.id,
        foundNewest: false, messages: newerMessages).toJson());
      await model.fetchNewer();
      checkNotified(count: 2);
      check(connection.takeRequests()).single;
    }));

    // TODO(#824): move this test
    test('fetchOlder recent senders track all the messages', () async {
      await prepare();
      final initialMessages = List.generate(10, (i) => eg.streamMessage(id: 100 + i));
      await prepareMessages(foundOldest: false, messages: initialMessages);

      final oldMessages = List.generate(10, (i) => eg.streamMessage(id: 89 + i))
        // Not subscribed to the stream with id 10.
        ..add(eg.streamMessage(id: 99, stream: eg.stream(streamId: 10)));
      connection.prepare(json: olderResult(
        anchor: 100, foundOldest: false,
        messages: oldMessages,
      ).toJson());
      await model.fetchOlder();

      check(model).messages.length.equals(20);
      recent_senders_test.checkMatchesMessages(store.recentSenders,
        [...initialMessages, ...oldMessages]);
    });

    // TODO(#824): move this test
    test('TODO fetchNewer recent senders track all the messages', () async {
      await prepare(anchor: NumericAnchor(100));
      final initialMessages = List.generate(10, (i) => eg.streamMessage(id: 100 + i));
      await prepareMessages(foundOldest: true, foundNewest: false,
        messages: initialMessages);

      final newMessages = List.generate(10, (i) => eg.streamMessage(id: 110 + i))
        // Not subscribed to the stream with id 10.
        ..add(eg.streamMessage(id: 120, stream: eg.stream(streamId: 10)));
      connection.prepare(json: newerResult(
        anchor: 100, foundNewest: false,
        messages: newMessages,
      ).toJson());
      await model.fetchNewer();

      check(model).messages.length.equals(20);
      recent_senders_test.checkMatchesMessages(store.recentSenders,
        [...initialMessages, ...newMessages]);
    });
  });

  group('oldestFetchedMessageId, newestFetchedMessageId', () {
    final mutedUser = eg.user();

    Message channelMessage({required int id}) =>
      eg.streamMessage(id: id, sender: eg.selfUser);

    List<Message> channelMessages({required int fromId, required int count}) =>
      List.generate(count, (i) => channelMessage(id: fromId + i));

    List<Message> mutedDmMessages({required int fromId, required int count}) =>
      List.generate(count, (i) =>
        eg.dmMessage(id: fromId + i, from: eg.selfUser, to: [mutedUser]));

    group('fetchInitial', () {
      test('visible messages', () async {
        await prepare();
        check(model)
          ..messages.isEmpty()
          ..oldestFetchedMessageId.isNull()..newestFetchedMessageId.isNull();

        connection.prepare(json: newestResult(
          foundOldest: true,
          messages: channelMessages(fromId: 100, count: 100),
        ).toJson());
        await model.fetchInitial();

        checkNotifiedOnce();
        check(model)
          ..messages.length.equals(100)
          ..messages.first.id.equals(100)..messages.last.id.equals(199)
          ..oldestFetchedMessageId.equals(100)..newestFetchedMessageId.equals(199);
      });

      test('invisible messages', () async {
        await prepare(users: [mutedUser], mutedUserIds: [mutedUser.userId]);
        check(model)
          ..messages.isEmpty()
          ..oldestFetchedMessageId.isNull()..newestFetchedMessageId.isNull();

        connection.prepare(json: newestResult(
          foundOldest: true,
          messages: mutedDmMessages(fromId: 100, count: 100),
        ).toJson());
        await model.fetchInitial();

        checkNotifiedOnce();
        check(model)
          ..messages.isEmpty()
          ..oldestFetchedMessageId.equals(100)..newestFetchedMessageId.equals(199);
      });

      test('no messages found', () async {
        await prepare();
        check(model)
          ..messages.isEmpty()
          ..oldestFetchedMessageId.isNull()..newestFetchedMessageId.isNull();

        connection.prepare(json: newestResult(
          foundOldest: true,
          messages: [],
        ).toJson());
        await model.fetchInitial();

        checkNotifiedOnce();
        check(model)
          ..messages.isEmpty()
          ..oldestFetchedMessageId.isNull()..newestFetchedMessageId.isNull();
      });
    });

    group('fetching more', () {
      test('visible messages', () async {
        await prepare(anchor: AnchorCode.firstUnread);
        check(model)
          ..messages.isEmpty()
          ..oldestFetchedMessageId.isNull()..newestFetchedMessageId.isNull();

        await prepareMessages(
          foundOldest: false, foundNewest: false,
          anchorMessageId: 250,
          messages: channelMessages(fromId: 200, count: 100));
        check(model)
          ..messages.length.equals(100)
          ..messages.first.id.equals(200)..messages.last.id.equals(299)
          ..oldestFetchedMessageId.equals(200)..newestFetchedMessageId.equals(299);

        connection.prepare(json: olderResult(
          anchor: 200, foundOldest: true,
          messages: channelMessages(fromId: 100, count: 100),
        ).toJson());
        await model.fetchOlder();
        checkNotified(count: 2);
        check(model)
          ..messages.length.equals(200)
          ..messages.first.id.equals(100)..messages.last.id.equals(299)
          ..oldestFetchedMessageId.equals(100)..newestFetchedMessageId.equals(299);

        connection.prepare(json: newerResult(
          anchor: 299, foundNewest: true,
          messages: channelMessages(fromId: 300, count: 100),
        ).toJson());
        await model.fetchNewer();
        checkNotified(count: 2);
        check(model)
          ..messages.length.equals(300)
          ..messages.first.id.equals(100)..messages.last.id.equals(399)
          ..oldestFetchedMessageId.equals(100)..newestFetchedMessageId.equals(399);
      });

      test('invisible messages', () async {
        await prepare(anchor: AnchorCode.firstUnread,
          users: [mutedUser], mutedUserIds: [mutedUser.userId]);
        check(model)
          ..messages.isEmpty()
          ..oldestFetchedMessageId.isNull()..newestFetchedMessageId.isNull();

        await prepareMessages(
          foundOldest: false, foundNewest: false,
          anchorMessageId: 250,
          messages: [
            ...mutedDmMessages(fromId: 200, count: 40),
            ...channelMessages(fromId: 240, count: 20),
            ...mutedDmMessages(fromId: 260, count: 40),
          ]);
        check(model)
          ..messages.length.equals(20)
          ..messages.first.id.equals(240)..messages.last.id.equals(259)
          ..oldestFetchedMessageId.equals(200)..newestFetchedMessageId.equals(299);

        connection.prepare(json: olderResult(
          anchor: 200, foundOldest: true,
          messages: mutedDmMessages(fromId: 100, count: 100),
        ).toJson());
        await model.fetchOlder();
        checkNotified(count: 2);
        check(connection.lastRequest).isA<http.Request>()
          .url.queryParameters['anchor'].equals('200');
        check(model)
          ..messages.length.equals(20)
          ..messages.first.id.equals(240)..messages.last.id.equals(259)
          ..oldestFetchedMessageId.equals(100)..newestFetchedMessageId.equals(299);

        connection.prepare(json: newerResult(
          anchor: 299, foundNewest: true,
          messages: mutedDmMessages(fromId: 300, count: 100),
        ).toJson());
        await model.fetchNewer();
        checkNotified(count: 2);
        check(connection.lastRequest).isA<http.Request>()
          .url.queryParameters['anchor'].equals('299');
        check(model)
          ..messages.length.equals(20)
          ..messages.first.id.equals(240)..messages.last.id.equals(259)
          ..oldestFetchedMessageId.equals(100)..newestFetchedMessageId.equals(399);
      });

      test('no messages found', () async {
        await prepare(anchor: AnchorCode.firstUnread);
        check(model)
          ..messages.isEmpty()
          ..oldestFetchedMessageId.isNull()..newestFetchedMessageId.isNull();

        await prepareMessages(
          foundOldest: false, foundNewest: false,
          anchorMessageId: 250,
          messages: channelMessages(fromId: 200, count: 100));
        check(model)
          ..messages.length.equals(100)
          ..messages.first.id.equals(200)..messages.last.id.equals(299)
          ..oldestFetchedMessageId.equals(200)..newestFetchedMessageId.equals(299);

        // This can happen if after the initial fetch,
        // all the older messages got deleted/moved out of the narrow.
        connection.prepare(json: olderResult(
          anchor: 200, foundOldest: true,
          messages: [],
        ).toJson());
        await model.fetchOlder();
        checkNotified(count: 2);
        check(model)
          ..messages.length.equals(100)
          ..messages.first.id.equals(200)..messages.last.id.equals(299)
          ..oldestFetchedMessageId.equals(200)..newestFetchedMessageId.equals(299);

        // This can happen if after the initial fetch,
        // all the newer messages got deleted/moved out of the narrow.
        connection.prepare(json: newerResult(
          anchor: 299, foundNewest: true,
          messages: [],
        ).toJson());
        await model.fetchNewer();
        checkNotified(count: 2);
        check(model)
          ..messages.length.equals(100)
          ..messages.first.id.equals(200)..messages.last.id.equals(299)
          ..oldestFetchedMessageId.equals(200)..newestFetchedMessageId.equals(299);
      });
    });

    test('message event', () async {
      await prepare();
      connection.prepare(json: newestResult(
        foundOldest: true,
        messages: channelMessages(fromId: 100, count: 100),
      ).toJson());
      await model.fetchInitial();
      checkNotifiedOnce();
      check(model).newestFetchedMessageId.equals(199);

      await store.addMessage(channelMessage(id: 200));
      checkNotifiedOnce();
      check(model)
        ..messages.last.id.equals(200)
        ..newestFetchedMessageId.equals(200);
    });

    test('message event when no messages fetched', () async {
      await prepare();
      connection.prepare(json: newestResult(
        foundOldest: true, messages: []).toJson());
      await model.fetchInitial();
      checkNotifiedOnce();
      check(model)
        ..oldestFetchedMessageId.isNull()..newestFetchedMessageId.isNull();

      await store.addMessage(channelMessage(id: 100));
      checkNotifiedOnce();
      check(model)
        ..oldestFetchedMessageId.equals(100)..newestFetchedMessageId.equals(100);

      await store.addMessage(channelMessage(id: 200));
      checkNotifiedOnce();
      check(model)
        ..oldestFetchedMessageId.equals(100)..newestFetchedMessageId.equals(200);
    });
  });

  // TODO(#1569): test jumpToEnd

  group('MessageEvent', () {
    test('in narrow', () async {
      final stream = eg.stream();
      await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
      await prepareMessages(foundOldest: true, messages:
        List.generate(30, (i) => eg.streamMessage(stream: stream)));

      check(model).messages.length.equals(30);
      await store.addMessage(eg.streamMessage(stream: stream));
      checkNotifiedOnce();
      check(model).messages.length.equals(31);
    });

    test('not in narrow', () async {
      final stream = eg.stream();
      await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
      await prepareMessages(foundOldest: true, messages:
        List.generate(30, (i) => eg.streamMessage(stream: stream)));

      check(model).messages.length.equals(30);
      final otherStream = eg.stream();
      await store.addMessage(eg.streamMessage(stream: otherStream));
      checkNotNotified();
      check(model).messages.length.equals(30);
    });

    test('in topic narrow: topics compared case-insensitively', () async {
      final channel = eg.stream();
      await prepare(narrow: eg.topicNarrow(channel.streamId, 't'));
      await prepareMessages(foundOldest: true, messages:
        .generate(30, (i) => eg.streamMessage(stream: channel, topic: 't')));

      check(model).messages.length.equals(30);
      await store.addMessage(eg.streamMessage(stream: channel, topic: 'T'));
      checkNotifiedOnce();
      check(model).messages.length.equals(31);
    });

    test('while in mid-history', () async {
      final stream = eg.stream();
      await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream,
        anchor: NumericAnchor(1000));
      await prepareMessages(foundOldest: true, foundNewest: false, messages:
        List.generate(30, (i) => eg.streamMessage(id: 1000 + i, stream: stream)));

      check(model).messages.length.equals(30);
      await store.addMessage(eg.streamMessage(stream: stream));
      checkNotNotified();
      check(model).messages.length.equals(30);
    });

    test('before fetch', () async {
      final stream = eg.stream();
      await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
      await store.addMessage(eg.streamMessage(stream: stream));
      checkNotNotified();
      check(model).fetched.isFalse();
    });

    test('when there are outbox messages', () => awaitFakeAsync((async) async {
      final stream = eg.stream();
      await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
      await prepareMessages(foundOldest: true, messages:
        List.generate(30, (i) => eg.streamMessage(stream: stream)));

      await prepareOutboxMessages(count: 5, stream: stream);
      async.elapse(kLocalEchoDebounceDuration);
      checkNotified(count: 5);
      check(model)
        ..messages.length.equals(30)
        ..outboxMessages.length.equals(5);

      await store.handleEvent(eg.messageEvent(eg.streamMessage(stream: stream)));
      checkNotifiedOnce();
      check(model)
        ..messages.length.equals(31)
        ..outboxMessages.length.equals(5);
    }));

    test('from another client (localMessageId present but unrecognized)', () => awaitFakeAsync((async) async {
      final stream = eg.stream();
      await prepare(narrow: eg.topicNarrow(stream.streamId, 'topic'), stream: stream);
      await prepareMessages(foundOldest: true, messages:
        List.generate(30, (i) => eg.streamMessage(stream: stream, topic: 'topic')));

      check(model)
        ..messages.length.equals(30)
        ..outboxMessages.isEmpty();

      await store.handleEvent(eg.messageEvent(
        eg.streamMessage(stream: stream, topic: 'topic'),
        localMessageId: 1234));
      check(store.outboxMessages).isEmpty();
      checkNotifiedOnce();
      check(model)
        ..messages.length.equals(31)
        ..outboxMessages.isEmpty();

      async.elapse(kLocalEchoDebounceDuration);
      checkNotNotified();
    }));

    test('for an OutboxMessage in the narrow', () => awaitFakeAsync((async) async {
      final stream = eg.stream();
      await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
      await prepareMessages(foundOldest: true, messages:
        List.generate(30, (i) => eg.streamMessage(stream: stream)));

      await prepareOutboxMessages(count: 5, stream: stream);
      async.elapse(kLocalEchoDebounceDuration);
      checkNotified(count: 5);
      final localMessageId = store.outboxMessages.keys.first;
      check(model)
        ..messages.length.equals(30)
        ..outboxMessages.length.equals(5)
        ..outboxMessages.any((message) =>
            message.localMessageId.equals(localMessageId));

      await store.handleEvent(eg.messageEvent(eg.streamMessage(stream: stream),
        localMessageId: localMessageId));
      checkNotifiedOnce();
      check(model)
        ..messages.length.equals(31)
        ..outboxMessages.length.equals(4)
        ..outboxMessages.every((message) =>
            message.localMessageId.not((m) => m.equals(localMessageId)));
    }));

    test('for an OutboxMessage outside the narrow', () => awaitFakeAsync((async) async {
      final stream = eg.stream();
      await prepare(narrow: eg.topicNarrow(stream.streamId, 'topic'), stream: stream);
      await prepareMessages(foundOldest: true, messages:
        List.generate(30, (i) => eg.streamMessage(stream: stream, topic: 'topic')));

      await prepareOutboxMessages(count: 5, stream: stream, topic: 'other');
      final localMessageId = store.outboxMessages.keys.first;
      check(model)
        ..messages.length.equals(30)
        ..outboxMessages.isEmpty();

      await store.handleEvent(eg.messageEvent(
        eg.streamMessage(stream: stream, topic: 'other'),
        localMessageId: localMessageId));
      checkNotNotified();
      check(model)
        ..messages.length.equals(30)
        ..outboxMessages.isEmpty();

      async.elapse(kLocalEchoDebounceDuration);
      checkNotNotified();
    }));

    group('message already in list from fetch/event race', () {
      // Regression tests for: https://github.com/zulip/zulip-flutter/issues/929

      test('no duplicate; adopt event copy of message', () async {
        final stream = eg.stream();
        await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
        final messages = List.generate(30, (i) => eg.streamMessage(stream: stream));
        final message = eg.streamMessage(stream: stream);
        await prepareMessages(foundOldest: true, messages: [...messages, message]);

        check(model).messages.length.equals(31);
        await store.handleEvent(eg.messageEvent(message));
        checkNotifiedOnce();
        check(model).messages.length.equals(31);
        check(model.messages.last).identicalTo(message);
      });

      test('event copy of message has different content', () async {
        // The fetched copy can be newer than the event's copy,
        // as when the message was edited just after being sent;
        // the event queue will separately deliver an update event.
        final stream = eg.stream();
        await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
        final messages = List.generate(30, (i) => eg.streamMessage(stream: stream));
        final message = eg.streamMessage(stream: stream, content: '<p>edited</p>');
        await prepareMessages(foundOldest: true, messages: [...messages, message]);

        final eventMessage = Message.fromJson(
          message.toJson()..['content'] = '<p>original</p>');
        await store.handleEvent(eg.messageEvent(eventMessage));
        checkNotifiedOnce();
        check(model).messages.length.equals(31);
        check(model.messages.last).identicalTo(eventMessage);
        check(model.contents.last).isA<ZulipContent>()
          .equalsNode(parseContent('<p>original</p>'));
      });

      test('with corresponding outbox message', () => awaitFakeAsync((async) async {
        final stream = eg.stream();
        await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
        await prepareOutboxMessages(count: 1, stream: stream);
        final localMessageId = store.outboxMessages.keys.single;
        async.elapse(kLocalEchoDebounceDuration);
        checkNotNotified();

        final messages = List.generate(30, (i) => eg.streamMessage(stream: stream));
        final message = eg.streamMessage(stream: stream);
        await prepareMessages(foundOldest: true, messages: [...messages, message]);
        check(model)
          ..messages.length.equals(31)
          ..outboxMessages.single.localMessageId.equals(localMessageId);

        await store.handleEvent(eg.messageEvent(message,
          localMessageId: localMessageId));
        checkNotifiedOnce();
        check(model)
          ..messages.length.equals(31)
          ..outboxMessages.isEmpty();
      }));

      test('adopt even when narrow.containsMessage is null (e.g. search)', () async {
        // A narrow like [KeywordSearchNarrow] can't say whether a message
        // belongs (containsMessage returns null), but a message the view
        // already has must still adopt the event's copy.
        final stream = eg.stream();
        await prepare(narrow: KeywordSearchNarrow('hello'), stream: stream);
        final messages = List.generate(30, (i) => eg.streamMessage(stream: stream));
        final message = eg.streamMessage(stream: stream, content: '<p>edited</p>');
        await prepareMessages(foundOldest: true,
          messages: [...messages, message]);
        check(model).haveNewest.isTrue();

        final eventMessage = Message.fromJson(
          message.toJson()..['content'] = '<p>original</p>');
        await store.handleEvent(eg.messageEvent(eventMessage));
        checkNotifiedOnce();
        check(model).messages.length.equals(31);
        check(model.messages.last).identicalTo(eventMessage);
        check(model.contents.last).isA<ZulipContent>()
          .equalsNode(parseContent('<p>original</p>'));
      });

      test('adopt even when mid-history (!haveNewest)', () async {
        // The store clobbers its own copy on every message event, so a view must
        // adopt any message it already holds -- even when it isn't caught up to
        // the newest message.
        final stream = eg.stream();
        await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream,
          anchor: NumericAnchor(1000));
        final message = eg.streamMessage(id: 1029, stream: stream,
          content: '<p>edited</p>');
        final messages = [
          for (int i = 0; i < 29; i++) eg.streamMessage(id: 1000 + i, stream: stream),
          message,
        ];
        await prepareMessages(foundOldest: true, foundNewest: false,
          messages: messages);
        check(model).haveNewest.isFalse();

        final eventMessage = Message.fromJson(
          message.toJson()..['content'] = '<p>original</p>');
        await store.handleEvent(eg.messageEvent(eventMessage));
        checkNotifiedOnce();
        check(model).messages.length.equals(30);
        check(model.messages.last).identicalTo(eventMessage);
        check(model.contents.last).isA<ZulipContent>()
          .equalsNode(parseContent('<p>original</p>'));
      });
    });
  });

  group('addOutboxMessage', () {
    final stream = eg.stream();

    test('in narrow', () => awaitFakeAsync((async) async {
      await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
      await prepareMessages(foundOldest: true, messages:
        List.generate(30, (i) => eg.streamMessage(stream: stream)));
      await prepareOutboxMessages(count: 5, stream: stream);
      check(model).outboxMessages.isEmpty();

      async.elapse(kLocalEchoDebounceDuration);
      checkNotified(count: 5);
      check(model).outboxMessages.length.equals(5);
    }));

    test('not in narrow', () => awaitFakeAsync((async) async {
      await prepare(narrow: eg.topicNarrow(stream.streamId, 'topic'), stream: stream);
      await prepareMessages(foundOldest: true, messages:
        List.generate(30, (i) => eg.streamMessage(stream: stream, topic: 'topic')));
      await prepareOutboxMessages(count: 5, stream: stream, topic: 'other topic');
      check(model).outboxMessages.isEmpty();

      async.elapse(kLocalEchoDebounceDuration);
      checkNotNotified();
      check(model).outboxMessages.isEmpty();
    }));

    test('before fetch', () => awaitFakeAsync((async) async {
      await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
      await prepareOutboxMessages(count: 5, stream: stream);
      check(model)
        ..fetched.isFalse()
        ..outboxMessages.isEmpty();

      async.elapse(kLocalEchoDebounceDuration);
      checkNotNotified();
      check(model)
        ..fetched.isFalse()
        ..outboxMessages.isEmpty();
    }));
  });

  group('removeOutboxMessage', () {
    final stream = eg.stream();

    Future<void> prepareFailedOutboxMessages({
      required int count,
      required ZulipStream stream,
      String topic = 'some topic',
    }) async {
      for (int i = 0; i < count; i++) {
        connection.prepare(httpException: SocketException('failed'));
        await check(store.sendMessage(
          destination: StreamDestination(stream.streamId, eg.t(topic)),
          content: 'content')).throws();
      }
    }

    test('in narrow', () async {
      await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
      await prepareMessages(foundOldest: true, messages:
        List.generate(30, (i) => eg.streamMessage(stream: stream, topic: 'topic')));
      await prepareFailedOutboxMessages(count: 5, stream: stream);
      check(model).outboxMessages.length.equals(5);
      checkNotified(count: 5);

      store.takeOutboxMessage(store.outboxMessages.keys.first);
      checkNotifiedOnce();
      check(model).outboxMessages.length.equals(4);
    });

    test('not in narrow', () async {
      await prepare(narrow: eg.topicNarrow(stream.streamId, 'topic'), stream: stream);
      await prepareMessages(foundOldest: true, messages:
        List.generate(30, (i) => eg.streamMessage(stream: stream, topic: 'topic')));
      await prepareFailedOutboxMessages(count: 5, stream: stream, topic: 'other topic');
      check(model).outboxMessages.isEmpty();
      checkNotNotified();

      store.takeOutboxMessage(store.outboxMessages.keys.first);
      check(model).outboxMessages.isEmpty();
      checkNotNotified();
    });

    test('removed outbox message is the only message in narrow', () async {
      await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
      await prepareMessages(foundOldest: true, messages: []);
      await prepareFailedOutboxMessages(count: 1, stream: stream);
      check(model).outboxMessages.single;
      checkNotified(count: 1);

      store.takeOutboxMessage(store.outboxMessages.keys.first);
      check(model).outboxMessages.isEmpty();
      checkNotifiedOnce();
    });
  });

  group('handleMessagesLearnedFromFetch', () {
    final channel = eg.stream();
    final narrow = ChannelNarrow(channel.streamId);
    final initialMessageIds = List.generate(30, (i) => 1000 + i);

    Future<void> prepareNarrow() async {
      await prepare(narrow: narrow, stream: channel);
      // The anchor is [AnchorCode.newest], so the fetch finds the newest.
      await prepareMessages(foundOldest: true, messages: [
        for (final id in initialMessageIds)
          eg.streamMessage(id: id, stream: channel, topic: 'topic')]);
      check(model).haveNewest.isTrue();
    }

    test('newer message in narrow -> invalidate haveNewest; fetchNewer finds it', () async {
      await prepareNarrow();

      // Another message list's fetch learns of a newer message in the narrow
      // (the event queue being stuck, no message event has arrived).
      final message = eg.streamMessage(id: 2000, stream: channel, topic: 'topic');
      store.reconcileMessages([message]);
      checkNotifiedOnce();
      check(model).haveNewest.isFalse();
      checkHasMessageIds(initialMessageIds);

      // A subsequent fetchNewer (which the UI would prompt) finds the message.
      connection.prepare(json: newerResult(
        anchor: initialMessageIds.last, foundNewest: true,
        messages: [message]).toJson());
      final fetchFuture = model.fetchNewer();
      checkNotifiedOnce();
      check(model).busyFetchingMore.isTrue();

      await fetchFuture;
      checkNotifiedOnce();
      check(model)
        ..haveNewest.isTrue()
        ..busyFetchingMore.isFalse();
      checkHasMessageIds([...initialMessageIds, 2000]);
    });

    test('message not in narrow -> no effect', () async {
      await prepareNarrow();

      store.reconcileMessages([
        eg.dmMessage(id: 2000, from: eg.otherUser, to: [eg.selfUser])]);
      checkNotNotified();
      check(model).haveNewest.isTrue();
    });

    test('message in narrow but muted -> no effect', () async {
      await prepareNarrow();
      await store.setUserTopic(channel, 'muted topic', UserTopicVisibilityPolicy.muted);
      checkNotNotified();

      store.reconcileMessages([
        eg.streamMessage(id: 2000, stream: channel, topic: 'muted topic')]);
      checkNotNotified();
      check(model).haveNewest.isTrue();
    });

    test('message not newer than the view -> no effect', () async {
      // A message the view lacks, with an ID inside its fetched history,
      // can arise from a message move.  A fetchNewer wouldn't find it,
      // so don't invalidate.
      await prepareNarrow();

      store.reconcileMessages([
        eg.streamMessage(id: 999, stream: channel, topic: 'topic')]);
      checkNotNotified();
      check(model).haveNewest.isTrue();
    });

    test('message in fetched range but not in view -> no effect', () async {
      // The end of the fetched range is in a muted topic, so [messages]
      // ends before [newestFetchedMessageId].  A message learned within
      // that range (as from a message move) is newer than all the messages
      // in the view, but a fetchNewer wouldn't find it, so don't invalidate.
      await prepare(narrow: narrow, stream: channel);
      await store.setUserTopic(channel, 'muted topic', UserTopicVisibilityPolicy.muted);
      await prepareMessages(foundOldest: true, messages: [
        for (final id in initialMessageIds.take(25))
          eg.streamMessage(id: id, stream: channel, topic: 'topic'),
        for (final id in initialMessageIds.skip(26))
          eg.streamMessage(id: id, stream: channel, topic: 'muted topic')]);
      check(model).haveNewest.isTrue();
      checkHasMessageIds(initialMessageIds.take(25));

      store.reconcileMessages([
        eg.streamMessage(id: initialMessageIds[25], stream: channel, topic: 'topic')]);
      checkNotNotified();
      check(model).haveNewest.isTrue();
    });

    test('message already known to store -> no effect', () async {
      await prepareNarrow();

      store.reconcileMessages([
        eg.streamMessage(id: initialMessageIds.last, stream: channel, topic: 'topic')]);
      checkNotNotified();
      check(model).haveNewest.isTrue();
    });

    test('newer message from event -> fetchNewer anchors there', () async {
      // A message added on an event extends the range a fetchNewer
      // would be redundant over.  Anchoring the fetch before it
      // would corrupt the view with a duplicate.
      await prepareNarrow();
      await store.addMessage(
        eg.streamMessage(id: 1100, stream: channel, topic: 'topic'));
      checkNotifiedOnce();
      checkHasMessageIds([...initialMessageIds, 1100]);

      final message = eg.streamMessage(id: 2000, stream: channel, topic: 'topic');
      store.reconcileMessages([message]);
      checkNotifiedOnce();
      check(model).haveNewest.isFalse();

      connection.prepare(json: newerResult(
        anchor: 1100, foundNewest: true, messages: [message]).toJson());
      final fetchFuture = model.fetchNewer();
      checkNotifiedOnce();
      await fetchFuture;
      checkNotifiedOnce();
      checkLastRequest(
        narrow: narrow.apiEncode(),
        anchor: '1100',
        includeAnchor: false,
        numBefore: 0,
        numAfter: kMessageListFetchBatchSize,
        allowEmptyTopicName: true,
      );
      checkHasMessageIds([...initialMessageIds, 1100, 2000]);
    });

    test('all messages from events, none from a fetch -> invalidate', () async {
      // Regression test for a crash: with no messages ever fetched,
      // [MessageListView.fetchNewer] has no fetched message to anchor at,
      // but it can anchor at a message added on an event.
      await prepare(narrow: narrow, stream: channel);
      await prepareMessages(foundOldest: true, messages: []);
      await store.addMessage(
        eg.streamMessage(id: 1000, stream: channel, topic: 'topic'));
      checkNotifiedOnce();
      checkHasMessageIds([1000]);

      final message = eg.streamMessage(id: 2000, stream: channel, topic: 'topic');
      store.reconcileMessages([message]);
      checkNotifiedOnce();
      check(model).haveNewest.isFalse();

      connection.prepare(json: newerResult(
        anchor: 1000, foundNewest: true, messages: [message]).toJson());
      final fetchFuture = model.fetchNewer();
      checkNotifiedOnce();
      await fetchFuture;
      checkNotifiedOnce();
      check(model).haveNewest.isTrue();
      checkHasMessageIds([1000, 2000]);
    });

    test('when not haveNewest -> no effect', () async {
      await prepare(narrow: narrow, stream: channel,
        anchor: NumericAnchor(initialMessageIds.first));
      await prepareMessages(foundOldest: true, foundNewest: false, messages: [
        for (final id in initialMessageIds)
          eg.streamMessage(id: id, stream: channel, topic: 'topic')]);
      check(model).haveNewest.isFalse();

      store.reconcileMessages([
        eg.streamMessage(id: 2000, stream: channel, topic: 'topic')]);
      checkNotNotified();
      check(model).haveNewest.isFalse();
    });

    test('empty narrow -> reset and refetch', () => awaitFakeAsync((async) async {
      await prepare(narrow: narrow, stream: channel);
      await prepareMessages(foundOldest: true, messages: []);
      check(model).haveNewest.isTrue();
      check(model).messages.isEmpty();

      final message = eg.streamMessage(id: 2000, stream: channel, topic: 'topic');
      connection.prepare(delay: const Duration(seconds: 2), json: newestResult(
        foundOldest: true, messages: [message]).toJson());
      store.reconcileMessages([message]);
      check(model).fetched.isFalse();
      checkNotifiedOnce();

      async.elapse(const Duration(seconds: 2));
      checkHasMessageIds([2000]);
      check(model).haveNewest.isTrue();
      checkNotifiedOnce();
    }));

    test('empty narrow, message in muted topic -> no effect', () async {
      await prepare(narrow: narrow, stream: channel);
      await store.setUserTopic(channel, 'muted topic', UserTopicVisibilityPolicy.muted);
      await prepareMessages(foundOldest: true, messages: []);
      check(model).haveNewest.isTrue();

      store.reconcileMessages([
        eg.streamMessage(id: 2000, stream: channel, topic: 'muted topic')]);
      checkNotNotified();
      check(model).fetched.isTrue();
    });

    test('outbox messages removed, and restored when fetch reaches end', () => awaitFakeAsync((async) async {
      await prepareNarrow();
      connection.prepare(httpException: SocketException('failed'));
      await check(store.sendMessage(
        destination: StreamDestination(channel.streamId, eg.t('topic')),
        content: 'content')).throws();
      check(model).outboxMessages.single;
      checkNotifiedOnce();

      // Learning of someone else's newer message invalidates [haveNewest],
      // which requires removing the outbox messages from the view
      // (they belong only at the true end of history).
      final message = eg.streamMessage(id: 2000, stream: channel, topic: 'topic');
      store.reconcileMessages([message]);
      checkNotifiedOnce();
      check(model)
        ..haveNewest.isFalse()
        ..outboxMessages.isEmpty();
      // ... but they remain in the store.
      check(store.outboxMessages).length.equals(1);

      // When a fetch again reaches the newest messages,
      // the outbox messages reappear, after the newly fetched message.
      connection.prepare(json: newerResult(
        anchor: initialMessageIds.last, foundNewest: true,
        messages: [message]).toJson());
      final fetchFuture = model.fetchNewer();
      checkNotifiedOnce();
      await fetchFuture;
      checkNotifiedOnce();
      check(model)
        ..haveNewest.isTrue()
        ..outboxMessages.single;
      checkHasMessageIds([...initialMessageIds, 2000]);
    }));

    test('jumpToEnd after invalidation', () => awaitFakeAsync((async) async {
      // Regression test for an assertion failure: invalidation can leave
      // [MessageListView.anchor] still at [AnchorCode.newest],
      // and the scroll-to-bottom button calls [MessageListView.jumpToEnd]
      // whenever not [haveNewest].
      await prepareNarrow();
      check(model).anchor.equals(AnchorCode.newest);

      final message = eg.streamMessage(id: 2000, stream: channel, topic: 'topic');
      store.reconcileMessages([message]);
      checkNotifiedOnce();
      check(model).haveNewest.isFalse();

      connection.prepare(json: newestResult(foundOldest: true, messages: [
        for (final id in initialMessageIds)
          eg.streamMessage(id: id, stream: channel, topic: 'topic'),
        message]).toJson());
      model.jumpToEnd();
      checkNotifiedOnce();
      async.elapse(Duration.zero);
      checkNotifiedOnce();
      check(model).haveNewest.isTrue();
      checkHasMessageIds([...initialMessageIds, 2000]);
    }));
  });

  group('UserTopicEvent', () {
    // The ChannelStore.willAffectIfTopicVisible/InChannel methods have their
    // own thorough unit tests.  So these tests focus on the rest of the logic.

    final stream = eg.stream();
    const String topic = 'foo';

    Future<void> setVisibility(UserTopicVisibilityPolicy policy) async {
      await store.handleEvent(eg.userTopicEvent(stream.streamId, topic, policy));
    }

    /// (Should run after `prepare`.)
    Future<void> prepareMutes([
      bool streamMuted = false,
      UserTopicVisibilityPolicy policy = UserTopicVisibilityPolicy.none,
    ]) async {
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream, isMuted: streamMuted));
      await setVisibility(policy);
    }

    test('mute a visible topic', () => awaitFakeAsync((async) async {
      await prepare(narrow: const CombinedFeedNarrow());
      await prepareMutes();
      final otherStream = eg.stream();
      await store.addStream(otherStream);
      await store.addSubscription(eg.subscription(otherStream));
      await prepareMessages(foundOldest: true, messages: [
        eg.streamMessage(id: 1, stream: stream, topic: 'bar'),
        eg.streamMessage(id: 2, stream: stream, topic: 'foo'),
        eg.streamMessage(id: 3, stream: stream, topic: 'FOO'),
        eg.streamMessage(id: 4, stream: otherStream, topic: 'elsewhere'),
        eg.dmMessage(    id: 5, from: eg.otherUser, to: [eg.selfUser]),
      ]);
      checkHasMessageIds([1, 2, 3, 4, 5]);

      await prepareOutboxMessagesTo([
        StreamDestination(stream.streamId, eg.t('foo')),
        StreamDestination(stream.streamId, eg.t('FOO')),
        StreamDestination(stream.streamId, eg.t('elsewhere')),
        DmDestination(userIds: [eg.selfUser.userId]),
      ]);
      async.elapse(kLocalEchoDebounceDuration);
      checkNotified(count: 4);
      check(model).outboxMessages.deepEquals(<Condition<Object?>>[
        (it) => it.isA<StreamOutboxMessage>()
                  .conversation.topic.equals(eg.t('foo')),
        (it) => it.isA<StreamOutboxMessage>()
                  .conversation.topic.equals(eg.t('FOO')),
        (it) => it.isA<StreamOutboxMessage>()
                  .conversation.topic.equals(eg.t('elsewhere')),
        (it) => it.isA<DmOutboxMessage>()
                  .conversation.allRecipientIds.deepEquals([eg.selfUser.userId]),
      ]);

      await setVisibility(UserTopicVisibilityPolicy.muted);
      checkNotifiedOnce();
      checkHasMessageIds([1, 4, 5]);
      check(model).outboxMessages.deepEquals(<Condition<Object?>>[
        (it) => it.isA<StreamOutboxMessage>()
                  .conversation.topic.equals(eg.t('elsewhere')),
        (it) => it.isA<DmOutboxMessage>()
                  .conversation.allRecipientIds.deepEquals([eg.selfUser.userId]),
      ]);
    }));

    test('mute a visible topic containing only outbox messages', () => awaitFakeAsync((async) async {
      await prepare(narrow: const CombinedFeedNarrow());
      await prepareMutes();
      await prepareMessages(foundOldest: true, messages: []);
      await prepareOutboxMessagesTo([
        StreamDestination(stream.streamId, eg.t(topic)),
        StreamDestination(stream.streamId, eg.t(topic)),
        StreamDestination(stream.streamId, eg.t(topic.toUpperCase())),
      ]);
      async.elapse(kLocalEchoDebounceDuration);
      check(model).outboxMessages.length.equals(3);
      checkNotified(count: 3);

      await setVisibility(UserTopicVisibilityPolicy.muted);
      check(model).outboxMessages.isEmpty();
      checkNotifiedOnce();
    }));

    test('in CombinedFeedNarrow, use combined-feed visibility', () async {
      // Compare the parallel ChannelNarrow test below.
      await prepare(narrow: const CombinedFeedNarrow());
      // Mute the stream, so that combined-feed vs. stream visibility differ.
      await prepareMutes(true, UserTopicVisibilityPolicy.followed);
      await prepareMessages(foundOldest: true, messages: [
        eg.streamMessage(id: 1, stream: stream, topic: topic),
      ]);
      checkHasMessageIds([1]);

      // Dropping from followed to none hides the message
      // (whereas it'd have no effect in a stream narrow).
      await setVisibility(UserTopicVisibilityPolicy.none);
      checkNotifiedOnce();
      checkHasMessageIds([]);

      // Dropping from none to muted has no further effect
      // (whereas it'd hide the message in a stream narrow).
      await setVisibility(UserTopicVisibilityPolicy.muted);
      checkNotNotified();
      checkHasMessageIds([]);
    });

    test('in ChannelNarrow, use stream visibility', () async {
      // Compare the parallel CombinedFeedNarrow test above.
      await prepare(narrow: ChannelNarrow(stream.streamId));
      // Mute the stream, so that combined-feed vs. stream visibility differ.
      await prepareMutes(true, UserTopicVisibilityPolicy.followed);
      await prepareMessages(foundOldest: true, messages: [
        eg.streamMessage(id: 1, stream: stream, topic: topic),
      ]);
      checkHasMessageIds([1]);

      // Dropping from followed to none has no effect
      // (whereas it'd hide the message in the combined feed).
      await setVisibility(UserTopicVisibilityPolicy.none);
      checkNotNotified();
      checkHasMessageIds([1]);

      // Dropping from none to muted hides the message
      // (whereas it'd have no effect in the combined feed).
      await setVisibility(UserTopicVisibilityPolicy.muted);
      checkNotifiedOnce();
      checkHasMessageIds([]);
    });

    test('in TopicNarrow, stay visible', () async {
      await prepare(narrow: eg.topicNarrow(stream.streamId, topic));
      await prepareMutes();
      await prepareMessages(foundOldest: true, messages: [
        eg.streamMessage(id: 1, stream: stream, topic: topic),
      ]);
      checkHasMessageIds([1]);

      await setVisibility(UserTopicVisibilityPolicy.muted);
      checkNotNotified();
      checkHasMessageIds([1]);
    });

    test('in DmNarrow, do nothing (smoke test)', () async {
      await prepare(narrow:
        DmNarrow.withUser(eg.otherUser.userId, selfUserId: eg.selfUser.userId));
      await prepareMutes();
      await prepareMessages(foundOldest: true, messages: [
        eg.dmMessage(id: 1, from: eg.otherUser, to: [eg.selfUser]),
      ]);
      checkHasMessageIds([1]);

      await setVisibility(UserTopicVisibilityPolicy.muted);
      checkNotNotified();
      checkHasMessageIds([1]);
    });

    test('no affected messages -> no notification', () => awaitFakeAsync((async) async {
      await prepare(narrow: const CombinedFeedNarrow());
      await prepareMutes();
      await prepareMessages(foundOldest: true, messages: [
        eg.streamMessage(id: 1, stream: stream, topic: 'bar'),
      ]);
      checkHasMessageIds([1]);

      await prepareOutboxMessagesTo(
        [StreamDestination(stream.streamId, eg.t('bar'))]);
      async.elapse(kLocalEchoDebounceDuration);
      final outboxMessage = model.outboxMessages.single;
      checkNotifiedOnce();

      await setVisibility(UserTopicVisibilityPolicy.muted);
      checkNotNotified();
      checkHasMessageIds([1]);
      check(model).outboxMessages.single.equals(outboxMessage);
    }));

    test('unmute a topic -> refetch from scratch', () => awaitFakeAsync((async) async {
      await prepare(narrow: const CombinedFeedNarrow());
      await prepareMutes(true);
      final messages = <Message>[
        eg.dmMessage(id: 1, from: eg.otherUser, to: [eg.selfUser]),
        eg.streamMessage(id: 2, stream: stream, topic: topic),
      ];
      await prepareMessages(foundOldest: true, messages: messages);
      await store.setUserTopic(stream, 'muted', UserTopicVisibilityPolicy.muted);
      await prepareOutboxMessagesTo([
        StreamDestination(stream.streamId, eg.t(topic)),
        StreamDestination(stream.streamId, eg.t('muted')),
      ]);
      async.elapse(kLocalEchoDebounceDuration);
      checkHasMessageIds([1]);
      check(model).outboxMessages.isEmpty();

      connection.prepare(
        json: newestResult(foundOldest: true, messages: messages).toJson());
      await setVisibility(UserTopicVisibilityPolicy.unmuted);
      checkNotifiedOnce();
      check(model).fetched.isFalse();
      checkHasMessageIds([]);
      check(model).outboxMessages.isEmpty();

      async.elapse(Duration.zero);
      checkNotifiedOnce();
      checkHasMessageIds([1, 2]);
      check(model).outboxMessages.single.isA<StreamOutboxMessage>().conversation
        ..streamId.equals(stream.streamId)
        ..topic.equals(eg.t(topic));
    }));

    test('unmute a topic before initial fetch completes -> do nothing', () async {
      await prepare(narrow: const CombinedFeedNarrow());
      await prepareMutes(true);
      final messages = [
        eg.streamMessage(id: 1, stream: stream, topic: topic),
      ];

      connection.prepare(
        json: newestResult(foundOldest: true, messages: messages).toJson());
      final fetchFuture = model.fetchInitial();

      await setVisibility(UserTopicVisibilityPolicy.unmuted);
      checkNotNotified();

      // The new policy does get applied when the fetch eventually completes.
      await fetchFuture;
      checkNotifiedOnce();
      checkHasMessageIds([1]);
    });
  });

  group('SubscriptionEvent', () {
    // ChannelStore.isTopicVisible has its own thorough unit tests.
    // So these tests focus on the rest of the logic.

    final channel = eg.stream();
    final otherChannel = eg.stream();

    Future<void> setChannelMuted(bool value) async {
      await store.updateSubscription(channel.streamId,
        SubscriptionProperty.isMuted, value);
    }

    /// Set up [model] on [narrow], subscribed to [channel] and [otherChannel],
    /// with a topic in [channel] the user has unmuted and one they follow.
    Future<void> prepareChannels(Narrow narrow, {List<int>? starredMessages}) async {
      await prepare(narrow: narrow, stream: channel,
        starredMessages: starredMessages);
      await store.addStream(otherChannel);
      await store.addSubscription(eg.subscription(otherChannel));
      await store.setUserTopic(channel, 'unmuted', UserTopicVisibilityPolicy.unmuted);
      await store.setUserTopic(channel, 'followed', UserTopicVisibilityPolicy.followed);
    }

    /// Messages in [channel] (in a topic with no policy, then the unmuted
    /// and followed topics), then in [otherChannel], then a DM.
    List<Message> combinedFeedMessages() => [
      eg.streamMessage(id: 1, stream: channel, topic: 'plain'),
      eg.streamMessage(id: 2, stream: channel, topic: 'unmuted'),
      eg.streamMessage(id: 3, stream: channel, topic: 'followed'),
      eg.streamMessage(id: 4, stream: otherChannel, topic: 'plain'),
      eg.dmMessage(    id: 5, from: eg.otherUser, to: [eg.selfUser]),
    ];

    test('mute a channel: remove its messages no longer visible', () => awaitFakeAsync((async) async {
      await prepareChannels(const CombinedFeedNarrow());
      await prepareMessages(foundOldest: true, messages: combinedFeedMessages());
      checkHasMessageIds([1, 2, 3, 4, 5]);

      await prepareOutboxMessagesTo([
        StreamDestination(channel.streamId, eg.t('plain')),
        StreamDestination(channel.streamId, eg.t('followed')),
        StreamDestination(otherChannel.streamId, eg.t('plain')),
      ]);
      async.elapse(kLocalEchoDebounceDuration);
      checkNotified(count: 3);

      await setChannelMuted(true);
      checkNotifiedOnce();
      checkHasMessageIds([2, 3, 4, 5]);
      check(model).outboxMessages.deepEquals(<Condition<Object?>>[
        (it) => it.isA<StreamOutboxMessage>().conversation
                  ..streamId.equals(channel.streamId)
                  ..topic.equals(eg.t('followed')),
        (it) => it.isA<StreamOutboxMessage>().conversation
                  ..streamId.equals(otherChannel.streamId)
                  ..topic.equals(eg.t('plain')),
      ]);
    }));

    test('mute a channel, no messages affected: no notification', () async {
      await prepareChannels(const CombinedFeedNarrow());
      await prepareMessages(foundOldest: true,
        messages: combinedFeedMessages().sublist(1));
      checkHasMessageIds([2, 3, 4, 5]);

      await setChannelMuted(true);
      checkNotNotified();
      checkHasMessageIds([2, 3, 4, 5]);
    });

    test('unmute a channel: refetch from scratch', () => awaitFakeAsync((async) async {
      await prepareChannels(const CombinedFeedNarrow());
      await setChannelMuted(true);
      final messages = combinedFeedMessages();
      await prepareMessages(foundOldest: true, messages: messages);
      checkHasMessageIds([2, 3, 4, 5]);

      connection.prepare(
        json: newestResult(foundOldest: true, messages: messages).toJson());
      await setChannelMuted(false);
      checkNotifiedOnce();
      check(model).fetched.isFalse();
      checkHasMessageIds([]);

      async.elapse(Duration.zero);
      checkNotifiedOnce();
      checkHasMessageIds([1, 2, 3, 4, 5]);
    }));

    test('unmute a channel before initial fetch completes: do nothing', () async {
      await prepareChannels(const CombinedFeedNarrow());
      await setChannelMuted(true);
      connection.prepare(json: newestResult(foundOldest: true,
        messages: combinedFeedMessages()).toJson());
      final fetchFuture = model.fetchInitial();

      await setChannelMuted(false);
      checkNotNotified();

      // The new state does get applied when the fetch eventually completes.
      await fetchFuture;
      checkNotifiedOnce();
      checkHasMessageIds([1, 2, 3, 4, 5]);
    });

    test('unsubscribe: remove its messages no longer visible', () async {
      await prepareChannels(const CombinedFeedNarrow());
      await prepareMessages(foundOldest: true, messages: combinedFeedMessages());
      checkHasMessageIds([1, 2, 3, 4, 5]);

      await store.removeSubscription(channel.streamId);
      checkNotifiedOnce();
      checkHasMessageIds([2, 3, 4, 5]);
    });

    test('subscribe: refetch from scratch', () => awaitFakeAsync((async) async {
      await prepareChannels(const CombinedFeedNarrow());
      await store.removeSubscription(channel.streamId);
      final messages = combinedFeedMessages();
      await prepareMessages(foundOldest: true, messages: messages);
      checkHasMessageIds([2, 3, 4, 5]);

      connection.prepare(
        json: newestResult(foundOldest: true, messages: messages).toJson());
      await store.addSubscription(eg.subscription(channel));
      checkNotifiedOnce();
      check(model).fetched.isFalse();

      async.elapse(Duration.zero);
      checkNotifiedOnce();
      checkHasMessageIds([1, 2, 3, 4, 5]);
    }));

    test('subscribe muted: no effect', () async {
      await prepareChannels(const CombinedFeedNarrow());
      await store.removeSubscription(channel.streamId);
      await prepareMessages(foundOldest: true, messages: combinedFeedMessages());
      checkHasMessageIds([2, 3, 4, 5]);

      await store.addSubscription(eg.subscription(channel, isMuted: true));
      checkNotNotified();
      check(model).fetched.isTrue();
      checkHasMessageIds([2, 3, 4, 5]);
    });

    test('other subscription property: no effect', () async {
      await prepareChannels(const CombinedFeedNarrow());
      await prepareMessages(foundOldest: true, messages: combinedFeedMessages());

      await store.updateSubscription(channel.streamId,
        SubscriptionProperty.pinToTop, true);
      checkNotNotified();
      check(model).fetched.isTrue();
      checkHasMessageIds([1, 2, 3, 4, 5]);
    });

    group('mute, unmute, unsubscribe, in other narrows: no effect', () {
      Future<void> checkNoEffect(Narrow narrow, List<Message> messages, {
        List<int>? starredMessages,
      }) async {
        await prepareChannels(narrow, starredMessages: starredMessages);
        await prepareMessages(foundOldest: true, messages: messages);
        checkHasMessages(messages);

        await setChannelMuted(true);
        checkNotNotified();
        await setChannelMuted(false);
        checkNotNotified();
        await store.removeSubscription(channel.streamId);
        checkNotNotified();
        check(model).fetched.isTrue();
        checkHasMessages(messages);
      }

      test('ChannelNarrow', () => checkNoEffect(ChannelNarrow(channel.streamId),
        [eg.streamMessage(stream: channel, topic: 'plain')]));

      test('TopicNarrow', () => checkNoEffect(eg.topicNarrow(channel.streamId, 'plain'),
        [eg.streamMessage(stream: channel, topic: 'plain')]));

      test('MentionsNarrow', () => checkNoEffect(const MentionsNarrow(),
        [eg.streamMessage(stream: channel, topic: 'plain',
          flags: [MessageFlag.mentioned])]));

      test('StarredMessagesNarrow', () {
        final message = eg.streamMessage(stream: channel, topic: 'plain',
          flags: [MessageFlag.starred]);
        return checkNoEffect(const StarredMessagesNarrow(), [message],
          starredMessages: [message.id]);
      });
    });

    group('subscribe, in other narrows', () {
      /// Check the effect on a view of [narrow] of subscribing to [channel]
      /// while it shows [messages], with [fresh] as the result of any refetch.
      Future<void> checkSubscribe(FakeAsync async, Narrow narrow, {
        required List<Message> messages,
        List<Message>? fresh,
        List<int>? starredMessages,
      }) async {
        await prepareChannels(narrow, starredMessages: starredMessages);
        await store.removeSubscription(channel.streamId);
        await prepareMessages(foundOldest: true, messages: messages);
        checkHasMessages(messages);

        if (fresh != null) {
          connection.prepare(
            json: newestResult(foundOldest: true, messages: fresh).toJson());
        }
        await store.addSubscription(eg.subscription(channel));
        if (fresh == null) {
          checkNotNotified();
          check(model).fetched.isTrue();
          checkHasMessages(messages);
          return;
        }
        checkNotifiedOnce();
        check(model).fetched.isFalse();
        checkHasMessages([]);

        async.elapse(Duration.zero);
        checkNotifiedOnce();
        checkHasMessages(fresh);
      }

      // While unsubscribed, the event queue doesn't bring
      // the channel's new messages, so the view may lack some.
      test('ChannelNarrow: refetch from scratch', () => awaitFakeAsync((async) async {
        final messages = [eg.streamMessage(stream: channel, topic: 'plain')];
        await checkSubscribe(async, ChannelNarrow(channel.streamId),
          messages: messages,
          fresh: [...messages, eg.streamMessage(stream: channel, topic: 'other')]);
      }));

      test('TopicNarrow: refetch from scratch', () => awaitFakeAsync((async) async {
        final messages = [eg.streamMessage(stream: channel, topic: 'plain')];
        await checkSubscribe(async, eg.topicNarrow(channel.streamId, 'plain'),
          messages: messages,
          fresh: [...messages, eg.streamMessage(stream: channel, topic: 'plain')]);
      }));

      test('ChannelNarrow, other channel: no effect', () => awaitFakeAsync((async) async {
        await checkSubscribe(async, ChannelNarrow(otherChannel.streamId),
          messages: [eg.streamMessage(stream: otherChannel)]);
      }));

      test('TopicNarrow, other channel: no effect', () => awaitFakeAsync((async) async {
        await checkSubscribe(async, eg.topicNarrow(otherChannel.streamId, 'plain'),
          messages: [eg.streamMessage(stream: otherChannel, topic: 'plain')]);
      }));

      test('MentionsNarrow: no effect', () => awaitFakeAsync((async) async {
        await checkSubscribe(async, const MentionsNarrow(),
          messages: [eg.streamMessage(stream: channel, topic: 'plain',
            flags: [MessageFlag.mentioned])]);
      }));

      test('StarredMessagesNarrow: no effect', () => awaitFakeAsync((async) async {
        final message = eg.streamMessage(stream: channel, topic: 'plain',
          flags: [MessageFlag.starred]);
        await checkSubscribe(async, const StarredMessagesNarrow(),
          messages: [message], starredMessages: [message.id]);
      }));
    });
  });

  group('MutedUsersEvent', () {
    final user1 = eg.user(userId: 1);
    final user2 = eg.user(userId: 2);
    final user3 = eg.user(userId: 3);
    final users = [user1, user2, user3];

    test('CombinedFeedNarrow', () async {
      await prepare(narrow: CombinedFeedNarrow(), users: users);
      await prepareMessages(foundOldest: true, messages: [
        eg.dmMessage(id: 1, from: eg.selfUser, to: [user1]),
        eg.dmMessage(id: 2, from: eg.selfUser, to: [user1, user2]),
        eg.dmMessage(id: 3, from: eg.selfUser, to: [user2, user3]),
        eg.dmMessage(id: 4, from: eg.selfUser, to: []),
        eg.streamMessage(id: 5),
      ]);
      checkHasMessageIds([1, 2, 3, 4, 5]);

      await store.setMutedUsers([user1.userId]);
      checkNotifiedOnce();
      checkHasMessageIds([2, 3, 4, 5]);

      await store.setMutedUsers([user1.userId, user2.userId]);
      checkNotifiedOnce();
      checkHasMessageIds([3, 4, 5]);
    });

    test('MentionsNarrow', () async {
      await prepare(narrow: MentionsNarrow(), users: users);
      await prepareMessages(foundOldest: true, messages: [
        eg.dmMessage(id: 1, from: eg.selfUser, to: [user1],
          flags: [MessageFlag.mentioned]),
        eg.dmMessage(id: 2, from: eg.selfUser, to: [user2],
          flags: [MessageFlag.mentioned]),
        eg.streamMessage(id: 3, flags: [MessageFlag.mentioned]),
      ]);
      checkHasMessageIds([1, 2, 3]);

      await store.setMutedUsers([user1.userId]);
      checkNotifiedOnce();
      checkHasMessageIds([2, 3]);
    });

    test('StarredMessagesNarrow', () async {
      await prepare(
        narrow: StarredMessagesNarrow(),
        starredMessages: [1, 2, 3],
        users: users);
      await prepareMessages(foundOldest: true, messages: [
        eg.dmMessage(id: 1, from: eg.selfUser, to: [user1],
          flags: [MessageFlag.starred]),
        eg.dmMessage(id: 2, from: eg.selfUser, to: [user2],
          flags: [MessageFlag.starred]),
        eg.streamMessage(id: 3, flags: [MessageFlag.starred]),
      ]);
      checkHasMessageIds([1, 2, 3]);

      await store.setMutedUsers([user1.userId]);
      checkNotNotified();
      checkHasMessageIds([1, 2, 3]);
    });

    test('ChannelNarrow -> do nothing', () async {
      await prepare(narrow: ChannelNarrow(eg.defaultStreamMessageStreamId), users: users);
      await prepareMessages(foundOldest: true, messages: [
        eg.streamMessage(id: 1),
      ]);
      checkHasMessageIds([1]);

      await store.setMutedUsers([user1.userId]);
      checkNotNotified();
      checkHasMessageIds([1]);
    });

    test('TopicNarrow -> do nothing', () async {
      await prepare(narrow: TopicNarrow(eg.defaultStreamMessageStreamId,
        TopicName('topic')), users: users);
      await prepareMessages(foundOldest: true, messages: [
        eg.streamMessage(id: 1, topic: 'topic'),
      ]);
      checkHasMessageIds([1]);

      await store.setMutedUsers([user1.userId]);
      checkNotNotified();
      checkHasMessageIds([1]);
    });

    test('DmNarrow -> do nothing', () async {
      await prepare(
        narrow: DmNarrow.withUser(user1.userId, selfUserId: eg.selfUser.userId),
        users: users);
      await prepareMessages(foundOldest: true, messages: [
        eg.dmMessage(id: 1, from: eg.selfUser, to: [user1]),
      ]);
      checkHasMessageIds([1]);

      await store.setMutedUsers([user1.userId]);
      checkNotNotified();
      checkHasMessageIds([1]);
    });

    test('unmute a user -> refetch from scratch', () => awaitFakeAsync((async) async {
      await prepare(narrow: CombinedFeedNarrow(), users: users,
        mutedUserIds: [user1.userId]);
      final messages = <Message>[
        eg.dmMessage(id: 1, from: eg.selfUser, to: [user1]),
        eg.streamMessage(id: 2),
      ];
      await prepareMessages(foundOldest: true, messages: messages);
      checkHasMessageIds([2]);

      connection.prepare(
        json: newestResult(foundOldest: true, messages: messages).toJson());
      await store.setMutedUsers([]);
      checkNotifiedOnce();
      check(model).fetched.isFalse();
      checkHasMessageIds([]);

      async.elapse(Duration.zero);
      checkNotifiedOnce();
      checkHasMessageIds([1, 2]);
    }));

    test('unmute a user before initial fetch completes -> do nothing', () async {
      await prepare(narrow: CombinedFeedNarrow(), users: users,
        mutedUserIds: [user1.userId]);
      final messages = <Message>[
        eg.dmMessage(id: 1, from: eg.selfUser, to: [user1]),
        eg.streamMessage(id: 2),
      ];
      connection.prepare(
        json: newestResult(foundOldest: true, messages: messages).toJson());
      final fetchFuture = model.fetchInitial();
      await store.setMutedUsers([]);
      checkNotNotified();

      await fetchFuture;
      checkNotifiedOnce();
      checkHasMessageIds([1, 2]);
    });
  });

  group('DeleteMessageEvent', () {
    final stream = eg.stream();
    final messages = List.generate(30, (i) => eg.streamMessage(stream: stream));

    test('all deleted messages are in the msglist', () async {
      await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
      await prepareMessages(foundOldest: true, messages: messages);

      check(model).messages.length.equals(30);
      await store.handleEvent(eg.deleteMessageEvent(messages.sublist(0, 10)));
      checkNotifiedOnce();
      check(model).messages.length.equals(20);
    });

    test('some deleted messages are in the msglist, some not', () async {
      await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
      await prepareMessages(foundOldest: true, messages: messages.sublist(5));

      check(model).messages.length.equals(25);
      await store.handleEvent(eg.deleteMessageEvent(messages.sublist(0, 10)));
      checkNotifiedOnce();
      check(model).messages.length.equals(20);
    });

    test('none of the deleted messages are in the msglist', () async {
      await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
      await prepareMessages(foundOldest: true, messages: messages.sublist(5));

      check(model).messages.length.equals(25);
      await store.handleEvent(eg.deleteMessageEvent(messages.sublist(0, 5)));
      checkNotNotified();
      check(model).messages.length.equals(25);
    });

    test('deleted messages are exactly those in the msglist', () async {
      await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
      await prepareMessages(foundOldest: true, messages: messages.sublist(0, 25));

      check(model).messages.length.equals(25);
      await store.handleEvent(eg.deleteMessageEvent(messages));
      checkNotifiedOnce();
      check(model).messages.length.equals(0);
    });

    test('deleted messages are present non-consecutively in the msglist', () async {
      await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
      await prepareMessages(foundOldest: true, messages: messages);
      final messagesToDelete = messages.sublist(2, 5) + messages.sublist(10, 15);

      check(model).messages.length.equals(30);
      await store.handleEvent(eg.deleteMessageEvent(messagesToDelete));
      checkNotifiedOnce();
      checkHasMessages([
        ...messages.sublist(0, 2),
        ...messages.sublist(5, 10),
        ...messages.sublist(15),
      ]);
    });
  });

  group('notifyListenersIfMessagePresent', () {
    test('message present', () async {
      await prepare(narrow: const CombinedFeedNarrow());
      await prepareMessages(foundOldest: false,
        messages: List.generate(100, (i) => eg.streamMessage(id: 100 + i)));
      model.notifyListenersIfMessagePresent(150);
      checkNotifiedOnce();
    });

    test('message absent', () async {
      await prepare(narrow: const CombinedFeedNarrow());
      await prepareMessages(foundOldest: false,
        messages: List.generate(100, (i) => eg.streamMessage(id: 100 + i))
          .where((m) => m.id != 150).toList());
      model.notifyListenersIfMessagePresent(150);
      checkNotNotified();
    });

    test('message absent (older than window)', () async {
      await prepare(narrow: const CombinedFeedNarrow());
      await prepareMessages(foundOldest: false,
        messages: List.generate(100, (i) => eg.streamMessage(id: 100 + i)));
      model.notifyListenersIfMessagePresent(50);
      checkNotNotified();
    });

    test('message absent (newer than window)', () async {
      await prepare(narrow: const CombinedFeedNarrow());
      await prepareMessages(foundOldest: false,
        messages: List.generate(100, (i) => eg.streamMessage(id: 100 + i)));
      model.notifyListenersIfMessagePresent(250);
      checkNotNotified();
    });
  });

  group('notifyListenersIfAnyMessagePresent', () {
    final messages = List.generate(100, (i) => eg.streamMessage(id: 100 + i));

    test('all messages present', () async {
      await prepare(narrow: const CombinedFeedNarrow());
      await prepareMessages(foundOldest: false, messages: messages);
      model.notifyListenersIfAnyMessagePresent([150, 151, 152]);
      checkNotifiedOnce();
    });

    test('some messages present', () async {
      await prepare(narrow: const CombinedFeedNarrow());
      await prepareMessages(foundOldest: false,
        messages: messages.where((m) => m.id != 151).toList());
      model.notifyListenersIfAnyMessagePresent([150, 151, 152]);
      checkNotifiedOnce();
    });

    test('no messages present', () async {
      await prepare(narrow: const CombinedFeedNarrow());
      await prepareMessages(foundOldest: false, messages:
        messages.where((m) => ![150, 151, 152].contains(m.id)).toList());
      model.notifyListenersIfAnyMessagePresent([150, 151, 152]);
      checkNotNotified();
    });
  });

  group('notifyListenersIfOutboxMessagePresent', () {
    final stream = eg.stream();

    test('message present', () => awaitFakeAsync((async) async {
      await prepare(narrow: const CombinedFeedNarrow(), stream: stream);
      await prepareMessages(foundOldest: true, messages: []);
      await prepareOutboxMessages(count: 5, stream: stream);

      async.elapse(kLocalEchoDebounceDuration);
      checkNotified(count: 5);

      model.notifyListenersIfOutboxMessagePresent(
        store.outboxMessages.keys.first);
      checkNotifiedOnce();
    }));

    test('message not present', () => awaitFakeAsync((async) async {
      await prepare(
        narrow: eg.topicNarrow(stream.streamId, 'some topic'), stream: stream);
      await prepareMessages(foundOldest: true, messages: []);
      await prepareOutboxMessages(count: 5,
        stream: stream, topic: 'other topic');

      async.elapse(kLocalEchoDebounceDuration);
      checkNotNotified();

      model.notifyListenersIfOutboxMessagePresent(
        store.outboxMessages.keys.first);
      checkNotNotified();
    }));
  });

  group('messageContentChanged', () {
    test('message present', () async {
      await prepare(narrow: const CombinedFeedNarrow());
      await prepareMessages(foundOldest: false,
        messages: List.generate(10, (i) => eg.streamMessage(id: 10 + i)));

      final message = model.messages[5];
      await store.handleEvent(eg.updateMessageEditEvent(message,
        renderedContent: '${message.content}<p>edited</p'));
      checkNotifiedOnce();
    });

    test('message absent', () async {
      final stream = eg.stream();
      final narrow = ChannelNarrow(stream.streamId);
      await prepare(narrow: narrow, stream: stream);

      final messagesInNarrow = List<Message>.generate(10,
        (i) => eg.streamMessage(id: 10 + i, stream: stream));
      check(messagesInNarrow.every(narrow.containsMessage)).isTrue();

      final messageNotInNarrow = eg.dmMessage(id: 100, from: eg.otherUser, to: [eg.selfUser]);
      check(narrow.containsMessage(messageNotInNarrow)).isFalse();

      await prepareMessages(foundOldest: false, messages: messagesInNarrow);
      await store.addMessage(messageNotInNarrow);

      await store.handleEvent(eg.updateMessageEditEvent(messageNotInNarrow,
        renderedContent: '${messageNotInNarrow.content}<p>edited</p'));
      checkNotNotified();
    });
  });

  group('messagesMoved', () {
    final stream = eg.stream();
    final otherStream = eg.stream();

    Future<void> prepareNarrow(Narrow narrow, List<Message>? messages) async {
      await prepare(narrow: narrow);
      for (final streamToAdd in [stream, otherStream]) {
        final subscription = eg.subscription(streamToAdd);
        await store.addStream(streamToAdd);
        await store.addSubscription(subscription);
      }
      if (messages != null) {
        await prepareMessages(foundOldest: false, messages: messages);
        // These tests aren't about cached messages; keep refetches
        // (which some delay past [kShowCachedMessagesDelay])
        // from showing the fetch just stored.
        if (messageFetchCacheKey(narrow) case final key?) {
          await store.deleteCachedMessageFetch(key);
        }
      }
      checkHasMessages(messages ?? []);
    }

    group('muting interactions on move', () {
      /// Test that a message move (topic 'orig' → 'new' on [stream])
      /// has the given [expected] effect on a [MessageListView] with
      /// the given [narrow].
      ///
      /// The concrete muting state — [channelMuted], [origTopicPolicy],
      /// [newTopicPolicy] — determines visibility differently depending
      /// on the narrow type (see [MessageListView._messageVisible]), so
      /// the same muting configuration can produce different effects in
      /// different narrows.
      void testCrossTopicMoveWithMuting({
        required Narrow narrow,
        required bool channelMuted,
        required UserTopicVisibilityPolicy origTopicPolicy,
        required UserTopicVisibilityPolicy newTopicPolicy,
        required _VisibilityEffect expected,
      }) {
        final channelDesc = channelMuted ? 'channel muted' : 'channel not muted';
        final desc = '${narrow.runtimeType}, $channelDesc, '
          '${origTopicPolicy.name} → ${newTopicPolicy.name}';
        test(desc, () => awaitFakeAsync((async) async {
          final flags = switch (narrow) {
            MentionsNarrow()        => <MessageFlag>[.mentioned],
            StarredMessagesNarrow() => <MessageFlag>[.starred],
            _                       => <MessageFlag>[],
          };
          final notMovedMessages = List.generate(5, (i) =>
            eg.streamMessage(stream: stream, topic: 'notMoved', flags: flags));
          final movedMessages = List.generate(5, (i) =>
            eg.streamMessage(stream: stream, topic: 'orig', flags: flags));

          await prepare(narrow: narrow,
            starredMessages: narrow is StarredMessagesNarrow
              ? (notMovedMessages + movedMessages).map((m) => m.id).toList()
              : null);
          await store.addStream(stream);
          await store.addSubscription(
            eg.subscription(stream, isMuted: channelMuted));
          if (channelMuted) {
            // Keep notMovedMessages visible despite channel muting.
            await store.setUserTopic(stream, 'notMoved',
              UserTopicVisibilityPolicy.unmuted);
          }
          if (origTopicPolicy != .none) {
            await store.setUserTopic(stream, 'orig', origTopicPolicy);
          }
          if (newTopicPolicy != .none) {
            await store.setUserTopic(stream, 'new', newTopicPolicy);
          }

          // The fetch includes all messages; _messageVisible filters by muting.
          await prepareMessages(foundOldest: false,
            messages: notMovedMessages + movedMessages);
          // Keep the refetch from showing the fetch just stored.
          await store.deleteCachedMessageFetch(messageFetchCacheKey(narrow)!);

          final postMoveMessages = <StreamMessage>[];
          if (expected == .refetched) {
            // The refetch returns messages at their post-move location.
            postMoveMessages.addAll(movedMessages.map((m) => eg.streamMessage(
              id: m.id, stream: stream, topic: 'new', flags: flags)));
            connection.prepare(
              delay: const Duration(seconds: 2),
              json: newestResult(foundOldest: false,
                messages: notMovedMessages + postMoveMessages).toJson());
          }

          await store.handleEvent(eg.updateMessageEventMoveFrom(
            origMessages: movedMessages, newTopicStr: 'new'));

          switch (expected) {
            case .unaffected:
              checkHasMessages(notMovedMessages);
              checkNotNotified();
            case .reprocessed:
              checkHasMessages(notMovedMessages + movedMessages);
              checkNotified(count: 2);
            case .removed:
              checkHasMessages(notMovedMessages);
              checkNotifiedOnce();
            case .refetched:
              check(model).fetched.isFalse();
              checkHasMessages([]);
              checkNotifiedOnce();
              async.elapse(const Duration(seconds: 2));
              checkHasMessages(notMovedMessages + postMoveMessages);
              checkNotifiedOnce();
          }
        }));
      }

      final combinedFeed = const CombinedFeedNarrow();
      final channel = ChannelNarrow(stream.streamId);
      final mentions = const MentionsNarrow();
      final starred = const StarredMessagesNarrow();

      // Channel not muted: CombinedFeedNarrow and ChannelNarrow agree;
      // MentionsNarrow and StarredMessagesNarrow always do "reprocessing"
      // because they don't exclude channel messages by muting.
      for (final narrow in [combinedFeed, channel]) {
        testCrossTopicMoveWithMuting(narrow: narrow, channelMuted: false,
          origTopicPolicy: .none,  newTopicPolicy: .none,  expected: .reprocessed);
        testCrossTopicMoveWithMuting(narrow: narrow, channelMuted: false,
          origTopicPolicy: .none,  newTopicPolicy: .muted, expected: .removed);
        testCrossTopicMoveWithMuting(narrow: narrow, channelMuted: false,
          origTopicPolicy: .muted, newTopicPolicy: .none,  expected: .refetched);
        testCrossTopicMoveWithMuting(narrow: narrow, channelMuted: false,
          origTopicPolicy: .muted, newTopicPolicy: .muted, expected: .unaffected);
      }
      for (final narrow in [mentions, starred]) {
        testCrossTopicMoveWithMuting(narrow: narrow, channelMuted: false,
          origTopicPolicy: .none,  newTopicPolicy: .muted, expected: .reprocessed);
        testCrossTopicMoveWithMuting(narrow: narrow, channelMuted: false,
          origTopicPolicy: .muted, newTopicPolicy: .none,  expected: .reprocessed);
      }

      // Channel muted: CombinedFeedNarrow and ChannelNarrow diverge.
      // With policy `none`, topics are invisible in CombinedFeedNarrow
      // (because the channel is muted) but visible in ChannelNarrow
      // (which doesn't consider channel muting).
      testCrossTopicMoveWithMuting(narrow: combinedFeed, channelMuted: true,
        origTopicPolicy: .none,  newTopicPolicy: .muted, expected: .unaffected);
      testCrossTopicMoveWithMuting(narrow: combinedFeed, channelMuted: true,
        origTopicPolicy: .muted, newTopicPolicy: .none,  expected: .unaffected);

      testCrossTopicMoveWithMuting(narrow: channel, channelMuted: true,
        origTopicPolicy: .none,  newTopicPolicy: .muted, expected: .removed);
      testCrossTopicMoveWithMuting(narrow: channel, channelMuted: true,
        origTopicPolicy: .muted, newTopicPolicy: .none,  expected: .refetched);
    });

    group('in combined feed narrow', () {
      const narrow = CombinedFeedNarrow();
      final initialMessages = List.generate(5, (i) => eg.streamMessage(stream: stream));
      final movedMessages = List.generate(5, (i) => eg.streamMessage(stream: stream));
      final otherChannelMessages = List.generate(5, (i) => eg.streamMessage(stream: otherStream));

      test('internal move between channels', () async {
        await prepareNarrow(narrow, initialMessages);

        await store.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: initialMessages,
          newTopic: initialMessages[0].topic,
          newStreamId: otherStream.streamId,
        ));
        checkHasMessages(initialMessages);
        checkNotified(count: 2);
      });

      test('channel -> muted channel: remove moved messages', () async {
        await prepareNarrow(narrow, initialMessages + movedMessages);
        await store.updateSubscription(
          otherStream.streamId, SubscriptionProperty.isMuted, true);

        await store.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: movedMessages,
          newStreamId: otherStream.streamId));
        checkHasMessages(initialMessages);
        checkNotifiedOnce();
      });

      test('muted channel -> channel: refetch', () => awaitFakeAsync((async) async {
        await prepareNarrow(narrow, initialMessages);
        await store.updateSubscription(
          otherStream.streamId, SubscriptionProperty.isMuted, true);
        await store.addMessages(otherChannelMessages);

        connection.prepare(delay: const Duration(seconds: 2), json: newestResult(
          foundOldest: false,
          messages: initialMessages + otherChannelMessages,
        ).toJson());
        await store.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: otherChannelMessages,
          newStreamId: stream.streamId));
        check(model).fetched.isFalse();
        checkHasMessages([]);
        checkNotifiedOnce();

        async.elapse(const Duration(seconds: 2));
        checkHasMessages(initialMessages + otherChannelMessages);
        checkNotifiedOnce();
      }));
    });

    group('in channel narrow', () {
      final narrow = ChannelNarrow(stream.streamId);
      final initialMessages = List.generate(5, (i) => eg.streamMessage(stream: stream));
      final movedMessages = List.generate(5, (i) => eg.streamMessage(stream: stream));
      final otherChannelMovedMessages = List.generate(5, (i) => eg.streamMessage(stream: otherStream, topic: 'topic'));

      group('old channel -> channel:', () {
        test('new topic not muted - refetch', () => awaitFakeAsync((async) async {
          await prepareNarrow(narrow, initialMessages);

          connection.prepare(delay: const Duration(seconds: 2), json: newestResult(
            foundOldest: false,
            messages: initialMessages + movedMessages,
          ).toJson());
          await store.handleEvent(eg.updateMessageEventMoveTo(
            origTopicStr: 'orig topic',
            origStreamId: otherStream.streamId,
            newMessages: movedMessages));
          check(model).fetched.isFalse();
          checkHasMessages([]);
          checkNotifiedOnce();

          async.elapse(const Duration(seconds: 2));
          checkHasMessages(initialMessages + movedMessages);
          checkNotifiedOnce();
        }));

        test('new topic muted - unaffected', () async {
          await prepareNarrow(narrow, initialMessages);
          await store.setUserTopic(stream, 'new', UserTopicVisibilityPolicy.muted);

          final newTopicMovedMessages = List.generate(5, (i) =>
            eg.streamMessage(stream: stream, topic: 'new'));
          await store.handleEvent(eg.updateMessageEventMoveTo(
            origTopicStr: 'orig topic',
            origStreamId: otherStream.streamId,
            newMessages: newTopicMovedMessages));
          checkHasMessages(initialMessages);
          checkNotNotified();
        });
      });

      test('channel -> new channel: remove moved messages', () async {
        await prepareNarrow(narrow, initialMessages + movedMessages);

        await store.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: movedMessages,
          newTopicStr: 'new',
          newStreamId: otherStream.streamId,
        ));
        checkHasMessages(initialMessages);
        checkNotifiedOnce();
      });

      test('channel -> new channel (with outbox messages): remove moved messages; outbox messages unaffected', () => awaitFakeAsync((async) async {
        final narrow = ChannelNarrow(stream.streamId);
        await prepareNarrow(narrow, initialMessages + movedMessages);
        connection.prepare(json: SendMessageResult(id: 1).toJson());
        await prepareOutboxMessages(count: 5, stream: stream);

        async.elapse(kLocalEchoDebounceDuration);
        checkNotified(count: 5);
        final outboxMessagesCopy = model.outboxMessages.toList();

        await store.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: movedMessages,
          newTopicStr: 'new',
          newStreamId: otherStream.streamId,
        ));
        checkHasMessages(initialMessages);
        check(model).outboxMessages.deepEquals(outboxMessagesCopy);
        checkNotifiedOnce();
      }));

      test('unrelated channel -> new channel: unaffected', () async {
        final thirdStream = eg.stream();
        await prepareNarrow(narrow, initialMessages);
        await store.addStream(thirdStream);
        await store.addSubscription(eg.subscription(thirdStream));

        await store.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: otherChannelMovedMessages,
          newStreamId: thirdStream.streamId,
        ));
        checkHasMessages(initialMessages);
        checkNotNotified();
      });

      test('unrelated channel -> unrelated channel: unaffected', () async {
        await prepareNarrow(narrow, initialMessages);

        await store.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: otherChannelMovedMessages,
          newTopicStr: 'new',
        ));
        checkHasMessages(initialMessages);
        checkNotNotified();
      });

      void testMessageMove(PropagateMode propagateMode) => awaitFakeAsync((async) async {
        await prepareNarrow(narrow, initialMessages + movedMessages);
        connection.prepare(delay: const Duration(seconds: 1), json: newestResult(
          foundOldest: false,
          messages: movedMessages,
        ).toJson());
        await store.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: movedMessages,
          newTopicStr: 'new',
          newStreamId: otherStream.streamId,
          propagateMode: propagateMode,
        ));
        checkNotifiedOnce();
        async.elapse(const Duration(seconds: 1));
        checkHasMessages(initialMessages);
        check(model).narrow.equals(ChannelNarrow(stream.streamId));
        checkNotNotified();
      });

      test('do not follow when propagateMode = changeOne', () {
        testMessageMove(PropagateMode.changeOne);
      });

      test('do not follow when propagateMode = changeLater', () {
        testMessageMove(PropagateMode.changeLater);
      });

      test('do not follow when propagateMode = changeAll', () {
        testMessageMove(PropagateMode.changeAll);
      });
    });

    group('in topic narrow', () {
      final narrow = eg.topicNarrow(stream.streamId, 'topic');
      final initialMessages = List.generate(5, (i) => eg.streamMessage(stream: stream, topic: 'topic'));
      final movedMessages = List.generate(5, (i) => eg.streamMessage(stream: stream, topic: 'topic'));
      final differentlyCasedMovedMessages = List.generate(5, (i) => eg.streamMessage(stream: stream, topic: 'ToPiC'));
      final otherTopicMovedMessages = List.generate(5, (i) => eg.streamMessage(stream: stream, topic: 'other topic'));
      final otherChannelMovedMessages = List.generate(5, (i) => eg.streamMessage(stream: otherStream, topic: 'topic'));

      group('moved into narrow: should refetch messages', () {
        final testCases = [
          ('(old channel, topic) -> (channel, topic)',
           origStreamId: 200,  origTopic:  null,   movedMessages: movedMessages),
          ('(channel, old topic) -> (channel, topic)',
           origStreamId: null, origTopic: 'other', movedMessages: movedMessages),
          ('(old channel, old topic) -> (channel, topic)',
           origStreamId: 200,  origTopic: 'other', movedMessages: movedMessages),
          ('(channel, old topic) -> (channel, ToPiC)',
           origStreamId: null, origTopic: 'other', movedMessages: differentlyCasedMovedMessages),
        ];

        for (final (description, :origStreamId, :origTopic, :movedMessages) in testCases) {
          test(description, () => awaitFakeAsync((async) async {
            await prepareNarrow(narrow, initialMessages);

            connection.prepare(delay: const Duration(seconds: 2), json: newestResult(
              foundOldest: false,
              messages: initialMessages + movedMessages,
            ).toJson());
            await store.handleEvent(eg.updateMessageEventMoveTo(
              origStreamId: origStreamId,
              origTopicStr: origTopic,
              newMessages: movedMessages,
            ));
            check(model).fetched.isFalse();
            checkHasMessages([]);
            checkNotifiedOnce();

            async.elapse(const Duration(seconds: 2));
            checkHasMessages(initialMessages + movedMessages);
            checkNotifiedOnce();
          }));
        }
      });

      group('moved from narrow: should remove moved messages', () {
        final testCases = [
          ('(channel, topic) -> (new channel, topic)',
           newStreamId: 200,  newTopic: null,  movedMessages: movedMessages),
          ('(channel, topic) -> (channel, new topic)',
           newStreamId: null, newTopic: 'new', movedMessages: movedMessages),
          ('(channel, topic) -> (new channel, new topic)',
           newStreamId: 200,  newTopic: 'new', movedMessages: movedMessages),
          ('(channel, ToPiC) -> (channel, new topic)',
           newStreamId: null, newTopic: 'new', movedMessages: differentlyCasedMovedMessages),
        ];

        for (final (description, :newStreamId, :newTopic, :movedMessages) in testCases) {
          test(description, () async {
            await prepareNarrow(narrow, initialMessages + movedMessages);

            await store.handleEvent(eg.updateMessageEventMoveFrom(
              origMessages: movedMessages,
              newStreamId: newStreamId,
              newTopicStr: newTopic,
            ));
            checkHasMessages(initialMessages);
            checkNotifiedOnce();
          });
        }
      });

      group('moved inside narrow: unaffected', () {
        test('(channel, topic) -> (channel, ToPiC)', () async {
          await prepareNarrow(narrow, initialMessages + movedMessages);

          await store.handleEvent(eg.updateMessageEventMoveFrom(
            origMessages: movedMessages,
            newTopicStr: 'ToPiC',
          ));
          checkHasMessages(initialMessages + movedMessages);
          checkNotifiedOnce();
        });

        test('(channel, ToPiC) -> (channel, topic)', () async {
          await prepareNarrow(narrow, initialMessages + differentlyCasedMovedMessages);

          await store.handleEvent(eg.updateMessageEventMoveFrom(
            origMessages: differentlyCasedMovedMessages,
            newTopicStr: 'topic',
          ));
          checkHasMessages(initialMessages + differentlyCasedMovedMessages);
          checkNotifiedOnce();
        });
      });

      group('irrelevant moves', () {
        test('(channel, old topic) -> (channel, unrelated topic)', () async {
          await prepareNarrow(narrow, initialMessages);

          await store.handleEvent(eg.updateMessageEventMoveTo(
            origTopicStr: 'other',
            newMessages: otherTopicMovedMessages,
          ));
          check(model).fetched.isTrue();
          checkHasMessages(initialMessages);
          checkNotNotified();
        });

        test('(old channel, topic) - > (unrelated channel, topic)', () async {
          await prepareNarrow(narrow, initialMessages);

          await store.handleEvent(eg.updateMessageEventMoveTo(
            origStreamId: 200,
            newMessages: otherChannelMovedMessages,
          ));
          check(model).fetched.isTrue();
          checkHasMessages(initialMessages);
          checkNotNotified();
        });
      });

      void handleMoveEvent(PropagateMode propagateMode) => awaitFakeAsync((async) async {
        await prepareNarrow(narrow, initialMessages + movedMessages);
        connection.prepare(delay: const Duration(seconds: 1), json: newestResult(
          foundOldest: false,
          messages: movedMessages,
        ).toJson());
        await store.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: movedMessages,
          newTopicStr: 'new',
          newStreamId: otherStream.streamId,
          propagateMode: propagateMode,
        ));
        switch (propagateMode) {
          case PropagateMode.changeOne:
            checkNotifiedOnce();
          case PropagateMode.changeLater:
          case PropagateMode.changeAll:
            checkNotified(count: 2);
        }
        async.elapse(const Duration(seconds: 1));
      });

      test('do not follow to the new narrow when propagateMode = changeOne', () {
        handleMoveEvent(PropagateMode.changeOne);
        checkNotNotified();
        checkHasMessages(initialMessages);
        check(model).narrow.equals(eg.topicNarrow(stream.streamId, 'topic'));
      });

      test('follow to the new narrow when propagateMode = changeLater', () {
        handleMoveEvent(PropagateMode.changeLater);
        checkNotifiedOnce();
        checkHasMessages(movedMessages);
        check(model).narrow.equals(eg.topicNarrow(otherStream.streamId, 'new'));
      });

      test('follow to the new narrow when propagateMode = changeAll', () {
        handleMoveEvent(PropagateMode.changeAll);
        checkNotifiedOnce();
        checkHasMessages(movedMessages);
        check(model).narrow.equals(eg.topicNarrow(otherStream.streamId, 'new'));
      });

      test('handle move event before initial fetch', () => awaitFakeAsync((async) async {
        await prepare(narrow: narrow);
        final subscription = eg.subscription(stream);
        await store.addStream(stream);
        await store.addSubscription(subscription);
        final followedMessage = eg.streamMessage(stream: stream, topic: 'new');

        connection.prepare(delay: const Duration(seconds: 2), json: newestResult(
          foundOldest: true,
          messages: [followedMessage],
        ).toJson());

        check(model).fetched.isFalse();
        checkHasMessages([]);
        await store.handleEvent(eg.updateMessageEventMoveTo(
          origTopicStr: 'topic',
          newMessages: [followedMessage],
          propagateMode: PropagateMode.changeAll,
        ));
        check(model).narrow.equals(eg.topicNarrow(stream.streamId, 'new'));

        async.elapse(const Duration(seconds: 2));
        checkHasMessages([followedMessage]);
      }));
    });

    group('fetch races', () {
      final narrow = ChannelNarrow(stream.streamId);
      final olderMessages = List.generate(5, (i) => eg.streamMessage(stream: stream));
      final initialMessages = List.generate(5, (i) => eg.streamMessage(stream: stream));
      final movedMessages = List.generate(5, (i) => eg.streamMessage(stream: stream));

      test('fetchOlder, _reset, fetchOlder returns, move fetch finishes', () => awaitFakeAsync((async) async {
        await prepareNarrow(narrow, initialMessages);

        connection.prepare(delay: const Duration(seconds: 1), json: olderResult(
          anchor: model.messages[0].id,
          foundOldest: true,
          messages: olderMessages,
        ).toJson());
        final fetchFuture = model.fetchOlder();
        check(model).busyFetchingMore.isTrue();
        checkHasMessages(initialMessages);
        checkNotifiedOnce();

        connection.prepare(delay: const Duration(seconds: 2), json: newestResult(
          foundOldest: false,
          messages: initialMessages + movedMessages,
        ).toJson());
        await store.handleEvent(eg.updateMessageEventMoveTo(
          origTopic: movedMessages[0].topic,
          origStreamId: otherStream.streamId,
          newMessages: movedMessages,
        ));
        check(model).busyFetchingMore.isFalse();
        checkHasMessages([]);
        checkNotifiedOnce();

        await fetchFuture;
        checkHasMessages([]);
        checkNotNotified();

        async.elapse(const Duration(seconds: 1));
        checkHasMessages(initialMessages + movedMessages);
        checkNotifiedOnce();
      }));

      test('fetchOlder, _reset, move fetch finishes, fetchOlder returns', () => awaitFakeAsync((async) async {
        await prepareNarrow(narrow, initialMessages);

        connection.prepare(delay: const Duration(seconds: 2), json: olderResult(
          anchor: model.messages[0].id,
          foundOldest: true,
          messages: olderMessages,
        ).toJson());
        final fetchFuture = model.fetchOlder();
        checkHasMessages(initialMessages);
        check(model).busyFetchingMore.isTrue();
        checkNotifiedOnce();

        connection.prepare(delay: const Duration(seconds: 1), json: newestResult(
          foundOldest: false,
          messages: initialMessages + movedMessages,
        ).toJson());
        await store.handleEvent(eg.updateMessageEventMoveTo(
          origTopic: movedMessages[0].topic,
          origStreamId: otherStream.streamId,
          newMessages: movedMessages,
        ));
        checkHasMessages([]);
        check(model).busyFetchingMore.isFalse();
        checkNotifiedOnce();

        async.elapse(const Duration(seconds: 1));
        checkHasMessages(initialMessages + movedMessages);
        checkNotifiedOnce();

        await fetchFuture;
        checkHasMessages(initialMessages + movedMessages);
        checkNotNotified();
      }));

      test('fetchOlder backoff A starts, _reset, move fetch finishes,'
          ' fetchOlder backoff B starts, fetchOlder backoff A ends', () => awaitFakeAsync((async) async {
        addTearDown(() => BackoffMachine.debugDuration = null);
        await prepareNarrow(narrow, initialMessages);

        connection.prepare(apiException: eg.apiBadRequest());
        BackoffMachine.debugDuration = const Duration(seconds: 1);
        await check(model.fetchOlder()).throws<ZulipApiException>();
        final backoffTimerA = async.pendingTimers.single;
        check(model).busyFetchingMore.isTrue();
        check(model).fetched.isTrue();
        checkHasMessages(initialMessages);
        checkNotified(count: 2);

        connection.prepare(json: newestResult(
          foundOldest: false,
          messages: initialMessages + movedMessages,
        ).toJson());
        await store.handleEvent(eg.updateMessageEventMoveTo(
          origTopic: movedMessages[0].topic,
          origStreamId: otherStream.streamId,
          newMessages: movedMessages,
        ));
        // Check that _reset was called.
        check(model).fetched.isFalse();
        checkHasMessages([]);
        checkNotifiedOnce();
        check(model).busyFetchingMore.isFalse();
        check(backoffTimerA.isActive).isTrue();

        async.elapse(Duration.zero);
        check(model).fetched.isTrue();
        checkHasMessages(initialMessages + movedMessages);
        checkNotifiedOnce();
        check(model).busyFetchingMore.isFalse();
        check(backoffTimerA.isActive).isTrue();

        connection.prepare(apiException: eg.apiBadRequest());
        BackoffMachine.debugDuration = const Duration(seconds: 2);
        await check(model.fetchOlder()).throws<ZulipApiException>();
        final backoffTimerB = async.pendingTimers.last;
        check(model).busyFetchingMore.isTrue();
        check(backoffTimerA.isActive).isTrue();
        check(backoffTimerB.isActive).isTrue();
        checkNotified(count: 2);

        // When `backoffTimerA` ends, `busyFetchingMore` remains `true`
        // because the backoff was from a previous generation.
        async.elapse(const Duration(seconds: 1));
        check(model).busyFetchingMore.isTrue();
        check(backoffTimerA.isActive).isFalse();
        check(backoffTimerB.isActive).isTrue();
        checkNotNotified();

        // When `backoffTimerB` ends, `busyFetchingMore` gets reset.
        async.elapse(const Duration(seconds: 1));
        check(model).busyFetchingMore.isFalse();
        check(backoffTimerA.isActive).isFalse();
        check(backoffTimerB.isActive).isFalse();
        checkNotifiedOnce();
      }));

      test('fetchInitial, _reset, initial fetch aborted, move fetch finishes', () => awaitFakeAsync((async) async {
        await prepareNarrow(narrow, null);

        connection.prepare(delay: const Duration(seconds: 1), json: newestResult(
          foundOldest: false,
          messages: initialMessages,
        ).toJson());
        final fetchFuture = model.fetchInitial();
        checkHasMessages([]);
        check(model).fetched.isFalse();

        connection.prepare(delay: const Duration(seconds: 2), json: newestResult(
          foundOldest: false,
          messages: initialMessages + movedMessages,
        ).toJson());
        await store.handleEvent(eg.updateMessageEventMoveTo(
          origTopic: movedMessages[0].topic,
          origStreamId: otherStream.streamId,
          newMessages: movedMessages,
        ));
        checkHasMessages([]);
        check(model).fetched.isFalse();
        checkNotifiedOnce();

        // The _reset aborted the initial fetch's request.
        await fetchFuture;
        check(async.elapsed).equals(Duration.zero);
        checkHasMessages([]);
        check(model).fetched.isFalse();
        checkNotNotified();

        async.elapse(const Duration(seconds: 1));
        checkHasMessages([]);
        check(model).fetched.isFalse();
        checkNotNotified();

        async.elapse(const Duration(seconds: 1));
        checkHasMessages(initialMessages + movedMessages);
        checkNotifiedOnce();
      }));

      test('fetchInitial, _reset, move fetch finishes, initial fetch finishes', () => awaitFakeAsync((async) async {
        await prepareNarrow(narrow, null);

        connection.prepare(delay: const Duration(seconds: 2), json: newestResult(
          foundOldest: false,
          messages: initialMessages,
        ).toJson());
        final fetchFuture = model.fetchInitial();
        checkHasMessages([]);
        check(model).fetched.isFalse();

        connection.prepare(delay: const Duration(seconds: 1), json: newestResult(
          foundOldest: false,
          messages: initialMessages + movedMessages,
        ).toJson());
        await store.handleEvent(eg.updateMessageEventMoveTo(
          origTopic: movedMessages[0].topic,
          origStreamId: otherStream.streamId,
          newMessages: movedMessages,
        ));
        checkHasMessages([]);
        check(model).fetched.isFalse();

        async.elapse(const Duration(seconds: 1));
        checkHasMessages(initialMessages + movedMessages);
        check(model).fetched.isTrue();

        await fetchFuture;
        checkHasMessages(initialMessages + movedMessages);
      }));

      test('fetchOlder #1, _reset, move fetch finishes, fetchOlder #2, '
        'fetchOlder #1 finishes, fetchOlder #2 finishes', () => awaitFakeAsync((async) async {
        await prepareNarrow(narrow, initialMessages);

        connection.prepare(delay: const Duration(seconds: 2), json: olderResult(
          anchor: model.messages[0].id,
          foundOldest: true,
          messages: olderMessages,
        ).toJson());
        final fetchFuture1 = model.fetchOlder();
        checkHasMessages(initialMessages);
        check(model).busyFetchingMore.isTrue();
        checkNotifiedOnce();

        connection.prepare(delay: const Duration(seconds: 1), json: newestResult(
          foundOldest: false,
          messages: initialMessages + movedMessages,
        ).toJson());
        await store.handleEvent(eg.updateMessageEventMoveTo(
          origTopic: movedMessages[0].topic,
          origStreamId: otherStream.streamId,
          newMessages: movedMessages,
        ));
        checkHasMessages([]);
        check(model).busyFetchingMore.isFalse();
        checkNotifiedOnce();

        async.elapse(const Duration(seconds: 1));
        checkNotifiedOnce();

        connection.prepare(delay: const Duration(seconds: 2), json: olderResult(
          anchor: model.messages[0].id,
          foundOldest: true,
          messages: olderMessages
        ).toJson());
        final fetchFuture2 = model.fetchOlder();
        checkHasMessages(initialMessages + movedMessages);
        check(model).busyFetchingMore.isTrue();
        checkNotifiedOnce();

        await fetchFuture1;
        checkHasMessages(initialMessages + movedMessages);
        // The older fetchOlder call should not override fetchingOlder set by
        // the new fetchOlder call, nor should it notify the listeners.
        check(model).busyFetchingMore.isTrue();
        checkNotNotified();

        await fetchFuture2;
        checkHasMessages(olderMessages + initialMessages + movedMessages);
        check(model).busyFetchingMore.isFalse();
        checkNotifiedOnce();
      }));
    });
  });

  group('regression tests for #455', () {
    test('reaction events handled once, even when message is in two message lists', () async {
      final stream = eg.stream();
      store = eg.store();
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));
      connection = store.connection as FakeApiConnection;

      int notifiedCount1 = 0;
      final model1 = MessageListView.init(store: store,
          narrow: ChannelNarrow(stream.streamId),
          anchor: AnchorCode.newest)
        ..addListener(() => notifiedCount1++);

      int notifiedCount2 = 0;
      final model2 = MessageListView.init(store: store,
          narrow: eg.topicNarrow(stream.streamId, 'hello'),
          anchor: AnchorCode.newest)
        ..addListener(() => notifiedCount2++);

      final initialMessage = eg.streamMessage(stream: stream, topic: 'hello');
      for (final m in [model1, model2]) {
        connection.prepare(json: newestResult(
          foundOldest: false,
          messages: [initialMessage]).toJson());
        await m.fetchInitial();
      }

      final message = eg.streamMessage(stream: stream, topic: 'hello');
      await store.addMessage(message);

      await store.handleEvent(
        eg.reactionEvent(eg.unicodeEmojiReaction, ReactionOp.add, message.id));

      check(notifiedCount1).equals(3); // fetch, new-message event, reaction event
      check(notifiedCount2).equals(3); // fetch, new-message event, reaction event

      check(model1.messages.last)
        ..identicalTo(model2.messages.last)
        ..reactions.isNotNull().total.equals(1);
    });

    Future<void> checkApplied({
      required Event Function(Message) mkEvent,
      required void Function(Subject<Message>) doCheckMessageAfterFetch,
    }) async {
      final stream = eg.stream();
      store = eg.store();
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));
      connection = store.connection as FakeApiConnection;

      final message = eg.streamMessage(stream: stream);

      await store.addMessage(Message.fromJson(message.toJson()));
      await store.handleEvent(mkEvent(message));

      // init msglist *after* event was handled
      model = MessageListView.init(store: store,
        narrow: const CombinedFeedNarrow(), anchor: AnchorCode.newest);
      checkInvariants(model);

      connection.prepare(json:
        newestResult(foundOldest: false, messages: [message]).toJson());
      await model.fetchInitial();
      checkInvariants(model);
      doCheckMessageAfterFetch(
        check(model).messages.single
          ..id.equals(message.id)
      );
    }

    test('ReactionEvent is applied even when message not in any msglists', () async {
      await checkApplied(
        mkEvent: (message) =>
          eg.reactionEvent(eg.unicodeEmojiReaction, ReactionOp.add, message.id),
        doCheckMessageAfterFetch:
          (messageSubject) => messageSubject.reactions.isNotNull().total.equals(1),
      );
    });

    test('UpdateMessageEvent (edit) is applied even when message not in any msglists', () async {
      await checkApplied(
        mkEvent: (message) {
          final newContent = '${message.content}<p>edited</p>';
          return eg.updateMessageEditEvent(message,
            renderedContent: newContent);
        },
        doCheckMessageAfterFetch:
          (messageSubject) => messageSubject.content.endsWith('<p>edited</p>'),
      );
    });

    test('UpdateMessageFlagsEvent is applied even when message not in any msglists', () async {
      await checkApplied(
        mkEvent: (message) => UpdateMessageFlagsAddEvent(
          id: 1,
          flag: MessageFlag.hasAlertWord,
          messages: [message.id],
          all: false,
        ),
        doCheckMessageAfterFetch:
          (messageSubject) => messageSubject.flags.contains(MessageFlag.hasAlertWord),
      );
    });
  });

  test('reassemble', () async {
    final stream = eg.stream();
    await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
    await prepareMessages(foundOldest: true, messages:
      List.generate(30, (i) => eg.streamMessage(stream: stream)));
    await store.addMessage(eg.streamMessage(stream: stream));
    checkNotifiedOnce();
    check(model).messages.length.equals(31);

    // Mess with model.contents, to simulate it having come from
    // a previous version of the code.
    final correctContent = parseContent(model.messages[0].content);
    model.contents[0] = const ZulipContent(nodes: [
      ParagraphNode(links: null, nodes: [TextNode('something outdated')])
    ]);
    check(model.contents[0]).isA<ZulipContent>()
      .not((it) => it.equalsNode(correctContent));

    model.reassemble();
    checkNotifiedOnce();
    check(model).messages.length.equals(31);
    check(model.contents[0]).isA<ZulipContent>().equalsNode(correctContent);
  });

  group('stream/topic muting', () {
    test('in CombinedFeedNarrow', () async {
      final stream1 = eg.stream();
      final stream2 = eg.stream();
      await prepare(narrow: const CombinedFeedNarrow());
      await store.addStreams([stream1, stream2]);
      await store.addSubscription(eg.subscription(stream1));
      await store.setUserTopic(stream1, 'B', UserTopicVisibilityPolicy.muted);
      await store.addSubscription(eg.subscription(stream2, isMuted: true));
      await store.setUserTopic(stream2, 'C', UserTopicVisibilityPolicy.unmuted);

      // Check filtering on fetchInitial…
      await prepareMessages(foundOldest: false, messages: [
        eg.streamMessage(id: 201, stream: stream1, topic: 'A'),
        eg.streamMessage(id: 202, stream: stream1, topic: 'B'),
        eg.streamMessage(id: 203, stream: stream2, topic: 'C'),
        eg.streamMessage(id: 204, stream: stream2, topic: 'D'),
        eg.dmMessage(    id: 205, from: eg.otherUser, to: [eg.selfUser]),
      ]);
      final expected = <int>[];
      checkHasMessageIds(expected..addAll([201, 203, 205]));

      // … and on fetchOlder…
      connection.prepare(json: olderResult(
        anchor: 201, foundOldest: true, messages: [
          eg.streamMessage(id: 101, stream: stream1, topic: 'A'),
          eg.streamMessage(id: 102, stream: stream1, topic: 'B'),
          eg.streamMessage(id: 103, stream: stream2, topic: 'C'),
          eg.streamMessage(id: 104, stream: stream2, topic: 'D'),
          eg.dmMessage(    id: 105, from: eg.otherUser, to: [eg.selfUser]),
        ]).toJson());
      await model.fetchOlder();
      checkNotified(count: 2);
      checkHasMessageIds(expected..insertAll(0, [101, 103, 105]));

      // … and on MessageEvent.
      await store.addMessage(
        eg.streamMessage(id: 301, stream: stream1, topic: 'A'));
      checkNotifiedOnce();
      checkHasMessageIds(expected..add(301));

      await store.addMessage(
        eg.streamMessage(id: 302, stream: stream1, topic: 'B'));
      checkNotNotified();
      checkHasMessageIds(expected);

      await store.addMessage(
        eg.streamMessage(id: 303, stream: stream2, topic: 'C'));
      checkNotifiedOnce();
      checkHasMessageIds(expected..add(303));

      await store.addMessage(
        eg.streamMessage(id: 304, stream: stream2, topic: 'D'));
      checkNotNotified();
      checkHasMessageIds(expected);

      await store.addMessage(
        eg.dmMessage(id: 305, from: eg.otherUser, to: [eg.selfUser]));
      checkNotifiedOnce();
      checkHasMessageIds(expected..add(305));
    });

    test('in ChannelNarrow', () async {
      final stream = eg.stream();
      await prepare(narrow: ChannelNarrow(stream.streamId));
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream, isMuted: true));
      await store.setUserTopic(stream, 'A', UserTopicVisibilityPolicy.unmuted);
      await store.setUserTopic(stream, 'C', UserTopicVisibilityPolicy.muted);

      // Check filtering on fetchInitial…
      await prepareMessages(foundOldest: false, messages: [
        eg.streamMessage(id: 201, stream: stream, topic: 'A'),
        eg.streamMessage(id: 202, stream: stream, topic: 'B'),
        eg.streamMessage(id: 203, stream: stream, topic: 'C'),
      ]);
      final expected = <int>[];
      checkHasMessageIds(expected..addAll([201, 202]));

      // … and on fetchOlder…
      connection.prepare(json: olderResult(
        anchor: 201, foundOldest: true, messages: [
          eg.streamMessage(id: 101, stream: stream, topic: 'A'),
          eg.streamMessage(id: 102, stream: stream, topic: 'B'),
          eg.streamMessage(id: 103, stream: stream, topic: 'C'),
        ]).toJson());
      await model.fetchOlder();
      checkNotified(count: 2);
      checkHasMessageIds(expected..insertAll(0, [101, 102]));

      // … and on MessageEvent.
      await store.addMessage(
        eg.streamMessage(id: 301, stream: stream, topic: 'A'));
      checkNotifiedOnce();
      checkHasMessageIds(expected..add(301));

      await store.addMessage(
        eg.streamMessage(id: 302, stream: stream, topic: 'B'));
      checkNotifiedOnce();
      checkHasMessageIds(expected..add(302));

      await store.addMessage(
        eg.streamMessage(id: 303, stream: stream, topic: 'C'));
      checkNotNotified();
      checkHasMessageIds(expected);
    });

    test('handle outbox messages', () => awaitFakeAsync((async) async {
      final stream = eg.stream();
      await prepare(narrow: ChannelNarrow(stream.streamId));
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));
      await store.setUserTopic(stream, 'muted', UserTopicVisibilityPolicy.muted);
      await prepareMessages(foundOldest: true, messages: []);

      // Check filtering on sent messages…
      await prepareOutboxMessagesTo([
        StreamDestination(stream.streamId, eg.t('not muted')),
        StreamDestination(stream.streamId, eg.t('muted')),
      ]);
      async.elapse(kLocalEchoDebounceDuration);
      checkNotifiedOnce();
      check(model.outboxMessages).single.isA<StreamOutboxMessage>()
        .conversation.topic.equals(eg.t('not muted'));

      final messages = [eg.streamMessage(stream: stream)];
      connection.prepare(json: newestResult(
        foundOldest: true, messages: messages).toJson());
      // Check filtering on fetchInitial…
      await store.handleEvent(eg.updateMessageEventMoveTo(
        newMessages: messages,
        origStreamId: eg.stream().streamId));
      checkNotifiedOnce();
      check(model).fetched.isFalse();
      async.elapse(Duration.zero);
      check(model).fetched.isTrue();
      check(model.outboxMessages).single.isA<StreamOutboxMessage>()
        .conversation.topic.equals(eg.t('not muted'));
    }));

    test('in TopicNarrow', () async {
      final stream = eg.stream();
      await prepare(narrow: eg.topicNarrow(stream.streamId, 'A'));
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream, isMuted: true));
      await store.setUserTopic(stream, 'A', UserTopicVisibilityPolicy.muted);

      // Check filtering on fetchInitial…
      await prepareMessages(foundOldest: false, messages: [
        eg.streamMessage(id: 201, stream: stream, topic: 'A'),
      ]);
      final expected = <int>[];
      checkHasMessageIds(expected..addAll([201]));

      // … and on fetchOlder…
      connection.prepare(json: olderResult(
        anchor: 201, foundOldest: true, messages: [
          eg.streamMessage(id: 101, stream: stream, topic: 'A'),
        ]).toJson());
      await model.fetchOlder();
      checkNotified(count: 2);
      checkHasMessageIds(expected..insertAll(0, [101]));

      // … and on MessageEvent.
      await store.addMessage(
        eg.streamMessage(id: 301, stream: stream, topic: 'A'));
      checkNotifiedOnce();
      checkHasMessageIds(expected..add(301));
    });

    test('in MentionsNarrow', () async {
      final stream = eg.stream();
      const mutedTopic = 'muted';
      await prepare(narrow: const MentionsNarrow());
      await store.addStream(stream);
      await store.setUserTopic(stream, mutedTopic, UserTopicVisibilityPolicy.muted);
      await store.addSubscription(eg.subscription(stream, isMuted: true));

      List<Message> getMessages(int startingId) => [
        eg.streamMessage(id: startingId,
          stream: stream, topic: mutedTopic, flags: [MessageFlag.topicWildcardMentioned]),
        eg.streamMessage(id: startingId + 1,
          stream: stream, topic: mutedTopic, flags: [MessageFlag.streamWildcardMentioned]),
        eg.streamMessage(id: startingId + 2,
          stream: stream, topic: mutedTopic, flags: [MessageFlag.mentioned]),
        eg.dmMessage(id: startingId + 3,
          from: eg.otherUser, to: [eg.selfUser], flags: [MessageFlag.mentioned]),
      ];

      // Check filtering on fetchInitial…
      await prepareMessages(foundOldest: false, messages: getMessages(201));
      final expected = <int>[];
      checkHasMessageIds(expected..addAll([201, 202, 203, 204]));

      // … and on fetchOlder…
      connection.prepare(json: olderResult(
        anchor: 201, foundOldest: true, messages: getMessages(101)).toJson());
      await model.fetchOlder();
      checkNotified(count: 2);
      checkHasMessageIds(expected..insertAll(0, [101, 102, 103, 104]));

      // … and on MessageEvent.
      final messages = getMessages(301);
      for (var i = 0; i < messages.length; i += 1) {
        await store.addMessage(messages[i]);
        checkNotifiedOnce();
        checkHasMessageIds(expected..add(301 + i));
      }
    });

    test('in StarredMessagesNarrow', () async {
      final stream = eg.stream(streamId: 1, name: 'muted stream');
      const mutedTopic = 'muted';
      await prepare(
        narrow: const StarredMessagesNarrow(),
        starredMessages: [101, 102, 201, 202, 301, 302],
      );
      await store.addStream(stream);
      await store.setUserTopic(stream, mutedTopic, UserTopicVisibilityPolicy.muted);
      await store.addSubscription(eg.subscription(stream, isMuted: true));

      List<Message> getMessages(int startingId) => [
        eg.streamMessage(id: startingId,
          stream: stream, topic: mutedTopic, flags: [MessageFlag.starred]),
        eg.dmMessage(id: startingId + 1,
          from: eg.otherUser, to: [eg.selfUser], flags: [MessageFlag.starred]),
      ];

      // Check filtering on fetchInitial…
      await prepareMessages(foundOldest: false, messages: getMessages(201));
      final expected = <int>[];
      checkHasMessageIds(expected..addAll([201, 202]));

      // … and on fetchOlder…
      connection.prepare(json: olderResult(
        anchor: 201, foundOldest: true, messages: getMessages(101)).toJson());
      await model.fetchOlder();
      checkNotified(count: 2);
      checkHasMessageIds(expected..insertAll(0, [101, 102]));

      // … and on MessageEvent.
      final messages = getMessages(301);
      for (var i = 0; i < 2; i += 1) {
        await store.addMessage(messages[i]);
        checkNotifiedOnce();
        checkHasMessageIds(expected..add(301 + i));
      }
    });
  });

  group('middleMessage maintained', () {
    // In [checkInvariants] we verify that messages don't move from the
    // top to the bottom slice or vice versa.
    // Most of these test cases rely on that for all the checks they need.

    test('on fetchInitial empty', () async {
      await prepare(narrow: const CombinedFeedNarrow());
      await prepareMessages(foundOldest: true, messages: []);
      check(model)..messages.isEmpty()
        ..middleMessage.equals(0);
    });

    test('on fetchInitial empty due to muting', () async {
      await prepare(narrow: const CombinedFeedNarrow());
      final stream = eg.stream();
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream, isMuted: true));
      await prepareMessages(foundOldest: true, messages: [
        eg.streamMessage(stream: stream),
      ]);
      check(model)..messages.isEmpty()
        ..middleMessage.equals(0);
    });

    test('on fetchInitial, anchor past end', () async {
      await prepare(narrow: const CombinedFeedNarrow(),
        anchor: AnchorCode.newest);
      final stream1 = eg.stream();
      final stream2 = eg.stream();
      await store.addStreams([stream1, stream2]);
      await store.addSubscription(eg.subscription(stream1));
      await store.addSubscription(eg.subscription(stream2, isMuted: true));
      final messages = [
        eg.streamMessage(stream: stream1), eg.streamMessage(stream: stream2),
        eg.streamMessage(stream: stream1), eg.streamMessage(stream: stream2),
        eg.streamMessage(stream: stream1), eg.streamMessage(stream: stream2),
        eg.streamMessage(stream: stream1), eg.streamMessage(stream: stream2),
        eg.streamMessage(stream: stream1), eg.streamMessage(stream: stream2),
      ];
      await prepareMessages(foundOldest: true, messages: messages);
      // The anchor message is the last visible message…
      check(model)
        ..messages.length.equals(5)
        ..middleMessage.equals(model.messages.length - 1)
        // … even though that's not the last message that was in the response.
        ..messages[model.middleMessage].id
            .equals(messages[messages.length - 2].id);
    });

    test('on fetchInitial, anchor in middle', () async {
      final s1 = eg.stream();
      final s2 = eg.stream();
      final messages = [
        eg.streamMessage(id: 1, stream: s1), eg.streamMessage(id: 2, stream: s2),
        eg.streamMessage(id: 3, stream: s1), eg.streamMessage(id: 4, stream: s2),
        eg.streamMessage(id: 5, stream: s1), eg.streamMessage(id: 6, stream: s2),
        eg.streamMessage(id: 7, stream: s1), eg.streamMessage(id: 8, stream: s2),
      ];
      final anchorId = 4;

      await prepare(narrow: const CombinedFeedNarrow(),
        anchor: NumericAnchor(anchorId));
      await store.addStreams([s1, s2]);
      await store.addSubscription(eg.subscription(s1));
      await store.addSubscription(eg.subscription(s2, isMuted: true));
      await prepareMessages(foundOldest: true, foundNewest: true,
        messages: messages);
      // The anchor message is the first visible message with ID at least anchorId…
      check(model)
        ..messages[model.middleMessage - 1].id.isLessThan(anchorId)
        ..messages[model.middleMessage].id.isGreaterOrEqual(anchorId);
      // … even though a non-visible message actually had anchorId itself.
      check(messages[3].id)
        ..equals(anchorId)
        ..isLessThan(model.messages[model.middleMessage].id);
    });

    /// Like [prepareMessages], but arrange for the given top and bottom slices.
    Future<void> prepareMessageSplit(List<Message> top, List<Message> bottom, {
      bool foundOldest = true,
    }) async {
      assert(bottom.isNotEmpty); // could handle this too if necessary
      await prepareMessages(foundOldest: foundOldest, messages: [
        ...top,
        bottom.first,
      ]);
      if (bottom.length > 1) {
        await store.addMessages(bottom.skip(1));
        checkNotifiedOnce();
      }
      check(model)
        ..messages.length.equals(top.length + bottom.length)
        ..middleMessage.equals(top.length);
    }

    test('on fetchOlder', () async {
      await prepare(narrow: const CombinedFeedNarrow());
      final stream = eg.stream();
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));
      await prepareMessageSplit(foundOldest: false,
        [eg.streamMessage(id: 100, stream: stream)],
        [eg.streamMessage(id: 101, stream: stream)]);

      connection.prepare(json: olderResult(anchor: 100, foundOldest: true,
        messages: List.generate(5, (i) =>
          eg.streamMessage(id: 95 + i, stream: stream))).toJson());
      await model.fetchOlder();
      checkNotified(count: 2);
    });

    test('on fetchOlder, from top empty', () async {
      await prepare(narrow: const CombinedFeedNarrow());
      final stream = eg.stream();
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));
      await prepareMessageSplit(foundOldest: false,
        [], [eg.streamMessage(id: 100, stream: stream)]);

      connection.prepare(json: olderResult(anchor: 100, foundOldest: true,
        messages: List.generate(5, (i) =>
          eg.streamMessage(id: 95 + i, stream: stream))).toJson());
      await model.fetchOlder();
      checkNotified(count: 2);
      // The messages from fetchOlder should go in the top sliver, always.
      check(model).middleMessage.equals(5);
    });

    test('on MessageEvent', () async {
      await prepare(narrow: const CombinedFeedNarrow());
      final stream = eg.stream();
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));
      await prepareMessageSplit(foundOldest: false,
        [eg.streamMessage(stream: stream)],
        [eg.streamMessage(stream: stream)]);

      await store.addMessage(eg.streamMessage(stream: stream));
      checkNotifiedOnce();
    });

    test('on messages muted, including anchor', () async {
      await prepare(narrow: const CombinedFeedNarrow());
      final stream = eg.stream();
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));
      await prepareMessageSplit([
        eg.streamMessage(stream: stream, topic: 'foo'),
        eg.streamMessage(stream: stream, topic: 'bar'),
      ], [
        eg.streamMessage(stream: stream, topic: 'bar'),
        eg.streamMessage(stream: stream, topic: 'foo'),
      ]);

      await store.handleEvent(eg.userTopicEvent(
        stream.streamId, 'bar', UserTopicVisibilityPolicy.muted));
      checkNotifiedOnce();
    });

    test('on messages muted, not including anchor', () async {
      await prepare(narrow: const CombinedFeedNarrow());
      final stream = eg.stream();
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));
      await prepareMessageSplit([
        eg.streamMessage(stream: stream, topic: 'foo'),
        eg.streamMessage(stream: stream, topic: 'bar'),
      ], [
        eg.streamMessage(stream: stream, topic: 'foo'),
      ]);

      await store.handleEvent(eg.userTopicEvent(
        stream.streamId, 'bar', UserTopicVisibilityPolicy.muted));
      checkNotifiedOnce();
    });

    test('on messages muted, bottom empty', () async {
      await prepare(narrow: const CombinedFeedNarrow());
      final stream = eg.stream();
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));
      await prepareMessageSplit([
        eg.streamMessage(stream: stream, topic: 'foo'),
        eg.streamMessage(stream: stream, topic: 'bar'),
      ], [
        eg.streamMessage(stream: stream, topic: 'third'),
      ]);

      await store.handleEvent(eg.deleteMessageEvent([
        model.messages.last as StreamMessage]));
      checkNotifiedOnce();
      check(model).middleMessage.equals(model.messages.length);

      await store.handleEvent(eg.userTopicEvent(
        stream.streamId, 'bar', UserTopicVisibilityPolicy.muted));
      checkNotifiedOnce();
    });

    test('on messages deleted', () async {
      await prepare(narrow: const CombinedFeedNarrow());
      final stream = eg.stream();
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));
      final messages = [
        eg.streamMessage(id: 1, stream: stream),
        eg.streamMessage(id: 2, stream: stream),
        eg.streamMessage(id: 3, stream: stream),
        eg.streamMessage(id: 4, stream: stream),
      ];
      await prepareMessageSplit(messages.sublist(0, 2), messages.sublist(2));

      await store.handleEvent(eg.deleteMessageEvent(messages.sublist(1, 3)));
      checkNotifiedOnce();
    });

    test('on messages deleted, bottom empty', () async {
      await prepare(narrow: const CombinedFeedNarrow());
      final stream = eg.stream();
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));
      final messages = [
        eg.streamMessage(id: 1, stream: stream),
        eg.streamMessage(id: 2, stream: stream),
        eg.streamMessage(id: 3, stream: stream),
        eg.streamMessage(id: 4, stream: stream),
      ];
      await prepareMessageSplit(messages.sublist(0, 3), messages.sublist(3));

      await store.handleEvent(eg.deleteMessageEvent(messages.sublist(3)));
      checkNotifiedOnce();
      check(model).middleMessage.equals(model.messages.length);

      await store.handleEvent(eg.deleteMessageEvent(messages.sublist(1, 2)));
      checkNotifiedOnce();
    });
  });

  group('handle content parsing into subclasses of ZulipMessageContent', () {
    test('ZulipContent', () async {
      final stream = eg.stream();
      await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
      await prepareMessages(foundOldest: true, messages: []);

      await store.addMessage(eg.streamMessage(stream: stream));
      // Each [checkNotifiedOnce] call ensures there's been a [checkInvariants]
      // call, where the [ContentNode] gets checked.  The additional checks to
      // make this test explicit.
      checkNotifiedOnce();
      check(model).messages.single.poll.isNull();
      check(model).contents.single.isA<ZulipContent>();
    });

    test('PollContent', () async {
      final stream = eg.stream();
      await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
      await prepareMessages(foundOldest: true, messages: []);

      await store.addMessage(eg.streamMessage(
        stream: stream,
        sender: eg.selfUser,
        submessages: [
          eg.submessage(senderId: eg.selfUser.userId,
            content: eg.pollWidgetData(question: 'question', options: ['A'])),
        ]));
      // Each [checkNotifiedOnce] call ensures there's been a [checkInvariants]
      // call, where the value of the [Poll] gets checked.  The additional
      // checks make this test explicit.
      checkNotifiedOnce();
      check(model).messages.single.poll.isNotNull();
      check(model).contents.single.isA<PollContent>();
    });
  });

  group('findItemWithMessageId', () {
    test('has MessageListDateSeparatorItem with null message ID', () => awaitFakeAsync(
        // Pin the clock, to noon, so the message is definitely dated on the
        // previous calendar day. (This avoids flakes involving a 25-hour day
        // when clocks fall back for Daylight Saving Time.)
        initialTime: DateTime(2035, 8, 21, 12), (async) async {
      final stream = eg.stream();
      final message = eg.streamMessage(stream: stream, topic: 'topic',
        timestamp: eg.utcTimestamp(clock.daysAgo(1)));
      await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
      await prepareMessages(foundOldest: true, messages: [message]);

      // `findItemWithMessageId` uses binary search.  Set up just enough
      // outbox message items, so that a [MessageListDateSeparatorItem] for
      // the outbox messages is right in the middle.
      await prepareOutboxMessages(count: 2, stream: stream, topic: 'topic');
      async.elapse(kLocalEchoDebounceDuration);
      checkNotified(count: 2);
      check(model.items).deepEquals(<Condition<Object?>>[
        (it) => it.isA<MessageListRecipientHeaderItem>(),
        (it) => it.isA<MessageListMessageItem>(),
        (it) => it.isA<MessageListDateSeparatorItem>().message.id.isNull(),
        (it) => it.isA<MessageListOutboxMessageItem>(),
        (it) => it.isA<MessageListOutboxMessageItem>(),
      ]);
      check(model.findItemWithMessageId(message.id)).equals(1);
    }));

    test('has MessageListOutboxMessageItem', () => awaitFakeAsync((async) async {
      final stream = eg.stream();
      final message = eg.streamMessage(stream: stream, topic: 'topic',
        timestamp: eg.utcTimestamp(clock.now()));
      await prepare(narrow: ChannelNarrow(stream.streamId), stream: stream);
      await prepareMessages(foundOldest: true, messages: [message]);

      // `findItemWithMessageId` uses binary search.  Set up just enough
      // outbox message items, so that a [MessageListOutboxMessageItem]
      // is right in the middle.
      await prepareOutboxMessages(count: 3, stream: stream, topic: 'topic');
      async.elapse(kLocalEchoDebounceDuration);
      checkNotified(count: 3);
      check(model.items).deepEquals(<Condition<Object?>>[
        (it) => it.isA<MessageListRecipientHeaderItem>(),
        (it) => it.isA<MessageListMessageItem>(),
        (it) => it.isA<MessageListOutboxMessageItem>(),
        (it) => it.isA<MessageListOutboxMessageItem>(),
        (it) => it.isA<MessageListOutboxMessageItem>(),
      ]);
      check(model.findItemWithMessageId(message.id)).equals(1);
    }));
  });

  test('recipient headers are maintained consistently (Combined feed)', () => awaitFakeAsync((async) async {
    // TODO test date separators are maintained consistently too
    // This tests the code that maintains the invariant that recipient headers
    // are present just where they're required.
    // In [checkInvariants] we check the current state against that invariant,
    // so here we just need to exercise that code through all the relevant cases.
    // Each [checkNotifiedOnce] call ensures there's been a [checkInvariants] call
    // (in the listener that increments [notifiedCount]).
    //
    // A separate unit test covers [haveSameRecipient] itself.  So this test
    // just needs messages that have the same recipient, and that don't, and
    // doesn't need to exercise the different reasons that messages don't.

    final timestamp = eg.utcTimestamp(clock.now());
    final stream = eg.stream(streamId: eg.defaultStreamMessageStreamId);
    Message streamMessage(int id) =>
      eg.streamMessage(id: id, stream: stream, topic: 'foo', timestamp: timestamp);
    Message dmMessage(int id) =>
      eg.dmMessage(id: id, from: eg.selfUser, to: [], timestamp: timestamp);

    // First, test fetchInitial, where some headers are needed and others not.
    await prepare(narrow: CombinedFeedNarrow());
    connection.prepare(json: newestResult(
      foundOldest: false,
      messages: [streamMessage(10), streamMessage(11), dmMessage(12)],
    ).toJson());
    await model.fetchInitial();
    checkNotifiedOnce();

    // Then fetchOlder, where a header is needed in between…
    connection.prepare(json: olderResult(
      anchor: model.messages[0].id,
      foundOldest: false,
      messages: [streamMessage(7), streamMessage(8), dmMessage(9)],
    ).toJson());
    await model.fetchOlder();
    checkNotified(count: 2);

    //  … and fetchOlder where there's no header in between.
    connection.prepare(json: olderResult(
      anchor: model.messages[0].id,
      foundOldest: false,
      messages: [streamMessage(6)],
    ).toJson());
    await model.fetchOlder();
    checkNotified(count: 2);

    // Then test MessageEvent, where a new header is needed…
    await store.addMessage(streamMessage(13));
    checkNotifiedOnce();

    // … and where it's not.
    await store.addMessage(streamMessage(14));
    checkNotifiedOnce();

    // Then test UpdateMessageEvent edits, where a header is and remains needed…
    UpdateMessageEvent updateEvent(Message message) => eg.updateMessageEditEvent(
      message, renderedContent: '${message.content}<p>edited</p>',
    );
    await store.handleEvent(updateEvent(model.messages.first));
    checkNotifiedOnce();
    await store.handleEvent(updateEvent(model.messages[model.messages.length - 2]));
    checkNotifiedOnce();

    // … and where it's not.
    await store.handleEvent(updateEvent(model.messages.last));
    checkNotifiedOnce();

    // Then test reassemble.
    model.reassemble();
    checkNotifiedOnce();

    // Then test outbox message, where a new header is needed…
    connection.prepare(json: SendMessageResult(id: 1).toJson());
    await store.sendMessage(
      destination: DmDestination(userIds: [eg.selfUser.userId]), content: 'hi');
    async.elapse(kLocalEchoDebounceDuration);
    checkNotifiedOnce();

    // … and where it's not.
    connection.prepare(json: SendMessageResult(id: 1).toJson());
    await store.sendMessage(
      destination: DmDestination(userIds: [eg.selfUser.userId]), content: 'hi');
    async.elapse(kLocalEchoDebounceDuration);
    checkNotifiedOnce();

    // Have a new fetchOlder reach the oldest, so that a history-start marker appears…
    connection.prepare(json: olderResult(
      anchor: model.messages[0].id,
      foundOldest: true,
      messages: [streamMessage(5)],
    ).toJson());
    await model.fetchOlder();
    checkNotified(count: 2);

    // … and then test reassemble again.
    model.reassemble();
    checkNotifiedOnce();

    final outboxMessageIds = store.outboxMessages.keys.toList();
    // Then test removing the first outbox message…
    await store.handleEvent(eg.messageEvent(
      dmMessage(15), localMessageId: outboxMessageIds.first));
    checkNotifiedOnce();

    // … and handling a new non-outbox message…
    await store.handleEvent(eg.messageEvent(streamMessage(16)));
    checkNotifiedOnce();

    // … and removing the second outbox message.
    await store.handleEvent(eg.messageEvent(
      dmMessage(17), localMessageId: outboxMessageIds.last));
    checkNotifiedOnce();
  }));

  group('one message per block?', () {
    final channelId = 1;
    final topic = 'some topic';
    void doTest({required Narrow narrow, required bool expected}) {
      test('$narrow: ${expected ? 'yes' : 'no'}', () async {
        final sender = eg.user();
        final channel = eg.stream(streamId: channelId);
        final message1 = eg.streamMessage(
          sender: sender,
          stream: channel,
          topic: topic,
          flags: [MessageFlag.starred, MessageFlag.mentioned],
        );
        final message2 = eg.streamMessage(
          sender: sender,
          stream: channel,
          topic: topic,
          flags: [MessageFlag.starred, MessageFlag.mentioned],
        );

        await prepare(
          narrow: narrow,
          starredMessages: [message1.id, message2.id],
          stream: channel,
        );
        connection.prepare(json: newestResult(
          foundOldest: false,
          messages: [message1, message2],
        ).toJson());
        await model.fetchInitial();
        checkNotifiedOnce();

        check(model).items.deepEquals(<Condition<Object?>>[
          (it) => it.isA<MessageListRecipientHeaderItem>(),
          (it) => it.isA<MessageListMessageItem>(),
          if (expected) (it) => it.isA<MessageListRecipientHeaderItem>(),
          (it) => it.isA<MessageListMessageItem>(),
        ]);
      });
    }

    doTest(narrow: CombinedFeedNarrow(),                expected: false);
    doTest(narrow: ChannelNarrow(channelId),            expected: false);
    doTest(narrow: TopicNarrow(channelId, eg.t(topic)), expected: false);
    doTest(narrow: StarredMessagesNarrow(),             expected: true);
    doTest(narrow: MentionsNarrow(),                    expected: true);
  });

  test('showSender is maintained correctly', () => awaitFakeAsync(
      // Pin the clock, to avoid flakes that depend on the local time of day.
      initialTime: DateTime(2035, 8, 21), (async) async {
    // TODO(#150): This will get more complicated with message moves.
    // Until then, we always compute this sequentially from oldest to newest.
    // So we just need to exercise the different cases of the logic for
    // whether the sender should be shown, but the difference between
    // fetchInitial and handleMessageEvent etc. doesn't matter.

    final now = clock.now();
    final t1 = eg.utcTimestamp(now.subtract(Duration(days: 1)));
    final t2 = t1 + Duration(minutes: 1).inSeconds;
    final t3 = t2 + Duration(minutes: 10, seconds: 1).inSeconds;
    final t4 = eg.utcTimestamp(now);
    final stream = eg.stream(streamId: eg.defaultStreamMessageStreamId);
    Message streamMessage(int timestamp, User sender) =>
      eg.streamMessage(sender: sender,
        stream: stream, topic: 'foo', timestamp: timestamp);
    Message dmMessage(int timestamp, User sender) =>
      eg.dmMessage(from: sender, timestamp: timestamp,
        to: [sender.userId == eg.selfUser.userId ? eg.otherUser : eg.selfUser]);
    DmDestination dmDestination(List<User> users) =>
      DmDestination(userIds: users.map((user) => user.userId).toList());

    await prepare();
    await prepareMessages(foundOldest: true, messages: [
      streamMessage(t1, eg.selfUser),  // first message, so show sender
      streamMessage(t1, eg.selfUser),  // hide sender
      streamMessage(t1, eg.otherUser), // no recipient header, but new sender
      streamMessage(t2, eg.otherUser), // same sender, and within 10 mins of last message
      streamMessage(t3, eg.otherUser), // same sender, but after 10 mins from last message
      dmMessage(    t3, eg.otherUser), // same sender, but new recipient
      dmMessage(    t4, eg.otherUser), // same sender/recipient, but new day
    ]);
    await prepareOutboxMessagesTo([
      dmDestination([eg.selfUser, eg.otherUser]), // same day, but new sender
      dmDestination([eg.selfUser, eg.otherUser]), // hide sender
    ]);
    assert(
      store.outboxMessages.values.every((message) => message.timestamp == t4));
    async.elapse(kLocalEchoDebounceDuration);

    // We check showSender has the right values in [checkInvariants],
    // but to make this test explicit:
    check(model.items).deepEquals(<void Function(Subject<Object?>)>[
      (it) => it.isA<MessageListRecipientHeaderItem>(),
      (it) => it.isA<MessageListMessageItem>().showSender.isTrue(),
      (it) => it.isA<MessageListMessageItem>().showSender.isFalse(),
      (it) => it.isA<MessageListMessageItem>().showSender.isTrue(),
      (it) => it.isA<MessageListMessageItem>().showSender.isFalse(),
      (it) => it.isA<MessageListMessageItem>().showSender.isTrue(),
      (it) => it.isA<MessageListRecipientHeaderItem>(),
      (it) => it.isA<MessageListMessageItem>().showSender.isTrue(),
      (it) => it.isA<MessageListDateSeparatorItem>(),
      (it) => it.isA<MessageListMessageItem>().showSender.isTrue(),
      (it) => it.isA<MessageListOutboxMessageItem>().showSender.isTrue(),
      (it) => it.isA<MessageListOutboxMessageItem>().showSender.isFalse(),
    ]);
  }));

  group('haveSameRecipient', () {
    test('stream messages vs DMs, no match', () {
      final dmMessage = eg.dmMessage(from: eg.selfUser, to: [eg.otherUser]);
      final streamMessage = eg.streamMessage();
      check(haveSameRecipient(streamMessage, dmMessage)).isFalse();
      check(haveSameRecipient(dmMessage, streamMessage)).isFalse();
    });

    test('stream messages match just if same stream/topic', () {
      final stream0 = eg.stream();
      final stream1 = eg.stream();
      final messageAB = eg.streamMessage(stream: stream0, topic: 'foo');
      final messageXB = eg.streamMessage(stream: stream1, topic: 'foo');
      final messageAX = eg.streamMessage(stream: stream0, topic: 'bar');
      check(haveSameRecipient(messageAB, messageAB)).isTrue();
      check(haveSameRecipient(messageAB, messageXB)).isFalse();
      check(haveSameRecipient(messageXB, messageAB)).isFalse();
      check(haveSameRecipient(messageAB, messageAX)).isFalse();
      check(haveSameRecipient(messageAX, messageAB)).isFalse();
      check(haveSameRecipient(messageAX, messageXB)).isFalse();
      check(haveSameRecipient(messageXB, messageAX)).isFalse();
    });

    test('DMs match just if same recipients', () {
      final message0 = eg.dmMessage(from: eg.selfUser, to: []);
      final message01 = eg.dmMessage(from: eg.selfUser, to: [eg.otherUser]);
      final message10 = eg.dmMessage(from: eg.otherUser, to: [eg.selfUser]);
      final message02 = eg.dmMessage(from: eg.selfUser, to: [eg.thirdUser]);
      final message20 = eg.dmMessage(from: eg.thirdUser, to: [eg.selfUser]);
      final message012 = eg.dmMessage(from: eg.selfUser, to: [eg.otherUser, eg.thirdUser]);
      final message102 = eg.dmMessage(from: eg.otherUser, to: [eg.selfUser, eg.thirdUser]);
      final message201 = eg.dmMessage(from: eg.thirdUser, to: [eg.selfUser, eg.otherUser]);
      final groups = [[message0], [message01, message10],
        [message02, message20], [message012, message102, message201]];
      for (int i0 = 0; i0 < groups.length; i0++) {
        for (int i1 = 0; i1 < groups.length; i1++) {
          for (int j0 = 0; j0 < groups[i0].length; j0++) {
            for (int j1 = 0; j1 < groups[i1].length; j1++) {
              final message0 = groups[i0][j0];
              final message1 = groups[i1][j1];
              check(
                because: 'recipients ${message0.allRecipientIds} vs ${message1.allRecipientIds}',
                haveSameRecipient(message0, message1),
              ).equals(i0 == i1);
            }
          }
        }
      }
    });

    group('topics compared case-insensitively', () {
      void doTest(String description, String topicA, String topicB, bool expected) {
        test(description, () {
          final stream = eg.stream();
          final messageA = eg.streamMessage(stream: stream, topic: topicA);
          final messageB = eg.streamMessage(stream: stream, topic: topicB);
          check(haveSameRecipient(messageA, messageB)).equals(expected);
        });
      }

      doTest('same case, all lower',               'abc',  'abc',  true);
      doTest('same case, all upper',               'ABC',  'ABC',  true);
      doTest('same case, mixed',                   'AbC',  'AbC',  true);
      doTest('same non-cased chars',               '嗎',    '嗎',    true);
      doTest('different case',                     'aBc',  'ABC',  true);
      doTest('different case, same diacritics',    'AbÇ',  'aBç',  true);
      doTest('same letters, different diacritics', 'ma',   'mǎ',   false);
      doTest('having different CJK characters',    '嗎', '馬', false);
    });

    test('outbox messages', () {
      final stream = eg.stream();
      final streamMessage1 = eg.streamOutboxMessage(stream: stream, topic: 'foo');
      final streamMessage2 = eg.streamOutboxMessage(stream: stream, topic: 'bar');
      final dmMessage = eg.dmOutboxMessage(from: eg.selfUser, to: [eg.otherUser]);
      check(haveSameRecipient(streamMessage1, streamMessage1)).isTrue();
      check(haveSameRecipient(streamMessage1, streamMessage2)).isFalse();
      check(haveSameRecipient(streamMessage1, dmMessage)).isFalse();
    });
  });

  // These timestamps will differ depending on the timezone of the
  // environment where the tests are run, in order to give the same results
  // in the code under test which is also based on the ambient timezone.
  // TODO(dart): It'd be great if tests could control the ambient timezone,
  //   so as to exercise cases like where local time falls back across midnight.
  int timestampFromLocalTime(String date) => DateTime.parse(date).millisecondsSinceEpoch ~/ 1000;

  test('messagesSameDay', () {
    const t111a = '2021-01-01 00:00:00';
    const t111b = '2021-01-01 12:00:00';
    const t111c = '2021-01-01 23:59:58';
    const t111d = '2021-01-01 23:59:59';
    const t112a = '2021-01-02 00:00:00';
    const t112b = '2021-01-02 00:00:01';
    const t121 = '2021-02-01 00:00:00';
    const t211 = '2022-01-01 00:00:00';
    final groups = [[t111a, t111b, t111c, t111d], [t112a, t112b], [t121], [t211]];

    final stream = eg.stream();
    for (int i0 = 0; i0 < groups.length; i0++) {
      for (int i1 = i0; i1 < groups.length; i1++) {
        for (int j0 = 0; j0 < groups[i0].length; j0++) {
          for (int j1 = (i0 == i1) ? j0 : 0; j1 < groups[i1].length; j1++) {
            final time0 = groups[i0][j0];
            final time1 = groups[i1][j1];
            check(because: 'times $time0, $time1', messagesSameDay(
              eg.streamMessage(stream: stream, topic: 'foo', timestamp: timestampFromLocalTime(time0)),
              eg.streamMessage(stream: stream, topic: 'foo', timestamp: timestampFromLocalTime(time1)),
            )).equals(i0 == i1);
            check(because: 'times $time0, $time1', messagesSameDay(
              eg.dmMessage(from: eg.selfUser, to: [], timestamp: timestampFromLocalTime(time0)),
              eg.dmMessage(from: eg.selfUser, to: [], timestamp: timestampFromLocalTime(time1)),
            )).equals(i0 == i1);
            check(because: 'times $time0, $time1', messagesSameDay(
              eg.streamOutboxMessage(timestamp: timestampFromLocalTime(time0)),
              eg.streamOutboxMessage(timestamp: timestampFromLocalTime(time1)),
            )).equals(i0 == i1);
            check(because: 'times $time0, $time1', messagesSameDay(
              eg.dmOutboxMessage(from: eg.selfUser, to: [], timestamp: timestampFromLocalTime(time0)),
              eg.dmOutboxMessage(from: eg.selfUser, to: [], timestamp: timestampFromLocalTime(time1)),
            )).equals(i0 == i1);
          }
        }
      }
    }
  });

  group('messagesCloseInTime', () {
    final stream = eg.stream();
    void doTest(String time0, String time1, bool expected) {
      test('$time0 vs $time1 -> $expected', () {
        check(messagesCloseInTime(
          eg.streamMessage(stream: stream, topic: 'foo', timestamp: timestampFromLocalTime(time0)),
          eg.streamMessage(stream: stream, topic: 'foo', timestamp: timestampFromLocalTime(time1)),
        )).equals(expected);
        check(messagesCloseInTime(
          eg.dmMessage(from: eg.selfUser, to: [], timestamp: timestampFromLocalTime(time0)),
          eg.dmMessage(from: eg.selfUser, to: [], timestamp: timestampFromLocalTime(time1)),
        )).equals(expected);
        check(messagesCloseInTime(
          eg.streamOutboxMessage(timestamp: timestampFromLocalTime(time0)),
          eg.streamOutboxMessage(timestamp: timestampFromLocalTime(time1)),
        )).equals(expected);
        check(messagesCloseInTime(
          eg.dmOutboxMessage(from: eg.selfUser, to: [], timestamp: timestampFromLocalTime(time0)),
          eg.dmOutboxMessage(from: eg.selfUser, to: [], timestamp: timestampFromLocalTime(time1)),
        )).equals(expected);
      });
    }

    const time = '2021-01-01 00:30:00';

    doTest('2021-01-01 00:19:59', time, false);
    doTest('2021-01-01 00:20:00', time, true);
    doTest('2021-01-01 00:29:59', time, true);
    doTest('2021-01-01 00:30:00', time, true);

    doTest(time, '2021-01-01 00:30:01', true);
    doTest(time, '2021-01-01 00:39:59', true);
    doTest(time, '2021-01-01 00:40:00', true);
    doTest(time, '2021-01-01 00:40:01', false);

    doTest(time, '2022-01-01 00:30:00', false);
    doTest(time, '2021-02-01 00:30:00', false);
    doTest(time, '2021-01-02 00:30:00', false);
    doTest(time, '2021-01-01 01:30:00', false);
  });
}

MessageListView? _lastModel;
List<Message>? _lastMessages;
int? _lastMiddleMessage;
bool? _lastShowingCachedMessages;

void checkInvariants(MessageListView model) {
  if (!model.fetched) {
    check(model)
      ..showingCachedMessages.isFalse()
      ..messages.isEmpty()
      ..outboxMessages.isEmpty()
      ..oldestFetchedMessageId.isNull()
      ..newestFetchedMessageId.isNull()
      ..haveOldest.isFalse()
      ..haveNewest.isFalse()
      ..busyFetchingMore.isFalse();
  }
  if (model.showingCachedMessages) {
    check(model)
      ..fetched.isTrue()
      ..outboxMessages.isEmpty()
      ..oldestFetchedMessageId.isNull()
      ..newestFetchedMessageId.isNull()
      ..haveOldest.isFalse()
      ..haveNewest.isFalse()
      ..busyFetchingMore.isTrue();
  }
  if (model.fetchInitialFailing) {
    check(model)
      ..fetched.isFalse()
      ..showingCachedMessages.isFalse();
  }
  if (model.haveOldest && model.haveNewest) {
    check(model).busyFetchingMore.isFalse();
  }

  for (final message in model.messages) {
    if (model.showingCachedMessages && model.store.messages[message.id] == null) {
      // A message known only from the cache.
      continue;
    }
    check(model.store.messages)[message.id].isNotNull().identicalTo(message);
  }
  if (model.outboxMessages.isNotEmpty) {
    check(model.haveNewest).isTrue();
  }
  for (final message in model.outboxMessages) {
    check(message).hidden.isFalse();
    check(model.store.outboxMessages)[message.localMessageId].isNotNull().identicalTo(message);
  }

  final allMessages = [...model.messages, ...model.outboxMessages];

  for (final message in allMessages) {
    check(model.narrow.containsMessage(message)).anyOf(<Condition<bool?>>[
      (it) => it.isNull(),
      (it) => it.isNotNull().isTrue(),
    ]);

    if (message is MessageBase<StreamConversation>) {
      final conversation = message.conversation;
      switch (model.narrow) {
        case CombinedFeedNarrow():
          check(model.store.isTopicVisible(conversation.streamId, conversation.topic))
            .isTrue();
        case ChannelNarrow():
          check(model.store.isTopicVisibleInChannel(conversation.streamId, conversation.topic))
            .isTrue();
        case TopicNarrow():
        case DmNarrow():
        case MentionsNarrow():
        case StarredMessagesNarrow():
        case KeywordSearchNarrow():
      }
    } else if (message is DmMessage) {
      final narrow = DmNarrow.ofMessage(message, selfUserId: model.store.selfUserId);
      switch (model.narrow) {
        case CombinedFeedNarrow():
        case MentionsNarrow():
        case KeywordSearchNarrow():
          check(model.store.shouldMuteDmConversation(narrow)).isFalse();
        case ChannelNarrow():
        case TopicNarrow():
        case DmNarrow():
        case StarredMessagesNarrow():
      }
    }
  }

  check(isSortedWithoutDuplicates(model.messages.map((m) => m.id).toList()))
    .isTrue();
  check(isSortedWithoutDuplicates(model.outboxMessages.map((m) => m.localMessageId).toList()))
    .isTrue();

  if (model.messages.isNotEmpty && !model.showingCachedMessages) {
    check(model).oldestFetchedMessageId.isNotNull()
      .isLessOrEqual(model.messages.first.id);
    check(model).newestFetchedMessageId.isNotNull()
      .isGreaterOrEqual(model.messages.last.id);
  }

  check(model).middleMessage
    ..isGreaterOrEqual(0)
    ..isLessOrEqual(model.messages.length);

  if (identical(model, _lastModel)
      && model.generation == _lastModel!.generation
      // When fresh messages replace cached ones, the slices start over.
      && model.showingCachedMessages == _lastShowingCachedMessages) {
    // All messages that were present, and still are, should be on the same side
    // of `middleMessage` (still top or bottom slice respectively) as they were.
    _checkNoIntersection(ListSlice(model.messages, 0, model.middleMessage),
      ListSlice(_lastMessages!, _lastMiddleMessage!, _lastMessages!.length),
      because: 'messages moved from bottom slice to top slice');
    _checkNoIntersection(ListSlice(_lastMessages!, 0, _lastMiddleMessage!),
      ListSlice(model.messages, model.middleMessage, model.messages.length),
      because: 'messages moved from top slice to bottom slice');
  }
  _lastModel = model;
  _lastMessages = model.messages.toList();
  _lastMiddleMessage = model.middleMessage;
  _lastShowingCachedMessages = model.showingCachedMessages;

  check(model).contents.length.equals(model.messages.length);
  for (int i = 0; i < model.contents.length; i++) {
    final poll = model.messages[i].poll;
    if (poll != null) {
      check(model).contents[i].isA<PollContent>().poll.identicalTo(poll);
      continue;
    }
    check(model.contents[i]).isA<ZulipContent>()
      .equalsNode(parseContent(model.messages[i].content));
  }

  int i = 0;
  for (int j = 0; j < allMessages.length; j++) {
    final bool showSender;
    if (j == 0
        || model.oneMessagePerBlock
        || !haveSameRecipient(allMessages[j-1], allMessages[j])) {
      check(model.items[i++]).isA<MessageListRecipientHeaderItem>()
        .message.identicalTo(allMessages[j]);
      showSender = true;
    } else if (!messagesSameDay(allMessages[j-1], allMessages[j])) {
      check(model.items[i++]).isA<MessageListDateSeparatorItem>()
        .message.identicalTo(allMessages[j]);
      showSender = true;
    } else if (allMessages[j-1].senderId == allMessages[j].senderId) {
      showSender = !messagesCloseInTime(allMessages[j-1], allMessages[j]);
    } else {
      showSender = true;
    }
    if (j < model.messages.length) {
      check(model.items[i]).isA<MessageListMessageItem>()
        ..message.identicalTo(model.messages[j])
        ..content.identicalTo(model.contents[j]);
    } else {
      check(model.items[i]).isA<MessageListOutboxMessageItem>()
        .message.identicalTo(model.outboxMessages[j-model.messages.length]);
    }
    check(model.items[i++]).isA<MessageListMessageBaseItem>()
      ..showSender.equals(showSender)
      ..isLastInBlock.equals(
        i == model.items.length || switch (model.items[i]) {
          MessageListMessageItem()
          || MessageListOutboxMessageItem()
          || MessageListDateSeparatorItem() => false,
          MessageListRecipientHeaderItem()  => true,
        });
  }
  check(model.items).length.equals(i);

  check(model).middleItem
    ..isGreaterOrEqual(0)
    ..isLessOrEqual(model.items.length);
  if (model.middleMessage == model.messages.length) {
    if (model.outboxMessages.isEmpty) {
      // the bottom slice of `model.messages` is empty
      check(model).middleItem.equals(model.items.length);
    } else {
      check(model.items[model.middleItem]).isA<MessageListOutboxMessageItem>()
        .message.identicalTo(model.outboxMessages.first);
    }
  } else {
    check(model.items[model.middleItem]).isA<MessageListMessageItem>()
      .message.identicalTo(model.messages[model.middleMessage]);
  }
}

void _checkNoIntersection(List<Message> xs, List<Message> ys, {String? because}) {
  // Both lists are sorted by ID.  As an optimization, bet on all or nearly all
  // of the first list having smaller IDs than all or nearly all of the other.
  if (xs.isEmpty || ys.isEmpty) return;
  if (xs.last.id < ys.first.id) return;
  final yCandidates = Set.of(ys.takeWhile((m) => m.id <= xs.last.id));
  final intersection = xs.reversed.takeWhile((m) => ys.first.id <= m.id)
    .where(yCandidates.contains);
  check(intersection, because: because).isEmpty();
}

extension MessageListRecipientHeaderItemChecks on Subject<MessageListRecipientHeaderItem> {
  Subject<MessageBase> get message => has((x) => x.message, 'message');
}

extension MessageListDateSeparatorItemChecks on Subject<MessageListDateSeparatorItem> {
  Subject<MessageBase> get message => has((x) => x.message, 'message');
}

extension MessageListMessageBaseItemChecks on Subject<MessageListMessageBaseItem> {
  Subject<MessageBase> get message => has((x) => x.message, 'message');
  Subject<ZulipMessageContent> get content => has((x) => x.content, 'content');
  Subject<bool> get showSender => has((x) => x.showSender, 'showSender');
  Subject<bool> get isLastInBlock => has((x) => x.isLastInBlock, 'isLastInBlock');
}

extension MessageListMessageItemChecks on Subject<MessageListMessageItem> {
  Subject<Message> get message => has((x) => x.message, 'message');
}

extension MessageListViewChecks on Subject<MessageListView> {
  Subject<PerAccountStore> get store => has((x) => x.store, 'store');
  Subject<Narrow> get narrow => has((x) => x.narrow, 'narrow');
  Subject<Anchor> get anchor => has((x) => x.anchor, 'anchor');
  Subject<List<Message>> get messages => has((x) => x.messages, 'messages');
  Subject<List<OutboxMessage>> get outboxMessages => has((x) => x.outboxMessages, 'outboxMessages');
  Subject<int> get middleMessage => has((x) => x.middleMessage, 'middleMessage');
  Subject<List<ZulipMessageContent>> get contents => has((x) => x.contents, 'contents');
  Subject<List<MessageListItem>> get items => has((x) => x.items, 'items');
  Subject<int> get middleItem => has((x) => x.middleItem, 'middleItem');
  Subject<bool> get fetched => has((x) => x.fetched, 'fetched');
  Subject<bool> get showingCachedMessages => has((x) => x.showingCachedMessages, 'showingCachedMessages');
  Subject<bool> get fetchInitialFailing => has((x) => x.fetchInitialFailing, 'fetchInitialFailing');
  Subject<int?> get oldestFetchedMessageId => has((x) => x.oldestFetchedMessageId, 'oldestFetchedMessageId');
  Subject<int?> get newestFetchedMessageId => has((x) => x.newestFetchedMessageId, 'newestFetchedMessageId');
  Subject<bool> get haveOldest => has((x) => x.haveOldest, 'haveOldest');
  Subject<bool> get haveNewest => has((x) => x.haveNewest, 'haveNewest');
  Subject<bool> get busyFetchingMore => has((x) => x.busyFetchingMore, 'busyFetchingMore');
}
