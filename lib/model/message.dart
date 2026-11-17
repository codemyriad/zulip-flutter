import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../api/backoff.dart';
import '../api/exception.dart';
import '../api/model/events.dart';
import '../api/model/initial_snapshot.dart';
import '../api/model/model.dart';
import '../api/route/channels.dart';
import '../api/route/messages.dart';
import '../log.dart';
import 'binding.dart';
import 'channel.dart';
import 'message_coverage.dart';
import 'message_database.dart';
import 'message_db_effects.dart';
import 'message_db_sync.dart';
import 'message_db_writer.dart';
import 'message_effect.dart';
import 'message_list.dart';
import 'message_search.dart';
import 'narrow.dart';
import 'notification_prefetch.dart';
import 'race_buffer.dart';
import 'realm.dart';
import 'store.dart';
import 'stored_message_codec.dart';
import 'unreads.dart';

export 'notification_prefetch.dart'
  show
    kNotificationPrefetchAfter,
    kNotificationPrefetchBefore,
    prefetchUnloadedNotificationMessages;

const _apiSendMessage = sendMessage; // Bit ugly; for alternatives, see: https://chat.zulip.org/#narrow/stream/243-mobile-team/topic/flutter.3A.20PerAccountStore.20methods/near/1545809

/// Outcome of attempting to persist a server event-log batch inside a
/// [MessageDbWriter] transaction alongside message DB updates.
enum EventLogCommitOutcome { notAttempted, committed, rejected, failed }

/// The portion of [PerAccountStore] for messages and message lists.
mixin MessageStore on ChannelStore {
  /// All known messages, indexed by [Message.id].
  Map<int, Message> get messages;

  /// All starred messages, as message IDs.
  Set<int> get starredMessages;

  /// Whether the initial snapshot's starred-message list hit the server cap
  /// and therefore might omit older starred messages.
  bool get isStarredMessagesAtCap;

  /// [OutboxMessage]s sent by the user, indexed by [OutboxMessage.localMessageId].
  Map<int, OutboxMessage> get outboxMessages;

  /// Unix timestamp (seconds) when the message database was last confirmed live,
  /// if known.
  int? get lastLiveAt;

  /// Whether [messageId] is marked possibly stale in memory.
  bool isMessageMaybeStale(int messageId);

  Set<MessageListView> get debugMessageListViews;

  void registerMessageList(MessageListView view);
  void unregisterMessageList(MessageListView view);

  void markReadFromScroll(Iterable<int> messageIds);

  /// Makes a send-message request and starts an outbox lifecycle.
  ///
  /// The returned [Future] settles when the send-message response is received.
  /// The [Future] resolves if the request succeeded and rejects if it failed,
  /// unless the event already arrived, in which case it resolves.
  ///
  /// See [takeOutboxMessage] for a way to restore a composing session
  /// when it seems like the request might fail, or it has failed.
  Future<void> sendMessage({
    required MessageDestination destination,
    required String content,
  });

  /// Remove from [outboxMessages] given the [localMessageId], and return
  /// the removed [OutboxMessage].
  ///
  /// The outbox message to be taken must exist.
  ///
  /// The state of the outbox message must be either [OutboxMessageState.failed]
  /// or [OutboxMessageState.waitPeriodExpired].
  OutboxMessage takeOutboxMessage(int localMessageId);

  /// Whether the current edit request for the given message, if any, has failed.
  ///
  /// Will be null if there is no current edit request.
  /// Will be false if the current request hasn't failed
  /// and the update-message event hasn't arrived.
  bool? getEditMessageErrorStatus(int messageId);

  /// Makes an edit-message request and starts an edit-outbox lifecycle.
  ///
  /// Should only be called when there is no current edit request for [messageId],
  /// i.e., [getEditMessageErrorStatus] returns null for [messageId].
  ///
  /// The returned [Future] settles when the edit-message response is received.
  /// The [Future] resolves if the request succeeded and rejects if it failed,
  /// unless the event already arrived or the message was deleted,
  /// in which case it resolves.
  ///
  /// See also:
  ///   * [getEditMessageErrorStatus]
  ///   * [takeFailedMessageEdit]
  Future<void> editMessage({
    required int messageId,
    required String originalRawContent,
    required String newContent,
  });

  /// Forgets the failed edit request and returns the attempted new content.
  ///
  /// Should only be called when there is a failed request,
  /// per [getEditMessageErrorStatus].
  ({String originalRawContent, String newContent}) takeFailedMessageEdit(int messageId);

  /// Whether the user has permission to delete a message, as of [atDate].
  ///
  /// For a value of [atDate], use [ZulipBinding.instance.utcNow].
  bool selfCanDeleteMessage(int messageId, {required DateTime atDate}) {
    // Compare web's message_delete.get_deletability.

    final message = messages[messageId];
    if (message == null) {
      assert(false); // TODO(log)
      return true;
    }

    final ZulipStream? channel;
    if (message is StreamMessage) {
      channel = streams[message.streamId];
      if (channel == null) {
        assert(false); // TODO(log)
        return true;
      }
    } else {
      channel = null;
    }

    if (channel != null && channel.isArchived) {
      return false;
    }

    if (selfHasPermissionForGroupSetting(realmCanDeleteAnyMessageGroup,
          GroupSettingType.realm, 'can_delete_any_message_group')) {
      return true;
    }

    if (channel != null) {
      if (selfHasPermissionForGroupSetting(channel.canDeleteAnyMessageGroup,
            GroupSettingType.stream, 'can_delete_any_message_group')) {
        return true;
      }
    }

    final sender = getUser(message.senderId);
    if (sender == null) return false;

    if (!(
      sender.userId == selfUserId
      || (sender.isBot && sender.botOwnerId == selfUserId)
    )) {
      return false;
    }

    // Web returns false here for local-echoed message objects;
    // that's impossible here because `message` can't be an [OutboxMessage]
    // (it's a [Message] from [MessageStore.messages]).

    // (selfHasPermissionForGroupSetting isn't equipped to handle the old-server
    // fallback logic for this specific permission; it's dynamic and depends on
    // realmDeleteOwnMessagePolicy, so we do our own null check here.)
    if (realmCanDeleteOwnMessageGroup != null) {
      if (!selfHasPermissionForGroupSetting(realmCanDeleteOwnMessageGroup!,
            GroupSettingType.realm, 'can_delete_own_message_group')) {
        if (channel == null) {
          // i.e. this is a DM
          return false;
        }

        if (!selfHasPermissionForGroupSetting(channel.canDeleteOwnMessageGroup,
              GroupSettingType.stream, 'can_delete_own_message_group')) {
          return false;
        }
      }
    } else if (realmDeleteOwnMessagePolicy != null) {
      if (!_selfPassesLegacyDeleteMessagePolicy(messageId, atDate: atDate)) {
        return false;
      }
    } else {
      assert(false); // TODO(log)
      return true;
    }

    if (realmMessageContentDeleteLimitSeconds == null) {
      // i.e., no limit
      return true;
    }
    return atDate.millisecondsSinceEpoch ~/ 1000 - message.timestamp
      <= realmMessageContentDeleteLimitSeconds!;
  }

  bool _selfPassesLegacyDeleteMessagePolicy(int messageId, {required DateTime atDate}) {
    assert(realmDeleteOwnMessagePolicy != null);
    final role = selfUser.role;

    // (Could early-return true on [UserRole.unknown],
    // but pre-291 servers shouldn't be giving us an unknown role.)

    switch (realmDeleteOwnMessagePolicy!) {
      case RealmDeleteOwnMessagePolicy.everyone:
        return true;
      case RealmDeleteOwnMessagePolicy.members:
        return role.isAtLeast(UserRole.member);
      case RealmDeleteOwnMessagePolicy.fullMembers: {
        if (!role.isAtLeast(UserRole.member)) return false;
        if (role == UserRole.member) {
          return selfHasPassedWaitingPeriod(byDate: atDate);
        }
        return true;
      }
      case RealmDeleteOwnMessagePolicy.moderators:
        return role.isAtLeast(UserRole.moderator);
      case RealmDeleteOwnMessagePolicy.admins:
        return role.isAtLeast(UserRole.administrator);
    }
  }
}

mixin ProxyMessageStore on MessageStore {
  @protected
  MessageStore get messageStore;

  @override
  Map<int, Message> get messages => messageStore.messages;
  @override
  Set<int> get starredMessages => messageStore.starredMessages;
  @override
  bool get isStarredMessagesAtCap => messageStore.isStarredMessagesAtCap;
  @override
  Map<int, OutboxMessage> get outboxMessages => messageStore.outboxMessages;
  @override
  int? get lastLiveAt => messageStore.lastLiveAt;
  @override
  bool isMessageMaybeStale(int messageId) =>
    messageStore.isMessageMaybeStale(messageId);
  @override
  void registerMessageList(MessageListView view) =>
    messageStore.registerMessageList(view);
  @override
  void unregisterMessageList(MessageListView view) =>
    messageStore.unregisterMessageList(view);
  @override
  void markReadFromScroll(Iterable<int> messageIds) =>
    messageStore.markReadFromScroll(messageIds);
  @override
  Future<void> sendMessage({required MessageDestination destination, required String content}) {
    return messageStore.sendMessage(destination: destination, content: content);
  }
  @override
  OutboxMessage takeOutboxMessage(int localMessageId) =>
    messageStore.takeOutboxMessage(localMessageId);

  @override
  bool? getEditMessageErrorStatus(int messageId) {
    return messageStore.getEditMessageErrorStatus(messageId);
  }
  @override
  Future<void> editMessage({
    required int messageId,
    required String originalRawContent,
    required String newContent,
  }) {
    return messageStore.editMessage(messageId: messageId,
      originalRawContent: originalRawContent, newContent: newContent);
  }
  @override
  ({String originalRawContent, String newContent}) takeFailedMessageEdit(int messageId) {
    return messageStore.takeFailedMessageEdit(messageId);
  }

  @override
  Set<MessageListView> get debugMessageListViews => messageStore.debugMessageListViews;
}

class _EditMessageRequestStatus {
  _EditMessageRequestStatus({
    required this.hasError,
    required this.originalRawContent,
    required this.newContent,
  });

  bool hasError;
  final String originalRawContent;
  final String newContent;
}

/// Metadata from a `GET /messages` request and response needed to record
/// message coverage for its result.
class FetchCoverageRequest {
  const FetchCoverageRequest({
    required this.narrow,
    required this.numBefore,
    required this.numAfter,
    required this.includeAnchor,
    required this.foundOldest,
    required this.foundNewest,
    required this.historyLimited,
    required this.resolvedAnchor,
  });

  final Narrow narrow;
  final int numBefore;
  final int numAfter;
  final bool includeAnchor;
  final bool foundOldest;
  final bool foundNewest;
  final bool historyLimited;
  final int resolvedAnchor;
}

/// A locally-constructed window from stored messages and coverage.
final class LocalWindow {
  const LocalWindow({
    required this.messages,
    required this.anchorId,
    required this.haveOldest,
    required this.haveNewest,
    required this.atKnownNewest,
    required this.narrow,
    required this.chain,
  });

  final List<Message> messages;
  final int anchorId;
  final bool haveOldest;
  final bool haveNewest;
  final bool atKnownNewest;
  final Narrow narrow;
  final CoverageChain chain;
}

/// Result of a local offline saved-message search, with [messages] sorted
/// ascending by [Message.id].
typedef SavedMessageSearchResult = ({List<Message> messages, bool hasMoreOlder});

