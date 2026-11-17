import 'dart:io';
import 'dart:math';

import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:zulip/model/message_coverage.dart';

import 'message_coverage_model.dart';

void main() {
  group('CoverageKeys', () {
    test('keys', () {
      check(CoverageKeys.dm([12, 3, 7])).equals('dm:3,7,12');
      check(CoverageKeys.channel(5)).equals('channel:5');
      check(CoverageKeys.topic(5, 'aBc')).equals('topic:5:ABC');
    });

    test('topic fold follows the server, not Dart lowercase', () {
      // Final sigma: equal under uppercase (the server's UPPER), not under lowercase.
      check(CoverageKeys.topic(1, 'τέλος')).equals(CoverageKeys.topic(1, 'ΤΈΛΟΣ'));
      check('τέλος'.toLowerCase()).not((it) => it.equals('ΤΈΛΟΣ'.toLowerCase()));
      // ß has no single-code-point uppercase: kept.
      check(serverTopicFold('straße')).equals('STRAßE');
    });

    test('sources and subkeys', () {
      check(CoverageKeys.sources('topic:5:A')).deepEquals(['topic:5:A', 'channel:5']);
      check(CoverageKeys.sources('dm:1,2')).deepEquals(['dm:1,2', 'dms']);
      check(CoverageKeys.sources('channel:5')).deepEquals(['channel:5']);
      check(CoverageKeys.isSubkey('topic:5:A', 'channel:5')).isTrue();
      check(CoverageKeys.isSubkey('topic:6:A', 'channel:5')).isFalse();
      check(CoverageKeys.isSubkey('dm:1,2', 'dms')).isTrue();
      check(CoverageKeys.isSubkey('channel:5', 'topic:5:A')).isFalse();
    });
  });

  group('interval algebra', () {
    CoverageInterval live(int lo, int? hi, {int verifiedAt = 0}) =>
      CoverageInterval(lo, hi, epoch: 1, tracked: true, verifiedAt: verifiedAt);
    CoverageInterval stale(int lo, int? hi, {int verifiedAt = 0}) =>
      CoverageInterval(lo, hi, epoch: 0, tracked: true, verifiedAt: verifiedAt);

    String show(MessageCoverage cov, String key) => cov.intervalsOf(key).join(' ');

    test('insert replaces overlaps of any status; merges same status only', () {
      final cov = MessageCoverage(epoch: 1);
      cov.insert('k', stale(10, 30));
      cov.insert('k', live(20, 25));
      check(show(cov, 'k')).equals(
        '[10, 19]@e0 v0 [20, 25]@e1 v0 [26, 30]@e0 v0');
      cov.insert('k', live(26, 40));
      check(show(cov, 'k')).equals('[10, 19]@e0 v0 [20, 40]@e1 v0');
      cov.insert('k', stale(0, 9, verifiedAt: 5));
      check(show(cov, 'k')).equals('[0, 19]@e0 v0 [20, 40]@e1 v0');
    });

    test('punctureSpan cuts one span per interval', () {
      final cov = MessageCoverage(epoch: 1);
      cov.insert('k', live(0, 50));
      cov.insert('k', live(60, null));
      cov.punctureSpan('k', [10, 12, 70, 300]);
      check(show(cov, 'k')).equals(
        '[0, 9]@e1 v0 [13, 50]@e1 v0 [60, 69]@e1 v0 [301, ∞]@e1 v0');
    });

    test('beginEpoch closes open intervals at the event high-water', () {
      final cov = MessageCoverage(epoch: 0);
      cov.beginEpoch(maxMessageId: 99, lastLiveAt: 0, now: 1);
      cov.insert('channel:1', live(150, null));
      cov.handleMessageEvent(messageId: 120, dmKey: 'dm:1,2', channelId: null,
        subscribed: true, now: 2);
      cov.handleMessageEvent(messageId: 160, dmKey: null, channelId: 1,
        subscribed: true, now: 3);
      cov.beginEpoch(maxMessageId: 300, lastLiveAt: 3, now: 4);
      check(show(cov, 'dms')).equals('[100, 160]@e1 v3 [301, ∞]@e2 v4');
      check(show(cov, 'channel:1')).equals('[150, 160]@e1 v3');
    });

    test('an open interval above the high-water is dropped at epoch end', () {
      final cov = MessageCoverage(epoch: 0);
      cov.beginEpoch(maxMessageId: 99, lastLiveAt: 0, now: 1);
      cov.beginEpoch(maxMessageId: 99, lastLiveAt: 1, now: 2);
      check(show(cov, 'dms')).equals('[100, ∞]@e2 v2');
    });

    test('untrackChannel closes and untracks the channel and its topics', () {
      final cov = MessageCoverage(epoch: 0);
      cov.beginEpoch(maxMessageId: 99, lastLiveAt: 0, now: 1);
      cov.handleMessageEvent(messageId: 105, dmKey: null, channelId: 1,
        subscribed: true, now: 2);
      cov.insert('topic:1:A', live(50, null));
      cov.insert('topic:2:A', live(50, null));
      cov.untrackChannel(1, now: 3);
      check(show(cov, 'channel:1')).equals('[105, 105]@e1 untracked v3');
      check(show(cov, 'topic:1:A')).equals('[50, 105]@e1 untracked v3');
      check(show(cov, 'topic:2:A')).equals('[50, ∞]@e1 v0');
    });

    test('the cap drops stale intervals with the lowest hi first', () {
      final cov = MessageCoverage(epoch: 1, maxIntervalsPerKey: 3);
      cov.insert('k', stale(0, 1));
      cov.insert('k', live(3, 4));
      cov.insert('k', stale(6, 7));
      cov.insert('k', live(9, 10));
      check(show(cov, 'k')).equals('[3, 4]@e1 v0 [6, 7]@e0 v0 [9, 10]@e1 v0');
    });

    test('chains: a topic is answered by its channel; best status wins', () {
      final cov = MessageCoverage(epoch: 1);
      cov.insert('topic:1:A', stale(0, 40));
      cov.insert('channel:1', live(30, null));
      final chain = cov.chainAt('topic:1:A', 10)!;
      check(chain.pieces.join(' ')).equals(
        '[0, 29] stale v0 (topic:1:A) [30, ∞] live v0 (channel:1)');
      check(chain.reachesOldest).isTrue();
      check(chain.isOpen).isTrue();
      check(cov.chainAt('topic:1:B', 10)).isNull();
      check(cov.chainAt('channel:1', 10)).isNull();
    });

    test('property: algebra agrees with explicit id sets', () {
      // Each claimed id carries its interval's tags; insert overwrites,
      // punctures erase. The algebra may claim less, never more or other tags.
      for (var seed = 0; seed < 300; seed++) {
        final rand = Random(seed);
        final cov = MessageCoverage(epoch: 1, maxIntervalsPerKey: 1000);
        final claimed = <int, (int, bool)>{};
        for (var i = 0; i < 30; i++) {
          final lo = rand.nextInt(60);
          final hi = lo + rand.nextInt(15);
          switch (rand.nextInt(3)) {
            case 0 || 1:
              final epoch = rand.nextInt(2);
              cov.insert('k', CoverageInterval(lo, hi, epoch: epoch, tracked: true, verifiedAt: 0));
              for (var x = lo; x <= hi; x++) {
                claimed[x] = (epoch, true);
              }
            case _:
              final ids = [for (var x = lo; x <= hi; x++) x];
              cov.punctureSpan('k', ids);
              for (var x = lo; x <= hi; x++) {
                claimed.remove(x);
              }
          }
          for (var x = 0; x < 80; x++) {
            final r = cov.intervalsOf('k').where((r) => r.contains(x)).firstOrNull;
            final status = r == null ? null : cov.statusOf(r);
            final expected = claimed[x] == null ? null
              : (claimed[x]!.$1 == 1 ? CoverageStatus.live : CoverageStatus.stale);
            check(because: 'seed $seed id $x', status).equals(expected);
          }
        }
      }
    });
  });

  group('fetchInterval', () {
    List<FetchBounds> intervals({
      required int anchor, int numBefore = 0, int numAfter = 0, bool includeAnchor = true,
      required List<int> ids, bool foundOldest = false, bool foundNewest = false,
      bool historyLimited = false, bool tracked = true, bool continuous = true,
      int knownMaxAtSend = 1000, bool anchorKnownVisible = true,
    }) => MessageCoverage.fetchIntervals(anchor: anchor, numBefore: numBefore,
      numAfter: numAfter, includeAnchor: includeAnchor, ids: ids,
      foundOldest: foundOldest, foundNewest: foundNewest, historyLimited: historyLimited,
      tracked: tracked, continuous: continuous, knownMaxAtSend: knownMaxAtSend,
      anchorKnownVisible: anchorKnownVisible);
    FetchBounds? interval({
      required int anchor, int numBefore = 0, int numAfter = 0, bool includeAnchor = true,
      required List<int> ids, bool foundOldest = false, bool foundNewest = false,
      bool historyLimited = false, bool tracked = true, bool continuous = true,
      int knownMaxAtSend = 1000, bool anchorKnownVisible = true,
    }) => intervals(anchor: anchor, numBefore: numBefore,
      numAfter: numAfter, includeAnchor: includeAnchor, ids: ids,
      foundOldest: foundOldest, foundNewest: foundNewest, historyLimited: historyLimited,
      tracked: tracked, continuous: continuous, knownMaxAtSend: knownMaxAtSend,
      anchorKnownVisible: anchorKnownVisible).singleOrNull;

    test('newest, found both', () {
      check(interval(anchor: kNewestMessageId, numBefore: 5, ids: [3, 8],
        foundOldest: true, foundNewest: true)).equals((lo: 0, hi: null));
    });

    test('newest, untracked: closed at the known max', () {
      check(interval(anchor: kNewestMessageId, numBefore: 2, ids: [3, 8],
        foundNewest: true, tracked: false, knownMaxAtSend: 20)).equals((lo: 3, hi: 20));
    });

    test('newest, tracked but from an earlier epoch: closed', () {
      check(interval(anchor: kNewestMessageId, numBefore: 2, ids: [3, 8],
        foundNewest: true, continuous: false, knownMaxAtSend: 5)).equals((lo: 3, hi: 8));
    });

    test('before-only from an anchor above every known id: capped', () {
      check(interval(anchor: 50, numBefore: 3, ids: [30, 40], foundOldest: true,
        knownMaxAtSend: 45)).equals((lo: 0, hi: 45));
    });

    test('history limited: from the oldest returned', () {
      check(interval(anchor: kNewestMessageId, numBefore: 5, ids: [30, 40],
        foundOldest: true, foundNewest: true, historyLimited: true))
        .equals((lo: 30, hi: null));
    });

    test('fetchOlder: adjacent below the anchor', () {
      check(interval(anchor: 50, numBefore: 2, includeAnchor: false, ids: [30, 40]))
        .equals((lo: 30, hi: 49));
    });

    test('fetchNewer: adjacent above a known anchor', () {
      check(interval(anchor: 50, numAfter: 2, includeAnchor: false, ids: [60, 70]))
        .equals((lo: 51, hi: 70));
    });

    test('after-only from an anchor not known visible: from the first returned', () {
      check(interval(anchor: 50, numAfter: 2, includeAnchor: false, ids: [60, 70],
        anchorKnownVisible: false)).equals((lo: 60, hi: 70));
    });

    test('anchor=oldest: no hole (the after-query is not bumped)', () {
      check(interval(anchor: 0, numAfter: 2, ids: [60, 70], foundOldest: true,
        anchorKnownVisible: false)).equals((lo: 0, hi: 70));
      check(interval(anchor: 0, numAfter: 2, ids: [], foundOldest: true, foundNewest: true,
        anchorKnownVisible: false)).equals((lo: 0, hi: null));
    });

    test('anchor=oldest, history limited: found_newest is no promise (C7)', () {
      check(interval(anchor: 0, numAfter: 2, ids: [108], foundOldest: true,
        foundNewest: true, historyLimited: true)).equals((lo: 108, hi: 108));
    });

    test('two-sided around an anchor not known visible: a hole up to the first returned', () {
      check(intervals(anchor: 102, numBefore: 3, numAfter: 2, ids: [117],
        foundOldest: true, foundNewest: true, anchorKnownVisible: false))
        .deepEquals([(lo: 0, hi: 101), (lo: 117, hi: null)]);
      check(intervals(anchor: 102, numBefore: 3, numAfter: 2, ids: [117],
        foundOldest: true, foundNewest: true, anchorKnownVisible: true))
        .deepEquals([(lo: 0, hi: null)]);
    });

    test('not foundOldest with numBefore > 0 and no id < anchor', () {
      check(intervals(anchor: 10, numBefore: 5, numAfter: 5, includeAnchor: true,
        ids: [10, 12], foundOldest: false, foundNewest: true,
        historyLimited: true, anchorKnownVisible: true))
        .deepEquals([(lo: 10, hi: null)]);
      check(intervals(anchor: 10, numBefore: 5, numAfter: 5, includeAnchor: true,
        ids: [10, 12], foundOldest: false, foundNewest: true,
        historyLimited: true, anchorKnownVisible: false))
        .deepEquals([(lo: 10, hi: null)]);
    });

    test('not foundNewest with numAfter > 0 and no id > anchor', () {
      check(intervals(anchor: 10, numBefore: 5, numAfter: 5, includeAnchor: true,
        ids: [10], foundOldest: true, foundNewest: false,
        knownMaxAtSend: 10))
        .deepEquals([(lo: 0, hi: 10)]);
      check(intervals(anchor: 10, numBefore: 5, numAfter: 5, includeAnchor: true,
        ids: [], foundOldest: false, foundNewest: false,
        historyLimited: true, anchorKnownVisible: false))
        .isEmpty();
    });
  });

  group('model: regression sequences', () {
    regressionTests();
  });

  group('model: counterexamples to the design as written', () {
    counterexampleTests();
  });

  group('model: randomized', () {
    const defaultSeeds = 5000;
    const defaultOps = 100;
    final env = Platform.environment;
    final seeds = int.tryParse(env['COVERAGE_MODEL_SEEDS'] ?? '') ?? defaultSeeds;
    final ops = int.tryParse(env['COVERAGE_MODEL_OPS'] ?? '') ?? defaultOps;
    final firstSeed = int.tryParse(env['COVERAGE_MODEL_FIRST_SEED'] ?? '') ?? 0;
    // Fixes the fragmentation cap for every seed; by default 1 seed in 7 uses 2-4.
    final cap = int.tryParse(env['COVERAGE_MODEL_CAP'] ?? '');
    // Fixes the queue-loss profile (0 rare, 1 some, 2 frequent); by default per seed.
    final lossProfile = int.tryParse(env['COVERAGE_MODEL_LOSS'] ?? '');
    // Delivery classes: 'random' (per seed, the default), 'none', 'all',
    // or a comma-separated list of ModelOptions.names.
    final classes = env['COVERAGE_MODEL_CLASSES'] ?? 'random';
    final options = switch (classes) {
      'random' => null,
      'none' => const ModelOptions(),
      'all' => ModelOptions.all,
      _ => ModelOptions.named(classes.split(',').toSet()),
    };
    // To replay the naive rules without specific corrections: COVERAGE_MODEL_DISABLE=name,name
    final disabled = {
      for (final name in (env['COVERAGE_MODEL_DISABLE'] ?? '').split(','))
        if (name.isNotEmpty) CoverageCorrection.values.byName(name),
    };
    final isDefault = seeds == defaultSeeds && ops == defaultOps && firstSeed == 0
      && cap == null && lossProfile == null && classes == 'random' && disabled.isEmpty;

    test('$seeds seeds × $ops operations', () {
      modelStats.clear();
      MessageCoverage.debugCapHits = 0;
      disabledCorrections = disabled;
      try {
        for (var seed = firstSeed; seed < firstSeed + seeds; seed++) {
          ModelRun(seed, options: options, cap: cap, lossProfile: lossProfile).run(ops: ops);
        }
      } finally {
        disabledCorrections = {};
      }
      modelStats['reach: cap hits'] = MessageCoverage.debugCapHits;
      if (!isDefault) return;
      // Reach: the default run must keep reaching the hard states,
      // so that a change to the generator that stops reaching them fails here.
      // Each minimum is about a third of what the generator reached when written.
      for (final MapEntry(key: what, value: minimum) in reachMinimums.entries) {
        check(because: 'reach of "$what"', modelStats[what] ?? 0).isGreaterOrEqual(minimum);
      }
    });
  });
}

