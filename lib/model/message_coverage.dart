/// Coverage of message-id ranges per canonical narrow, in memory.
///
/// An interval `[lo, hi]` of a key K claims:
/// the stored messages that are members of K with ids in it
/// are exactly K's members there.
library;

import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'narrow.dart' show serverTopicFold;
export 'narrow.dart' show serverTopicFold;

/// The server's `LARGER_THAN_MAX_MESSAGE_ID`, the resolved anchor of `newest`.
///
/// Open intervals are treated as reaching this id.
const int kNewestMessageId = 10000000000000000;

/// Canonical narrow keys for message coverage.
abstract final class CoverageKeys {
  /// All DMs: the server's `is:dm`, a coverage source only.
  static const dms = 'dms';

  static String dm(Iterable<int> allRecipientIds) {
    final sorted = allRecipientIds.toList()..sort();
    return 'dm:${sorted.join(',')}';
  }

  static String channel(int channelId) => 'channel:$channelId';

  static String topic(int channelId, String topic) =>
    'topic:$channelId:${serverTopicFold(topic)}';

  /// The keys of which a message at this location is a member.
  static List<String> ofLocation({String? dmKey, int? channelId, String? topic}) {
    if (dmKey != null) return [dmKey, dms];
    return [CoverageKeys.topic(channelId!, topic!), channel(channelId)];
  }

  /// The keys whose intervals may answer a query for [key]:
  /// the key itself, and a key that contains it exactly on the server.
  static List<String> sources(String key) {
    if (key.startsWith('topic:')) return [key, channel(channelIdOf(key)!)];
    if (key.startsWith('dm:')) return [key, dms];
    return [key];
  }

  /// Whether [sub]'s members are a subset of [key]'s, selected by a row predicate.
  static bool isSubkey(String sub, String key) {
    if (key == dms) return sub.startsWith('dm:');
    if (key.startsWith('channel:')) {
      return sub.startsWith('topic:') && channelIdOf(sub) == channelIdOf(key);
    }
    return false;
  }

  static int? channelIdOf(String key) {
    if (!key.startsWith('channel:') && !key.startsWith('topic:')) return null;
    return int.parse(key.split(':')[1]);
  }
}

enum CoverageStatus { live, unconfirmed, stale }

/// One interval of completeness for a key.
final class CoverageInterval {
  const CoverageInterval(this.lo, this.hi, {
    required this.epoch,
    required this.tracked,
    required this.verifiedAt,
  });

  /// Inclusive; 0 iff the interval reaches the oldest message.
  final int lo;

  /// Inclusive; null when open (claims every future member).
  final int? hi;

  final int epoch;

  /// Events are expected for the key's members (a DM, or a subscribed channel).
  final bool tracked;

  /// Timestamp (ms) when the interval was verified or last live.
  final int verifiedAt;

  bool get isOpen => hi == null;

  int get top => hi ?? kNewestMessageId;

  bool contains(int id) => id >= lo && id <= top;

  CoverageInterval _withBounds(int newLo, int? newHi) => CoverageInterval(
    newLo, newHi, epoch: epoch, tracked: tracked, verifiedAt: verifiedAt);

  CoverageInterval _withTags({bool? tracked, int? verifiedAt}) => CoverageInterval(
    lo, hi, epoch: epoch,
    tracked: tracked ?? this.tracked,
    verifiedAt: verifiedAt ?? this.verifiedAt);

  @override
  bool operator ==(Object other) =>
    other is CoverageInterval
    && other.lo == lo
    && other.hi == hi
    && other.epoch == epoch
    && other.tracked == tracked
    && other.verifiedAt == verifiedAt;

  @override
  int get hashCode => Object.hash(lo, hi, epoch, tracked, verifiedAt);

  @override
  String toString() =>
    '[$lo, ${hi ?? '∞'}]@e$epoch${tracked ? '' : ' untracked'} v$verifiedAt';
}

/// A maximal run of a key's coverage, possibly made of pieces from several sources.
final class CoveragePiece {
  const CoveragePiece(this.lo, this.hi, {
    required this.status,
    required this.verifiedAt,
    required this.source,
    required this.sourceOpen,
  });

  final int lo;
  final int? hi;
  final CoverageStatus status;
  final int verifiedAt;

  /// Whether the interval this piece comes from is open
  /// (the piece may be closed only because another source takes over above it).
  final bool sourceOpen;

