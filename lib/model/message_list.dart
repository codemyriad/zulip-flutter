import 'dart:async';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../api/backoff.dart';
import '../api/core.dart';
import '../api/exception.dart';
import '../api/model/events.dart';
import '../api/model/model.dart';
import '../api/route/messages.dart';
import '../log.dart';
import 'algorithms.dart';
import 'channel.dart';
import 'content.dart';
import 'message.dart';
import 'narrow.dart';
import 'store.dart';
import 'user.dart';

export '../api/route/messages.dart' show Anchor, AnchorCode, NumericAnchor;

/// The number of messages to fetch in each request.
const kMessageListFetchBatchSize = 100; // TODO tune

/// How long [MessageListView.fetchInitial] waits on its request
/// before showing cached messages, if any.
///
/// See [MessageListView.showingCachedMessages].
const kShowCachedMessagesDelay = Duration(seconds: 1);

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

  /// Like [fetchInitial], but meanwhile the model is showing messages
  /// from an earlier fetch of the narrow, stored on the device.
  ///
  /// See [MessageListView.showingCachedMessages].
  fetchInitialShowingCached,

  /// The model made a successful `fetchInitial` request,
  /// and has no outstanding requests or backoff.
  idle,

  /// The model has an active `fetchOlder` or `fetchNewer` request.
  fetchingMore,

  /// The model is in a backoff period from a failed request.
  backoff,
}

