/// A "truth server" model for one user, and a client that keeps
/// stored messages plus [MessageCoverage] by the coverage rules.
///
/// Citations like "narrow.py:n" and "message_edit.py:n" are to the
/// Zulip server source (`zulip/zulip` `main`).
///
/// The truth server is independent of the code under test:
/// it has its own topic fold ([truthTopicFold]) and membership predicate,
/// and uses `message_coverage.dart` only for [kNewestMessageId]
/// and to build the [CoverageMove] payload of its move events.
///
/// Delivery classes beyond the base model are [ModelOptions];
/// the randomized run turns them on per seed.
///
/// Simplifications:
/// - One realm; other users are subscribed to every channel since its creation,
///   so a mover can access every message (cross-channel moves never split).
/// - No content edits, rendering-only updates, flags other than the
///   historical UserMessage row a reaction creates, polls, or typing.
/// - Memory only: storage is the client's row map; no DB reads, no race-buffer cap.
library;

import 'dart:math';

import 'package:zulip/model/message_coverage.dart';

const selfUserId = 1;

/// Subtler coverage edge-case rules verified by the model tests.
///
/// Each can be disabled via [disabledCorrections] to replay its counterexample
/// against the naive rule.
enum CoverageCorrection {
  anchorBoundsOnlyIfKnown,
  openOnlyIfContinuous,
  dropDeletedDmRowsAtRegister,
  noCoverageAcrossChannelDrop,
  discardOldEpochFetches,
  clipContinuousAtHighWater,
  oldestAnchorLimitedNotNewest,
  relocateLiveCopyOnFetch,
  reapplyMoveOnlyAtItsOrigin,
  noRowWithoutAccess,
  impliedStartAboveHighWater,
  anchorVisibleOnlyIfReturned,
  bridgeOnlyListedConversations,
  forgetRowMovedFromElsewhere,
}

Set<CoverageCorrection> disabledCorrections = {};

bool isCoverageCorrected(CoverageCorrection c) => !disabledCorrections.contains(c);

/// The delivery classes a run's truth server produces, beyond the base model.
final class ModelOptions {
  const ModelOptions({
    this.outOfOrderCommits = false,
    this.guest = false,
    this.groupAccess = false,
    this.inviteOnlyChanges = false,
    this.risingHistoryLimit = false,
    this.selfActor = false,
    this.dmListCap,
    this.foldDivergence = false,
  });

  /// R-3: a send computes its recipients, gets its id, and commits,
  /// as three steps other operations can interleave with
  /// (message_send.py: recipients in build_message_send_dict, before
  /// do_send_messages; the id at bulk_create, :1128; events on commit, :1455).
  /// This also gives the non-atomic event order around subscribe and unsubscribe.
  final bool outOfOrderCommits;

  /// Self is a guest: no access to unsubscribed public channels,
  /// no group-granted access, and excluded from move events as a subscriber
  /// of the destination only (message_edit.py:1320-1352).
  final bool guest;

  /// Self may be in a group granting content access to private channels
  /// (message.py:546-589), changed by `user_group` events.
  final bool groupAccess;

  /// Channels change between public and private (`invite_only`, streams.py:1280-1440).
  final bool inviteOnlyChanges;

  /// The plan history limit advances, silently (message.py:1403-1443).
  final bool risingHistoryLimit;

  /// Self deletes messages: the acting user always gets the event
  /// if they can access the messages (retention.py:373-413, FL 274).
  final bool selfActor;

  /// `recent_private_conversations` lists only this many conversations
  /// (the server's 1000, scaled down).
  final int? dmListCap;

  /// Hypothetical fold divergence: the server's `upper()` differs from
  /// the client's fold for some topic names (see [truthTopicFold]).
  final bool foldDivergence;

  static const all = ModelOptions(outOfOrderCommits: true, guest: true,
    groupAccess: true, inviteOnlyChanges: true, risingHistoryLimit: true,
    selfActor: true, dmListCap: 2);

  static const names = ['outOfOrderCommits', 'guest', 'groupAccess',
    'inviteOnlyChanges', 'risingHistoryLimit', 'selfActor', 'dmListCap'];

  /// Each class on with some probability.
  factory ModelOptions.random(Random rand) => ModelOptions(
    outOfOrderCommits: rand.nextInt(2) == 0,
    guest: rand.nextInt(4) == 0,
    groupAccess: rand.nextInt(2) == 0,
    inviteOnlyChanges: rand.nextInt(2) == 0,
    risingHistoryLimit: rand.nextInt(2) == 0,
    selfActor: rand.nextInt(2) == 0,
    dmListCap: rand.nextInt(3) == 0 ? 1 + rand.nextInt(2) : null);

  factory ModelOptions.named(Set<String> on) => ModelOptions(
    outOfOrderCommits: on.contains('outOfOrderCommits'),
    guest: on.contains('guest'),
    groupAccess: on.contains('groupAccess'),
    inviteOnlyChanges: on.contains('inviteOnlyChanges'),
    risingHistoryLimit: on.contains('risingHistoryLimit'),
    selfActor: on.contains('selfActor'),
    dmListCap: on.contains('dmListCap') ? 2 : null);

  @override
  String toString() => [
    if (outOfOrderCommits) 'R-3',
    if (guest) 'guest',
    if (groupAccess) 'group',
    if (inviteOnlyChanges) 'invite_only',
    if (risingHistoryLimit) 'rising limit',
    if (selfActor) 'self actor',
    if (dmListCap != null) 'dm list cap $dmListCap',
    if (foldDivergence) 'fold divergence',
  ].join(', ');
}

/// What PostgreSQL's `upper()` returns for each topic name the model uses,
/// written out by hand: under `LC_CTYPE='C.UTF-8'`, glibc's `towupper`,
/// the Unicode simple uppercase mapping per code point.
/// Deliberately not computed with the client's [serverTopicFold],
/// so that a wrong client fold can't also change the truth.
const _pgUpper = <String, String>{
  'a': 'A', 'A': 'A', 'b': 'B', 'B': 'B', 'c': 'C', 'C': 'C', 'x': 'X', 'X': 'X',
  // Greek final sigma: ς and σ both uppercase to Σ.
  'τέλος': 'ΤΈΛΟΣ', 'ΤΈΛΟΣ': 'ΤΈΛΟΣ',
  '✔ a': '✔ A', '✔ A': '✔ A',
  // ß has no single-code-point uppercase: kept.
  'ß': 'ß', 'SS': 'SS', 'ss': 'SS',
  // Dotless ı uppercases to I.
  'ı': 'I', 'i': 'I', 'I': 'I',
};

/// Hypothetical fold divergence: a full case mapping for ß
/// (as ICU collations apply it: `upper('ß') = 'SS'`),
/// and a C library without the mapping for ı.
const _divergentUpper = <String, String>{'ß': 'SS', 'ı': 'ı'};

String truthTopicFold(String topic, {bool divergent = false}) {
  final result = (divergent ? _divergentUpper[topic] : null) ?? _pgUpper[topic];
  if (result == null) throw ArgumentError('truthTopicFold: add "$topic" to the table');
  return result;
}

/// Where a message is, and whether self has a UserMessage row for it.
final class TLoc {
  const TLoc.dm(String this.dmKey) : channelId = null, topic = null, selfUm = true;
  const TLoc.channel(int this.channelId, String this.topic, {required this.selfUm})
    : dmKey = null;

  final String? dmKey;
  final int? channelId;
  final String? topic;
  final bool selfUm;

  bool get isDm => dmKey != null;

  @override
  String toString() => isDm ? dmKey! : '#$channelId>$topic${selfUm ? '' : ' (no UM)'}';
}

/// Realm, channel and subscription state at one version.
final class TGlobal {
  const TGlobal({
    required this.subscribed,
    required this.protectedHistory,
    required this.privateChannels,
    required this.groupAccess,
    required this.firstVisible,
  });

  final Set<int> subscribed;
  final Set<int> protectedHistory;
  final Set<int> privateChannels;
  final Set<int> groupAccess;
  final int firstVisible;
}

sealed class Ev {
  /// The server version right after the change this event reports.
  int version = 0;

  bool names(int id) => false;
}

final class MessageEv extends Ev {
  MessageEv(this.id, this.loc);
  final int id;
  final TLoc loc;
  @override bool names(int id) => id == this.id;
  @override String toString() => 'message $id $loc';
}

final class DeleteEv extends Ev {
  DeleteEv(this.ids, {this.accessKept = false});
  final List<int> ids;

  /// Sent for access loss by a move though self can still read
  /// the messages through a group. Model-side only: the client gets the same event.
  final bool accessKept;
  @override bool names(int id) => ids.contains(id);
  @override String toString() => 'delete $ids';
}

final class MoveEv extends Ev {
  MoveEv(this.move);
  final CoverageMove move;
  @override bool names(int id) => move.messageIds.contains(id);
  @override String toString() => 'move ${move.messageIds} '
    '#${move.origChannelId}>${move.origTopic} -> #${move.newChannelId}>${move.newTopic}';
}

final class SubAddEv extends Ev {
  SubAddEv(this.channelId, {required this.isPrivate, required this.isProtected});
  final int channelId;
  final bool isPrivate;
  final bool isProtected;
  @override String toString() => 'subscription add $channelId';
}

final class SubRemoveEv extends Ev {
  SubRemoveEv(this.channelId);
  final int channelId;
  @override String toString() => 'subscription remove $channelId';
}

/// `stream` update of `invite_only` or `history_public_to_subscribers`
/// (or `stream` create/delete for a user gaining or losing metadata access;
/// the client recomputes access from it the same way).
final class StreamUpdateEv extends Ev {
  StreamUpdateEv(this.channelId, {required this.isPrivate, required this.isProtected});
  final int channelId;
  final bool isPrivate;
  final bool isProtected;
  @override String toString() => 'stream update $channelId '
    '${isPrivate ? 'private' : 'public'}${isProtected ? ' protected' : ''}';
}

/// `user_group` membership change of self, for a group granting
/// content access to [channelId] (sent to the whole realm).
final class GroupAccessEv extends Ev {
  GroupAccessEv(this.channelId, {required this.hasAccess});
  final int channelId;
  final bool hasAccess;
  @override String toString() => 'user_group: group access to $channelId $hasAccess';
}

enum Propagate { changeOne, changeLater, changeAll }

final class FetchRequest {
  const FetchRequest(this.key, {
    required this.anchor,
    required this.numBefore,
    required this.numAfter,
    required this.includeAnchor,
  });

  final String key;
  final int anchor;
  final int numBefore;
  final int numAfter;
  final bool includeAnchor;

  @override
  String toString() => 'fetch $key anchor=${anchor >= kNewestMessageId ? 'newest' : anchor} '
    'b=$numBefore a=$numAfter${includeAnchor ? '' : ' excl'}';
}

