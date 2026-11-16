import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../api/backoff.dart';
import '../api/exception.dart';
import '../api/model/events.dart';
import '../api/model/model.dart';
import '../api/route/messages.dart';
import '../log.dart';
import 'algorithms.dart';
import 'binding.dart';
import 'channel.dart';
import 'connectivity.dart';
import 'content.dart';
import 'message.dart';
import 'message_coverage.dart';
import 'narrow.dart';
import 'race_buffer.dart';
import 'store.dart';
import 'user.dart';

export '../api/route/messages.dart' show Anchor, AnchorCode, NumericAnchor;

/// The number of messages to fetch in each request.
const kMessageListFetchBatchSize = 100; // TODO tune

/// A message, or one of its siblings shown in the message list.
///
/// See [MessageListView.items], which is a list of these.
sealed class MessageListItem {
  const MessageListItem();
}

class MessageListRecipientHeaderItem extends MessageListItem {
  final MessageBase message;

  MessageListRecipientHeaderItem(this.message);
}

class MessageListDateSeparatorItem extends MessageListItem {
  final MessageBase message;

  MessageListDateSeparatorItem(this.message);
}

/// A [MessageBase] to show in the message list.
sealed class MessageListMessageBaseItem extends MessageListItem {
  MessageBase get message;
  ZulipMessageContent get content;
  bool showSender;
  bool isLastInBlock;

  MessageListMessageBaseItem({
    required this.showSender,
    required this.isLastInBlock,
  });
}

/// A [Message] to show in the message list.
class MessageListMessageItem extends MessageListMessageBaseItem {
  @override
  final Message message;
  @override
  ZulipMessageContent content;

  MessageListMessageItem(
    this.message,
    this.content, {
    required super.showSender,
    required super.isLastInBlock,
  });
}

/// An [OutboxMessage] to show in the message list.
class MessageListOutboxMessageItem extends MessageListMessageBaseItem {
  @override
  final OutboxMessage message;
  @override
  final ZulipContent content;

  MessageListOutboxMessageItem(
    this.message, {
    required super.showSender,
    required super.isLastInBlock,
  }) : content = ZulipContent(nodes: [
    ParagraphNode(links: null, nodes: [TextNode(message.contentMarkdown)]),
  ]);
}

/// The status of outstanding or recent fetch requests from a [MessageListView].
enum FetchingStatus {
  /// The model has not made any fetch requests (since its last reset, if any).
  unstarted,

  /// The model has made a `fetchInitial` request, which hasn't succeeded.
  fetchInitial,

  /// The model made a successful `fetchInitial` request,
  /// and has no outstanding requests or backoff.
  idle,

  /// The model has an active `fetchOlder` or `fetchNewer` request.
  fetchingMore,

  /// The model is in a backoff period from a failed request.
  backoff,
}

/// State of the background network revalidation while a local window is shown.
enum RevalidationState { none, inFlight, failing }

/// How fresh the currently shown window in [MessageListView] is known to be.
enum ContentState { current, unconfirmed, stale }

/// A request in the retry loop of [MessageListView.fetchInitial].
class _FetchInitialAttempt {
  _FetchInitialAttempt({
    required this.sentWhileRecovering,
    required this.connectivityCount,
  });

  /// Whether [PerAccountStore.isRecoveringEventStream] was true
  /// when the request was sent.
  final bool sentWhileRecovering;

  /// The value of [ConnectivityMonitor.updateCount]
  /// when the request was sent.
  final int connectivityCount;

  /// Whether, if the request fails, to retry it at once
  /// rather than after a backoff wait.
  bool retryPromptly = false;

  /// The abort trigger for the request; see [abort].
  Future<void> get abortTrigger => _abortCompleter.future;
  final Completer<void> _abortCompleter = Completer();

  /// Whether [abort] has been called.
  bool get aborted => _abortCompleter.isCompleted;

  /// Abort the request, if it hasn't already completed.
  void abort() {
    if (_abortCompleter.isCompleted) return;
    _abortCompleter.complete();
  }
}