class MessageStoreImpl extends HasChannelStore
    with MessageStore, _OutboxMessageStore
    implements MessageSearchStore {
  MessageStoreImpl({
    required super.channels,
    required List<int> initialStarredMessages,
    int firstLocalMessageId = 1,
    int? initialMaxMessageId = 0,
    this.coverageEnabled = false,
  }) :
     messages = {},
     starredMessages = Set.of(initialStarredMessages),
     _initialStarredMessagesAtCap = initialStarredMessages.length >= 10000,
     _initialStarredMaxId = initialStarredMessages.isEmpty
       ? null
       : initialStarredMessages.reduce(math.max),
     _initialSnapshotMaxMessageId = initialMaxMessageId,
     _knownMaxMessageId = initialMaxMessageId != null ? math.max(0, initialMaxMessageId) : 0 {
    _nextLocalMessageId = firstLocalMessageId;
    if (coverageEnabled) {
      _ensureCoverageBegun();
    }
  }

  final bool _initialStarredMessagesAtCap;
  final int? _initialStarredMaxId;

  static int _nowSeconds() =>
    ZulipBinding.instance.utcNow().millisecondsSinceEpoch ~/ 1000;

  @override
  final Map<int, Message> messages;

  @override
  final Set<int> starredMessages;

  @override
  bool get isStarredMessagesAtCap => _initialStarredMessagesAtCap;

  @override
  final Set<MessageListView> _messageListViews = {};

  @override
  Set<MessageListView> get debugMessageListViews => _messageListViews;

  @override
  void registerMessageList(MessageListView view) {
    assert(!_disposed);
    final added = _messageListViews.add(view);
    assert(added);
  }

  @override
  void unregisterMessageList(MessageListView view) {
    // TODO: Add `assert(!_disposed);` here once we ensure [PerAccountStore] is
    //   only disposed after [MessageListView]s with references to it are
    //   disposed.  See [dispose] for details.
    final removed = _messageListViews.remove(view);
    assert(removed);
  }

  void _notifyMessageListViewsForOneMessage(int messageId) {
    for (final view in _messageListViews) {
      view.notifyListenersIfMessagePresent(messageId);
    }
  }

  void _notifyMessageListViews(Iterable<int> messageIds) {
    for (final view in _messageListViews) {
      view.notifyListenersIfAnyMessagePresent(messageIds);
    }
  }

  void reassemble() {
    for (final view in _messageListViews) {
      view.reassemble();
    }
  }

  /// Called when the event stream has recovered from failures;
  /// see [PerAccountStore.isRecoveringEventStream].
  void handleEventStreamRecovered() {
    for (final view in _messageListViews) {
      view.handleEventStreamRecovered();
    }
  }

  @override
  bool _disposed = false;

  void dispose() {
    // Not disposing the [MessageListView]s here, because they are owned by
    // (i.e., they get [dispose]d by) the [_MessageListState], including in the
    // case where the [PerAccountStore] is replaced.
    //
    // TODO: Add assertions that the [MessageListView]s are indeed disposed, by
    //   first ensuring that [PerAccountStore] is only disposed after those with
    //   references to it are disposed, then reinstating this `dispose` method.
    //
    //   We can't add the assertions as-is because the sequence of events
    //   guarantees that `PerAccountStore` is disposed (when that happens,
    //   [GlobalStore] notifies its listeners, causing widgets dependent on the
    //   [InheritedNotifier] to rebuild in the next frame) before the owner's
    //   `dispose` or `onNewStore` is called.  Discussion:
    //     https://chat.zulip.org/#narrow/channel/243-mobile-team/topic/MessageListView.20lifecycle/near/2086893

    assert(!_disposed);
    _markReadDebounceTimer?.cancel();
    _markReadDebounceTimer = null;
    if (_markReadDebounceCompleter case final completer? when !completer.isCompleted) {
      completer.complete();
    }
    _markReadDebounceCompleter = null;
    if (_markReadWakeCompleter case final completer? when !completer.isCompleted) {
      completer.complete();
    }
    _markReadWakeCompleter = null;
    _raceBuffer.closeAll();
    _disposeOutboxMessages();
    if (identical(_dbWriter?.onPoisoned, _handleWriterPoisoned)) {
      _dbWriter!.onPoisoned = null;
    }
    _carriedOverUnreadIds.clear();
    _disposed = true;
  }

  final RaceBuffer _raceBuffer = RaceBuffer();

  RaceBuffer get debugRaceBuffer => _raceBuffer;

  final MessageCoverage _coverage = MessageCoverage(epoch: 0);
  MessageCoverage get debugCoverage => _coverage;

  final int? _initialSnapshotMaxMessageId;

  int _knownMaxMessageId;
  int get knownMaxMessageId => _knownMaxMessageId;

  bool coverageEnabled;

  bool _coverageBegun = false;

  final Map<int, bool> _channelHistoryPublic = {};

  final Set<int> _channelsWithData = {};

  MessageDbWriter? _dbWriter;
  int? _dbAccountId;
  bool _dbActive = false;
  bool get dbActive => _dbActive && _dbWriter != null && !_dbWriter!.isPoisoned;

  /// Tear down message-DB and coverage state in memory when the experimental
  /// setting is turned off at runtime.
  void disableMessageDatabase() {
    if (_disposed) return;
    coverageEnabled = false;
    _dbActive = false;
    _coverageBegun = false;
    _coverageThroughEventId = null;
    _lastLiveAt = null;
    final writer = _dbWriter;
    if (writer != null) {
      if (identical(writer.onPoisoned, _handleWriterPoisoned)) {
        writer.onPoisoned = null;
      }
      writer.poisonInMemoryOnly();
    }
    _dbWriter = null;
    _dbAccountId = null;
    _raceBuffer.closeAll();
    _coverage.restore(
      epoch: 0,
      eventHighWater: -1,
      evictedBelow: 0,
      confirmed: _confirmed,
      intervalsByKey: const {},
    );
    _channelsWithData.clear();
    _channelHistoryPublic.clear();
    _locationUnknown.clear();
    for (final view in _messageListViews) {
      view.handleStoreConfirmedChanged();
    }
  }

  void _handleWriterPoisoned() {
    if (_disposed || !_dbActive) return;
    _dbActive = false;
    final spansByKey = <String, List<({int lo, int top})>>{};
    for (final view in _messageListViews) {
      if (!view.fetched) continue;
      final key = coverageKey(view.narrow);
      if (key == null) continue;
      final ({int lo, int top})? span;
      if (view.messages.isEmpty) {
        if (view.haveOldest && view.haveNewest) {
          span = (lo: 0, top: kNewestMessageId);
        } else if (view.haveOldest) {
          span = (lo: 0, top: 0);
        } else {
          span = null;
        }
      } else {
        span = (
          lo: view.haveOldest ? 0 : view.messages.first.id,
          top: view.haveNewest ? kNewestMessageId : view.messages.last.id,
        );
      }
      if (span != null) {
        (spansByKey[key] ??= []).add(span);
      }
    }
    _coverage.retainOnlyOpenViewSpans(
      spansByKey,
      isKeyTracked: (key) {
        final cid = CoverageKeys.channelIdOf(key);
        return cid == null || subscriptions.containsKey(cid);
      },
    );
  }

  int? _coverageThroughEventId;
  int? get coverageThroughEventId => _coverageThroughEventId;

  int? _lastLiveAt;
  @override
  int? get lastLiveAt => _lastLiveAt;

  bool _replayingEvents = false;
  void setReplayingEvents(bool value) {
    _replayingEvents = value;
  }

  bool _suppressCurrentEventDb = false;
  _PendingEventBatch? _pendingBatch;
  Map<int, ({int? channelId, String? topicKey, String? dmKey})> _pendingMoveDbLocations = const {};

  bool get _shouldMutateCoverage =>
    coverageEnabled && !_replayingEvents && !_suppressCurrentEventDb;

  static const Duration _eventBatchCommitTimeout = Duration(seconds: 2);
  static const int _encodeYieldBatchSize = 50;

  /// Per-account soft cap on stored message body bytes.
  static const int defaultMessageDbSoftByteCap = 32 * 1024 * 1024;

  /// Override for [defaultMessageDbSoftByteCap] in tests.
  @visibleForTesting
  static int? debugSoftByteCap;

  static const Duration _evictionMinInterval = Duration(minutes: 10);
  static const int _evictionChunkLimit = 500;
  DateTime? _lastEvictionAt;
  bool _evictionInProgress = false;

  void _maybeScheduleEviction(int totalBodyBytes) {
    if (_disposed || !dbActive || _evictionInProgress) return;
    final cap = debugSoftByteCap ?? defaultMessageDbSoftByteCap;
    if (totalBodyBytes <= cap) return;
    final now = ZulipBinding.instance.utcNow();
    if (_lastEvictionAt != null && now.difference(_lastEvictionAt!) < _evictionMinInterval) {
      return;
    }
    _evictionInProgress = true;
    _lastEvictionAt = now;
    unawaited(_runEviction(
      writer: _dbWriter!,
      accountId: _dbAccountId!,
      startEpoch: _coverage.epoch,
      cap: cap,
    ));
  }

  Future<void> _runEviction({
    required MessageDbWriter writer,
    required int accountId,
    required int startEpoch,
    required int cap,
  }) async {
    await writer.runTrackedPipeline<void>(() async {
      try {
        if (_disposed || !dbActive || _coverage.epoch != startEpoch) return;
        final targetBytes = (cap * 3) ~/ 4;
        final rawCutoff = await writer.runRead(
          (db) => db.computeEvictionCutoffId(accountId, targetBytes: targetBytes),
        );
        if (_disposed || !dbActive || _coverage.epoch != startEpoch || rawCutoff == null) {
          return;
        }
        var cutoff = rawCutoff;
        for (final view in _messageListViews) {
          if (view.fetched && view.messages.isNotEmpty) {
            cutoff = math.min(cutoff, view.messages.first.id);
          }
        }
        if (cutoff <= _coverage.evictedBelow) return;

        int? committedCutoff;
        await writer.enqueueWrite<void>((db, {required removalOnly}) async {
          if (removalOnly || _disposed || _coverage.epoch != startEpoch) return;
          var effectiveCutoff = cutoff;
          for (final view in _messageListViews) {
            if (view.fetched && view.messages.isNotEmpty) {
              effectiveCutoff = math.min(effectiveCutoff, view.messages.first.id);
            }
          }
          if (effectiveCutoff <= _coverage.evictedBelow) return;
          _coverage.clipBelow(effectiveCutoff);
          final dirtyCoverage = _coverage.takeDirtyIntervals();
          committedCutoff = effectiveCutoff;
          await db.transaction(() async {
            final current = await db.loadAccountEpochAndWatermarkInTxn(accountId);
            if (current == null || current.epoch != startEpoch) return;
            await db.applyEvictionCutoffInTxn(
              accountId,
              cutoffId: effectiveCutoff,
              dirtyCoverage: dirtyCoverage,
            );
          });
        });
        if (committedCutoff == null) return;
        cutoff = committedCutoff!;

        while (!_disposed && dbActive && _coverage.epoch == startEpoch) {
          final deleted = await writer.enqueueWrite<int>((db, {required removalOnly}) async {
            if (removalOnly || _disposed) return 0;
            return db.transaction(() async {
              final current = await db.loadAccountEpochAndWatermarkInTxn(accountId);
              if (current == null || current.epoch != startEpoch) return 0;
              return db.deleteEvictedChunkInTxn(
                accountId,
                cutoffId: cutoff,
                limit: _evictionChunkLimit,
              );
            });
          });
          if (deleted == null || deleted < _evictionChunkLimit) break;
          await Future<void>.delayed(Duration.zero);
        }

        if (!_disposed && dbActive && _coverage.epoch == startEpoch) {
          await writer.enqueueWrite<void>((db, {required removalOnly}) async {
            if (removalOnly || _disposed || !writer.isIdleForMaintenance) return;
            await db.runIncrementalVacuum(2048);
          });
        }
      } finally {
        _evictionInProgress = false;
      }
    }, isMaintenance: true);
  }

  static const int _retentionSweepIntervalSeconds = 86400;
  int? _lastRetentionSweepAt;
  bool _retentionSweepInProgress = false;

  ({int? dmCutoffTimestamp, Map<int, int> channelCutoffTimestamps})
      _computeRetentionCutoffs(
    int now, {
    Iterable<int>? onlyChannels,
    Iterable<int>? extraChannels,
  }) {
    final candidates = onlyChannels ?? <int>{
      ...?extraChannels,
      ..._channelsWithData,
      for (final message in messages.values)
        if (message is StreamMessage) message.streamId,
      for (final key in _coverage.keys)
        ?CoverageKeys.channelIdOf(key),
    };
    return computeRetentionCutoffs(
      nowSeconds: now,
      realmMessageRetentionDays: realmMessageRetentionDays,
      streams: streams,
      candidateChannels: candidates,
      includeDms: onlyChannels == null,
    );
  }

  bool _isMessageExpiredByCutoff(
    Message message, {
    required int? dmCutoffTimestamp,
    required Map<int, int> channelCutoffTimestamps,
  }) {
    if (message is DmMessage) {
      return dmCutoffTimestamp != null && message.timestamp < dmCutoffTimestamp;
    }
    if (message is StreamMessage) {
      final cutoff = channelCutoffTimestamps[message.streamId];
      return cutoff != null && message.timestamp < cutoff;
    }
    return false;
  }

  void _applyRetentionPurgeInMemory({
    required int? dmCutoffTimestamp,
    required Map<int, int> channelCutoffTimestamps,
    int? dbMaxDeletedDmId,
    Map<int, int> dbMaxDeletedByChannelId = const {},
    List<int> dbDeletedIds = const [],
    bool recordRaceForget = false,
    bool clipCoverage = true,
  }) {
    final removedIds = <int>{...dbDeletedIds};
    int? maxDmId = dbMaxDeletedDmId;
    final maxByChannel = Map<int, int>.of(dbMaxDeletedByChannelId);

    final expiredIds = <int>[];
    for (final message in messages.values) {
      if (!_isMessageExpiredByCutoff(
        message,
        dmCutoffTimestamp: dmCutoffTimestamp,
        channelCutoffTimestamps: channelCutoffTimestamps,
      )) {
        continue;
      }
      expiredIds.add(message.id);
      removedIds.add(message.id);
      if (message is DmMessage) {
        maxDmId = maxDmId == null ? message.id : math.max(maxDmId, message.id);
      } else if (message is StreamMessage) {
        final prev = maxByChannel[message.streamId];
        maxByChannel[message.streamId] =
          prev == null ? message.id : math.max(prev, message.id);
      }
    }

    if (recordRaceForget && removedIds.isNotEmpty) {
      _raceBuffer.record(ForgetEffect(messageIds: removedIds.toList()));
    }

    for (final id in expiredIds) {
      messages.remove(id);
      starredMessages.remove(id);
      _maybeStaleMessages.remove(id);
      _locationUnknown.remove(id);
      _editMessageRequests.remove(id);
    }

    if (removedIds.isNotEmpty) {
      for (final view in _messageListViews) {
        view.handleMessagesPurgedForRetention(removedIds);
      }
    }

    if (clipCoverage) {
      if (maxDmId != null) {
        _coverage.clipDmFamilyBelow(1 + maxDmId);
      }
      for (final entry in maxByChannel.entries) {
        _coverage.clipChannelFamilyBelow(entry.key, 1 + entry.value);
      }
    }
  }

  void _maybeRunDailyRetentionSweep() {
    if (_disposed || !coverageEnabled || _retentionSweepInProgress) return;
    final now = _nowSeconds();
    if (_lastRetentionSweepAt != null
        && (now - _lastRetentionSweepAt!) < _retentionSweepIntervalSeconds) {
      return;
    }
    _lastRetentionSweepAt = now;
    final cutoffs = _computeRetentionCutoffs(now);
    if (cutoffs.dmCutoffTimestamp == null && cutoffs.channelCutoffTimestamps.isEmpty) {
      return;
    }
    if (!dbActive) {
      _applyRetentionPurgeInMemory(
        dmCutoffTimestamp: cutoffs.dmCutoffTimestamp,
        channelCutoffTimestamps: cutoffs.channelCutoffTimestamps,
        recordRaceForget: true,
        clipCoverage: _shouldMutateCoverage,
      );
      return;
    }
    final writer = _dbWriter!;
    final accountId = _dbAccountId!;
    final startEpoch = _coverage.epoch;
    _retentionSweepInProgress = true;
    unawaited(writer.runTrackedPipeline<void>(() async {
      try {
        if (_disposed || !dbActive || _coverage.epoch != startEpoch) return;
        await writer.enqueueWrite<void>((db, {required removalOnly}) async {
          if (removalOnly || _disposed || _coverage.epoch != startEpoch) return;
          await db.transaction(() async {
            final current = await db.loadAccountEpochAndWatermarkInTxn(accountId);
            if (current == null || current.epoch != startEpoch) return;
            final dbRes = await db.purgeExpiredRetentionRowsInTxn(
              accountId,
              dmCutoffTimestamp: cutoffs.dmCutoffTimestamp,
              channelCutoffTimestamps: cutoffs.channelCutoffTimestamps,
            );
            _applyRetentionPurgeInMemory(
              dmCutoffTimestamp: cutoffs.dmCutoffTimestamp,
              channelCutoffTimestamps: cutoffs.channelCutoffTimestamps,
              dbMaxDeletedDmId: dbRes.maxDeletedDmId,
              dbMaxDeletedByChannelId: dbRes.maxDeletedByChannelId,
              dbDeletedIds: dbRes.deletedIds,
              recordRaceForget: true,
              clipCoverage: true,
            );
            final dirtyCoverage = _coverage.takeDirtyIntervals();
            if (dirtyCoverage.isNotEmpty) {
              await db.replaceCoverageKeysInTxn(accountId, dirtyCoverage);
            }
          });
        });
      } finally {
        _retentionSweepInProgress = false;
      }
    }, isMaintenance: true));
  }

  /// Persist a channel's fetched topic list for offline topic browsing and
  /// autocomplete on future runs.
  void saveChannelTopics(int channelId, List<GetChannelTopicsEntry> topics) {
    if (_disposed || !coverageEnabled || !dbActive) return;
    final channel = streams[channelId];
    if (channel == null || !selfHasContentAccess(channel)) return;

    final writer = _dbWriter;
    final accountId = _dbAccountId;
    if (writer == null || accountId == null || writer.isPoisoned) return;

    _channelsWithData.add(channelId);
    _channelHistoryPublic[channelId] = channel.historyPublicToSubscribers;
    final epoch = _coverage.epoch;
    final genBefore = _channelGeneration[channelId] ?? 0;
    final historyPublic = channel.historyPublicToSubscribers;
    final rows = [
      for (final entry in topics)
        (
          topicKey: serverTopicFold(entry.name.apiName),
          topic: entry.name.apiName,
          maxId: entry.maxId,
        ),
    ];

    unawaited(writer.enqueueWrite<void>((db, {required removalOnly}) async {
      if (removalOnly || _disposed) return;
      if ((_channelGeneration[channelId] ?? 0) != genBefore) return;
      final currentCh = streams[channelId];
      if (currentCh == null || !selfHasContentAccess(currentCh)) return;
      await db.transaction(() async {
        final current = await db.loadAccountEpochAndWatermarkInTxn(accountId);
        if (current == null || current.epoch != epoch) return;
        await db.upsertChannelsInTxn(accountId, {channelId: historyPublic});
        await db.replaceStoredChannelTopicsInTxn(accountId, channelId, rows);
      });
    }).catchError((_) {}));
  }

  /// Load the channel's locally known topics (DB rows merged with in-memory
  /// messages and [unreads]), folded by [serverTopicFold] with the newest
  /// message's topic display name.
  ///
  /// Returns `null` if offline coverage is disabled, the user lacks content
  /// access to [channelId], or no saved topics are known and `channel:c` does
  /// not have a non-stale complete `[0, ∞)` interval.
  Future<List<GetChannelTopicsEntry>?> loadSavedTopics(
    int channelId, {
    required Unreads unreads,
  }) async {
    if (_disposed || !coverageEnabled) return null;
    final channel = streams[channelId];
    if (channel == null || !selfHasContentAccess(channel)) return null;

    List<({String topic, String topicKey, int maxId})>? dbRows;
    Set<int> raceExcludedIds = const {};
    if (dbActive && _dbWriter != null && !_dbWriter!.isPoisoned && _dbAccountId != null) {
      final writer = _dbWriter!;
      final accountId = _dbAccountId!;
      final readEpoch = _coverage.epoch;
      final genBefore = _channelGeneration[channelId] ?? 0;
      final ticket = _raceBuffer.openDbReadTicket(
        epoch: readEpoch,
        channelGeneration: genBefore,
      );
      try {
        final excludeIds = <int>{
          for (final move in _raceBuffer.moveEffectsAfter(ticket.mark))
            ...move.messageIds,
          ..._raceBuffer.removedIdsAfter(ticket.mark),
          ..._locationUnknown,
        };
        raceExcludedIds = excludeIds;
        dbRows = await writer.runRead(
          (db) => db.queryStoredChannelTopics(accountId, channelId, excludeIds: excludeIds),
        );
        if (_disposed) return null;
        final channelAfter = streams[channelId];
        if (channelAfter == null || !selfHasContentAccess(channelAfter)) {
          return null;
        }
        if (ticket.overflowed
            || _raceBuffer.wasChannelPurgedAfter(ticket.mark, channelId)
            || _coverage.epoch != readEpoch
            || (_channelGeneration[channelId] ?? 0) != genBefore) {
          dbRows = null;
        } else {
          raceExcludedIds = <int>{
            ...raceExcludedIds,
            for (final move in _raceBuffer.moveEffectsAfter(ticket.mark))
              ...move.messageIds,
            ..._raceBuffer.removedIdsAfter(ticket.mark),
            ..._locationUnknown,
          };
        }
      } finally {
        ticket.close();
      }
    }

    final byTopicKey = <String, ({TopicName name, int maxId})>{};
    if (dbRows != null) {
      for (final row in dbRows) {
        if (row.maxId < _coverage.evictedBelow) continue;
        if (raceExcludedIds.contains(row.maxId)) continue;
        final memMsg = messages[row.maxId];
        if (memMsg != null
            && (memMsg is! StreamMessage
                || memMsg.streamId != channelId
                || serverTopicFold(memMsg.topic.apiName) != row.topicKey)) {
          continue;
        }
        final existing = byTopicKey[row.topicKey];
        if (existing == null || row.maxId >= existing.maxId) {
          byTopicKey[row.topicKey] = (name: TopicName(row.topic), maxId: row.maxId);
        }
      }
    }

    for (final m in messages.values) {
      if (m is StreamMessage
          && m.streamId == channelId
          && !_locationUnknown.contains(m.id)
          && m.id >= _coverage.evictedBelow) {
        final key = serverTopicFold(m.topic.apiName);
        final existing = byTopicKey[key];
        if (existing == null || m.id >= existing.maxId) {
          byTopicKey[key] = (name: m.topic, maxId: m.id);
        }
      }
    }

    final unreadTopics = unreads.streams[channelId];
    if (unreadTopics != null) {
      for (final entry in unreadTopics.entries) {
        if (entry.value.isEmpty) continue;
        var maxUnreadId = entry.value.first;
        for (final id in entry.value) {
          if (id > maxUnreadId) maxUnreadId = id;
        }
        final key = serverTopicFold(entry.key.apiName);
        final existing = byTopicKey[key];
        if (existing == null || maxUnreadId > existing.maxId) {
          byTopicKey[key] = (name: entry.key, maxId: maxUnreadId);
        }
      }
    }

    if (byTopicKey.isEmpty) {
      final chains = _coverage.chains(CoverageKeys.channel(channelId));
      final isComplete = chains.length == 1
        && chains.single.reachesOldest
        && chains.single.isOpen
        && chains.single.status != CoverageStatus.stale;
      return isComplete ? <GetChannelTopicsEntry>[] : null;
    }

    return [
      for (final entry in byTopicKey.values)
        GetChannelTopicsEntry(maxId: entry.maxId, name: entry.name),
    ]..sort((a, b) => b.maxId.compareTo(a.maxId));
  }

  /// Search locally saved messages (RAM merged with FTS5 SQLite index),
  /// returning matches sorted ascending by [Message.id].
  ///
  /// Returns `null` if offline coverage is disabled, this store is disposed,
  /// or no local message store/messages are available (`!dbActive && messages.isEmpty`).
  Future<SavedMessageSearchResult?> searchSavedMessages({
    required String query,
    int? beforeMessageId,
    required int limit,
    required bool? Function(int messageId)? isUnreadFromStore,
  }) async {
    if (_disposed || !coverageEnabled || limit <= 0) return null;
    if (!dbActive && messages.isEmpty) return null;

    final parsed = ParsedMessageSearchQuery.parse(query, this);
    if (parsed.isImpossible) {
      return (messages: <Message>[], hasMoreOlder: false);
    }

    return _querySavedMessages(
      sqlSpec: parsed.sqlSpec,
      matches: (m) => parsed.matchesMessage(m, this),
      beforeMessageId: beforeMessageId,
      limit: limit,
      isUnreadFromStore: isUnreadFromStore,
    );
  }

  /// Synthesize a recent page of saved messages for a cross-conversation or
  /// search [narrow] (RAM merged with SQLite), sorted ascending by [Message.id].
  ///
  /// Returns `null` if [narrow] is not synthesized from saved messages, offline
  /// coverage is disabled, this store is disposed, or no local messages exist.
  Future<SavedMessageSearchResult?> savedMessagesForNarrow(
    Narrow narrow, {
    int? beforeMessageId,
    required int limit,
    required bool? Function(int messageId)? isUnreadFromStore,
  }) async {
    if (_disposed || !coverageEnabled || limit <= 0) return null;
    if (!dbActive && messages.isEmpty) return null;

    switch (narrow) {
      case KeywordSearchNarrow(:final keyword):
        return searchSavedMessages(
          query: keyword,
          beforeMessageId: beforeMessageId,
          limit: limit,
          isUnreadFromStore: isUnreadFromStore,
        );

      case CombinedFeedNarrow():
        return _querySavedMessages(
          sqlSpec: const StoredMessageSearchSpec(),
          matches: (m) => switch (m) {
            StreamMessage() => () {
              final channel = streams[m.streamId];
              return channel != null
                && selfHasContentAccess(channel)
                && isTopicVisible(m.streamId, m.topic);
            }(),
            DmMessage() => !shouldMuteDmConversation(
              DmNarrow.ofMessage(m, selfUserId: selfUserId),
            ),
          },
          beforeMessageId: beforeMessageId,
          limit: limit,
          isUnreadFromStore: isUnreadFromStore,
        );

      case MentionsNarrow():
        return _querySavedMessages(
          sqlSpec: const StoredMessageSearchSpec(
            anyFlagsMask: StoredMessageFlags.mentioned
              | StoredMessageFlags.streamWildcardMentioned
              | StoredMessageFlags.topicWildcardMentioned,
          ),
          matches: (m) {
            if (!m.flags.any((f) => f.isMentionFlag)) return false;
            return switch (m) {
              StreamMessage() => () {
                final channel = streams[m.streamId];
                return channel != null && selfHasContentAccess(channel);
              }(),
              DmMessage() => !shouldMuteDmConversation(
                DmNarrow.ofMessage(m, selfUserId: selfUserId),
              ),
            };
          },
          beforeMessageId: beforeMessageId,
          limit: limit,
          isUnreadFromStore: isUnreadFromStore,
        );

      case StarredMessagesNarrow():
        if (!isStarredMessagesAtCap && starredMessages.isEmpty) {
          return (messages: <Message>[], hasMoreOlder: false);
        }
        return _querySavedMessages(
          sqlSpec: StoredMessageSearchSpec(
            allowedMessageIds: !isStarredMessagesAtCap
              ? Set<int>.of(starredMessages)
              : null,
            requiredFlagsMask: isStarredMessagesAtCap
              ? StoredMessageFlags.starred
              : 0,
          ),
          matches: (m) {
            if (!m.flags.contains(MessageFlag.starred)) return false;
            return switch (m) {
              StreamMessage() => () {
                final channel = streams[m.streamId];
                return channel != null && selfHasContentAccess(channel);
              }(),
              DmMessage() => true,
            };
          },
          beforeMessageId: beforeMessageId,
          limit: limit,
          isUnreadFromStore: isUnreadFromStore,
        );

      case ChannelNarrow() || TopicNarrow() || DmNarrow():
        return null;
    }
  }

  Future<SavedMessageSearchResult?> _querySavedMessages({
    required StoredMessageSearchSpec sqlSpec,
    required bool Function(Message) matches,
    int? beforeMessageId,
    required int limit,
    required bool? Function(int messageId)? isUnreadFromStore,
  }) async {
    final dbMatchedById = <int, Message>{};
    if (dbActive && _dbWriter != null && !_dbWriter!.isPoisoned && _dbAccountId != null) {
      final writer = _dbWriter!;
      final accountId = _dbAccountId!;
      final readEpoch = _coverage.epoch;
      final ramIdsAtStart = Set<int>.of(messages.keys);
      final ticket = _raceBuffer.openDbReadTicket(epoch: readEpoch);
      try {
        final batchSize = math.max(limit * 2, 50);
        int? cursorBeforeId = beforeMessageId;
        var decodedCount = 0;
        while (dbMatchedById.length < limit + 1) {
          final batch = await writer.runRead((db) => db.searchStoredMessages(
            accountId,
            spec: sqlSpec,
            beforeMessageId: cursorBeforeId,
            limit: batchSize,
          ));
          if (batch == null || _disposed || _coverage.epoch != readEpoch || ticket.overflowed) {
            dbMatchedById.clear();
            break;
          }
          if (batch.isEmpty) break;
          cursorBeforeId = batch.last.row.id;

          for (final item in batch) {
            if (ramIdsAtStart.contains(item.row.id)) continue;
            if (++decodedCount % 250 == 0) {
              await Future<void>.delayed(Duration.zero);
              if (_disposed || _coverage.epoch != readEpoch || ticket.overflowed) {
                dbMatchedById.clear();
                break;
              }
            }
            final loaded = _maybeInsertLoadedRow(
              item,
              readMark: ticket.mark,
              readEpoch: readEpoch,
              isUnreadFromStore: isUnreadFromStore,
              requireNarrowMatch: null,
              additionalFilter: (m) =>
                (beforeMessageId == null || m.id < beforeMessageId)
                && matches(m),
            );
            if (loaded != null) {
              dbMatchedById[loaded.id] = loaded;
            }
          }
          if (batch.length < batchSize || _disposed || _coverage.epoch != readEpoch || ticket.overflowed) {
            break;
          }
        }
      } finally {
        ticket.close();
      }
      if (_disposed) return null;
    }

    final combinedById = <int, Message>{};
    for (final m in dbMatchedById.values) {
      final current = messages[m.id];
      if (current == null) continue;
      if (beforeMessageId != null && current.id >= beforeMessageId) continue;
      if (_locationUnknown.contains(current.id)) continue;
      if (current.id < _coverage.evictedBelow) continue;
      if (matches(current)) {
        combinedById[current.id] = current;
      }
    }
    for (final m in messages.values) {
      if (beforeMessageId != null && m.id >= beforeMessageId) continue;
      if (_locationUnknown.contains(m.id)) continue;
      if (m.id < _coverage.evictedBelow) continue;
      if (matches(m)) {
        combinedById[m.id] = m;
      }
    }

    final sortedDesc = combinedById.values.toList()
      ..sort((a, b) => b.id.compareTo(a.id));
    final hasMoreOlder = sortedDesc.length > limit;
    final pageAsc = (hasMoreOlder ? sortedDesc.sublist(0, limit) : sortedDesc)
      .reversed
      .toList();
    return (messages: pageAsc, hasMoreOlder: hasMoreOlder);
  }

  /// Apply message-retention purge when channel [channelId]'s retention setting
  /// changes via `ChannelUpdateEvent`.
  void handleChannelRetentionChanged(int channelId) {
    if (_disposed || !coverageEnabled) return;
    final now = _nowSeconds();
    final cutoffs = _computeRetentionCutoffs(now, onlyChannels: [channelId]);
    if (cutoffs.channelCutoffTimestamps.isEmpty) return;
    _applyRetentionPurgeInMemory(
      dmCutoffTimestamp: null,
      channelCutoffTimestamps: cutoffs.channelCutoffTimestamps,
      recordRaceForget: !_suppressCurrentEventDb,
      clipCoverage: _shouldMutateCoverage,
    );
    if (!dbActive) return;
    final writer = _dbWriter!;
    final accountId = _dbAccountId!;
    final startEpoch = _coverage.epoch;
    unawaited(writer.runTrackedPipeline<void>(() async {
      if (_disposed || !dbActive || _coverage.epoch != startEpoch) return;
      await writer.enqueueWrite<void>((db, {required removalOnly}) async {
        if (removalOnly || _disposed || _coverage.epoch != startEpoch) return;
        await db.transaction(() async {
          final current = await db.loadAccountEpochAndWatermarkInTxn(accountId);
          if (current == null || current.epoch != startEpoch) return;
          final dbRes = await db.purgeExpiredRetentionRowsInTxn(
            accountId,
            channelCutoffTimestamps: cutoffs.channelCutoffTimestamps,
          );
          _applyRetentionPurgeInMemory(
            dmCutoffTimestamp: null,
            channelCutoffTimestamps: cutoffs.channelCutoffTimestamps,
            dbMaxDeletedDmId: dbRes.maxDeletedDmId,
            dbMaxDeletedByChannelId: dbRes.maxDeletedByChannelId,
            dbDeletedIds: dbRes.deletedIds,
            recordRaceForget: true,
            clipCoverage: true,
          );
          final dirtyCoverage = _coverage.takeDirtyIntervals();
          if (dirtyCoverage.isNotEmpty) {
            await db.replaceCoverageKeysInTxn(accountId, dirtyCoverage);
          }
        });
      });
    }, isMaintenance: true));
  }

  void _recordEffect(
    MessageEffect effect, {
    Map<String, Object?>? rawMessageMap,
    List<String>? rawFlags,
  }) {
    if (_replayingEvents) return;
    final batch = _pendingBatch;
    final willEnqueue = !_suppressCurrentEventDb && batch != null && dbActive;
    final seq = _raceBuffer.record(effect, needsDbCommit: willEnqueue);
    if (_suppressCurrentEventDb || batch == null) return;
    batch.effects.add((
      effect: effect,
      seq: seq,
      rawMessageMap: rawMessageMap,
      rawFlags: rawFlags,
    ));
  }

  /// Begin collecting DB effects and coverage updates for an event batch.
  ///
  /// When [moveMessageIds] includes IDs not currently loaded in memory and
  /// [dbActive] is true, returns a [Future] that pre-queries their persisted
  /// channel/topic/DM locations so move-origin validation covers DB-only rows too;
  /// otherwise returns null synchronously.
  Future<void>? beginEventBatch({
    required int? lastEventId,
    Iterable<int> moveMessageIds = const [],
  }) {
    assert(_pendingBatch == null);
    if (_replayingEvents || _dbWriter == null) {
      _pendingBatch = null;
      _pendingMoveDbLocations = const {};
      return null;
    }
    _pendingBatch = _PendingEventBatch(
      lastEventId: lastEventId,
      epoch: _coverage.epoch,
    );
    _pendingMoveDbLocations = const {};

    if (!dbActive || moveMessageIds.isEmpty) {
      return null;
    }
    final missingIds = [
      for (final id in moveMessageIds)
        if (!messages.containsKey(id)) id,
    ];
    if (missingIds.isEmpty) {
      return null;
    }
    return _loadMoveDbLocationsForBatch(missingIds);
  }

  Future<void> _loadMoveDbLocationsForBatch(List<int> missingIds) async {
    final accountId = _dbAccountId!;
    final locations = await _dbWriter!.runRead(
      (db) => db.queryStoredLocationsByIds(accountId, missingIds),
    );
    if (_disposed) return;
    if (locations != null) {
      _pendingMoveDbLocations = Map.of(locations);
    }
  }

  /// Configure per-event suppression flags before dispatching one [Event]
  /// inside the active batch.
  void beginBatchEvent({required int eventId, required bool fromQueuePoll}) {
    _suppressCurrentEventDb = _replayingEvents
      || (fromQueuePoll
          && _coverageThroughEventId != null
          && eventId <= _coverageThroughEventId!);
  }

  /// Discard the active batch (e.g., on exception or store disposal).
  void abortEventBatch() {
    final batch = _pendingBatch;
    _pendingBatch = null;
    _pendingMoveDbLocations = const {};
    _suppressCurrentEventDb = false;
    if (batch != null && batch.effects.isNotEmpty) {
      _raceBuffer.markCommitted([for (final entry in batch.effects) entry.seq]);
    }
  }

  /// Commit the current batch's collected DB effects, dirty coverage, dirty
  /// channel flags, watermark, and (optionally) server event log atomically.
  ///
  /// Returns null synchronously when DB persistence is inactive and there are
  /// no removal-only deletes to apply. Otherwise returns a [Future] enforcing a
  /// 2-second timeout; on timeout or DB write failure, poisons the writer
  /// best-effort and resolves to [EventLogCommitOutcome.failed] if an event-log
  /// commit was requested (or [EventLogCommitOutcome.notAttempted] otherwise).
  Future<({EventLogCommitOutcome eventLogOutcome})>? finishEventBatch({
    Future<bool> Function(MessageDatabase db)? commitEventLogInTxn,
  }) {
    final batch = _pendingBatch;
    _pendingBatch = null;
    _pendingMoveDbLocations = const {};
    _suppressCurrentEventDb = false;

    void markBatchCommitted() {
      if (batch != null && batch.effects.isNotEmpty) {
        _raceBuffer.markCommitted([for (final entry in batch.effects) entry.seq]);
      }
    }

    if (_disposed || _replayingEvents || batch == null) {
      markBatchCommitted();
      return null;
    }

    final writer = _dbWriter;
    final accountId = _dbAccountId;
    if (writer == null || accountId == null) {
      markBatchCommitted();
      return null;
    }

    final bool hasRemovals = batch.effects.any(
      (e) => e.effect is DeleteEffect || e.effect is ChannelPurgeEffect);
    if (!dbActive) {
      markBatchCommitted();
      if (writer.isPoisoned && hasRemovals) {
        return _enqueueRemovalOnlyBatch(writer, accountId: accountId, batch: batch)
          .then((_) => (eventLogOutcome: EventLogCommitOutcome.notAttempted));
      }
      return null;
    }

    final dirtyCoverage = _coverage.takeDirtyIntervals();
    final eventHighWater = _coverage.eventHighWater;
    final now = _nowSeconds();

    if (batch.effects.isEmpty
        && batch.dirtyChannelFlags.isEmpty
        && batch.removedChannelIds.isEmpty
        && dirtyCoverage.isEmpty
        && batch.lastEventId == null
        && commitEventLogInTxn == null) {
      markBatchCommitted();
      return null;
    }

    return _commitEventBatchAsync(
      writer: writer,
      accountId: accountId,
      batch: batch,
      dirtyCoverage: dirtyCoverage,
      eventHighWater: eventHighWater,
      now: now,
      commitEventLogInTxn: commitEventLogInTxn,
    );
  }

  Future<({EventLogCommitOutcome eventLogOutcome})> _commitEventBatchAsync({
    required MessageDbWriter writer,
    required int accountId,
    required _PendingEventBatch batch,
    required Map<String, List<CoverageInterval>> dirtyCoverage,
    required int eventHighWater,
    required int now,
    required Future<bool> Function(MessageDatabase db)? commitEventLogInTxn,
  }) async {
    try {
      var timedOut = false;
      final outcome = await writer.enqueueWrite<({bool applied, bool eventLogCommitted, int totalBodyBytes})>(
        (db, {required removalOnly}) async {
          if (timedOut || _disposed) {
            return (applied: false, eventLogCommitted: false, totalBodyBytes: 0);
          }

          List<StoredMessageRecord?>? encodedInserts;
          if (!removalOnly) {
            encodedInserts = List<StoredMessageRecord?>.filled(batch.effects.length, null);
            var encodedCount = 0;
            for (var i = 0; i < batch.effects.length; i++) {
              final entry = batch.effects[i];
              final effect = entry.effect;
              if (effect is! InsertEffect) continue;
              if (encodedCount > 0 && encodedCount % _encodeYieldBatchSize == 0) {
                await Future<void>.delayed(Duration.zero);
                if (timedOut || _disposed) {
                  return (applied: false, eventLogCommitted: false, totalBodyBytes: 0);
                }
              }
              encodedInserts[i] = StoredMessageCodec.encode(
                accountId: accountId,
                message: effect.message,
                rawMap: rawMapOfMessage(effect.message, entry.rawMessageMap),
                epoch: batch.epoch,
                tracked: effect.tracked,
                rawFlagsOverride: entry.rawFlags,
              );
              encodedCount++;
            }
          }

          if (timedOut || _disposed) {
            return (applied: false, eventLogCommitted: false, totalBodyBytes: 0);
          }

          return db.transaction(() async {
            if (timedOut || _disposed) {
              return (applied: false, eventLogCommitted: false, totalBodyBytes: 0);
            }
            if (removalOnly) {
              await _applyRemovalOnlyInTxn(db, accountId: accountId, batch: batch);
              return (applied: false, eventLogCommitted: false, totalBodyBytes: 0);
            }

            final current = await db.loadAccountEpochAndWatermarkInTxn(accountId);
            if (current == null || current.epoch != batch.epoch) {
              return (applied: false, eventLogCommitted: false, totalBodyBytes: 0);
            }

            for (var i = 0; i < batch.effects.length; i++) {
              await applyMessageEffectToDb(
                db,
                accountId: accountId,
                effect: batch.effects[i].effect,
                epoch: batch.epoch,
                preEncodedRecord: encodedInserts![i],
              );
            }

            if (batch.dirtyChannelFlags.isNotEmpty || batch.removedChannelIds.isNotEmpty) {
              await db.upsertChannelsInTxn(
                accountId,
                batch.dirtyChannelFlags,
                removeChannelIds: batch.removedChannelIds,
              );
            }

            if (dirtyCoverage.isNotEmpty) {
              await db.replaceCoverageKeysInTxn(accountId, dirtyCoverage);
            }

            await db.updateAccountEventProgressInTxn(
              accountId: accountId,
              appliedThroughEventId: batch.lastEventId,
              eventHighWater: eventHighWater,
              lastLiveAt: now,
            );

            var eventLogCommitted = false;
            if (commitEventLogInTxn != null) {
              if (timedOut || _disposed) {
                throw StateError('Batch commit timed out or store disposed');
              }
              eventLogCommitted = await commitEventLogInTxn(db);
            }
            if (timedOut || _disposed) {
              throw StateError('Batch commit timed out or store disposed');
            }
            final totalBodyBytes = await db.readTotalBodyBytesInTxn(accountId);
            return (
              applied: true,
              eventLogCommitted: eventLogCommitted,
              totalBodyBytes: totalBodyBytes,
            );
          });
        },
      ).timeout(_eventBatchCommitTimeout, onTimeout: () {
        timedOut = true;
        return null;
      });

      if (_disposed) {
        return (eventLogOutcome: EventLogCommitOutcome.notAttempted);
      }
      if (timedOut || outcome == null || !outcome.applied) {
        _handleWriterPoisoned();
        if (!writer.isPoisoned) {
          unawaited(writer.markPoisoned());
        }
        return (eventLogOutcome: EventLogCommitOutcome.notAttempted);
      }

      if (batch.lastEventId != null
          && (_coverageThroughEventId == null || batch.lastEventId! > _coverageThroughEventId!)) {
        _coverageThroughEventId = batch.lastEventId;
      }
      _lastLiveAt = now;
      _maybeScheduleEviction(outcome.totalBodyBytes);
      _maybeRunDailyRetentionSweep();
      return (
        eventLogOutcome: commitEventLogInTxn == null
          ? EventLogCommitOutcome.notAttempted
          : (outcome.eventLogCommitted
              ? EventLogCommitOutcome.committed
              : EventLogCommitOutcome.rejected),
      );
    } finally {
      if (batch.effects.isNotEmpty) {
        _raceBuffer.markCommitted([for (final entry in batch.effects) entry.seq]);
      }
    }
  }

  Future<void> _enqueueRemovalOnlyBatch(
    MessageDbWriter writer, {
    required int accountId,
    required _PendingEventBatch batch,
  }) async {
    var timedOut = false;
    await writer.enqueueWrite<void>((db, {required removalOnly}) async {
      if (timedOut || _disposed) return;
      await db.transaction(() async {
        if (timedOut || _disposed) return;
        await _applyRemovalOnlyInTxn(db, accountId: accountId, batch: batch);
      });
    }).timeout(_eventBatchCommitTimeout, onTimeout: () {
      timedOut = true;
      return null;
    });
  }

  Future<void> _applyRemovalOnlyInTxn(
    MessageDatabase db, {
    required int accountId,
    required _PendingEventBatch batch,
  }) async {
    for (final entry in batch.effects) {
      final effect = entry.effect;
      if (effect is DeleteEffect || effect is ChannelPurgeEffect) {
        await applyMessageEffectToDb(
          db,
          accountId: accountId,
          effect: effect,
          epoch: batch.epoch,
          removalOnly: true,
        );
      }
    }
  }

  void _ensureCoverageBegun() {
    if (_coverageBegun) return;
    _coverageBegun = true;
    for (final channel in streams.values) {
      _channelHistoryPublic[channel.streamId] = channel.historyPublicToSubscribers;
    }
    _coverage.beginEpoch(
      maxMessageId: _initialSnapshotMaxMessageId,
      lastLiveAt: 0,
      now: _nowSeconds(),
    );
  }

  void debugSetCoverageEnabled(bool value) {
    coverageEnabled = value;
    if (value) _ensureCoverageBegun();
  }

  final Map<int, int> _channelGeneration = {};

  FetchTicket openFetchTicket({int? channelId}) {
    assert(!_disposed);
    if (channelId != null && !_channelHistoryPublic.containsKey(channelId)) {
      final channel = streams[channelId];
      if (channel != null) {
        _channelHistoryPublic[channelId] = channel.historyPublicToSubscribers;
      }
    }
    return _raceBuffer.openTicket(
      epoch: _coverage.epoch,
      knownMaxAtSend: _knownMaxMessageId,
      channelGeneration: channelId != null ? (_channelGeneration[channelId] ?? 0) : null,
      channelDropGeneration: channelId != null ? _coverage.dropGeneration(channelId) : null,
    );
  }

  Future<({Set<int> withData, Set<int> purgedChannels})> _runEpochStartAccessCheckInTxn(
    MessageDatabase db, {
    required int accountId,
    required LoadedMessageDbAccountState? loaded,
    required MessageCoverage coverage,
    required Map<int, bool> channelHistoryPublic,
  }) {
    return runEpochStartAccessCheckInTxn(
      db,
      accountId: accountId,
      channelStore: this,
      inMemoryMessages: messages.values,
      loaded: loaded,
      coverage: coverage,
      channelHistoryPublic: channelHistoryPublic,
    );
  }

  void _purgeChannelsFromMemoryOnly(Set<int> channelIds) {
    if (channelIds.isEmpty) return;
    final purgedIds = [
      for (final message in messages.values)
        if (message is StreamMessage && channelIds.contains(message.streamId))
          message.id,
    ];
    for (final id in purgedIds) {
      messages.remove(id);
      starredMessages.remove(id);
      _maybeStaleMessages.remove(id);
      _locationUnknown.remove(id);
      _editMessageRequests.remove(id);
    }
    for (final channelId in channelIds) {
      _channelGeneration[channelId] = (_channelGeneration[channelId] ?? 0) + 1;
      for (final view in _messageListViews) {
        view.handleChannelPurged(channelId);
      }
    }
  }

  Future<({
    int? dmCutoffTimestamp,
    Map<int, int> channelCutoffTimestamps,
    int? dbMaxDeletedDmId,
    Map<int, int> dbMaxDeletedByChannelId,
    List<int> dbDeletedIds,
  })?> _runEpochStartRetentionInTxn(
    MessageDatabase db, {
    required int accountId,
    required int now,
    required LoadedMessageDbAccountState? loaded,
    required MessageCoverage coverage,
  }) async {
    final cutoffs = _computeRetentionCutoffs(
      now,
      extraChannels: loaded?.channelsWithData,
    );
    if (cutoffs.dmCutoffTimestamp == null && cutoffs.channelCutoffTimestamps.isEmpty) {
      return null;
    }
    final dbRes = await db.purgeExpiredRetentionRowsInTxn(
      accountId,
      dmCutoffTimestamp: cutoffs.dmCutoffTimestamp,
      channelCutoffTimestamps: cutoffs.channelCutoffTimestamps,
    );
    if (dbRes.maxDeletedDmId case final maxDmId?) {
      coverage.clipDmFamilyBelow(1 + maxDmId);
    }
    for (final entry in dbRes.maxDeletedByChannelId.entries) {
      coverage.clipChannelFamilyBelow(entry.key, 1 + entry.value);
    }
    return (
      dmCutoffTimestamp: cutoffs.dmCutoffTimestamp,
      channelCutoffTimestamps: cutoffs.channelCutoffTimestamps,
      dbMaxDeletedDmId: dbRes.maxDeletedDmId,
      dbMaxDeletedByChannelId: dbRes.maxDeletedByChannelId,
      dbDeletedIds: dbRes.deletedIds,
    );
  }

  /// Timeout bounding message-DB transaction work at store startup.
  static const Duration _epochStartTimeout = Duration(seconds: 3);

  /// Initialize message-DB epoch state for a store created from a fresh `/register`.
  ///
  /// Bounded and isolated: never throws; on error or timeout leaves [dbActive]
  /// false and poisons [writer] for the session.
  Future<void> initMessageDbFromRegister({
    required MessageDbWriter writer,
    required int accountId,
    required Uri realmUrl,
    required int userId,
    required String queueId,
    required int lastEventId,
    required Map<String, int> listedDmLatestIds,
  }) async {
    _dbWriter = writer;
    _dbAccountId = accountId;
    coverageEnabled = true;
    var timedOut = false;
    try {
      if (_disposed) return;
      final result = await writer.enqueueEpochStart((db, {required wasPoisoned}) {
        return db.transaction(() async {
          if (timedOut || _disposed) {
            throw StateError('Epoch start aborted after timeout/dispose');
          }
          final now = _nowSeconds();
          if (wasPoisoned) {
            await db.wipeAccount(accountId);
          }
          final valid = wasPoisoned
            ? null
            : await db.ensureAccountInTxn(
                accountId: accountId, realmUrl: realmUrl, userId: userId);
          final loaded = valid != null
            ? await db.loadAccountStateInTxn(accountId)
            : null;
          final stagingCoverage = _coverage.stage();
          final stagingChannelHistoryPublic = Map<int, bool>.of(_channelHistoryPublic);
          if (loaded != null) {
            stagingCoverage.restore(
              epoch: loaded.account.epoch,
              eventHighWater: loaded.account.eventHighWater,
              evictedBelow: loaded.account.evictedBelowMessageId,
              confirmed: true,
              intervalsByKey: loaded.intervalsByKey,
            );
            stagingChannelHistoryPublic
              ..clear()
              ..addAll(loaded.channels);
          } else {
            stagingCoverage.restore(
              epoch: 0,
              eventHighWater: -1,
              evictedBelow: 0,
              confirmed: true,
              intervalsByKey: const {},
            );
            stagingChannelHistoryPublic.clear();
          }

          await db.dropDeletedDmRowsInTxn(
            accountId,
            maxMessageId: _initialSnapshotMaxMessageId,
            listedDmLatestIds: listedDmLatestIds,
          );
          stagingCoverage.beginEpoch(
            maxMessageId: _initialSnapshotMaxMessageId,
            lastLiveAt: loaded?.account.lastLiveAt ?? now,
            now: now,
          );
          if (loaded != null) {
            await db.updateAccountEpochInTxn(
              accountId: accountId,
              epoch: stagingCoverage.epoch,
              queueId: queueId,
              appliedThroughEventId: lastEventId,
              eventHighWater: stagingCoverage.eventHighWater,
              lastLiveAt: now,
            );
          } else {
            await db.upsertAccountInTxn(
              accountId: accountId,
              realmUrl: realmUrl,
              userId: userId,
              epoch: stagingCoverage.epoch,
              queueId: queueId,
              appliedThroughEventId: lastEventId,
              eventHighWater: stagingCoverage.eventHighWater,
              lastLiveAt: now,
            );
          }
          final accessRes = await _runEpochStartAccessCheckInTxn(
            db,
            accountId: accountId,
            loaded: loaded,
            coverage: stagingCoverage,
            channelHistoryPublic: stagingChannelHistoryPublic,
          );
          final retentionRes = await _runEpochStartRetentionInTxn(
            db,
            accountId: accountId,
            now: now,
            loaded: loaded,
            coverage: stagingCoverage,
          );
          await db.replaceCoverageKeysInTxn(accountId, stagingCoverage.takeDirtyIntervals());
          if (timedOut || _disposed) {
            throw StateError('Epoch start aborted after timeout/dispose');
          }
          final totalBodyBytes = await db.readTotalBodyBytesInTxn(accountId);
          return (
            coverage: stagingCoverage,
            channelHistoryPublic: stagingChannelHistoryPublic,
            withData: accessRes.withData,
            purgedChannels: accessRes.purgedChannels,
            retentionRes: retentionRes,
            now: now,
            totalBodyBytes: totalBodyBytes,
          );
        });
      }).timeout(_epochStartTimeout, onTimeout: () {
        timedOut = true;
        return null;
      });
      if (_disposed) return;
      if (result == null) {
        _dbActive = false;
        _coverage.retainOnlyOpenViewSpans(const {}, isKeyTracked: (_) => false);
        if (timedOut) {
          writer.poisonInMemoryOnly();
        } else {
          unawaited(writer.markPoisoned());
        }
        return;
      }
      _coverage.adoptFrom(result.coverage);
      _channelHistoryPublic
        ..clear()
        ..addAll(result.channelHistoryPublic);
      _raceBuffer.closeAll();
      _purgeChannelsFromMemoryOnly(result.purgedChannels);
      if (result.retentionRes case final ret?) {
        _applyRetentionPurgeInMemory(
          dmCutoffTimestamp: ret.dmCutoffTimestamp,
          channelCutoffTimestamps: ret.channelCutoffTimestamps,
          dbMaxDeletedDmId: ret.dbMaxDeletedDmId,
          dbMaxDeletedByChannelId: ret.dbMaxDeletedByChannelId,
          dbDeletedIds: ret.dbDeletedIds,
          clipCoverage: false,
        );
      }
      _channelsWithData
        ..clear()
        ..addAll(result.withData);
      _coverageThroughEventId = lastEventId;
      _lastLiveAt = result.now;
      _lastRetentionSweepAt = result.now;
      _coverageBegun = true;
      _confirmed = true;
      _dbActive = true;
      writer.onPoisoned = _handleWriterPoisoned;
      _maybeScheduleEviction(result.totalBodyBytes);
    } catch (e, s) {
      assert(debugLog('initMessageDbFromRegister failed: $e\n$s'));
      _dbActive = false;
      _coverage.retainOnlyOpenViewSpans(const {}, isKeyTracked: (_) => false);
      unawaited(writer.markPoisoned());
    }
  }

  /// Initialize message-DB epoch state for a store restored from persisted
  /// server snapshot data.
  ///
  /// Continues the persisted epoch (unconfirmed) if `!eventLogSkipped`,
  /// `queueId` matches, and `appliedThroughEventId >= ackEventId`;
  /// otherwise bumps (or initializes) an unconfirmed epoch. Never throws.
  Future<void> initMessageDbFromPersisted({
    required MessageDbWriter writer,
    required int accountId,
    required Uri realmUrl,
    required int userId,
    required String queueId,
    required int ackEventId,
    bool eventLogSkipped = false,
  }) async {
    _dbWriter = writer;
    _dbAccountId = accountId;
    var timedOut = false;
    try {
      if (_disposed) return;
      final result = await writer.enqueueEpochStart((db, {required wasPoisoned}) {
        return db.transaction(() async {
          if (timedOut || _disposed) {
            throw StateError('Persisted epoch start aborted after timeout/dispose');
          }
          final now = _nowSeconds();
          if (wasPoisoned) {
            await db.wipeAccount(accountId);
          }
          final valid = wasPoisoned
            ? null
            : await db.ensureAccountInTxn(
                accountId: accountId, realmUrl: realmUrl, userId: userId);
          var loaded = valid != null
            ? await db.loadAccountStateInTxn(accountId)
            : null;
          final stagingCoverage = _coverage.stage();
          final stagingChannelHistoryPublic = Map<int, bool>.of(_channelHistoryPublic);

          final bool hasPostWatermarkPrefetch = loaded != null && (
            loaded.intervalsByKey.values.any((list) => list.any(
              (iv) => iv.epoch == 0 && iv.top > loaded!.account.eventHighWater))
            || await db.hasPrefetchedRowAboveInTxn(
              accountId, loaded.account.eventHighWater));

          if (loaded != null
              && !eventLogSkipped
              && !hasPostWatermarkPrefetch
              && loaded.account.queueId == queueId
              && loaded.account.appliedThroughEventId != null
              && loaded.account.appliedThroughEventId! >= ackEventId) {
            stagingCoverage.restore(
              epoch: loaded.account.epoch,
              eventHighWater: loaded.account.eventHighWater,
              evictedBelow: loaded.account.evictedBelowMessageId,
              confirmed: false,
              intervalsByKey: loaded.intervalsByKey,
            );
            stagingChannelHistoryPublic
              ..clear()
              ..addAll(loaded.channels);
            final accessRes = await _runEpochStartAccessCheckInTxn(
              db,
              accountId: accountId,
              loaded: loaded,
              coverage: stagingCoverage,
              channelHistoryPublic: stagingChannelHistoryPublic,
            );
            final retentionRes = await _runEpochStartRetentionInTxn(
              db,
              accountId: accountId,
              now: now,
              loaded: loaded,
              coverage: stagingCoverage,
            );
            final dirtyCoverage = stagingCoverage.takeDirtyIntervals();
            if (dirtyCoverage.isNotEmpty) {
              await db.replaceCoverageKeysInTxn(accountId, dirtyCoverage);
            }
            if (timedOut || _disposed) {
              throw StateError('Persisted epoch start aborted');
            }
            final totalBodyBytes = await db.readTotalBodyBytesInTxn(accountId);
            return (
              coverage: stagingCoverage,
              channelHistoryPublic: stagingChannelHistoryPublic,
              withData: accessRes.withData,
              purgedChannels: accessRes.purgedChannels,
              retentionRes: retentionRes,
              now: now,
              throughEventId: loaded.account.appliedThroughEventId!,
              lastLiveAt: loaded.account.lastLiveAt,
              totalBodyBytes: totalBodyBytes,
            );
          }

          if (loaded != null
              && loaded.account.queueId == queueId
              && loaded.account.appliedThroughEventId != null
              && loaded.account.appliedThroughEventId! < ackEventId) {
            // An earlier run missed committing events past appliedThroughEventId;
            // wipe to preserve cache accuracy.
            await db.wipeAccount(accountId);
            loaded = null;
          }

          if (loaded != null) {
            stagingCoverage.restore(
              epoch: loaded.account.epoch,
              eventHighWater: loaded.account.eventHighWater,
              evictedBelow: loaded.account.evictedBelowMessageId,
              confirmed: false,
              intervalsByKey: loaded.intervalsByKey,
            );
            stagingChannelHistoryPublic
              ..clear()
              ..addAll(loaded.channels);
          } else {
            stagingCoverage.restore(
              epoch: 0,
              eventHighWater: -1,
              evictedBelow: 0,
              confirmed: false,
              intervalsByKey: const {},
            );
            stagingChannelHistoryPublic.clear();
          }

          stagingCoverage.beginEpoch(
            maxMessageId: null,
            lastLiveAt: loaded?.account.lastLiveAt ?? now,
            now: now,
          );
          stagingCoverage.markUnconfirmed();
          if (loaded != null) {
            await db.updateAccountEpochInTxn(
              accountId: accountId,
              epoch: stagingCoverage.epoch,
              queueId: queueId,
              appliedThroughEventId: ackEventId,
              eventHighWater: stagingCoverage.eventHighWater,
              lastLiveAt: loaded.account.lastLiveAt,
            );
          } else {
            await db.upsertAccountInTxn(
              accountId: accountId,
              realmUrl: realmUrl,
              userId: userId,
              epoch: stagingCoverage.epoch,
              queueId: queueId,
              appliedThroughEventId: ackEventId,
              eventHighWater: stagingCoverage.eventHighWater,
              lastLiveAt: null,
            );
          }
          final ({Set<int> withData, Set<int> purgedChannels}) accessRes;
          final ({
            int? dmCutoffTimestamp,
            Map<int, int> channelCutoffTimestamps,
            int? dbMaxDeletedDmId,
            Map<int, int> dbMaxDeletedByChannelId,
            List<int> dbDeletedIds,
          })? retentionRes;
          if (eventLogSkipped) {
            // The store's channel/subscription metadata is at initialSnapshot
            // (behind MessageDatabase at ackEventId) and will be immediately
            // replaced via /register; do not purge newer channels against stale
            // metadata.
            accessRes = (
              withData: loaded?.channelsWithData ?? const <int>{},
              purgedChannels: const <int>{},
            );
            retentionRes = null;
          } else {
            accessRes = await _runEpochStartAccessCheckInTxn(
              db,
              accountId: accountId,
              loaded: loaded,
              coverage: stagingCoverage,
              channelHistoryPublic: stagingChannelHistoryPublic,
            );
            retentionRes = await _runEpochStartRetentionInTxn(
              db,
              accountId: accountId,
              now: now,
              loaded: loaded,
              coverage: stagingCoverage,
            );
          }
          await db.replaceCoverageKeysInTxn(accountId, stagingCoverage.takeDirtyIntervals());
          if (timedOut || _disposed) {
            throw StateError('Persisted epoch start aborted');
          }
          final totalBodyBytes = await db.readTotalBodyBytesInTxn(accountId);
          return (
            coverage: stagingCoverage,
            channelHistoryPublic: stagingChannelHistoryPublic,
            withData: accessRes.withData,
            purgedChannels: accessRes.purgedChannels,
            retentionRes: retentionRes,
            now: now,
            throughEventId: ackEventId,
            lastLiveAt: loaded?.account.lastLiveAt,
            totalBodyBytes: totalBodyBytes,
          );
        });
      }).timeout(_epochStartTimeout, onTimeout: () {
        timedOut = true;
        return null;
      });
      if (_disposed) return;
      if (result == null) {
        _dbActive = false;
        _coverage.retainOnlyOpenViewSpans(const {}, isKeyTracked: (_) => false);
        if (timedOut) {
          writer.poisonInMemoryOnly();
        } else {
          unawaited(writer.markPoisoned());
        }
        return;
      }
      _coverage.adoptFrom(result.coverage);
      _channelHistoryPublic
        ..clear()
        ..addAll(result.channelHistoryPublic);
      _raceBuffer.closeAll();
      _purgeChannelsFromMemoryOnly(result.purgedChannels);
      if (result.retentionRes case final ret?) {
        _applyRetentionPurgeInMemory(
          dmCutoffTimestamp: ret.dmCutoffTimestamp,
          channelCutoffTimestamps: ret.channelCutoffTimestamps,
          dbMaxDeletedDmId: ret.dbMaxDeletedDmId,
          dbMaxDeletedByChannelId: ret.dbMaxDeletedByChannelId,
          dbDeletedIds: ret.dbDeletedIds,
          clipCoverage: false,
        );
      }
      _channelsWithData
        ..clear()
        ..addAll(result.withData);
      _coverageThroughEventId = result.throughEventId;
      _lastLiveAt = result.lastLiveAt;
      _lastRetentionSweepAt = result.now;
      _coverageBegun = true;
      _confirmed = false;
      coverageEnabled = true;
      _dbActive = true;
      writer.onPoisoned = _handleWriterPoisoned;
      _maybeScheduleEviction(result.totalBodyBytes);
    } catch (e, s) {
      assert(debugLog('initMessageDbFromPersisted failed: $e\n$s'));
      _dbActive = false;
      _coverage.retainOnlyOpenViewSpans(const {}, isKeyTracked: (_) => false);
      unawaited(writer.markPoisoned());
    }
  }

  void closeFetchTicket(FetchTicket ticket) {
    _raceBuffer.closeTicket(ticket);
  }

  static const _markReadOnScrollBatchSize = 1000;
  static const _markReadOnScrollDebounceDuration = Duration(milliseconds: 500);
  final _markReadOnScrollQueue = _MarkReadOnScrollQueue();
  final Set<int> _carriedOverUnreadIds = {};
  bool _markReadOnScrollBusy = false;
  bool _isRecoveringEventStream = false;
  Completer<void>? _markReadWakeCompleter;
  BackoffMachine? _markReadBackoffMachine;
  Timer? _markReadDebounceTimer;
  Completer<void>? _markReadDebounceCompleter;

  List<int> takePendingMarkReadIds() {
    final result = <int>[
      for (final id in _markReadOnScrollQueue.iterable)
        if (messages[id] != null
            ? !messages[id]!.flags.contains(MessageFlag.read)
            : _carriedOverUnreadIds.contains(id))
          id,
    ];
    _markReadOnScrollQueue.clear();
    _carriedOverUnreadIds.clear();
    return result;
  }

  void enqueueCarriedOverMarkReadIds(Iterable<int> messageIds) {
    assert(!_disposed);
    final ids = messageIds.toList();
    if (ids.isEmpty) return;
    _carriedOverUnreadIds.addAll(ids);
    markReadFromScroll(ids);
  }

  void setIsRecoveringEventStream(bool value) {
    if (_isRecoveringEventStream == value) return;
    _isRecoveringEventStream = value;
    if (!value) {
      _markReadWakeCompleter?.complete();
      _markReadWakeCompleter = null;
    }
  }

  Future<void> _waitForEventStreamRecovery() {
    final completer = _markReadWakeCompleter ??= Completer<void>();
    return completer.future;
  }

  Future<void> _waitMarkReadDebounce() {
    assert(_markReadDebounceTimer == null);
    assert(_markReadDebounceCompleter == null);
    final completer = _markReadDebounceCompleter = Completer<void>();
    _markReadDebounceTimer = Timer(_markReadOnScrollDebounceDuration, () {
      _markReadDebounceTimer = null;
      _markReadDebounceCompleter = null;
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    return completer.future;
  }

  Future<_MarkReadSendOutcome> _sendMarkReadOnScrollRequest(List<int> toSend) async {
    assert(toSend.isNotEmpty);

    // TODO(#1581) mark as read locally for latency compensation
    //   (in Unreads and on the message objects)
    try {
      await updateMessageFlags(connection,
        messages: toSend,
        op: UpdateMessageFlagsOp.add,
        flag: MessageFlag.read);
    } on ApiRequestException catch (e) {
      // TODO(#1581) un-mark as read locally?
      return isRetryableRequestError(e)
        ? _MarkReadSendOutcome.retryableFailure
        : _MarkReadSendOutcome.dropBatch;
    }
    return _MarkReadSendOutcome.sent;
  }

  @override
  void markReadFromScroll(Iterable<int> messageIds) async {
    assert(!_disposed);
    _markReadOnScrollQueue.addAll(messageIds);
    if (_markReadOnScrollBusy) return;

    _markReadOnScrollBusy = true;
    try {
      do {
        while (_isRecoveringEventStream) {
          await _waitForEventStreamRecovery();
          if (_disposed) return;
        }

        final toSend = <int>[];
        int numFromQueue = 0;
        for (final messageId in _markReadOnScrollQueue.iterable) {
          if (toSend.length == _markReadOnScrollBatchSize) {
            break;
          }
          final message = messages[messageId];
          if (message != null
              ? !message.flags.contains(MessageFlag.read)
              : _carriedOverUnreadIds.contains(messageId)) {
            toSend.add(messageId);
          }
          numFromQueue++;
        }

        final outcome = toSend.isEmpty
          ? _MarkReadSendOutcome.sent
          : await _sendMarkReadOnScrollRequest(toSend);
        if (_disposed) return;

        switch (outcome) {
          case _MarkReadSendOutcome.sent:
          case _MarkReadSendOutcome.dropBatch:
            final removed = _markReadOnScrollQueue.removeFirstN(numFromQueue);
            _carriedOverUnreadIds.removeAll(removed);
            _markReadBackoffMachine = null;
            await _waitMarkReadDebounce();
            if (_disposed) return;
          case _MarkReadSendOutcome.retryableFailure:
            final backoffMachine = _markReadBackoffMachine ??= BackoffMachine();
            final wakeFuture = _waitForEventStreamRecovery();
            await backoffMachine.wait(abortTrigger: wakeFuture);
            if (_disposed) return;
        }
      } while (_markReadOnScrollQueue.isNotEmpty);
    } finally {
      if (!_disposed) {
        _markReadOnScrollBusy = false;
      }
    }
  }

  @override
  Future<void> sendMessage({required MessageDestination destination, required String content}) {
    assert(!_disposed);
    if (!debugOutboxEnable) {
      return _trackInFlightSend(() => _apiSendMessage(connection,
        destination: destination,
        content: content));
    }
    return _outboxSendMessage(destination: destination, content: content);
  }

  void reconcileMessages(
    List<Message> messages, {
    FetchTicket? ticket,
    FetchCoverageRequest? coverageRequest,
    MessageListView? requester,
    List<Map<String, dynamic>>? rawMessages,
  }) {
    final writeFuture = _reconcileMessages(
      messages,
      ticket: ticket,
      coverageRequest: coverageRequest,
      requester: requester,
      rawMessages: rawMessages,
    );
    if (writeFuture != null) {
      unawaited(writeFuture);
    }
  }

  Future<void>? _reconcileMessages(
    List<Message> messages, {
    FetchTicket? ticket,
    FetchCoverageRequest? coverageRequest,
    MessageListView? requester,
    List<Map<String, dynamic>>? rawMessages,
  }) {
    assert(!_disposed);
    assert(ticket == null || !ticket.isClosed);

    // Discard fetches sent in an earlier epoch: changes across the queue gap
    // arrived with no events in _raceBuffer, so neither stored messages nor
    // coverage may be mutated by an earlier-epoch snapshot.
    if (coverageEnabled && ticket != null && ticket.epoch != _coverage.epoch) {
      int out = 0;
      for (int i = 0; i < messages.length; i++) {
        final m = _stripMatchFields(messages[i]);
        if (m is StreamMessage) {
          final ch = streams[m.streamId];
          if (ch == null || !selfHasContentAccess(ch)) continue;
        }
        messages[out++] = m;
      }
      messages.length = out;
      return null;
    }

    final bool canWriteDb = dbActive
      && (ticket == null || (!ticket.overflowed && ticket.epoch == _coverage.epoch));
    final int writeEpoch = _coverage.epoch;

    final Map<int, Map<String, dynamic>>? rawById = (canWriteDb && rawMessages != null)
      ? {
          for (final raw in rawMessages)
            if (raw['id'] is num) (raw['id'] as num).toInt(): raw,
        }
      : null;

    final List<int>? unfilteredIds =
      (coverageEnabled && ticket != null && coverageRequest != null)
        ? [for (final m in messages) m.id]
        : null;
    bool topicFoldMismatch = false;
    final String? expectedTopicFold = switch (coverageRequest?.narrow) {
      TopicNarrow(:final topic) => serverTopicFold(topic.apiName),
      _ => null,
    };

    final toUpsert = <({Message message, Map<String, dynamic>? rawMap})>[];
    final toTouchOnly = <({Message message, Map<String, dynamic>? rawMap})>[];

    bool shouldPersistMessage(Message m) {
      if (m.id < _coverage.evictedBelow) return false;
      if (m is StreamMessage) {
        final channel = streams[m.streamId];
        if (channel == null || !selfHasContentAccess(channel)) return false;
      }
      return true;
    }

    List<Message>? newlyLearned;
    List<({Message oldMessage, Message newMessage})>? clobbered;
    int writeIndex = 0;
    for (int i = 0; i < messages.length; i++) {
      final message = messages[i];
      if (message.id > _knownMaxMessageId) {
        _knownMaxMessageId = message.id;
      }
      if (expectedTopicFold != null
          && message is StreamMessage
          && serverTopicFold(message.topic.apiName) != expectedTopicFold) {
        topicFoldMismatch = true;
      }

      // TODO(#649) update Unreads, if [Unreads.oldUnreadsMissing]
      // TODO(#650) update RecentDmConversationsView

      // It's tempting to update [starredMessages] based on fetched messages,
      // like Unreads and RecentDmConversationsView.
      // But we don't need to: per the API doc, InitialSnapshot.starredMessages
      // is the complete list of starred message IDs. So we can maintain it
      // using just the event system, avoiding the fetch/event race
      // as a cause of inaccuracies.

      final existing = this.messages[message.id];
      if (existing == null) {
        if (ticket != null && _raceBuffer.wasRemovedOrPurgedAfter(
          ticket.mark,
          message.id,
          channelId: message is StreamMessage ? message.streamId : null,
        )) {
          continue;
        }
        final result = _reconcileUnrecognizedMessage(message);
        if (ticket != null) {
          _raceBuffer.applyEffectsAfter(ticket.mark, result);
          if (result is StreamMessage) {
            if (_raceBuffer.wasRemovedOrPurgedAfter(
                  ticket.mark, result.id, channelId: result.streamId)) {
              continue;
            }
            if (coverageEnabled) {
              final ch = streams[result.streamId];
              if (ch == null || !selfHasContentAccess(ch)) {
                continue;
              }
            }
          }
          if (ticket.overflowed
              || (result is StreamMessage
                  && (subscriptions[result.streamId] == null
                      || _raceBuffer.wasChannelUntrackedAfter(ticket.mark, result.streamId)))) {
            _maybeStaleMessages.add(result.id);
          }
        }
        this.messages[message.id] = result;
        (newlyLearned ??= []).add(result);
        messages[writeIndex++] = result;
        if (canWriteDb && shouldPersistMessage(result)) {
          toUpsert.add((message: result, rawMap: rawById?[result.id]));
        }
      } else {
        if (ticket != null && _raceBuffer.wasRemovedOrPurgedAfter(
          ticket.mark,
          message.id,
          channelId: message is StreamMessage ? message.streamId : null,
        )) {
          continue;
        }
        final candidate = _stripMatchFields(message);
        if (ticket != null) {
          _raceBuffer.applyEffectsAfter(ticket.mark, candidate);
          if (candidate is StreamMessage) {
            if (_raceBuffer.wasRemovedOrPurgedAfter(
                  ticket.mark, candidate.id, channelId: candidate.streamId)) {
              continue;
            }
            if (coverageEnabled) {
              final ch = streams[candidate.streamId];
              if (ch == null || !selfHasContentAccess(ch)) {
                continue;
              }
            }
          }
        }
        final result = _reconcileRecognizedMessage(
          existing,
          candidate,
          ticket: ticket,
        );
        final bool unchangedBody = canWriteDb && hasSamePersistedMessageData(existing, result);
        if (!identical(result, existing)) {
          if (coverageEnabled
              && existing is StreamMessage
              && result is StreamMessage
              && (existing.streamId != result.streamId
                  || serverTopicFold(existing.topic.apiName)
                      != serverTopicFold(result.topic.apiName))) {
            _coverage.forget(
              CoverageKeys.topic(result.streamId, result.topic.apiName),
              _keysOfMessage(existing),
              existing.id,
            );
          }
          this.messages[message.id] = result;
          (clobbered ??= []).add((oldMessage: existing, newMessage: result));
        }
        messages[writeIndex++] = result;
        if (canWriteDb && shouldPersistMessage(result)) {
          final rawMap = rawById?[result.id];
          if (unchangedBody) {
            toTouchOnly.add((message: result, rawMap: rawMap));
          } else {
            toUpsert.add((message: result, rawMap: rawMap));
          }
        }
      }
    }
    if (messages.isNotEmpty) {
      messages.length = writeIndex;
    }

    if (clobbered case final clobbered?) {
      for (final view in _messageListViews) {
        view.handleMessagesClobbered(
          clobbered,
          isRequester: identical(view, requester),
        );
      }
    }

    if (newlyLearned case final newlyLearned?) {
      for (final view in _messageListViews) {
        if (identical(view, requester)) continue;
        view.handleMessagesLearnedFromFetch(newlyLearned);
      }
    }

    _removeDeliveredOutboxMessages();

    _RecordedCoveragePlan? coveragePlan;
    if (coverageEnabled && ticket != null && coverageRequest != null) {
      coveragePlan = _recordFetchCoverage(
        ticket: ticket,
        request: coverageRequest,
        unfilteredIds: unfilteredIds!,
        topicFoldMismatch: topicFoldMismatch,
      );
    }

    Future<void>? writeFuture;
    if (canWriteDb
        && (toUpsert.isNotEmpty || toTouchOnly.isNotEmpty || coveragePlan != null)) {
      writeFuture = _scheduleFetchWritePipeline(
        writer: _dbWriter!,
        accountId: _dbAccountId!,
        writeEpoch: writeEpoch,
        ticket: ticket,
        unfilteredIds: unfilteredIds ?? const [],
        toUpsert: toUpsert,
        toTouchOnly: toTouchOnly,
        coveragePlan: coveragePlan,
      );
    }
    if (coverageEnabled) {
      _maybeRunDailyRetentionSweep();
    }
    return writeFuture;
  }

  final Map<String, Future<void>> _inFlightNotifPrefetches = {};
  final Map<String, int> _pendingNotifPrefetchMaxId = {};

  /// Prefetch messages around [messageId] in [narrow] so the notified
  /// conversation is available offline, returning any newly fetched messages.
  ///
  /// Skips the network request when [messageId] and its surrounding context
  /// are already covered, and coalesces concurrent notifications for the same
  /// conversation. Never throws.
  Future<List<Message>> prefetchNotificationMessages({
    required SendableNarrow narrow,
    required int messageId,
    Future<void>? abortTrigger,
  }) async {
    if (_disposed || !dbActive) return const [];
    final key = coverageKey(narrow);
    if (key == null) return const [];
    if (narrow case TopicNarrow(:final channelId)) {
      final channel = streams[channelId];
      if (channel == null || !selfHasContentAccess(channel)) return const [];
    }

    final existingInFlight = _inFlightNotifPrefetches[key];
    if (existingInFlight != null) {
      final prevPending = _pendingNotifPrefetchMaxId[key];
      if (prevPending == null || messageId > prevPending) {
        _pendingNotifPrefetchMaxId[key] = messageId;
      }
      await existingInFlight;
      return const [];
    }

    final completer = Completer<void>();
    _inFlightNotifPrefetches[key] = completer.future;
    final allFetched = <Message>[];
    try {
      var targetId = messageId;
      while (!_disposed && dbActive) {
        if (await _isNotificationAlreadyCovered(narrow, key, targetId)) {
          final nextId = _pendingNotifPrefetchMaxId.remove(key);
          if (nextId == null || nextId <= targetId) break;
          targetId = nextId;
          continue;
        }
        final batch = await _runSingleNotificationPrefetch(
          narrow: narrow,
          targetMessageId: targetId,
          abortTrigger: abortTrigger,
        );
        if (batch != null) {
          allFetched.addAll(batch);
        }
        final nextId = _pendingNotifPrefetchMaxId.remove(key);
        if (nextId == null) break;
        targetId = nextId;
      }
      return allFetched;
    } finally {
      _pendingNotifPrefetchMaxId.remove(key);
      unawaited(_inFlightNotifPrefetches.remove(key));
      completer.complete();
    }
  }

  Future<bool> _isNotificationAlreadyCovered(
    SendableNarrow narrow,
    String key,
    int targetId,
  ) async {
    if (_disposed || !dbActive) return true;
    if (targetId < _coverage.evictedBelow) return true;
    final chain = _coverage.chainAt(key, targetId);
    if (chain == null) return false;

    bool targetPresent = messages.containsKey(targetId)
      && !_locationUnknown.contains(targetId);
    if (!targetPresent) {
      if (!chain.isOpen || targetId <= _coverage.eventHighWater) {
        targetPresent = true;
      } else {
        targetPresent = await _dbWriter!.runRead(
          (db) => db.hasStoredMessage(_dbAccountId!, targetId),
        ) ?? false;
      }
    }
    if (!targetPresent || _disposed || !dbActive) return targetPresent;
    if (chain.reachesOldest) return true;

    int ramBeforeCount = 0;
    for (final m in messages.values) {
      if (!_locationUnknown.contains(m.id)
          && m.id >= chain.lo
          && m.id < targetId
          && _messageMatchesCoverageNarrow(m, narrow)) {
        ramBeforeCount++;
        if (ramBeforeCount >= kNotificationPrefetchBefore) return true;
      }
    }
    final (channelId, topicKey, dmKey) = scopeFiltersForNarrow(narrow);
    final dbBeforeCount = await _dbWriter!.runRead((db) =>
      db.countStoredBeforeInScope(
        _dbAccountId!,
        channelId: channelId,
        topicKey: topicKey,
        dmKey: dmKey,
        lo: chain.lo,
        beforeId: targetId,
        limit: kNotificationPrefetchBefore,
      )) ?? 0;
    return dbBeforeCount >= kNotificationPrefetchBefore;
  }

  Future<List<Message>?> _runSingleNotificationPrefetch({
    required SendableNarrow narrow,
    required int targetMessageId,
    Future<void>? abortTrigger,
  }) async {
    if (_disposed || !dbActive) return null;
    final int? channelId = switch (narrow) {
      TopicNarrow(:final channelId) => channelId,
      DmNarrow() => null,
    };
    if (channelId != null) {
      final channel = streams[channelId];
      if (channel == null || !selfHasContentAccess(channel)) return null;
    }
    final ticket = openFetchTicket(channelId: channelId);
    GetMessagesResult result;
    try {
      result = await getMessages(
        connection,
        narrow: narrow.apiEncode(),
        anchor: NumericAnchor(targetMessageId),
        numBefore: kNotificationPrefetchBefore,
        numAfter: kNotificationPrefetchAfter,
        allowEmptyTopicName: true,
        abortTrigger: abortTrigger,
      );
    } catch (e) {
      assert(debugLog('Notification message prefetch failed: $e'));
      closeFetchTicket(ticket);
      return null;
    }
    if (_disposed) {
      closeFetchTicket(ticket);
      return null;
    }
    Future<void>? dbWrite;
    try {
      dbWrite = _reconcileMessages(
        result.messages,
        rawMessages: result.rawMessages,
        ticket: ticket,
        coverageRequest: FetchCoverageRequest(
          narrow: narrow,
          numBefore: kNotificationPrefetchBefore,
          numAfter: kNotificationPrefetchAfter,
          includeAnchor: true,
          foundOldest: result.foundOldest,
          foundNewest: result.foundNewest,
          historyLimited: result.historyLimited,
          resolvedAnchor: result.anchor,
        ),
      );
    } finally {
      closeFetchTicket(ticket);
    }
    if (dbWrite != null) {
      await dbWrite;
    }
    return result.messages;
  }

  _RecordedCoveragePlan? _recordFetchCoverage({
    required FetchTicket ticket,
    required FetchCoverageRequest request,
    required List<int> unfilteredIds,
    required bool topicFoldMismatch,
  }) {
    if (ticket.overflowed) return null;
    if (ticket.epoch != _coverage.epoch) return null;
    if (topicFoldMismatch) return null;

    final narrow = request.narrow;
    // If a `with` permalink fetch returned nothing, the narrow wasn't resolved.
    if (narrow is TopicNarrow && narrow.with_ != null) return null;

    final key = coverageKey(narrow);
    if (key == null) return null;

    final int? channelId = switch (narrow) {
      ChannelNarrow(:final channelId) || TopicNarrow(:final channelId) => channelId,
      _ => null,
    };
    if (channelId != null) {
      if (_raceBuffer.wasChannelPurgedAfter(ticket.mark, channelId)) return null;
      if (_coverage.dropGeneration(channelId) != ticket.channelDropGeneration) {
        return null;
      }
      if (unfilteredIds.isEmpty && request.foundOldest && request.foundNewest) {
        final channel = streams[channelId];
        if (channel == null || !selfHasContentAccess(channel)) return null;
      }
    }

    final continuous = ticket.epoch == _coverage.epoch;
    final tracked = channelId == null
      || (subscriptions[channelId] != null
          && (_channelGeneration[channelId] ?? 0) == ticket.channelGeneration);
    final anchorKnownVisible = unfilteredIds.contains(request.resolvedAnchor)
      || messages.containsKey(request.resolvedAnchor);

    final intervals = MessageCoverage.fetchIntervals(
      anchor: request.resolvedAnchor,
      numBefore: request.numBefore,
      numAfter: request.numAfter,
      includeAnchor: request.includeAnchor,
      ids: unfilteredIds,
      foundOldest: request.foundOldest,
      foundNewest: request.foundNewest,
      historyLimited: request.historyLimited,
      tracked: tracked,
      continuous: continuous,
      knownMaxAtSend: ticket.knownMaxAtSend,
      anchorKnownVisible: anchorKnownVisible,
    );
    if (intervals.isEmpty) return null;

    final ramForgottenIds = _forgetAbsentInRange(
      key: key,
      narrow: narrow,
      intervals: intervals,
      unfilteredIds: unfilteredIds,
      mark: ticket.mark,
    );

    final movesAfterMark = [
      for (final move in _raceBuffer.moveEffectsAfter(ticket.mark))
        CoverageMove(
          messageIds: move.messageIds,
          origChannelId: move.origChannelId,
          origTopic: move.origTopic.apiName,
          newChannelId: move.newChannelId,
          newTopic: move.newTopic.apiName,
        ),
    ];
    final now = _nowSeconds();
    for (final bounds in intervals) {
      _coverage.recordFetch(
        key,
        bounds,
        epoch: _coverage.epoch,
        tracked: tracked,
        verifiedAt: now,
        movesAfterMark: movesAfterMark,
        isStored: (id) => messages.containsKey(id) && !_locationUnknown.contains(id),
      );
    }

    return (
      key: key,
      narrow: narrow,
      intervals: intervals,
      ramForgottenIds: ramForgottenIds,
    );
  }

  List<int> _forgetAbsentInRange({
    required String key,
    required Narrow narrow,
    required List<FetchBounds> intervals,
    required List<int> unfilteredIds,
    required int mark,
  }) {
    final resultIds = unfilteredIds.toSet();
    final touchedAfterMark = _raceBuffer.arrivedOrMovedIdsAfter(mark);

    final newlyForgotten = <Message>[];
    final absentInViews = <int>[];
    for (final message in messages.values) {
      final id = message.id;
      if (resultIds.contains(id)) continue;
      if (touchedAfterMark.contains(id)) continue;
      final alreadyUnknown = _locationUnknown.contains(id);
      if (!alreadyUnknown && !_messageMatchesCoverageNarrow(message, narrow)) {
        continue;
      }
      final inInterval = intervals.any((b) =>
        id >= b.lo && (b.hi == null || id <= b.hi!));
      if (!inInterval) continue;
      absentInViews.add(id);
      if (!alreadyUnknown) {
        newlyForgotten.add(message);
      }
    }

    final forgottenIds = [for (final m in newlyForgotten) m.id];
    if (newlyForgotten.isNotEmpty) {
      _raceBuffer.record(ForgetEffect(messageIds: forgottenIds));
      for (final message in newlyForgotten) {
        _maybeStaleMessages.add(message.id);
        _locationUnknown.add(message.id);
        _coverage.forget(key, _keysOfMessage(message), message.id);
      }
    }

    if (absentInViews.isNotEmpty) {
      for (final view in _messageListViews) {
        final viewKey = coverageKey(view.narrow);
        if (viewKey != null && (viewKey == key || CoverageKeys.isSubkey(viewKey, key))) {
          view.handleMessagesForgotten(absentInViews);
        }
      }
    }
    return forgottenIds;
  }

  Future<void> _scheduleFetchWritePipeline({
    required MessageDbWriter writer,
    required int accountId,
    required int writeEpoch,
    required FetchTicket? ticket,
    required List<int> unfilteredIds,
    required List<({Message message, Map<String, dynamic>? rawMap})> toUpsert,
    required List<({Message message, Map<String, dynamic>? rawMap})> toTouchOnly,
    required _RecordedCoveragePlan? coveragePlan,
  }) {
    final pipelineTicket = _raceBuffer.openTicket(epoch: writeEpoch);
    final prePipelineSeq = pipelineTicket.mark;
    final prePipelineMediaEffects = ticket != null
      ? [
          for (final e in _raceBuffer.effectsInRange(ticket.mark, prePipelineSeq))
            if (e is ReactionEffect || e is SubmessageEffect) e,
        ]
      : const <MessageEffect>[];
    final touchedAfterTicketMark = ticket != null
      ? _raceBuffer.arrivedOrMovedIdsAfter(ticket.mark)
      : const <int>{};
    final resultIdSet = unfilteredIds.toSet();

    final dirtyChannels = <int, bool>{};
    void captureChannelFlag(Message m) {
      if (m is StreamMessage) {
        final channel = streams[m.streamId];
        if (channel != null) {
          _channelHistoryPublic[m.streamId] = channel.historyPublicToSubscribers;
          dirtyChannels[m.streamId] = channel.historyPublicToSubscribers;
          _channelsWithData.add(m.streamId);
        }
      }
    }
    for (final item in toUpsert) {
      captureChannelFlag(item.message);
    }
    for (final item in toTouchOnly) {
      captureChannelFlag(item.message);
    }

    bool isTrackedForDb(Message m) =>
      m is! StreamMessage || subscriptions[m.streamId] != null;

    bool isOverflowed() =>
      pipelineTicket.overflowed || (ticket != null && ticket.overflowed);

    return writer.runTrackedPipeline(() async {
      try {
        if (_disposed || !dbActive || _coverage.epoch != writeEpoch || isOverflowed()) return;

        final dbForgottenIds = <int>[];
        if (coveragePlan != null && coveragePlan.intervals.isNotEmpty) {
          final (channelId, topicKey, dmKey) = scopeFiltersForNarrow(coveragePlan.narrow);
          final readTicket = _raceBuffer.openDbReadTicket(epoch: writeEpoch);
          List<StoredCoverageRow>? candidates;
          try {
            candidates = await writer.runRead((db) => db.queryStoredInCoverageScope(
              accountId,
              channelId: channelId,
              topicKey: topicKey,
              dmKey: dmKey,
              intervals: coveragePlan.intervals,
            ));
          } finally {
            readTicket.close();
          }
          if (_disposed || !dbActive || _coverage.epoch != writeEpoch || isOverflowed()) return;

          if (candidates != null && candidates.isNotEmpty && !readTicket.overflowed) {
            final touchedSinceDbRead = _raceBuffer.arrivedOrMovedIdsAfter(readTicket.mark);
            final ramForgottenSet = coveragePlan.ramForgottenIds.toSet();
            final forgottenEntries = <({int id, List<String> keys})>[];
            for (final row in candidates) {
              if (resultIdSet.contains(row.id)) continue;
              if (ramForgottenSet.contains(row.id)) continue;
              if (touchedAfterTicketMark.contains(row.id)) continue;
              if (touchedSinceDbRead.contains(row.id)) continue;
              if (_raceBuffer.wasRemovedOrPurgedAfter(
                  pipelineTicket.mark, row.id, channelId: row.channelId)) {
                continue;
              }
              final List<String> keys;
              if (row.channelId != null) {
                keys = [
                  CoverageKeys.channel(row.channelId!),
                  if (row.topicKey != null) 'topic:${row.channelId!}:${row.topicKey!}',
                ];
              } else {
                keys = [
                  CoverageKeys.dms,
                  if (row.dmKey != null) 'dm:${row.dmKey!}',
                ];
              }
              dbForgottenIds.add(row.id);
              forgottenEntries.add((id: row.id, keys: keys));
            }
            if (dbForgottenIds.isNotEmpty) {
              _raceBuffer.record(ForgetEffect(messageIds: dbForgottenIds));
              for (final entry in forgottenEntries) {
                _maybeStaleMessages.add(entry.id);
                _locationUnknown.add(entry.id);
                _coverage.forget(coveragePlan.key, entry.keys, entry.id);
              }
              for (final view in _messageListViews) {
                final viewKey = coverageKey(view.narrow);
                if (viewKey != null
                    && (viewKey == coveragePlan.key
                        || CoverageKeys.isSubkey(viewKey, coveragePlan.key))) {
                  view.handleMessagesForgotten(dbForgottenIds);
                }
              }
            }
          }
        }

        final encodedItems = <({
          int id,
          int? channelId,
          int encodeSeq,
          StoredMessageRecord record,
        })>[];
        var encodedCount = 0;
        for (final item in toUpsert) {
          if (encodedCount > 0 && encodedCount % _encodeYieldBatchSize == 0) {
            await Future<void>.delayed(Duration.zero);
            if (_disposed || !dbActive || _coverage.epoch != writeEpoch || isOverflowed()) return;
          }
          final msg = messages[item.message.id] ?? item.message;
          final int? channelId = msg is StreamMessage ? msg.streamId : null;
          if (msg.id < _coverage.evictedBelow) continue;
          if (_raceBuffer.wasRemovedOrPurgedAfter(
              pipelineTicket.mark, msg.id, channelId: channelId)) {
            continue;
          }
          final encodeSeq = _raceBuffer.seq;
          final record = StoredMessageCodec.encode(
            accountId: accountId,
            message: msg,
            rawMap: rawMapOfMessage(msg, item.rawMap),
            epoch: writeEpoch,
            tracked: isTrackedForDb(msg),
            rawFlagsOverride: effectiveRawFlags(msg, item.rawMap),
          );
          encodedItems.add((
            id: msg.id,
            channelId: channelId,
            encodeSeq: encodeSeq,
            record: record,
          ));
          encodedCount++;
        }

        if (_disposed || !dbActive || _coverage.epoch != writeEpoch || isOverflowed()) return;

        final trackedById = <int, bool>{};
        final touchIds = <int>[];
        final touchFallbackById = <int, ({Message message, Map<String, dynamic>? rawMap, int seq})>{};
        for (final item in toTouchOnly) {
          final msg = messages[item.message.id] ?? item.message;
          final int? channelId = msg is StreamMessage ? msg.streamId : null;
          if (msg.id < _coverage.evictedBelow) continue;
          if (_raceBuffer.wasRemovedOrPurgedAfter(
              pipelineTicket.mark, msg.id, channelId: channelId)) {
            continue;
          }
          touchIds.add(msg.id);
          trackedById[msg.id] = isTrackedForDb(msg);
          touchFallbackById[msg.id] = (
            message: msg,
            rawMap: item.rawMap,
            seq: _raceBuffer.seq,
          );
        }

        final allDeletedIds = <int>[
          ...?coveragePlan?.ramForgottenIds,
          ...dbForgottenIds,
        ];
        final enqueueSeq = _raceBuffer.seq;
        final dirtyCoverage = _coverage.takeDirtyIntervals();

        if (encodedItems.isEmpty
            && touchIds.isEmpty
            && allDeletedIds.isEmpty
            && dirtyCoverage.isEmpty
            && dirtyChannels.isEmpty) {
          return;
        }

        final totalBodyBytes = await writer.enqueueWrite<int>((db, {required removalOnly}) async {
          if (removalOnly || _disposed || isOverflowed()) return 0;
          return db.transaction(() async {
            if (_disposed || isOverflowed()) return 0;
            final current = await db.loadAccountEpochAndWatermarkInTxn(accountId);
            if (current == null || current.epoch != writeEpoch) return 0;

            Future<void> replayCatchup(int messageId, int? channelId, int encodeSeq) async {
              for (final effect in prePipelineMediaEffects) {
                if (effectTargetsMessage(effect, messageId, channelId)) {
                  await applyMessageEffectToDb(
                    db,
                    accountId: accountId,
                    effect: effect,
                    epoch: writeEpoch,
                  );
                }
              }
              if (encodeSeq > prePipelineSeq) {
                for (final effect in _raceBuffer.effectsInRange(prePipelineSeq, encodeSeq)) {
                  if ((effect is ReactionEffect || effect is SubmessageEffect)
                      && effectTargetsMessage(effect, messageId, channelId)) {
                    await applyMessageEffectToDb(
                      db,
                      accountId: accountId,
                      effect: effect,
                      epoch: writeEpoch,
                    );
                  }
                }
              }
              for (final effect in _raceBuffer.effectsInRange(encodeSeq, enqueueSeq)) {
                if (effectTargetsMessage(effect, messageId, channelId)) {
                  await applyMessageEffectToDb(
                    db,
                    accountId: accountId,
                    effect: effect,
                    epoch: writeEpoch,
                  );
                }
              }
            }

            for (final item in encodedItems) {
              if (item.id < _coverage.evictedBelow) continue;
              if (_raceBuffer.wasRemovedOrPurgedAfter(
                  item.encodeSeq, item.id, channelId: item.channelId)) {
                continue;
              }
              await upsertStoredMessageRecordInDb(
                db,
                accountId: accountId,
                record: item.record,
              );
              await replayCatchup(item.id, item.channelId, item.encodeSeq);
            }

            if (touchIds.isNotEmpty) {
              final missing = await db.touchUnchangedStoredMessagesInTxn(
                accountId,
                touchIds,
                epoch: writeEpoch,
                trackedById: trackedById,
              );
              for (final missingId in missing) {
                final fb = touchFallbackById[missingId];
                if (fb == null) continue;
                final int? channelId = fb.message is StreamMessage
                  ? (fb.message as StreamMessage).streamId
                  : null;
                if (missingId < _coverage.evictedBelow) continue;
                if (_raceBuffer.wasRemovedOrPurgedAfter(
                    fb.seq, missingId, channelId: channelId)) {
                  continue;
                }
                final record = StoredMessageCodec.encode(
                  accountId: accountId,
                  message: fb.message,
                  rawMap: rawMapOfMessage(fb.message, fb.rawMap),
                  epoch: writeEpoch,
                  tracked: trackedById[missingId] ?? true,
                  rawFlagsOverride: effectiveRawFlags(fb.message, fb.rawMap),
                );
                await upsertStoredMessageRecordInDb(
                  db,
                  accountId: accountId,
                  record: record,
                );
                await replayCatchup(missingId, channelId, fb.seq);
              }
            }

            if (allDeletedIds.isNotEmpty) {
              await deleteMessagesFromDb(db, accountId: accountId, messageIds: allDeletedIds);
            }

            if (dirtyChannels.isNotEmpty) {
              await db.upsertChannelsInTxn(accountId, dirtyChannels);
            }

            if (dirtyCoverage.isNotEmpty) {
              await db.replaceCoverageKeysInTxn(accountId, dirtyCoverage);
            }
            return db.readTotalBodyBytesInTxn(accountId);
          });
        });
        if (totalBodyBytes != null && !_disposed && dbActive && _coverage.epoch == writeEpoch) {
          _maybeScheduleEviction(totalBodyBytes);
        }
      } finally {
        pipelineTicket.close();
      }
    });
  }

  static List<String> _keysOfMessage(Message message) {
    return switch (message) {
      StreamMessage(:final streamId, :final topic) =>
        CoverageKeys.ofLocation(channelId: streamId, topic: topic.apiName),
      DmMessage(:final allRecipientIds) =>
        CoverageKeys.ofLocation(dmKey: CoverageKeys.dm(allRecipientIds)),
    };
  }

  static bool _messageMatchesCoverageNarrow(Message message, Narrow narrow) {
    return switch (narrow) {
      ChannelNarrow(:final channelId) =>
        message is StreamMessage && message.streamId == channelId,
      TopicNarrow(:final channelId, :final topic) =>
        message is StreamMessage
        && message.streamId == channelId
        && serverTopicFold(message.topic.apiName) == serverTopicFold(topic.apiName),
      DmNarrow(:final allRecipientIds) =>
        message is DmMessage
        && listEquals(message.allRecipientIds, allRecipientIds),
      _ => false,
    };
  }

  Message _reconcileUnrecognizedMessage(Message incoming) {
    if (
      incoming is StreamMessage
      && subscriptions[incoming.streamId] == null
    ) {
      // The message is in an unsubscribed channel. It might grow stale;
      // add it to _maybeStaleMessages.
      _maybeStaleMessages.add(incoming.id);
    }
    return _stripMatchFields(incoming);
  }

  Message _reconcileRecognizedMessage(
    Message current,
    Message incomingWithPostMarkEffects, {
    required FetchTicket? ticket,
  }) {
    final currentIsMaybeStale = _maybeStaleMessages.contains(current.id);
    final wasForgotten = _locationUnknown.remove(incomingWithPostMarkEffects.id);
    final bool ticketOverflowed = ticket != null && ticket.overflowed;

    final Message chosen;
    if (currentIsMaybeStale || wasForgotten || !confirmed || ticketOverflowed) {
      chosen = incomingWithPostMarkEffects;
    } else {
      chosen = current;
    }

    final bool shouldBeStale = ticketOverflowed
      || (chosen is StreamMessage
          && (subscriptions[chosen.streamId] == null
              || (ticket != null
                  && _raceBuffer.wasChannelUntrackedAfter(ticket.mark, chosen.streamId))));
    if (shouldBeStale) {
      _maybeStaleMessages.add(chosen.id);
    } else {
      _maybeStaleMessages.remove(chosen.id);
    }
    return chosen;
  }

  /// Messages in [messages] whose data might be stale (for example, because
  /// they are or were in an unsubscribed channel, or were loaded from stale
  /// coverage).
  ///
  /// If any of these maybe-stale messages appear in a fetch, we'll clobber
  /// our stored version with the fetched version. See [reconcileMessages].
  final Set<int> _maybeStaleMessages = {};

  /// Messages in [messages] whose location (channel/topic) is unknown because
  /// an authoritative fetch omitted them from its range (they were "forgotten").
  ///
  /// Excluded from local reads and location-sensitive actions until a fetch
  /// returns them again.
  final Set<int> _locationUnknown = {};

  /// Whether the store's event queue is confirmed (built from a fresh register,
  /// or a resumed queue after its first successful poll).
  bool _confirmed = true;
  bool get confirmed => _confirmed;

  void setConfirmed(bool value) {
    final changed = _confirmed != value;
    _confirmed = value;
    if (value) {
      _coverage.confirm();
      final now = _nowSeconds();
      _lastLiveAt = now;
      if (dbActive) {
        final writer = _dbWriter!;
        final accountId = _dbAccountId!;
        final epoch = _coverage.epoch;
        final dirtyCoverage = _coverage.takeDirtyIntervals();
        unawaited(writer.enqueueWrite<void>((db, {required removalOnly}) async {
          if (removalOnly || _disposed) return;
          await db.transaction(() async {
            final current = await db.loadAccountEpochAndWatermarkInTxn(accountId);
            if (current == null || current.epoch != epoch) return;
            await db.updateLastLiveAtInTxn(accountId, now);
            if (dirtyCoverage.isNotEmpty) {
              await db.replaceCoverageKeysInTxn(accountId, dirtyCoverage);
            }
          });
        }).catchError((_) {}));
      }
      _maybeRunDailyRetentionSweep();
    } else {
      _coverage.markUnconfirmed();
    }
    if (changed) {
      for (final view in _messageListViews) {
        view.handleStoreConfirmedChanged();
      }
    }
  }

  @override
  bool isMessageMaybeStale(int messageId) =>
    _maybeStaleMessages.contains(messageId);

  /// Whether [messageId] is in memory with a reliable location for
  /// location-sensitive actions and local `with` redirects.
  bool isLocationReliable(int messageId) =>
    _confirmed
    && messages.containsKey(messageId)
    && !_maybeStaleMessages.contains(messageId)
    && !_locationUnknown.contains(messageId);

  /// Choose a local window from in-memory messages and coverage.
  ///
  /// Returns null when coverage is disabled, [narrow] has no coverage key,
  /// no covered chain covers [anchor], or an empty non-oldest chain would be
  /// shown before a failure.
  bool _hasNarrowChannelAccessOrPurge(Narrow narrow) {
    final int? channelId = switch (narrow) {
      ChannelNarrow(:final channelId) || TopicNarrow(:final channelId) => channelId,
      _ => null,
    };
    if (channelId == null) return true;
    final channel = streams[channelId];
    if (channel != null && selfHasContentAccess(channel)) return true;
    final hasAnyState = _channelsWithData.contains(channelId)
      || _coverage.keys.any((k) => CoverageKeys.channelIdOf(k) == channelId)
      || messages.values.any((m) => m is StreamMessage && m.streamId == channelId);
    if (hasAnyState) {
      _purgeChannelAndPersistIfNeeded(channelId);
    }
    return false;
  }

  void _purgeChannelAndPersistIfNeeded(int channelId) {
    _purgeChannel(channelId);
    if (_pendingBatch != null) return;
    final writer = _dbWriter;
    final accountId = _dbAccountId;
    if (writer == null || accountId == null || (!_dbActive && !writer.isPoisoned)) {
      return;
    }
    final epoch = _coverage.epoch;
    final dirtyCoverage = _coverage.takeDirtyIntervals();
    unawaited(writer.enqueueWrite<void>((db, {required removalOnly}) async {
      if (_disposed) return;
      await db.transaction(() async {
        final current = await db.loadAccountEpochAndWatermarkInTxn(accountId);
        if (current == null || current.epoch != epoch) return;
        await db.purgeChannelsInTxn(accountId, [channelId]);
        if (!removalOnly && dirtyCoverage.isNotEmpty) {
          await db.replaceCoverageKeysInTxn(accountId, dirtyCoverage);
        }
      });
    }));
  }

  LocalWindow? localWindow(
    Narrow narrow,
    Anchor anchor,
    int before,
    int after, {
    required bool afterFailure,
    int? firstUnreadId,
    bool oldUnreadsMissing = false,
    int? dmLatestKnownId,
  }) {
    if (!coverageEnabled) return null;
    _ensureCoverageBegun();

    Narrow effectiveNarrow = narrow;
    if (narrow case TopicNarrow(:final with_?) when with_ > 0) {
      final target = messages[with_];
      if (target != null && isLocationReliable(with_) && target is StreamMessage) {
        effectiveNarrow = TopicNarrow.ofMessage(target);
      } else {
        effectiveNarrow = narrow.sansWith();
      }
    }

    if (!_hasNarrowChannelAccessOrPurge(effectiveNarrow)) return null;

    final key = coverageKey(effectiveNarrow);
    if (key == null) return null;

    final chains = _coverage.chains(key, dmLatestKnownId: dmLatestKnownId);
    if (chains.isEmpty) return null;

    // Collect all in-memory members of effectiveNarrow (excluding locationUnknown),
    // sorted ascending by id.
    final members = <Message>[
      for (final m in messages.values)
        if (!_locationUnknown.contains(m.id)
            && _messageMatchesCoverageNarrow(m, effectiveNarrow))
          m,
    ]..sort((a, b) => a.id.compareTo(b.id));

    bool hasMemberInChain(CoverageChain chain) {
      return members.any((m) => chain.contains(m.id));
    }

    CoverageChain? pickNewestChain() {
      final last = chains.last;
      if (last.isOpen
          && last.pieces.last.status != CoverageStatus.stale
          && (last.reachesOldest || hasMemberInChain(last))) {
        return last;
      }
      for (int i = chains.length - 1; i >= 0; i--) {
        if (hasMemberInChain(chains[i])) return chains[i];
      }
      if (afterFailure
          && last.reachesOldest
          && last.pieces.last.status != CoverageStatus.stale) {
        return last;
      }
      return null;
    }

    CoverageChain? chainContaining(int id) {
      for (final c in chains) {
        if (c.contains(id)) return c;
      }
      return null;
    }

    final CoverageChain? chain;
    final int targetAnchorId;
    switch (anchor) {
      case AnchorCode.newest:
        chain = pickNewestChain();
        targetAnchorId = kNewestMessageId;
      case AnchorCode.oldest:
        chain = chains.where((c) => c.reachesOldest).firstOrNull;
        targetAnchorId = 0;
      case AnchorCode.firstUnread:
        if (oldUnreadsMissing) return null;
        if (firstUnreadId == null) {
          chain = pickNewestChain();
          targetAnchorId = kNewestMessageId;
        } else {
          chain = chainContaining(firstUnreadId);
          targetAnchorId = firstUnreadId;
        }
      case NumericAnchor(:final messageId):
        chain = chainContaining(messageId);
        targetAnchorId = messageId;
    }
    if (chain == null) return null;

    final inChain = [
      for (final m in members)
        if (chain.contains(m.id)) m,
    ];
    return _buildLocalWindow(
      effectiveNarrow: effectiveNarrow,
      chain: chain,
      inChainMembers: inChain,
      targetAnchorId: targetAnchorId,
      before: before,
      after: after,
      afterFailure: afterFailure,
    );
  }

  /// Whether [narrow] has a live [CoverageChain] covering [anchorId] all the
  /// way to the requested edge ([older] ? oldest : open newest), so pagination
  /// from DB/RAM can be served without a network fetch.
  bool hasLiveLocalPaginationCoverage(
    Narrow narrow, {
    required int anchorId,
    required bool older,
    int? dmLatestKnownId,
  }) {
    if (!coverageEnabled) return false;
    final effectiveNarrow = narrow is TopicNarrow ? narrow.sansWith() : narrow;
    if (!_hasNarrowChannelAccessOrPurge(effectiveNarrow)) return false;
    final key = coverageKey(effectiveNarrow);
    if (key == null) return false;
    final chains = _coverage.chains(key, dmLatestKnownId: dmLatestKnownId);
    for (final c in chains) {
      if (c.contains(anchorId) && c.status == CoverageStatus.live) {
        return older ? c.reachesOldest : c.isOpen;
      }
    }
    return false;
  }

  /// Choose a local window, reading persisted rows from SQLite when the DB is
  /// active and applying the read race rule and fresh-snapshot flag overlays.
  Future<LocalWindow?> localWindowAsync(
    Narrow narrow,
    Anchor anchor,
    int before,
    int after, {
    required bool afterFailure,
    int? firstUnreadId,
    bool oldUnreadsMissing = false,
    bool? Function(int messageId)? isUnreadFromStore,
    int? dmLatestKnownId,
  }) async {
    if (!coverageEnabled) return null;
    if (!dbActive) {
      return localWindow(
        narrow,
        anchor,
        before,
        after,
        afterFailure: afterFailure,
        firstUnreadId: firstUnreadId,
        oldUnreadsMissing: oldUnreadsMissing,
        dmLatestKnownId: dmLatestKnownId,
      );
    }
    _ensureCoverageBegun();

    final writer = _dbWriter!;
    final accountId = _dbAccountId!;

    Narrow effectiveNarrow = narrow;
    if (narrow case TopicNarrow(:final with_?) when with_ > 0) {
      final memTarget = messages[with_];
      if (memTarget != null) {
        if (isLocationReliable(with_) && memTarget is StreamMessage) {
          effectiveNarrow = TopicNarrow.ofMessage(memTarget);
        } else {
          effectiveNarrow = narrow.sansWith();
        }
      } else if (_confirmed && !_locationUnknown.contains(with_) && with_ >= _coverage.evictedBelow) {
        final targetTicket = _raceBuffer.openDbReadTicket(epoch: _coverage.epoch);
        List<LoadedStoredMessage>? rows;
        try {
          rows = await writer.runRead((db) => db.loadFullMessagesByIds(accountId, [with_]));
        } finally {
          targetTicket.close();
        }
        if (_disposed || !dbActive) return null;
        if (rows != null && rows.isNotEmpty && !targetTicket.overflowed) {
          _maybeInsertLoadedRow(
            rows.single,
            readMark: targetTicket.mark,
            readEpoch: targetTicket.epoch,
            isUnreadFromStore: isUnreadFromStore,
            requireNarrowMatch: null,
          );
        }
        final loadedTarget = messages[with_];
        if (loadedTarget != null && isLocationReliable(with_) && loadedTarget is StreamMessage) {
          effectiveNarrow = TopicNarrow.ofMessage(loadedTarget);
        } else {
          effectiveNarrow = narrow.sansWith();
        }
      } else {
        effectiveNarrow = narrow.sansWith();
      }
    }

    if (!_hasNarrowChannelAccessOrPurge(effectiveNarrow)) return null;

    final key = coverageKey(effectiveNarrow);
    if (key == null) return null;

    final (channelId, topicKey, dmKey) = scopeFiltersForNarrow(effectiveNarrow);

    List<Message> ramMembersOf(Narrow n) => [
      for (final m in messages.values)
        if (!_locationUnknown.contains(m.id) && _messageMatchesCoverageNarrow(m, n))
          m,
    ]..sort((a, b) => a.id.compareTo(b.id));

    Future<CoverageChain?> resolveNewestChain(List<CoverageChain> chains, List<Message> ramMembers) async {
      final last = chains.last;
      if (last.isOpen && last.pieces.last.status != CoverageStatus.stale) {
        if (last.reachesOldest || ramMembers.any((m) => last.contains(m.id))) {
          return last;
        }
        final hasDb = await writer.runRead((db) => db.hasAnyStoredInChain(
          accountId,
          channelId: channelId,
          topicKey: topicKey,
          dmKey: dmKey,
          chain: last,
        ));
        if (_disposed || !dbActive) return null;
        if (hasDb == null) return null;
        if (hasDb) return last;
      }

      int? maxRamId;
      for (int i = ramMembers.length - 1; i >= 0; i--) {
        final id = ramMembers[i].id;
        if (chains.any((c) => c.contains(id))) {
          maxRamId = id;
          break;
        }
      }
      final maxDbMark = _raceBuffer.dbCommittedSeq;
      final maxDbId = await writer.runRead((db) => db.greatestStoredIdInChains(
        accountId,
        channelId: channelId,
        topicKey: topicKey,
        dmKey: dmKey,
        chains: chains,
      ));
      if (_disposed || !dbActive) return null;
      int? bestId = maxRamId;
      if (maxDbId != null
          && !_locationUnknown.contains(maxDbId)
          && (bestId == null || maxDbId > bestId)) {
        final deletedInMem = _raceBuffer.wasRemovedOrPurgedAfter(
          maxDbMark, maxDbId, channelId: channelId);
        if (!deletedInMem) bestId = maxDbId;
      }
      if (bestId != null) {
        for (int i = chains.length - 1; i >= 0; i--) {
          if (chains[i].contains(bestId)) return chains[i];
        }
      }
      if (afterFailure
          && last.reachesOldest
          && last.pieces.last.status != CoverageStatus.stale) {
        return last;
      }
      return null;
    }

    for (int attempt = 0; attempt < 3; attempt++) {
      if (_disposed || !dbActive || !coverageEnabled) return null;
      final chains = _coverage.chains(key, dmLatestKnownId: dmLatestKnownId);
      if (chains.isEmpty) return null;

      final ramBeforeRead = ramMembersOf(effectiveNarrow);
      CoverageChain? candidateChain;
      late final int targetAnchorId;
      switch (anchor) {
        case AnchorCode.newest:
          candidateChain = await resolveNewestChain(chains, ramBeforeRead);
          targetAnchorId = kNewestMessageId;
        case AnchorCode.oldest:
          candidateChain = chains.where((c) => c.reachesOldest).firstOrNull;
          targetAnchorId = 0;
        case AnchorCode.firstUnread:
          if (oldUnreadsMissing) return null;
          if (firstUnreadId == null) {
            candidateChain = await resolveNewestChain(chains, ramBeforeRead);
            targetAnchorId = kNewestMessageId;
          } else {
            candidateChain = chains.where((c) => c.contains(firstUnreadId)).firstOrNull;
            targetAnchorId = firstUnreadId;
          }
        case NumericAnchor(:final messageId):
          candidateChain = chains.where((c) => c.contains(messageId)).firstOrNull;
          targetAnchorId = messageId;
      }
      if (_disposed || !dbActive) return null;
      if (candidateChain == null) return null;

      final readEpoch = _coverage.epoch;
      final readTicket = _raceBuffer.openDbReadTicket(epoch: readEpoch);
      final preReadSeq = _raceBuffer.seq;
      final movedInIds = <int>[
        for (final move in _raceBuffer.moveEffectsAfter(readTicket.mark))
          if (_moveDestinationMatchesNarrow(move, effectiveNarrow))
            ...move.messageIds,
      ];
      final movedInSet = movedInIds.toSet();
      StoredWindowQueryResult? queryResult;
      try {
        queryResult = await writer.runRead((db) => db.queryWindowRows(
          accountId,
          channelId: channelId,
          topicKey: topicKey,
          dmKey: dmKey,
          chain: candidateChain!,
          anchorId: targetAnchorId,
          before: before,
          after: after,
          extraIds: movedInIds,
        ));
      } finally {
        readTicket.close();
      }
      if (_disposed || !dbActive) return null;
      if (!_hasNarrowChannelAccessOrPurge(effectiveNarrow)) return null;
      if (readTicket.overflowed || _coverage.epoch != readEpoch) {
        // Yield once so a pending commit can advance dbCommittedSeq, or pick up
        // the bumped epoch on retry.
        await Future<void>.delayed(Duration.zero);
        continue;
      }
      final hasConcurrentMovedIn = _raceBuffer.moveEffectsAfter(preReadSeq).any((move) =>
        _moveDestinationMatchesNarrow(move, effectiveNarrow)
        && move.messageIds.any((id) => !movedInSet.contains(id)));
      if (hasConcurrentMovedIn) {
        continue;
      }
      if (queryResult == null) return null;

      final dbSurviving = <Message>[];
      for (final item in queryResult.records) {
        final msg = _maybeInsertLoadedRow(
          item,
          readMark: readTicket.mark,
          readEpoch: readEpoch,
          isUnreadFromStore: isUnreadFromStore,
          requireNarrowMatch: effectiveNarrow,
        );
        if (msg != null) {
          dbSurviving.add(msg);
        }
      }

      // Union with all in-memory members of effectiveNarrow (memory wins / covers
      // uncommitted events) and post-await re-clip to coverage as it is *now*.
      final currentChains = _coverage.chains(key, dmLatestKnownId: dmLatestKnownId);
      if (currentChains.isEmpty) return null;

      final byId = <int, Message>{
        for (final m in dbSurviving) m.id: m,
      };
      for (final m in ramMembersOf(effectiveNarrow)) {
        byId[m.id] = m; // In-memory copy takes precedence.
      }
      final allMembersNow = byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));

      CoverageChain? currentChain;
      if (targetAnchorId == kNewestMessageId) {
        final lastNow = currentChains.last;
        if (lastNow.isOpen
            && lastNow.pieces.last.status != CoverageStatus.stale
            && (lastNow.reachesOldest || allMembersNow.any((m) => lastNow.contains(m.id)))) {
          currentChain = lastNow;
        } else {
          for (int i = currentChains.length - 1; i >= 0; i--) {
            final c = currentChains[i];
            if (allMembersNow.any((m) => c.contains(m.id))) {
              currentChain = c;
              break;
            }
          }
          if (currentChain == null
              && afterFailure
              && lastNow.reachesOldest
              && lastNow.pieces.last.status != CoverageStatus.stale) {
            currentChain = lastNow;
          }
        }
      } else {
        currentChain = currentChains.where((c) => c.contains(targetAnchorId)).firstOrNull;
      }
      if (currentChain == null) return null;

      final inChain = [
        for (final m in allMembersNow)
          if (currentChain.contains(m.id)) m,
      ];
      return _buildLocalWindow(
        effectiveNarrow: effectiveNarrow,
        chain: currentChain,
        inChainMembers: inChain,
        targetAnchorId: targetAnchorId,
        before: before,
        after: after,
        afterFailure: afterFailure,
        sqlHasMoreBefore: queryResult.hasMoreBefore,
        sqlHasMoreAfter: queryResult.hasMoreAfter,
      );
    }
    return null;
  }

  Message? _maybeInsertLoadedRow(
    LoadedStoredMessage item, {
    required int readMark,
    required int readEpoch,
    required bool? Function(int messageId)? isUnreadFromStore,
    required Narrow? requireNarrowMatch,
    bool Function(Message)? additionalFilter,
  }) {
    final existing = messages[item.row.id];
    if (existing != null) {
      if (_locationUnknown.contains(existing.id)) return null;
      if (existing is StreamMessage) {
        final channel = streams[existing.streamId];
        if (channel == null || !selfHasContentAccess(channel)) {
          return null;
        }
      }
      if (requireNarrowMatch != null && !_messageMatchesCoverageNarrow(existing, requireNarrowMatch)) {
        return null;
      }
      if (additionalFilter != null && !additionalFilter(existing)) {
        return null;
      }
      return existing;
    }

    if (item.row.id < _coverage.evictedBelow) return null;
    if (_raceBuffer.wasRemovedOrPurgedAfter(
        readMark, item.row.id, channelId: item.row.channelId)) {
      return null;
    }

    final bool? readOverride;
    if (item.row.channelId != null && subscriptions[item.row.channelId!] == null) {
      readOverride = true;
    } else if (isUnreadFromStore != null) {
      final isUnread = isUnreadFromStore(item.row.id);
      readOverride = isUnread == null ? null : !isUnread;
    } else {
      readOverride = null;
    }

    final bool? starredOverride =
      (_initialStarredMessagesAtCap
          && _initialStarredMaxId != null
          && item.row.id > _initialStarredMaxId)
        ? (starredMessages.contains(item.row.id) ? true : null)
        : starredMessages.contains(item.row.id);

    final decoded = StoredMessageCodec.decode(
      row: item.row,
      body: item.body,
      reactions: item.reactions,
      submessages: item.submessages,
      readOverride: readOverride,
      starredOverride: starredOverride,
    );
    _raceBuffer.applyEffectsAfter(readMark, decoded);

    if (decoded is StreamMessage) {
      if (_raceBuffer.wasRemovedOrPurgedAfter(
            readMark, decoded.id, channelId: decoded.streamId)) {
        return null;
      }
      final channel = streams[decoded.streamId];
      if (channel == null || !selfHasContentAccess(channel)) {
        return null;
      }
    }
    if (requireNarrowMatch != null && !_messageMatchesCoverageNarrow(decoded, requireNarrowMatch)) {
      return null;
    }
    if (additionalFilter != null && !additionalFilter(decoded)) {
      return null;
    }

    final bool untrackedInRace = decoded is StreamMessage
      && _raceBuffer.wasChannelUntrackedAfter(readMark, decoded.streamId);
    final bool isLive = item.row.epoch == readEpoch
      && item.row.tracked
      && !untrackedInRace;

    messages[decoded.id] = decoded;
    if (!isLive) {
      _maybeStaleMessages.add(decoded.id);
    }
    return decoded;
  }

  static bool _moveDestinationMatchesNarrow(MoveEffect move, Narrow narrow) {
    return switch (narrow) {
      ChannelNarrow(:final channelId) => move.newChannelId == channelId,
      TopicNarrow(:final channelId, :final topic) =>
        move.newChannelId == channelId
        && serverTopicFold(move.newTopic.apiName) == serverTopicFold(topic.apiName),
      _ => false,
    };
  }

  LocalWindow? _buildLocalWindow({
    required Narrow effectiveNarrow,
    required CoverageChain chain,
    required List<Message> inChainMembers,
    required int targetAnchorId,
    required int before,
    required int after,
    required bool afterFailure,
    bool sqlHasMoreBefore = false,
    bool sqlHasMoreAfter = false,
  }) {
    final below = <Message>[];
    final atOrAbove = <Message>[];
    for (final m in inChainMembers) {
      if (m.id < targetAnchorId) {
        below.add(m);
      } else {
        atOrAbove.add(m);
      }
    }

    final takeBelow = below.length > before
      ? below.sublist(below.length - before)
      : below;
    final takeAbove = atOrAbove.length > after + 1
      ? atOrAbove.sublist(0, after + 1)
      : atOrAbove;
    final windowMessages = [...takeBelow, ...takeAbove];

    if (windowMessages.isEmpty) {
      if (chain.status == CoverageStatus.stale) return null;
      if (!chain.reachesOldest && !afterFailure) return null;
    }

    final haveOldest = !sqlHasMoreBefore
      && below.length <= before
      && chain.reachesOldest;
    final atKnownNewest = !sqlHasMoreAfter && atOrAbove.length <= after + 1;
    final haveNewest = atKnownNewest
      && chain.isOpen
      && chain.pieces.last.status != CoverageStatus.stale;
    final resolvedAnchorId = targetAnchorId == kNewestMessageId
      ? (windowMessages.lastOrNull?.id ?? 0)
      : targetAnchorId;

    return LocalWindow(
      messages: windowMessages,
      anchorId: resolvedAnchorId,
      haveOldest: haveOldest,
      haveNewest: haveNewest,
      atKnownNewest: atKnownNewest,
      narrow: effectiveNarrow,
      chain: chain,
    );
  }

  Set<int> get debugMaybeStaleMessages => _maybeStaleMessages;

  Set<int> get debugLocationUnknown => _locationUnknown;

  bool isLocationUnknown(int messageId) => _locationUnknown.contains(messageId);

  Message _stripMatchFields(Message message) {
    message.matchContent = null;
    message.matchTopic = null;
    return message;
  }

  @override
  bool? getEditMessageErrorStatus(int messageId) {
    assert(!_disposed);
    return _editMessageRequests[messageId]?.hasError;
  }

  final Map<int, _EditMessageRequestStatus> _editMessageRequests = {};

  @override
  Future<void> editMessage({
    required int messageId,
    required String originalRawContent,
    required String newContent,
  }) async {
    assert(!_disposed);
    if (_editMessageRequests.containsKey(messageId)) {
      throw StateError('an edit request is already in progress');
    }

    _editMessageRequests[messageId] = _EditMessageRequestStatus(
      hasError: false, originalRawContent: originalRawContent, newContent: newContent);
    _notifyMessageListViewsForOneMessage(messageId);
    try {
      await updateMessage(connection,
        messageId: messageId,
        content: newContent,
        prevContentSha256: sha256.convert(utf8.encode(originalRawContent)).toString());
      // On success, we'll clear the status from _editMessageRequests
      // when we get the event (or below, if in an unsubscribed channel).
      if (_disposed) return;
    } catch (e) {
      // TODO(log) if e is something unexpected

      if (_disposed) return;

      final status = _editMessageRequests[messageId];
      if (status == null) {
        // The event actually arrived before this request failed
        // (can happen with network issues).
        // Or, the message was deleted.
        return;
      }
      status.hasError = true;
      _notifyMessageListViewsForOneMessage(messageId);
      rethrow;
    }

    final message = messages[messageId];
    if (message is StreamMessage && subscriptions[message.streamId] == null) {
      // The message is in an unsubscribed channel.
      // We don't expect an event (see "third buggy behavior" in #1798)
      // but we know the edit request succeeded, so, clear the pending-edit state.
      // We simultaneously reload the affected message lists from scratch, so
      // the user won't see a state where the edit appears to be forgotten.
      // (See _EditMessageBannerTrailing._handleTapSave in
      // lib/widgets/compose_box.dart.)
      _editMessageRequests.remove(messageId);
      _notifyMessageListViewsForOneMessage(messageId);
    }
  }

  @override
  ({String originalRawContent, String newContent}) takeFailedMessageEdit(int messageId) {
    assert(!_disposed);
    final status = _editMessageRequests.remove(messageId);
    _notifyMessageListViewsForOneMessage(messageId);
    if (status == null) {
      throw StateError('called takeFailedMessageEdit, but no edit');
    }
    if (!status.hasError) {
      throw StateError("called takeFailedMessageEdit, but edit hasn't failed");
    }
    return (
      originalRawContent: status.originalRawContent,
      newContent: status.newContent
    );
  }

  void handleChannelDeleteEvent(ChannelDeleteEvent event) {
    if (coverageEnabled) {
      if (_shouldMutateCoverage) {
        _ensureCoverageBegun();
      }
      for (final channelId in event.channelIds) {
        _purgeChannel(channelId);
      }
      return;
    }
    _handleSubscriptionsRemoved(event.channelIds);
  }

  void handleChannelCreateEvent(ChannelCreateEvent event) {
    if (!coverageEnabled) return;
    for (final channel in event.streams) {
      _channelHistoryPublic[channel.streamId] = channel.historyPublicToSubscribers;
      if (!_suppressCurrentEventDb) {
        _pendingBatch?.dirtyChannelFlags[channel.streamId] = channel.historyPublicToSubscribers;
      }
    }
  }

  /// Re-check content access and history regime for [candidateChannelIds]
  /// (or all channels with stored messages or coverage if null) after an event
  /// that may have changed channel, group, or role state.
  void handleChannelAccessMaybeChanged(Iterable<int>? candidateChannelIds) {
    if (!coverageEnabled) return;
    if (_shouldMutateCoverage) {
      _ensureCoverageBegun();
    }

    final candidates = candidateChannelIds ?? <int>{
      for (final message in messages.values)
        if (message is StreamMessage) message.streamId,
      ..._channelsWithData,
      ..._channelHistoryPublic.keys,
      for (final key in _coverage.keys)
        ?CoverageKeys.channelIdOf(key),
    };

    for (final channelId in candidates) {
      _channelGeneration[channelId] = (_channelGeneration[channelId] ?? 0) + 1;
      final channel = streams[channelId];
      if (channel == null || !selfHasContentAccess(channel)) {
        _purgeChannel(channelId);
        continue;
      }
      final prevHistoryPublic = _channelHistoryPublic[channelId];
      final nowHistoryPublic = channel.historyPublicToSubscribers;
      if (prevHistoryPublic != null && prevHistoryPublic != nowHistoryPublic) {
        if (!nowHistoryPublic) {
          _purgeChannel(channelId);
          continue;
        } else if (_shouldMutateCoverage) {
          _coverage.dropChannel(channelId);
        }
      }
      _channelHistoryPublic[channelId] = nowHistoryPublic;
      if (!_suppressCurrentEventDb) {
        _pendingBatch?.dirtyChannelFlags[channelId] = nowHistoryPublic;
      }
    }
  }

  void _purgeChannel(int channelId) {
    _recordEffect(ChannelPurgeEffect(channelId: channelId));
    _channelsWithData.remove(channelId);
    _channelHistoryPublic.remove(channelId);
    if (!_suppressCurrentEventDb) {
      _pendingBatch?.removedChannelIds.add(channelId);
      _pendingBatch?.dirtyChannelFlags.remove(channelId);
    }
    if (_pendingMoveDbLocations.isNotEmpty) {
      _pendingMoveDbLocations.removeWhere((_, loc) => loc.channelId == channelId);
    }
    _channelGeneration[channelId] = (_channelGeneration[channelId] ?? 0) + 1;
    final purgedIds = [
      for (final message in messages.values)
        if (message is StreamMessage && message.streamId == channelId)
          message.id,
    ];
    for (final id in purgedIds) {
      messages.remove(id);
      starredMessages.remove(id);
      _maybeStaleMessages.remove(id);
      _locationUnknown.remove(id);
      _editMessageRequests.remove(id);
    }
    for (final view in _messageListViews) {
      view.handleChannelPurged(channelId);
    }
    if (_shouldMutateCoverage) {
      _ensureCoverageBegun();
      _coverage.dropChannel(channelId);
    }
  }

  void handleSubscriptionRemoveEvent(SubscriptionRemoveEvent event) {
    _handleSubscriptionsRemoved(event.channelIds);
  }

  void _handleSubscriptionsRemoved(Iterable<int> channelIds) {
    for (final channelId in channelIds) {
      _recordEffect(ChannelUntrackEffect(channelId: channelId));
      _channelGeneration[channelId] = (_channelGeneration[channelId] ?? 0) + 1;
    }
    if (_shouldMutateCoverage) {
      _ensureCoverageBegun();
      final now = _nowSeconds();
      for (final channelId in channelIds) {
        _coverage.untrackChannel(channelId, now: now);
      }
    }
    if (channelIds.length > 8) {
      assert(channelIds is! Set);
      // optimization: https://github.com/zulip/zulip-flutter/pull/1912#discussion_r2479350329
      channelIds = Set.from(channelIds);
    }

    // Linear in [messages].
    final affectedKnownMessageIds = messages.values
      .where((message) => message is StreamMessage && channelIds.contains(message.streamId))
      .map((message) => message.id);

    _maybeStaleMessages.addAll(affectedKnownMessageIds);
  }

  void handleSubscriptionUpdateEvent(SubscriptionUpdateEvent event) {
    for (final view in _messageListViews) {
      view.handleSubscriptionUpdateEvent(event);
    }
  }

  /// Update the message lists for [event],
  /// which the channel store has already applied.
  void handleSubscriptionEvent(SubscriptionEvent event) {
    if (event is SubscriptionAddEvent) {
      for (final subscription in event.subscriptions) {
        _channelGeneration[subscription.streamId] =
          (_channelGeneration[subscription.streamId] ?? 0) + 1;
      }
    }
    for (final view in _messageListViews) {
      view.handleSubscriptionEvent(event);
    }
  }

  void handleUserTopicEvent(UserTopicEvent event) {
    for (final view in _messageListViews) {
      view.handleUserTopicEvent(event);
    }
  }

  void handleMutedUsersEvent(MutedUsersEvent event) {
    for (final view in _messageListViews) {
      view.handleMutedUsersEvent(event);
    }
  }

  void handleMessageEvent(
    MessageEvent event, {
    Map<String, Object?>? rawMessageMap,
    List<String>? rawFlags,
  }) {
    final message = event.message;
    final largestKnownIdBefore = _knownMaxMessageId;
    if (message.id > _knownMaxMessageId) {
      _knownMaxMessageId = message.id;
    }
    if (coverageEnabled && message is StreamMessage) {
      final channel = streams[message.streamId];
      if (channel == null || !selfHasContentAccess(channel)) {
        // Self no longer has content access to this channel: advance the event
        // watermark and clear any matching outbox entry, without storing a row
        // or opening a channel coverage interval.
        if (_shouldMutateCoverage) {
          _ensureCoverageBegun();
          _coverage.handleMessageEvent(
            messageId: message.id,
            dmKey: null,
            channelId: message.streamId,
            subscribed: false,
            now: _nowSeconds(),
          );
        }
        final sentOutbox = _handleMessageEventOutbox(event);
        if (sentOutbox != null) {
          for (final view in _messageListViews) {
            view.notifyListenersIfOutboxMessagePresent(sentOutbox.localMessageId);
          }
        }
        return;
      }
    }

    if (message.flags.contains(MessageFlag.starred)) { // TODO(log)
      // It would be surprising if a newly-sent message could be starred.
      // (I notice that the send-message endpoint doesn't offer a way to
      // set the starred flag.)
      // If it turns out to be possible, we should update [starredMessages].
    }

    // If the message is one we already know about (from a fetch),
    // clobber it with the one from the event system.
    // See [reconcileMessages] for reasoning.
    final tracked = message is! StreamMessage || subscriptions[message.streamId] != null;
    final effect = InsertEffect(message: message, tracked: tracked);
    _recordEffect(
      effect,
      rawMessageMap: rawMessageMap,
      rawFlags: rawFlags,
    );
    assert(() {
      // ignore: unnecessary_statements
      effect;
      return true;
    }());
    messages[message.id] = message;

    if (!tracked) {
      // We didn't expect this event, because the channel is unsubscribed. But
      // that doesn't mean we should expect future events about this message.
      _maybeStaleMessages.add(message.id);
    }

    if (message is StreamMessage) {
      _channelsWithData.add(message.streamId);
      final channel = streams[message.streamId];
      if (channel != null) {
        _channelHistoryPublic[message.streamId] = channel.historyPublicToSubscribers;
        if (!_suppressCurrentEventDb) {
          _pendingBatch?.dirtyChannelFlags[message.streamId] = channel.historyPublicToSubscribers;
        }
      }
    }

    if (_shouldMutateCoverage) {
      _ensureCoverageBegun();
      _coverage.handleMessageEvent(
        messageId: message.id,
        dmKey: message is DmMessage ? CoverageKeys.dm(message.allRecipientIds) : null,
        channelId: message is StreamMessage ? message.streamId : null,
        subscribed: tracked,
        now: _nowSeconds(),
        largestKnownIdBefore: largestKnownIdBefore,
      );
    }

    final sentOutboxMessage = _handleMessageEventOutbox(event);

    for (final view in _messageListViews) {
      view.handleMessageEvent(event, sentOutboxMessage: sentOutboxMessage);
    }
  }

  void handleUpdateMessageEvent(UpdateMessageEvent event) {
    assert(event.messageIds.contains(event.messageId), "See https://github.com/zulip/zulip-flutter/pull/753#discussion_r1649463633");
    _handleUpdateMessageEventTimestamp(event);
    _handleUpdateMessageEventContent(event);
    _handleUpdateMessageEventMove(event);
    _notifyMessageListViews(event.messageIds);
  }

  void _handleUpdateMessageEventTimestamp(UpdateMessageEvent event) {
    if (event.renderingOnly) {
      // A rendering-only update gets omitted from the message edit history,
      // and [Message.lastEditTimestamp] is the last timestamp of that history.
      // So on a rendering-only update, the timestamp doesn't get updated.
      return;
    }

    final effect = EditTimeEffect(
      messageIds: event.messageIds,
      editTimestamp: event.editTimestamp,
    );
    _recordEffect(effect);
    for (final messageId in effect.messageIds) {
      final message = messages[messageId];
      if (message == null) continue;
      effect.applyToMessage(message);
    }
  }

  void _handleUpdateMessageEventContent(UpdateMessageEvent event) {
    final effect = ContentEffect(
      messageId: event.messageId,
      flags: event.flags,
      editState: event.origContent != null ? MessageEditState.edited : null,
      renderedContent: event.renderedContent,
      isMeMessage: event.isMeMessage,
    );
    _recordEffect(effect);

    final message = messages[effect.messageId];
    if (message == null) return;

    if (effect.editState != null) {
      // Clear the edit-message progress feedback.
      // This makes a rare bug where we might clear the feedback too early,
      // if the user raced with themself to edit the same message
      // from multiple clients.
      _editMessageRequests.remove(message.id);
    }
    effect.applyToMessage(message);

    for (final view in _messageListViews) {
      view.messageContentChanged(event.messageId);
    }
  }

  void _handleUpdateMessageEventMove(UpdateMessageEvent event) {
    final messageMove = event.moveData;
    if (messageMove == null) {
      // There was no move.
      return;
    }

    final UpdateMessageMoveData(
      :origStreamId, :newStreamId, :origTopic, :newTopic) = messageMove;

    final wasResolveOrUnresolve = newStreamId == origStreamId
      && MessageEditState.topicMoveWasResolveOrUnresolve(origTopic, newTopic);
    final effect = MoveEffect(
      messageIds: event.messageIds,
      origChannelId: origStreamId,
      newChannelId: newStreamId,
      origTopic: origTopic,
      newTopic: newTopic,
      untrack: newStreamId != origStreamId && subscriptions[newStreamId] == null,
      markMoved: !wasResolveOrUnresolve,
      propagateMode: messageMove.propagateMode,
    );
    _recordEffect(effect);

    final List<int> originMismatchForgottenIds = [];
    final origTopicFold = coverageEnabled ? serverTopicFold(origTopic.apiName) : null;
    final newTopicFold = coverageEnabled ? serverTopicFold(newTopic.apiName) : null;
    bool anyMovedStored = false;

    for (final messageId in effect.messageIds) {
      final message = messages[messageId];
      if (message == null) {
        final dbLoc = _pendingMoveDbLocations[messageId];
        if (dbLoc == null) continue;
        if (dbLoc.dmKey != null) {
          assert(debugLog('Bad UpdateMessageEvent: channel/topic move on a DM')); // TODO(log)
          continue;
        }
        if (coverageEnabled
            && (dbLoc.channelId != origStreamId || dbLoc.topicKey != origTopicFold)) {
          // Persisted copy's location disagrees with the move's origin
          // (it missed an intermediate move): forget it and puncture the
          // destination keys instead of relocating.
          originMismatchForgottenIds.add(messageId);
          _pendingMoveDbLocations.remove(messageId);
        } else {
          anyMovedStored = true;
          _pendingMoveDbLocations[messageId] = (
            channelId: newStreamId,
            topicKey: newTopicFold,
            dmKey: null,
          );
        }
        continue;
      }

      if (message is! StreamMessage) {
        assert(debugLog('Bad UpdateMessageEvent: channel/topic move on a DM')); // TODO(log)
        continue;
      }

      if (coverageEnabled
          && (message.streamId != origStreamId
              || serverTopicFold(message.topic.apiName) != origTopicFold)) {
        // Stored copy's location disagrees with the move's origin
        // (it missed an intermediate move): forget it and puncture the
        // destination keys instead of relocating.
        originMismatchForgottenIds.add(messageId);
        messages.remove(messageId);
        starredMessages.remove(messageId);
        _maybeStaleMessages.remove(messageId);
        _locationUnknown.remove(messageId);
        _editMessageRequests.remove(messageId);
        continue;
      }

      anyMovedStored = true;
      if (effect.untrack) {
        // The message was moved into an unsubscribed channel, which means
        // we expect our data on it to get stale.
        _maybeStaleMessages.add(messageId);
      }
      effect.applyToMessage(message);
    }

    if (anyMovedStored) {
      _channelsWithData.add(newStreamId);
      final channel = streams[newStreamId];
      if (channel != null) {
        _channelHistoryPublic[newStreamId] = channel.historyPublicToSubscribers;
        if (!_suppressCurrentEventDb) {
          _pendingBatch?.dirtyChannelFlags[newStreamId] = channel.historyPublicToSubscribers;
        }
      }
    }

    if (originMismatchForgottenIds.isNotEmpty) {
      _recordEffect(ForgetEffect(messageIds: originMismatchForgottenIds));
      for (final view in _messageListViews) {
        view.handleMessagesForgotten(originMismatchForgottenIds);
      }
    }

    if (_shouldMutateCoverage) {
      _ensureCoverageBegun();
      final originMismatchSet = originMismatchForgottenIds.toSet();
      _coverage.handleMove(
        CoverageMove(
          messageIds: effect.messageIds,
          origChannelId: origStreamId,
          origTopic: origTopic.apiName,
          newChannelId: newStreamId,
          newTopic: newTopic.apiName,
        ),
        isStored: (id) =>
          messages.containsKey(id)
          || (_pendingMoveDbLocations.containsKey(id) && !originMismatchSet.contains(id)),
      );
      if (originMismatchForgottenIds.isNotEmpty) {
        _coverage.punctureSpan(CoverageKeys.channel(newStreamId), originMismatchForgottenIds);
        _coverage.punctureSpan(
          CoverageKeys.topic(newStreamId, newTopic.apiName), originMismatchForgottenIds);
      }
    }

    // TODO predict outbox message moves using propagateMode

    for (final view in _messageListViews) {
      view.messagesMoved(messageMove: messageMove, messageIds: event.messageIds);
    }
  }

  /// Handle a [DeleteMessageEvent]
  /// and return true if the [PerAccountStore] should notify listeners.
  bool handleDeleteMessageEvent(DeleteMessageEvent event) {
    _recordEffect(DeleteEffect(messageIds: event.messageIds));
    bool perAccountStoreShouldNotify = false;
    for (final messageId in event.messageIds) {
      messages.remove(messageId);
      if (_pendingMoveDbLocations.isNotEmpty) {
        _pendingMoveDbLocations.remove(messageId);
      }
      perAccountStoreShouldNotify |= starredMessages.remove(messageId);
      _maybeStaleMessages.remove(messageId);
      _locationUnknown.remove(messageId);
      _editMessageRequests.remove(messageId);
    }
    for (final view in _messageListViews) {
      view.handleDeleteMessageEvent(event);
    }
    return perAccountStoreShouldNotify;
  }

  /// Handle an [UpdateMessageFlagsEvent]
  /// and return true if the [PerAccountStore] should notify listeners.
  bool handleUpdateMessageFlagsEvent(UpdateMessageFlagsEvent event) {
    final isAdd = switch (event) {
      UpdateMessageFlagsAddEvent()    => true,
      UpdateMessageFlagsRemoveEvent() => false,
    };

    if (isAdd && (event as UpdateMessageFlagsAddEvent).all) {
      const effect = FlagAllReadEffect();
      _recordEffect(effect);
      for (final message in messages.values) {
        effect.applyToMessage(message);
      }

      for (final view in _messageListViews) {
        if (view.messages.isEmpty) continue;
        view.notifyListeners();
      }
    } else {
      final effect = FlagEffect(
        messageIds: event.messages,
        flag: event.flag,
        add: isAdd,
      );
      _recordEffect(effect);
      bool anyMessageFound = false;
      for (final messageId in effect.messageIds) {
        final message = messages[messageId];
        if (message == null) continue; // a message we don't know about yet
        anyMessageFound = true;
        effect.applyToMessage(message);
      }
      if (anyMessageFound) {
        // TODO(#818): Support MentionsNarrow live-updates when handling
        //   @-mention flags.

        // To make it easier to re-star a message, we opt-out from supporting
        // live-updates when starred flag is removed.
        //
        // TODO: Support StarredMessagesNarrow live-updates when starred flag
        //   is added.
        _notifyMessageListViews(event.messages);
      }
    }

    if (event.flag == MessageFlag.starred) {
      isAdd
        ? starredMessages.addAll(event.messages)
        : starredMessages.removeAll(event.messages);
      return true;
    }

    return false;
  }

  void handleReactionEvent(ReactionEvent event) {
    final effect = ReactionEffect(
      messageId: event.messageId,
      op: event.op,
      emojiName: event.emojiName,
      emojiCode: event.emojiCode,
      reactionType: event.reactionType,
      userId: event.userId,
    );
    _recordEffect(effect);
    final message = messages[effect.messageId];
    if (message == null) return;

    effect.applyToMessage(message);
    _notifyMessageListViewsForOneMessage(event.messageId);
  }

  void handleSubmessageEvent(SubmessageEvent event) {
    final effect = SubmessageEffect(event: event);
    _recordEffect(effect);
    final message = messages[event.messageId];
    if (message == null) return;

    // Live-updates for polls should not rebuild the message lists.
    // [Poll] is responsible for notifying the affected listeners.
    effect.applyToMessage(message);
  }

  /// In debug mode, controls whether outbox messages should be created when
  /// [sendMessage] is called.
  ///
  /// Outside of debug mode, this is always true and the setter has no effect.
  static bool get debugOutboxEnable {
    bool result = true;
    assert(() {
      result = _debugOutboxEnable;
      return true;
    }());
    return result;
  }
  static bool _debugOutboxEnable = true;
  static set debugOutboxEnable(bool value) {
    assert(() {
      _debugOutboxEnable = value;
      return true;
    }());
  }

  @visibleForTesting
  static void debugReset() {
    _debugOutboxEnable = true;
  }
}

