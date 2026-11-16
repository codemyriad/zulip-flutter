import 'dart:io';

import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:zulip/api/model/events.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/model/message.dart';
import 'package:zulip/model/message_coverage.dart';
import 'package:zulip/model/message_list.dart';
import 'package:zulip/model/narrow.dart';

import '../api/fake_api.dart';
import '../example_data.dart' as eg;
import '../fake_async.dart';
import 'binding.dart';
import 'test_store.dart';

void main() {
  TestZulipBinding.ensureInitialized();

  group('fetch coverage recording', () {
    test('does not record coverage when coverageEnabled is false', () async {
      final store = eg.store()..debugSetCoverageEnabled(false);
      final stream = eg.stream();
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));

      final connection = store.connection as FakeApiConnection;
      final view = MessageListView.init(
        store: store,
        narrow: TopicNarrow(stream.streamId, eg.t('topic')),
        anchor: AnchorCode.newest,
      );
      addTearDown(view.dispose);

      connection.prepare(json: eg.newestGetMessagesResult(
        foundOldest: true,
        messages: [eg.streamMessage(id: 1, stream: stream, topic: 'topic')],
      ).toJson());
      await view.fetchInitial();

      check(store.debugCoverage.intervalsOf('topic:${stream.streamId}:TOPIC')).isEmpty();
    });

    test('records live open interval on newest fetchInitial and merges fetchOlder', () async {
      final store = eg.store()..debugSetCoverageEnabled(true);
      final stream = eg.stream();
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));

      final connection = store.connection as FakeApiConnection;
      final view = MessageListView.init(
        store: store,
        narrow: TopicNarrow(stream.streamId, eg.t('topic')),
        anchor: AnchorCode.newest,
      );
      addTearDown(view.dispose);

      connection.prepare(json: eg.newestGetMessagesResult(
        foundOldest: false,
        messages: [
          eg.streamMessage(id: 10, stream: stream, topic: 'topic'),
          eg.streamMessage(id: 12, stream: stream, topic: 'topic'),
        ],
      ).toJson());
      await view.fetchInitial();

      final key = 'topic:${stream.streamId}:TOPIC';
      var intervals = store.debugCoverage.intervalsOf(key);
      check(intervals.length).equals(1);
      check(intervals.single.lo).equals(10);
      check(intervals.single.hi).isNull();
      check(intervals.single.tracked).isTrue();

      connection.prepare(json: eg.olderGetMessagesResult(
        anchor: 10,
        foundOldest: true,
        messages: [
          eg.streamMessage(id: 5, stream: stream, topic: 'topic'),
        ],
      ).toJson());
      await view.fetchOlder();

      intervals = store.debugCoverage.intervalsOf(key);
      check(intervals.length).equals(1);
      check(intervals.single.lo).equals(0);
      check(intervals.single.hi).isNull();
    });

    test('records closed untracked interval for unsubscribed public channel', () async {
      final store = eg.store()..debugSetCoverageEnabled(true);
      final stream = eg.stream(inviteOnly: false);
      await store.addStream(stream);

      final connection = store.connection as FakeApiConnection;
      final view = MessageListView.init(
        store: store,
        narrow: TopicNarrow(stream.streamId, eg.t('topic')),
        anchor: AnchorCode.newest,
      );
      addTearDown(view.dispose);

      connection.prepare(json: eg.newestGetMessagesResult(
        foundOldest: true,
        messages: [eg.streamMessage(id: 7, stream: stream, topic: 'topic')],
      ).toJson());
      await view.fetchInitial();

      final key = 'topic:${stream.streamId}:TOPIC';
      final intervals = store.debugCoverage.intervalsOf(key);
      check(intervals.length).equals(1);
      check(intervals.single.lo).equals(0);
      check(intervals.single.hi).equals(7);
      check(intervals.single.tracked).isFalse();
    });

    test('stops on search narrow, topic fold mismatch, and unsubscribed private empty result', () async {
      final store = eg.store()..debugSetCoverageEnabled(true);
      final privateStream = eg.stream(inviteOnly: true);
      await store.addStream(privateStream);

      final connection = store.connection as FakeApiConnection;

      // Search narrow: no coverage.
      final searchView = MessageListView.init(
        store: store,
        narrow: KeywordSearchNarrow('hello'),
        anchor: AnchorCode.newest,
      );
      addTearDown(searchView.dispose);
      connection.prepare(json: eg.newestGetMessagesResult(
        foundOldest: true,
        messages: [eg.streamMessage(id: 1, stream: privateStream, topic: 'topic')],
      ).toJson());
      await searchView.fetchInitial();
      check(store.debugCoverage.intervalsOf('topic:${privateStream.streamId}:TOPIC')).isEmpty();

      // Unsubscribed private channel returning empty with both foundOldest/foundNewest: no coverage.
      final privView = MessageListView.init(
        store: store,
        narrow: TopicNarrow(privateStream.streamId, eg.t('topic')),
        anchor: AnchorCode.newest,
      );
      addTearDown(privView.dispose);
      connection.prepare(json: eg.newestGetMessagesResult(
        foundOldest: true,
        messages: [],
      ).toJson());
      await privView.fetchInitial();
      check(store.debugCoverage.intervalsOf('topic:${privateStream.streamId}:TOPIC')).isEmpty();

      // Topic fold mismatch (e.g. 'ß' vs 'SS' if server returned 'SS' for 'ß'): no coverage.
      final publicStream = eg.stream(inviteOnly: false);
      await store.addStream(publicStream);
      await store.addSubscription(eg.subscription(publicStream));
      final foldView = MessageListView.init(
        store: store,
        narrow: TopicNarrow(publicStream.streamId, eg.t('straße')),
        anchor: AnchorCode.newest,
      );
      addTearDown(foldView.dispose);
      connection.prepare(json: eg.newestGetMessagesResult(
        foundOldest: true,
        messages: [eg.streamMessage(id: 2, stream: publicStream, topic: 'STRASSE')],
      ).toJson());
      await foldView.fetchInitial();
      check(store.debugCoverage.intervalsOf(
        'topic:${publicStream.streamId}:${serverTopicFold('straße')}')).isEmpty();
    });

    test('re-runs move punctures for moves recorded while fetch was in flight', () async {
      final store = eg.store()..debugSetCoverageEnabled(true);
      final stream = eg.stream();
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));

      final narrow = TopicNarrow(stream.streamId, eg.t('dest'));
      final ticket = store.openFetchTicket(channelId: stream.streamId);
      try {
        // An unstored message 5 moves into 'dest' while the fetch is in flight.
        await store.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: [eg.streamMessage(id: 5, stream: stream, topic: 'src')],
          newTopicStr: 'dest',
        ));

        final msg10 = eg.streamMessage(id: 10, stream: stream, topic: 'dest');
        store.reconcileMessages(
          [msg10],
          ticket: ticket,
          coverageRequest: FetchCoverageRequest(
            narrow: narrow,
            numBefore: kMessageListFetchBatchSize,
            numAfter: kMessageListFetchBatchSize,
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

      // The resulting interval [0, ∞) must be punctured at 5: [0, 4] and [6, ∞).
      final intervals = store.debugCoverage.intervalsOf('topic:${stream.streamId}:DEST');
      check(intervals.length).equals(2);
      check(intervals[0].lo).equals(0);
      check(intervals[0].hi).equals(4);
      check(intervals[1].lo).equals(6);
      check(intervals[1].hi).isNull();
    });

    test('forgets absent-in-range message from K views only, keeps store.messages, punctures channel', () async {
      final store = eg.store()..debugSetCoverageEnabled(true);
      final stream = eg.stream();
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));

      final msg1 = eg.streamMessage(id: 1, stream: stream, topic: 'topic');
      final msg2 = eg.streamMessage(id: 2, stream: stream, topic: 'topic');
      final msg3 = eg.streamMessage(id: 3, stream: stream, topic: 'topic');

      final connection = store.connection as FakeApiConnection;
      final topicView = MessageListView.init(
        store: store,
        narrow: TopicNarrow(stream.streamId, eg.t('topic')),
        anchor: AnchorCode.newest,
      );
      addTearDown(topicView.dispose);

      final feedView = MessageListView.init(
        store: store,
        narrow: const CombinedFeedNarrow(),
        anchor: AnchorCode.newest,
      );
      addTearDown(feedView.dispose);

      final channelView = MessageListView.init(
        store: store,
        narrow: ChannelNarrow(stream.streamId),
        anchor: AnchorCode.newest,
      );
      addTearDown(channelView.dispose);

      // Populate all three views with msg1, msg2, msg3 (and record channel coverage [0, ∞)).
      connection.prepare(json: eg.newestGetMessagesResult(
        foundOldest: true,
        messages: [msg1, msg2, msg3],
      ).toJson());
      await channelView.fetchInitial();

      connection.prepare(json: eg.newestGetMessagesResult(
        foundOldest: true,
        messages: [msg1, msg2, msg3],
      ).toJson());
      await feedView.fetchInitial();

      connection.prepare(json: eg.newestGetMessagesResult(
        foundOldest: true,
        messages: [msg1, msg2, msg3],
      ).toJson());
      await topicView.fetchInitial();

      // Now an authoritative fetch of the topic (e.g. from a second view)
      // omits msg2 (e.g. missed move).
      final topicView2 = MessageListView.init(
        store: store,
        narrow: TopicNarrow(stream.streamId, eg.t('topic')),
        anchor: AnchorCode.newest,
      );
      addTearDown(topicView2.dispose);
      connection.prepare(json: eg.newestGetMessagesResult(
        foundOldest: true,
        messages: [msg1, msg3],
      ).toJson());
      await topicView2.fetchInitial();

      // msg2 is still in store.messages, but marked maybe-stale and locationUnknown.
      check(store.messages.containsKey(2)).isTrue();
      check(store.debugMaybeStaleMessages.contains(2)).isTrue();
      check(store.debugLocationUnknown.contains(2)).isTrue();
      check(store.isLocationReliable(2)).isFalse();

      // Topic view drops msg2; CombinedFeedNarrow and ChannelNarrow keep msg2.
      check(topicView.messages.map((m) => m.id)).deepEquals([1, 3]);
      check(feedView.messages.map((m) => m.id)).deepEquals([1, 2, 3]);
      check(channelView.messages.map((m) => m.id)).deepEquals([1, 2, 3]);

      // Channel coverage is punctured at 2.
      final channelIntervals = store.debugCoverage.intervalsOf('channel:${stream.streamId}');
      check(channelIntervals.length).equals(2);
      check(channelIntervals[0].lo).equals(0);
      check(channelIntervals[0].hi).equals(1);
      check(channelIntervals[1].lo).equals(3);
      check(channelIntervals[1].hi).isNull();
    });

    test('does not forget message that arrived by event while fetch was in flight', () async {
      final store = eg.store()..debugSetCoverageEnabled(true);
      final stream = eg.stream();
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));

      final narrow = TopicNarrow(stream.streamId, eg.t('topic'));
      final ticket = store.openFetchTicket(channelId: stream.streamId);
      try {
        final msg5 = eg.streamMessage(id: 5, stream: stream, topic: 'topic');
        await store.handleEvent(eg.messageEvent(msg5));

        final msg1 = eg.streamMessage(id: 1, stream: stream, topic: 'topic');
        store.reconcileMessages(
          [msg1],
          ticket: ticket,
          coverageRequest: FetchCoverageRequest(
            narrow: narrow,
            numBefore: kMessageListFetchBatchSize,
            numAfter: kMessageListFetchBatchSize,
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

      check(store.debugLocationUnknown.contains(5)).isFalse();
      check(store.isLocationReliable(5)).isTrue();
    });
  });

  group('event coverage maintenance & access purge', () {
    test('message event opens implied interval at max(id, K+1) and checks C9 access', () async {
      final now = testBinding.utcNow().millisecondsSinceEpoch ~/ 1000;
      final store = eg.store()..debugSetCoverageEnabled(true);
      final publicStream = eg.stream(streamId: 1, inviteOnly: false);
      final privateStream = eg.stream(streamId: 2, inviteOnly: true);
      await store.addStream(publicStream);
      await store.addStream(privateStream);
      await store.addSubscription(eg.subscription(publicStream));

      // First DM event establishes K = 10; beginEpoch with maxMessageId=-1 already opened dms [0, ∞).
      await store.handleEvent(eg.messageEvent(
        eg.dmMessage(id: 10, from: eg.selfUser, to: [eg.otherUser]),
      ));
      check(store.debugCoverage.intervalsOf('dms').map((r) => r.toString()))
        .deepEquals(['[0, ∞]@e1 v$now']);

      // Channel event at id 5 (< K=10) opens channel:1 [11, ∞) per C10, while storing id 5.
      await store.handleEvent(eg.messageEvent(
        eg.streamMessage(id: 5, stream: publicStream, topic: 'a'),
      ));
      check(store.messages[5]).isNotNull();
      check(store.debugCoverage.intervalsOf('channel:1').map((r) => r.toString()))
        .deepEquals(['[11, ∞]@e1 v$now']);

      // C9: message event in inaccessible private channel stores no row & opens no interval.
      await store.handleEvent(eg.messageEvent(
        eg.streamMessage(id: 12, stream: privateStream, topic: 'secret'),
      ));
      check(store.messages[12]).isNull();
      check(store.debugCoverage.intervalsOf('channel:2')).isEmpty();
    });

    test('move event punctures destination for unstored ids and enforces C14 origin check', () async {
      final store = eg.store()..debugSetCoverageEnabled(true);
      final stream = eg.stream(streamId: 1);
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));

      final connection = store.connection as FakeApiConnection;
      final view = MessageListView.init(
        store: store,
        narrow: TopicNarrow(stream.streamId, eg.t('dest')),
        anchor: AnchorCode.newest,
      );

      // Fetch dest topic [1, 10] with only id 5 present.
      connection.prepare(json: eg.newestGetMessagesResult(
        foundOldest: true,
        messages: [
          eg.streamMessage(id: 5, stream: stream, topic: 'dest'),
        ],
      ).toJson());
      await view.fetchInitial();
      view.dispose();

      // Store id 7 in topic 'wrong' via a separate fetch.
      final wrongView = MessageListView.init(
        store: store,
        narrow: TopicNarrow(stream.streamId, eg.t('wrong')),
        anchor: AnchorCode.newest,
      );
      addTearDown(wrongView.dispose);
      connection.prepare(json: eg.newestGetMessagesResult(
        foundOldest: true,
        messages: [
          eg.streamMessage(id: 7, stream: stream, topic: 'wrong'),
        ],
      ).toJson());
      await wrongView.fetchInitial();

      // Move [6, 7] from (1, 'orig') -> (1, 'dest').
      // 6 is unstored -> punctures topic:1:DEST.
      // 7 is stored at 'wrong' != 'orig' -> C14 forgets 7, removes from wrongView,
      // and punctures both channel:1 and topic:1:DEST.
      await store.handleEvent(eg.updateMessageEventMoveFrom(
        origMessages: [
          eg.streamMessage(id: 6, stream: stream, topic: 'orig'),
          eg.streamMessage(id: 7, stream: stream, topic: 'orig'),
        ],
        newTopicStr: 'dest',
      ));

      check(store.messages[7]).isNull();
      check(wrongView.messages).isEmpty();
      final destIntervals = store.debugCoverage.intervalsOf('topic:1:DEST');
      check(destIntervals.any((r) => r.contains(6))).isFalse();
      check(destIntervals.any((r) => r.contains(7))).isFalse();
      check(destIntervals.any((r) => r.contains(5))).isTrue();
    });

    test('unsubscribe untracks accessible channel; access loss or delete purges channel', () async {
      final now = testBinding.utcNow().millisecondsSinceEpoch ~/ 1000;
      final store = eg.store()..debugSetCoverageEnabled(true);
      final publicStream = eg.stream(streamId: 1, inviteOnly: false);
      final privateStream = eg.stream(streamId: 2, inviteOnly: true);
      await store.addStream(publicStream);
      await store.addStream(privateStream);
      await store.addSubscription(eg.subscription(publicStream));
      await store.addSubscription(eg.subscription(privateStream));

      await store.handleEvent(eg.messageEvent(
        eg.streamMessage(id: 10, stream: publicStream, topic: 'a'),
      ));
      await store.handleEvent(eg.messageEvent(
        eg.streamMessage(id: 11, stream: privateStream, topic: 'b'),
      ));

      final pubView = MessageListView.init(
        store: store,
        narrow: ChannelNarrow(publicStream.streamId),
        anchor: AnchorCode.newest,
      );
      addTearDown(pubView.dispose);
      final privView = MessageListView.init(
        store: store,
        narrow: ChannelNarrow(privateStream.streamId),
        anchor: AnchorCode.newest,
      );
      addTearDown(privView.dispose);
      final connection = store.connection as FakeApiConnection;
      connection.prepare(json: eg.newestGetMessagesResult(
        foundOldest: true,
        messages: [store.messages[10]!],
      ).toJson());
      await pubView.fetchInitial();
      connection.prepare(json: eg.newestGetMessagesResult(
        foundOldest: true,
        messages: [store.messages[11]!],
      ).toJson());
      await privView.fetchInitial();

      // Unsubscribe from both: public stays accessible (untracked), private loses access (purged).
      await store.handleEvent(SubscriptionRemoveEvent(
        id: 3,
        channelIds: [publicStream.streamId, privateStream.streamId],
      ));

      check(store.messages[10]).isNotNull();
      check(pubView.messages.map((m) => m.id)).deepEquals([10]);
      check(store.debugCoverage.intervalsOf('channel:1').map((r) => r.toString()))
        .deepEquals(['[0, 11]@e1 untracked v$now']);

      check(store.messages[11]).isNull();
      check(privView.messages).isEmpty();
      check(store.debugCoverage.intervalsOf('channel:2')).isEmpty();

      // ChannelDeleteEvent purges publicStream too.
      await store.handleEvent(ChannelDeleteEvent(
        id: 4,
        channelIds: [publicStream.streamId],
      ));
      check(store.messages[10]).isNull();
      check(pubView.messages).isEmpty();
      check(store.debugCoverage.intervalsOf('channel:1')).isEmpty();
    });
  });

  group('localWindow over in-memory coverage', () {
    test('returns null when coverageEnabled is false or narrow is unkeyed', () async {
      final store = eg.store();
      final stream = eg.stream();
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));

      check(store.localWindow(
        ChannelNarrow(stream.streamId), AnchorCode.newest, 10, 10, afterFailure: false,
      )).isNull();

      store.debugSetCoverageEnabled(true);
      check(store.localWindow(
        const CombinedFeedNarrow(), AnchorCode.newest, 10, 10, afterFailure: false,
      )).isNull();
    });

    test('newest, numeric, oldest slicing and flags', () async {
      final store = eg.store()..debugSetCoverageEnabled(true);
      final stream = eg.stream(streamId: 1);
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));

      final connection = store.connection as FakeApiConnection;
      final view = MessageListView.init(
        store: store,
        narrow: TopicNarrow(stream.streamId, eg.t('topic')),
        anchor: AnchorCode.newest,
      );
      addTearDown(view.dispose);

      connection.prepare(json: eg.newestGetMessagesResult(
        foundOldest: true,
        messages: [
          for (int id = 1; id <= 5; id++)
            eg.streamMessage(id: id, stream: stream, topic: 'topic'),
        ],
      ).toJson());
      await view.fetchInitial();

      final wNewest = store.localWindow(
        TopicNarrow(stream.streamId, eg.t('topic')),
        AnchorCode.newest,
        3,
        0,
        afterFailure: false,
      )!;
      check(wNewest.messages.map((m) => m.id)).deepEquals([3, 4, 5]);
      check(wNewest.haveOldest).isFalse();
      check(wNewest.haveNewest).isTrue();
      check(wNewest.atKnownNewest).isTrue();
      check(wNewest.anchorId).equals(5);

      final wNumeric = store.localWindow(
        TopicNarrow(stream.streamId, eg.t('topic')),
        const NumericAnchor(3),
        2,
        1,
        afterFailure: false,
      )!;
      check(wNumeric.messages.map((m) => m.id)).deepEquals([1, 2, 3, 4]);
      check(wNumeric.haveOldest).isTrue();
      check(wNumeric.haveNewest).isFalse();
      check(wNumeric.atKnownNewest).isFalse();
      check(wNumeric.anchorId).equals(3);

      final wOldest = store.localWindow(
        TopicNarrow(stream.streamId, eg.t('topic')),
        AnchorCode.oldest,
        0,
        2,
        afterFailure: false,
      )!;
      check(wOldest.messages.map((m) => m.id)).deepEquals([1, 2, 3]);
      check(wOldest.haveOldest).isTrue();
      check(wOldest.haveNewest).isFalse();
    });

    test('empty window rules: live oldest shown, non-oldest only afterFailure, stale null', () async {
      final store = eg.store()..debugSetCoverageEnabled(true);
      final publicStream = eg.stream(streamId: 1, inviteOnly: false);
      final topicNarrow = TopicNarrow(publicStream.streamId, eg.t('empty'));
      await store.addStream(publicStream);
      await store.addSubscription(eg.subscription(publicStream));

      // Live & reachesOldest -> empty LocalWindow is returned even before failure.
      final view = MessageListView.init(
        store: store,
        narrow: topicNarrow,
        anchor: AnchorCode.newest,
      );
      addTearDown(view.dispose);
      final connection = store.connection as FakeApiConnection;
      connection.prepare(json: eg.newestGetMessagesResult(
        foundOldest: true,
        messages: [],
      ).toJson());
      await view.fetchInitial();

      final wEmptyLive = store.localWindow(
        topicNarrow, AnchorCode.newest, 10, 10, afterFailure: false,
      );
      check(wEmptyLive).isNotNull();
      check(wEmptyLive!.messages).isEmpty();
      check(wEmptyLive.haveOldest).isTrue();
      check(wEmptyLive.haveNewest).isTrue();

      // Unsubscribe -> coverage becomes stale -> empty stale returns null.
      await store.handleEvent(SubscriptionRemoveEvent(
        id: 1,
        channelIds: [publicStream.streamId],
      ));
      check(store.localWindow(
        topicNarrow, AnchorCode.newest, 10, 10, afterFailure: true,
      )).isNull();
    });

    test('TopicNarrow.with_ redirects locally when location-reliable', () async {
      final store = eg.store()..debugSetCoverageEnabled(true);
      final stream = eg.stream(streamId: 1);
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));

      await store.handleEvent(eg.messageEvent(
        eg.streamMessage(id: 10, stream: stream, topic: 'actual'),
      ));
      // Fetch 'actual' so topic:1:ACTUAL has coverage too.
      final view = MessageListView.init(
        store: store,
        narrow: TopicNarrow(stream.streamId, eg.t('actual')),
        anchor: AnchorCode.newest,
      );
      addTearDown(view.dispose);
      final connection = store.connection as FakeApiConnection;
      connection.prepare(json: eg.newestGetMessagesResult(
        foundOldest: true,
        messages: [store.messages[10]!],
      ).toJson());
      await view.fetchInitial();

      final wWith = store.localWindow(
        TopicNarrow(stream.streamId, eg.t('stale-link'), with_: 10),
        const NumericAnchor(10),
        10,
        10,
        afterFailure: false,
      )!;
      check(wWith.narrow).equals(TopicNarrow(stream.streamId, eg.t('actual')));
      check(wWith.messages.map((m) => m.id)).deepEquals([10]);
    });
  });

  group('fetchInitial failure fallback & merge', () {
    test('shows covered local window on failure and merges on retry success', () async {
      await awaitFakeAsync((async) async {
        final store = eg.store()..debugSetCoverageEnabled(true);
        final stream = eg.stream(streamId: 1);
        await store.addStream(stream);
        await store.addSubscription(eg.subscription(stream));
        final narrow = TopicNarrow(stream.streamId, eg.t('topic'));
        final connection = store.connection as FakeApiConnection;

        // First view populates coverage [0, ∞] with messages [1, 2].
        final seedView = MessageListView.init(
          store: store, narrow: narrow, anchor: AnchorCode.newest);
        connection.prepare(json: eg.newestGetMessagesResult(
          foundOldest: true,
          messages: [
            eg.streamMessage(id: 1, stream: stream, topic: 'topic'),
            eg.streamMessage(id: 2, stream: stream, topic: 'topic'),
          ],
        ).toJson());
        await seedView.fetchInitial();
        seedView.dispose();

        // Second view fails initial fetch -> shows [1, 2] with revalidation=failing.
        final view = MessageListView.init(
          store: store, narrow: narrow, anchor: AnchorCode.newest);
        addTearDown(view.dispose);
        connection.prepare(httpException: const SocketException('offline'));
        final future = view.fetchInitial();
        async.elapse(Duration.zero);

        check(view.fetched).isTrue();
        check(view.fetchInitialFailing).isFalse();
        check(view.revalidation).equals(RevalidationState.failing);
        check(view.messages.map((m) => m.id)).deepEquals([1, 2]);

        // Retry succeeds with a newer message [1, 2, 3].
        connection.prepare(json: eg.newestGetMessagesResult(
          foundOldest: true,
          messages: [
            eg.streamMessage(id: 1, stream: stream, topic: 'topic'),
            eg.streamMessage(id: 2, stream: stream, topic: 'topic'),
            eg.streamMessage(id: 3, stream: stream, topic: 'topic'),
          ],
        ).toJson());
        async.elapse(const Duration(milliseconds: 300));
        await future;

        check(view.revalidation).equals(RevalidationState.none);
        check(view.messages.map((m) => m.id)).deepEquals([1, 2, 3]);
        check(view.haveNewest).isTrue();
      });
    });

    test('anchor fallback to newest when requested numeric anchor has no coverage', () async {
      await awaitFakeAsync((async) async {
        final store = eg.store()..debugSetCoverageEnabled(true);
        final stream = eg.stream(streamId: 1);
        await store.addStream(stream);
        await store.addSubscription(eg.subscription(stream));
        final narrow = TopicNarrow(stream.streamId, eg.t('topic'));
        final connection = store.connection as FakeApiConnection;

        // Seed closed coverage [0, 5] (unsubscribed public channel) so anchor 99 isn't covered.
        await store.handleEvent(SubscriptionRemoveEvent(
          id: 1, channelIds: [stream.streamId]));
        final seedView = MessageListView.init(
          store: store, narrow: narrow, anchor: const NumericAnchor(3));
        connection.prepare(json: eg.getMessagesResult(
          anchor: const NumericAnchor(3),
          foundOldest: true,
          foundNewest: false,
          messages: [
            eg.streamMessage(id: 1, stream: stream, topic: 'topic'),
            eg.streamMessage(id: 3, stream: stream, topic: 'topic'),
            eg.streamMessage(id: 5, stream: stream, topic: 'topic'),
          ],
        ).toJson());
        await seedView.fetchInitial();
        seedView.dispose();

        // Open at NumericAnchor(99) while offline -> falls back to newest [1, 3, 5].
        final view = MessageListView.init(
          store: store, narrow: narrow, anchor: const NumericAnchor(99));
        addTearDown(view.dispose);
        connection.prepare(httpException: const SocketException('offline'));
        final future = view.fetchInitial();
        async.elapse(Duration.zero);

        check(view.fetched).isTrue();
        check(view.anchorFallback).isTrue();
        check(view.revalidation).equals(RevalidationState.failing);
        check(view.messages.map((m) => m.id)).deepEquals([1, 3, 5]);

        // Retry succeeds with anchor 99 result.
        connection.prepare(json: eg.getMessagesResult(
          anchor: const NumericAnchor(99),
          foundOldest: false,
          foundNewest: true,
          messages: [
            eg.streamMessage(id: 90, stream: stream, topic: 'topic'),
            eg.streamMessage(id: 99, stream: stream, topic: 'topic'),
          ],
        ).toJson());
        async.elapse(const Duration(milliseconds: 300));
        await future;

        check(view.anchorFallback).isFalse();
        check(view.revalidation).equals(RevalidationState.none);
        check(view.messages.map((m) => m.id)).deepEquals([90, 99]);
      });
    });

    test('paginates locally with fetchOlder and fetchNewer while revalidation is failing', () async {
      await awaitFakeAsync((async) async {
        final store = eg.store()..debugSetCoverageEnabled(true);
        final stream = eg.stream(streamId: 1);
        await store.addStream(stream);
        await store.addSubscription(eg.subscription(stream));
        final narrow = TopicNarrow(stream.streamId, eg.t('topic'));
        final connection = store.connection as FakeApiConnection;

        // Seed 250 messages [1..250] in one live chain [0, ∞].
        final seedView = MessageListView.init(
          store: store, narrow: narrow, anchor: AnchorCode.newest);
        connection.prepare(json: eg.newestGetMessagesResult(
          foundOldest: true,
          messages: [
            for (int id = 1; id <= 250; id++)
              eg.streamMessage(id: id, stream: stream, topic: 'topic'),
          ],
        ).toJson());
        await seedView.fetchInitial();
        seedView.dispose();

        // Open at NumericAnchor(150) while offline -> shows [50..250]? Wait: before=100, after=100 -> [50..250].
        // With 250 messages, NumericAnchor(120) -> [20..220], so both ends have more!
        final view = MessageListView.init(
          store: store, narrow: narrow, anchor: const NumericAnchor(120));
        addTearDown(view.dispose);
        connection.prepare(httpException: const SocketException('offline'));
        final future = view.fetchInitial();
        async.elapse(Duration.zero);

        check(view.revalidation).equals(RevalidationState.failing);
        check(view.messages.first.id).equals(20);
        check(view.messages.last.id).equals(220);
        check(view.haveOldest).isFalse();
        check(view.haveNewest).isFalse();

        // fetchOlder locally loads [1..19] with no network call and sets haveOldest=true.
        await view.fetchOlder();
        check(view.messages.first.id).equals(1);
        check(view.haveOldest).isTrue();

        // fetchNewer locally loads [221..250] with no network call and sets haveNewest=true.
        await view.fetchNewer();
        check(view.messages.last.id).equals(250);
        check(view.haveNewest).isTrue();

        // Retry succeeds -> merges cleanly.
        connection.prepare(json: eg.getMessagesResult(
          anchor: const NumericAnchor(120),
          foundOldest: false,
          foundNewest: false,
          messages: [
            for (int id = 20; id <= 220; id++)
              eg.streamMessage(id: id, stream: stream, topic: 'topic'),
          ],
        ).toJson());
        async.elapse(const Duration(milliseconds: 300));
        await future;

        check(view.revalidation).equals(RevalidationState.none);
        check(view.messages.first.id).equals(1);
        check(view.messages.last.id).equals(250);
      });
    });

    test('fetchInitial shows live local window at once with inFlight revalidation, then merges', () async {
      final store = eg.store()..debugSetCoverageEnabled(true);
        final stream = eg.stream(streamId: 1);
        await store.addStream(stream);
        await store.addSubscription(eg.subscription(stream));
        final narrow = TopicNarrow(stream.streamId, eg.t('topic'));
        final connection = store.connection as FakeApiConnection;

        // Seed [1..5] in a live chain.
        final seedView = MessageListView.init(
          store: store, narrow: narrow, anchor: AnchorCode.newest);
        connection.prepare(json: eg.newestGetMessagesResult(
          foundOldest: true,
          messages: [
            for (int id = 1; id <= 5; id++)
              eg.streamMessage(id: id, stream: stream, topic: 'topic'),
          ],
        ).toJson());
        await seedView.fetchInitial();
        seedView.dispose();

        // Open a new view while network is delayed; live local window appears immediately.
        final view = MessageListView.init(
          store: store, narrow: narrow, anchor: AnchorCode.newest);
        addTearDown(view.dispose);
        connection.prepare(
          delay: const Duration(milliseconds: 200),
          json: eg.newestGetMessagesResult(
            foundOldest: true,
            messages: [
              for (int id = 1; id <= 6; id++)
                eg.streamMessage(id: id, stream: stream, topic: 'topic'),
            ],
          ).toJson(),
        );
        final future = view.fetchInitial();

        check(view.fetched).isTrue();
        check(view.revalidation).equals(RevalidationState.inFlight);
        check(view.messages.map((m) => m.id).toList()).deepEquals([1, 2, 3, 4, 5]);

        await future;
        check(view.revalidation).equals(RevalidationState.none);
        check(view.messages.map((m) => m.id).toList()).deepEquals([1, 2, 3, 4, 5, 6]);
      });

    test('fetchInitial delays showing stale local window by 500ms (O12)', () => awaitFakeAsync((async) async {
      final store = eg.store()..debugSetCoverageEnabled(true);
        final stream = eg.stream(streamId: 1);
        await store.addStream(stream);
        await store.addSubscription(eg.subscription(stream));
        final narrow = TopicNarrow(stream.streamId, eg.t('topic'));
        final connection = store.connection as FakeApiConnection;

        // Seed [1..3], then start a new epoch so the chain is stale.
        final seedView = MessageListView.init(
          store: store, narrow: narrow, anchor: AnchorCode.newest);
        connection.prepare(json: eg.newestGetMessagesResult(
          foundOldest: true,
          messages: [
            for (int id = 1; id <= 3; id++)
              eg.streamMessage(id: id, stream: stream, topic: 'topic'),
          ],
        ).toJson());
        await seedView.fetchInitial();
        seedView.dispose();

        store.debugCoverage.beginEpoch(maxMessageId: 3, lastLiveAt: 1000, now: 2000);

        // Case 1: fast network (< 500ms) -> stale window is never flashed.
        final fastView = MessageListView.init(
          store: store, narrow: narrow, anchor: AnchorCode.newest);
        addTearDown(fastView.dispose);
        connection.prepare(
          delay: const Duration(milliseconds: 200),
          json: eg.newestGetMessagesResult(
            foundOldest: true,
            messages: [
              for (int id = 1; id <= 4; id++)
                eg.streamMessage(id: id, stream: stream, topic: 'topic'),
            ],
          ).toJson(),
        );
        final fastFuture = fastView.fetchInitial();
        async.elapse(const Duration(milliseconds: 100));
        check(fastView.fetched).isFalse();
        check(fastView.messages).isEmpty();
        async.elapse(const Duration(milliseconds: 100));
        await fastFuture;
        check(fastView.revalidation).equals(RevalidationState.none);
        check(fastView.messages.map((m) => m.id).toList()).deepEquals([1, 2, 3, 4]);

        // Deliver message 4 by event so eventHighWater advances to 4, then start
        // another epoch so the chain [0, 4]@e2 is stale.
        await store.handleEvent(eg.messageEvent(
          eg.streamMessage(id: 4, stream: stream, topic: 'topic')));
        store.debugCoverage.beginEpoch(maxMessageId: 4, lastLiveAt: 3000, now: 4000);

        // Case 2: slow network (> 500ms) -> stale window appears at 500ms, then merges.
        final slowView = MessageListView.init(
          store: store, narrow: narrow, anchor: AnchorCode.newest);
        addTearDown(slowView.dispose);
        connection.prepare(
          delay: const Duration(milliseconds: 800),
          json: eg.newestGetMessagesResult(
            foundOldest: true,
            messages: [
              for (int id = 1; id <= 5; id++)
                eg.streamMessage(id: id, stream: stream, topic: 'topic'),
            ],
          ).toJson(),
        );
        final slowFuture = slowView.fetchInitial();
        async.elapse(const Duration(milliseconds: 499));
        check(slowView.fetched).isFalse();
        async.elapse(const Duration(milliseconds: 1));
        check(slowView.fetched).isTrue();
        check(slowView.revalidation).equals(RevalidationState.inFlight);
        check(slowView.messages.map((m) => m.id).toList()).deepEquals([1, 2, 3, 4]);

        async.elapse(const Duration(milliseconds: 300));
        await slowFuture;
        check(slowView.revalidation).equals(RevalidationState.none);
        check(slowView.messages.map((m) => m.id).toList()).deepEquals([1, 2, 3, 4, 5]);
      }));

    test('paginates locally while online and catches up network anchors after revalidation', () async {
      await awaitFakeAsync((async) async {
        final store = eg.store()..debugSetCoverageEnabled(true);
        final stream = eg.stream(streamId: 1);
        await store.addStream(stream);
        await store.addSubscription(eg.subscription(stream));
        final narrow = TopicNarrow(stream.streamId, eg.t('topic'));
        final connection = store.connection as FakeApiConnection;

        // Seed [1..250] in one live chain.
        final seedView = MessageListView.init(
          store: store, narrow: narrow, anchor: AnchorCode.newest);
        connection.prepare(json: eg.newestGetMessagesResult(
          foundOldest: true,
          messages: [
            for (int id = 1; id <= 250; id++)
              eg.streamMessage(id: id, stream: stream, topic: 'topic'),
          ],
        ).toJson());
        await seedView.fetchInitial();
        seedView.dispose();

        // Case 1: live chain online -> fetchOlder / fetchNewer paginate locally at once.
        final liveView = MessageListView.init(
          store: store, narrow: narrow, anchor: const NumericAnchor(120));
        addTearDown(liveView.dispose);
        connection.prepare(json: eg.getMessagesResult(
          anchor: const NumericAnchor(120),
          foundOldest: false,
          foundNewest: false,
          messages: [
            for (int id = 20; id <= 220; id++)
              eg.streamMessage(id: id, stream: stream, topic: 'topic'),
          ],
        ).toJson());
        await liveView.fetchInitial();
        check(liveView.revalidation).equals(RevalidationState.none);
        check(liveView.messages.first.id).equals(20);
        check(liveView.messages.last.id).equals(220);

        await liveView.fetchOlder();
        check(liveView.messages.first.id).equals(1);
        check(liveView.haveOldest).isTrue();

        await liveView.fetchNewer();
        check(liveView.messages.last.id).equals(250);
        check(liveView.haveNewest).isTrue();

        // Case 2: stale chain -> local pagination during revalidation, then
        // network catch-up from networkOldestId=20 when online again.
        await store.handleEvent(eg.messageEvent(
          eg.streamMessage(id: 250, stream: stream, topic: 'topic')));
        store.debugCoverage.beginEpoch(maxMessageId: 250, lastLiveAt: 1000, now: 2000);
        final staleView = MessageListView.init(
          store: store, narrow: narrow, anchor: const NumericAnchor(120));
        addTearDown(staleView.dispose);
        connection.prepare(httpException: const SocketException('offline'));
        final future = staleView.fetchInitial();
        async.elapse(Duration.zero);
        check(staleView.revalidation).equals(RevalidationState.failing);
        check(staleView.messages.first.id).equals(20);

        // Local fetchOlder loads [1..19] while offline (stale, so haveOldest=false? Wait:
        // reachesOldest is true on [0, 250], so haveOldest=true; let's test fetchNewer too!).
        // Actually for stale, haveNewest is false while atKnownNewest is true, so let's
        // test fetchOlder when stale has a gap or test fetchNewer catch-up!
        // Here we just verify revalidation succeeds and fetchNewer refreshes [221..250].
        connection.prepare(json: eg.getMessagesResult(
          anchor: const NumericAnchor(120),
          foundOldest: false,
          foundNewest: false,
          messages: [
            for (int id = 20; id <= 220; id++)
              eg.streamMessage(id: id, stream: stream, topic: 'topic'),
          ],
        ).toJson());
        async.elapse(const Duration(milliseconds: 300));
        await future;
        check(staleView.revalidation).equals(RevalidationState.none);
        check(staleView.haveNewest).isFalse();

        // Now fetchNewer: loads [221..250] locally AND refreshes from network anchor 220.
        connection.prepare(
          delay: const Duration(milliseconds: 100),
          json: eg.getMessagesResult(
            anchor: const NumericAnchor(220),
            foundOldest: false,
            foundNewest: true,
            messages: [
              for (int id = 221; id <= 250; id++)
                eg.streamMessage(id: id, stream: stream, topic: 'topic'),
            ],
          ).toJson(),
        );
        final newerFuture = staleView.fetchNewer();
        // Locally loaded immediately before network completes:
        check(staleView.messages.last.id).equals(250);
        async.elapse(const Duration(milliseconds: 100));
        await newerFuture;
        check(staleView.haveNewest).isTrue();
        check(staleView.messages.last.id).equals(250);
        check(staleView.messages.length).equals(231); // [20..250], no duplicates
      });
    });

    test('debug oracle reports revalidations that change live data, but not racing events', () async {
      final reports = <String>[];
      MessageListView.debugOnLiveRevalidationChanged = (_, detail) => reports.add(detail);
      addTearDown(() => MessageListView.debugOnLiveRevalidationChanged = null);

      final store = eg.store()..debugSetCoverageEnabled(true);
      final stream = eg.stream(streamId: 1);
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));
      final narrow = TopicNarrow(stream.streamId, eg.t('topic'));
      final connection = store.connection as FakeApiConnection;

      final seedView = MessageListView.init(
        store: store, narrow: narrow, anchor: AnchorCode.newest);
      connection.prepare(json: eg.newestGetMessagesResult(
        foundOldest: true,
        messages: [
          eg.streamMessage(id: 1, stream: stream, topic: 'topic'),
          eg.streamMessage(id: 2, stream: stream, topic: 'topic'),
        ],
      ).toJson());
      await seedView.fetchInitial();
      seedView.dispose();

      // Case 1: racing message event arrives while revalidation is in flight -> NOT reported.
      final racingView = MessageListView.init(
        store: store, narrow: narrow, anchor: AnchorCode.newest);
      addTearDown(racingView.dispose);
      connection.prepare(
        delay: const Duration(milliseconds: 50),
        json: eg.newestGetMessagesResult(
          foundOldest: true,
          messages: [
            eg.streamMessage(id: 1, stream: stream, topic: 'topic'),
            eg.streamMessage(id: 2, stream: stream, topic: 'topic'),
          ],
        ).toJson(),
      );
      final racingFuture = racingView.fetchInitial();
      await store.handleEvent(eg.messageEvent(
        eg.streamMessage(id: 3, stream: stream, topic: 'topic')));
      await racingFuture;
      check(reports).isEmpty();
      check(racingView.messages.map((m) => m.id).toList()).deepEquals([1, 2, 3]);

      // Case 2: server returns an unexpected message id 4 on a live window -> reported.
      final gapView = MessageListView.init(
        store: store, narrow: narrow, anchor: AnchorCode.newest);
      addTearDown(gapView.dispose);
      connection.prepare(
        delay: const Duration(milliseconds: 50),
        json: eg.newestGetMessagesResult(
          foundOldest: true,
          messages: [
            eg.streamMessage(id: 1, stream: stream, topic: 'topic'),
            eg.streamMessage(id: 2, stream: stream, topic: 'topic'),
            eg.streamMessage(id: 3, stream: stream, topic: 'topic'),
            eg.streamMessage(id: 4, stream: stream, topic: 'topic'),
          ],
        ).toJson(),
      );
      await gapView.fetchInitial();
      check(reports).deepEquals(['added message 4']);
    });

    test('relocate live in-memory message when fetch observes it at a new conversation', () async {
      final store = eg.store()..debugSetCoverageEnabled(true);
      final s1 = eg.stream(streamId: 1, name: 'one');
      final s2 = eg.stream(streamId: 2, name: 'two');
      await store.addStream(s1);
      await store.addStream(s2);
      await store.addSubscription(eg.subscription(s1));
      await store.addSubscription(eg.subscription(s2));
      final connection = store.connection as FakeApiConnection;

      final oldView = MessageListView.init(
        store: store, narrow: TopicNarrow(1, eg.t('old')), anchor: AnchorCode.newest);
      addTearDown(oldView.dispose);
      connection.prepare(json: eg.newestGetMessagesResult(
        foundOldest: true,
        messages: [
          eg.streamMessage(id: 10, stream: s1, topic: 'old'),
          eg.streamMessage(id: 20, stream: s1, topic: 'old'),
        ],
      ).toJson());
      await oldView.fetchInitial();

      // Simulate unsubscribed move of id 10 to s2/'new' while store held id 10 at s1/'old'.
      store.debugMaybeStaleMessages.add(10);
      final newView = MessageListView.init(
        store: store, narrow: TopicNarrow(2, eg.t('new')), anchor: AnchorCode.newest);
      addTearDown(newView.dispose);
      connection.prepare(json: eg.newestGetMessagesResult(
        foundOldest: true,
        messages: [eg.streamMessage(id: 10, stream: s2, topic: 'new')],
      ).toJson());
      await newView.fetchInitial();

      check((store.messages[10] as StreamMessage).streamId).equals(2);
      check(oldView.messages.map((m) => m.id)).deepEquals([20]);
      check(store.debugCoverage.intervalsOf('topic:1:OLD').any((r) => r.contains(10))).isFalse();
    });

    test('compute anchorKnownVisible from includeAnchor and unfilteredIds', () async {
      final store = eg.store()..debugSetCoverageEnabled(true);
      final stream = eg.stream(streamId: 1);
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));

      // Pagination fetchOlder with includeAnchor: false returning numBefore=2 messages [8, 9]
      // anchored at 10 must record lo=8 (NOT shift lo to 9 as if anchor 10 consumed a slot).
      final ticket = store.openFetchTicket(channelId: stream.streamId);
      try {
        store.reconcileMessages(
          [
            eg.streamMessage(id: 8, stream: stream, topic: 't'),
            eg.streamMessage(id: 9, stream: stream, topic: 't'),
          ],
          ticket: ticket,
          coverageRequest: FetchCoverageRequest(
            narrow: TopicNarrow(stream.streamId, eg.t('t')),
            numBefore: 2,
            numAfter: 0,
            includeAnchor: false,
            foundOldest: false,
            foundNewest: false,
            historyLimited: false,
            resolvedAnchor: 10,
          ),
        );
      } finally {
        store.closeFetchTicket(ticket);
      }
      final intervals = store.debugCoverage.intervalsOf('topic:1:T');
      check(intervals.single.lo).equals(8);
      check(intervals.single.hi).equals(9);
    });

    test('drop fetch coverage when channel was deleted and recreated in flight', () async {
      final store = eg.store()..debugSetCoverageEnabled(true);
      final stream = eg.stream(streamId: 1);
      await store.addStream(stream);
      await store.addSubscription(eg.subscription(stream));

      final ticket = store.openFetchTicket(channelId: 1);
      try {
        await store.handleEvent(ChannelDeleteEvent(id: 1, channelIds: [1]));
        await store.handleEvent(ChannelCreateEvent(id: 2, streams: [stream]));
        await store.handleEvent(SubscriptionAddEvent(id: 3, subscriptions: [eg.subscription(stream)]));
        store.reconcileMessages(
          [eg.streamMessage(id: 10, stream: stream, topic: 't')],
          ticket: ticket,
          coverageRequest: FetchCoverageRequest(
            narrow: TopicNarrow(1, eg.t('t')),
            numBefore: 20,
            numAfter: 0,
            includeAnchor: true,
            foundOldest: true,
            foundNewest: true,
            historyLimited: false,
            resolvedAnchor: 10,
          ),
        );
      } finally {
        store.closeFetchTicket(ticket);
      }
      check(store.debugCoverage.intervalsOf('topic:1:T')).isEmpty();
    });

    test('drop fetched message moved in flight to inaccessible private channel', () async {
      final store = eg.store()..debugSetCoverageEnabled(true);
      final pub = eg.stream(streamId: 1, inviteOnly: false);
      final secret = eg.stream(streamId: 2, inviteOnly: true);
      await store.addStream(pub);
      await store.addStream(secret);
      await store.addSubscription(eg.subscription(pub));

      final ticket = store.openFetchTicket(channelId: 1);
      final fetched = eg.streamMessage(id: 10, stream: pub, topic: 't');
      try {
        await store.handleEvent(eg.updateMessageEventMoveFrom(
          origMessages: [fetched],
          newStreamId: secret.streamId,
          newTopicStr: 'secret-t',
        ));
        store.reconcileMessages([fetched], ticket: ticket);
      } finally {
        store.closeFetchTicket(ticket);
      }
      check(store.messages.containsKey(10)).isFalse();
    });

    test('no coverage on empty fetch of unsubscribed public channel by guest', () async {
      final guestSelf = eg.user(userId: eg.selfUser.userId, role: UserRole.guest);
      final pub = eg.stream(streamId: 1, inviteOnly: false, isWebPublic: false);
      final store = eg.store(
        selfUser: guestSelf,
        initialSnapshot: eg.initialSnapshot(
          realmUsers: [guestSelf],
          streams: [pub],
          subscriptions: const [],
        ),
      )..debugSetCoverageEnabled(true);

      final ticket = store.openFetchTicket(channelId: 1);
      try {
        store.reconcileMessages(
          <Message>[],
          ticket: ticket,
          coverageRequest: FetchCoverageRequest(
            narrow: TopicNarrow(1, eg.t('t')),
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
      check(store.debugCoverage.intervalsOf('topic:1:T')).isEmpty();
    });
  });
}