/// Minimum counts for the default randomized run (see there).
const reachMinimums = <String, int>{
  'forgets': 150,
  'reach: forget punctures another key': 80,
  'reach: move strictly inside a live interval (channel)': 400,
  'reach: move strictly inside a live interval (topic, cross-channel)': 50,
  'reach: move strictly inside a live interval (topic, same-channel rename)': 20,
  'reach: delete races a fetched id': 100,
  'reach: move races a fetched id': 130,
  'reach: after-mark move of a fetched copy not at its origin': 100,
  'reach: live copy at another location than fetched': 30,
  'reach: R-6 move re-applied after a move back (ABA)': 30,
  'reach: C6 precursor at an epoch end': 45,
  'reach: cap hits': 40,
  'reach: fetch handled across a re-register': 2000,
  'reach: queue lost with a fetch in flight': 3000,
  'reach: queue lost with events pending': 2500,
  'reach: R-1 silent move': 3000,
  'reach: R-3 out-of-order commit': 1500,
  'reach: R-3 recipients computed before subscribing': 35,
  'reach: message event while unsubscribed': 35,
  'reach: message event without access': 20,
  'reach: guest excluded from a move into a subscribed channel': 200,
  'reach: group access change': 900,
  'reach: invite_only change': 900,
  'reach: history limit advanced': 1200,
  'reach: lift reveals ids a fetch found absent': 150,
  'reach: access loss purges data': 700,
  'reach: history regime change drops data': 500,
  'reach: stored DM conversation unlisted at register': 500,
  'reach: move event from another location than the stored row': 90,
};