  /// The key whose interval this piece comes from,
  /// or `'bridge'` for the DM gap bridge.
  final String source;

  bool get isOpen => hi == null;
  int get top => hi ?? kNewestMessageId;

  @override
  String toString() => '[$lo, ${hi ?? '∞'}] ${status.name} v$verifiedAt ($source)';
}

/// Adjacent pieces of the union of a key's sources.
final class CoverageChain {
  CoverageChain(this.pieces) : assert(pieces.isNotEmpty);

  final List<CoveragePiece> pieces;

  int get lo => pieces.first.lo;
  int? get hi => pieces.last.hi;
  int get top => pieces.last.top;
  bool get isOpen => hi == null;
  bool get reachesOldest => lo == 0;

  bool contains(int id) => id >= lo && id <= top;

  /// The least trustworthy status among the pieces.
  CoverageStatus get status => pieces.map((p) => p.status)
    .reduce((a, b) => a.index >= b.index ? a : b);

  /// The status of the piece holding [id].
  CoverageStatus statusAt(int id) =>
    pieces.firstWhere((p) => id >= p.lo && id <= p.top).status;

  /// The oldest non-zero [CoveragePiece.verifiedAt] among non-live pieces,
  /// prioritizing stale pieces when any exist.
  int? get oldestVerifiedAt {
    int? minStale;
    int? minAny;
    for (final p in pieces) {
      if (p.status == CoverageStatus.live || p.verifiedAt <= 0) continue;
      if (p.status == CoverageStatus.stale) {
        if (minStale == null || p.verifiedAt < minStale) minStale = p.verifiedAt;
      }
      if (minAny == null || p.verifiedAt < minAny) minAny = p.verifiedAt;
    }
    return minStale ?? minAny;
  }

  @override
  String toString() => 'Chain(${pieces.join(', ')})';
}

/// A message move event's parameters, for [MessageCoverage.handleMove].
final class CoverageMove {
  const CoverageMove({
    required this.messageIds,
    required this.origChannelId,
    required this.origTopic,
    required this.newChannelId,
    required this.newTopic,
  });

  final List<int> messageIds;
  final int origChannelId;
  final String origTopic;
  final int newChannelId;
  final String newTopic;

  /// The keys moved messages may newly join.
  List<String> get destinationKeys => [
    if (!(newChannelId == origChannelId
          && serverTopicFold(newTopic) == serverTopicFold(origTopic)))
      CoverageKeys.topic(newChannelId, newTopic),
    if (newChannelId != origChannelId)
      CoverageKeys.channel(newChannelId),
  ];
}

/// The interval a `GET /messages` result proves, before tagging.
typedef FetchBounds = ({int lo, int? hi});

class MessageCoverage {
  /// How often the per-key interval cap dropped intervals (for test statistics).
  @visibleForTesting
  static int debugCapHits = 0;

  MessageCoverage({
    required this._epoch,
    this.maxIntervalsPerKey = 16,
  });

  final int maxIntervalsPerKey;

  int get epoch => _epoch;
  int _epoch;

  /// Whether the event queue of the current epoch has had one successful poll.
  bool confirmed = true;

  /// The largest message id among `/register`'s `max_message_id`
  /// and the `message` events applied in the current epoch.
  /// Never raised by fetched ids.
  int eventHighWater = -1;

  /// Rows with id below this were evicted; no interval starts below it.
  int evictedBelow = 0;

  /// The `lo` of the `dms` interval opened by the last [beginEpoch], for the DM bridge.
  int? _epochDmsStart;
  int? _epochStartedAt;

  final Map<String, List<CoverageInterval>> _byKey = {};

  /// Keys changed since the last persistence job.
  final Set<String> dirtyKeys = {};

  Iterable<String> get keys => _byKey.keys;

  List<CoverageInterval> intervalsOf(String key) =>
    List.unmodifiable(_byKey[key] ?? const <CoverageInterval>[]);

  /// Returns the current interval lists for all [dirtyKeys] and clears [dirtyKeys].
  Map<String, List<CoverageInterval>> takeDirtyIntervals() {
    if (dirtyKeys.isEmpty) return const {};
    final result = <String, List<CoverageInterval>>{
      for (final key in dirtyKeys)
        key: List<CoverageInterval>.of(_byKey[key] ?? const <CoverageInterval>[]),
    };
    dirtyKeys.clear();
    return result;
  }

