import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../api/backoff.dart';
import '../api/exception.dart';
import '../api/model/events.dart';
import '../api/model/model.dart';
import '../api/route/channels.dart';
import 'channel.dart';
import 'store.dart';

// similar to _apiSendMessage in lib/model/message.dart
final _apiGetChannelTopics = getChannelTopics;

/// How long [TopicListView.fetch] waits on its request
/// before showing the channel's saved topics, if any.
///
/// See [TopicListView.showingSavedTopics].
const kShowSavedTopicsDelay = Duration(seconds: 1);

/// The view-model for tracking channel topics.
///
/// Use [getChannelTopics] to first fetch the topics for a channel from the
/// server and then use [channelTopics] to get those topics, affected
/// by the relevant events.
class Topics extends PerAccountStoreBase with ChangeNotifier {
  Topics({required super.core});

  /// Maps indexed by channel IDs, of the known latest message IDs in each topic.
  ///
  /// For example: `_latestMessageIdsByChannelTopic[channel.streamId][topic] = maxId`
  ///
  /// Occasionally, the latest message ID of a topic will refer to a message
  /// that doesn't exist or is no longer in the topic.
  /// This happens when the topic's latest message is deleted or moved
  /// and we don't have enough information to replace it accurately.
  /// (We don't keep a snapshot of all messages.)
  // TODO(#2004): handle more cases where this can change
  final Map<int, TopicKeyedMap<int>> _latestMessageIdsByChannelTopic = {};

  /// Map of topics per channel, sorted by latest message IDs descending.
  ///
  /// Derived from [_latestMessageIdsByChannelTopic];
  /// used for optimized topics sorting.
  ///
  /// A channel entry should be discarded when there is a change to
  /// the ordering of its topics or the channel is no longer present
  /// in [_latestMessageIdsByChannelTopic], allowing [channelTopics]
  /// to recalculate the sorted topics on demand.
  // TODO(#2004): handle more cases where this can change
  final Map<int, List<GetChannelTopicsEntry>> _sortedTopicsByChannel = {};

  final Map<int, Future<List<GetChannelTopicsEntry>>> _channelTopicsFetching = {};

  /// Get the topics in a channel; typically making a request to the server.
  ///
  /// This will avoid making redundant requests for the same data,
  /// even if this method is called many times. The futures returned from each
  /// call for the same channel will all complete once the data is ready.
  ///
  /// Once fetched, the data will be updated by events;
  /// use [channelTopics] to consume the data.
  Future<List<GetChannelTopicsEntry>> getChannelTopics(int channelId) async {
    List<GetChannelTopicsEntry>? topics = channelTopics(channelId);
    if (topics != null) return topics;

    // See if another call has already started fetching topics for this channel.
    Future<List<GetChannelTopicsEntry>>? future = _channelTopicsFetching[channelId];
    if (future != null) return future;

    future = _getChannelTopics(channelId);
    _channelTopicsFetching[channelId] = future;

    try {
      return await future;
    } finally {
      unawaited(_channelTopicsFetching.remove(channelId));
    }
  }

  Future<List<GetChannelTopicsEntry>> _getChannelTopics(int channelId) async {
    final result = await _apiGetChannelTopics(connection, channelId: channelId,
      allowEmptyTopicName: true);
    (_latestMessageIdsByChannelTopic[channelId] = makeTopicKeyedMap())
      .addEntries(result.topics.map((entry) => MapEntry(entry.name, entry.maxId)));
    notifyListeners();
    return channelTopics(channelId)!;
  }

  /// The topics the user can access, along with their latest message ID,
  /// reflecting updates from events that arrived since the data was fetched.
  ///
  /// Returns `null` if the data has not been fetched yet.
  /// To fetch it from the server, use [getChannelTopics].
  ///
  /// The result is sorted by [GetChannelTopicsEntry.maxId] descending,
  /// and the topics are distinct.
  ///
  /// Occasionally, [GetChannelTopicsEntry.maxId] will refer to a message
  /// that doesn't exist or is no longer in the topic.
  /// This happens when a topic's latest message is deleted or moved
  /// and we don't have enough information
  /// to replace [GetChannelTopicsEntry.maxId] accurately.
  /// (We don't keep a snapshot of all messages.)
  /// Use [PerAccountStore.messages] to check a message's topic accurately.
  List<GetChannelTopicsEntry>? channelTopics(int channelId) {
    final latestMessageIdsByTopic = _latestMessageIdsByChannelTopic[channelId];
    if (latestMessageIdsByTopic == null) return null;
    return _sortedTopicsByChannel[channelId] ??= latestMessageIdsByTopic.entries
      .map((e) => GetChannelTopicsEntry(maxId: e.value, name: e.key))
      .sortedBy((value) => -value.maxId);
  }

