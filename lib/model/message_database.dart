import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/common.dart';

import 'message_coverage.dart';
import 'message_search_text.dart';

part 'message_database.g.dart';

/// Location of the message cache database file.
///
/// Stored in its own subdirectory inside application support so it stays in the
/// app's own container (excluded from iOS App Group and backups along with
/// its `-wal` and `-shm` sidecars).
Future<File> messageDatabaseFile({bool createDir = true}) async {
  final dir = await getApplicationSupportDirectory();
  final subdir = Directory(p.join(dir.path, 'message-db'));
  if (createDir) {
    await subdir.create(recursive: true);
  }
  return File(p.join(subdir.path, 'zulip-messages.db'));
}

/// Configure SQLite pragmas for [MessageDatabase].
///
/// `auto_vacuum = INCREMENTAL` MUST run before `journal_mode = WAL` on a fresh
/// database file; otherwise SQLite silently ignores `auto_vacuum`.
void configureMessageDbPragmas(CommonDatabase rawDb) {
  rawDb.execute('PRAGMA auto_vacuum = INCREMENTAL;');
  rawDb.execute('PRAGMA journal_mode = WAL;');
  rawDb.execute('PRAGMA synchronous = NORMAL;');
  rawDb.execute('PRAGMA busy_timeout = 5000;');
  rawDb.execute('PRAGMA foreign_keys = ON;');
}

/// Per account: identity, epoch and watermark.
///
/// One row per account with any stored message-cache data.
@DataClassName('MessageDbAccount')
class MessageDbAccounts extends Table {
  IntColumn get accountId => integer()();
  TextColumn get realmUrl => text()();
  IntColumn get userId => integer()();
  IntColumn get formatVersion => integer()();
  IntColumn get epoch => integer()();
  TextColumn get queueId => text().nullable()();

  /// Every event with id <= this has had its effects committed here.
  ///
  /// Null after the writer was poisoned: the next start wipes the account's
  /// rows and coverage.
  IntColumn get appliedThroughEventId => integer().nullable()();

  /// Max message id among register `max_message_id` and `message` events
  /// applied in the current epoch. Open intervals close here on epoch end.
  IntColumn get eventHighWater => integer()();

  /// Unix seconds of the last successful poll applied in the current epoch.
  IntColumn get lastLiveAt => integer().nullable()();

  /// Rows with id < this were evicted or purged by retention.
  IntColumn get evictedBelowMessageId =>
    integer().withDefault(const Constant(0))();

  /// Running sum of stored message body bytes, kept by every write job.
  IntColumn get totalBodyBytes =>
    integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {accountId};
}