  /// Creates an isolated working copy sharing the same parameters and state.
  MessageCoverage stage() {
    final copy = MessageCoverage(
      epoch: _epoch,
      maxIntervalsPerKey: maxIntervalsPerKey,
    )
      ..confirmed = confirmed
      ..eventHighWater = eventHighWater
      ..evictedBelow = evictedBelow
      .._epochDmsStart = _epochDmsStart
      .._epochStartedAt = _epochStartedAt;
    for (final entry in _byKey.entries) {
      copy._byKey[entry.key] = List<CoverageInterval>.of(entry.value);
    }
    copy.dirtyKeys.addAll(dirtyKeys);
    copy._dropGeneration.addAll(_dropGeneration);
    return copy;
  }

  /// Replaces this coverage state with [staged] after a staged transaction succeeds.
  void adoptFrom(MessageCoverage staged) {
    _epoch = staged._epoch;
    confirmed = staged.confirmed;
    eventHighWater = staged.eventHighWater;
    evictedBelow = staged.evictedBelow;
    _epochDmsStart = staged._epochDmsStart;
    _epochStartedAt = staged._epochStartedAt;
    _byKey
      ..clear()
      ..addEntries(staged._byKey.entries.map(
        (e) => MapEntry(e.key, List<CoverageInterval>.of(e.value))));
    dirtyKeys
      ..clear()
      ..addAll(staged.dirtyKeys);
    _dropGeneration
      ..clear()
      ..addAll(staged._dropGeneration);
  }

  bool isContinuous(CoverageInterval i) => i.epoch == _epoch && i.tracked;

  CoverageStatus statusOf(CoverageInterval i) {
    if (!isContinuous(i)) return CoverageStatus.stale;
    return confirmed ? CoverageStatus.live : CoverageStatus.unconfirmed;
  }

  //
  // Interval algebra.
  //

  /// Inserts [n] for [key], replacing overlapping parts of any status.
  void insert(String key, CoverageInterval n) {
    final lo = max(n.lo, evictedBelow);
    if (lo > n.top) return;
    if (lo != n.lo) n = n._withBounds(lo, n.hi);
    final list = _byKey[key] ?? [];
    final result = <CoverageInterval>[];
    for (final r in list) {
      if (r.top < n.lo || r.lo > n.top) {
        result.add(r);
        continue;
      }
      if (r.lo < n.lo) result.add(r._withBounds(r.lo, n.lo - 1));
      if (r.top > n.top) result.add(r._withBounds(n.top + 1, r.hi));
    }
    result.add(n);
    _set(key, result);
  }

  /// Per interval of [key], cuts out the span from the least to the greatest
  /// of [unstoredIds] inside it.
  void punctureSpan(String key, Iterable<int> unstoredIds) {
    final list = _byKey[key];
    if (list == null) return;
    final ids = unstoredIds.toList();
    if (ids.isEmpty) return;
    final result = <CoverageInterval>[];
    var changed = false;
    for (final r in list) {
      final inside = ids.where(r.contains);
      if (inside.isEmpty) {
        result.add(r);
        continue;
      }
      changed = true;
      final a = inside.reduce(min);
      final b = inside.reduce(max);
      if (r.lo <= a - 1) result.add(r._withBounds(r.lo, a - 1));
      if (b + 1 <= r.top) result.add(r._withBounds(b + 1, r.hi));
    }
    if (changed) _set(key, result);
  }

  void punctureAt(Iterable<String> keys, int id) {
    for (final key in keys) {
      punctureSpan(key, [id]);
    }
  }

  /// Closes every open interval at [highWater], as at an epoch end,
  /// and clips every other continuous interval there.
  ///
  /// Every continuous tracked interval, open or closed, was maintained until now,
  /// so it is verified as of [lastLiveAt].
  void _closeOpen(Iterable<String> keys, int highWater, int lastLiveAt) {
    for (final key in keys.toList()) {
      final result = <CoverageInterval>[];
      for (var r in _byKey[key]!) {
        final continuous = isContinuous(r);
        if (continuous) r = r._withTags(verifiedAt: lastLiveAt);
        if (r.isOpen || (continuous && r.top > highWater)) {
          final hi = max(r.lo - 1, highWater);
          if (hi < r.lo) continue; // nothing in it was ever received
          r = r._withBounds(r.lo, hi);
        }
        result.add(r);
      }
      _set(key, result);
    }
  }