/// A scripted scenario on the model.
class Scenario {
  Scenario({List<int> subscribed = const [], ModelOptions options = const ModelOptions()})
    : server = TruthServer(options: options)
  {
    for (final c in subscribed) {
      server.subscribe(c);
    }
    client.ghostIds = () => server.allIds;
    checker = Checker(server, client);
  }

  final rand = Random(0);
  final TruthServer server;
  final client = ModelClient(cap: 16);
  late final Checker checker;

  int send(int c, String topic) => server.sendChannel(rand, c, topic);
  int dm(String key) => server.sendDm(rand, key);

  void register() => client.register(server.register());

  void pollAll() {
    if (!client.poll(server, 1000)) register();
  }

  Ticket send_(FetchRequest req) => client.send(req);

  void process(Ticket t) => t.result = server.processFetch(t.req);

  void handle(Ticket t) => client.handleFetch(t);

  /// Send, process and handle at once.
  void fetch(FetchRequest req) {
    final t = client.send(req);
    process(t);
    handle(t);
  }

  List<String> errors() => checker.check();

  void checkOk() => check(errors()).isEmpty();
}

FetchRequest newest(String key, [int numBefore = 10]) =>
  FetchRequest(key, anchor: kNewestMessageId, numBefore: numBefore, numAfter: 0,
    includeAnchor: true);