/// One row per stored message: small, frequently updated fields only.
@DataClassName('StoredMessage')
@TableIndex(name: 'idx_sm_topic', columns: {#accountId, #channelId, #topicKey, #id})
@TableIndex(name: 'idx_sm_channel', columns: {#accountId, #channelId, #id})
@TableIndex(name: 'idx_sm_dm', columns: {#accountId, #dmKey, #id})
class StoredMessages extends Table {
  IntColumn get accountId => integer()
    .references(MessageDbAccounts, #accountId, onDelete: KeyAction.cascade)();
  IntColumn get id => integer()();
  IntColumn get channelId => integer().nullable()();
  TextColumn get topic => text().nullable()();
  TextColumn get topicKey => text().nullable()();
  TextColumn get dmKey => text().nullable()();
  IntColumn get senderId => integer()();
  IntColumn get timestamp => integer()();
  IntColumn get flags => integer()();
  TextColumn get unknownFlags => text().nullable()();
  BoolColumn get isMeMessage => boolean()();
  IntColumn get editState => integer()();
  IntColumn get lastEditTimestamp => integer().nullable()();
  BoolColumn get displayRecipientCleared => boolean()();
  IntColumn get epoch => integer()();
  BoolColumn get tracked => boolean()();
  IntColumn get bodyBytes => integer()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, id};

  @override
  bool get withoutRowId => true;
}

/// Rendered content and stripped raw server JSON for a stored message.
///
/// Separate table so metadata-only updates (flags, topic) don't rewrite blobs.
@DataClassName('StoredMessageBody')
class StoredMessageBodies extends Table {
  IntColumn get accountId => integer()();
  IntColumn get messageId => integer()();
  TextColumn get content => text()();
  BlobColumn get json => blob()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, messageId};

  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (account_id, message_id) '
      'REFERENCES stored_messages (account_id, id) ON DELETE CASCADE',
  ];
}

/// One row per (message, user, emoji), in server order.
@DataClassName('StoredReaction')
@TableIndex(name: 'idx_sr_message', columns: {#accountId, #messageId, #seq})
class StoredReactions extends Table {
  IntColumn get accountId => integer()();
  IntColumn get messageId => integer()();
  IntColumn get seq => integer()();
  IntColumn get userId => integer()();
  TextColumn get reactionType => text()();
  TextColumn get emojiCode => text()();
  TextColumn get emojiName => text()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {accountId, messageId, userId, reactionType, emojiCode},
  ];

  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (account_id, message_id) '
      'REFERENCES stored_messages (account_id, id) ON DELETE CASCADE',
  ];
}

/// Raw submessages for polls and widgets.
@DataClassName('StoredSubmessage')
@TableIndex(name: 'idx_ss_message', columns: {#accountId, #messageId, #submessageId})
class StoredSubmessages extends Table {
  IntColumn get accountId => integer()();
  IntColumn get submessageId => integer()();
  IntColumn get messageId => integer()();
  IntColumn get senderId => integer()();
  TextColumn get msgType => text()();
  TextColumn get content => text()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, submessageId};

  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (account_id, message_id) '
      'REFERENCES stored_messages (account_id, id) ON DELETE CASCADE',
  ];
}

/// Persisted intervals of completeness.
@DataClassName('StoredCoverageInterval')
class CoverageIntervals extends Table {
  IntColumn get accountId => integer()
    .references(MessageDbAccounts, #accountId, onDelete: KeyAction.cascade)();
  TextColumn get narrowKey => text()();
  IntColumn get lo => integer()();
  IntColumn get hi => integer().nullable()();
  IntColumn get epoch => integer()();
  BoolColumn get tracked => boolean()();
  IntColumn get verifiedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, narrowKey, lo};
}

/// Per channel with rows or coverage: the membership regime its intervals
/// were written under.
@DataClassName('MessageDbChannel')
class MessageDbChannels extends Table {
  IntColumn get accountId => integer()
    .references(MessageDbAccounts, #accountId, onDelete: KeyAction.cascade)();
  IntColumn get channelId => integer()();
  BoolColumn get historyPublicToSubscribers => boolean()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, channelId};
}

/// Latest initial snapshot metadata per account for startup resumption.
class ServerSnapshots extends Table {
  IntColumn get accountId => integer()();

  TextColumn get realmUrl => text()();

  IntColumn get userId => integer()();

  /// The ID of the event queue the snapshot was registered with.
  TextColumn get queueId => text()();

  /// The ID of the last event received on the queue and recorded here.
  IntColumn get lastEventId => integer()();

  /// The app version that stored the snapshot, as "version+buildNumber".
  TextColumn get appVersion => text()();

  /// When the snapshot was registered, in seconds since the Unix epoch.
  IntColumn get timestamp => integer()();

  /// Whether events on this queue were left out of [ServerEventBatches].
  BoolColumn get eventLogTruncated => boolean()
    .withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {accountId};
}

/// Raw UTF-8 JSON body of the account's [ServerSnapshot].
class ServerSnapshotBlobs extends Table {
  IntColumn get accountId => integer()
    .references(ServerSnapshots, #accountId, onDelete: KeyAction.cascade)();

  BlobColumn get data => blob()();

  @override
  Set<Column<Object>> get primaryKey => {accountId};
}

/// Recorded batches of events received since the account's [ServerSnapshot].
@DataClassName('ServerEventBatch')
@TableIndex(name: 'idx_server_event_batches_account_id', columns: {#accountId})
class ServerEventBatches extends Table {
  IntColumn get id => integer().autoIncrement()();

  IntColumn get accountId => integer()
    .references(ServerSnapshots, #accountId, onDelete: KeyAction.cascade)();

  TextColumn get queueId => text()();

  IntColumn get lastEventId => integer()();

  BlobColumn get data => blob()();
}

@DriftDatabase(tables: [
  MessageDbAccounts,
  StoredMessages,
  StoredMessageBodies,
  StoredReactions,
  StoredSubmessages,
  CoverageIntervals,
  MessageDbChannels,
  ServerSnapshots,
  ServerSnapshotBlobs,
  ServerEventBatches,
])
class MessageDatabase extends _$MessageDatabase {
  MessageDatabase(super.e);

  /// Open the message database at [file] in a background isolate.
  factory MessageDatabase.openFile(File file) {
    return MessageDatabase(NativeDatabase.createInBackground(
      file,
      setup: configureMessageDbPragmas,
    ));
  }

  /// Current record encoding version; mismatches wipe that account's cache.
  static const int currentFormatVersion = 1;

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _createFtsObjects();
    },
    // Cache semantics: everything here can be refetched, except when upgrading
    // in place for additive indexes/FTS tables so offline startup keeps
    // existing snapshots and cached messages intact.
    onUpgrade: (m, from, to) async {
      if (from == 1 && to == 2) {
        final cols = await customSelect('PRAGMA table_info(server_snapshots)').get();
        final colNames = {for (final r in cols) r.read<String>('name')};
        if (!colNames.contains('realm_url')) {
          await customStatement(
            "ALTER TABLE server_snapshots ADD COLUMN realm_url TEXT NOT NULL DEFAULT ''");
        }
        if (!colNames.contains('user_id')) {
          await customStatement(
            'ALTER TABLE server_snapshots ADD COLUMN user_id INTEGER NOT NULL DEFAULT 0');
        }
        await _createFtsObjects();
        await _backfillFtsFromExistingRows();
        return;
      }
      await _dropAllTables(m);
      await m.createAll();
      await _createFtsObjects();
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  Future<void> _createFtsObjects() async {
    await customStatement(
      'CREATE VIRTUAL TABLE IF NOT EXISTS stored_message_fts USING fts5('
      'account_id UNINDEXED, '
      'message_id UNINDEXED, '
      'topic_text, '
      'body_text, '
      "tokenize = 'unicode61 remove_diacritics 2'"
      ')',
    );
    await customStatement(
      'CREATE TRIGGER IF NOT EXISTS trg_stored_message_bodies_delete_fts '
      'AFTER DELETE ON stored_message_bodies '
      'BEGIN '
      'DELETE FROM stored_message_fts WHERE rowid = old.rowid; '
      'END',
    );
  }

  Future<void> _backfillFtsFromExistingRows() async {
    final submsgRows = await customSelect(
      'SELECT account_id, message_id, sender_id, content '
      'FROM stored_submessages '
      'ORDER BY account_id ASC, message_id ASC, submessage_id ASC',
    ).get();
    final submessagesByKey = <(int, int), List<({int senderId, String content})>>{};
    for (final row in submsgRows) {
      final key = (row.read<int>('account_id'), row.read<int>('message_id'));
      (submessagesByKey[key] ??= []).add((
        senderId: row.read<int>('sender_id'),
        content: row.read<String>('content'),
      ));
    }

    var lastRowId = 0;
    while (true) {
      final batch = await customSelect(
        'SELECT b.rowid AS body_rowid, b.account_id, b.message_id, b.content, '
        'm.topic, m.sender_id '
        'FROM stored_message_bodies b '
        'JOIN stored_messages m '
        '  ON m.account_id = b.account_id AND m.id = b.message_id '
        'WHERE b.rowid > ? '
        'ORDER BY b.rowid ASC '
        'LIMIT 250',
        variables: [Variable.withInt(lastRowId)],
      ).get();
      if (batch.isEmpty) break;

      for (final row in batch) {
        final bodyRowId = row.read<int>('body_rowid');
        final accountId = row.read<int>('account_id');
        final messageId = row.read<int>('message_id');
        final senderId = row.read<int>('sender_id');
        final htmlContent = row.read<String>('content');
        final topicText = row.readNullable<String>('topic') ?? '';
        final subs = submessagesByKey[(accountId, messageId)] ?? const [];
        final bodyText = extractMessageSearchBodyText(
          htmlContent: htmlContent,
          messageSenderId: senderId,
          submessages: subs,
        );
        await customInsert(
          'INSERT OR REPLACE INTO stored_message_fts '
          '(rowid, account_id, message_id, topic_text, body_text) '
          'VALUES (?, ?, ?, ?, ?)',
          variables: [
            Variable.withInt(bodyRowId),
            Variable.withInt(accountId),
            Variable.withInt(messageId),
            Variable.withString(topicText),
            Variable.withString(bodyText),
          ],
        );
        lastRowId = bodyRowId;
      }
    }
  }

  Future<void> _dropAllTables(Migrator m) async {
    await customStatement('PRAGMA foreign_keys = OFF');
    try {
      await customStatement('DROP TRIGGER IF EXISTS trg_stored_message_bodies_delete_fts');
      await customStatement('DROP TABLE IF EXISTS stored_message_fts');
      for (final table in allTables.toList().reversed) {
        await m.deleteTable(table.actualTableName);
      }
    } finally {
      await customStatement('PRAGMA foreign_keys = ON');
    }
  }

  /// Verify an account's stored metadata against ([realmUrl], [userId]) and
  /// [currentFormatVersion], wiping the account's data if anything mismatches
  /// or if its writer was poisoned ([MessageDbAccount.appliedThroughEventId] is null).
  ///
  /// Returns the existing valid row, or `null` if none exists (or was wiped).
  Future<MessageDbAccount?> ensureAccount({
    required int accountId,
    required Uri realmUrl,
    required int userId,
  }) {
    return transaction(() => ensureAccountInTxn(
      accountId: accountId,
      realmUrl: realmUrl,
      userId: userId,
    ));
  }

  /// Like [ensureAccount], for callers already inside a transaction.
  Future<MessageDbAccount?> ensureAccountInTxn({
    required int accountId,
    required Uri realmUrl,
    required int userId,
  }) async {
    final existing = await (select(messageDbAccounts)
      ..where((a) => a.accountId.equals(accountId))).getSingleOrNull();
    if (existing == null) return null;

    final valid = existing.realmUrl == realmUrl.toString()
      && existing.userId == userId
      && existing.formatVersion == currentFormatVersion
      && existing.appliedThroughEventId != null;
    if (valid) return existing;

    await wipeAccount(accountId);
    return null;
  }

  /// Load the account metadata, coverage intervals, channel table, and
  /// all channel IDs that currently hold stored rows or coverage intervals.
  Future<LoadedMessageDbAccountState?> loadAccountStateInTxn(int accountId) async {
    final account = await (select(messageDbAccounts)
      ..where((a) => a.accountId.equals(accountId))).getSingleOrNull();
    if (account == null) return null;

    final intervalRows = await (select(coverageIntervals)
      ..where((c) => c.accountId.equals(accountId))
      ..orderBy([(c) => OrderingTerm.asc(c.lo)])).get();
    final intervalsByKey = <String, List<CoverageInterval>>{};
    final channelsWithData = <int>{};
    for (final row in intervalRows) {
      (intervalsByKey[row.narrowKey] ??= []).add(CoverageInterval(
        row.lo,
        row.hi,
        epoch: row.epoch,
        tracked: row.tracked,
        verifiedAt: row.verifiedAt,
      ));
      final cid = CoverageKeys.channelIdOf(row.narrowKey);
      if (cid != null) channelsWithData.add(cid);
    }

    final channelRows = await (select(messageDbChannels)
      ..where((c) => c.accountId.equals(accountId))).get();
    final channels = <int, bool>{
      for (final row in channelRows)
        row.channelId: row.historyPublicToSubscribers,
    };
    channelsWithData.addAll(channels.keys);

    final storedChannelRows = await customSelect(
      'SELECT DISTINCT channel_id FROM stored_messages '
      'WHERE account_id = ? AND channel_id IS NOT NULL',
      variables: [Variable.withInt(accountId)],
    ).get();
    for (final row in storedChannelRows) {
      final cid = row.readNullable<int>('channel_id');
      if (cid != null) channelsWithData.add(cid);
    }

    return (
      account: account,
      intervalsByKey: intervalsByKey,
      channels: channels,
      channelsWithData: channelsWithData,
    );
  }

  /// Insert or update the account metadata row.
  Future<void> upsertAccountInTxn({
    required int accountId,
    required Uri realmUrl,
    required int userId,
    required int epoch,
    required String? queueId,
    required int? appliedThroughEventId,
    required int eventHighWater,
    required int? lastLiveAt,
    int evictedBelowMessageId = 0,
    int totalBodyBytes = 0,
  }) async {
    await into(messageDbAccounts).insertOnConflictUpdate(
      MessageDbAccountsCompanion(
        accountId: Value(accountId),
        realmUrl: Value(realmUrl.toString()),
        userId: Value(userId),
        formatVersion: const Value(currentFormatVersion),
        epoch: Value(epoch),
        queueId: Value(queueId),
        appliedThroughEventId: Value(appliedThroughEventId),
        eventHighWater: Value(eventHighWater),
        lastLiveAt: Value(lastLiveAt),
        evictedBelowMessageId: Value(evictedBelowMessageId),
        totalBodyBytes: Value(totalBodyBytes),
      ),
    );
  }

  /// Update the account row for a new epoch while preserving
  /// [MessageDbAccounts.evictedBelowMessageId] and
  /// [MessageDbAccounts.totalBodyBytes].
  Future<void> updateAccountEpochInTxn({
    required int accountId,
    required int epoch,
    required String? queueId,
    required int? appliedThroughEventId,
    required int eventHighWater,
    required int? lastLiveAt,
  }) async {
    await (update(messageDbAccounts)..where((a) => a.accountId.equals(accountId))).write(
      MessageDbAccountsCompanion(
        epoch: Value(epoch),
        queueId: Value(queueId),
        appliedThroughEventId: Value(appliedThroughEventId),
        eventHighWater: Value(eventHighWater),
        lastLiveAt: Value(lastLiveAt),
      ),
    );
  }

  /// Update [MessageDbAccounts.lastLiveAt] for [accountId].
  Future<void> updateLastLiveAtInTxn(int accountId, int lastLiveAt) async {
    await (update(messageDbAccounts)
      ..where((a) => a.accountId.equals(accountId)))
      .write(MessageDbAccountsCompanion(lastLiveAt: Value(lastLiveAt)));
  }

  /// Read the current epoch and `applied_through_event_id` for [accountId].
  Future<({int epoch, int? appliedThroughEventId})?> loadAccountEpochAndWatermarkInTxn(
    int accountId,
  ) async {
    final row = await (select(messageDbAccounts)
      ..where((a) => a.accountId.equals(accountId)))
      .getSingleOrNull();
    if (row == null) return null;
    return (
      epoch: row.epoch,
      appliedThroughEventId: row.appliedThroughEventId,
    );
  }

  /// Advance [appliedThroughEventId] (when non-null), [eventHighWater], and
  /// [lastLiveAt] for [accountId] inside a transaction.
  Future<void> updateAccountEventProgressInTxn({
    required int accountId,
    int? appliedThroughEventId,
    required int eventHighWater,
    required int lastLiveAt,
  }) async {
    await customUpdate(
      'UPDATE message_db_accounts SET '
      'applied_through_event_id = COALESCE(?, applied_through_event_id), '
      'event_high_water = MAX(event_high_water, ?), '
      'last_live_at = ? '
      'WHERE account_id = ?',
      variables: [
        appliedThroughEventId != null
          ? Variable.withInt(appliedThroughEventId)
          : const Variable(null),
        Variable.withInt(eventHighWater),
        Variable.withInt(lastLiveAt),
        Variable.withInt(accountId),
      ],
      updates: {messageDbAccounts},
    );
  }

  /// Query the stored channel, folded topic, and DM key for any messages in
  /// [messageIds] currently persisted for [accountId].
  Future<Map<int, ({int? channelId, String? topicKey, String? dmKey})>>
      queryStoredLocationsByIds(
    int accountId,
    Iterable<int> messageIds,
  ) async {
    final ids = messageIds.toList();
    if (ids.isEmpty) return const {};
    final rows = await customSelect(
      'SELECT id, channel_id, topic_key, dm_key FROM stored_messages '
      'WHERE account_id = ? AND id IN (SELECT value FROM json_each(?))',
      variables: [
        Variable.withInt(accountId),
        Variable.withString(jsonEncode(ids)),
      ],
    ).get();
    return {
      for (final row in rows)
        row.read<int>('id'): (
          channelId: row.readNullable<int>('channel_id'),
          topicKey: row.readNullable<String>('topic_key'),
          dmKey: row.readNullable<String>('dm_key'),
        ),
    };
  }

  /// Purge all stored messages and channel metadata for [channelId],
  /// maintaining [MessageDbAccounts.totalBodyBytes].
  Future<void> purgeChannelDataInTxn(int accountId, int channelId) async {
    final sumRow = await customSelect(
      'SELECT COALESCE(SUM(body_bytes), 0) AS total FROM stored_messages '
      'WHERE account_id = ? AND channel_id = ?',
      variables: [Variable.withInt(accountId), Variable.withInt(channelId)],
    ).getSingle();
    final removedBytes = sumRow.read<int>('total');
    await customUpdate(
      'DELETE FROM stored_messages WHERE account_id = ? AND channel_id = ?',
      variables: [Variable.withInt(accountId), Variable.withInt(channelId)],
      updates: {storedMessages},
    );
    await customUpdate(
      'DELETE FROM message_db_channels WHERE account_id = ? AND channel_id = ?',
      variables: [Variable.withInt(accountId), Variable.withInt(channelId)],
      updates: {messageDbChannels},
    );
    if (removedBytes != 0) {
      await customUpdate(
        'UPDATE message_db_accounts '
        'SET total_body_bytes = MAX(0, total_body_bytes - ?) '
        'WHERE account_id = ?',
        variables: [Variable.withInt(removedBytes), Variable.withInt(accountId)],
        updates: {messageDbAccounts},
      );
    }
  }

  /// Purge all stored messages and channel metadata for each channel in [channelIds].
  Future<void> purgeChannelsInTxn(int accountId, Iterable<int> channelIds) async {
    for (final channelId in channelIds) {
      await purgeChannelDataInTxn(accountId, channelId);
    }
  }

  /// Delete stored DM rows proved deleted by a fresh `/register` snapshot:
  /// any DM row with `id > maxMessageId`, and any row in a listed DM
  /// conversation whose `id > listedDmLatestIds[dmKey]`.
  Future<void> dropDeletedDmRowsInTxn(
    int accountId, {
    required int? maxMessageId,
    required Map<String, int> listedDmLatestIds,
  }) async {
    const chunkLimit = 500;
    final idsToDelete = <int>{};
    var removedBytes = 0;

    if (maxMessageId != null) {
      final rows = await customSelect(
        'SELECT id, body_bytes FROM stored_messages '
        'WHERE account_id = ? AND dm_key IS NOT NULL AND id > ?',
        variables: [Variable.withInt(accountId), Variable.withInt(maxMessageId)],
      ).get();
      for (final row in rows) {
        if (idsToDelete.add(row.read<int>('id'))) {
          removedBytes += row.read<int>('body_bytes');
        }
      }
    }

    if (listedDmLatestIds.isNotEmpty) {
      final rows = await customSelect(
        'SELECT m.id, m.body_bytes '
        'FROM json_each(?) AS c '
        'JOIN stored_messages AS m '
        '  ON m.account_id = ? '
        ' AND m.dm_key = c.key '
        ' AND m.id > CAST(c.value AS INTEGER)',
        variables: [
          Variable.withString(jsonEncode(listedDmLatestIds)),
          Variable.withInt(accountId),
        ],
      ).get();
      for (final row in rows) {
        if (idsToDelete.add(row.read<int>('id'))) {
          removedBytes += row.read<int>('body_bytes');
        }
      }
    }

    if (idsToDelete.isEmpty) return;
    final idList = idsToDelete.toList();
    for (var start = 0; start < idList.length; start += chunkLimit) {
      final end = math.min(start + chunkLimit, idList.length);
      await customUpdate(
        'DELETE FROM stored_messages '
        'WHERE account_id = ? AND id IN (SELECT value FROM json_each(?))',
        variables: [
          Variable.withInt(accountId),
          Variable.withString(jsonEncode(idList.sublist(start, end))),
        ],
        updates: {storedMessages},
      );
    }
    if (removedBytes > 0) {
      await customUpdate(
        'UPDATE message_db_accounts '
        'SET total_body_bytes = MAX(0, total_body_bytes - ?) '
        'WHERE account_id = ?',
        variables: [Variable.withInt(removedBytes), Variable.withInt(accountId)],
        updates: {messageDbAccounts},
      );
    }
  }

  /// Replace stored coverage intervals for the keys in [intervalsByKey],
  /// clipping at [MessageDbAccounts.evictedBelowMessageId].
  Future<void> replaceCoverageKeysInTxn(
    int accountId,
    Map<String, List<CoverageInterval>> intervalsByKey,
  ) async {
    if (intervalsByKey.isEmpty) return;
    final acctRow = await (select(messageDbAccounts)
      ..where((a) => a.accountId.equals(accountId))).getSingleOrNull();
    final evictedBelow = acctRow?.evictedBelowMessageId ?? 0;

    final keys = intervalsByKey.keys.toList();
    await (delete(coverageIntervals)
      ..where((c) => c.accountId.equals(accountId) & c.narrowKey.isIn(keys)))
      .go();
    final toInsert = <CoverageIntervalsCompanion>[];
    for (final entry in intervalsByKey.entries) {
      for (final r in entry.value) {
        if ((r.hi ?? kNewestMessageId) < evictedBelow) continue;
        final lo = math.max(r.lo, evictedBelow);
        if (r.hi != null && lo > r.hi!) continue;
        toInsert.add(CoverageIntervalsCompanion.insert(
          accountId: accountId,
          narrowKey: entry.key,
          lo: lo,
          hi: Value(r.hi),
          epoch: r.epoch,
          tracked: r.tracked,
          verifiedAt: r.verifiedAt,
        ));
      }
    }
    if (toInsert.isNotEmpty) {
      await batch((b) => b.insertAll(coverageIntervals, toInsert));
    }
  }

  /// Upsert tracked channel history visibility flags and remove dropped channels.
  Future<void> upsertChannelsInTxn(
    int accountId,
    Map<int, bool> channels, {
    Iterable<int> removeChannelIds = const [],
  }) async {
    final removed = removeChannelIds.toList();
    if (removed.isNotEmpty) {
      await (delete(messageDbChannels)
        ..where((c) => c.accountId.equals(accountId) & c.channelId.isIn(removed)))
        .go();
    }
    if (channels.isNotEmpty) {
      await batch((b) => b.insertAllOnConflictUpdate(messageDbChannels, [
        for (final entry in channels.entries)
          MessageDbChannelsCompanion.insert(
            accountId: accountId,
            channelId: entry.key,
            historyPublicToSubscribers: entry.value,
          ),
      ]));
    }
  }

  /// Query stored message locations matching a coverage scope within [intervals].
  ///
  /// Exactly one of [channelId] (with optional [topicKey]) or [dmKey] must be
  /// provided to identify the scope (`ChannelNarrow`, `TopicNarrow`, or `DmNarrow`).
  Future<List<StoredCoverageRow>> queryStoredInCoverageScope(
    int accountId, {
    int? channelId,
    String? topicKey,
    String? dmKey,
    required List<FetchBounds> intervals,
  }) async {
    assert((channelId != null) ^ (dmKey != null));
    if (intervals.isEmpty) return const [];

    final vars = <Variable<Object>>[Variable.withInt(accountId)];
    final scopeSql = StringBuffer();
    if (channelId != null) {
      scopeSql.write('channel_id = ?');
      vars.add(Variable.withInt(channelId));
      if (topicKey != null) {
        scopeSql.write(' AND topic_key = ?');
        vars.add(Variable.withString(topicKey));
      }
    } else {
      scopeSql.write('dm_key = ?');
      vars.add(Variable.withString(dmKey!));
    }

    final rangeClauses = <String>[];
    for (final b in intervals) {
      if (b.hi != null) {
        rangeClauses.add('(id >= ? AND id <= ?)');
        vars.add(Variable.withInt(b.lo));
        vars.add(Variable.withInt(b.hi!));
      } else {
        rangeClauses.add('id >= ?');
        vars.add(Variable.withInt(b.lo));
      }
    }

    final rows = await customSelect(
      'SELECT id, channel_id, topic, topic_key, dm_key FROM stored_messages '
      'WHERE account_id = ? AND $scopeSql AND (${rangeClauses.join(' OR ')})',
      variables: vars,
    ).get();
    return [
      for (final row in rows)
        (
          id: row.read<int>('id'),
          channelId: row.readNullable<int>('channel_id'),
          topic: row.readNullable<String>('topic'),
          topicKey: row.readNullable<String>('topic_key'),
          dmKey: row.readNullable<String>('dm_key'),
        ),
    ];
  }

  /// Update only `epoch` and `tracked` for unchanged clobbered messages.
  ///
  /// Returns any IDs from [messageIds] that had no existing row in SQLite.
  Future<Set<int>> touchUnchangedStoredMessagesInTxn(
    int accountId,
    Iterable<int> messageIds, {
    required int epoch,
    required Map<int, bool> trackedById,
  }) async {
    final ids = messageIds.toSet();
    if (ids.isEmpty) return const {};

    final existingRows = await customSelect(
      'SELECT id FROM stored_messages '
      'WHERE account_id = ? AND id IN (SELECT value FROM json_each(?))',
      variables: [
        Variable.withInt(accountId),
        Variable.withString(jsonEncode(ids.toList())),
      ],
    ).get();
    final existingIds = {
      for (final row in existingRows) row.read<int>('id'),
    };
    final missing = ids.difference(existingIds);
    if (existingIds.isEmpty) return missing;

    final trackedIds = <int>[];
    final untrackedIds = <int>[];
    for (final id in existingIds) {
      if (trackedById[id] ?? true) {
        trackedIds.add(id);
      } else {
        untrackedIds.add(id);
      }
    }
    if (trackedIds.isNotEmpty) {
      await customUpdate(
        'UPDATE stored_messages SET epoch = ?, tracked = 1 '
        'WHERE account_id = ? AND id IN (SELECT value FROM json_each(?))',
        variables: [
          Variable.withInt(epoch),
          Variable.withInt(accountId),
          Variable.withString(jsonEncode(trackedIds)),
        ],
        updates: {storedMessages},
      );
    }
    if (untrackedIds.isNotEmpty) {
      await customUpdate(
        'UPDATE stored_messages SET epoch = ?, tracked = 0 '
        'WHERE account_id = ? AND id IN (SELECT value FROM json_each(?))',
        variables: [
          Variable.withInt(epoch),
          Variable.withInt(accountId),
          Variable.withString(jsonEncode(untrackedIds)),
        ],
        updates: {storedMessages},
      );
    }
    return missing;
  }

  Expression<bool> _scopePredicate(
    $StoredMessagesTable t,
    int accountId, {
    int? channelId,
    String? topicKey,
    String? dmKey,
  }) {
    assert((channelId != null) ^ (dmKey != null));
    var expr = t.accountId.equals(accountId);
    if (channelId != null) {
      expr = expr & t.channelId.equals(channelId);
      if (topicKey != null) {
        expr = expr & t.topicKey.equals(topicKey);
      }
    } else {
      expr = expr & t.dmKey.equals(dmKey!);
    }
    return expr;
  }

  Expression<bool> _chainPredicate($StoredMessagesTable t, CoverageChain chain) {
    var expr = t.id.isBiggerOrEqualValue(chain.lo);
    if (chain.hi case final hi?) {
      expr = expr & t.id.isSmallerOrEqualValue(hi);
    }
    return expr;
  }

  /// Whether at least one row in the given scope exists within [chain].
  Future<bool> hasAnyStoredInChain(
    int accountId, {
    int? channelId,
    String? topicKey,
    String? dmKey,
    required CoverageChain chain,
  }) async {
    final row = await (select(storedMessages)
      ..where((t) =>
        _scopePredicate(t, accountId,
          channelId: channelId, topicKey: topicKey, dmKey: dmKey)
        & _chainPredicate(t, chain))
      ..limit(1))
      .getSingleOrNull();
    return row != null;
  }

  /// Whether message [messageId] is currently stored for [accountId].
  Future<bool> hasStoredMessage(int accountId, int messageId) async {
    final row = await (selectOnly(storedMessages)
      ..addColumns([storedMessages.id])
      ..where(storedMessages.accountId.equals(accountId)
        & storedMessages.id.equals(messageId))
      ..limit(1))
      .getSingleOrNull();
    return row != null;
  }

  /// Whether any background-prefetched (`epoch == 0`) row exists for [accountId]
  /// with `id > messageId`.
  Future<bool> hasPrefetchedRowAboveInTxn(int accountId, int messageId) async {
    final row = await customSelect(
      'SELECT 1 FROM stored_messages '
      'WHERE account_id = ? AND epoch = 0 AND id > ? LIMIT 1',
      variables: [Variable.withInt(accountId), Variable.withInt(messageId)],
    ).getSingleOrNull();
    return row != null;
  }

  /// Count up to [limit] stored messages in scope within `[lo, beforeId)`.
  Future<int> countStoredBeforeInScope(
    int accountId, {
    int? channelId,
    String? topicKey,
    String? dmKey,
    required int lo,
    required int beforeId,
    required int limit,
  }) async {
    if (limit <= 0 || beforeId <= lo) return 0;
    final rows = await (selectOnly(storedMessages)
      ..addColumns([storedMessages.id])
      ..where(_scopePredicate(storedMessages, accountId,
          channelId: channelId, topicKey: topicKey, dmKey: dmKey)
        & storedMessages.id.isBiggerOrEqualValue(lo)
        & storedMessages.id.isSmallerThanValue(beforeId))
      ..limit(limit))
      .get();
    return rows.length;
  }

  /// Return the greatest stored message ID in scope that falls inside any of
  /// [chains], or `null` if none exists.
  Future<int?> greatestStoredIdInChains(
    int accountId, {
    int? channelId,
    String? topicKey,
    String? dmKey,
    required List<CoverageChain> chains,
  }) async {
    if (chains.isEmpty) return null;
    final row = await (select(storedMessages)
      ..where((t) {
        Expression<bool> chainsExpr = _chainPredicate(t, chains.first);
        for (int i = 1; i < chains.length; i++) {
          chainsExpr = chainsExpr | _chainPredicate(t, chains[i]);
        }
        return _scopePredicate(t, accountId,
            channelId: channelId, topicKey: topicKey, dmKey: dmKey)
          & chainsExpr;
      })
      ..orderBy([(t) => OrderingTerm.desc(t.id)])
      ..limit(1))
      .getSingleOrNull();
    return row?.id;
  }

  /// Load full stored message records (header, body, reactions, submessages)
  /// for [messageIds].
  Future<List<LoadedStoredMessage>> loadFullMessagesByIds(
    int accountId,
    List<int> messageIds,
  ) {
    if (messageIds.isEmpty) return Future.value(const []);
    return transaction(() => _loadStoredRecordsInTxn(
      accountId,
      initialRows: const [],
      extraIds: messageIds,
    ));
  }

  /// Return stored topics for [channelId] grouped by [StoredMessages.topicKey],
  /// with display [topic] taken from the row with `MAX(id)`.
  Future<List<({String topic, String topicKey, int maxId})>>
      queryStoredChannelTopics(
    int accountId,
    int channelId, {
    Set<int> excludeIds = const {},
  }) async {
    final excludeClause = excludeIds.isEmpty
      ? ''
      : ' AND id NOT IN (SELECT value FROM json_each(?))';
    final rows = await customSelect(
      'SELECT topic, topic_key, MAX(id) AS max_id '
      'FROM stored_messages '
      'WHERE account_id = ? AND channel_id = ? AND topic_key IS NOT NULL'
      '$excludeClause '
      'GROUP BY topic_key '
      'ORDER BY max_id DESC',
      variables: [
        Variable.withInt(accountId),
        Variable.withInt(channelId),
        if (excludeIds.isNotEmpty) Variable.withString(jsonEncode(excludeIds.toList())),
      ],
      readsFrom: {storedMessages},
    ).get();
    return [
      for (final row in rows)
        (
          topic: row.read<String?>('topic') ?? row.read<String>('topic_key'),
          topicKey: row.read<String>('topic_key'),
          maxId: row.read<int>('max_id'),
        ),
    ];
  }

  /// Load a local window of stored rows for a narrow scope within [chain] around
  /// [anchorId], plus any [extraIds] (such as moved-in rows from the race buffer).
  Future<StoredWindowQueryResult> queryWindowRows(
    int accountId, {
    int? channelId,
    String? topicKey,
    String? dmKey,
    required CoverageChain chain,
    required int anchorId,
    required int before,
    required int after,
    List<int> extraIds = const [],
  }) {
    return transaction(() async {
      final rawBelowRows = before > 0
        ? await (select(storedMessages)
            ..where((t) =>
              _scopePredicate(t, accountId,
                channelId: channelId, topicKey: topicKey, dmKey: dmKey)
              & _chainPredicate(t, chain)
              & t.id.isSmallerThanValue(anchorId))
            ..orderBy([(t) => OrderingTerm.desc(t.id)])
            ..limit(before + 1))
          .get()
        : const <StoredMessage>[];
      final hasMoreBefore = before > 0 && rawBelowRows.length > before;
      final belowRows = hasMoreBefore ? rawBelowRows.sublist(0, before) : rawBelowRows;

      final rawAtOrAboveRows = await (select(storedMessages)
        ..where((t) =>
          _scopePredicate(t, accountId,
            channelId: channelId, topicKey: topicKey, dmKey: dmKey)
          & _chainPredicate(t, chain)
          & t.id.isBiggerOrEqualValue(anchorId))
        ..orderBy([(t) => OrderingTerm.asc(t.id)])
        ..limit(after + 2))
        .get();
      final hasMoreAfter = rawAtOrAboveRows.length > after + 1;
      final atOrAboveRows = hasMoreAfter
        ? rawAtOrAboveRows.sublist(0, after + 1)
        : rawAtOrAboveRows;

      final initialRows = <StoredMessage>[
        ...belowRows.reversed,
        ...atOrAboveRows,
      ];
      final records = await _loadStoredRecordsInTxn(
        accountId,
        initialRows: initialRows,
        extraIds: extraIds,
      );
      return (
        records: records,
        hasMoreBefore: hasMoreBefore,
        hasMoreAfter: hasMoreAfter,
      );
    });
  }

  Future<List<LoadedStoredMessage>> _loadStoredRecordsInTxn(
    int accountId, {
    required List<StoredMessage> initialRows,
    required List<int> extraIds,
  }) async {
    final rowById = <int, StoredMessage>{
      for (final r in initialRows) r.id: r,
    };
    final missingIds = <int>[
      for (final id in extraIds)
        if (!rowById.containsKey(id)) id,
    ];
    if (missingIds.isNotEmpty) {
      final extraRows = await (select(storedMessages)
        ..where((t) => t.accountId.equals(accountId) & t.id.isIn(missingIds)))
        .get();
      for (final r in extraRows) {
        rowById[r.id] = r;
      }
    }
    if (rowById.isEmpty) return const [];

    final allIds = rowById.keys.toList()..sort();
    final bodyRows = await (select(storedMessageBodies)
      ..where((t) => t.accountId.equals(accountId) & t.messageId.isIn(allIds)))
      .get();
    final bodyById = {for (final b in bodyRows) b.messageId: b};

    final reactionRows = await (select(storedReactions)
      ..where((t) => t.accountId.equals(accountId) & t.messageId.isIn(allIds))
      ..orderBy([(t) => OrderingTerm.asc(t.seq)]))
      .get();
    final reactionsById = <int, List<StoredReaction>>{};
    for (final r in reactionRows) {
      (reactionsById[r.messageId] ??= []).add(r);
    }

    final submessageRows = await (select(storedSubmessages)
      ..where((t) => t.accountId.equals(accountId) & t.messageId.isIn(allIds))
      ..orderBy([(t) => OrderingTerm.asc(t.submessageId)]))
      .get();
    final submessagesById = <int, List<StoredSubmessage>>{};
    for (final s in submessageRows) {
      (submessagesById[s.messageId] ??= []).add(s);
    }

    return [
      for (final id in allIds)
        if (bodyById[id] case final body?)
          (
            row: rowById[id]!,
            body: body,
            reactions: reactionsById[id] ?? const [],
            submessages: submessagesById[id] ?? const [],
          ),
    ];
  }

  /// Search stored messages for [accountId] matching [spec] using FTS5 and
  /// SQL metadata pushdown, ordered descending by [StoredMessages.id].
  ///
  /// When [beforeMessageId] is provided, only messages with `id < beforeMessageId`
  /// are considered. Returns at most [limit] full message records.
  Future<List<LoadedStoredMessage>> searchStoredMessages(
    int accountId, {
    required StoredMessageSearchSpec spec,
    int? beforeMessageId,
    required int limit,
  }) {
    if (limit <= 0) return Future.value(const []);
    if (spec.allowedChannelIds != null && spec.allowedChannelIds!.isEmpty) {
      return Future.value(const []);
    }
    if (spec.allowedSenderIds != null && spec.allowedSenderIds!.isEmpty) {
      return Future.value(const []);
    }
    if (spec.allowedMessageIds != null && spec.allowedMessageIds!.isEmpty) {
      return Future.value(const []);
    }
    if (spec.exactMessageId != null
        && (spec.excludedMessageIds.contains(spec.exactMessageId)
            || (beforeMessageId != null && spec.exactMessageId! >= beforeMessageId))) {
      return Future.value(const []);
    }

    return transaction(() async {
      final sql = StringBuffer();
      final vars = <Variable<Object>>[];

      final hasPosFts = spec.positiveFtsMatch != null;
      final hasNegFts = spec.negatedFtsMatch != null;
      if (hasPosFts) {
        sql.write(
          'SELECT m.id FROM stored_message_fts '
          'JOIN stored_messages m '
          '  ON m.account_id = stored_message_fts.account_id '
          ' AND m.id = stored_message_fts.message_id '
          'WHERE stored_message_fts MATCH ? '
          '  AND stored_message_fts.account_id = ?',
        );
        vars.add(Variable.withString(spec.positiveFtsMatch!));
        vars.add(Variable.withInt(accountId));
        if (beforeMessageId != null) {
          sql.write(' AND stored_message_fts.message_id < ?');
          vars.add(Variable.withInt(beforeMessageId));
        }
        if (hasNegFts) {
          sql.write(
            ' AND stored_message_fts.rowid NOT IN ('
            'SELECT rowid FROM stored_message_fts '
            'WHERE stored_message_fts MATCH ? AND account_id = ?'
            ')',
          );
          vars.add(Variable.withString(spec.negatedFtsMatch!));
          vars.add(Variable.withInt(accountId));
        }
      } else {
        sql.write('SELECT m.id FROM stored_messages m ');
        if (hasNegFts) {
          sql.write(
            'JOIN stored_message_bodies b '
            '  ON b.account_id = m.account_id AND b.message_id = m.id ',
          );
        }
        sql.write('WHERE m.account_id = ?');
        vars.add(Variable.withInt(accountId));
        if (beforeMessageId != null) {
          sql.write(' AND m.id < ?');
          vars.add(Variable.withInt(beforeMessageId));
        }
        if (hasNegFts) {
          sql.write(
            ' AND b.rowid NOT IN ('
            'SELECT rowid FROM stored_message_fts '
            'WHERE stored_message_fts MATCH ? AND account_id = ?'
            ')',
          );
          vars.add(Variable.withString(spec.negatedFtsMatch!));
          vars.add(Variable.withInt(accountId));
        }
      }

      if (spec.exactMessageId case final exactId?) {
        sql.write(' AND m.id = ?');
        vars.add(Variable.withInt(exactId));
      }
      if (spec.allowedMessageIds case final allowedMids?) {
        sql.write(' AND m.id IN (SELECT value FROM json_each(?))');
        vars.add(Variable.withString(jsonEncode(allowedMids.toList())));
      }
      if (spec.excludedMessageIds.isNotEmpty) {
        sql.write(' AND m.id NOT IN (SELECT value FROM json_each(?))');
        vars.add(Variable.withString(jsonEncode(spec.excludedMessageIds.toList())));
      }
      if (spec.isDm case final isDm?) {
        sql.write(isDm ? ' AND m.channel_id IS NULL' : ' AND m.channel_id IS NOT NULL');
      }
      if (spec.allowedChannelIds case final allowedCids?) {
        sql.write(' AND m.channel_id IN (SELECT value FROM json_each(?))');
        vars.add(Variable.withString(jsonEncode(allowedCids.toList())));
      }
      if (spec.excludedChannelIds.isNotEmpty) {
        sql.write(
          ' AND (m.channel_id IS NULL '
          'OR m.channel_id NOT IN (SELECT value FROM json_each(?)))',
        );
        vars.add(Variable.withString(jsonEncode(spec.excludedChannelIds.toList())));
      }
      if (spec.topicKey case final tKey?) {
        sql.write(' AND m.topic_key = ?');
        vars.add(Variable.withString(tKey));
      }
      if (spec.excludedTopicKeys.isNotEmpty) {
        sql.write(
          ' AND (m.topic_key IS NULL '
          'OR m.topic_key NOT IN (SELECT value FROM json_each(?)))',
        );
        vars.add(Variable.withString(jsonEncode(spec.excludedTopicKeys.toList())));
      }
      if (spec.dmKey case final dKey?) {
        sql.write(' AND m.dm_key = ?');
        vars.add(Variable.withString(dKey));
      }
      if (spec.excludedDmKeys.isNotEmpty) {
        sql.write(
          ' AND (m.dm_key IS NULL '
          'OR m.dm_key NOT IN (SELECT value FROM json_each(?)))',
        );
        vars.add(Variable.withString(jsonEncode(spec.excludedDmKeys.toList())));
      }
      if (spec.allowedSenderIds case final allowedSenders?) {
        sql.write(' AND m.sender_id IN (SELECT value FROM json_each(?))');
        vars.add(Variable.withString(jsonEncode(allowedSenders.toList())));
      }
      if (spec.excludedSenderIds.isNotEmpty) {
        sql.write(' AND m.sender_id NOT IN (SELECT value FROM json_each(?))');
        vars.add(Variable.withString(jsonEncode(spec.excludedSenderIds.toList())));
      }
      if (spec.requiredFlagsMask != 0) {
        sql.write(' AND (m.flags & ?) = ?');
        vars.add(Variable.withInt(spec.requiredFlagsMask));
        vars.add(Variable.withInt(spec.requiredFlagsMask));
      }
      if (spec.forbiddenFlagsMask != 0) {
        sql.write(' AND (m.flags & ?) = 0');
        vars.add(Variable.withInt(spec.forbiddenFlagsMask));
      }
      if (spec.anyFlagsMask != 0) {
        sql.write(' AND (m.flags & ?) != 0');
        vars.add(Variable.withInt(spec.anyFlagsMask));
      }

      sql.write(' ORDER BY m.id DESC LIMIT ?');
      vars.add(Variable.withInt(limit));

      final idRows = await customSelect(
        sql.toString(),
        variables: vars,
      ).get();
      if (idRows.isEmpty) return const [];

      final ids = [for (final row in idRows) row.read<int>('id')];
      final loaded = await _loadStoredRecordsInTxn(
        accountId,
        initialRows: const [],
        extraIds: ids,
      );
      return loaded.reversed.toList();
    });
  }

  /// Delete all cached message data across all accounts (cascading to message
  /// child tables), leaving server snapshot data intact.
  Future<void> wipeAllMessageCache() async {
    await delete(messageDbAccounts).go();
    await runIncrementalVacuum();
  }

  /// Delete all cached message data for [accountId] (cascading to message
  /// child tables), leaving server snapshot data intact.
  Future<void> wipeAccount(int accountId) async {
    await (delete(messageDbAccounts)
      ..where((a) => a.accountId.equals(accountId))).go();
  }

  /// Delete all data for [accountId], both cached messages and server snapshots.
  Future<void> purgeAccount(int accountId) async {
    await transaction(() async {
      await wipeAccount(accountId);
      await clearServerDataInTxn(accountId);
    });
    await runIncrementalVacuum();
  }

  /// Read [MessageDbAccounts.totalBodyBytes] for [accountId] inside a transaction.
  Future<int> readTotalBodyBytesInTxn(int accountId) async {
    final row = await customSelect(
      'SELECT total_body_bytes FROM message_db_accounts WHERE account_id = ?',
      variables: [Variable.withInt(accountId)],
    ).getSingleOrNull();
    return row?.read<int>('total_body_bytes') ?? 0;
  }

  /// Compute the global eviction id cutoff so the kept suffix stays under
  /// [targetBytes]. Reads only [StoredMessages] (no bodies).
  Future<int?> computeEvictionCutoffId(
    int accountId, {
    required int targetBytes,
  }) async {
    final row = await customSelect(
      'SELECT id FROM ('
      '  SELECT id, SUM(body_bytes) OVER (ORDER BY id DESC) AS acc '
      '  FROM stored_messages '
      '  WHERE account_id = ?'
      ') WHERE acc > ? '
      'ORDER BY id DESC '
      'LIMIT 1',
      variables: [Variable.withInt(accountId), Variable.withInt(targetBytes)],
    ).getSingleOrNull();
    if (row == null) return null;
    return 1 + row.read<int>('id');
  }

  /// Persist [cutoffId] in [MessageDbAccounts.evictedBelowMessageId] and
  /// commit clipped coverage intervals in one transaction.
  Future<void> applyEvictionCutoffInTxn(
    int accountId, {
    required int cutoffId,
    required Map<String, List<CoverageInterval>> dirtyCoverage,
  }) async {
    await customUpdate(
      'UPDATE message_db_accounts '
      'SET evicted_below_message_id = MAX(evicted_below_message_id, ?) '
      'WHERE account_id = ?',
      variables: [Variable.withInt(cutoffId), Variable.withInt(accountId)],
      updates: {messageDbAccounts},
    );
    await replaceCoverageKeysInTxn(accountId, dirtyCoverage);
    // Defensively clip any intervals not present in dirtyCoverage.
    await customUpdate(
      'DELETE FROM coverage_intervals '
      'WHERE account_id = ? AND hi IS NOT NULL AND hi < ?',
      variables: [Variable.withInt(accountId), Variable.withInt(cutoffId)],
      updates: {coverageIntervals},
    );
    await customUpdate(
      'UPDATE OR REPLACE coverage_intervals SET lo = ? '
      'WHERE account_id = ? AND lo < ?',
      variables: [
        Variable.withInt(cutoffId),
        Variable.withInt(accountId),
        Variable.withInt(cutoffId),
      ],
      updates: {coverageIntervals},
    );
  }

  /// Delete up to [limit] stored messages below [cutoffId] for [accountId],
  /// subtracting their bytes from [MessageDbAccounts.totalBodyBytes].
  Future<int> deleteEvictedChunkInTxn(
    int accountId, {
    required int cutoffId,
    int limit = 500,
  }) async {
    final rows = await customSelect(
      'SELECT id, body_bytes FROM stored_messages '
      'WHERE account_id = ? AND id < ? '
      'ORDER BY id ASC LIMIT ?',
      variables: [
        Variable.withInt(accountId),
        Variable.withInt(cutoffId),
        Variable.withInt(limit),
      ],
    ).get();
    if (rows.isEmpty) return 0;

    var removedBytes = 0;
    for (final row in rows) {
      removedBytes += row.read<int>('body_bytes');
    }
    final maxDeletedId = rows.last.read<int>('id');
    await customUpdate(
      'DELETE FROM stored_messages WHERE account_id = ? AND id <= ?',
      variables: [Variable.withInt(accountId), Variable.withInt(maxDeletedId)],
      updates: {storedMessages},
    );
    if (removedBytes > 0) {
      await customUpdate(
        'UPDATE message_db_accounts '
        'SET total_body_bytes = MAX(0, total_body_bytes - ?) '
        'WHERE account_id = ?',
        variables: [Variable.withInt(removedBytes), Variable.withInt(accountId)],
        updates: {messageDbAccounts},
      );
    }
    return rows.length;
  }

  /// Delete stored messages whose timestamp is strictly older than the
  /// corresponding family's retention cutoff, returning the deleted IDs and the
  /// highest deleted ID per family so coverage can be clipped cleanly.
  Future<({
    int? maxDeletedDmId,
    Map<int, int> maxDeletedByChannelId,
    List<int> deletedIds,
  })> purgeExpiredRetentionRowsInTxn(
    int accountId, {
    int? dmCutoffTimestamp,
    required Map<int, int> channelCutoffTimestamps,
  }) async {
    const chunkLimit = 500;
    var removedBytes = 0;
    int? maxDeletedDmId;
    final maxDeletedByChannelId = <int, int>{};
    final deletedIds = <int>[];

    if (dmCutoffTimestamp != null) {
      final dmRows = await (selectOnly(storedMessages)
            ..addColumns([storedMessages.id, storedMessages.bodyBytes])
            ..where(storedMessages.accountId.equals(accountId)
                & storedMessages.channelId.isNull()
                & storedMessages.timestamp.isSmallerThanValue(dmCutoffTimestamp))
            ..orderBy([OrderingTerm.asc(storedMessages.id)]))
          .get();
      for (final row in dmRows) {
        final id = row.read(storedMessages.id)!;
        deletedIds.add(id);
        removedBytes += row.read(storedMessages.bodyBytes)!;
        maxDeletedDmId = id;
      }
    }

    if (channelCutoffTimestamps.isNotEmpty) {
      final cutoffsJson = jsonEncode({
        for (final entry in channelCutoffTimestamps.entries)
          '${entry.key}': entry.value,
      });
      final chRows = await customSelect(
        'SELECT m.id, m.channel_id, m.body_bytes '
        'FROM json_each(?) AS c '
        'JOIN stored_messages AS m '
        '  ON m.account_id = ? '
        ' AND m.channel_id = CAST(c.key AS INTEGER) '
        ' AND m.timestamp < CAST(c.value AS INTEGER) '
        'ORDER BY m.id ASC',
        variables: [
          Variable.withString(cutoffsJson),
          Variable.withInt(accountId),
        ],
      ).get();
      for (final row in chRows) {
        final id = row.read<int>('id');
        final cid = row.read<int>('channel_id');
        deletedIds.add(id);
        removedBytes += row.read<int>('body_bytes');
        final prevMax = maxDeletedByChannelId[cid];
        if (prevMax == null || id > prevMax) {
          maxDeletedByChannelId[cid] = id;
        }
      }
    }

    for (var start = 0; start < deletedIds.length; start += chunkLimit) {
      final end = math.min(start + chunkLimit, deletedIds.length);
      await customUpdate(
        'DELETE FROM stored_messages '
        'WHERE account_id = ? AND id IN (SELECT value FROM json_each(?))',
        variables: [
          Variable.withInt(accountId),
          Variable.withString(jsonEncode(deletedIds.sublist(start, end))),
        ],
        updates: {storedMessages},
      );
    }

    if (removedBytes > 0) {
      await customUpdate(
        'UPDATE message_db_accounts '
        'SET total_body_bytes = MAX(0, total_body_bytes - ?) '
        'WHERE account_id = ?',
        variables: [Variable.withInt(removedBytes), Variable.withInt(accountId)],
        updates: {messageDbAccounts},
      );
    }

    return (
      maxDeletedDmId: maxDeletedDmId,
      maxDeletedByChannelId: maxDeletedByChannelId,
      deletedIds: deletedIds,
    );
  }

  /// Number of calls to [runIncrementalVacuum] for verifying idle scheduling.
  int debugIncrementalVacuumCalls = 0;

  /// Run `PRAGMA incremental_vacuum` outside any transaction.
  Future<void> runIncrementalVacuum([int? pages]) async {
    debugIncrementalVacuumCalls++;
    final sql = pages != null
      ? 'PRAGMA incremental_vacuum($pages)'
      : 'PRAGMA incremental_vacuum';
    await customStatement(sql);
  }

  /// Remove data for any account id no longer present in [liveAccountIds].
  Future<void> sweepOrphanAccounts(Set<int> liveAccountIds) {
    return transaction(() async {
      if (liveAccountIds.isEmpty) {
        await delete(messageDbAccounts).go();
        await delete(serverSnapshots).go();
        return;
      }
      await (delete(messageDbAccounts)
        ..where((a) => a.accountId.isNotIn(liveAccountIds))).go();
      await (delete(serverSnapshots)
        ..where((s) => s.accountId.isNotIn(liveAccountIds))).go();
    });
  }

  /// Store [snapshot] as its account's [ServerSnapshot], with [data],
  /// replacing any previous one and deleting its [ServerEventBatch]es.
  Future<bool> storeServerSnapshot(ServerSnapshot snapshot, {
    required Uint8List data,
  }) {
    return transaction(() async {
      await (delete(serverEventBatches)
        ..where((b) => b.accountId.equals(snapshot.accountId))
      ).go();
      await into(serverSnapshots).insertOnConflictUpdate(snapshot);
      await into(serverSnapshotBlobs).insertOnConflictUpdate(
        ServerSnapshotBlob(accountId: snapshot.accountId, data: data));
      return true;
    });
  }

  /// In-transaction body of [appendServerEvents].
  Future<bool> appendServerEventsInTxn(int accountId, {
    required String queueId,
    required int lastEventId,
    required Uint8List? data,
  }) async {
    final rowsAffected = await (update(serverSnapshots)
      ..where((s) => s.accountId.equals(accountId)
          & s.queueId.equals(queueId)
          & s.lastEventId.isSmallerThanValue(lastEventId))
    ).write(ServerSnapshotsCompanion(lastEventId: Value(lastEventId)));
    if (rowsAffected == 0) return false;

    if (data != null) {
      await into(serverEventBatches).insert(ServerEventBatchesCompanion.insert(
        accountId: accountId,
        queueId: queueId,
        lastEventId: lastEventId,
        data: data));
    }
    return true;
  }

  /// Record a batch of events received on the account's stored event queue.
  Future<bool> appendServerEvents(int accountId, {
    required String queueId,
    required int lastEventId,
    required Uint8List? data,
  }) {
    return transaction(() => appendServerEventsInTxn(accountId,
      queueId: queueId, lastEventId: lastEventId, data: data));
  }

  /// In-transaction body of [truncateServerEventLog].
  Future<bool> truncateServerEventLogInTxn(int accountId, {
    required String queueId,
    required int lastEventId,
  }) async {
    final rowsAffected = await (update(serverSnapshots)
      ..where((s) => s.accountId.equals(accountId)
          & s.queueId.equals(queueId)
          & s.lastEventId.isSmallerThanValue(lastEventId))
    ).write(ServerSnapshotsCompanion(
      lastEventId: Value(lastEventId),
      eventLogTruncated: const Value(true)));
    if (rowsAffected == 0) return false;

    await (delete(serverEventBatches)
      ..where((b) => b.accountId.equals(accountId))
    ).go();
    return true;
  }

  /// Record that events received on the account's stored event queue
  /// are being left out of the stored event log.
  Future<bool> truncateServerEventLog(int accountId, {
    required String queueId,
    required int lastEventId,
  }) {
    return transaction(() => truncateServerEventLogInTxn(accountId,
      queueId: queueId, lastEventId: lastEventId));
  }

  /// Get the metadata of the account's [ServerSnapshot] and its event batches,
  /// without reading their data.
  Future<ServerSnapshotInfo?> loadServerSnapshotInfo(int accountId) {
    return transaction(() async {
      final snapshot = await (select(serverSnapshots)
        ..where((s) => s.accountId.equals(accountId))
      ).getSingleOrNull();
      if (snapshot == null) return null;

      final snapshotSize = serverSnapshotBlobs.data.length;
      final snapshotBlobRow = await (selectOnly(serverSnapshotBlobs)
        ..addColumns([snapshotSize])
        ..where(serverSnapshotBlobs.accountId.equals(accountId))
      ).getSingleOrNull();
      if (snapshotBlobRow == null) return null;

      final eventBatchesSize = serverEventBatches.data.length.sum();
      final eventBatchesRow = await (selectOnly(serverEventBatches)
        ..addColumns([eventBatchesSize])
        ..where(serverEventBatches.accountId.equals(accountId)
          & serverEventBatches.queueId.equals(snapshot.queueId))
      ).getSingle();

      return (
        realmUrl: snapshot.realmUrl,
        userId: snapshot.userId,
        queueId: snapshot.queueId,
        lastEventId: snapshot.lastEventId,
        appVersion: snapshot.appVersion,
        timestamp: snapshot.timestamp,
        eventLogTruncated: snapshot.eventLogTruncated,
        snapshotSize: snapshotBlobRow.read(snapshotSize)!,
        eventBatchesSize: eventBatchesRow.read(eventBatchesSize) ?? 0,
      );
    });
  }

  /// Get the account's [ServerSnapshot], its data,
  /// and its event batches, in order.
  Future<ServerData?> loadServerData(int accountId, {
    bool includeEventBatches = true,
  }) {
    return transaction(() async {
      final snapshot = await (select(serverSnapshots)
        ..where((s) => s.accountId.equals(accountId))
      ).getSingleOrNull();
      if (snapshot == null) return null;
      final snapshotBlob = await (select(serverSnapshotBlobs)
        ..where((s) => s.accountId.equals(accountId))
      ).getSingleOrNull();
      if (snapshotBlob == null) return null;
      if (!includeEventBatches) {
        return (snapshot: snapshot, snapshotData: snapshotBlob.data,
          eventBatches: <ServerEventBatch>[]);
      }

      final eventBatches = await (select(serverEventBatches)
        ..where((b) => b.accountId.equals(accountId)
          & b.queueId.equals(snapshot.queueId))
        ..orderBy([(b) => OrderingTerm.asc(b.id)])
      ).get();
      return (snapshot: snapshot, snapshotData: snapshotBlob.data,
        eventBatches: eventBatches);
    });
  }

  /// In-transaction body of [clearServerData].
  Future<void> clearServerDataInTxn(int accountId) async {
    await (delete(serverEventBatches)
      ..where((b) => b.accountId.equals(accountId))
    ).go();
    await (delete(serverSnapshotBlobs)
      ..where((s) => s.accountId.equals(accountId))
    ).go();
    await (delete(serverSnapshots)
      ..where((s) => s.accountId.equals(accountId))
    ).go();
  }

  /// Delete the account's [ServerSnapshot], its data,
  /// and its [ServerEventBatch]es, if any.
  Future<void> clearServerData(int accountId) {
    return transaction(() => clearServerDataInTxn(accountId));
  }
}

/// Persisted message-DB account metadata, coverage, channel visibility,
/// and the set of channels with stored rows or coverage intervals.
typedef LoadedMessageDbAccountState = ({
  MessageDbAccount account,
  Map<String, List<CoverageInterval>> intervalsByKey,
  Map<int, bool> channels,
  Set<int> channelsWithData,
});

/// Stored message metadata needed to detect absent-in-range forgets.
typedef StoredCoverageRow = ({
  int id,
  int? channelId,
  String? topic,
  String? topicKey,
  String? dmKey,
});

/// Full persisted rows for a single stored message.
typedef LoadedStoredMessage = ({
  StoredMessage row,
  StoredMessageBody body,
  List<StoredReaction> reactions,
  List<StoredSubmessage> submessages,
});

/// Result of [MessageDatabase.queryWindowRows], indicating whether SQLite holds
/// additional rows past the requested page bounds.
typedef StoredWindowQueryResult = ({
  List<LoadedStoredMessage> records,
  bool hasMoreBefore,
  bool hasMoreAfter,
});

/// Pushdown filter specification for [MessageDatabase.searchStoredMessages].
class StoredMessageSearchSpec {
  const StoredMessageSearchSpec({
    this.positiveFtsMatch,
    this.negatedFtsMatch,
    this.allowedChannelIds,
    this.excludedChannelIds = const {},
    this.topicKey,
    this.excludedTopicKeys = const {},
    this.isDm,
    this.dmKey,
    this.excludedDmKeys = const {},
    this.allowedSenderIds,
    this.excludedSenderIds = const {},
    this.requiredFlagsMask = 0,
    this.forbiddenFlagsMask = 0,
    this.anyFlagsMask = 0,
    this.exactMessageId,
    this.allowedMessageIds,
    this.excludedMessageIds = const {},
  });

  final String? positiveFtsMatch;
  final String? negatedFtsMatch;
  final Set<int>? allowedChannelIds;
  final Set<int> excludedChannelIds;
  final String? topicKey;
  final Set<String> excludedTopicKeys;
  final bool? isDm;
  final String? dmKey;
  final Set<String> excludedDmKeys;
  final Set<int>? allowedSenderIds;
  final Set<int> excludedSenderIds;
  final int requiredFlagsMask;
  final int forbiddenFlagsMask;
  final int anyFlagsMask;
  final int? exactMessageId;
  final Set<int>? allowedMessageIds;
  final Set<int> excludedMessageIds;
}

/// Metadata about an account's [ServerSnapshot]
/// and the [ServerEventBatch]es on its event queue.
typedef ServerSnapshotInfo = ({
  String realmUrl,
  int userId,
  String queueId,
  int lastEventId,
  String appVersion,
  int timestamp,
  bool eventLogTruncated,
  int snapshotSize,
  int eventBatchesSize,
});

/// An account's [ServerSnapshot], its data (see [ServerSnapshotBlob.data]),
/// and the [ServerEventBatch]es on its event queue, in order.
typedef ServerData = ({
  ServerSnapshot snapshot,
  Uint8List snapshotData,
  List<ServerEventBatch> eventBatches,
});