final class FetchResult {
  const FetchResult({
    required this.messages,
    required this.anchor,
    required this.foundOldest,
    required this.foundNewest,
    required this.historyLimited,
    required this.version,
  });

  final List<(int, TLoc)> messages;
  final int anchor;
  final bool foundOldest;
  final bool foundNewest;
  final bool historyLimited;
  final int version;

  List<int> get ids => [for (final (id, _) in messages) id];

  @override
  String toString() => 'result@v$version $ids anchor=$anchor '
    'oldest=$foundOldest newest=$foundNewest limited=$historyLimited';
}

final class RegisterSnapshot {
  const RegisterSnapshot({
    required this.version,
    required this.maxMessageId,
    required this.subscribed,
    required this.privateChannels,
    required this.protectedHistory,
    required this.groupAccess,
    required this.guest,
    required this.dmLatest,
  });

  final int version;
  final int maxMessageId;
  final Set<int> subscribed;
  final Set<int> privateChannels;
  final Set<int> protectedHistory;
  final Set<int> groupAccess;
  final bool guest;
  final Map<String, int> dmLatest;
}

/// A send between computing its recipients and committing (R-3).
final class PendingSend {
  PendingSend({this.channelId, this.topic, this.dmKey, required this.selfRecipient,
    this.begunAt = 0});
  final int begunAt;
  final int? channelId;
  final String? topic;
  final String? dmKey;
  final bool selfRecipient;
  int? id;

  @override
  String toString() => 'pending ${id ?? '(no id)'} to '
    '${dmKey ?? '#$channelId>$topic'}${selfRecipient ? '' : ' (self not a recipient)'}';
}

class TruthServer {
  TruthServer({this.options = const ModelOptions()});

  final ModelOptions options;
  bool get guest => options.guest;

  static const channels = [10, 11, 12, 13];
  static const dmKeys = ['dm:1', 'dm:1,2', 'dm:1,3', 'dm:1,2,3'];
  static const topics = ['a', 'A', 'b', 'ΤΈΛΟΣ', 'τέλος'];

  int version = 0;
  int _lastId = 100;
  int _committedMax = -1;

  final Map<int, TLoc> messages = {};

  /// Every id assigned, in order, committed or not.
  final List<int> allIds = [];
  final Map<int, List<(int, TLoc?)>> _history = {};
  final List<(int, TGlobal)> _globalHistory = [];

  Set<int> subscribed = {};
  final Set<int> everSubscribed = {};
  final Set<int> privateChannels = {12, 13};
  final Set<int> protectedHistory = {13};
  final Set<int> groupAccess = {};
  int firstVisible = 0;

  /// Changes of self's membership with no event to self, per id:
  /// the version of the change and its kind (residuals R-1, R-3, R-4).
  final Map<int, List<(int, String)>> silent = {};

  /// The version of the latest change of self's content access per channel.
  final Map<int, int> lastAccessChange = {};

  /// The version at which each message was committed.
  final Map<int, int> createdAt = {};

  bool queueAlive = false;
  final List<Ev> pending = [];
  final List<PendingSend> pendingSends = [];

  String fold(String topic) => truthTopicFold(topic, divergent: options.foldDivergence);

  bool isPrivate(int c) => privateChannels.contains(c);
  bool isProtected(int c) => isPrivate(c) && protectedHistory.contains(c);
  bool isPublicHistory(int c) => !isProtected(c);

  void _tagSilent(int id, String kind) => (silent[id] ??= []).add((version, kind));

  void _commit({Iterable<int> changed = const [], bool global = false}) {
    version++;
    for (final id in changed) {
      (_history[id] ??= []).add((version, messages[id]));
    }
    if (global || _globalHistory.isEmpty) {
      _globalHistory.add((version, TGlobal(subscribed: {...subscribed},
        protectedHistory: {...protectedHistory}, privateChannels: {...privateChannels},
        groupAccess: {...groupAccess}, firstVisible: firstVisible)));
    }
  }

  void _emit(Ev e) {
    if (!queueAlive) return;
    e.version = version;
    pending.add(e);
  }

  /// Ids named in some event delivered to self, or with a UM row at a register:
  /// what the client may know of.
  final Set<int> toldSelf = {};

  /// When set, ids are assigned consecutively (for scripted scenarios).
  bool consecutiveIds = false;

  int get lastId => _lastId;

  int _newId(Random rand) {
    // Gaps stand for messages self can never see (others' DMs, other channels).
    _lastId += consecutiveIds ? 1 : 1 + rand.nextInt(3);
    allIds.add(_lastId);
    return _lastId;
  }

  void _committed(int id) {
    createdAt[id] = version;
    _committedMax = max(_committedMax, id);
  }

  /// Self's content access to channel [c] (message.py:546-642).
  bool contentAccessIn(int c, TGlobal g) {
    if (!g.privateChannels.contains(c)) return !guest || g.subscribed.contains(c);
    return g.subscribed.contains(c) || (!guest && g.groupAccess.contains(c));
  }

  bool contentAccessNow(int c) => contentAccessIn(c, _global);

  /// Self can read channel message [loc].
  bool _access(int c, TLoc loc, TGlobal g) {
    if (!contentAccessIn(c, g)) return false;
    if (g.privateChannels.contains(c) && g.protectedHistory.contains(c)) return loc.selfUm;
    return true;
  }

  TGlobal get _global => _globalHistory.last.$2;

  //
  // Server mutations.
  //

  int sendChannel(Random rand, int c, String topic) {
    final id = _newId(rand);
    // UM rows and `message` events go to active subscribers at send;
    // a sender not subscribed gets neither.
    final um = subscribed.contains(c);
    messages[id] = TLoc.channel(c, topic, selfUm: um);
    _commit(changed: [id]);
    _committed(id);
    if (um) _emit(MessageEv(id, messages[id]!));
    return id;
  }

  int sendDm(Random rand, String dmKey) {
    final id = _newId(rand);
    messages[id] = TLoc.dm(dmKey); // all participants
    _commit(changed: [id]);
    _committed(id);
    _emit(MessageEv(id, messages[id]!));
    return id;
  }

  /// R-3, step 1: recipients are computed (message_send.py:740, before
  /// the transaction of do_send_messages, :1107); maybe the id too.
  PendingSend beginSend(Random rand, {int? channelId, String? topic, String? dmKey,
      bool assignId = false}) {
    final p = PendingSend(channelId: channelId, topic: topic, dmKey: dmKey,
      selfRecipient: dmKey != null || subscribed.contains(channelId), begunAt: version);
    if (assignId) p.id = _newId(rand);
    pendingSends.add(p);
    return p;
  }

  /// R-3, step 2: `bulk_create` takes the id from the sequence (message_send.py:1128).
  void assignId(Random rand, PendingSend p) {
    assert(p.id == null);
    p.id = _newId(rand);
  }

  /// R-3, step 3: the transaction commits; the event goes to the recipients
  /// computed at step 1 (send_event_on_commit, message_send.py:1455;
  /// Tornado doesn't recheck subscriptions, event_queue.py:1091-1131).
  int commitSend(PendingSend p) {
    final id = p.id!;
    pendingSends.remove(p);
    messages[id] = p.dmKey != null ? TLoc.dm(p.dmKey!)
      : TLoc.channel(p.channelId!, p.topic!, selfUm: p.selfRecipient);
    final outOfOrder = id < _committedMax;
    final staleRecipients = p.dmKey == null && !p.selfRecipient
      && subscribed.contains(p.channelId);
    _commit(changed: [id]);
    _committed(id);
    if (outOfOrder) _tagSilent(id, 'R-3 out-of-order commit');
    if (staleRecipients) _tagSilent(id, 'R-3 recipients computed before subscribing');
    final c = p.channelId;
    if (c != null && p.selfRecipient
        && (outOfOrder || (lastAccessChange[c] ?? 0) > p.begunAt)) {
      // This event may open an implied interval at its id, which
      // then claims the channel's messages with higher ids that committed earlier,
      // or arrived by a move, and that self was never told of (R-3).
      for (final MapEntry(key: x, value: l) in messages.entries) {
        if (x > id && l.channelId == c && !toldSelf.contains(x)) {
          _tagSilent(x, 'R-3 implied: an out-of-order event opens the channel below it');
        }
      }
    }
    if (p.selfRecipient) _emit(MessageEv(id, messages[id]!));
    return id;
  }

  void delete(List<int> ids, {bool bySelf = false}) {
    final locs = [for (final id in ids) messages[id]!];
    final first = locs.first;
    bool gets;
    if (first.isDm) {
      gets = true; // DM UM holders
    } else {
      final c = first.channelId!;
      final anyUm = locs.any((l) => l.selfUm);
      if (isProtected(c)) {
        gets = subscribed.contains(c) && anyUm; // UM holders ∩ subscribers
      } else if (isPrivate(c)) {
        gets = subscribed.contains(c); // subscribers only
      } else {
        // subscribers ∪ non-guest UM holders
        gets = subscribed.contains(c) || (anyUm && !guest);
      }
    }
    // The acting user gets the event if they can access the messages
    // (retention.py:373-413, FL 274 / FL 457).
    if (bySelf) gets = true;
    for (final id in ids) {
      messages.remove(id);
    }
    _commit(changed: ids);
    // No residual tag when self gets no event: a continuous claim never covers
    // such a message (it would be in a tracked conversation, which gets deletes),
    // and a stale claim allows members to leave.
    if (gets) _emit(DeleteEv([...ids]..sort()));
  }

  /// Whether self can read message [id] now.
  bool canAccess(int id) {
    final l = messages[id];
    if (l == null) return false;
    return l.isDm || _access(l.channelId!, l, _global);
  }

  /// The ids [move] would select.
  List<int> selectForMove(int targetId, Propagate mode) {
    final target = messages[targetId]!;
    final o = target.channelId!;
    final f = fold(target.topic!);
    // change_one / change_later (id > target) / change_all,
    // topics matched case-insensitively (topic.py:209-222).
    return switch (mode) {
      Propagate.changeOne => [targetId],
      _ => [
        for (final MapEntry(key: id, value: l) in messages.entries)
          if (l.channelId == o && fold(l.topic!) == f
              && (mode == Propagate.changeAll || id >= targetId))
            id,
      ],
    }..sort();
  }

