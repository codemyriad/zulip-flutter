import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../api/model/model.dart';
import 'message_effect.dart';

/// A handle representing an in-flight message fetch or DB read
/// whose snapshot reflects all effects with `seq <= mark`.
class FetchTicket {
  FetchTicket._(
    this._buffer, {
    required this.mark,
    this.epoch = 0,
    this.knownMaxAtSend = 0,
    this.channelGeneration,
    this.channelDropGeneration,
  });

  final RaceBuffer _buffer;

  /// The [RaceBuffer.seq] (or [RaceBuffer.dbCommittedSeq] for DB reads)
  /// at the moment this fetch or read was issued.
  final int mark;

  /// The store's coverage epoch when this fetch or DB read started.
  final int epoch;

  /// The largest message ID known to the client when this fetch was sent.
  final int knownMaxAtSend;

  /// The channel's subscription/access generation when this fetch was sent,
  /// if the fetch is for a channel or topic narrow.
  final int? channelGeneration;

  /// The channel's coverage drop generation when this fetch was sent,
  /// if the fetch is for a channel or topic narrow.
  final int? channelDropGeneration;

  bool _overflowed = false;

  /// Whether the [RaceBuffer] entry cap was exceeded for entries needed by this ticket.
  bool get overflowed => _overflowed;

  bool _closed = false;

  /// Whether this ticket has been closed.
  bool get isClosed => _closed;

  void _markClosed() {
    _closed = true;
  }

  /// Close this ticket and allow the buffer to prune entries no longer needed.
  void close() {
    _buffer.closeTicket(this);
  }
}

/// Bounded per-store buffer of effects recorded while fetches or DB writes
/// are in flight, so a completing fetch or DB read can drop deleted/purged
/// messages and re-apply effects that raced with its snapshot.
class RaceBuffer {
  RaceBuffer({this.entryCap = defaultEntryCap});

  static const int defaultEntryCap = 2000;

  final int entryCap;

  int _seq = 0;

  /// Monotonic sequence number incremented for each recorded effect.
  int get seq => _seq;

  /// Highest sequence number discarded by an entry-cap overflow,
  /// or 0 if no overflow has discarded entries needed by uncommitted batches.
  int _entriesClearedThroughSeq = 0;

  final Set<FetchTicket> _openTickets = {};
  final SplayTreeSet<int> _uncommittedSeqs = SplayTreeSet<int>();

  @visibleForTesting
  int get openTicketCount => _openTickets.length;

  @visibleForTesting
  int get uncommittedCount => _uncommittedSeqs.length;

  /// The highest effect sequence number whose write job has committed to DB.
  int get dbCommittedSeq => _uncommittedSeqs.isEmpty ? _seq : _uncommittedSeqs.first - 1;

  final List<({int seq, MessageEffect effect})> _entries = [];
  final List<({int seq, Set<int> ids})> _removed = [];
  final List<({int seq, int channelId})> _purged = [];
  final List<({int seq, int id})> _arrived = [];
  // `ids == null` represents [FlagAllReadEffect].
  final List<({int seq, bool add, Set<int>? ids})> _readFlags = [];

  @visibleForTesting
  int get entryCount => _entries.length;
  @visibleForTesting
  int get removedCount => _removed.length;
  @visibleForTesting
  int get purgedCount => _purged.length;
  @visibleForTesting
  int get arrivedCount => _arrived.length;
  @visibleForTesting
  int get readFlagsCount => _readFlags.length;

  /// Open a new [FetchTicket] anchored at the current [seq].
  ///
  /// The caller must close the ticket in a `finally` block
  /// via [FetchTicket.close] or [closeTicket].
  FetchTicket openTicket({
    int epoch = 0,
    int knownMaxAtSend = 0,
    int? channelGeneration,
    int? channelDropGeneration,
  }) {
    final ticket = FetchTicket._(
      this,
      mark: _seq,
      epoch: epoch,
      knownMaxAtSend: knownMaxAtSend,
      channelGeneration: channelGeneration,
      channelDropGeneration: channelDropGeneration,
    );
    if (ticket.mark < _entriesClearedThroughSeq) {
      ticket._overflowed = true;
    }
    _openTickets.add(ticket);
    return ticket;
  }

  /// Open a [FetchTicket] for a message-DB read, anchored at [dbCommittedSeq].
  ///
  /// The caller must close the ticket in a `finally` block
  /// via [FetchTicket.close] or [closeTicket].
  FetchTicket openDbReadTicket({
    required int epoch,
    int? channelGeneration,
    int? channelDropGeneration,
  }) {
    final ticket = FetchTicket._(
      this,
      mark: dbCommittedSeq,
      epoch: epoch,
      channelGeneration: channelGeneration,
      channelDropGeneration: channelDropGeneration,
    );
    if (ticket.mark < _entriesClearedThroughSeq) {
      ticket._overflowed = true;
    }
    _openTickets.add(ticket);
    return ticket;
  }

