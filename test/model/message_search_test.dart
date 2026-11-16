import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:zulip/api/model/initial_snapshot.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/model/message.dart';
import 'package:zulip/model/message_search.dart';
import 'package:zulip/model/narrow.dart';
import 'package:zulip/model/presence.dart';
import 'package:zulip/model/settings.dart';
import 'package:zulip/model/store.dart';

import '../api/fake_api.dart';
import '../example_data.dart' as eg;
import '../fake_async.dart';
import 'binding.dart';
import 'test_store.dart';

class _PerAccountSearchStore implements MessageSearchStore {
  _PerAccountSearchStore(this.store);

  final PerAccountStore store;

  @override
  int get selfUserId => store.selfUserId;

  @override
  Map<int, ZulipStream> get streams => store.streams;

  @override
  Map<int, Subscription> get subscriptions => store.subscriptions;

  @override
  Iterable<User> get allUsers => store.allUsers;

  @override
  User? getUser(int userId) => store.getUser(userId);

  @override
  bool selfHasContentAccess(ZulipStream channel) => store.selfHasContentAccess(channel);

  @override
  bool isTopicVisible(int channelId, TopicName topic) =>
    store.isTopicVisible(channelId, topic);

  @override
  bool isTopicVisibleInChannel(int channelId, TopicName topic) =>
    store.isTopicVisibleInChannel(channelId, topic);

  @override
  UserTopicVisibilityPolicy topicVisibilityPolicy(int channelId, TopicName topic) =>
    store.topicVisibilityPolicy(channelId, topic);

  @override
  bool shouldMuteDmConversation(DmNarrow narrow) =>
    store.shouldMuteDmConversation(narrow);

  @override
  Set<int> get starredMessages => store.starredMessages;

  @override
  bool get isStarredMessagesAtCap => store.isStarredMessagesAtCap;
}