  /// Returns false if the move was a no-op.
  bool move(int targetId, Propagate mode, int newC, String newTopic) {
    final target = messages[targetId]!;
    final o = target.channelId!;
    final origTopic = target.topic!;
    if (newC == o && newTopic == origTopic) return false;
    final selected = selectForMove(targetId, mode);
    final cross = newC != o;
    final publicHistoryO = isPublicHistory(o);
    // message_edit.py:1124-1136: users with any subscription row to O
    // who are not subscribed to N lose access, if N is private or they are guests;
    // they get `delete_message` and lose their UM rows.
    final losing = cross && everSubscribed.contains(o) && !subscribed.contains(newC)
      && (isPrivate(newC) || guest);
    // A protected-history N gives its subscribers UM rows.
    final umFromN = cross && isProtected(newC) && subscribed.contains(newC);
    for (final id in selected) {
      final l = messages[id]!;
      messages[id] = TLoc.channel(newC, newTopic,
        selfUm: losing ? false : (umFromN || l.selfUm));
    }
    _commit(changed: selected);
    if (losing) {
      // Still readable through a group only with shared history: a protected N
      // needs the UM rows the move just deleted.
      final accessKept = contentAccessNow(newC) && !isProtected(newC);
      _emit(DeleteEv(selected, accessKept: accessKept));
      if (accessKept) {
        // Group-granted access to N: the messages are still readable,
        // yet self got `delete_message` and lost its UM rows (R-1).
        for (final id in selected) {
          _tagSilent(id, 'R-1 move-loss delete with access kept');
        }
      }
      return true;
    }
    final targetAfter = messages[targetId]!;
    // message_edit.py:1309-1352: the target's UM holders who can
    // access the moved messages, plus, only if O is public-history, subscribers
    // of O, and for a cross-channel move of N, minus guests not subscribed to O.
    final gets = (targetAfter.selfUm && _access(newC, targetAfter, _global))
      || (publicHistoryO
          && (subscribed.contains(o)
              || (cross && subscribed.contains(newC) && !(guest && !subscribed.contains(o)))));
    if (!gets && guest && publicHistoryO && cross && subscribed.contains(newC)) {
      _count('reach: guest excluded from a move into a subscribed channel');
    }
    if (gets) {
      _emit(MoveEv(CoverageMove(messageIds: selected,
        origChannelId: o, origTopic: origTopic, newChannelId: newC, newTopic: newTopic)));
    } else {
      // No event to self (R-1): protected-history O without a UM row
      // for the target, out of protected O into N, guests, or nobody told at all.
      for (final id in selected) {
        _tagSilent(id, 'R-1 silent move');
      }
      _count('reach: R-1 silent move');
    }
    return true;
  }

  void subscribe(int c) {
    if (!subscribed.add(c)) return;
    everSubscribed.add(c);
    _commit(global: true);
    lastAccessChange[c] = version;
    _emit(SubAddEv(c, isPrivate: isPrivate(c), isProtected: isProtected(c)));
  }

  void unsubscribe(int c) {
    if (!subscribed.remove(c)) return;
    _commit(global: true);
    lastAccessChange[c] = version;
    // `subscription` remove; for a private channel also `stream` delete,
    // which the client handles as access loss (by recomputing access).
    _emit(SubRemoveEv(c));
  }

  bool _metadataAccess(int c) => isPrivate(c)
    ? subscribed.contains(c) || (!guest && groupAccess.contains(c))
    : !guest || subscribed.contains(c);

  void toggleHistory(int c) {
    assert(isPrivate(c));
    if (!protectedHistory.remove(c)) protectedHistory.add(c);
    _commit(global: true);
    // `stream` update to users with metadata access.
    if (_metadataAccess(c)) {
      _emit(StreamUpdateEv(c, isPrivate: true, isProtected: isProtected(c)));
    }
  }

  /// `invite_only` toggled (do_change_stream_permission, streams.py:1280-1440):
  /// `stream` update to users with metadata access, `stream` delete to those
  /// losing it, `stream` create to those gaining it.
  void toggleInviteOnly(int c, {required bool protectedIfPrivate}) {
    final hadMetadata = _metadataAccess(c);
    if (isPrivate(c)) {
      privateChannels.remove(c);
      protectedHistory.remove(c); // public channels have shared history
    } else {
      privateChannels.add(c);
      if (protectedIfPrivate) protectedHistory.add(c);
    }
    _commit(global: true);
    lastAccessChange[c] = version;
    if (hadMetadata || _metadataAccess(c)) {
      _emit(StreamUpdateEv(c, isPrivate: isPrivate(c), isProtected: isProtected(c)));
    }
  }

  /// Self joins or leaves a group granting content access to [c]
  /// (`user_group` events go to the whole realm).
  void toggleGroupAccess(int c) {
    if (!groupAccess.remove(c)) groupAccess.add(c);
    _commit(global: true);
    lastAccessChange[c] = version;
    _emit(GroupAccessEv(c, hasAccess: groupAccess.contains(c)));
  }

  /// Self reacts to (or stars) a channel message: creates a historical UM row.
  bool react(int id) {
    final l = messages[id]!;
    if (l.isDm || l.selfUm || !_access(l.channelId!, l, _global)) return false;
    messages[id] = TLoc.channel(l.channelId!, l.topic!, selfUm: true);
    _commit(changed: [id]);
    return true;
  }

  /// The plan history limit changes silently.
  void setFirstVisible(int id) {
    final old = firstVisible;
    firstVisible = id;
    _commit(global: true);
    if (id > old) {
      for (final m in messages.keys) {
        if (m >= old && m < id) _tagSilent(m, 'R-4 history limit advanced');
      }
    }
  }

  void loseQueue() {
    queueAlive = false;
    pending.clear();
  }

  RegisterSnapshot register() {
    queueAlive = true;
    pending.clear();
    _commit(); // no state change; a distinct version for the register
    var maxId = -1;
    final dmLatest = <String, int>{};
    for (final MapEntry(key: id, value: l) in messages.entries) {
      // max over self's UM rows (historical included).
      if (l.selfUm) maxId = max(maxId, id);
      if (l.selfUm) toldSelf.add(id);
      if (l.isDm) dmLatest[l.dmKey!] = max(dmLatest[l.dmKey!] ?? -1, id);
    }
    // recent_private_conversations: the most recent conversations only
    // (message.py:1484, 1000 of them).
    final cap = options.dmListCap;
    if (cap != null && dmLatest.length > cap) {
      final keep = (dmLatest.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
        .take(cap).map((e) => e.key).toSet();
      dmLatest.removeWhere((k, _) => !keep.contains(k));
    }
    return RegisterSnapshot(version: version, maxMessageId: maxId,
      subscribed: {...subscribed}, privateChannels: {...privateChannels},
      protectedHistory: {...protectedHistory}, groupAccess: {...groupAccess},
      guest: guest, dmLatest: dmLatest);
  }

  /// Up to [n] events, or null for `BAD_EVENT_QUEUE_ID`.
  List<Ev>? poll(int n) {
    if (!queueAlive) return null;
    final take = min(n, pending.length);
    final result = pending.sublist(0, take);
    pending.removeRange(0, take);
    for (final e in result) {
      toldSelf.addAll(switch (e) {
        MessageEv(:final id) => [id],
        DeleteEv(:final ids) => ids,
        MoveEv(:final move) => move.messageIds,
        _ => const <int>[],
      });
    }
    return result;
  }

  /// `GET /messages`: fetch_messages, limit_query_to_range and
  /// post_process_limited_query (narrow.py:1238-1410, :1434-1621),
  /// line for line, at the current version.
  FetchResult processFetch(FetchRequest req) {
    final key = req.key;
    final g = _global;
    final c = _channelOfKey(key);
    if (c != null && !contentAccessIn(c, g)) {
      // access_narrow (:1446-1458): empty, both found, anchor newest.
      return FetchResult(messages: [], anchor: kNewestMessageId,
        foundOldest: true, foundNewest: true, historyLimited: false, version: version);
    }
    // The query before range limits: every accessible member, ignoring the
    // plan history limit, which post-processing applies (:1353-1356).
    final query = [
      for (final id in allIds)
        if (messages[id] case final l? when isMemberAt(key, id, l, g, ignoreFirstVisible: true))
          id,
    ];
    final fv = g.firstVisible;
    final anchor = req.anchor;
    final includeAnchor = req.includeAnchor;
    final numBefore = req.numBefore;
    var numAfter = req.numAfter;
    final anchoredToLeft = anchor == 0; // :1550
    final anchoredToRight = anchor >= kNewestMessageId; // :1554
    if (anchoredToRight) numAfter = 0; // :1555-1556

    // limit_query_to_range (:1238-1321).
    final needBeforeQuery = !anchoredToLeft && numBefore > 0;
    final needAfterQuery = !anchoredToRight && numAfter > 0;
    final needBothSides = needBeforeQuery && needAfterQuery;
    late int beforeAnchor, afterAnchor, beforeLimit, afterLimit;
    if (needBothSides) {
      beforeAnchor = anchor - 1;
      afterAnchor = max(anchor, fv);
      beforeLimit = numBefore;
      afterLimit = numAfter + 1;
    } else if (needBeforeQuery) {
      beforeAnchor = anchor - (includeAnchor ? 0 : 1);
      beforeLimit = numBefore;
      if (!anchoredToRight) beforeLimit += includeAnchor ? 1 : 0;
    } else if (needAfterQuery) {
      afterAnchor = max(anchor + (includeAnchor ? 0 : 1), fv);
      afterLimit = numAfter + (includeAnchor ? 1 : 0);
    }
    final rows = <int>[];
    if (needBeforeQuery) {
      var beforeQuery = query;
      if (!anchoredToRight) beforeQuery = [for (final id in beforeQuery) if (id <= beforeAnchor) id];
      rows.addAll(beforeQuery.reversed.take(beforeLimit)); // order_by(-id)[:limit]
    }
    if (needAfterQuery) {
      var afterQuery = query;
      // :1301: not filtered when anchored to the left.
      if (!anchoredToLeft) afterQuery = [for (final id in afterQuery) if (id >= afterAnchor) id];
      rows.addAll(afterQuery.take(afterLimit));
    }
    if (!needBeforeQuery && !needAfterQuery) {
      rows.addAll(query.where((id) => id == anchor)); // :1321
    }
    rows.sort(); // :1582

    // post_process_limited_query (:1336-1410).
    final visibleRows = fv > 0 ? [for (final id in rows) if (id >= fv) id] : rows;
    final rowsLimited = visibleRows.length != rows.length;
    var beforeRows = <int>[];
    final anchorRows = <int>[];
    var afterRows = <int>[];
    if (anchoredToRight) {
      numAfter = 0;
      beforeRows = [...visibleRows];
    } else {
      for (final id in visibleRows) {
        if (id < anchor) {
          beforeRows.add(id);
        } else if (id == anchor) {
          anchorRows.add(id);
        } else {
          afterRows.add(id);
        }
      }
    }
    if (numBefore > 0) beforeRows = beforeRows.sublist(max(0, beforeRows.length - numBefore));
    if (numAfter > 0) afterRows = afterRows.take(numAfter).toList();
    final limitedRows = [...beforeRows, ...anchorRows, ...afterRows];
    final foundOldest = anchoredToLeft || beforeRows.length < numBefore;
    final foundNewest = anchoredToRight || afterRows.length < numAfter;
    final historyLimited = rowsLimited && foundOldest;
    return FetchResult(
      messages: [for (final id in limitedRows) (id, messages[id]!)],
      anchor: anchor,
      foundOldest: foundOldest,
      foundNewest: foundNewest,
      historyLimited: historyLimited,
      version: version);
  }

  static int? _channelOfKey(String key) {
    if (!key.startsWith('channel:') && !key.startsWith('topic:')) return null;
    return int.parse(key.split(':')[1]);
  }

  //
  // Truth over time, for the checker.
  //

  /// Self's membership of message [id] at [loc] in the narrow of [key]:
  /// the truth's own reading of the key, with its own topic fold.
  bool isMemberAt(String key, int id, TLoc loc, TGlobal g, {bool ignoreFirstVisible = false}) {
    if (!ignoreFirstVisible && id < g.firstVisible) return false;
    if (key == 'dms') return loc.isDm;
    if (key.startsWith('dm:')) return loc.dmKey == key;
    if (loc.isDm) return false;
    final (c, topicFold) = _parsed[key] ??= _parse(key);
    if (loc.channelId != c || !_access(c, loc, g)) return false;
    if (topicFold != null) return fold(loc.topic!) == topicFold;
    return true;
  }

  final Map<String, (int, String?)> _parsed = {};

  (int, String?) _parse(String key) {
    final parts = key.split(':');
    final c = int.parse(parts[1]);
    return switch (parts[0]) {
      'topic' => (c, fold(parts.sublist(2).join(':'))),
      'channel' => (c, null),
      _ => throw ArgumentError(key),
    };
  }

  TLoc? _locAt(int id, int v) {
    TLoc? result;
    for (final (ver, loc) in _history[id] ?? const <(int, TLoc?)>[]) {
      if (ver > v) break;
      result = loc;
    }
    return result;
  }

  /// The index of the last global state with version <= [v] (at least 0).
  int _globalIndexAt(int v) {
    var lo = 0, hi = _globalHistory.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_globalHistory[mid].$1 <= v) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  TGlobal _globalAt(int v) => _globalHistory[_globalIndexAt(v)].$2;

  bool memberAt(String key, int id, int v, {bool ignoreFirstVisible = false}) {
    final loc = _locAt(id, v);
    return loc != null
      && isMemberAt(key, id, loc, _globalAt(v), ignoreFirstVisible: ignoreFirstVisible);
  }

  /// The versions in `[from, to]` at which [id]'s membership may change.
  Iterable<int> _changePoints(int id, int from, int to) sync* {
    yield from;
    for (final (ver, _) in _history[id] ?? const <(int, TLoc?)>[]) {
      if (ver > from && ver <= to) yield ver;
    }
    for (var i = _globalIndexAt(from) + 1; i < _globalHistory.length; i++) {
      final ver = _globalHistory[i].$1;
      if (ver > to) break;
      if (ver > from) yield ver;
    }
  }

  bool memberThroughout(String key, int id, int from, int to) =>
    _changePoints(id, from, to).every((v) => memberAt(key, id, v));

  bool memberSometime(String key, int id, int from, int to, {bool ignoreFirstVisible = false}) =>
    _changePoints(id, from, to).any((v) =>
      memberAt(key, id, v, ignoreFirstVisible: ignoreFirstVisible));
}

/// A stored message on the client.
final class CRow {
  CRow(this.id, {this.dmKey, this.channelId, this.topic,
    required this.epoch, required this.tracked});