  /// A fresh `/register`: ends the current epoch and begins the next.
  ///
  /// Before calling this, the caller deletes stored DM rows proved deleted
  /// by the snapshot (those with id > [maxMessageId], or above a listed
  /// conversation's latest id) and then runs the epoch-start access check
  /// ([dropChannel] for channels whose access or history regime changed).
  void beginEpoch({required int? maxMessageId, required int lastLiveAt, required int now}) {
    _closeOpen(_byKey.keys, eventHighWater, lastLiveAt);
    _epoch += 1;
    confirmed = true;
    eventHighWater = maxMessageId ?? -1;
    if (maxMessageId != null) {
      // Every DM with id > max_message_id arrives as an event in this epoch.
      insert(CoverageKeys.dms, CoverageInterval(maxMessageId + 1, null,
        epoch: _epoch, tracked: true, verifiedAt: now));
      _epochDmsStart = maxMessageId + 1;
    } else {
      _epochDmsStart = null;
    }
    _epochStartedAt = now;
  }

  /// Restores persisted coverage from the database without marking [dirtyKeys].
  void restore({
    required int epoch,
    required int eventHighWater,
    required int evictedBelow,
    required bool confirmed,
    required Map<String, List<CoverageInterval>> intervalsByKey,
  }) {
    _byKey.clear();
    dirtyKeys.clear();
    for (final entry in intervalsByKey.entries) {
      if (entry.value.isNotEmpty) {
        _byKey[entry.key] = List<CoverageInterval>.of(entry.value)
          ..sort((a, b) => a.lo.compareTo(b.lo));
      }
    }
    _epoch = epoch;
    this.confirmed = confirmed;
    this.eventHighWater = eventHighWater;
    this.evictedBelow = evictedBelow;
    CoverageInterval? openDms;
    final dmList = _byKey[CoverageKeys.dms];
    if (dmList != null && dmList.isNotEmpty && dmList.last.isOpen && dmList.last.epoch == epoch) {
      openDms = dmList.last;
    }
    _epochDmsStart = openDms?.lo;
    _epochStartedAt = openDms?.verifiedAt;
  }

  /// A persisted start that continues the epoch: unconfirmed until the first poll.
  void markUnconfirmed() => confirmed = false;

  void confirm() => confirmed = true;

  /// Unsubscribe: close and untrack every interval of the channel and its topics.
  void untrackChannel(int channelId, {required int now}) {
    final keys = _keysOfChannel(channelId);
    _closeOpen(keys, eventHighWater, now);
    for (final key in _keysOfChannel(channelId)) {
      _set(key, [for (final r in _byKey[key]!) r._withTags(tracked: false)]);
    }
  }

  /// Counts [dropChannel] calls per channel; a fetch ticket records it at send.
  int dropGeneration(int channelId) => _dropGeneration[channelId] ?? 0;
  final Map<int, int> _dropGeneration = {};

  /// Access loss or a history-regime change: forget all coverage of the channel.
  void dropChannel(int channelId) {
    _dropGeneration[channelId] = dropGeneration(channelId) + 1;
    for (final key in _keysOfChannel(channelId)) {
      _byKey.remove(key);
      dirtyKeys.add(key);
    }
  }

  void _clipKeyBelow(String key, int cutoff) {
    final existing = _byKey[key];
    if (existing == null || existing.isEmpty) return;
    final clipped = [
      for (final r in existing)
        if (r.top >= cutoff) r._withBounds(max(r.lo, cutoff), r.hi),
    ];
    if (clipped.length == existing.length && clipped.first.lo == existing.first.lo) {
      return;
    }
    _set(key, clipped);
  }

  /// Eviction or a global purge of rows below [cutoff].
  void clipBelow(int cutoff) {
    evictedBelow = max(evictedBelow, cutoff);
    for (final key in _byKey.keys.toList()) {
      _clipKeyBelow(key, cutoff);
    }
  }