enum _MarkReadSendOutcome {
  sent,
  dropBatch,
  retryableFailure,
}

class _MarkReadOnScrollQueue {
  _MarkReadOnScrollQueue();

  bool get isNotEmpty => _queue.isNotEmpty;

  final _set = <int>{};
  final _queue = QueueList<int>();

  /// Add [messageIds] to the end of the queue,
  /// if they aren't already in the queue.
  void addAll(Iterable<int> messageIds) {
    for (final messageId in messageIds) {
      if (_set.add(messageId)) {
        _queue.add(messageId);
      }
    }
  }

  Iterable<int> get iterable => _queue;

  List<int> removeFirstN(int n) {
    final removed = <int>[];
    for (int i = 0; i < n; i++) {
      if (_queue.isEmpty) break;
      final id = _queue.removeFirst();
      _set.remove(id);
      removed.add(id);
    }
    return removed;
  }

  void clear() {
    _set.clear();
    _queue.clear();
  }
}

/// The duration an outbox message stays hidden to the user.
///
/// See [OutboxMessageState.waiting].
const kLocalEchoDebounceDuration = Duration(milliseconds: 500);  // TODO(#1441) find the right value for this

/// The duration before an outbox message can be restored for resending, since
/// its creation.
///
/// See [OutboxMessageState.waitPeriodExpired].
const kSendMessageOfferRestoreWaitPeriod = Duration(seconds: 10);  // TODO(#1441) find the right value for this