/// The sequence of messages in a message list, and how to display them.
///
/// This comprises much of the guts of [MessageListView].
mixin _MessageSequence {
  PerAccountStore get store;

  /// Whether each message should have its own recipient header,
  /// even if it's in the same conversation as the previous message.
  ///
  /// In some message-list views, notably "Mentions" and "Starred",
  /// it would be misleading to give the impression that consecutive messages
  /// in the same conversation were sent one after the other
  /// with no other messages in between.
  /// By giving each message its own recipient header (a `true` value for this),
  /// we intend to avoid giving that impression.
  @visibleForTesting
  bool get oneMessagePerBlock;

  /// A sequence number for invalidating stale fetches.
  int generation = 0;

  /// The known messages in the list.
  ///
  /// This may or may not represent all the message history that
  /// conceptually belongs in this message list.
  /// That information is expressed in [fetched], [haveOldest], [haveNewest].
  ///
  /// See also [middleMessage], an index which divides this list
  /// into a top slice and a bottom slice.
  ///
  /// See also [contents] and [items].
  final List<Message> messages = [];

  /// An index into [messages] dividing it into a top slice and a bottom slice.
  ///
  /// The indices 0 to before [middleMessage] are the top slice of [messages],
  /// and the indices from [middleMessage] to the end are the bottom slice.
  ///
  /// The corresponding item index is [middleItem].
  int middleMessage = 0;

  /// The ID of the oldest message fetched so far in this narrow,
  /// or of the first message added on a message event
  /// when none had been fetched.
  ///
  /// This is used as the anchor for fetching the next batch of older messages
  /// and will be `null` if no messages of this narrow
  /// have been fetched or added yet.
  ///
  /// A message with this ID might not appear in [messages]:
  /// - The message may be in a muted conversation.
  /// - The message may have been moved or deleted after it was fetched.
  ///
  /// See also [newestFetchedMessageId].
  int? get oldestFetchedMessageId => _oldestFetchedMessageId;
  int? _oldestFetchedMessageId;

  /// The ID of the newest message fetched so far in this narrow,
  /// or of a newer message added on a message event while [haveNewest].
  ///
  /// This is used as the anchor for fetching the next batch of newer messages
  /// and will be `null` if no messages of this narrow
  /// have been fetched or added yet.
  ///
  /// A message with this ID might not appear in [messages]:
  /// - The message may be in a muted conversation.
  /// - The message may have been moved or deleted after it was fetched.
  ///
  /// See also [oldestFetchedMessageId].
  int? get newestFetchedMessageId => _newestFetchedMessageId;
  int? _newestFetchedMessageId;

  /// Whether [messages] and [items] represent the results of a fetch.
  ///
  /// This allows the UI to distinguish "still working on fetching messages"
  /// from "there are in fact no messages here".
  bool get fetched => switch (_status) {
    FetchingStatus.unstarted || FetchingStatus.fetchInitial => false,
    _ => true,
  };

  /// Whether the initial fetch is failing and being retried.
  ///
  /// This becomes true when a request in the retry loop of
  /// [MessageListView.fetchInitial] fails in a way that may be temporary,
  /// for example because the device is offline.
  /// A request the view aborted itself, to retry it at once, doesn't count.
  /// It becomes false when a request succeeds,
  /// or the fetch stops on an error not to retry,
  /// or the view is reset (as by [MessageListView.renarrowAndFetch]).
  ///
  /// While this is true, [fetched] is false.
  bool get fetchInitialFailing => _fetchInitialFailing;
  bool _fetchInitialFailing = false;

  RevalidationState get revalidation => _revalidation;
  RevalidationState _revalidation = RevalidationState.none;

  /// Whether the view is showing local saved-message search results for a
  /// [KeywordSearchNarrow] while the server search has not yet completed.
  bool get showingSavedSearchResults => _showingSavedSearchResults;
  bool _showingSavedSearchResults = false;

  bool _hasUnsupersededStalePiece = false;
  int? _stalePieceOldestVerifiedAt;

  Timer? _staleBannerTimer;
  bool _revalidatingBannerVisible = false;

  bool get atKnownNewest => _atKnownNewest;
  bool _atKnownNewest = false;

  bool get _canShowOutbox => haveNewest || atKnownNewest;

  bool get anchorFallback => _anchorFallback;
  bool _anchorFallback = false;

  bool _exhaustedLocalOlder = false;
  bool _exhaustedLocalNewer = false;
  bool _localOlderBusy = false;
  bool _localNewerBusy = false;
  bool _olderPaginationFailing = false;
  bool _newerPaginationFailing = false;

  /// Whether the top edge should show the "Can't load older messages offline"
  /// affordance instead of a spinner.
  bool get showOfflineOlderNotice =>
    store.coverageEnabled
    && !_haveOldest
    && (_olderPaginationFailing
        || (_revalidation == RevalidationState.failing && _exhaustedLocalOlder));

  /// Whether the bottom edge should show the anchor-fallback offline note.
  bool get showAnchorFallbackOfflineNotice =>
    store.coverageEnabled
    && !_haveNewest
    && _anchorFallback
    && _revalidation == RevalidationState.failing;

  /// Whether the bottom edge should show the "Can't load newer messages offline"
  /// affordance instead of a spinner.
  bool get showOfflineNewerNotice =>
    store.coverageEnabled
    && !_haveNewest
    && !_anchorFallback
    && (_newerPaginationFailing
        || (_revalidation == RevalidationState.failing && _exhaustedLocalNewer));

  bool _localWindowWasLive = false;
  bool _haveNewestInvalidated = false;

  int? _networkOldestId;
  int? _networkNewestId;
  bool _networkHaveOldest = false;
  bool _networkHaveNewest = false;

  /// Whether we know we have the oldest messages for this narrow.
  ///
  /// See also [haveNewest].
  bool get haveOldest => _haveOldest;
  bool _haveOldest = false;

  /// Whether we know we have the newest messages for this narrow.
  ///
  /// See also [haveOldest].
  bool get haveNewest => _haveNewest;
  bool _haveNewest = false;

  /// Whether this message list is currently busy when it comes to
  /// fetching more messages.
  ///
  /// Here "busy" means a new call to fetch more messages would do nothing,
  /// rather than make any request to the server,
  /// as a result of an existing recent request.
  /// This is true both when the recent request is still outstanding,
  /// and when it failed and the backoff from that is still in progress.
  bool get busyFetchingMore => switch (_status) {
    FetchingStatus.fetchingMore || FetchingStatus.backoff => true,
    _ => false,
  };

  FetchingStatus _status = FetchingStatus.unstarted;

  BackoffMachine? _fetchBackoffMachine;

  /// Completed to stop the backoff wait in progress, if any,
  /// in the retry loop of [MessageListView.fetchInitial],
  /// when the loop is no longer wanted.
  ///
  /// See [_cancelFetchInitial].
  Completer<void>? _fetchInitialAbort;

  /// The request in flight, if any,
  /// in the retry loop of [MessageListView.fetchInitial].
  _FetchInitialAttempt? _fetchInitialAttempt;

  /// Timer for showing a [CoverageStatus.stale] local window if the initial
  /// network fetch takes longer than 500 ms.
  Timer? _fetchInitialStaleTimer;

  /// Stop the retry loop of [MessageListView.fetchInitial], if running,
  /// from waiting further on its request or backoff.
  ///
  /// The loop also needs to see, when it resumes, that it should stop;
  /// for example because [generation] has changed.
  void _cancelStaleBannerTimer() {
    _staleBannerTimer?.cancel();
    _staleBannerTimer = null;
    _revalidatingBannerVisible = false;
  }

  void _cancelFetchInitial() {
    _cancelStaleBannerTimer();
    _fetchInitialStaleTimer?.cancel();
    _fetchInitialStaleTimer = null;
    final abort = _fetchInitialAbort;
    _fetchInitialAbort = null;
    abort?.complete();
    final attempt = _fetchInitialAttempt;
    _fetchInitialAttempt = null;
    attempt?.abort();
  }

  /// The parsed message contents, as a list parallel to [messages].
  ///
  /// The i'th element is the result of parsing the i'th element of [messages].
  ///
  /// This information is completely derived from [messages].
  /// It exists as an optimization, to memoize the work of parsing.
  final List<ZulipMessageContent> contents = [];

  /// The [OutboxMessage]s sent by the self-user, retrieved from
  /// [MessageStore.outboxMessages].
  ///
  /// See also [items].
  ///
  /// O(N) iterations through this list are acceptable
  /// because it won't normally have more than a few items.
  final List<OutboxMessage> outboxMessages = [];

  /// The messages and their siblings in the UI, in order.
  ///
  /// This has a [MessageListMessageItem] corresponding to each element
  /// of [messages], in order.  It may have additional items interspersed
  /// before, between, or after the messages. Then, similarly,
  /// [MessageListOutboxMessageItem]s corresponding to [outboxMessages].
  ///
  /// This information is completely derived from [messages], [outboxMessages],
  /// and the flags [haveOldest], [haveNewest], and [busyFetchingMore].
  /// It exists as an optimization, to memoize that computation.
  ///
  /// See also [middleItem], an index which divides this list
  /// into a top slice and a bottom slice.
  final QueueList<MessageListItem> items = QueueList();

  /// An index into [items] dividing it into a top slice and a bottom slice.
  ///
  /// The indices 0 to before [middleItem] are the top slice of [items],
  /// and the indices from [middleItem] to the end are the bottom slice.
  ///
  /// The top slice of [items] corresponds to the top slice of [messages].
  /// The bottom slice of [items] corresponds to the bottom slice of [messages]
  /// plus any [outboxMessages].
  ///
  /// The bottom slice will either be empty
  /// or start with a [MessageListMessageBaseItem].
  /// It will not start with a [MessageListDateSeparatorItem]
  /// or a [MessageListRecipientHeaderItem].
  int middleItem = 0;

  int _findMessageWithId(int messageId) {
    return binarySearchByKey(messages, messageId,
      (message, messageId) => message.id.compareTo(messageId));
  }

  int findItemWithMessageId(int messageId) {
    return binarySearchByKey(items, messageId, _compareItemToMessageId);
  }

  Iterable<Message>? getMessagesRange(int firstMessageId, int lastMessageId) {
    assert(firstMessageId <= lastMessageId);
    final firstIndex = _findMessageWithId(firstMessageId);
    final lastIndex = _findMessageWithId(lastMessageId);
    if (firstIndex == -1 || lastIndex == -1) {
      // TODO(log)
      return null;
    }
    return messages.getRange(firstIndex, lastIndex + 1);
  }

  static int _compareItemToMessageId(MessageListItem item, int messageId) {
    switch (item) {
      case MessageListRecipientHeaderItem(:var message):
      case MessageListDateSeparatorItem(:var message):
        if (message.id == null)                  return 1;
        return message.id! <= messageId ? -1 : 1;
      case MessageListMessageItem(:var message): return message.id.compareTo(messageId);
      case MessageListOutboxMessageItem():       return 1;
    }
  }

  /// Update data derived from the content of the index-th message.
  void _reparseContent(int index) {
    final message = messages[index];
    final content = parseMessageContent(message);
    contents[index] = content;

    final itemIndex = findItemWithMessageId(message.id);
    assert(itemIndex > -1
      && items[itemIndex] is MessageListMessageItem
      && identical((items[itemIndex] as MessageListMessageItem).message, message));
    (items[itemIndex] as MessageListMessageItem).content = content;
  }

  /// Append [message] to [messages], and update derived data accordingly.
  ///
  /// The caller is responsible for ensuring this is an appropriate thing to do
  /// given [narrow], our state of being caught up, and other concerns.
  void _addMessage(Message message) {
    assert(contents.length == messages.length);
    messages.add(message);
    contents.add(parseMessageContent(message));
    assert(contents.length == messages.length);
    _processMessage(messages.length - 1);
  }

  /// Replace the message at [index] with [message],
  /// which must have the same message ID,
  /// and update [contents] accordingly unless [reuseContent] is true.
  ///
  /// The caller is responsible for updating [items],
  /// for example by calling [_reprocessAll].
  void _replaceMessage(int index, Message message, {bool reuseContent = false}) {
    assert(messages[index].id == message.id);
    messages[index] = message;
    if (!reuseContent) {
      contents[index] = parseMessageContent(message);
    }
  }

  /// Removes all messages from the list that satisfy [test].
  ///
  /// Returns true if any messages were removed, false otherwise.
  bool _removeMessagesWhere(bool Function(Message) test) {
    // Before we find a message to remove, there's no need to copy elements.
    // This is like the loop below, but simplified for `target == candidate`.
    int candidate = 0;
    while (true) {
      if (candidate == messages.length) return false;
      if (test(messages[candidate])) break;
      candidate++;
    }

    int target = candidate;
    candidate++;
    assert(contents.length == messages.length);
    while (candidate < messages.length) {
      if (candidate == middleMessage) middleMessage = target;
      if (test(messages[candidate])) {
        candidate++;
        continue;
      }
      messages[target] = messages[candidate];
      contents[target] = contents[candidate];
      target++; candidate++;
    }
    if (candidate == middleMessage) middleMessage = target;
    messages.length = target;
    contents.length = target;
    assert(contents.length == messages.length);
    _reprocessAll();
    return true;
  }

  /// Removes the given messages, if present.
  ///
  /// Returns true if at least one message was present, false otherwise.
  /// If none of [messageIds] are found, this is a no-op.
  bool _removeMessagesById(Iterable<int> messageIds) {
    final messagesToRemoveById = <int>{};
    final contentToRemove = Set<ZulipMessageContent>.identity();
    for (final messageId in messageIds) {
      final index = _findMessageWithId(messageId);
      if (index == -1) continue;
      messagesToRemoveById.add(messageId);
      contentToRemove.add(contents[index]);
    }
    if (messagesToRemoveById.isEmpty) return false;

    if (middleMessage == messages.length) {
      middleMessage -= messagesToRemoveById.length;
    } else {
      final middleMessageId = messages[middleMessage].id;
      middleMessage -= messagesToRemoveById
        .where((id) => id < middleMessageId).length;
    }
    assert(contents.length == messages.length);
    messages.removeWhere((message) => messagesToRemoveById.contains(message.id));
    contents.removeWhere((content) => contentToRemove.contains(content));
    assert(contents.length == messages.length);
    _reprocessAll();

    return true;
  }

  void _insertAllMessages(int index, Iterable<Message> toInsert) {
    // TODO parse/process messages in smaller batches, to not drop frames.
    //   On a Pixel 5, a batch of 100 messages takes ~15-20ms in _insertAllMessages.
    //   (Before that, ~2-5ms in jsonDecode and 0ms in fromJson,
    //   so skip worrying about those steps.)
    final oldLength = messages.length;
    assert(contents.length == messages.length);
    messages.insertAll(index, toInsert);
    contents.insertAll(index, toInsert.map(
      (message) => parseMessageContent(message)));
    assert(contents.length == messages.length);
    if (index <= middleMessage) {
      middleMessage += messages.length - oldLength;
    }
    _reprocessAll();
  }

  /// Append [outboxMessage] to [outboxMessages] and update derived data
  /// accordingly.
  ///
  /// The caller is responsible for ensuring this is an appropriate thing to do
  /// given [narrow] and other concerns.
  void _addOutboxMessage(OutboxMessage outboxMessage) {
    assert(_canShowOutbox);
    assert(!outboxMessages.contains(outboxMessage));
    outboxMessages.add(outboxMessage);
    _processOutboxMessage(outboxMessages.length - 1);
  }

  /// Remove the [outboxMessage] from the view.
  ///
  /// Returns true if the outbox message was removed, false otherwise.
  bool _removeOutboxMessage(OutboxMessage outboxMessage) {
    if (!outboxMessages.remove(outboxMessage)) {
      return false;
    }
    _reprocessOutboxMessages();
    return true;
  }

  /// Remove from [outboxMessages] the outbox message the event's message
  /// was sent as, if any.
  ///
  /// The caller is responsible for updating the corresponding items,
  /// for example by calling [_reprocessOutboxMessages].
  ///
  /// [outboxMessages] is expected to be short, so removing the corresponding
  /// outbox message in linear time is efficient.
  void _removeOutboxMessageOfEvent(MessageEvent event) {
    if (event.localMessageId == null) return;
    final localMessageId = int.parse(event.localMessageId!, radix: 10);
    outboxMessages.removeWhere(
      (message) => message.localMessageId == localMessageId);
  }

  /// Remove all outbox messages that satisfy [test] from [outboxMessages].
  ///
  /// Returns true if any outbox messages were removed, false otherwise.
  bool _removeOutboxMessagesWhere(bool Function(OutboxMessage) test) {
    final count = outboxMessages.length;
    outboxMessages.removeWhere(test);
    if (outboxMessages.length == count) {
      return false;
    }
    _reprocessOutboxMessages();
    return true;
  }

  /// Mark this sequence as no longer having the newest messages,
  /// so that a subsequent [MessageListView.fetchNewer] can find them.
  ///
  /// This removes all [outboxMessages],
  /// preserving the invariant that those are present only when [haveNewest].
  /// See [MessageListView._syncOutboxMessagesFromStore],
  /// which will restore the outbox messages
  /// when a fetch again reaches the newest messages.
  ///
  /// This does not call [notifyListeners].
  void _invalidateHaveNewest() {
    assert(haveNewest);
    _removeOutboxMessagesWhere((_) => true);
    _haveNewest = false;
    _atKnownNewest = false;
    _networkHaveNewest = false;
    _haveNewestInvalidated = true;
  }

  /// Reset all [_MessageSequence] data, and cancel any active fetches.
  void _reset() {
    generation += 1;
    _clearContents();
    _status = FetchingStatus.unstarted;
    _fetchInitialFailing = false;
    _revalidation = RevalidationState.none;
    _showingSavedSearchResults = false;
    _hasUnsupersededStalePiece = false;
    _stalePieceOldestVerifiedAt = null;
    _anchorFallback = false;
    _exhaustedLocalOlder = false;
    _exhaustedLocalNewer = false;
    _localOlderBusy = false;
    _localNewerBusy = false;
    _olderPaginationFailing = false;
    _newerPaginationFailing = false;
    _fetchBackoffMachine = null;
    _cancelFetchInitial();
  }

  void _clearContents() {
    messages.clear();
    middleMessage = 0;
    _oldestFetchedMessageId = null;
    _newestFetchedMessageId = null;
    _networkOldestId = null;
    _networkNewestId = null;
    _networkHaveOldest = false;
    _networkHaveNewest = false;
    outboxMessages.clear();
    _haveOldest = false;
    _haveNewest = false;
    _atKnownNewest = false;
    _localWindowWasLive = false;
    _haveNewestInvalidated = false;
    contents.clear();
    items.clear();
    middleItem = 0;
  }

  /// Redo all computations from scratch, based on [messages].
  void _recompute() {
    assert(contents.length == messages.length);
    contents.clear();
    contents.addAll(messages.map((message) => parseMessageContent(message)));
    assert(contents.length == messages.length);
    _reprocessAll();
  }

  /// Append to [items] based on [message] and [prevMessage].
  ///
  /// This appends a recipient header or a date separator to [items],
  /// depending on how [prevMessage] relates to [message],
  /// and then the result of [buildItem], updating [middleItem] if desired.
  ///
  /// See [middleItem] to determine the value of [shouldSetMiddleItem].
  ///
  /// [prevMessage] should be the message that visually appears before [message].
  ///
  /// The caller must ensure that [prevMessage] and all messages before it
  /// have been processed.
  void _addItemsForMessage(MessageBase message, {
    required bool shouldSetMiddleItem,
    required MessageBase? prevMessage,
    required MessageListMessageBaseItem Function(bool canShareSender) buildItem,
  }) {
    final bool canShareSender;
    if (
      prevMessage == null
      || oneMessagePerBlock
      || !haveSameRecipient(prevMessage, message)
    ) {
      items.add(MessageListRecipientHeaderItem(message));
      canShareSender = false;
    } else {
      assert(items.last is MessageListMessageBaseItem);
      final prevMessageItem = items.last as MessageListMessageBaseItem;
      assert(identical(prevMessageItem.message, prevMessage));
      assert(prevMessageItem.isLastInBlock);
      prevMessageItem.isLastInBlock = false;

      if (!messagesSameDay(prevMessageItem.message, message)) {
        items.add(MessageListDateSeparatorItem(message));
        canShareSender = false;
      } else if (prevMessageItem.message.senderId == message.senderId) {
        canShareSender = messagesCloseInTime(prevMessage, message);
      } else {
        canShareSender = false;
      }
    }
    final item = buildItem(canShareSender);
    assert(identical(item.message, message));
    assert(item.showSender == !canShareSender);
    assert(item.isLastInBlock);
    if (shouldSetMiddleItem) {
      middleItem = items.length;
    }
    items.add(item);
  }

  /// Append to [items] based on the index-th message and its content.
  ///
  /// The previous messages in the list must already have been processed.
  /// This message must already have been parsed and reflected in [contents].
  void _processMessage(int index) {
    assert(items.lastOrNull is! MessageListOutboxMessageItem);
    final prevMessage = index == 0 ? null : messages[index - 1];
    final message = messages[index];
    final content = contents[index];

    _addItemsForMessage(message,
      shouldSetMiddleItem: index == middleMessage,
      prevMessage: prevMessage,
      buildItem: (bool canShareSender) => MessageListMessageItem(
        message, content, showSender: !canShareSender, isLastInBlock: true));
  }

  /// Append to [items] based on the index-th message in [outboxMessages].
  ///
  /// All [messages] and previous messages in [outboxMessages] must already have
  /// been processed.
  void _processOutboxMessage(int index) {
    final prevMessage = index == 0 ? messages.lastOrNull
                                   : outboxMessages[index - 1];
    final message = outboxMessages[index];

    _addItemsForMessage(message,
      // The first outbox message item becomes the middle item
      // when the bottom slice of [messages] is empty.
      shouldSetMiddleItem: index == 0 && middleMessage == messages.length,
      prevMessage: prevMessage,
      buildItem: (bool canShareSender) => MessageListOutboxMessageItem(
        message, showSender: !canShareSender, isLastInBlock: true));
  }

  /// Remove items associated with [outboxMessages] from [items].
  ///
  /// This is designed to be idempotent; repeated calls will not change the
  /// content of [items].
  ///
  /// This is efficient due to the expected small size of [outboxMessages].
  void _removeOutboxMessageItems() {
    // This loop relies on the assumption that all items that follow
    // the last [MessageListMessageItem] are derived from outbox messages.
    while (items.isNotEmpty && items.last is! MessageListMessageItem) {
      items.removeLast();
    }

    if (items.isNotEmpty) {
      final lastItem = items.last as MessageListMessageItem;
      lastItem.isLastInBlock = true;
    }
    if (middleMessage == messages.length) middleItem = items.length;
  }

  /// Recompute the portion of [items] derived from outbox messages,
  /// based on [outboxMessages] and [messages].
  ///
  /// All [messages] should have been processed when this is called.
  void _reprocessOutboxMessages() {
    assert(_canShowOutbox || outboxMessages.isEmpty);
    _removeOutboxMessageItems();
    for (var i = 0; i < outboxMessages.length; i++) {
      _processOutboxMessage(i);
    }
  }

  /// Recompute [items] from scratch, based on [messages], [contents],
  /// [outboxMessages] and flags.
  void _reprocessAll() {
    items.clear();
    for (var i = 0; i < messages.length; i++) {
      _processMessage(i);
    }
    if (middleMessage == messages.length) middleItem = items.length;
    for (var i = 0; i < outboxMessages.length; i++) {
      _processOutboxMessage(i);
    }
  }
}