  final int id;
  final String? dmKey;
  int? channelId;
  String? topic;
  int epoch;
  bool tracked;

  List<String> get keys =>
    CoverageKeys.ofLocation(dmKey: dmKey, channelId: channelId, topic: topic);

  /// Whether this row matches the predicate of [key].
  bool matches(String key) {
    if (key == CoverageKeys.dms) return dmKey != null;
    if (key.startsWith('dm:')) return dmKey == key;
    if (dmKey != null) return false;
    if (key.startsWith('topic:')) return _topicKey(channelId!, topic!) == key;
    return key == _channelKey(channelId!);
  }

  // Caches, for the model's speed only.
  static final Map<(int, String), String> _topicKeys = {};
  static final Map<int, String> _channelKeys = {};
  static String _topicKey(int c, String t) =>
    _topicKeys[(c, t)] ??= CoverageKeys.topic(c, t);
  static String _channelKey(int c) => _channelKeys[c] ??= CoverageKeys.channel(c);
}

final class Ticket {
  Ticket(this.req, {
    required this.mark,
    required this.epoch,
    required this.gens,
    required this.knownMaxAtSend,
    required this.sentClock,
    required this.anchorKnownVisible,
    required this.dropGeneration,
  });

  final int? dropGeneration;

  final FetchRequest req;
  final int mark;
  final int epoch;
  final Map<int, int> gens;
  final int knownMaxAtSend;
  final int sentClock;
  final bool anchorKnownVisible;
  bool alive = true;
  FetchResult? result;

  @override
  String toString() => '$req (mark $mark, e$epoch)';
}

/// The fragmentation cap the model's client uses by default.
int debugMaxIntervalsPerKey = 16;

/// The client: stored messages and coverage.
class ModelClient {
  ModelClient({int? cap}) : cap = cap ?? debugMaxIntervalsPerKey;

  final int cap;
  late MessageCoverage cov;
  bool registered = false;

  final Map<int, CRow> rows = {};
  Set<int> subscribed = {};
  Set<int> knownPrivate = {12, 13};
  Set<int> knownProtected = {13};
  Set<int> groupAccess = {};
  bool isGuest = false;
  final Map<int, int> gen = {for (final c in TruthServer.channels) c: 0};

  int seq = 0;
  final List<(int, Ev)> log = [];
  final List<(int, int)> purgeLog = [];

  /// The server version of the last applied event or register: what the client knows.
  int clock = 0;
  int lastLiveClock = 0;

  final Set<int> deletedApplied = {};
  int knownMax = -1;
  final Set<int> seenIds = {};
  Map<String, int> dmLatest = {};

  /// The conversations `recent_private_conversations` listed at this epoch's register.
  Set<String> dmListed = {};

  /// The latest id the DM gap bridge may use for [key], if any.
  int? bridgeLatest(String key) {
    if (!dmListed.contains(key)
        && isCoverageCorrected(CoverageCorrection.bridgeOnlyListedConversations)) {
      if (dmLatest.containsKey(key)) _count('reach: bridge refused for an unlisted conversation');
      return null;
    }
    return dmLatest[key];
  }

  /// Set when the client handled a fetch for a key (for the forget-ahead demo).
  final List<String> notes = [];

  //
  // Ghost state, for the checker only; the client's rules never read it.
  //

  /// All ids the server ever assigned (set by the run).
  Iterable<int> Function() ghostIds = () => const [];

  /// Per id: the server version as of which the client last took in
  /// the message's location (fetch snapshot, or applied event).
  final Map<int, int> learnedAt = {};

  /// Per id: the same, from fetches only. An event tells where a message is,
  /// not whether the plan history limit hides it; only a fetch shows that.
  final Map<int, int> fetchedAt = {};

  /// Per key and id: the server version of the fetch snapshot at which
  /// the client last learned that the id is not a member of the key.
  final Map<String, Map<int, int>> learnedAbsent = {};

  /// The client's copy of [id] now reflects the server at version [v]
  /// (which may be older than what it knew: an event still queued behind a fetch).
  /// Per id: the client's clock when it last took in a copy (from a fetch or event).
  final Map<int, int> tookInAt = {};

  void _tookIn(int id, int v, {int? snapshot}) {
    learnedAt[id] = v;
    tookInAt[id] = clock;
    if (snapshot != null) {
      fetchedAt[id] = snapshot; // visibility is known as of the snapshot only
    } else {
      fetchedAt.remove(id);
    }
    for (final m in learnedAbsent.values) {
      m.remove(id);
    }
  }

  /// The latest server version as of which the client knew whether [id]
  /// is a member of [key], or -1.
  int learned(String key, int id, {bool fetchOnly = false}) {
    var l = (fetchOnly ? fetchedAt[id] : learnedAt[id]) ?? -1;
    for (final k in _ghostContaining(key)) {
      l = max(l, learnedAbsent[k]?[id] ?? -1);
    }
    return l;
  }

  /// [key] and the key containing it on the server, written independently
  /// of [CoverageKeys.sources]: absence from a channel proves absence
  /// from its topics, and absence from all DMs from each conversation.
  static List<String> _ghostContaining(String key) => _containing[key] ??= switch (key) {
    _ when key.startsWith('topic:') => [key, 'channel:${key.split(':')[1]}'],
    _ when key.startsWith('dm:') => [key, 'dms'],
    _ => [key],
  };
  static final Map<String, List<String>> _containing = {};

  /// Self's content access to [c], from what the client knows (channel.dart:233-242).
  bool hasAccess(int c) {
    if (!knownPrivate.contains(c)) return !isGuest || subscribed.contains(c);
    return subscribed.contains(c) || (!isGuest && groupAccess.contains(c));
  }

  bool isProtectedChannel(int c) => knownPrivate.contains(c) && knownProtected.contains(c);

  bool _hasData(int c) => rows.values.any((r) => r.channelId == c)
    || cov.keys.any((k) => CoverageKeys.channelIdOf(k) == c);

  /// Post-event access hook.
  void _accessHook(int c, {required bool wasProtected}) {
    if (!hasAccess(c)) {
      if (_hasData(c)) _count('reach: access loss purges data');
      _purge(c);
      cov.dropChannel(c);
      return;
    }
    if (wasProtected != isProtectedChannel(c)) {
      if (_hasData(c)) _count('reach: history regime change drops data');
      cov.dropChannel(c);
      if (isProtectedChannel(c)) _purge(c);
    }
  }