  /// Close [ticket] and prune buffer items no longer needed by any open ticket.
  ///
  /// Safe to call multiple times or after [closeAll].
  void closeTicket(FetchTicket ticket) {
    assert(identical(ticket._buffer, this));
    if (ticket.isClosed) return;
    ticket._markClosed();
    _openTickets.remove(ticket);
    _prune();
  }

  /// Close all open tickets, clear uncommitted markers, and prune retained items.
  void closeAll() {
    for (final ticket in _openTickets) {
      ticket._markClosed();
    }
    _openTickets.clear();
    _uncommittedSeqs.clear();
    _entriesClearedThroughSeq = 0;
    _prune();
  }

  /// Record [effect], incrementing [seq] and retaining it while any ticket
  /// is open or its DB commit is pending (when [needsDbCommit] is true).
  ///
  /// Returns the assigned sequence number.
  int record(MessageEffect effect, {bool needsDbCommit = false}) {
    final s = ++_seq;
    if (needsDbCommit) {
      _uncommittedSeqs.add(s);
    }
    if (_openTickets.isEmpty && _uncommittedSeqs.isEmpty) return s;

    switch (effect) {
      case InsertEffect(:final message):
        _arrived.add((seq: s, id: message.id));

      case DeleteEffect(:final messageIds):
      case ForgetEffect(:final messageIds):
        if (messageIds.isNotEmpty) {
          _removed.add((seq: s, ids: messageIds.toSet()));
        }

      case ChannelPurgeEffect(:final channelId):
        _purged.add((seq: s, channelId: channelId));

      case FlagAllReadEffect():
        _readFlags.add((seq: s, add: true, ids: null));

      case FlagEffect(:final flag, :final add, :final messageIds):
        if (flag == MessageFlag.read) {
          if (messageIds.isNotEmpty) {
            _readFlags.add((seq: s, add: add, ids: messageIds.toSet()));
          }
        } else {
          _addEntry(s, effect);
        }

      case ContentEffect():
      case EditTimeEffect():
      case MoveEffect():
      case ReactionEffect():
      case SubmessageEffect():
      case ChannelUntrackEffect():
        _addEntry(s, effect);
    }
    return s;
  }

  /// Return all mutable-message effects with `afterMark < seq <= throughSeq`
  /// in exact [seq] order.
  List<MessageEffect> effectsInRange(int afterMark, int throughSeq) {
    final result = <MessageEffect>[];
    int ei = _lowerBound(_entries, afterMark, (e) => e.seq);
    int ri = _lowerBound(_readFlags, afterMark, (e) => e.seq);

    MessageEffect readFlagToEffect(({int seq, bool add, Set<int>? ids}) item) {
      if (item.ids == null) {
        return const FlagAllReadEffect();
      }
      return FlagEffect(
        messageIds: item.ids!.toList(),
        flag: MessageFlag.read,
        add: item.add,
      );
    }

    while (ei < _entries.length && _entries[ei].seq <= throughSeq
        && ri < _readFlags.length && _readFlags[ri].seq <= throughSeq) {
      if (_entries[ei].seq < _readFlags[ri].seq) {
        result.add(_entries[ei].effect);
        ei++;
      } else {
        result.add(readFlagToEffect(_readFlags[ri]));
        ri++;
      }
    }
    while (ei < _entries.length && _entries[ei].seq <= throughSeq) {
      result.add(_entries[ei].effect);
      ei++;
    }
    while (ri < _readFlags.length && _readFlags[ri].seq <= throughSeq) {
      result.add(readFlagToEffect(_readFlags[ri]));
      ri++;
    }
    return result;
  }

  /// Whether any entries after [afterMark] were discarded due to overflow.
  bool didOverflowAfter(int afterMark) => afterMark < _entriesClearedThroughSeq;

  /// Mark effects with [seqs] as committed to SQLite and prune retained items.
  void markCommitted(Iterable<int> seqs) {
    var removedAny = false;
    for (final s in seqs) {
      if (_uncommittedSeqs.remove(s)) {
        removedAny = true;
      }
    }
    if (removedAny) {
      _prune();
    }
  }

  void _addEntry(int seq, MessageEffect effect) {
    if (_entries.length >= entryCap) {
      for (final ticket in _openTickets) {
        ticket._overflowed = true;
      }
      _entries.clear();
      _entriesClearedThroughSeq = seq;
      return;
    }
    _entries.add((seq: seq, effect: effect));
  }