@visibleForTesting
bool haveSameRecipient(MessageBase prevMessage, MessageBase message) {
  return prevMessage.conversation.isSameAs(message.conversation);
}

@visibleForTesting
bool messagesSameDay(MessageBase prevMessage, MessageBase message) {
  // TODO memoize [DateTime]s... also use memoized for showing date/time in msglist
  final prevTime = dateTimeFromTimestamp(prevMessage.timestamp);
  final time = dateTimeFromTimestamp(message.timestamp);
  if (!_sameDay(prevTime, time)) return false;
  return true;
}

@visibleForTesting
bool messagesCloseInTime(MessageBase prevMessage, MessageBase message) {
  final diffSeconds = (message.timestamp - prevMessage.timestamp).abs();
  return diffSeconds <= 10 * 60;
}

bool _sameDay(DateTime date1, DateTime date2) {
  if (date1.year != date2.year) return false;
  if (date1.month != date2.month) return false;
  if (date1.day != date2.day) return false;
  return true;
}

/// A view-model for a message list.
///
/// The owner of one of these objects must call [dispose] when the object
/// will no longer be used, in order to free resources on the [PerAccountStore].
///
/// Lifecycle:
///  * Create with [init].
///  * Add listeners with [addListener].
///  * Fetch messages with [fetchInitial].  When the fetch completes, this object
///    will notify its listeners (as it will any other time the data changes.)
///  * Fetch more messages as needed with [fetchOlder] and [fetchNewer].
///  * On reassemble, call [reassemble].
///  * When the object will no longer be used, call [dispose] to free
///    resources on the [PerAccountStore].
class MessageListView with ChangeNotifier, _MessageSequence {
  /// Debug hook called when revalidating a live local window changes its
  /// message IDs or message instances beyond racing events.
  @visibleForTesting
  static void Function(MessageListView view, String detail)?
    debugOnLiveRevalidationChanged;
  factory MessageListView.init({
    required PerAccountStore store,
    required Narrow narrow,
    required Anchor anchor,
  }) {
    return MessageListView._(store: store, narrow: narrow, anchor: anchor)
      .._register();
  }

  MessageListView._({
    required this.store,
    required this._narrow,
    required this._anchor,
  });

  @override
  final PerAccountStore store;

  bool _disposed = false;

  /// The narrow shown in this message list.
  ///
  /// This can change over time, notably if showing a topic that gets moved,
  /// or if [renarrowAndFetch] is called.
  Narrow get narrow => _narrow;
  Narrow _narrow;

  /// Set [narrow] and [anchor], reset, [notifyListeners], and [fetchInitial].
  void renarrowAndFetch(Narrow newNarrow, Anchor anchor) {
    assert(!_disposed);
    _narrow = newNarrow;
    _anchor = anchor;
    _reset();
    notifyListeners();
    unawaited(fetchInitial());
  }

  /// The anchor point this message list starts from in the message history.
  ///
  /// This is passed to the server in the get-messages request
  /// sent by [fetchInitial].
  /// That includes not only the original [fetchInitial] call made by
  /// the message-list widget, but any additional [fetchInitial] calls
  /// which might be made internally by this class in order to
  /// fetch the messages from scratch, e.g. after certain events.
  Anchor get anchor => _anchor;
  Anchor _anchor;

  void _register() {
    store.registerMessageList(this);
    _retrySignalSubscription = store.connectivityMonitor.retrySignals
      .listen(_handleConnectivityRetrySignal);
  }

  StreamSubscription<void>? _retrySignalSubscription;

  @override
  void dispose() {
    assert(!_disposed);
    store.unregisterMessageList(this);
    _retrySignalSubscription?.cancel();
    // Fetches in progress check this when they resume, so that they
    // don't act on, or notify listeners of, this disposed object.
    _disposed = true;
    _cancelFetchInitial();
    super.dispose();
  }

  /// How fresh the currently shown window is known to be.
  ContentState get contentState {
    if (_hasUnsupersededStalePiece
        || messages.any((m) => store.isMessageMaybeStale(m.id))) {
      return ContentState.stale;
    }
    if (messages.isNotEmpty && !store.confirmed) {
      return ContentState.unconfirmed;
    }
    return ContentState.current;
  }

  /// Timestamp corresponding to the oldest shown stale or unconfirmed content,
  /// if known.
  DateTime? get contentSavedAt {
    switch (contentState) {
      case ContentState.stale:
        return _timestampFromSeconds(_stalePieceOldestVerifiedAt ?? store.lastLiveAt);
      case ContentState.unconfirmed:
        return _timestampFromSeconds(store.lastLiveAt);
      case ContentState.current:
        return null;
    }
  }

  /// Whether the view should show the "Updating…" banner for possibly stale
  /// content whose revalidation has been in flight for at least 3 seconds.
  bool get showStaleRevalidatingBanner =>
    !_showingSavedSearchResults
    && _revalidation == RevalidationState.inFlight
    && _revalidatingBannerVisible
    && contentState != ContentState.current;

  /// Whether the view should show the offline banner for possibly stale content.
  bool get showStaleOfflineBanner =>
    !_showingSavedSearchResults
    && (_revalidation == RevalidationState.failing
        || _olderPaginationFailing
        || _newerPaginationFailing)
    && contentState != ContentState.current;

  /// Whether empty-state autofocus can safely decide that the narrow is empty.
  bool get canDecideEmptyAutofocus =>
    fetched
    && (messages.isNotEmpty
        || (store.confirmed
            && contentState == ContentState.current
            && haveOldest
            && haveNewest));

  /// Notify this view when [PerAccountStore.confirmed] changes.
  void handleStoreConfirmedChanged() {
    _syncStaleBannerTimer();
    notifyListeners();
  }

  void _syncStaleBannerTimer() {
    if (_disposed
        || _revalidation != RevalidationState.inFlight
        || contentState == ContentState.current) {
      _cancelStaleBannerTimer();
      return;
    }
    if (_revalidatingBannerVisible || _staleBannerTimer != null) return;
    Timer? timer;
    timer = _staleBannerTimer = Timer(const Duration(seconds: 3), () {
      if (identical(_staleBannerTimer, timer)) {
        _staleBannerTimer = null;
      }
      if (_disposed
          || _revalidation != RevalidationState.inFlight
          || contentState == ContentState.current) {
        return;
      }
      _revalidatingBannerVisible = true;
      notifyListeners();
    });
  }