/// States of an [OutboxMessage] since its creation from a
/// [MessageStore.sendMessage] call and before its eventual deletion.
///
/// ```
///                             Got an [ApiRequestException].
///          ┌──────┬────────────────────────────┬──────────► failed
///          │      │                            │              │
///          │      │      [sendMessage]         │              │
/// (create) │      │      request succeeds.     │              │
///    └► hidden   waiting ◄─────────────── waitPeriodExpired ──┴─────► (delete)
///          │      ▲   │                     ▲               User restores
///          └──────┘   └─────────────────────┘               the draft.
///         Debounce     [sendMessage] request
///         timed out.   not finished when
///                      wait period timed out.
///
///              Event received.
///              Or message found in a fetch
///              and [sendMessage] succeeded, in either order.
///              Or [sendMessage] request succeeds and
///              we're sending to an unsubscribed channel.
/// (any state) ───────────────────────────────────────► (delete)
/// ```
///
/// During its lifecycle, it is guaranteed that the outbox message is deleted
/// as soon a message event with a matching [MessageEvent.localMessageId]
/// arrives.
/// Once the [sendMessage] request has succeeded, the outbox message is also
/// deleted as soon as a message with a matching [OutboxMessage.messageId]
/// is found in a fetch; see [MessageStoreImpl.reconcileMessages].
/// If the message was found in a fetch while the send request was in flight,
/// the deletion happens when the send request succeeds,
/// which is when [OutboxMessage.messageId] becomes known.
/// If we're sending to an unsubscribed channel, we don't expect an event
/// (see "third buggy behavior" in #1798) so in that case
/// the outbox message is deleted when the [sendMessage] request succeeds.
enum OutboxMessageState {
  /// The [sendMessage] HTTP request has started but the resulting
  /// [MessageEvent] hasn't arrived, and nor has the request failed.  In this
  /// state, the outbox message is hidden to the user.
  ///
  /// This is the initial state when an [OutboxMessage] is created.
  hidden,

