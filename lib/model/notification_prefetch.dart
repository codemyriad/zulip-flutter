import 'dart:async';
import 'dart:math' as math;

import '../api/core.dart';
import '../api/model/model.dart';
import '../api/route/messages.dart';
import '../log.dart';
import 'binding.dart';
import 'database.dart' show Account;
import 'message_coverage.dart';
import 'message_database.dart';
import 'message_db_effects.dart';
import 'message_db_sync.dart';
import 'message_db_writer.dart';
import 'narrow.dart';
import 'stored_message_codec.dart';

/// Number of older messages requested when prefetching around a notification.
const kNotificationPrefetchBefore = 50;

/// Number of newer messages requested when prefetching around a notification.
const kNotificationPrefetchAfter = 20;

/// Prefetch messages around [targetMessageId] in [narrow] directly into
/// [MessageDatabase] when no `PerAccountStore` is loaded for [account].
///
/// Returns `false` if [canProceedUnloaded] became false before committing
/// (so the caller can hand off to a newly loading `PerAccountStore`),
/// or `true` otherwise. Never throws.
Future<bool> prefetchUnloadedNotificationMessages({
  required Account account,
  required MessageDbWriter writer,
  required ApiConnection Function() openConnection,
  required bool Function() canProceedUnloaded,
  required SendableNarrow narrow,
  required int targetMessageId,
  Future<void>? abortTrigger,
}) async {
  final key = coverageKey(narrow);
  if (key == null || !canProceedUnloaded()) return true;
  final (channelId, topicKey, dmKey) = scopeFiltersForNarrow(narrow);

  final preCheck = await writer.runRead<({
    bool needed,
    int epoch,
    int? lastLiveAt,
  })>((db) async {
    final existing = await (db.select(db.messageDbAccounts)
      ..where((a) => a.accountId.equals(account.id))).getSingleOrNull();
    if (existing == null
        || existing.realmUrl != account.realmUrl.toString()
        || existing.userId != account.userId
        || existing.formatVersion != MessageDatabase.currentFormatVersion
        || existing.appliedThroughEventId == null) {
      return (needed: false, epoch: 0, lastLiveAt: null);
    }
    if (targetMessageId < existing.evictedBelowMessageId) {
      return (needed: false, epoch: existing.epoch, lastLiveAt: existing.lastLiveAt);
    }
    final loaded = await db.loadAccountStateInTxn(account.id);
    if (loaded == null) {
      return (needed: false, epoch: existing.epoch, lastLiveAt: existing.lastLiveAt);
    }
    final now = ZulipBinding.instance.utcNow().millisecondsSinceEpoch ~/ 1000;
    final staging = MessageCoverage(epoch: loaded.account.epoch)
      ..restore(
        epoch: loaded.account.epoch,
        eventHighWater: loaded.account.eventHighWater,
        evictedBelow: loaded.account.evictedBelowMessageId,
        confirmed: false,
        intervalsByKey: loaded.intervalsByKey,
      )
      ..beginEpoch(
        maxMessageId: null,
        lastLiveAt: loaded.account.lastLiveAt ?? now,
        now: now,
      );
    final chain = staging.chainAt(key, targetMessageId);
    if (chain == null) {
      return (needed: true, epoch: loaded.account.epoch, lastLiveAt: loaded.account.lastLiveAt);
    }
    final hasTarget = await db.hasStoredMessage(account.id, targetMessageId);
    if (!hasTarget && targetMessageId > loaded.account.eventHighWater && chain.isOpen) {
      return (needed: true, epoch: loaded.account.epoch, lastLiveAt: loaded.account.lastLiveAt);
    }
    if (chain.reachesOldest) {
      return (needed: false, epoch: loaded.account.epoch, lastLiveAt: loaded.account.lastLiveAt);
    }
    final beforeCount = await db.countStoredBeforeInScope(
      account.id,
      channelId: channelId,
      topicKey: topicKey,
      dmKey: dmKey,
      lo: chain.lo,
      beforeId: targetMessageId,
      limit: kNotificationPrefetchBefore,
    );
    return (
      needed: beforeCount < kNotificationPrefetchBefore,
      epoch: loaded.account.epoch,
      lastLiveAt: loaded.account.lastLiveAt,
    );
  });
  if (preCheck == null || !preCheck.needed) return true;
  if (!canProceedUnloaded()) return false;

  final GetMessagesResult result;
  final connection = openConnection();
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
    assert(debugLog('Unloaded notification message prefetch failed: $e'));
    return true;
  } finally {
    connection.close();
  }
  if (!canProceedUnloaded()) return false;

  final String? expectedTopicFold = switch (narrow) {
    TopicNarrow(:final topic) => serverTopicFold(topic.apiName),
    DmNarrow() => null,
  };
  bool topicFoldMismatch = false;
  for (final message in result.messages) {
    if (expectedTopicFold != null
        && message is StreamMessage
        && serverTopicFold(message.topic.apiName) != expectedTopicFold) {
      topicFoldMismatch = true;
    }
  }
  final rawById = <int, Map<String, dynamic>>{
    if (result.rawMessages case final rawList?)
      for (final raw in rawList)
        if (raw['id'] is num) (raw['id'] as num).toInt(): raw,
  };
  final unfilteredIds = [for (final m in result.messages) m.id];
  final resultIdSet = unfilteredIds.toSet();
  final encodedRecords = <({int id, StoredMessageRecord record})>[];
  for (final m in result.messages) {
    final clean = m
      ..matchContent = null
      ..matchTopic = null;
    final rawMap = rawMapOfMessage(clean, rawById[clean.id]);
    encodedRecords.add((
      id: clean.id,
      record: StoredMessageCodec.encode(
        accountId: account.id,
        message: clean,
        rawMap: rawMap,
        epoch: 0,
        tracked: false,
        rawFlagsOverride: effectiveRawFlags(clean, rawMap),
      ),
    ));
  }
  if (!canProceedUnloaded()) return false;

  final committed = await writer.runTrackedPipeline(() {
    return writer.enqueueWrite<bool>((db, {required removalOnly}) async {
      if (removalOnly || !canProceedUnloaded()) return false;
      return db.transaction(() async {
        if (!canProceedUnloaded()) return false;
        final valid = await db.ensureAccountInTxn(
          accountId: account.id,
          realmUrl: account.realmUrl,
          userId: account.userId,
        );
        if (valid == null) return true;
        final loaded = await db.loadAccountStateInTxn(account.id);
        if (loaded == null) return true;
        // Abort if a live store in another isolate advanced epoch or liveness
        // while our HTTP request was in flight.
        if (loaded.account.epoch != preCheck.epoch
            || loaded.account.lastLiveAt != preCheck.lastLiveAt) {
          return false;
        }

        List<FetchBounds> intervals = topicFoldMismatch
          ? const []
          : MessageCoverage.fetchIntervals(
              anchor: result.anchor,
              numBefore: kNotificationPrefetchBefore,
              numAfter: kNotificationPrefetchAfter,
              includeAnchor: true,
              ids: unfilteredIds,
              foundOldest: result.foundOldest,
              foundNewest: result.foundNewest,
              historyLimited: result.historyLimited,
              tracked: false,
              continuous: false,
              knownMaxAtSend: math.max(loaded.account.eventHighWater, targetMessageId),
              anchorKnownVisible: resultIdSet.contains(result.anchor),
            );
        if (narrow is TopicNarrow && !loaded.channels.containsKey(narrow.channelId)) {
          if (unfilteredIds.isEmpty) {
            intervals = const [];
          } else {
            final firstId = unfilteredIds.first;
            intervals = [
              for (final b in intervals)
                if ((b.hi ?? kNewestMessageId) >= math.max(b.lo, firstId))
                  (lo: math.max(b.lo, firstId), hi: b.hi),
            ];
          }
        }

        final forgottenIds = <int>[];
        final forgottenEntries = <({int id, List<String> keys})>[];
        if (intervals.isNotEmpty) {
          final candidates = await db.queryStoredInCoverageScope(
            account.id,
            channelId: channelId,
            topicKey: topicKey,
            dmKey: dmKey,
            intervals: intervals,
          );
          for (final row in candidates) {
            if (resultIdSet.contains(row.id)) continue;
            forgottenIds.add(row.id);
            forgottenEntries.add((
              id: row.id,
              keys: row.channelId != null
                ? [
                    CoverageKeys.channel(row.channelId!),
                    if (row.topicKey != null) 'topic:${row.channelId!}:${row.topicKey!}',
                  ]
                : [
                    CoverageKeys.dms,
                    if (row.dmKey != null) 'dm:${row.dmKey!}',
                  ],
            ));
          }
        }

        for (final item in encodedRecords) {
          if (item.id < loaded.account.evictedBelowMessageId) continue;
          await upsertStoredMessageRecordInDb(
            db,
            accountId: account.id,
            record: item.record,
          );
        }
        if (forgottenIds.isNotEmpty) {
          await deleteMessagesFromDb(
            db,
            accountId: account.id,
            messageIds: forgottenIds,
          );
        }

        if (intervals.isNotEmpty || forgottenEntries.isNotEmpty) {
          final now = ZulipBinding.instance.utcNow().millisecondsSinceEpoch ~/ 1000;
          final highWater = loaded.account.eventHighWater;
          final reachesAboveHighWater = intervals.any(
            (b) => (b.hi ?? kNewestMessageId) > highWater);
          final adjustedIntervals = <String, List<CoverageInterval>>{
            for (final entry in loaded.intervalsByKey.entries)
              entry.key: (entry.key == key && reachesAboveHighWater)
                ? [
                    for (final r in entry.value)
                      if (r.epoch == loaded.account.epoch
                          && r.tracked
                          && (r.isOpen || r.top > highWater))
                        if (highWater >= r.lo)
                          CoverageInterval(
                            r.lo,
                            highWater,
                            epoch: r.epoch,
                            tracked: r.tracked,
                            verifiedAt: loaded.account.lastLiveAt ?? now,
                          )
                        else
                          ...const <CoverageInterval>[]
                      else
                        r,
                  ]
                : entry.value,
          };
          final stagingCoverage = MessageCoverage(epoch: loaded.account.epoch)
            ..restore(
              epoch: loaded.account.epoch,
              eventHighWater: highWater,
              evictedBelow: loaded.account.evictedBelowMessageId,
              confirmed: false,
              intervalsByKey: adjustedIntervals,
            );
          if (reachesAboveHighWater && loaded.intervalsByKey.containsKey(key)) {
            stagingCoverage.dirtyKeys.add(key);
          }
          for (final entry in forgottenEntries) {
            stagingCoverage.forget(key, entry.keys, entry.id);
          }
          for (final bounds in intervals) {
            stagingCoverage.insert(
              key,
              CoverageInterval(
                bounds.lo,
                bounds.hi,
                epoch: 0,
                tracked: false,
                verifiedAt: now,
              ),
            );
          }
          final dirty = stagingCoverage.takeDirtyIntervals();
          if (dirty.isNotEmpty) {
            await db.replaceCoverageKeysInTxn(account.id, dirty);
          }
        }
        return true;
      });
    });
  });
  return committed ?? true;
}
