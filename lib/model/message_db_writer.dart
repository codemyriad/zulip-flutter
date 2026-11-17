import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../log.dart';
import 'message_database.dart';

/// Serializes message-DB writes for one account in strict FIFO order while
/// isolating read failures and poisoning writes for the rest of an epoch on
/// any write failure.
class MessageDbWriter {
  MessageDbWriter({
    required this.accountId,
    required this.openDb,
    this.debugBeforeWrite,
    this.debugBeforeRead,
  });

  final int accountId;
  final Future<MessageDatabase> Function() openDb;

  /// Test hooks run before each write/read operation if non-null.
  @visibleForTesting
  Future<void> Function()? debugBeforeWrite;
  @visibleForTesting
  Future<void> Function()? debugBeforeRead;

  Future<void> _tail = Future<void>.value();
  int _pendingWriteCount = 0;
  int _activePipelineCount = 0;
  int _maintenancePipelineCount = 0;
  final List<Completer<void>> _pipelineDrainWaiters = [];

  bool _poisoned = false;
  int _poisonGeneration = 0;

  /// Whether a write error or startup timeout has poisoned this writer
  /// for the remainder of the epoch.
  bool get isPoisoned => _poisoned;

  /// Whether no write jobs are currently running or queued.
  bool get isIdle => _pendingWriteCount == 0 && _activePipelineCount == 0;

  /// Whether no write jobs or non-maintenance pipelines are waiting behind
  /// the currently executing maintenance write job.
  bool get isIdleForMaintenance =>
    _pendingWriteCount <= 1 && (_activePipelineCount - _maintenancePipelineCount) == 0;

  /// Invoked synchronously when the writer becomes poisoned.
  VoidCallback? onPoisoned;

  Future<T> _enqueueFifo<T>(Future<T> Function() task) {
    _pendingWriteCount++;
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await task());
      } catch (e, s) {
        completer.completeError(e, s);
      } finally {
        _pendingWriteCount--;
      }
    });
    return completer.future;
  }

  /// Track an async multi-stage write pipeline (e.g. pre-write read + encode
  /// + [enqueueWrite]) so [drainForTesting] waits for the full pipeline.
  Future<T> runTrackedPipeline<T>(
    Future<T> Function() pipeline, {
    bool isMaintenance = false,
  }) async {
    _activePipelineCount++;
    if (isMaintenance) _maintenancePipelineCount++;
    try {
      return await pipeline();
    } finally {
      _activePipelineCount--;
      if (isMaintenance) _maintenancePipelineCount--;
      if (_activePipelineCount == 0 && _pipelineDrainWaiters.isNotEmpty) {
        final waiters = _pipelineDrainWaiters.toList();
        _pipelineDrainWaiters.clear();
        for (final w in waiters) {
          w.complete();
        }
      }
    }
  }

  /// Wait until all currently queued write jobs and tracked pipelines finish.
  Future<void> drainForTesting() async {
    while (_activePipelineCount > 0 || _pendingWriteCount > 0) {
      if (_activePipelineCount > 0) {
        final waiter = Completer<void>();
        _pipelineDrainWaiters.add(waiter);
        await waiter.future;
      }
      await _tail;
    }
  }

  /// Enqueue a write job on the account FIFO.
  ///
  /// When [isPoisoned] is true, [run] receives `removalOnly: true` and must
  /// only apply row deletions (`Delete` and `ChannelPurge`).
  /// Any thrown error is caught, logged, poisons the writer, best-effort writes
  /// `applied_through_event_id = NULL`, and resolves to `null`.
  Future<T?> enqueueWrite<T>(
    Future<T> Function(MessageDatabase db, {required bool removalOnly}) run,
  ) {
    return _enqueueFifo<T?>(() async {
      MessageDatabase? db;
      try {
        db = await openDb();
        if (debugBeforeWrite != null) {
          await debugBeforeWrite!();
        }
        return await run(db, removalOnly: _poisoned);
      } catch (e, s) {
        assert(debugLog('MessageDbWriter($accountId) write failed: $e\n$s'));
        await _poisonAndMarkDb(db);
        return null;
      }
    });
  }

  /// Enqueue an epoch initialization/bump job on the account FIFO.
  ///
  /// Passes `wasPoisoned: isPoisoned` so [run] wipes the account before
  /// writing new epoch state. Clears [isPoisoned] only when [run] succeeds.
  Future<T?> enqueueEpochStart<T>(
    Future<T> Function(MessageDatabase db, {required bool wasPoisoned}) run,
  ) {
    return _enqueueFifo<T?>(() async {
      MessageDatabase? db;
      try {
        db = await openDb();
        if (debugBeforeWrite != null) {
          await debugBeforeWrite!();
        }
        final startPoisonGen = _poisonGeneration;
        final result = await run(db, wasPoisoned: _poisoned);
        if (_poisonGeneration == startPoisonGen) {
          _poisoned = false;
          return result;
        }
        return null;
      } catch (e, s) {
        assert(debugLog('MessageDbWriter($accountId) epoch start failed: $e\n$s'));
        await _poisonAndMarkDb(db);
        return null;
      }
    });
  }

  /// Enqueue a best-effort poison marker (`applied_through_event_id = NULL`)
  /// and poison this writer immediately.
  Future<void> markPoisoned() {
    _poisonWriter();
    return _enqueueFifo<void>(() async {
      try {
        final db = await openDb();
        await _writePoisonMarker(db);
      } catch (e) {
        assert(debugLog('MessageDbWriter($accountId) markPoisoned failed: $e'));
      }
    });
  }

  /// Enqueue an account purge (on logout) after any prior queued writes.
  Future<void> enqueuePurge() {
    return _enqueueFifo<void>(() async {
      try {
        final db = await openDb();
        await db.purgeAccount(accountId);
      } catch (e) {
        assert(debugLog('MessageDbWriter($accountId) purge failed: $e'));
      }
    });
  }

  /// Run a read operation outside write-poisoning semantics.
  ///
  /// Returns `null` immediately if poisoned, or if the read throws.
  /// A read failure never poisons the writer.
  Future<T?> runRead<T>(Future<T> Function(MessageDatabase db) run) async {
    if (_poisoned) return null;
    try {
      final db = await openDb();
      if (_poisoned) return null;
      if (debugBeforeRead != null) {
        await debugBeforeRead!();
      }
      return await run(db);
    } catch (e, s) {
      assert(debugLog('MessageDbWriter($accountId) read failed: $e\n$s'));
      return null;
    }
  }

  /// Poison this writer in memory without enqueuing a DB marker write
  /// (used when disabling the message database at runtime before wiping).
  void poisonInMemoryOnly() {
    _poisonWriter();
  }

  void _poisonWriter() {
    _poisonGeneration++;
    if (!_poisoned) {
      _poisoned = true;
      onPoisoned?.call();
    }
  }

  Future<void> _poisonAndMarkDb(MessageDatabase? db) async {
    _poisonWriter();
    try {
      final targetDb = db ?? await openDb();
      await _writePoisonMarker(targetDb);
    } catch (e) {
      assert(debugLog('MessageDbWriter($accountId) poison marker failed: $e'));
    }
  }

  Future<void> _writePoisonMarker(MessageDatabase db) async {
    await (db.update(db.messageDbAccounts)
      ..where((a) => a.accountId.equals(accountId))
    ).write(const MessageDbAccountsCompanion(appliedThroughEventId: Value(null)));
  }
}