  void register(RegisterSnapshot snap) {
    _count('registers');
    if (!registered) {
      cov = MessageCoverage(epoch: 0, maxIntervalsPerKey: cap);
      registered = true;
    } else {
      var precursor = false;
      for (final k in cov.keys) {
        for (final r in cov.intervalsOf(k)) {
          if (!r.isOpen && cov.isContinuous(r) && r.top > cov.eventHighWater) precursor = true;
        }
      }
      if (precursor) _count('reach: C6 precursor at an epoch end');
    }
    if (isCoverageCorrected(CoverageCorrection.dropDeletedDmRowsAtRegister)) {
      rows.removeWhere((id, r) => r.dmKey != null
        && (id > snap.maxMessageId || id > (snap.dmLatest[r.dmKey] ?? kNewestMessageId)));
    }
    if (snap.dmLatest.length < TruthServer.dmKeys.length
        && rows.values.any((r) => r.dmKey != null && !snap.dmLatest.containsKey(r.dmKey))) {
      _count('reach: stored DM conversation unlisted at register');
    }
    final unclippedClosed = <(String, CoverageInterval)>[];
    if (!isCoverageCorrected(CoverageCorrection.clipContinuousAtHighWater)) {
      for (final k in cov.keys) {
        for (final r in cov.intervalsOf(k)) {
          if (!r.isOpen && cov.isContinuous(r) && r.top > cov.eventHighWater) {
            unclippedClosed.add((k, CoverageInterval(r.lo, r.hi,
              epoch: r.epoch, tracked: r.tracked, verifiedAt: lastLiveClock)));
          }
        }
      }
    }
    cov.beginEpoch(maxMessageId: snap.maxMessageId, lastLiveAt: lastLiveClock, now: snap.version);
    for (final (k, saved) in unclippedClosed) {
      cov.insert(k, saved);
    }
    // Epoch-start access check against the fresh snapshot.
    final withData = {
      for (final r in rows.values) ?r.channelId,
      for (final k in cov.keys) ?CoverageKeys.channelIdOf(k),
    };
    final wasProtected = {for (final c in TruthServer.channels) c: isProtectedChannel(c)};
    subscribed = {...snap.subscribed};
    knownPrivate = {...snap.privateChannels};
    knownProtected = {...snap.protectedHistory};
    groupAccess = {...snap.groupAccess};
    isGuest = snap.guest;
    for (final c in withData) {
      _accessHook(c, wasProtected: wasProtected[c]!);
    }
    for (final c in gen.keys) {
      gen[c] = gen[c]! + 1;
    }
    clock = snap.version;
    lastLiveClock = clock;
    dmLatest = {...snap.dmLatest};
    dmListed = {...snap.dmLatest.keys};
    knownMax = max(knownMax, snap.maxMessageId);
  }

  void _purge(int c) {
    rows.removeWhere((_, r) => r.channelId == c);
    purgeLog.add((seq, c));
  }

  void apply(Ev e) {
    seq++;
    log.add((seq, e));
    clock = e.version;
    lastLiveClock = clock;
    switch (e) {
      case MessageEv(:final id, :final loc):
        _tookIn(id, e.version);
        final knownMaxBefore = knownMax;
        knownMax = max(knownMax, id);
        seenIds.add(id);
        if (!loc.isDm && !subscribed.contains(loc.channelId)) {
          _count('reach: message event while unsubscribed');
        }
        if (!loc.isDm && !hasAccess(loc.channelId!)) {
          _count('reach: message event without access');
          if (isCoverageCorrected(CoverageCorrection.noRowWithoutAccess)) {
            cov.handleMessageEvent(messageId: id, dmKey: null, channelId: loc.channelId,
              subscribed: false, now: clock);
            break;
          }
        }
        final tracked = loc.isDm || subscribed.contains(loc.channelId);
        rows[id] = CRow(id, dmKey: loc.dmKey, channelId: loc.channelId, topic: loc.topic,
          epoch: cov.epoch, tracked: tracked);
        cov.handleMessageEvent(messageId: id, dmKey: loc.dmKey, channelId: loc.channelId,
          subscribed: tracked, now: clock,
          largestKnownIdBefore: isCoverageCorrected(CoverageCorrection.impliedStartAboveHighWater)
            ? knownMaxBefore : -1);
        if (loc.isDm) dmLatest[loc.dmKey!] = max(dmLatest[loc.dmKey!] ?? -1, id);

      case DeleteEv(:final ids, :final accessKept):
        knownMax = max(knownMax, ids.reduce(max));
        for (final id in ids) {
          rows.remove(id);
          if (accessKept) {
            // The client now believes something false (R-1): it knows nothing.
            learnedAt.remove(id);
            fetchedAt.remove(id);
            for (final m in learnedAbsent.values) {
              m.remove(id);
            }
          } else {
            _tookIn(id, e.version);
          }
        }
        deletedApplied.addAll(ids);

      case MoveEv(:final move):
        knownMax = max(knownMax, move.messageIds.reduce(max));
        final unstored = move.messageIds.where((id) => !rows.containsKey(id)).toList();
        for (final key in move.destinationKeys) {
          for (final r in cov.intervalsOf(key)) {
            if (!cov.isContinuous(r)) continue;
            if (!unstored.any((id) => id > r.lo && id < r.top)) continue;
            final kind = key.startsWith('topic:')
              ? (move.newChannelId == move.origChannelId ? 'topic, same-channel rename' : 'topic, cross-channel')
              : 'channel';
            _count('reach: move strictly inside a live interval ($kind)');
          }
        }
        for (final id in move.messageIds) {
          final row = rows[id];
          // An unstored id only punctures the destination keys:
          // the client doesn't take in its location, so nothing is learned.
          if (row == null) continue;
          if (row.channelId != move.origChannelId
              || serverTopicFold(row.topic!) != serverTopicFold(move.origTopic)) {
            _count('reach: move event from another location than the stored row');
            if (isCoverageCorrected(CoverageCorrection.forgetRowMovedFromElsewhere)) {
              rows.remove(id);
              learnedAt.remove(id);
              fetchedAt.remove(id);
              // Every key of the destination: the channel too, even if unchanged.
              cov.punctureAt(CoverageKeys.ofLocation(
                channelId: move.newChannelId, topic: move.newTopic), id);
              continue;
            }
          }
          _tookIn(id, e.version);
          row.channelId = move.newChannelId;
          row.topic = move.newTopic;
          if (!subscribed.contains(move.newChannelId)) row.tracked = false;
        }
        cov.handleMove(move, isStored: rows.containsKey);
        _count('move events');

      case SubAddEv(:final channelId, :final isPrivate, :final isProtected):
        final wasProtected = isProtectedChannel(channelId);
        subscribed.add(channelId);
        gen[channelId] = gen[channelId]! + 1;
        _setPrivacy(channelId, isPrivate: isPrivate, isProtected: isProtected);
        _accessHook(channelId, wasProtected: wasProtected);

      case SubRemoveEv(:final channelId):
        gen[channelId] = gen[channelId]! + 1;
        subscribed.remove(channelId);
        for (final r in rows.values) {
          if (r.channelId == channelId) r.tracked = false;
        }
        final unclippedChannel = <(String, CoverageInterval)>[];
        if (!isCoverageCorrected(CoverageCorrection.clipContinuousAtHighWater)) {
          for (final k in cov.keys) {
            if (CoverageKeys.channelIdOf(k) != channelId) continue;
            for (final r in cov.intervalsOf(k)) {
              if (!r.isOpen && cov.isContinuous(r) && r.top > cov.eventHighWater) {
                unclippedChannel.add((k, CoverageInterval(r.lo, r.hi,
                  epoch: r.epoch, tracked: false, verifiedAt: clock)));
              }
            }
          }
        }
        cov.untrackChannel(channelId, now: clock);
        for (final (k, saved) in unclippedChannel) {
          cov.insert(k, saved);
        }
        _accessHook(channelId, wasProtected: isProtectedChannel(channelId));

      case StreamUpdateEv(:final channelId, :final isPrivate, :final isProtected):
        gen[channelId] = gen[channelId]! + 1;
        final wasProtected = isProtectedChannel(channelId);
        _setPrivacy(channelId, isPrivate: isPrivate, isProtected: isProtected);
        _accessHook(channelId, wasProtected: wasProtected);

      case GroupAccessEv(:final channelId, :final hasAccess):
        gen[channelId] = gen[channelId]! + 1;
        if (hasAccess) {
          groupAccess.add(channelId);
        } else {
          groupAccess.remove(channelId);
        }
        _accessHook(channelId, wasProtected: isProtectedChannel(channelId));
    }
  }

  void _setPrivacy(int c, {required bool isPrivate, required bool isProtected}) {
    if (isPrivate) {
      knownPrivate.add(c);
    } else {
      knownPrivate.remove(c);
    }
    if (isProtected) {
      knownProtected.add(c);
    } else {
      knownProtected.remove(c);
    }
  }

  /// Returns false on `BAD_EVENT_QUEUE_ID` (the caller re-registers).
  bool poll(TruthServer server, int n) {
    final evs = server.poll(n);
    if (evs == null) return false;
    for (final e in evs) {
      apply(e);
    }
    cov.confirm();
    return true;
  }

  void restart(List<Ticket> tickets) {
    for (final t in tickets) {
      t.alive = false;
    }
    cov.markUnconfirmed();
  }

  void evict(int cutoff) {
    rows.removeWhere((id, _) => id < cutoff);
    cov.clipBelow(cutoff);
  }

  Ticket send(FetchRequest req) => Ticket(req,
    mark: seq, epoch: cov.epoch, gens: {...gen}, knownMaxAtSend: knownMax,
    sentClock: clock, anchorKnownVisible: seenIds.contains(req.anchor),
    dropGeneration: switch (CoverageKeys.channelIdOf(req.key)) {
      final c? => cov.dropGeneration(c),
      null => null,
    });