  void handleMessageEvent(MessageEvent event) {
    if (event.message is! StreamMessage) return;
    final StreamMessage(:id, streamId: channelId, :topic) = event.message as StreamMessage;

    final latestMessageIdsByTopic = _latestMessageIdsByChannelTopic[channelId];
    if (latestMessageIdsByTopic == null) {
      // We're not tracking this channel's topics yet.
      // We'll start doing that when we get the full topic list;
      // see [fetchChannelTopics].
      return;
    }

    final currentLatestMessageId = latestMessageIdsByTopic[topic];
    if (currentLatestMessageId != null && currentLatestMessageId >= id) {
      // The event raced with a topic-list fetch.
      return;
    }
    latestMessageIdsByTopic[topic] = id;
    _sortedTopicsByChannel.remove(channelId);
    notifyListeners();
  }

  void handleUpdateMessageEvent(UpdateMessageEvent event) {
    if (event.moveData == null) return;
    final UpdateMessageMoveData(
      :origStreamId, :origTopic, :newStreamId, :newTopic, :propagateMode,
    ) = event.moveData!;
    bool shouldNotify = false;

    final origLatestMessageIdsByTopic = _latestMessageIdsByChannelTopic[origStreamId];
    if (origLatestMessageIdsByTopic != null) {
      switch (propagateMode) {
        case .changeOne:
        case .changeLater:
          // We can't know the new `maxId` for the original topic.
          // Shrug; leave it unchanged. (See dartdoc of [channelTopics],
          // where we call out this possibility that `maxId` is incorrect.)
          break;
        case .changeAll:
          origLatestMessageIdsByTopic.remove(origTopic);
          _sortedTopicsByChannel.remove(origStreamId);
          shouldNotify = true;
      }
    }

    final newLatestMessageIdsByTopic = _latestMessageIdsByChannelTopic[newStreamId];
    if (newLatestMessageIdsByTopic != null) {
      // TODO(server-11): rely on `event.messageIds` being sorted, to avoid this linear scan
      final movedMaxId = event.messageIds.max;
      final currentMaxId = newLatestMessageIdsByTopic[newTopic];
      if (currentMaxId == null || currentMaxId < movedMaxId) {
        newLatestMessageIdsByTopic[newTopic] = movedMaxId;
        _sortedTopicsByChannel.remove(newStreamId);
        shouldNotify = true;
      }
    }

    if (shouldNotify) notifyListeners();
  }

  final Set<TopicListView> _topicListViews = {};

  void registerTopicListView(TopicListView view) {
    final added = _topicListViews.add(view);
    assert(added);
  }

  void unregisterTopicListView(TopicListView view) {
    final removed = _topicListViews.remove(view);
    assert(removed);
  }

  /// Called when the event stream has recovered from failures;
  /// see [PerAccountStore.isRecoveringEventStream].
  void handleEventStreamRecovered() {
    for (final view in _topicListViews) {
      view.handleEventStreamRecovered();
    }
  }
}

/// A view-model for a channel's topic list.
///
/// This fetches the channel's topics with [Topics.getChannelTopics],
/// retrying while that fails in a way that may be temporary;
/// see [fetch] and [fetchFailing].
///
/// Lifecycle:
///  * Create with [TopicListView.init].
///  * Call [fetch] once.
///  * Listen for changes with [addListener].
///  * When done, call [dispose].
class TopicListView extends ChangeNotifier {
  factory TopicListView.init({
    required PerAccountStore store,
    required int channelId,
  }) {
    return TopicListView._(store: store, channelId: channelId)
      .._register();
  }

  TopicListView._({required this.store, required this.channelId});

  final PerAccountStore store;
  final int channelId;

  bool _disposed = false;

  void _register() {
    store.topics.registerTopicListView(this);
    store.topics.addListener(_handleTopicsChanged);
    store.addListener(_handleStoreChanged);
  }