  /// The [sendMessage] HTTP request has started but hasn't finished, and the
  /// outbox message is shown to the user.
  ///
  /// This state can be reached after staying in [hidden] for
  /// [kLocalEchoDebounceDuration], or when the request succeeds after the
  /// outbox message reaches [OutboxMessageState.waitPeriodExpired].
  waiting,

  /// The [sendMessage] HTTP request did not finish in time and the user is
  /// invited to retry it.
  ///
  /// This state can be reached when the request has not finished
  /// [kSendMessageOfferRestoreWaitPeriod] since the outbox message's creation.
  waitPeriodExpired,

  /// The message could not be delivered, and the user is invited to retry it.
  ///
  /// This state can be reached when we got an [ApiRequestException] from the
  /// [sendMessage] HTTP request.
  failed,

  /// The [MessageEvent] for this message has arrived while a view at
  /// [MessageListView.atKnownNewest] is waiting for revalidation or a fetch to
  /// bridge a gap before the server message can be merged into the list.
  ///
  /// The message has been sent and assigned [OutboxMessage.messageId], so it
  /// is no longer in [MessageStore.outboxMessages] and shows without a
  /// progress indicator or error label.
  sent,
}

/// An outstanding request to send a message, aka an outbox-message.
///
/// This will be shown in the UI in the message list, as a placeholder
/// for the actual [Message] the request is anticipated to produce.
///
/// A request remains "outstanding" even after the [sendMessage] HTTP request
/// completes, whether with success or failure.
/// The outbox-message persists until either the corresponding message
/// arrives to replace it (in a [MessageEvent] or, once the request has
/// succeeded, in a fetch), or the user discards it (perhaps to try again).
/// For details, see the state diagram at [OutboxMessageState],
/// and [MessageStore.takeOutboxMessage].
sealed class OutboxMessage<T extends Conversation> extends MessageBase<T> {
  OutboxMessage({
    required this.localMessageId,
    required int selfUserId,
    required super.timestamp,
    required this.contentMarkdown,
  }) : _state = OutboxMessageState.hidden,
       super(senderId: selfUserId);