void main() {
  TestZulipBinding.ensureInitialized();
  Presence.debugEnable = false;

  Map<String, dynamic> snapshotToJson(InitialSnapshot snap) {
    final json = jsonDecode(jsonEncode(snap)) as Map<String, dynamic>;
    final subs = json['subscriptions'];
    if (subs is List) {
      for (final sub in subs) {
        if (sub is Map<String, dynamic> && sub['color'] is int) {
          final color = sub['color'] as int;
          sub['color'] = '#${(color & 0xffffff).toRadixString(16).padLeft(6, '0')}';
        }
      }
    }
    return json;
  }

  Future<({TestGlobalStore global, UpdateMachine um, FakeApiConnection conn})>
      startDbStore({
    TestGlobalStore? existingGlobal,
    InitialSnapshot? snap,
    bool allowPersisted = false,
  }) async {
    final global = existingGlobal ?? eg.globalStore();
    if (existingGlobal == null) {
      await global.settings.setBool(BoolGlobalSetting.messageDatabase, true);
      await global.insertAccount(eg.selfAccount.toCompanion(false));
      global.useCachedApiConnections = true;
    } else {
      global.clearCachedApiConnections();
    }
    final conn = global.apiConnectionFromAccount(eg.selfAccount) as FakeApiConnection;
    final effectiveSnap = snap ?? eg.initialSnapshot();
    if (!allowPersisted) {
      conn.prepare(json: snapshotToJson(effectiveSnap));
    }
    conn.prepare(json: {
      'result': 'success',
      'msg': '',
      'events': <Object>[],
      'queue_id': effectiveSnap.queueId ?? 'q1',
    });
    final um = await UpdateMachine.load(
      global,
      eg.selfAccount.id,
      allowPersisted: allowPersisted,
    );
    um.debugPauseLoop();
    return (global: global, um: um, conn: conn);
  }

  void reconcileWithRaw(
    PerAccountStore store,
    Narrow narrow,
    List<Message> messages, {
    int? resolvedAnchor,
    bool foundOldest = true,
    bool foundNewest = true,
  }) {
    final channelId = switch (narrow) {
      ChannelNarrow(:final channelId) || TopicNarrow(:final channelId) => channelId,
      _ => null,
    };
    final ticket = store.openFetchTicket(channelId: channelId);
    try {
      store.reconcileMessages(
        messages,
        rawMessages: [
          for (final m in messages) jsonDecode(jsonEncode(m)) as Map<String, dynamic>,
        ],
        ticket: ticket,
        coverageRequest: FetchCoverageRequest(
          narrow: narrow,
          numBefore: 100,
          numAfter: 100,
          includeAnchor: true,
          foundOldest: foundOldest,
          foundNewest: foundNewest,
          historyLimited: false,
          resolvedAnchor: resolvedAnchor ?? messages.last.id,
        ),
      );
    } finally {
      store.closeFetchTicket(ticket);
    }
  }

  group('ParsedMessageSearchQuery', () {
    test('text, phrases, prefix, negation, punctuation, diacritics, and unsafe tokens', () async {
      final stream = eg.stream(streamId: 10, name: 'General');
      final store = eg.store(initialSnapshot: eg.initialSnapshot(
        streams: [stream],
        subscriptions: [eg.subscription(stream)],
      ));
      final adapter = _PerAccountSearchStore(store);

      final mHello = eg.streamMessage(
        id: 1, stream: stream, topic: 'Alpha_beta topic',
        content: '<p>Café latte and espresso shots hello_world</p>',
      );
      final mPartial = eg.streamMessage(
        id: 2, stream: stream, topic: 'Espresso',
        content: '<p>world hello AND OR NOT NEAR</p>',
      );
      final mEmoji = eg.streamMessage(
        id: 3, stream: stream, topic: 'Reactions',
        content: '<p>Great job 👍 foo:bar c++ ??? a*b</p>',
      );

      bool matches(String query, Message m) =>
        ParsedMessageSearchQuery.parse(query, adapter).matchesMessage(m, adapter);

      check(matches('cafe latte', mHello)).isTrue();
      check(matches('café', mHello)).isTrue();
      check(matches('"hello world"', mHello)).isTrue();
      check(matches('"hello_world"', mHello)).isTrue();
      check(matches('"hello world"', mPartial)).isFalse(); // reversed order

      check(matches('espress*', mHello)).isTrue();
      check(matches('espresso -latte', mHello)).isFalse();
      check(matches('espresso -latte', mPartial)).isTrue();
      check(matches('espresso -"cafe latte"', mHello)).isFalse();
      check(matches('espresso -"cafe latte"', mPartial)).isTrue();
      // `!` is not a negation operator in Zulip search syntax.
      check(matches('!espresso', mHello)).isTrue();

      // FTS5 reserved keywords & unknown operators safely treated as plain text.
      check(matches('AND OR NOT NEAR', mPartial)).isTrue();
      check(matches('foo:bar', mEmoji)).isTrue();
      check(matches('"Great job', mEmoji)).isTrue();
      check(matches('"unclosed quote foo', mEmoji)).isFalse();

      // Non-alphanumeric symbol / emoji-only terms fall back to literal match.
      check(matches('👍', mEmoji)).isTrue();
      check(matches('👍', mHello)).isFalse();
      check(matches('???', mEmoji)).isTrue();
      check(matches('c++', mEmoji)).isTrue();
      check(matches('c++ -👍', mEmoji)).isFalse();

      // Check SQL FTS5 spec quotes reserved keywords and strips unsafe chars.
      final spec = ParsedMessageSearchQuery.parse(
        'AND foo* -"cafe latte" -alpha c++',
        adapter,
      ).sqlSpec;
      check(spec.positiveFtsMatch).isNotNull()
        ..contains('"and"')
        ..contains('"foo"*')
        ..contains('"c"');
      // Single-token negation pushed down; multi-token negated phrase left for Dart.
      check(spec.negatedFtsMatch).equals('"alpha"');
    });

    test('operators and visibility/muting rules', () async {
      final general = eg.stream(streamId: 1, name: 'General', inviteOnly: false);
      final design = eg.stream(streamId: 2, name: 'Design Team', inviteOnly: false);
      final webPub = eg.stream(streamId: 3, name: 'Web Pub', inviteOnly: false, isWebPublic: true);
      final unsubPub = eg.stream(streamId: 4, name: 'Unsub Public', inviteOnly: false);
      final mutedCh = eg.stream(streamId: 5, name: 'Muted Ch', inviteOnly: false);

      final alice = eg.user(userId: 201, email: 'alice@example.com', fullName: 'Alice Smith');
      final bob = eg.user(userId: 202, email: 'bob@example.com', fullName: 'Bob Jones');
      final mutedUser = eg.user(userId: 203, email: 'muted@example.com', fullName: 'Muted Person');

      final store = eg.store(initialSnapshot: eg.initialSnapshot(
        realmUsers: [eg.selfUser, alice, bob, mutedUser],
        streams: [general, design, webPub, unsubPub, mutedCh],
        subscriptions: [
          eg.subscription(general),
          eg.subscription(design),
          eg.subscription(webPub),
          eg.subscription(mutedCh, isMuted: true),
        ],
        mutedUsers: [MutedUserItem(id: mutedUser.userId)],
        starredMessages: [10],
        userTopics: [
          eg.userTopicItem(general, 'Muted Topic', UserTopicVisibilityPolicy.muted),
          eg.userTopicItem(general, 'Followed Topic', UserTopicVisibilityPolicy.followed),
          eg.userTopicItem(mutedCh, 'Unmuted In Muted', UserTopicVisibilityPolicy.unmuted),
        ],
      ));
      final adapter = _PerAccountSearchStore(store);

      final mGeneral = eg.streamMessage(
        id: 10, stream: general, topic: '✔ Fixed bug', sender: alice,
        content: '<p><a href="https://zulip.org">site</a> <a href="/user_uploads/a.pdf">doc</a></p>',
        flags: [MessageFlag.starred, MessageFlag.mentioned],
      );
      final mDesign = eg.streamMessage(
        id: 11, stream: design, topic: 'Followed Topic', sender: eg.selfUser,
        content: '<p>Check <img src="/img.png" class="message_inline_image"></p>',
        flags: [MessageFlag.read, MessageFlag.hasAlertWord],
      );
      await store.handleEvent(eg.userTopicEvent(
        design.streamId, 'Followed Topic', UserTopicVisibilityPolicy.followed));
      final mWebPub = eg.streamMessage(
        id: 12, stream: webPub, topic: 'Open', sender: bob,
        content: '<p>public announcement</p>',
        flags: [MessageFlag.read, MessageFlag.streamWildcardMentioned],
      );
      final mUnsubPub = eg.streamMessage(
        id: 13, stream: unsubPub, topic: 'News', sender: alice,
        content: '<p>unsubscribed news</p>',
        flags: [MessageFlag.read],
      );
      final mMutedCh = eg.streamMessage(
        id: 14, stream: mutedCh, topic: 'Noisy', sender: alice,
        content: '<p>noisy msg</p>',
        flags: [MessageFlag.read],
      );
      final mUnmutedInMuted = eg.streamMessage(
        id: 15, stream: mutedCh, topic: 'Unmuted In Muted', sender: alice,
        content: '<p>important msg</p>',
        flags: [MessageFlag.read],
      );
      final mMutedTopic = eg.streamMessage(
        id: 16, stream: general, topic: 'Muted Topic', sender: alice,
        content: '<p>shh</p>',
        flags: [MessageFlag.read],
      );
      final mMutedSender = eg.streamMessage(
        id: 17, stream: general, topic: 'Normal', sender: mutedUser,
        content: '<p>hello from muted</p>',
        flags: [MessageFlag.read],
      );
      final mFormerSender = StreamMessage.fromJson({
        ...mGeneral.toJson(),
        'id': 18,
        'sender_id': 9999,
        'sender_email': 'former@example.com',
        'sender_full_name': 'Former Member',
        'subject': 'Archive',
        'content': '<p>legacy note</p>',
        'flags': ['read'],
      });
      final mDmAlice = eg.dmMessage(
        id: 19, from: alice, to: [eg.selfUser],
        content: '<p>direct hello</p>',
        flags: [MessageFlag.read],
      );
      final mGroupDm = eg.dmMessage(
        id: 20, from: eg.selfUser, to: [alice, bob],
        content: '<p>group discussion</p>',
        flags: [MessageFlag.read],
      );
      final mDmMuted = eg.dmMessage(
        id: 21, from: mutedUser, to: [eg.selfUser],
        content: '<p>muted dm</p>',
        flags: [MessageFlag.read],
      );

      bool matches(String query, Message m) =>
        ParsedMessageSearchQuery.parse(query, adapter).matchesMessage(m, adapter);

      // Default visibility & muting.
      check(matches('', mGeneral)).isTrue();
      check(matches('', mUnmutedInMuted)).isTrue();
      check(matches('', mMutedCh)).isFalse();
      check(matches('', mMutedTopic)).isFalse();
      check(matches('', mUnsubPub)).isFalse();
      check(matches('', mMutedSender)).isTrue();
      check(matches('-sender:${mutedUser.email}', mMutedSender)).isFalse();
      check(matches('', mDmMuted)).isFalse();

      // Explicit scope bypasses defaults cleanly.
      check(matches('channels:public', mUnsubPub)).isTrue();
      check(matches('channels:web-public', mWebPub)).isTrue();
      check(matches('channels:web-public', mGeneral)).isFalse();
      check(matches('channel:"Muted Ch"', mMutedCh)).isTrue();
      check(matches('channel:General topic:"Muted Topic"', mMutedTopic)).isTrue();
      check(matches('is:muted', mMutedCh)).isTrue();
      check(matches('is:muted', mDmMuted)).isTrue();
      check(matches('is:muted', mGeneral)).isFalse();
      check(matches('sender:${mutedUser.email}', mMutedSender)).isTrue();
      check(matches('dm:${mutedUser.email}', mDmMuted)).isTrue();

      // Channel, topic, near.
      check(matches('channel:"design team" near:999', mDesign)).isTrue();
      check(matches('-stream:general', mGeneral)).isFalse();
      check(matches('-stream:general', mDesign)).isTrue();
      check(matches('topic:"followed topic"', mDesign)).isTrue();
      check(matches('-topic:"followed topic"', mDesign)).isFalse();

      // Senders (me, email, full name, missing former user fallback).
      check(matches('sender:me', mDesign)).isTrue();
      check(matches('from:alice@example.com', mGeneral)).isTrue();
      check(matches('sender:"Alice Smith"', mGeneral)).isTrue();
      check(matches('sender:former@example.com', mFormerSender)).isTrue();
      check(matches('-sender:me', mDesign)).isFalse();

      // DM operators.
      check(matches('is:dm', mDmAlice)).isTrue();
      check(matches('is:private', mGroupDm)).isTrue();
      check(matches('is:dm', mGeneral)).isFalse();
      check(matches('-is:dm', mDmAlice)).isFalse();
      check(matches('dm:alice@example.com', mDmAlice)).isTrue();
      check(matches('dm:alice@example.com', mGroupDm)).isFalse();
      check(matches('pm-with:alice@example.com,bob@example.com', mGroupDm)).isTrue();
      check(matches('dm-including:alice@example.com', mDmAlice)).isTrue();
      check(matches('dm-including:alice@example.com', mGroupDm)).isTrue();
      check(matches('group-pm-with:bob@example.com', mGroupDm)).isTrue();
      check(matches('group-pm-with:alice@example.com', mDmAlice)).isFalse();

      // Flags & topic properties.
      check(matches('is:starred', mGeneral)).isTrue();
      check(matches('-is:starred', mGeneral)).isFalse();
      check(matches('is:unread', mGeneral)).isTrue();
      check(matches('is:unread', mDesign)).isFalse();
      check(matches('is:mentioned', mGeneral)).isTrue();
      check(matches('is:mentioned', mWebPub)).isTrue();
      check(matches('is:alerted', mDesign)).isTrue();
      check(matches('is:resolved', mGeneral)).isTrue();
      check(matches('-is:resolved', mGeneral)).isFalse();
      check(matches('is:followed', mDesign)).isTrue();
      check(matches('id:10', mGeneral)).isTrue();
      check(matches('-id:10', mGeneral)).isFalse();

      // Has operators.
      check(matches('has:link', mGeneral)).isTrue();
      check(matches('has:attachment', mGeneral)).isTrue();
      check(matches('has:image', mDesign)).isTrue();
      check(matches('-has:image', mDesign)).isFalse();
      final mCustomEmoji = eg.streamMessage(
        id: 22, stream: general, topic: 'Normal', sender: alice,
        content: '<p><img alt=":party:" class="emoji" src="/static/emoji.png"></p>',
      );
      check(matches('has:image', mCustomEmoji)).isFalse();
      final mCustomEmojiWithImage = eg.streamMessage(
        id: 23, stream: general, topic: 'Normal', sender: alice,
        content: '<p><img alt=":party:" class="emoji" src="/static/emoji.png">'
          '<div class="message_inline_image"><img src="/user_uploads/photo.png"></div></p>',
      );
      check(matches('has:image', mCustomEmojiWithImage)).isTrue();
    });
  });

  group('PerAccountStore.searchSavedMessages with SQLite', () {
    test('searches DB-only rows across restart, polls, live star/read overrides, access control, delete, and pagination', () => awaitFakeAsync((async) async {
      UpdateMachine.debugEnableFetchEmojiData = false;

      final pubStream = eg.stream(streamId: 10, name: 'General', inviteOnly: false);
      final privStream = eg.stream(streamId: 20, name: 'Secret', inviteOnly: true);
      final snap1 = eg.initialSnapshot(
        queueId: 'q1',
        lastEventId: 10,
        maxMessageId: 200,
        realmUsers: [eg.selfUser, eg.otherUser],
        streams: [pubStream, privStream],
        subscriptions: [eg.subscription(pubStream), eg.subscription(privStream)],
      );
      final setup1 = await startDbStore(snap: snap1);
      async.elapse(Duration.zero);

      final pollRaw = {
        ...jsonDecode(jsonEncode(eg.streamMessage(
          id: 101,
          stream: pubStream,
          topic: 'Lunch plans',
          sender: eg.selfUser,
          content: '<p></p>',
          flags: [MessageFlag.read],
        ))) as Map<String, dynamic>,
        'submessages': [
          {
            'id': 9001,
            'sender_id': eg.selfUser.userId,
            'msg_type': 'widget',
            'content': jsonEncode({
              'widget_type': 'poll',
              'extra_data': {'question': 'Taco Tuesday?', 'options': ['Beef', 'Veggie']},
            }),
          },
        ],
      };
      final mPoll = Message.fromJson(pollRaw);
      final m102 = eg.streamMessage(
        id: 102, stream: pubStream, topic: 'Café menu', sender: eg.otherUser,
        content: '<p>taco platter</p>', flags: [MessageFlag.read],
      );
      final m103Secret = eg.streamMessage(
        id: 103, stream: privStream, topic: 'Vault', sender: eg.otherUser,
        content: '<p>taco secret recipe</p>', flags: [MessageFlag.read],
      );
      final m104ToDelete = eg.streamMessage(
        id: 104, stream: pubStream, topic: 'Trash', sender: eg.selfUser,
        content: '<p>taco deleted</p>', flags: [MessageFlag.read],
      );

      reconcileWithRaw(
        setup1.um.store,
        ChannelNarrow(pubStream.streamId),
        [mPoll, m102, m104ToDelete],
        resolvedAnchor: 104,
      );
      reconcileWithRaw(
        setup1.um.store,
        ChannelNarrow(privStream.streamId),
        [m103Secret],
        resolvedAnchor: 103,
      );
      await setup1.global.backend
        .messageDbWriterForAccount(eg.selfAccount.id)
        .drainForTesting();
      setup1.um.store.dispose();

      // Restart with no in-memory messages loaded yet (DB-only rows)
      // and simulate losing membership in `privStream` (now inaccessible inviteOnly).
      // Also mark message 102 unread and starred in snapshot/RAM while DB row has read=1, starred=0!
      final setup2 = await startDbStore(
        existingGlobal: setup1.global,
        snap: eg.initialSnapshot(
          queueId: 'q2',
          lastEventId: 10,
          maxMessageId: 200,
          realmUsers: [eg.selfUser, eg.otherUser],
          streams: [pubStream, privStream],
          subscriptions: [eg.subscription(pubStream)], // unsubscribed from inviteOnly privStream!
          starredMessages: [102],
          unreadMsgs: UnreadMessagesSnapshot(
            count: 1,
            channels: [
              UnreadChannelSnapshot(
                streamId: pubStream.streamId,
                topic: eg.t('Café menu'),
                unreadMessageIds: [102],
              ),
            ],
            dms: [],
            huddles: [],
            mentions: [],
            oldUnreadsMissing: false,
          ),
        ),
      );
      async.elapse(Duration.zero);
      final store2 = setup2.um.store;

      // Also delete m104 via event.
      await store2.handleEvent(eg.deleteMessageEvent([m104ToDelete]));

      // Add a newer in-memory-only message matching "taco".
      final m105Ram = eg.streamMessage(
        id: 105, stream: pubStream, topic: 'Fresh', sender: eg.selfUser,
        content: '<p>taco evening</p>', flags: [MessageFlag.read],
      );
      await store2.handleEvent(eg.messageEvent(m105Ram));

      // Clear DB-side memory mirror if needed to prove 101 & 102 come from SQLite,
      // and check limit=2 pagination ascending order.
      check(store2.messages.containsKey(101)).isFalse();
      final page1 = await store2.searchSavedMessages(query: 'taco', limit: 2);
      check(page1).isNotNull();
      check(page1!.messages.map((m) => m.id)).deepEquals([102, 105]);
      check(page1.hasMoreOlder).isTrue();

      final page2 = await store2.searchSavedMessages(
        query: 'taco',
        beforeMessageId: page1.messages.first.id,
        limit: 2,
      );
      // Finds poll message 101 (by poll question "Taco"), skips deleted 104 and inaccessible 103.
      check(page2).isNotNull();
      check(page2!.messages.map((m) => m.id)).deepEquals([101]);
      check(page2.hasMoreOlder).isFalse();

      // RAM overrides: message 102 is starred & unread in live store even though DB stored read=1/starred=0!
      final starredRes = await store2.searchSavedMessages(query: 'is:starred taco', limit: 10);
      check(starredRes).isNotNull();
      check(starredRes!.messages.map((m) => m.id)).deepEquals([102]);

      final unreadRes = await store2.searchSavedMessages(query: 'is:unread taco', limit: 10);
      check(unreadRes).isNotNull();
      check(unreadRes!.messages.map((m) => m.id)).deepEquals([102]);

      await setup2.global.backend.closeMessageDb();
      store2.dispose();
    }));

    test('concurrent delete while SQLite read awaits does not resurrect deleted message', () => awaitFakeAsync((async) async {
      UpdateMachine.debugEnableFetchEmojiData = false;
      final stream = eg.stream(streamId: 10, name: 'General');
      final snap = eg.initialSnapshot(
        queueId: 'q1',
        lastEventId: 10,
        maxMessageId: 50,
        realmUsers: [eg.selfUser],
        streams: [stream],
        subscriptions: [eg.subscription(stream)],
      );
      final setup1 = await startDbStore(snap: snap);
      async.elapse(Duration.zero);

      final m1 = eg.streamMessage(id: 10, stream: stream, topic: 'T', content: '<p>needle one</p>');
      final m2 = eg.streamMessage(id: 20, stream: stream, topic: 'T', content: '<p>needle two</p>');
      reconcileWithRaw(setup1.um.store, ChannelNarrow(stream.streamId), [m1, m2]);
      await setup1.global.backend.messageDbWriterForAccount(eg.selfAccount.id).drainForTesting();
      setup1.um.store.dispose();

      final setup2 = await startDbStore(existingGlobal: setup1.global, snap: snap);
      async.elapse(Duration.zero);
      final store2 = setup2.um.store;

      // Pause SQLite read by holding `messageDbWriteGate`? No, pause a custom read via `nextMessageDbReadError` isn't a gate;
      // use two batches or delete before read resolves. Actually `messageDbWriteGate` doesn't pause reads,
      // wait: deleting m2 via handleEvent triggers a race buffer entry at the next microtask while writer.runRead awaits DB isolate.
      final futureSearch = store2.searchSavedMessages(query: 'needle', limit: 10);
      await store2.handleEvent(eg.deleteMessageEvent([m2]));
      final res = await futureSearch;
      check(res).isNotNull();
      check(res!.messages.map((m) => m.id)).deepEquals([10]);

      await setup2.global.backend.closeMessageDb();
      store2.dispose();
    }));

    test('matches non-Latin FTS5 tokens and avoids loading post-filter misses into RAM', () => awaitFakeAsync((async) async {
      UpdateMachine.debugEnableFetchEmojiData = false;
      final stream = eg.stream(streamId: 10, name: 'General', inviteOnly: false);
      final snap = eg.initialSnapshot(
        queueId: 'q1',
        lastEventId: 10,
        maxMessageId: 100,
        realmUsers: [eg.selfUser],
        streams: [stream],
        subscriptions: [eg.subscription(stream)],
        starredMessages: [10],
        unreadMsgs: UnreadMessagesSnapshot(
          count: 1,
          channels: [
            UnreadChannelSnapshot(
              streamId: stream.streamId,
              topic: eg.t('I18n'),
              unreadMessageIds: [11],
            ),
          ],
          dms: [],
          huddles: [],
          mentions: [],
          oldUnreadsMissing: false,
        ),
      );
      final setup1 = await startDbStore(snap: snap);
      async.elapse(Duration.zero);

      final mKorean = eg.streamMessage(
        id: 10, stream: stream, topic: 'I18n', sender: eg.selfUser,
        content: '<p>한국어 안녕하세요 café</p>', flags: [MessageFlag.read, MessageFlag.starred],
      );
      final mDakuten = eg.streamMessage(
        id: 11, stream: stream, topic: 'I18n', sender: eg.selfUser,
        content: '<p>がっこう に いく</p>', flags: [],
      );
      final mSeion = eg.streamMessage(
        id: 12, stream: stream, topic: 'I18n', sender: eg.selfUser,
        content: '<p>かっこう を みる</p>', flags: [MessageFlag.read],
      );
      final mDevanagari = eg.streamMessage(
        id: 13, stream: stream, topic: 'I18n', sender: eg.selfUser,
        content: '<p>नमस्ते दुनिया</p>', flags: [MessageFlag.read],
      );
      reconcileWithRaw(
        setup1.um.store,
        ChannelNarrow(stream.streamId),
        [mKorean, mDakuten, mSeion, mDevanagari],
        resolvedAnchor: 13,
      );
      await setup1.global.backend
        .messageDbWriterForAccount(eg.selfAccount.id)
        .drainForTesting();
      setup1.um.store.dispose();

      final setup2 = await startDbStore(existingGlobal: setup1.global, snap: snap);
      async.elapse(Duration.zero);
      final store2 = setup2.um.store;
      check(store2.messages).isEmpty();

      // `is:starred` pushes starred IDs into `allowedMessageIds` when not at cap.
      final starredSpec = ParsedMessageSearchQuery.parse(
        'is:starred',
        _PerAccountSearchStore(store2),
      ).sqlSpec;
      check(starredSpec.allowedMessageIds).isNotNull().deepEquals({10});

      // Searching with a post-filter does not retain non-matching DB rows in RAM.
      final unreadRes = await store2.searchSavedMessages(query: 'is:unread', limit: 10);
      check(unreadRes).isNotNull();
      check(unreadRes!.messages.map((m) => m.id)).deepEquals([11]);
      check(store2.messages.keys).deepEquals([11]);

      // Non-Latin FTS5 + Dart post-filter parity.
      final koRes = await store2.searchSavedMessages(query: '한국어', limit: 10);
      check(koRes!.messages.map((m) => m.id)).deepEquals([10]);
      final hiRes = await store2.searchSavedMessages(query: 'नमस्ते', limit: 10);
      check(hiRes!.messages.map((m) => m.id)).deepEquals([13]);
      final jaDakuten = await store2.searchSavedMessages(query: 'がっこう', limit: 10);
      check(jaDakuten!.messages.map((m) => m.id)).deepEquals([11]);
      final jaSeion = await store2.searchSavedMessages(query: 'かっこう', limit: 10);
      check(jaSeion!.messages.map((m) => m.id)).deepEquals([12]);
      final latinAccent = await store2.searchSavedMessages(query: 'cafe', limit: 10);
      check(latinAccent!.messages.map((m) => m.id)).deepEquals([10]);

      await setup2.global.backend.closeMessageDb();
      store2.dispose();
    }));

    test('quoted colon phrases, channel muting, and stroked Latin positive/negative search', () => awaitFakeAsync((async) async {
      UpdateMachine.debugEnableFetchEmojiData = false;
      final publicStream = eg.stream(streamId: 10, name: 'Public', inviteOnly: false);
      final mutedStream = eg.stream(streamId: 11, name: 'Noisy', inviteOnly: false);
      final snap = eg.initialSnapshot(
        queueId: 'q1',
        lastEventId: 10,
        maxMessageId: 100,
        realmUsers: [eg.selfUser],
        streams: [publicStream, mutedStream],
        subscriptions: [
          eg.subscription(publicStream),
          eg.subscription(mutedStream, isMuted: true),
        ],
        userTopics: [
          UserTopicItem(
            streamId: mutedStream.streamId,
            topicName: eg.t('important'),
            lastUpdated: 1,
            visibilityPolicy: UserTopicVisibilityPolicy.unmuted,
          ),
        ],
      );
      final setup = await startDbStore(snap: snap);
      addTearDown(() async {
        await setup.global.backend.closeMessageDb();
        setup.global.dispose();
      });
      async.elapse(Duration.zero);

      final mQuoted = eg.streamMessage(
        id: 21, stream: publicStream, topic: 'note: one', sender: eg.selfUser,
        content: '<p>Literal is:starred phrase</p>', flags: [MessageFlag.read],
      );
      final mStroked = eg.streamMessage(
        id: 22, stream: publicStream, topic: 'Nordic', sender: eg.selfUser,
        content: '<p>Søren visited Łódź</p>', flags: [MessageFlag.read],
      );
      final mMuted = eg.streamMessage(
        id: 23, stream: mutedStream, topic: 'chat', sender: eg.selfUser,
        content: '<p>Muted channel msg</p>', flags: [MessageFlag.read],
      );
      final mUnmutedTopic = eg.streamMessage(
        id: 24, stream: mutedStream, topic: 'important', sender: eg.selfUser,
        content: '<p>Unmuted topic msg</p>', flags: [MessageFlag.read],
      );
      reconcileWithRaw(setup.um.store, ChannelNarrow(publicStream.streamId), [mQuoted, mStroked]);
      reconcileWithRaw(setup.um.store, ChannelNarrow(mutedStream.streamId), [mMuted, mUnmutedTopic]);
      await setup.global.backend
        .messageDbWriterForAccount(eg.selfAccount.id)
        .drainForTesting();
      final store = setup.um.store;

      // Quoted `"is:starred"` searches text rather than requiring starred flag,
      // while `topic:"note: one"` parses `topic:` with value `note: one`.
      final quotedOp = await store.searchSavedMessages(query: '"is:starred"', limit: 10);
      check(quotedOp!.messages.map((m) => m.id)).deepEquals([21]);
      final quotedTopic = await store.searchSavedMessages(query: 'topic:"note: one"', limit: 10);
      check(quotedTopic!.messages.map((m) => m.id)).deepEquals([21]);

      // Channel muting & unmuted topic override:
      final mutedOnly = await store.searchSavedMessages(query: 'is:muted', limit: 10);
      check(mutedOnly!.messages.map((m) => m.id)).deepEquals([23]);
      final publicNotMuted = await store.searchSavedMessages(
        query: 'channels:public -is:muted', limit: 10);
      check(publicNotMuted!.messages.map((m) => m.id)).deepEquals([21, 22, 24]);
      final topicChat = await store.searchSavedMessages(query: 'topic:chat', limit: 10);
      check(topicChat!.messages).isEmpty();
      final topicImportant = await store.searchSavedMessages(query: 'topic:important', limit: 10);
      check(topicImportant!.messages.map((m) => m.id)).deepEquals([24]);

      // Stroked Latin positive and negative match:
      final sorenPos = await store.searchSavedMessages(query: 'soren', limit: 10);
      check(sorenPos!.messages.map((m) => m.id)).deepEquals([22]);
      final sorenNeg = await store.searchSavedMessages(
        query: 'channel:Public -soren', limit: 10);
      check(sorenNeg!.messages.map((m) => m.id)).deepEquals([21]);

      store.dispose();
    }));

    test('is:starred and is:mentioned bypass muting, also in savedMessagesForNarrow', () => awaitFakeAsync((async) async {
      UpdateMachine.debugEnableFetchEmojiData = false;
      final publicStream = eg.stream(streamId: 10, name: 'Public', inviteOnly: false);
      final mutedStream = eg.stream(streamId: 11, name: 'MutedCh', inviteOnly: false);
      final unsubPrivate = eg.stream(streamId: 12, name: 'Secret', inviteOnly: true);
      final otherUser = eg.user(userId: 50);
      final mutedUser = eg.user(userId: 51);
      final snap = eg.initialSnapshot(
        queueId: 'q1',
        lastEventId: 10,
        maxMessageId: 100,
        realmUsers: [eg.selfUser, otherUser, mutedUser],
        streams: [publicStream, mutedStream, unsubPrivate],
        subscriptions: [
          eg.subscription(publicStream),
          eg.subscription(mutedStream, isMuted: true),
        ],
        mutedUsers: [
          MutedUserItem(id: mutedUser.userId),
        ],
        userTopics: [
          UserTopicItem(
            streamId: publicStream.streamId,
            topicName: eg.t('muted topic'),
            lastUpdated: 100,
            visibilityPolicy: UserTopicVisibilityPolicy.muted,
          ),
        ],
        starredMessages: [1, 2, 3, 4],
      );
      final setup = await startDbStore(snap: snap);
      addTearDown(() async {
        await setup.global.backend.closeMessageDb();
        setup.global.dispose();
      });
      async.elapse(Duration.zero);

      final mPublicMention = eg.streamMessage(
        id: 1, stream: publicStream, topic: 'muted topic', sender: otherUser,
        content: '<p>ping</p>', flags: [MessageFlag.read, MessageFlag.mentioned, MessageFlag.starred],
      );
      final mMutedChannelMention = eg.streamMessage(
        id: 2, stream: mutedStream, topic: 'chat', sender: otherUser,
        content: '<p>muted ch mention</p>',
        flags: [MessageFlag.read, MessageFlag.streamWildcardMentioned, MessageFlag.starred],
      );
      final mMutedDmStarredMention = eg.dmMessage(
        id: 3, from: mutedUser, to: [eg.selfUser],
        content: '<p>muted dm</p>',
        flags: [MessageFlag.read, MessageFlag.mentioned, MessageFlag.starred],
      );
      final mSecretStarred = eg.streamMessage(
        id: 4, stream: unsubPrivate, topic: 'priv', sender: otherUser,
        content: '<p>secret</p>', flags: [MessageFlag.read, MessageFlag.starred],
      );
      final mPublicVisible = eg.streamMessage(
        id: 5, stream: publicStream, topic: 'general', sender: otherUser,
        content: '<p>visible</p>', flags: [MessageFlag.read],
      );
      final mDmVisible = eg.dmMessage(
        id: 6, from: otherUser, to: [eg.selfUser],
        content: '<p>dm visible</p>', flags: [MessageFlag.read],
      );

      reconcileWithRaw(setup.um.store, ChannelNarrow(publicStream.streamId), [mPublicMention, mPublicVisible]);
      reconcileWithRaw(setup.um.store, ChannelNarrow(mutedStream.streamId), [mMutedChannelMention]);
      reconcileWithRaw(setup.um.store, DmNarrow.withUser(mutedUser.userId, selfUserId: eg.selfUser.userId), [mMutedDmStarredMention]);
      reconcileWithRaw(setup.um.store, ChannelNarrow(unsubPrivate.streamId), [mSecretStarred]);
      reconcileWithRaw(setup.um.store, DmNarrow.withUser(otherUser.userId, selfUserId: eg.selfUser.userId), [mDmVisible]);
      await setup.global.backend.messageDbWriterForAccount(eg.selfAccount.id).drainForTesting();
      final store = setup.um.store;

      // Search parity: is:starred bypasses channel, topic, and DM muting;
      // is:mentioned bypasses channel and topic muting while respecting DM muting.
      final starredSearch = await store.searchSavedMessages(query: 'is:starred', limit: 10);
      check(starredSearch!.messages.map((m) => m.id)).deepEquals([1, 2, 3]);
      final mentionedSearch = await store.searchSavedMessages(query: 'is:mentioned', limit: 10);
      check(mentionedSearch!.messages.map((m) => m.id)).deepEquals([1, 2]);

      // Synthesized narrows match their live counterparts from DB/RAM cache:
      final combined = await store.savedMessagesForNarrow(const CombinedFeedNarrow(), limit: 10);
      check(combined!.messages.map((m) => m.id)).deepEquals([5, 6]);
      final mentions = await store.savedMessagesForNarrow(const MentionsNarrow(), limit: 10);
      check(mentions!.messages.map((m) => m.id)).deepEquals([1, 2]);
      final starred = await store.savedMessagesForNarrow(const StarredMessagesNarrow(), limit: 10);
      check(starred!.messages.map((m) => m.id)).deepEquals([1, 2, 3]);
      check(await store.savedMessagesForNarrow(ChannelNarrow(publicStream.streamId), limit: 10))
        .isNull();

      store.dispose();
    }));
  });
}