  static DateTime? _timestampFromSeconds(int? seconds) {
    if (seconds == null || seconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  }

  void _setContentStateFromChain(CoverageChain chain) {
    if (chain.status == CoverageStatus.stale) {
      _hasUnsupersededStalePiece = true;
      _stalePieceOldestVerifiedAt = chain.oldestVerifiedAt;
    } else {
      _hasUnsupersededStalePiece = false;
      _stalePieceOldestVerifiedAt = null;
    }
  }

  void _mergeContentStateFromChain(CoverageChain chain) {
    if (chain.status == CoverageStatus.stale) {
      _hasUnsupersededStalePiece = true;
      final ts = chain.oldestVerifiedAt;
      if (ts != null
          && (_stalePieceOldestVerifiedAt == null || ts < _stalePieceOldestVerifiedAt!)) {
        _stalePieceOldestVerifiedAt = ts;
      }
    }
  }

  void _maybeClearSupersededStalePiece() {
    if (!_hasUnsupersededStalePiece || _revalidation != RevalidationState.none) {
      return;
    }
    final olderSuperseded = _networkHaveOldest
      || (_networkOldestId != null
          && _oldestFetchedMessageId != null
          && _networkOldestId! <= _oldestFetchedMessageId!);
    final newerSuperseded = _networkHaveNewest
      || (_networkNewestId != null
          && _newestFetchedMessageId != null
          && _networkNewestId! >= _newestFetchedMessageId!);
    if (olderSuperseded && newerSuperseded) {
      _hasUnsupersededStalePiece = false;
      _stalePieceOldestVerifiedAt = null;
    }
  }

  @override bool get oneMessagePerBlock => switch (narrow) {
    CombinedFeedNarrow()
      || ChannelNarrow()
      || TopicNarrow()
      || DmNarrow() => false,
    MentionsNarrow()
      || StarredMessagesNarrow()
      || KeywordSearchNarrow() => true,
  };

  /// Whether [message] should actually appear in this message list,
  /// given that it does belong to the narrow.
  ///
  /// This depends in particular on whether the message's conversation is muted
  /// in one way or another.
  ///
  /// The muted-users state can influence the result,
  /// but only via [UserStore.shouldMuteDmConversation];
  /// this never returns false just because [message]'s sender is muted.
  /// UI logic mitigates harassment by obscuring messages from muted senders,
  /// with a "reveal" button;
  /// see [RevealedMutedMessagesState] in lib/widgets/message_list.dart.
  // When updating this, check [_willAffectVisibility],
  // [_mutedUsersEventWillAffectVisibility], [handleSubscriptionEvent],
  // and [messagesMoved] to see whether they need to be updated too.
  // Also check the unread-count methods in [Unreads] to make sure they count
  // exactly the unread messages for which this would return true.
  bool _messageVisible(MessageBase message) {
    switch (narrow) {
      case CombinedFeedNarrow():
        final conversation = message.conversation;
        return switch (conversation) {
          StreamConversation(:final streamId, :final topic) =>
            store.isTopicVisible(streamId, topic),
          DmConversation() => !store.shouldMuteDmConversation(
            DmNarrow.ofConversation(conversation, selfUserId: store.selfUserId)),
        };

      case ChannelNarrow(:final channelId):
        assert(message is MessageBase<StreamConversation>
               && message.conversation.streamId == channelId);
        if (message is! MessageBase<StreamConversation>) return false;
        return store.isTopicVisibleInChannel(channelId, message.conversation.topic);

      case TopicNarrow():
        assert((narrow as TopicNarrow).containsMessage(message));
        return true;

      case DmNarrow():
        assert((narrow as DmNarrow).containsMessage(message));
        return true;

      case MentionsNarrow():
        // If changing this, consider whether [Unreads.countInMentionsNarrow]
        // should be changed correspondingly, so the message-list view matches
        // the unread-count badge.
        if (message.conversation case DmConversation(:final allRecipientIds)) {
          return !store.shouldMuteDmConversation(DmNarrow(
            allRecipientIds: allRecipientIds, selfUserId: store.selfUserId));
        }
        return true;

      case StarredMessagesNarrow():
        // Include messages even if muted in some way.
        // Other users can't spam the starred-messages view by starring;
        // the starred state is read/write by the self-user only.
        //
        // If we want to change this, consider that we need to compute a
        // starred-message count without relying on fetched message data:
        //   https://zulip.com/help/star-a-message#view-your-starred-messages
        // ([MessageStore.starredMessages] is just a list of message IDs.)
        return true;

      case KeywordSearchNarrow():
        if (message.conversation case DmConversation(:final allRecipientIds)) {
          return !store.shouldMuteDmConversation(DmNarrow(
            allRecipientIds: allRecipientIds, selfUserId: store.selfUserId));
        }
        return true;
    }
  }

  /// Whether [message] belongs in this view after a fetch, accounting for
  /// both [narrow] (which may no longer match if a move raced the fetch) and
  /// [_messageVisible].
  bool _messageBelongsInFetchedView(MessageBase message) {
    final matchesNarrow = switch (narrow) {
      ChannelNarrow() || TopicNarrow() || DmNarrow() =>
        narrow.containsMessage(message) != false,
      CombinedFeedNarrow() ||
      MentionsNarrow() ||
      StarredMessagesNarrow() ||
      KeywordSearchNarrow() =>
        true,
    };
    return matchesNarrow && _messageVisible(message);
  }

  /// Whether [message] is known to belong in [narrow], and is visible
  /// ([_messageVisible]).
  bool _messageBelongsHere(MessageBase message) =>
    narrow.containsMessage(message) == true && _messageVisible(message);

  /// Whether this event could affect the result that [_messageVisible]
  /// would ever have returned for any possible message in this message list.
  TopicVisibilityEffect _willAffectVisibility(Event event) {
    switch (narrow) {
      case CombinedFeedNarrow():
        return store.willAffectIfTopicVisible(event);

      case ChannelNarrow(:final channelId):
        return store.willAffectIfTopicVisibleInChannel(channelId, event);

      case TopicNarrow():
      case DmNarrow():
      case MentionsNarrow():
      case StarredMessagesNarrow():
      case KeywordSearchNarrow():
        return TopicVisibilityEffect.none;
    }
  }

  /// Whether this event could affect the result that [_messageVisible]
  /// would ever have returned for any possible message in this message list.
  MutedUsersVisibilityEffect _mutedUsersEventWillAffectVisibility(MutedUsersEvent event) {
    switch(narrow) {
      case CombinedFeedNarrow():
        return store.willAffectShouldMuteDmConversation(event);

      case ChannelNarrow():
      case TopicNarrow():
      case DmNarrow():
        return MutedUsersVisibilityEffect.none;

      case MentionsNarrow():
        return store.willAffectShouldMuteDmConversation(event);

      case StarredMessagesNarrow():
        return MutedUsersVisibilityEffect.none;

      case KeywordSearchNarrow():
        return store.willAffectShouldMuteDmConversation(event);
    }
  }

  void _setStatus(FetchingStatus value, {FetchingStatus? was}) {
    assert(was == null || _status == was);
    _status = value;
    if (!fetched) return;
    notifyListeners();
  }

  /// Fetch messages, starting from scratch.
  ///
  /// If the request fails in a way that may be temporary,
  /// such as a network failure or a 5xx error,
  /// this retries with backoff until a request succeeds,
  /// or until this view is disposed or reset (as by [renarrowAndFetch]),
  /// or the store is disposed.
  /// See [isRetryableRequestError].
  /// On other errors, this throws.
  Future<void> fetchInitial({bool skipInitialLocal = false}) async {
    assert(!_disposed);
    assert(!fetched && !haveOldest && !haveNewest && !busyFetchingMore);
    assert(messages.isEmpty && contents.isEmpty);
    assert(oldestFetchedMessageId == null && newestFetchedMessageId == null);

    if (narrow case KeywordSearchNarrow(keyword: '')) {
      // The server would reject an empty keyword search; skip the request.
      // TODO this seems like an awkward layer to handle this at --
      //   probably better if the UI code doesn't take it to this point.
      _haveOldest = true;
      _haveNewest = true;
      _setStatus(FetchingStatus.idle, was: FetchingStatus.unstarted);
      return;
    }

    _setStatus(FetchingStatus.fetchInitial, was: FetchingStatus.unstarted);
    // TODO schedule all this in another isolate
    final generation = this.generation;
    bool isStale() => _disposed || store.disposed || this.generation != generation;
    assert(_fetchInitialAbort == null);
    final abort = _fetchInitialAbort = Completer<void>();

    BackoffMachine? backoffMachine;
    GetMessagesResult result;
    FetchTicket? ticket;
    bool redirected = false;
    final int? narrowChannelId = switch (narrow) {
      ChannelNarrow(:final channelId) || TopicNarrow(:final channelId) => channelId,
      _ => null,
    };

    bool networkDone = false;
    bool initialLocalSuperseded = false;
    Timer? staleTimer;
    if (!skipInitialLocal) {
      if (narrow is KeywordSearchNarrow && store.coverageEnabled) {
        void runSavedSearch() {
          final searchQuery = (narrow as KeywordSearchNarrow).keyword;
          unawaited(store.searchSavedMessages(
            query: searchQuery,
            limit: kMessageListFetchBatchSize,
          ).then((savedSearch) {
            if (networkDone || initialLocalSuperseded || isStale()
                || _status != FetchingStatus.fetchInitial
                || _revalidation != RevalidationState.none) {
              return;
            }
            if (savedSearch == null) return;
            initialLocalSuperseded = true;
            _showSavedSearchResults(
              savedSearch,
              revalidation: RevalidationState.inFlight,
            );
          }).catchError((_) {}));
        }
        if (!store.connectivityMonitor.hasConnectivity) {
          runSavedSearch();
        } else {
          staleTimer = _fetchInitialStaleTimer = Timer(
            const Duration(milliseconds: 500),
            () {
              if (identical(_fetchInitialStaleTimer, staleTimer)) {
                _fetchInitialStaleTimer = null;
              }
              if (networkDone || initialLocalSuperseded || isStale()
                  || _status != FetchingStatus.fetchInitial
                  || _revalidation != RevalidationState.none) {
                return;
              }
              runSavedSearch();
            },
          );
        }
      } else if (store.dbActive) {
        final localStopwatch = ZulipBinding.instance.stopwatch()..start();
        unawaited(_findLocalWindowAsync(afterFailure: false).then((found) {
          if (networkDone || initialLocalSuperseded || isStale()
              || _status != FetchingStatus.fetchInitial
              || _revalidation != RevalidationState.none) {
            return;
          }
          if (found == null) return;
          final (local, usedFallback) = found;
          if (local.chain.status != CoverageStatus.stale) {
            _showLocalWindow(
              local,
              usedFallback: usedFallback,
              revalidation: RevalidationState.inFlight,
            );
            return;
          }
          final remaining = const Duration(milliseconds: 500) - localStopwatch.elapsed;
          if (remaining <= Duration.zero) {
            _showLocalWindow(
              local,
              usedFallback: usedFallback,
              revalidation: RevalidationState.inFlight,
            );
          } else {
            staleTimer = _fetchInitialStaleTimer = Timer(remaining, () {
              if (identical(_fetchInitialStaleTimer, staleTimer)) {
                _fetchInitialStaleTimer = null;
              }
              if (networkDone || initialLocalSuperseded || isStale()
                  || _status != FetchingStatus.fetchInitial
                  || _revalidation != RevalidationState.none) {
                return;
              }
              _showLocalWindow(
                local,
                usedFallback: usedFallback,
                revalidation: RevalidationState.inFlight,
              );
            });
          }
        }).catchError((_) {}));
      } else {
        final initialLocal = _findLocalWindow(afterFailure: false);
        if (initialLocal != null) {
          final (local, usedFallback) = initialLocal;
          if (local.chain.status != CoverageStatus.stale) {
            _showLocalWindow(
              local,
              usedFallback: usedFallback,
              revalidation: RevalidationState.inFlight,
            );
          } else {
            staleTimer = _fetchInitialStaleTimer = Timer(
              const Duration(milliseconds: 500),
              () {
                if (identical(_fetchInitialStaleTimer, staleTimer)) {
                  _fetchInitialStaleTimer = null;
                }
                if (isStale() || _revalidation != RevalidationState.none) return;
                final delayedLocal = _findLocalWindow(afterFailure: false);
                if (delayedLocal == null) return;
                _showLocalWindow(
                  delayedLocal.$1,
                  usedFallback: delayedLocal.$2,
                  revalidation: RevalidationState.inFlight,
                );
              },
            );
          }
        }
      }
    }

    try {
      while (true) {
        assert(_fetchInitialAttempt == null);
        final attempt = _fetchInitialAttempt = _FetchInitialAttempt(
          sentWhileRecovering: store.isRecoveringEventStream,
          connectivityCount: store.connectivityMonitor.updateCount);
        final attemptTicket = ticket = store.openFetchTicket(channelId: narrowChannelId);
        try {
          result = await getMessages(store.connection,
            narrow: narrow.apiEncode(),
            anchor: anchor,
            numBefore: kMessageListFetchBatchSize,
            numAfter: kMessageListFetchBatchSize,
            allowEmptyTopicName: true,
            abortTrigger: attempt.abortTrigger,
          );
          break;
        } catch (e) {
          store.closeFetchTicket(attemptTicket);
          ticket = null;
          if (isStale()) return;
          if (!isRetryableRequestError(e)) {
            _fetchInitialAbort = null;
            if (_revalidation != RevalidationState.none) {
              _reset();
              notifyListeners();
            } else if (fetchInitialFailing) {
              _fetchInitialFailing = false;
              notifyListeners(); // [_setStatus] wouldn't, as [fetched] is false
            }
            rethrow;
          }
          // If we aborted the request ourselves, to retry promptly,
          // the retry may well succeed fast; don't count it as failing.
          if (!attempt.aborted) {
            if (_revalidation != RevalidationState.none) {
              if (_revalidation != RevalidationState.failing) {
                _revalidation = RevalidationState.failing;
                _syncStaleBannerTimer();
                notifyListeners();
              }
            } else {
              staleTimer?.cancel();
              if (identical(_fetchInitialStaleTimer, staleTimer)) {
                _fetchInitialStaleTimer = null;
              }
              initialLocalSuperseded = true;
              if (narrow is KeywordSearchNarrow && store.coverageEnabled) {
                final savedSearch = await store.searchSavedMessages(
                  query: (narrow as KeywordSearchNarrow).keyword,
                  limit: kMessageListFetchBatchSize,
                );
                if (isStale()) return;
                if (savedSearch != null) {
                  _showSavedSearchResults(
                    savedSearch,
                    revalidation: RevalidationState.failing,
                  );
                } else if (!fetchInitialFailing) {
                  _fetchInitialFailing = true;
                  notifyListeners(); // [_setStatus] wouldn't, as [fetched] is false
                }
              } else {
                final failureLocal = store.dbActive
                  ? await _findLocalWindowAsync(afterFailure: true)
                  : _findLocalWindow(afterFailure: true);
                if (isStale()) return;
                if (failureLocal != null) {
                  _showLocalWindow(
                    failureLocal.$1,
                    usedFallback: failureLocal.$2,
                    revalidation: RevalidationState.failing,
                  );
                } else if (!fetchInitialFailing) {
                  _fetchInitialFailing = true;
                  notifyListeners(); // [_setStatus] wouldn't, as [fetched] is false
                }
              }
            }
          }
        } finally {
          if (identical(_fetchInitialAttempt, attempt)) _fetchInitialAttempt = null;
        }
        // TODO(log) the error
        if (attempt.retryPromptly) {
          // The network is probably working again, or is a new one;
          // see [handleEventStreamRecovered] and [_handleConnectivityRetrySignal].
          // Retry now, and if that fails too, start backoff over small.
          backoffMachine = null;
          continue;
        }
        final wake = _fetchInitialBackoffWake = Completer<void>();
        await (backoffMachine ??= BackoffMachine())
          .wait(abortTrigger: Future.any([abort.future, wake.future]));
        if (isStale()) return;
        _fetchInitialBackoffWake = null;
        if (wake.isCompleted) {
          // The network is probably working again;
          // if the retry fails anyway, start backoff over small.
          backoffMachine = null;
        }
      }
      if (isStale()) return;
      networkDone = true;
      _fetchInitialAbort = null;
      staleTimer?.cancel();
      if (identical(_fetchInitialStaleTimer, staleTimer)) {
        _fetchInitialStaleTimer = null;
      }

      final narrowBefore = narrow;
      _adjustNarrowForTopicPermalink(result.messages.firstOrNull);
      redirected = narrow != narrowBefore;

      store.reconcileMessages(
        result.messages,
        rawMessages: result.rawMessages,
        ticket: ticket,
        requester: this,
        coverageRequest: FetchCoverageRequest(
          narrow: narrow,
          numBefore: kMessageListFetchBatchSize,
          numAfter: kMessageListFetchBatchSize,
          includeAnchor: true,
          foundOldest: result.foundOldest,
          foundNewest: result.foundNewest,
          historyLimited: result.historyLimited,
          resolvedAnchor: result.anchor,
        ),
      );
      store.recentSenders.handleMessages(result.messages); // TODO(#824)
    } finally {
      _cancelStaleBannerTimer();
      staleTimer?.cancel();
      if (identical(_fetchInitialStaleTimer, staleTimer)) {
        _fetchInitialStaleTimer = null;
      }
      if (ticket != null) {
        store.closeFetchTicket(ticket);
      }
    }
    if (isStale()) return;

    _networkOldestId = result.messages.firstOrNull?.id;
    _networkNewestId = result.messages.lastOrNull?.id;
    _networkHaveOldest = result.foundOldest;
    _networkHaveNewest = result.foundNewest;

    if (_revalidation == RevalidationState.none) {
      _populateFromResult(
        messages: result.messages,
        anchorId: result.anchor,
        foundOldest: result.foundOldest,
        foundNewest: result.foundNewest,
      );
      _atKnownNewest = haveNewest;
      _hasUnsupersededStalePiece = false;
      _stalePieceOldestVerifiedAt = null;
      _syncStaleBannerTimer();
      _fetchInitialFailing = false;
      _setStatus(FetchingStatus.idle, was: FetchingStatus.fetchInitial);
    } else {
      final wasAnchorFallback = _anchorFallback;
      final wasShowingSavedSearch = _showingSavedSearchResults;
      _revalidation = RevalidationState.none;
      _showingSavedSearchResults = false;
      _anchorFallback = false;
      _exhaustedLocalOlder = false;
      _exhaustedLocalNewer = false;
      _olderPaginationFailing = false;
      _newerPaginationFailing = false;
      _hasUnsupersededStalePiece = false;
      _stalePieceOldestVerifiedAt = null;
      _syncStaleBannerTimer();
      if (redirected || wasAnchorFallback || wasShowingSavedSearch) {
        _clearContents();
        _populateFromResult(
          messages: result.messages,
          anchorId: result.anchor,
          foundOldest: result.foundOldest,
          foundNewest: result.foundNewest,
        );
        _atKnownNewest = haveNewest;
        notifyListeners();
      } else {
        _mergeWindow(result);
        notifyListeners();
      }
    }
  }

  (LocalWindow, bool)? _findLocalWindow({required bool afterFailure}) {
    final direct = store.localWindow(
      narrow,
      anchor,
      kMessageListFetchBatchSize,
      kMessageListFetchBatchSize,
      afterFailure: afterFailure,
    );
    if (direct != null) return (direct, false);
    if (afterFailure && anchor != AnchorCode.newest) {
      final fallback = store.localWindow(
        narrow,
        AnchorCode.newest,
        kMessageListFetchBatchSize,
        kMessageListFetchBatchSize,
        afterFailure: true,
      );
      if (fallback != null) return (fallback, true);
    }
    return null;
  }

  Future<(LocalWindow, bool)?> _findLocalWindowAsync({required bool afterFailure}) async {
    final direct = await store.localWindowAsync(
      narrow,
      anchor,
      kMessageListFetchBatchSize,
      kMessageListFetchBatchSize,
      afterFailure: afterFailure,
    );
    if (direct != null) return (direct, false);
    if (afterFailure && anchor != AnchorCode.newest) {
      final fallback = await store.localWindowAsync(
        narrow,
        AnchorCode.newest,
        kMessageListFetchBatchSize,
        kMessageListFetchBatchSize,
        afterFailure: true,
      );
      if (fallback != null) return (fallback, true);
    }
    return null;
  }

  void _showLocalWindow(
    LocalWindow local, {
    required bool usedFallback,
    required RevalidationState revalidation,
  }) {
    _anchorFallback = usedFallback;
    _localWindowWasLive = local.chain.status == CoverageStatus.live && !usedFallback;
    _setContentStateFromChain(local.chain);
    _populateFromResult(
      messages: local.messages,
      anchorId: local.anchorId,
      foundOldest: local.haveOldest,
      foundNewest: local.haveNewest,
      atKnownNewest: local.atKnownNewest,
    );
    _fetchInitialFailing = false;
    _revalidation = revalidation;
    _syncStaleBannerTimer();
    _setStatus(FetchingStatus.idle, was: FetchingStatus.fetchInitial);
  }

  void _showSavedSearchResults(
    SavedMessageSearchResult saved, {
    required RevalidationState revalidation,
  }) {
    _showingSavedSearchResults = true;
    _anchorFallback = false;
    _localWindowWasLive = false;
    _hasUnsupersededStalePiece = false;
    _stalePieceOldestVerifiedAt = null;
    _exhaustedLocalOlder = false;
    _exhaustedLocalNewer = false;
    _olderPaginationFailing = false;
    _newerPaginationFailing = false;
    _populateFromResult(
      messages: saved.messages,
      anchorId: saved.messages.lastOrNull?.id ?? kNewestMessageId,
      foundOldest: false,
      foundNewest: true,
      atKnownNewest: true,
    );
    _fetchInitialFailing = false;
    _revalidation = revalidation;
    _syncStaleBannerTimer();
    _setStatus(FetchingStatus.idle, was: FetchingStatus.fetchInitial);
  }

  void _mergeWindow(GetMessagesResult result) {
    final wasLive = _localWindowWasLive;
    _localWindowWasLive = false;
    final sentOutbox = [
      for (final om in outboxMessages)
        if (om.state == OutboxMessageState.sent) om,
    ];
    final l = result.foundOldest
      ? 0
      : (result.messages.firstOrNull?.id ?? result.anchor);
    final h = result.foundNewest
      ? kNewestMessageId
      : (result.messages.lastOrNull?.id ?? result.anchor);

    final disjoint = messages.isNotEmpty
      && (h < messages.first.id || l > messages.last.id);
    if (disjoint) {
      assert(() {
        if (wasLive) {
          _reportLiveRevalidationChanged('disjoint window [$l, $h]');
        }
        return true;
      }());
      _clearContents();
      _populateFromResult(
        messages: result.messages,
        anchorId: result.anchor,
        foundOldest: result.foundOldest,
        foundNewest: result.foundNewest,
      );
      if (_canShowOutbox) {
        var addedSent = false;
        for (final om in sentOutbox) {
          if (om.messageId != null
              && _findMessageWithId(om.messageId!) == -1
              && outboxMessages.none((x) => x.localMessageId == om.localMessageId)) {
            outboxMessages.add(om);
            addedSent = true;
          }
        }
        if (addedSent) {
          _reprocessOutboxMessages();
        }
      }
      return;
    }

    final oldContentsById = <int, (Message, ZulipMessageContent)>{
      for (int i = 0; i < messages.length; i++)
        messages[i].id: (messages[i], contents[i]),
    };
    final oldMiddleId = messages.isNotEmpty && middleMessage < messages.length
      ? messages[middleMessage].id
      : null;
    final oldTopId = messages.lastOrNull?.id;
    final wasAtEnd = messages.isEmpty || middleMessage == messages.length - 1;

    // Collect merged messages:
    // - outside [l, h]: keep existing messages still in store & visible
    // - inside [l, h]: union of result.messages and existing messages (like
    //   racing event arrivals) that are still in store & visible.
    final byId = <int, Message>{};
    for (final m in messages) {
      final current = store.messages[m.id];
      if (current != null
          && !store.isLocationUnknown(current.id)
          && _messageBelongsInFetchedView(current)) {
        byId[m.id] = current;
      }
    }
    for (final m in result.messages) {
      final current = store.messages[m.id] ?? m;
      if (_messageBelongsInFetchedView(current)) {
        byId[current.id] = current;
      }
    }

    final merged = byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));