void regressionTests() {
  final topicA = CoverageKeys.topic(10, 'a');

  test('fetch racing a delete', () {
    final s = Scenario(subscribed: [10]);
    final m = s.send(10, 'a');
    s.register();
    final t = s.send_(newest(topicA));
    s.process(t); // snapshot holds m
    s.server.delete([m]);
    s.pollAll(); // the delete event
    s.handle(t);
    check(s.client.rows).not((it) => it.containsKey(m));
    s.checkOk();
  });

  test('subscribe from the channel list while quiet elsewhere', () {
    final s = Scenario(subscribed: [10]);
    s.dm('dm:1,2');
    s.register();
    final old = [for (var i = 0; i < 3; i++) s.send(11, 'a')]; // unsubscribed: no events
    s.server.subscribe(11);
    s.pollAll();
    check(s.client.cov.intervalsOf(CoverageKeys.channel(11))).isEmpty();
    check(s.client.cov.chainAt(CoverageKeys.topic(11, 'a'), old.last)).isNull();
    final next = s.send(11, 'a');
    s.pollAll();
    check(s.client.cov.chainAt(CoverageKeys.channel(11), next)!.lo).equals(next);
    s.checkOk();
  });

  test('subscribed on the web before a register', () {
    final s = Scenario();
    s.send(11, 'a');
    s.server.subscribe(11);
    s.register();
    check(s.client.cov.intervalsOf(CoverageKeys.channel(11))).isEmpty();
    s.checkOk();
  });

  test('resolve a topic whose target predates the subscription', () {
    final s = Scenario();
    final old = s.send(10, 'a');
    s.server.subscribe(10);
    s.register();
    s.pollAll();
    final m = s.send(10, 'a');
    s.pollAll();
    s.fetch(newest(topicA));
    s.server.move(old, Propagate.changeAll, 10, '✔ a');
    s.pollAll();
    // Both moved messages were stored: nothing is punctured,
    // and the resolved topic is answered by the channel's interval from m on.
    check(s.client.rows[old]!.topic).equals('✔ a');
    check(s.client.cov.chainAt(CoverageKeys.topic(10, '✔ a'), m)).isNotNull();
    s.checkOk();
  });

  test('react to an old unstored message, then it moves into a covered topic', () {
    final s = Scenario(subscribed: [10]);
    final old = s.send(11, 'x'); // unsubscribed channel 11
    s.register();
    s.send(10, 'a');
    s.pollAll();
    s.fetch(newest(topicA));
    s.server.react(old); // historical UM row: self now hears about it
    s.server.move(old, Propagate.changeOne, 10, 'a');
    s.pollAll();
    check(s.client.rows).not((it) => it.containsKey(old));
    check(s.client.cov.chainAt(topicA, old)).isNull(); // punctured
    s.checkOk();
  });

  test('a gap across an epoch, with a new message after it', () {
    final s = Scenario(subscribed: [10]);
    s.register();
    for (var i = 0; i < 3; i++) {
      s.send(10, 'a');
    }
    s.pollAll();
    s.fetch(newest(topicA));
    s.server.loseQueue();
    final missed = [s.send(10, 'a'), s.send(10, 'a')];
    s.pollAll(); // BAD_EVENT_QUEUE_ID → register
    final after = s.send(10, 'a');
    s.pollAll();
    final chain = s.client.cov.chainAt(topicA, after)!;
    check(chain.lo).equals(after); // the new epoch's piece doesn't reach back
    for (final id in missed) {
      check(s.client.cov.chainAt(topicA, id)).isNull();
    }
    s.checkOk();
  });

  test('resumed epoch, dead queue, a fetch, then BAD_EVENT_QUEUE_ID (A-S2)', () {
    final s = Scenario(subscribed: [10, 11]);
    s.register();
    s.send(10, 'a');
    s.pollAll();
    s.fetch(newest(topicA)); // open
    s.client.restart(const []);
    s.server.loseQueue();
    final missed = [s.send(10, 'a'), s.send(10, 'a')];
    s.send(11, 'b');
    s.fetch(newest(CoverageKeys.channel(11))); // fetched max above `missed`
    check(s.client.cov.confirmed).isFalse();
    s.pollAll(); // BAD_EVENT_QUEUE_ID → register
    for (final id in missed) {
      check(s.client.cov.chainAt(topicA, id)).isNull();
    }
    s.checkOk();
  });

  test('unconfirmed until the first poll (A-S1, coverage part)', () {
    final s = Scenario(subscribed: [10]);
    s.register();
    final m = s.send(10, 'a');
    s.pollAll();
    s.fetch(newest(topicA));
    s.client.restart(const []);
    check(s.client.cov.chainAt(topicA, m)!.status).equals(CoverageStatus.unconfirmed);
    s.server.loseQueue();
    s.server.move(m, Propagate.changeOne, 10, 'b'); // lost with the queue
    s.checkOk();
    s.pollAll();
    check(s.client.cov.chainAt(topicA, m)!.status).equals(CoverageStatus.stale);
    s.checkOk();
  });

  test('a large catch-up batch while a fetch is in flight (A-S4, without a cap)', () {
    final s = Scenario(subscribed: [10]);
    s.register();
    final ms = [for (var i = 0; i < 40; i++) s.send(10, 'a')];
    final t = s.send_(newest(topicA, 100));
    s.process(t);
    s.server.delete([ms[7]]);
    s.pollAll();
    s.handle(t);
    check(s.client.rows).not((it) => it.containsKey(ms[7]));
    s.checkOk();
  });

  test('a message event during a newest-anchored fetch (A-S5, coverage part)', () {
    final s = Scenario(subscribed: [10]);
    s.register();
    s.send(10, 'a');
    s.pollAll();
    final t = s.send_(newest(topicA));
    s.process(t);
    final m = s.send(10, 'a');
    s.pollAll();
    s.handle(t);
    check(s.client.rows).containsKey(m);
    check(s.client.cov.chainAt(topicA, m)!.isOpen).isTrue();
    s.checkOk();
  });

  test('a move into a protected-history topic during its fetch (A-S6, topic analog)', () {
    final s = Scenario(subscribed: [11, 13]);
    final x = s.send(11, 'x'); // public, subscribed
    final topic13 = CoverageKeys.topic(13, 'a');
    s.register();
    s.send(13, 'a');
    s.pollAll();
    final t = s.send_(newest(topic13));
    s.process(t); // before the move
    s.server.move(x, Propagate.changeOne, 13, 'a'); // UM rows for 13's subscribers
    s.pollAll();
    s.handle(t);
    check(s.client.cov.chainAt(topic13, x)).isNull();
    s.checkOk();
  });

  test('subscribe during a fetch (A-S8)', () {
    final s = Scenario();
    s.send(11, 'a');
    s.register();
    final t = s.send_(newest(CoverageKeys.channel(11)));
    s.process(t);
    final x = s.send(11, 'a'); // unsubscribed: no event
    s.server.subscribe(11);
    s.pollAll();
    s.handle(t);
    check(s.client.cov.chainAt(CoverageKeys.channel(11), x)).isNull();
    s.checkOk();
  });

  test('page back, eviction, page again (B-S4)', () {
    final s = Scenario(subscribed: [10]);
    final ms = [for (var i = 0; i < 8; i++) s.send(10, 'a')];
    s.register();
    s.fetch(newest(topicA, 3));
    s.fetch(FetchRequest(topicA, anchor: ms[5], numBefore: 3, numAfter: 0, includeAnchor: false));
    s.client.evict(ms[4]);
    s.fetch(FetchRequest(topicA, anchor: ms[7], numBefore: 6, numAfter: 0, includeAnchor: false));
    check(s.client.cov.intervalsOf(topicA).first.lo).equals(ms[4]);
    s.checkOk();
  });

  test('protected-history change_later move without a UM row for the target (B-S5)', () {
    final s = Scenario();
    final target = s.send(13, 'a'); // before self subscribes: no UM row
    s.server.subscribe(13);
    s.register();
    final mine = s.send(13, 'a');
    s.pollAll();
    final topic13 = CoverageKeys.topic(13, 'a');
    s.fetch(newest(topic13));
    check(s.client.rows).containsKey(mine);
    s.server.move(target, Propagate.changeLater, 13, 'b'); // silent for self: R-1
    s.pollAll();
    check(s.server.silent).containsKey(mine);
    s.fetch(newest(topic13)); // revalidation forgets the silent move-out
    check(s.client.rows).not((it) => it.containsKey(mine));
    s.checkOk();
  });

  test('history toggle (B-S5): to protected purges, to shared drops coverage', () {
    final s = Scenario();
    final pre = s.send(12, 'a'); // before self subscribes: no UM row
    s.server.subscribe(12);
    s.register();
    final post = s.send(12, 'a');
    s.pollAll();
    final ch = CoverageKeys.channel(12);
    s.fetch(newest(ch));
    check(s.client.rows).containsKey(pre);
    s.server.toggleHistory(12); // shared → protected: `pre` (no UM row) leaves
    s.pollAll();
    check(s.client.rows).isEmpty();
    check(s.client.cov.intervalsOf(ch)).isEmpty();
    s.fetch(newest(ch));
    check(s.client.rows.keys).deepEquals([post]);
    s.server.toggleHistory(12); // protected → shared: `pre` reappears
    s.pollAll();
    check(s.client.cov.intervalsOf(ch)).isEmpty();
    s.checkOk();
  });

  test('history toggle while the queue is dead: found at the epoch start', () {
    final s = Scenario();
    final pre = s.send(12, 'a'); // before self subscribes: no UM row
    s.server.subscribe(12);
    s.register();
    s.fetch(newest(CoverageKeys.channel(12)));
    check(s.client.rows).containsKey(pre);
    s.server.loseQueue();
    s.server.toggleHistory(12);
    s.pollAll();
    check(s.client.rows).isEmpty();
    s.checkOk();
  });

  test('DM gap bridge over a dead queue', () {
    final s = Scenario();
    final a = s.dm('dm:1,2');
    s.register();
    s.fetch(newest('dm:1,2'));
    s.server.loseQueue();
    final b = s.dm('dm:1,3'); // raises max_message_id above the old high-water
    s.pollAll();
    final chain = s.client.cov.chainAt('dm:1,2', a,
      dmLatestKnownId: s.client.dmLatest['dm:1,2'])!;
    check(chain.isOpen).isTrue(); // stale piece, bridge, open dms
    check(chain.pieces.map((p) => p.source)).deepEquals(['dm:1,2', 'bridge', 'dms']);
    check(s.client.cov.chainAt('dm:1,3', b,
      dmLatestKnownId: s.client.dmLatest['dm:1,3'])).isNull();
    s.checkOk();
  });

  // Scripted regressions for subtle coverage rules.

  test('same-channel rename of an unstored id into a live topic interval punctures it', () {
    final s = Scenario(subscribed: [10]);
    final u = s.send(10, 'b'); // before the register: never stored
    s.register();
    s.send(10, 'a');
    s.pollAll();
    s.fetch(newest(topicA)); // topic:10:A [0, ∞), live, with u inside
    check(s.client.cov.chainAt(topicA, u)).isNotNull();
    s.server.move(u, Propagate.changeOne, 10, 'a');
    s.pollAll();
    check(s.client.cov.chainAt(topicA, u)).isNull();
    s.checkOk();
  });

  test('a message event opens the implied interval at its own id, not across a gap below', () {
    final s = Scenario(subscribed: [10]);
    final ch = CoverageKeys.channel(10);
    s.send(10, 'a');
    final b = s.send(10, 'a');
    final c = s.send(10, 'a');
    s.register();
    s.fetch(FetchRequest(ch, anchor: c, numBefore: 1, numAfter: 0, includeAnchor: false));
    check(s.client.cov.intervalsOf(ch).single).has((r) => (r.lo, r.hi), 'bounds')
      .equals((b, c - 1));
    final d = s.send(10, 'a');
    s.pollAll();
    check(s.client.cov.chainAt(ch, c)).isNull();
    check(s.client.cov.chainAt(ch, d)!.lo).equals(d);
    s.checkOk();
  });

  test('unsubscribe untracks the topic keys too; then a silent delete there', () {
    final s = Scenario();
    final u = s.send(10, 'a'); // before subscribing: no UM row
    s.server.subscribe(10);
    s.register();
    s.send(10, 'a');
    s.pollAll();
    s.fetch(newest(topicA));
    s.server.unsubscribe(10);
    s.pollAll();
    check(s.client.cov.intervalsOf(topicA).every((r) => !r.tracked)).isTrue();
    s.server.delete([u]); // no event: not subscribed, no UM row
    s.dm('dm:1,2');
    s.pollAll(); // the client's clock passes the delete
    s.checkOk();
  });

  test('later moves are re-applied to fetched copies', () {
    final s = Scenario(subscribed: [10]);
    final m = s.send(10, 'a'); // never stored before the fetch
    s.register();
    final t = s.send_(newest(topicA));
    s.process(t); // m in topic a
    s.server.move(m, Propagate.changeOne, 10, 'b');
    s.pollAll(); // the move, before the result
    s.handle(t);
    check(s.client.rows[m]!.topic).equals('b');
    s.checkOk();
  });

  test('a message event after the subscription-remove event opens no interval (R-3 order)', () {
    final s = Scenario(subscribed: [10]);
    s.register();
    // Recipients are computed before the unsubscribe commits, the message after:
    // its event follows the subscription-remove event.
    final p = s.server.beginSend(s.rand, channelId: 10, topic: 'a', assignId: true);
    s.server.unsubscribe(10);
    s.server.commitSend(p);
    s.pollAll();
    check(s.client.rows[p.id!]!.tracked).isFalse();
    check(s.client.cov.intervalsOf(CoverageKeys.channel(10))).isEmpty();
    s.send(10, 'a'); // unsubscribed: no event
    s.dm('dm:1,2');
    s.pollAll();
    s.checkOk();
  });

  test('topic keys fold case like the server: a channel interval answers both spellings', () {
    final s = Scenario(subscribed: [10]);
    s.register();
    final x = s.send(10, 'A');
    s.pollAll(); // channel:10 [x, ∞)
    check(s.client.cov.chainAt(CoverageKeys.topic(10, 'a'), x)).isNotNull();
    s.checkOk();
  });

  test('fold divergence: the topic fetch records nothing; the channel derivation is a residual', () {
    // Hypothetical server whose upper() maps ß to SS (a full case mapping):
    // it matches topics the client's fold keeps apart.
    final s = Scenario(subscribed: [10], options: const ModelOptions(foldDivergence: true));
    s.checker.extraQueryTopics = ['ß', 'SS'];
    final eszett = CoverageKeys.topic(10, 'ß');
    s.send(10, 'SS');
    s.send(10, 'ß');
    s.register();
    s.fetch(newest(eszett)); // returns both: a fold mismatch
    check(s.client.cov.intervalsOf(eszett)).isEmpty();
    s.checkOk();
    s.fetch(newest(CoverageKeys.channel(10)));
    // topic:10:ß from channel:10 omits the SS message the server's ß narrow holds.
    check(s.errors()).any((it) => it.startsWith('I6 gap: query $eszett'));
  });
}