  /// Drops all coverage outside [viewSpansByKey], used when the DB writer is
  /// poisoned mid-session so memory-only `localWindow` never claims rows that
  /// existed only in SQLite while keeping currently open views coherent.
  void retainOnlyOpenViewSpans(
    Map<String, List<({int lo, int top})>> viewSpansByKey, {
    required bool Function(String key) isKeyTracked,
  }) {
    final oldChains = <String, List<CoverageChain>>{
      for (final key in viewSpansByKey.keys) key: chains(key),
    };
    _byKey.clear();
    dirtyKeys.clear();
    _epochDmsStart = null;
    evictedBelow = 0;
    for (final entry in viewSpansByKey.entries) {
      final key = entry.key;
      final tracked = isKeyTracked(key);
      final existing = oldChains[key] ?? const <CoverageChain>[];
      for (final span in entry.value) {
        for (final chain in existing) {
          for (final piece in chain.pieces) {
            final lo = max(piece.lo, span.lo);
            final top = min(piece.top, span.top);
            if (lo > top) continue;
            final hi = (top >= kNewestMessageId && piece.hi == null) ? null : top;
            final isStale = piece.status == CoverageStatus.stale;
            insert(
              key,
              CoverageInterval(
                lo,
                hi,
                epoch: isStale ? 0 : _epoch,
                tracked: !isStale && (hi == null || tracked),
                verifiedAt: piece.verifiedAt,
              ),
            );
          }
        }
      }
    }
    dirtyKeys.clear();
  }

  /// Retention purge of DM rows below [cutoff], leaving [evictedBelow] unchanged.
  void clipDmFamilyBelow(int cutoff) {
    if (cutoff <= 0) return;
    for (final key in _byKey.keys.toList()) {
      if (key == CoverageKeys.dms || key.startsWith('dm:')) {
        _clipKeyBelow(key, cutoff);
      }
    }
  }

  /// Retention purge of channel [channelId] rows below [cutoff],
  /// leaving [evictedBelow] unchanged.
  void clipChannelFamilyBelow(int channelId, int cutoff) {
    if (cutoff <= 0) return;
    for (final key in _keysOfChannel(channelId).toList()) {
      _clipKeyBelow(key, cutoff);
    }
  }

  //
  // The event stream.
  //

  /// Record implied intervals for a `message` event.
  void handleMessageEvent({
    required int messageId,
    required String? dmKey,
    required int? channelId,
    required bool subscribed,
    required int now,
    int largestKnownIdBefore = -1,
  }) {
    eventHighWater = max(eventHighWater, messageId);
    final String key;
    if (dmKey != null) {
      key = CoverageKeys.dms;
    } else if (subscribed) {
      key = CoverageKeys.channel(channelId!);
    } else {
      return;
    }
    if ((_byKey[key] ?? const []).any((r) => r.isOpen)) return;
    final start = max(messageId, largestKnownIdBefore + 1);
    insert(key, CoverageInterval(start, null,
      epoch: _epoch, tracked: true, verifiedAt: now));
  }

  /// A move event: puncture the destination keys at the moved ids not stored.
  void handleMove(CoverageMove move, {required bool Function(int id) isStored}) {
    final unstored = move.messageIds.where((id) => !isStored(id)).toList();
    for (final key in move.destinationKeys) {
      punctureSpan(key, unstored);
    }
  }

  //
  // Fetch results.
  //