  @override
  void dispose() {
    assert(!_disposed);
    _endFetch();
    _disposed = true;
    store.removeListener(_handleStoreChanged);
    store.topics.removeListener(_handleTopicsChanged);
    store.topics.unregisterTopicListView(this);
    super.dispose();
  }

  List<GetChannelTopicsEntry>? get _liveTopics =>
    store.topics.channelTopics(channelId);

  /// The channel's topics to show, or null if there are none yet.
  ///
  /// These are those of [Topics.channelTopics], once fetched,
  /// and until then any locally saved ones being shown;
  /// see [showingSavedTopics].
  List<GetChannelTopicsEntry>? get topics => _liveTopics ?? _savedTopics;

  /// Whether [topics] are being shown with the saved-topics banner because
  /// [fetch] hasn't yet succeeded.
  bool get showingSavedTopics =>
    _liveTopics == null && _savedTopics != null && _showSavedTopicsBanner;
  List<GetChannelTopicsEntry>? _savedTopics;
  bool _showSavedTopicsBanner = false;

  bool get _canShowSavedTopics {
    if (!store.coverageEnabled) return false;
    final channel = store.streams[channelId];
    return channel != null && store.selfHasContentAccess(channel);
  }

  /// Whether [fetch] is failing and being retried, with no topics shown.
  ///
  /// This becomes true when a request in [fetch] fails
  /// in a way that may be temporary, unless [showingSavedTopics].
  /// It becomes false when the topics are fetched, saved topics are shown,
  /// or [fetch] stops on an error not to retry.
  bool get fetchFailing => _fetchFailing;
  bool _fetchFailing = false;

  bool _fetching = false;
  List<GetChannelTopicsEntry>? _loadedSavedTopics;
  bool _shouldShowSavedTopics = false;
  Timer? _showSavedTopicsTimer;

  /// Completed to stop the backoff wait in progress, if any,
  /// in the retry loop of [fetch], when the loop is no longer wanted.
  Completer<void>? _fetchAbort;

  /// Completed to cut short the backoff wait in progress, if any,
  /// in the retry loop of [fetch].
  ///
  /// See [handleEventStreamRecovered].
  Completer<void>? _backoffWake;

  /// Whether a request is in flight in the retry loop of [fetch].
  bool _requestInFlight = false;

  /// Whether, if the request in flight fails,
  /// [fetch] should retry at once rather than after a backoff wait.
  bool _retryPromptly = false;

  bool _fetchStarted = false;