  // TODO(dart): This has to be a plain static method, because factories/constructors
  //   do not support type parameters: https://github.com/dart-lang/language/issues/647
  static OutboxMessage fromConversation(Conversation conversation, {
    required int localMessageId,
    required int selfUserId,
    required int timestamp,
    required String contentMarkdown,
  }) {
    return switch (conversation) {
      StreamConversation() => StreamOutboxMessage._(
        localMessageId: localMessageId,
        selfUserId: selfUserId,
        timestamp: timestamp,
        conversation: conversation,
        contentMarkdown: contentMarkdown),
      DmConversation() => DmOutboxMessage._(
        localMessageId: localMessageId,
        selfUserId: selfUserId,
        timestamp: timestamp,
        conversation: conversation,
        contentMarkdown: contentMarkdown),
    };
  }

  /// As in [MessageEvent.localMessageId].
  ///
  /// This uniquely identifies this outbox message's corresponding message object
  /// in events from the same event queue.
  ///
  /// See also:
  ///  * [MessageStoreImpl.sendMessage], where this ID is assigned.
  final int localMessageId;

  /// The ID of the [Message] this request is anticipated to produce,
  /// from the [sendMessage] response ([SendMessageResult.id]),
  /// or null if a successful response hasn't arrived.
  int? get messageId => _messageId;
  int? _messageId;