  /// The intervals a `GET /messages` response proves:
  /// usually one, two when an unknown anchor leaves a hole, none if nothing is proven.
  ///
  /// [ids] are all returned ids, unfiltered and sorted.
  /// [anchorKnownVisible] is true only when this response itself returned [anchor]
  /// (so the server's plan history limit was at or below it).
  static List<FetchBounds> fetchIntervals({
    required int anchor,
    required int numBefore,
    required int numAfter,
    required bool includeAnchor,
    required List<int> ids,
    required bool foundOldest,
    required bool foundNewest,
    required bool historyLimited,
    required bool tracked,
    required bool continuous,
    required int knownMaxAtSend,
    required bool anchorKnownVisible,
  }) {
    final anchoredRight = anchor >= kNewestMessageId;
    final anchoredLeft = anchor == 0;
    if (foundNewest && anchoredLeft && historyLimited) {
      // With `anchor=oldest`, rows hidden by the plan history limit were still
      // counted against `num_after`, so `found_newest` does not prove the top.
      foundNewest = false;
    }

    final firstBefore = (!foundOldest && numBefore > 0)
      ? ids.where((s) => s < anchor).firstOrNull
      : null;
    final int lo;
    if (foundOldest && !historyLimited) {
      lo = 0;
    } else if (foundOldest) {
      if (ids.isEmpty) return [];
      lo = ids.first;
    } else if (firstBefore != null) {
      lo = firstBefore;
    } else {
      lo = includeAnchor ? anchor : anchor + 1;
    }

    final openAllowed = tracked && continuous;
    final lastAfter = (!foundNewest && numAfter > 0 && !anchoredRight)
      ? ids.where((s) => s > anchor).lastOrNull
      : null;
    final int? hi;
    if (foundNewest && openAllowed) {
      hi = null;
    } else if (foundNewest) {
      hi = max(ids.isEmpty ? -1 : ids.last, knownMaxAtSend);
    } else if (lastAfter != null) {
      hi = lastAfter;
    } else {
      // Ids above every id known assigned at the snapshot
      // may be assigned later to matching messages.
      hi = min(includeAnchor ? anchor : anchor - 1,
        max(knownMaxAtSend, ids.isEmpty ? -1 : ids.last));
    }
    final top = hi ?? kNewestMessageId;
    if (top < lo) return [];
    if (anchorKnownVisible) return [(lo: lo, hi: hi)];

    // When the anchor is not known visible, it may be hidden or unassigned.
    if (numBefore == 0 && numAfter == 0) return [];
    // No after-query; or anchor=oldest, whose after-query isn't bumped.
    if (numAfter == 0 || anchoredRight || anchoredLeft) return [(lo: lo, hi: hi)];
    // The after-query started at max(start, first_visible_message_id)
    // and says nothing about rows it skipped below first_visible_message_id,
    // so ids from `start` up to the first returned one are not proven.
    final start = numBefore > 0 ? anchor : anchor + (includeAnchor ? 0 : 1);
    final firstAfter = ids.where((s) => s >= start).firstOrNull;
    return [
      if (lo <= start - 1) (lo: lo, hi: min(start - 1, top)),
      if (firstAfter != null && firstAfter <= top) (lo: max(lo, firstAfter), hi: hi),
    ];
  }

  /// Records a fetch's interval, then re-runs the punctures of the moves
  /// handled after the request was sent.
  void recordFetch(String key, FetchBounds bounds, {
    required int epoch,
    required bool tracked,
    required int verifiedAt,
    required List<CoverageMove> movesAfterMark,
    required bool Function(int id) isStored,
  }) {
    insert(key, CoverageInterval(bounds.lo, bounds.hi,
      epoch: epoch, tracked: tracked, verifiedAt: verifiedAt));
    for (final move in movesAfterMark) {
      handleMove(move, isStored: isStored);
    }
  }

  /// The keys to puncture when an authoritative fetch of [fetchedKey]
  /// forgets a message stored at a location with keys [keysOfMessage].
  static Iterable<String> forgetPunctureKeys(String fetchedKey, List<String> keysOfMessage) =>
    keysOfMessage.where((k) => k != fetchedKey && !CoverageKeys.isSubkey(k, fetchedKey));

  void forget(String fetchedKey, List<String> keysOfMessage, int messageId) {
    punctureAt(forgetPunctureKeys(fetchedKey, keysOfMessage), messageId);
  }

  //
  // Queries.
  //