  /// `handleFetchedMessages`, in memory.
  void handleFetch(Ticket t) {
    if (!t.alive) return;
    if (t.epoch != cov.epoch) {
      _count('reach: fetch handled across a re-register');
      if (isCoverageCorrected(CoverageCorrection.discardOldEpochFetches)) return;
    }
    final res = t.result!;
    final req = t.req;
    final key = req.key;
    final later = [for (final (s, e) in log) if (s > t.mark) e];
    final removed = {for (final e in later) if (e is DeleteEv) ...e.ids};
    final purged = {for (final (s, c) in purgeLog) if (s > t.mark) c};
    final laterMoves = [for (final e in later) if (e is MoveEv) e];
    final resultIds = res.ids.toSet();
    if (removed.any(resultIds.contains)) _count('reach: delete races a fetched id');
    if (laterMoves.any((e) => e.move.messageIds.any(resultIds.contains))) {
      _count('reach: move races a fetched id');
    }

    bool trackedFor(int? c) => c == null
      || (subscribed.contains(c) && gen[c] == t.gens[c]);

    // Steps 2-4: drop removed, reconcile, re-apply later moves.
    for (final (id, loc) in res.messages) {
      seenIds.add(id);
      knownMax = max(knownMax, id);
      if (removed.contains(id)) continue;
      var c = loc.channelId;
      var topic = loc.topic;
      var asOf = res.version;
      for (final e in laterMoves) {
        final m = e.move;
        if (!m.messageIds.contains(id)) continue;
        if (c != m.origChannelId || serverTopicFold(topic!) != serverTopicFold(m.origTopic)) {
          _count('reach: after-mark move of a fetched copy not at its origin');
          if (isCoverageCorrected(CoverageCorrection.reapplyMoveOnlyAtItsOrigin)) {
            continue;
          }
        }
        c = m.newChannelId;
        topic = m.newTopic;
        if (e.version <= res.version
            && isCoverageCorrected(CoverageCorrection.reapplyMoveOnlyAtItsOrigin)) {
          // Ghost: the snapshot already had this move and a later one back to
          // its origin (A→B→A), whose event is still queued; the copy now
          // reflects the server as of this move. The client can't tell (R-6).
          _count('reach: R-6 move re-applied after a move back (ABA)');
          asOf = e.version;
        } else {
          asOf = max(asOf, e.version);
        }
      }
      if (c != null && purged.contains(c)) continue;
      if (id < cov.evictedBelow) continue;
      final tracked = trackedFor(c);
      // I4 allows a deleted id back when a later server response includes it
      // (a `delete_message` also reports access loss by a move).
      deletedApplied.remove(id);
      // The client takes this copy in: what it knew of the id before is superseded,
      // even if that was newer (responses can be handled out of snapshot order).
      _tookIn(id, asOf, snapshot: min(asOf, res.version));
      final existing = rows[id];
      if (existing == null) {
        rows[id] = CRow(id, dmKey: loc.dmKey, channelId: c, topic: topic,
          epoch: t.epoch, tracked: tracked);
      } else if (!(existing.epoch == cov.epoch && existing.tracked) || !cov.confirmed) {
        existing
          ..channelId = c
          ..topic = topic
          ..epoch = t.epoch
          ..tracked = tracked;
      } else if (existing.channelId != c || existing.topic != topic) {
        // A live copy whose location differs from the fetched one's
        // (with later moves re-applied) missed a move.
        _count('reach: live copy at another location than fetched');
        if (isCoverageCorrected(CoverageCorrection.relocateLiveCopyOnFetch)) {
          existing
            ..channelId = c
            ..topic = topic
            ..tracked = existing.tracked && tracked;
        }
      }
    }

    // Step 5.
    final c = CoverageKeys.channelIdOf(key);
    if (c != null && cov.dropGeneration(c) != t.dropGeneration
        && isCoverageCorrected(CoverageCorrection.noCoverageAcrossChannelDrop)) {
      _count('fetches stopped by a channel drop');
      return;
    }
    if (c != null && !hasAccess(c)
        && res.messages.isEmpty && res.foundOldest && res.foundNewest) {
      return;
    }
    if (key.startsWith('topic:') && res.messages.any((m) =>
        m.$2.channelId != c || CoverageKeys.topic(c!, m.$2.topic!) != key)) {
      // The client's fold disagrees with the server's matching.
      _count('reach: fetch stopped by a topic fold mismatch');
      return;
    }

    // Step 6.
    final continuous = t.epoch == cov.epoch;
    final tracked = c == null || trackedFor(c);
    final anchorBoundsCorrected = isCoverageCorrected(CoverageCorrection.anchorBoundsOnlyIfKnown);
    final effectiveContinuous = continuous
      || !isCoverageCorrected(CoverageCorrection.openOnlyIfContinuous);
    final effectiveKnownMax = anchorBoundsCorrected
      ? t.knownMaxAtSend : max(t.knownMaxAtSend, res.anchor);
    final effectiveAnchorKnownVisible = !anchorBoundsCorrected || (
      isCoverageCorrected(CoverageCorrection.anchorVisibleOnlyIfReturned)
        ? resultIds.contains(res.anchor)
        : t.anchorKnownVisible);
    List<FetchBounds> intervals;
    if (!isCoverageCorrected(CoverageCorrection.oldestAnchorLimitedNotNewest)
        && res.foundNewest && res.anchor == 0 && res.historyLimited) {
      intervals = res.ids.isEmpty
        ? const []
        : [(
            lo: res.ids.first,
            hi: (tracked && effectiveContinuous) ? null : max(res.ids.last, t.knownMaxAtSend),
          )];
    } else {
      intervals = MessageCoverage.fetchIntervals(
        anchor: res.anchor, numBefore: req.numBefore, numAfter: req.numAfter,
        includeAnchor: req.includeAnchor, ids: res.ids,
        foundOldest: res.foundOldest, foundNewest: res.foundNewest,
        historyLimited: res.historyLimited,
        tracked: tracked, continuous: effectiveContinuous,
        knownMaxAtSend: effectiveKnownMax,
        anchorKnownVisible: effectiveAnchorKnownVisible);
    }
    if (intervals.isEmpty) {
      _count('fetches without interval');
      return;
    }
    _count(continuous ? (tracked ? 'fetch intervals live' : 'fetch intervals untracked')
      : 'fetch intervals old epoch');
    if (intervals.length > 1) _count('fetches split by an unknown anchor');
    if (later.isNotEmpty) _count('fetches with racing events');
    bool inIntervals(int id) =>
      intervals.any((b) => id >= b.lo && id <= (b.hi ?? kNewestMessageId));

    // Step 7: forget stored members absent from the result.
    final named = {
      for (final e in later)
        ...switch (e) {
          MessageEv(:final id) => [id],
          MoveEv(:final move) => move.messageIds,
          _ => const <int>[],
        },
    };
    final forgotten = <int>{};
    for (final row in rows.values.toList()) {
      if (!row.matches(key)) continue;
      if (!inIntervals(row.id)) continue;
      if (resultIds.contains(row.id) || named.contains(row.id)) continue;
      rows.remove(row.id);
      forgotten.add(row.id);
      final others = MessageCoverage.forgetPunctureKeys(key, row.keys);
      if (others.any((k) => cov.intervalsOf(k).any((r) => r.contains(row.id)))) {
        _count('reach: forget punctures another key');
      }
      cov.forget(key, row.keys, row.id);
      _count('forgets');
      notes.add('forgot ${row.id} from $key');
    }
    // Ghost: the ids in the intervals that the result says are not members.
    // (Older than what it knew, if responses are handled out of snapshot order.)
    final absent = learnedAbsent[key] ??= {};
    for (final id in ghostIds()) {
      if (!inIntervals(id) || resultIds.contains(id) || named.contains(id)) continue;
      absent[id] = res.version;
      if (forgotten.contains(id)) {
        learnedAt.remove(id);
        fetchedAt.remove(id);
      }
    }

    // Steps 8-9.
    for (final bounds in intervals) {
      cov.recordFetch(key, bounds, epoch: t.epoch, tracked: tracked,
        verifiedAt: t.sentClock, movesAfterMark: [for (final e in laterMoves) e.move],
        isStored: rows.containsKey);
    }
  }
}

/// Counters across runs, to see that the model exercises the rules.
final modelStats = <String, int>{};
void _count(String what, [int n = 1]) => modelStats[what] = (modelStats[what] ?? 0) + n;

/// Coverage invariants, checked against the truth.
class Checker {
  Checker(this.server, this.client);

  final TruthServer server;
  final ModelClient client;

  /// Check I6 literally, against the truth as of the client's last applied event,
  /// instead of over the window from it to now.
  bool literalI6 = false;

  /// Topic names to query besides [TruthServer.topics].
  List<String> extraQueryTopics = [];

  /// Per id, the lowest version among the events still queued that name it.
  Map<int, int> _pendingNaming = {};

  List<String> check() {
    final errors = <String>[];
    if (!client.registered) return errors;
    _pendingNaming = {};
    for (final e in server.pending) {
      for (final id in switch (e) {
        MessageEv(:final id) => [id],
        DeleteEv(:final ids) => ids,
        MoveEv(:final move) => move.messageIds,
        _ => const <int>[],
      }) {
        _pendingNaming[id] ??= e.version;
      }
    }
    final cov = client.cov;

    // I4: deletes are final.
    for (final id in client.deletedApplied) {
      if (client.rows.containsKey(id)) errors.add('I4: deleted $id is stored');
    }

    // I12: normal form.
    for (final key in cov.keys) {
      final list = cov.intervalsOf(key);
      if (list.length > cov.maxIntervalsPerKey) errors.add('I12: $key has ${list.length}');
      for (var i = 0; i < list.length; i++) {
        final r = list[i];
        if (r.lo > r.top) errors.add('I12: empty $r in $key');
        if (r.lo < cov.evictedBelow) errors.add('I12: $r in $key below eviction');
        if (r.isOpen && !cov.isContinuous(r)) errors.add('I12: open stale $r in $key');
        if (r.isOpen && i != list.length - 1) errors.add('I12: open not highest in $key');
        if (i > 0 && list[i - 1].top >= r.lo) errors.add('I12: overlap in $key');
      }
    }

    // I14: no data of a channel without content access, once the client has
    // applied the change (a fetch may report an access gain before its event).
    for (final c in TruthServer.channels) {
      if (server.contentAccessNow(c)) continue;
      if ((server.lastAccessChange[c] ?? 0) > client.clock) continue;
      if (client.rows.values.any((r) => r.channelId == c)) errors.add('I14: rows of $c');
      if (cov.keys.any((k) => CoverageKeys.channelIdOf(k) == c)) errors.add('I14: keys of $c');
    }

    // I6 and I7, per key and per query chain.
    for (final key in cov.keys) {
      for (final r in cov.intervalsOf(key)) {
        _checkClaim(errors, key, r.lo, r.top, closed: !r.isOpen,
          continuous: cov.isContinuous(r), verifiedAt: r.verifiedAt, what: '$key $r');
      }
    }
    for (final key in _queryKeys()) {
      // An unlisted conversation gets no bridge.
      final latest = key.startsWith('dm:') ? client.bridgeLatest(key) : null;
      for (final chain in cov.chains(key, dmLatestKnownId: latest)) {
        for (final p in chain.pieces) {
          _checkClaim(errors, key, p.lo, p.top, closed: !p.sourceOpen,
            continuous: p.status != CoverageStatus.stale, verifiedAt: p.verifiedAt,
            source: p.source == 'bridge' ? null : p.source,
            what: 'query $key piece $p');
        }
      }
    }
    return errors;
  }

  Iterable<String> _queryKeys() sync* {
    yield CoverageKeys.dms;
    yield* TruthServer.dmKeys;
    for (final c in TruthServer.channels) {
      yield CoverageKeys.channel(c);
      yield* {
        for (final t in [...TruthServer.topics, ...extraQueryTopics]) CoverageKeys.topic(c, t),
      };
    }
  }

  /// The server version as of which the client's copy of [id] reflects
  /// whether it is a member of [key], or -1 if unknown.
  ///
  /// Not while the client still has to apply queued events older than that:
  /// applying them takes the copy back in time until it catches up.
  int _knownSince(String key, int id, {bool fetchOnly = false}) {
    final l = client.learned(key, id, fetchOnly: fetchOnly);
    if (l < 0) return -1;
    if ((_pendingNaming[id] ?? kNewestMessageId) <= l) return -1;
    return l;
  }