    assert(() {
      if (wasLive) {
        _debugCheckLiveRevalidation(l, h, oldContentsById, merged);
      }
      return true;
    }());

    final belowL = merged.any((m) => m.id < l);
    final aboveH = merged.any((m) => m.id > h);
    _haveOldest = result.foundOldest || (belowL && _haveOldest);
    _haveNewest = result.foundNewest || (aboveH && _haveNewest);
    _atKnownNewest = haveNewest;
    _oldestFetchedMessageId = result.foundOldest
      ? (merged.firstOrNull?.id ?? _oldestFetchedMessageId)
      : _minNullable(_oldestFetchedMessageId, result.messages.firstOrNull?.id);
    _newestFetchedMessageId = result.foundNewest
      ? (merged.lastOrNull?.id ?? _newestFetchedMessageId)
      : _maxNullable(_newestFetchedMessageId, result.messages.lastOrNull?.id);

    messages
      ..clear()
      ..addAll(merged);
    contents.clear();
    for (final m in merged) {
      final prev = oldContentsById[m.id];
      if (prev != null
          && prev.$1.content == m.content
          && prev.$1.poll == null
          && m.poll == null) {
        contents.add(prev.$2);
      } else {
        contents.add(parseMessageContent(m));
      }
    }

    if (merged.isEmpty) {
      middleMessage = 0;
    } else if (anchor == AnchorCode.newest
        && wasAtEnd
        && oldTopId != null
        && merged.last.id > oldTopId) {
      middleMessage = merged.length - 1;
    } else if (oldMiddleId != null) {
      final idx = merged.indexWhere((m) => m.id >= oldMiddleId);
      middleMessage = idx == -1 ? merged.length - 1 : idx;
    } else {
      final idx = merged.indexWhere((m) => m.id >= result.anchor);
      middleMessage = idx == -1 ? merged.length - 1 : idx;
    }