/// The sequence of messages in a message list, and how to display them.
///
/// This comprises much of the guts of [MessageListView].
mixin _MessageSequence {
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
  ///
  /// This is also true while [showingCachedMessages],
  /// when the results are those of an earlier fetch.
  bool get fetched => switch (_status) {
    FetchingStatus.unstarted || FetchingStatus.fetchInitial => false,
    _ => true,
  };

  /// Whether [messages] are from an earlier fetch of [narrow],
  /// stored on the device, while the initial fetch is still being retried.
  ///
  /// This happens when the initial fetch fails in a way that may be temporary,
  /// for example because the device is offline, or is slow to complete.
  /// See [MessageListView.fetchInitial].
  /// When the fetch succeeds, its results replace these messages.
  ///
  /// While this is true, [fetched] and [busyFetchingMore] are true,
  /// and [haveOldest] and [haveNewest] are false,
  /// so no further fetches are made;
  /// [oldestFetchedMessageId] and [newestFetchedMessageId] are null;
  /// and there are no [outboxMessages].
  ///
  /// The messages are as of when the stored fetch was made,
  /// the last time the narrow was opened from its newest or first unread message
  /// and the fetch reached the newest message;
  /// they don't reflect events received after that,
  /// except for read and starred state, which come from the store.
  /// Where the store has a message, its copy is used instead.
  ///
  /// Known limitations:
  ///  * Outbox messages aren't shown meanwhile,
  ///    so a message the user sends appears only once the fetch succeeds.
  ///  * Only a fetch from the newest or first unread message is stored,
  ///    and not for keyword searches (see [MessageListView.fetchInitial]);
  ///    a list opened at a specific message, or a search, stays online-only,
  ///    as do other fetches like those for the topic list.
  bool get showingCachedMessages =>
    _status == FetchingStatus.fetchInitialShowingCached;

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
  ///
  /// This is also true while [showingCachedMessages],
  /// because the initial fetch is still in progress.
  bool get busyFetchingMore => switch (_status) {
    FetchingStatus.fetchingMore
      || FetchingStatus.backoff
      || FetchingStatus.fetchInitialShowingCached => true,
    _ => false,
  };

  FetchingStatus _status = FetchingStatus.unstarted;

  BackoffMachine? _fetchBackoffMachine;

  /// Completed to stop the request or backoff wait in progress, if any,
  /// in the retry loop of [MessageListView.fetchInitial],
  /// when the loop is no longer wanted.
  ///
  /// See [_cancelFetchInitial].
  Completer<void>? _fetchInitialAbort;

  /// The timer after which [MessageListView.fetchInitial]
  /// shows cached messages if its request hasn't completed;
  /// see [kShowCachedMessagesDelay].
  Timer? _showCachedMessagesTimer;

  void _cancelShowCachedMessagesTimer() {
    _showCachedMessagesTimer?.cancel();
    _showCachedMessagesTimer = null;
  }

  /// Stop the retry loop of [MessageListView.fetchInitial], if running,
  /// from waiting further on its request or backoff,
  /// and cancel its timer for showing cached messages.
  ///
  /// The loop also needs to see, when it resumes, that it should stop;
  /// for example because [generation] has changed.
  void _cancelFetchInitial() {
    final abort = _fetchInitialAbort;
    _fetchInitialAbort = null;
    abort?.complete();
    _cancelShowCachedMessagesTimer();
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
  /// and update [contents] accordingly.
  ///
  /// The caller is responsible for updating [items],
  /// for example by calling [_reprocessAll].
  void _replaceMessage(int index, Message message) {
    assert(messages[index].id == message.id);
    messages[index] = message;
    contents[index] = parseMessageContent(message);
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
    assert(haveNewest);
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
  }

  /// Reset all [_MessageSequence] data, and cancel any active fetches.
  void _reset() {
    generation += 1;
    _clearContents();
    _status = FetchingStatus.unstarted;
    _fetchBackoffMachine = null;
    _cancelFetchInitial();
  }

  /// Clear [messages], [outboxMessages], and the data derived from them,
  /// and forget what's been fetched.
  ///
  /// Unlike [_reset], this leaves [generation] and the fetching status alone,
  /// so a fetch in progress can call this and carry on.
  ///
  /// This does not call [notifyListeners].
  void _clearContents() {
    messages.clear();
    middleMessage = 0;
    _oldestFetchedMessageId = null;
    _newestFetchedMessageId = null;
    outboxMessages.clear();
    _haveOldest = false;
    _haveNewest = false;
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
    assert(haveNewest);
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
    fetchInitial();
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
  }

  @override
  void dispose() {
    assert(!_disposed);
    store.unregisterMessageList(this);
    // Fetches in progress check this when they resume, so that they
    // don't act on, or notify listeners of, this disposed object.
    _disposed = true;
    _cancelFetchInitial();
    super.dispose();
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
  ///
  /// See also [_allMessagesVisible].
  // When updating this, check [_allMessagesVisible], [_willAffectVisibility],
  // [_mutedUsersEventWillAffectVisibility], and [messagesMoved] to see whether
  // they need to be updated too.
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

  /// Whether [message] belongs in this view:
  /// it's known to be in [narrow], and it's visible ([_messageVisible]).
  bool _messageBelongsHere(MessageBase message) =>
    narrow.containsMessage(message) == true && _messageVisible(message);

  /// Whether [_messageVisible] is true for all possible messages.
  ///
  /// This is useful for an optimization.
  bool get _allMessagesVisible {
    switch (narrow) {
      case CombinedFeedNarrow():
      case ChannelNarrow():
        return false;

      case TopicNarrow():
      case DmNarrow():
        return true;

      case MentionsNarrow():
        return false;

      case StarredMessagesNarrow():
        return true;

      case KeywordSearchNarrow():
        return false;
    }
  }

  /// Whether this event could affect the result that [_messageVisible]
  /// would ever have returned for any possible message in this message list.
  UserTopicVisibilityEffect _willAffectVisibility(UserTopicEvent event) {
    switch (narrow) {
      case CombinedFeedNarrow():
        return store.willAffectIfTopicVisible(event);

      case ChannelNarrow(:final channelId):
        if (event.streamId != channelId) return UserTopicVisibilityEffect.none;
        return store.willAffectIfTopicVisibleInChannel(event);

      case TopicNarrow():
      case DmNarrow():
      case MentionsNarrow():
      case StarredMessagesNarrow():
      case KeywordSearchNarrow():
        return UserTopicVisibilityEffect.none;
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
  /// See [_isRetryableFetchInitialError].
  /// On other errors, this throws.
  ///
  /// Meanwhile, if the request has failed, or has taken longer than
  /// [kShowCachedMessagesDelay],
  /// this shows the messages from the narrow's stored earlier fetch, if any.
  /// See [showingCachedMessages].
  /// A fetch is stored after it succeeds, if [narrow] isn't a keyword search
  /// (see [messageFetchCacheKey]), [anchor] is
  /// [AnchorCode.newest] or [AnchorCode.firstUnread],
  /// and the result reaches the newest message
  /// ([GetMessagesResult.foundNewest]);
  /// a stored fetch is shown only for those anchors too.
  /// A fetch that finds no messages deletes any stored one.
  Future<void> fetchInitial() async {
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

    // A fetch from the newest or first-unread message is what the user
    // will want to see again on opening this narrow again later,
    // so keep a copy, to show if the fetch then fails or is slow.
    final cacheKey = messageFetchCacheKey(narrow);
    final useCache = cacheKey != null && switch (anchor) {
      AnchorCode.newest || AnchorCode.firstUnread => true,
      _ => false,
    };

    // Meanwhile, read any stored fetch, in parallel with the request.
    // Parse it only if it's to be shown; usually the request succeeds first.
    Uint8List? cachedData;
    bool mayShowCached = useCache;
    bool shouldShowCached = false;
    void maybeShowCached() {
      if (isStale() || !mayShowCached || !shouldShowCached) return;
      final data = cachedData;
      if (data == null) return;
      assert(_status == FetchingStatus.fetchInitial);
      mayShowCached = false;
      final result = _parseCachedMessageFetch(cacheKey!, data);
      if (result == null) return;
      _showCachedMessages(result);
    }
    if (useCache) {
      assert(_showCachedMessagesTimer == null);
      _showCachedMessagesTimer = Timer(kShowCachedMessagesDelay, () {
        _showCachedMessagesTimer = null;
        shouldShowCached = true;
        maybeShowCached();
      });
      unawaited(store.loadCachedMessageFetch(cacheKey).then((data) {
        if (isStale()) return;
        if (data == null) {
          mayShowCached = false;
          _cancelShowCachedMessagesTimer();
          return;
        }
        cachedData = data;
        maybeShowCached();
      }));
    }

    BackoffMachine? backoffMachine;
    GetMessagesResult result;
    BytesBuilder? rawBody;
    while (true) {
      rawBody = useCache ? BytesBuilder(copy: false) : null;
      try {
        result = await getMessages(store.connection,
          narrow: narrow.apiEncode(),
          anchor: anchor,
          numBefore: kMessageListFetchBatchSize,
          numAfter: kMessageListFetchBatchSize,
          allowEmptyTopicName: true,
          abortTrigger: abort.future,
          rawBody: rawBody,
        );
        break;
      } catch (e) {
        if (isStale()) return;
        if (!_isRetryableFetchInitialError(e)) {
          _fetchInitialAbort = null;
          mayShowCached = false;
          _cancelShowCachedMessagesTimer();
          if (cacheKey != null && e is ZulipApiException) {
            // The narrow may be gone, or no longer accessible to the user;
            // in any case, don't keep showing its stored messages.
            unawaited(store.deleteCachedMessageFetch(cacheKey));
          }
          if (showingCachedMessages) {
            _clearContents();
            _status = FetchingStatus.fetchInitial;
            notifyListeners(); // [_setStatus] wouldn't, as [fetched] is now false
          }
          rethrow;
        }
        shouldShowCached = true;
        maybeShowCached();
      }
      // TODO(log) the error
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
    _fetchInitialAbort = null;
    mayShowCached = false;
    _cancelShowCachedMessagesTimer();
    if (showingCachedMessages) {
      // Replace the cached messages with the fresh ones.
      _clearContents();
    }

    _oldestFetchedMessageId = result.messages.firstOrNull?.id;
    _newestFetchedMessageId = result.messages.lastOrNull?.id;

    _adjustNarrowForTopicPermalink(result.messages.firstOrNull);

    store.reconcileMessages(result.messages);
    store.recentSenders.handleMessages(result.messages); // TODO(#824)

    // The bottom slice will start at the "anchor message".
    // This is the first visible message at or past [anchor] if any,
    // else the last visible message if any.  [reachedAnchor] helps track that.
    bool reachedAnchor = false;
    for (final message in result.messages) {
      if (!_messageVisible(message)) continue;
      if (!reachedAnchor) {
        // Push the previous message into the top slice.
        middleMessage = messages.length;
        // We could interpret [anchor] for ourselves; but the server has already
        // done that work, reducing it to an int, `result.anchor`.  So use that.
        reachedAnchor = message.id >= result.anchor;
      }
      _addMessage(message);
    }
    _haveOldest = result.foundOldest;
    _haveNewest = result.foundNewest;

    if (haveNewest) {
      _syncOutboxMessagesFromStore();
    }

    if (rawBody != null) {
      // Use the narrow as adjusted for any topic-permalink redirect.
      final key = messageFetchCacheKey(narrow)!;
      if (result.messages.isEmpty) {
        unawaited(store.deleteCachedMessageFetch(key));
      } else if (result.foundNewest) {
        unawaited(store.storeCachedMessageFetch(key, rawBody.takeBytes()));
      }
      // Otherwise the fetch stops short of the newest messages,
      // as from an old unread in a busy conversation.
      // Keep any stored fetch, which reaches them.
    }

    assert(_status == FetchingStatus.fetchInitial
      || _status == FetchingStatus.fetchInitialShowingCached);
    _setStatus(FetchingStatus.idle);
  }

  /// Parse [data], the stored fetch for [cacheKey].
  ///
  /// If the data doesn't parse, this deletes it and returns null.
  GetMessagesResult? _parseCachedMessageFetch(String cacheKey, Uint8List data) {
    try {
      return GetMessagesResult.fromJson(
        jsonUtf8Decoder.convert(data) as Map<String, dynamic>);
    } catch (e) {
      assert(debugLog('Error parsing cached message fetch: $e')); // TODO(log)
      unawaited(store.deleteCachedMessageFetch(cacheKey));
      return null;
    }
  }

  /// Show the messages of [cached], a stored earlier fetch of [narrow],
  /// while [fetchInitial] keeps trying.
  ///
  /// The messages are filtered by what the store knows now:
  /// for example a message moved out of [narrow], into a muted topic,
  /// or into a channel the user can no longer access, is left out.
  /// If no messages are left, this leaves the view as it is.
  ///
  /// See [showingCachedMessages].
  void _showCachedMessages(GetMessagesResult cached) {
    assert(_status == FetchingStatus.fetchInitial);
    assert(messages.isEmpty && outboxMessages.isEmpty);

    final toShow = <Message>[];
    for (final cachedMessage in cached.messages) {
      // Prefer the store's copy, which events have kept up to date.
      // Leave the store alone otherwise: this data may be stale,
      // and no event would come to correct it.
      final message = store.messages[cachedMessage.id]
        ?? _updateCachedMessageFlags(cachedMessage);
      if (message is StreamMessage) {
        final channel = store.streams[message.streamId];
        if (channel == null || !store.selfHasContentAccess(channel)) continue;
      }
      if (!_messageBelongsHere(message)) continue;
      toShow.add(message);
    }
    if (toShow.isEmpty) return;

    // The bottom slice will start at the anchor message, as in [fetchInitial].
    // Find that from [anchor] and the current unread state;
    // the stored result's own anchor is as of the earlier fetch.
    final anchorId = switch (anchor) {
      AnchorCode.firstUnread => toShow.firstWhereOrNull(
        (message) => !message.flags.contains(MessageFlag.read))?.id,
      _ => null,
    } ?? toShow.last.id;
    bool reachedAnchor = false;
    for (final message in toShow) {
      if (!reachedAnchor) {
        // Push the previous message into the top slice.
        middleMessage = messages.length;
        reachedAnchor = message.id >= anchorId;
      }
      _addMessage(message);
    }
    _setStatus(FetchingStatus.fetchInitialShowingCached,
      was: FetchingStatus.fetchInitial);
  }

  /// Update the read and starred flags of [message], from a stored fetch,
  /// to the store's current knowledge, which events have kept up to date.
  ///
  /// The [message] must not be one in the store; this mutates it.
  Message _updateCachedMessageFlags(Message message) {
    assert(!identical(store.messages[message.id], message));
    final flags = message.flags;
    final isUnread = store.unreads.isUnread(message.id);
    if (isUnread != null) { // if unknown, keep the stored flag
      flags.remove(MessageFlag.read);
      if (!isUnread) flags.add(MessageFlag.read);
    }
    flags.remove(MessageFlag.starred);
    if (store.starredMessages.contains(message.id)) {
      flags.add(MessageFlag.starred);
    }
    return message;
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
  void handleEventStreamRecovered() {
    final wake = _fetchInitialBackoffWake;
    _fetchInitialBackoffWake = null;
    wake?.complete();
  }

  /// Whether [fetchInitial] should retry after its request failed with [error].
  ///
  /// This is true for errors that may go away on their own:
  /// network failures, server errors, rate limiting,
  /// and malformed responses (as from a captive portal on the network).
  /// It's false for other errors, like a 4xx error for a bad narrow,
  /// which retrying won't fix,
  /// and errors from bugs in our code, which shouldn't be retried silently.
  bool _isRetryableFetchInitialError(Object error) {
    switch (error) {
      case NetworkException(:final cause):
        // In tests, [FakeApiConnection] throws a [FlutterError]
        // when a test forgot to prepare a response; don't hide that.
        assert(cause is! FlutterError, 'Unexpected error in fetchInitial: $cause');
        return true;
      case Server5xxException():
      case MalformedServerResponseException():
      case ZulipApiException(code: 'RATE_LIMIT_HIT'):
      case HttpException(httpStatus: 429):
        return true;
      default:
        return false;
    }
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
    if (busyFetchingMore) return;
    assert(fetched);
    assert(oldestFetchedMessageId != null);
    await _fetchMore(
      anchor: NumericAnchor(oldestFetchedMessageId!),
      numBefore: kMessageListFetchBatchSize,
      numAfter: 0,
      processResult: (result) {
        if (result.messages.isNotEmpty) {
          _oldestFetchedMessageId = result.messages.first.id;
        }
        store.reconcileMessages(result.messages);
        store.recentSenders.handleMessages(result.messages); // TODO(#824)

        final fetchedMessages = _allMessagesVisible
          ? result.messages // Avoid unnecessarily copying the list.
          : result.messages.where(_messageVisible);

        _insertAllMessages(0, fetchedMessages);
        _haveOldest = result.foundOldest;
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
    if (busyFetchingMore) return;
    assert(fetched);
    assert(newestFetchedMessageId != null);
    await _fetchMore(
      anchor: NumericAnchor(newestFetchedMessageId!),
      numBefore: 0,
      numAfter: kMessageListFetchBatchSize,
      processResult: (result) {
        if (result.messages.isNotEmpty) {
          _newestFetchedMessageId = result.messages.last.id;
        }
        store.reconcileMessages(result.messages);
        store.recentSenders.handleMessages(result.messages); // TODO(#824)

        for (final message in result.messages) {
          if (_messageVisible(message)) {
            _addMessage(message);
          }
        }
        _haveNewest = result.foundNewest;

        if (haveNewest) {
          _syncOutboxMessagesFromStore();
        }
      });
  }

  Future<void> _fetchMore({
    required Anchor anchor,
    required int numBefore,
    required int numAfter,
    required void Function(GetMessagesResult) processResult,
  }) async {
    assert(narrow is! TopicNarrow
      // We only intend to send "with" in [fetchInitial]; see there.
      || (narrow as TopicNarrow).with_ == null);
    _setStatus(FetchingStatus.fetchingMore, was: FetchingStatus.idle);
    final generation = this.generation;
    bool hasFetchError = false;
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
        rethrow;
      }
      if (_disposed || this.generation > generation) return;

      processResult(result);
    } finally {
      if (!_disposed && this.generation == generation) {
        if (hasFetchError) {
          _setStatus(FetchingStatus.backoff, was: FetchingStatus.fetchingMore);
          unawaited((_fetchBackoffMachine ??= BackoffMachine())
            .wait().then((_) {
              if (_disposed || this.generation != generation) return;
              _setStatus(FetchingStatus.idle, was: FetchingStatus.backoff);
            }));
        } else {
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
    // [anchor] is usually not [AnchorCode.newest] here, but it can be,
    // when [haveNewest] was invalidated.  See [handleMessagesLearnedFromFetch].
    _anchor = AnchorCode.newest;
    _reset();
    notifyListeners();
    fetchInitial();
  }

  bool _shouldAddOutboxMessage(OutboxMessage outboxMessage) {
    assert(haveNewest);
    return !outboxMessage.hidden && _messageBelongsHere(outboxMessage);
  }

  /// Reads [MessageStore.outboxMessages] and copies to [outboxMessages]
  /// the ones belonging to this view.
  ///
  /// This should only be called when [haveNewest] is true
  /// because outbox messages are considered newer than regular messages.
  ///
  /// This does not call [notifyListeners].
  void _syncOutboxMessagesFromStore() {
    assert(haveNewest);
    assert(outboxMessages.isEmpty);
    for (final outboxMessage in store.outboxMessages.values) {
      if (_shouldAddOutboxMessage(outboxMessage)) {
        _addOutboxMessage(outboxMessage);
      }
    }
  }

  /// Add [outboxMessage] if it belongs to the view.
  void addOutboxMessage(OutboxMessage outboxMessage) {
    // We don't have the newest messages;
    // we shouldn't show any outbox messages until we do.
    if (!haveNewest) return;

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
        fetchInitial();
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

  void handleUserTopicEvent(UserTopicEvent event) {
    switch (_willAffectVisibility(event)) {
      case UserTopicVisibilityEffect.none:
        return;

      case UserTopicVisibilityEffect.muted:
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

      case UserTopicVisibilityEffect.unmuted:
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

  /// Add [MessageEvent.message] to this view if it belongs here,
  /// or adopt the event's copy if we already have the message.
  void handleMessageEvent(MessageEvent event) {
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
      // (When [haveNewest] is false there are no [outboxMessages], so this
      // is a no-op; see [_syncOutboxMessagesFromStore].)
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
      // This message list's [messages] doesn't yet reach the new end
      // of the narrow's message history.  (Either [fetchInitial] hasn't yet
      // completed, or if it has then it was in the middle of history and no
      // subsequent [fetchNewer] has reached the end.)
      // So this still-newer message doesn't belong.
      // Leave it to be found by a subsequent fetch when appropriate.
      // TODO mitigate this fetch/event race: save message to add to list later,
      //   in case the fetch that reaches the end is already ongoing and
      //   didn't include this message.
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
    // If the view had no messages at all, this message also bounds
    // the history on the other end.
    _oldestFetchedMessageId ??= message.id;
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
    fetchInitial();
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
          case (false, true ): _messagesMovedIntoMessageList();
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
          case (false, true ): _messagesMovedIntoMessageList();
          case (true,  false): _messagesMovedFromMessageList(messageIds);
        }

      case TopicNarrow(:final channelId, :final topic):
        final oldMatch = (origStreamId == channelId && origTopic.isSameAs(topic));
        final newMatch = (newStreamId == channelId && newTopic.isSameAs(topic));
        switch ((oldMatch, newMatch)) {
          case (false, false): return;
          case (true,  true ): return; // TODO(log) when no-op move
          case (false, true ): _messagesMovedIntoMessageList();
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
