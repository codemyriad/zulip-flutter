import 'dart:io';

import 'package:checks/checks.dart';
import 'package:flutter_checks/flutter_checks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:zulip/api/backoff.dart';
import 'package:zulip/api/model/events.dart';
import 'package:zulip/api/model/initial_snapshot.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/api/route/channels.dart';
import 'package:zulip/model/binding.dart';
import 'package:zulip/model/message.dart';
import 'package:zulip/model/message_coverage.dart';
import 'package:zulip/model/narrow.dart';
import 'package:zulip/model/settings.dart';
import 'package:zulip/model/store.dart';
import 'package:zulip/widgets/app_bar.dart';
import 'package:zulip/widgets/banner.dart';
import 'package:zulip/widgets/icons.dart';
import 'package:zulip/widgets/message_list.dart';
import 'package:zulip/widgets/text.dart';
import 'package:zulip/widgets/topic_list.dart';

import '../api/fake_api.dart';
import '../example_data.dart' as eg;
import '../model/binding.dart';
import '../model/test_store.dart';
import '../stdlib_checks.dart';
import 'test_app.dart';

void main() {
  TestZulipBinding.ensureInitialized();

  late PerAccountStore store;
  late FakeApiConnection connection;

  Future<void> prepare(WidgetTester tester, {
    ZulipStream? channel,
    List<GetChannelTopicsEntry>? topics,
    List<UserTopicItem> userTopics = const [],
    List<StreamMessage>? messages,
  }) async {
    addTearDown(testBinding.reset);
    await testBinding.globalStore.add(eg.selfAccount, eg.initialSnapshot());
    store = await testBinding.globalStore.perAccount(eg.selfAccount.id);
    connection = store.connection as FakeApiConnection;

    await store.addUser(eg.selfUser);
    channel ??= eg.stream();
    await store.addStream(channel);
    await store.addSubscription(eg.subscription(channel));
    for (final userTopic in userTopics) {
      await store.setUserTopic(
        channel, userTopic.topicName.apiName, userTopic.visibilityPolicy);
    }
    topics ??= [eg.getChannelTopicsEntry()];
    messages ??= [eg.streamMessage(stream: channel, topic: topics.first.name.apiName)];
    await store.addMessages(messages);

    connection.prepare(json: GetChannelTopicsResult(topics: topics).toJson());
    await tester.pumpWidget(TestZulipApp(
      accountId: eg.selfAccount.id,
      child: TopicListPage(channelId: channel.streamId)));
    await tester.pump();
    await tester.pump(Duration.zero);
    check(connection.takeRequests()).single.isA<http.Request>()
      ..method.equals('GET')
      ..url.path.equals('/api/v1/users/me/${channel.streamId}/topics')
      ..url.queryParameters.deepEquals({'allow_empty_topic_name': 'true'});
  }

  group('app bar', () {
    testWidgets('unknown channel name', (tester) async {
      addTearDown(testBinding.reset);
      await testBinding.globalStore.add(eg.selfAccount, eg.initialSnapshot());
      final store = await testBinding.globalStore.perAccount(eg.selfAccount.id);
      final channel = eg.stream();

      (store.connection as FakeApiConnection).prepare(
        json: GetChannelTopicsResult(topics: []).toJson());
      await tester.pumpWidget(TestZulipApp(
        accountId: eg.selfAccount.id,
        child: TopicListPage(channelId: channel.streamId)));
      await tester.pump();
      await tester.pump(Duration.zero);
      check(find.widgetWithText(ZulipAppBar, '(unknown channel)')).findsOne();
    });

    testWidgets('navigate to channel feed', (tester) async {
      final channel = eg.stream(name: 'channel foo');
      await prepare(tester, channel: channel);

      connection.prepare(json: eg.newestGetMessagesResult(
        foundOldest: true, messages: [eg.streamMessage(stream: channel)]).toJson());
      await tester.tap(find.byIcon(ZulipIcons.message_feed));
      await tester.pump();
      await tester.pump(Duration.zero);
      check(find.descendant(
        of: find.byType(MessageListPage),
        matching: find.text('channel foo')),
      ).findsOne();
    });

    testWidgets('show channel action sheet', (tester) async {
      final channel = eg.stream(name: 'channel foo');
      await prepare(tester, channel: channel,
        messages: [eg.streamMessage(stream: channel)]);

      await tester.longPress(find.text('channel foo'));
      await tester.pump(Duration(milliseconds: 100)); // bottom-sheet animation
      check(find.text('Mark channel as read')).findsOne();
    });
  });

  testWidgets('show loading indicator', (tester) async {
    addTearDown(testBinding.reset);
    await testBinding.globalStore.add(eg.selfAccount, eg.initialSnapshot());
    final store = await testBinding.globalStore.perAccount(eg.selfAccount.id);
    final channel = eg.stream();

    (store.connection as FakeApiConnection).prepare(
      json: GetChannelTopicsResult(topics: []).toJson(),
      delay: Duration(seconds: 1),
    );
    await tester.pumpWidget(TestZulipApp(
      accountId: eg.selfAccount.id,
      child: TopicListPage(channelId: channel.streamId)));
    await tester.pump();
    check(find.byType(CircularProgressIndicator)).findsOne();

    await tester.pump(Duration(seconds: 1));
    check(find.byType(CircularProgressIndicator)).findsNothing();
  });

  testWidgets('shows empty state when no topics', (tester) async {
    final channel = eg.stream();
    await prepare(tester, channel: channel, topics: [], messages: []);
    check(find.text('There are no topics here yet.')).findsOne();
  });

  testWidgets("don't fetch again when navigating away and back", (tester) async {
    addTearDown(testBinding.reset);
    await testBinding.globalStore.add(eg.selfAccount, eg.initialSnapshot());
    final store = await testBinding.globalStore.perAccount(eg.selfAccount.id);
    final connection = store.connection as FakeApiConnection;
    final channel = eg.stream();

    // Start from a message list page in a channel narrow.
    connection.prepare(json: eg.newestGetMessagesResult(
      foundOldest: true, messages: []).toJson());
    await tester.pumpWidget(TestZulipApp(
      accountId: eg.selfAccount.id,
      child: MessageListPage(initNarrow: ChannelNarrow(channel.streamId))));
    await tester.pump();
    connection.takeRequests();

    // Tap "TOPICS" button navigating to the topic-list page…
    connection.prepare(json: GetChannelTopicsResult(
      topics: [eg.getChannelTopicsEntry(name: 'topic A')]).toJson());
    await tester.tap(find.byIcon(ZulipIcons.topics));
    await tester.pump();
    await tester.pump(Duration.zero);
    check(connection.takeRequests()).single.isA<http.Request>()
      ..method.equals('GET')
      ..url.path.equals('/api/v1/users/me/${channel.streamId}/topics');
    check(find.text('topic A')).findsOne();

    // … go back to the message list page…
    await tester.pageBack();
    await tester.pump();

    // … then back to the topic-list page. No new fetch request occurs.
    await tester.tap(find.byIcon(ZulipIcons.topics));
    await tester.pump();
    await tester.pump(Duration.zero);
    check(connection.takeRequests()).isEmpty();
    check(find.text('topic A')).findsOne();
  });

  Finder topicItemFinder = find.descendant(
    of: find.byType(ListView),
    matching: find.byType(Material));

  Finder findInTopicItemAt(int index, Finder finder) => find.descendant(
    of: topicItemFinder.at(index),
    matching: finder);

  InlineIcon checkmarkIconAt(WidgetTester tester, int index) =>
    tester.widget<InlineIcon>(findInTopicItemAt(index, find.byWidgetPredicate(
      (w) => w is InlineIcon && w.icon == ZulipIcons.check)));

  group('while the fetch retries', () {
    // Tests of the model side are in test/model/topics_test.dart.

    final channel = eg.stream();

    final findCantConnect = find.text('Can’t connect. Retrying…');

    final findLoadingIndicator = find.byType(CircularProgressIndicator);

    /// Open the topic list for [channel], with a fetch that fails
    /// and will be retried after a backoff of 10 seconds;
    /// see [retryFetch].
    Future<void> setupRetrying(WidgetTester tester) async {
      addTearDown(testBinding.reset);
      BackoffMachine.debugDuration = const Duration(seconds: 10);
      addTearDown(() => BackoffMachine.debugDuration = null);
      await testBinding.globalStore.add(eg.selfAccount, eg.initialSnapshot(
        streams: [channel], subscriptions: [eg.subscription(channel)]));
      store = await testBinding.globalStore.perAccount(eg.selfAccount.id);
      connection = store.connection as FakeApiConnection;
      await store.addUser(eg.selfUser);

      connection.prepare(httpException: const SocketException('failed'));
      await tester.pumpWidget(TestZulipApp(accountId: eg.selfAccount.id,
        child: TopicListPage(channelId: channel.streamId)));
      await tester.pump(); // global store, per-account store
      await tester.pump(Duration.zero); // fetch fails
      check(connection.takeRequests()).single;
    }

    Future<void> retryFetch(WidgetTester tester) async {
      await tester.pump(BackoffMachine.debugDuration);
    }

    void prepareFreshFetch(List<GetChannelTopicsEntry> topics) {
      connection.prepare(json: GetChannelTopicsResult(topics: topics).toJson());
    }

    testWidgets('"can\'t connect" without spinner, until fetch succeeds', (tester) async {
      await setupRetrying(tester);
      check(findLoadingIndicator).findsNothing();
      check(findCantConnect).findsOne();

      connection.prepare(httpException: const SocketException('failed'));
      await retryFetch(tester);
      check(connection.takeRequests()).single;
      check(findLoadingIndicator).findsNothing();
      check(findCantConnect).findsOne();

      prepareFreshFetch([eg.getChannelTopicsEntry(name: 'fresh topic')]);
      await retryFetch(tester);
      check(connection.takeRequests()).single;
      check(findLoadingIndicator).findsNothing();
      check(findCantConnect).findsNothing();
      check(find.text('fresh topic')).findsOne();
    });

    testWidgets('airplane mode hides spinner while initial fetch is in flight', (tester) async {
      addTearDown(testBinding.reset);
      await testBinding.globalStore.add(eg.selfAccount, eg.initialSnapshot(
        streams: [channel], subscriptions: [eg.subscription(channel)]));
      store = await testBinding.globalStore.perAccount(eg.selfAccount.id);
      connection = store.connection as FakeApiConnection;
      await store.addUser(eg.selfUser);

      connection.prepare(
        delay: const Duration(seconds: 1),
        json: GetChannelTopicsResult(
          topics: [eg.getChannelTopicsEntry(name: 'fresh topic')],
        ).toJson(),
      );
      await tester.pumpWidget(TestZulipApp(accountId: eg.selfAccount.id,
        child: TopicListPage(channelId: channel.streamId)));
      await tester.pump();
      check(findLoadingIndicator).findsOne();
      check(findCantConnect).findsNothing();

      testBinding.notifyConnectivityChanged([ConnectivityResult.none]);
      await tester.pump();
      check(findLoadingIndicator).findsNothing();
      check(findCantConnect).findsOne();

      await tester.pump(const Duration(seconds: 1));
      check(findLoadingIndicator).findsNothing();
      check(findCantConnect).findsNothing();
      check(find.text('fresh topic')).findsOne();
    });

    testWidgets('page closed during backoff: no retry', (tester) async {
      await setupRetrying(tester);

      await tester.pumpWidget(const SizedBox.shrink());
      await retryFetch(tester);
      check(connection.takeRequests()).isEmpty();
    });

    testWidgets('store replaced during backoff: fetch on the new store only', (tester) async {
      await setupRetrying(tester);

      FakeApiConnection? newConnection;
      void prepareNewStore() {
        final newStore = testBinding.globalStore.perAccountSync(eg.selfAccount.id);
        if (newStore == null || newStore == store || newConnection != null) return;
        newConnection = newStore.connection as FakeApiConnection;
        newConnection!.prepare(json: GetChannelTopicsResult(
          topics: [eg.getChannelTopicsEntry(name: 'fresh topic')]).toJson());
      }
      testBinding.globalStore.addListener(prepareNewStore);
      addTearDown(() => testBinding.globalStore.removeListener(prepareNewStore));

      final updateMachine = store.updateMachine!;
      updateMachine.debugPauseLoop();
      updateMachine.poll();
      updateMachine.debugPrepareLoopError(
        eg.apiExceptionBadEventQueueId(queueId: store.queueId));
      updateMachine.debugAdvanceLoop();
      await tester.pump();
      await tester.pump(Duration.zero);
      final newStore = testBinding.globalStore.perAccountSync(eg.selfAccount.id)!;
      check(newStore).not((it) => it.identicalTo(store));
      check(newConnection!.takeRequests()).single;
      check(find.text('fresh topic')).findsOne();
      check(findCantConnect).findsNothing();

      // The old view never retries,
      // which would be a request on the old, closed connection.
      await retryFetch(tester);
      check(connection.takeRequests()).isEmpty();
    });

    testWidgets('shows saved topics banner offline with coverage enabled, hides on live fetch', (tester) async {
      addTearDown(testBinding.reset);
      BackoffMachine.debugDuration = const Duration(seconds: 10);
      addTearDown(() => BackoffMachine.debugDuration = null);
      await testBinding.globalStore.settings.setBool(BoolGlobalSetting.messageDatabase, true);
      await testBinding.globalStore.add(eg.selfAccount, eg.initialSnapshot(
        streams: [channel], subscriptions: [eg.subscription(channel)]));
      store = await testBinding.globalStore.perAccount(eg.selfAccount.id);
      connection = store.connection as FakeApiConnection;
      await store.addUser(eg.selfUser);
      store.debugSetCoverageEnabled(true);
      await store.handleEvent(MessageEvent(
        id: 1,
        localMessageId: null,
        message: eg.streamMessage(id: 50, stream: channel, topic: 'saved topic', sender: eg.selfUser),
      ));

      connection.prepare(httpException: const SocketException('failed'));
      await tester.pumpWidget(TestZulipApp(accountId: eg.selfAccount.id,
        child: TopicListPage(channelId: channel.streamId)));
      await tester.pump();
      await tester.pump(Duration.zero);

      check(find.byType(ZulipBanner)).findsOne();
      check(find.text('Topics with messages saved on this device')).findsOne();
      check(find.text('saved topic')).findsOne();
      check(findCantConnect).findsNothing();

      prepareFreshFetch([eg.getChannelTopicsEntry(name: 'fresh topic')]);
      await retryFetch(tester);
      await tester.pump(Duration.zero);
      check(find.byType(ZulipBanner)).findsNothing();
      check(find.text('fresh topic')).findsOne();
    });

    testWidgets('shows saved topics banner offline even when saved topic list is empty', (tester) async {
      addTearDown(testBinding.reset);
      BackoffMachine.debugDuration = const Duration(seconds: 10);
      addTearDown(() => BackoffMachine.debugDuration = null);
      await testBinding.globalStore.settings.setBool(BoolGlobalSetting.messageDatabase, true);
      await testBinding.globalStore.add(eg.selfAccount, eg.initialSnapshot(
        streams: [channel], subscriptions: [eg.subscription(channel)]));
      store = await testBinding.globalStore.perAccount(eg.selfAccount.id);
      connection = store.connection as FakeApiConnection;
      await store.addUser(eg.selfUser);
      store.debugSetCoverageEnabled(true);
      final ticket = store.openFetchTicket(channelId: channel.streamId);
      try {
        store.reconcileMessages(
          <Message>[],
          ticket: ticket,
          coverageRequest: FetchCoverageRequest(
            narrow: ChannelNarrow(channel.streamId),
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
        store.closeFetchTicket(ticket);
      }

      connection.prepare(httpException: const SocketException('failed'));
      await tester.pumpWidget(TestZulipApp(accountId: eg.selfAccount.id,
        child: TopicListPage(channelId: channel.streamId)));
      await tester.pump();
      await tester.pump(Duration.zero);

      check(find.byType(ZulipBanner)).findsOne();
      check(find.text('Topics with messages saved on this device')).findsOne();
      check(find.text('There are no topics here yet.')).findsOne();
      check(findCantConnect).findsNothing();
    });

    testWidgets('store replaced preserves saved topics under banner until fresh fetch completes', (tester) async {
      addTearDown(testBinding.reset);
      BackoffMachine.debugDuration = const Duration(seconds: 10);
      addTearDown(() => BackoffMachine.debugDuration = null);
      await testBinding.globalStore.settings.setBool(BoolGlobalSetting.messageDatabase, true);
      await testBinding.globalStore.add(eg.selfAccount, eg.initialSnapshot(
        streams: [channel], subscriptions: [eg.subscription(channel)]));
      store = await testBinding.globalStore.perAccount(eg.selfAccount.id);
      connection = store.connection as FakeApiConnection;
      await store.addUser(eg.selfUser);
      store.debugSetCoverageEnabled(true);
      await store.handleEvent(MessageEvent(
        id: 1,
        localMessageId: null,
        message: eg.streamMessage(id: 50, stream: channel, topic: 'saved topic', sender: eg.selfUser),
      ));

      connection.prepare(httpException: const SocketException('failed'));
      await tester.pumpWidget(TestZulipApp(accountId: eg.selfAccount.id,
        child: TopicListPage(channelId: channel.streamId)));
      await tester.pump();
      await tester.pump(Duration.zero);
      check(find.text('saved topic')).findsOne();
      check(find.byType(ZulipBanner)).findsOne();

      FakeApiConnection? newConnection;
      void prepareNewStore() {
        final newStore = testBinding.globalStore.perAccountSync(eg.selfAccount.id);
        if (newStore == null || newStore == store || newConnection != null) return;
        newStore.debugSetCoverageEnabled(true);
        newConnection = newStore.connection as FakeApiConnection;
        newConnection!.prepare(
          delay: const Duration(seconds: 2),
          json: GetChannelTopicsResult(
            topics: [eg.getChannelTopicsEntry(name: 'reloaded topic')]).toJson(),
        );
      }
      testBinding.globalStore.addListener(prepareNewStore);
      addTearDown(() => testBinding.globalStore.removeListener(prepareNewStore));

      final updateMachine = store.updateMachine!;
      updateMachine.debugPauseLoop();
      updateMachine.poll();
      updateMachine.debugPrepareLoopError(
        eg.apiExceptionBadEventQueueId(queueId: store.queueId));
      updateMachine.debugAdvanceLoop();
      await tester.pump();
      await tester.pump(Duration.zero);

      // Still showing previous saved topics under the banner while new fetch is in flight.
      check(find.text('saved topic')).findsOne();
      check(find.byType(ZulipBanner)).findsOne();
      check(findLoadingIndicator).findsNothing();

      await tester.pump(const Duration(seconds: 2));
      check(find.text('reloaded topic')).findsOne();
      check(find.byType(ZulipBanner)).findsNothing();
    });
  });

  testWidgets('sort topics by maxId', (tester) async {
    await prepare(tester, topics: [
      eg.getChannelTopicsEntry(name: 'A', maxId: 3),
      eg.getChannelTopicsEntry(name: 'B', maxId: 2),
      eg.getChannelTopicsEntry(name: 'C', maxId: 4),
    ]);

    check(findInTopicItemAt(0, find.text('C'))).findsOne();
    check(findInTopicItemAt(1, find.text('A'))).findsOne();
    check(findInTopicItemAt(2, find.text('B'))).findsOne();
  });

  testWidgets('show topic action sheet', (tester) async {
    final channel = eg.stream();
    await prepare(tester, channel: channel,
      topics: [eg.getChannelTopicsEntry(name: 'topic foo')]);
    await tester.longPress(topicItemFinder);
    await tester.pump(Duration(milliseconds: 150)); // bottom-sheet animation

    connection.prepare(json: {});
    await tester.tap(find.text('Mute topic'));
    await tester.pump();
    await tester.pump(Duration.zero);
    check(connection.takeRequests()).single.isA<http.Request>()
      ..method.equals('POST')
      ..url.path.equals('/api/v1/user_topics')
      ..bodyFields.deepEquals({
        'stream_id': channel.streamId.toString(),
        'topic': 'topic foo',
        'visibility_policy': UserTopicVisibilityPolicy.muted.apiValue.toString(),
      });
  });

  testWidgets('topic action sheet before and after moves', (tester) async {
    final channel = eg.stream();
    final message = eg.streamMessage(id: 100, stream: channel, topic: 'foo');
    await prepare(tester, channel: channel,
      topics: [eg.getChannelTopicsEntry(name: 'foo', maxId: 100)],
      messages: [message]);
    check(topicItemFinder).findsOne();

    // Before the move, "foo"'s maxId is known to be accurate. This makes
    // topic actions that require `someMessageIdInTopic` available.
    await tester.longPress(find.text('foo'));
    await tester.pump(Duration(milliseconds: 150)); // bottom-sheet animation
    check(find.text('Mark as resolved')).findsOne();
    await tester.tap(find.text('Cancel'));

    await store.handleEvent(eg.updateMessageEventMoveFrom(
      origMessages: [message],
      newTopicStr: 'bar'));
    await tester.pump();
    check(topicItemFinder).findsExactly(2);

    // After the move, the message with maxId moved away from "foo". The topic
    // actions that require `someMessageIdInTopic` are no longer available.
    await tester.longPress(find.text('foo'));
    await tester.pump(Duration(milliseconds: 150)); // bottom-sheet animation
    check(find.text('Mark as resolved')).findsNothing();
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    // Topic actions that require `someMessageIdInTopic` are available
    // for "bar", the new topic that the message moved to.
    await tester.longPress(find.text('bar'));
    await tester.pump(Duration(milliseconds: 150)); // bottom-sheet animation
    check(find.text('Mark as resolved')).findsOne();
  });

  testWidgets('topic action sheet hides resolve when maxId message is maybe-stale', (tester) async {
    final channel = eg.stream();
    final message = eg.streamMessage(id: 100, stream: channel, topic: 'foo');
    await prepare(tester, channel: channel,
      topics: [eg.getChannelTopicsEntry(name: 'foo', maxId: 100)],
      messages: [message]);
    check(topicItemFinder).findsOne();

    await store.handleEvent(SubscriptionRemoveEvent(
      id: 1, channelIds: [channel.streamId]));
    await tester.pump();
    check(store.isLocationReliable(message.id)).isFalse();

    await tester.longPress(find.text('foo'));
    await tester.pump(Duration(milliseconds: 150)); // bottom-sheet animation
    check(find.text('Mark as resolved')).findsNothing();
    check(find.text('Mark as unresolved')).findsNothing();
    check(find.text('Copy link to topic')).findsOne();
  });

  // event handling is more thoroughly tested in test/model/channel_test.dart
  testWidgets('smoke resolve topic from topic action sheet', (tester) async {
    final channel = eg.stream();
    final messages = List.generate(10, (i) =>
      eg.streamMessage(id: 100 + i, stream: channel, topic: 'foo'));

    await prepare(tester, channel: channel,
      topics: [eg.getChannelTopicsEntry(maxId: 109, name: 'foo')],
      messages: messages);

    await tester.longPress(topicItemFinder);
    await tester.pump(Duration(milliseconds: 150)); // bottom-sheet animation
    check(checkmarkIconAt(tester, 0).visible).isFalse();
    check(findInTopicItemAt(0, find.text('foo'))).findsOne();

    connection.prepare(json: {});
    await tester.tap(find.text('Mark as resolved'));
    await tester.pump();
    await tester.pump(Duration.zero);

    await store.handleEvent(eg.updateMessageEventMoveFrom(
      origMessages: messages,
      newTopic: eg.t('foo').resolve(),
      propagateMode: .changeAll));
    await tester.pump();
    check(checkmarkIconAt(tester, 0).visible).isTrue();
    check(findInTopicItemAt(0, find.text('foo'))).findsOne();
  });

  testWidgets('resolved and unresolved topics', (tester) async {
    final resolvedTopic = TopicName('resolved').resolve();
    final unresolvedTopic = TopicName('unresolved');
    await prepare(tester, topics: [
      eg.getChannelTopicsEntry(maxId: 2, name: resolvedTopic.apiName),
      eg.getChannelTopicsEntry(maxId: 1, name: unresolvedTopic.apiName),
    ]);

    assert(resolvedTopic.displayName == '✔ resolved', resolvedTopic.displayName);
    check(findInTopicItemAt(0, find.text('✔ resolved'))).findsNothing();

    check(findInTopicItemAt(0, find.text('resolved'))).findsOne();
    check(checkmarkIconAt(tester, 0).visible).isTrue();

    check(findInTopicItemAt(1, find.text('unresolved'))).findsOne();
    check(checkmarkIconAt(tester, 1).visible).isFalse();
  });

  testWidgets('handle empty topics', (tester) async {
    await prepare(tester, topics: [
      eg.getChannelTopicsEntry(name: ''),
    ]);
    check(findInTopicItemAt(0,
      find.text(eg.defaultRealmEmptyTopicDisplayName))).findsOne();
  });

  group('unreads', () {
    testWidgets('muted and non-muted topics', (tester) async {
      final channel = eg.stream();
      await prepare(tester, channel: channel,
        topics: [
          eg.getChannelTopicsEntry(maxId: 2, name: 'muted'),
          eg.getChannelTopicsEntry(maxId: 1, name: 'non-muted'),
        ],
        userTopics: [
          eg.userTopicItem(channel, 'muted', UserTopicVisibilityPolicy.muted),
        ],
        messages: [
          eg.streamMessage(stream: channel, topic: 'muted'),
          eg.streamMessage(stream: channel, topic: 'non-muted'),
          eg.streamMessage(stream: channel, topic: 'non-muted'),
        ]);

      check(findInTopicItemAt(0, find.text('1'))).findsOne();
      check(findInTopicItemAt(0, find.text('muted'))).findsOne();
      check(findInTopicItemAt(0, find.byIcon(ZulipIcons.mute).hitTestable()))
        .findsOne();

      check(findInTopicItemAt(1, find.text('2'))).findsOne();
      check(findInTopicItemAt(1, find.text('non-muted'))).findsOne();
      check(findInTopicItemAt(1, find.byType(Icon).hitTestable()))
        .findsNothing();
    });

    testWidgets('with and without unread mentions', (tester) async {
      final channel = eg.stream();
      await prepare(tester, channel: channel,
        topics: [
          eg.getChannelTopicsEntry(maxId: 2, name: 'not mentioned'),
          eg.getChannelTopicsEntry(maxId: 1, name: 'mentioned'),
        ],
        messages: [
          eg.streamMessage(stream: channel, topic: 'not mentioned'),
          eg.streamMessage(stream: channel, topic: 'not mentioned'),
          eg.streamMessage(stream: channel, topic: 'not mentioned',
            flags: [MessageFlag.mentioned, MessageFlag.read]),
          eg.streamMessage(stream: channel, topic: 'mentioned',
            flags: [MessageFlag.mentioned]),
        ]);

      check(findInTopicItemAt(0, find.text('2'))).findsOne();
      check(findInTopicItemAt(0, find.text('not mentioned'))).findsOne();
      check(findInTopicItemAt(0, find.byType(Icons))).findsNothing();

      check(findInTopicItemAt(1, find.text('1'))).findsOne();
      check(findInTopicItemAt(1, find.text('mentioned'))).findsOne();
      check(findInTopicItemAt(1, find.byIcon(ZulipIcons.at_sign))).findsOne();
    });
  });

  group('topic visibility', () {
    testWidgets('default', (tester) async {
      final channel = eg.stream();
      await prepare(tester, channel: channel,
        topics: [eg.getChannelTopicsEntry(name: 'topic')]);

      check(find.descendant(of: topicItemFinder,
        matching: find.byType(Icons))).findsNothing();
    });

    testWidgets('muted', (tester) async {
      final channel = eg.stream();
      await prepare(tester, channel: channel,
        topics: [eg.getChannelTopicsEntry(name: 'topic')],
        userTopics: [
          eg.userTopicItem(channel, 'topic', UserTopicVisibilityPolicy.muted),
        ]);
      check(find.descendant(of: topicItemFinder,
        matching: find.byIcon(ZulipIcons.mute))).findsOne();
    });

    testWidgets('unmuted', (tester) async {
      final channel = eg.stream();
      await prepare(tester, channel: channel,
        topics: [eg.getChannelTopicsEntry(name: 'topic')],
        userTopics: [
          eg.userTopicItem(channel, 'topic', UserTopicVisibilityPolicy.unmuted),
        ]);
      check(find.descendant(of: topicItemFinder,
        matching: find.byIcon(ZulipIcons.unmute))).findsOne();
    });

    testWidgets('followed', (tester) async {
      final channel = eg.stream();
      await prepare(tester, channel: channel,
        topics: [eg.getChannelTopicsEntry(name: 'topic')],
        userTopics: [
          eg.userTopicItem(channel, 'topic', UserTopicVisibilityPolicy.followed),
        ]);
      check(find.descendant(of: topicItemFinder,
        matching: find.byIcon(ZulipIcons.follow))).findsOne();
    });
  });
}