    _reconcileOutboxMessages();
    _reprocessAll();
  }

  void _debugCheckLiveRevalidation(
    int l,
    int h,
    Map<int, (Message, ZulipMessageContent)> oldContentsById,
    List<Message> merged,
  ) {
    final mergedById = <int, Message>{for (final m in merged) m.id: m};
    for (final m in merged) {
      if (m.id < l || m.id > h) continue;
      final prev = oldContentsById[m.id];
      if (prev == null) {
        _reportLiveRevalidationChanged('added message ${m.id}');
        return;
      }
      if (!identical(prev.$1, m)) {
        _reportLiveRevalidationChanged('replaced message ${m.id}');
        return;
      }
    }
    for (final id in oldContentsById.keys) {
      if (id < l || id > h) continue;
      if (!mergedById.containsKey(id)) {
        _reportLiveRevalidationChanged('removed message $id');
        return;
      }
    }
  }

  void _reportLiveRevalidationChanged(String detail) {
    final callback = MessageListView.debugOnLiveRevalidationChanged;
    if (callback != null) {
      callback(this, detail);
    } else {
      assert(debugLog('revalidation changed live data ($narrow): $detail'));
    }
  }

  static int? _minNullable(int? a, int? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a < b ? a : b;
  }

  static int? _maxNullable(int? a, int? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a > b ? a : b;
  }

  void _populateFromResult({
    required List<Message> messages,
    required int anchorId,
    required bool foundOldest,
    required bool foundNewest,
    bool? atKnownNewest,
  }) {
    _oldestFetchedMessageId = messages.firstOrNull?.id;
    _newestFetchedMessageId = messages.lastOrNull?.id;

    // The bottom slice will start at the "anchor message".
    // This is the first visible message at or past [anchor] if any,
    // else the last visible message if any.  [reachedAnchor] helps track that.
    bool reachedAnchor = false;
    for (final message in messages) {
      if (!_messageBelongsInFetchedView(message)) continue;
      if (!reachedAnchor) {
        // Push the previous message into the top slice.
        middleMessage = this.messages.length;
        // We could interpret [anchor] for ourselves; but the server has already
        // done that work, reducing it to an int, `result.anchor`.  So use that.
        reachedAnchor = message.id >= anchorId;
      }
      _addMessage(message);
    }
    _haveOldest = foundOldest;
    _haveNewest = foundNewest;
    _atKnownNewest = atKnownNewest ?? foundNewest;

    if (_canShowOutbox) {
      _syncOutboxMessagesFromStore();
    }
  }

  /// Completed to cut short the backoff wait in progress, if any,
  /// in the retry loop of [fetchInitial].
  ///
  /// See [handleEventStreamRecovered].
  Completer<void>? _fetchInitialBackoffWake;

  /// Called when the store's event stream has recovered from failures:
  /// [PerAccountStore.isRecoveringEventStream] has become false.
  ///
  /// If [fetchInitial] is waiting to retry, this makes it retry now,
  /// because the network is probably working again.
  ///
  /// If [fetchInitial] has a request in flight
  /// that was sent while the event stream was recovering,
  /// the request may be stuck on a dead connection;
  /// this aborts it, so that [fetchInitial] retries now.
  /// If the request in flight was sent otherwise,
  /// and goes on to fail, [fetchInitial] retries without waiting.
  void handleEventStreamRecovered() {
    if (_fetchInitialAttempt case final attempt?) {
      attempt.retryPromptly = true;
      if (attempt.sentWhileRecovering) attempt.abort();
    }
    final wake = _fetchInitialBackoffWake;
    _fetchInitialBackoffWake = null;
    wake?.complete();
  }

  /// Handle a [ConnectivityMonitor.retrySignals] event:
  /// the network changed.
  ///
  /// A [fetchInitial] request sent before the change
  /// may be stuck on a dead connection; abort it,
  /// so that [fetchInitial] retries now on the new network.
  ///
  /// Compare [UpdateMachine]'s handling of the same signal.
  void _handleConnectivityRetrySignal(void _) {
    final attempt = _fetchInitialAttempt;
    if (attempt == null) return;
    if (attempt.connectivityCount == store.connectivityMonitor.updateCount) {
      // The request was sent after the change.
      return;
    }
    attempt.retryPromptly = true;
    attempt.abort();
  }

  /// Update [narrow] for the result of a "with" narrow (topic permalink) fetch.
  ///
  /// To avoid an extra round trip, the server handles [ApiNarrowWith]
  /// by returning results from the indicated message's current stream/topic
  /// (if the user has access),
  /// even if that differs from the narrow's stream/topic filters
  /// because the message was moved.
  ///
  /// If such a "redirect" happened, this helper updates the stream and topic
  /// in [narrow] to match the message's current conversation.
  /// It also removes the "with" component from [narrow]
  /// whether or not a redirect happened.
  ///
  /// See API doc:
  ///   https://zulip.com/api/construct-narrow#message-ids
  void _adjustNarrowForTopicPermalink(Message? someFetchedMessageOrNull) {
    final narrow = this.narrow;
    if (narrow is! TopicNarrow || narrow.with_ == null) return;

    switch (someFetchedMessageOrNull) {
      case null:
        // This can't be a redirect; a redirect can't produce an empty result.
        // (The server only redirects if the message is accessible to the user,
        // and if it is, it'll appear in the result, making it non-empty.)
        _narrow = narrow.sansWith();
      case StreamMessage():
        _narrow = TopicNarrow.ofMessage(someFetchedMessageOrNull);
      case DmMessage(): // TODO(log)
        assert(false);
    }
  }

  /// Fetch the next batch of older messages, if applicable.
  ///
  /// If there are no older messages to fetch (i.e. if [haveOldest]),
  /// or if this message list is already busy fetching more messages
  /// (i.e. if [busyFetchingMore], which includes backoff from failed requests),
  /// then this method does nothing and immediately returns.
  /// That makes this method suitable to call frequently, e.g. every frame,
  /// whenever it looks likely to be useful to have more messages.
  Future<void> fetchOlder() async {
    assert(!_disposed);
    if (haveOldest) return;
    if (_revalidation != RevalidationState.none) {
      if (_localOlderBusy) return;
      _localOlderBusy = true;
      final bool didLoad;
      try {
        if (_showingSavedSearchResults && narrow is KeywordSearchNarrow) {
          didLoad = await _fetchOlderSavedSearchAsync();
        } else if (store.dbActive) {
          didLoad = await _fetchOlderLocallyAsync();
        } else {
          didLoad = _fetchOlderLocally();
        }
      } finally {
        _localOlderBusy = false;
      }
      if (!_disposed && !didLoad && !_haveOldest
          && _revalidation == RevalidationState.failing
          && !_exhaustedLocalOlder) {
        _exhaustedLocalOlder = true;
        notifyListeners();
      }
      return;
    }
    if (busyFetchingMore) return;
    assert(fetched);
    assert(oldestFetchedMessageId != null);

    final generation = this.generation;
    final anchorId = oldestFetchedMessageId!;
    final needsNetworkCatchUp = !_networkHaveOldest
      && _networkOldestId != null
      && _networkOldestId! > anchorId;
    var networkDone = false;
    if (!needsNetworkCatchUp) {
      if (store.dbActive) {
        if (store.hasLiveLocalPaginationCoverage(
            narrow, anchorId: anchorId, older: true)) {
          final didLoad = await _fetchOlderLocallyAsync(
            requireRevalidation: false,
            afterFailure: false,
          );
          if (_disposed || this.generation != generation) return;
          if (didLoad) {
            _networkOldestId = _oldestFetchedMessageId;
            _networkHaveOldest = _haveOldest;
            return;
          }
        } else {
          unawaited(store.localWindowAsync(
            narrow,
            NumericAnchor(anchorId),
            kMessageListFetchBatchSize,
            0,
            afterFailure: false,
          ).then((window) {
            if (networkDone || _disposed || this.generation != generation
                || _revalidation != RevalidationState.none) {
              return;
            }
            if (window == null) return;
            _applyOlderLocalWindow(window, anchorId);
          }).catchError((_) {}));
        }
      } else {
        final local = store.localWindow(
          narrow,
          NumericAnchor(anchorId),
          kMessageListFetchBatchSize,
          0,
          afterFailure: false,
        );
        if (local != null) {
          final didLoad = _fetchOlderLocally(local: local);
          if (didLoad && local.chain.status == CoverageStatus.live) {
            _networkOldestId = _oldestFetchedMessageId;
            _networkHaveOldest = _haveOldest;
            return;
          }
        }
      }
    }

    final networkAnchorId = _networkOldestId ?? oldestFetchedMessageId!;
    await _fetchMore(
      anchor: NumericAnchor(networkAnchorId),
      numBefore: kMessageListFetchBatchSize,
      numAfter: 0,
      processResult: (result, ticket) {
        networkDone = true;
        if (result.messages.isNotEmpty) {
          _networkOldestId = result.messages.first.id;
          _oldestFetchedMessageId = _minNullable(
            _oldestFetchedMessageId, result.messages.first.id);
        }
        _networkHaveOldest = result.foundOldest;
        store.reconcileMessages(
          result.messages,
          rawMessages: result.rawMessages,
          ticket: ticket,
          requester: this,
          coverageRequest: FetchCoverageRequest(
            narrow: narrow,
            numBefore: kMessageListFetchBatchSize,
            numAfter: 0,
            includeAnchor: false,
            foundOldest: result.foundOldest,
            foundNewest: result.foundNewest,
            historyLimited: result.historyLimited,
            resolvedAnchor: result.anchor,
          ),
        );
        store.recentSenders.handleMessages(result.messages); // TODO(#824)
        if (_disposed || this.generation != generation) return;

        if (messages.isEmpty || result.messages.isEmpty
            || result.messages.last.id < messages.first.id) {
          final fetchedMessages = result.messages.where(_messageBelongsInFetchedView);
          _insertAllMessages(0, fetchedMessages);
        } else {
          _mergeSortedMessages(result.messages);
        }
        _haveOldest = _haveOldest || result.foundOldest;
        _maybeClearSupersededStalePiece();
      });
  }

  /// Fetch the next batch of newer messages, if applicable.
  ///
  /// If there are no newer messages to fetch (i.e. if [haveNewest]),
  /// or if this message list is already busy fetching more messages
  /// (i.e. if [busyFetchingMore], which includes backoff from failed requests),
  /// then this method does nothing and immediately returns.
  /// That makes this method suitable to call frequently, e.g. every frame,
  /// whenever it looks likely to be useful to have more messages.
  Future<void> fetchNewer() async {
    assert(!_disposed);
    if (haveNewest) return;
    if (_revalidation != RevalidationState.none) {
      if (_localNewerBusy) return;
      _localNewerBusy = true;
      final bool didLoad;
      try {
        if (store.dbActive) {
          didLoad = await _fetchNewerLocallyAsync();
        } else {
          didLoad = _fetchNewerLocally();
        }
      } finally {
        _localNewerBusy = false;
      }
      if (!_disposed && !didLoad && !_haveNewest && !_anchorFallback
          && _revalidation == RevalidationState.failing
          && !_exhaustedLocalNewer) {
        _exhaustedLocalNewer = true;
        notifyListeners();
      }
      return;
    }
    if (busyFetchingMore) return;
    assert(fetched);
    assert(newestFetchedMessageId != null);

    final generation = this.generation;
    final anchorId = newestFetchedMessageId!;
    final needsNetworkCatchUp = _haveNewestInvalidated
      || (!_networkHaveNewest
          && _networkNewestId != null
          && _networkNewestId! < anchorId);
    var networkDone = false;
    if (!needsNetworkCatchUp) {
      if (store.dbActive) {
        if (store.hasLiveLocalPaginationCoverage(
            narrow, anchorId: anchorId, older: false)) {
          final didLoad = await _fetchNewerLocallyAsync(
            requireRevalidation: false,
            afterFailure: false,
          );
          if (_disposed || this.generation != generation) return;
          if (didLoad) {
            _networkNewestId = _newestFetchedMessageId;
            _networkHaveNewest = _haveNewest;
            return;
          }
        } else {
          unawaited(store.localWindowAsync(
            narrow,
            NumericAnchor(anchorId),
            0,
            kMessageListFetchBatchSize,
            afterFailure: false,
          ).then((window) {
            if (networkDone || _disposed || this.generation != generation
                || _revalidation != RevalidationState.none) {
              return;
            }
            if (window == null) return;
            _applyNewerLocalWindow(window, anchorId);
          }).catchError((_) {}));
        }
      } else {
        final local = store.localWindow(
          narrow,
          NumericAnchor(anchorId),
          0,
          kMessageListFetchBatchSize,
          afterFailure: false,
        );
        if (local != null) {
          final didLoad = _fetchNewerLocally(local: local);
          if (didLoad && local.chain.status == CoverageStatus.live) {
            _networkNewestId = _newestFetchedMessageId;
            _networkHaveNewest = _haveNewest;
            return;
          }
        }
      }
    }

    final networkAnchorId = _networkNewestId ?? newestFetchedMessageId!;
    await _fetchMore(
      anchor: NumericAnchor(networkAnchorId),
      numBefore: 0,
      numAfter: kMessageListFetchBatchSize,
      processResult: (result, ticket) {
        networkDone = true;
        if (result.messages.isNotEmpty) {
          _networkNewestId = result.messages.last.id;
          _newestFetchedMessageId = _maxNullable(
            _newestFetchedMessageId, result.messages.last.id);
        }
        _haveNewestInvalidated = false;
        _networkHaveNewest = result.foundNewest;
        store.reconcileMessages(
          result.messages,
          rawMessages: result.rawMessages,
          ticket: ticket,
          requester: this,
          coverageRequest: FetchCoverageRequest(
            narrow: narrow,
            numBefore: 0,
            numAfter: kMessageListFetchBatchSize,
            includeAnchor: false,
            foundOldest: result.foundOldest,
            foundNewest: result.foundNewest,
            historyLimited: result.historyLimited,
            resolvedAnchor: result.anchor,
          ),
        );
        store.recentSenders.handleMessages(result.messages); // TODO(#824)
        if (_disposed || this.generation != generation) return;

        if (messages.isEmpty || result.messages.isEmpty
            || result.messages.first.id > messages.last.id) {
          _removeOutboxMessageItems();
          for (final message in result.messages) {
            if (_messageBelongsInFetchedView(message)) {
              _addMessage(message);
            }
          }
          _reprocessOutboxMessages();
        } else {
          _mergeSortedMessages(result.messages);
        }
        _haveNewest = _haveNewest || result.foundNewest;
        _atKnownNewest = _atKnownNewest || _haveNewest;
        _maybeClearSupersededStalePiece();

        if (_canShowOutbox) {
          _reconcileOutboxMessages();
          _reprocessOutboxMessages();
        }
      });
  }

  void _mergeSortedMessages(List<Message> incoming) {
    final oldContentsById = <int, (Message, ZulipMessageContent)>{
      for (int i = 0; i < messages.length; i++)
        messages[i].id: (messages[i], contents[i]),
    };
    final oldMiddleId = messages.isNotEmpty && middleMessage < messages.length
      ? messages[middleMessage].id
      : null;

    final byId = <int, Message>{};
    for (final m in messages) {
      final current = store.messages[m.id];
      if (current != null
          && !store.isLocationUnknown(current.id)
          && _messageBelongsInFetchedView(current)) {
        byId[current.id] = current;
      }
    }
    for (final m in incoming) {
      final current = store.messages[m.id] ?? m;
      if (_messageBelongsInFetchedView(current)) {
        byId[current.id] = current;
      } else {
        byId.remove(m.id);
      }
    }

    final merged = byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    messages
      ..clear()
      ..addAll(merged);
    contents
      ..clear()
      ..addAll(merged.map((m) {
        final prev = oldContentsById[m.id];
        if (prev != null && identical(prev.$1, m)) return prev.$2;
        return parseMessageContent(m);
      }));

    if (merged.isEmpty) {
      middleMessage = 0;
    } else if (oldMiddleId != null) {
      final idx = merged.indexWhere((m) => m.id >= oldMiddleId);
      middleMessage = idx == -1 ? merged.length - 1 : idx;
    }
    _reprocessAll();
  }

  bool _fetchOlderLocally({LocalWindow? local}) {
    final anchorId = oldestFetchedMessageId;
    if (anchorId == null) return false;
    final window = local ?? store.localWindow(
      narrow,
      NumericAnchor(anchorId),
      kMessageListFetchBatchSize,
      0,
      afterFailure: true,
    );
    if (window == null) return false;
    return _applyOlderLocalWindow(window, anchorId);
  }

  Future<bool> _runAsyncLocalPagination({
    required int anchorId,
    required int before,
    required int after,
    required bool afterFailure,
    required bool requireRevalidation,
    required bool Function(LocalWindow window) apply,
  }) async {
    final generation = this.generation;
    if (!requireRevalidation) {
      _setStatus(FetchingStatus.fetchingMore, was: FetchingStatus.idle);
    }
    final LocalWindow? window;
    try {
      window = await store.localWindowAsync(
        narrow,
        NumericAnchor(anchorId),
        before,
        after,
        afterFailure: afterFailure,
      );
    } catch (_) {
      if (!requireRevalidation && !_disposed && !store.disposed
          && this.generation == generation
          && _status == FetchingStatus.fetchingMore) {
        _setStatus(FetchingStatus.idle, was: FetchingStatus.fetchingMore);
      }
      rethrow;
    }
    if (_disposed || store.disposed || this.generation != generation) {
      return false;
    }
    if (!requireRevalidation && _status == FetchingStatus.fetchingMore) {
      _setStatus(FetchingStatus.idle, was: FetchingStatus.fetchingMore);
    }
    if (window == null) return false;
    if (requireRevalidation && _revalidation == RevalidationState.none) {
      return false;
    }
    return apply(window);
  }

  Future<bool> _fetchOlderLocallyAsync({
    bool requireRevalidation = true,
    bool afterFailure = true,
  }) async {
    final anchorId = oldestFetchedMessageId;
    if (anchorId == null) return false;
    return _runAsyncLocalPagination(
      anchorId: anchorId,
      before: kMessageListFetchBatchSize,
      after: 0,
      afterFailure: afterFailure,
      requireRevalidation: requireRevalidation,
      apply: (window) => _applyOlderLocalWindow(window, anchorId),
    );
  }

  bool _applyOlderLocalWindow(LocalWindow window, int anchorId) {
    final olderMessages = [
      for (final m in window.messages)
        if (m.id < anchorId && _messageBelongsInFetchedView(m)) m,
    ];
    if (olderMessages.isEmpty && !window.haveOldest) return false;
    if (olderMessages.isNotEmpty) {
      _oldestFetchedMessageId = olderMessages.first.id;
      _insertAllMessages(0, olderMessages);
    }
    _haveOldest = window.haveOldest;
    _exhaustedLocalOlder = false;
    _mergeContentStateFromChain(window.chain);
    _syncStaleBannerTimer();
    notifyListeners();
    return true;
  }

  Future<bool> _fetchOlderSavedSearchAsync() async {
    final currentNarrow = narrow;
    if (currentNarrow is! KeywordSearchNarrow) return false;
    final anchorId = oldestFetchedMessageId;
    if (anchorId == null) return false;
    final generation = this.generation;
    final older = await store.searchSavedMessages(
      query: currentNarrow.keyword,
      beforeMessageId: anchorId,
      limit: kMessageListFetchBatchSize,
    );
    if (_disposed || store.disposed || this.generation != generation
        || _revalidation == RevalidationState.none
        || !_showingSavedSearchResults
        || older == null) {
      return false;
    }
    final olderMessages = [
      for (final m in older.messages)
        if (m.id < anchorId && _messageBelongsInFetchedView(m)) m,
    ];
    if (olderMessages.isEmpty) return false;
    _oldestFetchedMessageId = olderMessages.first.id;
    _insertAllMessages(0, olderMessages);
    _exhaustedLocalOlder = !older.hasMoreOlder;
    notifyListeners();
    return true;
  }

  bool _fetchNewerLocally({LocalWindow? local}) {
    if (_atKnownNewest) return false;
    final anchorId = newestFetchedMessageId;
    if (anchorId == null) return false;
    final window = local ?? store.localWindow(
      narrow,
      NumericAnchor(anchorId),
      0,
      kMessageListFetchBatchSize,
      afterFailure: true,
    );
    if (window == null) return false;
    return _applyNewerLocalWindow(window, anchorId);
  }

  Future<bool> _fetchNewerLocallyAsync({
    bool requireRevalidation = true,
    bool afterFailure = true,
  }) async {
    if (_atKnownNewest) return false;
    final anchorId = newestFetchedMessageId;
    if (anchorId == null) return false;
    return _runAsyncLocalPagination(
      anchorId: anchorId,
      before: 0,
      after: kMessageListFetchBatchSize,
      afterFailure: afterFailure,
      requireRevalidation: requireRevalidation,
      apply: (window) => _applyNewerLocalWindow(window, anchorId),
    );
  }

  bool _applyNewerLocalWindow(LocalWindow window, int anchorId) {
    final newerMessages = [
      for (final m in window.messages)
        if (m.id > anchorId && _messageBelongsInFetchedView(m)) m,
    ];
    final effectiveAtKnownNewest = _revalidation != RevalidationState.none
      ? window.atKnownNewest
      : window.haveNewest;
    if (newerMessages.isEmpty && !effectiveAtKnownNewest) return false;
    if (newerMessages.isNotEmpty) {
      _newestFetchedMessageId = newerMessages.last.id;
      _removeOutboxMessageItems();
      for (final m in newerMessages) {
        _addMessage(m);
      }
    }
    _haveNewest = window.haveNewest;
    _atKnownNewest = effectiveAtKnownNewest;
    _exhaustedLocalNewer = false;
    _mergeContentStateFromChain(window.chain);
    _syncStaleBannerTimer();
    if (_canShowOutbox) {
      _reconcileOutboxMessages();
      _reprocessOutboxMessages();
    }
    notifyListeners();
    return true;
  }

  Future<void> _fetchMore({
    required NumericAnchor anchor,
    required int numBefore,
    required int numAfter,
    required void Function(GetMessagesResult, FetchTicket) processResult,
  }) async {
    assert(narrow is! TopicNarrow
      // We only intend to send "with" in [fetchInitial]; see there.
      || (narrow as TopicNarrow).with_ == null);
    _setStatus(FetchingStatus.fetchingMore, was: FetchingStatus.idle);
    final generation = this.generation;
    bool hasFetchError = false;
    bool isConnectionFailure = false;
    final int? narrowChannelId = switch (narrow) {
      ChannelNarrow(:final channelId) || TopicNarrow(:final channelId) => channelId,
      _ => null,
    };
    final ticket = store.openFetchTicket(channelId: narrowChannelId);
    try {
      final GetMessagesResult result;
      try {
        result = await getMessages(store.connection,
          narrow: narrow.apiEncode(),
          anchor: anchor,
          includeAnchor: false,
          numBefore: numBefore,
          numAfter: numAfter,
          allowEmptyTopicName: true,
        );
      } catch (e) {
        hasFetchError = true;
        isConnectionFailure = e is NetworkException
          && e.kind == NetworkExceptionKind.connectionFailed;
        rethrow;
      }
      if (_disposed || this.generation > generation) return;

      processResult(result, ticket);
    } finally {
      store.closeFetchTicket(ticket);
      if (!_disposed && this.generation == generation) {
        if (hasFetchError) {
          if (numBefore > 0) {
            _olderPaginationFailing = store.coverageEnabled && isConnectionFailure;
          }
          if (numAfter > 0) {
            _newerPaginationFailing = store.coverageEnabled && isConnectionFailure;
          }
          _setStatus(FetchingStatus.backoff, was: FetchingStatus.fetchingMore);
          unawaited((_fetchBackoffMachine ??= BackoffMachine())
            .wait().then((_) {
              if (_disposed || this.generation != generation) return;
              _setStatus(FetchingStatus.idle, was: FetchingStatus.backoff);
            }));
        } else {
          if (numBefore > 0) _olderPaginationFailing = false;
          if (numAfter > 0) _newerPaginationFailing = false;
          _setStatus(FetchingStatus.idle, was: FetchingStatus.fetchingMore);
          _fetchBackoffMachine = null;
        }
      }
    }
  }

  /// Reset this view to start from the newest messages.
  ///
  /// This will set [anchor] to [AnchorCode.newest],
  /// and cause messages to be re-fetched from scratch.
  void jumpToEnd() {
    assert(!_disposed);
    assert(fetched);
    assert(!haveNewest);
    if (_anchor == AnchorCode.newest && _revalidation != RevalidationState.none) {
      if (store.dbActive) {
        unawaited(_jumpToEndLocallyAsync());
      } else {
        final pair = _findLocalWindow(
          afterFailure: _revalidation == RevalidationState.failing);
        if (pair != null) {
          _applyLocalJump(pair.$1, usedFallback: pair.$2);
          return;
        }
        _reset();
        notifyListeners();
        unawaited(fetchInitial());
      }
      return;
    }
    // [anchor] is usually not [AnchorCode.newest] here, but it can be,
    // when [haveNewest] was invalidated.  See [handleMessagesLearnedFromFetch].
    final skipInitialLocal = _haveNewestInvalidated;
    _anchor = AnchorCode.newest;
    _reset();
    notifyListeners();
    unawaited(fetchInitial(skipInitialLocal: skipInitialLocal));
  }

  Future<void> _jumpToEndLocallyAsync() async {
    final generation = this.generation;
    final pair = await _findLocalWindowAsync(
      afterFailure: _revalidation == RevalidationState.failing);
    if (_disposed || this.generation != generation) return;
    if (pair != null && _revalidation != RevalidationState.none) {
      _applyLocalJump(pair.$1, usedFallback: pair.$2);
      return;
    }
    if (_revalidation == RevalidationState.none) return;
    _reset();
    notifyListeners();
    unawaited(fetchInitial());
  }

  void _applyLocalJump(LocalWindow local, {required bool usedFallback}) {
    _clearContents();
    _anchorFallback = usedFallback;
    _localWindowWasLive = local.chain.status == CoverageStatus.live && !usedFallback;
    _setContentStateFromChain(local.chain);
    _populateFromResult(
      messages: local.messages,
      anchorId: local.anchorId,
      foundOldest: local.haveOldest,
      foundNewest: local.haveNewest,
      atKnownNewest: local.atKnownNewest,
    );
    _exhaustedLocalOlder = false;
    _exhaustedLocalNewer = false;
    _syncStaleBannerTimer();
    notifyListeners();
  }

  bool _shouldAddOutboxMessage(OutboxMessage outboxMessage) {
    assert(_canShowOutbox);
    return !outboxMessage.hidden && _messageBelongsHere(outboxMessage);
  }

  /// Reads [MessageStore.outboxMessages] and copies to [outboxMessages]
  /// the ones belonging to this view.
  ///
  /// This should only be called when [haveNewest] or [atKnownNewest] is true
  /// because outbox messages are considered newer than regular messages.
  ///
  /// This does not call [notifyListeners].
  void _syncOutboxMessagesFromStore() {
    assert(_canShowOutbox);
    assert(outboxMessages.isEmpty);
    for (final outboxMessage in store.outboxMessages.values) {
      if (_shouldAddOutboxMessage(outboxMessage)) {
        _addOutboxMessage(outboxMessage);
      }
    }
  }

  void _reconcileOutboxMessages() {
    if (!_canShowOutbox) {
      outboxMessages.clear();
      return;
    }
    outboxMessages.removeWhere((om) =>
      om.messageId != null && _findMessageWithId(om.messageId!) != -1);
    for (final outboxMessage in store.outboxMessages.values) {
      if (_shouldAddOutboxMessage(outboxMessage)
          && (outboxMessage.messageId == null
              || _findMessageWithId(outboxMessage.messageId!) == -1)
          && outboxMessages.none(
            (existing) => existing.localMessageId == outboxMessage.localMessageId)) {
        outboxMessages.add(outboxMessage);
      }
    }
  }

  /// Add [outboxMessage] if it belongs to the view.
  void addOutboxMessage(OutboxMessage outboxMessage) {
    // We don't have the newest known messages;
    // we shouldn't show any outbox messages until we do.
    if (!_canShowOutbox) return;

    assert(outboxMessages.none(
      (message) => message.localMessageId == outboxMessage.localMessageId));
    if (_shouldAddOutboxMessage(outboxMessage)) {
      _addOutboxMessage(outboxMessage);
      notifyListeners();
    }
  }

  /// Remove the [outboxMessage] from the view.
  ///
  /// This is a no-op if the message is not found.
  ///
  /// This should only be called from [MessageStore.takeOutboxMessage].
  void removeOutboxMessage(OutboxMessage outboxMessage) {
    if (_removeOutboxMessage(outboxMessage)) {
      notifyListeners();
    }
  }

  /// Remove the [outboxMessage] from the view, its anticipated message
  /// (see [OutboxMessage.messageId]) having been received in a fetch.
  ///
  /// This is a no-op if the message is not found.
  void handleOutboxMessageDelivered(OutboxMessage outboxMessage) {
    if (_removeOutboxMessage(outboxMessage)) {
      notifyListeners();
    }
  }

  /// Called when the store has newly learned of messages from a fetch,
  /// whether by this view or another.
  /// See [MessageStoreImpl.reconcileMessages].
  ///
  /// If any of the messages belong in this view
  /// but are newer than the messages it has,
  /// then stop claiming to have the newest messages
  /// ([haveNewest] becomes false),
  /// so that a subsequent [fetchNewer] will find them.
  ///
  /// If the view has never had any messages,
  /// a [fetchNewer] would have nothing to anchor its request at.
  /// In that case, reset and refetch from scratch instead.
  ///
  /// Normally such messages would already have been added to this view,
  /// on a message event.
  /// But the event queue might be delayed or stuck
  /// while fetches continue to succeed
  /// (see #2397, and e.g. #514 and #2415 for ways this can happen).
  /// In that case this is how the view learns
  /// its impression of being caught up is stale.
  ///
  /// A view on a search narrow never invalidates this way,
  /// because the client can't tell which messages belong in it
  /// (see [Narrow.containsMessage]).
  /// So such a view can keep claiming [haveNewest] when it's stale.
  void handleMessagesLearnedFromFetch(List<Message> newlyLearned) {
    if (!haveNewest) return;
    final anchorId = newestFetchedMessageId;
    if (anchorId == null) {
      // A [fetchNewer] would have no message to anchor its request at.
      // But the view has never had any messages,
      // so there's no content to preserve. Just refetch from scratch.
      if (newlyLearned.any(_messageBelongsHere)) {
        _reset();
        notifyListeners();
        unawaited(fetchInitial(skipInitialLocal: true));
      }
      return;
    }
    final hasNewerMessage = newlyLearned.any((message) =>
      // A message at or before [anchorId] wouldn't be found by [fetchNewer],
      // so don't invalidate for it.  (A message the view lacks, with an ID
      // in the already-fetched range, can arise from a message move.)
      message.id > anchorId && _messageBelongsHere(message));
    if (!hasNewerMessage) return;
    _invalidateHaveNewest();
    notifyListeners();
  }

  /// Update messages in this view that were clobbered during
  /// [MessageStoreImpl.reconcileMessages].
  void handleMessagesClobbered(
    List<({Message oldMessage, Message newMessage})> clobbered, {
    bool isRequester = false,
  }) {
    bool swappedAny = false;
    List<({Message oldMessage, Message newMessage})>? relocated;
    for (final entry in clobbered) {
      final (:oldMessage, :newMessage) = entry;
      final isRelocated = !oldMessage.conversation.isSameAs(newMessage.conversation);
      final index = _findMessageWithId(newMessage.id);
      if (index != -1) {
        _replaceMessage(index, newMessage,
          reuseContent: newMessage.content == oldMessage.content
            && oldMessage.poll == null
            && newMessage.poll == null);
        if (!isRelocated) swappedAny = true;
      }
      if (isRelocated) {
        (relocated ??= []).add(entry);
      }
    }
    if (swappedAny) {
      _reprocessAll();
      notifyListeners();
    }
    if (relocated != null) {
      for (final (:oldMessage, :newMessage) in relocated) {
        if (oldMessage is StreamMessage && newMessage is StreamMessage) {
          messagesMoved(
            messageMove: UpdateMessageMoveData(
              origStreamId: oldMessage.streamId,
              newStreamId: newMessage.streamId,
              origTopic: oldMessage.topic,
              newTopic: newMessage.topic,
              propagateMode: PropagateMode.changeOne,
            ),
            messageIds: [newMessage.id],
            allowRefetch: !isRequester,
          );
        } else {
          // A message cannot relocate to or from a DM in Zulip.
          assert(false);
        }
      }
    }
  }

  void handleUserTopicEvent(UserTopicEvent event) {
    switch (_willAffectVisibility(event)) {
      case TopicVisibilityEffect.none:
        return;

      case TopicVisibilityEffect.muted:
        bool removed = _removeMessagesWhere((message) =>
          message is StreamMessage
            && message.streamId == event.streamId
            && message.topic.isSameAs(event.topicName));

        removed |= _removeOutboxMessagesWhere((message) =>
          message is StreamOutboxMessage
            && message.conversation.streamId == event.streamId
            && message.conversation.topic.isSameAs(event.topicName));

        if (removed) {
          notifyListeners();
        }

      case TopicVisibilityEffect.unmuted:
        // TODO get the newly-unmuted messages from the message store
        // For now, we simplify the task by just refetching this message list
        // from scratch.
        if (fetched) {
          _reset();
          notifyListeners();
          fetchInitial();
        }
    }
  }

  void handleSubscriptionUpdateEvent(SubscriptionUpdateEvent event) {
    switch (_willAffectVisibility(event)) {
      case .none:
        return;

      case .muted:
        bool nowHidden(TopicName topic) =>
          !store.isTopicVisibleGivenChannelMuted(event.channelId, topic,
            channelMuted: true);

        bool removed = _removeMessagesWhere((message) =>
          message is StreamMessage
            && message.streamId == event.channelId
            && nowHidden(message.topic));

        removed |= _removeOutboxMessagesWhere((message) =>
          message is StreamOutboxMessage
            && message.conversation.streamId == event.channelId
            && nowHidden(message.conversation.topic));

        if (removed) {
          notifyListeners();
        }

      case .unmuted:
        // TODO get the newly-unmuted messages from the message store
        // For now, we simplify the task by just refetching this message list
        // from scratch.
        if (fetched) {
          _reset();
          notifyListeners();
          fetchInitial();
        }
    }
  }

  /// Update for [event], a change to the user's subscriptions,
  /// which the store has already applied.
  ///
  /// Of the narrows, only the combined feed's [_messageVisible] depends on
  /// whether the user is subscribed to a channel
  /// (see [ChannelStore.isTopicVisible]).
  /// On unsubscribing from a channel,
  /// this removes the channel's messages that are no longer visible there.
  /// On subscribing to a channel unmuted,
  /// some of its messages may become visible,
  /// so this refetches the list from scratch, as for unmuting a topic.
  /// (Subscribing to a channel muted changes no message's visibility:
  /// a topic the user has unmuted or follows is visible either way,
  /// and any other topic is hidden either way.)
  ///
  /// A view of a channel, or of a topic in it, shows the same messages
  /// whether or not the user is subscribed.
  /// But while the user isn't subscribed,
  /// the event queue doesn't bring the channel's new messages,
  /// so the view may lack some.
  /// On subscribing to the channel, this refetches such a view from scratch,
  /// so it doesn't go on to add new messages after a gap.
  void handleSubscriptionEvent(SubscriptionEvent event) {
    switch (narrow) {
      case CombinedFeedNarrow():
        break;

      case ChannelNarrow(:final channelId):
      case TopicNarrow(:final channelId):
        switch (event) {
          case SubscriptionAddEvent(:final subscriptions)
              when subscriptions.any((s) => s.streamId == channelId):
            // Restart even a fetch still in progress: its result may have been
            // computed before the user subscribed, and so lack messages
            // which no event will bring either.
            if (_status != FetchingStatus.unstarted) {
              _reset();
              notifyListeners();
              unawaited(fetchInitial());
            }
          case SubscriptionRemoveEvent(:final channelIds)
              when channelIds.contains(channelId) && store.dbActive:
            _syncStaleBannerTimer();
            notifyListeners();
          default:
            break;
        }
        return;

      case DmNarrow():
      case MentionsNarrow():
      case StarredMessagesNarrow():
      case KeywordSearchNarrow():
        return;
    }

    switch (event) {
      case SubscriptionAddEvent(:final subscriptions):
        if (subscriptions.every((subscription) => subscription.isMuted)) return;
        _refetchFromScratch();

      case SubscriptionRemoveEvent(:final channelIds):
        _removeMessagesNoLongerVisible(channelIds: channelIds);

      case SubscriptionUpdateEvent():
        // Handled in [handleSubscriptionUpdateEvent], before `_channels` updates.
        return;

      case SubscriptionPeerAddEvent():
      case SubscriptionPeerRemoveEvent():
        return;
    }
  }

  /// Remove the messages in [channelIds], including outbox messages,
  /// that [_messageVisible] no longer allows.
  void _removeMessagesNoLongerVisible({required Iterable<int> channelIds}) {
    bool shouldRemove(MessageBase message) => switch (message.conversation) {
      StreamConversation(:final streamId) =>
        channelIds.contains(streamId) && !_messageVisible(message),
      DmConversation() => false,
    };
    bool removed = _removeMessagesWhere(shouldRemove);
    removed |= _removeOutboxMessagesWhere(shouldRemove);
    if (removed) {
      notifyListeners();
    }
  }

  /// Refetch from scratch, if fetched,
  /// because messages this view lacks may now belong in it.
  void _refetchFromScratch() {
    // TODO take the messages from the message store, where it has them
    // For now, we simplify the task by just refetching this message list
    // from scratch.
    if (fetched) {
      _reset();
      notifyListeners();
      unawaited(fetchInitial());
    }
  }

  void handleMutedUsersEvent(MutedUsersEvent event) {
    switch (_mutedUsersEventWillAffectVisibility(event)) {
      case MutedUsersVisibilityEffect.none:
        return;

      case MutedUsersVisibilityEffect.muted:
        final anyRemoved = _removeMessagesWhere((message) {
          if (message is! DmMessage) return false;
          final narrow = DmNarrow.ofMessage(message, selfUserId: store.selfUserId);
          return store.shouldMuteDmConversation(narrow, event: event);
        });
        if (anyRemoved) {
          notifyListeners();
        }

      case MutedUsersVisibilityEffect.mixed:
      case MutedUsersVisibilityEffect.unmuted:
        // TODO get the newly-unmuted messages from the message store
        // For now, we simplify the task by just refetching this message list
        // from scratch.
        if (fetched) {
          _reset();
          notifyListeners();
          fetchInitial();
        }
    }
  }

  void handleDeleteMessageEvent(DeleteMessageEvent event) {
    if (_removeMessagesById(event.messageIds)) {
      notifyListeners();
    }
  }

  /// Remove [messageIds] that were forgotten by an authoritative fetch
  /// of this view's narrow or a containing narrow.
  void handleMessagesForgotten(List<int> messageIds) {
    if (_removeMessagesById(messageIds)) {
      notifyListeners();
    }
  }

  /// Remove [messageIds] purged under the realm or channel retention policy.
  void handleMessagesPurgedForRetention(Iterable<int> messageIds) {
    if (_removeMessagesById(messageIds)) {
      notifyListeners();
    }
  }

  /// Remove all messages in [channelId] after access loss or channel deletion.
  void handleChannelPurged(int channelId) {
    final idsToRemove = [
      for (final message in messages)
        if (message is StreamMessage && message.streamId == channelId)
          message.id,
    ];
    if (idsToRemove.isNotEmpty && _removeMessagesById(idsToRemove)) {
      notifyListeners();
    }
  }

  /// Add [MessageEvent.message] to this view if it belongs here,
  /// or adopt the event's copy if we already have the message.
  void handleMessageEvent(MessageEvent event, {OutboxMessage? sentOutboxMessage}) {
    final message = event.message;

    final index = _findMessageWithId(message.id);
    if (index != -1) {
      // We already have the message, from a fetch whose response was
      // computed after the message was sent:
      //   https://github.com/zulip/zulip-flutter/issues/929
      // Instead of adding a duplicate, adopt the event's copy of the message,
      // like the message store has (see [MessageStoreImpl.handleMessageEvent]),
      // so that this view continues to see updates
      // that are applied to the store's copy.
      //
      // This runs regardless of [narrow] and [haveNewest]:
      // those decide whether a *new* message belongs in this view,
      // but this message is already here and must stay in sync with the store.
      _replaceMessage(index, message);
      // If we sent this message, drop its outbox counterpart.
      _removeOutboxMessageOfEvent(event);
      // This is a rare race, so the cost of rebuilding [items] is fine.
      // [_reprocessAll] also rebuilds the outbox items, so there's no need
      // to reprocess them separately.
      _reprocessAll();
      notifyListeners();
      return;
    }

    if (!_messageBelongsHere(message)) {
      assert(event.localMessageId == null || outboxMessages.none((message) =>
        message.localMessageId == int.parse(event.localMessageId!, radix: 10)));
      return;
    }
    if (!haveNewest) {
      if (atKnownNewest && (sentOutboxMessage != null || event.localMessageId != null)) {
        if (sentOutboxMessage != null) {
          final existingIndex = outboxMessages.indexWhere(
            (om) => om.localMessageId == sentOutboxMessage.localMessageId);
          if (existingIndex != -1) {
            _reprocessOutboxMessages();
            notifyListeners();
          } else {
            _addOutboxMessage(sentOutboxMessage);
            notifyListeners();
          }
        }
        // The event shows the server connection is working; trigger revalidation
        // so any gap before this message is fetched promptly.
        if (_revalidation == RevalidationState.failing) {
          handleEventStreamRecovered();
        } else if (_revalidation == RevalidationState.none
            && !busyFetchingMore
            && newestFetchedMessageId != null) {
          unawaited(fetchNewer());
        }
      }
      // Leave the server message itself to be found by revalidation / fetchNewer
      // so we don't append it after an unknown gap.
      return;
    }

    // Remove the outbox messages temporarily.
    // We'll add them back after the new message.
    _removeOutboxMessageItems();
    // TODO insert in middle of [messages] instead, when appropriate
    _addMessage(message);
    // Keep [newestFetchedMessageId] up to date as the anchor for a future
    // [fetchNewer], so that such a fetch can't return this message again
    // (which would corrupt [messages] with a duplicate).
    _newestFetchedMessageId = message.id;
    _networkNewestId = message.id;
    // If the view had no messages at all, this message also bounds
    // the history on the other end.
    _oldestFetchedMessageId ??= message.id;
    _networkOldestId ??= message.id;
    _removeOutboxMessageOfEvent(event);
    _reprocessOutboxMessages();
    notifyListeners();
  }

  /// Update data derived from the content of the given message.
  ///
  /// This does not notify listeners.
  /// The caller should ensure that happens later.
  void messageContentChanged(int messageId) {
    final index = _findMessageWithId(messageId);
    if (index != -1) {
      _reparseContent(index);
    }
  }

  void _messagesMovedInternally(List<int> messageIds) {
    for (final messageId in messageIds) {
      if (_findMessageWithId(messageId) != -1) {
        _reprocessAll();
        notifyListeners();
        return;
      }
    }
  }

  void _messagesMovedIntoMessageList() {
    // If there are some messages we don't have in [MessageStore], and they
    // occur later than the messages we have here, then we just have to
    // re-fetch from scratch.  That's always valid, so just do that always.
    // TODO in cases where we do have data to do better, do better.
    _reset();
    notifyListeners();
    unawaited(fetchInitial());
  }

  void _messagesMovedFromMessageList(List<int> messageIds) {
    if (_removeMessagesById(messageIds)) {
      notifyListeners();
    }
  }

  void _handlePropagateMode(PropagateMode propagateMode, Narrow newNarrow) {
    switch (propagateMode) {
      case PropagateMode.changeAll:
      case PropagateMode.changeLater:
        // TODO(#1009) anchor to some visible message, if any
        renarrowAndFetch(newNarrow, anchor);
      case PropagateMode.changeOne:
    }
  }

  void messagesMoved({
    required UpdateMessageMoveData messageMove,
    required List<int> messageIds,
    bool allowRefetch = true,
  }) {
    final UpdateMessageMoveData(
      :origStreamId, :newStreamId, :origTopic, :newTopic, :propagateMode,
    ) = messageMove;
    switch (narrow) {
      case DmNarrow():
        // DMs can't be moved (nor created by moves),
        // so the messages weren't in this narrow and still aren't.
        return;

      case CombinedFeedNarrow():
        final wasVisible = store.isTopicVisible(origStreamId, origTopic);
        final isVisible = store.isTopicVisible(newStreamId, newTopic);
        switch ((wasVisible, isVisible)) {
          case (false, false): return;
          case (true,  true ): _messagesMovedInternally(messageIds);
          case (false, true ): if (allowRefetch) _messagesMovedIntoMessageList();
          case (true,  false): _messagesMovedFromMessageList(messageIds);
        }

      case MentionsNarrow():
      case StarredMessagesNarrow():
        // The messages didn't enter or leave this message list.
        // (They may have been (un)muted, but we don't exclude channel messages
        // in these narrows on the basis of muting. See _messageVisible.)
        // Recipient headers, and downstream of those, may change, though.
        _messagesMovedInternally(messageIds);

      case KeywordSearchNarrow():
        // This might not be quite true, since matches can be determined by
        // the topic alone, and topics change. Punt on trying to add/remove
        // messages, though, because we aren't equipped to evaluate the match
        // without asking the server.
        // (Messages may have been (un)muted, but we don't exclude channel
        // messages in this narrow on the basis of muting. See _messageVisible.)
        _messagesMovedInternally(messageIds);

      case ChannelNarrow(:final channelId):
        final wasInChannelAndVisible = origStreamId == channelId
          && store.isTopicVisibleInChannel(origStreamId, origTopic);
        final isInChannelAndVisible = newStreamId == channelId
          && store.isTopicVisibleInChannel(newStreamId, newTopic);
        switch ((wasInChannelAndVisible, isInChannelAndVisible)) {
          case (false, false): return;
          case (true,  true ): _messagesMovedInternally(messageIds);
          case (false, true ): if (allowRefetch) _messagesMovedIntoMessageList();
          case (true,  false): _messagesMovedFromMessageList(messageIds);
        }

      case TopicNarrow(:final channelId, :final topic):
        final oldMatch = origStreamId == channelId
          && serverTopicFold(origTopic.apiName) == serverTopicFold(topic.apiName);
        final newMatch = newStreamId == channelId
          && serverTopicFold(newTopic.apiName) == serverTopicFold(topic.apiName);
        switch ((oldMatch, newMatch)) {
          case (false, false): return;
          case (true,  true ): return; // TODO(log) when no-op move
          case (false, true ): if (allowRefetch) _messagesMovedIntoMessageList();
          case (true,  false):
            _messagesMovedFromMessageList(messageIds);
            _handlePropagateMode(propagateMode, TopicNarrow(newStreamId, newTopic));
        }
    }
  }

  // Repeal the `@protected` annotation that applies on the base implementation,
  // so we can call this method from [MessageStoreImpl].
  @override
  void notifyListeners() {
    super.notifyListeners();
  }

  /// Notify listeners if the given message is present in this view.
  void notifyListenersIfMessagePresent(int messageId) {
    final index = _findMessageWithId(messageId);
    if (index != -1) {
      notifyListeners();
    }
  }

  /// Notify listeners if any of the given messages is present in this view.
  void notifyListenersIfAnyMessagePresent(Iterable<int> messageIds) {
    final isAnyPresent = messageIds.any((id) => _findMessageWithId(id) != -1);
    if (isAnyPresent) {
      notifyListeners();
    }
  }

  /// Notify listeners if the given outbox message is present in this view.
  void notifyListenersIfOutboxMessagePresent(int localMessageId) {
    final isAnyPresent =
      outboxMessages.any((message) => message.localMessageId == localMessageId);
    if (isAnyPresent) {
      notifyListeners();
    }
  }

  /// Called when the app is reassembled during debugging, e.g. for hot reload.
  ///
  /// This will redo from scratch any computations we can, such as parsing
  /// message contents.  It won't repeat network requests.
  void reassemble() {
    _recompute();
    notifyListeners();
  }
}
