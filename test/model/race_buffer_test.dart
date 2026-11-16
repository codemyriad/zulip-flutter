import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:zulip/api/model/events.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/model/message_effect.dart';
import 'package:zulip/model/message_list.dart';
import 'package:zulip/model/narrow.dart';
import 'package:zulip/model/race_buffer.dart';

import '../api/fake_api.dart';
import '../example_data.dart' as eg;
import '../fake_async.dart';
import 'binding.dart';
import 'test_store.dart';

void main() {
  TestZulipBinding.ensureInitialized();

  group('RaceBuffer', () {
    test('does not retain effects when no ticket is open', () {
      final buf = RaceBuffer();
      buf.record(ContentEffect(
        messageId: 1,
        flags: const [],
        renderedContent: '<p>x</p>',
      ));
      buf.record(const DeleteEffect(messageIds: [1]));
      buf.record(const ChannelPurgeEffect(channelId: 10));
      buf.record(const FlagAllReadEffect());

      check(buf.seq).equals(4);
      check(buf.entryCount).equals(0);
      check(buf.removedCount).equals(0);
      check(buf.purgedCount).equals(0);
      check(buf.readFlagsCount).equals(0);
    });

    test('retains effects above floor and prunes on ticket close', () {
      final buf = RaceBuffer();
      final t1 = buf.openTicket();
      check(t1.mark).equals(0);

      buf.record(ContentEffect(
        messageId: 1,
        flags: const [],
        renderedContent: '<p>first</p>',
      ));
      final t2 = buf.openTicket();
      check(t2.mark).equals(1);

      buf.record(const DeleteEffect(messageIds: [2]));
      buf.record(const ChannelPurgeEffect(channelId: 9));
      buf.record(InsertEffect(message: eg.streamMessage(id: 3), tracked: true));
      buf.record(const FlagEffect(
        messageIds: [4], flag: MessageFlag.read, add: true));

      check(buf.entryCount).equals(1);
      check(buf.removedCount).equals(1);
      check(buf.purgedCount).equals(1);
      check(buf.arrivedCount).equals(1);
      check(buf.readFlagsCount).equals(1);

      // Closing t1 advances floor from 0 to t2.mark (1), pruning seq 1.
      t1.close();
      check(t1.isClosed).isTrue();
      check(buf.entryCount).equals(0);
      check(buf.removedCount).equals(1);
      check(buf.purgedCount).equals(1);

      // Closing t2 advances floor to seq (5), pruning everything.
      t2.close();
      check(buf.removedCount).equals(0);
      check(buf.purgedCount).equals(0);
      check(buf.arrivedCount).equals(0);
      check(buf.readFlagsCount).equals(0);

      // Closing twice is a no-op.
      t2.close();
    });

    test('overflows open tickets at entryCap without dropping removed/arrived/readFlags', () {
      final buf = RaceBuffer(entryCap: 3);
      final t1 = buf.openTicket();

      buf.record(const EditTimeEffect(messageIds: [1], editTimestamp: 10));
      buf.record(const EditTimeEffect(messageIds: [1], editTimestamp: 11));
      buf.record(const EditTimeEffect(messageIds: [1], editTimestamp: 12));
      check(t1.overflowed).isFalse();
      check(buf.entryCount).equals(3);

      // Recording a 4th entry overflows t1 and clears entries,
      // while uncapped lists remain unaffected.
      buf.record(const DeleteEffect(messageIds: [99]));
      buf.record(const FlagAllReadEffect());
      check(t1.overflowed).isFalse();

      buf.record(const EditTimeEffect(messageIds: [1], editTimestamp: 13));
      check(t1.overflowed).isTrue();
      check(buf.entryCount).equals(0);
      check(buf.removedCount).equals(1);
      check(buf.readFlagsCount).equals(1);

      // A ticket opened after overflow does not inherit overflowed=true.
      final t2 = buf.openTicket();
      check(t2.overflowed).isFalse();

      buf.closeAll();
      check(t1.isClosed).isTrue();
      check(t2.isClosed).isTrue();
      check(buf.openTicketCount).equals(0);
      check(buf.removedCount).equals(0);
      check(buf.readFlagsCount).equals(0);
    });

    test('applyEffectsAfter preserves order across entries and readFlags', () {
      final buf = RaceBuffer();
      final t = buf.openTicket();

      // seq 1: ContentEffect with flags: [read]
      buf.record(ContentEffect(
        messageId: 1,
        flags: [MessageFlag.read],
        renderedContent: '<p>edited</p>',
      ));
      // seq 2: FlagEffect removing read
      buf.record(const FlagEffect(
        messageIds: [1], flag: MessageFlag.read, add: false));
      // seq 3: FlagAllReadEffect
      buf.record(const FlagAllReadEffect());

      final msg = eg.streamMessage(id: 1, content: '<p>orig</p>', flags: []);
      buf.applyEffectsAfter(t.mark, msg);
      check(msg.content).equals('<p>edited</p>');
      check(msg.flags).deepEquals([MessageFlag.read]);

      // Now if FlagEffect(read, add: false) comes AFTER FlagAllReadEffect:
      buf.record(const FlagEffect(
        messageIds: [1], flag: MessageFlag.read, add: false));
      final msg2 = eg.streamMessage(id: 1, content: '<p>orig</p>', flags: []);
      buf.applyEffectsAfter(t.mark, msg2);
      check(msg2.flags).isEmpty();

      t.close();
    });
  });

  group('FetchTicket lifecycle in MessageListView', () {
    test('closes ticket on fetchInitial success and on store dispose', () async {
      final store = eg.store();
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

      final future = view.fetchInitial();
      check(store.debugRaceBuffer.openTicketCount).equals(1);
      await future;
      check(store.debugRaceBuffer.openTicketCount).equals(0);
    });
  });

  group('fetch/event race re-application', () {
    test('re-applies edit, reaction, read flag, and drops deleted/moved-out messages', () => awaitFakeAsync((async) async {
      final store = eg.store();
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

      final msg1 = eg.streamMessage(
        id: 1, stream: stream, topic: 'topic', content: '<p>before</p>', flags: []);
      final msg2 = eg.streamMessage(
        id: 2, stream: stream, topic: 'topic', content: '<p>deleted</p>');
      final msg3 = eg.streamMessage(
        id: 3, stream: stream, topic: 'topic', content: '<p>moved</p>');

      connection.prepare(
        delay: const Duration(milliseconds: 50),
        json: eg.newestGetMessagesResult(
          foundOldest: true,
          messages: [msg1, msg2, msg3],
        ).toJson(),
      );

      final fetchFuture = view.fetchInitial();
      async.elapse(const Duration(milliseconds: 10));

      // Events arrive before the fetch completes, while msg1..msg3 are not yet in store.
      await store.handleEvent(eg.updateMessageEditEvent(
        msg1,
        renderedContent: '<p>after</p>',
        flags: [],
      ));
      await store.handleEvent(eg.reactionEvent(
        Reaction(
          emojiName: 'thumbs_up',
          emojiCode: '1f44d',
          reactionType: ReactionType.unicodeEmoji,
          userId: eg.selfUser.userId,
        ),
        ReactionOp.add,
        msg1.id,
      ));
      await store.handleEvent(UpdateMessageFlagsAddEvent(
        id: 10,
        flag: MessageFlag.read,
        messages: [msg1.id],
        all: false,
      ));
      await store.handleEvent(eg.deleteMessageEvent([msg2]));
      await store.handleEvent(eg.updateMessageEventMoveFrom(
        origMessages: [msg3],
        newTopicStr: 'other',
      ));

      async.elapse(const Duration(milliseconds: 50));
      await fetchFuture;

      // msg2 was deleted: dropped from store and view.
      check(store.messages.containsKey(msg2.id)).isFalse();

      // msg3 was moved out of 'topic': in store at 'other', but dropped from view.
      final stored3 = store.messages[msg3.id] as StreamMessage;
      check(stored3.topic).equals(eg.t('other'));

      // msg1 is in store and view with the edit, reaction, and read flag applied.
      check(view.messages.map((m) => m.id)).deepEquals([msg1.id]);
      final stored1 = store.messages[msg1.id]!;
      check(stored1.content).equals('<p>after</p>');
      check(stored1.flags).deepEquals([MessageFlag.read]);
      check(stored1.reactions!.aggregated.single.emojiName).equals('thumbs_up');
    }));

    test('fetchOlder drops messages moved out during the fetch', () => awaitFakeAsync((async) async {
      final store = eg.store();
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

      final initialMsg = eg.streamMessage(id: 10, stream: stream, topic: 'topic');
      connection.prepare(json: eg.newestGetMessagesResult(
        foundOldest: false,
        messages: [initialMsg],
      ).toJson());
      await view.fetchInitial();

      final olderKept = eg.streamMessage(id: 8, stream: stream, topic: 'topic');
      final olderMoved = eg.streamMessage(id: 9, stream: stream, topic: 'topic');
      connection.prepare(
        delay: const Duration(milliseconds: 50),
        json: eg.olderGetMessagesResult(
          anchor: 10,
          foundOldest: true,
          messages: [olderKept, olderMoved],
        ).toJson(),
      );

      final olderFuture = view.fetchOlder();
      async.elapse(const Duration(milliseconds: 10));
      await store.handleEvent(eg.updateMessageEventMoveFrom(
        origMessages: [olderMoved],
        newTopicStr: 'other',
      ));

      async.elapse(const Duration(milliseconds: 50));
      await olderFuture;

      check(view.messages.map((m) => m.id)).deepEquals([8, 10]);
      check((store.messages[9] as StreamMessage).topic).equals(eg.t('other'));
    }));

    test('channel untracked during fetch marks newly-fetched message maybe-stale', () => awaitFakeAsync((async) async {
      final store = eg.store();
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

      final msg1 = eg.streamMessage(
        id: 1, stream: stream, topic: 'topic', content: '<p>stale</p>');
      connection.prepare(
        delay: const Duration(milliseconds: 50),
        json: eg.newestGetMessagesResult(
          foundOldest: true,
          messages: [msg1],
        ).toJson(),
      );

      final fetchFuture = view.fetchInitial();
      async.elapse(const Duration(milliseconds: 10));
      await store.handleEvent(SubscriptionRemoveEvent(
        id: 1,
        channelIds: [stream.streamId],
      ));

      async.elapse(const Duration(milliseconds: 50));
      await fetchFuture;

      // Because the channel was untracked while the fetch was in flight,
      // msg1 is marked maybe-stale, so a subsequent reconcile clobbers it.
      final fresh1 = eg.streamMessage(
        id: 1, stream: stream, topic: 'topic', content: '<p>fresh</p>');
      store.reconcileMessages([fresh1]);
      check(store.messages[1]!.content).equals('<p>fresh</p>');
    }));

    test('dbCommittedSeq and needsDbCommit retention without open tickets', () {
      final buf = RaceBuffer();
      final s1 = buf.record(const DeleteEffect(messageIds: [1]), needsDbCommit: true);
      final s2 = buf.record(ContentEffect(
        messageId: 2,
        flags: const [],
        renderedContent: '<p>edited</p>',
      ), needsDbCommit: true);
      final s3 = buf.record(const FlagEffect(
        messageIds: [3], flag: MessageFlag.read, add: true));

      check(s1).equals(1);
      check(s2).equals(2);
      check(s3).equals(3);
      check(buf.dbCommittedSeq).equals(0);
      check(buf.uncommittedCount).equals(2);
      // Even with zero open tickets, uncommitted effects are retained so a DB
      // read issued at dbCommittedSeq sees them.
      check(buf.removedCount).equals(1);
      check(buf.entryCount).equals(1);

      final readTicket = buf.openDbReadTicket(epoch: 1);
      check(readTicket.mark).equals(0);
      check(readTicket.epoch).equals(1);
      check(buf.wasRemovedOrPurgedAfter(readTicket.mark, 1)).isTrue();

      buf.markCommitted([s1]);
      check(buf.dbCommittedSeq).equals(1);
      check(buf.uncommittedCount).equals(1);
      // readTicket at mark 0 still pins items above 0 until closed.
      check(buf.removedCount).equals(1);

      buf.markCommitted([s2]);
      check(buf.dbCommittedSeq).equals(3);
      check(buf.uncommittedCount).equals(0);

      buf.closeTicket(readTicket);
      check(buf.removedCount).equals(0);
      check(buf.entryCount).equals(0);
    });

    test('uncommitted batch overflow marks subsequent openDbReadTicket overflowed', () {
      final buf = RaceBuffer(entryCap: 2);
      final s1 = buf.record(const EditTimeEffect(messageIds: [1], editTimestamp: 10), needsDbCommit: true);
      final s2 = buf.record(const EditTimeEffect(messageIds: [1], editTimestamp: 11), needsDbCommit: true);
      final s3 = buf.record(const EditTimeEffect(messageIds: [1], editTimestamp: 12), needsDbCommit: true);
      check(buf.entryCount).equals(0);

      final readBeforeCommit = buf.openDbReadTicket(epoch: 1);
      check(readBeforeCommit.overflowed).isTrue();
      buf.closeTicket(readBeforeCommit);

      buf.markCommitted([s1, s2, s3]);
      final readAfterCommit = buf.openDbReadTicket(epoch: 1);
      check(readAfterCommit.overflowed).isFalse();
      buf.closeTicket(readAfterCommit);
    });
  });
}