  /// The chains of [key]: maximal runs of adjacent pieces of its sources' intervals.
  ///
  /// Where sources overlap, the most trustworthy piece wins.
  /// For a DM key, [dmLatestKnownId] (the conversation's latest id from
  /// recent DM conversations) enables the DM gap bridge:
  /// a gap ending just below the current epoch's implied `dms` interval
  /// holds no member of the conversation when its latest id is below the gap.
  List<CoverageChain> chains(String key, {int? dmLatestKnownId}) {
    final candidates = <(CoverageInterval, String)>[
      for (final source in CoverageKeys.sources(key))
        for (final r in _byKey[source] ?? const <CoverageInterval>[])
          (r, source),
    ];
    if (candidates.isEmpty) return [];
    final breaks = <int>{};
    for (final (r, _) in candidates) {
      breaks.add(r.lo);
      if (r.top < kNewestMessageId) breaks.add(r.top + 1);
    }
    final sortedBreaks = breaks.toList()..sort();
    final pieces = <CoveragePiece>[];
    for (var i = 0; i < sortedBreaks.length; i++) {
      final a = sortedBreaks[i];
      final b = i + 1 < sortedBreaks.length ? sortedBreaks[i + 1] - 1 : kNewestMessageId;
      (CoverageInterval, String)? best;
      for (final c in candidates) {
        if (!c.$1.contains(a)) continue;
        if (best == null || _better(c.$1, best.$1)) best = c;
      }
      if (best == null) continue;
      final (r, source) = best;
      final hi = b >= kNewestMessageId ? r.hi : b;
      final piece = CoveragePiece(a, hi,
        status: statusOf(r), verifiedAt: r.verifiedAt, source: source, sourceOpen: r.isOpen);
      if (pieces.isNotEmpty) {
        final last = pieces.last;
        if (last.top + 1 == a && last.status == piece.status
            && last.verifiedAt == piece.verifiedAt && last.source == piece.source) {
          pieces[pieces.length - 1] = CoveragePiece(last.lo, piece.hi,
            status: last.status, verifiedAt: last.verifiedAt, source: last.source,
            sourceOpen: piece.sourceOpen);
          continue;
        }
      }
      pieces.add(piece);
    }

    if (dmLatestKnownId != null && key.startsWith('dm:') && _epochDmsStart != null) {
      final start = _epochDmsStart!;
      for (var i = 0; i + 1 < pieces.length; i++) {
        final below = pieces[i];
        final above = pieces[i + 1];
        if (above.lo == start && below.top + 1 < start && dmLatestKnownId <= below.top) {
          pieces.insert(i + 1, CoveragePiece(below.top + 1, start - 1,
            status: CoverageStatus.stale, verifiedAt: _epochStartedAt!, source: 'bridge',
            sourceOpen: false));
          break;
        }
      }
    }

    final result = <CoverageChain>[];
    var run = <CoveragePiece>[];
    for (final p in pieces) {
      if (run.isNotEmpty && run.last.top + 1 != p.lo) {
        result.add(CoverageChain(run));
        run = [];
      }
      run.add(p);
    }
    if (run.isNotEmpty) result.add(CoverageChain(run));
    return result;
  }

  /// The chain of [key] holding [id], if any:
  /// the id range around [id] that can be shown from storage,
  /// with the status of each piece.
  CoverageChain? chainAt(String key, int id, {int? dmLatestKnownId}) {
    for (final chain in chains(key, dmLatestKnownId: dmLatestKnownId)) {
      if (chain.contains(id)) return chain;
    }
    return null;
  }

  //
  // Internals.
  //

  bool _better(CoverageInterval a, CoverageInterval b) {
    final sa = statusOf(a).index;
    final sb = statusOf(b).index;
    if (sa != sb) return sa < sb;
    return a.verifiedAt > b.verifiedAt;
  }

  List<String> _keysOfChannel(int channelId) => [
    for (final key in _byKey.keys)
      if (CoverageKeys.channelIdOf(key) == channelId) key,
  ];

  bool _mergeable(CoverageInterval a, CoverageInterval b) {
    final ca = isContinuous(a);
    final cb = isContinuous(b);
    if (ca && cb) return true; // same (current) epoch, both tracked
    return !ca && !cb; // stale with stale
  }

  /// Sorts, merges adjacent intervals of the same status, and applies the cap.
  void _set(String key, List<CoverageInterval> list) {
    dirtyKeys.add(key);
    list.removeWhere((r) => r.lo > r.top);
    list.sort((a, b) => a.lo.compareTo(b.lo));
    final merged = <CoverageInterval>[];
    for (final r in list) {
      if (merged.isNotEmpty) {
        final last = merged.last;
        assert(r.lo > last.top, 'overlap in $key: $last, $r');
        if (r.lo == last.top + 1 && _mergeable(last, r)) {
          final continuous = isContinuous(last);
          merged[merged.length - 1] = CoverageInterval(last.lo, r.hi,
            epoch: min(last.epoch, r.epoch),
            tracked: continuous || (last.tracked && r.tracked),
            verifiedAt: min(last.verifiedAt, r.verifiedAt));
          continue;
        }
      }
      merged.add(r);
    }
    // The cap: drop stale intervals with the lowest hi first, then any.
    // Dropping is always sound.
    if (merged.length > maxIntervalsPerKey) debugCapHits++;
    while (merged.length > maxIntervalsPerKey) {
      final stale = merged.where((r) => !isContinuous(r));
      final victim = (stale.isNotEmpty ? stale : merged)
        .reduce((a, b) => a.top <= b.top ? a : b);
      merged.remove(victim);
    }
    if (merged.isEmpty) {
      _byKey.remove(key);
    } else {
      _byKey[key] = merged;
    }
  }
}