  void _prune() {
    int floor = _uncommittedSeqs.isEmpty ? _seq : _uncommittedSeqs.first - 1;
    for (final t in _openTickets) {
      if (t.mark < floor) floor = t.mark;
    }

    _pruneBySeq(_entries, floor, (e) => e.seq);
    _pruneBySeq(_removed, floor, (e) => e.seq);
    _pruneBySeq(_purged, floor, (e) => e.seq);
    _pruneBySeq(_arrived, floor, (e) => e.seq);
    _pruneBySeq(_readFlags, floor, (e) => e.seq);
  }

  static void _pruneBySeq<T>(List<T> list, int floor, int Function(T) seqOf) {
    int dropCount = 0;
    while (dropCount < list.length && seqOf(list[dropCount]) <= floor) {
      dropCount++;
    }
    if (dropCount > 0) {
      list.removeRange(0, dropCount);
    }
  }

  /// Whether [messageId] (or its [channelId], if a channel message)
  /// was deleted, forgotten, or purged after [mark].
  bool wasRemovedOrPurgedAfter(int mark, int messageId, {int? channelId}) {
    for (int i = _removed.length - 1; i >= 0; i--) {
      final item = _removed[i];
      if (item.seq <= mark) break;
      if (item.ids.contains(messageId)) return true;
    }
    if (channelId != null) {
      for (int i = _purged.length - 1; i >= 0; i--) {
        final item = _purged[i];
        if (item.seq <= mark) break;
        if (item.channelId == channelId) return true;
      }
    }
    return false;
  }

  /// Whether [channelId] had a [ChannelPurgeEffect] recorded after [mark].
  bool wasChannelPurgedAfter(int mark, int channelId) {
    for (int i = _purged.length - 1; i >= 0; i--) {
      final item = _purged[i];
      if (item.seq <= mark) break;
      if (item.channelId == channelId) return true;
    }
    return false;
  }

  /// All message IDs that arrived via [InsertEffect]
  /// or were moved via [MoveEffect] after [mark].
  Set<int> arrivedOrMovedIdsAfter(int mark) {
    final result = <int>{};
    for (int i = _lowerBound(_arrived, mark, (e) => e.seq); i < _arrived.length; i++) {
      result.add(_arrived[i].id);
    }
    for (final move in moveEffectsAfter(mark)) {
      result.addAll(move.messageIds);
    }
    return result;
  }

  /// All message IDs removed via delete or forget after [mark].
  Set<int> removedIdsAfter(int mark) {
    final result = <int>{};
    for (int i = _lowerBound(_removed, mark, (e) => e.seq); i < _removed.length; i++) {
      result.addAll(_removed[i].ids);
    }
    return result;
  }

  /// All [MoveEffect]s recorded after [mark], in order.
  Iterable<MoveEffect> moveEffectsAfter(int mark) sync* {
    int i = _lowerBound(_entries, mark, (e) => e.seq);
    for (; i < _entries.length; i++) {
      final effect = _entries[i].effect;
      if (effect is MoveEffect) yield effect;
    }
  }

  /// Whether [channelId] had a [ChannelUntrackEffect] recorded after [mark].
  bool wasChannelUntrackedAfter(int mark, int channelId) {
    for (int i = _entries.length - 1; i >= 0; i--) {
      final item = _entries[i];
      if (item.seq <= mark) break;
      final effect = item.effect;
      if (effect is ChannelUntrackEffect && effect.channelId == channelId) {
        return true;
      }
    }
    return false;
  }

  /// Re-apply all effects recorded after [mark] that affect [message],
  /// in exact [seq] order.
  void applyEffectsAfter(int mark, Message message) {
    int ei = _lowerBound(_entries, mark, (e) => e.seq);
    int ri = _lowerBound(_readFlags, mark, (e) => e.seq);

    while (ei < _entries.length && ri < _readFlags.length) {
      if (_entries[ei].seq < _readFlags[ri].seq) {
        _entries[ei].effect.applyToMessage(message);
        ei++;
      } else {
        _applyReadFlag(_readFlags[ri], message);
        ri++;
      }
    }
    while (ei < _entries.length) {
      _entries[ei].effect.applyToMessage(message);
      ei++;
    }
    while (ri < _readFlags.length) {
      _applyReadFlag(_readFlags[ri], message);
      ri++;
    }
  }

  static void _applyReadFlag(
    ({int seq, bool add, Set<int>? ids}) item,
    Message message,
  ) {
    if (item.ids != null && !item.ids!.contains(message.id)) return;
    if (item.add) {
      if (!message.flags.contains(MessageFlag.read)) {
        message.flags = [...message.flags, MessageFlag.read];
      }
    } else {
      if (message.flags.contains(MessageFlag.read)) {
        message.flags = [
          for (final f in message.flags)
            if (f != MessageFlag.read) f,
        ];
      }
    }
  }

  static int _lowerBound<T>(List<T> list, int mark, int Function(T) seqOf) {
    int lo = 0;
    int hi = list.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (seqOf(list[mid]) <= mark) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}