  @override
  int? get id => null;

  final String contentMarkdown;

  OutboxMessageState get state => _state;
  OutboxMessageState _state;

  /// Whether the [OutboxMessage] is hidden to [MessageListView] or not.
  bool get hidden => state == OutboxMessageState.hidden;
}

class StreamOutboxMessage extends OutboxMessage<StreamConversation> {
  StreamOutboxMessage._({
    required super.localMessageId,
    required super.selfUserId,
    required super.timestamp,
    required this.conversation,
    required super.contentMarkdown,
  });

  @override
  final StreamConversation conversation;
}

class DmOutboxMessage extends OutboxMessage<DmConversation> {
  DmOutboxMessage._({
    required super.localMessageId,
    required super.selfUserId,
    required super.timestamp,
    required this.conversation,
    required super.contentMarkdown,
  }) : assert(conversation.allRecipientIds.contains(selfUserId));

  @override
  final DmConversation conversation;
}

/// Manages the outbox messages portion of [MessageStore].
mixin _OutboxMessageStore on HasChannelStore {
  int _inFlightSendCount = 0;
  Completer<void>? _allSendsSettled;

  /// Resolves when all `_apiSendMessage` calls currently in flight settle,
  /// or `null` if none are in flight when accessed.
  Future<void>? get inFlightSendsSettled => _allSendsSettled?.future;

  Future<T> _trackInFlightSend<T>(Future<T> Function() fn) async {
    assert(!_disposed);
    _inFlightSendCount++;
    _allSendsSettled ??= Completer<void>();
    try {
      return await fn();
    } finally {
      _inFlightSendCount--;
      if (_inFlightSendCount == 0) {
        _allSendsSettled?.complete();
        _allSendsSettled = null;
      }
    }
  }
  late final UnmodifiableMapView<int, OutboxMessage> outboxMessages =
    UnmodifiableMapView(_outboxMessages);
  final Map<int, OutboxMessage> _outboxMessages = {};

  /// The replacement store's [_OutboxMessageStore], if this store was replaced
  /// while still holding outbox entries or in-flight sends.
  _OutboxMessageStore? _successorOutbox;

  _OutboxMessageStore? get _liveSuccessorOutbox {
    var current = _successorOutbox;
    while (current != null && current._disposed) {
      current = current._successorOutbox;
    }
    return current;
  }

  /// Transfer pending and failed outbox messages to [successor] when this store
  /// is being replaced by [successor] for the same account.
  void handOffOutboxMessagesTo(_OutboxMessageStore successor) {
    assert(!_disposed);
    assert(!successor._disposed);
    _successorOutbox = successor;
    if (successor._nextLocalMessageId < _nextLocalMessageId) {
      successor._nextLocalMessageId = _nextLocalMessageId;
    }
    if (_outboxMessages.isEmpty) return;

    for (final entry in _outboxMessages.entries) {
      final localMessageId = entry.key;
      final outboxMessage = entry.value;
      _outboxMessageDebounceTimers.remove(localMessageId)?.cancel();
      _outboxMessageWaitPeriodTimers.remove(localMessageId)?.cancel();
      if (successor._nextLocalMessageId <= localMessageId) {
        successor._nextLocalMessageId = localMessageId + 1;
      }

      final messageId = outboxMessage._messageId;
      if (messageId != null) {
        if (successor.messages.containsKey(messageId)) continue;
        if (outboxMessage.conversation case StreamConversation(:final streamId)
            when successor.subscriptions[streamId] == null) {
          continue;
        }
      }

      successor._outboxMessages[localMessageId] = outboxMessage;
      switch (outboxMessage.state) {
        case OutboxMessageState.hidden:
          successor._outboxMessageDebounceTimers[localMessageId] = Timer(
            kLocalEchoDebounceDuration,
            () => successor._handleOutboxDebounce(localMessageId));
          if (messageId == null) {
            successor._outboxMessageWaitPeriodTimers[localMessageId] = Timer(
              kSendMessageOfferRestoreWaitPeriod,
              () => successor._handleOutboxWaitPeriodExpired(localMessageId));
          }
        case OutboxMessageState.waiting:
          if (messageId == null) {
            successor._outboxMessageWaitPeriodTimers[localMessageId] = Timer(
              kSendMessageOfferRestoreWaitPeriod,
              () => successor._handleOutboxWaitPeriodExpired(localMessageId));
          }
        case OutboxMessageState.waitPeriodExpired:
        case OutboxMessageState.failed:
        case OutboxMessageState.sent:
          break;
      }
    }
    _outboxMessages.clear();
  }

  /// A map of timers to show outbox messages after a delay,
  /// indexed by [OutboxMessage.localMessageId].
  ///
  /// If the send message request fails within the time limit,
  /// the outbox message's timer gets removed and cancelled.
  final Map<int, Timer> _outboxMessageDebounceTimers = {};

  /// A map of timers to update outbox messages state to
  /// [OutboxMessageState.waitPeriodExpired] if the [sendMessage]
  /// request did not complete in time,
  /// indexed by [OutboxMessage.localMessageId].
  ///
  /// If the send message request completes within the time limit,
  /// the outbox message's timer gets removed and cancelled.
  final Map<int, Timer> _outboxMessageWaitPeriodTimers = {};

  /// A fresh ID to use for [OutboxMessage.localMessageId],
  /// unique within this instance.
  int _nextLocalMessageId = 1;

  /// As in [MessageStoreImpl.messages].
  Map<int, Message> get messages;

  /// As in [MessageStoreImpl._messageListViews].
  Set<MessageListView> get _messageListViews;

  /// As in [MessageStoreImpl._disposed].
  bool get _disposed;

  /// Update the state of the [OutboxMessage] with the given [localMessageId],
  /// and notify listeners if necessary.
  ///
  /// The outbox message with [localMessageId] must exist.
  void _updateOutboxMessage(int localMessageId, {
    required OutboxMessageState newState,
  }) {
    assert(!_disposed);
    final outboxMessage = outboxMessages[localMessageId];
    if (outboxMessage == null) {
      throw StateError(
        'Removing unknown outbox message with localMessageId: $localMessageId');
    }
    final oldState = outboxMessage.state;
    // See [OutboxMessageState] for valid state transitions.
    final isStateTransitionValid = switch (newState) {
      OutboxMessageState.hidden => false,
      OutboxMessageState.waiting =>
        oldState == OutboxMessageState.hidden
        || oldState == OutboxMessageState.waitPeriodExpired,
      OutboxMessageState.waitPeriodExpired =>
        oldState == OutboxMessageState.waiting,
      OutboxMessageState.failed =>
        oldState == OutboxMessageState.hidden
        || oldState == OutboxMessageState.waiting
        || oldState == OutboxMessageState.waitPeriodExpired,
      OutboxMessageState.sent => false,
    };
    if (!isStateTransitionValid) {
      throw StateError('Unexpected state transition: $oldState -> $newState');
    }

    outboxMessage._state = newState;
    for (final view in _messageListViews) {
      if (oldState == OutboxMessageState.hidden) {
        view.addOutboxMessage(outboxMessage);
      } else {
        view.notifyListenersIfOutboxMessagePresent(localMessageId);
      }
    }
  }

  /// Send a message and create an entry of [OutboxMessage].
  Future<void> _outboxSendMessage({
    required MessageDestination destination,
    required String content,
  }) async {
    assert(!_disposed);
    final localMessageId = _nextLocalMessageId++;
    assert(!outboxMessages.containsKey(localMessageId));

    final conversation = switch (destination) {
      StreamDestination(:final streamId, :final topic) =>
        StreamConversation(
          streamId,
          _processTopicLikeServer(topic),
          displayRecipient: null),
      DmDestination(:final userIds) => DmConversation(allRecipientIds: userIds),
    };

    _outboxMessages[localMessageId] = OutboxMessage.fromConversation(
      conversation,
      localMessageId: localMessageId,
      selfUserId: selfUserId,
      timestamp: ZulipBinding.instance.utcNow().millisecondsSinceEpoch ~/ 1000,
      contentMarkdown: content);

    _outboxMessageDebounceTimers[localMessageId] = Timer(
      kLocalEchoDebounceDuration,
      () => _handleOutboxDebounce(localMessageId));

    _outboxMessageWaitPeriodTimers[localMessageId] = Timer(
      kSendMessageOfferRestoreWaitPeriod,
      () => _handleOutboxWaitPeriodExpired(localMessageId));

    final SendMessageResult result;
    try {
      result = await _trackInFlightSend(() => _apiSendMessage(connection,
        destination: destination,
        content: content,
        queueId: queueId,
        localId: localMessageId.toString()));
    } catch (e) {
      if (_disposed) {
        final successor = _liveSuccessorOutbox;
        if (successor == null) return;
        if (!successor._handleCarriedSendFailed(localMessageId)) return;
        rethrow;
      }
      if (!_outboxMessages.containsKey(localMessageId)) {
        // The message event already arrived; the failure is probably due to
        // networking issues. Don't rethrow; the send succeeded
        // (we got the event) so we don't want to show an error dialog.
        return;
      }
      _outboxMessageDebounceTimers.remove(localMessageId)?.cancel();
      _outboxMessageWaitPeriodTimers.remove(localMessageId)?.cancel();
      _updateOutboxMessage(localMessageId, newState: OutboxMessageState.failed);
      rethrow;
    }
    if (_disposed) {
      _liveSuccessorOutbox?._handleCarriedSendSucceeded(
        localMessageId,
        destination: destination,
        messageId: result.id,
      );
      return;
    }
    _completeSendSucceeded(
      localMessageId,
      destination: destination,
      messageId: result.id,
    );
  }

  bool _handleCarriedSendFailed(int localMessageId) {
    assert(!_disposed);
    if (!_outboxMessages.containsKey(localMessageId)) return false;
    _outboxMessageDebounceTimers.remove(localMessageId)?.cancel();
    _outboxMessageWaitPeriodTimers.remove(localMessageId)?.cancel();
    _updateOutboxMessage(localMessageId, newState: OutboxMessageState.failed);
    return true;
  }

  void _handleCarriedSendSucceeded(
    int localMessageId, {
    required MessageDestination destination,
    required int messageId,
  }) {
    assert(!_disposed);
    _completeSendSucceeded(
      localMessageId,
      destination: destination,
      messageId: messageId,
    );
  }

  void _completeSendSucceeded(
    int localMessageId, {
    required MessageDestination destination,
    required int messageId,
  }) {
    final outboxMessage = _outboxMessages[localMessageId];
    if (outboxMessage == null) {
      // The message event already arrived; nothing to do.
      return;
    }
    outboxMessage._messageId = messageId;

    if (destination is StreamDestination && subscriptions[destination.streamId] == null) {
      // We don't expect an event (we're sending to an unsubscribed channel);
      // clear the loading spinner.
      // We simultaneously reload the affected message lists from scratch, so
      // the user won't see a state where the message appears to have vanished.
      // (See _SendButtonState._send in lib/widgets/compose_box.dart.)
      _removeOutboxMessage(localMessageId);
      for (final view in _messageListViews) {
        view.notifyListenersIfOutboxMessagePresent(localMessageId);
      }
      return;
    }

    if (messages.containsKey(messageId)) {
      // The message already appeared in a fetch (or on a replacement queue),
      // while the send request was in flight.  Now that we know its ID, drop
      // the outbox message.
      _removeDeliveredOutboxMessage(outboxMessage);
      return;
    }

    // The send request succeeded, so the message was definitely sent.
    // Cancel the timer that would have had us start presuming that the
    // send might have failed.
    _outboxMessageWaitPeriodTimers.remove(localMessageId)?.cancel();
    if (outboxMessage.state == OutboxMessageState.waitPeriodExpired) {
      // The user was offered to restore the message since the request did not
      // complete for a while.  Since the request was successful, we expect the
      // message event to arrive eventually.  Stop inviting the the user to
      // retry, to avoid double-sends.
      _updateOutboxMessage(localMessageId, newState: OutboxMessageState.waiting);
    }
  }

  TopicName _processTopicLikeServer(TopicName topic) {
    // Processing this just once on creating the outbox message
    // allows an uncommon bug, because either of the values
    // [zulipFeatureLevel] or [realmEmptyTopicDisplayName] can change.
    // During the outbox message's life, a topic processed from
    // "(no topic)" could become stale/wrong when zulipFeatureLevel
    // changes; a topic processed from "general chat" could become
    // stale/wrong when realmEmptyTopicDisplayName changes.
    //
    // Shrug. The same effect is caused by an unavoidable race:
    // an admin could change the name of "general chat"
    // (i.e. the value of realmEmptyTopicDisplayName)
    // concurrently with the user making the send request,
    // so that the setting in effect by the time the request arrives
    // is different from the setting the client last heard about.
    return processTopicLikeServer(topic);
  }

  void _handleOutboxDebounce(int localMessageId) {
    assert(!_disposed);
    assert(outboxMessages.containsKey(localMessageId),
      'The timer should have been canceled when the outbox message was removed.');
    _outboxMessageDebounceTimers.remove(localMessageId);
    _updateOutboxMessage(localMessageId, newState: OutboxMessageState.waiting);
  }

  void _handleOutboxWaitPeriodExpired(int localMessageId) {
    assert(!_disposed);
    assert(outboxMessages.containsKey(localMessageId),
      'The timer should have been canceled when the outbox message was removed.');
    assert(!_outboxMessageDebounceTimers.containsKey(localMessageId),
      'The debounce timer should have been removed before the wait period timer expires.');
    _outboxMessageWaitPeriodTimers.remove(localMessageId);
    _updateOutboxMessage(localMessageId, newState: OutboxMessageState.waitPeriodExpired);
  }

  /// Remove the outbox message with [localMessageId] from the store,
  /// canceling its timers, and return it, or null if it isn't found.
  ///
  /// The caller is responsible for updating [MessageListView]s as appropriate.
  OutboxMessage? _removeOutboxMessage(int localMessageId) {
    final removed = _outboxMessages.remove(localMessageId);
    _outboxMessageDebounceTimers.remove(localMessageId)?.cancel();
    _outboxMessageWaitPeriodTimers.remove(localMessageId)?.cancel();
    return removed;
  }

  OutboxMessage takeOutboxMessage(int localMessageId) {
    assert(!_disposed);
    final removed = _removeOutboxMessage(localMessageId);
    if (removed == null) {
      throw StateError(
        'Removing unknown outbox message with localMessageId: $localMessageId');
    }
    if (removed.state != OutboxMessageState.failed
        && removed.state != OutboxMessageState.waitPeriodExpired
    ) {
      throw StateError('Unexpected state when restoring draft: ${removed.state}');
    }
    for (final view in _messageListViews) {
      view.removeOutboxMessage(removed);
    }
    return removed;
  }

  /// Remove any outbox messages whose anticipated [Message],
  /// as identified by [OutboxMessage.messageId], is in [messages],
  /// updating message-list views accordingly.
  ///
  /// This is how outbox messages get removed when their messages
  /// are received through a fetch instead of a [MessageEvent];
  /// see [MessageStoreImpl.reconcileMessages].
  void _removeDeliveredOutboxMessages() {
    assert(!_disposed);
    // This runs on every fetch (see [MessageStoreImpl.reconcileMessages]);
    // return cheaply in the common case of an empty outbox.
    if (_outboxMessages.isEmpty) return;
    final delivered = _outboxMessages.values
      .where((outboxMessage) {
        final messageId = outboxMessage._messageId;
        return messageId != null && messages.containsKey(messageId);
      })
      .toList();
    for (final outboxMessage in delivered) {
      _removeDeliveredOutboxMessage(outboxMessage);
    }
  }

  /// Remove [outboxMessage], whose anticipated [Message]
  /// (see [OutboxMessage.messageId]) must be in [messages],
  /// updating message-list views accordingly.
  void _removeDeliveredOutboxMessage(OutboxMessage outboxMessage) {
    assert(messages.containsKey(outboxMessage._messageId));
    _removeOutboxMessage(outboxMessage.localMessageId);
    for (final view in _messageListViews) {
      view.handleOutboxMessageDelivered(outboxMessage);
    }
  }

  OutboxMessage? _handleMessageEventOutbox(MessageEvent event) {
    if (event.localMessageId != null) {
      final localMessageId = int.parse(event.localMessageId!, radix: 10);
      // The outbox message can be missing if the user removes it before the
      // event arrives.  Nothing to do in that case.
      final removed = _removeOutboxMessage(localMessageId);
      if (removed != null) {
        removed._messageId = event.message.id;
        removed._state = OutboxMessageState.sent;
      }
      return removed;
    }
    if (_outboxMessages.isNotEmpty) {
      for (final outboxMessage in _outboxMessages.values) {
        if (outboxMessage._messageId == event.message.id) {
          final removed = _removeOutboxMessage(outboxMessage.localMessageId);
          if (removed != null) {
            removed._state = OutboxMessageState.sent;
          }
          return removed;
        }
      }
    }
    return null;
  }

  /// Cancel [_OutboxMessageStore]'s timers.
  void _disposeOutboxMessages() {
    assert(!_disposed);
    for (final timer in _outboxMessageDebounceTimers.values) {
      timer.cancel();
    }
    for (final timer in _outboxMessageWaitPeriodTimers.values) {
      timer.cancel();
    }
  }
}

typedef _RecordedCoveragePlan = ({
  String key,
  Narrow narrow,
  List<FetchBounds> intervals,
  List<int> ramForgottenIds,
});

typedef _PendingEffectEntry = ({
  MessageEffect effect,
  int seq,
  Map<String, Object?>? rawMessageMap,
  List<String>? rawFlags,
});

class _PendingEventBatch {
  _PendingEventBatch({required this.lastEventId, required this.epoch});

  final int? lastEventId;
  final int epoch;
  final List<_PendingEffectEntry> effects = [];
  final Map<int, bool> dirtyChannelFlags = {};
  final Set<int> removedChannelIds = {};
}