/// Each counterexample the model found, replayed:
/// a violation with the naive rule, none with the corrected rule.
void counterexampleTests() {
  final topicA = CoverageKeys.topic(10, 'a');

  /// Runs [scenario] with [correction] disabled, then enabled.
  void replay(CoverageCorrection correction, void Function(Scenario Function() make) scenario, {
    required Scenario Function() make,
  }) {
    late Scenario designRule;
    late List<String> designErrors;
    try {
      disabledCorrections = {correction};
      scenario(() => designRule = make());
      designErrors = designRule.errors(); // some rules act at query time
    } finally {
      disabledCorrections = {};
    }
    check(because: 'the uncorrected rule fails', designErrors).isNotEmpty();
    late Scenario corrected;
    scenario(() => corrected = make());
    check(corrected.errors()).isEmpty();
  }

  test('C1 after-only fetch from a hidden numeric anchor, then the plan history limit is lifted', () {
    replay(CoverageCorrection.anchorBoundsOnlyIfKnown, make: () => Scenario(subscribed: [10]), (make) {
      final s = make();
      final old = [s.send(10, 'a'), s.send(10, 'a'), s.send(10, 'a')];
      s.server.setFirstVisible(old.last);
      s.send(10, 'a');
      s.register();
      // A link to old[0]: num_before=0, so the after-query starts at
      // max(anchor + 1, first_visible_message_id) (narrow.py:1284) and skips old[1];
      // found_oldest is false and history_limited false. Without the rule, claims [old[0] + 1, ..].
      s.fetch(FetchRequest(topicA, anchor: old[0], numBefore: 0, numAfter: 5, includeAnchor: false));
      s.server.setFirstVisible(0); // plan upgrade: no event
      s.dm('dm:1,2');
      s.pollAll(); // the client's clock passes the lift
    });
  });

  test('C1 does not apply to anchor=oldest: hidden rows set history_limited', () {
    // Formerly C1's "after-only fetch from the oldest" replay: an artifact of
    // the model's fetch, which filtered the after-query at the limit.
    // The server doesn't (narrow.py:1301), so the design's lo rule holds there.
    late Scenario s;
    try {
      disabledCorrections = {CoverageCorrection.anchorBoundsOnlyIfKnown};
      s = Scenario(subscribed: [10]);
      final old = [s.send(10, 'a'), s.send(10, 'a')];
      s.server.setFirstVisible(old.last + 1);
      final x = s.send(10, 'a');
      s.register();
      s.fetch(FetchRequest(topicA, anchor: 0, numBefore: 0, numAfter: 5, includeAnchor: true));
      check(s.client.cov.intervalsOf(topicA).single.lo).equals(x);
      s.server.setFirstVisible(0);
      s.dm('dm:1,2');
      s.pollAll();
    } finally {
      disabledCorrections = {};
    }
    s.checkOk();
  });

  test('C7 anchor=oldest under a history limit: found_newest counts the hidden rows (seed 2391)', () {
    replay(CoverageCorrection.oldestAnchorLimitedNotNewest, make: () => Scenario(subscribed: [10]), (make) {
      final s = make();
      final old = [s.send(10, 'a'), s.send(10, 'a')];
      s.server.setFirstVisible(old.last + 1);
      final x = s.send(10, 'a');
      s.send(10, 'a');
      s.send(10, 'a');
      s.register();
      // The after-query isn't bumped for anchor=oldest (narrow.py:1301): it takes
      // num_after + 1 = 3 rows from the oldest, [old[0], old[1], x]; the limit drops two
      // (:1353-1356), and found_newest = 1 < 2 (:1390) though two members follow x.
      s.fetch(FetchRequest(topicA, anchor: 0, numBefore: 0, numAfter: 2, includeAnchor: true));
      check(s.client.rows.keys).deepEquals([x]);
    });
  });

  test('C1 anchor id not yet assigned bounds an interval from below (seed 1190)', () {
    replay(CoverageCorrection.anchorBoundsOnlyIfKnown, make: Scenario.new, (make) {
      final s = make()..server.consecutiveIds = true;
      s.send(11, 'a');
      s.register();
      final r = s.server.lastId + 1;
      s.fetch(FetchRequest(topicA, anchor: r, numBefore: 0, numAfter: 0, includeAnchor: true));
      check(s.send(10, 'a')).equals(r);
    });
  });

  test('C1 anchor id not yet assigned bounds an interval from above', () {
    replay(CoverageCorrection.anchorBoundsOnlyIfKnown, make: Scenario.new, (make) {
      final s = make()..server.consecutiveIds = true;
      final topic = CoverageKeys.topic(11, 'a'); // unsubscribed: no events
      s.send(11, 'a');
      s.register();
      final r = s.server.lastId + 2;
      s.fetch(FetchRequest(topic, anchor: r, numBefore: 2, numAfter: 0, includeAnchor: true));
      s.send(11, 'b');
      check(s.send(11, 'a')).equals(r); // inside the claim [.., r]
    });
  });

  test('C1 two-sided fetch around a hidden anchor, then the limit is lifted (seed 118195)', () {
    replay(CoverageCorrection.anchorBoundsOnlyIfKnown, make: Scenario.new, (make) {
      final s = make()..server.consecutiveIds = true;
      final hidden = s.dm('dm:1,2,3');
      s.server.setFirstVisible(hidden + 1);
      s.register();
      s.dm('dm:1,2,3');
      // A link to `hidden`: num_before and num_after both > 0; the after-query
      // starts at first_visible_message_id and the before-query finds no hidden row.
      s.fetch(FetchRequest('dm:1,2,3', anchor: hidden, numBefore: 3, numAfter: 2,
        includeAnchor: true));
      s.server.setFirstVisible(0);
      s.dm('dm:1');
      s.pollAll();
    });
  });

  test('C12 the limit rises past a stored anchor; a fetchNewer from it; the limit is lifted', () {
    for (final includeAnchor in [false, true]) {
      replay(CoverageCorrection.anchorVisibleOnlyIfReturned, make: () => Scenario(subscribed: [10]), (make) {
        final s = make();
        final r = s.send(10, 'a');
        final skipped = s.send(10, 'a');
        s.register();
        s.fetch(newest(topicA)); // stores r and skipped
        final x = s.send(10, 'a');
        s.send(10, 'a');
        s.server.setFirstVisible(x); // silent (R-4): r and skipped are hidden now
        // The app's fetchNewer from r, which it has seen: the after-query starts
        // at max(r + 1, x) (narrow.py:1284); r is not returned.
        s.fetch(FetchRequest(topicA, anchor: r, numBefore: 0, numAfter: 5,
          includeAnchor: includeAnchor));
        // Under the design rule, skipped (hidden now) is forgotten inside the claim.
        check(s.client.rows.containsKey(skipped)).equals(
          isCoverageCorrected(CoverageCorrection.anchorVisibleOnlyIfReturned));
        s.server.setFirstVisible(0); // upgrade: skipped is visible again
        s.dm('dm:1,2');
        s.pollAll();
      });
    }
  });

  test('C6 a forget above the high-water closes an implied interval; then the queue dies (seed 100345)', () {
    replay(CoverageCorrection.clipContinuousAtHighWater, make: () => Scenario(subscribed: [10]), (make) {
      final s = make();
      s.register();
      s.send(10, 'a');
      s.pollAll(); // channel:10 [m1, ∞), implied
      s.send(10, 'b'); // x: its event stays in the queue
      final y = s.send(10, 'a');
      s.fetch(newest(topicA)); // stores y, above the event high-water
      s.server.delete([y]); // event stays in the queue too
      s.fetch(newest(topicA)); // forgets y: channel:10 punctured at y → [m1, y − 1]
      s.server.loseQueue();
      s.pollAll(); // register: [m1, y − 1] goes stale, claiming x absent
    });
  });

  test('C3a DM deleted during a queue gap, above the new max_message_id', () {
    replay(CoverageCorrection.dropDeletedDmRowsAtRegister, make: Scenario.new, (make) {
      final s = make();
      s.register();
      final d = s.dm('dm:1,2');
      s.pollAll();
      s.server.loseQueue();
      s.server.delete([d]); // lost with the queue
      s.pollAll(); // register: dms [F + 1, ∞) with F < d
    });
  });

  test('C3b DM deleted during a queue gap, inside the DM gap bridge', () {
    replay(CoverageCorrection.dropDeletedDmRowsAtRegister, make: Scenario.new, (make) {
      final s = make();
      s.dm('dm:1,2');
      s.register();
      final t = s.send_(newest('dm:1,2'));
      final b = s.dm('dm:1,2'); // its event is never polled
      s.process(t);
      s.handle(t);
      s.server.loseQueue();
      s.server.delete([b]);
      s.dm('dm:1,3'); // max_message_id above b
      s.pollAll(); // register; bridge (high-water, F] for dm:1,2 holds row b
    });
  });

  test('C4 channel purged by a history toggle while its fetch is in flight', () {
    replay(CoverageCorrection.noCoverageAcrossChannelDrop, make: Scenario.new, (make) {
      final s = make();
      s.send(12, 'a'); // before self subscribes: no UM row
      s.server.subscribe(12);
      s.register();
      s.send(12, 'a');
      s.pollAll();
      final t = s.send_(newest(CoverageKeys.channel(12)));
      s.server.toggleHistory(12); // → protected: purge
      s.pollAll();
      s.process(t);
      s.handle(t); // rows dropped as purged after the mark, but an interval recorded
    });
  });

  test('C5 fetch sent before a queue loss, handled after the re-register', () {
    replay(CoverageCorrection.discardOldEpochFetches, make: Scenario.new, (make) {
      final s = make();
      s.register();
      final d = s.dm('dm:1,2');
      final t = s.send_(newest('dm:1,2'));
      s.process(t); // holds d
      s.server.loseQueue();
      s.server.delete([d]); // no event will ever say so
      s.pollAll(); // register: dms [F + 1, ∞), F < d
      s.handle(t); // stale row d inside the live dms interval
    });
  });

  test('C8 a live copy kept by reconcile misses a move whose event is lost (seed 68)', () {
    replay(CoverageCorrection.relocateLiveCopyOnFetch, make: () => Scenario(subscribed: [10, 13]), (make) {
      final s = make();
      s.register();
      final m = s.send(10, 'a');
      s.pollAll(); // m stored, live, in #10
      final t = s.send_(newest(CoverageKeys.channel(13)));
      s.server.move(m, Propagate.changeOne, 13, 'a'); // its event stays queued
      s.process(t); // m in #13
      s.handle(t); // design: m is known and live, so the store's copy (in #10) is kept
      s.server.loseQueue();
      s.pollAll(); // register: channel:13's interval is stale and claims m absent
    });
  });

  test('C11 an older move re-applied to a newer snapshot takes the copy back (seed 461)', () {
    replay(CoverageCorrection.reapplyMoveOnlyAtItsOrigin, make: () => Scenario(subscribed: [10, 11, 13]), (make) {
      final s = make();
      final m = s.send(11, 'a'); // before the register: never stored
      s.register();
      final t = s.send_(newest(CoverageKeys.channel(13)));
      s.server.move(m, Propagate.changeOne, 10, 'a'); // e1, after the mark
      s.server.move(m, Propagate.changeOne, 13, 'a'); // e2
      s.process(t); // the snapshot has m in #13: it reflects e1 and e2
      check(s.client.poll(s.server, 1)).isTrue(); // only e1 arrives before the result
      s.handle(t); // design: re-applying e1 puts the fetched copy in #10
      s.server.loseQueue(); // e2 is never delivered
      s.pollAll();
    });
  });

  test('C9 a message event after the access loss (seed 27)', () {
    replay(CoverageCorrection.noRowWithoutAccess, make: () => Scenario(subscribed: [12]), (make) {
      final s = make();
      s.register();
      // Recipients computed while subscribed; the unsubscribe from the private
      // channel commits before the message does (message_send.py:740, :1107-1128).
      final p = s.server.beginSend(s.rand, channelId: 12, topic: 'a', assignId: true);
      s.server.unsubscribe(12);
      s.server.commitSend(p);
      s.pollAll(); // subscription remove (access lost, purge), then the message event
    });
  });

  test('C10 an out-of-order message event opens an implied interval below committed ids (seed 35)', () {
    replay(CoverageCorrection.impliedStartAboveHighWater, make: () => Scenario(subscribed: [10]), (make) {
      final s = make();
      final p = s.server.beginSend(s.rand, channelId: 10, topic: 'a', assignId: true);
      final y = s.send(10, 'a'); // y > p.id, committed before the register
      s.register(); // max_message_id = y
      s.server.commitSend(p); // p.id < y commits late; its event comes
      s.pollAll(); // design: channel:10 [p.id, ∞) claims y, which never arrives
      check(s.client.rows).not((it) => it.containsKey(y));
    });
  });

  test('C13 the DM gap bridge for a conversation the register did not list (seed 66512)', () {
    replay(CoverageCorrection.bridgeOnlyListedConversations,
      make: () => Scenario(options: const ModelOptions(outOfOrderCommits: true, dmListCap: 1)),
      (make) {
        final s = make();
        final p = s.server.beginSend(s.rand, dmKey: 'dm:1,3', assignId: true); // id x
        s.dm('dm:1,3'); // a > x
        s.register();
        s.fetch(newest('dm:1,3')); // dm:1,3 [0, ∞): x is not committed yet
        s.server.loseQueue();
        s.dm('dm:1,3'); // m, lost with the queue
        s.dm('dm:1,2'); // the newest conversation: the only one listed (cap 1)
        s.pollAll(); // register: dm:1,3 closed at a; dms [F + 1, ∞), F above m
        s.server.commitSend(p); // x < F commits late; its event names dm:1,3
        s.pollAll(); // design: latest(dm:1,3) = x below a, so the bridge (a, F] claims m absent
      });
  });

  test('C14 a move event relocates a row that missed a move out of access (seed 104649)', () {
    replay(CoverageCorrection.forgetRowMovedFromElsewhere, make: () => Scenario(subscribed: [10, 12]), (make) {
      final s = make();
      s.register();
      final m = s.send(10, 'a');
      s.pollAll(); // m stored, live, in #10
      // Self is not subscribed to private, protected #13: moving m there takes
      // self's UM row and sends `delete_message` (message_edit.py:1124-1136) ...
      s.server.move(m, Propagate.changeOne, 13, 'a');
      s.server.loseQueue(); // ... which is lost
      s.pollAll(); // register: m is a stale row in #10
      s.server.subscribe(13);
      final t = s.send(13, 'a'); // self has a UM row for t
      s.pollAll();
      s.fetch(newest(CoverageKeys.channel(13))); // channel:13 [0, ∞): m is no member
      // A move whose target self has a UM row for: the event names m too.
      s.server.move(t, Propagate.changeAll, 13, 'b');
      s.pollAll(); // design: m's row is relocated into #13, which self can't read
    });
  });

  test('C2 an old-epoch fetch with found_newest opens a stale interval', () {
    // Moot once C5 discards old-epoch fetches; replayed with both disabled.
    late Scenario s;
    try {
      disabledCorrections = {
        CoverageCorrection.discardOldEpochFetches, CoverageCorrection.openOnlyIfContinuous};
      // A DM key is tracked without a channel generation check.
      s = Scenario();
      s.register();
      s.dm('dm:1,2');
      final t = s.send_(newest('dm:1,2'));
      s.process(t);
      s.server.loseQueue();
      s.pollAll();
      s.handle(t);
    } finally {
      disabledCorrections = {};
    }
    check(s.errors()).any((it) => it.startsWith('I12: open stale'));
  });

  test('invariant I6 as written fails on a forget that runs ahead of the delete event', () {
    final s = Scenario(subscribed: [10]);
    s.register();
    final m = s.send(10, 'a');
    s.pollAll();
    s.fetch(newest(topicA));
    s.server.delete([m]); // event not yet polled
    s.fetch(newest(topicA)); // m absent and not named after the mark: forgotten
    check(s.client.rows).not((it) => it.containsKey(m));
    check(s.errors()).isEmpty(); // the window form
    s.checker.literalI6 = true;
    check(s.errors()).isNotEmpty(); // "truth as of the last applied event"
  });
}