  /// Fetch the channel's topics, unless [Topics] already has them.
  ///
  /// If the request fails in a way that may be temporary,
  /// such as a network failure or a 5xx error,
  /// this retries with backoff until a request succeeds,
  /// or until this view or the store is disposed.
  /// See [isRetryableRequestError].
  /// On other errors, this throws.
  ///
  /// Meanwhile, when saved topics are available and enabled, shows them
  /// immediately if [previousTopics] is passed or on a retryable failure,
  /// or after [kShowSavedTopicsDelay] while the initial request is pending.
  Future<void> fetch({
    List<GetChannelTopicsEntry>? previousTopics,
    bool previousShowingSavedTopics = true,
  }) async {
    assert(!_disposed);
    assert(!_fetchStarted);
    _fetchStarted = true;
    if (_liveTopics != null) return;

    bool isStale() => _disposed || store.disposed;
    _fetching = true;
    final abort = _fetchAbort = Completer<void>();

    if (_canShowSavedTopics) {
      if (previousTopics != null
          && (previousTopics.isNotEmpty || previousShowingSavedTopics)) {
        _savedTopics = previousTopics;
        _showSavedTopicsBanner = previousShowingSavedTopics;
        if (!previousShowingSavedTopics) {
          _showSavedTopicsTimer = Timer(kShowSavedTopicsDelay, () {
            _showSavedTopicsTimer = null;
            if (_disposed || store.disposed || !_fetching || _liveTopics != null) return;
            _showSavedTopicsBanner = true;
            notifyListeners();
          });
        }
        notifyListeners();
      } else {
        _showSavedTopicsTimer = Timer(kShowSavedTopicsDelay, () {
          _showSavedTopicsTimer = null;
          _shouldShowSavedTopics = true;
          _maybeShowSavedTopics();
        });
        unawaited(_loadSavedTopics());
      }
    }

    BackoffMachine? backoffMachine;
    while (true) {
      _requestInFlight = true;
      try {
        await store.topics.getChannelTopics(channelId);
        break;
      } catch (e) {
        if (isStale()) return;
        if (!isRetryableRequestError(e)) {
          _endFetch();
          if (_savedTopics != null || _fetchFailing) {
            _savedTopics = null;
            _showSavedTopicsBanner = false;
            _fetchFailing = false;
            notifyListeners();
          }
          rethrow;
        }
        if (_canShowSavedTopics) {
          if (_savedTopics != null && !_showSavedTopicsBanner) {
            _showSavedTopicsBanner = true;
            notifyListeners();
          }
          _shouldShowSavedTopics = true;
          _maybeShowSavedTopics();
        }
        if (!showingSavedTopics && !_fetchFailing) {
          _fetchFailing = true;
          notifyListeners();
        }
      } finally {
        _requestInFlight = false;
      }
      // TODO(log) the error
      if (_retryPromptly) {
        // The network is probably working again;
        // see [handleEventStreamRecovered].
        // Retry now, and if that fails too, start backoff over small.
        _retryPromptly = false;
        backoffMachine = null;
        continue;
      }
      final wake = _backoffWake = Completer<void>();
      await (backoffMachine ??= BackoffMachine())
        .wait(abortTrigger: Future.any([abort.future, wake.future]));
      if (isStale()) return;
      _backoffWake = null;
      if (wake.isCompleted) {
        // The network is probably working again;
        // if the retry fails anyway, start backoff over small.
        backoffMachine = null;
      }
    }
    if (isStale()) return;
    _endFetch();
    // [_handleTopicsChanged] has updated [fetchFailing] and [showingSavedTopics]
    // already, when [Topics] notified of the fetched topics.
    assert(topics != null && !showingSavedTopics && !fetchFailing);
  }

  /// Stop the retry loop of [fetch], if running,
  /// from waiting further on its backoff.
  ///
  /// The loop also needs to see, when it resumes, that it should stop.
  void _endFetch() {
    _fetching = false;
    final abort = _fetchAbort;
    _fetchAbort = null;
    abort?.complete();
    _backoffWake = null;
    _retryPromptly = false;
    _loadedSavedTopics = null;
    _showSavedTopicsTimer?.cancel();
    _showSavedTopicsTimer = null;
  }

  Future<void> _loadSavedTopics() async {
    final loaded = await store.loadSavedTopics(channelId);
    if (_disposed || store.disposed || !_fetching || loaded == null) return;
    _loadedSavedTopics = loaded;
    _maybeShowSavedTopics();
  }

  void _maybeShowSavedTopics() {
    if (_disposed || store.disposed || !_fetching || !_canShowSavedTopics) return;
    if (!_shouldShowSavedTopics) return;
    final loaded = _loadedSavedTopics;
    if (loaded == null) return;
    _loadedSavedTopics = null;
    _showSavedTopicsTimer?.cancel();
    _showSavedTopicsTimer = null;
    if (_liveTopics != null) return;
    _savedTopics = loaded;
    _showSavedTopicsBanner = true;
    _fetchFailing = false;
    notifyListeners();
  }

  void _handleStoreChanged() {
    if ((_savedTopics != null || _loadedSavedTopics != null) && !_canShowSavedTopics) {
      _savedTopics = null;
      _showSavedTopicsBanner = false;
      _loadedSavedTopics = null;
      notifyListeners();
    }
  }

  void _handleTopicsChanged() {
    if (_liveTopics != null) {
      _savedTopics = null;
      _showSavedTopicsBanner = false;
      _loadedSavedTopics = null;
      _fetchFailing = false;
    }
    notifyListeners();
  }

  /// Called when the event stream has recovered from failures;
  /// see [PerAccountStore.isRecoveringEventStream].
  ///
  /// If [fetch] is waiting to retry, this makes it retry now,
  /// because the network is probably working again.
  /// If it has a request in flight, and that goes on to fail,
  /// it retries without waiting.
  void handleEventStreamRecovered() {
    if (_requestInFlight) _retryPromptly = true;
    final wake = _backoffWake;
    _backoffWake = null;
    wake?.complete();
  }
}