  /// Whether a change of [id]'s membership in [key] with no event to self
  /// (a residual) happened after the client last learned the truth.
  bool _excused(String key, int id) {
    final silent = server.silent[id];
    if (silent == null) return false;
    final known = _knownSince(key, id);
    final knownByFetch = _knownSince(key, id, fetchOnly: true);
    for (final (v, kind) in silent) {
      if (kind.startsWith('R-3 implied')) {
        if (v <= known) continue;
        if (server.memberSometime(key, id, v, server.version)) return true;
        continue;
      }
      if (kind.startsWith('R-4')) {
        // Hidden by the limit with no signal; only a fetch would show it.
        // From then on the client takes it for a member wherever it would be one.
        if (v <= knownByFetch) continue;
        if (server.memberSometime(key, id, v, server.version, ignoreFirstVisible: true)) {
          return true;
        }
        continue;
      }
      if (v <= known) continue;
      // A silent move or commit changes where the message is; whether the plan
      // history limit hides it then is another matter (a lift may reveal it later).
      // Until the client learns the location again, every key the message
      // visits from then on may be wrong about it: later delivered moves name
      // an origin the client doesn't know (and C11 then won't re-apply them).
      if (server.memberAt(key, id, v - 1, ignoreFirstVisible: true)
          != server.memberAt(key, id, v, ignoreFirstVisible: true)
          || server.memberSometime(key, id, v, server.version, ignoreFirstVisible: true)) {
        return true;
      }
    }
    return false;
  }

  /// A claim over `[lo, top]` of [key]:
  /// a message that was a member throughout the window is stored,
  /// and a stored member was a member at some point of the window.
  /// The window runs to now; it starts at the client's clock for continuous
  /// claims, and for stale ones at the later of [verifiedAt] and the version
  /// at which the client last learned the message's membership (ghost state).
  /// A closed stale claim also covers no id committed after the window began
  /// to a message that has been a member since and is not stored.
  /// (A continuous claim may: the message's event is still in the queue.)
  /// Ids whose membership changed silently since the client last learned it
  /// are excused, for the keys whose membership that change affected.
  void _checkClaim(List<String> errors, String key, int lo, int top, {
    required bool closed,
    required bool continuous,
    required int verifiedAt,
    String? source,
    required String what,
  }) {
    final to = server.version;
    final ids = server.allIds;
    var checked = 0, skipped = 0;
    // The first id at or above lo (ids are sorted).
    var i = 0, j = ids.length;
    while (i < j) {
      final mid = (i + j) >> 1;
      if (ids[mid] < lo) {
        i = mid + 1;
      } else {
        j = mid;
      }
    }
    for (; i < ids.length; i++) {
      final id = ids[i];
      if (id > top) break;
      // A piece taken from a containing key inherits that key's residuals.
      if (_excused(key, id) || (source != null && source != key && _excused(source, id))) {
        skipped++;
        continue;
      }
      checked++;
      // For a stale claim, the version the client's copy reflects, if known;
      // older than verifiedAt when a response with an older snapshot was handled
      // after the one that established the claim (R-7: no event repairs that
      // for an untracked conversation).
      final known = continuous ? -1 : _knownSince(key, id);
      final tookInAfterClaim = (client.tookInAt[id] ?? -1) >= verifiedAt;
      final from = continuous ? client.clock
        : known >= 0 && tookInAfterClaim ? known : max(verifiedAt, known);
      final row = client.rows[id];
      final stored = row != null && row.matches(key);
      if (literalI6 && continuous) {
        final member = server.memberAt(key, id, client.clock);
        if (member != stored) {
          errors.add('I6-literal: $what: $id ${member ? 'member' : 'not member'} '
            'at v${client.clock} but ${stored ? 'stored' : 'not stored'}');
        }
        continue;
      }
      if (!stored && server.memberThroughout(key, id, from, to)) {
        errors.add('${continuous ? 'I6' : 'I7'} gap: $what: $id member throughout '
          '[v$from, v$to] but not stored (row: ${row == null ? 'none' : '${row.keys}'})');
      }
      if (stored && !server.memberSometime(key, id, from, to)) {
        errors.add('${continuous ? 'I6' : 'I7'} extra: $what: $id stored but '
          'never a member in [v$from, v$to]');
      }
      final created = server.createdAt[id];
      if (!continuous && closed && !stored && created != null && created > from
          && server.memberThroughout(key, id, created, to)) {
        errors.add('I7 newer gap: $what: $id created at '
          'v$created after v$from, a member since, not stored');
      }
    }
    if (skipped > 0) _count('residual skips', skipped);
    _count(continuous ? 'continuous claims checked' : 'stale claims checked', checked);
  }
}

/// One seeded run: random server and client operations, checked after each.
class ModelRun {
  ModelRun(this.seed, {ModelOptions? options, int? cap, this.lossProfile})
    : rand = Random(seed) {
    final optionsRand = Random(seed * 7919 + 17);
    this.options = options ?? ModelOptions.random(optionsRand);
    server = TruthServer(options: this.options);
    client = ModelClient(cap: cap
      ?? (optionsRand.nextInt(7) == 0 ? 2 + optionsRand.nextInt(3) : null));
    client.ghostIds = () => server.allIds;
    checker = Checker(server, client);
    lossProfile ??= optionsRand.nextInt(3);
  }

  final int seed;
  final Random rand;
  late final ModelOptions options;
  late final TruthServer server;
  late final ModelClient client;
  late final Checker checker;

  /// 0: rare queue losses (long live intervals); 1: some; 2: frequent.
  int? lossProfile;

  final List<Ticket> tickets = [];
  final List<String> trace = [];

  T _pick<T>(List<T> list) => list[rand.nextInt(list.length)];

  String _randomTopic() =>
    rand.nextInt(3) == 0 ? _pick(['a', 'A']) : _pick(TruthServer.topics);

  /// Server history before the client registers.
  void warmup(int ops) {
    for (final c in TruthServer.channels) {
      if (rand.nextBool()) {
        server.subscribe(c);
        trace.add('server: subscribe $c');
      }
    }
    for (var i = 0; i < ops; i++) {
      _serverOp(warm: true);
    }
    if (rand.nextBool() && server.allIds.length > 4) {
      var id = server.allIds[rand.nextInt(server.allIds.length ~/ 2)];
      // Below every send in flight (see the rising limit in _serverOp).
      for (final p in server.pendingSends) {
        if (p.id != null) id = min(id, p.id!);
      }
      server.setFirstVisible(id);
      trace.add('server: history limit at $id');
    }
    client.register(server.register());
    trace.add('client: register (epoch ${client.cov.epoch})');
  }

  void _registerAfterLoss(String what) {
    client.register(server.register());
    trace.add('client: $what → BAD_EVENT_QUEUE_ID; register (epoch ${client.cov.epoch})');
  }

  void step() {
    final r = rand.nextInt(100);
    if (r < 40) {
      _serverOp(warm: false);
    } else if (r < 55) {
      final n = 1 + rand.nextInt(4);
      if (!client.poll(server, n)) {
        _registerAfterLoss('poll');
      } else {
        trace.add('client: poll ≤$n → through v${client.clock}');
      }
    } else if (r < 66) {
      final req = _randomRequest();
      final t = client.send(req);
      tickets.add(t);
      trace.add('client: send $t');
    } else if (r < 75) {
      final waiting = tickets.where((t) => t.result == null).toList();
      if (waiting.isEmpty) return;
      final t = _pick(waiting);
      if (!server.queueAlive || t.epoch != client.cov.epoch) {
        _count('reach: fetch processed after a queue loss');
      }
      t.result = server.processFetch(t.req);
      trace.add('server: process ${t.req} → ${t.result}');
    } else if (r < 85) {
      final done = tickets.where((t) => t.result != null).toList();
      if (done.isEmpty) return;
      final t = _pick(done);
      tickets.remove(t);
      client.handleFetch(t);
      trace.add('client: handle ${t.req}${t.alive ? '' : ' (dropped)'}');
    } else if (r < 89) {
      _raceOp();
    } else if (r < 91) {
      client.restart(tickets);
      tickets.clear();
      trace.add('client: restart (unconfirmed)');
    } else if (r < 92) {
      if (server.allIds.isEmpty) return;
      final cutoff = server.allIds[rand.nextInt(server.allIds.length)];
      client.evict(cutoff);
      trace.add('client: evict below $cutoff');
    } else {
      final lossPercent = const [3, 25, 60][lossProfile!];
      if (rand.nextInt(100) < lossPercent) {
        _loseQueue();
      } else {
        _serverOp(warm: false);
      }
    }
  }

  void _loseQueue() {
    if (server.queueAlive && server.pending.isNotEmpty) _count('reach: queue lost with events pending');
    if (tickets.any((t) => t.epoch == client.cov.epoch && t.alive)) {
      _count('reach: queue lost with a fetch in flight');
    }
    server.loseQueue();
    trace.add('server: queue lost');
  }

  /// A change racing a fetch: delete or move an id of a processed, unhandled result.
  void _raceOp() {
    final done = tickets.where((t) => t.result != null && t.result!.messages.isNotEmpty).toList();
    if (done.isEmpty) return _serverOp(warm: false);
    final t = _pick(done);
    final ids = [for (final id in t.result!.ids) if (server.messages.containsKey(id)) id];
    if (ids.isEmpty) return;
    final id = _pick(ids);
    if (rand.nextBool() || server.messages[id]!.isDm) {
      _delete([id], bySelf: false);
    } else {
      final o = server.messages[id]!.channelId!;
      final newC = rand.nextInt(3) < 2 ? o : _pick(TruthServer.channels);
      _move(id, _pick(Propagate.values), newC, _randomTopic(), what: 'race: ');
    }
  }

  void _delete(List<int> group, {required bool bySelf}) {
    server.delete(group, bySelf: bySelf);
    trace.add('server: ${bySelf ? 'self ' : ''}delete $group'
      '${server.pending.lastOrNull?.version == server.version ? '' : ' (no event)'}');
  }

  void _move(int target, Propagate mode, int newC, String topic, {String what = ''}) {
    if (server.move(target, mode, newC, topic)) {
      final silent = server.silent[target]?.lastOrNull?.$1 == server.version;
      trace.add('server: ${what}move ${mode.name} $target → #$newC>$topic'
        '${silent ? ' (silent: R-1)' : ''}');
    }
  }

  void _serverOp({required bool warm}) {
    final o = options;
    final r = rand.nextInt(100);
    if (o.outOfOrderCommits && server.pendingSends.isNotEmpty && rand.nextInt(10) < 4) {
      final p = _pick(server.pendingSends);
      if (p.id == null) {
        server.assignId(rand, p);
        trace.add('server: assign id ${p.id} to $p');
      } else {
        final id = server.commitSend(p);
        final kinds = [for (final (v, k) in server.silent[id] ?? const <(int, String)>[])
          if (v == server.version) k];
        if (kinds.isNotEmpty) _count('reach: ${kinds.join(', ')}');
        trace.add('server: commit $id ${server.messages[id]}${kinds.isEmpty ? '' : ' ($kinds)'}');
      }
      return;
    }
    if (r < 22) {
      final c = _pick(TruthServer.channels);
      final topic = _randomTopic();
      if (o.outOfOrderCommits && rand.nextInt(3) == 0) {
        final p = server.beginSend(rand, channelId: c, topic: topic, assignId: rand.nextBool());
        trace.add('server: begin send $p');
      } else {
        final id = server.sendChannel(rand, c, topic);
        trace.add('server: send $id to #$c>$topic');
      }
    } else if (r < 32) {
      final key = _pick(TruthServer.dmKeys);
      if (o.outOfOrderCommits && rand.nextInt(3) == 0) {
        final p = server.beginSend(rand, dmKey: key, assignId: rand.nextBool());
        trace.add('server: begin send $p');
      } else {
        final id = server.sendDm(rand, key);
        trace.add('server: send $id to $key');
      }
    } else if (r < 42) {
      if (server.messages.isEmpty) return;
      final stored = [for (final id in client.rows.keys) if (server.messages.containsKey(id)) id];
      final int id;
      final rr = rand.nextInt(10);
      if (o.selfActor && rr < 2) {
        final accessible = [for (final id in server.messages.keys) if (server.canAccess(id)) id];
        if (accessible.isEmpty) return;
        _delete([_pick(accessible)], bySelf: true);
        return;
      } else if (rr < 5 && stored.isNotEmpty) {
        id = _pick(stored); // often silent: an unsubscribed channel, no UM row
      } else {
        id = _pick(server.messages.keys.toList());
      }
      final l = server.messages[id]!;
      final group = [id];
      if (rand.nextBool()) {
        for (final MapEntry(key: other, value: ol) in server.messages.entries) {
          if (other != id && group.length < 3 && ol.dmKey == l.dmKey
              && ol.channelId == l.channelId && ol.topic == l.topic) {
            group.add(other);
          }
        }
      }
      _delete(group, bySelf: false);
    } else if (r < 52) {
      final channelMessages = [
        for (final MapEntry(key: id, value: l) in server.messages.entries)
          if (!l.isDm) id,
      ];
      if (channelMessages.isEmpty) return;
      final storedChannel = [for (final id in channelMessages) if (client.rows.containsKey(id)) id];
      final target = storedChannel.isNotEmpty && rand.nextInt(3) == 0
        ? _pick(storedChannel) : _pick(channelMessages);
      final mode = _pick(Propagate.values);
      final oc = server.messages[target]!.channelId!;
      final newC = rand.nextInt(5) < 3 ? oc : _pick(TruthServer.channels);
      _move(target, mode, newC, _randomTopic());
    } else if (r < 62) {
      if (!warm && _targetedMove()) return;
    } else if (r < 70) {
      final c = _pick(TruthServer.channels);
      if (server.subscribed.contains(c)) {
        server.unsubscribe(c);
        trace.add('server: unsubscribe $c');
      } else {
        server.subscribe(c);
        trace.add('server: subscribe $c');
      }
    } else if (r < 73) {
      final private = server.privateChannels.toList()..sort();
      if (private.isEmpty) return;
      final c = _pick(private);
      server.toggleHistory(c);
      trace.add('server: toggle history of $c → '
        '${server.isProtected(c) ? 'protected' : 'shared'}');
    } else if (r < 75) {
      if (!o.inviteOnlyChanges) return;
      final c = _pick(TruthServer.channels);
      server.toggleInviteOnly(c, protectedIfPrivate: rand.nextBool());
      _count('reach: invite_only change');
      trace.add('server: #$c now ${server.isPrivate(c) ? 'private' : 'public'}'
        '${server.isProtected(c) ? ' protected' : ''}');
    } else if (r < 77) {
      if (!o.groupAccess) return;
      final c = _pick(TruthServer.channels);
      server.toggleGroupAccess(c);
      _count('reach: group access change');
      trace.add('server: self ${server.groupAccess.contains(c) ? 'gains' : 'loses'} '
        'group content access to #$c');
    } else if (r < 80) {
      if (server.messages.isEmpty) return;
      final id = _pick(server.messages.keys.toList());
      if (server.react(id)) trace.add('server: self reacts to $id (historical UM)');
    } else if (r < 83) {
      if (server.firstVisible > 0) {
        final revealed = [
          for (final id in server.messages.keys) if (id < server.firstVisible) id,
        ];
        if (revealed.any((id) => client.learnedAbsent.values.any((m) => m.containsKey(id)))) {
          _count('reach: lift reveals ids a fetch found absent');
        }
        server.setFirstVisible(0);
        trace.add('server: history limit lifted');
      }
    } else if (r < 86) {
      if (!o.risingHistoryLimit || server.allIds.isEmpty) return;
      // The limit keeps the newest messages visible (message.py:1403-1443):
      // it stays below every send in flight and leaves a few messages above it.
      final inFlight = [for (final p in server.pendingSends) ?p.id];
      final committed = server.createdAt.keys.toList()..sort();
      if (committed.length < 4) return;
      final ceiling = min(committed[committed.length - 3],
        inFlight.isEmpty ? kNewestMessageId : inFlight.reduce(min));
      final candidates = [
        for (final id in server.allIds) if (id > server.firstVisible && id <= ceiling) id,
      ];
      if (candidates.isEmpty) return;
      final id = candidates[rand.nextInt(min(candidates.length, 6))];
      server.setFirstVisible(id);
      _count('reach: history limit advanced');
      trace.add('server: history limit advanced to $id (silent: R-4)');
    } else if (r < 88) {
      if (!warm) _loseQueue();
    } else {
      final c = _pick(TruthServer.channels);
      final topic = _randomTopic();
      final id = server.sendChannel(rand, c, topic);
      trace.add('server: send $id to #$c>$topic');
    }
  }

  /// A move into a key the client covers, of messages with ids inside
  /// one of its intervals: same-channel renames, resolves and change_later
  /// across covered ranges as well as cross-channel moves.
  bool _targetedMove() {
    if (!client.registered) return false;
    final cov = client.cov;
    final candidates = <(String, CoverageInterval)>[
      for (final key in cov.keys)
        if (!key.startsWith('dm'))
          for (final r in cov.intervalsOf(key))
            if (cov.isContinuous(r) || rand.nextInt(4) == 0) (key, r),
    ];
    if (candidates.isEmpty) return false;
    final (key, r) = _pick(candidates);
    final c = CoverageKeys.channelIdOf(key)!;
    final inside = [
      for (final MapEntry(key: id, value: l) in server.messages.entries)
        if (!l.isDm && id > r.lo && id < r.top
            && !(client.rows[id]?.matches(key) ?? false)
            && !(l.channelId == c && key.startsWith('topic:')
                 && CoverageKeys.topic(c, l.topic!) == key))
          id,
    ];
    if (inside.isEmpty) return false;
    // Mostly renames within the channel (resolve, rename, change_later), when the key is a topic.
    final sameChannel = [for (final id in inside) if (server.messages[id]!.channelId == c) id];
    final target = key.startsWith('topic:') && sameChannel.isNotEmpty && rand.nextInt(4) != 0
      ? _pick(sameChannel) : _pick(inside);
    final String topic;
    if (key.startsWith('topic:')) {
      final names = [
        for (final t in [...TruthServer.topics, '✔ a'])
          if (CoverageKeys.topic(c, t) == key) t,
      ];
      if (names.isEmpty) return false;
      topic = _pick(names);
    } else {
      topic = _randomTopic();
    }
    final mode = rand.nextInt(5) < 2 ? Propagate.changeLater : _pick(Propagate.values);
    _move(target, mode, c, topic, what: 'targeted ');
    return true;
  }

  String _randomKey() {
    if (client.registered && rand.nextInt(10) < 6) {
      final withData = {
        for (final k in client.cov.keys) if (k != CoverageKeys.dms) k,
        for (final row in client.rows.values) ...row.keys.where((k) => k != CoverageKeys.dms),
      }.toList()..sort();
      if (withData.isNotEmpty) return _pick(withData);
    }
    final r = rand.nextInt(10);
    if (r < 3) return _pick(TruthServer.dmKeys);
    if (r < 5) return CoverageKeys.channel(_pick(TruthServer.channels));
    return CoverageKeys.topic(_pick(TruthServer.channels), _randomTopic());
  }

  FetchRequest _randomRequest() {
    final key = _randomKey();
    final storedInKey = [for (final row in client.rows.values) if (row.matches(key)) row.id]..sort();
    final known = client.seenIds.toList()..sort();
    int someAnchor() {
      if (storedInKey.isNotEmpty && rand.nextBool()) return _pick(storedInKey);
      if (known.isNotEmpty && rand.nextBool()) return _pick(known);
      return server.allIds.isEmpty ? 0 : _pick(server.allIds) + rand.nextInt(2);
    }
    final r = rand.nextInt(100);
    if (r < 32) {
      // fetchInitial at newest (num_after is ignored there).
      return FetchRequest(key, anchor: kNewestMessageId,
        numBefore: 1 + rand.nextInt(4), numAfter: rand.nextInt(3), includeAnchor: true);
    } else if (r < 52) {
      // fetchInitial at a numeric anchor (or first unread, resolved).
      return FetchRequest(key, anchor: someAnchor(),
        numBefore: 1 + rand.nextInt(3), numAfter: 1 + rand.nextInt(3), includeAnchor: true);
    } else if (r < 69) {
      // fetchOlder.
      return FetchRequest(key, anchor: storedInKey.isNotEmpty ? storedInKey.first : someAnchor(),
        numBefore: 1 + rand.nextInt(3), numAfter: 0, includeAnchor: false);
    } else if (r < 86) {
      // fetchNewer (with include_anchor true, as C12 asks, or false, as today).
      return FetchRequest(key, anchor: storedInKey.isNotEmpty ? storedInKey.last : someAnchor(),
        numBefore: 0, numAfter: 1 + rand.nextInt(3), includeAnchor: rand.nextBool());
    } else if (r < 94) {
      // Other requests the API allows: anchor oldest, one-sided with the anchor.
      return FetchRequest(key, anchor: 0,
        numBefore: 0, numAfter: 1 + rand.nextInt(3), includeAnchor: rand.nextBool());
    } else {
      return FetchRequest(key, anchor: someAnchor(),
        numBefore: rand.nextInt(2), numAfter: rand.nextInt(2), includeAnchor: true);
    }
  }

  /// Runs [ops] steps after the warmup, checking after each; throws on a violation.
  void run({int warmupOps = 14, required int ops}) {
    _count('runs');
    warmup(warmupOps);
    _checkOrThrow();
    for (var i = 0; i < ops; i++) {
      step();
      _checkOrThrow();
    }
  }

  void _checkOrThrow() {
    final errors = checker.check();
    if (errors.isEmpty) return;
    throw ModelViolation(seed, options, client.cap, trace, errors);
  }
}

class ModelViolation implements Exception {
  ModelViolation(this.seed, this.options, this.cap, this.trace, this.errors);

  final int seed;
  final ModelOptions options;
  final int cap;
  final List<String> trace;
  final List<String> errors;

  @override
  String toString() => 'Coverage model violation, seed $seed, after ${trace.length} steps '
    '(options: $options; cap $cap):\n'
    '${errors.take(5).join('\n')}\n'
    'trace:\n${trace.map((s) => '  $s').join('\n')}';
}
